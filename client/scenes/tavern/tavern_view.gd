extends Node2D
## 酒馆灰盒的画面：只读逻辑层给的快照（基本类型字典）来画，不碰逻辑对象。
## 图形全用引擎内置绘制，不引外部资源；面板、常驻栏是 scenes/ui/tavern_ui.gd 里的控件，不在这里画。

const FLOOR := Color("2b2118")
const WALL := Color("5a4330")
const BOUNDS_LINE := Color(1, 1, 1, 0.12)
const OBJECT_COLOR := {"recruit": Color("c9a24a"), "prepare": Color("4f8fe0"), "sortie": Color("c8553d")}
const OBSTACLE_HEIGHT := {
	"bar": 60.0, "table_a": 46.0, "table_b": 46.0, "partition": 78.0,
	"pantry_top": 60.0, "pantry_left": 60.0,
}
const REASON_TEXT := {
	"blocked": "这里无法到达",
	"unreachable": "无法到达该位置",
	"approach_unreachable": "无法靠近，请使用界面入口",
	"path_invalid": "路径失效，已停止",
}

var _font: Font = preload("res://scenes/ui/cjk_font.gd").get_font()
var _layout: Dictionary = {}
var _objects: Array = []
var _scenery: Array[Dictionary] = []
var _captain_index: int = 0
var _captain_radius: float = 0.0
var _class_colors: Dictionary = {}
var _snapshot: Dictionary = {}
var _toast: String = ""
var _members: int = 0


## 开场将静态物件按接地边和 ID 排好，画面高度只扩展显示矩形。
func configure(layout: Dictionary, class_colors: Dictionary) -> void:
	_layout = layout
	_class_colors = class_colors
	_objects = layout["objects"]
	_captain_radius = float(layout["captain"]["radius"])
	_scenery.clear()
	for entry: Dictionary in layout["obstacles"]:
		var rect := _rect(entry)
		var id := String(entry["id"])
		var height := float(OBSTACLE_HEIGHT.get(id, 0.0))
		_scenery.append({"id": id, "y": rect.end.y, "rect": rect.grow_side(SIDE_TOP, height), "height": height, "kind": ""})
	for entry: Dictionary in _objects:
		var rect := _rect(entry)
		_scenery.append({"id": String(entry["id"]), "y": rect.end.y, "rect": rect, "height": 0.0, "kind": String(entry["kind"])})
	# 同 Y 用稳定 ID 决定覆盖关系，避免配置数组重排影响显示。
	_scenery.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["y"] < b["y"] if a["y"] != b["y"] else a["id"] < b["id"])
	queue_redraw()


## 每次投影快照时找队长在静态物件之间的位置，绘制和可见本体命中共用它。
func render(snapshot: Dictionary, toast: String, members: int) -> void:
	_snapshot = snapshot
	_toast = toast
	_members = members
	_captain_index = _scenery.size()
	if bool(snapshot.get("has_captain", false)):
		var feet: Vector2 = snapshot["pos"]
		for index in _scenery.size():
			var item := _scenery[index]
			if item["y"] > feet.y or (item["y"] == feet.y and item["id"] > "captain"):
				_captain_index = index
				break
	queue_redraw()


## 命中可见的队长本体，已被前方物件覆盖的像素继续交给原场景输入。
func captain_body_at(pos: Vector2) -> bool:
	if not bool(_snapshot.get("has_captain", false)) or pos.distance_to(_captain_center()) > _captain_radius:
		return false
	for index in range(_captain_index, _scenery.size()):
		if (_scenery[index]["rect"] as Rect2).has_point(pos):
			return false
	return true


func reason_text(reason: String) -> String:
	return String(REASON_TEXT.get(reason, ""))


func _text(pos: Vector2, text: String, size: int, color: Color, width: float = -1.0, align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT) -> void:
	draw_string(_font, pos, text, align, width, size, color)


## 地面提示先画，接着按接地点合并绘制物件和队长，世界名称最后画。
func _draw() -> void:
	draw_rect(Rect2(0, 0, 1920, 1080), Color("120d09"))
	if _layout.is_empty():
		return
	var bounds := _rect(_layout["bounds"])
	draw_rect(bounds, FLOOR)
	draw_rect(bounds, BOUNDS_LINE, false, 2.0)
	var hover := String(_snapshot.get("hover", ""))
	var pending := String(_snapshot.get("pending", ""))
	var has_captain := bool(_snapshot.get("has_captain", false))
	if has_captain:
		_draw_captain_path(_snapshot["pos"])
	for entry: Dictionary in _objects:
		var color: Color = OBJECT_COLOR.get(String(entry["kind"]), Color.WHITE)
		var approach := _point(entry["approach"])
		draw_arc(approach, float(entry["range"]), 0.0, TAU, 40, Color(color, 0.35 if String(entry["id"]) != pending else 0.9), 2.0)
	for index in _scenery.size():
		if has_captain and index == _captain_index:
			_draw_captain()
		_draw_scenery(_scenery[index], hover)
	if has_captain:
		if _captain_index == _scenery.size():
			_draw_captain()
		var center := _captain_center()
		var radius := Vector2.ONE * _captain_radius
		var body_bounds := Rect2(center - radius, radius * 2.0)
		# 只在单件前方物件完全覆盖角色时补轮廓，保留局部遮挡。
		for index in range(_captain_index, _scenery.size()):
			if (_scenery[index]["rect"] as Rect2).encloses(body_bounds):
				draw_arc(center, _captain_radius - 1.0, 0.0, TAU, 40, Color(1, 0.9, 0.67, 0.50), 2.0, true)
				break
		_text(center + Vector2(-60, -_captain_radius - 10), "队长", 16, Color(1, 1, 1, 0.8), 120.0, HORIZONTAL_ALIGNMENT_CENTER)
	for entry: Dictionary in _objects:
		var rect := _rect(entry)
		# 显示名称按既有 kind 与底部按钮统一，布局表的名称和 id 保持原样。
		var display_name := String(entry["name"])
		match String(entry["kind"]):
			"recruit":
				display_name = "招募伙伴"
			"prepare":
				display_name = "队伍整备"
			"sortie":
				display_name = "出征准备"
		_text(rect.position + Vector2(-40, -10), display_name, 24, Color.WHITE, rect.size.x + 80.0, HORIZONTAL_ALIGNMENT_CENTER)
	if _members == 0:
		_text(Vector2(24, 90), "还没有队伍，场景里没有队长。点下方「招募伙伴」，或点黄色公告板，招募第一名队员后队长就会出现。", 22, Color(1, 0.9, 0.6, 0.9))
	else:
		_text(Vector2(24, 54), "下一步：点「队伍整备」看装备和天赋，准备好后点「出征准备」。", 22, Color(1, 0.9, 0.6, 0.9))
		_text(Vector2(24, 90), "操作：左键点地走路 / 点方块走近后开面板，右键停步，Esc 退一层", 20, Color(1, 1, 1, 0.55))
	if _toast != "":
		_text(Vector2(0, 972), _toast, 30, Color(1, 0.85, 0.5), 1920.0, HORIZONTAL_ALIGNMENT_CENTER)


## 投影的上表面与前侧面覆盖显示矩形，原矩形下沿仍是物件的地面基准。
func _draw_scenery(item: Dictionary, hover: String) -> void:
	var rect: Rect2 = item["rect"]
	var kind: String = item["kind"]
	if not kind.is_empty():
		var color: Color = OBJECT_COLOR.get(kind, Color.WHITE)
		draw_rect(rect, color.darkened(0.35))
		draw_rect(rect, color, false, 3.0 if item["id"] != hover else 6.0)
		return
	var height: float = item["height"]
	draw_rect(rect, WALL)
	if height > 0.0:
		draw_rect(Rect2(Vector2(rect.position.x, rect.end.y - height), Vector2(rect.size.x, height)), WALL.darkened(0.25))


## 路径与落点沿用脚下地面坐标，先于本体和物件绘制。
func _draw_captain_path(feet: Vector2) -> void:
	if not bool(_snapshot.get("moving", false)):
		return
	var destination: Vector2 = _snapshot["destination"]
	var path: Array = _snapshot["path"]
	var last := feet
	for index in range(int(_snapshot["path_index"]), path.size()):
		draw_line(last, path[index], Color(1, 1, 1, 0.35), 2.0)
		last = path[index]
	draw_arc(destination, 14.0, 0.0, TAU, 24, Color(1, 0.9, 0.4, 0.9), 3.0)
	draw_circle(destination, 3.0, Color(1, 0.9, 0.4, 0.9))


## 灰盒圆形的下缘落在脚点，绘制和可见本体点击使用同一圆心。
func _captain_center() -> Vector2:
	return (_snapshot["pos"] as Vector2) - Vector2(0, _captain_radius)


## 在排序序列中只绘制队长本体与朝向。
func _draw_captain() -> void:
	var pos := _captain_center()
	var color := Color(String(_class_colors.get(String(_snapshot.get("class_id", "")), "ffffff")))
	draw_circle(pos, _captain_radius, color)
	draw_arc(pos, _captain_radius - 2.0, 0.0, TAU, 32, Color("3b2a1d"), 4.0)
	var facing := float(_snapshot.get("facing", 0.0))
	draw_line(pos, pos + Vector2.from_angle(facing) * (_captain_radius - 2.0), Color("3b2a1d"), 4.0)


func _rect(entry: Dictionary) -> Rect2:
	return Rect2(float(entry["x"]), float(entry["y"]), float(entry["w"]), float(entry["h"]))


func _point(entry: Dictionary) -> Vector2:
	return Vector2(float(entry["x"]), float(entry["y"]))
