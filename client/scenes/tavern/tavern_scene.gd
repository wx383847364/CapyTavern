extends Node2D
## 酒馆场景驱动：建逻辑层、按固定步长推进、把鼠标键盘交给控制器、把快照交给画面。
## 移动、交互、面板规则都在 TavernSim；这里不判断可不可走，也不读任何动画回调。
## 队长来自存档（P2 的单档服务）：存档里有队长才生成角色，位置不进存档，重启回默认落点。

const MotionTrack := preload("res://scenes/ui/motion_track.gd")
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
const BattleSim := preload("res://scripts/battle/battle_sim.gd")
const BattleEvents := preload("res://scripts/battle/battle_events.gd")
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
var _motion: MotionTrack
var _display_pos := Vector2.ZERO
var _stepping := false
var _toast: String = ""
var _toast_until_ms: int = 0
var _class_colors: Dictionary = {}
var _loading: bool = false
# 私有出征快照随确认生成，失败重试复用，公共 sortie_locked 的字段不变。
var _formal_lock: Dictionary = {}
var _formal_prepared: Dictionary = {}

@onready var _view: Node2D = $View


## 酒馆初始化沿用原规则；日志先于布局检查，失败退出有明确原因。
func _ready() -> void:
	TavernEvents.observe_window(get_tree().root)
	TavernEvents.diagnostic("scene_entered", {"scene": scene_file_path})
	var layout := TavernLayout.load_layout()
	var problems := TavernLayout.validate(layout)
	if not problems.is_empty():
		push_error("酒馆布局不可用：" + "; ".join(problems))
		get_tree().root.set_meta("capy_exit_reason", "invalid_tavern_layout")
		get_tree().root.set_meta("capy_exit_initiator", "tavern_scene")
		TavernEvents.diagnostic("exit_requested", {"initiator": "tavern_scene", "reason": "invalid_tavern_layout", "intended_code": 2})
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
		get_tree().root.set_meta("capy_exit_reason", "invalid_tavern_geometry")
		get_tree().root.set_meta("capy_exit_initiator", "tavern_scene")
		TavernEvents.diagnostic("exit_requested", {"initiator": "tavern_scene", "reason": "invalid_tavern_geometry", "intended_code": 2})
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


## 场景退出先flush原因再关闭业务日志；树退出不等同OS终止或崩溃。
func _exit_tree() -> void:
	TavernEvents.diagnostic("scene_exiting", {"scene": scene_file_path, "reason": get_tree().root.get_meta("capy_exit_reason", "scene_transition_or_unknown")})
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


## 确认出征成功后锁定名单和法师专精，再加载战斗。
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
		"mage_spec": options["mage_spec"],
	}
	_formal_lock = {}
	var specs := BattleConfig.formal_specs(SortieSession.locked["slots"], options["mage_spec"])
	if not specs.is_empty():
		_formal_lock = SortieSession.locked.duplicate(true)
		_formal_lock["specs"] = specs
		_formal_lock["equips"] = (service.state["equips"] as Dictionary).duplicate(true)
	SortieSession.bus().fire(&"sortie_locked", [SortieSession.locked.duplicate(true)])
	_load_battle()


## 加载战斗。失败（注入或真读不到）留在酒馆的出征面板，可重试；不结算、不发奖。
func _load_battle() -> void:
	if _loading or SortieSession.locked.is_empty():
		return
	_loading = true
	ui.set_load_state("loading", "")
	await get_tree().process_frame
	var run_id := str(SortieSession.locked.get("run_id", ""))
	var reason := _load_problem()
	if reason != "":
		_loading = false
		SortieSession.bus().fire(&"battle_load_failed", [run_id, reason])
		ui.set_load_state("failed", reason)
		return
	var args := SortieSession.user_args()
	BattleLaunch.formal_sortie = _formal_prepared
	_formal_prepared = {}
	BattleLaunch.slots = SortieSession.locked["slots"]
	BattleLaunch.talents = SortieSession.locked["talents"]
	BattleLaunch.sets = SortieSession.locked["sets"]
	BattleLaunch.mage_spec = SortieSession.locked["mage_spec"]
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


## 按锁定的阵容与专精预检。失败时留在原面板，用同一场次重试。
func _load_problem() -> String:
	_formal_prepared = {}
	if SortieSession.fail_load_left > 0:
		SortieSession.fail_load_left -= 1
		return "注入的加载失败（--fail-load）"
	if not ResourceLoader.exists(BATTLE_SCENE):
		return "战斗场景读不到"
	var locked := SortieSession.locked
	var slots: Variant = locked.get("slots")
	if not slots is Array or not locked.get("talents") is Dictionary or not locked.get("sets") is Array:
		return "出征阵容、天赋或套装快照无效"
	var mage_spec: String = locked.get("mage_spec", "mage.fire")
	var specs := BattleConfig.formal_specs(slots, mage_spec)
	var formal := not specs.is_empty() or not _formal_lock.is_empty()
	var options := {"modifiers": false} if formal else {"talents": locked["talents"], "sets": locked["sets"]}
	options["mage_spec"] = mage_spec
	var config := BattleConfig.load_config(options)
	if not formal:
		var legacy_problems := BattleConfig.validate(config)
		return "" if legacy_problems.is_empty() else "战斗配置不可用：" + "; ".join(legacy_problems)
	var scene: Variant = load(BATTLE_SCENE)
	if not scene is PackedScene or not scene.can_instantiate():
		return "战斗场景读不到"
	var lock_problem := _formal_lock_problem(specs)
	if not lock_problem.is_empty():
		return lock_problem
	var problems := BattleConfig.formal_config_problems(config, slots)
	problems.append_array(BattleConfig.frost_config_problems(config))
	if not problems.is_empty():
		return "正式战斗配置不可用：" + "; ".join(problems)
	var catalog := BattleConfig.load_skill_catalog()
	if not catalog["problems"].is_empty():
		return "正式战斗技能源不可用：" + "; ".join(catalog["problems"])
	var seed := -1
	for arg in SortieSession.user_args():
		if arg.begins_with("--seed="):
			seed = int(arg.get_slice("=", 1))
	# 候选战斗预建在树外；通过前没有出生、加载或奖励事件，交接时使用同一份 Sim。
	var candidate := BattleSim.new()
	problems = candidate.prepare_formal_sortie(config, _formal_lock, seed, BattleEvents.new(), catalog)
	if not problems.is_empty() or not candidate.formal_skill_sortie:
		return "正式战斗初始化失败：" + "; ".join(problems)
	_formal_prepared = {"run_id": locked["run_id"], "slots": slots.duplicate(), "sim": candidate}
	return ""


## 用冻结装备及实际物品表复核套装快照，重试不读取当前穿戴或重做专精选择。
func _formal_lock_problem(specs: Array) -> String:
	var locked := SortieSession.locked
	if specs.is_empty() or _formal_lock.get("specs") != specs:
		return "正式出征的专精快照无效"
	if not _formal_lock.get("run_id") is String or _formal_lock["run_id"].is_empty() or table.slots.is_empty():
		return "正式出征的场次或物品表无效"
	for key: String in ["run_id", "slots", "captain", "captain_slot", "talents", "sets", "mage_spec"]:
		if _formal_lock.get(key) != locked.get(key):
			return "正式出征快照不一致：" + key
	var slot: Variant = _formal_lock.get("captain_slot")
	var slots: Array = _formal_lock["slots"]
	if not slot is int or slot < 0 or slot >= slots.size() or slots[slot] == "" or slots[slot] != _formal_lock.get("captain"):
		return "正式出征的队长快照无效"
	var equips: Variant = _formal_lock.get("equips")
	if not equips is Dictionary or equips.size() != slots.size() - slots.count(""):
		return "正式出征的装备快照无效"
	var sets: Array = []
	for class_id: String in slots:
		if class_id.is_empty():
			continue
		if _formal_lock["talents"].get(class_id) not in ["t1", "t2"]:
			return "正式出征的天赋快照无效：" + class_id
		var worn: Variant = equips.get(class_id)
		if not worn is Dictionary or worn.size() != table.slots.size():
			return "正式出征的装备槽缺失：" + class_id
		var pieces := {}
		for slot_id: String in table.slots:
			if not worn.get(slot_id) is String:
				return "正式出征的装备标识无效：" + class_id
			var item := table.item(worn[slot_id])
			if item.get("class_id") != class_id or item.get("slot") != slot_id:
				return "正式出征的装备不匹配：" + class_id
			var set_id: Variant = item.get("set_id")
			if set_id is String and not set_id.is_empty():
				pieces[set_id] = int(pieces.get(set_id, 0)) + 1
		for count: int in pieces.values():
			if count >= 2:
				sets.append(class_id)
				break
	var frozen_sets: Array = _formal_lock["sets"].duplicate()
	frozen_sets.sort()
	sets.sort()
	return "" if frozen_sets == sets else "正式出征的套装快照不一致"


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


## 每步只发布完成后的移动轨迹，每帧计算一次队长的显示位置。
func _process(delta: float) -> void:
	if sim == null:
		return
	# 帧时间太长时最多补 5 步，避免卡顿后瞬移
	_accumulator = minf(_accumulator + delta, TICK * 5.0)
	while _accumulator >= TICK:
		_accumulator -= TICK
		var corners := PackedVector2Array()
		_stepping = true
		sim.step(TICK, corners)
		_stepping = false
		if sim.has_captain and _motion != null and _motion.generation == sim.captain_generation:
			_motion.record(sim.time, sim.captain_pos, 0, corners)
	if _motion != null:
		_display_pos = _motion.local_position(_accumulator)
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


## 界面先消费点击；控制器使用这一帧队长的本体和脚下命中。
func _on_left_click(pos: Vector2) -> void:
	_show_result(controller.on_left_click(pos, bool(_view.call("captain_at", pos))))


## 记录面板请求和实际响应，正式阵容提示使用当前专精。
func _on_open_requested(kind: String) -> void:
	TavernEvents.diagnostic("ui_open_requested", {"kind": kind})
	sim.open_panel(kind)
	var specs := BattleConfig.formal_specs(service.battle_slots(), service.mage_spec()) if kind in ["prepare", "sortie"] else []
	if specs.is_empty():
		_refresh_view()
	else:
		var party_name := "法师与牧师" if specs.has("priest.holy") else "法师"
		_toast_text(party_name + "已启用正式专精，技能与套装规则见面板", 7000)
	TavernEvents.diagnostic("ui_panel_response", {"kind": sim.panel})


## 原关闭面板逻辑保持，额外记录请求及实际结果。
func _on_close_requested() -> void:
	TavernEvents.diagnostic("ui_close_requested", {"kind": sim.panel})
	sim.close_panel()
	_refresh_view()
	TavernEvents.diagnostic("ui_panel_response", {"kind": sim.panel})


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


## 输入和面板刷新复用这一帧的位置；新队长在自己的出生点建立基线。
func _refresh_view() -> void:
	if _stepping:
		return
	if Time.get_ticks_msec() > _toast_until_ms:
		_toast = ""
	var snapshot := sim.snapshot()
	if sim.has_captain:
		if _motion == null or _motion.generation != sim.captain_generation:
			_motion = MotionTrack.new(sim.get_instance_id(), sim.captain_generation, 0)
			_motion.record(sim.time, sim.captain_pos, 0)
			_display_pos = sim.captain_pos
		snapshot["pos"] = _display_pos
	else:
		_motion = null
	_view.call("render", snapshot, _toast, service.members().size() if service != null else 0)
	if ui != null:
		ui.sync(String(snapshot.get("panel", "")))


func _toast_text(text: String, duration_ms: int = 2200) -> void:
	_toast = text
	_toast_until_ms = Time.get_ticks_msec() + duration_ms
	_refresh_view()
