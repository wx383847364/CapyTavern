extends RefCounted
## 读正式数值表（client/data/balance/，design/balance 的原样副本）和程序自有的站位文件，
## 拼成战斗结算用的一份配置，并把天赋、两件套修正算进技能。
## 口径照 design/balance/README.md：同类加算 add_pct；add_flat 只给持续时间；
## 消耗四舍五入取整，时间保留 0.1 秒；伤害和治疗在最终结算时才取整。
## 这里不写任何数值，也不改副本；改数值走策划。

const BALANCE_DIR := "res://data/balance/"
const LAYOUT_PATH := "res://data/battle_layout.json"
const TABLES: Array[String] = ["global", "classes", "skills", "enemies", "modifiers"]
const DEFAULT_TALENT := "t1"

## 修正行里 param 对应到技能的哪里。
const TOP_LEVEL_PARAMS: Array[String] = ["cost", "cooldown"]
const EFFECT_PARAMS := {"damage": ["damage", "amount"], "heal": ["heal", "amount"]}


## options：
##   talents  {class_id: "t1"|"t2"}，缺省或非法标识回默认 t1
##   sets     [class_id, ...] 已凑齐两件套的职业
##   dir      数值表目录（测试用）
##   modifiers false 时完全不套天赋和两件套（只给对照实验用）
## 返回合并后的配置；读不到表返回空字典，并把原因写进 push_error。
static func load_balance(options: Dictionary = {}) -> Dictionary:
	var dir: String = String(options.get("dir", BALANCE_DIR))
	var tables := {}
	for name in TABLES:
		var parsed := _read_json(dir.path_join("%s.json" % name))
		if parsed.is_empty():
			return {}
		tables[name] = parsed
	var layout := _read_json(LAYOUT_PATH)
	if layout.is_empty():
		return {}

	var global: Dictionary = tables["global"]
	var config := {}
	for key in ["tick", "time_limit", "gcd", "crit_chance", "crit_mult", "heal_threat", "defense_formula", "party_scaling"]:
		if global.has(key):
			config[key] = global[key]
	for key in ["unit_radius", "arena", "ally_spawn", "attack_school"]:
		config[key] = layout[key]
	config["classes"] = _strip_meta(tables["classes"])
	config["enemies"] = _strip_meta(tables["enemies"])
	config["skills"] = (tables["skills"]["skills"] as Dictionary).duplicate(true)

	# wave：敌人构成读数值表，站位读程序文件（沿用 P1）
	var wave: Array = (global["wave"] as Array).duplicate(true)
	var positions: Array = layout.get("wave_positions", [])
	for index in wave.size():
		if index < positions.size():
			wave[index]["x"] = positions[index]["x"]
			wave[index]["y"] = positions[index]["y"]
	config["wave"] = wave

	var talents: Dictionary = {}
	var warnings: Array[String] = []
	var applied: Array = []
	var rows: Array = tables["modifiers"]["rows"]
	var sets: Array = options.get("sets", [])
	for class_id: String in config["classes"]:
		var chosen := resolve_talent(rows, class_id, _requested_talent(options, class_id))
		talents[class_id] = chosen
		var picked: Array = []
		for row: Dictionary in rows:
			if String(row["class_id"]) != class_id:
				continue
			var group := String(row["group"])
			if group == "talent" and talent_key(String(row["id"])) == chosen:
				picked.append(row)
			elif group == "set" and sets.has(class_id):
				picked.append(row)
		if not bool(options.get("modifiers", true)):
			picked = []
		_apply_rows(config["skills"], picked, warnings)
		for row: Dictionary in picked:
			applied.append(String(row["id"]))
	config["talents"] = talents
	config["applied_modifiers"] = applied
	config["warnings"] = warnings
	return config


## 职业有哪些天赋选项（从修正行的 id 里取，如 war_t1_dur → t1），按名字排序。
static func talent_ids(rows: Array, class_id: String) -> Array[String]:
	var found: Array[String] = []
	for row: Dictionary in rows:
		if String(row["class_id"]) == class_id and String(row["group"]) == "talent":
			var key := talent_key(String(row["id"]))
			if key != "" and not found.has(key):
				found.append(key)
	found.sort()
	return found


## 请求的天赋不在选项里（含空串）就回默认 t1。
static func resolve_talent(rows: Array, class_id: String, requested: String) -> String:
	var options := talent_ids(rows, class_id)
	if options.has(requested):
		return requested
	return DEFAULT_TALENT


## id 形如 "war_t1_dur"：第二段是天赋标识。取不到返回空串。
static func talent_key(row_id: String) -> String:
	var parts := row_id.split("_")
	if parts.size() >= 3 and parts[1].begins_with("t") and parts[1].substr(1).is_valid_int():
		return parts[1]
	return ""


## 请求的天赋标识：存档里可能是任何类型，一律转成字符串，转不出有效值就当没选。
static func _requested_talent(options: Dictionary, class_id: String) -> String:
	var talents: Variant = options.get("talents", {})
	if typeof(talents) != TYPE_DICTIONARY:
		return ""
	var value: Variant = (talents as Dictionary).get(class_id, "")
	if typeof(value) == TYPE_STRING or typeof(value) == TYPE_STRING_NAME:
		return String(value)
	return ""


static func _apply_rows(skills: Dictionary, picked: Array, warnings: Array[String]) -> void:
	# 先按 (技能, 参数) 汇总，再一次算出有效值，避免叠层顺序影响结果
	var sums := {}
	for row: Dictionary in picked:
		var key := "%s|%s" % [row["skill_id"], row["param"]]
		var entry: Dictionary = sums.get(key, {"skill": row["skill_id"], "param": row["param"], "pct": 0.0, "flat": 0.0, "ids": []})
		match String(row["op"]):
			"add_pct":
				entry["pct"] = float(entry["pct"]) + float(row["value"])
			"add_flat":
				entry["flat"] = float(entry["flat"]) + float(row["value"])
			_:
				warnings.append("修正 %s 的 op=%s 不认识，已忽略" % [row["id"], row["op"]])
		(entry["ids"] as Array).append(row["id"])
		sums[key] = entry
	for key in sums:
		var entry: Dictionary = sums[key]
		var skill_id := String(entry["skill"])
		if not skills.has(skill_id):
			warnings.append("修正 %s 指向不存在的技能 %s，已忽略" % [entry["ids"], skill_id])
			continue
		var skill: Dictionary = skills[skill_id]
		var param := String(entry["param"])
		var pct := float(entry["pct"])
		var flat := float(entry["flat"])
		var touched := false
		if TOP_LEVEL_PARAMS.has(param) and skill.has(param):
			var value := float(skill[param]) * (1.0 + pct) + flat
			skill[param] = roundi(value) if param == "cost" else snappedf(value, 0.1)
			touched = true
		elif EFFECT_PARAMS.has(param):
			var spec: Array = EFFECT_PARAMS[param]
			for effect: Dictionary in skill["effects"]:
				if String(effect["kind"]) == String(spec[0]) and effect.has(spec[1]):
					effect[spec[1]] = float(effect[spec[1]]) * (1.0 + pct) + flat
					touched = true
		elif param == "radius":
			for effect: Dictionary in skill["effects"]:
				if effect.has("radius") and float(effect["radius"]) > 0.0:
					effect["radius"] = float(effect["radius"]) * (1.0 + pct) + flat
					touched = true
		elif param == "duration":
			for effect: Dictionary in skill["effects"]:
				if effect.has("duration"):
					effect["duration"] = snappedf(float(effect["duration"]) * (1.0 + pct) + flat, 0.1)
					touched = true
		if not touched:
			warnings.append("修正 %s 的参数 %s 在技能 %s 上没有对应字段，已忽略" % [entry["ids"], param, skill_id])


static func _strip_meta(table: Dictionary) -> Dictionary:
	var out := {}
	for key in table:
		if not String(key).begins_with("_"):
			out[key] = (table[key] as Dictionary).duplicate(true)
	return out


static func _read_json(path: String) -> Dictionary:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		push_error("数值文件读不到：%s（%s）" % [path, error_string(FileAccess.get_open_error())])
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("数值文件不是 JSON 对象：%s" % path)
		return {}
	return parsed
