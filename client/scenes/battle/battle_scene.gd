extends Node2D
## 战斗场景驱动：建模拟器、按固定步长推进、把鼠标键盘交给控制器、把快照交给画面。
## 结算只在 BattleSim 里发生；这里不算伤害，也不读任何动画回调。

const BattleSim := preload("res://scripts/battle/battle_sim.gd")
const BattleEvents := preload("res://scripts/battle/battle_events.gd")
const BattleConfig := preload("res://scripts/battle/battle_config.gd")
const BattleLaunch := preload("res://scripts/battle/battle_launch.gd")
const BattleController := preload("res://scripts/input/battle_controller.gd")
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
var _toast: String = ""
var _toast_until_ms: int = 0
var _config: Dictionary = {}
var _leaving: bool = false
## 出征进来的战斗（P4）：结算写存档，回酒馆。
var _service: SaveService = null
var _result: String = ""
var _settled: bool = false
var _outcome: String = ""

@onready var _view: Node2D = $View


func _ready() -> void:
	_config = BattleConfig.load_config({"talents": BattleLaunch.talents, "sets": BattleLaunch.sets})
	var problems := BattleConfig.validate(_config)
	if not problems.is_empty():
		push_error("战斗配置不可用：" + "; ".join(problems))
		get_tree().quit(2)
		return
	print("BALANCE talents=%s sets=%s applied=%s warnings=%s" % [_config["talents"], BattleLaunch.sets, _config["applied_modifiers"], _config["warnings"]])
	_tick = float(_config["tick"])
	events = BattleEvents.new()
	events.echo_stdout = true
	events.open_log(LOG_PATH)
	sim = BattleSim.new()
	sim.setup(_config, BattleLaunch.slots, BattleLaunch.seed, events)
	controller = BattleController.new()
	controller.setup(sim, events, BattleLaunch.captain_slot if BattleLaunch.from_tavern else -1)
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


func _process(delta: float) -> void:
	if sim == null or _leaving:
		return
	_accumulator += minf(delta, 0.25)
	while _accumulator >= _tick:
		_accumulator -= _tick
		if bot != null:
			bot.tick()
		sim.step(_tick)
	_refresh_view()


func _refresh_view() -> void:
	if Time.get_ticks_msec() > _toast_until_ms:
		_toast = ""
	_view.call("render", sim.snapshot(), controller.selected_slot, _toast, ProjectSettings.globalize_path(LOG_PATH))


func _on_rejected(unit_id: int, _kind: String, reason: String) -> void:
	var unit := controller.selected_unit()
	if unit == null or unit.id != unit_id:
		return
	_toast = String(_view.call("reason_text", reason))
	_toast_until_ms = Time.get_ticks_msec() + 1500


func _on_ended(result: String, reason: String, elapsed: float) -> void:
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


func _unhandled_input(event: InputEvent) -> void:
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
	if event.is_action_pressed("click_primary"):
		_on_click(_event_pos(event), false)
	elif event.is_action_pressed("click_secondary"):
		_on_click(_event_pos(event), true)
	elif event.is_action_pressed("pause"):
		controller.toggle_pause()
	for index in SLOT_ACTIONS.size():
		if event.is_action_pressed(SLOT_ACTIONS[index]):
			controller.select_slot(index)
	for action: String in SKILL_ACTIONS:
		if event.is_action_pressed(action):
			controller.press_skill(SKILL_ACTIONS[action])


## 鼠标事件自带的位置换成战场坐标（不读全局鼠标位置，窗口没焦点或注入事件时也准）。
func _event_pos(event: InputEvent) -> Vector2:
	if event is InputEventMouse:
		return make_input_local(event).position
	return Vector2(-1.0, -1.0)


## 点击先给界面：头像、技能按钮、面板空白处都不会传给战场。
func _on_click(pos: Vector2, secondary: bool) -> void:
	var hit: Dictionary = _view.call("hit_test", pos)
	if hit.is_empty():
		if secondary:
			controller.on_right_click(pos)
		else:
			controller.on_left_click(pos)
		return
	if secondary:
		return
	match String(hit["kind"]):
		"portrait":
			controller.select_slot(int(hit["slot"]))
		"skill":
			controller.press_skill(String(hit["key"]))


func _notification(what: int) -> void:
	# 失去焦点：战斗暂停，回来后等玩家自己按 P 继续
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and sim != null:
		sim.set_paused(true)


## 结算写进存档（P2b 的 settle）。选中的战斗角色只记 selectedSlot，不会变成队长。
## 写失败：不返回、不发奖，结果页提示，再按一次返回就重试。
func _settle() -> bool:
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


func _back_to_main() -> void:
	if BattleLaunch.from_tavern:
		if not _settle():
			return
		_leaving = true
		BattleLaunch.from_tavern = false
		SortieSession.locked = {}
		SortieSession.returned = {"result": _result, "run_id": BattleLaunch.run_id, "outcome": _outcome}
		SortieSession.change_scene(get_tree(), SortieSession.TAVERN_SCENE)
		return
	_leaving = true
	events.close_log()
	get_tree().change_scene_to_file(MAIN_SCENE)
