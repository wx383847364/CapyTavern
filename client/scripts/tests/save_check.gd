extends SceneTree
## P2b 单档自检（无窗口）。运行：
##   godot --headless --path client --script res://scripts/tests/save_check.gd
## 存档写到 /tmp 下的临时目录，不碰 user://save.json。有失败时退出码 1。
## 逐条对应计划书 P2b 验收：招募一次写入且不重复、两人招募一人派出仍能给另一职业领奖、换下旧装备仍算拥有、
## 8 件齐后不再发、重启保留状态、非法天赋回默认、失败不发、同一场不能领两次、写失败两边回到写入前。

const ItemsTable := preload("res://scripts/data/items_table.gd")
const SaveStore := preload("res://scripts/data/save_store.gd")
const SaveService := preload("res://scripts/data/save_service.gd")
const SaveCli := preload("res://scripts/data/save_cli.gd")
const BattleConfig := preload("res://scripts/battle/battle_config.gd")

var _failures: int = 0
var _table: ItemsTable
var _dir: String = ""
var _counter: int = 0


func _initialize() -> void:
	_table = ItemsTable.new()
	if not _table.load_tables():
		print("FAIL  物品表读不到")
		quit(1)
		return
	_dir = "/tmp/capy_save_check_%d" % int(Time.get_unix_time_from_system())
	DirAccess.make_dir_recursive_absolute(_dir)
	_tables()
	_recruit()
	_reward_rules()
	_equip_and_ownership()
	_restart()
	_talents()
	_rollback()
	_corrupt_files()
	_sets_and_fight()
	_cli()
	print("RESULT: %s (%d 条失败)" % ["FAIL" if _failures > 0 else "ALL PASS", _failures])
	quit(1 if _failures > 0 else 0)


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		print("PASS  ", name)
	else:
		_failures += 1
		print("FAIL  ", name, "  ", detail)


## 新服务，存档放独立文件。
func _fresh(name: String = "") -> SaveService:
	_counter += 1
	var path := "%s/%s_%d.json" % [_dir, name if name != "" else "save", _counter]
	var service := SaveService.new(_table, SaveStore.new(path))
	service.load_state()
	return service


func _reopen(service: SaveService) -> SaveService:
	var again := SaveService.new(_table, SaveStore.new(service.store.path))
	again.load_state()
	return again


func _recruit_all(service: SaveService) -> void:
	for class_id in _table.class_ids:
		service.recruit(class_id)


func _tables() -> void:
	_check("物品共 40 件：初始 32 + 奖励 8", _table.items.size() == 40 and _table.all_reward_items().size() == 8, str(_table.items.size()))
	var initial_ok := true
	for class_id in _table.class_ids:
		initial_ok = initial_ok and _table.initial_set(class_id).size() == 8
	_check("四职业各八件初始装备，覆盖八个槽", initial_ok and _table.slots.size() == 8, str(_table.slots))
	_check("八个槽 id 与存档约定一致", _table.slots == ["weapon", "helmet", "chest", "shoulder", "legs", "boots", "ring", "amulet"], str(_table.slots))


func _recruit() -> void:
	var service := _fresh("recruit")
	var result := service.recruit("warrior")
	_check("招募成功，进第一个空槽并成为队长", result["ok"] and service.state["slots"][0] == "warrior" and service.state["captainSlot"] == 0, str(result))
	var owned: Array = service.state["ownedItems"]
	var worn: Dictionary = service.state["equips"]["warrior"]
	_check("八件初始装备同时进 ownedItems 和 equips", owned.size() == 8 and worn.size() == 8 and worn.values().all(func(id): return owned.has(id)), "owned=%d worn=%d" % [owned.size(), worn.size()])
	_check("默认天赋 t1", service.state["talentId"]["warrior"] == "t1")
	var before := JSON.stringify(service.state, "", true)
	var again := service.recruit("warrior")
	_check("重复招募被拒，不复制（拥有清单、穿戴、槽位都不变）", not again["ok"] and again["reason"] == "already_recruited" and JSON.stringify(service.state, "", true) == before, str(again))
	_check("未知职业被拒", service.recruit("paladin")["reason"] == "unknown_class")
	service.recruit("priest")
	_check("第二人进第二个槽，队长不变", service.state["slots"][1] == "priest" and service.state["captainSlot"] == 0)
	_check("两人共 16 件，无重复", (service.state["ownedItems"] as Array).size() == 16 and _unique(service.state["ownedItems"]))
	var swapped := service.swap_slots(0, 1)
	_check("换槽顺序后队长跟着人走", swapped["ok"] and service.state["slots"][0] == "priest" and service.state["captainSlot"] == 1)
	var inspect_before: int = service.state["captainSlot"]
	service.set_inspect("warrior")
	_check("整备面板看谁只改 inspectSlot，不改队长", service.state["inspectSlot"] == 1 and service.slot_of("warrior") == 1)
	_check("看谁不影响队长", service.state["captainSlot"] == inspect_before)
	_check("非队伍成员不能当队长", service.set_captain("mage")["reason"] == "not_recruited")


func _unique(values: Array) -> bool:
	var seen := {}
	for value in values:
		if seen.has(value):
			return false
		seen[value] = true
	return true


func _reward_rules() -> void:
	# 只招募两人、只派出一人：仍能给另一职业领一件
	var service := _fresh("reward")
	service.recruit("warrior")
	service.recruit("priest")
	var settled := service.settle("run1", "win", -1, ["warrior"])
	_check("两人招募、只派出战士，胜利后记待领奖", settled["ok"] and settled["outcome"] == "pending_reward" and service.state["pendingReward"]["run_id"] == "run1", str(settled))
	var options := service.reward_options()
	_check("候选包含没上场的牧师", options.has("priest") and (options["priest"] as Array).size() == 2, str(options))
	_check("没招募的职业不能领", service.claim("mage")["reason"] == "not_recruited")
	_check("两件都没有时必须自己选", service.claim("priest")["reason"] == "needs_choice")
	_check("不是该职业的奖励件被拒", service.claim("priest", "warrior_boots_set")["reason"] == "not_available")
	_check("初始件不是奖励，不能领", service.claim("priest", "priest_boots")["reason"] == "not_available")
	var owned_before: int = (service.state["ownedItems"] as Array).size()
	var claimed := service.claim("priest", "priest_shoulder_set")
	_check("给没上场的牧师领一件肩膀", claimed["ok"] and service.owns("priest_shoulder_set") and (service.state["ownedItems"] as Array).size() == owned_before + 1, str(claimed))
	_check("奖励只进拥有清单，不自动穿上", service.state["equips"]["priest"]["shoulder"] == "priest_shoulder")
	_check("领完清空待领奖，场次记为已领", service.state["pendingReward"] == null and (service.state["claimedRuns"] as Array) == ["run1"])
	_check("同一场不能领第二次", service.claim("priest", "priest_boots_set")["reason"] == "no_pending")
	_check("已领过的场次不能再结算", service.settle("run1", "win")["reason"] == "already_claimed")
	# 只剩一件直接领
	service.settle("run2", "win")
	var auto := service.claim("priest")
	_check("该职业只剩 1 件，直接领（不用指定）", auto["ok"] and auto["item"] == "priest_boots_set", str(auto))
	# 该职业两件都有：引导换职业
	service.settle("run3", "win")
	var done := service.claim("priest")
	_check("该职业两件都有：引导换职业", not done["ok"] and done["reason"] == "class_complete" and (done["other_classes"] as Array).has("warrior"), str(done))
	_check("引导换职业时待领奖仍在、没发东西", service.state["pendingReward"] != null and not service.owns("priest_boots_set_x"))
	# 待领奖时不能再出征
	_check("有待领奖时不能再结算新的一场", service.settle("run4", "win")["reason"] == "pending_reward")
	_check("有待领奖时不能出征", service.can_sortie()["reason"] == "pending_reward")
	# 失败不发
	var lose := _fresh("lose")
	lose.recruit("warrior")
	var lost := lose.settle("runL", "lose")
	_check("失败不发装备，也不记待领奖", lost["ok"] and lost["outcome"] == "no_reward" and lose.state["pendingReward"] == null and lose.claim("warrior")["reason"] == "no_pending", str(lost))
	_check("失败的场次不占用领奖记录", (lose.state["claimedRuns"] as Array).is_empty())
	_check("没人出战不能结算", _fresh("empty").settle("x", "win")["reason"] == "no_party")
	_check("派出未招募的职业被拒", service.party_valid(["mage"]) == false)

	# 8 件齐了之后再胜利，不新增
	var full := _fresh("full")
	_recruit_all(full)
	var guard := 0
	while not full.collection_complete() and guard < 20:
		guard += 1
		full.settle("fill%d" % guard, "win")
		for class_id in full.members():
			if not (full.reward_options()[class_id] as Array).is_empty():
				full.claim(class_id, String(full.reward_options()[class_id][0]))
				break
	_check("领满 8 件替换件", full.collection_complete() and guard == 8, "guard=%d" % guard)
	var count_before: int = (full.state["ownedItems"] as Array).size()
	var after := full.settle("extra", "win")
	_check("8 件齐后再胜利：显示收集完成，不发重复件", after["ok"] and after["outcome"] == "collection_complete" and full.state["pendingReward"] == null and (full.state["ownedItems"] as Array).size() == count_before and count_before == 40, str(after))


func _equip_and_ownership() -> void:
	var service := _fresh("equip")
	service.recruit("warrior")
	service.recruit("priest")
	service.settle("e1", "win")
	service.claim("warrior", "warrior_shoulder_set")
	var swapped := service.equip("warrior", "warrior_shoulder_set")
	_check("穿上奖励肩膀", swapped["ok"] and service.state["equips"]["warrior"]["shoulder"] == "warrior_shoulder_set", str(swapped))
	_check("换下的旧肩膀仍算拥有", service.owns("warrior_shoulder"))
	_check("旧装备不会再被当成奖励候选", not ((service.reward_options()["warrior"] as Array).has("warrior_shoulder")))
	_check("旧装备可以再穿回去", service.equip("warrior", "warrior_shoulder")["ok"] and service.state["equips"]["warrior"]["shoulder"] == "warrior_shoulder")
	_check("没拥有的东西不能穿", service.equip("warrior", "warrior_boots_set")["reason"] == "not_owned")
	_check("别的职业的装备不能穿", service.equip("warrior", "priest_weapon")["reason"] == "wrong_class")
	_check("不存在的物品被拒", service.equip("warrior", "no_such_item")["reason"] == "unknown_item")
	_check("没招募的职业不能整备", service.equip("mage", "mage_weapon")["reason"] == "not_recruited")
	# 每件穿戴都在拥有清单里
	var consistent := true
	for class_id in service.members():
		for item_id: String in (service.state["equips"][class_id] as Dictionary).values():
			consistent = consistent and service.owns(item_id)
	_check("equips 里每件都在 ownedItems 里", consistent)


func _restart() -> void:
	var service := _fresh("restart")
	service.recruit("warrior")
	service.recruit("mage")
	service.set_talent("mage", "t2")
	service.settle("r1", "win", 1, ["mage"])
	service.claim("warrior", "warrior_shoulder_set")
	service.settle("r2", "win")
	service.equip("warrior", "warrior_shoulder_set")
	service.swap_slots(0, 1)
	var snapshot := JSON.stringify(service.state, "", true)
	var reopened := _reopen(service)
	_check("重启后整份存档一致", JSON.stringify(reopened.state, "", true) == snapshot, snapshot)
	_check("重启后拥有清单、穿戴、天赋都在", reopened.owns("warrior_shoulder_set") and reopened.state["equips"]["warrior"]["shoulder"] == "warrior_shoulder_set" and reopened.state["talentId"]["mage"] == "t2")
	_check("重启后领奖状态还在：有待领奖、已领场次保留", reopened.state["pendingReward"]["run_id"] == "r2" and (reopened.state["claimedRuns"] as Array) == ["r1"])
	_check("重启后待领奖仍挡着出征", reopened.can_sortie()["reason"] == "pending_reward")
	_check("存档根字段 version=1", int(reopened.state["version"]) == 1)
	_check("存档里不含战斗临时数据", not (reopened.state as Dictionary).has("hp") and not (reopened.state as Dictionary).has("cooldowns"))
	_check("写盘后没有残留临时文件", not FileAccess.file_exists(service.store.path + ".tmp"))
	_check("存档字段正好是计划书里的九项加 version", (reopened.state as Dictionary).keys().size() == 10, str(reopened.state.keys()))


func _talents() -> void:
	var service := _fresh("talent")
	service.recruit("rogue")
	var result := service.set_talent("rogue", "t2")
	_check("合法天赋 t2 写入", result["ok"] and not result["fallback"] and service.state["talentId"]["rogue"] == "t2")
	var bad := service.set_talent("rogue", "t9")
	_check("非法天赋标识回默认 t1，不崩", bad["ok"] and bad["fallback"] and service.state["talentId"]["rogue"] == "t1", str(bad))
	_check("空标识回默认", service.set_talent("rogue", "")["talent"] == "t1")
	# 读档时的非法天赋
	var path := service.store.path
	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	raw["talentId"]["rogue"] = "<evil>"
	_write(path, raw)
	var loaded := _reopen(service)
	_check("读档遇到非法天赋标识：回默认，不崩，记一条说明", loaded.state["talentId"]["rogue"] == "t1" and loaded.notes.size() == 1, str(loaded.notes))
	raw["talentId"]["rogue"] = 7
	_write(path, raw)
	_check("天赋标识是数字也回默认", _reopen(service).state["talentId"]["rogue"] == "t1")
	raw["talentId"] = "oops"
	_write(path, raw)
	_check("talentId 整个不是字典也不崩", _reopen(service).state["talentId"]["rogue"] == "t1")


func _write(path: String, data: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(data))
	file.close()


func _rollback() -> void:
	var service := _fresh("rollback")
	service.recruit("warrior")
	var file_before := FileAccess.get_file_as_string(service.store.path)
	var state_before := JSON.stringify(service.state, "", true)
	service.store.fail_next_write = true
	var failed := service.recruit("priest")
	_check("招募写盘失败：返回失败", not failed["ok"] and failed["reason"] == "write_failed", str(failed))
	_check("招募写盘失败：成员、拥有清单、穿戴都回到写入前（内存）", JSON.stringify(service.state, "", true) == state_before and not service.is_recruited("priest") and (service.state["ownedItems"] as Array).size() == 8)
	_check("招募写盘失败：文件内容不变", FileAccess.get_file_as_string(service.store.path) == file_before)
	_check("失败后可以重试成功", service.recruit("priest")["ok"] and (service.state["ownedItems"] as Array).size() == 16)
	service.settle("rb1", "win")
	var pending_state := JSON.stringify(service.state, "", true)
	service.store.fail_next_write = true
	var claim_failed := service.claim("warrior", "warrior_boots_set")
	_check("领奖写盘失败：拥有清单和待领奖都不变", not claim_failed["ok"] and JSON.stringify(service.state, "", true) == pending_state and service.state["pendingReward"] != null and not service.owns("warrior_boots_set"))
	_check("领奖失败后可重领，且只发一次", service.claim("warrior", "warrior_boots_set")["ok"] and service.claim("warrior", "warrior_shoulder_set")["reason"] == "no_pending")
	# 不可写路径
	var blocked := SaveService.new(_table, SaveStore.new("/proc/capy_nope/save.json"))
	blocked.load_state()
	var blocked_result := blocked.recruit("warrior")
	_check("存档路径写不了：返回失败，内存仍是空档", not blocked_result["ok"] and blocked.members().is_empty(), str(blocked_result))


func _corrupt_files() -> void:
	var path := "%s/corrupt.json" % _dir
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("{ this is not json")
	file.close()
	var service := SaveService.new(_table, SaveStore.new(path))
	service.load_state()
	_check("坏档不崩：当新档开始，原文件改名留证", service.members().is_empty() and FileAccess.file_exists(path + ".corrupt") and service.notes.size() == 1, str(service.notes))
	_write(path, {"version": 99, "slots": ["warrior", "", "", ""]})
	var future := SaveService.new(_table, SaveStore.new(path))
	future.load_state()
	_check("版本不认识：不乱读，改名留证", future.members().is_empty() and FileAccess.file_exists(path + ".corrupt"))
	# 字段被改坏：全部修复
	_write(path, {"version": 1, "slots": ["warrior", "ghost", "warrior", 5], "captainSlot": 3, "inspectSlot": "x", "selectedSlot": 2, "ownedItems": ["nope", "warrior_weapon", "warrior_weapon"], "equips": {"warrior": {"weapon": "priest_weapon", "helmet": "warrior_helmet", "shoulder": "warrior_shoulder_set"}, "ghost": {}}, "talentId": {"warrior": "t2"}, "pendingReward": {"run_id": 3}, "claimedRuns": ["a", "a", 4]})
	var fixed := SaveService.new(_table, SaveStore.new(path))
	fixed.load_state()
	_check("坏字段被修复：只剩战士在槽 1，重复和幽灵职业被清掉", fixed.state["slots"] == ["warrior", "", "", ""], str(fixed.state["slots"]))
	_check("队长指针修复到有人的槽；找不到的指针为 -1", fixed.state["captainSlot"] == 0 and fixed.state["inspectSlot"] == -1 and fixed.state["selectedSlot"] == -1)
	_check("拥有清单去重去假，并补齐初始八件", (fixed.state["ownedItems"] as Array).size() == 8 and _unique(fixed.state["ownedItems"]))
	_check("穿了别人的装备/没拥有的奖励件：回初始件；合法的保留", fixed.state["equips"]["warrior"]["weapon"] == "warrior_weapon" and fixed.state["equips"]["warrior"]["shoulder"] == "warrior_shoulder" and fixed.state["equips"]["warrior"]["helmet"] == "warrior_helmet")
	_check("非法待领奖被清掉，重复场次去重", fixed.state["pendingReward"] == null and (fixed.state["claimedRuns"] as Array) == ["a"])
	var equips_ok := true
	for item_id: String in (fixed.state["equips"]["warrior"] as Dictionary).values():
		equips_ok = equips_ok and fixed.owns(item_id)
	_check("修复后 equips 仍都在 ownedItems 里", equips_ok)
	_check("修复过程只记说明、不崩（%d 条）" % fixed.notes.size(), fixed.notes.size() > 0)


func _sets_and_fight() -> void:
	var service := _fresh("sets")
	service.recruit("warrior")
	service.recruit("priest")
	_check("没有奖励件时不凑套", service.active_sets().is_empty())
	service.settle("s1", "win")
	service.claim("warrior", "warrior_shoulder_set")
	service.settle("s2", "win")
	service.claim("warrior", "warrior_boots_set")
	service.equip("warrior", "warrior_shoulder_set")
	_check("只穿一件套装件不算两件套", not service.active_sets().has("warrior"))
	service.equip("warrior", "warrior_boots_set")
	_check("肩膀和鞋子同套都穿上：两件套生效", service.active_sets() == ["warrior"], str(service.active_sets()))
	var options := service.battle_options()
	var config := BattleConfig.load_config(options)
	var taunt: Dictionary = {}
	for effect: Dictionary in config["skills"]["defensive_taunt"]["effects"]:
		if effect["kind"] == "taunt":
			taunt = effect
	_check("两件套经存档接到战斗配置：战士挑衅 5+2（t1）+1（套）=8 秒", absf(float(taunt["duration"]) - 8.0) < 0.001, str(taunt))
	service.equip("warrior", "warrior_boots")
	_check("脱掉一件后两件套失效", service.active_sets().is_empty())
	service.set_talent("warrior", "t2")
	var t2 := BattleConfig.load_config(service.battle_options())
	_check("存档天赋经 battle_options 接到战斗：t2 战士挑衅守势消耗 15", int(t2["skills"]["defensive_taunt"]["cost"]) == 15)
	_check("战斗槽位：只派一人时其余留空，顺序不变", service.battle_slots(["priest"]) == ["", "priest", "", ""], str(service.battle_slots(["priest"])))

	# 真打一场再结算（命令行同一入口）
	var four := _fresh("fight")
	_recruit_all(four)
	var fought := SaveCli._fight(four, "f1", [], 5, false)
	_check("fight：4 人真打赢一场并结算，胜利后记待领奖", fought["ok"] and fought["battle"]["result"] == "win" and four.state["pendingReward"] != null, str(fought))
	_check("fight 记下战斗里最后选中的槽，且不改队长", four.state["selectedSlot"] >= 0 and four.state["captainSlot"] == 0)
	_check("有待领奖时 fight 被拒", SaveCli._fight(four, "f2", [], 5, false)["reason"] == "pending_reward")
	four.claim("mage", "mage_shoulder_set")
	var lost := SaveCli._fight(four, "f2", [], 1, true)
	_check("fight：不操作输掉，不发装备", lost["ok"] and lost["battle"]["result"] == "lose" and four.state["pendingReward"] == null and not four.owns("mage_boots_set"), str(lost.get("battle")))
	var solo := SaveCli._fight(four, "f3", ["mage"], 1, true)
	_check("fight 只派一人：战斗里只有一个友方", solo["ok"] and (solo["battle"]["party"] as Array) == ["", "", "mage", ""], str(solo.get("battle")))
	_check("派出未招募的人被拒", SaveCli._fight(_fresh("x"), "f", ["mage"], 1, false)["reason"] in ["bad_party", "no_party"])


func _cli() -> void:
	var path := "%s/cli.json" % _dir
	var code := SaveCli.run(PackedStringArray(["--save=" + path, "--do=recruit:warrior", "--do=recruit:warrior", "--do=talent:warrior:zz"]))
	_check("命令行：有一条失败时退出码为 1，其余命令仍执行", code == 1 and FileAccess.file_exists(path))
	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	_check("命令行写出的存档：默认天赋 t1、一名成员", raw["talentId"]["warrior"] == "t1" and raw["slots"][0] == "warrior")
	_check("命令行全部成功时退出码为 0", SaveCli.run(PackedStringArray(["--save=" + path, "--do=show"])) == 0)
	_check("没有 --do 不进命令行模式", not SaveCli.wanted(PackedStringArray(["--battle=4"])))
