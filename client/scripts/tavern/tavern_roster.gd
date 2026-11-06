extends RefCounted
## 酒馆里招募 / 整备 / 出征三个面板共用的数据与操作层。
## 面板只通过这里读写：读来自存档服务和数值表，写全部走 SaveService（单档、事务、失败回滚）。
## 这里不画界面、不碰场景；界面把返回的字典摆出来，把按钮接到这里的动作上。
## 不新增存档字段；槽位 id、物品 id 沿用 P2。

const SaveService := preload("res://scripts/data/save_service.gd")
const BalanceLoader := preload("res://scripts/data/balance_loader.gd")

const PARAM_LABEL := {"cost": "消耗", "cooldown": "冷却", "damage": "伤害", "heal": "治疗量", "radius": "范围", "duration": "持续时间"}
## 这些参数越小越好（负值是收益，正值是代价）。
const LOWER_IS_BETTER: Array[String] = ["cost", "cooldown"]
const KEYS: Array[String] = ["q", "w", "e", "r"]

var service: SaveService
var stage: Dictionary = {}
var _base: Dictionary = {}
var _cache: Dictionary = {}


func _init(save_service: SaveService, stage_info: Dictionary = {}) -> void:
	service = save_service
	stage = stage_info
	_base = BalanceLoader.load_balance({})


# ── 名字与概要 ──

func class_name_of(class_id: String) -> String:
	return String(_base["classes"].get(class_id, {}).get("name", class_id))


func class_color(class_id: String) -> Color:
	return Color.html(String(_base["classes"].get(class_id, {}).get("color", "888888")))


func item_name(item_id: String) -> String:
	var row := service.table.item(item_id)
	return String(row.get("name", item_id)) if not row.is_empty() else "（空）"


func slot_name(slot_id: String) -> String:
	return String(service.table.slot_names.get(slot_id, slot_id))


## 招募卡：职业、资源、面板、四个技能概要。
func class_card(class_id: String) -> Dictionary:
	var cls: Dictionary = _base["classes"][class_id]
	var res: Dictionary = cls["resource"]
	return {
		"class_id": class_id,
		"name": String(cls["name"]),
		"recruited": service.is_recruited(class_id),
		"max_hp": int(cls["max_hp"]),
		"armor": int(cls["armor"]),
		"magic_resist": int(cls["magic_resist"]),
		"speed": int(cls["speed"]),
		"resource": "%s %d" % [_resource_name(String(res["kind"])), int(res["max"])],
		"attack": _attack_text(cls["attack"]),
		"skills": _skill_lines(_config_for(class_id, "t1", false), class_id),
	}


func _resource_name(kind: String) -> String:
	return {"rage": "怒气", "energy": "能量", "mana": "法力"}.get(kind, kind)


func _attack_text(attack: Dictionary) -> String:
	return "普攻 %s %d，间隔 %s 秒，射程 %d" % ["伤害" if String(attack["kind"]) == "damage" else "治疗", int(attack.get("damage", attack.get("heal", 0))), str(attack["interval"]), int(attack["range"])]


func _config_for(class_id: String, talent: String, with_set: bool) -> Dictionary:
	var key := "%s|%s|%s" % [class_id, talent, with_set]
	if not _cache.has(key):
		_cache[key] = BalanceLoader.load_balance({"talents": {class_id: talent}, "sets": [class_id] if with_set else []})
	return _cache[key]


func _skill_lines(config: Dictionary, class_id: String) -> Array:
	var out: Array = []
	var cls: Dictionary = config["classes"][class_id]
	for key: String in KEYS:
		var skill: Dictionary = config["skills"][String(cls["skills"][key])]
		var parts: Array = ["耗%d" % int(skill.get("cost", 0)), "冷却%s秒" % str(skill.get("cooldown", 0))]
		for effect: Dictionary in skill.get("effects", []):
			if effect.has("amount"):
				parts.append("%s%s" % ["治疗" if String(effect["kind"]) == "heal" else "伤害", str(effect["amount"])])
			if effect.has("radius"):
				parts.append("范围%s" % str(effect["radius"]))
			if effect.has("duration"):
				parts.append("持续%s秒" % str(effect["duration"]))
		out.append({"key": key.to_upper(), "name": String(skill["name"]), "text": "，".join(parts)})
	return out


# ── 队伍与槽位 ──

func party_count() -> int:
	return service.members().size()


func slots_view() -> Array:
	var out: Array = []
	var captain := int(service.state["captainSlot"])
	for index in SaveService.SLOT_COUNT:
		var class_id := String((service.state["slots"] as Array)[index])
		out.append({
			"slot": index,
			"number": index + 1,
			"class_id": class_id,
			"name": class_name_of(class_id) if class_id != "" else "",
			"color": class_color(class_id) if class_id != "" else Color(0.3, 0.3, 0.3),
			"captain": index == captain and class_id != "",
		})
	return out


func captain_class() -> String:
	var captain := int(service.state["captainSlot"])
	return String((service.state["slots"] as Array)[captain]) if captain >= 0 else ""


## 整备面板正在看的职业：inspectSlot 有效用它，否则队长。
func inspected_class() -> String:
	var inspect := int(service.state["inspectSlot"])
	if inspect >= 0 and String((service.state["slots"] as Array)[inspect]) != "":
		return String((service.state["slots"] as Array)[inspect])
	return captain_class()


func set_status(class_id: String) -> Dictionary:
	var worn: Dictionary = (service.state["equips"] as Dictionary).get(class_id, {})
	var counts := {}
	for item_id: String in worn.values():
		var row := service.table.item(item_id)
		if not row.is_empty() and row.get("set_id") != null and str(row["set_id"]) != "":
			counts[str(row["set_id"])] = int(counts.get(str(row["set_id"]), 0)) + 1
	for set_id: String in service.table.sets:
		var info: Dictionary = service.table.sets[set_id]
		if String(info["class_id"]) == class_id:
			var have := int(counts.get(set_id, 0))
			var need := (info["pieces"] as Array).size()
			return {"set_id": set_id, "name": String(info["name"]), "have": have, "need": need, "active": have >= need, "text": "%s %d/%d%s" % [String(info["name"]), have, need, "（已生效）" if have >= need else ""]}
	return {"set_id": "", "name": "", "have": 0, "need": 0, "active": false, "text": "无套装"}


func talent_of(class_id: String) -> String:
	return str((service.state["talentId"] as Dictionary).get(class_id, SaveService.DEFAULT_TALENT))


## 成员详情：面板数值 + 技能最终参数（已含当前天赋和两件套）。
func member_view(class_id: String) -> Dictionary:
	var card := class_card(class_id)
	var status := set_status(class_id)
	card["talent"] = talent_of(class_id)
	card["set"] = status
	card["skills"] = _skill_lines(_config_for(class_id, talent_of(class_id), bool(status["active"])), class_id)
	card["captain"] = captain_class() == class_id
	card["slot"] = service.slot_of(class_id)
	return card


# ── 装备 ──

func equip_view(class_id: String) -> Array:
	var worn: Dictionary = (service.state["equips"] as Dictionary).get(class_id, {})
	var out: Array = []
	for slot_id: String in service.table.slots:
		var current := str(worn.get(slot_id, ""))
		var candidates: Array = []
		for item_id: String in service.state["ownedItems"]:
			var row := service.table.item(item_id)
			if not row.is_empty() and String(row["class_id"]) == class_id and String(row["slot"]) == slot_id and item_id != current:
				candidates.append({"id": item_id, "name": String(row["name"]), "set_id": str(row.get("set_id", "")) if row.get("set_id") != null else ""})
		out.append({"slot": slot_id, "slot_name": slot_name(slot_id), "current": current, "current_name": item_name(current), "candidates": candidates})
	return out


## 对比预览：不改任何数据，只算换上后的套装件数变化。
func preview(class_id: String, item_id: String) -> Dictionary:
	var row := service.table.item(item_id)
	if row.is_empty():
		return {}
	var slot_id := String(row["slot"])
	var worn: Dictionary = ((service.state["equips"] as Dictionary).get(class_id, {}) as Dictionary).duplicate()
	var before := set_status(class_id)
	var old_id := str(worn.get(slot_id, ""))
	var after_count := int(before["have"])
	if old_id != "" and not service.table.item(old_id).is_empty() and service.table.item(old_id).get("set_id") != null and str(service.table.item(old_id)["set_id"]) == str(before["set_id"]):
		after_count -= 1
	if row.get("set_id") != null and str(row["set_id"]) == str(before["set_id"]) and str(before["set_id"]) != "":
		after_count += 1
	var need := int(before["need"])
	var line := "%s → %s" % [item_name(old_id), String(row["name"])]
	if need > 0:
		line += "；套装 %d/%d → %d/%d%s" % [int(before["have"]), need, after_count, need, "（生效）" if after_count >= need else ""]
	return {"slot_name": slot_name(slot_id), "text": line, "set_after": after_count, "set_need": need}


# ── 天赋 ──

func talent_options(class_id: String) -> Array:
	var out: Array = []
	var current := talent_of(class_id)
	for talent: String in service.table.talent_ids(class_id):
		var lines: Array = []
		for row: Dictionary in service.table.modifier_rows(class_id, "talent"):
			if BalanceLoader.talent_key(String(row["id"])) != talent:
				continue
			var param := String(row["param"])
			var value := float(row["value"])
			var skill_name := String(_base["skills"].get(String(row["skill_id"]), {}).get("name", row["skill_id"]))
			var shown := "%+d%%" % int(round(value * 100)) if String(row["op"]) == "add_pct" else "%+s 秒" % str(value)
			var good := value < 0.0 if LOWER_IS_BETTER.has(param) else value > 0.0
			lines.append({"text": "%s %s %s" % [skill_name, String(PARAM_LABEL.get(param, param)), shown], "good": good})
		var final_skills := _skill_lines(_config_for(class_id, talent, bool(set_status(class_id)["active"])), class_id)
		out.append({"id": talent, "active": talent == current, "lines": lines, "skills": final_skills})
	return out


# ── 出征 ──

func stage_view() -> Dictionary:
	var enemies := {}
	for entry: Dictionary in _base["wave"]:
		enemies[String(entry["enemy"])] = int(enemies.get(String(entry["enemy"]), 0)) + 1
	var enemy_parts: Array = []
	var mechanics: Array = []
	for enemy_id: String in enemies:
		var enemy: Dictionary = _base["enemies"][enemy_id]
		enemy_parts.append("%s×%d" % [String(enemy["name"]), int(enemies[enemy_id])])
		if enemy.has("spell"):
			var spell: Dictionary = enemy["spell"]
			mechanics.append("%s 的%s：读条 %s 秒，%s" % [String(enemy["name"]), String(spell["name"]), str(spell["cast_time"]), "可打断" if bool(spell["interruptible"]) else "不可打断，注意躲开范围"])
	var tips: Array = []
	for tip: Variant in stage.get("tips", []):
		tips.append(str(tip))
	var notes: Array = []
	for entry: Variant in stage.get("enemies", []):
		if typeof(entry) == TYPE_DICTIONARY:
			notes.append(str((entry as Dictionary).get("text", "")))
	return {
		"name": String(stage.get("name", "第一关")),
		"goal": "%s（限时 %d 秒）" % [String(stage.get("goal", "击败全部敌人")), int(_base["time_limit"])],
		"enemies": "、".join(enemy_parts),
		"enemy_notes": notes,
		"mechanics": tips if not tips.is_empty() else mechanics,
		"reward": String(stage.get("reward", "")),
	}


## 出征前置检查。blockers：[{code, text, class_id, action}]，action 给界面做入口（recruit / claim / prepare）。
func sortie_view() -> Dictionary:
	var problems := service.validate_party()
	var blockers: Array = []
	for problem: Dictionary in problems:
		var code := String(problem["code"])
		var class_id := String(problem["class_id"])
		match code:
			"no_party":
				blockers.append({"code": code, "text": "至少需要一名队员", "class_id": "", "action": "recruit", "action_text": "去招募"})
			"pending_reward":
				blockers.append({"code": code, "text": "有未领取的战利品，领取后才能出征", "class_id": "", "action": "claim", "action_text": "领取战利品"})
			"equip_invalid":
				blockers.append({"code": code, "text": "%s 的装备不合法" % class_name_of(class_id), "class_id": class_id, "action": "prepare", "action_text": "去整备"})
			"talent_invalid":
				blockers.append({"code": code, "text": "%s 的天赋不合法" % class_name_of(class_id), "class_id": class_id, "action": "prepare", "action_text": "去整备"})
			_:
				blockers.append({"code": code, "text": "队伍配置异常（%s）" % code, "class_id": class_id, "action": "prepare", "action_text": "去整备"})
	var party: Array = []
	for slot: Dictionary in slots_view():
		var entry: Dictionary = slot.duplicate()
		var class_id := String(slot["class_id"])
		if class_id != "":
			entry["talent"] = talent_of(class_id)
			entry["set_text"] = String(set_status(class_id)["text"])
			entry["flagged"] = blockers.any(func(b: Dictionary) -> bool: return String(b["class_id"]) == class_id)
		party.append(entry)
	var count := party_count()
	return {
		"ok": blockers.is_empty(),
		"blockers": blockers,
		"party": party,
		"count": count,
		"summary": "当前 %d/4 人，可出征" % count if blockers.is_empty() else "当前 %d/4 人" % count,
		"hint": "战斗快捷键按当前队伍顺序对应：1–4 选中对应槽位，空槽无效",
		"stage": stage_view(),
	}


## 战利品面板：每个已招募职业还能领的件。
func reward_view() -> Array:
	var out: Array = []
	var options := service.reward_options()
	for class_id: String in options:
		var items: Array = []
		for item_id: String in options[class_id]:
			items.append({"id": item_id, "name": item_name(item_id), "slot_name": slot_name(String(service.table.item(item_id)["slot"]))})
		out.append({"class_id": class_id, "name": class_name_of(class_id), "items": items})
	return out


## 确认出征：重新检查 → 写盘保存最新配置 → 返回将锁定的名单。本版不加载战斗（P4）。
func confirm_sortie() -> Dictionary:
	var view := sortie_view()
	if not bool(view["ok"]):
		return {"ok": false, "reason": "blocked", "blockers": view["blockers"]}
	var saved := service.save_now()
	if not bool(saved["ok"]):
		return saved
	var roster: Array = []
	for entry: Dictionary in view["party"]:
		if String(entry["class_id"]) != "":
			roster.append({"slot": int(entry["number"]), "class_id": String(entry["class_id"]), "name": String(entry["name"]), "captain": bool(entry["captain"]), "talent": String(entry["talent"]), "set_text": String(entry["set_text"])})
	return {"ok": true, "reason": "", "roster": roster}
