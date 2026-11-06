extends RefCounted
## 战斗事件总线。信号参数全是纯数据（整数、字符串、Vector2），不带节点引用。
## 契约见 doc/方案与数据/Godot程序开发计划 v0.1.md 的 P1 任务单；改名或改参数先报制作人。
## 结算只在逻辑层按固定步长推进，表现只订阅这里的信号，不反向影响结算。

signal battle_started(seed, allies, enemies)
signal unit_spawned(unit_id, side, slot, class_id, max_hp, pos)
signal command_issued(unit_id, kind, target_id, pos)
signal command_rejected(unit_id, kind, reason)
signal skill_cast(unit_id, skill_id, target_id, cost, cd_until)
signal damage_dealt(source_id, target_id, amount, skill_id, is_crit, hp_after)
signal heal_done(source_id, target_id, amount, effective, skill_id, hp_after)
signal resource_changed(unit_id, kind, value, max)
signal status_applied(unit_id, status_id, source_id, until)
signal status_expired(unit_id, status_id, source_id, until)
signal enemy_cast_started(unit_id, skill_id, ends_at)
signal enemy_cast_interrupted(unit_id, by_id)
signal unit_downed(unit_id, by_id)
signal battle_ended(result, reason, elapsed)
## 只给界面用，不进结算日志。
signal selection_changed(slot)

## 日志里每个事件的参数名，顺序与信号一致。
const SCHEMA := {
	"battle_started": ["seed", "allies", "enemies"],
	"unit_spawned": ["unit_id", "side", "slot", "class_id", "max_hp", "pos"],
	"command_issued": ["unit_id", "kind", "target_id", "pos"],
	"command_rejected": ["unit_id", "kind", "reason"],
	"skill_cast": ["unit_id", "skill_id", "target_id", "cost", "cd_until"],
	"damage_dealt": ["source_id", "target_id", "amount", "skill_id", "is_crit", "hp_after"],
	"heal_done": ["source_id", "target_id", "amount", "effective", "skill_id", "hp_after"],
	"resource_changed": ["unit_id", "kind", "value", "max"],
	"status_applied": ["unit_id", "status_id", "source_id", "until"],
	"status_expired": ["unit_id", "status_id", "source_id", "until"],
	"enemy_cast_started": ["unit_id", "skill_id", "ends_at"],
	"enemy_cast_interrupted": ["unit_id", "by_id"],
	"unit_downed": ["unit_id", "by_id"],
	"battle_ended": ["result", "reason", "elapsed"],
}

## 战斗时间（秒），由模拟器每步写入，日志用它打时间戳。
var now: float = 0.0
## 全部已发事件的 JSON 行，测试和导出包日志都读它。
var lines: PackedStringArray = PackedStringArray()
var echo_stdout: bool = false
var _file: FileAccess = null


func open_log(path: String) -> void:
	_file = FileAccess.open(path, FileAccess.WRITE)


func close_log() -> void:
	if _file != null:
		_file.close()
		_file = null


## 发信号并写日志。selection_changed 不走这里。
func fire(event_name: StringName, args: Array) -> void:
	var names: Array = SCHEMA[event_name]
	var record: Dictionary = {"t": snappedf(now, 0.001), "e": String(event_name)}
	for i in names.size():
		record[names[i]] = _plain(args[i])
	var line := JSON.stringify(record, "", false)
	lines.append(line)
	if _file != null:
		_file.store_line(line)
	if echo_stdout:
		print(line)
	callv("emit_signal", [event_name] + args)


func select(slot: int) -> void:
	selection_changed.emit(slot)


func _plain(value: Variant) -> Variant:
	if value is Vector2:
		return [snappedf(value.x, 0.1), snappedf(value.y, 0.1)]
	if value is float:
		return snappedf(value, 0.001)
	return value
