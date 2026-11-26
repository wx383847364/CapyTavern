extends SceneTree
## P1 战斗机制自检，默认无窗口；显式 --s1b6-window 为真实窗口取证，不能自动判视觉通过。运行：
##   godot --headless --path client --script res://scripts/tests/battle_check.gd
## 每条用例打印 PASS / FAIL；有失败时退出码 1。不改任何工程文件。
## 隔离副本参数：-- --s1a-only --s1a-qa-root=<QA根> --s1a-fixture-dir=<QA根>/effect-fixtures-r3-<唯一后缀>。
## 完整回归去掉 --s1a-only；两项目录参数必填，未通过目录检查时不写夹具。
## 隔离调度及唤醒事务用例随两套入口执行；含隔离输入分发，不代表正式场景或其他四技能效果验收。

const BattleSim := preload("res://scripts/battle/battle_sim.gd")
const BattleEvents := preload("res://scripts/battle/battle_events.gd")
const BattleConfig := preload("res://scripts/battle/battle_config.gd")
const BattleController := preload("res://scripts/input/battle_controller.gd")
const BattleSceneScript := preload("res://scenes/battle/battle_scene.gd")
const BattleViewScript := preload("res://scenes/ui/battle_view.gd")
const BattleBot := preload("res://scripts/input/battle_bot.gd")

var _failures: int = 0
var _config: Dictionary = {}
var _s1a_fixture_directory: String = ""
## 同步检查全部通过才挂真实树节点；所有路径均由 deferred 收尾统一退出。
var _s1b4_can_run: bool = false


## 窗口观察状态只属于本测试入口；不向Sim或公共事件增加字段，默认回归不使用。
var _s1b6_log_probe_running: bool = false
var _s1b6_log_cancelled: bool = false
var _s1b6_log_cleanup_unknown: bool = false
var _s1b6_finishing: bool = false
var _s1b6_scene_ref: WeakRef = null
var _s1b6_sim: BattleSim = null
var _s1b6_bus: BattleEvents = null
var _s1b6_controller: BattleController = null
var _s1b6_battle_id: String = ""
var _s1b6_input_source: String = "unspecified"
var _s1b6_life: Dictionary = {"entered": 0, "ready": 0, "exiting": 0, "exited": 0}
var _s1b6_results: Array[Dictionary] = []
var _s1b6_last_control: Dictionary = {}
var _s1b6_counts: Dictionary = {"key_presses": 0, "mouse_presses": 0, "resize": 0, "focus_out": 0, "focus_in": 0, "selection": 0}


## 显式窗口在回归前独立分流；默认仍同步检查再deferred验树，实际执行和视觉结论归测试。
func _initialize() -> void:
	if OS.get_cmdline_user_args().has("--s1b6-window"):
		# 在首次deferred前接管关闭，建场尚未完成时也走统一幂等清理。
		auto_accept_quit = false
		root.close_requested.connect(_s1b6_close_requested)
		_s1b6_window_start.call_deferred()
		return
	_s1a_config_cases()
	_config = BattleConfig.load_config()
	var problems := BattleConfig.validate(_config)
	_check("配置可用", problems.is_empty(), ", ".join(problems))
	if problems.is_empty():
		# 独立入口只造场并纯查询，避免 S1a 验证依赖旧全局数值回归。
		if not OS.get_cmdline_user_args().has("--s1a-only"):
			_run_all()
		# 复用旧入口，追加独立S23盾及B范围用例；旧夹具保留，不接入产品输入或正式初始化。
		if BattleConfig.load_skill_catalog()["problems"].is_empty():
			_s1a_prepare_cases()
			_s1b_schedule_cases()
			_s1b2_transaction_cases()
			_s1b3_input_cases()
			_s1b5_projection_cases()
			_s2_numeric_cases()
			_s22_transaction_cases()
			_s23_shield_cases()
			_s23b_cases()
			_s1b4_can_run = _failures == 0
	# 初始化回调结束后才入树，避免根节点尚未准备好；配置失败也走同一最终汇总。
	_s1b4_tree_cases.call_deferred()


## 执行旧机制和真人操作回归。
func _run_all() -> void:
	_full_battles()
	_invalid_skills()
	_selection_rules()
	_command_rules()
	_interrupt_and_status()
	_determinism()
	_player_control_cases()
	_ally_ai_cases()
	_player_threat_cases()
	for primary_index: int in [0, 2, 3]:
		_player_whirlwind_case(primary_index, false)
	_player_whirlwind_case(0, true)


## 固定站位和敌方计时，只让被测 AI 执行真实命令和结算。
func _ally_ai_fixture() -> Dictionary:
	var made := _make(["warrior", "rogue", "mage", "priest"], 131, {"crit_chance": 0.0})
	var sim: BattleSim = made["sim"]
	sim.player_controls = true
	sim.ally_ai_enabled = true
	for index in 4:
		var enemy: BattleSim.Unit = sim.living("enemy")[index]
		enemy.pos = Vector2(900, 320) if index == 0 else Vector2(1570, 300 + index * 145)
		enemy.speed = 0.0
		enemy.next_attack_at = INF
		enemy.cast_cd_until = INF
	for index in 4:
		sim.slot_unit(index).pos = Vector2(300, 320 + index * 100)
	return made


## 覆盖开怪等待、追击、手动接管及同种子连续战斗轨迹。
func _ally_ai_cases() -> void:
	var traces: Array[PackedStringArray] = []
	for trial in 2:
		var made := _ally_ai_fixture()
		var sim: BattleSim = made["sim"]
		var controller: BattleController = made["controller"]
		var tank := sim.slot_unit(0)
		var mage := sim.slot_unit(2)
		var target: BattleSim.Unit = sim.living("enemy")[0]
		mage.pos = Vector2(560, 570)
		controller.select_slot(mage.slot)
		controller.select_target(target.id + 1)
		controller.select_slot(tank.slot)
		controller.player_right_click(target.pos, target.id)
		var tank_start := tank.pos
		sim.step(0.05)
		_check("AI 战士先跑，法师跟随入位但保持观察目标", tank.pos.x > tank_start.x
			and mage.auto_target_id == target.id and mage.selected_target_id == target.id + 1
			and mage.damage_done == 0.0 and not tank.ai_contact)
		for step in 100:
			sim.step(0.05)
		_check("AI 战士接怪后法师自动输出，普攻射程内停止追击", tank.ai_contact and mage.damage_done > 0.0
			and tank.pos.distance_to(target.pos) <= tank.attack_range and controller.selected_slot == tank.slot)
		var stopped := tank.pos
		for step in 4:
			sim.step(0.05)
		_check("AI 不把已在普攻距离内的战士推进目标中心", tank.pos == stopped)
		traces.append(sim.events.lines.duplicate())
	_check("实战 AI 同种子、同输入的全部事件逐行一致", traces[0] == traces[1])

	var made := _ally_ai_fixture()
	var sim: BattleSim = made["sim"]
	var controller: BattleController = made["controller"]
	var tank := sim.slot_unit(0)
	var mage := sim.slot_unit(2)
	var target: BattleSim.Unit = sim.living("enemy")[0]
	mage.pos = target.pos + Vector2(-300, 110)
	controller.player_right_click(target.pos, target.id)
	sim.step(0.05)
	_check("AI 无接触不会按时间抢跑", mage.damage_done == 0.0)
	sim._damage(target, tank, 10.0, "", false)
	sim.step(0.05)
	_check("AI 战士先受击也算接怪", mage.damage_done > 0.0)

	made = _ally_ai_fixture()
	sim = made["sim"]
	controller = made["controller"]
	tank = sim.slot_unit(0)
	mage = sim.slot_unit(2)
	target = sim.living("enemy")[0]
	mage.pos = target.pos + Vector2(-300, 100)
	tank.pos = target.pos + Vector2(-80, 0)
	controller.player_right_click(target.pos, target.id)
	controller.select_target(target.id)
	_check("AI 手动嘲讽实际施加", controller.submit_player_skill("w", Vector2.ZERO, false))
	sim.step(0.05)
	_check("AI 成功嘲讽立即放行跟随输出", mage.damage_done > 0.0 and target.statuses.has("taunt"))

	for override in ["manual", "fallen"]:
		made = _ally_ai_fixture()
		sim = made["sim"]
		controller = made["controller"]
		tank = sim.slot_unit(0)
		mage = sim.slot_unit(2)
		target = sim.living("enemy")[0]
		mage.pos = target.pos + Vector2(-300, 100)
		controller.player_right_click(target.pos, target.id)
		if override == "manual":
			controller.select_slot(mage.slot)
			controller.player_right_click(target.pos, target.id)
		else:
			sim._down(tank, target.id)
		sim.step(0.05)
		_check("AI 接怪等待解除 " + override, mage.damage_done > 0.0 and not tank.ai_contact)

	made = _ally_ai_fixture()
	sim = made["sim"]
	controller = made["controller"]
	tank = sim.slot_unit(0)
	mage = sim.slot_unit(2)
	target = sim.living("enemy")[0]
	mage.pos = target.pos + Vector2(-300, 100)
	target.hp = 1.0
	controller.select_slot(mage.slot)
	controller.select_target(target.id)
	_check("AI 首发手动伤害可直接击杀", controller.submit_player_skill("w", Vector2.ZERO, false) and not target.alive)
	sim.step(0.05)
	_check("AI 首发击杀仍开怪，其他队员接续存活目标", tank.auto_target_id != -1 and tank.auto_target_id != target.id)
	_ally_ai_range_cases()
	_ally_ai_support_cases()
	_ally_ai_interrupt_case()


## 盗贼去实际攻击目标处打断可打断技能，选中的观察目标不会改写攻击。
func _ally_ai_interrupt_case() -> void:
	var made := _ally_ai_fixture()
	var sim: BattleSim = made["sim"]
	var controller: BattleController = made["controller"]
	var rogue := sim.slot_unit(1)
	var caster: BattleSim.Unit = sim.living("enemy")[2]
	caster.pos = rogue.pos + Vector2(50, 0)
	sim._start_cast(caster, rogue)
	controller.select_slot(rogue.slot)
	controller.player_right_click(caster.pos, caster.id)
	controller.select_target(sim.living("enemy")[0].id)
	sim.step(0.05)
	_check("AI 破法突刺打断实际攻击目标的读条", caster.cast.is_empty()
		and _count(sim.events, "enemy_cast_interrupted") == 1 and rogue.auto_target_id == caster.id)
	_check("AI 打断后保留玩家的观察目标", rogue.selected_target_id != caster.id)


## 检查远程距离、唤醒边界和手动占用；无可用技能时不为远程技能追击。
func _ally_ai_range_cases() -> void:
	var made := _ally_ai_fixture()
	var sim: BattleSim = made["sim"]
	var controller: BattleController = made["controller"]
	var mage := sim.slot_unit(2)
	var target: BattleSim.Unit = sim.living("enemy")[0]
	mage.pos = Vector2(300, 475)
	controller.select_slot(mage.slot)
	controller.player_right_click(target.pos, target.id)
	mage.res_regen = 0.0
	mage.res = 10.0
	sim.step(0.05)
	_check("AI 缺资源且唤醒等于10%时既不施法也不追", mage.pos == Vector2(300, 475)
		and mage.res == 10.0 and _count(sim.events, "ai_skill_cast", {"skill_id": "evocation"}) == 0)
	mage.res = 9.9
	sim.set_ally_aim_actor(mage.id)
	sim.step(0.05)
	_check("AI 瞄准期保留唤醒和走位", mage.res == 9.9 and mage.pos == Vector2(300, 475))
	sim.set_ally_aim_actor(-1)
	controller.submit_player_skill("w", Vector2.ZERO, false)
	sim.step(0.05)
	_check("AI 手动失败占用该角色下一步", mage.res == 9.9)
	sim.step(0.05)
	_check("AI 严格低于10%按旧唤醒资源规则恢复", mage.res > 10.0
		and _count(sim.events, "ai_skill_cast", {"skill_id": "evocation"}) == 1)
	for step in 24:
		sim.step(0.05)
	var distance := mage.pos.distance_to(target.pos)
	_check("AI 法师在可施法距离停住，保留远于普攻的距离", distance <= 450.0 and distance > mage.attack_range
		and mage.damage_done > 0 and mage.auto_target_id == target.id)
	controller.player_right_click(Vector2(380, 680))
	sim.step(0.05)
	_check("AI 手动移动保留持续攻击目标", mage.order_kind == "move" and mage.auto_target_id == target.id)


## 依次验证危急可达、坦克优先、出圈停步及场边的确定性备选方向。
func _ally_ai_support_cases() -> void:
	var made := _ally_ai_fixture()
	var sim: BattleSim = made["sim"]
	var tank := sim.slot_unit(0)
	var rogue := sim.slot_unit(1)
	var mage := sim.slot_unit(2)
	var priest := sim.slot_unit(3)
	tank.hp = tank.max_hp * 0.65
	mage.hp = mage.max_hp * 0.18
	mage.pos = Vector2(1580, 900)
	rogue.hp = rogue.max_hp * 0.24
	var rogue_hp := rogue.hp
	sim.step(0.05)
	_check("AI 可达危急队友先于远端危急和战士", rogue.hp > rogue_hp and mage.hp == mage.max_hp * 0.18)
	mage.hp = mage.max_hp
	rogue.hp = rogue.max_hp * 0.40
	priest.cd_until.clear()
	priest.gcd_until = 0.0
	priest.next_attack_at = INF
	var tank_hp := tank.hp
	sim.step(0.05)
	_check("AI 无危急时战士先于较低血量的普通队友", tank.hp > tank_hp)

	var target: BattleSim.Unit = sim.living("enemy")[0]
	tank.pos = Vector2(42, 280)
	target.pos = Vector2(52, 280)
	target.cast = {"radius": 150.0, "center": target.pos, "ends_at": sim.time + 15.0}
	sim.issue_player_target(tank, target)
	for step in 32:
		sim.step(0.05)
	var safe := tank.pos
	_check("AI 场边有替代路线，退出实际命中半径", safe.distance_to(target.pos) > 150.0 + tank.radius
		and tank.auto_target_id == target.id)
	for step in 12:
		sim.step(0.05)
	_check("AI 出圈后预警仍在时不折返", tank.pos.distance_to(target.pos) > 150.0 + tank.radius and tank.damage_done == 0.0)
	target.cast.clear()
	for step in 20:
		sim.step(0.05)
	_check("AI 震地结束后恢复原攻击", tank.pos.distance_to(target.pos) <= tank.attack_range and tank.damage_done > 0.0)


## 同一模拟器验证显式普攻、治疗支援、选目标循环与战士仇恨。
func _player_control_cases() -> void:
	var made := _make(["warrior", "rogue", "mage", "priest"], 121, {"crit_chance": 0.0})
	var sim: BattleSim = made["sim"]
	var controller: BattleController = made["controller"]
	sim.player_controls = true
	var allies := sim.living("ally")
	var enemies := sim.living("enemy")
	var warrior: BattleSim.Unit = allies[0]
	var rogue: BattleSim.Unit = allies[1]
	var mage: BattleSim.Unit = allies[2]
	var priest: BattleSim.Unit = allies[3]
	var first: BattleSim.Unit = enemies[0]
	var second: BattleSim.Unit = enemies[1]
	warrior.pos = Vector2(600, 400)
	first.pos = Vector2(660, 400)
	second.pos = Vector2(800, 400)
	for foe in enemies:
		foe.speed = 0
		foe.next_attack_at = 1000
		foe.cast_cd_until = 1000
	var before := first.hp
	controller.select_target(first.id)
	sim.step(0.05)
	_check("真人左键／观察目标不启动普攻", first.hp == before and warrior.auto_target_id == -1)
	controller.player_right_click(first.pos, first.id)
	controller.select_target(second.id)
	sim.step(0.05)
	_check("真人普攻与观察目标独立", first.hp < before and warrior.auto_target_id == first.id and warrior.selected_target_id == second.id)
	controller.player_right_click(Vector2(500, 400))
	before = first.hp
	warrior.next_attack_at = 0
	sim.step(0.05)
	_check("真人走位中保留目标并暂停普攻", first.hp == before and warrior.order_kind == "move" and warrior.auto_target_id == first.id and warrior.selected_target_id == second.id)
	warrior.order_kind = "none"
	warrior.pos = Vector2(580, 400)
	sim.step(0.05)
	_check("真人超距不自动追击", warrior.pos == Vector2(580, 400) and first.hp == before)
	warrior.pos = Vector2(600, 400)
	controller.select_target(first.id)
	var threat := float(first.threat.get(warrior.id, 0.0))
	warrior.res = 100.0
	_check("真人战士猛击使用选中敌人", controller.submit_player_skill("q", Vector2.ZERO, false))
	var dealt := before - first.hp
	_check("猛击只对本目标追加 50% 仇恨", dealt > 0 and is_equal_approx(float(first.threat[warrior.id]) - threat, dealt * 4.5))
	first.threat[rogue.id] = 1000.0
	# 走到真实冷却校验之外，之后只让模拟器推进状态和实际敌方选择。
	sim.time = 2.0
	warrior.next_attack_at = 1000.0
	_check("战士嘲讽补足 10% 并接回仇恨", controller.submit_player_skill("w", Vector2.ZERO, false) and first.threat[warrior.id] == 1100.0)
	var expiry := float(first.statuses["taunt"]["until"])
	sim.step(0.05)
	_check("嘲讽期间实际攻击战士", first.target_id == warrior.id)
	sim.time = expiry
	sim.step(0.05)
	_check("嘲讽到期后继续按仇恨攻击战士", not first.statuses.has("taunt") and first.target_id == warrior.id)
	first.threat[rogue.id] = 1300.0
	sim.step(0.05)
	_check("持续爆发仍可 OT，模型实际对象随之更新", first.target_id == rogue.id)
	controller.select_slot(mage.slot)
	mage.pos = Vector2(500, 400)
	mage.res = 100.0
	_check("战士与法师各自保留观察目标", controller.target_for(mage) == null and warrior.selected_target_id == first.id)
	_check("无敌方选择的爆破接受战场落点", controller.submit_player_skill("q", second.pos, true) and mage.auto_target_id == second.id and mage.damage_done > 0)
	mage.cd_until.clear()
	mage.gcd_until = 0.0
	var mana := mage.res
	var damage := mage.damage_done
	_check("旧路径有效空放消耗且不重选普攻对象", controller.submit_player_skill("q", Vector2(490, 550), true) and mage.res < mana and mage.damage_done == damage and mage.auto_target_id == second.id)
	controller.preferences["tab_health"] = true
	first.hp = 1
	second.hp = 2
	enemies[2].hp = 3
	enemies[3].hp = 4
	controller.cycle_target()
	_check("Tab 本轮优先最低当前生命", mage.selected_target_id == first.id)
	enemies[3].hp = 0.5
	controller.select_target(enemies[3].id)
	controller.cycle_target()
	_check("循环中途换血量和鼠标选择均不重排", mage.selected_target_id == second.id)
	enemies[2].alive = false
	controller.cycle_target()
	_check("循环跳过离场敌人并保持剩余顺序", mage.selected_target_id == enemies[3].id)
	controller.cycle_target()
	_check("下一轮按最新血量重新排序", mage.selected_target_id == enemies[3].id)
	controller.select_slot(priest.slot)
	priest.pos = Vector2(580, 414)
	warrior.hp -= 14.0
	controller.select_target(warrior.id)
	_check("牧师有效治疗预览只读缺血", sim.player_heal_preview(priest, warrior) == 14.0 and warrior.hp == warrior.max_hp - 14.0)
	priest.next_attack_at = 0
	sim.step(0.05)
	_check("牧师无需右键也能自动支援", warrior.hp == warrior.max_hp and sim.player_heal_preview(priest, warrior) == 0.0)


## 真人出征按实际交战均分治疗，换目标遵循阈值、读条锁定和死亡重选。
func _player_threat_cases() -> void:
	# 牧师 t2 的强效治疗足以将 100 缺血补满，验证以实得量而非技能面值计仇恨。
	var config := BattleConfig.load_config({"talents": {"priest": "t2"}})
	config["crit_chance"] = 0.0
	var made := _make(["warrior", "rogue", "mage", "priest"], 121, config)
	var sim: BattleSim = made["sim"]
	var controller: BattleController = made["controller"]
	sim.player_controls = true
	var tank := sim.slot_unit(0)
	var rogue := sim.slot_unit(1)
	var mage := sim.slot_unit(2)
	var priest := sim.slot_unit(3)
	var foes := sim.living("enemy")
	var first := foes[0]
	var second := foes[1]
	var caster := foes[2]
	var untouched := foes[3]
	tank.pos = Vector2(600, 400)
	priest.pos = Vector2(500, 400)
	first.pos = Vector2(660, 400)
	second.pos = Vector2(600, 490)
	caster.pos = Vector2(850, 400)
	for foe in foes:
		foe.speed = 0.0
		foe.next_attack_at = INF
		foe.cast_cd_until = INF
	tank.next_attack_at = INF
	priest.next_attack_at = INF
	controller.select_slot(tank.slot)
	_check("交战治疗夹具：旋风斩命中两只近战", controller.submit_player_skill("e", Vector2.ZERO, false)
		and first.engaged_allies.has(tank.id) and second.engaged_allies.has(tank.id) and not untouched.activated)
	controller.select_slot(priest.slot)
	controller.select_target(tank.id)
	tank.hp -= 100.0
	var healed := controller.submit_player_skill("q", Vector2.ZERO, false)
	_check("真人治疗：实际回100血，两只交战敌人各10仇恨", healed and tank.hp == tank.max_hp
		and is_equal_approx(float(first.threat.get(priest.id, 0.0)), 10.0) and is_equal_approx(float(second.threat.get(priest.id, 0.0)), 10.0)
		and first.engaged_allies.has(priest.id) and second.engaged_allies.has(priest.id)
		and not caster.threat.has(priest.id) and not untouched.threat.has(priest.id),
		"accepted=%s hp=%s/%s threat=%s/%s/%s/%s" % [healed, tank.hp, tank.max_hp, first.threat, second.threat, caster.threat, untouched.threat])
	sim._heal(priest, tank, 100.0, "")
	mage.hp -= 20.0
	sim._heal(priest, mage, 20.0, "")
	_check("真人治疗：满血和未交战队友均无额外仇恨", first.threat.get(priest.id) == 10.0
		and second.threat.get(priest.id) == 10.0 and untouched.threat.is_empty())
	tank.hp -= 14.0
	priest.next_attack_at = 0.0
	sim.step(0.05)
	_check("真人普疗：实际回14血，交战敌人分别增加1.4", tank.hp == tank.max_hp
		and is_equal_approx(float(first.threat.get(priest.id)), 11.4)
		and is_equal_approx(float(second.threat.get(priest.id)), 11.4) and untouched.threat.is_empty())
	first.threat[tank.id] = 100.0
	first.threat[mage.id] = 110.0
	sim.step(0.05)
	_check("真人换目标：等于110%仍打战士", first.target_id == tank.id)
	first.threat[mage.id] = 111.0
	sim.step(0.05)
	_check("真人换目标：严格超过110%时转火", first.target_id == mage.id)

	# 让施法怪自然开始读条，然后用仇恨变化验证读条锁定和后续转火。
	caster.threat[tank.id] = 100.0
	caster.cast_cd_until = sim.time
	sim.step(0.05)
	caster.threat[mage.id] = 111.0
	var before := tank.hp
	var mage_before := mage.hp
	sim.step(0.05)
	_check("真人换目标：读条开始后保留原目标", caster.target_id == tank.id and caster.cast.get("target_id") == tank.id)
	var cast_end := float(caster.cast.get("ends_at", sim.time))
	while sim.time <= cast_end:
		sim.step(0.05)
	_check("真人读条命中原目标并登记敌方发起的交战", tank.hp < before and mage.hp == mage_before
		and caster.engaged_allies.has(tank.id))
	sim.step(0.05)
	_check("真人读条结束后按仇恨转火", caster.target_id == mage.id)

	sim._down(mage, first.id)
	first.threat[tank.id] = 100.0
	first.threat[rogue.id] = 100.0
	sim.step(0.05)
	_check("真人换目标：当前目标死亡，同仇恨选较小ID", first.target_id == tank.id and not first.threat.has(mage.id))
	sim._down(second, tank.id)
	_check("真人敌人死亡清除自身交战与仇恨", not second.activated and second.engaged_allies.is_empty() and second.threat.is_empty())
	sim._finish("lose", "test")
	_check("真人战斗结束清除交战仇恨", first.engaged_allies.is_empty() and first.threat.is_empty())


## 用实际四人配表测试一次旋风斩承接两轮法师技能，并单独记录开启普攻时的表现。
func _player_whirlwind_case(primary_index: int, natural_attacks: bool) -> void:
	var config := BattleConfig.load_config({"talents": {"mage": "t1", "priest": "t2"}, "sets": ["mage"]})
	if not natural_attacks:
		config["crit_chance"] = 0.0
	var made := _make(["warrior", "rogue", "mage", "priest"], 121, config)
	var sim: BattleSim = made["sim"]
	var controller: BattleController = made["controller"]
	sim.player_controls = true
	var tank := sim.slot_unit(0)
	var mage := sim.slot_unit(2)
	var priest := sim.slot_unit(3)
	var foes := sim.living("enemy")
	var primary := foes[primary_index]
	var companion := foes[1]
	var label := "旋风斩四人/%s/%s" % [primary.kind, "开放普攻" if natural_attacks else "仅技能"]
	tank.pos = Vector2(600, 400)
	sim.slot_unit(1).pos = Vector2(500, 600)
	mage.pos = Vector2(735, 400)
	priest.pos = Vector2(480, 400)
	for foe in foes:
		# 固定聚怪位置，用真实敌方选目标推进，冻结攻击和读条以观察每次转火。
		foe.pos = Vector2(1400, 300 + 180 * (foe.id - foes[0].id))
		foe.speed = 0.0
		foe.next_attack_at = INF
		foe.cast_cd_until = INF
	primary.pos = Vector2(660, 400)
	companion.pos = Vector2(600, 490)
	if not natural_attacks:
		tank.next_attack_at = INF
		mage.next_attack_at = INF
	controller.select_slot(tank.slot)
	controller.select_target(primary.id)
	var primary_before := primary.hp
	var companion_before := companion.hp
	var opened := controller.submit_player_skill("e", Vector2.ZERO, false)
	var opened_threat := float(primary.threat.get(tank.id, 0.0))
	_check(label + " 旋风斩对每只命中怪应用技能仇恨倍率", opened
		and is_equal_approx(opened_threat, (primary_before - primary.hp) * 10.5)
		and is_equal_approx(float(companion.threat.get(tank.id, 0.0)), (companion_before - companion.hp) * 10.5))
	sim.step(0.05)
	_check(label + " 两只怪由战士开怪", opened and primary.target_id == tank.id and companion.target_id == tank.id)

	# 验收用例固定法师四发全部暴击；开放普攻用例沿用配表暴击率。
	if not natural_attacks:
		sim.config["crit_chance"] = 1.0
	var first_ot := ""
	for index in range(4):
		var key := "q" if index % 2 == 0 else "w"
		var ready_at := maxf(mage.gcd_until, float(mage.cd_until.get(key, 0.0)))
		while sim.time < ready_at:
			sim.step(0.05)
			if first_ot.is_empty() and (primary.target_id != tank.id or companion.target_id != tank.id):
				first_ot = "第%d发前 t=%.2f 主怪目标=%d 旁怪目标=%d 主怪仇恨=%s" % [index + 1, sim.time, primary.target_id, companion.target_id, primary.threat]
		controller.select_slot(mage.slot)
		controller.select_target(primary.id)
		var mage_before := float(primary.threat.get(mage.id, 0.0))
		var hp_before := primary.hp
		var cast := controller.submit_player_skill(key, Vector2.ZERO, false)
		var mage_after := float(primary.threat.get(mage.id, 0.0))
		var damage := hp_before - primary.hp
		sim.step(0.05)
		if first_ot.is_empty() and (primary.target_id != tank.id or companion.target_id != tank.id):
			first_ot = "第%d发%s后 t=%.2f 主怪目标=%d 旁怪目标=%d 主怪仇恨=%s" % [index + 1, key.to_upper(), sim.time, primary.target_id, companion.target_id, primary.threat]
		var held := primary.target_id == tank.id and companion.target_id == tank.id
		var detail := "t=%.2f 主怪目标=%d 战士=%.2f 法师=%.2f 旁怪目标=%d" % [sim.time, primary.target_id,
			float(primary.threat.get(tank.id, 0.0)), float(primary.threat.get(mage.id, 0.0)), companion.target_id]
		_check(label + " 第%d发%s" % [index + 1, key.to_upper()], cast and damage > 0.0
			and is_equal_approx(mage_after - mage_before, damage)
			and (natural_attacks or held), detail)
		if index == 0:
			tank.hp -= 100.0
			controller.select_slot(priest.slot)
			controller.select_target(tank.id)
			var healed := controller.submit_player_skill("q", Vector2.ZERO, false)
			_check(label + " 牧师有效治疗各记10仇恨", healed and tank.hp == tank.max_hp
				and is_equal_approx(float(primary.threat.get(priest.id, 0.0)), 10.0)
				and is_equal_approx(float(companion.threat.get(priest.id, 0.0)), 10.0),
				"accepted=%s hp=%s/%s threat=%s/%s" % [healed, tank.hp, tank.max_hp, primary.threat, companion.threat])
	var untouched := true
	for foe in foes:
		if foe != primary and foe != companion:
			untouched = untouched and not foe.activated and foe.threat.is_empty()
	_check(label + " 圈外怪没有受到旋风斩或治疗仇恨", untouched)
	print("THREAT_RUN ", label, " E=", opened_threat, " first_ot=", first_ot if not first_ot.is_empty() else "无",
		" final_primary=", primary.threat, " final_companion=", companion.threat)


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


# ── S1a：本批仅新增待测试执行的夹具，不在实现阶段运行引擎 ──
## 从 Resource 源生成每次独立的可注错样本，不修改加载缓存或正式目录。
func _s1a_sources() -> Dictionary:
	var skills: Array = []
	var loadouts: Array = []
	for path: String in BattleConfig.SKILL_PATHS:
		var source: Resource = load(path)
		skills.append(source.duplicate(true) if source != null else null)
	for path: String in BattleConfig.LOADOUT_PATHS:
		var source: Resource = load(path)
		loadouts.append(source.duplicate(true) if source != null else null)
	return {"skills": skills, "loadouts": loadouts}


## 校验坏源必须拒绝整个目录，且给出含 ID 和字段名的诊断。
func _s1a_bad_catalog(label: String, sources: Dictionary, expected: String) -> void:
	var catalog := BattleConfig.build_skill_catalog(sources["skills"], sources["loadouts"])
	var detail := "; ".join(catalog["problems"])
	_check("S1a配置拒绝：" + label, not catalog["problems"].is_empty() and catalog["skills"].is_empty() and catalog["loadouts"].is_empty() and detail.contains(expected), detail)


## 覆盖目录引用、缺字段哨兵及效果组合，不运行任何施法或数值结算。
func _s1a_config_cases() -> void:
	var catalog := BattleConfig.load_skill_catalog()
	_check("S1a五技能和两专精全部通过严格校验", catalog["problems"].is_empty() and catalog["skills"].size() == 5 and catalog["loadouts"].size() == 2, "; ".join(catalog["problems"]))
	if not catalog["problems"].is_empty():
		return
	# 真实序列化负例使用仓外临时源，合法目录先通过才有意义。
	_s1a_effect_resource_cases()
	var priest := BattleConfig.resolve_spec(catalog, "priest.holy")
	_check("S1a牧师Q存在而WER是三个明确空槽", not priest["slots"]["q"].is_empty() and priest["slots"]["w"].is_empty() and priest["slots"]["e"].is_empty() and priest["slots"]["r"].is_empty())
	var a := BattleConfig.resolve_spec(catalog, "mage.fire")
	var b := BattleConfig.resolve_spec(catalog, "mage.fire")
	a["slots"]["q"]["mana_cost"] = 99.0
	a["slots"]["q"]["effects"][0]["radius_m"] = 99.0
	_check("S1a角色参数与嵌套效果相互独立且不改基础目录", b["slots"]["q"]["mana_cost"] == 25.0 and b["slots"]["q"]["effects"][0]["radius_m"] == 2.0 and catalog["skills"]["mage.fire.flame_burst"]["effects"][0]["radius_m"] == 2.0)
	var sources := _s1a_sources()
	sources["skills"].append(sources["skills"][0].duplicate(true))
	_s1a_bad_catalog("重复技能ID", sources, "mage.fire.flame_burst.skill_id")
	sources = _s1a_sources()
	sources["loadouts"].append(sources["loadouts"][0].duplicate(true))
	_s1a_bad_catalog("重复专精ID", sources, "mage.fire.spec_id")
	for entry: Array in [["缺引用", "mage.fire.missing"], ["跨专精引用", "priest.holy.greater_heal"], ["槽内重复", "mage.fire.fireball"]]:
		sources = _s1a_sources()
		sources["loadouts"][0].slots[0] = entry[1]
		_s1a_bad_catalog(entry[0], sources, "mage.fire.slots[0]" if entry[0] != "槽内重复" else "mage.fire.slots[1]")
	sources = _s1a_sources()
	sources["loadouts"][1].slots.clear()
	_s1a_bad_catalog("缺四槽数组", sources, "priest.holy.slots")
	sources = _s1a_sources()
	sources["skills"][0].spec_id = "mage.unknown"
	_s1a_bad_catalog("非法专精", sources, "mage.fire.flame_burst.spec_id")
	sources = _s1a_sources()
	sources["skills"][0].mana_cost = -1.0
	_s1a_bad_catalog("Resource负消耗", sources, "mage.fire.flame_burst.mana_cost")
	sources = _s1a_sources()
	sources["skills"][0].effects.clear()
	_s1a_bad_catalog("缺失效果", sources, "mage.fire.flame_burst.effects")
	# 新建不赋数值/图标的源，验证类型导出默认值不能变成有效零或占位图。
	sources = _s1a_sources()
	var missing := BattleConfig.SkillDef.new()
	missing.skill_id = "mage.fire.flame_burst"
	missing.spec_id = "mage.fire"
	missing.name = "缺字段夹具"
	missing.target_kind = "ENEMY"
	missing.effects = sources["skills"][0].effects.duplicate(true)
	sources["skills"][0] = missing
	_s1a_bad_catalog("数值默认哨兵", sources, "mage.fire.flame_burst.mana_cost")
	_s1a_bad_catalog("未声明可空图标", sources, "mage.fire.flame_burst.icon")
	# 未赋布尔字段的效果，其余字段齐全；false 默认值不能掩盖漏填。
	sources = _s1a_sources()
	var missing_flags := BattleConfig.SkillEffectDef.new()
	missing_flags.kind = "MAGIC_DAMAGE"
	missing_flags.selector = "ENEMIES_AROUND_PRIMARY"
	missing_flags.power_coeff = 1.7
	missing_flags.flat_amount = 0.0
	missing_flags.radius_m = 2.0
	missing_flags.duration_s = 0.0
	sources["skills"][0].effects[0] = missing_flags
	_s1a_bad_catalog("缺显式布尔值", sources, "mage.fire.flame_burst.effects[0].uses_mastery")
	# 每个数值字段都覆盖负数/NaN/无穷/缺失，确认不是只校验 mana_cost。
	for field: String in ["cast_range_m", "mana_cost", "cooldown_s", "power_coeff", "flat_amount", "radius_m", "duration_s"]:
		for invalid: Variant in [-1.0, NAN, INF, null]:
			var data: Dictionary = catalog["skills"]["mage.fire.flame_burst"].duplicate(true)
			var owner: Dictionary = data if field in ["cast_range_m", "mana_cost", "cooldown_s"] else data["effects"][0]
			if invalid == null:
				owner.erase(field)
			else:
				owner[field] = invalid
			var errors := BattleConfig.validate_resolved_skill(data)
			_check("S1a坏数值拦截 %s=%s" % [field, str(invalid)], not errors.is_empty() and "; ".join(errors).contains(field), "; ".join(errors))
	for entry: Array in [["mage.fire.flame_burst", "selector", "ENEMIES_IN_LOCKED_AREA"], ["mage.fire.flame_burst", "selector", "SELF"], ["mage.fire.flame_burst", "radius_m", 0.0], ["mage.fire.flame_barrier", "duration_s", 0.0], ["mage.fire.fireball", "duration_s", 1.0], ["mage.fire.fireball", "radius_m", 2.0], ["mage.fire.fireball", "flat_amount", 1.0], ["mage.fire.evocation", "uses_mastery", true], ["mage.fire.evocation", "power_coeff", 1.0]]:
		var data: Dictionary = catalog["skills"][entry[0]].duplicate(true)
		data["effects"][0][entry[1]] = entry[2]
		var errors := BattleConfig.validate_resolved_skill(data)
		_check("S1a非法效果组合 %s.%s" % [entry[0], entry[1]], not errors.is_empty() and "; ".join(errors).contains(entry[1]), "; ".join(errors))
	var self_range: Dictionary = catalog["skills"]["mage.fire.evocation"].duplicate(true)
	self_range["cast_range_m"] = 8.0
	_check("S1a自身技能射程必须为零", not BattleConfig.validate_resolved_skill(self_range).is_empty())


## 将坏效果写成临时 tres 并经生产入口加载校验；不能绕过强类型加载边界或在夹具中补造诊断。
func _s1a_effect_resource_cases() -> void:
	var template: String = FileAccess.get_file_as_string(BattleConfig.SKILL_PATHS[0])
	var original := 'effects = Array[ExtResource("2_effect")]([SubResource("Effect_1")])'
	_check("R1序列化夹具来源是正式强类型声明", template.contains(original))
	if not template.contains(original):
		return
	# 仅使用显式授权且属于当前运行副本的 QA 目录；没有系统临时目录回退。
	var directory: String = _s1a_fixture_directory_from_args()
	if directory.is_empty():
		return
	var unique: bool = not DirAccess.dir_exists_absolute(directory) and not FileAccess.file_exists(directory)
	_check("R1临时目录不可复用已有路径", unique, directory)
	if not unique:
		return
	var error: Error = DirAccess.make_dir_absolute(directory)
	_check("R1建立测试专用临时目录", error == OK, "%s (%s)" % [directory, error_string(error)])
	if error != OK:
		return
	_s1a_fixture_directory = directory
	print("R1_EFFECT_FIXTURES: ", directory)
	# 合法对照与坏源都走正式加载入口；仅复制路径表并替换第一项，不修改正式路径表或资源。
	var control_path: String = directory.path_join("control.tres")
	if not _s1a_write_effect_fixture(control_path, template):
		return
	var skill_paths: Array = BattleConfig.SKILL_PATHS.duplicate()
	skill_paths[0] = control_path
	var control_catalog: Dictionary = BattleConfig.load_skill_catalog(skill_paths)
	var control_skill: Dictionary = control_catalog["skills"].get("mage.fire.flame_burst", {})
	var control_ok: bool = control_catalog["problems"].is_empty() and control_catalog["skills"].size() == 5 and control_catalog["loadouts"].size() == 2
	if control_ok:
		control_ok = control_skill["effects"].size() == 1 and control_skill["effects"][0] is Dictionary
	_check("R1同路径合法对照完整加载且目录通过", control_ok, control_path + ": " + "; ".join(control_catalog["problems"]))
	if not control_ok:
		return
	# 导出使用二进制资源，显式 false 往返后仍须与漏填的空哨兵区分。
	var source: Resource = ResourceLoader.load(control_path)
	var binary_path := directory.path_join("control_binary.res")
	var saved := ResourceSaver.save(source, binary_path)
	var binary: Resource = ResourceLoader.load(binary_path) if saved == OK else null
	var preserves_flags: bool = binary is BattleConfig.SkillDef and binary.effects.size() == 1
	if preserves_flags:
		var saved_effect: Resource = binary.effects[0]
		preserves_flags = saved_effect.uses_stable_crit == true and saved_effect.uses_mastery == false
	_check("二进制资源往返保留显式 true 和 false", preserves_flags, error_string(saved))
	# 普通 Resource、挂错脚本的 Resource 和 null，均测试单独及与合法效果混合的列表。
	for wrong_kind: String in ["plain", "wrong_script", "null"]:
		for mixed: bool in [false, true]:
			var label: String = wrong_kind + ("_mixed" if mixed else "_only")
			var path: String = directory.path_join(label + ".tres")
			var text: String = template
			var wrong_ref: String = "null"
			if wrong_kind != "null":
				var extra: String = '[sub_resource type="Resource" id="WrongEffect"]\n'
				if wrong_kind == "wrong_script":
					# 复用已有 SkillDef 脚本作为错误类型，不新增脚本、全局类或仓库资源。
					extra += 'script = ExtResource("1_skill")\n'
				else:
					extra += 'resource_name = "R1 plain Resource"\n'
				text = text.replace("load_steps=4", "load_steps=5")
				text = text.replace("[resource]\n", extra + "\n[resource]\n")
				wrong_ref = 'SubResource("WrongEffect")'
			var entries: String = 'SubResource("Effect_1"), ' + wrong_ref if mixed else wrong_ref
			text = text.replace(original, 'effects = Array[ExtResource("2_effect")]([' + entries + '])')
			if not _s1a_write_effect_fixture(path, text):
				continue
			# 不先独立加载或直接调 build；由生产入口完成读取、目录拒绝及真实路径诊断。
			skill_paths[0] = path
			var rejected: Dictionary = BattleConfig.load_skill_catalog(skill_paths)
			var detail: String = "; ".join(rejected["problems"])
			_check("R1序列化坏效果整个目录拒绝 " + label, not rejected["problems"].is_empty() and rejected["skills"].is_empty() and rejected["loadouts"].is_empty(), path + ": " + detail)
			var bad_index: int = 1 if mixed else 0
			var indexed_field: String = "mage.fire.flame_burst.effects[%d]:" % bad_index
			var lost_effects: String = "%s -> mage.fire.flame_burst.effects: 加载后效果列表为空，无法恢复元素下标" % path
			var failed_source: String = "%s.resource: 加载失败" % path
			# null 元素可保留下标，不能退化为整表丢失；其他强类型截断必须由生产结果同时给路径、ID、effects。
			var located: bool = detail.contains(indexed_field) or detail.contains(failed_source)
			if wrong_kind != "null":
				located = located or detail.contains(lost_effects)
			_check("R1坏效果诊断保留下标或明确加载边界 " + label, located, detail)
			if detail.contains("skills[0].resource:"):
				# 源失败无法承诺内部技能 ID；实际路径必须来自生产结果，不能只检查 null 或数组下标。
				_check("R1加载失败须由生产目录诊断保留源路径 " + label, detail.contains(failed_source), detail)


## 只接受显式 QA 根及其全新直接子目录；校验当前副本位置和路径各层，拒绝符号链接逃逸。
func _s1a_fixture_directory_from_args() -> String:
	var qa_root: String = ""
	var directory: String = ""
	var root_count: int = 0
	var directory_count: int = 0
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--s1a-qa-root="):
			qa_root = argument.trim_prefix("--s1a-qa-root=")
			root_count += 1
		elif argument.begins_with("--s1a-fixture-dir="):
			directory = argument.trim_prefix("--s1a-fixture-dir=")
			directory_count += 1
	var project_path: String = ProjectSettings.globalize_path("res://").trim_suffix("/")
	var valid: bool = root_count == 1 and directory_count == 1 and not qa_root.is_empty() and not directory.is_empty()
	valid = valid and qa_root == qa_root.simplify_path() and directory == directory.simplify_path()
	valid = valid and qa_root.get_base_dir() == "/private/tmp" and qa_root.get_file().begins_with("capytavern-s1a-qa-")
	valid = valid and project_path == qa_root.path_join("run/client") and DirAccess.dir_exists_absolute(qa_root)
	valid = valid and directory.get_base_dir() == qa_root and directory.get_file().begins_with("effect-fixtures-r3-")
	# 规范化字符串不能消除符号链接；逐层检查实际项目路径，目标目录也禁止复用或链接。
	if valid:
		var access: DirAccess = DirAccess.open("/")
		valid = access != null
		if valid:
			var component_path: String = ""
			for component: String in project_path.trim_prefix("/").split("/"):
				component_path += "/" + component
				if access.is_link(component_path):
					valid = false
			valid = valid and not access.is_link(directory)
	_check("R3显式夹具目录属于当前授权QA根且无符号链接", valid, "qa=" + qa_root + "; fixtures=" + directory + "; project=" + project_path)
	return directory if valid else ""


## 仅向已校验的新目录写全新夹具，检查错误并关闭句柄；拒绝覆盖，文件保留供复现。
func _s1a_write_effect_fixture(path: String, text: String) -> bool:
	var access: DirAccess = DirAccess.open("/")
	var allowed: bool = not _s1a_fixture_directory.is_empty() and path == path.simplify_path() and path.get_base_dir() == _s1a_fixture_directory and access != null
	if allowed:
		allowed = not access.is_link(_s1a_fixture_directory) and not access.is_link(path) and not FileAccess.file_exists(path) and not DirAccess.dir_exists_absolute(path)
	_check("R3夹具只写授权目录内新文件", allowed, path)
	if not allowed:
		return false
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_check("R1写入临时资源 " + path, false, error_string(FileAccess.get_open_error()))
		return false
	file.store_string(text)
	file.flush()
	var error: Error = file.get_error()
	file.close()
	_check("R1临时资源完整写入 " + path, error == OK, error_string(error))
	return error == OK


## 在旧战斗夹具上显式安装新槽位；不连接输入、不执行 step 或成功施法。
func _s1a_battle() -> Dictionary:
	var battle := _make(["mage", "priest", "mage", ""], 31)
	var sim: BattleSim = battle["sim"]
	var catalog := BattleConfig.load_skill_catalog()
	sim.skill_battle_id = "s1a_readonly"
	for entry: Array in [[0, "mage.fire"], [1, "priest.holy"], [2, "mage.fire"]]:
		var unit := sim.slot_unit(entry[0])
		var errors := sim.install_skill_loadout(unit.id, entry[1], catalog)
		_check("S1a安装独立副本 %d" % entry[0], errors.is_empty(), "; ".join(errors))
		unit.res = 100.0
		unit.res_max = 100.0
		unit.pos = Vector2.ZERO
	return battle


## 构造已绑定身份的准备请求；序号仅作为未消费的输入数据供断言。
func _s1a_request(sim: BattleSim, slot_index: int = 0, key: String = "Q") -> Dictionary:
	var unit := sim.slot_unit(slot_index)
	var skill: Dictionary = unit.resolved_slots.get(key.to_lower(), {})
	return {"battle_id": sim.skill_battle_id, "request_seq": 17, "caster_id": unit.id, "slot": key, "expected_skill_id": skill.get("skill_id", "")}


## 捕获所有模拟/Unit/事件字段；包含未来队列字段，以免只比较少数已知状态。
func _s1a_state(sim: BattleSim) -> Dictionary:
	var state: Dictionary = {}
	for property: Dictionary in sim.get_property_list():
		if (int(property["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0:
			continue
		var key: String = property["name"]
		if key in ["units", "events", "rng"]:
			continue
		var value: Variant = sim.get(key)
		state[key] = value.duplicate(true) if value is Dictionary or value is Array else value
	var unit_states: Dictionary = {}
	for id: int in sim.units:
		var unit: BattleSim.Unit = sim.units[id]
		var fields: Dictionary = {}
		for property: Dictionary in unit.get_property_list():
			if (int(property["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0:
				continue
			var value: Variant = unit.get(property["name"])
			fields[property["name"]] = value.duplicate(true) if value is Dictionary or value is Array else value
		unit_states[id] = fields
	state["units"] = unit_states
	state["rng_state"] = sim.rng.state
	state["event_lines"] = sim.events.lines.duplicate()
	state["event_now"] = sim.events.now
	return state


## 精确递归比较完整快照；同类型浮点 NaN 视为未变，其余值不取整、不转字符串、不做近似比较。
func _s1a_same_state(left: Variant, right: Variant) -> bool:
	if typeof(left) != typeof(right):
		return false
	if left is float:
		return (is_nan(left) and is_nan(right)) or left == right
	if left is Dictionary:
		if not left.is_same_typed(right) or left.size() != right.size():
			return false
		var right_keys: Array = right.keys()
		for key: Variant in left:
			if not right.has(key):
				return false
			# 字典可能将数值相同的 int/float 键视为相等，快照仍须识别键类型变化。
			if not _s1a_same_state(key, right_keys[right_keys.find(key)]) or not _s1a_same_state(left[key], right[key]):
				return false
		return true
	if left is Array:
		if not left.is_same_typed(right) or left.size() != right.size():
			return false
		for i in left.size():
			if not _s1a_same_state(left[i], right[i]):
				return false
		return true
	return left == right


## 连查三次同一序号，按类型精确比对整个状态与请求；通过也只允许内部准备标记。
func _s1a_expect(sim: BattleSim, request: Dictionary, expected: String) -> Dictionary:
	var before := _s1a_state(sim)
	var original := request.duplicate(true)
	var prepared: Dictionary = {}
	for _i in 3:
		prepared = sim._prepare_skill(request)
		_check("S1a预检优先级 " + expected, prepared.get("reason") == expected and prepared.get("preparable") == expected.is_empty(), str(prepared))
	_check("S1a反复纯查询不改全状态/事件/请求 " + expected, _s1a_same_state(_s1a_state(sim), before) and _s1a_same_state(request, original))
	_check("S1a准备不是成功施法结果", not prepared.has("accepted") and not prepared.has("cast_id"))
	return prepared


## 多错并存时逐层解除，验证规格优先级；未触发提交、队列消费或旧代选。
func _s1a_prepare_cases() -> void:
	# 比较器必须容纳原样 NaN，同时仍检出类型、精度、事件列表及请求字段变化。
	_check("R3嵌套NaN精确比较", _s1a_same_state({"values": [NAN, INF, 1.0]}, {"values": [NAN, INF, 1.0]}))
	_check("R3比较不掩盖状态变化", not _s1a_same_state([NAN], [0.0]) and not _s1a_same_state([1], [1.0]) and not _s1a_same_state([1.0], [1.0 + 0.000000000001]) and not _s1a_same_state({"events": []}, {"events": ["added"]}) and not _s1a_same_state({"request_seq": 17}, {"request_seq": 18}))
	var battle := _s1a_battle()
	var sim: BattleSim = battle["sim"]
	var mage := sim.slot_unit(0)
	var priest := sim.slot_unit(1)
	var enemies := sim.living("enemy")
	var target: BattleSim.Unit = enemies[0]
	mage.target_id = target.id
	target.pos = Vector2(801, 0)
	mage.res = 0.0
	mage.gcd_until = 2.0
	mage.skill_ready_at["mage.fire.flame_burst"] = 3.0
	mage.alive = false
	sim.paused = true
	sim.skill_input_locked = true
	var request := _s1a_request(sim)
	request["battle_id"] = "old_battle"
	_s1a_expect(sim, request, "STALE_BATTLE")
	request["battle_id"] = sim.skill_battle_id
	_s1a_expect(sim, request, "BATTLE_PAUSED")
	sim.paused = false
	_s1a_expect(sim, request, "INPUT_LOCKED")
	sim.skill_input_locked = false
	sim.finished = true
	_s1a_expect(sim, request, "INPUT_LOCKED")
	sim.finished = false
	var bad_caster := request.duplicate(true)
	bad_caster["caster_id"] = -999
	_s1a_expect(sim, bad_caster, "NO_CASTER")
	bad_caster["caster_id"] = target.id
	_s1a_expect(sim, bad_caster, "NO_CASTER")
	mage.controllable = false
	_s1a_expect(sim, request, "NO_CASTER")
	mage.controllable = true
	_s1a_expect(sim, request, "CASTER_DOWN")
	mage.alive = true
	for key: String in ["W", "E", "R"]:
		_s1a_expect(sim, _s1a_request(sim, 1, key), "EMPTY_SLOT")
	var changed := request.duplicate(true)
	changed["expected_skill_id"] = "mage.fire.fireball"
	_s1a_expect(sim, changed, "SKILL_CHANGED")
	mage.spec_id = "priest.holy"
	_s1a_expect(sim, request, "SKILL_CHANGED")
	mage.spec_id = "mage.fire"
	for invalid_target: int in [-999, priest.id, target.id]:
		mage.target_id = invalid_target
		if invalid_target == target.id:
			target.alive = false
		_s1a_expect(sim, request, "INVALID_TARGET")
	target.alive = true
	mage.target_id = target.id
	target.selectable = false
	_s1a_expect(sim, request, "INVALID_TARGET")
	target.selectable = true
	_s1a_expect(sim, request, "OUT_OF_RANGE")
	target.pos = Vector2(800, 0)
	_s1a_expect(sim, request, "NOT_ENOUGH_MANA")
	mage.res = 24.999
	_s1a_expect(sim, request, "NOT_ENOUGH_MANA")
	mage.res = 25.0
	_s1a_expect(sim, request, "GCD_ACTIVE")
	sim.time = 2.0
	_s1a_expect(sim, request, "SKILL_COOLDOWN")
	sim.time = 3.0
	_s1a_expect(sim, request, "")
	# 无目标也不代选；SELF 忽略外部目标；牧师对敌目标失败，满血/自身合法。
	mage.target_id = -1
	_s1a_expect(sim, request, "INVALID_TARGET")
	_s1a_expect(sim, _s1a_request(sim, 0, "E"), "")
	_s1a_expect(sim, _s1a_request(sim, 0, "R"), "")
	priest.target_id = target.id
	_s1a_expect(sim, _s1a_request(sim, 1), "INVALID_TARGET")
	priest.target_id = mage.id
	_s1a_expect(sim, _s1a_request(sim, 1), "")
	priest.target_id = priest.id
	_s1a_expect(sim, _s1a_request(sim, 1), "")
	# 新参数副本和 CD 为角色独立状态，规则不触碰仍供旧入口使用的 skills/cd_until。
	var second_mage := sim.slot_unit(2)
	mage.resolved_slots["q"]["effects"][0]["radius_m"] = 1.0
	_check("S1a两个角色效果副本独立", second_mage.resolved_slots["q"]["effects"][0]["radius_m"] == 2.0)
	_check("S1a新旧技能目录/冷却隔离", mage.skills["q"]["id"] == "fire_burst" and mage.cd_until.is_empty() and second_mage.skill_ready_at.is_empty())
	mage.resolved_slots["q"]["effects"][0]["radius_m"] = NAN
	_s1a_expect(sim, request, "CONFIG_ERROR")
	_s1a_snapshot_cases()


## 精确中心距离、主目标优先、稳定排序与无效目标过滤；预检返回的副本也不能回写状态。
func _s1a_snapshot_cases() -> void:
	var battle := _s1a_battle()
	var sim: BattleSim = battle["sim"]
	var mage := sim.slot_unit(0)
	var enemies := sim.living("enemy")
	var primary: BattleSim.Unit = enemies[2]
	primary.pos = Vector2(800, 0)
	mage.target_id = primary.id
	enemies[0].pos = Vector2(1000, 0)
	enemies[1].pos = Vector2(1001, 0)
	enemies[3].pos = Vector2(800, 0)
	enemies[3].selectable = false
	var request := _s1a_request(sim)
	var prepared := _s1a_expect(sim, request, "")
	_check("S1a主目标8米/次目标2米包含且次目标可超施法射程", prepared["effect_targets"][0] == [primary.id, enemies[0].id])
	enemies[1].pos = Vector2(800, 200)
	prepared = _s1a_expect(sim, request, "")
	_check("S1a主目标先且其余按稳定ID排序不重复", prepared["effect_targets"][0] == [primary.id, enemies[0].id, enemies[1].id])
	enemies[0].alive = false
	prepared = _s1a_expect(sim, request, "")
	_check("S1a倒下/不可选/友方排除范围快照", prepared["effect_targets"][0] == [primary.id, enemies[1].id])
	prepared["skill"]["effects"][0]["radius_m"] = 999.0
	prepared["effect_targets"][0].append(-999)
	_check("S1a预检返回参数和名单均不回写角色", mage.resolved_slots["q"]["effects"][0]["radius_m"] == 2.0 and sim._prepare_skill(request)["effect_targets"][0] == [primary.id, enemies[1].id])


## 复用现有造场/Resource；冻结旧自动攻击而保留周期调用，避免夹具冒充正式数值验证。
func _s1b_battle() -> Dictionary:
	var battle := _s1a_battle()
	var sim: BattleSim = battle["sim"]
	sim._begin_skill_schedule()
	sim.config["time_limit"] = 10000.0
	var enemies := sim.living("enemy")
	for i in enemies.size():
		var enemy: BattleSim.Unit = enemies[i]
		enemy.pos = Vector2(600 + i * 100, 300)
		enemy.speed = 0.0
		enemy.attack_range = 0.0
		enemy.spell = {}
	for i in 3:
		var unit := sim.slot_unit(i)
		unit.pos = Vector2(200 + i * 100, 300)
		unit.speed = 0.0
		unit.res_regen = 0.0
		unit.order_kind = "attack"
		unit.target_id = enemies[0].id
		unit.attack_range = 2000.0
		unit.next_attack_at = 1000000.0
	return battle


## 只比较相同战斗时间的业务状态；场身份应不同，普通帧浮点余量另做误差/守恒检查。
func _s1b_same_run(left: BattleSim, right: BattleSim) -> bool:
	var a := _s1a_state(left)
	var b := _s1a_state(right)
	for key in ["skill_battle_id", "_skill_accumulator"]:
		a.erase(key)
		b.erase(key)
	return _s1a_same_state(a, b) and absf(left._skill_accumulator - right._skill_accumulator) < 0.000000000001


## 按类别组织有意义的调度夹具；无成功施法、无外部时间源或新回调注入服务。
func _s1b_schedule_cases() -> void:
	_s1b_clock_cases()
	_s1b_queue_cases()
	_s1b_lifecycle_cases()
	_s1b_callback_cases()


## 比较相同步数、不同帧切片、余量守恒及截止边界；回蓝仅用显式夹具值验证先后顺序。
func _s1b_clock_cases() -> void:
	var one: BattleSim = _s1b_battle()["sim"]
	var two: BattleSim = _s1b_battle()["sim"]
	var sliced: BattleSim = _s1b_battle()["sim"]
	var uneven: BattleSim = _s1b_battle()["sim"]
	for sim: BattleSim in [one, two, sliced, uneven]:
		var mage := sim.slot_unit(0)
		mage.res = 10.0
		mage.res_regen = 6.0
		mage.statuses["qa_clock"] = {"until": 0.1 + 0.2, "source": mage.id}
		sim._enqueue_skill_command("prepare", _s1a_request(sim, 0, "R"))
	one._advance_skill_schedule(1.0)
	two._advance_skill_schedule(0.5, 2)
	for _i in 60:
		sliced._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
	for frame_dt in [0.001, 0.217, 0.003, 0.279, 0.5]:
		uneven._advance_skill_schedule(frame_dt)
	_check("S1b1x/2x同战斗时间状态与事件一致", one._skill_tick == 60 and two.time == 1.0 and _s1b_same_run(one, two))
	_check("S1b单大帧/60小帧/不等帧不截断累计", _s1b_same_run(one, sliced) and _s1b_same_run(one, uneven))
	_check("S1b周期每步固定长度", is_equal_approx(one.slot_unit(0).res, 16.0) and one.slot_unit(0).statuses.is_empty())
	var sim: BattleSim = _s1b_battle()["sim"]
	var mage := sim.slot_unit(0)
	sim._advance_skill_schedule(0.01)
	_check("S1b不足一步不提前执行", sim._skill_tick == 0 and sim.time == 0.0 and is_equal_approx(sim._skill_accumulator, 0.01))
	sim._advance_skill_schedule(0.01)
	_check("S1b普通帧余量守恒", sim._skill_tick == 1 and absf(sim.time + sim._skill_accumulator - 0.02) < 0.000000000001)
	var before := _s1a_state(sim)
	for bad_dt in [-1.0, NAN, INF]:
		sim._advance_skill_schedule(bad_dt)
	sim._advance_skill_schedule(1.0, 3)
	_check("S1b非法时间/倍速无状态变化", _s1a_same_state(before, _s1a_state(sim)))
	# 截止在 0.3 的二进制浮点噪声不多等一帧；真正位于两点之间的 CD 要等下点。
	sim = _s1b_battle()["sim"]
	mage = sim.slot_unit(0)
	mage.gcd_until = 0.1 + 0.2
	mage.skill_ready_at["mage.fire.evocation"] = 0.305
	mage.statuses["qa_clock"] = {"until": 0.1 + 0.2, "source": mage.id}
	sim._advance_skill_schedule(17.0 / 60.0)
	_s1a_expect(sim, _s1a_request(sim, 0, "R"), "GCD_ACTIVE")
	_check("S1b到期前一步状态仍在", mage.statuses.has("qa_clock"))
	sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
	_s1a_expect(sim, _s1a_request(sim, 0, "R"), "SKILL_COOLDOWN")
	_check("S1b同刻截止先到期且无浮点多等一步", sim._skill_tick == 18 and not mage.statuses.has("qa_clock"))
	sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
	_s1a_expect(sim, _s1a_request(sim, 0, "R"), "")
	# 资源低于费用，先自然恢复到费用再准备；没有技能提交与扣费。
	sim = _s1b_battle()["sim"]
	mage = sim.slot_unit(0)
	mage.res = 24.0
	mage.res_regen = 60.0
	sim._enqueue_skill_command("prepare", _s1a_request(sim))
	var inspected := sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
	_check("S1b全员自然恢复先于命令准备", inspected.size() == 1 and inspected[0]["preparation"]["preparable"] and mage.res == 25.0)
	_check("S1b准备不写费用/GCD/CD或成功事件", mage.gcd_until == 0.0 and mage.skill_ready_at.is_empty() and _count(sim.events, "skill_cast") == 0)


## 验证集合去重、五字段快照、统一顺序、非法形状和失败无业务副作用。
func _s1b_queue_cases() -> void:
	var sim: BattleSim = _s1b_battle()["sim"]
	var mage := sim.slot_unit(0)
	var request := _s1a_request(sim, 0, "R")
	request["request_seq"] = 99
	_check("S1b首次高序号入队", sim._enqueue_skill_command("prepare", request)["queued"])
	request["request_seq"] = 3
	_check("S1b未见低序号仍入队", sim._enqueue_skill_command("prepare", request)["queued"])
	_check("S1b执行前重复即丢弃", sim._enqueue_skill_command("prepare", request)["reason"] == "DUPLICATE_REQUEST")
	# 入队后改写外部字典，不得污染内部的五字段请求；不添加额外协议字段。
	request["slot"] = "Q"
	request["expected_skill_id"] = "tampered"
	request["caster_id"] = -99
	var inspected := sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
	_check("S1b接收深拷贝且乱序两个请求均准备", inspected.size() == 2 and inspected[0]["preparation"]["preparable"] and inspected[1]["preparation"]["preparable"] and inspected[0]["receive_seq"] == 1 and inspected[1]["receive_seq"] == 2)
	request = _s1a_request(sim, 0, "R")
	request["request_seq"] = 101
	request["slot"] = "?"
	var before := _s1a_state(sim)
	sim._enqueue_skill_command("prepare", request)
	inspected = sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
	_check("S1b失败仅返回内部拒绝", inspected.size() == 1 and inspected[0]["preparation"]["reason"] == "EMPTY_SLOT" and not inspected[0]["preparation"].has("accepted") and not inspected[0]["preparation"].has("cast_id"))
	_check("S1b失败不改目标/普攻/费用/计时/事件", _s1a_same_state(before["units"], _s1a_state(sim)["units"]) and before["event_lines"] == sim.events.lines)
	request["slot"] = "R"
	_check("S1b失败后修正重投仍丢弃", sim._enqueue_skill_command("prepare", request)["reason"] == "DUPLICATE_REQUEST")
	before = _s1a_state(sim)
	for bad: Variant in [null, [], 9, {}, {"battle_id": sim.skill_battle_id, "caster_id": "1"}, {"battle_id": sim.skill_battle_id, "caster_id": mage.id, "request_seq": [], "slot": "R", "expected_skill_id": "mage.fire.evocation"}]:
		_check("S1b非法请求形状安全拒绝", sim._enqueue_skill_command("prepare", bad)["reason"] == "INVALID_REQUEST")
	_check("S1b非法种类和非有限坐标安全拒绝", sim._enqueue_skill_command([], {})["reason"] == "INVALID_REQUEST" and sim._enqueue_skill_command("move", {"battle_id": sim.skill_battle_id, "caster_id": mage.id, "pos": Vector2(NAN, 0)})["reason"] == "INVALID_REQUEST")
	_check("S1b非法形状不占去重/序号且全状态不变", _s1a_same_state(before, _s1a_state(sim)))
	# 移动也必须锁定接收时坐标，不能执行时回读外部可变字典。
	var expected_move := sim._arena.get_center()
	var move_command := {"battle_id": sim.skill_battle_id, "caster_id": mage.id, "pos": expected_move}
	sim._enqueue_skill_command("move", move_command)
	move_command["pos"] = Vector2(888, 888)
	sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
	_check("S1b移动接收快照不被外部改写", mage.order_pos == expected_move)
	# 同点：先准备读旧目标，设目标后准备读新目标，再移动清目标，最后准备失败。
	sim = _s1b_battle()["sim"]
	mage = sim.slot_unit(0)
	var enemies := sim.living("enemy")
	var old_target := mage.target_id
	request = _s1a_request(sim)
	sim._enqueue_skill_command("prepare", request)
	var target_command := {"battle_id": sim.skill_battle_id, "caster_id": mage.id, "target_id": enemies[1].id}
	sim._enqueue_skill_command("target", target_command)
	target_command["target_id"] = -999
	request["request_seq"] = 18
	sim._enqueue_skill_command("prepare", request)
	sim._enqueue_skill_command("move", {"battle_id": sim.skill_battle_id, "caster_id": mage.id, "pos": Vector2(300, 400)})
	request["request_seq"] = 19
	sim._enqueue_skill_command("prepare", request)
	# 队列和 seen 已有内容时，纯查询仍必须连同它们和 NaN 原样保全。
	_s1a_expect(sim, request, "")
	mage.resolved_slots["q"]["effects"][0]["radius_m"] = NAN
	_s1a_expect(sim, request, "CONFIG_ERROR")
	mage.resolved_slots["q"]["effects"][0]["radius_m"] = 2.0
	inspected = sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
	_check("S1b移动/目标/准备共用递增接收序号", inspected.size() == 5 and inspected[0]["receive_seq"] == 1 and inspected[1]["receive_seq"] == 2 and inspected[2]["receive_seq"] == 3 and inspected[3]["receive_seq"] == 4 and inspected[4]["receive_seq"] == 5)
	if inspected.size() == 5:
		_check("S1b同刻后项读取前项目标且快照不被改写", inspected[0]["preparation"].get("target_id") == old_target and inspected[2]["preparation"].get("target_id") == enemies[1].id and inspected[4]["preparation"]["reason"] == "INVALID_TARGET")
	_check("S1b准备通过也没有成功施法", mage.res == 100.0 and mage.gcd_until == 0.0 and mage.skill_ready_at.is_empty() and _count(sim.events, "skill_cast") == 0)
	# 同职业也独立维护旧有时钟；只读准备不会借某角色的时钟污染另一角色。
	mage.gcd_until = 2.0
	mage.skill_ready_at["mage.fire.evocation"] = 3.0
	var other := sim.slot_unit(2)
	other.gcd_until = 0.0
	_s1a_expect(sim, _s1a_request(sim, 0, "R"), "GCD_ACTIVE")
	_s1a_expect(sim, _s1a_request(sim, 2, "R"), "")
	_check("S1b不同角色已有时钟互不干扰", mage.gcd_until == 2.0 and mage.skill_ready_at["mage.fire.evocation"] == 3.0 and other.gcd_until == 0.0 and other.skill_ready_at.is_empty())


## 暂停/结束/离场丢弃战术输入，新场清调度状态且不接受旧身份污染新去重集合。
func _s1b_lifecycle_cases() -> void:
	var sim: BattleSim = _s1b_battle()["sim"]
	var mage := sim.slot_unit(0)
	var request := _s1a_request(sim, 0, "R")
	sim._enqueue_skill_command("prepare", request)
	sim._advance_skill_schedule(0.01)
	sim.set_paused(true)
	_check("S1b暂停即清队列和不足一步余量", sim._skill_pending.is_empty() and sim._skill_accumulator == 0.0 and sim._skill_tick == 0)
	var before := _s1a_state(sim)
	sim._advance_skill_schedule(120.0, 2)
	_check("S1b暂停时间/全状态精确冻结", _s1a_same_state(before, _s1a_state(sim)))
	request["request_seq"] = 18
	_check("S1b暂停技能不缓存", sim._enqueue_skill_command("prepare", request)["reason"] == "BATTLE_PAUSED" and sim._skill_pending.is_empty())
	_check("S1b暂停移动/目标不缓存", not sim._enqueue_skill_command("move", {"battle_id": sim.skill_battle_id, "caster_id": mage.id, "pos": mage.pos})["queued"] and not sim._enqueue_skill_command("target", {"battle_id": sim.skill_battle_id, "caster_id": mage.id, "target_id": mage.id})["queued"])
	sim.set_paused(false)
	sim._advance_skill_schedule(0.01)
	_check("S1b恢复不补发/不补暂停余量", sim._skill_tick == 0 and sim._skill_pending.is_empty())
	_check("S1b被暂停丢弃的已见请求不能复活", sim._enqueue_skill_command("prepare", request)["reason"] == "DUPLICATE_REQUEST")
	sim._advance_skill_schedule(0.01)
	_check("S1b恢复只计恢复后真实时间", sim._skill_tick == 1 and sim.time == BattleSim.SKILL_FIXED_STEP)
	var old_request := request.duplicate(true)
	request["request_seq"] = 19
	sim._enqueue_skill_command("prepare", request)
	sim._advance_skill_schedule(0.003)
	_check("S1b换场前确有队列/余量/去重待清", not sim._skill_pending.is_empty() and sim._skill_accumulator > 0.0 and not sim._skill_seen_requests.is_empty())
	var old_id := sim.skill_battle_id
	var new_id := sim._begin_skill_schedule()
	_check("S1b新场更换身份并重置全部调度状态", new_id != old_id and sim._skill_tick == 0 and sim.time == 0.0 and sim._skill_accumulator == 0.0 and sim._skill_receive_seq == 0 and sim._skill_pending.is_empty() and sim._skill_seen_requests.is_empty())
	_check("S1b旧场不污染本场去重", sim._enqueue_skill_command("prepare", old_request)["reason"] == "STALE_BATTLE" and sim._skill_seen_requests.is_empty())
	request["battle_id"] = new_id
	request["request_seq"] = old_request["request_seq"]
	_check("S1b新场可复用相同请求序号", sim._enqueue_skill_command("prepare", request)["queued"])
	sim._leave_skill_schedule()
	_check("S1b显式离场失效且清队列", sim.skill_battle_id.is_empty() and sim._skill_pending.is_empty() and sim._skill_accumulator == 0.0 and sim._enqueue_skill_command("prepare", request)["reason"] == "STALE_BATTLE")
	before = _s1a_state(sim)
	sim._advance_skill_schedule(1.0)
	_check("S1b离场后不能推进", _s1a_same_state(before, _s1a_state(sim)))
	# 周期胜负在本点命令之前结束；不能借未执行命令跨过结束边界。
	sim = _s1b_battle()["sim"]
	sim.config["time_limit"] = BattleSim.SKILL_FIXED_STEP
	sim._enqueue_skill_command("prepare", _s1a_request(sim, 0, "R"))
	var inspected := sim._advance_skill_schedule(1.0)
	_check("S1b自然结束清掉当点批次与累计量", sim.finished and sim._skill_tick == 1 and inspected.is_empty() and sim._skill_pending.is_empty() and sim._skill_accumulator == 0.0)
	_check("S1b结束后请求不执行", sim._enqueue_skill_command("prepare", _s1a_request(sim, 0, "R"))["reason"] == "DUPLICATE_REQUEST" and sim._advance_skill_schedule(1.0).is_empty())
	request = _s1a_request(sim, 0, "R")
	request["request_seq"] = 99
	_check("S1b结束后新请求锁定且不排队", sim._enqueue_skill_command("prepare", request)["reason"] == "INPUT_LOCKED" and sim._skill_pending.is_empty())
	# 未开启隔离调度的旧 step/暂停行为仍保持，不自动启用新队列。
	var legacy: BattleSim = _make(["mage", "", "", ""], 31)["sim"]
	legacy.step(0.037)
	_check("S1b旧step仍按原传入dt推进", legacy.time == 0.037 and not legacy._skill_schedule_active and legacy._skill_tick == 0)
	legacy.set_paused(true)
	before = _s1a_state(legacy)
	legacy.step(1.0)
	_check("S1b旧暂停路径仍冻结", _s1a_same_state(before, _s1a_state(legacy)))


## 用现有事件订阅检验回调命令延后一执行点，包含周期通知与同帧多点；不注入新调度接口。
func _s1b_callback_cases() -> void:
	var sim: BattleSim = _s1b_battle()["sim"]
	var mage := sim.slot_unit(0)
	var observation := {"calls": 0, "reentrant_empty": false}
	# 旧移动发布的同步通知里入队并尝试重入，不能在当前批次递归处理。
	var on_move := func(_id: int, _kind: String, _target_id: int, _pos: Vector2) -> void:
		observation["calls"] += 1
		sim._enqueue_skill_command("prepare", _s1a_request(sim, 0, "R"))
		observation["reentrant_empty"] = sim._advance_skill_schedule(10.0).is_empty()
	sim.events.command_issued.connect(on_move)
	sim._enqueue_skill_command("move", {"battle_id": sim.skill_battle_id, "caster_id": mage.id, "pos": Vector2(300, 400)})
	var inspected := sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
	_check("S1b命令回调入队不递归/不在同点追赶", inspected.size() == 1 and sim._skill_pending.size() == 1 and observation["calls"] == 1 and observation["reentrant_empty"] and sim._skill_tick == 1)
	inspected = sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
	_check("S1b回调请求在下一执行点准备", inspected.size() == 1 and inspected[0]["preparation"]["prepared_at"] == 2.0 * BattleSim.SKILL_FIXED_STEP)
	sim.events.command_issued.disconnect(on_move)
	# 周期回调发生在命令阶段之前，仍不能钻入已经截取的本点批次。
	sim = _s1b_battle()["sim"]
	mage = sim.slot_unit(0)
	mage.statuses["qa_callback"] = {"until": BattleSim.SKILL_FIXED_STEP, "source": mage.id}
	# 到期事件仅入队，不触发成功施法或修改生产信号。
	var on_expire := func(_id: int, _status: String, _source: int, _until: float) -> void:
		sim._enqueue_skill_command("prepare", _s1a_request(sim, 0, "R"))
	sim.events.status_expired.connect(on_expire)
	inspected = sim._advance_skill_schedule(2.0 * BattleSim.SKILL_FIXED_STEP)
	_check("S1b周期回调在同帧下一点而非当点执行", inspected.size() == 1 and inspected[0]["preparation"]["prepared_at"] == 2.0 * BattleSim.SKILL_FIXED_STEP)
	sim.events.status_expired.disconnect(on_expire)
	# 在同一个通知中暂停再恢复，暂停前批次也不能复活。
	sim = _s1b_battle()["sim"]
	mage = sim.slot_unit(0)
	var original_target := mage.target_id
	# 生命周期清理必须令已截取的局部批次失效，不只清公开待执行队列。
	var on_pause := func(_id: int, _kind: String, _target_id: int, _pos: Vector2) -> void:
		sim.set_paused(true)
		sim.set_paused(false)
	sim.events.command_issued.connect(on_pause)
	sim._enqueue_skill_command("move", {"battle_id": sim.skill_battle_id, "caster_id": mage.id, "pos": mage.pos})
	sim._enqueue_skill_command("target", {"battle_id": sim.skill_battle_id, "caster_id": mage.id, "target_id": sim.slot_unit(2).id})
	inspected = sim._advance_skill_schedule(1.0)
	_check("S1b回调暂停再恢复仍丢弃原批次", inspected.size() == 1 and sim._skill_tick == 1 and mage.target_id == -1 and mage.target_id != original_target and sim._skill_pending.is_empty() and sim._skill_accumulator == 0.0)
	sim.events.command_issued.disconnect(on_pause)

	# 离场发生在命令通知中时，本点剩余局部命令也失效。
	sim = _s1b_battle()["sim"]
	mage = sim.slot_unit(0)
	# 只调用既有隔离生命周期，不额外注入生产回调或新事件。
	var on_leave := func(_id: int, _kind: String, _target_id: int, _pos: Vector2) -> void:
		sim._leave_skill_schedule()
	sim.events.command_issued.connect(on_leave)
	sim._enqueue_skill_command("move", {"battle_id": sim.skill_battle_id, "caster_id": mage.id, "pos": mage.pos})
	sim._enqueue_skill_command("prepare", _s1a_request(sim, 0, "R"))
	inspected = sim._advance_skill_schedule(1.0)
	_check("S1b回调离场清除局部批次与后续点", inspected.size() == 1 and sim._skill_tick == 1 and sim.skill_battle_id.is_empty() and sim._skill_pending.is_empty())
	sim.events.command_issued.disconnect(on_leave)


## 为全部参与友方提供显式评级；调用方可修改该输入，验证安装副本与错误原子性。
func _s1b2_stats(sim: BattleSim, spirit: float = 100.0, rating: float = 1000.0) -> Dictionary:
	var stats: Dictionary = {}
	for i in 3:
		stats[sim.slot_unit(i).id] = {"spirit": spirit, "haste_rating": rating}
	return stats


## 复用已验造场后显式启用事务；每份场均独立，不能借旧res_regen作为输入默认值。
func _s1b2_battle() -> BattleSim:
	var sim: BattleSim = _s1b_battle()["sim"]
	var problems := sim._enable_skill_transactions(_s1b2_stats(sim))
	_check("S1b2显式启用全部友方", problems.is_empty(), str(problems))
	return sim


## 从正式五字段请求构造独立序号，不创建公共施法入口或额外请求字段。
func _s1b2_request(sim: BattleSim, seq: int, index: int = 0, key: String = "R") -> Dictionary:
	var request := _s1a_request(sim, index, key)
	request["request_seq"] = seq
	return request


## 真正经队列与固定点执行；结果取自执行记录，未执行不能伪造成功或诊断。
func _s1b2_cast(sim: BattleSim, seq: int, index: int = 0, key: String = "R") -> Dictionary:
	var queued := sim._enqueue_skill_command("cast", _s1b2_request(sim, seq, index, key))
	_check("S1b2事务请求入队", queued.get("queued", false), str(queued))
	var records := sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
	_check("S1b2固定点产生一次事务记录", records.size() == 1, str(records))
	return records[0].get("result", {}) if records.size() == 1 else {}


## 只读取结果事件，旧事件仍由原SCHEMA及回归约束，不把周期事件当作施法事件。
func _s1b2_results(sim: BattleSim) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	for line: String in sim.events.lines:
		var record: Dictionary = JSON.parse_string(line)
		if record["e"] == "cast_resolved":
			results.append(record["result"])
	return results


## 比较每个Unit，只有施法者法力与双钟可变；其他角色、目标及普攻字段须逐项保全。
func _s1b2_units_unchanged(before: Dictionary, after: Dictionary, caster_id: int) -> bool:
	var a: Dictionary = before["units"].duplicate(true)
	var b: Dictionary = after["units"].duplicate(true)
	for key in ["res", "gcd_until", "skill_ready_at"]:
		a[caster_id].erase(key)
		b[caster_id].erase(key)
	return _s1a_same_state(a, b)


## 使用现有入口按职责验证完整事务，保留全部S1a/S1b-1及49条旧断言。
func _s1b2_transaction_cases() -> void:
	_s1b2_install_cases()
	_s1b2_success_cases()
	_s1b2_clock_cases()
	_s1b2_failure_cases()
	_s1b2_callback_cases()
	_s1b2_guard_cases()
	_s1b2_business_failure_cases()
	_s1b2_end_callback_case()


## 检验缺失/错型/负数/NaN以及参与职业，失败只停场，不先安装一部分角色。
func _s1b2_install_cases() -> void:
	for bad: Variant in [null, {}, {"spirit": 1.0}, {"spirit": "100", "haste_rating": 0.0}, {"spirit": true, "haste_rating": 0.0}, {"spirit": -1.0, "haste_rating": 0.0}, {"spirit": NAN, "haste_rating": 0.0}, {"spirit": 0.0, "haste_rating": INF}, {"spirit": 0.0, "haste_rating": NAN}, {"spirit": 0.0, "haste_rating": true}, {"spirit": 0.0, "haste_rating": -1.0}]:
		var sim: BattleSim = _s1b_battle()["sim"]
		var stats := _s1b2_stats(sim)
		stats[sim.slot_unit(2).id] = bad
		var before := _s1a_state(sim)
		var problems := sim._enable_skill_transactions(stats)
		_check("S1b2非法评级拒绝且全部安装原子", not problems.is_empty() and sim.finished and sim.skill_input_locked and not sim._skill_transactions_enabled and _s1a_same_state(before["units"], _s1a_state(sim)["units"]), str(bad))
	var sim: BattleSim = _s1b_battle()["sim"]
	sim.slot_unit(1).kind = "warrior"
	_check("S1b2非支持职业拒绝启用", not sim._enable_skill_transactions(_s1b2_stats(sim)).is_empty() and sim.finished)
	sim = _s1b_battle()["sim"]
	var stats := _s1b2_stats(sim)
	var before := _s1a_state(sim)
	_check("S1b2合法安装不改初始法力上限双钟", sim._enable_skill_transactions(stats).is_empty() and sim.slot_unit(0).res == before["units"][sim.slot_unit(0).id]["res"] and sim.slot_unit(0).res_max == 100.0 and sim.slot_unit(0).gcd_until == 0.0 and sim.slot_unit(0).skill_ready_at.is_empty())
	stats[sim.slot_unit(0).id]["spirit"] = 999.0
	_check("S1b2安装评级副本不受外部改写", sim.slot_unit(0).combat_stats["spirit"] == 100.0 and sim.slot_unit(2).combat_stats["spirit"] == 100.0)
	for late: String in ["step", "queued"]:
		sim = _s1b_battle()["sim"]
		if late == "step":
			sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
		else:
			sim._enqueue_skill_command("prepare", _s1a_request(sim))
		_check("S1b2首步或入队后禁止启用 " + late, not sim._enable_skill_transactions(_s1b2_stats(sim)).is_empty() and sim.finished)


## 同刻快照排除周期贡献；满蓝零实得也成功，结果含完整双钟且只发单一新事件。
func _s1b2_success_cases() -> void:
	for amount: float in [50.0, 80.0, 100.0]:
		var sim := _s1b2_battle()
		var mage := sim.slot_unit(0)
		# 先扣除已知一固定点恢复，使执行时mana_before精确等于本例50/80/100。
		mage.res = amount - mage.res_regen * BattleSim.SKILL_FIXED_STEP if amount < 100.0 else amount
		var before := _s1a_state(sim)
		var old_lines := sim.events.lines.duplicate()
		var resolved := _s1b2_cast(sim, 100)
		var details: Dictionary = resolved.get("details", {})
		var effects: Array = details.get("effects", [])
		_check("S1b2唤醒50/80/100实得 " + str(amount), resolved.get("accepted", false) and effects.size() == 1 and absf(details.get("mana_before", -1.0) - amount) < 0.000000001 and absf(effects[0]["actual_amount"] - minf(35.0, 100.0 - amount)) < 0.000000001 and absf(mage.res - minf(100.0, amount + 35.0)) < 0.000000001)
		_check("S1b2零费用仍启动独立20秒CD和急速GCD", details.get("mana_cost") == 0.0 and absf(mage.gcd_until - sim.time - 1.0 / 1.15) < 0.000000001 and mage.skill_ready_at.get("mage.fire.evocation") == sim.time + 20.0)
		_check("S1b2成功字段与有序效果完整", resolved.size() == 8 and resolved.get("reason") == "" and resolved.get("cast_id") == sim.skill_battle_id + ":100" and details.size() == 7 and effects.size() == 1 and effects[0].size() == 11 and effects[0]["effect_index"] == 0 and effects[0]["target_index"] == 0 and effects[0]["source_id"] == mage.id and effects[0]["target_id"] == mage.id and effects[0]["effect_kind"] == "RESTORE_MANA" and effects[0]["requested_amount"] == 35.0 and effects[0]["cast_id"] == resolved["cast_id"] and effects[0]["mana_after"] == mage.res)
		_check("S1b2事务保全目标普攻其他角色和旧事件", _s1b2_units_unchanged(before, _s1a_state(sim), mage.id) and sim.events.lines.size() == old_lines.size() + 1 and _s1b2_results(sim).size() == 1)
		var seen := _s1b2_results(sim)
		resolved["details"]["effects"][0]["actual_amount"] = -99.0
		_check("S1b2结果返回副本不污染状态或日志", mage.res >= amount and _s1b2_results(sim) == seen)
	# 同点第二请求与另一施法者看见各自的时钟；seq跨角色唯一，不能重用。
	var sim := _s1b2_battle()
	for pair: Array in [[1, 0], [2, 0], [3, 2]]:
		sim._enqueue_skill_command("cast", _s1b2_request(sim, pair[0], pair[1]))
	var records := sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
	_check("S1b2同点后项读新GCD且不同角色独立", records.size() == 3 and records[0]["result"]["accepted"] and records[1]["result"]["reason"] == "GCD_ACTIVE" and not records[1]["result"].has("cast_id") and records[2]["result"]["accepted"] and records[0]["result"]["cast_id"] != records[2]["result"]["cast_id"] and sim.slot_unit(1).gcd_until == 0.0)
	_check("S1b2成功重复与失败重投直接丢弃", sim._enqueue_skill_command("cast", _s1b2_request(sim, 1, 2))["reason"] == "DUPLICATE_REQUEST" and sim._enqueue_skill_command("cast", _s1b2_request(sim, 2))["reason"] == "DUPLICATE_REQUEST" and _s1b2_results(sim).size() == 3)
	var request := _s1b2_request(sim, 4)
	sim._enqueue_skill_command("cast", request)
	request["slot"] = "Q"
	request["expected_skill_id"] = "external_mutation"
	records = sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
	_check("S1b2入队请求快照不受外部改写", records.size() == 1 and records[0]["result"]["skill_id"] == "mage.fire.evocation" and records[0]["result"]["reason"] == "GCD_ACTIVE")
	sim = _s1b2_battle()
	request = _s1b2_request(sim, 5)
	sim._enqueue_skill_command("prepare", request)
	_check("S1b2prepare和cast共享已见集合", sim._enqueue_skill_command("cast", request)["reason"] == "DUPLICATE_REQUEST")


## 截止前一点拒绝/到期点可用；周期恢复单列，倍速暂停不改变单步及公式。
func _s1b2_clock_cases() -> void:
	var sim := _s1b2_battle()
	sim.slot_unit(0).gcd_until = 3.0 * BattleSim.SKILL_FIXED_STEP
	sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
	var blocked := _s1b2_cast(sim, 1)
	var ready := _s1b2_cast(sim, 2)
	_check("S1b2GCD前一点拒绝到期点真实成功", blocked.get("reason") == "GCD_ACTIVE" and ready.get("accepted", false) and ready["details"]["executed_at"] == 3.0 * BattleSim.SKILL_FIXED_STEP)
	sim = _s1b2_battle()
	sim.slot_unit(0).skill_ready_at["mage.fire.evocation"] = 3.0 * BattleSim.SKILL_FIXED_STEP
	sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
	blocked = _s1b2_cast(sim, 1)
	ready = _s1b2_cast(sim, 2)
	_check("S1b2独立CD前一点拒绝到期点成功", blocked.get("reason") == "SKILL_COOLDOWN" and ready.get("accepted", false))
	var one := _s1b2_battle()
	var two := _s1b2_battle()
	for current: BattleSim in [one, two]:
		current.slot_unit(0).res = 10.0
		current.slot_unit(1).res = 10.0
	one._advance_skill_schedule(1.0)
	two._advance_skill_schedule(0.5, 2)
	_check("S1b2两职业100精神1000急速自然恢复6.9875", absf(one.slot_unit(0).res - 16.9875) < 0.000000001 and absf(one.slot_unit(1).res - 16.9875) < 0.000000001)
	_check("S1b2自然恢复1x2x同战斗时间一致", _s1b_same_run(one, two))
	var priest := one.slot_unit(1)
	priest.combat_stats["spirit"] = 200.0
	var derived := one._skill_derived_parameters(priest)
	_check("S1b2牧师精神150后分段", derived["problems"].is_empty() and absf(derived["regen"] - (3.0 + 0.035 * 150.0 + 0.003 * 50.0) * 1.075) < 0.000000001)
	one = _s1b2_battle()
	one._enqueue_skill_command("cast", _s1b2_request(one, 7))
	one._advance_skill_schedule(0.01)
	one.set_paused(true)
	var frozen := _s1a_state(one)
	one._advance_skill_schedule(100.0, 2)
	_check("S1b2暂停冻结清队列无补发", _s1a_same_state(frozen, _s1a_state(one)) and one._skill_pending.is_empty() and one._skill_accumulator == 0.0 and one._enqueue_skill_command("cast", _s1b2_request(one, 8))["reason"] == "BATTLE_PAUSED")
	one.set_paused(false)
	one._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
	_check("S1b2恢复不补发暂停前施法", _s1b2_results(one).is_empty())
	one._begin_skill_schedule()
	_check("S1b2新场关闭事务并清评级", not one._skill_transactions_enabled and one.slot_unit(0).combat_stats.is_empty() and one.slot_unit(0).res_regen == 0.0 and one._enqueue_skill_command("cast", _s1b2_request(one, 9))["reason"] == "TRANSACTIONS_DISABLED")


## 普通拒绝仅反馈；坏配置纯查询无副作用，执行时带字段诊断停场并清队列。
func _s1b2_failure_cases() -> void:
	var sim := _s1b2_battle()
	var request := _s1b2_request(sim, 1)
	request["expected_skill_id"] = "stale_skill"
	var before := _s1a_state(sim)
	sim._enqueue_skill_command("cast", request)
	var records := sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
	_check("S1b2技能变更普通拒绝保全全部Unit", records.size() == 1 and records[0]["result"]["skill_id"] == "stale_skill" and records[0]["result"]["reason"] == "SKILL_CHANGED" and records[0]["result"]["details"]["current_skill_id"] == "mage.fire.evocation" and not records[0]["result"].has("cast_id") and not sim.finished and _s1a_same_state(before["units"], _s1a_state(sim)["units"]))
	for bad: String in ["mixed", "empty", "other_id", "rating"]:
		sim = _s1b2_battle()
		var mage := sim.slot_unit(0)
		if bad == "mixed":
			var wrong: Dictionary = mage.resolved_slots["e"]["effects"][0].duplicate(true)
			mage.resolved_slots["r"]["effects"].append(wrong)
		elif bad == "empty":
			mage.resolved_slots["r"]["effects"] = []
		elif bad == "other_id":
			mage.resolved_slots["r"]["skill_id"] = "mage.fire.fake"
		else:
			mage.combat_stats["spirit"] = NAN
		request = _s1b2_request(sim, 13)
		before = _s1a_state(sim)
		for _repeat in 3:
			var prepared := sim._prepare_skill_transaction(request)
			_check("S1b2坏输入纯查询CONFIG_ERROR " + bad, not prepared["preparable"] and prepared["reason"] == "CONFIG_ERROR")
		_check("S1b2纯查询含新字段NaN全状态不变 " + bad, _s1a_same_state(before, _s1a_state(sim)))
		# 直接跑周期会先发现坏评级；其余坏效果由真实执行路径发现。
		sim._enqueue_skill_command("cast", request)
		sim._enqueue_skill_command("target", {"battle_id": sim.skill_battle_id, "caster_id": mage.id, "target_id": sim.slot_unit(2).id})
		records = sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
		_check("S1b2坏输入提交前拒绝并停场 " + bad, sim.finished and sim.skill_input_locked and sim.result == "error" and not sim._skill_validation_error.is_empty() and sim._skill_pending.is_empty() and _s1a_same_state(before["units"], _s1a_state(sim)["units"]) and mage.skill_ready_at.is_empty())
		if bad != "rating":
			var results := _s1b2_results(sim)
			_check("S1b2严重错误不发成功结果 " + bad, results.size() == 1 and not results[0]["accepted"] and results[0]["reason"] == "CONFIG_ERROR" and results[0]["details"].has("problems") and not results[0].has("cast_id"))
	# 纯查询成功也不消耗序号、改事件/目标/普攻或双钟。
	sim = _s1b2_battle()
	request = _s1b2_request(sim, 44)
	before = _s1a_state(sim)
	for _repeat in 3:
		_check("S1b2合法完整准备仍仅preparable", sim._prepare_skill_transaction(request)["preparable"])
	_check("S1b2完整准备反复全状态请求不变", _s1a_same_state(before, _s1a_state(sim)) and request == _s1b2_request(sim, 44))


## 订阅者只能观察完整状态；回调入队延后、直接事务及调度重入都无递归反馈。
func _s1b2_callback_cases() -> void:
	var sim := _s1b2_battle()
	var observation := {"calls": 0, "complete": false, "reentry": false}
	# 此闭包只保留标量快照，随后修改收到的结果也不能改变返回结果/Unit。
	var listener := func(resolved: Dictionary) -> void:
		observation["calls"] += 1
		var mage := sim.slot_unit(0)
		observation["complete"] = mage.res == resolved["details"]["mana_after"] and mage.gcd_until == resolved["details"]["gcd_ready_at"] and mage.skill_ready_at["mage.fire.evocation"] == resolved["details"]["skill_ready_at"]
		observation["reentry"] = sim._execute_skill_transaction(_s1b2_request(sim, 90)).get("reason") == "TRANSACTION_REENTRY" and sim._advance_skill_schedule(5.0).is_empty()
		sim._enqueue_skill_command("cast", _s1b2_request(sim, 91, 2))
		resolved["details"]["effects"][0]["actual_amount"] = -100.0
	sim.events.cast_resolved.connect(listener)
	var resolved := _s1b2_cast(sim, 89)
	_check("S1b2发布仅完整状态一次且拒绝递归重入", observation["calls"] == 1 and observation["complete"] and observation["reentry"] and resolved["details"]["effects"][0]["actual_amount"] == 0.0 and _s1b2_results(sim).size() == 1 and sim._skill_pending.size() == 1)
	sim.events.cast_resolved.disconnect(listener)
	var next := sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
	_check("S1b2结果回调命令下一点执行", next.size() == 1 and next[0]["result"]["accepted"] and next[0]["result"]["details"]["executed_at"] == 2.0 * BattleSim.SKILL_FIXED_STEP)
	for action: String in ["pause", "leave", "new"]:
		sim = _s1b2_battle()
		var original_id := sim.skill_battle_id
		# 发布后立即变更生命周期，当前批次第二条和同帧剩余点都不能作用于新场。
		var change := func(_result: Dictionary) -> void:
			if action == "pause":
				sim.set_paused(true)
				sim.set_paused(false)
			elif action == "leave":
				sim._leave_skill_schedule()
			else:
				sim._begin_skill_schedule()
				# 若旧事务错误地检查新场胜负，此零时限会令新场立即结束。
				sim.config["time_limit"] = 0.0
		sim.events.cast_resolved.connect(change)
		sim._enqueue_skill_command("cast", _s1b2_request(sim, 1))
		sim._enqueue_skill_command("cast", _s1b2_request(sim, 2, 2))
		var records := sim._advance_skill_schedule(1.0)
		_check("S1b2发布回调生命周期使旧批次失效 " + action, records.size() == 1 and _s1b2_results(sim).size() == 1 and sim._skill_pending.is_empty() and not sim.finished and (sim.skill_battle_id != original_id if action != "pause" else sim._skill_tick == 1))
		sim.events.cast_resolved.disconnect(change)


## 最小故障探针只验证遗留保护检测层，不宣称捕获真实GDScript异常或完成回滚。
func _s1b2_guard_cases() -> void:
	for entry: String in ["advance", "command", "receive", "advance_stuck", "receive_stuck"]:
		var sim := _s1b2_battle()
		var request := _s1b2_request(sim, 66)
		sim._enqueue_skill_command("cast", request)
		# 模拟子调用因运行时错误未走到清标记的现场，不加生产故障开关。
		sim._skill_transaction_pending = {"battle_id": sim.skill_battle_id, "request_seq": 65, "skill_id": "mage.fire.evocation", "phase": "effects", "problems": PackedStringArray(["qa.guard: 未完成标记探针"])}
		if entry.ends_with("_stuck"):
			sim._skill_advancing = true
		var before := _s1a_state(sim)
		if entry.begins_with("advance"):
			sim._advance_skill_schedule(1.0)
		elif entry == "command":
			sim._execute_skill_command({"kind": "cast", "receive_seq": 1, "payload": request})
		else:
			sim._enqueue_skill_command("cast", _s1b2_request(sim, 67))
		_check("S1b2未完成保护停场清队列不补成功 " + entry, sim.finished and sim.skill_input_locked and sim._skill_pending.is_empty() and sim._skill_validation_error["phase"] == "effects" and _s1b2_results(sim).is_empty() and _s1a_same_state(before["units"], _s1a_state(sim)["units"]))


## 正常失败与成功周期分开比较：全员满蓝无恢复写入，失败不改任何Unit且仅一条结果。
func _s1b2_business_failure_cases() -> void:
	for code: String in ["NO_CASTER", "CASTER_DOWN", "EMPTY_SLOT", "INVALID_TARGET", "GCD_ACTIVE", "SKILL_COOLDOWN"]:
		var sim := _s1b2_battle()
		var request := _s1b2_request(sim, 77)
		var mage := sim.slot_unit(0)
		match code:
			"NO_CASTER":
				request["caster_id"] = -123
			"CASTER_DOWN":
				mage.alive = false
			"EMPTY_SLOT":
				request = _s1b2_request(sim, 77, 1)
			"INVALID_TARGET":
				mage.selectable = false
			"GCD_ACTIVE":
				mage.gcd_until = 1.0
			"SKILL_COOLDOWN":
				mage.skill_ready_at["mage.fire.evocation"] = 20.0
		var before := _s1a_state(sim)
		sim._enqueue_skill_command("cast", request)
		var records := sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
		var results := _s1b2_results(sim)
		_check("S1b2普通拒绝只反馈不改全部Unit " + code, records.size() == 1 and results.size() == 1 and results[0]["reason"] == code and not results[0]["accepted"] and not results[0].has("cast_id") and not results[0]["details"].has("effects") and not sim.finished and _s1a_same_state(before["units"], _s1a_state(sim)["units"]))
		var count := sim.events.lines.size()
		_check("S1b2普通失败重投无第二次事件 " + code, sim._enqueue_skill_command("cast", request)["reason"] == "DUPLICATE_REQUEST" and sim.events.lines.size() == count)
	# 真实提交产生的20秒CD，也必须在前一点拒绝、到期点重新提交成功。
	var sim := _s1b2_battle()
	var first := _s1b2_cast(sim, 1)
	sim._advance_skill_schedule(1198.0 * BattleSim.SKILL_FIXED_STEP)
	var early := _s1b2_cast(sim, 2)
	var ready := _s1b2_cast(sim, 3)
	_check("S1b2真实20秒CD提交边界和cast_id唯一", first.get("accepted", false) and early.get("reason") == "SKILL_COOLDOWN" and ready.get("accepted", false) and ready["cast_id"] != first["cast_id"] and absf(ready["details"]["executed_at"] - first["details"]["skill_ready_at"]) < 0.000000001)
	var one := _s1b2_battle()
	var two := _s1b2_battle()
	for current: BattleSim in [one, two]:
		current.slot_unit(0).res = 50.0
		current._enqueue_skill_command("cast", _s1b2_request(current, 4))
	one._advance_skill_schedule(1.0)
	two._advance_skill_schedule(0.5, 2)
	_check("S1b2唤醒事务与自然恢复1x2x一致", one.slot_unit(0).res == two.slot_unit(0).res and one.slot_unit(0).gcd_until == two.slot_unit(0).gcd_until and one.slot_unit(0).skill_ready_at == two.slot_unit(0).skill_ready_at and _s1b2_results(one).size() == 1 and _s1b2_results(two).size() == 1)


## 结果发布之后才检查胜负；结束通知仍在事务保护内，不能递归发失败反馈。
func _s1b2_end_callback_case() -> void:
	var sim := _s1b2_battle()
	var observed := {"ended": 0, "guarded": false}
	# 仅夹具调整时限使结算后检查结束，周期阶段原时限仍充足。
	var on_result := func(_resolved: Dictionary) -> void:
		sim.config["time_limit"] = sim.time
	# 结束信号里直接调用事务/调度，必须只得到重入诊断，不能再发布结果。
	var on_end := func(_outcome: String, _reason: String, _elapsed: float) -> void:
		observed["ended"] += 1
		observed["guarded"] = sim._execute_skill_transaction(_s1b2_request(sim, 100)).get("reason") == "TRANSACTION_REENTRY" and sim._advance_skill_schedule(1.0).is_empty()
	sim.events.cast_resolved.connect(on_result)
	sim.events.battle_ended.connect(on_end)
	var resolved := _s1b2_cast(sim, 99)
	var last: Dictionary = JSON.parse_string(sim.events.lines[-1])
	_check("S1b2完整结果先于胜负且结束回调禁重入", resolved.get("accepted", false) and sim.finished and observed["ended"] == 1 and observed["guarded"] and _s1b2_results(sim).size() == 1 and last["e"] == "battle_ended" and sim._skill_pending.is_empty() and sim._skill_transaction_pending.is_empty())
	sim.events.cast_resolved.disconnect(on_result)
	sim.events.battle_ended.disconnect(on_end)


# ── 隔离输入链：复用实际场景脚本和控制器，不造窗口、View 或手工 cast 请求 ──
## 每份输入场使用既有显式造场；必须先绑定再执行 ready，避免旧启动链产生任何副作用。
func _s1b3_scene(ready: bool = true) -> BattleSceneScript:
	var scene: BattleSceneScript = BattleSceneScript.new()
	var sim := _s1b2_battle()
	_check("S1b3入生命周期前显式绑定", scene.bind_skill_validation(sim, sim.events))
	if ready:
		scene._ready()
	return scene


## 从工程现有按键映射构造真实键盘事件，不修改 InputMap；缺映射本身是失败。
func _s1b3_key(action: String, pressed: bool = true, echo: bool = false) -> InputEvent:
	for mapped: InputEvent in InputMap.action_get_events(action):
		if mapped is InputEventKey:
			var event: InputEventKey = mapped.duplicate()
			event.pressed = pressed
			event.echo = echo
			return event
	_check("S1b3按键映射存在 " + action, false)
	# 缺映射时继续收集其他断言，不能把替代事件认作键盘验收通过。
	var fallback := InputEventAction.new()
	fallback.action = action
	fallback.pressed = pressed
	return fallback


## 原键盘、点击分发、生命周期及实际队列结果共用既有断言入口，不代替图形几何命中验证。
func _s1b3_input_cases() -> void:
	_s1b3_binding_cases()
	_s1b3_dispatch_cases()
	_s1b3_order_cases()
	_s1b3_pause_cases()
	_s1b3_lifecycle_cases()
	_s1b3_callback_cases()


## 验证绑定先校验后替换、同场序号保留及订阅只属于本次绑定。
func _s1b3_binding_cases() -> void:
	var late: BattleSceneScript = BattleSceneScript.new()
	var late_sim := _s1b2_battle()
	late._notification(Node.NOTIFICATION_ENTER_TREE)
	_check("S1b3先入生命周期后绑定被拒绝", not late.bind_skill_validation(late_sim, late_sim.events) and late.sim == null and late._config.is_empty() and late_sim.events.cast_resolved.get_connections().is_empty())
	late.free()
	var scene := _s1b3_scene(false)
	var sim: BattleSim = scene.sim
	var bus := sim.events
	var controller: BattleController = scene.controller
	var callbacks := bus.cast_resolved.get_connections().size()
	var old_id: String = scene._skill_validation_id
	var invalid := _s1b2_battle()
	var wrong_bus := BattleEvents.new()
	_check("S1b3错误bus绑定原子拒绝", not scene.bind_skill_validation(invalid, wrong_bus) and scene.sim == sim and scene.controller == controller and scene.events == bus and invalid._skill_schedule_active)
	_check("S1b3空绑定不替换原场", not scene.bind_skill_validation(null, bus) and scene._skill_validation_id == old_id)
	var disabled := _s1b_battle()["sim"] as BattleSim
	_check("S1b3未启用事务拒绝绑定", not scene.bind_skill_validation(disabled, disabled.events) and scene.sim == sim)
	_check("S1b3失败绑定不泄漏订阅", bus.cast_resolved.get_connections().size() == callbacks and invalid.events.cast_resolved.get_connections().is_empty() and wrong_bus.cast_resolved.get_connections().is_empty())
	_check("S1b3控制器错误绑定不部分替换", not controller.setup(invalid, wrong_bus, 2, true) and controller.sim == sim and controller.selected_slot == 0)
	scene._unhandled_input(_s1b3_key("skill_r"))
	_check("S1b3同场重绑不重订阅", scene.bind_skill_validation(sim, bus) and bus.cast_resolved.get_connections().size() == callbacks and scene.controller == controller)
	scene._dispatch_click({"kind": "skill", "key": "r"}, Vector2.ZERO, false)
	_check("S1b3重绑不复用请求身份", sim._skill_pending.size() == 2 and sim._skill_pending[0]["payload"]["request_seq"] == 1 and sim._skill_pending[1]["payload"]["request_seq"] == 2)
	var replacement := BattleController.new()
	_check("S1b3新控制器不能重用本场已见身份", not replacement.setup(sim, bus, 0, true))
	var new_sim := _s1b2_battle()
	_check("S1b3合法换绑定释放旧订阅队列", scene.bind_skill_validation(new_sim, new_sim.events) and not sim._skill_schedule_active and sim._skill_pending.is_empty() and bus.cast_resolved.get_connections().is_empty() and bus.battle_ended.get_connections().is_empty())
	_check("S1b3旧控制器解绑后不走旧施法", not controller.press_skill("r") and controller.sim == null and _count(bus, "skill_cast") == 0)
	scene._ready()
	_check("S1b3生命周期开始后拒绝重绑", not scene.bind_skill_validation(new_sim, new_sim.events))
	_check("S1b3隔离ready不接默认配置日志存档", scene._config.is_empty() and scene.bot == null and scene._service == null and scene._view == null and new_sim.events._file == null and scene._accumulator == 0.0)
	_check("S1b3隔离不能调用默认结算", not scene._settle() and not scene._settled)
	scene._refresh_view()
	scene.free()
	_check("S1b3释放实例清除订阅", new_sim.events.cast_resolved.get_connections().is_empty() and new_sim.events.battle_ended.get_connections().is_empty() and not new_sim._skill_schedule_active)


## 真实键盘处理与按钮命中分发共用 press_skill；未支持与空槽不触发旧施法或严重错误。
func _s1b3_dispatch_cases() -> void:
	for via_button in [false, true]:
		var scene := _s1b3_scene()
		var sim: BattleSim = scene.sim
		var caster := sim.slot_unit(0)
		caster.res = 50.0 - caster.res_regen * BattleSim.SKILL_FIXED_STEP
		var before := _s1a_state(sim)
		scene._unhandled_input(_s1b3_key("skill_r", true, true))
		scene._unhandled_input(_s1b3_key("skill_r", false))
		_check("S1b3echo与释放均不施法 %s" % via_button, _s1a_same_state(before, _s1a_state(sim)))
		if via_button:
			scene._dispatch_click({"kind": "skill", "key": "r"}, Vector2(900, 500), false)
		else:
			scene._unhandled_input(_s1b3_key("skill_r"))
		var request: Dictionary = sim._skill_pending[0]["payload"] if not sim._skill_pending.is_empty() else {}
		_check("S1b3键盘按钮生成同契约 %s" % via_button, request.size() == 5 and request.get("caster_id") == caster.id and request.get("slot") == "R" and request.get("expected_skill_id") == "mage.fire.evocation" and request.get("battle_id") == sim.skill_battle_id and request.get("request_seq") == 1)
		_check("S1b3入队不是执行结果 %s" % via_button, scene.controller.last_input.get("queued", false) and scene.last_cast_result.is_empty() and caster.skill_ready_at.is_empty())
		scene._process(BattleSim.SKILL_FIXED_STEP)
		_check("S1b3输入推进唤醒到一次结果 %s" % via_button, scene.last_cast_result.get("accepted", false) and is_equal_approx(caster.res, 85.0) and _s1b2_results(sim).size() == 1 and caster.gcd_until > sim.time and caster.skill_ready_at.get("mage.fire.evocation", 0.0) > sim.time)
		_check("S1b3按钮不移动且无旧成功事件 %s" % via_button, caster.order_kind == before["units"][caster.id]["order_kind"] and caster.order_pos == before["units"][caster.id]["order_pos"] and _count(sim.events, "skill_cast") == 0 and _count(sim.events, "command_issued") == 0)
		scene.last_cast_result["details"]["mana_after"] = -999.0
		_check("S1b3本地结果副本不写回状态 %s" % via_button, is_equal_approx(caster.res, 85.0) and is_equal_approx(_s1b2_results(sim)[0]["details"]["mana_after"], 85.0))
		scene._dispatch_click({"kind": "skill", "key": "r"}, Vector2.ZERO, false)
		scene._process(BattleSim.SKILL_FIXED_STEP)
		_check("S1b3入队成功与执行拒绝分离 %s" % via_button, scene.controller.last_input.get("queued", false) and not scene.last_cast_result.get("accepted", true) and scene.last_cast_result.get("reason") == "GCD_ACTIVE" and _s1b2_results(sim).size() == 2)
		scene.free()
	var scene := _s1b3_scene()
	var sim: BattleSim = scene.sim
	for hit: Dictionary in [{"kind": "portrait", "slot": 0}, {"kind": "skill", "key": "r"}, {"kind": "panel"}]:
		var before := _s1a_state(sim)
		scene._dispatch_click(hit, Vector2(900, 500), true)
		_check("S1b3右键界面命中全部消费 " + String(hit["kind"]), _s1a_same_state(before, _s1a_state(sim)))
	var before_panel := _s1a_state(sim)
	scene._dispatch_click({"kind": "panel"}, Vector2(900, 500), false)
	_check("S1b3左键面板消费不移动", _s1a_same_state(before_panel, _s1a_state(sim)))
	scene._dispatch_click({"kind": "portrait", "slot": 2}, Vector2(900, 500), false)
	_check("S1b3左键头像只切人不入队", scene.controller.selected_slot == 2 and sim._skill_pending.is_empty())
	scene._dispatch_click({}, sim.slot_unit(0).pos, false)
	_check("S1b3左键友军只选人", scene.controller.selected_slot == 0 and sim._skill_pending.is_empty())
	for key in ["q", "w", "e"]:
		scene._dispatch_click({"kind": "skill", "key": key}, Vector2(900, 500), false)
		_check("S1b3法师未接入技能本地拒绝 " + key, scene.controller.last_input.get("reason") == "NOT_IMPLEMENTED" and sim._skill_pending.is_empty() and not sim.finished)
	scene._unhandled_input(_s1b3_key("slot_2"))
	for key in ["q", "w", "e", "r"]:
		scene._dispatch_click({"kind": "skill", "key": key}, Vector2(900, 500), false)
		_check("S1b3牧师未接入或空槽 " + key, scene.controller.last_input.get("reason") == ("NOT_IMPLEMENTED" if key == "q" else "EMPTY_SLOT") and sim._skill_pending.is_empty() and not sim.finished)
	_check("S1b3其他技能无旧成功或配置停场", _count(sim.events, "skill_cast") == 0 and _s1b2_results(sim).is_empty() and sim._skill_validation_error.is_empty())
	scene.free()


## 移动/目标/施法共用接收顺序；切人锁输入角色，目标只在实际执行点写入。
func _s1b3_order_cases() -> void:
	var scene := _s1b3_scene()
	var sim: BattleSim = scene.sim
	var first := sim.slot_unit(0)
	var third := sim.slot_unit(2)
	var enemy := sim.living("enemy")[0]
	first.target_id = -1
	var original_target := first.target_id
	scene._dispatch_click({}, Vector2(900, 500), false)
	scene._dispatch_click({}, enemy.pos, true)
	scene._unhandled_input(_s1b3_key("skill_r"))
	scene._unhandled_input(_s1b3_key("slot_3"))
	scene._dispatch_click({"kind": "skill", "key": "r"}, Vector2.ZERO, false)
	var queue: Array = sim._skill_pending
	_check("S1b3移动目标施法统一接收顺序", queue.size() == 4 and queue[0]["kind"] == "move" and queue[1]["kind"] == "target" and queue[2]["kind"] == "cast" and queue[0]["receive_seq"] < queue[1]["receive_seq"] and queue[1]["receive_seq"] < queue[2]["receive_seq"] and first.target_id == original_target)
	_check("S1b3跨角色递增且切人不改旧请求", queue.size() == 4 and queue[2]["payload"]["caster_id"] == first.id and queue[3]["payload"]["caster_id"] == third.id and queue[2]["payload"]["request_seq"] == 1 and queue[3]["payload"]["request_seq"] == 2)
	var observations: Array = []
	# 仅观察完整结果时已经生效的前序移动/目标，不在回调中驱动结算。
	var observe := func(result: Dictionary) -> void:
		observations.append({"caster_id": result["caster_id"], "target_id": first.target_id, "mode": first.order_kind})
	sim.events.cast_resolved.connect(observe)
	scene._process(BattleSim.SKILL_FIXED_STEP)
	sim.events.cast_resolved.disconnect(observe)
	_check("S1b3后项看到前项目标且两角色独立成功", observations.size() == 2 and observations[0]["target_id"] == enemy.id and observations[0]["mode"] == "move" and _s1b2_results(sim)[0]["caster_id"] == first.id and _s1b2_results(sim)[1]["caster_id"] == third.id and _s1b2_results(sim)[0]["accepted"] and _s1b2_results(sim)[1]["accepted"])
	scene._unhandled_input(_s1b3_key("slot_2"))
	var priest := sim.slot_unit(1)
	var mode := priest.order_kind
	var progress := priest.next_attack_at
	scene._dispatch_click({}, priest.pos, true)
	scene._process(BattleSim.SKILL_FIXED_STEP)
	_check("S1b3牧师右键自己仅设友方目标", priest.target_id == priest.id and priest.order_kind == mode and priest.next_attack_at == progress)
	var controller: BattleController = scene.controller
	sim._begin_skill_schedule()
	var current_id := sim.skill_battle_id
	var before := _s1a_state(sim)
	_check("S1b3旧控制器不能显式接管新场", not controller.setup(sim, sim.events, 0, true) and controller._skill_bound_id != current_id)
	_check("S1b3旧控制器拒绝新场不自动改绑", not controller.press_skill("r") and controller.last_input.get("reason") == "STALE_BATTLE" and controller._skill_bound_id != current_id and _s1a_same_state(before, _s1a_state(sim)))
	scene._process(0.5)
	_check("S1b3失效场景不清理新场", sim._skill_schedule_active and sim.skill_battle_id == current_id and sim.time == 0.0 and scene.sim == null)
	scene.free()


## 暂停和失焦丢弃待命令/余量，暂停仍可切人；倍速只增加相同模拟步数。
func _s1b3_pause_cases() -> void:
	var scene := _s1b3_scene()
	var sim: BattleSim = scene.sim
	scene._process(0.01)
	scene._unhandled_input(_s1b3_key("skill_r"))
	scene._unhandled_input(_s1b3_key("pause"))
	scene._unhandled_input(_s1b3_key("slot_3"))
	scene._dispatch_click({"kind": "skill", "key": "r"}, Vector2.ZERO, false)
	scene._dispatch_click({}, Vector2(900, 500), false)
	scene._dispatch_click({}, sim.living("enemy")[0].pos, true)
	_check("S1b3暂停目标输入不缓存", scene.controller.last_input.get("reason") == "BATTLE_PAUSED" and sim._skill_pending.is_empty())
	scene._process(10.0)
	_check("S1b3暂停冻结清余量且可切人", sim.paused and sim.time == 0.0 and sim._skill_accumulator == 0.0 and sim._skill_pending.is_empty() and scene.controller.selected_slot == 2 and scene.controller._skill_request_seq == 2)
	scene._unhandled_input(_s1b3_key("pause"))
	scene._process(BattleSim.SKILL_FIXED_STEP)
	_check("S1b3恢复不补发暂停请求", _s1b2_results(sim).is_empty() and is_equal_approx(sim.time, BattleSim.SKILL_FIXED_STEP))
	scene._unhandled_input(_s1b3_key("skill_r"))
	scene._process(0.01)
	scene._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	var frozen := sim.time
	scene._notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	scene._process(1.0)
	_check("S1b3失焦冻结且回焦不自动恢复", sim.paused and sim.time == frozen and sim._skill_pending.is_empty() and sim._skill_accumulator == 0.0)
	scene._unhandled_input(_s1b3_key("pause"))
	scene._process(BattleSim.SKILL_FIXED_STEP)
	_check("S1b3失焦前请求恢复不补发", _s1b2_results(sim).is_empty())
	scene.free()
	var one := _s1b3_scene()
	var two := _s1b3_scene()
	_check("S1b3倍速仅接受两档", one.set_skill_validation_speed(1) and two.set_skill_validation_speed(2) and not two.set_skill_validation_speed(3) and two._skill_validation_speed == 2)
	one._unhandled_input(_s1b3_key("skill_r"))
	two._unhandled_input(_s1b3_key("skill_r"))
	one._process(0.6)
	two._process(0.3)
	var one_state := _s1a_state(one.sim)
	var two_state := _s1a_state(two.sim)
	# 场身份和结果内 cast_id 必然不同；单独核结果次数，完整业务状态仍精确比较。
	for key in ["skill_battle_id", "_skill_accumulator", "event_lines"]:
		one_state.erase(key)
		two_state.erase(key)
	_check("S1b3不同倍速不截帧且同战斗状态", is_equal_approx(one.sim.time, 0.6) and _s1a_same_state(one_state, two_state) and absf(one.sim._skill_accumulator - two.sim._skill_accumulator) < 0.000000000001 and _s1b2_results(one.sim).size() == 1 and _s1b2_results(two.sim).size() == 1)
	one.free()
	two.free()


## 结束/离场/退出/销毁均封输入并断订阅，回调尝试旧请求不能复活队列。
func _s1b3_lifecycle_cases() -> void:
	for kind in ["end", "leave", "exit_tree", "destroy", "callback"]:
		var scene := _s1b3_scene()
		var sim: BattleSim = scene.sim
		var bus := sim.events
		var controller: BattleController = scene.controller
		scene._unhandled_input(_s1b3_key("skill_r"))
		if kind == "end":
			sim.config["time_limit"] = BattleSim.SKILL_FIXED_STEP
			scene._process(BattleSim.SKILL_FIXED_STEP)
		elif kind == "leave":
			scene._back_to_main()
		elif kind == "exit_tree":
			scene._notification(Node.NOTIFICATION_EXIT_TREE)
		elif kind == "destroy":
			scene.free()
		else:
			# 发布完整结果后离场，再尝试真实键盘处理；不得落入旧入口或产生下一请求。
			var close := func(_result: Dictionary) -> void:
				scene._back_to_main()
				scene._unhandled_input(_s1b3_key("skill_r"))
			bus.cast_resolved.connect(close)
			scene._process(BattleSim.SKILL_FIXED_STEP)
			bus.cast_resolved.disconnect(close)
		_check("S1b3生命周期清队列及订阅 " + kind, sim._skill_pending.is_empty() and not sim._skill_schedule_active and bus.cast_resolved.get_connections().is_empty() and bus.battle_ended.get_connections().is_empty() and bus._file == null)
		_check("S1b3生命周期旧控制器封输入 " + kind, not controller.press_skill("r") and controller.sim == null and _count(bus, "skill_cast") == 0 and _s1b2_results(sim).size() == (1 if kind == "callback" else 0))
		if kind != "destroy":
			_check("S1b3生命周期不走默认结算 " + kind, scene._service == null and not scene._settled and scene._config.is_empty() and scene._leaving)
			scene.free()


## 结果回调经真实输入入队只能下一点执行；选人回调离场后当前键盘分发安全结束。
func _s1b3_callback_cases() -> void:
	var scene := _s1b3_scene()
	var sim: BattleSim = scene.sim
	var bus := sim.events
	# 完整结果通知中切到另一角色再按 R，不直接调用事务或手造请求。
	var input_next := func(resolved: Dictionary) -> void:
		if resolved["request_seq"] == 1:
			scene._unhandled_input(_s1b3_key("slot_3"))
			scene._unhandled_input(_s1b3_key("skill_r"))
	bus.cast_resolved.connect(input_next)
	scene._unhandled_input(_s1b3_key("skill_r"))
	scene._process(BattleSim.SKILL_FIXED_STEP)
	_check("S1b3结果回调真实输入留下一点", _s1b2_results(sim).size() == 1 and sim._skill_pending.size() == 1 and sim._skill_pending[0]["payload"]["caster_id"] == sim.slot_unit(2).id)
	scene._process(BattleSim.SKILL_FIXED_STEP)
	_check("S1b3回调下一点执行一次完整结果", _s1b2_results(sim).size() == 2 and _s1b2_results(sim)[1]["accepted"] and _s1b2_results(sim)[1]["details"]["executed_at"] > _s1b2_results(sim)[0]["details"]["executed_at"])
	bus.cast_resolved.disconnect(input_next)
	scene.free()
	var closing := _s1b3_scene()
	var closing_sim: BattleSim = closing.sim
	var closing_bus := closing_sim.events
	# 选人信号是同步回调；释放绑定后原输入函数不得继续访问空控制器。
	var leave := func(_slot: int) -> void:
		closing._back_to_main()
	closing_bus.selection_changed.connect(leave)
	closing._unhandled_input(_s1b3_key("slot_3"))
	_check("S1b3切人回调离场封住后续输入", closing.controller == null and not closing_sim._skill_schedule_active and closing_sim._skill_pending.is_empty() and closing_bus.cast_resolved.get_connections().is_empty())
	closing_bus.selection_changed.disconnect(leave)
	closing.free()


# ── 真实场景树：只用现有隔离脚本，不创建场景资源或 View ──
## 原同步检查完成后才进入事件循环；保留旧树验证，并追加独立的完整隔离输入断言。
func _s1b4_tree_cases() -> void:
	if _s1b4_can_run:
		for kind: String in ["input", "callback", "pause", "queue_free", "new_field"]:
			await _s1b4_tree_case(kind)
		await _s1b5_view_cases()
		_s24_cases()
	print("RESULT: %s (%d 条失败)" % ["FAIL" if _failures > 0 else "ALL PASS", _failures])
	quit(1 if _failures > 0 else 0)


## 同时限制帧数和单调时间；只等待真实帧信号，超时不手动推进或伪造生命周期。
func _s1b4_wait(label: String, condition: Callable) -> bool:
	var started := Time.get_ticks_usec()
	var frames := 0
	while not bool(condition.call()) and frames < 4096 and Time.get_ticks_usec() - started < 5000000:
		frames += 1
		await process_frame
	var ok := bool(condition.call())
	_check("S1b4" + label, ok, "frames=%d elapsed_us=%d" % [frames, Time.get_ticks_usec() - started])
	return ok


## 经实际 Viewport 投递现有映射的键盘事件；缺少真实键映射就失败，绝不直调处理函数兜底。
func _s1b4_key(action: String, pressed: bool = true, echo: bool = false) -> bool:
	var event := _s1b3_key(action, pressed, echo)
	if not event is InputEventKey:
		_check("S1b4必须投递键盘 " + action, false)
		return false
	root.push_input(event, true)
	return true


## 一次按下配一次释放；Viewport 的输入传播独立于节点是否启用自动帧处理。
func _s1b4_tap(action: String) -> void:
	_s1b4_key(action)
	_s1b4_key(action, false)


## 一次只入树一个输入节点；生命周期信号在 add_child 前连接，保存数据而不干预退出路径。
func _s1b4_tree_case(kind: String) -> void:
	var scene := _s1b3_scene(false)
	# 绑定失败的实例绝不能入树，否则可能触发默认初始化；记失败并仅释放本次未入树节点。
	if not scene._skill_validation_mode or scene.sim == null or scene.controller == null:
		_check("S1b4入树前必须绑定 " + kind, false)
		scene.free()
		return
	var sim: BattleSim = scene.sim
	var bus: BattleEvents = sim.events
	var controller: BattleController = scene.controller
	var life := {"entered": 0, "ready": 0, "exiting": 0, "exited": 0, "stages": []}
	# 信号回调不捕获节点本身；退出/释放后仍能用独立数据证明真实生命周期发生。
	var entered := func() -> void:
		life["entered"] += 1
		life["stages"].append({"stage": "entered", "active": sim._skill_schedule_active})
	# ready 信号由引擎在脚本 _ready 之后发出，不能在 add_child 返回后再等待已发出的信号。
	var readied := func() -> void:
		life["ready"] += 1
		life["stages"].append({"stage": "ready", "active": sim._skill_schedule_active})
	# tree_exiting 和 tree_exited 分别记录，不假定 EXIT_TREE 通知与前者的先后顺序。
	var exiting := func() -> void:
		life["exiting"] += 1
		life["stages"].append({"stage": "exiting", "active": sim._skill_schedule_active})
	# 真正离树后应已完成生产清理；具体断言在回调返回后执行。
	var exited := func() -> void:
		life["exited"] += 1
		life["stages"].append({"stage": "exited", "active": sim._skill_schedule_active})
	scene.tree_entered.connect(entered)
	scene.ready.connect(readied)
	scene.tree_exiting.connect(exiting)
	scene.tree_exited.connect(exited)
	root.add_child(scene)
	# 暂停自动处理只用于在同一调用栈检查输入队列；随后必须靠引擎自动 _process 完成施法。
	scene.set_process(false)
	var mounted: bool = scene.is_inside_tree() and scene.is_node_ready() and life["entered"] == 1 and life["ready"] == 1
	_check("S1b4真实入树ready " + kind, mounted)
	_check("S1b4真实ready隔离默认路径 " + kind, scene._config.is_empty() and scene._view == null and scene.bot == null and scene._service == null and not scene._settled and bus._file == null and scene._accumulator == 0.0)
	var before_bind := _s1a_state(sim)
	_check("S1b4树内重绑拒绝保全 " + kind, not scene.bind_skill_validation(sim, bus) and scene.sim == sim and scene.events == bus and scene.controller == controller and _s1a_same_state(before_bind, _s1a_state(sim)) and bus.cast_resolved.get_connections().size() == 1 and bus.battle_ended.get_connections().size() == 1)
	# 测试观察者只收集纯结果，并在需要时通过同一 Viewport 注入后续输入。
	var observed: Array[Dictionary] = []
	var callback_state := {"queued_after_first": false, "count_inside_first": -1}
	var on_result := func(resolved: Dictionary) -> void:
		observed.append(resolved.duplicate(true))
		if kind == "callback" and observed.size() == 1:
			# 回调新请求必须留给下一执行点；不是手造 CastRequest，也不递归推进调度。
			_s1b4_tap("slot_3")
			_s1b4_tap("skill_r")
			callback_state["queued_after_first"] = sim._skill_pending.size() == 1
			callback_state["count_inside_first"] = _s1b2_results(sim).size()
	bus.cast_resolved.connect(on_result)
	if mounted:
		if kind == "input":
			var before_filter := _s1a_state(sim)
			_s1b4_key("skill_r", true, true)
			_s1b4_key("skill_r", false)
			_check("S1b4Viewport过滤echo释放", _s1a_same_state(before_filter, _s1a_state(sim)) and controller._skill_request_seq == 0)
			_s1b4_tap("skill_r")
			_s1b4_tap("slot_3")
			_s1b4_tap("skill_r")
			var pending := sim._skill_pending
			_check("S1b4Viewport输入确实到达", controller.selected_slot == 2 and pending.size() == 2 and observed.is_empty() and scene.last_cast_result.is_empty())
			if pending.size() == 2:
				var first: Dictionary = pending[0]["payload"]
				var second: Dictionary = pending[1]["payload"]
				_check("S1b4输入锁角色跨角色身份", first.size() == 5 and second.size() == 5 and first["request_seq"] == 1 and second["request_seq"] == 2 and first["caster_id"] == sim.slot_unit(0).id and second["caster_id"] == sim.slot_unit(2).id and first["battle_id"] == sim.skill_battle_id and second["battle_id"] == sim.skill_battle_id and first["slot"] == "R" and second["slot"] == "R" and first["expected_skill_id"] == "mage.fire.evocation" and second["expected_skill_id"] == "mage.fire.evocation")
			else:
				_check("S1b4输入锁角色跨角色身份", false, "Viewport 未形成两份请求")
			scene.set_process(true)
			# process_frame 在本帧节点处理前发出，等待条件跨帧观察；不假定一帧只执行一步。
			if await _s1b4_wait("自动帧完成两角色唤醒", func() -> bool: return observed.size() >= 2):
				_check("S1b4自动推进固定步与完整结果", sim._skill_tick > 0 and is_equal_approx(sim.time, sim._skill_tick * BattleSim.SKILL_FIXED_STEP) and observed.size() == 2 and observed[0]["accepted"] and observed[1]["accepted"] and scene.last_cast_result == observed[1] and _count(bus, "skill_cast") == 0)
				_check("S1b4一次结果与身份对应", observed[0]["request_seq"] == 1 and observed[1]["request_seq"] == 2 and observed[0].get("cast_id") == sim.skill_battle_id + ":1" and observed[1].get("cast_id") == sim.skill_battle_id + ":2" and observed[0]["details"]["effects"].size() == 1 and observed[1]["details"]["effects"].size() == 1)
				for resolved: Dictionary in observed:
					var details: Dictionary = resolved.get("details", {})
					var effects: Array = details.get("effects", [])
					# 本夹具满蓝仍应成功：恢复实得零，费用零但双钟提交；按执行快照排除帧间自然恢复。
					var complete: bool = resolved.get("accepted", false) and effects.size() == 1
					if complete:
						complete = details["mana_before"] == 100.0 and details["mana_cost"] == 0.0 and details["mana_after"] == 100.0 and effects[0]["requested_amount"] == 35.0 and effects[0]["actual_amount"] == 0.0 and details["gcd_ready_at"] > details["executed_at"] and is_equal_approx(details["skill_ready_at"], details["executed_at"] + 20.0)
					_check("S1b4实际投递完整事务 " + str(resolved["request_seq"]), complete)
		elif kind == "callback":
			_s1b4_tap("skill_r")
			scene.set_process(true)
			# 等待条件只看结果数据，实际后续输入由发布回调经 Viewport 投递。
			if await _s1b4_wait("回调输入自动执行", func() -> bool: return observed.size() >= 2):
				_check("S1b4回调留下一点非递归", callback_state["queued_after_first"] and callback_state["count_inside_first"] == 1 and observed.size() == 2 and observed[0]["accepted"] and observed[1]["accepted"] and observed[1]["request_seq"] == 2 and observed[1]["caster_id"] == sim.slot_unit(2).id and observed[1]["details"]["executed_at"] > observed[0]["details"]["executed_at"])
		elif kind == "pause":
			_s1b4_tap("skill_r")
			_s1b4_tap("pause")
			_s1b4_tap("slot_3")
			_s1b4_tap("skill_r")
			_check("S1b4Viewport暂停清队列可切人", sim.paused and sim._skill_pending.is_empty() and sim._skill_accumulator == 0.0 and controller.selected_slot == 2 and controller._skill_request_seq == 2 and not controller.last_input.get("queued", true))
			var paused_state := _s1a_state(sim)
			var frame_before := get_frame()
			scene.set_process(true)
			# 用真实 SceneTree 帧号证明暂停期间事件循环仍在运行。
			if await _s1b4_wait("暂停经过真实帧", func() -> bool: return get_frame() >= frame_before + 3):
				_check("S1b4暂停真实帧全状态冻结", _s1a_same_state(paused_state, _s1a_state(sim)) and observed.is_empty())
			_s1b4_tap("pause")
			var tick_before := sim._skill_tick
			# 不直接推进模拟，观察引擎自动 _process 首次增加战斗步号。
			if await _s1b4_wait("恢复自动推进", func() -> bool: return sim._skill_tick > tick_before):
				_check("S1b4恢复无缓存补发", not sim.paused and sim._skill_pending.is_empty() and observed.is_empty())
			_s1b4_tap("skill_r")
			# 恢复后的新身份必须真正经过自动帧结算，不能拿 queued 代替结果。
			if await _s1b4_wait("恢复后新输入完成", func() -> bool: return not observed.is_empty()):
				_check("S1b4暂停失败不复用序号", observed.size() == 1 and observed[0]["accepted"] and observed[0]["request_seq"] == 3 and observed[0]["caster_id"] == sim.slot_unit(2).id)
	# 暂停节点处理后检查退出：这里只阻止测试继续积时，绝不手动调用生产关闭函数。
	if is_instance_valid(scene):
		scene.set_process(false)
	# 测试订阅者独立释放，随后检查生产退出路径是否自行断开其两项订阅。
	bus.cast_resolved.disconnect(on_result)
	if kind == "new_field":
		var old_id := sim.skill_battle_id
		sim._begin_skill_schedule()
		_check("S1b4新场显式启用", sim.skill_battle_id != old_id and sim._enable_skill_transactions(_s1b2_stats(sim)).is_empty())
		var new_state := _s1a_state(sim)
		root.remove_child(scene)
		_check("S1b4旧节点真实退出不碰新场", life["exited"] == 1 and not controller.press_skill("r") and _s1a_same_state(new_state, _s1a_state(sim)) and sim._skill_schedule_active and sim._skill_transactions_enabled)
	else:
		# 退出前确有待执行请求，证明清队列发生在实际生命周期，而非测试提前清空。
		_s1b4_tap("skill_r")
		_check("S1b4退出前存在待执行命令 " + kind, not sim._skill_pending.is_empty())
		if kind == "queue_free":
			# WeakRef 不持有节点生命期；等待回调仅捕获此引用包装，避免节点释放后的失效捕获错误。
			var scene_ref: WeakRef = weakref(scene)
			scene.queue_free()
			_check("S1b4销毁申请仍在树待释放", is_instance_valid(scene) and scene.is_inside_tree() and scene.is_queued_for_deletion() and life["exited"] == 0 and sim._skill_schedule_active and not sim._skill_pending.is_empty())
			print("S1b4_PHASE queue_free requested ", JSON.stringify(life))
			# 回调以 get_ref() 为空确认对象实际释放，不能仅看退出信号，也不提前 remove_child/free。
			await _s1b4_wait("queue_free实际释放", func() -> bool: return scene_ref.get_ref() == null)
		else:
			root.remove_child(scene)
			_check("S1b4remove_child实际退出 " + kind, not scene.is_inside_tree() and life["exiting"] == 1 and life["exited"] == 1)
		_check("S1b4真实退出清队列时钟绑定 " + kind, not sim._skill_schedule_active and not sim._skill_transactions_enabled and sim._skill_pending.is_empty() and sim._skill_accumulator == 0.0 and not controller.press_skill("r") and controller.sim == null)
	# 节点退出后再投递键盘；旧控制器引用和已退出节点都不能生成旧场命令。
	var after_exit := _s1a_state(sim)
	_s1b4_tap("skill_r")
	_check("S1b4退出后Viewport输入无旧影响 " + kind, _s1a_same_state(after_exit, _s1a_state(sim)) and bus.cast_resolved.get_connections().is_empty() and bus.battle_ended.get_connections().is_empty() and bus._file == null and life["exiting"] == 1 and life["exited"] == 1)
	print("S1b4_PHASE actual_exit ", kind, " ", JSON.stringify(life))
	# 正常路径已实际退出；超时路径也必须回收本次节点，但不能把兜底清理算作被测路径通过。
	if is_instance_valid(scene):
		if scene.is_inside_tree():
			root.remove_child(scene)
		for pair: Array in [[&"tree_entered", entered], [&"ready", readied], [&"tree_exiting", exiting], [&"tree_exited", exited]]:
			if scene.is_connected(pair[0], pair[1]):
				scene.disconnect(pair[0], pair[1])
		scene.free()
	_check("S1b4节点最终实际释放 " + kind, not is_instance_valid(scene))
	# 所有按键均成对释放；新的场代次只由测试所有者清理，旧节点不能代为清场。
	for action: String in ["skill_r", "slot_3", "pause"]:
		_s1b4_key(action, false)
	if kind == "new_field":
		sim._leave_skill_schedule()


# ── 隔离 View：仅复用既有脚本及造场，不建资源，不替代真实窗口视觉验收 ──
## 验证逐槽契约、深副本和异常纯查询；显示秒数不作为截止判定依据。
func _s1b5_projection_cases() -> void:
	var sim := _s1b2_battle()
	var mage := sim.slot_unit(0)
	var priest := sim.slot_unit(1)
	var fields := ["caster_id", "slot", "empty", "skill_id", "name", "target_kind", "cast_range_m", "mana_cost", "effects", "cooldown", "skill_ready_at", "cd_left", "gcd_ready_at", "gcd_left", "preparable", "reason", "details", "implemented"]
	var before := _s1a_state(sim)
	for slot: String in ["Q", "W", "E", "R"]:
		var data := sim.get_skill_view(mage.id, slot)
		# 回调仅检查字段是否存在，不捕获节点或修改投影。
		_check("S1b5逐槽稳定字段 " + slot, data.size() == fields.size() and fields.all(func(field: String) -> bool: return data.has(field)) and data["caster_id"] == mage.id and data["slot"] == slot)
	_check("S1b5规则准备和实现分离", sim.get_skill_view(mage.id, "Q")["preparable"] and not sim.get_skill_view(mage.id, "Q")["implemented"] and sim.get_skill_view(mage.id, "R")["implemented"])
	for slot: String in ["W", "E", "R"]:
		var empty := sim.get_skill_view(priest.id, slot)
		_check("S1b5牧师空槽 " + slot, empty["empty"] and empty["reason"] == "EMPTY_SLOT" and empty["skill_id"] == "" and not empty["implemented"] and empty["mana_cost"] == null)
	var copied := sim.get_skill_view(mage.id, "Q")
	copied["effects"][0]["radius_m"] = 999.0
	copied["details"]["injected"] = true
	var snap := sim.snapshot(true)
	snap["skills"][mage.id][0]["effects"][0]["power_coeff"] = 999.0
	snap["units"][0]["hp"] = -1
	_check("S1b5查询嵌套副本与全状态保全", sim.get_skill_view(mage.id, "Q")["effects"][0]["radius_m"] == 2.0 and _s1a_same_state(before, _s1a_state(sim)))
	_check("S1b5无角色及非法槽明确拒绝", sim.get_skill_view(-123, "R")["reason"] == "NO_CASTER" and sim.get_skill_view(mage.id, "X")["reason"] == "EMPTY_SLOT")
	mage.combat_stats["spirit"] = NAN
	var stats_state := _s1a_state(sim)
	_check("S1b5必要评级异常只读拒绝", sim.get_skill_view(mage.id, "R")["reason"] == "CONFIG_ERROR" and _s1a_same_state(stats_state, _s1a_state(sim)) and not sim.finished)
	mage.combat_stats["spirit"] = 100.0
	var legacy := sim.snapshot()
	_check("S1b5默认旧快照字段保留", not legacy.has("skill_validation") and legacy["skills"][mage.id][0].has("key") and not legacy["skills"][mage.id][0].has("implemented"))
	var old_skills := mage.skills
	var old_clocks := mage.cd_until
	mage.skills = {}
	mage.cd_until = {"r": 999999.0}
	var isolated := sim.snapshot(true)
	_check("S1b5隔离投影不读旧技能及时钟", isolated["skill_validation"] and isolated["skills"][mage.id][3]["cd_left"] == 0.0 and isolated["skills"][mage.id][3]["cooldown"] == 20.0)
	mage.skills = old_skills
	mage.cd_until = old_clocks
	# 仅改夹具的执行点元数据，精确检测 GCD 与独立 CD 的前一点/到期点，避免被自然恢复干扰。
	for clock: String in ["gcd", "cd"]:
		mage.gcd_until = 0.0
		mage.skill_ready_at.clear()
		if clock == "gcd":
			mage.gcd_until = BattleSim.SKILL_FIXED_STEP * 3.0
		else:
			mage.skill_ready_at["mage.fire.evocation"] = BattleSim.SKILL_FIXED_STEP * 3.0
		sim._skill_tick = 2
		sim.time = BattleSim.SKILL_FIXED_STEP * 2.0
		var pending := sim.get_skill_view(mage.id, "R")
		_check("S1b5权威截止前一点 " + clock, not pending["preparable"] and pending["reason"] == ("GCD_ACTIVE" if clock == "gcd" else "SKILL_COOLDOWN"))
		sim._skill_tick = 3
		sim.time = BattleSim.SKILL_FIXED_STEP * 3.0
		var ready := sim.get_skill_view(mage.id, "R")
		_check("S1b5权威截止到期点 " + clock, ready["preparable"] and ready["reason"] == "" and ready["gcd_left"] == 0.0 and ready["cd_left"] == 0.0)
	mage.gcd_until = NAN
	mage.resolved_slots["q"]["effects"][0]["radius_m"] = NAN
	var nan_state := _s1a_state(sim)
	for i in 3:
		var invalid := sim.get_skill_view(mage.id, "Q")
		_check("S1b5NaN异常只读诊断 %d" % i, invalid["reason"] == "CONFIG_ERROR" and not invalid["details"]["problems"].is_empty() and invalid["gcd_left"] == null and invalid["effects"][0]["radius_m"] == null)
	_check("S1b5含NaN纯查询全状态不变", _s1a_same_state(nan_state, _s1a_state(sim)) and not sim.finished and not sim.skill_input_locked)
	mage.gcd_until = 0.0
	mage.resolved_slots["q"]["effects"][0]["radius_m"] = 2.0
	mage.resolved_slots["q"]["mana_cost"] = "wrong"
	_check("S1b5错型配置不补零", sim.get_skill_view(mage.id, "Q")["reason"] == "CONFIG_ERROR" and sim.get_skill_view(mage.id, "Q")["mana_cost"] == null)
	mage.resolved_slots["q"]["mana_cost"] = 25.0
	mage.resolved_slots["q"]["effects"] = [Resource.new()]
	var object_state := _s1a_state(sim)
	var no_object := sim.get_skill_view(mage.id, "Q")
	_check("S1b5错误效果对象不泄露不触发停场", no_object["reason"] == "CONFIG_ERROR" and no_object["effects"] == [{}] and _s1a_same_state(object_state, _s1a_state(sim)))
	mage.resolved_slots["q"]["skill_id"] = null
	_check("S1b5非法ID纯查询诊断", sim.get_skill_view(mage.id, "Q")["reason"] == "CONFIG_ERROR")
	sim._leave_skill_schedule()
	var left := _s1a_state(sim)
	_check("S1b5旧场查询拒绝且不改场", sim.get_skill_view(mage.id, "R")["reason"] == "STALE_BATTLE" and _s1a_same_state(left, _s1a_state(sim)))


## 通过 Viewport 送入合成鼠标；使用实际 View 到视口变换，处理函数必须自行逆变换及几何命中。
func _s1b5_mouse(view: Node2D, local_pos: Vector2, secondary: bool = false) -> void:
	var point: Vector2 = view.get_global_transform_with_canvas() * local_pos
	for down: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_RIGHT if secondary else MOUSE_BUTTON_LEFT
		event.pressed = down
		event.position = point
		event.global_position = point
		root.push_input(event, true)


## 每例唯一真实 View/输入节点；继承已有等待上限和统一汇总，不手调 ready/process/exit。
func _s1b5_view_cases() -> void:
	for kind: String in ["input", "callback", "end", "new_field"]:
		await _s1b5_view_case(kind)


## 覆盖真实矩形、输入诊断、完整结果及生命周期；回调只捕获 WeakRef，销毁后无失效 Node 捕获。
func _s1b5_view_case(kind: String) -> void:
	# 仅测试视口尺寸覆盖既有1920×1080矩形，结束恢复，不改项目配置或布局资源。
	var old_viewport_size: Vector2i = root.size
	root.size = Vector2i(1920, 1080)
	var scene := _s1b3_scene(false)
	# 绑定失败绝不入树，避免失败路径意外启动默认配置、日志或存档。
	if not scene._skill_validation_mode or scene.sim == null or scene.controller == null:
		_check("S1b5隔离绑定必须先成功 " + kind, false)
		scene.free()
		root.size = old_viewport_size
		return
	var sim: BattleSim = scene.sim
	# 非满蓝用例区分自然恢复与效果实得，其他用例保留满蓝零实得成功。
	if kind == "input":
		sim.slot_unit(0).res = 80.0
	var bus: BattleEvents = scene.events
	var controller: BattleController = scene.controller
	var before_bind := _s1a_state(sim)
	_check("S1b5缺View绑定原子拒绝 " + kind, not scene.bind_skill_validation(sim, bus, true) and scene.controller == controller and not scene._skill_validation_view and _s1a_same_state(before_bind, _s1a_state(sim)) and bus.cast_resolved.get_connections().size() == 1)
	# 同名普通 Node2D 不是批准的 View 脚本；拒绝时不替换旧绑定。
	var invalid_view := Node2D.new()
	invalid_view.name = "View"
	scene.add_child(invalid_view)
	_check("S1b5错误View脚本原子拒绝 " + kind, not scene.bind_skill_validation(sim, bus, true) and scene.controller == controller and _s1a_same_state(before_bind, _s1a_state(sim)))
	scene.remove_child(invalid_view)
	invalid_view.free()
	var view: BattleViewScript = BattleViewScript.new()
	view.name = "View"
	scene.add_child(view)
	var bound: bool = scene.bind_skill_validation(sim, bus, true)
	_check("S1b5入树前显式View绑定 " + kind, bound)
	if not bound:
		scene.free()
		root.size = old_viewport_size
		return
	# 有效View存在时再验错误bus，保证拒绝真实发生于候选场身份校验。
	_check("S1b5无效bus绑定原子拒绝 " + kind, not scene.bind_skill_validation(sim, BattleEvents.new(), true) and scene.events == bus and scene.controller == controller and scene._skill_validation_view and _s1a_same_state(before_bind, _s1a_state(sim)))
	# 非零父子位移验证 _event_pos 和 View 命中各自坐标空间；不修改任何绘制矩形。
	scene.position = Vector2(31, 19)
	view.position = Vector2(7, 11)
	var scene_ref: WeakRef = weakref(scene)
	var life := {"ready": 0, "exited": 0}
	# 实际信号只记录数据，不提前手动清理生产订阅。
	var readied := func() -> void:
		life["ready"] += 1
	scene.ready.connect(readied)
	# 不捕获待释放节点，以实际退出事件记录生命周期。
	var exited := func() -> void:
		life["exited"] += 1
	scene.tree_exited.connect(exited)
	root.add_child(scene)
	scene.set_process(false)
	_check("S1b5真实ready初始投影 " + kind, life["ready"] == 1 and scene._view == view and view._snap.get("skill_validation", false) and view._selected_slot == 0 and scene._config.is_empty() and scene.bot == null and scene._service == null and bus._file == null)
	# 已有提示行仅检查字体度量边界，不把 headless 宽度检查称为真实窗口视觉验收。
	var guide: String = "隔离：右键仅设目标；" + view._skill_configuration_text()
	_check("S1b5配置文字沿用原区域 " + kind, view._font.get_string_size(guide, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 20).x <= 1872.0)
	_check("S1b5树内重绑拒绝 " + kind, not scene.bind_skill_validation(sim, bus, true) and scene.controller == controller and scene._skill_validation_view)
	var observed: Array[Dictionary] = []
	# 观察完整结果后通过同一个 Viewport 送下一输入；WeakRef 仅访问尚存活的节点。
	var observer := func(resolved: Dictionary) -> void:
		observed.append(resolved.duplicate(true))
		var live: BattleSceneScript = scene_ref.get_ref()
		if live == null:
			return
		if kind == "callback" and observed.size() == 1:
			_s1b4_tap("slot_3")
			_s1b4_tap("pause")
		elif kind == "end" and observed.size() == 1:
			sim._finish("win", "all_enemies_down")
	bus.cast_resolved.connect(observer)
	if kind == "input":
		var r: Rect2 = view._skill_rect(3)
		var empty: Rect2 = view._skill_rect(0)
		_check("S1b5实际矩形内外命中", view.hit_test(r.get_center()).get("key") == "r" and view.hit_test(Vector2(500, 500)).is_empty() and view.hit_test(r.position - Vector2(1, 1)).get("kind") == "hud")
		var before_panel := _s1a_state(sim)
		_s1b5_mouse(view, r.get_center(), true)
		_s1b5_mouse(view, r.position - Vector2(1, 1))
		_s1b5_mouse(view, view._portrait_rect(0).get_center(), true)
		_check("S1b5面板右键不透传", _s1a_same_state(before_panel, _s1a_state(sim)) and controller._skill_request_seq == 0)
		_s1b5_mouse(view, empty.get_center())
		_check("S1b5未接入本地提示不投旧施法", controller.last_input.get("reason") == "NOT_IMPLEMENTED" and sim._skill_pending.is_empty() and view._toast.contains("输入拒绝") and view._toast.contains("NOT_IMPLEMENTED") and _count(bus, "skill_cast") == 0)
		_s1b5_mouse(view, view._portrait_rect(1).get_center())
		_s1b5_mouse(view, r.get_center())
		_check("S1b5头像切人空槽即时刷新", controller.selected_slot == 1 and view._selected_slot == 1 and view._snap["skills"][sim.slot_unit(1).id][3]["empty"] and controller.last_input.get("reason") == "EMPTY_SLOT" and view._toast.contains("EMPTY_SLOT"))
		_s1b5_mouse(view, view._portrait_rect(0).get_center())
		_s1b5_mouse(view, Vector2(500, 500))
		_check("S1b5矩形外移动同一队列", sim._skill_pending.size() == 1 and sim._skill_pending[0]["kind"] == "move")
		var enemy: BattleSim.Unit = sim.living("enemy")[0]
		var enemy_in_view: Vector2 = view.to_local(scene.to_global(enemy.pos))
		_s1b5_mouse(view, enemy_in_view, true)
		_check("S1b5真实右键目标同一队列", sim._skill_pending.size() == 2 and sim._skill_pending[1]["kind"] == "target")
		_s1b5_mouse(view, r.get_center())
		_check("S1b5鼠标按钮真实入队非成功", sim._skill_pending.size() == 3 and controller._skill_request_seq == 1 and observed.is_empty() and scene.last_cast_result.is_empty() and view._toast.contains("已入队") and not view._toast.contains("执行成功"))
	else:
		_s1b4_tap("skill_r")
	scene.set_process(true)
	# 只观察纯结果数组，自动 _process 执行实际队列和事务。
	if await _s1b4_wait("S1b5自动View结果 " + kind, func() -> bool: return not observed.is_empty()):
		if kind != "end":
			var actual: float = observed[0]["details"]["effects"][0]["actual_amount"]
			_check("S1b5View实得读取结果 " + kind, observed.size() == 1 and scene.last_cast_result == observed[0] and view._toast.contains("执行成功：唤醒实得 %.1f 法力" % actual))
			_check("S1b5恢复实得与周期分开 " + kind, (actual > 0.0 and actual < 20.0 and observed[0]["details"]["mana_before"] > 80.0) if kind == "input" else actual == 0.0)
		if kind == "input":
			scene.set_process(false)
			var live_data: Dictionary = view._snap["skills"][sim.slot_unit(0).id][3]
			_check("S1b5双钟显示来自Unit", live_data["skill_ready_at"] == sim.slot_unit(0).skill_ready_at["mage.fire.evocation"] and live_data["gcd_ready_at"] == sim.slot_unit(0).gcd_until and not live_data["preparable"])
			# 返回值和 View 缓存独立，外部改画面不能回写 Unit；随后实际输入刷新会纠正显示。
			view._snap["skills"][sim.slot_unit(0).id][3]["effects"][0]["flat_amount"] = -999.0
			_check("S1b5View数据不能回写玩法", sim.slot_unit(0).resolved_slots["r"]["effects"][0]["flat_amount"] == 35.0)
			_s1b4_tap("pause")
			var paused: Dictionary = view._snap.duplicate(true)
			var frozen := _s1a_state(sim)
			var pause_start_frame: int = get_frame()
			scene.set_process(true)
			# 真实事件循环继续，但战斗时间及可见倒计时冻结。
			await _s1b4_wait("S1b5暂停实际帧", func() -> bool: return get_frame() >= pause_start_frame + 3)
			_check("S1b5暂停View与状态冻结", _s1a_same_state(paused, view._snap) and _s1a_same_state(frozen, _s1a_state(sim)))
			_check("S1b5倍速只选既有调度", scene.set_skill_validation_speed(2))
			_s1b4_tap("pause")
			var old_tick: int = sim._skill_tick
			# 继续由引擎驱动，而非手工调用 _process 或造新时钟。
			await _s1b4_wait("S1b5倍速真实推进", func() -> bool: return sim._skill_tick > old_tick)
			_check("S1b5倍速投影随战斗时间", view._snap["time"] == sim.time and is_equal_approx(sim.time, sim._skill_tick * BattleSim.SKILL_FIXED_STEP))
		elif kind == "callback":
			_check("S1b5同步回调切人暂停画面完整", sim.paused and view._selected_slot == 2 and view._snap["paused"] and view._toast.contains("执行成功"))
		elif kind == "end":
			_check("S1b5结束先留最终纯画面再解绑", scene.sim == null and scene.controller == null and view._snap["finished"] and view._snap["result"] == "win" and not scene._settled and scene._service == null and bus._file == null)
	scene.set_process(false)
	bus.cast_resolved.disconnect(observer)
	if kind == "new_field":
		var final_picture: Dictionary = view._snap.duplicate(true)
		sim._begin_skill_schedule()
		_check("S1b5新场显式再启用", sim._enable_skill_transactions(_s1b2_stats(sim)).is_empty())
		var new_state := _s1a_state(sim)
		_s1b4_tap("skill_r")
		_check("S1b5旧View不读不改新场", scene.sim == null and _s1a_same_state(final_picture, view._snap) and _s1a_same_state(new_state, _s1a_state(sim)))
	root.remove_child(scene)
	var after := _s1a_state(sim)
	_s1b4_tap("skill_r")
	_check("S1b5实际退出清理引用订阅 " + kind, life["exited"] == 1 and scene.sim == null and scene.events == null and controller.sim == null and bus.cast_resolved.get_connections().is_empty() and bus.battle_ended.get_connections().is_empty() and _s1a_same_state(after, _s1a_state(sim)))
	scene.queue_free()
	# WeakRef 证明实际释放，不捕获已释放场景或其 View，也不以退出信号替代销毁。
	await _s1b4_wait("S1b5场景View实际释放 " + kind, func() -> bool: return scene_ref.get_ref() == null)
	for action: String in ["skill_r", "slot_3", "pause"]:
		_s1b4_key(action, false)
	if kind == "new_field":
		sim._leave_skill_schedule()
	root.size = old_viewport_size


# ── 显式真实窗口取证：只观测已有输入/信号/状态，不注入输入或改生产接口 ──
## 自动回归前独立分流；无显示或隔离环境不完整时统一失败收尾，不创建默认日志或存档。
func _s1b6_window_start() -> void:
	if _s1b6_finishing:
		return
	var args := OS.get_cmdline_user_args()
	var flag_count: int = args.count("--s1b6-window")
	var sources: PackedStringArray = PackedStringArray()
	for argument: String in args:
		if argument.begins_with("--s1b6-input-source="):
			sources.append(argument.trim_prefix("--s1b6-input-source="))
	var valid_flags: bool = flag_count == 1 and not args.has("--s1a-only") and sources.size() == 1 and sources[0] in ["manual", "os-automation"]
	_check("S1b6窗口参数与输入来源声明", valid_flags)
	if valid_flags:
		_s1b6_input_source = sources[0]
	var directory: String = _s1a_fixture_directory_from_args()
	if directory.is_empty() or not valid_flags:
		await _s1b6_finish("invalid_arguments", true)
		return
	# 仅复用校验返回的目录定位QA根，不创建坏源夹具或扫描额外资源。
	var qa_root: String = directory.get_base_dir()
	var access: DirAccess = DirAccess.open("/")
	var isolated: bool = access != null and not DirAccess.dir_exists_absolute(directory) and not FileAccess.file_exists(directory)
	var paths := {"home": OS.get_environment("HOME"), "cache": OS.get_environment("XDG_CACHE_HOME"), "temporary": OS.get_environment("TMPDIR"), "user": OS.get_user_data_dir()}
	# 引擎消费--log-file；用户参数只声明匹配条件，随后必须核对实际写句柄，不据自报放行。
	var expected_logs := PackedStringArray()
	for argument: String in args:
		if argument.begins_with("--s1b6-engine-log="):
			expected_logs.append(argument.trim_prefix("--s1b6-engine-log="))
	var expected: String = expected_logs[0] if expected_logs.size() == 1 else ""
	paths["engine_log"] = expected
	isolated = isolated and expected_logs.size() == 1 and expected == qa_root.path_join("logs/window-engine.log")
	for name: String in paths:
		var path: String = paths[name]
		isolated = isolated and path.is_absolute_path() and path.simplify_path().begins_with(qa_root + "/")
		if access != null:
			var part: String = ""
			for component: String in path.trim_prefix("/").trim_suffix("/").split("/"):
				part += "/" + component
				if access.is_link(part):
					isolated = false
	# 路径边界/无链接先通过才启动工具；不枚举其他进程，也不读取任何日志内容。
	if isolated:
		var evidence: Dictionary = await _s1b6_log_handle(expected)
		_s1b6_trace("engine_log_handle", evidence)
		if _s1b6_log_cancelled:
			await _s1b6_finish("window_close_during_log_probe", false)
			return
		isolated = bool(evidence["ok"])
		# await期间路径可能变化；核验完成后再查日志每一级链接，不能只信工具启动前的检查。
		var checked_part: String = ""
		for component: String in expected.trim_prefix("/").split("/"):
			checked_part += "/" + component
			if access.is_link(checked_part):
				isolated = false
	_check("S1b6用户目录均隔离且无链接", isolated, JSON.stringify(paths))
	_check("S1b6必须真实显示后端", DisplayServer.get_name() != "headless", DisplayServer.get_name())
	_s1b6_trace("environment", {"paths": paths, "display": DisplayServer.get_name(), "engine": Engine.get_version_info(), "input_source_declared": _s1b6_input_source, "visual": "UNVERIFIED"})
	if not isolated or DisplayServer.get_name() == "headless":
		await _s1b6_finish("invalid_environment", true)
		return
	_config = BattleConfig.load_config()
	var problems := BattleConfig.validate(_config)
	problems.append_array(BattleConfig.load_skill_catalog()["problems"])
	_check("S1b6造场配置可用", problems.is_empty(), "; ".join(problems))
	if not problems.is_empty():
		await _s1b6_finish("configuration", true)
		return
	# 非满蓝和初始暂停仅为显式夹具初态；按P后自然恢复与输入均交原调度，不在取证时重置法力。
	var scene: BattleSceneScript = _s1b3_scene(false)
	_s1b6_scene_ref = weakref(scene)
	_s1b6_sim = scene.sim
	_s1b6_bus = scene.events
	_s1b6_controller = scene.controller
	if _s1b6_sim == null or _s1b6_bus == null or _s1b6_controller == null or _failures > 0:
		await _s1b6_finish("construction", true)
		return
	_s1b6_sim.slot_unit(0).res = 50.0
	_s1b6_sim.slot_unit(2).res = 80.0
	_s1b6_sim.set_paused(true)
	_s1b6_battle_id = _s1b6_sim.skill_battle_id
	var view: BattleViewScript = BattleViewScript.new()
	view.name = "View"
	scene.add_child(view)
	var bound: bool = scene.bind_skill_validation(_s1b6_sim, _s1b6_bus, true)
	_check("S1b6真实入树前绑定View", bound)
	if not bound:
		await _s1b6_finish("view_binding", true)
		return
	# 先连生命周期信号再入树；回调均为本SceneTree方法，不捕获将被释放的Node。
	scene.tree_entered.connect(_s1b6_tree_entered)
	scene.ready.connect(_s1b6_ready)
	scene.tree_exiting.connect(_s1b6_tree_exiting)
	scene.tree_exited.connect(_s1b6_tree_exited)
	_s1b6_bus.cast_resolved.connect(_s1b6_result)
	_s1b6_bus.selection_changed.connect(_s1b6_selected)
	root.window_input.connect(_s1b6_input)
	root.size_changed.connect(_s1b6_resized)
	root.focus_entered.connect(_s1b6_focus_entered)
	root.focus_exited.connect(_s1b6_focus_exited)
	root.add_child(scene)
	_check("S1b6实际ready并隔离默认路径", _s1b6_life["ready"] == 1 and scene._view == view and scene._config.is_empty() and scene.bot == null and scene._service == null and _s1b6_bus._file == null)
	if _failures > 0:
		await _s1b6_finish("ready", true)
		return
	_s1b6_trace("window_ready", {"window": _s1b6_window_geometry(), "font_reported_name": view._font.get_font_name(), "fixture": "spirit=100; haste_rating=1000; speed=0; mana=50/100/80; initially_paused=true", "instructions": "先P再R；另测头像、Q未接入、鼠标中心/边缘/面板/战场、另一窗口尺寸、切出切回后P；系统关闭收尾。截图及输入来源由测试另证，不自动判视觉通过。"})
	_s1b6_observe("ready", true)
	var started: int = Time.get_ticks_usec()
	var last_sample: int = started
	var frames: int = 0
	# 交互限90秒及54000帧，暂停不延长期限；只等真实事件循环，不合成输入或强制设置窗口/根视口大小。
	while not _s1b6_finishing and frames < 54000 and Time.get_ticks_usec() - started < 90000000:
		frames += 1
		await process_frame
		if _s1b6_finishing:
			return
		var now: int = Time.get_ticks_usec()
		_s1b6_observe("state", now - last_sample >= 1000000)
		if now - last_sample >= 1000000:
			last_sample = now
		if _s1b6_sim.skill_input_locked or _s1b6_sim.skill_battle_id != _s1b6_battle_id or _s1b6_scene_ref.get_ref() == null:
			await _s1b6_finish("field_invalidated", true)
			return
	if not _s1b6_finishing:
		_s1b6_trace("interaction_limit", {"frames": frames, "elapsed_us": Time.get_ticks_usec() - started})
		await _s1b6_finish("interaction_frame_limit" if frames >= 54000 else "interaction_timeout_90s", true)


## 只编码纯数据写stdout；外部启动器将stdout/stderr与引擎日志写入全新QA证据区。
func _s1b6_trace(stage: String, data: Dictionary = {}) -> void:
	print("S1b6_TRACE ", JSON.stringify({"stage": stage, "monotonic_us": Time.get_ticks_usec(), "data": data}, "", false))


## 记录引擎实际窗口/视口及变换，不把项目配置值当作实际缩放，也不乘固定比例。
func _s1b6_window_geometry() -> Dictionary:
	var visible: Rect2 = root.get_visible_rect()
	return {"window_size": [root.size.x, root.size.y], "window_position": [root.position.x, root.position.y],
		"viewport_size": [visible.size.x, visible.size.y], "content_scale_size": [root.content_scale_size.x, root.content_scale_size.y],
		"content_scale_mode": root.content_scale_mode, "content_scale_factor": root.content_scale_factor,
		"final_transform": str(root.get_final_transform()), "stretch_transform": str(root.get_stretch_transform()), "focused": root.has_focus()}


## 观察输入处理后的真实队列与本地反馈；只有状态变化或每秒采样才输出，持续时间变化不刷屏。
func _s1b6_observe(stage: String, force: bool = false) -> void:
	if _s1b6_finishing or _s1b6_sim == null or _s1b6_controller == null:
		return
	var sim: BattleSim = _s1b6_sim
	var selected: BattleSim.Unit = _s1b6_controller.selected_unit()
	var control: Dictionary = {"battle_id": sim.skill_battle_id, "paused": sim.paused, "finished": sim.finished,
		"locked": sim.skill_input_locked, "selected_slot": _s1b6_controller.selected_slot,
		"selected_caster_id": selected.id if selected != null else -1,
		"request_seq": _s1b6_controller._skill_request_seq, "receive_seq": sim._skill_receive_seq,
		"last_input": _s1b6_controller.last_input.duplicate(true), "pending": sim._skill_pending.duplicate(true)}
	if not force and _s1a_same_state(_s1b6_last_control, control):
		return
	_s1b6_last_control = control.duplicate(true)
	var clocks: Array[Dictionary] = []
	for index in 3:
		var unit := sim.slot_unit(index)
		var cd_left: Dictionary = {}
		for skill_id: String in unit.skill_ready_at:
			cd_left[skill_id] = maxf(0.0, float(unit.skill_ready_at[skill_id]) - sim.time)
		clocks.append({"caster_id": unit.id, "slot": index, "mana": unit.res, "gcd_ready_at": unit.gcd_until,
			"skill_ready_at": unit.skill_ready_at.duplicate(true), "cd_left_display": cd_left, "gcd_left_display": maxf(0.0, unit.gcd_until - sim.time)})
	_s1b6_trace(stage, {"control": control, "time": sim.time, "tick": sim._skill_tick, "clocks": clocks, "window": _s1b6_window_geometry()})


## 窗口输入只观察，不接管、不转发或生成命令；声明来源不是对物理硬件来源的自动证明。
func _s1b6_input(event: InputEvent) -> void:
	if _s1b6_finishing or not (event is InputEventKey or event is InputEventMouseButton):
		return
	var data := {"input_source_declared": _s1b6_input_source, "device": event.device}
	if _s1b6_controller != null:
		var caster: BattleSim.Unit = _s1b6_controller.selected_unit()
		data["selected_slot_before"] = _s1b6_controller.selected_slot
		data["caster_id_before"] = caster.id if caster != null else -1
		data["request_seq_before"] = _s1b6_controller._skill_request_seq
	if event is InputEventKey:
		var key: InputEventKey = event
		if key.pressed and not key.echo:
			_s1b6_counts["key_presses"] += 1
		data.merge({"type": "key", "physical_keycode": key.physical_keycode, "keycode": key.keycode, "pressed": key.pressed, "echo": key.echo})
	else:
		var mouse: InputEventMouseButton = event
		if mouse.pressed:
			_s1b6_counts["mouse_presses"] += 1
		data.merge({"type": "mouse_button", "button": mouse.button_index, "pressed": mouse.pressed, "window_signal_position": [mouse.position.x, mouse.position.y]})
		var scene: BattleSceneScript = _s1b6_scene_ref.get_ref() if _s1b6_scene_ref != null else null
		if scene != null and scene._skill_validation_current() and scene._view != null:
			# 窗口信号处先记原始点及变换预测；不声称该阶段的坐标已是业务_unhandled_input的最终坐标。
			var point: Vector2 = scene._event_pos(event)
			var local: Vector2 = scene._view.to_local(scene.to_global(point))
			data["observer_scene_position"] = [point.x, point.y]
			data["observer_view_position"] = [local.x, local.y]
			data["observer_hit_prediction"] = scene._view.call("hit_test", local)
	_s1b6_trace("window_input", data)
	# window_input与_unhandled_input有先后，延迟记录处理结果；未进入队列的本地拒绝也可见。
	_s1b6_observe.call_deferred("after_input", true)


## 原有选择信号只记录角色变化，不重置请求身份，也不改选中槽位。
func _s1b6_selected(slot: int) -> void:
	_s1b6_counts["selection"] += 1
	_s1b6_trace("selection", {"slot": slot})
	_s1b6_observe.call_deferred("after_selection", true)


## 已完成结果直接留原字段与实得明细；不以UI法力差重建结果、不触发新的事务。
func _s1b6_result(resolved: Dictionary) -> void:
	_s1b6_results.append(resolved.duplicate(true))
	_s1b6_trace("cast_resolved", resolved.duplicate(true))
	_s1b6_observe.call_deferred("after_result", true)


## 记录实际窗口尺寸变化；测试应在两种尺寸各自截图，程序日志不代替视觉证据。
func _s1b6_resized() -> void:
	_s1b6_counts["resize"] += 1
	_s1b6_trace("window_resized", _s1b6_window_geometry())


## 失焦只记信号；暂停仍由既有场景通知执行，观察延迟到通知完成后。
func _s1b6_focus_exited() -> void:
	_s1b6_counts["focus_out"] += 1
	_s1b6_trace("focus_exited", _s1b6_window_geometry())
	_s1b6_observe.call_deferred("after_focus_exited", true)


## 回焦不替玩家恢复；P恢复应由真实键盘与原控制器完成。
func _s1b6_focus_entered() -> void:
	_s1b6_counts["focus_in"] += 1
	_s1b6_trace("focus_entered", _s1b6_window_geometry())
	_s1b6_observe.call_deferred("after_focus_entered", true)


## 真正进入树时记录状态，不调用任何生命周期方法制造信号。
func _s1b6_tree_entered() -> void:
	_s1b6_life["entered"] += 1
	_s1b6_trace("tree_entered", _s1b6_life.duplicate(true))


## ready信号在生产_ready之后发出；初始纯画面必须由该真实生命周期产生。
func _s1b6_ready() -> void:
	_s1b6_life["ready"] += 1
	_s1b6_trace("ready", _s1b6_life.duplicate(true))


## 实际开始离树时留证，不能在queue_free申请时先清生产订阅。
func _s1b6_tree_exiting() -> void:
	_s1b6_life["exiting"] += 1
	_s1b6_trace("tree_exiting", _s1b6_life.duplicate(true))


## 真正离树后记录信号；对象是否已释放另由WeakRef等待验证。
func _s1b6_tree_exited() -> void:
	_s1b6_life["exited"] += 1
	_s1b6_trace("tree_exited", _s1b6_life.duplicate(true))


## 系统关闭仅请求统一收尾；幂等标记在首个await前置位，重复关闭不能再次汇总。
func _s1b6_close_requested() -> void:
	# 查询期间由唯一工具所有者取消并回收子进程，再进入统一关闭；避免主程序先quit留下工具。
	if _s1b6_log_probe_running:
		_s1b6_log_cancelled = true
		return
	if not _s1b6_finishing:
		_s1b6_finish("window_close", false)


## 关闭/失败/90秒期限共用真实退出清理；只解除测试观察者，生产解绑必须由实际退出完成。
func _s1b6_finish(cause: String, failed: bool) -> void:
	if _s1b6_finishing:
		return
	_s1b6_finishing = true
	if failed:
		_check("S1b6启动或交互完成", false, cause)
	# 先断所有测试输入/窗口/业务观察订阅，保留生命周期观察直至实际释放。
	for pair: Array in [[&"window_input", _s1b6_input], [&"size_changed", _s1b6_resized], [&"focus_entered", _s1b6_focus_entered], [&"focus_exited", _s1b6_focus_exited], [&"close_requested", _s1b6_close_requested]]:
		if root.is_connected(pair[0], pair[1]):
			root.disconnect(pair[0], pair[1])
	if _s1b6_bus != null:
		if _s1b6_bus.cast_resolved.is_connected(_s1b6_result):
			_s1b6_bus.cast_resolved.disconnect(_s1b6_result)
		if _s1b6_bus.selection_changed.is_connected(_s1b6_selected):
			_s1b6_bus.selection_changed.disconnect(_s1b6_selected)
	var had_scene: bool = _s1b6_scene_ref != null and _s1b6_scene_ref.get_ref() != null
	if had_scene:
		var scene: BattleSceneScript = _s1b6_scene_ref.get_ref()
		_s1b6_trace("close_requested", {"cause": cause, "inside_tree": scene.is_inside_tree(), "life": _s1b6_life.duplicate(true)})
		# 本地停止后续输入传播即可，不能先调用生产_close或leave来伪造退出清理。
		scene.set_process_unhandled_input(false)
		scene.set_process(false)
		scene.queue_free()
		var reference: WeakRef = _s1b6_scene_ref
		# 条件仅捕获WeakRef，不捕获将释放的scene；等待同时受4096帧/5秒上限约束。
		var released: bool = await _s1b4_wait("S1b6窗口节点实际释放", func() -> bool: return reference.get_ref() == null)
		_check("S1b6实际退出信号", _s1b6_life["entered"] == 0 or (_s1b6_life["exiting"] == 1 and _s1b6_life["exited"] == 1))
		if not released and reference.get_ref() != null:
			# 仅在释放等待已判失败后回收本次节点，绝不把兜底回收改记为queue_free验证成功。
			var remaining: Node = reference.get_ref()
			remaining.free()
	if _s1b6_sim != null:
		_check("S1b6生产退出自行清场", not _s1b6_sim._skill_schedule_active and not _s1b6_sim._skill_transactions_enabled and _s1b6_sim._skill_pending.is_empty() and _s1b6_sim._skill_accumulator == 0.0)
	if _s1b6_controller != null:
		_check("S1b6旧控制器解除引用", _s1b6_controller.sim == null and _s1b6_controller.events == null)
	if _s1b6_bus != null:
		_check("S1b6无生产订阅或默认日志残留", _s1b6_bus.cast_resolved.get_connections().is_empty() and _s1b6_bus.battle_ended.get_connections().is_empty() and _s1b6_bus.selection_changed.get_connections().is_empty() and _s1b6_bus._file == null)
	# 最小交互证据不足也不能正常通过退出；完整视觉/坐标/焦点矩阵仍须由测试审核截图。
	var nonzero: bool = false
	for resolved: Dictionary in _s1b6_results:
		if resolved.get("accepted", false):
			for effect: Dictionary in resolved.get("details", {}).get("effects", []):
				nonzero = nonzero or float(effect.get("actual_amount", 0.0)) > 0.0
	if not failed:
		_check("S1b6至少观察到窗口键鼠", _s1b6_counts["key_presses"] > 0 and _s1b6_counts["mouse_presses"] > 0, "缺键盘或鼠标观察记录属于未完成")
		_check("S1b6至少有交互后的非满蓝结果", nonzero, "提前关闭或无实得证据属于未完成")
	_s1b6_trace("closed", {"cause": cause, "life": _s1b6_life.duplicate(true), "result_count": _s1b6_results.size(), "nonzero_result": nonzero, "observed_counts": _s1b6_counts.duplicate(true), "visual": "UNVERIFIED", "input_source_declared": _s1b6_input_source})
	_s1b6_scene_ref = null
	_s1b6_controller = null
	_s1b6_sim = null
	_s1b6_bus = null
	print("RESULT: S1b6 %s; visual=UNVERIFIED; cause=%s; failures=%d" % ["INCOMPLETE" if _failures > 0 else "AUTO_CHECKS_ONLY", cause, _failures])
	# 终止工具未收回时保持父进程存活，保留未回收lsof的PID；外部须先结束工具再处理本场进程。
	# 此路径仅输出失败结果，不冒称正常退出或清理完成，真实非零终码由120秒看门狗另行记录。
	if _s1b6_log_cleanup_unknown:
		return
	quit(1 if _failures > 0 else 0)


## 仅窗口查询本进程日志写句柄；固定参数、非阻塞管道和双上限，默认回归不依赖系统工具。
func _s1b6_log_handle(expected: String) -> Dictionary:
	var parent_pid: int = OS.get_process_id()
	var arguments := PackedStringArray(["-n", "-P", "-a", "-p", str(parent_pid), "-F0pftan"])
	var proof := {"ok": false, "godot_pid": parent_pid, "tool": "/usr/sbin/lsof", "arguments": arguments,
		"tool_pid": -1, "exit_code": -1, "reaped": false, "stdout_base64": "", "stderr_base64": "", "reason": "tool_unavailable"}
	if OS.get_name() != "macOS" or not FileAccess.file_exists("/usr/sbin/lsof") or not FileAccess.file_exists("/bin/kill"):
		return proof
	var child: Dictionary = OS.execute_with_pipe("/usr/sbin/lsof", arguments, false)
	if child.is_empty():
		return proof
	# PID只来自本次创建结果，整个核验由当前协程独占；任何退出观测之后均不再发送信号。
	var pid: int = child["pid"]
	proof["tool_pid"] = pid
	_s1b6_log_probe_running = true
	var out: FileAccess = child["stdio"]
	var err: FileAccess = child["stderr"]
	var stdout_bytes := PackedByteArray()
	var stderr_bytes := PackedByteArray()
	var started: int = Time.get_ticks_usec()
	var frames: int = 0
	var stopped: bool = false
	var complete: bool = false
	# Unix管道eof_reached恒为false；已回收子进程后读尽剩余字节，不能依赖普通文件EOF标记。
	while frames < 512 and Time.get_ticks_usec() - started < 3000000 and not _s1b6_log_cancelled:
		stdout_bytes.append_array(out.get_buffer(mini(16384, out.get_length())))
		stderr_bytes.append_array(err.get_buffer(mini(16384, err.get_length())))
		stopped = not OS.is_process_running(pid)
		complete = stopped and out.get_length() == 0 and err.get_length() == 0
		if stdout_bytes.size() + stderr_bytes.size() > 1048576 or complete:
			break
		frames += 1
		await process_frame
	var within_budget: bool = frames < 512 and Time.get_ticks_usec() - started < 3000000
	var signal_ok: bool = true
	var killer_stopped: bool = true
	# 最后一次WNOHANG观测若已回收则不启动kill；仍在运行的直接子进程退出后暂留僵尸，PID不会复用。
	if not stopped:
		stopped = not OS.is_process_running(pid)
	if not stopped and pid > 2 and pid != parent_pid:
		var kill_args := PackedStringArray(["-KILL", str(pid)])
		var killer: Dictionary = OS.execute_with_pipe("/bin/kill", kill_args, false)
		proof["termination"] = {"tool": "/bin/kill", "arguments": kill_args, "pid": -1, "exit_code": -1, "reaped": false}
		signal_ok = false
		if not killer.is_empty():
			var kill_pid: int = killer["pid"]
			var kill_out: FileAccess = killer["stdio"]
			var kill_err: FileAccess = killer["stderr"]
			var kill_stdout := PackedByteArray()
			var kill_stderr := PackedByteArray()
			var kill_started: int = Time.get_ticks_usec()
			var kill_frames: int = 0
			killer_stopped = false
			# kill退出前禁止查询/回收lsof；即使lsof自然退出也保留其PID，避免延迟信号落到复用PID。
			while kill_frames < 256 and Time.get_ticks_usec() - kill_started < 1000000:
				kill_stdout.append_array(kill_out.get_buffer(mini(4096, kill_out.get_length())))
				kill_stderr.append_array(kill_err.get_buffer(mini(4096, kill_err.get_length())))
				killer_stopped = not OS.is_process_running(kill_pid)
				if kill_stdout.size() + kill_stderr.size() > 65536 or (killer_stopped and kill_out.get_length() == 0 and kill_err.get_length() == 0):
					break
				kill_frames += 1
				await process_frame
			var kill_exit: int = OS.get_process_exit_code(kill_pid) if killer_stopped else -1
			signal_ok = killer_stopped and kill_exit == 0 and kill_stdout.is_empty() and kill_stderr.is_empty() and kill_frames < 256 and Time.get_ticks_usec() - kill_started < 1000000
			# 空字节的Base64证据直接记为空串，避免编码API报错；非空输出仍精确保留原始字节。
			proof["termination"] = {"tool": "/bin/kill", "arguments": kill_args, "pid": kill_pid, "exit_code": kill_exit,
				"reaped": killer_stopped, "elapsed_us": Time.get_ticks_usec() - kill_started,
				"stdout_base64": ("" if kill_stdout.is_empty() else Marshalls.raw_to_base64(kill_stdout)), "stderr_base64": ("" if kill_stderr.is_empty() else Marshalls.raw_to_base64(kill_stderr))}
			kill_out.close()
			kill_err.close()
	elif not stopped:
		signal_ok = false
	# 终止工具已退出或未创建才能有界回收lsof；工具仍挂起时保留两PID并交外部看门狗，绝不递归杀工具。
	if killer_stopped and not stopped:
		var reap_started: int = Time.get_ticks_usec()
		var reap_frames: int = 0
		while reap_frames < 256 and Time.get_ticks_usec() - reap_started < 1000000:
			stopped = not OS.is_process_running(pid)
			if stopped:
				break
			reap_frames += 1
			await process_frame
	proof["reaped"] = stopped
	proof["exit_code"] = OS.get_process_exit_code(pid) if stopped else -1
	proof["unrecovered_pids"] = [] if stopped and killer_stopped else [pid]
	if not killer_stopped:
		proof["unrecovered_pids"].append(proof["termination"]["pid"])
	_s1b6_log_cleanup_unknown = not stopped or not killer_stopped
	proof["cleanup_owner"] = "entry" if stopped and killer_stopped else "external_launcher_120s_watchdog"
	proof["elapsed_us"] = Time.get_ticks_usec() - started
	# lsof两路输出同样保留空串语义（可还原为空字节），不改变stderr非空时的拒绝条件。
	proof["stdout_base64"] = ("" if stdout_bytes.is_empty() else Marshalls.raw_to_base64(stdout_bytes))
	proof["stderr_base64"] = ("" if stderr_bytes.is_empty() else Marshalls.raw_to_base64(stderr_bytes))
	out.close()
	err.close()
	_s1b6_log_probe_running = false
	proof["reason"] = "cancelled" if _s1b6_log_cancelled else "tool_failed_timeout_incomplete_or_cleanup_unknown"
	# 超时后即便成功终止也不能把残缺输出当证据；终止失败、回收不明一律拒绝。
	if not complete or not within_budget or stdout_bytes.size() + stderr_bytes.size() > 1048576 or not stopped or not signal_ok or proof["exit_code"] != 0 or not stderr_bytes.is_empty() or _s1b6_log_cancelled:
		return proof
	var parsed: Dictionary = _s1b6_log_records(stdout_bytes, parent_pid, expected)
	proof.merge(parsed, true)
	return proof


## 解析lsof的NUL分隔原始字节，不读取日志；仅当前PID、非标准流且唯一的REG写日志能匹配。
func _s1b6_log_records(raw: PackedByteArray, pid: int, expected: String) -> Dictionary:
	var rejected := {"ok": false, "reason": "malformed_or_missing_pid_fields"}
	if raw.size() < 2 or raw[raw.size() - 2] != 0 or raw[raw.size() - 1] != 10:
		return rejected
	var records: Array[Dictionary] = []
	var record: Dictionary = {}
	var seen_pid: bool = false
	var offset: int = 0
	# 直接按字节找NUL，避免String把嵌入零当终结；只去掉记录集间的一个换行，不裁剪路径空格。
	while offset < raw.size() - 1:
		if raw[offset] == 10:
			offset += 1
		var end: int = raw.find(0, offset)
		if end <= offset:
			return rejected
		var bytes: PackedByteArray = raw.slice(offset, end)
		var field: String = bytes.get_string_from_utf8()
		if field.to_utf8_buffer() != bytes:
			return rejected
		offset = end + 1
		var tag: String = field.left(1)
		var value: String = field.substr(1)
		if tag == "p":
			if seen_pid or value != str(pid):
				return rejected
			seen_pid = true
		elif tag == "f":
			if not seen_pid:
				return rejected
			if not record.is_empty():
				records.append(record)
			record = {"f": value}
		elif tag in ["a", "t", "n"]:
			if record.is_empty() or record.has(tag):
				return rejected
			record[tag] = value
		else:
			return rejected
	if not record.is_empty():
		records.append(record)
	if not seen_pid:
		return rejected
	var candidates: Array[Dictionary] = []
	for entry: Dictionary in records:
		var fd: String = entry["f"]
		if fd.is_valid_int() and fd.to_int() > 2 and entry.get("t") == "REG" and entry.get("a") in ["w", "u"]:
			if not entry.get("n") is String:
				return rejected
			# 核验发生在建场/业务写文件之前；唯一非标准流.log写句柄须精确等于QA/logs固定引擎日志名。
			if String(entry["n"]).ends_with(".log"):
				candidates.append(entry.duplicate(true))
	var matched: bool = candidates.size() == 1 and candidates[0]["n"] == expected and candidates[0]["a"] == "w"
	return {"ok": matched, "reason": "unique_REG_write_fd_matches_expected" if matched else "log_handle_missing_ambiguous_or_mismatched", "candidates": candidates}


## 新完整数值夹具只复用既有造场；独立显式输入不修改旧fixture或把旧普攻当P。
func _s2_inputs(sim: BattleSim) -> Dictionary:
	var stats: Dictionary = {}
	var relations: Dictionary = {}
	for id: int in sim.units:
		var unit: BattleSim.Unit = sim.units[id]
		var supplied := {"armor": 500, "magic_resistance": 1000, "evasion_rating": 200, "damage_reduction": 0.2}
		if unit.side == "ally":
			supplied.merge({"intellect": 30, "spirit": 100, "equipment_power": 10, "temporary_power": -5,
				"power_bonus": 0.2, "precision_rating": 400, "critical_rating": 1000, "haste_rating": 1000,
				"mastery_rating": 1000, "penetration_rating": 1000, "damage_bonus": -0.8,
				"healing_bonus": 0.1, "shield_bonus": 0.3, "critical_bonus": 0.0})
		else:
			var allies: Dictionary = {}
			allies[sim.slot_unit(0).id] = true
			relations[id] = {"activated": true, "engaged_allies": allies}
		stats[id] = supplied
	return {"stats": stats, "relations": relations}


## 安装成功的完整场供边界用例使用；不运行引擎或创造第二份生命状态。
func _s2_battle() -> BattleSim:
	var sim: BattleSim = _s1b_battle()["sim"]
	var inputs := _s2_inputs(sim)
	var problems := sim._enable_skill_transactions(inputs["stats"], true, inputs["relations"])
	_check("S2完整夹具原子安装", problems.is_empty(), str(problems))
	return sim


## 同一既有入口追加数值、严格拒绝、旧类型兼容、关系和硬隔离；全部旧断言/精确比较保留。
func _s2_numeric_cases() -> void:
	_s2_rejection_cases()
	_s2_value_cases()
	_s2_legacy_cases()
	_s2_relation_cases()
	_s2_isolation_cases()


## 各种坏输入安装前后比较全部字段/事件/随机源；NaN相等规则复用原精确比较，不放宽类型。
func _s2_rejection_cases() -> void:
	var labels: Array[String] = ["missing_unit", "extra_unit", "float_id", "string_id", "stats_null", "missing_field", "extra_field", "bool", "string", "null", "nan", "infinity", "negative_base", "negative_rating", "negative_defense", "negative_equipment", "negative_reduction", "power_overflow", "primary_overflow", "power_cancel_overflow", "bad_hp", "small_max_hp", "nan_hp", "infinite_max", "hp_exceeds", "alive_mismatch", "bad_mana", "missing_enemy", "extra_relation", "float_enemy_id", "activation_bool", "extra_relation_field", "set_type", "false_member", "float_ally_id", "foreign_ally", "enemy_as_ally", "inactive_set", "dead_ally", "dead_enemy", "late_step", "late_queue"]
	for label: String in labels:
		var sim: BattleSim = _s1b_battle()["sim"]
		var inputs := _s2_inputs(sim)
		var stats: Dictionary = inputs["stats"]
		var relations: Dictionary = inputs["relations"]
		var ally := sim.slot_unit(0)
		var enemy := sim.living("enemy")[0]
		match label:
			"missing_unit": stats.erase(ally.id)
			"extra_unit": stats[999999] = stats[ally.id].duplicate(true)
			"float_id":
				var supplied: Dictionary = stats[ally.id]
				stats.erase(ally.id)
				stats[float(ally.id)] = supplied
			"string_id": stats[str(ally.id)] = stats[ally.id].duplicate(true)
			"stats_null": stats[ally.id] = null
			"missing_field": stats[ally.id].erase("intellect")
			"extra_field": stats[ally.id]["power"] = 100.0
			"bool": stats[ally.id]["spirit"] = true
			"string": stats[ally.id]["spirit"] = "100"
			"null": stats[ally.id]["spirit"] = null
			"nan": stats[ally.id]["spirit"] = NAN
			"infinity": stats[enemy.id]["armor"] = INF
			"negative_base": stats[ally.id]["intellect"] = -1
			"negative_rating": stats[ally.id]["critical_rating"] = -1
			"negative_defense": stats[enemy.id]["magic_resistance"] = -1
			"negative_equipment": stats[ally.id]["equipment_power"] = -1
			"negative_reduction": stats[enemy.id]["damage_reduction"] = -0.1
			"power_overflow":
				stats[ally.id]["equipment_power"] = 1.0e308
				stats[ally.id]["power_bonus"] = 10.0
			"primary_overflow": stats[ally.id]["intellect"] = 1.0e308
			"power_cancel_overflow":
				stats[ally.id]["intellect"] = 1.0e308
				stats[ally.id]["power_bonus"] = -2.0
			"bad_hp": ally.hp = -0.001
			"small_max_hp":
				ally.max_hp = 0.9
				ally.hp = 0.5
			"nan_hp": ally.hp = NAN
			"infinite_max": ally.max_hp = INF
			"hp_exceeds": ally.hp = ally.max_hp + 0.001
			"alive_mismatch": ally.hp = 0.0
			"bad_mana": ally.res = NAN
			"missing_enemy": relations.erase(enemy.id)
			"extra_relation": relations[ally.id] = {"activated": false, "engaged_allies": {}}
			"float_enemy_id":
				var supplied: Dictionary = relations[enemy.id]
				relations.erase(enemy.id)
				relations[float(enemy.id)] = supplied
			"activation_bool": relations[enemy.id]["activated"] = 1
			"extra_relation_field": relations[enemy.id]["threat"] = {}
			"set_type": relations[enemy.id]["engaged_allies"] = [ally.id]
			"false_member": relations[enemy.id]["engaged_allies"][ally.id] = false
			"float_ally_id":
				relations[enemy.id]["engaged_allies"].clear()
				relations[enemy.id]["engaged_allies"][float(ally.id)] = true
			"foreign_ally": relations[enemy.id]["engaged_allies"][999999] = true
			"enemy_as_ally": relations[enemy.id]["engaged_allies"][enemy.id] = true
			"inactive_set": relations[enemy.id]["activated"] = false
			"dead_ally":
				ally.hp = 0.0
				ally.alive = false
			"dead_enemy":
				enemy.hp = 0.0
				enemy.alive = false
			"late_step": sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
			"late_queue": sim._enqueue_skill_command("prepare", _s1a_request(sim))
		var before := _s1a_state(sim)
		var problems := sim._enable_skill_transactions(stats, true, relations)
		_check("S2拒绝且全状态不变 " + label, not problems.is_empty() and _s1a_same_state(before, _s1a_state(sim)), str(problems))


## 纸面计算两职业P和非零评级，验证限幅、独立副本、唯一防护、微量生命及纯派生查询。
func _s2_value_cases() -> void:
	var sim: BattleSim = _s1b_battle()["sim"]
	var inputs := _s2_inputs(sim)
	var mage := sim.slot_unit(0)
	var priest := sim.slot_unit(1)
	mage.max_hp = 10.125
	mage.hp = 0.000001
	mage.res = 50.0
	mage.gcd_until = 4.5
	mage.skill_ready_at["mage.fire.evocation"] = 20.125
	var before := _s1a_state(sim)
	var problems := sim._enable_skill_transactions(inputs["stats"], true, inputs["relations"])
	_check("S2完整安装保留生命法力双钟", problems.is_empty() and mage.hp == 0.000001 and mage.max_hp == 10.125 and mage.res == 50.0 and mage.gcd_until == 4.5 and mage.skill_ready_at["mage.fire.evocation"] == 20.125 and sim.time == before["time"], str(problems))
	var derived := sim._skill_derived_parameters(mage)
	var holy := sim._skill_derived_parameters(priest)
	_check("S2法师P=(20+10-5+60+50)*1.2", is_equal_approx(derived.get("power", -1), 162.0), str(derived))
	_check("S2牧师P=(20+10-5+200+15)*1.2", is_equal_approx(holy.get("power", -1), 288.0), str(holy))
	_check("S2非零评级及稳定暴击", is_equal_approx(derived.get("critical_multiplier", -1), 1.1375) and is_equal_approx(derived.get("haste", -1), 0.15) and is_equal_approx(derived.get("gcd", -1), 1.0 / 1.15) and is_equal_approx(derived.get("mastery", -1), 0.225) and is_equal_approx(derived.get("penetration", -1), 0.175) and is_equal_approx(mage.res_regen, 6.9875), str(derived))
	_check("S2净伤害修正最低负60%", is_equal_approx(derived.get("damage_multiplier", -1), 0.4))
	_check("S2唯一防护且所有输入浮点化", mage.armor == 500.0 and mage.magic_resist == 1000.0 and not mage.combat_stats.has("armor") and not mage.combat_stats.has("magic_resistance") and mage.combat_stats["intellect"] is float)
	inputs["stats"][mage.id]["intellect"] = 9999.0
	inputs["relations"][sim.living("enemy")[0].id]["engaged_allies"].clear()
	derived["stats"]["spirit"] = 9999.0
	_check("S2安装和派生结果不泄漏内部字典", mage.combat_stats["intellect"] == 30.0 and mage.combat_stats["spirit"] == 100.0 and not sim._skill_engaged_enemies(mage.id).is_empty())
	for projected: bool in [false, true]:
		var view := sim.snapshot(projected)
		var unit: Dictionary = view["units"][0]
		_check("S2完整快照保留微量float生命 " + str(projected), unit["hp"] is float and unit["max_hp"] is float and unit["hp"] == 0.000001 and unit["max_hp"] == 10.125)
	before = _s1a_state(sim)
	sim._skill_derived_parameters(mage)
	sim._skill_engaged_enemies(mage.id)
	_check("S2派生及关系查询全状态纯读", _s1a_same_state(before, _s1a_state(sim)))
	_check("S2重复完整安装拒绝全状态保全", not sim._enable_skill_transactions(inputs["stats"], true, inputs["relations"]).is_empty() and _s1a_same_state(before, _s1a_state(sim)))
	for scenario: String in ["zero", "caps", "priest_segment"]:
		sim = _s1b_battle()["sim"]
		inputs = _s2_inputs(sim)
		var stats: Dictionary = inputs["stats"][sim.slot_unit(1).id]
		if scenario == "zero":
			stats["temporary_power"] = -10000.0
			stats["power_bonus"] = -2.0
			stats["healing_bonus"] = -2.0
			stats["shield_bonus"] = -2.0
			stats["critical_bonus"] = -2.0
		elif scenario == "caps":
			stats["damage_reduction"] = 1.0
			stats["critical_bonus"] = 100.0
		else:
			stats["spirit"] = 200.0
		problems = sim._enable_skill_transactions(inputs["stats"], true, inputs["relations"])
		derived = sim._skill_derived_parameters(sim.slot_unit(1))
		var correct: bool = problems.is_empty()
		if scenario == "zero":
			correct = correct and derived.get("power") == 0.0 and derived.get("healing_multiplier") == 0.0 and derived.get("shield_multiplier") == 0.0 and derived.get("critical_multiplier") == 1.0
		elif scenario == "caps":
			correct = correct and is_equal_approx(derived.get("damage_taken_multiplier", -1), 0.4) and is_equal_approx(derived.get("critical_multiplier", -1), 1.4125)
		else:
			correct = correct and is_equal_approx(derived.get("regen", -1), (3.0 + 0.035 * 150.0 + 0.003 * 50.0) * 1.075)
		_check("S2职业派生边界 " + scenario, correct, str(derived))


## 直接观察旧事件实参类型及整数数值，不以JSON数字模糊类型；旧伤害治疗仍用整数旧算法。
func _s2_legacy_cases() -> void:
	var sim := BattleSim.new()
	var bus := BattleEvents.new()
	var observed: Dictionary = {"spawn": [], "damage": [], "heal": []}
	# 同步信号只采纯值；回调随本地总线销毁，不连接生产节点或延迟引用。
	bus.unit_spawned.connect(func(_id: int, _side: String, _slot: int, _kind: String, hp: Variant, _pos: Vector2) -> void: observed["spawn"].append(hp))
	# 旧事件的金额、有效量及生命必须仍为int。
	bus.damage_dealt.connect(func(_source: int, _target: int, amount: Variant, _skill: String, _crit: bool, hp: Variant) -> void: observed["damage"].append([amount, hp]))
	# 治疗观测使用独立数组，确保不是由日志格式化掩盖浮点变化。
	bus.heal_done.connect(func(_source: int, _target: int, amount: Variant, effective: Variant, _skill: String, hp: Variant) -> void: observed["heal"].append([amount, effective, hp]))
	var cfg: Dictionary = _config.duplicate(true)
	cfg["crit_chance"] = 0.0
	sim.setup(cfg, ["mage", "priest", "", ""], 19, bus)
	var mage := sim.slot_unit(0)
	var priest := sim.slot_unit(1)
	var enemy := sim.living("enemy")[0]
	var spawn_ints := true
	for hp: Variant in observed["spawn"]:
		spawn_ints = spawn_ints and hp is int
	_check("S2旧出生生命事件仍全部int", spawn_ints and observed["spawn"].size() == sim.units.size())
	enemy.max_hp = 1000.0
	enemy.hp = 1000.0
	enemy.armor = 0.0
	sim._damage(mage, enemy, 10.6, "legacy_probe", false)
	_check("S2旧伤害仍四舍五入整数事件", observed["damage"].size() == 1 and _s1a_same_state(observed["damage"][0], [11, 989]) and enemy.hp == 989.0)
	priest.hp = priest.max_hp - 2.0
	sim._heal(mage, priest, 10.6, "legacy_probe")
	_check("S2旧治疗仍整数有效量与事件", observed["heal"].size() == 1 and _s1a_same_state(observed["heal"][0], [11, 2, int(priest.max_hp)]) and priest.hp == priest.max_hp)
	var snapshot_ints := true
	for unit: Dictionary in sim.snapshot()["units"]:
		snapshot_ints = snapshot_ints and unit["hp"] is int and unit["max_hp"] is int
	_check("S2旧默认快照生命类型及值保留", snapshot_ints and sim.snapshot()["units"][0]["hp"] == int(mage.hp))


## 关系只能安装和查询；仇恨/目标/距离/暂停均不推断，死亡、停用及离场清理有明确边界。
func _s2_relation_cases() -> void:
	var sim := _s2_battle()
	var ally := sim.slot_unit(0)
	var healer := sim.slot_unit(1)
	var enemies := sim.living("enemy")
	var expected: Array[int] = []
	for enemy: BattleSim.Unit in enemies:
		expected.append(enemy.id)
	expected.sort()
	_check("S2交战集合稳定排序", _s1a_same_state(sim._skill_engaged_enemies(ally.id), expected))
	var snapshot := sim._skill_engaged_enemies(ally.id)
	snapshot.clear()
	_check("S2关系查询不返回内部集合", sim._skill_engaged_enemies(ally.id).size() == enemies.size())
	for enemy: BattleSim.Unit in enemies:
		enemy.target_id = healer.id
		enemy.threat[healer.id] = 1000.0
		enemy.pos = healer.pos
	_check("S2目标距离与仇恨不建立交战", sim._skill_engaged_enemies(healer.id).is_empty())
	sim.set_paused(true)
	sim.set_paused(false)
	_check("S2暂停恢复不解除关系", _s1a_same_state(sim._skill_engaged_enemies(ally.id), expected))
	var enemy := enemies[0]
	var before := _s1a_state(sim)
	_check("S2停用友方拒绝且全状态不变", not sim._deactivate_skill_enemy(ally.id) and _s1a_same_state(before, _s1a_state(sim)))
	_check("S2敌方明确停用清自身关系仇恨", sim._deactivate_skill_enemy(enemy.id) and not enemy.activated and enemy.engaged_allies.is_empty() and enemy.threat.is_empty())
	sim._down(ally, enemy.id)
	for participant: BattleSim.Unit in enemies:
		_check("S2友方死亡移除关系和该人仇恨 " + str(participant.id), not participant.engaged_allies.has(ally.id) and not participant.threat.has(ally.id))
	_check("S2空关系不自动停用其他敌人", enemies.size() < 2 or enemies[1].activated)
	sim = _s1b_battle()["sim"]
	var supplied := _s2_inputs(sim)
	for id: int in supplied["relations"]:
		supplied["relations"][id] = {"activated": false, "engaged_allies": {}}
	var problems := sim._enable_skill_transactions(supplied["stats"], true, supplied["relations"])
	_check("S2显式未激活空集合法且不从目标补关系", problems.is_empty() and sim._skill_engaged_enemies(sim.slot_unit(0).id).is_empty())
	sim = _s2_battle()
	enemy = sim.living("enemy")[0]
	enemy.threat[sim.slot_unit(0).id] = 3.0
	sim._down(enemy, sim.slot_unit(0).id)
	_check("S2敌方死亡清激活关系仇恨", not enemy.activated and enemy.engaged_allies.is_empty() and enemy.threat.is_empty())
	for ending: String in ["leave", "finish"]:
		sim = _s2_battle()
		for participant: BattleSim.Unit in sim.living("enemy"):
			participant.threat[sim.slot_unit(0).id] = 1.0
		if ending == "leave":
			sim._leave_skill_schedule()
		else:
			sim._finish("win", "s2_fixture")
		var cleared := true
		for participant: BattleSim.Unit in sim.living("enemy"):
			cleared = cleared and not participant.activated and participant.engaged_allies.is_empty() and participant.threat.is_empty()
		_check("S2全场收尾清关系与仇恨 " + ending, cleared)


## 将旧攻击/敌方施法设为立即可执行，证明隔离依靠硬分支；合法命令、固定钟、恢复及胜负仍推进。
func _s2_isolation_cases() -> void:
	var sim := _s2_battle()
	var mage := sim.slot_unit(0)
	var enemy := sim.living("enemy")[0]
	for unit: BattleSim.Unit in sim.units.values():
		unit.next_attack_at = 0.0
		unit.attack_range = 100000.0
		unit.attack_damage = 100.0
		unit.speed = 0.0
		unit.target_id = enemy.id if unit.side == "ally" else mage.id
		unit.order_kind = "attack"
	# 敌方使用原配置的真实spell；不用延长时钟或清空spell制造“无旧攻击”。
	for unit: BattleSim.Unit in sim.living("enemy"):
		unit.spell = (sim.config["enemies"][unit.kind] as Dictionary).get("spell", {}).duplicate(true)
		unit.cast_cd_until = 0.0
	mage.res = 50.0
	mage.hp = 0.000001
	var before := _s1a_state(sim)
	_check("S2完整场旧施法零副作用拒绝", not sim.cast_skill(mage.id, "q") and _s1a_same_state(before, _s1a_state(sim)))
	sim.step(1.0)
	_check("S2完整场旧step零副作用拒绝", _s1a_same_state(before, _s1a_state(sim)))
	var queued := sim._enqueue_skill_command("target", {"battle_id": sim.skill_battle_id, "caster_id": mage.id, "target_id": enemy.id})
	var records := sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
	_check("S2完整场统一目标命令执行", queued.get("queued", false) and records.size() == 1 and records[0].get("applied", false))
	_check("S2完整场固定钟恢复且微量生命保真", sim.time == BattleSim.SKILL_FIXED_STEP and is_equal_approx(mage.res, 50.0 + 6.9875 * BattleSim.SKILL_FIXED_STEP) and mage.hp == 0.000001)
	var unchanged_hp := true
	for id: int in sim.units:
		unchanged_hp = unchanged_hp and sim.units[id].hp == before["units"][id]["hp"]
	var no_legacy := true
	for i in range(before["event_lines"].size(), sim.events.lines.size()):
		var event: Dictionary = JSON.parse_string(sim.events.lines[i])
		no_legacy = no_legacy and event["e"] not in ["damage_dealt", "heal_done", "skill_cast", "enemy_cast_started"]
	_check("S2完整场旧周期不造成攻击治疗施法", unchanged_hp and no_legacy)
	var accepted := sim._enqueue_skill_command("move", {"battle_id": sim.skill_battle_id, "caster_id": mage.id, "pos": mage.pos})
	records = sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
	_check("S2完整场移动命令仍接受执行", accepted.get("queued", false) and records.size() == 1 and records[0].get("applied", false))
	sim.set_paused(true)
	var stopped := sim.time
	sim._advance_skill_schedule(1.0)
	_check("S2完整场暂停冻结时钟", sim.time == stopped)
	sim.set_paused(false)
	sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
	_check("S2完整场恢复不补跑暂停时间", is_equal_approx(sim.time, stopped + BattleSim.SKILL_FIXED_STEP))
	sim._leave_skill_schedule()
	before = _s1a_state(sim)
	var restarted := sim._begin_skill_schedule()
	var supplied := _s2_inputs(sim)
	var problems := sim._enable_skill_transactions(_s1b2_stats(sim))
	sim.step(1.0)
	var cast := sim.cast_skill(mage.id, "r")
	_check("S2离场残留拒绝新代次及旧入口", restarted.is_empty() and not problems.is_empty() and not cast and _s1a_same_state(before, _s1a_state(sim)))
	_check("S2离场残留完整模式也须重建", not sim._enable_skill_transactions(supplied["stats"], true, supplied["relations"]).is_empty() and _s1a_same_state(before, _s1a_state(sim)))
	sim = _s2_battle()
	sim.slot_unit(0).res = 50.0
	var resolved := _s1b2_cast(sim, 73001)
	var effects: Array = resolved.get("details", {}).get("effects", [])
	_check("S2完整场仍复用已验唤醒事务", resolved.get("accepted", false) and effects.size() == 1 and is_equal_approx(effects[0].get("actual_amount", -1), 35.0))
	var fresh: BattleSim = _s1b_battle()["sim"]
	_check("S2重建新Sim仍可用原两字段入口", fresh._enable_skill_transactions(_s1b2_stats(fresh)).is_empty() and not fresh._skill_full_numeric)
	sim = _s2_battle()
	for participant: BattleSim.Unit in sim.living("enemy"):
		sim._down(participant, sim.slot_unit(0).id)
	sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
	_check("S2完整场保留胜负检查", sim.finished and sim.result == "win" and sim.reason == "all_enemies_down")


## 新单体夹具独立显式提供P100/零评级；不改旧夹具，速度0只验证事务，不代表移动表现。
func _s22_battle(rated: bool = false) -> BattleSim:
	var sim: BattleSim = _s1b_battle()["sim"]
	var inputs := _s2_inputs(sim)
	for id: int in sim.units:
		var unit: BattleSim.Unit = sim.units[id]
		var stats: Dictionary = inputs["stats"][id]
		for field: String in stats:
			stats[field] = 0.0
		stats["magic_resistance"] = 1000.0
		if unit.side == "ally":
			stats["equipment_power"] = 80.0
			if rated:
				stats.merge({"precision_rating": 1000.0, "critical_rating": 1000.0, "haste_rating": 1000.0,
					"mastery_rating": 1000.0, "penetration_rating": 1000.0}, true)
		else:
			inputs["relations"][id] = {"activated": false, "engaged_allies": {}}
			unit.max_hp = 1000.0
			unit.hp = 1000.0
	var problems := sim._enable_skill_transactions(inputs["stats"], true, inputs["relations"])
	_check("S22独立完整无盾夹具安装", problems.is_empty(), str(problems))
	sim.slot_unit(1).target_id = sim.slot_unit(0).id
	return sim


## 每次纯准备都精确比较全部状态与请求；配置错误也不能借停场清理制造零变更。
func _s22_prepare(sim: BattleSim, request: Dictionary, reason: String, label: String) -> Dictionary:
	var before := _s1a_state(sim)
	var original := request.duplicate(true)
	var prepared := sim._prepare_skill_transaction(request)
	_check("S22纯准备" + label, prepared.get("reason") == reason and prepared.get("preparable") == reason.is_empty(), str(prepared))
	_check("S22纯准备全状态保全" + label, _s1a_same_state(before, _s1a_state(sim)) and _s1a_same_state(original, request))
	return prepared


## 只取真实事务明细；缺失时返回空字典供断言报FAIL，不能伪造成功值。
func _s22_effect(resolved: Dictionary) -> Dictionary:
	var effects: Array = resolved.get("details", {}).get("effects", [])
	return effects[0] if effects.size() == 1 else {}


## 单体事务在既有同步入口执行；盾/范围/输入及异常回滚不在本组断言内。
func _s22_transaction_cases() -> void:
	_s22_formula_cases()
	_s22_threat_cases()
	_s22_reject_cases()
	_s22_queue_cases()
	_s22_notification_cases()


## A02/A06与非零评级、零量和可表示正微量；核对输入及派生量，缺仇恨键只记失败，继续后续用例。
func _s22_formula_cases() -> void:
	for mastery: float in [0.0, 1000.0]:
		var sim := _s22_battle()
		var mage := sim.slot_unit(0)
		var target := sim.living("enemy")[0]
		mage.combat_stats["mastery_rating"] = mastery
		var prepared := _s22_prepare(sim, _s1b2_request(sim, 81001, 0, "W"), "", "A02")
		var projected := sim.get_skill_view(mage.id, "W")
		_check("S22投影完整模式火球已实现且纯预检可用", projected["implemented"] and projected["preparable"])
		prepared["commit_units"][target.id]["hp"] = -999.0
		prepared["skill"]["effects"][0]["power_coeff"] = 99.0
		_check("S22准备返回生命及配置均为深副本", target.hp == 1000.0 and mage.resolved_slots["w"]["effects"][0]["power_coeff"] == 1.10)
		var before := target.hp
		var resolved := _s1b2_cast(sim, 81001, 0, "W")
		var effect := _s22_effect(resolved)
		var expected := 56.375 if mastery == 0.0 else 69.059375
		_check("S22A02火球魔抗1000及专精", resolved.get("accepted", false) and is_equal_approx(effect.get("requested_amount", -1.0), expected) and is_equal_approx(effect.get("raw_amount", -1.0), expected * 2.0))
		_check("S22火球实际量与生命差及仇恨一致", effect.get("actual_amount") == before - target.hp and target.threat.get(mage.id) == before - target.hp and is_equal_approx(before - target.hp, expected))
		_check("S22无盾范围及独立双钟", resolved.get("details", {}).get("resolution_scope") == "S2_2_UNSHIELDED" and effect.get("absorbed_amount") == 0.0 and mage.res == 85.0 and mage.gcd_until == sim.time + 1.0 and mage.skill_ready_at["mage.fire.fireball"] == sim.time + 3.0)
		var types_ok := true
		for field: String in ["cast_id", "skill_id", "effect_kind"]:
			types_ok = types_ok and effect.get(field) is String
		for field: String in ["effect_index", "target_index", "source_id", "target_id"]:
			types_ok = types_ok and effect.get(field) is int
		for field: String in ["requested_amount", "actual_amount", "hp_before", "hp_after", "raw_amount", "absorbed_amount", "overkill_amount"]:
			types_ok = types_ok and effect.get(field) is float and is_finite(effect[field])
		_check("S22效果明细字符串整数浮点类型", types_ok)
		_check("S22伤害明细守恒且身份对应本次请求", is_equal_approx(effect["requested_amount"], effect["absorbed_amount"] + effect["actual_amount"] + effect["overkill_amount"]) and effect["cast_id"] == resolved.get("cast_id") and effect["skill_id"] == "mage.fire.fireball" and effect["source_id"] == mage.id and effect["target_id"] == target.id)
	for missing: float in [100.0, 0.0, 300.0]:
		var sim := _s22_battle()
		var receiver := sim.slot_unit(0)
		receiver.max_hp = 1000.0
		receiver.hp = 1000.0 - missing
		var resolved := _s1b2_cast(sim, 81002, 1, "Q")
		var effect := _s22_effect(resolved)
		var actual := minf(missing, 246.0)
		_check("S22A06有效过量及满血仍成功", resolved.get("accepted", false) and is_equal_approx(effect.get("requested_amount", -1.0), 246.0) and effect.get("actual_amount") == actual and is_equal_approx(effect.get("overheal_amount", -1.0), 246.0 - actual) and receiver.hp == 1000.0 - missing + actual)
		_check("S22治疗效果量守恒及生命差", is_equal_approx(effect.get("requested_amount", -1.0), effect.get("actual_amount", -1.0) + effect.get("overheal_amount", -1.0)) and effect.get("actual_amount") == effect.get("hp_after", 0.0) - effect.get("hp_before", 0.0))
		_check("S22治疗无集合不加仇恨且启动费用CD", effect.get("threat_changes", [-1]).is_empty() and sim.slot_unit(1).res == 75.0 and sim.slot_unit(1).skill_ready_at["priest.holy.greater_heal"] == sim.time + 5.0)
	var sim := _s22_battle(true)
	var mage := sim.slot_unit(0)
	var target := sim.living("enemy")[0]
	target.combat_stats["evasion_rating"] = 400.0
	target.combat_stats["damage_reduction"] = 0.2
	var effect := _s22_effect(_s1b2_cast(sim, 81003, 0, "W"))
	var q := 1.0 + 0.25 * 600.0 / 2400.0
	var expected := 110.0 * 1.225 * q * 1.1375 * (1000.0 / 1825.0) * 0.8
	_check("S22非零精准回避穿透减伤暴击专精", is_equal_approx(effect.get("requested_amount", -1.0), expected) and is_equal_approx(mage.gcd_until - sim.time, 1.0 / 1.15))
	sim = _s22_battle(true)
	var priest := sim.slot_unit(1)
	priest.target_id = priest.id
	priest.max_hp = 1000.0
	priest.hp = 1.0
	priest.combat_stats["healing_bonus"] = 0.1
	priest.combat_stats["damage_reduction"] = 0.6
	priest.magic_resist = 1.0e100
	effect = _s22_effect(_s1b2_cast(sim, 81004, 1, "Q"))
	_check("S22非零评级自疗不乘防护精准减伤", is_equal_approx(effect.get("requested_amount", -1.0), 240.0 * 1.1 * 1.225 * 1.1375) and effect.get("actual_amount") == priest.hp - 1.0)
	for key: String in ["damage_zero", "heal_zero", "damage_tiny", "heal_tiny"]:
		sim = _s22_battle()
		mage = sim.slot_unit(0)
		target = sim.living("enemy")[0]
		priest = sim.slot_unit(1)
		var healing: bool = key.begins_with("heal")
		var caster := priest if healing else mage
		if key.ends_with("zero"):
			caster.combat_stats["power_bonus"] = -1.0
		else:
			# 本夹具选用距−1足够远的显式输入；仍以原微量上限及实际生命差验证，不推广引擎字面量观察。
			caster.combat_stats["power_bonus"] = -0.99999999999999
		var zero: bool = key.ends_with("zero")
		var power_multiplier: float = 1.0 + float(caster.combat_stats["power_bonus"])
		var derived: Dictionary = sim._skill_derived_parameters(caster)
		var fixture_detail := "case=%s power_bonus=%s multiplier=%s derived=%s" % [key, caster.combat_stats["power_bonus"], power_multiplier, derived]
		# 先区分零量和正微量输入与派生强度，避免实际归零仍被当成微量执行。
		_check("S22零量微量输入及派生强度" + key, derived["problems"].is_empty() and derived.has("power") and (power_multiplier == 0.0 and derived["power"] == 0.0 if zero else power_multiplier > 0.0 and derived["power"] > 0.0), fixture_detail)
		if healing:
			mage.max_hp = 1000.0
			mage.hp = 1.0
		else:
			target.hp = 1.0
		var hp_before := mage.hp if healing else target.hp
		var resolved := _s1b2_cast(sim, 81005, 1 if healing else 0, "Q" if healing else "W")
		effect = _s22_effect(resolved)
		var delta := mage.hp - hp_before if healing else hp_before - target.hp
		var result_detail := "%s resolved=%s hp_before=%s delta=%s threat=%s" % [fixture_detail, resolved, hp_before, delta, target.threat]
		var requested: Variant = effect.get("requested_amount")
		_check("S22零量微量请求量明确区分" + key, requested is float and (requested == 0.0 if zero else requested > 0.0), result_detail)
		_check("S22零量微量无保底" + key, resolved.get("accepted", false) and effect.get("actual_amount") == delta and (delta == 0.0 if key.ends_with("zero") else delta > 0.0 and delta < 0.000001), result_detail)
		if not healing:
			# 缺键必须成为普通FAIL，不补默认仇恨或直接索引崩溃，使后续heal_tiny仍可执行。
			_check("S22成功零量也建立权威关系", target.activated and target.engaged_allies.has(mage.id) and (not target.threat.has(mage.id) if key.ends_with("zero") else target.threat.has(mage.id) and target.threat[mage.id] == delta), result_detail)


## 治疗快照只从权威交战集合取，稳定均分且不扩张；致死步骤明细与最终清理分开观察。
func _s22_threat_cases() -> void:
	var sim := _s22_battle()
	var mage := sim.slot_unit(0)
	var priest := sim.slot_unit(1)
	var enemies := sim.living("enemy")
	mage.max_hp = 1000.0
	mage.hp = 900.0
	# 只有两个敌人激活且关联被治疗者；第三个虽有仇恨键、邻近和当前目标仍须排除。
	for i in 2:
		enemies[i].activated = true
		enemies[i].engaged_allies[mage.id] = true
		enemies[i].threat[priest.id] = float(i * 10)
	enemies[2].activated = true
	enemies[2].threat[mage.id] = 999.0
	enemies[2].target_id = mage.id
	var effect := _s22_effect(_s1b2_cast(sim, 82001, 1, "Q"))
	var changes: Array = effect.get("threat_changes", [])
	_check("S22治疗100有效量20百分比快照均分", changes.size() == 2 and changes[0]["enemy_id"] == enemies[0].id and changes[1]["enemy_id"] == enemies[1].id and changes[0]["amount"] == 10.0 and changes[1]["amount"] == 10.0 and enemies[0].threat[priest.id] == 10.0 and enemies[1].threat[priest.id] == 20.0)
	_check("S22关系新增不扩张本次快照", effect.get("engagements_added") == [enemies[0].id, enemies[1].id] and enemies[0].engaged_allies.has(priest.id) and enemies[1].engaged_allies.has(priest.id) and not enemies[2].engaged_allies.has(priest.id) and not enemies[2].threat.has(priest.id))
	var typed := true
	for change: Dictionary in changes:
		typed = typed and change["enemy_id"] is int and change["source_id"] is int and change["amount"] is float and change["before"] is float and change["after"] is float
	_check("S22仇恨步骤明细类型", typed)
	sim = _s22_battle()
	mage = sim.slot_unit(0)
	var victim := sim.living("enemy")[0]
	victim.hp = 10.0
	victim.activated = true
	victim.engaged_allies[mage.id] = true
	victim.threat[mage.id] = 9.0
	effect = _s22_effect(_s1b2_cast(sim, 82002, 0, "W"))
	_check("S22致死仅有效伤害生仇恨过量独立", effect.get("actual_amount") == 10.0 and is_equal_approx(effect.get("overkill_amount", -1.0), 46.375) and effect["threat_changes"][0]["before"] == 9.0 and effect["threat_changes"][0]["after"] == 19.0)
	_check("S22致死提交清生命激活关系和仇恨", not victim.alive and victim.hp == 0.0 and not victim.activated and victim.engaged_allies.is_empty() and victim.threat.is_empty())
	# 治疗满血时既不加仇恨也不建立治疗者关系，即使权威集合非空。
	sim = _s22_battle()
	mage = sim.slot_unit(0)
	priest = sim.slot_unit(1)
	victim = sim.living("enemy")[0]
	victim.activated = true
	victim.engaged_allies[mage.id] = true
	effect = _s22_effect(_s1b2_cast(sim, 82003, 1, "Q"))
	_check("S22满血快照不生仇恨关系", effect.get("actual_amount") == 0.0 and effect["threat_changes"].is_empty() and effect["engagements_added"].is_empty() and not victim.engaged_allies.has(priest.id))


## 坏状态、各步溢出和不可表达增量均纯准备拒绝；执行停场另验，绝不要求错误停场全状态不变。
func _s22_reject_cases() -> void:
	for label: String in ["bad_hp", "bad_stats", "bad_relation", "bad_threat", "dead_threat", "formula_overflow", "q_overflow", "threat_overflow", "hp_precision", "heal_precision", "threat_precision", "heal_threat_precision", "heal_threat_overflow", "bad_death_status", "resource_changed"]:
		var sim := _s22_battle()
		var mage := sim.slot_unit(0)
		var priest := sim.slot_unit(1)
		var target := sim.living("enemy")[0]
		var request := _s1b2_request(sim, 83001, 0, "W")
		match label:
			"bad_hp":
				target.hp = NAN
			"bad_stats":
				target.combat_stats["evasion_rating"] = true
			"bad_relation":
				target.engaged_allies[priest.id] = false
			"bad_threat":
				target.threat[mage.id] = INF
			"dead_threat":
				var other := sim.living("enemy")[1]
				other.hp = 0.0
				other.alive = false
				other.threat[mage.id] = 1.0
			"formula_overflow":
				mage.combat_stats["equipment_power"] = 1.7e308
			"q_overflow":
				mage.combat_stats["precision_rating"] = 1.0e308
				target.combat_stats["evasion_rating"] = 1.0e308
			"threat_overflow":
				mage.combat_stats["equipment_power"] = 1.0e308
				target.max_hp = 1.7e308
				target.hp = 1.5e308
				target.threat[mage.id] = 1.5e308
			"hp_precision":
				target.max_hp = 1.0e30
				target.hp = 1.0e30
			"heal_precision":
				mage.max_hp = 2.0e30
				mage.hp = 1.0e30
				request = _s1b2_request(sim, 83001, 1, "Q")
			"threat_precision":
				target.threat[mage.id] = 1.0e30
			"heal_threat_precision", "heal_threat_overflow":
				mage.max_hp = 1000.0
				mage.hp = 900.0
				target.activated = true
				target.engaged_allies[mage.id] = true
				target.threat[priest.id] = 1.0e30
				request = _s1b2_request(sim, 83001, 1, "Q")
				if label == "heal_threat_overflow":
					priest.combat_stats["equipment_power"] = 1.0e307
					mage.max_hp = 1.0e308
					mage.hp = 1.0
					target.threat[priest.id] = 1.79e308
			"bad_death_status":
				target.hp = 1.0
				target.statuses["bad"] = {"source": true, "until": 100.0}
			"resource_changed":
				mage.resolved_slots["w"]["effects"][0]["power_coeff"] = 1.2
		_s22_prepare(sim, request, "CONFIG_ERROR", label)
	var sim := _s22_battle()
	var mage := sim.slot_unit(0)
	var victim := sim.living("enemy")[0]
	victim.threat[mage.id] = 1.0e30
	var hp_before := victim.hp
	var mana_before := mage.res
	var resolved := _s1b2_cast(sim, 83002, 0, "W")
	_check("S22执行配置错误停场且不提交费用生命", not resolved.get("accepted", true) and resolved.get("reason") == "CONFIG_ERROR" and sim.finished and sim.result == "error" and sim._skill_pending.is_empty() and victim.hp == hp_before and mage.res == mana_before and mage.gcd_until == 0.0 and mage.skill_ready_at.is_empty())
	_check("S22执行配置错误沿用关系清理", victim.threat.is_empty() and not victim.activated and victim.engaged_allies.is_empty() and _s1b2_results(sim).size() == 1)
	for code: String in ["STALE_BATTLE", "BATTLE_PAUSED", "INPUT_LOCKED", "NO_CASTER", "CASTER_DOWN", "EMPTY_SLOT", "SKILL_CHANGED", "INVALID_TARGET", "OUT_OF_RANGE", "NOT_ENOUGH_MANA", "GCD_ACTIVE", "SKILL_COOLDOWN"]:
		sim = _s22_battle()
		mage = sim.slot_unit(0)
		victim = sim.living("enemy")[0]
		var request := _s1b2_request(sim, 83003, 0, "W")
		# 多个后续错误同时存在，逐步去掉更高优先级，证明既有优先级没有被最终预演抢占。
		mage.res = 0.0 if code in ["STALE_BATTLE", "BATTLE_PAUSED", "INPUT_LOCKED", "NO_CASTER", "CASTER_DOWN", "EMPTY_SLOT", "SKILL_CHANGED", "INVALID_TARGET", "OUT_OF_RANGE", "NOT_ENOUGH_MANA"] else 100.0
		mage.gcd_until = 10.0 if code != "SKILL_COOLDOWN" else 0.0
		mage.skill_ready_at["mage.fire.fireball"] = 20.0
		match code:
			"STALE_BATTLE":
				request["battle_id"] = "old"
			"BATTLE_PAUSED":
				sim.paused = true
			"INPUT_LOCKED":
				sim.skill_input_locked = true
			"NO_CASTER":
				request["caster_id"] = -999
			"CASTER_DOWN":
				mage.alive = false
				mage.hp = 0.0
			"EMPTY_SLOT":
				request["slot"] = "X"
			"SKILL_CHANGED":
				request["expected_skill_id"] = "wrong"
			"INVALID_TARGET":
				mage.target_id = -999
			"OUT_OF_RANGE":
				victim.pos = mage.pos + Vector2(801.0, 0)
		_s22_prepare(sim, request, code, code)
	# 旧两字段仍只接唤醒；完整场范围/屏障不能借合法Resource绕过支持范围。
	var legacy := _s1b2_battle()
	_s22_prepare(legacy, _s1b2_request(legacy, 83004, 0, "W"), "CONFIG_ERROR", "两字段拒绝火球")
	_check("S22两字段唤醒保留", _s1b2_cast(legacy, 83005).get("accepted", false))
	for key: String in ["Q", "E"]:
		sim = _s22_battle()
		_s22_prepare(sim, _s1b2_request(sim, 83006, 0, key), "CONFIG_ERROR", "范围屏障拒绝" + key)


## 重复、同点GCD、深副本及回调下一点；使用原队列，不直接调用执行函数冒充调度。
func _s22_queue_cases() -> void:
	var sim := _s22_battle()
	var mage := sim.slot_unit(0)
	var request := _s1b2_request(sim, 84001, 0, "W")
	var queued := sim._enqueue_skill_command("cast", request)
	var duplicate := sim._enqueue_skill_command("cast", request)
	sim._enqueue_skill_command("cast", _s1b2_request(sim, 84002, 0, "W"))
	var records := sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
	_check("S22重复及同点GCD", queued.get("queued", false) and duplicate.get("reason") == "DUPLICATE_REQUEST" and records.size() == 2 and records[0]["result"].get("accepted", false) and records[1]["result"].get("reason") == "GCD_ACTIVE" and _s1b2_results(sim).size() == 2 and mage.res == 85.0)
	sim = _s22_battle()
	mage = sim.slot_unit(0)
	var target := sim.living("enemy")[0]
	var callback_state := {"complete": false, "queued": false, "reentry": false}
	# 结果回调只观察完整生命/仇恨，再入队另一角色唤醒；篡改事件副本不能回写返回值或Unit。
	var on_result := func(data: Dictionary) -> void:
		if data.get("request_seq") != 84003:
			return
		var effect := _s22_effect(data)
		callback_state["complete"] = effect.get("hp_after") == target.hp and effect.get("actual_amount") == target.threat.get(mage.id) and mage.res == 85.0 and mage.skill_ready_at.has("mage.fire.fireball")
		callback_state["queued"] = sim._enqueue_skill_command("cast", _s1b2_request(sim, 84004, 2, "R")).get("queued", false)
		callback_state["reentry"] = sim._advance_skill_schedule(1.0).is_empty()
		data["details"]["effects"][0]["actual_amount"] = -999.0
		data["details"]["effects"][0]["threat_changes"].clear()
	sim.events.cast_resolved.connect(on_result)
	var resolved := _s1b2_cast(sim, 84003, 0, "W")
	_check("S22同步回调完整状态重入及下一点队列", callback_state["complete"] and callback_state["queued"] and callback_state["reentry"] and _s1b2_results(sim).size() == 1 and sim._skill_pending.size() == 1)
	_check("S22事件深副本不改返回或仇恨", _s22_effect(resolved).get("actual_amount", -1.0) > 0.0 and _s22_effect(resolved)["threat_changes"].size() == 1 and target.threat[mage.id] > 0.0)
	sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
	_check("S22回调命令只在下一执行点生效", _s1b2_results(sim).size() == 2 and sim.slot_unit(2).skill_ready_at.has("mage.fire.evocation"))
	sim.events.cast_resolved.disconnect(on_result)
	# prepare命令与投影须和最终数值纯准备一致，不能只看早期目标/费用通过。
	sim = _s22_battle()
	mage = sim.slot_unit(0)
	target = sim.living("enemy")[0]
	target.max_hp = 1.0e30
	target.hp = 1.0e30
	var before := _s1a_state(sim)
	var view := sim.get_skill_view(mage.id, "W")
	_check("S22投影运算失败仍为纯查询", view["implemented"] and not view["preparable"] and view["reason"] == "CONFIG_ERROR" and _s1a_same_state(before, _s1a_state(sim)))
	sim._enqueue_skill_command("prepare", _s1b2_request(sim, 84005, 0, "W"))
	records = sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
	_check("S22prepare命令拒绝但不执行停场或结果", records.size() == 1 and records[0]["preparation"].get("reason") == "CONFIG_ERROR" and not sim.finished and sim._skill_validation_error.is_empty() and _s1b2_results(sim).is_empty())


## 致死状态先完整提交，再结果/状态清理/倒下/胜负；换场切断旧通知，暂停只冻结后续推进。
func _s22_notification_cases() -> void:
	for mode: String in ["normal", "pause", "leave", "new_field", "leave_status", "leave_down"]:
		var sim := _s22_battle()
		var mage := sim.slot_unit(0)
		var victim := sim.living("enemy")[0]
		# 仅当前新夹具预置其余敌人为合法死亡状态，保留目标来验证最后一击与胜负顺序。
		for other: BattleSim.Unit in sim.living("enemy"):
			if other.id != victim.id:
				other.hp = 0.0
				other.alive = false
		victim.hp = 10.0
		victim.activated = true
		victim.engaged_allies[mage.id] = true
		victim.threat[mage.id] = 9.0
		victim.statuses["mark"] = {"source": mage.id, "until": 100.0}
		victim.cast = {"skill_id": "old_spell"}
		var sequence: Array[String] = []
		var observed := {"complete": false, "down_complete": false, "fresh": null, "fresh_before": {}}
		# 第一回调必须已经看到全部死亡清理；暂停不应让缓存死亡通知消失。
		var on_result := func(data: Dictionary) -> void:
			sequence.append("result")
			observed["complete"] = data.get("accepted", false) and data.get("details", {}).get("defeated_ids") == [victim.id] and not victim.alive and victim.hp == 0.0 and victim.threat.is_empty() and victim.engaged_allies.is_empty() and not victim.activated and victim.statuses.is_empty() and victim.cast.is_empty() and not sim.finished
			if mode == "pause":
				sim.set_paused(true)
			elif mode in ["leave", "new_field"]:
				sim._leave_skill_schedule()
				if mode == "new_field":
					var fresh := _s22_battle()
					observed["fresh"] = fresh
					observed["fresh_before"] = _s1a_state(fresh)
		# 缓存状态通知只报既有事件，不能复用旧_down再做一轮清理。
		var on_status := func(_id: int, _status: String, _source: int, _until: float) -> void:
			sequence.append("status")
			if mode == "leave_status":
				sim._leave_skill_schedule()
		# 倒下回调也应看到完整最终状态，而不是等待该回调之后才清理关系。
		var on_down := func(_id: int, _by: int) -> void:
			sequence.append("down")
			observed["down_complete"] = not victim.alive and victim.statuses.is_empty() and victim.threat.is_empty()
			if mode == "leave_down":
				sim._leave_skill_schedule()
		# 胜负通知必须最后，不能在cast_resolved以前把最后一击藏掉。
		var on_end := func(_result: String, _reason: String, _elapsed: float) -> void:
			sequence.append("end")
		sim.events.cast_resolved.connect(on_result)
		sim.events.status_expired.connect(on_status)
		sim.events.unit_downed.connect(on_down)
		sim.events.battle_ended.connect(on_end)
		var event_start := sim.events.lines.size()
		var resolved := _s1b2_cast(sim, 85001, 0, "W")
		_check("S22致死结果可见完整提交" + mode, observed["complete"] and _s1b2_results(sim).size() == 1 and resolved.get("details", {}).get("defeated_ids") == [victim.id])
		if mode == "normal":
			_check("S22结果状态倒下胜负严格顺序", sequence == ["result", "status", "down", "end"] and observed["down_complete"] and sim.finished and sim.result == "win")
		elif mode == "pause":
			_check("S22暂停不撤销已提交死亡通知", sequence == ["result", "status", "down"] and observed["down_complete"] and sim.paused and not sim.finished)
			sim.set_paused(false)
			sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
			_check("S22恢复后胜负只补发一次", sequence == ["result", "status", "down", "end"] and sim.result == "win")
		elif mode in ["leave_status", "leave_down"]:
			_check("S22死亡通知中离场停止后续通知" + mode, sequence == (["result", "status"] if mode == "leave_status" else ["result", "status", "down"]) and sim.skill_battle_id.is_empty() and not sim.finished)
		else:
			_check("S22离场换场停止旧通知" + mode, sequence == ["result"] and sim.skill_battle_id.is_empty() and sim._skill_pending.is_empty() and not sim.finished)
			if mode == "new_field":
				_check("S22旧链不污染新场或检查新场胜负", _s1a_same_state(observed["fresh_before"], _s1a_state(observed["fresh"])))
		var no_legacy := true
		for i in range(event_start, sim.events.lines.size()):
			var line: Dictionary = JSON.parse_string(sim.events.lines[i])
			no_legacy = no_legacy and line["e"] not in ["damage_dealt", "heal_done", "skill_cast"]
		_check("S22新事务不发重复旧施法伤害治疗通知" + mode, no_legacy)
		sim.events.cast_resolved.disconnect(on_result)
		sim.events.status_expired.disconnect(on_status)
		sim.events.unit_downed.disconnect(on_down)
		sim.events.battle_ended.disconnect(on_end)


## S23独立未安装夹具：P100、零评级、零魔抗；不修改S22或旧输入，旧攻击仍关闭。
func _s23_uninstalled() -> Dictionary:
	var sim: BattleSim = _s1b_battle()["sim"]
	var inputs := _s2_inputs(sim)
	for id: int in sim.units:
		var unit: BattleSim.Unit = sim.units[id]
		for field: String in inputs["stats"][id]:
			inputs["stats"][id][field] = 0.0
		if unit.side == "ally":
			inputs["stats"][id]["equipment_power"] = 80.0
		else:
			# 新夹具独立采用128生命，便于精确核对盾/生命预算；不改S22的1000生命。
			unit.hp = 128.0
			unit.max_hp = 128.0
			inputs["relations"][id] = {"activated": false, "engaged_allies": {}}
	return {"sim": sim, "inputs": inputs}


## 仅本组夹具通过首次原子安装建立合法盾；可选同阵营其他来源，不伪造敌方施法。
func _s23_battle(amount: float = 0.0, enemy_shield: bool = false, expires_at: float = 100.0, other_source: bool = false) -> BattleSim:
	var fixture := _s23_uninstalled()
	var sim: BattleSim = fixture["sim"]
	var inputs: Dictionary = fixture["inputs"]
	var initial: Dictionary = {}
	if amount > 0.0:
		var target: BattleSim.Unit = sim.living("enemy")[0] if enemy_shield else sim.slot_unit(0)
		var source: BattleSim.Unit = (sim.living("enemy")[1] if enemy_shield else sim.slot_unit(2)) if other_source else target
		initial[target.id] = {"source_id": source.id, "remaining": amount, "expires_at": expires_at}
	var problems := sim._enable_skill_transactions(inputs["stats"], true, inputs["relations"], "S2_3_SHIELD_AWARE", initial)
	_check("S23独立完整盾夹具安装", problems.is_empty(), str(problems))
	sim.slot_unit(1).target_id = sim.slot_unit(0).id
	return sim


## 每次S23预检精确比较全部真实状态与请求；错误不得借停场或到期清池改变战场。
func _s23_prepare(sim: BattleSim, request: Dictionary, reason: String, label: String) -> Dictionary:
	var before := _s1a_state(sim)
	var original := request.duplicate(true)
	var prepared := sim._prepare_skill_transaction(request)
	_check("S23纯准备" + label, prepared.get("reason") == reason and prepared.get("preparable") == reason.is_empty(), str(prepared))
	_check("S23纯准备全状态零变更" + label, _s1a_same_state(before, _s1a_state(sim)) and _s1a_same_state(original, request))
	return prepared


## A段验证单盾/火球及普通生命尺度精度回归；范围和系统输入不在本组授权内。
func _s23_shield_cases() -> void:
	_s23_install_cases()
	_s23_barrier_cases()
	_s23_absorption_cases()
	_s23_precision_cases()
	_s23_clock_cases()
	_s23_lifecycle_cases()
	_s23_reject_cases()


## 初始盾输入与属性/关系一起原子拒绝；合法敌盾和死亡仍在场来源也走安装器。
func _s23_install_cases() -> void:
	for variant: String in ["missing", "extra", "identity", "cast_identity", "source_bool", "source_string", "source_missing", "wrong_side", "target_missing", "target_bool", "dead_target", "zero", "negative", "remaining_bool", "remaining_string", "nan", "infinite", "expired", "deadline_bool", "deadline_nan", "deadline_inf", "stats", "relations"]:
		var fixture := _s23_uninstalled()
		var sim: BattleSim = fixture["sim"]
		var inputs: Dictionary = fixture["inputs"]
		var target := sim.living("enemy")[0]
		var entry := {"source_id": target.id, "remaining": 150.0, "expires_at": 6.0}
		var initial := {target.id: entry}
		match variant:
			"missing": entry.erase("remaining")
			"extra": entry["extra"] = 1
			"identity": entry["shield_id"] = "forged"
			"cast_identity": entry["source_cast_id"] = "forged"
			"source_bool": entry["source_id"] = true
			"source_string": entry["source_id"] = str(target.id)
			"source_missing": entry["source_id"] = 999999
			"wrong_side": entry["source_id"] = sim.slot_unit(0).id
			"target_missing": initial = {999999: entry}
			"target_bool": initial = {true: entry}
			"dead_target":
				target.hp = 0.0
				target.alive = false
			"zero": entry["remaining"] = 0.0
			"negative": entry["remaining"] = -1.0
			"remaining_bool": entry["remaining"] = true
			"remaining_string": entry["remaining"] = "150"
			"nan": entry["remaining"] = NAN
			"infinite": entry["remaining"] = INF
			"expired": entry["expires_at"] = 0.0
			"deadline_bool": entry["expires_at"] = true
			"deadline_nan": entry["expires_at"] = NAN
			"deadline_inf": entry["expires_at"] = INF
			"stats": inputs["stats"][sim.slot_unit(2).id].erase("spirit")
			"relations": inputs["relations"][target.id]["activated"] = "true"
		# 在另一个合法目标同时提供盾，证明不是只拒绝坏项却提前安装其他单位。
		var second := sim.living("enemy")[-1]
		initial[second.id] = {"source_id": second.id, "remaining": 40, "expires_at": 7}
		var before := _s1a_state(sim)
		var copied := initial.duplicate(true)
		var problems := sim._enable_skill_transactions(inputs["stats"], true, inputs["relations"], "S2_3_SHIELD_AWARE", initial)
		_check("S23非法安装全量零变更" + variant, not problems.is_empty() and _s1a_same_state(before, _s1a_state(sim)) and _s1a_same_state(copied, initial), str(problems))
	for variant: String in ["bad_scope", "two_field_scope", "two_field_initial", "s22_initial"]:
		var fixture := _s23_uninstalled()
		var sim: BattleSim = fixture["sim"]
		var target := sim.living("enemy")[0]
		var initial := {target.id: {"source_id": target.id, "remaining": 10.0, "expires_at": 5.0}}
		var before := _s1a_state(sim)
		var scope := "bad" if variant == "bad_scope" else ("S2_3_SHIELD_AWARE" if variant == "two_field_scope" else "S2_2_UNSHIELDED")
		var full := variant in ["bad_scope", "s22_initial"]
		var problems := sim._enable_skill_transactions(fixture["inputs"]["stats"], full, fixture["inputs"]["relations"], scope, {} if variant == "two_field_scope" else initial)
		_check("S23入口门禁先于旧失败副作用" + variant, not problems.is_empty() and _s1a_same_state(before, _s1a_state(sim)))
	var fixture := _s23_uninstalled()
	var sim: BattleSim = fixture["sim"]
	var target := sim.living("enemy")[0]
	var source := sim.living("enemy")[1]
	source.hp = 0.0
	source.alive = false
	var entry := {"source_id": source.id, "remaining": 150, "expires_at": 6}
	var initial := {target.id: entry}
	var problems := sim._enable_skill_transactions(fixture["inputs"]["stats"], true, fixture["inputs"]["relations"], "S2_3_SHIELD_AWARE", initial)
	_check("S23死亡来源仍在场可合法安装及数值转float", problems.is_empty() and target.shield.size() == 5 and target.shield["remaining"] is float and target.shield["expires_at"] is float and sim._skill_shield_problems(target).is_empty())
	entry["remaining"] = 999.0
	initial.clear()
	_check("S23安装输入深副本及独立初始化身份", target.shield.get("remaining") == 150.0 and target.shield.get("source_cast_id") == "%s:initial:%d:%d" % [sim.skill_battle_id, source.id, target.id] and sim._skill_receive_seq == 0 and _s1b2_results(sim).is_empty())
	var before := _s1a_state(sim)
	problems = sim._enable_skill_transactions(fixture["inputs"]["stats"], true, fixture["inputs"]["relations"], "S2_3_SHIELD_AWARE", {target.id: {"source_id": source.id, "remaining": 100.0, "expires_at": 10.0}})
	_check("S23启用后禁止重装且全状态零变更", not problems.is_empty() and _s1a_same_state(before, _s1a_state(sim)))


## 屏障新建/保留/替换/零量口径及净增；费用双钟由同一提交写入，保持旧scope拒绝屏障。
func _s23_barrier_cases() -> void:
	for old_amount: float in [0.0, 160.0, 150.0, 149.0]:
		var sim := _s23_battle(old_amount, false, 100.0, true)
		var mage := sim.slot_unit(0)
		var before := mage.shield.duplicate(true)
		var projected := sim.get_skill_view(mage.id, "E")
		_check("S23屏障投影与纯准备已实现", projected["implemented"] and projected["preparable"])
		var prepared := _s23_prepare(sim, _s1b2_request(sim, 91001, 0, "E"), "", "屏障" + str(old_amount))
		if not prepared.get("preparable", false):
			continue
		prepared["commit_units"][mage.id]["shield"]["remaining"] = -1.0
		_check("S23准备盾深副本", _s1a_same_state(before, mage.shield))
		var resolved := _s1b2_cast(sim, 91001, 0, "E")
		var effect := _s22_effect(resolved)
		var action := "created" if old_amount == 0.0 else ("replaced" if old_amount < 150.0 else "retained")
		_check("S23屏障动作实得净增" + str(old_amount), resolved.get("accepted", false) and effect.get("shield_action") == action and effect.get("actual_amount") == maxf(0.0, 150.0 - old_amount) and mage.shield.get("remaining") == maxf(old_amount, 150.0), str(resolved))
		if not resolved.get("accepted", false):
			continue
		_check("S23R1屏障各动作公共生命字段" + action, effect.get("hp_before") is float and effect.get("hp_after") is float and is_finite(effect["hp_before"]) and is_finite(effect["hp_after"]) and effect["hp_before"] == mage.hp and effect["hp_after"] == mage.hp)
		_check("S23屏障费用独立CD及scope", mage.res == 80.0 and mage.gcd_until == sim.time + 1.0 and mage.skill_ready_at.get("mage.fire.flame_barrier") == sim.time + 16.0 and resolved.get("details", {}).get("resolution_scope") == "S2_3_SHIELD_AWARE")
		if action == "retained":
			_check("S23保留原来源身份与截止" + str(old_amount), _s1a_same_state(before, mage.shield) and resolved["details"]["shield_changes"].is_empty())
		else:
			_check("S23真实盾身份关联已提交请求", mage.shield["source_cast_id"] == resolved["cast_id"] and sim._skill_shield_problems(mage).is_empty() and mage.shield["expires_at"] == sim.time + 6.0)
			_check("S23替换仅记录replaced", resolved["details"]["shield_changes"].size() == (1 if action == "replaced" else 0) and (action != "replaced" or resolved["details"]["shield_changes"][0]["reason"] == "replaced"))
	for old_amount: float in [0.0, 160.0]:
		var sim := _s23_battle(old_amount)
		var mage := sim.slot_unit(0)
		mage.combat_stats["power_bonus"] = -1.0
		var before := mage.shield.duplicate(true)
		var effect := _s22_effect(_s1b2_cast(sim, 91002, 0, "E"))
		_check("S23零盾不建立或替换但仍扣费开钟" + str(old_amount), effect.get("shield_action") == "zero" and effect.get("actual_amount") == 0.0 and mage.res == 80.0 and mage.skill_ready_at.has("mage.fire.flame_barrier") and _s1a_same_state(before, mage.shield))
		_check("S23R1零盾公共生命字段", effect.get("hp_before") is float and effect.get("hp_after") is float and is_finite(effect["hp_before"]) and effect["hp_before"] == mage.hp and effect["hp_after"] == mage.hp)
	var legacy := _s22_battle()
	_s23_prepare(legacy, _s1b2_request(legacy, 91003, 0, "E"), "CONFIG_ERROR", "S22仍拒绝屏障")
	var sim := _s23_battle()
	_s23_prepare(sim, _s1b2_request(sim, 91004, 0, "Q"), "", "B爆破成功预检")
	var wake := _s1b2_cast(sim, 91005, 0, "R")
	_check("S23唤醒沿旧明细不改scope", wake.get("accepted", false) and not wake["details"].has("resolution_scope") and _s22_effect(wake)["effect_kind"] == "RESTORE_MANA")


	# 非零评级在安装前显式传入，盾不乘暴击/专精/急速；只有GCD使用急速派生。
	var fixture := _s23_uninstalled()
	var rated: BattleSim = fixture["sim"]
	var caster := rated.slot_unit(0)
	fixture["inputs"]["stats"][caster.id].merge({"critical_rating": 1000.0, "mastery_rating": 1000.0, "haste_rating": 1000.0}, true)
	var issues := rated._enable_skill_transactions(fixture["inputs"]["stats"], true, fixture["inputs"]["relations"], "S2_3_SHIELD_AWARE")
	_check("S23非零评级夹具安装", issues.is_empty(), str(issues))
	var barrier := _s1b2_cast(rated, 91006, 0, "E")
	_check("S23屏障不乘暴击专精且持续CD不受急速", barrier.get("accepted", false) and _s22_effect(barrier).get("actual_amount") == 150.0 and caster.shield.get("expires_at") == rated.time + 6.0 and caster.skill_ready_at.get("mage.fire.flame_barrier") == rated.time + 16.0 and is_equal_approx(caster.gcd_until - rated.time, 1.0 / 1.15))
	var healing := _s23_battle(150.0)
	var receiver := healing.slot_unit(0)
	receiver.hp = receiver.max_hp - 10.0
	var original_pool := receiver.shield.duplicate(true)
	var healed := _s1b2_cast(healing, 91007, 1, "Q")
	_check("S23治疗不吸收也不改盾", healed.get("accepted", false) and _s22_effect(healed).get("actual_amount") == 10.0 and healed["details"]["shield_changes"].is_empty() and _s1a_same_state(original_pool, receiver.shield))


## 合法敌方初始盾只证明目标数学：分开核对名义预算与真实差，不用浮点分项总和限制结算。
func _s23_absorption_cases() -> void:
	for amount: float in [150.0, 50.0]:
		var sim := _s23_battle(amount, true)
		var mage := sim.slot_unit(0)
		var target := sim.living("enemy")[0]
		var original := target.shield.duplicate(true)
		var before := target.hp
		var resolved := _s1b2_cast(sim, 92001, 0, "W")
		var effect := _s22_effect(resolved)
		_check("S23合法敌盾火球完成" + str(amount), resolved.get("accepted", false), str(resolved))
		if not resolved.get("accepted", false):
			continue
		var absorbed: float = effect["absorbed_amount"]
		var nominal_absorb := minf(amount, float(effect["requested_amount"]))
		var hp_budget := float(effect["requested_amount"]) - nominal_absorb
		# 名义预算约束最终状态；实际量分别等于状态差，不能用过量补舍入残差。
		_check("S23吸收仅盾差生命及仇恨仅HP差" + str(amount), absorbed == amount - float(target.shield.get("remaining", 0.0)) and effect["actual_amount"] == before - target.hp and float(target.threat.get(mage.id, 0.0)) == effect["actual_amount"] and target.hp == maxf(0.0, before - minf(before, hp_budget)) and float(target.shield.get("remaining", 0.0)) == maxf(0.0, amount - nominal_absorb) and effect["overkill_amount"] == maxf(0.0, hp_budget - before))
		_check("S23吸收明细来源与耗尽不重复" + str(amount), effect["absorptions"].size() == 1 and effect["absorptions"][0]["shield_id"] == original["shield_id"] and effect["absorptions"][0]["depleted"] == target.shield.is_empty() and resolved["details"]["shield_changes"].size() == 1 and resolved["details"]["shield_changes"][0]["reason"] == ("depleted" if target.shield.is_empty() else "absorbed"))
		_check("S23全吸收仍激活并交战", target.activated and target.engaged_allies.has(mage.id))
		# 篡改返回明细不能更改真实盾；第二法师再击只对尚存在的池记吸收。
		effect["shield_before"]["remaining"] = -99.0
		effect["shield_after"]["remaining"] = -99.0
		_check("S23结果盾明细深副本", target.shield.is_empty() or target.shield["remaining"] > 0.0)
		var again := _s1b2_cast(sim, 92002, 2, "W")
		if amount <= 112.75:
			_check("S23已耗尽身份不重复吸收或耗尽", again.get("accepted", false) and _s22_effect(again)["absorptions"].is_empty() and again["details"]["shield_changes"].is_empty())
	# A03给定D1=180，明确通过合法火球输出夹具造出，不声称敌方来伤链。
	var sim := _s23_battle(150.0, true)
	var mage := sim.slot_unit(0)
	var target := sim.living("enemy")[0]
	mage.combat_stats["damage_bonus"] = 180.0 / (1.10 * 100.0 * 1.025) - 1.0
	var resolved := _s1b2_cast(sim, 92003, 0, "W")
	var effect := _s22_effect(resolved)
	_check("S23A03盾150挡D1一百八十余30", resolved.get("accepted", false) and is_equal_approx(effect.get("requested_amount", -1), 180.0) and effect.get("absorbed_amount") == 150.0 and is_equal_approx(effect.get("actual_amount", -1), 30.0) and target.shield.is_empty(), str(resolved))


	var zero := _s23_battle(150.0, true)
	zero.slot_unit(0).combat_stats["power_bonus"] = -1.0
	var zero_target := zero.living("enemy")[0]
	var zero_pool := zero_target.shield.duplicate(true)
	var hit := _s1b2_cast(zero, 92004, 0, "W")
	_check("S23零伤害不吸收但仍命中交战", hit.get("accepted", false) and _s22_effect(hit).get("actual_amount") == 0.0 and _s22_effect(hit).get("absorbed_amount") == 0.0 and _s22_effect(hit).get("absorptions", ["missing"]).is_empty() and _s1a_same_state(zero_pool, zero_target.shield) and zero_target.engaged_allies.has(zero.slot_unit(0).id))


## 普通生命尺度与相邻可表示输入独立造场；精确核对名义分配、真实状态差及仇恨，不以分项总和作门禁。
func _s23_precision_cases() -> void:
	var power_step := pow(2.0, -46.0)
	var hp_step := pow(2.0, -43.0)
	_check("S23R1相邻输入确有区别", 100.0 + power_step > 100.0 and 100.0 - power_step < 100.0 and 1000.0 + hp_step > 1000.0 and 1000.0 - hp_step < 1000.0)
	var cases: Array[Dictionary] = [
		{"name": "hp1000", "hp": 1000.0},
		{"name": "fractional", "hp": 1000.1},
		{"name": "repeated", "hp": 1000.1, "strikes": 3},
		{"name": "full", "hp": 1000.0, "pool": 1000.0},
		{"name": "partial", "hp": 1000.1, "pool": 50.1},
		{"name": "lethal", "hp": 12.3, "pool": 50.1},
		{"name": "rated", "hp": 1000.1, "rated": true},
		{"name": "rated_full", "hp": 1000.0, "pool": 1000.0, "rated": true},
		{"name": "rated_partial", "hp": 1000.1, "pool": 17.1, "rated": true},
		{"name": "rated_lethal", "hp": 1.3, "pool": 17.1, "rated": true},
		{"name": "power_up", "hp": 1000.0, "power_delta": power_step},
		{"name": "power_down", "hp": 1000.0, "power_delta": -power_step},
		{"name": "hp_up", "hp": 1000.0 + hp_step},
		{"name": "hp_down", "hp": 1000.0 - hp_step},
		{"name": "pool_up", "hp": 1000.0, "pool": 1000.0 + hp_step},
		{"name": "pool_down", "hp": 1000.0, "pool": 1000.0 - hp_step}
	]
	for sample: Dictionary in cases:
		var fixture := _s23_uninstalled()
		var sim: BattleSim = fixture["sim"]
		var inputs: Dictionary = fixture["inputs"]
		var mage := sim.slot_unit(0)
		var target := sim.living("enemy")[0]
		target.hp = sample["hp"]
		target.max_hp = sample["hp"]
		inputs["stats"][mage.id]["temporary_power"] = sample.get("power_delta", 0.0)
		if sample.get("rated", false):
			# 安装前显式传评级与防护；独立验证火球未漏乘精准、暴击、专精、穿透和目标减伤。
			inputs["stats"][mage.id].merge({"precision_rating": 1000.0, "critical_rating": 1000.0, "mastery_rating": 1000.0, "penetration_rating": 1000.0}, true)
			inputs["stats"][target.id].merge({"evasion_rating": 400.0, "magic_resistance": 1000.0, "damage_reduction": 0.2}, true)
		var pool_before := float(sample.get("pool", 0.0))
		var initial: Dictionary = {}
		if pool_before > 0.0:
			initial[target.id] = {"source_id": target.id, "remaining": pool_before, "expires_at": 100.0}
		var issues := sim._enable_skill_transactions(inputs["stats"], true, inputs["relations"], "S2_3_SHIELD_AWARE", initial)
		_check("S23R1普通尺度原子安装" + sample["name"], issues.is_empty(), str(issues))
		if not issues.is_empty():
			continue
		var power: float = sim._skill_derived_parameters(mage)["power"]
		_check("S23R1输入强度未归零或被抹平" + sample["name"], power == 100.0 + float(sample.get("power_delta", 0.0)))
		for strike: int in int(sample.get("strikes", 1)):
			# 连续受击通过真实战斗时钟等CD，不清费用、时钟或仇恨；隔离场保持旧攻击关闭。
			if strike > 0:
				sim._advance_skill_schedule(3.0)
			mage.target_id = target.id
			var hp_before := target.hp
			pool_before = float(target.shield.get("remaining", 0.0))
			var threat_before := float(target.threat.get(mage.id, 0.0))
			var label: String = sample["name"] + ":" + str(strike)
			var preview := _s23_prepare(sim, _s1b2_request(sim, 96001 + strike, 0, "W"), "", label)
			if not preview.get("preparable", false):
				continue
			var expected: Dictionary = preview["details"]["effects"][0]
			var requested: float = expected["requested_amount"]
			var nominal_absorb := minf(pool_before, requested)
			var hp_budget := requested - nominal_absorb
			var hp_after := maxf(0.0, hp_before - minf(hp_before, hp_budget))
			var pool_after := maxf(0.0, pool_before - nominal_absorb)
			var overkill := maxf(0.0, hp_budget - hp_before)
			_check("S23R1名义分配及真实差预演" + label, requested > 0.0 and expected["hp_after"] == hp_after and expected["actual_amount"] == hp_before - hp_after and expected["absorbed_amount"] == pool_before - pool_after and expected["overkill_amount"] == overkill and float(expected["shield_after"].get("remaining", 0.0)) == pool_after, str(expected))
			if sample.get("rated", false):
				var reference := 110.0 * 1.225 * (1.0 + 0.25 * 600.0 / 2400.0) * 1.1375 * (1000.0 / 1825.0) * 0.8
				_check("S23R1非零评级及防护公式" + label, is_equal_approx(requested, reference), str(expected))
			var result := _s1b2_cast(sim, 96001 + strike, 0, "W")
			_check("S23R1常规正伤害不误停场" + label, result.get("accepted", false) and sim._skill_schedule_active, str(result))
			if not result.get("accepted", false):
				break
			var effect := _s22_effect(result)
			var actual: float = effect["actual_amount"]
			_check("S23R1提交生命盾真实差及合法过量" + label, target.hp == hp_after and float(target.shield.get("remaining", 0.0)) == pool_after and effect["hp_before"] == hp_before and effect["hp_after"] == target.hp and actual == hp_before - target.hp and effect["absorbed_amount"] == pool_before - float(target.shield.get("remaining", 0.0)) and effect["overkill_amount"] == overkill and is_finite(actual) and actual >= 0.0 and actual <= hp_before and target.hp >= 0.0 and target.hp <= hp_before and pool_after <= pool_before)
			var changes: Array = effect["threat_changes"]
			var threat_ok: bool = changes.size() == (1 if actual > 0.0 else 0)
			if actual > 0.0 and changes.size() == 1:
				threat_ok = threat_ok and changes[0]["amount"] == actual and changes[0]["before"] == threat_before and changes[0]["after"] == threat_before + actual
			_check("S23R1伤害仇恨严格来自生命差" + label, threat_ok and (target.threat.get(mage.id, 0.0) == threat_before + actual if target.alive else target.threat.is_empty()))
			_check("S23R1吸收耗尽及致死清理" + label, effect["absorptions"].size() == (1 if nominal_absorb > 0.0 else 0) and (target.alive == (target.hp > 0.0)) and (target.alive or (target.shield.is_empty() and target.engaged_allies.is_empty() and result["details"]["defeated_ids"] == [target.id])))
	# 邻近强度生成奇数尾位的新盾，小旧池净增可表达；逆向加法不重建总量也应成功替换。
	for delta: float in [-power_step, power_step]:
		var fixture := _s23_uninstalled()
		var sim: BattleSim = fixture["sim"]
		var mage := sim.slot_unit(0)
		fixture["inputs"]["stats"][mage.id]["temporary_power"] = delta
		var old_amount := pow(2.0, -46.0)
		var issues := sim._enable_skill_transactions(fixture["inputs"]["stats"], true, fixture["inputs"]["relations"], "S2_3_SHIELD_AWARE", {mage.id: {"source_id": mage.id, "remaining": old_amount, "expires_at": 100.0}})
		_check("S23R1邻近盾原子安装", issues.is_empty(), str(issues))
		if not issues.is_empty():
			continue
		var prepared := _s23_prepare(sim, _s1b2_request(sim, 96010, 0, "E"), "", "屏障逆向重建" + str(delta))
		if not prepared.get("preparable", false):
			continue
		var hp_before := mage.hp
		var result := _s1b2_cast(sim, 96010, 0, "E")
		var effect := _s22_effect(result)
		_check("S23R1屏障邻近值替换不要求逆向重建", result.get("accepted", false) and effect.get("shield_action") == "replaced" and effect.get("actual_amount") == float(mage.shield.get("remaining", 0.0)) - old_amount and old_amount + float(effect.get("actual_amount", 0.0)) != mage.shield.get("remaining") and effect.get("requested_amount") == mage.shield.get("remaining"), str(result))
		_check("S23R1屏障公共生命有限浮点且未变", effect.get("hp_before") is float and effect.get("hp_after") is float and is_finite(effect["hp_before"]) and is_finite(effect["hp_after"]) and effect["hp_before"] == hp_before and effect["hp_after"] == hp_before and mage.hp == hp_before)


## 到期前/恰到期及同刻命令对照；暂停不推进，1倍/2倍使用相同固定点截止。
func _s23_clock_cases() -> void:
	for speed: int in [1, 2]:
		var sim := _s23_battle(150.0, true, 2.0 * BattleSim.SKILL_FIXED_STEP)
		var target := sim.living("enemy")[0]
		sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP / speed, speed)
		_check("S23截止前盾仍在" + str(speed), not target.shield.is_empty() and sim._skill_tick == 1)
		sim.set_paused(true)
		var before := _s1a_state(sim)
		sim._advance_skill_schedule(100.0, speed)
		_check("S23暂停不推进盾与时钟" + str(speed), _s1a_same_state(before, _s1a_state(sim)))
		sim.set_paused(false)
		sim._enqueue_skill_command("cast", _s1b2_request(sim, 93001, 0, "W"))
		var inspected := sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP / speed, speed)
		var resolved: Dictionary = inspected[0]["result"] if inspected.size() == 1 else {}
		_check("S23恰到期先清再同刻火球" + str(speed), resolved.get("accepted", false) and _s22_effect(resolved).get("absorbed_amount") == 0.0 and _s22_effect(resolved).get("shield_before", {"missing": true}).is_empty() and target.shield.is_empty() and sim._skill_tick == 2, str(resolved))
	var sim := _s23_battle(150.0, true, BattleSim.SKILL_FIXED_STEP)
	# 模拟只读查询已在截止点、清理周期尚未执行；预检只能在副本视为无盾。
	sim._skill_tick = 1
	sim.time = BattleSim.SKILL_FIXED_STEP
	sim.events.now = sim.time
	var target := sim.living("enemy")[0]
	var prepared := _s23_prepare(sim, _s1b2_request(sim, 93002, 0, "W"), "", "到期副本")
	_check("S23到期纯预检视无盾但不写真实池", not target.shield.is_empty() and prepared["details"]["effects"][0]["shield_before"].is_empty() and prepared["details"]["effects"][0]["absorbed_amount"] == 0.0)


## 来源死亡仍在场保留他人盾；结果先见完整池，目标死亡、结束/离场/停场清理各自独立取证。
func _s23_lifecycle_cases() -> void:
	var sim := _s23_battle(150.0, true, 100.0, true)
	var target := sim.living("enemy")[0]
	var source := sim.living("enemy")[1]
	var original := target.shield.duplicate(true)
	source.hp = 1.0
	sim.slot_unit(0).target_id = source.id
	var resolved := _s1b2_cast(sim, 94001, 0, "W")
	_check("S23来源死亡仍在场不清他人盾", resolved.get("accepted", false) and not source.alive and sim.units.has(source.id) and _s1a_same_state(original, target.shield) and sim._skill_shield_problems(target).is_empty())
	for mode: String in ["target_death", "direct_death", "finish", "leave", "stop"]:
		sim = _s23_battle(10.0, true)
		target = sim.living("enemy")[0]
		if mode == "target_death":
			target.hp = 1.0
			resolved = _s1b2_cast(sim, 94002, 0, "W")
			_check("S23目标死亡清自身盾且耗尽仅一次", resolved.get("accepted", false) and not target.alive and target.shield.is_empty() and resolved["details"]["shield_changes"].size() == 1 and resolved["details"]["shield_changes"][0]["reason"] == "depleted")
		elif mode == "direct_death":
			# 非伤害死亡清自身盾，不应制造吸收或耗尽的施法结果。
			sim._down(target, sim.slot_unit(0).id)
			_check("S23非伤害死亡不伪造耗尽结果", target.shield.is_empty() and _s1b2_results(sim).is_empty())
		elif mode == "finish":
			sim._finish("lose", "s23_fixture")
		elif mode == "leave":
			sim._leave_skill_schedule()
		else:
			# 通过实际执行的非法来源触发既有CONFIG_ERROR停场；纯准备仍必须零写入。
			target.shield["source_id"] = 999999
			_s23_prepare(sim, _s1b2_request(sim, 94003, 0, "W"), "CONFIG_ERROR", "停场前纯校验")
			sim._enqueue_skill_command("cast", _s1b2_request(sim, 94004, 0, "W"))
			sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
			_check("S23执行配置错误停场保留诊断", sim.finished and sim.result == "error" and not sim._skill_validation_error.is_empty())
		var empty := true
		for unit: BattleSim.Unit in sim.units.values():
			empty = empty and unit.shield.is_empty()
		_check("S23生命周期全部清盾" + mode, empty)
	# 真正移除来源，与死亡仍保留在units不同；纯准备拒绝且不删除目标盾。
	sim = _s23_battle(150.0, true, 100.0, true)
	target = sim.living("enemy")[0]
	source = sim.living("enemy")[1]
	sim._ids.erase(source.id)
	sim.units.erase(source.id)
	_s23_prepare(sim, _s1b2_request(sim, 94005, 0, "W"), "CONFIG_ERROR", "来源已离场")
	_check("S23查无来源纯校验不清盾", not target.shield.is_empty())
	sim = _s23_battle(150.0, true, 100.0, true)
	target = sim.living("enemy")[0]
	source = sim.living("enemy")[1]
	sim.units.erase(source.id)
	_s23_prepare(sim, _s1b2_request(sim, 94007, 0, "W"), "CONFIG_ERROR", "来源查无且稳定ID残留")
	sim._enqueue_skill_command("cast", _s1b2_request(sim, 94008, 0, "W"))
	sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
	_check("S23来源查无可停场收尾而非下标崩溃", sim.finished and sim.result == "error" and target.shield.is_empty() and not sim._skill_validation_error.is_empty())
	sim._leave_skill_schedule()
	_check("S23坏来源停场后仍可安全离场", sim.skill_battle_id.is_empty())
	for mode: String in ["normal", "pause", "leave", "new_field"]:
		sim = _s23_battle(10.0, true)
		target = sim.living("enemy")[0]
		target.hp = 1.0
		for enemy: BattleSim.Unit in sim.living("enemy"):
			if enemy.id != target.id:
				enemy.hp = 0.0
				enemy.alive = false
		var order: Array[String] = []
		var observation := {"complete": false, "fresh": null, "fresh_state": {}}
		# 所有池、生命、费用及双钟均已提交；可暂停/离场，但不能让后续旧通知污染新场。
		var on_result := func(data: Dictionary) -> void:
			order.append("result")
			observation["complete"] = data.get("accepted", false) and target.shield.is_empty() and target.hp == 0.0 and not target.alive and sim.slot_unit(0).res == 85.0 and sim.slot_unit(0).skill_ready_at.has("mage.fire.fireball") and not sim.finished
			data["details"]["effects"][0]["absorptions"].clear()
			if mode == "pause":
				sim.set_paused(true)
			elif mode in ["leave", "new_field"]:
				sim._leave_skill_schedule()
				if mode == "new_field":
					observation["fresh"] = _s23_battle(160.0)
					observation["fresh_state"] = _s1a_state(observation["fresh"])
		# 死亡通知只在结果后；不调用旧_down来二次耗尽或重新清理。
		var on_down := func(_id: int, _by: int) -> void:
			order.append("down")
		# 胜负由既有队列末尾检查，必须最后发布。
		var on_end := func(_outcome: String, _reason: String, _time: float) -> void:
			order.append("end")
		sim.events.cast_resolved.connect(on_result)
		sim.events.unit_downed.connect(on_down)
		sim.events.battle_ended.connect(on_end)
		resolved = _s1b2_cast(sim, 94006, 0, "W")
		_check("S23回调只见完整提交及事件深副本" + mode, observation["complete"] and _s22_effect(resolved).get("absorptions", []).size() == 1)
		if mode == "normal":
			_check("S23结果死亡胜负顺序", order == ["result", "down", "end"] and sim.result == "win")
		elif mode == "pause":
			_check("S23暂停不丢已提交死亡", order == ["result", "down"] and not sim.finished)
			sim.set_paused(false)
			sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
			_check("S23恢复最后胜负", order == ["result", "down", "end"])
		else:
			_check("S23离场停止旧通知" + mode, order == ["result"] and sim.skill_battle_id.is_empty())
			if mode == "new_field":
				_check("S23换场不污染新池", _s1a_same_state(observation["fresh_state"], _s1a_state(observation["fresh"])))
		sim.events.cast_resolved.disconnect(on_result)
		sim.events.unit_downed.disconnect(on_down)
		sim.events.battle_ended.disconnect(on_end)


## 身份防伪、非法池、正微量与溢出拒绝：不把配置错误当零盾绕过，不放宽精确比较或设epsilon。
func _s23_reject_cases() -> void:
	for variant: String in ["fake_initial", "fake_cast", "wrong_target", "wrong_deadline", "above_capacity", "bool", "nan", "negative", "extra", "missing"]:
		var sim := _s23_battle(150.0, true)
		var target := sim.living("enemy")[0]
		match variant:
			"fake_initial":
				var source := sim.living("enemy")[1]
				var identity := "%s:initial:%d:%d" % [sim.skill_battle_id, source.id, target.id]
				target.shield.merge({"source_id": source.id, "source_cast_id": identity, "shield_id": identity + ":shield"}, true)
			"fake_cast":
				target.shield["source_cast_id"] = sim.skill_battle_id + ":99999"
				target.shield["shield_id"] = "%s:99999:shield:0:%d" % [sim.skill_battle_id, target.id]
			"wrong_target":
				var other_id: int = sim.living("enemy")[1].id
				var other_identity := "%s:initial:%d:%d" % [sim.skill_battle_id, target.id, other_id]
				target.shield["source_cast_id"] = other_identity
				target.shield["shield_id"] = other_identity + ":shield"
			"wrong_deadline": target.shield["expires_at"] = 500.0
			"above_capacity": target.shield["remaining"] = 151.0
			"bool": target.shield["remaining"] = true
			"nan": target.shield["remaining"] = NAN
			"negative": target.shield["remaining"] = -1.0
			"extra": target.shield["extra"] = 0
			"missing": target.shield.erase("remaining")
		_s23_prepare(sim, _s1b2_request(sim, 95001, 0, "W"), "CONFIG_ERROR", "坏盾" + variant)
	var sim := _s23_battle()
	var mage := sim.slot_unit(0)
	var created := _s1b2_cast(sim, 95002, 0, "E")
	_check("S23真实新盾确已建立供防伪", created.get("accepted", false) and not mage.shield.is_empty())
	if not mage.shield.is_empty():
		# 不能把真实盾冒充未安装的初始化身份；不是仅看可识别前缀。
		var identity := "%s:initial:%d:%d" % [sim.skill_battle_id, mage.id, mage.id]
		mage.shield["source_cast_id"] = identity
		mage.shield["shield_id"] = identity + ":shield"
		_s23_prepare(sim, _s1b2_request(sim, 95003, 2, "R"), "CONFIG_ERROR", "真实盾不可冒充初始化")
	for variant: String in ["absorb_unrepresentable", "hp_unrepresentable", "formula_overflow", "shield_overflow"]:
		sim = _s23_battle(1.0e30 if variant == "absorb_unrepresentable" else 0.0, true)
		mage = sim.slot_unit(0)
		var target := sim.living("enemy")[0]
		var slot := "W"
		match variant:
			"hp_unrepresentable":
				target.max_hp = 1.0e30
				target.hp = 1.0e30
			"formula_overflow": mage.combat_stats["damage_bonus"] = 1.0e308
			"shield_overflow":
				mage.combat_stats["shield_bonus"] = 1.0e308
				slot = "E"
		_s23_prepare(sim, _s1b2_request(sim, 95004, 0, slot), "CONFIG_ERROR", variant)
	# 以二进制微量构造显式增量，并断言实际派生为正；不取最低1或伪装零量。
	sim = _s23_battle()
	mage = sim.slot_unit(0)
	mage.combat_stats["power_bonus"] = -1.0 + pow(2.0, -24.0) / 100.0
	var amount: float = sim._skill_derived_parameters(mage)["power"] * 1.50
	_check("S23微盾输入及派生为正", mage.combat_stats["power_bonus"] > -1.0 and amount > 0.0 and amount < 1.0e-6)
	var resolved := _s1b2_cast(sim, 95005, 0, "E")
	_check("S23可表达微盾不取整或保底", resolved.get("accepted", false) and _s22_effect(resolved).get("actual_amount") == amount and mage.shield.get("remaining") == amount)
	sim = _s23_battle(pow(2.0, -24.0), true)
	resolved = _s1b2_cast(sim, 95006, 0, "W")
	_check("S23正微量吸收严格池差", resolved.get("accepted", false) and _s22_effect(resolved).get("absorbed_amount") == pow(2.0, -24.0) and sim.living("enemy")[0].shield.is_empty(), str(resolved))
	# S22非空盾即使形式像S23也不能绕过；复制仅用于非法输入拒绝，不宣称合法施放。
	var s22 := _s22_battle()
	var fixture_shield := _s23_battle(50.0, true)
	s22.living("enemy")[0].shield = fixture_shield.living("enemy")[0].shield.duplicate(true)
	_s23_prepare(s22, _s1b2_request(s22, 95007, 0, "W"), "CONFIG_ERROR", "S22不绕非空盾")

	# 耗尽后不能仅靠旧五字段重新激活同一初始身份；不累计永久耗尽记录。
	var replay := _s23_battle(50.0, true)
	var replay_target := replay.living("enemy")[0]
	var retired := replay_target.shield.duplicate(true)
	var depletion := _s1b2_cast(replay, 95008, 0, "W")
	_check("S23耗尽回放前提", depletion.get("accepted", false) and replay_target.shield.is_empty())
	replay_target.shield = retired
	_s23_prepare(replay, _s1b2_request(replay, 95009, 2, "W"), "CONFIG_ERROR", "旧耗尽身份不可重放")


## B段独立完整场：P100、零防护，主目标故意不是最小ID；初始盾只由合法同阵营来源原子安装。
func _s23b_battle(shields: Array = [], rated: bool = false, primary_source: bool = false) -> Dictionary:
	var fixture := _s23_uninstalled()
	var sim: BattleSim = fixture["sim"]
	var inputs: Dictionary = fixture["inputs"]
	var enemies := sim.living("enemy")
	var mage := sim.slot_unit(0)
	var primary: BattleSim.Unit = enemies[2]
	mage.pos = Vector2.ZERO
	mage.target_id = primary.id
	var initial: Dictionary = {}
	for i: int in enemies.size():
		var target: BattleSim.Unit = enemies[i]
		target.pos = Vector2(800.0 + i * 10.0, 0.0)
		target.hp = 1000.0
		target.max_hp = 1000.0
		if rated:
			inputs["stats"][target.id].merge({"evasion_rating": 200.0 * i, "magic_resistance": 500.0 * i, "damage_reduction": 0.1 * i}, true)
		if i < shields.size() and float(shields[i]) > 0.0:
			initial[target.id] = {"source_id": primary.id if primary_source else target.id, "remaining": float(shields[i]), "expires_at": 100.0}
	primary.pos = Vector2(800.0, 0.0)
	if rated:
		inputs["stats"][mage.id].merge({"precision_rating": 1000.0, "critical_rating": 1000.0, "penetration_rating": 1000.0, "mastery_rating": 1000.0}, true)
	var issues := sim._enable_skill_transactions(inputs["stats"], true, inputs["relations"], "S2_3_SHIELD_AWARE", initial)
	_check("S23B独立场原子安装", issues.is_empty(), str(issues))
	var order: Array[int] = [primary.id]
	for target: BattleSim.Unit in enemies:
		if target.id != primary.id:
			order.append(target.id)
	return {"sim": sim, "enemies": enemies, "primary": primary, "order": order}


## 爆破仅在本组追加，原S23A与S22夹具/断言保留；不接产品输入、敌方攻击或通用范围框架。
func _s23b_cases() -> void:
	_s23b_geometry_cases()
	_s23b_formula_cases()
	_s23b_late_error_cases()
	_s23b_notification_cases()
	_s23b_reject_cases()


## A01真实事务：副目标超过施法者射程仍可命中；逆序容器、去重与过滤沿同一快照检查。
func _s23b_geometry_cases() -> void:
	var fixture := _s23b_battle()
	var sim: BattleSim = fixture["sim"]
	var enemies: Array = fixture["enemies"]
	var primary: BattleSim.Unit = fixture["primary"]
	enemies[0].pos = Vector2(1000, 0)
	enemies[1].pos = Vector2(1001, 0)
	enemies[3].selectable = false
	var projected := sim.get_skill_view(sim.slot_unit(0).id, "Q")
	_check("S23B投影已实现并可准备", projected["implemented"] and projected["preparable"])
	var prepared := _s23_prepare(sim, _s1b2_request(sim, 97001, 0, "Q"), "", "B几何边界")
	_check("S23B八米两米包含及2点01排除", prepared.get("effect_targets", []) == [[primary.id, enemies[0].id]])
	var result := _s1b2_cast(sim, 97001, 0, "Q")
	_check("S23BA01每目标完整伤害且费用结果一次", result.get("accepted", false) and result["details"]["effects"].size() == 2 and is_equal_approx(result["details"]["effects"][0]["requested_amount"], 174.25) and is_equal_approx(result["details"]["effects"][1]["requested_amount"], 174.25) and sim.slot_unit(0).res == 75.0 and sim.slot_unit(0).skill_ready_at.get("mage.fire.flame_burst") == sim.time + 8.0 and sim.slot_unit(0).gcd_until == sim.time + 1.0 and _s1b2_results(sim).size() == 1 and enemies[1].hp == 1000.0 and enemies[3].hp == 1000.0, str(result))
	fixture = _s23b_battle()
	sim = fixture["sim"]
	enemies = fixture["enemies"]
	primary = fixture["primary"]
	# 只逆序本组容器，不篡改稳定ID；主目标不能因容器顺序或重复扫描结算两次。
	var keys := sim.units.keys()
	keys.reverse()
	var reversed: Dictionary = {}
	for id: int in keys:
		reversed[id] = sim.units[id]
	sim.units = reversed
	prepared = _s23_prepare(sim, _s1b2_request(sim, 97002, 0, "Q"), "", "B逆序")
	_check("S23B主目标优先其余稳定ID且唯一", prepared.get("effect_targets", []) == [fixture["order"]])
	enemies[0].hp = 0.0
	enemies[0].alive = false
	enemies[1].selectable = false
	sim.slot_unit(1).pos = primary.pos
	prepared = _s23_prepare(sim, _s1b2_request(sim, 97002, 0, "Q"), "", "B过滤")
	_check("S23B排除死亡不可选友军", prepared.get("effect_targets", []) == [[primary.id, enemies[3].id]])
	if prepared.get("preparable", false):
		prepared["effect_targets"][0].clear()
		prepared["commit_units"][primary.id]["hp"] = -1.0
		_check("S23B名单及工作副本不回写", primary.hp == 1000.0 and sim._prepare_skill_transaction(_s1b2_request(sim, 97002, 0, "Q"))["effect_targets"][0] == [primary.id, enemies[3].id])


## 每目标独立防护盾生命与实得；专精不作用爆破，零量成功、正微量不设保底。
func _s23b_formula_cases() -> void:
	var plain_requests: Array[float] = []
	for mode: String in ["plain", "rated", "mastery", "zero", "tiny"]:
		var fixture := _s23b_battle([0.0, 50.0, 0.0, 1000.0] if mode != "tiny" else [], mode == "rated")
		var sim: BattleSim = fixture["sim"]
		var mage := sim.slot_unit(0)
		var enemies: Array = fixture["enemies"]
		if mode == "mastery":
			mage.combat_stats["mastery_rating"] = 1000.0
		elif mode == "zero":
			mage.combat_stats["power_bonus"] = -1.0
		elif mode == "tiny":
			mage.combat_stats["power_bonus"] = -1.0 + pow(2.0, -24.0) / 100.0
		for target: BattleSim.Unit in enemies:
			if mode == "tiny" or target == enemies[0]:
				target.hp = 1.0
		var snapshots: Dictionary = {}
		for target: BattleSim.Unit in enemies:
			snapshots[target.id] = {"hp": target.hp, "shield": target.shield.duplicate(true)}
		var result := _s1b2_cast(sim, 97100, 0, "Q")
		_check("S23B四目标一次完整结果" + mode, result.get("accepted", false) and result["details"]["effects"].size() == 4 and _s1b2_results(sim).size() == 1 and mage.res == 75.0, str(result))
		if not result.get("accepted", false):
			continue
		var changed_ids: Array[int] = []
		for index: int in result["details"]["effects"].size():
			var effect: Dictionary = result["details"]["effects"][index]
			var target: BattleSim.Unit = sim.units[fixture["order"][index]]
			var hp_before: float = snapshots[target.id]["hp"]
			var pool_before: float = snapshots[target.id]["shield"].get("remaining", 0.0)
			var requested: float = effect["requested_amount"]
			if mode == "plain":
				plain_requests.append(requested)
			elif mode == "mastery":
				_check("S23B专精变化不改变爆破请求量", index < plain_requests.size() and requested == plain_requests[index])
			var nominal := minf(pool_before, requested)
			var hp_budget := requested - nominal
			var hp_after := maxf(0.0, hp_before - minf(hp_before, hp_budget))
			var pool_after := maxf(0.0, pool_before - nominal)
			_check("S23B效果顺序与身份" + mode, effect["effect_index"] == 0 and effect["target_index"] == index and effect["target_id"] == target.id and effect["cast_id"] == result["cast_id"] and effect["source_id"] == mage.id)
			_check("S23B真实池差生命差及合法过量" + mode, target.hp == hp_after and effect["actual_amount"] == hp_before - target.hp and effect["absorbed_amount"] == pool_before - pool_after and float(target.shield.get("remaining", 0.0)) == pool_after and effect["overkill_amount"] == maxf(0.0, hp_budget - hp_before) and effect["hp_before"] == hp_before and effect["hp_after"] == hp_after)
			var actual: float = effect["actual_amount"]
			var threats: Array = effect["threat_changes"]
			_check("S23B仇恨仅真实HP差" + mode, threats.size() == (1 if actual > 0.0 else 0) and (actual <= 0.0 or (threats.size() == 1 and threats[0]["amount"] == actual)) and (target.threat.get(mage.id, 0.0) == actual if target.alive else target.threat.is_empty()))
			_check("S23B吸收归属且耗尽至多一次" + mode, effect["absorptions"].size() == (1 if nominal > 0.0 else 0) and (nominal <= 0.0 or (effect["absorptions"][0]["source_id"] == snapshots[target.id]["shield"]["source_id"] and effect["absorptions"][0]["absorbed_amount"] == pool_before - pool_after)))
			if nominal > 0.0:
				changed_ids.append(target.id)
			if mode == "rated":
				var q := 1.0 + 0.25 * (1000.0 - float(target.combat_stats["evasion_rating"])) / (2000.0 + float(target.combat_stats["evasion_rating"]))
				var expected := 170.0 * q * 1.1375 * (1000.0 / (1000.0 + target.magic_resist * 0.825)) * (1.0 - float(target.combat_stats["damage_reduction"]))
				_check("S23B各目标独立评级防护且无专精", is_equal_approx(requested, expected), str(effect))
			elif mode == "zero":
				_check("S23B零量仍命中存活敌人", requested == 0.0 and actual == 0.0 and target.activated and target.engaged_allies.has(mage.id))
			elif mode == "tiny":
				_check("S23B正微量真实可表达无保底", mage.combat_stats["power_bonus"] > -1.0 and requested > 0.0 and actual > 0.0 and actual < 1.0e-6)
			else:
				_check("S23B零或非零专精都为174点25", is_equal_approx(requested, 174.25))
		var actual_ids: Array[int] = []
		for change: Dictionary in result["details"]["shield_changes"]:
			actual_ids.append(change["target_id"])
		_check("S23B盾变化依目标顺序无重复", actual_ids == changed_ids)


## 晚期失败证明：诊断只取已完成效果副本，末目标合法大仇恨到累加才失败，不能用全量早拒绝替代。
func _s23b_late_error_cases() -> void:
	for mode: String in ["threat_precision", "death_status"]:
		var fixture := _s23b_battle([0.0, 0.0, 1.0, 0.0])
		var sim: BattleSim = fixture["sim"]
		var mage := sim.slot_unit(0)
		var primary: BattleSim.Unit = fixture["primary"]
		var last: BattleSim.Unit = sim.units[fixture["order"][-1]]
		primary.hp = 1.0
		if mode == "threat_precision":
			last.threat[mage.id] = 1.0e30
		else:
			last.hp = 1.0
			last.statuses["bad"] = {"source": true, "until": 100.0}
		var before := _s1a_state(sim)
		var prepared := _s23_prepare(sim, _s1b2_request(sim, 97200, 0, "Q"), "CONFIG_ERROR", "B末目标" + mode)
		var audit: Variant = null
		var location := false
		for problem: String in prepared.get("problems", PackedStringArray()):
			if problem.begins_with("burst.prepared_effects:"):
				audit = JSON.parse_string(problem.trim_prefix("burst.prepared_effects:"))
			location = location or problem == "burst.target_index=3 target_id=%d" % last.id
		var previous_ok: bool = audit is Array and audit.size() == 3
		if previous_ok:
			# 缺诊断或错型只记普通FAIL，不用缺键下标中断后续用例。
			for i: int in audit.size():
				previous_ok = previous_ok and audit[i] is Dictionary and audit[i].get("target_id") == fixture["order"][i] and audit[i].get("target_index") == i
			previous_ok = previous_ok and audit[0].get("hp_before", -1.0) == 1.0 and audit[0].get("hp_after", -1.0) == 0.0 and audit[0].get("actual_amount", -1.0) == 1.0 and audit[0].get("absorbed_amount", -1.0) == 1.0 and audit[0].get("shield_after", {"missing": true}).is_empty()
		var errors: PackedStringArray = prepared.get("problems", PackedStringArray())
		var late_kind: bool = not errors.is_empty() and errors[0].begins_with("single.threat:" if mode == "threat_precision" else "single.death.status:")
		_check("S23B末目标晚期错误前已有三效果准备" + mode, location and previous_ok and late_kind, str(prepared))
		_check("S23B末目标失败整场精确未提交" + mode, _s1a_same_state(before, _s1a_state(sim)) and primary.hp == 1.0 and primary.shield["remaining"] == 1.0 and _s1b2_results(sim).is_empty())
		# 移除唯一晚期缺陷后，相同主目标必须成功致死并继续其余目标，佐证不是配置或名单早退。
		if mode == "threat_precision":
			last.threat.clear()
		else:
			last.statuses.clear()
		var ready := _s23_prepare(sim, _s1b2_request(sim, 97200, 0, "Q"), "", "B修复晚期缺陷" + mode)
		_check("S23B主目标副本死亡仍准备全部目标" + mode, ready.get("preparable", false) and ready["details"]["effects"].size() == 4 and ready["commit_units"][primary.id]["hp"] == 0.0)
	# 实际执行错误可以停场清关系/盾，费用生命双钟不得部分提交；与上述纯准备零写入分开。
	var fixture := _s23b_battle()
	var sim: BattleSim = fixture["sim"]
	var primary: BattleSim.Unit = fixture["primary"]
	var mage := sim.slot_unit(0)
	var last: BattleSim.Unit = sim.units[fixture["order"][-1]]
	last.threat[mage.id] = 1.0e30
	var result := _s1b2_cast(sim, 97201, 0, "Q")
	_check("S23B实际晚期配置错误停场无部分扣费生命", result.get("reason") == "CONFIG_ERROR" and not result.get("accepted", true) and sim.finished and sim.result == "error" and primary.hp == 1000.0 and mage.res == 100.0 and mage.gcd_until == 0.0 and mage.skill_ready_at.is_empty() and _s1b2_results(sim).size() == 1 and last.threat.is_empty(), str(result))


## 多死亡通知在唯一结果后依名单发布；结果/死亡回调离场换场须停止旧通知，暂停不丢已提交事实。
func _s23b_notification_cases() -> void:
	for mode: String in ["normal", "pause", "leave_result", "new_result", "leave_down", "new_down"]:
		var fixture := _s23b_battle([10.0, 10.0, 10.0, 10.0], false, true)
		var sim: BattleSim = fixture["sim"]
		var order: Array = fixture["order"]
		var mage := sim.slot_unit(0)
		for target: BattleSim.Unit in fixture["enemies"]:
			target.hp = 1.0
			target.statuses["s23b"] = {"source": mage.id, "until": 100.0}
		var sequence: Array[String] = []
		var observed := {"complete": false, "fresh": null, "fresh_state": {}}
		# 此时所有四目标已提交死亡及清池；修改事件副本不影响返回/真实状态。
		var on_result := func(data: Dictionary) -> void:
			sequence.append("result")
			var complete: bool = data.get("accepted", false) and data["details"]["defeated_ids"] == order and mage.res == 75.0 and not sim.finished
			for id: int in order:
				var target: BattleSim.Unit = sim.units[id]
				complete = complete and target.hp == 0.0 and not target.alive and target.shield.is_empty() and target.statuses.is_empty() and target.threat.is_empty()
			observed["complete"] = complete
			if data.get("details", {}).get("effects") is Array:
				data["details"]["effects"].clear()
			if mode == "pause":
				sim.set_paused(true)
			elif mode in ["leave_result", "new_result"]:
				sim._leave_skill_schedule()
				if mode == "new_result":
					observed["fresh"] = _s23b_battle()["sim"]
					observed["fresh_state"] = _s1a_state(observed["fresh"])
		# 单目标状态通知先于该目标死亡；此处只记录顺序，不触发旧生命周期。
		var on_status := func(id: int, _status: String, _source: int, _until: float) -> void:
			sequence.append("status:" + str(id))
		# 第一条死亡通知可换场，剩余旧目标通知和胜负必须停止。
		var on_down := func(id: int, _by: int) -> void:
			sequence.append("down:" + str(id))
			if mode in ["leave_down", "new_down"]:
				sim._leave_skill_schedule()
				if mode == "new_down":
					observed["fresh"] = _s23b_battle()["sim"]
					observed["fresh_state"] = _s1a_state(observed["fresh"])
		# 胜负只能在全部通知之后；暂停则留待恢复后的固定点。
		var on_end := func(_result: String, _reason: String, _time: float) -> void:
			sequence.append("end")
		sim.events.cast_resolved.connect(on_result)
		sim.events.status_expired.connect(on_status)
		sim.events.unit_downed.connect(on_down)
		sim.events.battle_ended.connect(on_end)
		var result := _s1b2_cast(sim, 97300, 0, "Q")
		_check("S23B回调仅见完整多目标及返回深副本" + mode, observed["complete"] and result.get("details", {}).get("effects", []).size() == 4, str(result))
		var expected: Array[String] = ["result"]
		if mode in ["normal", "pause"]:
			for id: int in order:
				expected.append("status:" + str(id))
				expected.append("down:" + str(id))
			if mode == "normal":
				expected.append("end")
		elif mode in ["leave_down", "new_down"]:
			expected.append("status:" + str(order[0]))
			expected.append("down:" + str(order[0]))
		_check("S23B多死亡通知及换场截止顺序" + mode, sequence == expected, str(sequence))
		if mode == "pause":
			sim.set_paused(false)
			sim._advance_skill_schedule(BattleSim.SKILL_FIXED_STEP)
			expected.append("end")
			_check("S23B恢复后胜负最后且死亡不重复", sequence == expected and sim.result == "win")
		if mode.begins_with("new_"):
			_check("S23B旧通知不污染新场", _s1a_same_state(observed["fresh_state"], _s1a_state(observed["fresh"])))
		sim.events.cast_resolved.disconnect(on_result)
		sim.events.status_expired.disconnect(on_status)
		sim.events.unit_downed.disconnect(on_down)
		sim.events.battle_ended.disconnect(on_end)


## 旧入口继续拒爆破，B参数防冒充且拒绝顺序不被最终多目标数值准备抢占。
func _s23b_reject_cases() -> void:
	for legacy: BattleSim in [_s22_battle(), _s1b2_battle()]:
		_s23_prepare(legacy, _s1b2_request(legacy, 97400, 0, "Q"), "CONFIG_ERROR", "B旧入口不开放")
	var fixture := _s23b_battle()
	var sim: BattleSim = fixture["sim"]
	var mage := sim.slot_unit(0)
	mage.resolved_slots["q"]["effects"][0]["uses_mastery"] = true
	_s23_prepare(sim, _s1b2_request(sim, 97401, 0, "Q"), "CONFIG_ERROR", "B参数冒充")
	fixture = _s23b_battle()
	sim = fixture["sim"]
	mage = sim.slot_unit(0)
	var last: BattleSim.Unit = sim.units[fixture["order"][-1]]
	last.threat[mage.id] = 1.0e30
	mage.res = 0.0
	mage.gcd_until = 10.0
	mage.skill_ready_at["mage.fire.flame_burst"] = 20.0
	_s23_prepare(sim, _s1b2_request(sim, 97402, 0, "Q"), "NOT_ENOUGH_MANA", "B法力优先晚期错误")
	mage.res = 100.0
	_s23_prepare(sim, _s1b2_request(sim, 97402, 0, "Q"), "GCD_ACTIVE", "BGCD优先晚期错误")
	mage.gcd_until = 0.0
	_s23_prepare(sim, _s1b2_request(sim, 97402, 0, "Q"), "SKILL_COOLDOWN", "BCD优先晚期错误")


# ── S2-4 完整隔离输入：复用真实脚本、Viewport 合成事件和固定执行点 ──
## 只在本组显式指定阵容、生命法力、位置、完整属性及逐敌关系，按用例在安装阶段加盾。
func _s24_battle(dual: bool = false, mage_shield: float = 0.0, mage_mana: float = 100.0, enemy_shield: float = 0.0) -> BattleSim:
	var sim := BattleSim.new()
	var config := _config.duplicate(true)
	config["time_limit"] = 10000.0
	sim.setup(config, ["mage", "priest" if dual else "", "", ""], 31, BattleEvents.new())
	sim._begin_skill_schedule()
	var catalog := BattleConfig.load_skill_catalog()
	var mage := sim.slot_unit(0)
	var priest := sim.slot_unit(1)
	for unit: BattleSim.Unit in sim.living("ally"):
		var issues := sim.install_skill_loadout(unit.id, "mage.fire" if unit == mage else "priest.holy", catalog)
		_check("S24夹具安装原技能资源 " + unit.kind, issues.is_empty(), str(issues))
		unit.hp = 950.0 if unit == mage else 1000.0
		unit.max_hp = 1000.0
		unit.res = mage_mana if unit == mage else 100.0
		unit.res_max = 100.0
		unit.pos = Vector2(400, 400) if unit == mage else Vector2(430, 520)
		unit.target_id = -1
	var enemies := sim.living("enemy")
	_check("S24夹具四个敌人", enemies.size() == 4, str(enemies.size()))
	if enemies.size() != 4:
		return sim
	# 第二个敌人是主目标；第一个在爆破半径内，其余超过半径。关系独立提供，不从位置反推。
	var positions := [Vector2(720, 500), Vector2(700, 400), Vector2(990, 650), Vector2(1120, 650)]
	var inputs := _s2_inputs(sim)
	for id: int in sim.units:
		for field: String in inputs["stats"][id]:
			inputs["stats"][id][field] = 0.0
	for unit: BattleSim.Unit in sim.living("ally"):
		inputs["stats"][unit.id]["equipment_power"] = 80.0
	for i: int in enemies.size():
		var enemy: BattleSim.Unit = enemies[i]
		enemy.pos = positions[i]
		enemy.hp = 1000.0
		enemy.max_hp = 1000.0
		enemy.target_id = -1
		var engaged: Dictionary = {}
		if i == 1:
			engaged[mage.id] = true
			if priest != null:
				engaged[priest.id] = true
		inputs["relations"][enemy.id] = {"activated": i == 1, "engaged_allies": engaged}
	var initial: Dictionary = {}
	if mage_shield > 0.0:
		initial[mage.id] = {"source_id": mage.id, "remaining": mage_shield, "expires_at": 30.0}
	if enemy_shield > 0.0:
		var enemy: BattleSim.Unit = enemies[1]
		initial[enemy.id] = {"source_id": enemy.id, "remaining": enemy_shield, "expires_at": 30.0}
	var problems := sim._enable_skill_transactions(inputs["stats"], true, inputs["relations"], "S2_3_SHIELD_AWARE", initial)
	_check("S24完整数值与关系首步前安装", problems.is_empty() and sim._skill_tick == 0, str(problems))
	return sim


## 显式绑定成功才可入树；保留既有 View 与命中矩形，测试由指定的固定执行点推进。
func _s24_scene(sim: BattleSim) -> BattleSceneScript:
	var scene := BattleSceneScript.new()
	var view := BattleViewScript.new()
	view.name = "View"
	scene.add_child(view)
	var bound := scene.bind_skill_validation(sim, sim.events, true)
	_check("S24完整隔离显式绑定", bound and scene.controller._skill_full_input)
	if not bound:
		scene.free()
		return null
	root.add_child(scene)
	scene.set_process(false)
	_check("S24真实ready仅走隔离路径", view._snap.get("skill_full_input") == true and scene.bot == null and scene._service == null and sim.events._file == null and scene._config.is_empty())
	return scene


## 无窗口套件共用原验证入口及结果汇总；视口仅在本组按既有矩形调整。
func _s24_cases() -> void:
	var previous_size := root.size
	root.size = Vector2i(1920, 1080)
	_s24_single_cast_cases()
	_s24_dual_cast_case()
	_s24_shield_and_mana_cases()
	_s24_clock_case()
	_s24_binding_cases()
	root.size = previous_size


## 单法师：两种入口生成同形请求，队列目标顺序决定先拒绝后命中，爆破汇总原值后舍入。
func _s24_single_cast_cases() -> void:
	var sim := _s24_battle()
	var scene := _s24_scene(sim)
	if scene == null:
		return
	var mage := sim.slot_unit(0)
	var view: BattleViewScript = scene._view
	var projected: Array = view._snap["skills"][mage.id]
	_check("S24单人阵容", sim.living("ally").size() == 1 and scene.controller.selected_slot == 0 and sim.slot_unit(1) == null)
	var expected := ["mage.fire.flame_burst", "mage.fire.fireball", "mage.fire.flame_barrier", "mage.fire.evocation"]
	for i: int in expected.size():
		_check("S24法师槽位 " + String(BattleSim.SKILL_KEYS[i]), projected[i]["implemented"] and projected[i]["skill_id"] == expected[i])
	var burst_cost := view._full_skill_cost_text(projected[0])
	var evocation_cost := view._full_skill_cost_text(projected[3])
	_check("S24目标中文及法力消耗固定一位", burst_cost.begins_with("敌方 ") and burst_cost.ends_with("米 / 耗25.0法力") and evocation_cost.begins_with("自身 ") and evocation_cost.ends_with("米 / 耗0.0法力"))
	var snapshot := _s1a_state(sim)
	_s1b4_key("skill_q", true, true)
	_s1b4_key("skill_q", false)
	_check("S24长按与释放不进队", _s1a_same_state(snapshot, _s1a_state(sim)) and scene.controller._skill_request_seq == 0)
	_s1b4_tap("skill_q")
	var enemies := sim.living("enemy")
	_s1b5_mouse(view, enemies[1].pos, true)
	_s1b5_mouse(view, view._skill_rect(0).get_center())
	var pending := sim._skill_pending.duplicate(true)
	var expected_request := _s1b2_request(sim, 1, 0, "Q")
	var expected_button := _s1b2_request(sim, 2, 0, "Q")
	_check("S24键钮同五字段且接收顺序为施法-目标-施法", pending.size() == 3 and pending[0]["payload"] == expected_request and pending[1]["kind"] == "target" and pending[1]["payload"]["target_id"] == enemies[1].id and pending[2]["payload"] == expected_button and pending[0]["receive_seq"] == 1 and pending[2]["receive_seq"] == 3)
	_check("S24预检失败不拦入队且尚未发布", not projected[0]["preparable"] and scene.last_cast_result.is_empty() and mage.target_id == -1 and view._toast.contains("已入队"))
	scene._process(BattleSim.SKILL_FIXED_STEP)
	var results := _s1b2_results(sim)
	_check("S24执行点在设目标前拒绝、设目标后成功", results.size() == 2 and results[0]["request_seq"] == 1 and results[0]["reason"] == "INVALID_TARGET" and results[1]["request_seq"] == 2 and results[1]["accepted"])
	var effects: Array = scene.last_cast_result.get("details", {}).get("effects", [])
	_check("S24爆破主目标先、其次按ID", effects.size() == 2 and effects[0]["target_id"] == enemies[1].id and effects[1]["target_id"] == enemies[0].id and effects[0]["target_index"] == 0 and effects[1]["target_index"] == 1)
	_check("S24爆破原值174.25两笔合计显示349", effects.size() == 2 and effects[0]["actual_amount"] == 174.25 and effects[1]["actual_amount"] == 174.25 and scene._skill_result_notice == "执行成功：法师·烈焰爆破，2 个目标，有效伤害 349，吸收 0，过量 0" and view._toast.contains(scene._skill_result_notice))
	_check("S24实际结果和日志保留原cast_id及浮点效果", results.size() == 2 and effects.size() == 2 and results[1]["cast_id"] == scene.last_cast_result.get("cast_id") and effects[0]["cast_id"] == results[1]["cast_id"] and results[1]["details"]["effects"][0]["actual_amount"] == 174.25 and enemies[1].hp == 825.75)
	var replay := sim._enqueue_skill_command("cast", expected_request)
	_check("S24失败序号也去重", replay.get("reason") == "DUPLICATE_REQUEST" and sim._skill_pending.is_empty() and _s1b2_results(sim).size() == 2)
	# 独立冷却保持 GCD 已可用；命中原始 1.25 秒的显示边界。
	mage.gcd_until = 0.0
	mage.skill_ready_at["mage.fire.flame_burst"] = 1.25 + 2.0 * BattleSim.SKILL_FIXED_STEP
	_s1b4_tap("skill_q")
	scene._process(BattleSim.SKILL_FIXED_STEP)
	_check("S24冷却实际拒绝原始1.25显示1.3秒", scene.last_cast_result.get("reason") == "SKILL_COOLDOWN" and is_equal_approx(float(scene.last_cast_result.get("details", {}).get("seconds", 0.0)), 1.25) and scene._skill_result_notice == "执行拒绝：法师·烈焰爆破，技能冷却中，剩余 1.3 秒")
	# 多一个副目标，并把最小 ID 移到容器末尾，区分稳定排序与遍历顺序。
	var first: BattleSim.Unit = enemies[0]
	sim.units.erase(first.id)
	sim.units[first.id] = first
	enemies[2].pos = Vector2(590, 470)
	mage.skill_ready_at.erase("mage.fire.flame_burst")
	_s1b4_tap("skill_q")
	scene._process(BattleSim.SKILL_FIXED_STEP)
	var order: Array[int] = []
	for effect: Dictionary in scene.last_cast_result.get("details", {}).get("effects", []):
		order.append(effect["target_id"])
	_check("S24爆破遍历逆序时仍先主目标再按副目标ID", order == [enemies[1].id, enemies[0].id, enemies[2].id], str(order))
	scene.free()


## 双人：角色切换不更改已排命令；火球与治疗执行时各自读取本人的队列目标。
func _s24_dual_cast_case() -> void:
	var sim := _s24_battle(true, 0.0, 100.0, 100.0)
	var scene := _s24_scene(sim)
	if scene == null:
		return
	var mage := sim.slot_unit(0)
	var priest := sim.slot_unit(1)
	var enemy: BattleSim.Unit = sim.living("enemy")[1]
	enemy.hp = 5.0
	var view: BattleViewScript = scene._view
	var priest_slots: Array = view._snap["skills"][priest.id]
	var heal_cost := view._full_skill_cost_text(priest_slots[0])
	_check("S24双人仅配置牧师Q", sim.living("ally").size() == 2 and priest_slots[0]["implemented"] and priest_slots[0]["skill_id"] == "priest.holy.greater_heal" and heal_cost.begins_with("友方 ") and heal_cost.ends_with("米 / 耗25.0法力"))
	var rendered: Array[String] = []
	# 生产 Scene 已订阅，随后观察同一发布中的 View 提示，保留被下一条结果覆盖的火球画面。
	var capture_notice := func(_resolved: Dictionary) -> void:
		rendered.append(view._toast)
	sim.events.cast_resolved.connect(capture_notice)
	_s1b5_mouse(view, enemy.pos, true)
	_s1b4_tap("skill_w")
	_s1b4_tap("slot_2")
	for i: int in range(1, 4):
		_s1b5_mouse(view, view._skill_rect(i).get_center())
		_check("S24牧师空槽不占号 " + String(BattleSim.SKILL_KEYS[i]), priest_slots[i]["empty"] and scene.controller._skill_request_seq == 1 and sim._skill_pending.size() == 2 and view._toast.contains("输入拒绝：空槽"))
	_s1b5_mouse(view, mage.pos, true)
	_s1b5_mouse(view, view._skill_rect(0).get_center())
	_s1b4_tap("slot_1")
	var pending := sim._skill_pending
	_check("S24两角色目标与施法分别固化身份并全场递增", pending.size() == 4 and pending[0]["payload"]["caster_id"] == mage.id and pending[1]["payload"] == _s1b2_request(sim, 1, 0, "W") and pending[2]["payload"]["caster_id"] == priest.id and pending[3]["payload"] == _s1b2_request(sim, 2, 1, "Q") and scene.controller.selected_slot == 0)
	scene._process(BattleSim.SKILL_FIXED_STEP)
	sim.events.cast_resolved.disconnect(capture_notice)
	var results := _s1b2_results(sim)
	if results.size() == 2 and results[0]["accepted"] and results[1]["accepted"]:
		var hit: Dictionary = results[0]["details"]["effects"][0]
		var healed: Dictionary = results[1]["details"]["effects"][0]
		_check("S24火球原角色读取敌人，显示伤害吸收过量", hit["target_id"] == enemy.id and hit["source_id"] == mage.id and hit["actual_amount"] == 5.0 and hit["absorbed_amount"] == 100.0 and is_equal_approx(hit["overkill_amount"], 7.75) and rendered.size() == 2 and rendered[0].contains("执行成功：法师·火球，有效伤害 5，吸收 100，过量 8"))
		_check("S24切回法师后结果仍为牧师治疗", healed["target_id"] == mage.id and healed["source_id"] == priest.id and healed["actual_amount"] == 50.0 and is_equal_approx(healed["overheal_amount"], 196.0) and mage.hp == 1000.0 and view._selected_slot == 0 and scene.last_cast_result["caster_id"] == priest.id and scene._skill_result_notice == "执行成功：牧师·强效治疗，有效治疗 50，过量 196" and view._toast.contains(scene._skill_result_notice))
	else:
		_check("S24火球及强效治疗均自产生实际成功结果", false, str(results))
	# 退出树前留一条输入，验证真正取消队列与订阅，旧控制器不能再投技能。
	var controller := scene.controller
	_s1b4_tap("skill_r")
	root.remove_child(scene)
	_check("S24实际离树清队列及引用", scene.sim == null and controller.sim == null and sim._skill_pending.is_empty() and sim.events.cast_resolved.get_connections().is_empty() and sim.events.battle_ended.get_connections().is_empty() and not controller.press_skill("r"))
	scene.free()


## 屏障与唤醒只落施法者。通过真实初始盾和法力差验证净增、恰半及实际零收益。
func _s24_shield_and_mana_cases() -> void:
	for seed_shield: float in [0.0, 149.75, 200.0]:
		var sim := _s24_battle(false, seed_shield)
		var scene := _s24_scene(sim)
		if scene == null:
			continue
		var mage := sim.slot_unit(0)
		var view: BattleViewScript = scene._view
		var enemy: BattleSim.Unit = sim.living("enemy")[1]
		var initial: String = mage.shield.get("source_cast_id", "")
		_check("S24合法字符串盾登记可首绑 " + str(seed_shield), sim._skill_seen_requests.size() == (1 if seed_shield > 0.0 else 0) and (seed_shield == 0.0 or sim._skill_seen_requests.has(initial)) and scene.controller._skill_request_seq == 0)
		_s1b5_mouse(view, enemy.pos, true)
		_s1b4_tap("skill_e")
		scene._process(BattleSim.SKILL_FIXED_STEP)
		var effects: Array = scene.last_cast_result.get("details", {}).get("effects", [])
		var action := "created" if seed_shield == 0.0 else ("replaced" if seed_shield < 150.0 else "retained")
		var label := "建立" if seed_shield == 0.0 else ("替换" if seed_shield < 150.0 else "保留")
		var amount := "150" if seed_shield == 0.0 else "0"
		_check("S24屏障忽略外部目标并核对真实盾池 " + action, effects.size() == 1 and effects[0]["target_id"] == mage.id and effects[0]["shield_action"] == action and effects[0]["actual_amount"] == maxf(0.0, 150.0 - seed_shield) and mage.target_id == enemy.id and mage.shield.get("remaining", -1) == maxf(150.0, seed_shield) and (seed_shield < 150.0 or mage.shield["source_cast_id"] == initial))
		_check("S24屏障中文及正0.25显示0 " + action, scene.last_cast_result.get("accepted", false) and scene._skill_result_notice == "执行成功：法师·烈焰屏障，%s护盾，净增 %s" % [label, amount] and view._toast.contains(scene._skill_result_notice))
		scene.free()
	for start: float in [98.70, 100.0, 0.0]:
		var sim := _s24_battle(false, 0.0, start)
		var scene := _s24_scene(sim)
		if scene == null:
			continue
		var mage := sim.slot_unit(0)
		var enemy: BattleSim.Unit = sim.living("enemy")[1]
		var view: BattleViewScript = scene._view
		_s1b5_mouse(view, enemy.pos, true)
		_s1b4_tap("skill_w" if start == 0.0 else "skill_r")
		scene._process(BattleSim.SKILL_FIXED_STEP)
		if start == 0.0:
			_check("S24缺蓝执行拒绝中文及所需法力一位小数", scene.last_cast_result.get("reason") == "NOT_ENOUGH_MANA" and scene.last_cast_result.get("details", {}).get("cost") == 15.0 and scene._skill_result_notice == "执行拒绝：法师·火球，法力不足，需 15.0 法力" and view._toast.contains(scene._skill_result_notice))
		else:
			var effects: Array = scene.last_cast_result.get("details", {}).get("effects", [])
			var expected := 1.25 if start < 100.0 else 0.0
			var displayed := "1.3" if start < 100.0 else "0.0"
			_check("S24唤醒对自己、原值与提示 " + displayed, scene.last_cast_result.get("accepted", false) and effects.size() == 1 and effects[0]["actual_amount"] == expected and effects[0]["target_id"] == mage.id and mage.target_id == enemy.id and mage.res == 100.0 and scene._skill_result_notice == "执行成功：法师·唤醒，实得 %s 法力" % displayed)
		scene.free()


## 暂停与失焦各清一次待执行及余量；1×与2×只改变相同固定步的次数。
func _s24_clock_case() -> void:
	var sim := _s24_battle(true)
	var scene := _s24_scene(sim)
	if scene == null:
		return
	var step_size := BattleSim.SKILL_FIXED_STEP
	scene._process(step_size / 2.0)
	_s1b4_tap("skill_r")
	_check("S24暂停前已有队列与半步余量", sim._skill_pending.size() == 1 and sim._skill_accumulator > 0.0 and sim._skill_tick == 0)
	_s1b4_tap("pause")
	_s1b4_tap("slot_2")
	_s1b4_tap("skill_q")
	_check("S24暂停仍可切人、消耗请求号但丢弃战术队列", sim.paused and sim._skill_pending.is_empty() and sim._skill_accumulator == 0.0 and scene.controller.selected_slot == 1 and scene.controller._skill_request_seq == 2 and scene.controller.last_input.get("reason") == "BATTLE_PAUSED")
	_s1b4_tap("pause")
	_check("S24倍率1×接收", scene.set_skill_validation_speed(1))
	scene._process(step_size * 2.0)
	_check("S24恢复无补发且1×两步", sim._skill_tick == 2 and sim.time == 2.0 * step_size and _s1b2_results(sim).is_empty())
	_s1b4_tap("skill_q")
	scene._process(step_size / 2.0)
	scene._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	scene._notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	scene._process(step_size * 4.0)
	_check("S24合成失焦清队列及余量、回焦不自动恢复", sim.paused and sim._skill_pending.is_empty() and sim._skill_accumulator == 0.0 and sim._skill_tick == 2)
	_check("S24倍率2×采用既有setter并拒绝3×", scene.set_skill_validation_speed(2) and not scene.set_skill_validation_speed(3))
	_s1b4_tap("pause")
	scene._process(step_size)
	_check("S24恢复无补发且2×同样两步", sim._skill_tick == 4 and sim.time == 4.0 * step_size and _s1b2_results(sim).is_empty())
	scene.free()


## 首绑拒绝已用整数号；同场重绑保持序号，换场只释放原场；实际配置错误保存最后画面。
func _s24_binding_cases() -> void:
	var used := _s24_battle(false, 12.0)
	var spent := used._enqueue_skill_command("cast", _s1b2_request(used, 1))
	var candidate := BattleSceneScript.new()
	var used_before := _s1a_state(used)
	_check("S24合法初始盾和已用整数号并存仍拒绑", spent.get("queued", false) and not candidate.bind_skill_validation(used, used.events) and candidate.sim == null and used.events.cast_resolved.get_connections().is_empty() and _s1a_same_state(used_before, _s1a_state(used)))
	var old := _s24_battle(false, 12.0)
	var new_battle := _s24_battle()
	var bound := candidate.bind_skill_validation(old, old.events)
	_check("S24换场夹具先绑定原场", bound)
	if bound:
		candidate._unhandled_input(_s1b3_key("skill_r"))
		var old_controller := candidate.controller
		_check("S24同场绑定保留请求号与订阅", candidate.bind_skill_validation(old, old.events) and candidate.controller == old_controller and old_controller._skill_request_seq == 1 and old.events.cast_resolved.get_connections().size() == 1)
		_check("S24旧控制器不认领新场", not old_controller.setup(new_battle, new_battle.events, -1, true))
		_check("S24候选有效后清原场及订阅、换独立场与序号", candidate.bind_skill_validation(new_battle, new_battle.events) and old_controller.sim == null and old._skill_pending.is_empty() and old.slot_unit(0).shield.is_empty() and old.events.cast_resolved.get_connections().is_empty() and candidate.sim == new_battle and candidate.controller._skill_request_seq == 0 and new_battle.events.cast_resolved.get_connections().size() == 1)
	candidate.free()
	for fault: bool in [false, true]:
		var sim := _s24_battle()
		var scene := _s24_scene(sim)
		if scene == null:
			continue
		var controller := scene.controller
		var view: BattleViewScript = scene._view
		if fault:
			# 制造可被投影识别为已实现、但真实执行预检失败的冻结参数违规。
			sim.slot_unit(0).resolved_slots["r"]["mana_cost"] = 1.0
			_s1b4_tap("skill_r")
			_check("S24配置预演失败仍入队且入队阶段不停止", sim._skill_pending.size() == 1 and not sim.finished and sim._skill_validation_error.is_empty())
			scene._process(BattleSim.SKILL_FIXED_STEP)
			_check("S24真实配置异常只发一次原码拒绝、无结束补发", _s1b2_results(sim).size() == 1 and _count(sim.events, "battle_ended") == 0 and scene.last_cast_result.get("reason") == "CONFIG_ERROR" and sim._skill_validation_error.get("request_seq") == 1 and sim._skill_validation_error.get("phase") == "prepare")
			_check("S24配置异常最后一帧留中文结果和终止快照", view._snap.get("finished", false) and view._snap.get("result") == "error" and view._snap.get("skill_full_input", false) and scene._skill_result_notice == "执行拒绝：法师·唤醒，配置异常" and view._toast.contains(scene._skill_result_notice))
		else:
			_s1b4_tap("skill_r")
			scene._process(BattleSim.SKILL_FIXED_STEP)
			_s1b4_tap("skill_e")
			sim._finish("win", "all_enemies_down")
			_check("S24结束后保留真实最后结果", view._snap.get("finished", false) and view._snap.get("result") == "win" and view._toast.contains("法师·唤醒，实得 0.0 法力"))
		_check("S24终止清绑定、输入及订阅 " + str(fault), scene.sim == null and scene.controller == null and controller.sim == null and sim._skill_pending.is_empty() and sim.skill_battle_id.is_empty() and sim.events.cast_resolved.get_connections().is_empty() and sim.events.battle_ended.get_connections().is_empty())
		scene.free()
