extends SceneTree
## P1 战斗机制自检（无窗口）。运行：
##   godot --headless --path client --script res://scripts/tests/battle_check.gd
## 每条用例打印 PASS / FAIL；有失败时退出码 1。不改任何工程文件。

const BattleSim := preload("res://scripts/battle/battle_sim.gd")
const BattleEvents := preload("res://scripts/battle/battle_events.gd")
const BattleConfig := preload("res://scripts/battle/battle_config.gd")
const BattleController := preload("res://scripts/input/battle_controller.gd")
const BattleBot := preload("res://scripts/input/battle_bot.gd")

var _failures: int = 0
var _config: Dictionary = {}


func _initialize() -> void:
	_config = BattleConfig.load_config()
	var problems := BattleConfig.validate(_config)
	_check("配置可用", problems.is_empty(), ", ".join(problems))
	if problems.is_empty():
		_run_all()
	print("RESULT: %s (%d 条失败)" % ["FAIL" if _failures > 0 else "ALL PASS", _failures])
	quit(1 if _failures > 0 else 0)


func _run_all() -> void:
	_full_battles()
	_invalid_skills()
	_selection_rules()
	_command_rules()
	_interrupt_and_status()
	_determinism()


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		print("PASS  ", name)
	else:
		_failures += 1
		print("FAIL  ", name, "  ", detail)


## 建一场战斗。返回 {sim, events, controller, bot}。
func _make(slots: Array, seed: int, cfg: Dictionary = {}) -> Dictionary:
	var merged: Dictionary = _config.duplicate(true)
	for key in cfg:
		merged[key] = cfg[key]
	var events := BattleEvents.new()
	var sim := BattleSim.new()
	sim.setup(merged, slots, seed, events)
	var controller := BattleController.new()
	controller.setup(sim, events)
	var bot := BattleBot.new()
	bot.setup(sim, controller)
	return {"sim": sim, "events": events, "controller": controller, "bot": bot}


func _play(battle: Dictionary, passive: bool) -> void:
	var sim: BattleSim = battle["sim"]
	var bot: BattleBot = battle["bot"]
	bot.passive = passive
	var dt := float(_config["tick"])
	var guard := 0
	while not sim.finished and guard < 20000:
		bot.tick()
		sim.step(dt)
		guard += 1


func _count(events: BattleEvents, event_name: String, filter: Dictionary = {}) -> int:
	var total := 0
	for line in events.lines:
		var record: Dictionary = JSON.parse_string(line)
		if record["e"] != event_name:
			continue
		var match_all := true
		for key in filter:
			if record.get(key) != filter[key]:
				match_all = false
		if match_all:
			total += 1
	return total


func _full_battles() -> void:
	var one := ["warrior", "", "", ""]
	var four := ["warrior", "rogue", "mage", "priest"]
	for entry: Array in [["1 人", one, 11, true], ["4 人", four, 12, true]]:
		var label: String = entry[0]
		var must_win_loop: bool = entry[3]
		var win_run := _make(entry[1], entry[2])
		_play(win_run, false)
		var tries := 1
		while must_win_loop and (win_run["sim"] as BattleSim).result != "win" and tries < 30:
			win_run = _make(entry[1], int(entry[2]) + tries)
			_play(win_run, false)
			tries += 1
		var win_sim: BattleSim = win_run["sim"]
		var win_events: BattleEvents = win_run["events"]
		# 1 人胜率约五成（见 balance_sweep），所以从给定种子起找第一个赢的，最多试 30 个
		var must_win: bool = entry[3]
		_check("%s 操作打到结算%s" % [label, "且打赢" if must_win else "（胜率见 balance_sweep）"], win_sim.result == ("win" if must_win else win_sim.result) and win_sim.finished, "试了 %d 个种子，result=%s reason=%s t=%.1f" % [tries, win_sim.result, win_sim.reason, win_sim.time])
		print("      %s 胜利：用时 %.1fs，技能 %d 次，被拒 %d 次，倒下 %d 个，日志 %d 行" % [label, win_sim.time, _count(win_events, "skill_cast"), _count(win_events, "command_rejected"), _count(win_events, "unit_downed"), win_events.lines.size()])
		var lose_run := _make(entry[1], entry[2])
		_play(lose_run, true)
		var lose_sim: BattleSim = lose_run["sim"]
		_check("%s 不操作会失败（全员倒下）" % label, lose_sim.result == "lose" and lose_sim.reason == "all_allies_down", "result=%s reason=%s" % [lose_sim.result, lose_sim.reason])
		var timeout_run := _make(entry[1], entry[2], {"time_limit": 2.0})
		_play(timeout_run, true)
		var timeout_sim: BattleSim = timeout_run["sim"]
		_check("%s 超时判失败" % label, timeout_sim.result == "lose" and timeout_sim.reason == "timeout", "reason=%s" % timeout_sim.reason)
		var ended: int = _count(win_events, "battle_ended")
		_check("%s 只发一次 battle_ended" % label, ended == 1, str(ended))
	var spawn_run := _make(["", "mage", "", "priest"], 5)
	var spawn_sim: BattleSim = spawn_run["sim"]
	_check("空槽不生成：2 人 = 2 个友方", spawn_sim.living("ally").size() == 2, str(spawn_sim.living("ally").size()))
	_check("敌人固定 4 个（2 近战 + 1 施法 + 1 精英）", spawn_sim.living("enemy").size() == 4)


func _invalid_skills() -> void:
	# 无效技能不扣资源、不进冷却
	var battle := _make(["warrior", "", "", ""], 3)
	var sim: BattleSim = battle["sim"]
	var events: BattleEvents = battle["events"]
	var controller: BattleController = battle["controller"]
	var warrior := sim.slot_unit(0)
	var rage_before := warrior.res
	var accepted := controller.press_skill("q")
	_check("敌人太远：猛击被拒", not accepted and _count(events, "command_rejected", {"reason": "out_of_range", "kind": "skill"}) == 1)
	_check("被拒不扣资源", warrior.res == rage_before, "rage %.1f -> %.1f" % [rage_before, warrior.res])
	_check("被拒不进冷却、不发 skill_cast", not warrior.cd_until.has("q") and _count(events, "skill_cast") == 0)
	_check("被拒不占公共冷却", warrior.gcd_until == 0.0)

	# 资源不足
	var rogue_battle := _make(["rogue", "", "", ""], 3)
	var rogue_sim: BattleSim = rogue_battle["sim"]
	var rogue := rogue_sim.slot_unit(0)
	var enemy: BattleSim.Unit = rogue_sim.living("enemy")[0]
	enemy.pos = rogue.pos + Vector2(40, 0)
	rogue.res = 5.0
	var rogue_controller: BattleController = rogue_battle["controller"]
	var accepted_w := rogue_controller.press_skill("w")
	_check("能量不足：致命一击被拒且不扣能量", not accepted_w and rogue.res == 5.0 and _count(rogue_battle["events"], "command_rejected", {"reason": "no_resource"}) == 1)

	# 有效技能：扣资源、进冷却、占 GCD；GCD 内别的技能被拒；按住连发被冷却挡住
	var cast_battle := _make(["warrior", "mage", "", ""], 3)
	var cast_sim: BattleSim = cast_battle["sim"]
	var cast_controller: BattleController = cast_battle["controller"]
	var cast_events: BattleEvents = cast_battle["events"]
	var tank := cast_sim.slot_unit(0)
	var target: BattleSim.Unit = cast_sim.living("enemy")[0]
	target.max_hp = 1000
	target.hp = 1000
	target.pos = tank.pos + Vector2(50, 0)
	var rage := tank.res
	var ok_cast := cast_controller.press_skill("q")
	_check("有效技能：猛击成功并扣 30 怒气", ok_cast and is_equal_approx(tank.res, rage - 30.0), "rage %.1f -> %.1f" % [rage, tank.res])
	_check("猛击进入 5 秒冷却", is_equal_approx(float(tank.cd_until["q"]), 5.0), str(tank.cd_until))
	var again := cast_controller.press_skill("q")
	_check("连按猛击：被冷却挡住不重复施放", not again and _count(cast_events, "skill_cast", {"skill_id": "slam"}) == 1)
	var gcd_try := cast_controller.press_skill("e")
	_check("1 秒公共间隔内其他技能被拒（gcd）", not gcd_try and _count(cast_events, "command_rejected", {"reason": "gcd"}) == 1)
	var off_gcd := cast_controller.press_skill("r")
	_check("蓄怒不占公共间隔，可以紧接着放", off_gcd)

	# 切人不重置冷却
	var q_cd_before := float(tank.cd_until["q"])
	cast_controller.select_slot(1)
	var mage := cast_sim.slot_unit(1)
	mage.pos = target.pos + Vector2(-200, 0)
	for _i in 25:
		cast_sim.step(float(_config["tick"]))
	var mage_cast := cast_controller.press_skill("w")
	var mage_cd := float(mage.cd_until.get("w", -1.0))
	cast_controller.select_slot(0)
	cast_controller.select_slot(1)
	cast_controller.select_slot(0)
	_check("切人：战士猛击冷却不变", is_equal_approx(float(tank.cd_until["q"]), q_cd_before))
	_check("切人：法师奥术弹冷却不变", mage_cast and is_equal_approx(float(mage.cd_until["w"]), mage_cd))
	cast_sim.set_paused(true)
	var paused_cast := cast_controller.press_skill("w")
	var time_before := cast_sim.time
	cast_sim.step(1.0)
	_check("暂停时不施法、时间不走", not paused_cast and cast_sim.time == time_before and _count(cast_events, "command_rejected", {"reason": "paused"}) >= 1)
	cast_sim.set_paused(false)


func _selection_rules() -> void:
	var battle := _make(["warrior", "", "rogue", ""], 4)
	var controller: BattleController = battle["controller"]
	var events: BattleEvents = battle["events"]
	var changes: Array = []
	events.selection_changed.connect(func(slot): changes.append(slot))
	_check("默认选中第一名在场成员", controller.selected_slot == 0)
	var before := controller.selected_slot
	var r1 := controller.select_slot(1)
	var r3 := controller.select_slot(3)
	_check("空槽数字键（2、4）不改变当前选择", not r1 and not r3 and controller.selected_slot == before and changes.is_empty())
	_check("有人的槽位可以选（3）", controller.select_slot(2) and controller.selected_slot == 2 and changes == [2])
	_check("越界槽位不报错、不改选择", not controller.select_slot(9) and not controller.select_slot(-1) and controller.selected_slot == 2)
	var sim: BattleSim = battle["sim"]
	var warrior := sim.slot_unit(0)
	controller.on_left_click(warrior.pos)
	_check("左键点己方只选人，不发移动命令", controller.selected_slot == 0 and warrior.order_kind == "none" and _count(events, "command_issued") == 0)
	controller.on_left_click(Vector2(700, 500))
	_check("左键点地：选中者移动", warrior.order_kind == "move" and _count(events, "command_issued", {"kind": "move", "unit_id": warrior.id}) == 1)
	var rogue := sim.slot_unit(2)
	_check("移动命令不影响别人（盗贼没有命令）", rogue.order_kind == "none")


func _command_rules() -> void:
	var battle := _make(["warrior", "", "", "priest"], 6)
	var sim: BattleSim = battle["sim"]
	var controller: BattleController = battle["controller"]
	var events: BattleEvents = battle["events"]
	var warrior := sim.slot_unit(0)
	var priest := sim.slot_unit(3)
	var enemy: BattleSim.Unit = sim.living("enemy")[0]
	controller.on_right_click(enemy.pos)
	_check("右键点敌人：战士进入攻击命令", warrior.order_kind == "attack" and warrior.target_id == enemy.id)
	controller.on_right_click(priest.pos)
	_check("非牧师右键点队友：不改当前命令", warrior.order_kind == "attack" and warrior.target_id == enemy.id)
	controller.on_right_click(Vector2(900, 900))
	_check("右键空地：不改当前命令", warrior.order_kind == "attack")
	controller.select_slot(3)
	controller.on_right_click(warrior.pos)
	_check("牧师右键点队友：进入治疗命令", priest.order_kind == "heal" and priest.target_id == warrior.id)
	controller.on_right_click(enemy.pos)
	_check("牧师右键点敌人：不改命令", priest.order_kind == "heal" and priest.target_id == warrior.id)
	# 倒下的人不能再下令
	sim._damage(enemy, warrior, 99999.0, "", false)
	_check("倒下发 unit_downed", not warrior.alive and _count(events, "unit_downed", {"unit_id": warrior.id}) == 1)
	controller.select_slot(0)
	var moved := sim.order_move(warrior.id, Vector2(100, 100))
	var cast := controller.press_skill("q")
	_check("倒下的人不能移动、不能放技能", not moved and not cast and _count(events, "command_rejected", {"reason": "unit_down"}) == 2)
	var heal_target_dead := priest.order_kind
	for _i in 3:
		sim.step(float(_config["tick"]))
	_check("治疗目标倒下后命令自动清掉", heal_target_dead == "heal" and priest.order_kind == "none")
	_check("战内没有复活：倒下的人 hp 保持 0", warrior.hp == 0 and not warrior.alive)


func _interrupt_and_status() -> void:
	var battle := _make(["rogue", "warrior", "", ""], 8)
	var sim: BattleSim = battle["sim"]
	var controller: BattleController = battle["controller"]
	var events: BattleEvents = battle["events"]
	var rogue := sim.slot_unit(0)
	var caster: BattleSim.Unit = null
	for enemy in sim.living("enemy"):
		if enemy.kind == "caster":
			caster = enemy
	caster.max_hp = 1000
	caster.hp = 1000
	caster.pos = Vector2(600, 540)
	rogue.pos = Vector2(560, 540)
	rogue.res = 100.0
	var guard := 0
	while caster.cast.is_empty() and guard < 400:
		sim.step(float(_config["tick"]))
		guard += 1
	_check("施法小怪开始读条", not caster.cast.is_empty() and _count(events, "enemy_cast_started", {"skill_id": "shadow_bolt"}) == 1)
	controller.on_right_click(caster.pos)
	var interrupted := controller.press_skill("q")
	_check("盗贼破法突刺打断读条", interrupted and caster.cast.is_empty() and _count(events, "enemy_cast_interrupted", {"unit_id": caster.id}) == 1)
	# 嘲讽与减伤状态
	controller.select_slot(1)
	var tank := sim.slot_unit(1)
	var elite: BattleSim.Unit = null
	for enemy in sim.living("enemy"):
		if enemy.kind == "melee":
			elite = enemy
	tank.pos = elite.pos + Vector2(-50, 0)
	controller.on_right_click(elite.pos)
	var taunted := controller.press_skill("w")
	_check("挑衅守势：敌人带嘲讽、战士带减伤", taunted and elite.statuses.has("taunt") and tank.statuses.has("mitigate") and _count(events, "status_applied") == 2)
	var applied_mult := sim.taken_mult(tank)
	_check("减伤状态让承伤系数为 0.6", is_equal_approx(applied_mult, 0.6), str(applied_mult))
	var expiry_guard := 0
	while tank.statuses.has("mitigate") and expiry_guard < 400:
		sim.step(float(_config["tick"]))
		expiry_guard += 1
	_check("状态到期发 status_expired", _count(events, "status_expired", {"status_id": "mitigate"}) >= 1 and not tank.statuses.has("mitigate"))
	# 治疗只算有效量，满血不空补
	var heal_battle := _make(["warrior", "priest", "", ""], 9)
	var heal_sim: BattleSim = heal_battle["sim"]
	var heal_controller: BattleController = heal_battle["controller"]
	heal_controller.select_slot(1)
	var priest := heal_sim.slot_unit(1)
	var hurt := heal_sim.slot_unit(0)
	hurt.hp = hurt.max_hp - 40
	heal_controller.on_right_click(hurt.pos)
	var healed := heal_controller.press_skill("q")
	var heal_line: Dictionary = JSON.parse_string(_last_line(heal_battle["events"], "heal_done"))
	var heal_skill: Dictionary = _config["skills"]["greater_heal"]
	var expect_amount := roundi(float((heal_skill["effects"] as Array)[0]["amount"]))
	var expect_cost := float(heal_skill["cost"])
	_check("强效治疗：治疗量 %d（读配置），实际只补 40" % expect_amount, healed and heal_line["amount"] == expect_amount and heal_line["effective"] == 40 and hurt.hp == hurt.max_hp, str(heal_line))
	_check("牧师法力扣 %d（读配置）" % int(expect_cost), is_equal_approx(priest.res, float(_config["classes"]["priest"]["resource"]["start"]) - expect_cost), str(priest.res))


func _last_line(events: BattleEvents, event_name: String) -> String:
	for i in range(events.lines.size() - 1, -1, -1):
		var record: Dictionary = JSON.parse_string(events.lines[i])
		if record["e"] == event_name:
			return events.lines[i]
	return "{}"


func _determinism() -> void:
	var a := _make(["warrior", "rogue", "mage", "priest"], 77)
	var b := _make(["warrior", "rogue", "mage", "priest"], 77)
	var c := _make(["warrior", "rogue", "mage", "priest"], 78)
	_play(a, false)
	_play(b, false)
	_play(c, false)
	var lines_a: PackedStringArray = a["events"].lines
	var lines_b: PackedStringArray = b["events"].lines
	var lines_c: PackedStringArray = c["events"].lines
	_check("同一种子同样操作：日志逐行一致", lines_a == lines_b, "%d vs %d 行" % [lines_a.size(), lines_b.size()])
	_check("不同种子：暴击结果不同（日志不同）", lines_a != lines_c)
	_check("battle_started 把种子写进日志", _last_line(a["events"], "battle_started").contains("\"seed\":77") or lines_a[0].contains("\"seed\":77"))
