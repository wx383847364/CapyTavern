extends RefCounted
## 酒馆 → 战斗 → 酒馆 之间传递的运行时数据（不是存档，不新增存档字段）。
## 场次沿用 P2b 的 run_id：确认出征锁名单时生成，加载失败重试沿用同一个，战斗结算时才写进存档。

const SortieEvents := preload("res://scripts/tavern/sortie_events.gd")
const TAVERN_SCENE := "res://scenes/tavern/tavern.tscn"

static var _bus: SortieEvents = null
## 当前这次出征锁定的名单；空表示没有。
static var locked: Dictionary = {}
## 战斗回酒馆时留的话：{result, run_id, outcome}；酒馆读一次就清掉。
static var returned: Dictionary = {}
## 验收注入：接下来 N 次加载战斗失败（--fail-load=N）。只在第一次读命令行时设一次。
static var fail_load_left: int = 0
## 验收注入：战斗结算接下来 N 次写盘失败（--fail-settle=N）。
static var fail_settle_left: int = 0
static var _args_read: bool = false
## 测试替换场景切换（返回 true 表示已处理）；默认走 change_scene_to_file。
static var goto_scene: Callable = Callable()


static func bus() -> SortieEvents:
	if _bus == null:
		_bus = SortieEvents.new()
		_bus.echo_stdout = OS.get_cmdline_user_args().has("--echo")
		_bus.open_log()
	return _bus


static func read_args_once() -> void:
	if _args_read:
		return
	_args_read = true
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--fail-load="):
			fail_load_left = int(arg.get_slice("=", 1))
		elif arg.begins_with("--fail-settle="):
			fail_settle_left = int(arg.get_slice("=", 1))


## 测试可以把它设成非空来替换命令行里的战斗参数（--autoplay --fast --seed=N 等）。
static var args_override: PackedStringArray = PackedStringArray()


static func user_args() -> PackedStringArray:
	return args_override if not args_override.is_empty() else OS.get_cmdline_user_args()


static func new_run_id() -> String:
	return "run_%d" % Time.get_unix_time_from_system()


static func change_scene(tree: SceneTree, path: String) -> void:
	if goto_scene.is_valid():
		goto_scene.call(path)
	else:
		tree.change_scene_to_file(path)
