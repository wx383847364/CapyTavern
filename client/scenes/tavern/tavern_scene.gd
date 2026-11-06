extends Node2D
## 酒馆场景驱动：建逻辑层、按固定步长推进、把鼠标键盘交给控制器、把快照交给画面。
## 移动、交互、面板规则都在 TavernSim；这里不判断可不可走，也不读任何动画回调。
## 队长来自存档（P2 的单档服务）：存档里有队长才生成角色，位置不进存档，重启回默认落点。

const TavernSim := preload("res://scripts/tavern/tavern_sim.gd")
const TavernEvents := preload("res://scripts/tavern/tavern_events.gd")
const TavernLayout := preload("res://scripts/data/tavern_layout.gd")
const TavernController := preload("res://scripts/input/tavern_controller.gd")
const ItemsTable := preload("res://scripts/data/items_table.gd")
const SaveStore := preload("res://scripts/data/save_store.gd")
const SaveService := preload("res://scripts/data/save_service.gd")
const TavernRoster := preload("res://scripts/tavern/tavern_roster.gd")
const TavernUi := preload("res://scenes/ui/tavern_ui.gd")
const StageText := preload("res://scripts/data/stage_text.gd")
const SortieSession := preload("res://scripts/tavern/sortie_session.gd")
const BattleLaunch := preload("res://scripts/battle/battle_launch.gd")
const BattleConfig := preload("res://scripts/battle/battle_config.gd")
const BATTLE_SCENE := "res://scenes/battle/battle.tscn"

const LOG_PATH := "user://tavern_log.jsonl"
const TICK := 0.05

var sim: TavernSim
var events: TavernEvents
var controller: TavernController
var service: SaveService
var table: ItemsTable
var roster: TavernRoster
var ui: TavernUi
var _accumulator: float = 0.0
var _toast: String = ""
var _toast_until_ms: int = 0
var _class_colors: Dictionary = {}
var _loading: bool = false

@onready var _view: Node2D = $View


func _ready() -> void:
	var layout := TavernLayout.load_layout()
	var problems := TavernLayout.validate(layout)
	if not problems.is_empty():
		push_error("酒馆布局不可用：" + "; ".join(problems))
		get_tree().quit(2)
		return
	events = TavernEvents.new()
	events.echo_stdout = OS.get_cmdline_user_args().has("--echo")
	events.open_log(LOG_PATH)
	sim = TavernSim.new()
	sim.setup(layout, events)
	var geometry := _geometry_problems(layout)
	if not geometry.is_empty():
		push_error("酒馆布局几何不合法：" + "; ".join(geometry))
		get_tree().quit(2)
		return
	controller = TavernController.new()
	controller.setup(sim)
	table = ItemsTable.new()
	table.load_tables()
	service = SaveService.new(table, SaveStore.new(_save_path()))
	service.load_state()
	for note in service.notes:
		print("SAVE_NOTE ", note)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--fail-writes="):
			service.store.fail_writes = int(arg.get_slice("=", 1))  # 验收用：前 N 次写盘失败，看「未保存」和重试
	roster = TavernRoster.new(service, StageText.load_stage())
	ui = TavernUi.new()
	add_child(ui)
	ui.setup(roster)
	ui.open_requested.connect(_on_open_requested)
	ui.close_requested.connect(_on_close_requested)
	ui.party_changed.connect(_on_party_changed)
	ui.notice.connect(_toast_text)
	ui.sortie_confirmed.connect(_on_sortie_confirmed)
	ui.retry_load_requested.connect(_load_battle)
	SortieSession.read_args_once()
	_load_class_colors()
	_view.call("configure", layout, _class_colors)
	events.fire(&"tavern_started", [service.members().size()])
	# 重启后位置回默认落点
	if int(service.state["captainSlot"]) >= 0:
		var class_id: String = (service.state["slots"] as Array)[int(service.state["captainSlot"])]
		sim.spawn_captain(class_id, sim.default_pos())
	_refresh_view()
	_show_return_notice()


func _exit_tree() -> void:
	if events != null:
		events.close_log()


## 招募、换队长之后调用（P3b 的面板会用）：零成员无角色；第一人入队在出生点生成队长；
## 换队长只换形象，位置、朝向不变，也不发移动信号。
func refresh_party() -> void:
	var slot := int(service.state["captainSlot"])
	if slot < 0:
		sim.remove_captain()
		return
	var class_id: String = (service.state["slots"] as Array)[slot]
	if not sim.has_captain:
		sim.spawn_captain(class_id, sim.spawn_pos())
	elif sim.captain_class != class_id:
		sim.swap_captain_class(class_id)


func _save_path() -> String:
	return SaveStore.path_from_args()


## 战斗结算写盘成功后回到酒馆：队长在固定返回点（默认落点）重新出现，
## 队长是存档里的队长，不是战斗里最后选中的角色。
func _show_return_notice() -> void:
	var back: Dictionary = SortieSession.returned
	if back.is_empty():
		return
	SortieSession.returned = {}
	SortieSession.bus().fire(&"battle_returned", [String(back["result"])])
	var text := "失败，没有奖励，可以整备后再试"
	if String(back["result"]) == "win":
		text = "胜利！有战利品待领取：点「出征准备」→「领取战利品」" if String(back["outcome"]) == "pending_reward" else "胜利！所有奖励都已收集"
	_toast_text(text, 7000)


## 确认出征成功（已保存最新配置）：锁定名单、记事件，再加载战斗。
func _on_sortie_confirmed(_roster_list: Array) -> void:
	if _loading:
		return
	var slot := int(service.state["captainSlot"])
	var options := service.battle_options()
	SortieSession.locked = {
		"run_id": SortieSession.new_run_id(),
		"slots": service.battle_slots(),
		"captain": String((service.state["slots"] as Array)[slot]),
		"captain_slot": slot,
		"talents": options["talents"],
		"sets": options["sets"],
	}
	SortieSession.bus().fire(&"sortie_locked", [SortieSession.locked.duplicate(true)])
	_load_battle()


## 加载战斗。失败（注入或真读不到）留在酒馆的出征面板，可重试；不结算、不发奖。
func _load_battle() -> void:
	if _loading or SortieSession.locked.is_empty():
		return
	_loading = true
	ui.set_load_state("loading", "")
	await get_tree().process_frame
	var run_id := String(SortieSession.locked["run_id"])
	var reason := _load_problem()
	if reason != "":
		_loading = false
		SortieSession.bus().fire(&"battle_load_failed", [run_id, reason])
		ui.set_load_state("failed", reason)
		return
	var args := SortieSession.user_args()
	BattleLaunch.slots = SortieSession.locked["slots"]
	BattleLaunch.talents = SortieSession.locked["talents"]
	BattleLaunch.sets = SortieSession.locked["sets"]
	BattleLaunch.captain_slot = int(SortieSession.locked["captain_slot"])
	BattleLaunch.run_id = run_id
	BattleLaunch.from_tavern = true
	BattleLaunch.seed = -1
	BattleLaunch.autoplay = args.has("--autoplay")
	BattleLaunch.passive = args.has("--passive")
	BattleLaunch.fast = args.has("--fast")
	for arg in args:
		if arg.begins_with("--seed="):
			BattleLaunch.seed = int(arg.get_slice("=", 1))
	SortieSession.change_scene(get_tree(), BATTLE_SCENE)


## 返回非空字符串表示加载失败的原因。
func _load_problem() -> String:
	if SortieSession.fail_load_left > 0:
		SortieSession.fail_load_left -= 1
		return "注入的加载失败（--fail-load）"
	if not ResourceLoader.exists(BATTLE_SCENE):
		return "战斗场景读不到"
	var config := BattleConfig.load_config({"talents": SortieSession.locked["talents"], "sets": SortieSession.locked["sets"]})
	var problems := BattleConfig.validate(config)
	if not problems.is_empty():
		return "战斗配置不可用：" + "; ".join(problems)
	return ""


func _load_class_colors() -> void:
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/balance/classes.json"))
	if typeof(raw) != TYPE_DICTIONARY:
		return
	for class_id in raw:
		if not String(class_id).begins_with("_"):
			_class_colors[String(class_id)] = String(raw[class_id].get("color", "ffffff"))


## 出生点、默认落点、交互落点必须站得住，否则布局写错了。
func _geometry_problems(layout: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	if not sim.nav.click_ok(sim.spawn_pos()):
		out.append("出生点不可站")
	if not sim.nav.click_ok(sim.default_pos()):
		out.append("默认落点不可站")
	for object_id: String in sim.object_ids():
		var info := sim.object_info(object_id)
		if not sim.nav.click_ok(info["approach"]):
			out.append("交互点 %s 的落点不可站" % object_id)
		elif not bool(sim.nav.find_path(sim.default_pos(), info["approach"])["ok"]):
			out.append("交互点 %s 的落点从默认落点走不到" % object_id)
	return out


func _process(delta: float) -> void:
	if sim == null:
		return
	# 帧时间太长时最多补 5 步，避免卡顿后瞬移
	_accumulator = minf(_accumulator + delta, TICK * 5.0)
	while _accumulator >= TICK:
		_accumulator -= TICK
		sim.step(TICK)
	_refresh_view()


func _notification(what: int) -> void:
	# 失去焦点：停步并取消待交互，回来后等新输入
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and controller != null:
		controller.on_focus_lost()


func _unhandled_input(event: InputEvent) -> void:
	if sim == null:
		return
	if event is InputEventMouseMotion:
		controller.on_hover(_event_pos(event))
		return
	if event is InputEventKey and (event as InputEventKey).echo:
		return
	# 数字键 1～4 和 Q/W/E/R 在酒馆里不做任何事：这里不处理它们。
	if event.is_action_pressed("cancel_layer"):
		if not ui.handle_escape():
			controller.on_escape()
		_refresh_view()
	elif event.is_action_pressed("click_primary"):
		_on_left_click(_event_pos(event))
	elif event.is_action_pressed("click_secondary"):
		# 右键只在场景可操作时生效，面板打开时由逻辑层拒绝，不穿透
		_show_result(controller.on_right_click())


## 鼠标事件自带的位置换成场景坐标（不读全局鼠标位置，注入事件和失焦时也准）。
func _event_pos(event: InputEvent) -> Vector2:
	if event is InputEventMouse:
		return make_input_local(event).position
	return Vector2(-1.0, -1.0)


## 界面控件（常驻栏、面板、面板后的遮罩）在场景之前接住点击，能走到这里的都是场景上的点击。
func _on_left_click(pos: Vector2) -> void:
	_show_result(controller.on_left_click(pos))


func _on_open_requested(kind: String) -> void:
	sim.open_panel(kind)
	_refresh_view()


func _on_close_requested() -> void:
	sim.close_panel()
	_refresh_view()


func _on_party_changed() -> void:
	refresh_party()
	ui.mark_dirty()


func _show_result(result: Dictionary) -> void:
	if not bool(result.get("ok", true)):
		var text := String(_view.call("reason_text", String(result.get("reason", ""))))
		if text != "":
			_toast = text
			_toast_until_ms = Time.get_ticks_msec() + 1600
	_refresh_view()


func _refresh_view() -> void:
	if Time.get_ticks_msec() > _toast_until_ms:
		_toast = ""
	var snapshot := sim.snapshot()
	_view.call("render", snapshot, _toast, service.members().size() if service != null else 0)
	if ui != null:
		ui.sync(String(snapshot.get("panel", "")))


func _toast_text(text: String, duration_ms: int = 2200) -> void:
	_toast = text
	_toast_until_ms = Time.get_ticks_msec() + duration_ms
	_refresh_view()
