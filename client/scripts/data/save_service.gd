extends RefCounted
## 单档的招募、整备、结算、领奖规则（逻辑层，不碰场景和界面）。
## 每个写操作是一次提交：先在副本上改，写盘成功才换成新状态；写失败则内存和文件都保持写入前。
## 规则出处：doc/方案与数据/Godot程序开发计划 v0.1.md 第 6 节与 P2；物品表见 design/balance/README.md。
##
## 存档字段（version: 1）：
##   slots[4]        成员职业 id，空槽 ""
##   captainSlot     队长槽位 0..3，没有队伍为 -1
##   inspectSlot     整备面板正在看的槽位，没有为 -1（不影响队长）
##   selectedSlot    战斗里最后选中的槽位，没有为 -1（不写回队长）
##   ownedItems      已拥有物品 id（含穿着的、换下的、领到的）
##   equips          {class_id: {slot: item_id}}，每件必须在 ownedItems 里
##   talentId        {class_id: "t1"|"t2"}
##   pendingReward   null 或 {"run_id": 场次}，非空时不能再出征
##   claimedRuns     已领过奖的场次
## 不进存档：酒馆坐标、战斗中的生命、资源、冷却、仇恨、临时增益。

const ItemsTable := preload("res://scripts/data/items_table.gd")
const SaveStore := preload("res://scripts/data/save_store.gd")

const VERSION := 1
const SLOT_COUNT := 4
const DEFAULT_TALENT := "t1"

var table: ItemsTable
var store: SaveStore
var state: Dictionary = {}
## 加载时发现并修复的问题，给日志和测试看。
var notes: Array[String] = []


func _init(items: ItemsTable, save_store: SaveStore) -> void:
	table = items
	store = save_store
	state = empty_state()


static func empty_state() -> Dictionary:
	return {
		"version": VERSION,
		"slots": ["", "", "", ""],
		"captainSlot": -1,
		"inspectSlot": -1,
		"selectedSlot": -1,
		"ownedItems": [],
		"equips": {},
		"talentId": {},
		"pendingReward": null,
		"claimedRuns": [],
	}


# ── 读档 ──

## 读存档并修复不合法的字段。文件不存在 = 新档；读不动的坏档挪成 .corrupt 后当新档。永不崩溃。
func load_state() -> void:
	notes.clear()
	var raw := store.read_raw()
	if raw.has("missing"):
		state = empty_state()
		return
	if raw.has("corrupt"):
		var moved := store.quarantine()
		notes.append("存档损坏（%s），已改名为 %s，按新档开始" % [raw["corrupt"], moved])
		state = empty_state()
		return
	var data: Dictionary = raw["data"]
	if int(data.get("version", VERSION)) != VERSION:
		var moved := store.quarantine()
		notes.append("存档版本 %s 不认识，已改名为 %s，按新档开始" % [data.get("version"), moved])
		state = empty_state()
		return
	state = _normalize(data)


func _normalize(data: Dictionary) -> Dictionary:
	var out := empty_state()
	# 槽位：只认表里的职业，重复的后者丢弃
	var raw_slots: Variant = data.get("slots", [])
	var seen := {}
	for index in SLOT_COUNT:
		var class_id := ""
		if typeof(raw_slots) == TYPE_ARRAY and index < (raw_slots as Array).size():
			var candidate: Variant = (raw_slots as Array)[index]
			if typeof(candidate) == TYPE_STRING and table.has_class(String(candidate)) and not seen.has(candidate):
				class_id = String(candidate)
			elif str(candidate) != "":
				notes.append("槽 %d 的成员 %s 不合法，已清空" % [index + 1, candidate])
		(out["slots"] as Array)[index] = class_id
		if class_id != "":
			seen[class_id] = true
	var members: Array[String] = []
	for class_id: String in out["slots"]:
		if class_id != "":
			members.append(class_id)

	# 拥有清单：只留表里有的，去重；成员的初始装备必须都在
	var owned: Array = []
	var raw_owned: Variant = data.get("ownedItems", [])
	if typeof(raw_owned) == TYPE_ARRAY:
		for entry: Variant in raw_owned:
			if typeof(entry) == TYPE_STRING and table.has_item(String(entry)):
				if not owned.has(String(entry)):
					owned.append(String(entry))
			else:
				notes.append("拥有清单里的 %s 不是表里的物品，已丢弃" % str(entry))
	for class_id in members:
		for item_id: String in table.initial_set(class_id).values():
			if not owned.has(item_id):
				owned.append(item_id)
				notes.append("成员 %s 缺初始装备 %s，已补发" % [class_id, item_id])
	out["ownedItems"] = owned

	# 穿戴：每件都必须已拥有、职业和槽位对得上，否则回该职业的初始件
	var raw_equips: Variant = data.get("equips", {})
	for class_id in members:
		var worn := {}
		var initial := table.initial_set(class_id)
		var given: Dictionary = {}
		if typeof(raw_equips) == TYPE_DICTIONARY and typeof((raw_equips as Dictionary).get(class_id)) == TYPE_DICTIONARY:
			given = (raw_equips as Dictionary)[class_id]
		for slot_id in table.slots:
			var chosen: String = String(initial.get(slot_id, ""))
			var wanted: Variant = given.get(slot_id)
			if typeof(wanted) == TYPE_STRING and _can_wear(class_id, slot_id, String(wanted), owned):
				chosen = String(wanted)
			elif wanted != null:
				notes.append("%s 的 %s 穿戴 %s 不合法，已回到初始件" % [class_id, slot_id, str(wanted)])
			worn[slot_id] = chosen
		(out["equips"] as Dictionary)[class_id] = worn

	# 天赋：非法标识回默认
	var raw_talents: Variant = data.get("talentId", {})
	for class_id in members:
		var wanted_talent := ""
		if typeof(raw_talents) == TYPE_DICTIONARY and typeof((raw_talents as Dictionary).get(class_id)) == TYPE_STRING:
			wanted_talent = String((raw_talents as Dictionary)[class_id])
		var resolved := wanted_talent if table.talent_ids(class_id).has(wanted_talent) else DEFAULT_TALENT
		if resolved != wanted_talent:
			notes.append("%s 的天赋标识 %s 不合法，已回默认 %s" % [class_id, wanted_talent, DEFAULT_TALENT])
		(out["talentId"] as Dictionary)[class_id] = resolved

	# 三个槽位指针：必须指向有人的槽
	out["captainSlot"] = _pointer(data.get("captainSlot"), out["slots"], true)
	out["inspectSlot"] = _pointer(data.get("inspectSlot"), out["slots"], false)
	out["selectedSlot"] = _pointer(data.get("selectedSlot"), out["slots"], false)

	var claimed: Array = []
	var raw_claimed: Variant = data.get("claimedRuns", [])
	if typeof(raw_claimed) == TYPE_ARRAY:
		for entry: Variant in raw_claimed:
			if typeof(entry) == TYPE_STRING and String(entry) != "" and not claimed.has(String(entry)):
				claimed.append(String(entry))
	out["claimedRuns"] = claimed

	var pending: Variant = data.get("pendingReward")
	if typeof(pending) == TYPE_DICTIONARY and typeof((pending as Dictionary).get("run_id")) == TYPE_STRING and String((pending as Dictionary)["run_id"]) != "":
		var run_id := String((pending as Dictionary)["run_id"])
		if claimed.has(run_id):
			notes.append("待领奖场次 %s 已经领过，已清掉" % run_id)
		else:
			out["pendingReward"] = {"run_id": run_id}
	elif pending != null:
		notes.append("待领奖字段不合法，已清掉")
	return out


func _pointer(value: Variant, slots: Array, fallback_to_first: bool) -> int:
	if typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT:
		var index := int(value)
		if index >= 0 and index < SLOT_COUNT and String(slots[index]) != "":
			return index
	if fallback_to_first:
		for index in SLOT_COUNT:
			if String(slots[index]) != "":
				return index
	return -1


func _can_wear(class_id: String, slot_id: String, item_id: String, owned: Array) -> bool:
	var row := table.item(item_id)
	return not row.is_empty() and owned.has(item_id) and String(row["class_id"]) == class_id and String(row["slot"]) == slot_id


# ── 提交 ──

func _ok(extra: Dictionary = {}) -> Dictionary:
	var result := {"ok": true, "reason": ""}
	result.merge(extra)
	return result


func _fail(reason: String, extra: Dictionary = {}) -> Dictionary:
	var result := {"ok": false, "reason": reason}
	result.merge(extra)
	return result


## 把改好的副本写盘；成功才换掉内存状态。失败时内存和文件都是写入前的样子。
func _commit(draft: Dictionary, extra: Dictionary = {}) -> Dictionary:
	var error := store.write(draft)
	if error != OK:
		return _fail("write_failed", {"error": error_string(error)})
	state = draft
	return _ok(extra)


# ── 查询 ──

func members() -> Array[String]:
	var out: Array[String] = []
	for class_id: String in state["slots"]:
		if class_id != "":
			out.append(class_id)
	return out


func slot_of(class_id: String) -> int:
	return (state["slots"] as Array).find(class_id)


func is_recruited(class_id: String) -> bool:
	return slot_of(class_id) >= 0


func owns(item_id: String) -> bool:
	return (state["ownedItems"] as Array).has(item_id)


func can_sortie() -> Dictionary:
	if state["pendingReward"] != null:
		return _fail("pending_reward")
	if members().is_empty():
		return _fail("no_party")
	return _ok()


## 已穿齐两件套的职业：同一 set_id 的奖励件都穿在身上。
func active_sets() -> Array[String]:
	var out: Array[String] = []
	for class_id in members():
		var worn: Dictionary = (state["equips"] as Dictionary).get(class_id, {})
		var set_ids := {}
		var set_pieces := 0
		for item_id: String in worn.values():
			var row := table.item(item_id)
			var set_id := str(row.get("set_id", "")) if row.get("set_id") != null else ""
			if not row.is_empty() and set_id != "":
				set_ids[set_id] = int(set_ids.get(set_id, 0)) + 1
		for count: int in set_ids.values():
			set_pieces = maxi(set_pieces, count)
		if set_pieces >= 2:
			out.append(class_id)
	return out


## 给 BalanceLoader / 战斗用的参数。
func battle_options() -> Dictionary:
	return {"talents": (state["talentId"] as Dictionary).duplicate(), "sets": active_sets()}


## 战斗槽位：长度 4 的职业 id 列表。party 为空表示全部已招募成员出战；
## 否则只派 party 里的职业（必须都已招募），其余槽位留空，槽位顺序不变。
func battle_slots(party: Array = []) -> Array:
	var out: Array = (state["slots"] as Array).duplicate()
	if party.is_empty():
		return out
	for index in SLOT_COUNT:
		if not party.has(out[index]):
			out[index] = ""
	return out


## party 是否合法：非空时必须都是已招募的职业。
func party_valid(party: Array) -> bool:
	for class_id: Variant in party:
		if typeof(class_id) != TYPE_STRING or not is_recruited(String(class_id)):
			return false
	return true


## 奖励候选：每个已招募职业还没拥有的奖励件。
func reward_options() -> Dictionary:
	var out := {}
	for class_id in members():
		var missing: Array = []
		for item_id in table.reward_items(class_id):
			if not owns(item_id):
				missing.append(item_id)
		out[class_id] = missing
	return out


func collection_complete() -> bool:
	for item_id in table.all_reward_items():
		if not owns(item_id):
			return false
	return true


# ── 招募与整备 ──

## 招募：成员、八件初始装备（同时进 ownedItems 和 equips）、默认天赋，一次提交。
func recruit(class_id: String) -> Dictionary:
	if not table.has_class(class_id):
		return _fail("unknown_class")
	if is_recruited(class_id):
		return _fail("already_recruited")
	var free := (state["slots"] as Array).find("")
	if free < 0:
		return _fail("no_free_slot")
	var draft := state.duplicate(true)
	(draft["slots"] as Array)[free] = class_id
	var initial := table.initial_set(class_id)
	for item_id: String in initial.values():
		if not (draft["ownedItems"] as Array).has(item_id):
			(draft["ownedItems"] as Array).append(item_id)
	(draft["equips"] as Dictionary)[class_id] = initial.duplicate()
	(draft["talentId"] as Dictionary)[class_id] = DEFAULT_TALENT
	if int(draft["captainSlot"]) < 0:
		draft["captainSlot"] = free
	return _commit(draft, {"slot": free, "items": initial.size()})


## 两个槽位互换（顺序即战斗快捷键）。指针跟着人走。
func swap_slots(a: int, b: int) -> Dictionary:
	if a < 0 or a >= SLOT_COUNT or b < 0 or b >= SLOT_COUNT:
		return _fail("bad_slot")
	if a == b:
		return _ok({"changed": false})
	var draft := state.duplicate(true)
	var slots: Array = draft["slots"]
	var tmp: Variant = slots[a]
	slots[a] = slots[b]
	slots[b] = tmp
	for key in ["captainSlot", "inspectSlot", "selectedSlot"]:
		var pointer := int(draft[key])
		if pointer == a:
			draft[key] = b
		elif pointer == b:
			draft[key] = a
	return _commit(draft, {"changed": true})


func set_captain(class_id: String) -> Dictionary:
	if not is_recruited(class_id):
		return _fail("not_recruited")
	var draft := state.duplicate(true)
	draft["captainSlot"] = slot_of(class_id)
	return _commit(draft)


## 整备面板看谁：只改 inspectSlot，不动队长。
func set_inspect(class_id: String) -> Dictionary:
	if not is_recruited(class_id):
		return _fail("not_recruited")
	var draft := state.duplicate(true)
	draft["inspectSlot"] = slot_of(class_id)
	return _commit(draft)


## 换装：物品必须已拥有，职业对得上；替换到物品自己所在的槽。换下的仍算拥有。
func equip(class_id: String, item_id: String) -> Dictionary:
	if not is_recruited(class_id):
		return _fail("not_recruited")
	if not table.has_item(item_id):
		return _fail("unknown_item")
	var row := table.item(item_id)
	if String(row["class_id"]) != class_id:
		return _fail("wrong_class")
	if not owns(item_id):
		return _fail("not_owned")
	var draft := state.duplicate(true)
	((draft["equips"] as Dictionary)[class_id] as Dictionary)[String(row["slot"])] = item_id
	return _commit(draft, {"slot": row["slot"]})


## 选天赋。标识不在该职业选项里就回默认，不报错、不崩（result.fallback = true）。
func set_talent(class_id: String, talent: String) -> Dictionary:
	if not is_recruited(class_id):
		return _fail("not_recruited")
	var resolved := talent if table.talent_ids(class_id).has(talent) else DEFAULT_TALENT
	var draft := state.duplicate(true)
	(draft["talentId"] as Dictionary)[class_id] = resolved
	return _commit(draft, {"talent": resolved, "fallback": resolved != talent})


# ── 结算与领奖 ──

## 一场战斗结算。胜利且还有没拿全的替换件 → 记待领奖；失败不发；8 件齐了不再发。
## selected_slot 非负时顺带记下战斗里最后选中的槽（不写回队长）。
## party：本场派出的职业，空表示全部；没派出的已招募职业照样可以领奖。
func settle(run_id: String, result: String, selected_slot: int = -1, party: Array = []) -> Dictionary:
	if run_id == "":
		return _fail("bad_run_id")
	if result != "win" and result != "lose":
		return _fail("bad_result")
	var gate := can_sortie()
	if not gate["ok"]:
		return gate
	if not party_valid(party):
		return _fail("bad_party")
	if (state["claimedRuns"] as Array).has(run_id):
		return _fail("already_claimed")
	var draft := state.duplicate(true)
	if selected_slot >= 0 and selected_slot < SLOT_COUNT and String((draft["slots"] as Array)[selected_slot]) != "":
		draft["selectedSlot"] = selected_slot
	var outcome := "no_reward"
	if result == "win":
		if collection_complete():
			outcome = "collection_complete"
		else:
			draft["pendingReward"] = {"run_id": run_id}
			outcome = "pending_reward"
	return _commit(draft, {"outcome": outcome, "run_id": run_id})


## 领奖：先选已招募的职业，再从该职业还没拥有的肩膀/鞋子里选一件。
## 只剩一件就直接领（item_id 可省）；两件都没有必须指定；该职业两件都有则引导换职业。
func claim(class_id: String, item_id: String = "") -> Dictionary:
	var pending: Variant = state["pendingReward"]
	if pending == null:
		return _fail("no_pending")
	if not is_recruited(class_id):
		return _fail("not_recruited")
	var run_id := String((pending as Dictionary)["run_id"])
	if (state["claimedRuns"] as Array).has(run_id):
		return _fail("already_claimed")
	var missing: Array = []
	for candidate in table.reward_items(class_id):
		if not owns(candidate):
			missing.append(candidate)
	if missing.is_empty():
		var others: Array = []
		for other: String in reward_options():
			if not (reward_options()[other] as Array).is_empty():
				others.append(other)
		return _fail("class_complete", {"other_classes": others})
	var picked := item_id
	if picked == "":
		if missing.size() == 1:
			picked = String(missing[0])
		else:
			return _fail("needs_choice", {"options": missing})
	if not missing.has(picked):
		return _fail("not_available", {"options": missing})
	var draft := state.duplicate(true)
	(draft["ownedItems"] as Array).append(picked)
	(draft["claimedRuns"] as Array).append(run_id)
	draft["pendingReward"] = null
	return _commit(draft, {"item": picked, "run_id": run_id})


# ── 酒馆面板用 ──

## 把当前状态原样写一次盘（确认出征前「保存最新配置」）。失败时内存不变。
func save_now() -> Dictionary:
	return _commit(state.duplicate(true))


## 前移 / 后移：与相邻槽位交换（包含空槽）。direction 取 -1 或 1；边缘返回 edge。
func move_member(class_id: String, direction: int) -> Dictionary:
	if not is_recruited(class_id):
		return _fail("not_recruited")
	var from := slot_of(class_id)
	var to := from + direction
	if to < 0 or to >= SLOT_COUNT:
		return _fail("edge")
	return swap_slots(from, to)


## 出征前的配置校验。先尝试恢复有效队长（写盘），再返回问题列表：
## [{"code": "no_party"|"duplicate_member"|"bad_captain"|"equip_invalid"|"talent_invalid"|"pending_reward", "class_id": 成员或空}]
func validate_party() -> Array:
	var problems: Array = []
	var current := members()
	if current.is_empty():
		problems.append({"code": "no_party", "class_id": ""})
		return problems
	var seen := {}
	for class_id in current:
		if seen.has(class_id):
			problems.append({"code": "duplicate_member", "class_id": class_id})
		seen[class_id] = true
	var captain := int(state["captainSlot"])
	if captain < 0 or captain >= SLOT_COUNT or String((state["slots"] as Array)[captain]) == "":
		var draft := state.duplicate(true)
		draft["captainSlot"] = (state["slots"] as Array).find(current[0])
		if not bool(_commit(draft)["ok"]):
			problems.append({"code": "bad_captain", "class_id": ""})
	for class_id in current:
		var worn: Dictionary = (state["equips"] as Dictionary).get(class_id, {})
		var ok := true
		for slot_id in table.slots:
			var item_id := str(worn.get(slot_id, ""))
			if not _can_wear(class_id, slot_id, item_id, state["ownedItems"]):
				ok = false
		if not ok:
			problems.append({"code": "equip_invalid", "class_id": class_id})
		if not table.talent_ids(class_id).has(str((state["talentId"] as Dictionary).get(class_id, ""))):
			problems.append({"code": "talent_invalid", "class_id": class_id})
	if state["pendingReward"] != null:
		problems.append({"code": "pending_reward", "class_id": ""})
	return problems
