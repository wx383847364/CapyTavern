extends Node2D
## 战斗场景驱动：建模拟器、按固定步长推进、把鼠标键盘交给控制器、把快照交给画面。
## 结算只在 BattleSim 里发生；这里不算伤害，也不读任何动画回调。

const MotionTrack := preload("res://scenes/ui/motion_track.gd")
const BattleSim := preload("res://scripts/battle/battle_sim.gd")
const BattleEvents := preload("res://scripts/battle/battle_events.gd")
const BattleConfig := preload("res://scripts/battle/battle_config.gd")
const BattleLaunch := preload("res://scripts/battle/battle_launch.gd")
const BattleController := preload("res://scripts/input/battle_controller.gd")
const DisplayOptionsScript := preload("res://scripts/input/display_options.gd")
const BattleViewScript := preload("res://scenes/ui/battle_view.gd")
const BattleBot := preload("res://scripts/input/battle_bot.gd")
const SaveStore := preload("res://scripts/data/save_store.gd")
const SaveService := preload("res://scripts/data/save_service.gd")
const ItemsTable := preload("res://scripts/data/items_table.gd")
const SortieSession := preload("res://scripts/tavern/sortie_session.gd")

const LOG_PATH := "user://battle_log.jsonl"
const MAIN_SCENE := "res://scenes/main.tscn"
const SLOT_ACTIONS: Array[String] = ["slot_1", "slot_2", "slot_3", "slot_4"]
const SKILL_ACTIONS := {"skill_q": "q", "skill_w": "w", "skill_e": "e", "skill_r": "r"}

var sim: BattleSim
var events: BattleEvents
var controller: BattleController
var bot: BattleBot
var _tick: float = 0.05
var _accumulator: float = 0.0
var _local_tracks: Dictionary[int, MotionTrack] = {}
var _remote_tracks: Dictionary[int, MotionTrack] = {}
var _display_positions: Dictionary[int, Vector2] = {}
var _completed_time := -INF
var _stepping := false
var _toast: String = ""
var _toast_until_ms: int = 0
var _config: Dictionary = {}
var _leaving: bool = false
## 出征进来的战斗（P4）：结算写存档，回酒馆。
var _service: SaveService = null
var _result: String = ""
var _settled: bool = false
var _outcome: String = ""

## 隔离 View 须显式开启并在绑定前提供现有脚本节点；默认场景仍取得原节点。
@onready var _view: Node2D = get_node_or_null("View")
@onready var _display_options := get_node_or_null("/root/DisplayOptions") as DisplayOptionsScript
var _skill_validation_view: bool = false
var _skill_view_slot: String = "R"
var _skill_input_notice: String = ""
var _skill_result_notice: String = ""
var _skill_validation_mode: bool = false
var _skill_validation_id: String = ""
var _skill_validation_speed: int = 1
var _skill_lifecycle_started: bool = false
## 仅存执行结果的独立数据；与 controller.last_input 的入队诊断分开。
var last_cast_result: Dictionary = {}
var _settings_open: bool = false
var _aim_key: String = ""
var _aim_from_button: bool = false
var _pointer: Vector2 = Vector2.ZERO


## 酒馆正式战斗领取预检实例；其他场次从各自锁定的配置初始化。
func _ready() -> void:
	_skill_lifecycle_started = true
	if _skill_validation_mode:
		if not _skill_validation_view:
			_view = null
		if not _skill_validation_current():
			_close_skill_validation()
		else:
			_refresh_view()
		return
	# 预检产物只供本次正式出征领取。默认入口和其他阵容依旧用原初始化。
	var prepared := BattleLaunch.formal_sortie
	BattleLaunch.formal_sortie = {}
	var use_formal := BattleLaunch.from_tavern and (not prepared.is_empty() or not BattleConfig.formal_specs(BattleLaunch.slots, BattleLaunch.mage_spec).is_empty())
	if use_formal:
		sim = prepared.get("sim") as BattleSim
		if sim == null or not sim.formal_skill_sortie or prepared.get("run_id") != BattleLaunch.run_id or prepared.get("slots") != BattleLaunch.slots:
			# 此分支只防失效交接；加载及快照错误应已在酒馆留原面板并可重试。
			push_error("正式出征缺少同场已预检实例")
			get_tree().quit(2)
			return
		_config = sim.config
		events = sim.events
	else:
		# 调试入口不读取上一次酒馆出征的选择。
		var mage_spec := BattleLaunch.mage_spec if BattleLaunch.from_tavern else "mage.fire"
		_config = BattleConfig.load_config({"talents": BattleLaunch.talents, "sets": BattleLaunch.sets, "mage_spec": mage_spec})
		var problems := BattleConfig.validate(_config)
		if not problems.is_empty():
			push_error("战斗配置不可用：" + "; ".join(problems))
			get_tree().quit(2)
			return
		events = BattleEvents.new()
	if use_formal:
		print("BALANCE_FORMAL run_id=%s specs=%s q_sets=%s legacy_modifiers=%s" % [BattleLaunch.run_id, BattleConfig.formal_specs(BattleLaunch.slots, BattleLaunch.mage_spec), BattleLaunch.sets, _config["applied_modifiers"]])
	else:
		print("BALANCE talents=%s sets=%s applied=%s warnings=%s" % [_config["talents"], BattleLaunch.sets, _config["applied_modifiers"], _config["warnings"]])
	_tick = float(_config["tick"])
	events.echo_stdout = true
	events.open_log(LOG_PATH)
	if not use_formal:
		sim = BattleSim.new()
		sim.setup(_config, BattleLaunch.slots, BattleLaunch.seed, events)
	_pointer = get_local_mouse_position()
	controller = BattleController.new()
	if not controller.setup(sim, events, BattleLaunch.captain_slot if BattleLaunch.from_tavern else -1):
		push_error("战斗输入绑定失败")
		get_tree().quit(2)
		return
	sim.player_controls = not BattleLaunch.autoplay
	sim.ally_ai_enabled = sim.player_controls
	if sim.player_controls:
		if controller.selected_unit() != null:
			sim.set_controlled_actor(controller.selected_unit().id)
		controller.load_preferences()
		_pointer = get_local_mouse_position()
	if use_formal:
		events.cast_resolved.connect(_on_formal_cast)
		sim.publish_formal_start()
	if sim.player_controls:
		events.health_effect_applied.connect(_on_health_effect_applied)
		events.selection_changed.connect(_on_feedback_selection)
	events.command_rejected.connect(_on_rejected)
	events.battle_ended.connect(_on_ended)
	if BattleLaunch.from_tavern:
		var table := ItemsTable.new()
		table.load_tables()
		_service = SaveService.new(table, SaveStore.new(SaveStore.path_from_args()))
		_service.load_state()
		SortieSession.read_args_once()
		_service.store.fail_writes = SortieSession.fail_settle_left
		_view.call("set_back_text", "回酒馆（Enter）")
		SortieSession.bus().fire(&"battle_loaded", [BattleLaunch.run_id])
	if BattleLaunch.autoplay:
		bot = BattleBot.new()
		bot.setup(sim, controller)
		bot.passive = BattleLaunch.passive
		if BattleLaunch.fast:
			while not sim.finished and sim.time < float(_config["time_limit"]) + 5.0:
				bot.tick()
				sim.step(_tick)
			if BattleLaunch.from_tavern:
				_back_to_main.call_deferred()
			return
	_refresh_view()


## 隔离模式交给独立调度器；实际战斗在完整模拟步后提交位置，再按渲染帧播放。
func _process(delta: float) -> void:
	_skill_lifecycle_started = true
	if _skill_validation_mode:
		if not _skill_validation_current():
			_close_skill_validation()
			return
		sim._advance_skill_schedule(delta, _skill_validation_speed)
		if not _skill_validation_current():
			_close_skill_validation()
		else:
			_refresh_view()
		return
	if sim == null or _leaving:
		return
	_accumulator += minf(delta, 0.25)
	while _accumulator >= _tick:
		_accumulator -= _tick
		_stepping = true
		if bot != null:
			bot.tick()
		sim.step(_tick)
		_stepping = false
		if sim.time != _completed_time:
			_record_positions()
	_sample_positions()
	_refresh_view()


## 场次由模拟实例标识，单位 ID 在同场不复用；记录结算后的完整位置。
func _record_positions() -> void:
	for unit: BattleSim.Unit in sim.units.values():
		var track: MotionTrack = _local_tracks.get(unit.id)
		if track == null:
			track = MotionTrack.new(sim.get_instance_id(), 0, unit.id)
			_local_tracks[unit.id] = track
		track.record(sim.time, unit.pos, unit.motion_revision)
	_completed_time = sim.time


## 绑定已存在角色的同步源；重连必须提升代次，旧句柄不会再被画面读取。
func open_remote_motion(scene_id: int, entity_id: int, generation: int, delay: float, gap: float) -> MotionTrack:
	if sim == null or scene_id != sim.get_instance_id() or not sim.units.has(entity_id) or delay < 0.0 or gap <= delay or not is_finite(delay) or not is_finite(gap):
		return null
	var previous: MotionTrack = _remote_tracks.get(entity_id)
	if previous != null and generation <= previous.generation:
		return null
	var track := MotionTrack.new(scene_id, generation, entity_id, delay, gap)
	_remote_tracks[entity_id] = track
	return track


## 各单位每帧只取一次位置，远端时钟与本地模拟相互独立。
func _sample_positions(wall: float = Time.get_ticks_usec() / 1000000.0) -> void:
	for id: int in _local_tracks:
		var remote: MotionTrack = _remote_tracks.get(id)
		if remote != null:
			# 重连第一包之前保持原画面，不能闪回本地模拟位置。
			if not remote.samples.is_empty():
				_display_positions[id] = remote.remote_position(wall)
			elif not _display_positions.has(id):
				_display_positions[id] = sim.units[id].pos
		else:
			_display_positions[id] = _local_tracks[id].local_position(_accumulator)


## 渲染战斗快照和技能反馈，隔离验证保留独立的最终画面。
func _refresh_view(final_frame: bool = false) -> void:
	if _stepping:
		return
	if _skill_validation_mode:
		if not _skill_validation_view or _view == null or sim == null or controller == null or _leaving:
			return
		if sim.skill_battle_id != _skill_validation_id or not sim._skill_schedule_active:
			return
		if not final_frame and not _skill_validation_current():
			return
		var data := sim.snapshot(true)
		data["skill_focus_slot"] = _skill_view_slot
		if controller._skill_full_input:
			data["skill_full_input"] = true
		_view.call("render", data, controller.selected_slot, _skill_input_notice + "  " + _skill_result_notice, "")
		return
	if Time.get_ticks_msec() > _toast_until_ms:
		_toast = ""
	var text := _toast
	if sim.formal_skill_sortie and not _skill_result_notice.is_empty():
		text = _skill_result_notice
	var frame := sim.snapshot()
	# 初次入场和外部直接推进模拟时，建立可信位置基线。
	if _completed_time != sim.time:
		_local_tracks.clear()
		_record_positions()
		_sample_positions()
	for unit: Dictionary in frame["units"]:
		var id: int = unit["id"]
		var track := _local_tracks[id]
		var actor: BattleSim.Unit = sim.units[id]
		# 两步之间也可能执行瞬移、暂停或重置；不能从旧位置再插回去。
		if track.samples.back().revision != actor.motion_revision or track.samples.back().pos != actor.pos or ((sim.paused or sim.finished) and track.samples.size() > 1):
			track.record(sim.time, actor.pos, actor.motion_revision)
			if not _remote_tracks.has(id):
				_display_positions[id] = actor.pos
		unit["pos"] = _display_positions[id]
	if sim.player_controls:
		var actor := controller.selected_unit()
		if actor != null and not actor.cast.is_empty() and _skill_result_notice == "技能已入队":
			# 读条接替入队提示；命中或取消时再由正式结果提供反馈。
			_skill_result_notice = ""
			text = ""
		if actor != null and not actor.cast_approach.is_empty():
			if _skill_result_notice == "技能已入队":
				_skill_result_notice = ""
			text = "正在接近 · %s" % actor.cast_approach["name"]
		var target := controller.target_for(actor)
		var aim := controller.aim_view(_aim_key, _pointer, _pointer_is_ground()) if not _aim_key.is_empty() else {}
		frame["player_hud"] = {"target": target.id if target != null else -1,
			"heal_preview": sim.player_heal_preview(actor, target),
			"prefs": controller.preferences, "settings": _settings_open, "aim": aim,
			"display": _display_options.limits() if _settings_open and _display_options != null else {}}
	_view.call("render", frame, controller.selected_slot, text, ProjectSettings.globalize_path(LOG_PATH))


## 实际命中时按当前操控身份筛选个人反馈，飞弹冲击供全队观察。
func _on_health_effect_applied(source_id: int, target_id: int, amount: float, healing: bool, critical: bool, projectile: bool) -> void:
	if _leaving or sim.paused or sim.finished:
		return
	var target: BattleSim.Unit = sim.units.get(target_id)
	if target == null:
		return
	if projectile:
		_view.call("show_projectile_impact", target.pos)
	if source_id != sim.controlled_actor_id:
		return
	_view.call("show_combat_number", target_id, target.pos, target.radius, amount, healing, critical)
	if not healing and target.side == "enemy":
		_view.call("show_enemy_hit", target_id, critical)


## 切人清理个人闪白与飘字，场上飞弹继续显示。
func _on_feedback_selection(_slot: int) -> void:
	_skill_result_notice = ""
	_toast = ""
	_view.call("clear_enemy_hits")


## 新的正式普通命令拒绝取代上次技能提示；旧战斗和隔离继续使用原反馈。
func _on_rejected(unit_id: int, _kind: String, reason: String) -> void:
	if _skill_validation_mode:
		_toast = reason
		return
	var unit := controller.selected_unit()
	if unit == null or unit.id != unit_id:
		return
	_toast = String(_view.call("reason_text", reason))
	_toast_until_ms = Time.get_ticks_msec() + 1500
	if sim.formal_skill_sortie:
		_skill_result_notice = ""


## 隔离结束只解绑清队列，不能执行旧日志收尾、存档结算或场景跳转。
func _on_ended(result: String, reason: String, elapsed: float) -> void:
	if _skill_validation_mode:
		_result = result
		_refresh_view(true)
		_close_skill_validation()
		return
	_view.call("clear_enemy_hits", true)
	_cancel_aim()
	_settings_open = false
	_result = result
	events.close_log()
	print("BATTLE_RESULT result=%s reason=%s elapsed=%.2f log=%s" % [result, reason, elapsed, ProjectSettings.globalize_path(LOG_PATH)])
	if BattleLaunch.from_tavern:
		_settle()
	if BattleLaunch.autoplay:
		if BattleLaunch.from_tavern:
			# 无人值守出征：快速模式在 _ready 里算完后直接回酒馆；否则让结果页停 2 秒再回
			if not BattleLaunch.fast:
				await get_tree().create_timer(2.0).timeout
				_back_to_main()
			return
		_leaving = true
		if BattleLaunch.fast:
			get_tree().quit(0)
		else:
			await get_tree().create_timer(2.0).timeout
			get_tree().quit(0)


## 战斗先分流真人输入与隔离入口；重复按键不产生请求，真人瞄准可接收释放。
func _unhandled_input(event: InputEvent) -> void:
	if _skill_validation_mode and not _skill_validation_current():
		_close_skill_validation()
		return
	if sim == null or _leaving:
		return
	if event is InputEventKey and (event as InputEventKey).echo:
		return
	if sim.finished:
		if event.is_action_pressed("ui_accept") or event.is_action_pressed("cancel_layer"):
			_back_to_main()
		elif event.is_action_pressed("click_primary") and _view.call("hit_test", _event_pos(event)).get("kind", "") == "back":
			_back_to_main()
		return
	if sim.player_controls:
		_player_input(event)
		return
	if event.is_action_pressed("click_primary"):
		_on_click(_event_pos(event), false)
	elif event.is_action_pressed("click_secondary"):
		_on_click(_event_pos(event), true)
	elif event.is_action_pressed("pause"):
		controller.toggle_pause()
	# 选人通知可同步离场；不能继续用已解绑控制器处理本事件的其他动作。
	if _skill_validation_mode and not _skill_validation_current():
		return
	for index in SLOT_ACTIONS.size():
		if event.is_action_pressed(SLOT_ACTIONS[index]):
			controller.select_slot(index)
			if _skill_validation_mode and not _skill_validation_current():
				return
	for action: String in SKILL_ACTIONS:
		if event.is_action_pressed(action):
			_submit_skill(String(SKILL_ACTIONS[action]))
	if _skill_validation_mode:
		_refresh_view()


## 鼠标事件自带的位置换成战场坐标（不读全局鼠标位置，窗口没焦点或注入事件时也准）。
func _event_pos(event: InputEvent) -> Vector2:
	if event is InputEventMouse:
		return make_input_local(event).position
	return Vector2(-1.0, -1.0)


## 点击先给界面：头像、技能按钮、面板空白处都不会传给战场。
func _on_click(pos: Vector2, secondary: bool) -> void:
	if _skill_validation_mode and not _skill_validation_current():
		return
	# 无 View 的隔离实例没有几何命中能力；验证直接调用同一分发函数，不伪装图形验收。
	if _view == null:
		return
	# 战场点交控制器，View命中点单独转入其局部坐标；父子位移不能把面板点击漏给移动。
	var hit_pos := _view.to_local(to_global(pos)) if _skill_validation_view else pos
	var hit: Dictionary = _view.call("hit_test", hit_pos)
	_dispatch_click(hit, pos, secondary)


## 分发真实点击；正式场普通命令入队前的拒绝也走已有提示，选人和右键空地不重放旧结果。
func _dispatch_click(hit: Dictionary, pos: Vector2, secondary: bool) -> void:
	if _leaving or sim == null or (_skill_validation_mode and not _skill_validation_current()):
		return
	if sim.player_controls:
		_player_click(hit, pos, secondary)
		return
	if hit.is_empty():
		var previous_input := controller.last_input
		if secondary:
			controller.on_right_click(pos)
		else:
			controller.on_left_click(pos)
		# 控制器每次入队尝试都会换结果字典；相同拒绝连续发生时仍要更新提示时间。
		var latest_input := controller.last_input
		if sim.formal_skill_sortie and not is_same(previous_input, latest_input) and not latest_input.get("queued", false):
			var unit := controller.selected_unit()
			if unit != null:
				_on_rejected(unit.id, "target" if secondary else "move", String(latest_input["reason"]))
		return
	if secondary:
		return
	match String(hit["kind"]):
		"portrait":
			controller.select_slot(int(hit["slot"]))
		"skill":
			_submit_skill(String(hit["key"]))


## 实战输入先处理设置与瞄准；Esc 可撤回当前角色待执行的接近。
func _player_input(event: InputEvent) -> void:
	if event is InputEventMouse:
		_pointer = _event_pos(event)
		if event.is_action_pressed("click_primary") or event.is_action_pressed("click_secondary"):
			_on_click(_pointer, event.is_action_pressed("click_secondary"))
			_refresh_view()
		return
	if not (event is InputEventKey or event is InputEventAction):
		return
	if event.is_action_pressed("cancel_layer"):
		if not _settings_open and _aim_key.is_empty():
			controller.cancel_skill_approach()
		_settings_open = false
		_cancel_aim()
	elif _settings_open:
		return
	elif event.is_action_pressed("pause"):
		_cancel_aim()
		controller.toggle_pause()
	elif event.is_action_pressed("battle_cycle_target"):
		controller.cycle_target()
	else:
		for index in SLOT_ACTIONS.size():
			if event.is_action_pressed(SLOT_ACTIONS[index]) or event.is_action_pressed("battle_slot_%d" % (index + 1)):
				var previous := controller.selected_slot
				controller.select_slot(index)
				if previous != controller.selected_slot:
					_cancel_aim()
				break
		for action: String in SKILL_ACTIONS:
			var key := String(SKILL_ACTIONS[action])
			if event.is_action_pressed(action):
				if sim.paused or not controller.preferences["release_cast"]:
					_player_cast(key)
				elif _aim_key.is_empty():
					_begin_aim(key, false)
			elif event.is_action_released(action) and key == _aim_key and not _aim_from_button:
				_cancel_aim()
				_player_cast(key)
	_refresh_view()


## 地面瞄准允许覆盖场上单位，界面和留白会截断落点。
func _pointer_is_ground() -> bool:
	var hit: Dictionary = _view.call("hit_test", _pointer)
	return hit.is_empty() or hit.get("kind") == "world_target"


## 按键和地面按钮共用同一个角色瞄准锁。
func _begin_aim(key: String, from_button: bool) -> void:
	var actor := controller.selected_unit()
	if actor == null or not actor.alive:
		return
	_aim_key = key
	_aim_from_button = from_button
	sim.set_ally_aim_actor(actor.id)


## 取消后不再认领按键抬起，也不复用技能栏进入的等待落点。
func _cancel_aim() -> void:
	_aim_key = ""
	_aim_from_button = false
	if sim != null:
		sim.set_ally_aim_actor(-1)


## 将绘制命中化为选目标、移动、打开设置或一次技能确认，模态界面消费全部点击。
func _player_click(hit: Dictionary, pos: Vector2, secondary: bool) -> void:
	_pointer = pos
	var kind := String(hit.get("kind", ""))
	if _settings_open:
		if not secondary and kind == "settings_close":
			_settings_open = false
		elif not secondary and kind == "display_preference" and _display_options != null:
			if controller.set_preference(hit["key"], hit["value"]):
				_display_options.apply_preferences(controller.preferences)
			else:
				_toast = "设置保存失败"
				_toast_until_ms = Time.get_ticks_msec() + 1500
		elif not secondary and kind == "preference":
			if not controller.toggle_preference(hit["key"]):
				_toast = "设置保存失败"
				_toast_until_ms = Time.get_ticks_msec() + 1500
		return
	if not secondary and kind == "settings":
		_cancel_aim()
		sim.set_paused(true)
		_settings_open = true
		return
	if _aim_from_button:
		if secondary:
			_cancel_aim()
		elif kind in ["", "world_target"]:
			var key := _aim_key
			_cancel_aim()
			_player_cast(key)
		return
	if secondary:
		if kind in ["", "world_target"]:
			var previous := controller.last_input
			controller.player_right_click(pos, int(hit.get("id", -1)))
			if sim.formal_skill_sortie and not is_same(previous, controller.last_input) and not controller.last_input.get("queued", false):
				_on_rejected(controller.selected_unit().id, kind, controller.last_input["reason"])
			elif sim.formal_skill_sortie and not is_same(previous, controller.last_input):
				_skill_result_notice = ""
		return
	match kind:
		"world_target", "target":
			controller.select_target(int(hit.get("id", -1)))
		"skill":
			var key: String = hit["key"]
			if not sim.paused and controller.aim_view(key, pos, false).get("ground", false):
				_begin_aim(key, true)
			else:
				_cancel_aim()
				_player_cast(key)


## 正式结果由事件确认；旧版爆破依据实际命中提示，方向技能独立处理。
func _player_cast(key: String) -> void:
	var actor := controller.selected_unit()
	if sim.paused:
		if actor != null:
			_on_rejected(actor.id, "skill", "paused")
		return
	var on_ground := _pointer_is_ground()
	var aim := controller.aim_view(key, _pointer, on_ground)
	var before := actor.damage_done if actor != null else 0.0
	var queued := controller.submit_player_skill(key, _pointer, on_ground)
	if sim.formal_skill_sortie:
		_toast = ""
		_skill_result_notice = "技能已入队" if queued else "输入拒绝：" + String(_view.call("reason_text", controller.last_input.get("reason", "无角色")))
	elif not queued and actor != null:
		_on_rejected(actor.id, "skill", controller.last_input.get("reason", "no_target"))
	elif aim.get("ground", false) and not aim.get("direction", false) and actor != null and actor.damage_done == before:
		_toast = "烈焰爆破：未命中"
		_toast_until_ms = Time.get_ticks_msec() + 1500


## 键钮共用一个入口，正式技能提交提示替换更旧的普通命令提示，实际效果等执行事件。
func _submit_skill(key: String) -> void:
	controller.press_skill(key)
	if _skill_validation_mode:
		_skill_validation_input_notice(key)
	elif sim.formal_skill_sortie:
		# 法力和目标等由执行时判定；暂停、空槽等未入队情况仅显示输入提示。
		var why := String(controller.last_input.get("reason", ""))
		_toast = ""
		_skill_result_notice = "技能已入队" if controller.last_input.get("queued", false) else "输入拒绝：" + String(BattleViewScript.REASON_TEXT.get(why, "输入不可用"))


## 失焦暂停不自动恢复；退出/销毁立即解绑，即使未入树的验证实例也清理订阅。
func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE:
		_skill_lifecycle_started = true
	if _skill_validation_mode:
		if what == NOTIFICATION_EXIT_TREE or what == NOTIFICATION_PREDELETE:
			_close_skill_validation()
		elif what == NOTIFICATION_APPLICATION_FOCUS_OUT:
			if _skill_validation_current():
				sim.set_paused(true)
			else:
				_close_skill_validation()
		return
	# 失去焦点：战斗暂停，回来后等玩家自己按 P 继续。
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and sim != null:
		_cancel_aim()
		sim.set_paused(true)
	elif what == NOTIFICATION_EXIT_TREE and sim != null:
		if events.health_effect_applied.is_connected(_on_health_effect_applied):
			events.health_effect_applied.disconnect(_on_health_effect_applied)
		if events.selection_changed.is_connected(_on_feedback_selection):
			events.selection_changed.disconnect(_on_feedback_selection)
		if is_instance_valid(_view):
			_view.call("clear_enemy_hits", true)
		if sim.formal_skill_sortie:
			# 正式场额外解绑事务，清理盾、关系和排队请求。
			if events.cast_resolved.is_connected(_on_formal_cast):
				events.cast_resolved.disconnect(_on_formal_cast)
			if controller != null:
				controller.release_skill_validation()
			sim._leave_skill_schedule()
			events.close_log()


## 结算写进存档（P2b 的 settle）。选中的战斗角色只记 selectedSlot，不会变成队长。
## 写失败：不返回、不发奖，结果页提示，再按一次返回就重试。
func _settle() -> bool:
	if _skill_validation_mode:
		return false
	if _settled:
		return true
	var party: Array = []
	for class_id: Variant in BattleLaunch.slots:
		if String(class_id) != "":
			party.append(String(class_id))
	var saved := _service.settle(BattleLaunch.run_id, _result, controller.selected_slot, party)
	SortieSession.fail_settle_left = _service.store.fail_writes
	if bool(saved["ok"]):
		_settled = true
		_outcome = String(saved.get("outcome", ""))
		_view.call("set_notice", "")
		SortieSession.bus().fire(&"battle_settled", [BattleLaunch.run_id, _result, _outcome])
		return true
	SortieSession.bus().fire(&"settle_failed", [BattleLaunch.run_id, String(saved["reason"])])
	_view.call("set_notice", "未保存，本次战斗结果未记录，按「回酒馆」重试" if String(saved["reason"]) == "write_failed" else "结算失败（%s）" % String(saved["reason"]))
	return false


## 正式胜负沿用原保存重试；运行中配置停场允许返回酒馆，跳过胜负和奖励写入。
func _back_to_main() -> void:
	if _skill_validation_mode:
		_close_skill_validation()
		return
	if BattleLaunch.from_tavern:
		var configuration_error := sim != null and sim.formal_skill_sortie and sim.result == "error"
		if not configuration_error and not _settle():
			return
		_leaving = true
		BattleLaunch.from_tavern = false
		SortieSession.locked = {}
		SortieSession.returned = {} if configuration_error else {"result": _result, "run_id": BattleLaunch.run_id, "outcome": _outcome}
		SortieSession.change_scene(get_tree(), SortieSession.TAVERN_SCENE)
		return
	_leaving = true
	events.close_log()
	get_tree().change_scene_to_file(MAIN_SCENE)


## 入树前原子验证候选及可选现有 View；显式选项默认关闭，不补建节点或正式初始化。
func bind_skill_validation(battle_sim: BattleSim, bus: BattleEvents, with_view: bool = false) -> bool:
	if battle_sim == null or bus == null or _skill_lifecycle_started or is_inside_tree():
		return false
	# 在修改任何绑定前检查现有子节点，不能靠 ready 自动补建或默认场景初始化兜底。
	var candidate_view := get_node_or_null("View")
	if with_view and (not candidate_view is Node2D or candidate_view.get_script() != BattleViewScript or candidate_view.is_queued_for_deletion()):
		return false
	if _skill_validation_mode and sim == battle_sim and events == bus and controller != null and _skill_validation_id == battle_sim.skill_battle_id:
		# 同场重复绑定不重复订阅，也不清掉跨角色请求序号。
		if not controller.setup(battle_sim, bus, controller.selected_slot, true):
			return false
		_skill_validation_view = with_view
		_view = candidate_view if with_view else null
		return true
	var candidate := BattleController.new()
	if not candidate.setup(battle_sim, bus, -1, true):
		return false
	if _skill_validation_mode:
		_close_skill_validation()
	_skill_validation_mode = true
	_skill_validation_view = with_view
	_view = candidate_view if with_view else null
	_skill_view_slot = "R"
	_skill_input_notice = ""
	_skill_result_notice = ""
	_skill_validation_id = battle_sim.skill_battle_id
	_skill_validation_speed = 1
	sim = battle_sim
	events = bus
	controller = candidate
	_leaving = false
	_toast = ""
	last_cast_result = {}
	events.cast_resolved.connect(_on_validation_cast)
	events.battle_ended.connect(_on_ended)
	return true


## 只核本次绑定的身份；旧场控制器不能自动取得新场的调度或输入权。
func _skill_validation_current() -> bool:
	return not _leaving and sim != null and events != null and controller != null and sim.events == events and not _skill_validation_id.is_empty() and sim.skill_battle_id == _skill_validation_id and sim._skill_schedule_active and sim._skill_transactions_enabled and not sim.finished and not sim.skill_input_locked


## 只允许既有两档倍速，不推进时钟、不改模拟单步长度，暂停时也可选择恢复后的倍率。
func set_skill_validation_speed(speed: int) -> bool:
	if not _skill_validation_mode or not _skill_validation_current() or speed not in [1, 2]:
		return false
	_skill_validation_speed = speed
	return true


## 结果只读存副本；业务失败提示来自执行结果，不把入队 queued 当作施法 accepted。
func _on_validation_cast(resolved: Dictionary) -> void:
	if _leaving or resolved.get("battle_id") != _skill_validation_id:
		return
	last_cast_result = resolved.duplicate(true)
	if controller._skill_full_input:
		_skill_result_notice = _full_skill_result_text(resolved)
		if resolved.get("reason") == "CONFIG_ERROR" and sim.finished and sim.reason == "skill_validation_error":
			# Sim 先标记停场再发布拒绝，且没有结束事件。立即保存最终快照，随后由正常生命周期解绑。
			_refresh_view(true)
			return
		_refresh_view()
		return
	if not resolved.get("accepted", false):
		_toast = String(resolved.get("reason", ""))
		_skill_result_notice = "执行拒绝：" + _toast
	else:
		# 唤醒实得只来自已完成结果，不以资源差减去自然恢复倒推。
		var actual: float = 0.0
		for effect: Dictionary in resolved.get("details", {}).get("effects", []):
			actual += float(effect["actual_amount"])
		_skill_result_notice = "执行成功：唤醒实得 %.1f 法力" % actual
	_refresh_view()


## 存下本场手动事务结果，仅显示当前角色的技能反馈。
func _on_formal_cast(resolved: Dictionary) -> void:
	if _leaving or resolved.get("battle_id") != sim.skill_battle_id:
		return
	if resolved.get("source") == "ai":
		if sim.result == "error":
			_view.call("set_notice", "战斗配置异常，本次未结算")
		return
	last_cast_result = resolved.duplicate(true)
	if not sim.player_controls or resolved.get("caster_id") == sim.controlled_actor_id:
		_skill_result_notice = _full_skill_result_text(resolved)
		_toast = ""
	if resolved.get("reason") == "CONFIG_ERROR" and sim.result == "error":
		_view.call("set_notice", "战斗配置异常，本次未结算")
	_refresh_view()


## 按事件身份显示原施法者、装备技能和实际结果，包括寒霜的控制与位移。
func _full_skill_result_text(resolved: Dictionary) -> String:
	var caster: BattleSim.Unit = sim.units.get(resolved["caster_id"])
	var skill_id: String = resolved["skill_id"]
	var skill_name := skill_id
	var caster_name := "角色 %d" % resolved["caster_id"]
	if caster != null:
		caster_name = caster.display_name
		var slots := caster.skills if caster.spec_id == BattleConfig.MAGE_FROST else caster.resolved_slots
		for skill: Variant in slots.values():
			if skill is Dictionary and skill.get("skill_id", skill.get("id")) == skill_id and skill.get("name") is String:
				skill_name = skill["name"]
				break
	var subject := "%s·%s" % [caster_name, skill_name]
	var details: Dictionary = resolved["details"]
	if not resolved["accepted"]:
		_toast = resolved["reason"]
		var explanation := String(BattleViewScript.REASON_TEXT.get(_toast, "无法施放"))
		if details.has("cost"):
			explanation += "，需 %s 法力" % BattleViewScript.skill_amount_text(float(details["cost"]), true)
		elif details.has("seconds"):
			explanation += "，剩余 %s 秒" % BattleViewScript.skill_amount_text(float(details["seconds"]), true)
		return "执行拒绝：%s，%s" % [subject, explanation]
	if skill_id.begins_with("mage.frost."):
		var frost_outcome := ""
		match skill_id:
			"mage.frost.frostbolt":
				frost_outcome = "有效伤害 %s" % BattleViewScript.skill_amount_text(float(details["damage"]))
			"mage.frost.frost_nova":
				frost_outcome = "冻结 %d 只小怪，有效伤害 %s" % [details["frozen"], BattleViewScript.skill_amount_text(float(details["damage"]))]
			"mage.frost.blink":
				frost_outcome = "移动 %s 米" % BattleViewScript.skill_amount_text(float(details["distance_m"]), true)
			"mage.frost.ice_block":
				frost_outcome = "开始免疫伤害并回复生命与法力"
		return "%s，%s" % [subject, frost_outcome]
	# 先分别汇总真实效果；先舍入单个目标会改变爆破总量。零收益仍是成功。
	var effects: Array = details["effects"]
	var actual := 0.0
	var absorbed := 0.0
	var excess := 0.0
	for effect: Dictionary in effects:
		actual += float(effect["actual_amount"])
		absorbed += float(effect.get("absorbed_amount", 0.0))
		excess += float(effect.get("overkill_amount", effect.get("overheal_amount", 0.0)))
	var amount := BattleViewScript.skill_amount_text(actual)
	var outcome := ""
	match skill_id:
		"mage.fire.fireball", "mage.fire.flame_burst":
			if skill_id == "mage.fire.flame_burst":
				outcome = "未命中，" if effects.is_empty() else "%d 个目标，" % effects.size()
			outcome += "有效伤害 %s，吸收 %s，过量 %s" % [amount, BattleViewScript.skill_amount_text(absorbed), BattleViewScript.skill_amount_text(excess)]
		"mage.fire.flame_barrier":
			var action := String(effects[0]["shield_action"])
			var label := String({"created": "建立", "replaced": "替换", "retained": "保留", "zero": "未生成"}[action])
			outcome = "%s护盾，净增 %s" % [label, amount]
		"priest.holy.greater_heal":
			outcome = "有效治疗 %s，过量 %s" % [amount, BattleViewScript.skill_amount_text(excess)]
		"mage.fire.evocation":
			outcome = "实得 %s 法力" % BattleViewScript.skill_amount_text(actual, true)
	return "执行成功：%s，%s" % [subject, outcome]


## 先封住本地输入再断订阅和清本场队列；失效旧绑定不清理或暂停新场。
func _close_skill_validation() -> void:
	if not _skill_validation_mode:
		return
	_leaving = true
	if events != null:
		if events.cast_resolved.is_connected(_on_validation_cast):
			events.cast_resolved.disconnect(_on_validation_cast)
		if events.battle_ended.is_connected(_on_ended):
			events.battle_ended.disconnect(_on_ended)
	if controller != null:
		controller.release_skill_validation()
	if sim != null and not _skill_validation_id.is_empty() and sim.skill_battle_id == _skill_validation_id:
		sim._leave_skill_schedule()
	_skill_validation_id = ""
	controller = null
	sim = null
	events = null


## 读取控制器本地诊断；输入排队与执行结果分栏，不把 queued 提示为成功。
func _skill_validation_input_notice(slot: String) -> void:
	if not _skill_validation_current():
		return
	_skill_view_slot = slot.to_upper()
	if controller.last_input.get("queued", false):
		_skill_input_notice = "输入：已入队，待执行"
	else:
		# 旧夹具保留原提示，完整隔离场将同一本地诊断码转为中文。
		var code := String(controller.last_input.get("reason", ""))
		var explanation := String(BattleViewScript.REASON_TEXT.get(code, "输入不可用")) if controller._skill_full_input else code
		_skill_input_notice = "输入拒绝：" + explanation
