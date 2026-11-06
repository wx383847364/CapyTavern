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


func open_log(path: String) -> void:
	_file = FileAccess.open(path, FileAccess.WRITE)


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
