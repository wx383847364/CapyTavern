extends SceneTree
## P3a 酒馆自检（无窗口，直接驱动逻辑层和控制器）。运行：
##   godot --headless --path client --script res://scripts/tests/tavern_check.gd
## 对应操作稿 §1.2～§1.4 和 §1.12 里 P3a 范围的条目。有失败时退出码 1。不改任何文件。

const TavernSim := preload("res://scripts/tavern/tavern_sim.gd")
const TavernEvents := preload("res://scripts/tavern/tavern_events.gd")
const TavernLayout := preload("res://scripts/data/tavern_layout.gd")
const TavernController := preload("res://scripts/input/tavern_controller.gd")

const TICK := 0.05

var _failures: int = 0
var _layout: Dictionary = {}


func _initialize() -> void:
	_layout = TavernLayout.load_layout()
	var problems := TavernLayout.validate(_layout)
	_check("布局可用", problems.is_empty(), ", ".join(problems))
	if problems.is_empty():
		_geometry()
		_movement()
		_invalid_clicks()
		_right_click_and_focus()
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


# ── 移动 ──

func _movement() -> void:
	var battle := _make()
	var sim: TavernSim = battle["sim"]
	var events: TavernEvents = battle["events"]
	var controller: TavernController = battle["controller"]
	var target := Vector2(700, 700)
	var straight_blocked := not sim.nav.segment_clear(sim.captain_pos, target)
	_check("测试前提：默认落点到目标之间隔着隔断，直线不通", straight_blocked)
	var result := controller.on_left_click(target)
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
	controller.on_left_click(Vector2(300, 400))
	_steps(sim, 5)
	controller.on_left_click(second)
	_settle(sim)
	_check("移动中点另一处：改走新路径，只去最新落点", sim.captain_pos.distance_to(second) < 0.01, str(sim.captain_pos))
	# 点队长自己
	controller.on_left_click(Vector2(300, 400))
	_steps(sim, 3)
	var dest_before := sim.destination
	var self_click := controller.on_left_click(sim.captain_pos)
	_check("点队长自己：不做任何事，不打断移动", self_click.get("ignored", false) and sim.is_moving() and sim.destination == dest_before, str(self_click))
	_check("点队长自己不打开面板", sim.panel == "")


func _invalid_clicks() -> void:
	var battle := _make()
	var sim: TavernSim = battle["sim"]
	var events: TavernEvents = battle["events"]
	var controller: TavernController = battle["controller"]
	var good := Vector2(700, 700)
	controller.on_left_click(good)
	_steps(sim, 4)
	var table_click := controller.on_left_click(Vector2(520, 585))
	_check("点桌子（阻挡区域）：拒绝，原因 blocked", not table_click["ok"] and table_click["reason"] == "blocked", str(table_click))
	_check("无效点击不覆盖原合法命令", sim.is_moving() and sim.destination == good)
	var outside := controller.on_left_click(Vector2(10, 10))
	_check("点场景外：同样 blocked，原命令保留", not outside["ok"] and sim.destination == good)
	var closet := controller.on_left_click(Vector2(1700, 880))
	_check("点能站但不连通的区域（密闭储藏间）：unreachable，原命令保留", not closet["ok"] and closet["reason"] == "unreachable" and sim.destination == good, str(closet))
	var wall := controller.on_left_click(Vector2(1575, 850))
	_check("点墙：blocked", not wall["ok"] and wall["reason"] == "blocked")
	_settle(sim)
	_check("被拒绝之后原合法命令照常走完", sim.captain_pos.distance_to(good) < 0.01)
	_check("三次拒绝都进日志", _count(events, "command_rejected", {"kind": "move"}) == 4, str(_count(events, "command_rejected")))
	# 靠近阻挡边缘一点点的落点也不会让人穿墙：能走到的点都不在外扩障碍里
	var near_wall := Vector2(1100, 138 + 22 + 3)
	var near_result := controller.on_left_click(near_wall)
	_check("贴边落点要么拒绝要么站得住，不会卡进墙里", (not near_result["ok"]) or sim.nav.on_path_ok(near_wall))


func _right_click_and_focus() -> void:
	var battle := _make()
	var sim: TavernSim = battle["sim"]
	var events: TavernEvents = battle["events"]
	var controller: TavernController = battle["controller"]
	controller.on_left_click(_object_center(sim, "recruit"))
	_steps(sim, 6)
	_check("测试前提：正在走向招募并有待交互", sim.is_moving() and sim.pending_object == "recruit")
	var stopped_at := sim.captain_pos
	var result := controller.on_right_click()
	_check("右键：停步并取消待交互", result["ok"] and not sim.is_moving() and sim.pending_object == "", str(result))
	_steps(sim, 40)
	_check("右键后不再走，也不会补开面板", sim.captain_pos == stopped_at and sim.panel == "" and _count(events, "panel_opened") == 0)
	_check("日志记了停步原因和取消原因", _count(events, "movement_stopped", {"why": "right_click"}) == 1 and _count(events, "interact_cancelled", {"why": "right_click"}) == 1)
	_check("没在走时右键不报错也不记日志", controller.on_right_click()["ok"] and _count(events, "movement_stopped") == 1)
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


# ── 交互点 ──

func _interaction() -> void:
	# 走过范围不自动开：落点正好在交互范围里，也只是走到
	var battle := _make()
	var sim: TavernSim = battle["sim"]
	var events: TavernEvents = battle["events"]
	var controller: TavernController = battle["controller"]
	var recruit_approach: Vector2 = sim.object_info("recruit")["approach"]
	controller.on_left_click(recruit_approach)
	_settle(sim)
	_check("点地面走进招募点范围：到达，但不开面板", sim.captain_pos.distance_to(recruit_approach) < 0.01 and sim.panel == "" and _count(events, "panel_opened") == 0)
	# 路过：从招募点一路走到整备点，途中经过别的交互点范围
	var sortie_approach: Vector2 = sim.object_info("sortie")["approach"]
	controller.on_left_click(sortie_approach)
	_settle(sim)
	_check("点地面走到出征点范围：同样不开面板", sim.panel == "" and _count(events, "panel_opened") == 0)
	var crossed := false
	var path_walker := _make()
	var psim: TavernSim = path_walker["sim"]
	var pctl: TavernController = path_walker["controller"]
	psim.spawn_captain("warrior", Vector2(1300, 480))
	pctl.on_left_click(Vector2(1520, 480))
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
	sctl.on_left_click(Vector2(700, 700))
	_check("改点地面：待交互取消", ssim.pending_object == "")
	_settle(ssim)
	_check("改点地面后到达不会弹出原面板", ssim.panel == "" and _count(sevents, "panel_opened") == 0 and _count(sevents, "interact_cancelled", {"why": "ground_click"}) == 1)
	# 交互落点不可达：保留原合法命令并提示
	var closed_layout: Dictionary = _layout.duplicate(true)
	for entry: Dictionary in closed_layout["objects"]:
		if entry["id"] == "recruit":
			entry["approach"] = {"x": 1700, "y": 880}
	var shut := _make(closed_layout)
	var shsim: TavernSim = shut["sim"]
	var shevents: TavernEvents = shut["events"]
	var shctl: TavernController = shut["controller"]
	shctl.on_left_click(Vector2(700, 700))
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
	var right := controller.on_right_click()
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
	mctl.on_left_click(Vector2(400, 300))
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
	var ground := controller.on_left_click(Vector2(700, 700))
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


func _random_paths() -> void:
	var battle := _make()
	var sim: TavernSim = battle["sim"]
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var accepted := 0
	var rejected_blocked := 0
	var rejected_unreachable := 0
	var violations := 0
	for _i in 300:
		var target := Vector2(rng.randf_range(60.0, 1860.0), rng.randf_range(120.0, 1000.0))
		var route := sim.nav.find_path(sim.captain_pos, target)
		if not bool(route["ok"]):
			if route["reason"] == "blocked":
				rejected_blocked += 1
			else:
				rejected_unreachable += 1
			continue
		accepted += 1
		var path: Array = route["path"]
		for index in range(path.size() - 1):
			var a: Vector2 = path[index]
			var b: Vector2 = path[index + 1]
			var length := a.distance_to(b)
			var samples := maxi(1, int(length / 2.0))
			for sample in samples + 1:
				if not sim.nav.on_path_ok(a.lerp(b, float(sample) / float(samples))):
					violations += 1
	_check("300 个随机落点：三种结果都出现（可达 %d / 阻挡 %d / 不连通 %d）" % [accepted, rejected_blocked, rejected_unreachable], accepted > 50 and rejected_blocked > 10 and rejected_unreachable > 0)
	_check("所有可达路径沿线每 2 像素取样都不在障碍里", violations == 0, str(violations))


func _determinism() -> void:
	var lines: Array = []
	for _run in 2:
		var battle := _make()
		var sim: TavernSim = battle["sim"]
		var controller: TavernController = battle["controller"]
		controller.on_left_click(_object_center(sim, "recruit"))
		_steps(sim, 9)
		controller.on_left_click(Vector2(700, 700))
		_steps(sim, 15)
		controller.on_left_click(_object_center(sim, "sortie"))
		_settle(sim)
		controller.on_escape()
		lines.append("\n".join((battle["events"] as TavernEvents).lines))
	_check("同样的输入序列得到逐行相同的事件日志", lines[0] == lines[1] and lines[0].length() > 100)
