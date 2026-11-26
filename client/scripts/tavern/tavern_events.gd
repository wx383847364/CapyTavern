extends RefCounted
## 酒馆事件总线。三个对外信号是契约（doc/方案与数据/Godot程序开发计划 v0.1.md P3a 任务单），
## 改名或改参数先报制作人；日志专用事件不是信号，只写日志，不进契约。
## 坐标是 1920×1080 场景坐标；日志里 Vector2 写成 [x, y]。

## 队长位置变化：移动中每个固定步长（0.05 秒）最多一次，到达时的那一次就是精确终点。换队长不发。
signal tavern_captain_moved(pos)
## 面板显示。kind 取 recruit / prepare / sortie。同一面板已开着时不重发。
signal panel_opened(kind)
## 面板关闭（Esc、被别的面板替换、程序关闭）。切面板时先 closed 再 opened。
signal panel_closed(kind)

## 对外信号。
const SIGNALS: Array[String] = ["tavern_captain_moved", "panel_opened", "panel_closed"]

## 日志里每个事件的参数名；前三个是信号，其余只写日志。
const SCHEMA := {
	"tavern_captain_moved": ["pos"],
	"panel_opened": ["kind"],
	"panel_closed": ["kind"],
	"tavern_started": ["members"],
	"captain_spawned": ["class_id", "pos"],
	"captain_removed": [],
	"move_ordered": ["pos", "waypoints"],
	"interact_requested": ["object_id", "kind"],
	"interact_replaced": ["old_object_id", "new_object_id"],
	"interact_cancelled": ["object_id", "why"],
	"movement_stopped": ["why", "pos"],
	"command_rejected": ["kind", "reason"],
}

var now: float = 0.0
var lines: PackedStringArray = PackedStringArray()
var echo_stdout: bool = false
var _file: FileAccess = null
static var _diagnostic_file: FileAccess = null
static var _session: String = ""


## 沿用本事件模块落盘诊断；逐条flush，失败同时报标准错误，不改变业务信号契约。
static func diagnostic(kind: String, fields: Dictionary = {}) -> void:
	if _session == "":
		_session = "%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	if _diagnostic_file == null:
		_diagnostic_file = FileAccess.open("user://app_log.jsonl", FileAccess.READ_WRITE if FileAccess.file_exists("user://app_log.jsonl") else FileAccess.WRITE_READ)
		if _diagnostic_file == null:
			push_error("DIAGNOSTIC_OPEN_FAILED error=%d event=%s pid=%d" % [FileAccess.get_open_error(), kind, OS.get_process_id()])
			return
		_diagnostic_file.seek_end()
	var row: Dictionary = fields.duplicate(true)
	row.merge({"e": kind, "session": _session, "pid": OS.get_process_id(), "epoch": Time.get_unix_time_from_system(), "ticks_ms": Time.get_ticks_msec()}, true)
	_diagnostic_file.store_line(JSON.stringify(row, "", false))
	_diagnostic_file.flush()
	if _diagnostic_file.get_error() != OK:
		push_error("DIAGNOSTIC_WRITE_FAILED error=%d event=%s" % [_diagnostic_file.get_error(), kind])
		_diagnostic_file.close()
		_diagnostic_file = null


## 根窗口信号只旁听，不接管系统关闭、抢焦点或移动窗口。
static func observe_window(window: Window) -> void:
	if window.has_meta("capy_diagnostics_connected"):
		return
	window.set_meta("capy_diagnostics_connected", true)
	window.close_requested.connect(_window_close.bind(window))
	window.size_changed.connect(_window_changed.bind(window))
	window.focus_entered.connect(_window_focus.bind(true, window))
	window.focus_exited.connect(_window_focus.bind(false, window))
	window.tree_exiting.connect(_root_exiting.bind(window))
	_window_changed(window)


## 系统关闭请求仅记录；默认SceneTree关闭语义保持，由宿主核实际OS终码。
static func _window_close(window: Window) -> void:
	window.set_meta("capy_exit_initiator", "window_manager")
	window.set_meta("capy_exit_reason", "close_requested")
	diagnostic("window_close_requested", {"initiator": "window_manager", "reason": "close_requested", "window_id": window.get_window_id()})


## 尺寸信号才落盘，避免每帧刷屏；记录实际窗口与视口供变换核查。
static func _window_changed(window: Window) -> void:
	diagnostic("window_changed", {"window_id": window.get_window_id(), "position": str(window.position), "size": str(window.size), "mode": window.mode, "focus": window.has_focus(), "viewport": str(window.get_visible_rect())})


## 焦点边沿只记日志，不请求激活窗口，也不改变原失焦停步规则。
static func _window_focus(focused: bool, window: Window) -> void:
	diagnostic("window_focus", {"window_id": window.get_window_id(), "focused": focused})


## 树退出表示正常收尾路径到达，不冒充原生崩溃捕获或真实OS退出码。
static func _root_exiting(window: Window) -> void:
	diagnostic("root_tree_exiting", {"initiator": window.get_meta("capy_exit_initiator", "unknown"), "reason": window.get_meta("capy_exit_reason", "unknown"), "os_returncode": null})


## 打开现有酒馆业务日志；失败可见，但不伪造日志或改变游戏规则。
func open_log(path: String) -> void:
	_file = FileAccess.open(path, FileAccess.WRITE)
	if _file == null:
		push_error("TAVERN_LOG_OPEN_FAILED path=%s error=%d" % [path, FileAccess.get_open_error()])


## 场景退出关闭本场景日志；应用诊断流继续供下一场景及根退出使用。
func close_log() -> void:
	if _file != null:
		_file.close()
		_file = null


## 写日志；是信号的同时发信号。
func fire(event_name: StringName, args: Array) -> void:
	var names: Array = SCHEMA[event_name]
	var record: Dictionary = {"t": snappedf(now, 0.001), "e": String(event_name)}
	for i in names.size():
		record[names[i]] = _plain(args[i])
	var line := JSON.stringify(record, "", false)
	lines.append(line)
	if _file != null:
		_file.store_line(line)
		_file.flush()  # 每行落盘：程序被直接关掉时日志也不丢
		if _file.get_error() != OK:
			push_error("TAVERN_LOG_WRITE_FAILED event=%s error=%d" % [event_name, _file.get_error()])
	if echo_stdout:
		print(line)
	if SIGNALS.has(String(event_name)):
		callv("emit_signal", [event_name] + args)


func _plain(value: Variant) -> Variant:
	if value is Vector2:
		return [snappedf(value.x, 0.1), snappedf(value.y, 0.1)]
	if value is float:
		return snappedf(value, 0.001)
	return value
