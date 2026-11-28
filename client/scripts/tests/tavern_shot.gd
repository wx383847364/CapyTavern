extends SceneTree
## 开窗口跑酒馆场景：注入真实输入事件走一遍交互，并在引擎内截图（不截桌面）。用法：
##   godot --path client --script res://scripts/tests/tavern_shot.gd -- --save=/tmp/x.json --out=/tmp/tavern_shots
## 存档里要有队长（先用 --do=recruit:warrior 建一个）。打印 PASS / FAIL，有失败退出码 1。
## 从当前视口注入配对鼠标事件，截图直接取引擎渲染帧。

var _dir: String = "/tmp/tavern_shots"
var _scene: Node = null
var _failures: int = 0


## 验收只走脚本注入，避免桌面操作或焦点变化打断录制中的路径。
func _initialize() -> void:
	root.mouse_passthrough = true
	root.unfocusable = true
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


## 等渲染完成再截图，返回原帧供遮挡像素比较。
func _shot(name: String) -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	image.save_png("%s/%s.png" % [_dir, name])
	print("shot ", name)
	return image


## 读取指定场景点在当前渲染帧的颜色，换算窗口实际像素尺寸。
func _pixel(image: Image, scene_pos: Vector2) -> Color:
	var viewport_pos: Vector2 = _scene.get_global_transform_with_canvas() * scene_pos
	var pixel := Vector2i(viewport_pos * Vector2(image.get_size()) / root.get_visible_rect().size)
	return image.get_pixelv(pixel)


## 按下并释放动作，走场景原有输入入口。
func _press(action: String) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	root.push_input(event, true)
	event = event.duplicate()
	event.pressed = false
	root.push_input(event, true)
	await process_frame


## 使用视口坐标，不依赖窗口缩放比例。输入仍经过原有的 GUI 和场景优先级。
func _click(button: int, pos: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	motion.global_position = pos
	root.push_input(motion, true)
	for down: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = button
		event.position = pos
		event.global_position = pos
		event.pressed = down
		if down:
			event.button_mask = MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT
		root.push_input(event, true)
	await process_frame


## 等逻辑层走完（按逻辑时间计，最多 30 秒墙钟）。
func _wait_idle() -> void:
	var guard := 0
	while _scene.sim.is_moving() and guard < 150:
		await create_timer(0.2).timeout
		guard += 1


func _wait(seconds: float) -> void:
	await create_timer(seconds).timeout


## 在大厅里实际点击走过两个占地，并用当前帧与开场底图比对前后遮挡。
func _run() -> void:
	var sim = _scene.sim
	var view := _scene.get_node("View")
	await _wait(1.0)
	_check("启动后只有队长一个角色，在默认落点", sim.has_captain and sim.captain_pos == sim.default_pos(), str(sim.captain_pos))
	var baseline := await _shot("00_start")

	var cargo_back := Vector2(300, 650)
	await _click(MOUSE_BUTTON_LEFT, cargo_back)
	await _wait_idle()
	var cargo_hidden := await _shot("01_cargo_behind")
	var cargo_body := cargo_back - Vector2(0, sim.nav.radius())
	_check("走到货台后方：脚点可到，本体被货箱遮挡",
		sim.captain_pos.is_equal_approx(cargo_back) and not view.captain_body_at(cargo_body)
		and _pixel(cargo_hidden, cargo_body).is_equal_approx(_pixel(baseline, cargo_body)))
	var lower_left := Vector2(80, 1010)
	await _click(MOUSE_BUTTON_LEFT, lower_left)
	_check("点左下可走区：队长开始绕货台斜边", sim.is_moving() and sim.path.size() > 2, str(sim.path))
	await _shot("02_cargo_detour")
	await _wait_idle()
	_check("沿货台占地绕行后到达左下完整地板", sim.captain_pos.is_equal_approx(lower_left), str(sim.captain_pos))
	await _click(MOUSE_BUTTON_LEFT, Vector2(350, 730))
	_check("点货台占地：不动、不开面板", not sim.is_moving() and sim.panel == "" and sim.captain_pos == lower_left)
	await _shot("03_blocked_toast")

	var board_left := Vector2(1510, 565)
	var board_right := Vector2(1870, 565)
	await _click(MOUSE_BUTTON_LEFT, board_left)
	await _wait_idle()
	await _click(MOUSE_BUTTON_LEFT, board_right)
	_check("点告示牌另一侧：队长绕过底座", sim.is_moving() and sim.path.size() > 2, str(sim.path))
	await _shot("04_board_detour")
	await _wait_idle()
	_check("绕过告示牌底座后到达另一侧", sim.captain_pos.is_equal_approx(board_right), str(sim.captain_pos))
	await _click(MOUSE_BUTTON_LEFT, Vector2(1722, 570))
	_check("点告示牌底座：不动、不开面板", not sim.is_moving() and sim.panel == "" and sim.captain_pos == board_right)

	await _click(MOUSE_BUTTON_LEFT, Vector2(1870, 493))
	await _wait_idle()
	await _click(MOUSE_BUTTON_LEFT, Vector2(1540, 493))
	var deadline: float = sim.time + 3.0
	while sim.is_moving() and sim.captain_pos.x > 1730 and sim.time < deadline:
		await process_frame
	var board_hidden := await _shot("05_board_behind")
	var behind_probe := Vector2(1722, 471)
	_check("从告示牌后走过：原有牌面像素盖住队长", sim.is_moving()
		and behind_probe.distance_to(view._captain_center()) < sim.nav.radius() - 2.0
		and not view.captain_body_at(behind_probe)
		and _pixel(board_hidden, behind_probe).is_equal_approx(_pixel(baseline, behind_probe)), str(sim.captain_pos))
	await _wait_idle()
	_check("队长可穿过牌面背后的地板", sim.captain_pos.is_equal_approx(Vector2(1540, 493)), str(sim.captain_pos))
	var front_pos := Vector2(1650, 614)
	await _click(MOUSE_BUTTON_LEFT, front_pos)
	await _wait_idle()
	var board_front := await _shot("06_board_front")
	var front_probe := Vector2(1650, 578)
	_check("队长走到告示牌前方：本体盖住支脚像素", sim.captain_pos.is_equal_approx(front_pos)
		and view.captain_body_at(front_probe)
		and not _pixel(board_front, front_probe).is_equal_approx(_pixel(baseline, front_probe)), str(sim.captain_pos))
	# 点牌面沿用走近后开招募，点底座的移动阻挡与交互区域相互独立。
	var recruit: Rect2 = sim.object_info("recruit")["rect"]
	await _click(MOUSE_BUTTON_LEFT, recruit.get_center())
	_check("点招募公告板：走向它，面板未开", sim.is_moving() and sim.pending_object == "recruit" and sim.panel == "")
	await _click(MOUSE_BUTTON_RIGHT, Vector2(0, 0))
	_check("右键：停步并取消待交互", not sim.is_moving() and sim.pending_object == "")
	await _click(MOUSE_BUTTON_LEFT, recruit.get_center())
	await _wait_idle()
	await _wait(0.2)
	_check("走到交互落点后打开招募面板", sim.panel == "recruit", sim.panel)
	await _shot("07_recruit_panel")
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
	var prepare: Rect2 = sim.object_info("prepare")["rect"]
	await _click(MOUSE_BUTTON_LEFT, prepare.get_center())
	await _wait_idle()
	await _wait(0.2)
	_check("点货台：到达后打开整备面板", sim.panel == "prepare", sim.panel)
	await _click(MOUSE_BUTTON_LEFT, (root.find_child("panel_close", true, false) as Control).get_global_rect().get_center())
	await _wait(0.2)
	_check("点面板上的关闭按钮：面板关闭", sim.panel == "", sim.panel)
	await _shot("08_after_close")
	print("RESULT: %s (%d 条失败)" % ["FAIL" if _failures > 0 else "ALL PASS", _failures])
	quit(1 if _failures > 0 else 0)
