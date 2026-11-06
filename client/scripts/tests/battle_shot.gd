extends SceneTree
## 开窗口跑一场并在引擎内截图（不截桌面）。用法：
##   godot --path client --script res://scripts/tests/battle_shot.gd -- --out=/tmp/shots 4
##   godot --path client --script res://scripts/tests/battle_shot.gd -- /tmp/shots 4
## 截图目录支持 --out=PATH 或第一个位置参数；其后可给出战人数，默认 4 人。

const BattleLaunch := preload("res://scripts/battle/battle_launch.gd")

var _dir: String = "/tmp/battle_shots"
var _scene: Node = null


## 解析截图目录和人数；参数无效或建目录失败时退出，避免把选项字面量写进工程。
func _initialize() -> void:
	var positional: Array[String] = []
	var named_output := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_dir = arg.trim_prefix("--out=")
			named_output = true
		elif arg.begins_with("--"):
			printerr("不支持的截图参数：", arg)
			quit(2)
			return
		else:
			positional.append(arg)
	# 保留旧的位置参数调用；具名目录不占用人数的位置，也不截断路径中的等号。
	if not named_output and not positional.is_empty():
		_dir = positional.pop_front()
	if _dir.is_empty() or positional.size() > 1 or (not positional.is_empty() and not positional[0].is_valid_int()):
		printerr("截图参数无效：请给出非空目录及可选的 1～4 人数量")
		quit(2)
		return
	var count := int(positional[0]) if not positional.is_empty() else 4
	if count < 1 or count > 4:
		printerr("出战人数必须为 1～4")
		quit(2)
		return
	var error := DirAccess.make_dir_recursive_absolute(_dir)
	if error != OK:
		printerr("创建截图目录失败：", _dir, "，错误码：", error)
		quit(1)
		return
	BattleLaunch.slots = BattleLaunch.default_slots(count)
	BattleLaunch.seed = 5
	BattleLaunch.autoplay = false
	_scene = load("res://scenes/battle/battle.tscn").instantiate()
	root.add_child(_scene)
	_run.call_deferred()


## 等待画面刷新后保存截图；写入失败必须返回非零退出码，不能把缺失证据报成成功。
func _shot(name: String) -> void:
	await process_frame
	await process_frame
	var error := root.get_texture().get_image().save_png("%s/%s.png" % [_dir, name])
	if error != OK:
		printerr("保存截图失败：", name, "，错误码：", error)
		quit(1)
		return
	print("shot ", name)


func _press(action: String) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	Input.parse_input_event(event)
	await process_frame


## pos 是战场坐标（1920×1080）；窗口是 1280×720，注入事件要给窗口坐标。
func _click(button: int, canvas_pos: Vector2) -> void:
	var pos := canvas_pos / 1.5
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	motion.global_position = pos
	Input.parse_input_event(motion)
	await process_frame
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.position = pos
	event.global_position = pos
	event.pressed = true
	Input.parse_input_event(event)
	await process_frame
	event.pressed = false
	Input.parse_input_event(event)
	await process_frame


func _wait(seconds: float) -> void:
	# 窗口没有焦点时引擎会按规则暂停战斗；截图脚本每 0.2 秒手动放行，只为让画面往前走
	var left := seconds
	while left > 0.0:
		_scene.sim.set_paused(false)
		await create_timer(0.2).timeout
		left -= 0.2


func _run() -> void:
	_scene.sim.set_paused(false)
	await _shot("00_start")
	await _press("slot_1")
	await _click(MOUSE_BUTTON_LEFT, Vector2(900, 540))
	await _wait(1.5)
	await _shot("01_move")
	await _click(MOUSE_BUTTON_RIGHT, Vector2(1500, 360))
	await _wait(4.0)
	await _press("skill_q")
	await _wait(0.3)
	await _shot("02_attack_skill")
	await _wait(3.0)
	await _shot("03_midfight")
	quit(0)
