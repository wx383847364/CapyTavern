extends SceneTree
## 开窗口跑酒馆场景：注入真实输入事件走一遍交互，并在引擎内截图（不截桌面）。用法：
##   godot --path client --script res://scripts/tests/tavern_shot.gd -- --save=/tmp/x.json --out=/tmp/tavern_shots
## 存档里要有队长（先用 --do=recruit:warrior 建一个）。打印 PASS / FAIL，有失败退出码 1。
## 注入事件要给窗口坐标：场景坐标（1920×1080）除以 1.5。

var _dir: String = "/tmp/tavern_shots"
var _scene: Node = null
var _failures: int = 0


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_dir = arg.get_slice("=", 1)
	DirAccess.make_dir_recursive_absolute(_dir)
	_scene = load("res://scenes/tavern/tavern.tscn").instantiate()
	root.add_child(_scene)
	_run.call_deferred()


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		print("PASS  ", name)
	else:
		_failures += 1
		print("FAIL  ", name, "  ", detail)


func _shot(name: String) -> void:
	await process_frame
	await process_frame
	root.get_texture().get_image().save_png("%s/%s.png" % [_dir, name])
	print("shot ", name)


func _press(action: String) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	Input.parse_input_event(event)
	await process_frame


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


## 等逻辑层走完（按逻辑时间计，最多 30 秒墙钟）。
func _wait_idle() -> void:
	var guard := 0
	while _scene.sim.is_moving() and guard < 150:
		await create_timer(0.2).timeout
		guard += 1


func _wait(seconds: float) -> void:
	await create_timer(seconds).timeout


func _run() -> void:
	var sim = _scene.sim
	await _wait(0.3)
	_check("启动后只有队长一个角色，在默认落点", sim.has_captain and sim.captain_pos == sim.default_pos(), str(sim.captain_pos))
	await _shot("00_start")
	await _click(MOUSE_BUTTON_LEFT, Vector2(700, 700))
	await _wait(0.4)
	_check("真实左键点地面：开始移动", sim.is_moving(), str(sim.snapshot()))
	await _shot("01_walking_around_partition")
	await _wait_idle()
	_check("绕过隔断走到点击位置", sim.captain_pos.distance_to(Vector2(700, 700)) < 0.01, str(sim.captain_pos))
	await _click(MOUSE_BUTTON_LEFT, Vector2(520, 585))
	_check("真实点击桌子：不动、不开面板", not sim.is_moving() and sim.panel == "")
	await _shot("02_blocked_toast")
	# 点招募公告板：先走近，到达才开
	await _click(MOUSE_BUTTON_LEFT, Vector2(280, 180))
	await _wait(0.3)
	_check("点招募公告板：走向它，面板未开", sim.is_moving() and sim.pending_object == "recruit" and sim.panel == "")
	await _click(MOUSE_BUTTON_RIGHT, Vector2(0, 0))
	_check("真实右键：停步并取消待交互", not sim.is_moving() and sim.pending_object == "")
	await _click(MOUSE_BUTTON_LEFT, Vector2(280, 180))
	await _wait_idle()
	await _wait(0.2)
	_check("走到交互落点后打开招募面板", sim.panel == "recruit", sim.panel)
	await _shot("03_recruit_panel")
	var held: Vector2 = sim.captain_pos
	await _click(MOUSE_BUTTON_LEFT, Vector2(300, 900))
	await _click(MOUSE_BUTTON_RIGHT, Vector2(300, 900))
	await _wait(0.3)
	_check("面板打开时点面板外、右键：队长不动，面板仍在", sim.captain_pos == held and sim.panel == "recruit" and not sim.is_moving())
	await _click(MOUSE_BUTTON_LEFT, Vector2(900, 500))
	_check("点面板里面：不移动", sim.captain_pos == held and sim.panel == "recruit")
	await _press("slot_1")
	await _press("skill_q")
	_check("面板和场景里按数字键、Q 无反应", sim.panel == "recruit" and sim.captain_pos == held)
	await _press("cancel_layer")
	_check("Esc 关闭面板（一次一层）", sim.panel == "")
	await _wait(0.5)
	_check("关闭后不续走", sim.captain_pos == held)
	await _click(MOUSE_BUTTON_LEFT, Vector2(1400, 330))
	await _wait_idle()
	await _wait(0.2)
	_check("点整备桌：到达后打开整备面板", sim.panel == "prepare", sim.panel)
	await _click(MOUSE_BUTTON_LEFT, (root.find_child("panel_close", true, false) as Control).get_global_rect().get_center())
	await _wait(0.2)
	_check("点面板上的关闭按钮：面板关闭", sim.panel == "", sim.panel)
	await _shot("04_after_close")
	print("RESULT: %s (%d 条失败)" % ["FAIL" if _failures > 0 else "ALL PASS", _failures])
	quit(1 if _failures > 0 else 0)
