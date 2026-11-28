extends Node2D
## 酒馆画面按布局绘制贴图，队长与落地物件按脚点 Y 排序。输入和面板仍由场景驱动。

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
var _captain_index: int = 0
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
	for entry: Dictionary in layout["layers"]:
		var texture := load(entry["texture"]) as Texture2D
		_background.append({"texture": texture, "position": TavernLayout.point_of(entry)})
	for entry: Dictionary in layout["obstacles"]:
		if not entry.has("texture"):
			continue
		var texture := load(entry["texture"]) as Texture2D
		var origin := TavernLayout.point_of(entry)
		var opaque := BitMap.new()
		opaque.create_from_image_alpha(texture.get_image(), 0.5)
		_scenery.append({
			"id": String(entry["id"]), "y": origin.y + float(entry["pivot_y"]),
			"rect": Rect2(origin, texture.get_size()), "texture": texture, "opaque": opaque
		})
	# 同 Y 用稳定 ID 决定覆盖关系，避免配置数组重排影响显示。
	_scenery.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["y"] < b["y"] if a["y"] != b["y"] else a["id"] < b["id"])
	queue_redraw()


## 以显示帧的接地点计算队长插入位置，绘制与可见本体命中共用这个顺序。
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


## 检测可见的队长本体，前方贴图的镂空和半透阴影仍可点到队长。
func captain_body_at(pos: Vector2) -> bool:
	if not bool(_snapshot.get("has_captain", false)):
		return false
	if pos.distance_to(_captain_center()) > _captain_radius:
		return false
	for index in range(_captain_index, _scenery.size()):
		var item := _scenery[index]
		var rect: Rect2 = item["rect"]
		if rect.has_point(pos) and (item["opaque"] as BitMap).get_bitv(Vector2i(pos - rect.position)):
			return false
	return true


## 脚下保留原有的点击半径，与可见本体共用本帧脚点。
func captain_at(pos: Vector2) -> bool:
	return bool(_snapshot.get("has_captain", false)) and (
		pos.distance_to(_snapshot["pos"]) <= _captain_radius or captain_body_at(pos))


func reason_text(reason: String) -> String:
	return String(REASON_TEXT.get(reason, ""))


## 文字沿用世界坐标，加深色描边以便在明暗不同的木纹上阅读。
func _text(pos: Vector2, text: String, size: int, color: Color, width: float = -1.0, align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT) -> void:
	draw_string_outline(_font, pos, text, align, width, size, 4, Color(0.14, 0.08, 0.04, 0.9))
	draw_string(_font, pos, text, align, width, size, color)


## 先绘制地板和固定背景，再将队长插入落地物件之间；文字提示置顶。
func _draw() -> void:
	if _background.is_empty():
		return
	for layer in _background:
		draw_texture(layer["texture"], layer["position"])
	var has_captain := bool(_snapshot.get("has_captain", false))
	if has_captain:
		_draw_captain_path(_snapshot["pos"])
	for index in _scenery.size():
		if has_captain and index == _captain_index:
			_draw_captain()
		var item := _scenery[index]
		draw_texture(item["texture"], (item["rect"] as Rect2).position)
	if has_captain:
		if _captain_index == _scenery.size():
			_draw_captain()
		var center := _captain_center()
		# 只在单个摆件遮住整个本体时保留原来的淡轮廓，部分遮挡直接由贴图显示。
		for index in range(_captain_index, _scenery.size()):
			if _covers_captain(_scenery[index], center):
				draw_arc(center, _captain_radius - 1.0, 0.0, TAU, 40, Color(1, 0.9, 0.67, 0.5), 2.0, true)
				break
		_text(center + Vector2(-60, -_captain_radius - 10), "队长", 16, Color.WHITE, 120.0, HORIZONTAL_ALIGNMENT_CENTER)
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
		_text(Vector2(24, 90), "左键点地走路，点场景入口走近后打开面板。右键停步，Esc 关闭面板。", 20, Color.WHITE)
	if _toast != "":
		_text(Vector2(0, 972), _toast, 30, Color(1, 0.85, 0.5), 1920.0, HORIZONTAL_ALIGNMENT_CENTER)


## 包围盒预筛后检测队长圆形内的贴图像素，避免告示牌脚间的镂空误判成全遮挡。
func _covers_captain(item: Dictionary, center: Vector2) -> bool:
	var rect: Rect2 = item["rect"]
	var radius := Vector2.ONE * _captain_radius
	if not rect.encloses(Rect2(center - radius, radius * 2.0)):
		return false
	var local := center - rect.position
	var mask: BitMap = item["opaque"]
	for y in range(ceili(local.y - _captain_radius), ceili(local.y + _captain_radius)):
		var width := sqrt(_captain_radius * _captain_radius - (y - local.y) ** 2)
		for x in range(ceili(local.x - width), ceili(local.x + width)):
			if not mask.get_bit(x, y):
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
