extends SceneTree
## P3a 酒馆自检（无窗口，直接驱动逻辑层和控制器）。运行：
##   godot --headless --path client --script res://scripts/tests/tavern_check.gd
## 对应操作稿 §1.2～§1.4 和 §1.12 里 P3a 范围的条目。有失败时退出码 1。不改任何文件。

const TavernSim := preload("res://scripts/tavern/tavern_sim.gd")
const TavernEvents := preload("res://scripts/tavern/tavern_events.gd")
const TavernLayout := preload("res://scripts/data/tavern_layout.gd")
const TavernController := preload("res://scripts/input/tavern_controller.gd")

const MotionTrack := preload("res://scenes/ui/motion_track.gd")
const TICK := 0.05

var _failures: int = 0
var _layout: Dictionary = {}


## 在同一入口检查酒馆规则与显示路径。
func _initialize() -> void:
	_layout = TavernLayout.load_layout()
	var problems := TavernLayout.validate(_layout)
	_check("布局可用", problems.is_empty(), ", ".join(problems))
	if problems.is_empty():
		_geometry()
		_movement()
		_display_corners()
		_invalid_clicks()
		_right_click_and_focus()
		_direction_input()
		_interaction()
		_replace_and_dedupe()
		_panels()
		_zero_members()
		_captain_swap()
		_signals_and_log()
		_random_paths()
		_determinism()
	print("RESULT: %s (%d 条失败)" % ["FAIL" if _failures > 0 else "ALL PASS", _failures])
	quit(1 if _failures > 0 else 0)


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		print("PASS  ", name)
	else:
		_failures += 1
		print("FAIL  ", name, "  ", detail)


func _make(layout: Dictionary = {}, with_captain: bool = true) -> Dictionary:
	var events := TavernEvents.new()
	var sim := TavernSim.new()
	sim.setup(layout if not layout.is_empty() else _layout, events)
	var controller := TavernController.new()
	controller.setup(sim)
	if with_captain:
		sim.spawn_captain("warrior", sim.default_pos())
	return {"sim": sim, "events": events, "controller": controller}


func _steps(sim: TavernSim, count: int) -> void:
	for _i in count:
		sim.step(TICK)


## 一直走到站住（最多 40 秒）。
func _settle(sim: TavernSim) -> void:
	var guard := 0
	while sim.is_moving() and guard < 800:
		sim.step(TICK)
		guard += 1


func _count(events: TavernEvents, name: String, filter: Dictionary = {}) -> int:
	var total := 0
	for line in events.lines:
		var record: Dictionary = JSON.parse_string(line)
		if record["e"] != name:
			continue
		var ok := true
		for key in filter:
			if record.get(key) != filter[key]:
				ok = false
		if ok:
			total += 1
	return total


func _object_center(sim: TavernSim, object_id: String) -> Vector2:
	var rect: Rect2 = sim.object_info(object_id)["rect"]
	return rect.get_center()


# ── 布局几何 ──

## 验证正式大厅的矩形边界、摆件独立占地和三个交互落点。
func _geometry() -> void:
	var battle := _make()
	var sim: TavernSim = battle["sim"]
	_check("出生点可站", sim.nav.click_ok(sim.spawn_pos()))
	_check("默认落点可站", sim.nav.click_ok(sim.default_pos()))
	var ok := true
	for object_id: String in sim.object_ids():
		var info := sim.object_info(object_id)
		var route := sim.nav.find_path(sim.default_pos(), info["approach"])
		ok = ok and sim.nav.click_ok(info["approach"]) and bool(route["ok"])
	_check("三个交互点的落点都可站，且从默认落点走得到", ok and sim.object_ids().size() == 3)
	_check("出生点和默认落点不是同一个点", sim.spawn_pos() != sim.default_pos())
	var kinds := {}
	for object_id: String in sim.object_ids():
		kinds[sim.object_info(object_id)["kind"]] = true
	_check("交互点正好是招募、整备、出征", kinds.keys().size() == 3 and kinds.has("recruit") and kinds.has("prepare") and kinds.has("sortie"))

	_check("大厅行走边界是原尺寸地板矩形", sim.nav.bounds() == Rect2(0, 433, 1920, 637))
	_check("货台只阻挡接地面，箱子背后的地面可站", not sim.nav.walkable(Vector2(350, 730)) and sim.nav.click_ok(Vector2(300, 650)))
	_check("告示牌只阻挡支脚占地，牌面投影后方可站", not sim.nav.walkable(Vector2(1722, 570)) and sim.nav.click_ok(Vector2(1722, 493)))
	_check("货台斜边外包框里的空地可走", sim.nav.click_ok(Vector2(385, 900)))
	_check("原灰盒桌子和隔断位置已恢复通行", sim.nav.segment_clear(Vector2(400, 585), Vector2(1120, 585)))
	# 从配置中分别移走一个摆件，另一个仍保持原位置的阻挡。
	for removed: int in [0, 1]:
		var layout := _layout.duplicate(true)
		layout["obstacles"].remove_at(removed)
		var nav := (_make(layout)["sim"] as TavernSim).nav
		var probes := [Vector2(350, 730), Vector2(1722, 570)]
		_check("移走 %s 后只释放自己的占地" % _layout["obstacles"][removed]["id"],
			nav.click_ok(probes[removed]) and not nav.walkable(probes[1 - removed]))


# ── 移动 ──

## 拖出两条被物件占地截断的路线，并检查固定步长、到点与改道信号。
func _movement() -> void:
	var battle := _make()
	var sim: TavernSim = battle["sim"]
	var events: TavernEvents = battle["events"]
	var controller: TavernController = battle["controller"]
	var board_start := Vector2(1510, 565)
	var board_end := Vector2(1870, 565)
	var board_route := sim.nav.find_path(board_start, board_end)
	_check("路径从告示牌一侧绕到另一侧", not sim.nav.segment_clear(board_start, board_end)
		and board_route["ok"] and board_route["path"].size() > 2, str(board_route))
	sim.spawn_captain("warrior", Vector2(300, 650))
	var target := Vector2(80, 1010)
	var straight_blocked := not sim.nav.segment_clear(sim.captain_pos, target)
	_check("货台接地多边形截断直线路径", straight_blocked)
	var result := controller.on_right_click(target)
	_check("点可达地面：接受，路径有绕行点", result["ok"] and int(result["waypoints"]) >= 3, str(result))
	var last := sim.captain_pos
	var max_step := 0.0
	var guard := 0
	while sim.is_moving() and guard < 800:
		sim.step(TICK)
		max_step = maxf(max_step, sim.captain_pos.distance_to(last))
		last = sim.captain_pos
		guard += 1
	_check("到达落点后停止，位置是精确终点", not sim.is_moving() and sim.captain_pos.distance_to(target) < 0.01, str(sim.captain_pos))
	_check("每步移动不超过 速度×步长（220×0.05=11）", max_step <= 11.0 + 0.001, str(max_step))
	_check("沿途从不进入障碍（绕行）", _count(events, "command_rejected", {"reason": "path_invalid"}) == 0)
	# 移动信号：每个步长最多一次，最后一次是精确终点
	var moves: Array = []
	for line in events.lines:
		var record: Dictionary = JSON.parse_string(line)
		if record["e"] == "tavern_captain_moved":
			moves.append(record)
	var per_tick := {}
	var once_per_tick := true
	for record: Dictionary in moves:
		var tick := int(round(float(record["t"]) / TICK))
		once_per_tick = once_per_tick and not per_tick.has(tick)
		per_tick[tick] = true
	var final_pos: Array = moves[moves.size() - 1]["pos"]
	_check("tavern_captain_moved 每个步长最多一次", once_per_tick and moves.size() > 5, str(moves.size()))
	_check("最后一次 tavern_captain_moved 是精确终点", absf(float(final_pos[0]) - target.x) < 0.11 and absf(float(final_pos[1]) - target.y) < 0.11, str(final_pos))
	var before := _count(events, "tavern_captain_moved")
	_steps(sim, 20)
	_check("站住后不再发移动信号", _count(events, "tavern_captain_moved") == before)
	# 移动中改点另一处：只保留最新落点
	var second := Vector2(1400, 900)
	controller.on_right_click(Vector2(480, 500))
	_steps(sim, 5)
	controller.on_right_click(second)
	_settle(sim)
	_check("移动中点另一处：改走新路径，只去最新落点", sim.captain_pos.distance_to(second) < 0.01, str(sim.captain_pos))
	# 点队长自己
	controller.on_right_click(Vector2(480, 500))
	_steps(sim, 3)
	var dest_before := sim.destination
	var self_click := controller.on_left_click(sim.captain_pos)
	_check("点队长自己：不做任何事，不打断移动", self_click.get("ignored", false) and sim.is_moving() and sim.destination == dest_before, str(self_click))
	_check("点队长自己不打开面板", sim.panel == "")


## 对真实绕障路径逐帧取样，验证每个转弯都经过权威路点。
func _display_corners() -> void:
	for fps: int in [60, 120]:
		var sim: TavernSim = _make()["sim"]
		sim.spawn_captain("warrior", Vector2(300, 650))
		var target := Vector2(80, 1010)
		var track := MotionTrack.new(sim.get_instance_id(), sim.captain_generation, 0)
		track.record(sim.time, sim.captain_pos, 0)
		sim.click_ground(target)
		var valid := true
		var count := 0
		var steps := 0
		while sim.is_moving() and steps < 800:
			steps += 1
			var before := sim.captain_pos
			var corners := PackedVector2Array()
			sim.step(TICK, corners)
			track.record(sim.time, sim.captain_pos, 0, corners)
			var chain := PackedVector2Array([before])
			chain.append_array(corners)
			chain.append(sim.captain_pos)
			var length := 0.0
			for i in range(1, chain.size()):
				length += chain[i - 1].distance_to(chain[i])
			if not corners.is_empty():
				count += 1
				var phase := TICK * before.distance_to(corners[0]) / length
				valid = valid and track.local_position(phase).distance_to(corners[0]) < 0.001
			for frame in range(1, roundi(TICK * fps) + 1):
				var pos := track.local_position(float(frame) / fps)
				valid = valid and sim.nav.on_path_ok(pos) and pos.distance_to(before) <= length + 0.001
		_check("%d FPS 酒馆逐帧绕障并精确通过转角" % fps, valid and count > 0 and track.local_position(TICK).distance_to(target) < 0.001)


## 用一条测试墙制造不连通区域，正式场景的占地拒绝仍用两件实物验证。
func _invalid_clicks() -> void:
	var battle := _make(_divided_layout())
	var sim: TavernSim = battle["sim"]
	var events: TavernEvents = battle["events"]
	var controller: TavernController = battle["controller"]
	var good := Vector2(700, 700)
	controller.on_right_click(good)
	_steps(sim, 4)
	var cargo_click := controller.on_right_click(Vector2(350, 730))
	_check("点货台占地：拒绝，原因 blocked", not cargo_click["ok"] and cargo_click["reason"] == "blocked", str(cargo_click))
	_check("无效点击不覆盖原合法命令", sim.is_moving() and sim.destination == good)
	var outside := controller.on_right_click(Vector2(10, 10))
	_check("点场景外：同样 blocked，原命令保留", not outside["ok"] and sim.destination == good)
	var across := controller.on_right_click(Vector2(1700, 880))
	_check("点能站但不连通的区域：unreachable，原命令保留", not across["ok"] and across["reason"] == "unreachable" and sim.destination == good, str(across))
	var board_click := controller.on_right_click(Vector2(1722, 570))
	_check("点告示牌底座：blocked", not board_click["ok"] and board_click["reason"] == "blocked")
	_settle(sim)
	_check("被拒绝之后原合法命令照常走完", sim.captain_pos.distance_to(good) < 0.01)
	_check("四次拒绝都进日志", _count(events, "command_rejected", {"kind": "move"}) == 4, str(_count(events, "command_rejected")))
	# 靠近阻挡边缘一点点的落点也不会让人穿墙：能走到的点都不在外扩障碍里
	var near_wall := Vector2(1100, sim.nav.bounds().position.y + sim.nav.radius() + 3)
	var near_result := controller.on_right_click(near_wall)
	_check("贴边落点要么拒绝要么站得住，不会卡进墙里", (not near_result["ok"]) or sim.nav.on_path_ok(near_wall))


## 右键接管旧交互，失焦仍能结束路线。
func _right_click_and_focus() -> void:
	var battle := _make()
	var sim: TavernSim = battle["sim"]
	var events: TavernEvents = battle["events"]
	var controller: TavernController = battle["controller"]
	controller.on_left_click(_object_center(sim, "recruit"))
	_steps(sim, 6)
	_check("测试前提：正在走向招募并有待交互", sim.is_moving() and sim.pending_object == "recruit")
	var landing := Vector2(700, 700)
	var result := controller.on_right_click(landing)
	_check("右键改为走向落点，取消待交互", result["ok"] and sim.is_moving()
		and sim.pending_object == "" and sim.destination == landing, str(result))
	var left := controller.on_left_click(Vector2(1080, 540))
	_check("左键空地维持当前路线", left.get("ignored", false) and sim.destination == landing)
	_settle(sim)
	_check("右键落点到达后停步，原交互不再打开", sim.captain_pos == landing
		and sim.panel == "" and _count(events, "panel_opened") == 0)
	_check("日志记录改点地面取消交互", _count(events, "interact_cancelled", {"why": "ground_click"}) == 1)
	# 失去焦点
	var focus := _make()
	var fsim: TavernSim = focus["sim"]
	var fctl: TavernController = focus["controller"]
	fctl.on_left_click(_object_center(fsim, "prepare"))
	_steps(fsim, 6)
	fctl.on_focus_lost()
	var held := fsim.captain_pos
	_steps(fsim, 80)
	_check("失去焦点：停步并取消待交互，回来后不续走也不开面板", not fsim.is_moving() and fsim.pending_object == "" and fsim.captain_pos == held and fsim.panel == "")


## 方向输入经过 InputMap 进入原控制器，测试速度、回中与按脚下判定。
func _direction_input() -> void:
	var test := _make()
	var sim: TavernSim = test["sim"]
	var controller: TavernController = test["controller"]
	var origin := sim.captain_pos
	Input.action_press("move_key_right")
	Input.action_press("move_key_up")
	controller.update_direction(true)
	sim.step(TICK)
	var diagonal := sim.captain_pos - origin
	_check("方向键斜向以原速度走位", diagonal.x > 0.0 and diagonal.y < 0.0 and is_equal_approx(diagonal.length(), 11.0))
	var landing := Vector2(1300, 700)
	controller.on_right_click(landing)
	controller.update_direction(true)
	_check("鼠标能接管按住的方向键", sim.move_direction == Vector2.ZERO and sim.destination == landing)
	Input.action_release("move_key_right")
	Input.action_release("move_key_up")
	controller.update_direction(true)
	Input.action_press("move_stick_down", 0.1)
	controller.update_direction(true)
	_check("摇杆死区内保留现有路线", sim.move_direction == Vector2.ZERO and sim.destination == landing)
	Input.action_press("move_stick_down", 0.6)
	var before := sim.captain_pos
	controller.update_direction(true)
	sim.step(TICK)
	_check("左摇杆越过死区后按幅度走位", sim.path.is_empty()
		and absf(sim.captain_pos.y - before.y - 5.5) < 0.001 and sim.captain_pos.x == before.x)
	Input.action_release("move_stick_down")
	controller.update_direction(true)
	var stopped := sim.captain_pos
	sim.step(TICK)
	_check("摇杆回中后停止，不恢复旧路线", not sim.is_moving() and sim.captain_pos == stopped)
	_check("同一个脚点可贴近墙和告示牌，角色显示范围可以重叠",
		sim.nav.radius() == 8.0 and sim.nav.click_ok(Vector2(1100, 442))
		and sim.nav.click_ok(Vector2(1722, 541)) and not sim.nav.click_ok(Vector2(1722, 543)))
	var foot := Vector2(1600, 560)
	sim.spawn_captain("warrior", foot)
	sim.set_move_direction(Vector2(1, 0.22))
	for index in 6:
		sim.step(TICK)
	_check("斜推告示牌边缘沿侧面滑动，脚点路径始终在外", sim.captain_pos.y > foot.y
		and sim.captain_pos.x <= 1618.0 and sim.nav.walkable(sim.captain_pos))


# ── 交互点 ──

## 检查三个场景入口的走近规则，普通走过交互范围也不会开面板。
func _interaction() -> void:
	# 走过范围不自动开：落点正好在交互范围里，也只是走到
	var battle := _make()
	var sim: TavernSim = battle["sim"]
	var events: TavernEvents = battle["events"]
	var controller: TavernController = battle["controller"]
	var recruit_approach: Vector2 = sim.object_info("recruit")["approach"]
	controller.on_right_click(recruit_approach)
	_settle(sim)
	_check("点地面走进招募点范围：到达，但不开面板", sim.captain_pos.distance_to(recruit_approach) < 0.01 and sim.panel == "" and _count(events, "panel_opened") == 0)
	# 路过：从招募点一路走到整备点，途中经过别的交互点范围
	var sortie_approach: Vector2 = sim.object_info("sortie")["approach"]
	controller.on_right_click(sortie_approach)
	_settle(sim)
	_check("点地面走到出征点范围：同样不开面板", sim.panel == "" and _count(events, "panel_opened") == 0)
	var crossed := false
	var path_walker := _make()
	var psim: TavernSim = path_walker["sim"]
	var pctl: TavernController = path_walker["controller"]
	psim.spawn_captain("warrior", Vector2(442, 660))
	pctl.on_right_click(Vector2(442, 830))
	var guard := 0
	while psim.is_moving() and guard < 800:
		psim.step(TICK)
		var info := psim.object_info("prepare")
		if psim.captain_pos.distance_to(info["approach"]) <= float(info["range"]):
			crossed = true
		guard += 1
	_check("路径横穿整备点范围（起点和终点都在范围外）：全程不开面板", crossed and psim.captain_pos.distance_to(psim.object_info("prepare")["approach"]) > 60.0 and psim.panel == "" and _count(path_walker["events"], "panel_opened") == 0)

	# 点对象：先走近，到达后才开，只开一次
	var go := _make()
	var gsim: TavernSim = go["sim"]
	var gevents: TavernEvents = go["events"]
	var gctl: TavernController = go["controller"]
	var result := gctl.on_left_click(_object_center(gsim, "sortie"))
	_check("点远处的出征点：接受，开始走，面板还没开", result["ok"] and gsim.is_moving() and gsim.panel == "" and gsim.pending_object == "sortie", str(result))
	_steps(gsim, 8)
	_check("走到一半时仍没开面板", gsim.panel == "" and _count(gevents, "panel_opened") == 0)
	_settle(gsim)
	var approach: Vector2 = gsim.object_info("sortie")["approach"]
	_check("到达交互落点（对象外的可走位置，不是对象中心）", gsim.captain_pos.distance_to(approach) < 0.01 and not (gsim.object_info("sortie")["rect"] as Rect2).has_point(gsim.captain_pos))
	_check("到达后恰好打开一个出征面板，待交互清空", gsim.panel == "sortie" and _count(gevents, "panel_opened", {"kind": "sortie"}) == 1 and gsim.pending_object == "")
	_steps(gsim, 40)
	_check("面板开着时队长站着不动", not gsim.is_moving() and gsim.captain_pos.distance_to(approach) < 0.01)
	# 已经在范围内：点击后立即开
	gsim.close_panel()
	var again := gctl.on_left_click(_object_center(gsim, "sortie"))
	_check("已在范围内再点：立即打开，不走动", again.get("opened", false) and gsim.panel == "sortie" and not gsim.is_moving(), str(again))
	_check("三类对象各自打开对应面板", _opens_each())


func _opens_each() -> bool:
	for kind in ["recruit", "prepare", "sortie"]:
		var battle := _make()
		var sim: TavernSim = battle["sim"]
		(battle["controller"] as TavernController).on_left_click(_object_center(sim, kind))
		_settle(sim)
		if sim.panel != kind:
			return false
	return true


## 保留交互请求替换、去重和不可达时不打断原命令的验收。
func _replace_and_dedupe() -> void:
	# 改道：走向招募途中改点整备，原请求不会随后弹出
	var battle := _make()
	var sim: TavernSim = battle["sim"]
	var events: TavernEvents = battle["events"]
	var controller: TavernController = battle["controller"]
	controller.on_left_click(_object_center(sim, "recruit"))
	_steps(sim, 12)
	controller.on_left_click(_object_center(sim, "prepare"))
	_check("改点另一个对象：待交互换成新的", sim.pending_object == "prepare")
	_settle(sim)
	_check("到达后只开整备，招募请求不会随后弹出", sim.panel == "prepare" and _count(events, "panel_opened") == 1 and _count(events, "panel_opened", {"kind": "recruit"}) == 0)
	_check("日志记了替换", _count(events, "interact_replaced", {"old_object_id": "recruit", "new_object_id": "prepare"}) == 1)
	# 同一对象连点：只保留一次请求
	var dup := _make()
	var dsim: TavernSim = dup["sim"]
	var devents: TavernEvents = dup["events"]
	var dctl: TavernController = dup["controller"]
	for _i in 4:
		dctl.on_left_click(_object_center(dsim, "recruit"))
		_steps(dsim, 3)
	_settle(dsim)
	_check("连续点同一对象：只一次请求、只开一个面板", _count(devents, "interact_requested") == 1 and _count(devents, "panel_opened") == 1 and dsim.panel == "recruit", "requests=%d" % _count(devents, "interact_requested"))
	# 点对象后改点地面：只移动，到达后不弹面板
	var swap := _make()
	var ssim: TavernSim = swap["sim"]
	var sevents: TavernEvents = swap["events"]
	var sctl: TavernController = swap["controller"]
	sctl.on_left_click(_object_center(ssim, "recruit"))
	_steps(ssim, 5)
	sctl.on_right_click(Vector2(700, 700))
	_check("改点地面：待交互取消", ssim.pending_object == "")
	_settle(ssim)
	_check("改点地面后到达不会弹出原面板", ssim.panel == "" and _count(sevents, "panel_opened") == 0 and _count(sevents, "interact_cancelled", {"why": "ground_click"}) == 1)
	# 交互落点不可达：保留原合法命令并提示
	var shut := _make(_divided_layout())
	var shsim: TavernSim = shut["sim"]
	var shevents: TavernEvents = shut["events"]
	var shctl: TavernController = shut["controller"]
	shctl.on_right_click(Vector2(700, 700))
	_steps(shsim, 4)
	var dest := shsim.destination
	var bad := shctl.on_left_click(_object_center(shsim, "recruit"))
	_check("交互落点不可达：拒绝，原因 approach_unreachable", not bad["ok"] and bad["reason"] == "approach_unreachable", str(bad))
	_check("不可达时保留原合法命令，不留待交互", shsim.is_moving() and shsim.destination == dest and shsim.pending_object == "")
	_settle(shsim)
	_check("原命令走完，不无限行走", shsim.captain_pos.distance_to(dest) < 0.01 and _count(shevents, "panel_opened") == 0)
	# 界面入口仍可用：不依赖走过去
	shsim.open_panel("recruit")
	_check("界面入口（open_panel）不受交互落点影响", shsim.panel == "recruit")


# ── 面板与输入优先级 ──

## 验证面板输入优先级，移动目标选在实际大厅内。
func _panels() -> void:
	var battle := _make()
	var sim: TavernSim = battle["sim"]
	var events: TavernEvents = battle["events"]
	var controller: TavernController = battle["controller"]
	controller.on_left_click(_object_center(sim, "prepare"))
	_settle(sim)
	var held := sim.captain_pos
	var ground := controller.on_left_click(Vector2(400, 800))
	_check("面板里点地面：不移动（panel_open）", not ground["ok"] and ground["reason"] == "panel_open" and not sim.is_moving())
	var object := controller.on_left_click(_object_center(sim, "recruit"))
	_check("面板打开时点场景对象：不处理、不换面板", not object["ok"] and sim.panel == "prepare" and sim.pending_object == "")
	var right := controller.on_right_click(Vector2(700, 700))
	_check("面板打开时右键不穿透到场景", not right["ok"] and right["reason"] == "panel_open")
	_steps(sim, 30)
	_check("面板打开期间队长位置始终不变", sim.captain_pos == held)
	_check("点面板外不会关面板", sim.panel == "prepare")
	var escaped := controller.on_escape()
	_check("Esc 关闭当前面板，一次只关一层", escaped and sim.panel == "" and _count(events, "panel_closed", {"kind": "prepare"}) == 1)
	_steps(sim, 40)
	_check("关闭后队长保持站立，不续走", sim.captain_pos == held and not sim.is_moving())
	_check("没有面板时 Esc 不处理（以后是菜单）", not controller.on_escape())
	# 移动中开面板：队长当场站住，关闭后不续走
	var moving := _make()
	var msim: TavernSim = moving["sim"]
	var mctl: TavernController = moving["controller"]
	mctl.on_right_click(Vector2(490, 520))
	_steps(msim, 10)
	var mid := msim.captain_pos
	msim.open_panel("recruit")
	_check("移动中从常驻入口开面板：当场站住并取消待交互", not msim.is_moving() and msim.captain_pos == mid and msim.pending_object == "")
	msim.close_panel()
	_steps(msim, 40)
	_check("关面板后不续走", msim.captain_pos == mid)
	# 面板替换：先 closed 再 opened，永不叠加
	var swap := _make()
	var ssim: TavernSim = swap["sim"]
	var sevents: TavernEvents = swap["events"]
	ssim.open_panel("prepare")
	ssim.open_panel("prepare")
	_check("同一面板已开着再开：不重发信号", _count(sevents, "panel_opened") == 1)
	ssim.open_panel("recruit")
	var seq: Array = []
	for line in sevents.lines:
		var record: Dictionary = JSON.parse_string(line)
		if record["e"] == "panel_opened" or record["e"] == "panel_closed":
			seq.append("%s:%s" % [record["e"], record["kind"]])
	_check("切面板顺序：opened prepare → closed prepare → opened recruit", seq == ["panel_opened:prepare", "panel_closed:prepare", "panel_opened:recruit"], str(seq))
	_check("同一时刻只有一个面板", ssim.panel == "recruit")
	_check("未知面板被拒绝", not ssim.open_panel("bag")["ok"] and ssim.panel == "recruit")
	# 酒馆里没有战斗入口
	_check("酒馆控制器没有选人和放技能入口（数字键、Q/W/E/R 无效）", not controller.has_method("press_skill") and not controller.has_method("select_slot"))


func _zero_members() -> void:
	var battle := _make({}, false)
	var sim: TavernSim = battle["sim"]
	var events: TavernEvents = battle["events"]
	var controller: TavernController = battle["controller"]
	_check("零成员：场景里没有角色", not sim.has_captain)
	var ground := controller.on_right_click(Vector2(700, 700))
	_check("零成员点地面：无事发生（no_captain）", not ground["ok"] and ground["reason"] == "no_captain")
	var recruit := controller.on_left_click(_object_center(sim, "recruit"))
	_check("零成员点招募公告板：直接开招募面板", recruit.get("opened", false) and sim.panel == "recruit" and _count(events, "panel_opened", {"kind": "recruit"}) == 1)
	sim.close_panel()
	_check("零成员也能直接开整备和出征面板", (controller.on_left_click(_object_center(sim, "prepare")) as Dictionary).get("opened", false) and sim.panel == "prepare")
	sim.close_panel()
	sim.spawn_captain("mage", sim.spawn_pos())
	_check("第一人入队：队长出现在出生点", sim.has_captain and sim.captain_pos == sim.spawn_pos() and sim.captain_class == "mage")
	_check("生成队长不发移动信号", _count(events, "tavern_captain_moved") == 0)


func _captain_swap() -> void:
	var battle := _make()
	var sim: TavernSim = battle["sim"]
	var events: TavernEvents = battle["events"]
	var controller: TavernController = battle["controller"]
	controller.on_left_click(_object_center(sim, "prepare"))
	_steps(sim, 10)
	var pos := sim.captain_pos
	var facing := sim.captain_facing
	var moved_before := _count(events, "tavern_captain_moved")
	sim.swap_captain_class("priest")
	_check("换队长：形象换了，位置和朝向不变", sim.captain_class == "priest" and sim.captain_pos == pos and is_equal_approx(sim.captain_facing, facing))
	_check("换队长：取消原移动和待交互", not sim.is_moving() and sim.pending_object == "")
	_check("换队长不发 tavern_captain_moved，也不重复生成角色", _count(events, "tavern_captain_moved") == moved_before and _count(events, "captain_spawned") == 1)
	_steps(sim, 30)
	_check("换队长后不续走", sim.captain_pos == pos)


func _signals_and_log() -> void:
	var battle := _make({}, false)
	var sim: TavernSim = battle["sim"]
	var events: TavernEvents = battle["events"]
	var controller: TavernController = battle["controller"]
	var seen := {"moved": 0, "opened": 0, "closed": 0}
	var kinds: Array = []
	events.tavern_captain_moved.connect(func(_pos): seen["moved"] += 1)
	events.panel_opened.connect(func(kind): seen["opened"] += 1; kinds.append(kind))
	events.panel_closed.connect(func(kind): seen["closed"] += 1; kinds.append(kind))
	sim.spawn_captain("warrior", sim.default_pos())
	controller.on_left_click(_object_center(sim, "recruit"))
	_settle(sim)
	controller.on_escape()
	_check("三个信号都真的发出，次数与日志一致", seen["moved"] == _count(events, "tavern_captain_moved") and seen["moved"] > 0 and seen["opened"] == 1 and seen["closed"] == 1, str(seen))
	_check("信号参数：kind 是字符串、与面板一致", kinds == ["recruit", "recruit"], str(kinds))
	var record: Dictionary = JSON.parse_string(events.lines[events.lines.size() - 1])
	_check("日志每行是 JSON，含时间戳和事件名", record.has("t") and record.has("e"))
	var schema_ok := true
	for line in events.lines:
		var parsed: Dictionary = JSON.parse_string(line)
		schema_ok = schema_ok and TavernEvents.SCHEMA.has(parsed["e"])
	_check("日志里的事件名都在 SCHEMA 里", schema_ok)
	_check("信号名正好三个", TavernEvents.SIGNALS == ["tavern_captain_moved", "panel_opened", "panel_closed"])


## 从空地及两件落地物附近取样，检查拉直后的实际路线。
func _random_paths() -> void:
	var battle := _make()
	var sim: TavernSim = battle["sim"]
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var accepted := 0
	var rejected_blocked := 0
	var rejected_unreachable := 0
	var violations := 0
	var origins := [sim.default_pos(), Vector2(300, 650), Vector2(1510, 565)]
	for index in 300:
		var target := Vector2(rng.randf_range(0.0, 1920.0), rng.randf_range(420.0, 1070.0))
		var route := sim.nav.find_path(origins[index % origins.size()], target)
		if not bool(route["ok"]):
			if route["reason"] == "blocked":
				rejected_blocked += 1
			else:
				rejected_unreachable += 1
			continue
		accepted += 1
		var path: Array = route["path"]
		for segment in range(path.size() - 1):
			var a: Vector2 = path[segment]
			var b: Vector2 = path[segment + 1]
			var length := a.distance_to(b)
			var samples := maxi(1, int(length / 2.0))
			for sample in samples + 1:
				if not sim.nav.on_path_ok(a.lerp(b, float(sample) / float(samples))):
					violations += 1
	_check("开放大厅的 300 个随机落点（可达 %d / 阻挡 %d / 不连通 %d）" % [accepted, rejected_blocked, rejected_unreachable], accepted > 50 and rejected_blocked > 10 and rejected_unreachable == 0)
	_check("所有可达路径沿线每 2 像素取样都不在障碍里", violations == 0, str(violations))


## 隔开告示牌一侧以保留不可达回归用例，分隔墙只存在于测试布局。
func _divided_layout() -> Dictionary:
	var layout := _layout.duplicate(true)
	var bounds := TavernLayout.rect_of(layout["bounds"])
	layout["obstacles"].append({"id": "test_divider", "x": 1540, "y": bounds.position.y, "w": 30, "h": bounds.size.y})
	return layout


func _determinism() -> void:
	var lines: Array = []
	for _run in 2:
		var battle := _make()
		var sim: TavernSim = battle["sim"]
		var controller: TavernController = battle["controller"]
		controller.on_left_click(_object_center(sim, "recruit"))
		_steps(sim, 9)
		controller.on_right_click(Vector2(700, 700))
		_steps(sim, 15)
		controller.on_left_click(_object_center(sim, "sortie"))
		_settle(sim)
		controller.on_escape()
		lines.append("\n".join((battle["events"] as TavernEvents).lines))
	_check("同样的输入序列得到逐行相同的事件日志", lines[0] == lines[1] and lines[0].length() > 100)
