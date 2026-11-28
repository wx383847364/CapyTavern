extends Node2D
## 酒馆按布局分层，队长用显示帧的脚点与物件接地点或接地折线比较。

const TavernLayout := preload("res://scripts/data/tavern_layout.gd")
const OBJECT_NAMES := {"recruit": "招募伙伴", "prepare": "队伍整备", "sortie": "出征准备"}
const REASON_TEXT := {
	"blocked": "这里无法到达",
	"unreachable": "无法到达该位置",
	"approach_unreachable": "无法靠近，请使用界面入口",
	"path_invalid": "路径失效，已停止",
}

var _font: Font = preload("res://scenes/ui/cjk_font.gd").get_font()
var _objects: Array = []
var _background: Array[Dictionary] = []
var _scenery: Array[Dictionary] = []
var _foreground: Array[Dictionary] = []
var _behind_captain: Array[Dictionary] = []
var _in_front_of_captain: Array[Dictionary] = []
var _captain_fully_covered := false
var _captain_radius: float = 0.0
var _class_colors: Dictionary = {}
var _snapshot: Dictionary = {}
var _toast: String = ""
var _members: int = 0


## 加载原尺寸图层和落地贴图。透明像素用于点击遮挡检测，图片仅在初始化时读取。
func configure(layout: Dictionary, class_colors: Dictionary) -> void:
	_class_colors = class_colors
	_objects = layout["objects"]
	_captain_radius = float(layout["captain"]["radius"])
	_background.clear()
	_scenery.clear()
	_foreground.clear()
	for group: String in ["layers", "obstacles"]:
		for entry: Dictionary in layout[group]:
			if entry.has("texture"):
				_configure_layer(entry)
	# 同 Y 用稳定 ID 决定覆盖关系，避免配置数组重排影响显示。
	_scenery.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["y"] < b["y"] if a["y"] != b["y"] else a["id"] < b["id"])
	_behind_captain.assign(_scenery)
	_in_front_of_captain.assign(_foreground)
	queue_redraw()


## 加载一张贴图。遮挡层预存实像素遮罩，折线在初始化时换算为场景坐标。
func _configure_layer(entry: Dictionary) -> void:
	var texture := load(entry["texture"]) as Texture2D
	var origin := TavernLayout.point_of(entry)
	var is_foreground: bool = entry.get("foreground", false)
	if not is_foreground and not entry.has("pivot_y") and not entry.has("sort_edge"):
		_background.append({"texture": texture, "position": origin})
		return
	var opaque := BitMap.new()
	opaque.create_from_image_alpha(texture.get_image(), 0.5)
	var item := {"rect": Rect2(origin, texture.get_size()), "texture": texture, "opaque": opaque}
	if is_foreground:
		_foreground.append(item)
		return
	var edge := PackedVector2Array()
	var reference_y := origin.y + float(entry.get("pivot_y", 0.0))
	if entry.has("sort_edge"):
		reference_y = -INF
		for pair: Array in entry["sort_edge"]:
			var point := origin + Vector2(float(pair[0]), float(pair[1]))
			edge.append(point)
			reference_y = maxf(reference_y, point.y)
	item["id"] = String(entry["id"])
	item["y"] = reference_y
	item["edge"] = edge
	_scenery.append(item)


## 取物件在脚点 X 的接地 Y。走出折线端点时沿用端点，角色绕角仍能连续切换前后。
func _sort_y(item: Dictionary, feet_x: float) -> float:
	var edge: PackedVector2Array = item["edge"]
	if edge.is_empty():
		return item["y"]
	if feet_x <= edge[0].x:
		return edge[0].y
	for index in range(1, edge.size()):
		var end := edge[index]
		if feet_x <= end.x:
			var start := edge[index - 1]
			return lerpf(start.y, end.y, inverse_lerp(start.x, end.x, feet_x))
	return edge[-1].y


## 按本帧接地点划分角色前后物件，绘制、命中和全遮挡提示共享结果。
func render(snapshot: Dictionary, toast: String, members: int) -> void:
	_snapshot = snapshot
	_toast = toast
	_members = members
	_behind_captain.clear()
	_in_front_of_captain.clear()
	_captain_fully_covered = false
	var has_captain := bool(snapshot.get("has_captain", false))
	if has_captain:
		var feet: Vector2 = snapshot["pos"]
		# 预筛范围含角色本体、头顶名牌与脚下的点击圆。远处物件无需约束角色顺序。
		var reach_x := maxf(60.0, _captain_radius)
		var reach_up := _captain_radius * 2.0 + 30.0
		var actor_rect := Rect2(feet - Vector2(reach_x, reach_up), Vector2(reach_x * 2.0, reach_up + _captain_radius))
		for item in _scenery:
			var rect: Rect2 = item["rect"]
			var in_front := rect.intersects(actor_rect) and feet.y < _sort_y(item, feet.x)
			if not in_front:
				# 此贴图在之前的前景件上方。两张图相叠时一并进前景，保持物件覆盖顺序。
				for other in _in_front_of_captain:
					if rect.intersects(other["rect"]):
						in_front = true
						break
			if in_front:
				_in_front_of_captain.append(item)
			else:
				_behind_captain.append(item)
	else:
		_behind_captain.assign(_scenery)
	_in_front_of_captain.append_array(_foreground)
	if has_captain:
		_captain_fully_covered = _covers_captain(_captain_center())
	queue_redraw()


## 检测可见的队长本体，前方贴图的镂空和半透阴影仍可点到队长。
func captain_body_at(pos: Vector2) -> bool:
	return bool(_snapshot.get("has_captain", false)) and pos.distance_to(_captain_center()) <= _captain_radius and not _foreground_at(pos)


## 脚下和本体保留原有点击半径。前方实像素覆盖的位置留给物件交互。
func captain_at(pos: Vector2) -> bool:
	return bool(_snapshot.get("has_captain", false)) and (
		pos.distance_to(_snapshot["pos"]) <= _captain_radius or pos.distance_to(_captain_center()) <= _captain_radius
	) and not _foreground_at(pos)


func reason_text(reason: String) -> String:
	return String(REASON_TEXT.get(reason, ""))


## 文字沿用世界坐标，加深色描边以便在明暗不同的木纹上阅读。
func _text(pos: Vector2, text: String, size: int, color: Color, width: float = -1.0, align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT) -> void:
	draw_string_outline(_font, pos, text, align, width, size, 4, Color(0.14, 0.08, 0.04, 0.9))
	draw_string(_font, pos, text, align, width, size, color)


## 地板和路径在最下方，角色和名字一起参与遮挡，交互名称及提示绘制在世界画面之上。
func _draw() -> void:
	for layer in _background:
		draw_texture(layer["texture"], layer["position"])
	var has_captain := bool(_snapshot.get("has_captain", false))
	if has_captain:
		_draw_captain_path(_snapshot["pos"])
	for item in _behind_captain:
		draw_texture(item["texture"], (item["rect"] as Rect2).position)
	if has_captain:
		_draw_captain()
		if not _captain_fully_covered:
			_text(_captain_center() + Vector2(-60, -_captain_radius - 10), "队长", 16, Color.WHITE, 120.0, HORIZONTAL_ALIGNMENT_CENTER)
	for item in _in_front_of_captain:
		draw_texture(item["texture"], (item["rect"] as Rect2).position)
	if has_captain and _captain_fully_covered:
		draw_arc(_captain_center(), _captain_radius - 1.0, 0.0, TAU, 40, Color(1, 0.9, 0.67, 0.5), 2.0, true)
	var hover := String(_snapshot.get("hover", ""))
	var pending := String(_snapshot.get("pending", ""))
	for entry: Dictionary in _objects:
		var rect := TavernLayout.rect_of(entry)
		var name := String(OBJECT_NAMES.get(entry["kind"], entry["name"]))
		var color := Color("ffda7d") if entry["id"] == hover or entry["id"] == pending else Color.WHITE
		_text(rect.position + Vector2(0, 24), name, 22, color, rect.size.x, HORIZONTAL_ALIGNMENT_CENTER)
	if _members == 0:
		_text(Vector2(24, 54), "点击公告板或下方「招募伙伴」，招募第一名队员后队长就会出现。", 22, Color("ffe5ac"))
	else:
		_text(Vector2(24, 54), "下一步：点「队伍整备」看装备和天赋，准备好后点「出征准备」。", 22, Color("ffe5ac"))
		_text(Vector2(24, 90), "右键点地走路，方向键／左摇杆走位。左键点场景入口交互，Esc 关闭面板。", 20, Color.WHITE)
	if _toast != "":
		_text(Vector2(0, 972), _toast, 30, Color(1, 0.85, 0.5), 1920.0, HORIZONTAL_ALIGNMENT_CENTER)


## 只检测排在队长前方的实像素。镂空和半透明阴影不消费队长点击。
func _foreground_at(pos: Vector2) -> bool:
	for item in _in_front_of_captain:
		var rect: Rect2 = item["rect"]
		if rect.has_point(pos) and (item["opaque"] as BitMap).get_bitv(Vector2i(pos - rect.position)):
			return true
	return false


## 用前景遮罩的并集检查本体圆，只有全部像素被挡时才切换为淡轮廓。
func _covers_captain(center: Vector2) -> bool:
	if not _foreground_at(center):
		return false
	for y in range(ceili(center.y - _captain_radius), ceili(center.y + _captain_radius)):
		var width := sqrt(_captain_radius * _captain_radius - (y - center.y) ** 2)
		for x in range(ceili(center.x - width), ceili(center.x + width)):
			if not _foreground_at(Vector2(x, y)):
				return false
	return true


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
