extends Node2D
## 酒馆灰盒的画面：只读逻辑层给的快照（基本类型字典）来画，不碰逻辑对象。
## 图形全用引擎内置绘制，不引外部资源；面板、常驻栏是 scenes/ui/tavern_ui.gd 里的控件，不在这里画。

const FLOOR := Color("2b2118")
const WALL := Color("5a4330")
const BOUNDS_LINE := Color(1, 1, 1, 0.12)
const OBJECT_COLOR := {"recruit": Color("c9a24a"), "prepare": Color("4f8fe0"), "sortie": Color("c8553d")}
const REASON_TEXT := {
	"blocked": "这里无法到达",
	"unreachable": "无法到达该位置",
	"approach_unreachable": "无法靠近，请使用界面入口",
	"path_invalid": "路径失效，已停止",
}

var _font: Font = preload("res://scenes/ui/cjk_font.gd").get_font()
var _layout: Dictionary = {}
var _objects: Array = []
var _class_colors: Dictionary = {}
var _snapshot: Dictionary = {}
var _toast: String = ""
var _members: int = 0


## 布局和职业颜色只在开场给一次。
func configure(layout: Dictionary, class_colors: Dictionary) -> void:
	_layout = layout
	_class_colors = class_colors
	_objects = layout["objects"]
	queue_redraw()


func render(snapshot: Dictionary, toast: String, members: int) -> void:
	_snapshot = snapshot
	_toast = toast
	_members = members
	queue_redraw()


func reason_text(reason: String) -> String:
	return String(REASON_TEXT.get(reason, ""))


func _text(pos: Vector2, text: String, size: int, color: Color, width: float = -1.0, align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT) -> void:
	draw_string(_font, pos, text, align, width, size, color)


func _draw() -> void:
	draw_rect(Rect2(0, 0, 1920, 1080), Color("120d09"))
	if _layout.is_empty():
		return
	var bounds := _rect(_layout["bounds"])
	draw_rect(bounds, FLOOR)
	draw_rect(bounds, BOUNDS_LINE, false, 2.0)
	for entry: Dictionary in _layout["obstacles"]:
		draw_rect(_rect(entry), WALL)
		_text(_rect(entry).position + Vector2(8, 22), String(entry["id"]), 16, Color(1, 1, 1, 0.25))
	var hover := String(_snapshot.get("hover", ""))
	var pending := String(_snapshot.get("pending", ""))
	for entry: Dictionary in _objects:
		var rect := _rect(entry)
		var color: Color = OBJECT_COLOR.get(String(entry["kind"]), Color.WHITE)
		draw_rect(rect, color.darkened(0.35))
		draw_rect(rect, color, false, 3.0 if String(entry["id"]) != hover else 6.0)
		var approach := _point(entry["approach"])
		draw_arc(approach, float(entry["range"]), 0.0, TAU, 40, Color(color, 0.35 if String(entry["id"]) != pending else 0.9), 2.0)
		if String(entry["id"]) == hover or String(entry["id"]) == pending:
			_text(rect.position + Vector2(0, -10), String(entry["name"]), 24, Color.WHITE)
	_draw_captain()
	_text(Vector2(24, 54), "酒馆灰盒（P3b：面板与出征入口）", 22, Color(1, 1, 1, 0.55))
	if _members == 0:
		_text(Vector2(24, 90), "还没有队伍，场景里没有队长。点下方「招募伙伴」，或点黄色公告板，招募第一名队员后队长就会出现。", 22, Color(1, 0.9, 0.6, 0.9))
	else:
		_text(Vector2(24, 90), "操作：左键点地走路 / 点方块走近后开面板，右键停步，Esc 退一层", 20, Color(1, 1, 1, 0.55))
	if _toast != "":
		_text(Vector2(0, 972), _toast, 30, Color(1, 0.85, 0.5), 1920.0, HORIZONTAL_ALIGNMENT_CENTER)


func _draw_captain() -> void:
	if not bool(_snapshot.get("has_captain", false)):
		return
	var pos: Vector2 = _snapshot["pos"]
	var color := Color(String(_class_colors.get(String(_snapshot.get("class_id", "")), "ffffff")))
	if bool(_snapshot.get("moving", false)):
		var destination: Vector2 = _snapshot["destination"]
		var path: Array = _snapshot["path"]
		var last := pos
		for index in range(int(_snapshot["path_index"]), path.size()):
			draw_line(last, path[index], Color(1, 1, 1, 0.35), 2.0)
			last = path[index]
		draw_arc(destination, 14.0, 0.0, TAU, 24, Color(1, 0.9, 0.4, 0.9), 3.0)
		draw_circle(destination, 3.0, Color(1, 0.9, 0.4, 0.9))
	draw_circle(pos, 22.0, color)
	draw_arc(pos, 22.0, 0.0, TAU, 32, Color("3b2a1d"), 4.0)
	var facing := float(_snapshot.get("facing", 0.0))
	draw_line(pos, pos + Vector2.from_angle(facing) * 22.0, Color("3b2a1d"), 4.0)
	_text(pos + Vector2(-60, -32), "队长", 16, Color(1, 1, 1, 0.8), 120.0, HORIZONTAL_ALIGNMENT_CENTER)


func _rect(entry: Dictionary) -> Rect2:
	return Rect2(float(entry["x"]), float(entry["y"]), float(entry["w"]), float(entry["h"]))


func _point(entry: Dictionary) -> Vector2:
	return Vector2(float(entry["x"]), float(entry["y"]))
