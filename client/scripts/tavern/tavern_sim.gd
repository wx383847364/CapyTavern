extends RefCounted
## 酒馆逻辑（纯数据、固定步长，不依赖场景和动画）。
## 规则出处：doc/方案与数据/游戏操作功能设计.md §1.1～§1.4。
##   - 只有队长一个角色；点地移动，点交互点先走近、到达后才开面板；走过范围不自动开。
##   - 同一时刻只有一个待交互对象，最新的命令替换旧的；不合法的点击不覆盖原合法命令。
##   - 面板打开：队长站住、取消待交互，场景点击和右键都不处理；一次 Esc 只关一层。
##   - 失去焦点：停步并取消待交互。
##   - 没有队长（零成员）：点交互点直接开对应面板。
## 位置不进存档，重启回默认落点。

const TavernEvents := preload("res://scripts/tavern/tavern_events.gd")
const TavernNav := preload("res://scripts/tavern/tavern_nav.gd")
const TavernLayout := preload("res://scripts/data/tavern_layout.gd")

var layout: Dictionary = {}
var events: TavernEvents
var nav: TavernNav = TavernNav.new()
var time: float = 0.0

var has_captain: bool = false
var captain_class: String = ""
var captain_pos: Vector2 = Vector2.ZERO
## 朝向（弧度），换队长时保持。
var captain_facing: float = 0.0

## 当前路径（含起点）与走到第几个点；空表示站着。
var path: Array[Vector2] = []
var path_index: int = 0
var destination: Vector2 = Vector2.ZERO
## 待交互对象 id，空表示没有。
var pending_object: String = ""
## 当前打开的面板 kind，空表示没有。
var panel: String = ""
var hovered_object: String = ""

var _objects: Dictionary = {}   # id -> {kind, name, rect, approach, range}
var _speed: float = 220.0
var _eps: float = 4.0


func setup(tavern_layout: Dictionary, bus: TavernEvents) -> void:
	layout = tavern_layout
	events = bus
	nav = TavernNav.new()
	nav.setup(layout)
	_speed = float(layout["captain"]["speed"])
	_eps = float(layout["arrive_eps"])
	_objects.clear()
	for entry: Dictionary in layout["objects"]:
		_objects[String(entry["id"])] = {
			"kind": String(entry["kind"]),
			"name": String(entry["name"]),
			"rect": TavernLayout.rect_of(entry),
			"approach": TavernLayout.point_of(entry["approach"]),
			"range": float(entry["range"]),
		}


# ── 队长 ──

func spawn_captain(class_id: String, pos: Vector2) -> void:
	has_captain = true
	captain_class = class_id
	captain_pos = pos
	_clear_motion()
	events.fire(&"captain_spawned", [class_id, pos])


func remove_captain() -> void:
	if has_captain:
		has_captain = false
		captain_class = ""
		_clear_motion()
		events.fire(&"captain_removed", [])


## 换队长只换形象：位置、朝向、槽位都不动，不发 tavern_captain_moved；
## 按操作稿 §1.6 取消原移动和待交互。
func swap_captain_class(class_id: String) -> void:
	if not has_captain:
		return
	captain_class = class_id
	if not path.is_empty():
		_stop("captain_swapped")
	_cancel_pending("captain_swapped")


func spawn_pos() -> Vector2:
	return TavernLayout.point_of(layout["spawn"])


func default_pos() -> Vector2:
	return TavernLayout.point_of(layout["default_pos"])


func is_moving() -> bool:
	return not path.is_empty()


# ── 命令 ──

func _ok(extra: Dictionary = {}) -> Dictionary:
	var result := {"ok": true, "reason": ""}
	result.merge(extra)
	return result


func _reject(kind: String, reason: String) -> Dictionary:
	events.fire(&"command_rejected", [kind, reason])
	return {"ok": false, "reason": reason}


## 左键点地面。
func click_ground(pos: Vector2) -> Dictionary:
	if panel != "":
		return _reject("move", "panel_open")
	if not has_captain:
		return _reject("move", "no_captain")
	var route := nav.find_path(captain_pos, pos)
	if not bool(route["ok"]):
		return _reject("move", String(route["reason"]))
	_cancel_pending("ground_click")
	_begin_path(route["path"])
	events.fire(&"move_ordered", [pos, path.size()])
	return _ok({"waypoints": path.size()})


## 左键点交互点。
func click_object(object_id: String) -> Dictionary:
	if not _objects.has(object_id):
		return _reject("interact", "unknown_object")
	var info: Dictionary = _objects[object_id]
	if panel != "":
		return _reject("interact", "panel_open")
	if not has_captain:
		# 零成员：场景里没有角色可走，直接开面板
		events.fire(&"interact_requested", [object_id, info["kind"]])
		open_panel(String(info["kind"]))
		return _ok({"opened": true})
	if pending_object == object_id:
		# 连续点同一对象只保留一次请求
		return _ok({"duplicate": true})
	events.fire(&"interact_requested", [object_id, info["kind"]])
	if _in_range(info):
		_cancel_pending("opened_in_range")
		open_panel(String(info["kind"]))
		return _ok({"opened": true})
	var route := nav.find_path(captain_pos, info["approach"])
	if not bool(route["ok"]):
		return _reject("interact", "approach_unreachable")
	if pending_object != "":
		events.fire(&"interact_replaced", [pending_object, object_id])
	pending_object = object_id
	_begin_path(route["path"])
	events.fire(&"move_ordered", [info["approach"], path.size()])
	return _ok({"waypoints": path.size()})


## 场景右键：停步并取消待交互。面板打开时不处理（不穿透）。
func right_click() -> Dictionary:
	if panel != "":
		return _reject("stop", "panel_open")
	if path.is_empty() and pending_object == "":
		return _ok({"changed": false})
	if not path.is_empty():
		_stop("right_click")
	_cancel_pending("right_click")
	return _ok({"changed": true})


## 打开面板（场景交互到达、常驻按钮都走这里）。已开着同一个面板时什么也不做；
## 开着别的面板就先关再开，永不叠加。队长站住，待交互清掉。
func open_panel(kind: String) -> Dictionary:
	if not TavernLayout.KINDS.has(kind):
		return _reject("panel", "unknown_panel")
	if panel == kind:
		return _ok({"changed": false})
	if panel != "":
		var previous := panel
		panel = ""
		events.fire(&"panel_closed", [previous])
	if not path.is_empty():
		_stop("panel_opened")
	_cancel_pending("panel_opened")
	panel = kind
	events.fire(&"panel_opened", [kind])
	return _ok({"changed": true})


## 关掉当前面板。返回是否真的关了一个。
func close_panel() -> bool:
	if panel == "":
		return false
	var previous := panel
	panel = ""
	events.fire(&"panel_closed", [previous])
	return true


## Esc 一次只处理一层。P3a 只有面板一层；没有面板时返回 false（以后是打开菜单）。
func escape() -> bool:
	return close_panel()


## 失去程序焦点：停步并取消待交互，回来后等新输入。
func focus_lost() -> void:
	if not path.is_empty():
		_stop("focus_lost")
	_cancel_pending("focus_lost")


func set_hover(pos: Vector2) -> void:
	hovered_object = object_at(pos) if panel == "" else ""


# ── 查询 ──

func object_at(pos: Vector2) -> String:
	for object_id: String in _objects:
		if (_objects[object_id]["rect"] as Rect2).grow(6.0).has_point(pos):
			return object_id
	return ""


func object_info(object_id: String) -> Dictionary:
	return _objects.get(object_id, {})


func object_ids() -> Array:
	return _objects.keys()


## 点在队长身上（点队长自己不做任何事）。
func captain_at(pos: Vector2) -> bool:
	return has_captain and pos.distance_to(captain_pos) <= nav.radius()


func _in_range(info: Dictionary) -> bool:
	return captain_pos.distance_to(info["approach"]) <= float(info["range"])


# ── 推进 ──

func step(dt: float) -> void:
	time += dt
	events.now = time
	if path.is_empty() or panel != "":
		return
	var budget := _speed * dt
	var moved := false
	while budget > 0.0 and path_index < path.size():
		var target := path[path_index]
		var distance := captain_pos.distance_to(target)
		if distance <= 0.0001:
			path_index += 1
			continue
		var next_pos := captain_pos
		var arrived_point := false
		if distance <= budget:
			next_pos = target
			budget -= distance
			arrived_point = true
		else:
			next_pos = captain_pos + (target - captain_pos) / distance * budget
			budget = 0.0
		if not nav.on_path_ok(next_pos):
			_stop("path_invalid")
			events.fire(&"command_rejected", ["move", "path_invalid"])
			_cancel_pending("path_invalid")
			return
		captain_facing = (target - captain_pos).angle()
		captain_pos = next_pos
		moved = true
		if arrived_point:
			path_index += 1
	if moved:
		events.fire(&"tavern_captain_moved", [captain_pos])
	if path_index >= path.size():
		_arrive()


func _arrive() -> void:
	path.clear()
	path_index = 0
	var object_id := pending_object
	pending_object = ""
	if object_id != "":
		var info: Dictionary = _objects[object_id]
		open_panel(String(info["kind"]))


func _begin_path(route: Array) -> void:
	path.clear()
	for point: Vector2 in route:
		path.append(point)
	path_index = 1
	destination = path[path.size() - 1]


func _stop(why: String) -> void:
	path.clear()
	path_index = 0
	events.fire(&"movement_stopped", [why, captain_pos])


func _cancel_pending(why: String) -> void:
	if pending_object != "":
		events.fire(&"interact_cancelled", [pending_object, why])
		pending_object = ""


func _clear_motion() -> void:
	path.clear()
	path_index = 0
	pending_object = ""


func snapshot() -> Dictionary:
	return {
		"has_captain": has_captain,
		"class_id": captain_class,
		"pos": captain_pos,
		"facing": captain_facing,
		"moving": not path.is_empty(),
		"path": path.duplicate(),
		"path_index": path_index,
		"destination": destination,
		"pending": pending_object,
		"panel": panel,
		"hover": hovered_object,
		"time": time,
	}
