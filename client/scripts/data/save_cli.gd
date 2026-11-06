extends RefCounted
## 命令行驱动单档（P2 不做界面，界面在 P3）。用法（`--` 之后）：
##   --save=PATH            存档路径，缺省 user://save.json（测试沙箱写不了默认目录时用）
##   --do=命令              可重复，按给出顺序执行；任何一条失败退出码为 1，但后面的命令仍会执行
##   --seed=N --passive     给 fight 用
## 命令：
##   show                          打印当前存档
##   recruit:职业                   招募
##   move:槽A:槽B                  两个槽位（1..4）互换
##   captain:职业   inspect:职业
##   talent:职业:t1|t2             非法标识回默认
##   equip:职业:物品id             换装
##   options                       列出可领奖的候选（已招募职业里还没拥有的肩膀/鞋子）
##   settle:场次:win|lose[:职业,职业]  直接按给定结果结算一场（不打）；职业列表是本场派出的人，缺省全部
##   fight:场次[:职业,职业]        用当前队伍、天赋、两件套真打一场（bot 自动操作），再结算
##   claim:职业[:物品id]           领奖
##   failwrite                     让下一次写盘失败（验证失败回滚）
## 输出：开头 STATE_BEFORE，每条命令一行 CMD，结尾 STATE_AFTER；都是单行 JSON，便于对比。

const ItemsTable := preload("res://scripts/data/items_table.gd")
const SaveStore := preload("res://scripts/data/save_store.gd")
const SaveService := preload("res://scripts/data/save_service.gd")
const BattleConfig := preload("res://scripts/battle/battle_config.gd")
const BattleSim := preload("res://scripts/battle/battle_sim.gd")
const BattleEvents := preload("res://scripts/battle/battle_events.gd")
const BattleController := preload("res://scripts/input/battle_controller.gd")
const BattleBot := preload("res://scripts/input/battle_bot.gd")


## 参数里有 --do= 才算命令行单档模式。
static func wanted(raw: PackedStringArray) -> bool:
	for arg in raw:
		if arg.begins_with("--do="):
			return true
	return false


## 返回进程退出码：0 全部成功，1 有命令失败，2 表读不到。
static func run(raw: PackedStringArray) -> int:
	var save_path := SaveStore.DEFAULT_PATH
	var commands: Array[String] = []
	var seed_value := 1
	var passive := false
	for arg in raw:
		if arg.begins_with("--save="):
			save_path = arg.get_slice("=", 1)
		elif arg.begins_with("--do="):
			commands.append(arg.substr(5))
		elif arg.begins_with("--seed="):
			seed_value = int(arg.get_slice("=", 1))
		elif arg == "--passive":
			passive = true
	var table := ItemsTable.new()
	if not table.load_tables():
		print("SAVE_ERROR 数值表读不到")
		return 2
	var service := SaveService.new(table, SaveStore.new(save_path))
	service.load_state()
	for note in service.notes:
		print("SAVE_NOTE ", note)
	print("STATE_BEFORE ", JSON.stringify(service.state, "", true))
	var failed := 0
	for command in commands:
		var result := _execute(service, table, command, seed_value, passive)
		if not bool(result.get("ok", false)):
			failed += 1
		print("CMD ", command, " -> ", "OK" if bool(result.get("ok", false)) else "ERR", " ", JSON.stringify(result, "", true))
	print("STATE_AFTER ", JSON.stringify(service.state, "", true))
	print("SAVE_PATH ", ProjectSettings.globalize_path(save_path))
	return 1 if failed > 0 else 0


static func _execute(service: SaveService, table: ItemsTable, command: String, seed_value: int, passive: bool) -> Dictionary:
	var parts := command.split(":")
	var verb := parts[0]
	match verb:
		"show":
			return {"ok": true, "reason": "", "state": service.state}
		"recruit":
			return service.recruit(_arg(parts, 1))
		"move":
			return service.swap_slots(int(_arg(parts, 1)) - 1, int(_arg(parts, 2)) - 1)
		"captain":
			return service.set_captain(_arg(parts, 1))
		"inspect":
			return service.set_inspect(_arg(parts, 1))
		"talent":
			return service.set_talent(_arg(parts, 1), _arg(parts, 2))
		"equip":
			return service.equip(_arg(parts, 1), _arg(parts, 2))
		"options":
			return {"ok": true, "reason": "", "options": service.reward_options(), "pending": service.state["pendingReward"], "collection_complete": service.collection_complete()}
		"settle":
			return service.settle(_arg(parts, 1), _arg(parts, 2), -1, _party(_arg(parts, 3)))
		"claim":
			return service.claim(_arg(parts, 1), _arg(parts, 2))
		"fight":
			return _fight(service, _arg(parts, 1), _party(_arg(parts, 2)), seed_value, passive)
		"failwrite":
			service.store.fail_next_write = true
			return {"ok": true, "reason": ""}
	return {"ok": false, "reason": "unknown_command"}


static func _party(text: String) -> Array:
	var out: Array = []
	for part in text.split(",", false):
		out.append(part.strip_edges())
	return out


static func _arg(parts: PackedStringArray, index: int) -> String:
	return parts[index] if index < parts.size() else ""


## 真打一场：能不能出征由存档判断（有待领奖、没成员都不行），打完按结果结算。
static func _fight(service: SaveService, run_id: String, party: Array, seed_value: int, passive: bool) -> Dictionary:
	var gate := service.can_sortie()
	if not gate["ok"]:
		return gate
	if not service.party_valid(party):
		return {"ok": false, "reason": "bad_party"}
	if (service.state["claimedRuns"] as Array).has(run_id):
		return {"ok": false, "reason": "already_claimed"}
	var config := BattleConfig.load_config(service.battle_options())
	if config.is_empty():
		return {"ok": false, "reason": "config_unreadable"}
	var events := BattleEvents.new()
	var sim := BattleSim.new()
	var slots := service.battle_slots(party)
	sim.setup(config, slots, seed_value, events)
	var controller := BattleController.new()
	controller.setup(sim, events)
	var bot := BattleBot.new()
	bot.setup(sim, controller)
	bot.passive = passive
	var guard := 0
	var step := float(config["tick"])
	while not sim.finished and guard < 20000:
		bot.tick()
		sim.step(step)
		guard += 1
	var settled := service.settle(run_id, sim.result, controller.selected_slot, party)
	settled["battle"] = {"result": sim.result, "reason": sim.reason, "elapsed": snappedf(sim.time, 0.01), "seed": sim.seed_value, "party": slots, "talents": config["talents"], "sets": service.active_sets()}
	return settled
