extends SceneTree
## 数值复跑：按 design/balance/README.md 的场景表，每个场景跑一批种子，打印胜率和用时。
## 运行：godot --headless --path client --script res://scripts/tests/balance_sweep.gd -- [--seeds=20] [--only=名字] [--talent=t2] [--sets=warrior,rogue] [--no-modifiers]
## 场景名：4auto 4passive 4noheal 3auto 2auto 1auto 1passive
## 只读数值，不改任何文件；种子从 1 起连续。

const BattleSim := preload("res://scripts/battle/battle_sim.gd")
const BattleEvents := preload("res://scripts/battle/battle_events.gd")
const BattleConfig := preload("res://scripts/battle/battle_config.gd")
const BattleController := preload("res://scripts/input/battle_controller.gd")
const BattleBot := preload("res://scripts/input/battle_bot.gd")

const SCENARIOS := [
	{"name": "4auto", "label": "4 人 自动操作", "slots": ["warrior", "rogue", "mage", "priest"], "passive": false, "noheal": false},
	{"name": "4passive", "label": "4 人 不操作", "slots": ["warrior", "rogue", "mage", "priest"], "passive": true, "noheal": false},
	{"name": "4noheal", "label": "4 人 牧师治疗置 0", "slots": ["warrior", "rogue", "mage", "priest"], "passive": false, "noheal": true},
	{"name": "3auto", "label": "3 人（战、法、牧）", "slots": ["warrior", "mage", "", "priest"], "passive": false, "noheal": false},
	{"name": "2auto", "label": "2 人（战、牧）", "slots": ["warrior", "", "", "priest"], "passive": false, "noheal": false},
	{"name": "1auto", "label": "1 人（战）", "slots": ["warrior", "", "", ""], "passive": false, "noheal": false},
	{"name": "1passive", "label": "1 人 不操作", "slots": ["warrior", "", "", ""], "passive": true, "noheal": false},
]


func _initialize() -> void:
	var seeds := 20
	var only := ""
	var talent := ""
	var sets: Array = []
	var modifiers := true
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seeds="):
			seeds = int(arg.get_slice("=", 1))
		elif arg.begins_with("--only="):
			only = arg.get_slice("=", 1)
		elif arg.begins_with("--talent="):
			talent = arg.get_slice("=", 1)
		elif arg == "--no-modifiers":
			modifiers = false
		elif arg.begins_with("--sets="):
			sets = Array(arg.get_slice("=", 1).split(","))
	var talents := {}
	if talent != "":
		for class_id in ["warrior", "rogue", "mage", "priest"]:
			talents[class_id] = talent
	var config := BattleConfig.load_config({"talents": talents, "sets": sets, "modifiers": modifiers})
	if config.is_empty():
		print("配置读取失败")
		quit(1)
		return
	print("talent=%s sets=%s seeds=%d 已生效修正=%s" % [talent if talent != "" else "默认", sets, seeds, config["applied_modifiers"]])
	print("%-22s %6s %10s %10s %8s" % ["场景", "胜率", "胜局中位s", "败局中位s", "我方倒下均值"])
	for scenario: Dictionary in SCENARIOS:
		if only != "" and only != scenario["name"]:
			continue
		_run(scenario, config, seeds)
	quit(0)


func _run(scenario: Dictionary, base_config: Dictionary, seeds: int) -> void:
	var config := base_config.duplicate(true)
	if scenario["noheal"]:
		_zero_heals(config)
	var wins: Array[float] = []
	var losses: Array[float] = []
	var downed := 0
	for seed_value in range(1, seeds + 1):
		var events := BattleEvents.new()
		var sim := BattleSim.new()
		sim.setup(config, scenario["slots"], seed_value, events)
		var controller := BattleController.new()
		controller.setup(sim, events)
		var bot := BattleBot.new()
		bot.setup(sim, controller)
		bot.passive = scenario["passive"]
		var guard := 0
		while not sim.finished and guard < 20000:
			bot.tick()
			sim.step(float(config["tick"]))
			guard += 1
		for unit in sim.units.values():
			if unit.side == "ally" and not unit.alive:
				downed += 1
		if sim.result == "win":
			wins.append(sim.time)
		else:
			losses.append(sim.time)
	print("%-22s %5d%% %10s %10s %8.2f" % [scenario["label"], int(round(100.0 * wins.size() / seeds)), _median(wins), _median(losses), float(downed) / seeds])


func _zero_heals(config: Dictionary) -> void:
	for skill: Dictionary in config["skills"].values():
		for effect: Dictionary in skill["effects"]:
			if String(effect["kind"]) == "heal":
				effect["amount"] = 0.0
	(config["classes"]["priest"]["attack"] as Dictionary)["damage"] = 0.0


func _median(values: Array[float]) -> String:
	if values.is_empty():
		return "-"
	var sorted := values.duplicate()
	sorted.sort()
	return "%.1f" % sorted[sorted.size() / 2]
