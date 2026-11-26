extends RefCounted
## 战斗配置入口。数值来自 data/balance/（策划表的原样副本）+ data/battle_layout.json（站位）。
## 所有战斗数值只从这里来，脚本里不写死。读不到时返回空字典，调用方自己决定怎么报。
## options 见 BalanceLoader.load_balance：talents、sets、dir。

const BalanceLoader := preload("res://scripts/data/balance_loader.gd")


## 保留旧 balance JSON 配置入口；五技能使用显式的独立目录加载。
static func load_config(options: Dictionary = {}) -> Dictionary:
	return BalanceLoader.load_balance(options)


## 校验必要字段，返回问题列表；空表示可用。
static func validate(config: Dictionary) -> PackedStringArray:
	var problems := PackedStringArray()
	for key in ["tick", "time_limit", "gcd", "classes", "skills", "enemies", "wave", "party_scaling", "arena", "ally_spawn", "defense_formula"]:
		if not config.has(key):
			problems.append("缺字段 %s" % key)
	if not problems.is_empty():
		return problems
	for class_id in config["classes"]:
		var cls: Dictionary = config["classes"][class_id]
		for slot_key in ["q", "w", "e", "r"]:
			var skill_id: String = cls.get("skills", {}).get(slot_key, "")
			if skill_id.is_empty() or not config["skills"].has(skill_id):
				problems.append("职业 %s 的 %s 技能 %s 未定义" % [class_id, slot_key, skill_id])
	for skill_id: String in config["skills"]:
		var skill: Dictionary = config["skills"][skill_id]
		if not _valid_auto_use(skill.get("auto_use", {})):
			problems.append("%s.auto_use: 无效的自动施放规则" % skill_id)
	for entry in config["wave"]:
		if not config["enemies"].has(entry.get("enemy", "")):
			problems.append("wave 里有未定义的敌人 %s" % entry.get("enemy", ""))
	return problems


## 将旧配置颜色转换为 Godot 颜色，不改变已有表现调用。
static func color_of(hex: String) -> Color:
	return Color.html(hex)


# ── 五技能 Resource 目录：与旧 balance JSON 入口隔离 ──
const SkillDef := preload("res://scripts/battle/skill_def.gd")
const SkillEffectDef := preload("res://scripts/battle/skill_effect_def.gd")
const SpecLoadout := preload("res://scripts/battle/spec_loadout.gd")
const SPEC_IDS := ["mage.fire", "priest.holy"]
const SKILL_PATHS := [
	"res://data/skills/mage.fire.flame_burst.tres",
	"res://data/skills/mage.fire.fireball.tres",
	"res://data/skills/mage.fire.flame_barrier.tres",
	"res://data/skills/mage.fire.evocation.tres",
	"res://data/skills/priest.holy.greater_heal.tres",
]
const LOADOUT_PATHS := [
	"res://data/skills/mage.fire.tres",
	"res://data/skills/priest.holy.tres",
]


## 只识别裁决中的正式阵容，专精数组保留原四槽及空位。
static func formal_specs(slots: Array) -> Array:
	if slots.size() != 4 or slots.count("mage") != 1 or slots.count("priest") > 1:
		return []
	var specs: Array = []
	for class_id: Variant in slots:
		match class_id:
			"": specs.append("")
			"mage": specs.append("mage.fire")
			"priest": specs.append("priest.holy")
			_: return []
	return specs


## 检查正式初始化所用的数值源。缺失字段不得落到旧出生默认值或先建立战斗。
static func formal_config_problems(config: Dictionary, slots: Array) -> PackedStringArray:
	var problems := PackedStringArray()
	for key: String in ["party_scaling", "arena", "ally_spawn", "defense_formula", "classes", "enemies", "attack_school"]:
		if not config.get(key) is Dictionary:
			problems.append("正式配置 %s 需要字典" % key)
	if not config.get("wave") is Array:
		problems.append("正式配置 wave 需要数组")
	if not problems.is_empty():
		return problems
	for class_id: Variant in config["classes"]:
		if not config["classes"][class_id] is Dictionary or not config["classes"][class_id].get("skills") is Dictionary:
			problems.append("职业 %s 技能表无效" % class_id)
	if not config.get("skills") is Dictionary:
		problems.append("正式技能表无效")
	for entry: Variant in config["wave"]:
		if not entry is Dictionary or not config["enemies"].get(entry.get("enemy")) is Dictionary:
			problems.append("正式波次包含未知敌人")
	if not problems.is_empty():
		return problems
	problems = validate(config)
	if not problems.is_empty():
		return problems
	var party_size := slots.size() - slots.count("")
	var scaling: Variant = config["party_scaling"].get(str(party_size))
	var groups: Array = [[config, ["tick", "time_limit", "unit_radius"]], [config["arena"], ["w", "h"]],
		[config["ally_spawn"], ["x", "y0", "dy"]], [config["defense_formula"], ["K"]], [scaling, ["hp", "dmg"]]]
	for class_id: String in slots:
		if class_id.is_empty():
			continue
		var cls: Dictionary = config["classes"].get(class_id, {})
		groups.append_array([[cls, ["max_hp", "armor", "magic_resist", "speed", "threat_coef"]],
			[cls.get("attack"), ["range", "damage", "interval"]], [cls.get("resource"), ["max", "start", "regen"]]])
		var attack_kind := "damage" if class_id == "mage" else "heal"
		if not cls.get("name") is String or not cls.get("color") is String or not cls.get("attack") is Dictionary or cls["attack"].get("kind") != attack_kind:
			problems.append("%s: 名称、颜色或普攻类型无效" % class_id)
		if cls.get("resource") is Dictionary:
			var mana: Dictionary = cls["resource"]
			if mana.get("kind") != "mana" or mana.get("max") != 100.0 or mana.get("start") != 100.0:
				problems.append("%s.resource: 正式出场需要满额 100 法力" % class_id)
	for entry: Dictionary in config["wave"]:
		var enemy: Dictionary = config["enemies"][entry["enemy"]]
		groups.append_array([[entry, ["x", "y"]], [enemy, ["max_hp", "radius", "speed", "attack_range", "damage", "interval", "armor", "magic_resist"]]])
		if not enemy.get("name") is String or not enemy.get("color") is String:
			problems.append("敌人 %s 名称或颜色无效" % entry["enemy"])
		if enemy.has("spell"):
			groups.append([enemy["spell"], ["cast_time", "cooldown", "first_at", "range", "damage", "radius"]])
			var spell: Variant = enemy["spell"]
			if not spell is Dictionary or not spell.get("name") is String or not spell.get("id") is String or not spell.get("interruptible") is bool:
				problems.append("敌人 %s 施法配置无效" % entry["enemy"])
	for group: Array in groups:
		for field: String in group[1]:
			if not group[0] is Dictionary or not _nonnegative_number(group[0].get(field)):
				problems.append("正式数值 %s 缺失或无效" % field)
	if problems.is_empty() and (float(config["tick"]) <= 0.0 or float(config["time_limit"]) <= 0.0 or float(config["defense_formula"]["K"]) <= 0.0 or float(scaling["hp"]) <= 0.0 or config["wave"].is_empty()):
		problems.append("正式配置的周期、防护常数、缩放或波次无效")
	if not config["arena"] is Dictionary or not _nonnegative_number(config["arena"].get("x")) or not _nonnegative_number(config["arena"].get("y")):
		problems.append("正式战场原点缺失或无效")
	return problems


## 加载并校验目录；默认源不变，错误附真实路径，强类型截断后的空效果不能推测原下标。
static func load_skill_catalog(skill_paths: Array = SKILL_PATHS, loadout_paths: Array = LOADOUT_PATHS) -> Dictionary:
	var skills: Array = []
	var loadouts: Array = []
	for path: String in skill_paths:
		skills.append(load(path))
	for path: String in loadout_paths:
		loadouts.append(load(path))
	var catalog := build_skill_catalog(skills, loadouts)
	# build 已将加载失败的目录整体清空；再以本次实际读取路径补充诊断，不推测内部技能 ID。
	for i in skills.size():
		if skills[i] == null:
			catalog["problems"].append("%s.resource: 加载失败" % skill_paths[i])
		elif skills[i] is SkillDef and skills[i].effects.is_empty():
			# 引擎可能已丢失整个强类型数组；只报告能确认的加载边界，不伪造元素位置。
			catalog["problems"].append("%s -> %s.effects: 加载后效果列表为空，无法恢复元素下标" % [skill_paths[i], skills[i].skill_id])
	for i in loadouts.size():
		if loadouts[i] == null:
			catalog["problems"].append("%s.resource: 加载失败" % loadout_paths[i])
	return catalog


## 校验 Resource 源并转为只读基础参数；数组输入允许测试在加载前注入坏源。
static func build_skill_catalog(skill_sources: Array, loadout_sources: Array) -> Dictionary:
	var problems := PackedStringArray()
	var skills: Dictionary = {}
	var loadouts: Dictionary = {}
	if skill_sources.is_empty():
		problems.append("catalog.skills: 缺少技能源")
	if loadout_sources.is_empty():
		problems.append("catalog.loadouts: 缺少专精源")
	for i in skill_sources.size():
		var source: Variant = skill_sources[i]
		if not source is SkillDef:
			problems.append("skills[%d].resource: 不是 SkillDef 或加载失败" % i)
			continue
		var data := _skill_data(source)
		problems.append_array(validate_resolved_skill(data))
		var id: String = source.skill_id
		if skills.has(id):
			problems.append("%s.skill_id: 重复 ID" % id)
		skills[id] = data
	for i in loadout_sources.size():
		var source: Variant = loadout_sources[i]
		if not source is SpecLoadout:
			problems.append("loadouts[%d].resource: 不是 SpecLoadout 或加载失败" % i)
			continue
		var id: String = source.spec_id
		if id not in SPEC_IDS:
			problems.append("%s.spec_id: 非法或缺失专精" % id)
		if loadouts.has(id):
			problems.append("%s.spec_id: 重复 ID" % id)
		if source.slots.size() != 4:
			problems.append("%s.slots: 必须显式填写四槽" % id)
		var seen: Dictionary = {}
		for slot_index in source.slots.size():
			var skill_id: String = source.slots[slot_index]
			if skill_id.is_empty():
				continue
			var field := "%s.slots[%d]" % [id, slot_index]
			if seen.has(skill_id):
				problems.append("%s: 重复技能 %s" % [field, skill_id])
			seen[skill_id] = true
			if not skills.has(skill_id):
				problems.append("%s: 未定义技能 %s" % [field, skill_id])
			elif skills[skill_id]["spec_id"] != id:
				problems.append("%s: 技能 %s 归属专精不匹配" % [field, skill_id])
		loadouts[id] = source.slots.duplicate()
	# 错误不降级为零，也不返回剩余“可用”技能。
	if not problems.is_empty():
		return {"skills": {}, "loadouts": {}, "problems": problems}
	return {"skills": skills, "loadouts": loadouts, "problems": problems}


## 为一个角色生成独立的槽位与嵌套效果副本；不读取旧 modifiers 或天赋。
static func resolve_spec(catalog: Dictionary, spec_id: String) -> Dictionary:
	if not catalog.has("problems") or not catalog["problems"].is_empty():
		return {"slots": {}, "problems": PackedStringArray(["%s.catalog: 目录未通过校验" % spec_id])}
	if not catalog["loadouts"].has(spec_id):
		return {"slots": {}, "problems": PackedStringArray(["%s.spec_id: 专精未定义" % spec_id])}
	var slots: Dictionary = {}
	var keys := ["q", "w", "e", "r"]
	for i in 4:
		var id: String = catalog["loadouts"][spec_id][i]
		slots[keys[i]] = {} if id.is_empty() else catalog["skills"][id].duplicate(true)
	return {"slots": slots, "problems": PackedStringArray()}


## 校验派生参数完整性；预检复用它拦截被错误修改的副本，不为缺项填零。
static func validate_resolved_skill(data: Dictionary) -> PackedStringArray:
	var problems := PackedStringArray()
	var id := String(data.get("skill_id", "<missing>"))
	for field in ["skill_id", "spec_id", "name", "target_kind"]:
		if not data.get(field) is String or String(data[field]).strip_edges().is_empty():
			problems.append("%s.%s: 缺少非空字符串" % [id, field])
	if data.get("spec_id") not in SPEC_IDS:
		problems.append("%s.spec_id: 非法专精" % id)
	elif not id.begins_with(String(data["spec_id"]) + ".") or id == String(data["spec_id"]) + ".":
		problems.append("%s.skill_id: 稳定 ID 与专精不匹配" % id)
	if not data.has("icon") or (data["icon"] != null and not data["icon"] is Texture2D):
		problems.append("%s.icon: 缺失或类型错误；允许显式 null 占位" % id)
	for field in ["cast_range_m", "mana_cost", "cooldown_s"]:
		_check_number(data, field, id, problems)
	if not _valid_auto_use(data.get("auto_use", {})):
		problems.append("%s.auto_use: 无效的自动施放规则" % id)
	var target: Variant = data.get("target_kind")
	if target not in ["ENEMY", "ALLY", "SELF"]:
		problems.append("%s.target_kind: 非法目标类型" % id)
	if target == "SELF" and data.get("cast_range_m") != 0.0:
		problems.append("%s.cast_range_m: 自身技能射程必须为零" % id)
	if not data.get("effects") is Array or data["effects"].is_empty():
		problems.append("%s.effects: 缺少非空有序效果列表" % id)
		return problems
	for i in data["effects"].size():
		var effect: Variant = data["effects"][i]
		var field := "%s.effects[%d]" % [id, i]
		if not effect is Dictionary:
			problems.append("%s: 缺少 SkillEffectDef" % field)
			continue
		for number_field in ["power_coeff", "flat_amount", "radius_m", "duration_s"]:
			_check_number(effect, number_field, field, problems)
		for flag in ["uses_stable_crit", "uses_mastery"]:
			if not effect.get(flag) is bool:
				problems.append("%s.%s: 缺少显式布尔值" % [field, flag])
		var kind: Variant = effect.get("kind")
		var selector: Variant = effect.get("selector")
		var allowed_selectors: Array = []
		match kind:
			"MAGIC_DAMAGE":
				allowed_selectors = ["PRIMARY", "ENEMIES_AROUND_PRIMARY"]
				if target != "ENEMY" or data.get("spec_id") != "mage.fire":
					problems.append("%s.kind: 首版魔法伤害必须属于法师敌方技能" % field)
			"HEAL":
				allowed_selectors = ["PRIMARY"]
				if target != "ALLY" or data.get("spec_id") != "priest.holy":
					problems.append("%s.kind: 首版治疗必须属于牧师友方技能" % field)
			"SHIELD", "RESTORE_MANA":
				allowed_selectors = ["SELF"]
				if target != "SELF":
					problems.append("%s.kind: 首版护盾与回蓝必须为自身技能" % field)
			_:
				problems.append("%s.kind: 非法或缺失效果类型" % field)
		if selector not in allowed_selectors:
			problems.append("%s.selector: 非法效果与选择器组合" % field)
		if _nonnegative_number(effect.get("radius_m")):
			if (selector == "ENEMIES_AROUND_PRIMARY" and effect["radius_m"] <= 0.0) or (selector != "ENEMIES_AROUND_PRIMARY" and effect["radius_m"] != 0.0):
				problems.append("%s.radius_m: 范围半径必须正数，其他效果填零" % field)
		if _nonnegative_number(effect.get("duration_s")):
			if (kind == "SHIELD" and effect["duration_s"] <= 0.0) or (kind != "SHIELD" and effect["duration_s"] != 0.0):
				problems.append("%s.duration_s: 护盾时长必须正数，其他效果填零" % field)
		if kind in ["SHIELD", "RESTORE_MANA"] and (effect.get("uses_stable_crit") != false or effect.get("uses_mastery") != false):
			problems.append("%s.uses_stable_crit/uses_mastery: 护盾与回蓝不享受暴击或专精" % field)
		if kind in ["MAGIC_DAMAGE", "HEAL"] and effect.get("uses_stable_crit") != true:
			problems.append("%s.uses_stable_crit: 首版直接伤害与治疗必须使用稳定暴击" % field)
		if selector == "ENEMIES_AROUND_PRIMARY" and effect.get("uses_mastery") != false:
			problems.append("%s.uses_mastery: 首版烈焰爆破不享受专精" % field)
		if kind in ["MAGIC_DAMAGE", "HEAL", "SHIELD"] and effect.get("flat_amount") != 0.0:
			problems.append("%s.flat_amount: 首版伤害、治疗与护盾未使用固定量，必须填零" % field)
		if kind == "RESTORE_MANA" and effect.get("power_coeff") != 0.0:
			problems.append("%s.power_coeff: 首版回蓝仅用固定值" % field)
	return problems


## 旧表与正式资源共用规则验证；缺省或空字典只保留手动施放。
static func _valid_auto_use(rule: Variant) -> bool:
	if not rule is Dictionary:
		return false
	if rule.is_empty():
		return true
	if not _nonnegative_number(rule.get("priority")):
		return false
	var condition: Variant = rule.get("condition")
	if condition in ["low_resource", "low_hp", "unprotected", "threatened", "heal_area"]:
		var threshold: Variant = rule.get("threshold")
		if not _nonnegative_number(threshold) or threshold <= 0.0 or threshold > 1.0:
			return false
	if condition in ["unprotected", "threatened", "basic_range"] and rule.get("status") not in ["shield", "mitigate", "haste"]:
		return false
	match condition:
		"damage_area":
			return _nonnegative_number(rule.get("crowd_priority"))
		"heal_area":
			return _nonnegative_number(rule.get("minimum")) and rule["minimum"] >= 1
	return condition in ["ready", "low_resource", "low_hp", "unprotected", "threatened", "interrupt", "recover_aggro", "basic_range"]


## 统一拒绝缺失、非数字、无穷、NaN 与负值；布尔值不能充当数字。
static func _nonnegative_number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value)) and float(value) >= 0.0


## 累积带 ID 和字段路径的问题，不在校验中修复源数据。
static func _check_number(data: Dictionary, field: String, id: String, problems: PackedStringArray) -> void:
	if not _nonnegative_number(data.get(field)):
		problems.append("%s.%s: 缺失、非有限或负数" % [id, field])


## 从有类型的 Resource 提取参数；未显式声明的可空/布尔字段保留为错误状态。
static func _skill_data(source: SkillDef) -> Dictionary:
	var data := {
		"skill_id": source.skill_id, "spec_id": source.spec_id, "name": source.name,
		"target_kind": source.target_kind, "cast_range_m": source.cast_range_m,
		"mana_cost": source.mana_cost, "cooldown_s": source.cooldown_s, "effects": [],
	}
	if not source.auto_use.is_empty():
		data["auto_use"] = source.auto_use.duplicate(true)
	if source.icon_declared:
		data["icon"] = source.icon
	for source_effect in source.effects:
		if not source_effect is SkillEffectDef:
			data["effects"].append(null)
			continue
		data["effects"].append({
			"kind": source_effect.kind, "selector": source_effect.selector,
			"power_coeff": source_effect.power_coeff, "flat_amount": source_effect.flat_amount,
			"radius_m": source_effect.radius_m, "duration_s": source_effect.duration_s,
			"uses_stable_crit": source_effect.uses_stable_crit,
			"uses_mastery": source_effect.uses_mastery,
		})
	return data
