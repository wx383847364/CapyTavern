extends RefCounted
## 出征衔接的事件：酒馆和战斗是两个场景，这条总线由 SortieSession 持有，跨场景活着。
## 日志追加写到 user://sortie_log.jsonl（每行一个 JSON，逐行落盘），--echo 时同步打印。
## 契约（P4，名字和参数已报制作人）：
##   sortie_locked(party)   party = {run_id, slots[4], captain, captain_slot, talents, sets}
##   battle_loaded(run_id)  战斗场景建好、名单已生成
##   battle_returned(result) 战斗结算写盘成功、回到酒馆；result = "win" | "lose"
## 只进日志的：battle_load_failed(run_id, reason)、battle_settled(run_id, result, outcome)、settle_failed(run_id, reason)

signal sortie_locked(party)
signal battle_loaded(run_id)
signal battle_returned(result)

const LOG_PATH := "user://sortie_log.jsonl"
const SCHEMA := {
	"sortie_locked": ["party"],
	"battle_loaded": ["run_id"],
	"battle_returned": ["result"],
	"battle_load_failed": ["run_id", "reason"],
	"battle_settled": ["run_id", "result", "outcome"],
	"settle_failed": ["run_id", "reason"],
}

var lines: PackedStringArray = PackedStringArray()
var echo_stdout: bool = false
var _file: FileAccess = null


func open_log(path: String = LOG_PATH) -> void:
	if _file != null:
		return
	_file = FileAccess.open(path, FileAccess.READ_WRITE) if FileAccess.file_exists(path) else FileAccess.open(path, FileAccess.WRITE)
	if _file != null:
		_file.seek_end()


func fire(event_name: StringName, args: Array) -> void:
	var names: Array = SCHEMA[event_name]
	var record: Dictionary = {"t": snappedf(Time.get_ticks_msec() / 1000.0, 0.001), "e": String(event_name)}
	for i in names.size():
		record[names[i]] = args[i]
	var line := JSON.stringify(record, "", false)
	lines.append(line)
	if _file != null:
		_file.store_line(line)
		_file.flush()
	if echo_stdout:
		print(line)
	match event_name:
		&"sortie_locked":
			sortie_locked.emit(args[0])
		&"battle_loaded":
			battle_loaded.emit(args[0])
		&"battle_returned":
			battle_returned.emit(args[0])
