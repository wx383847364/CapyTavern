extends RefCounted
## 读 client/data/tavern_layout.json 并校验。酒馆的位置、障碍、交互点都从这里来，脚本里不写死。

const PATH := "res://data/tavern_layout.json"
const KINDS: Array[String] = ["recruit", "prepare", "sortie"]


## 读不到或不是对象返回空字典。
static func load_layout(path: String = PATH) -> Dictionary:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		push_error("酒馆布局读不到：%s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("酒馆布局不是 JSON 对象：%s" % path)
		return {}
	return parsed


static func rect_of(entry: Dictionary) -> Rect2:
	return Rect2(float(entry["x"]), float(entry["y"]), float(entry["w"]), float(entry["h"]))


static func point_of(entry: Dictionary) -> Vector2:
	return Vector2(float(entry["x"]), float(entry["y"]))


## 把贴图局部的占地点换算成场景坐标，物件移位时占地跟随贴图。
static func polygon_of(entry: Dictionary) -> PackedVector2Array:
	var origin := point_of(entry)
	var points := PackedVector2Array()
	for pair: Array in entry["polygon"]:
		points.append(origin + Vector2(float(pair[0]), float(pair[1])))
	return points


## 返回布局与分层配置的问题。落点能否到达由调用方建好导航后检查。
static func validate(layout: Dictionary) -> PackedStringArray:
	var problems := PackedStringArray()
	for key in ["bounds", "cell", "captain", "spawn", "default_pos", "arrive_eps", "layers", "obstacles", "objects"]:
		if not layout.has(key):
			problems.append("缺字段 %s" % key)
	if not problems.is_empty():
		return problems
	var scenery_ids := {}
	for group: String in ["layers", "obstacles"]:
		for entry: Dictionary in layout[group]:
			_validate_render_layer(entry, group, scenery_ids, problems)
	for entry: Dictionary in layout["obstacles"]:
		if not entry.has("polygon"):
			continue
		var polygon: Variant = entry["polygon"]
		if not polygon is Array or polygon.size() < 3:
			problems.append("物件 %s 的占地多边形至少需要三个点" % entry.get("id", "?"))
			continue
		for pair: Variant in polygon:
			if not pair is Array or pair.size() != 2:
				problems.append("物件 %s 的占地点需要 [x, y]" % entry.get("id", "?"))
				break
	var kinds_seen := {}
	for entry: Dictionary in layout["objects"]:
		var kind := String(entry.get("kind", ""))
		if not KINDS.has(kind):
			problems.append("交互点 %s 的 kind=%s 不在 recruit/prepare/sortie 里" % [entry.get("id", "?"), kind])
		kinds_seen[kind] = true
		for key in ["id", "name", "x", "y", "w", "h", "approach", "range"]:
			if not entry.has(key):
				problems.append("交互点 %s 缺字段 %s" % [entry.get("id", "?"), key])
	for kind in KINDS:
		if not kinds_seen.has(kind):
			problems.append("缺少 %s 交互点" % kind)
	if float(layout["cell"]) <= 0.0:
		problems.append("cell 必须大于 0")
	return problems


## 校验贴图的排序方式与唯一 ID。固定图层、可排序装饰与纯碰撞允许分别配置。
static func _validate_render_layer(entry: Dictionary, group: String, ids: Dictionary, problems: PackedStringArray) -> void:
	var label: String = str(entry.get("id", entry.get("texture", "?")))
	var has_pivot := entry.has("pivot_y")
	var has_edge := entry.has("sort_edge")
	var has_sort := has_pivot or has_edge
	var foreground: Variant = entry.get("foreground", false)
	var texture: Variant = entry.get("texture", "")
	var textured: bool = texture is String and not texture.strip_edges().is_empty()
	if not textured and (group == "layers" or entry.has("texture") or has_sort):
		problems.append("物件 %s 的 texture 需要非空路径" % label)
	if entry.has("foreground") and (group != "layers" or foreground is not bool):
		problems.append("物件 %s 的 foreground 只能在 layers 使用布尔值" % label)
	elif foreground == true and has_sort:
		problems.append("物件 %s 的 foreground 与 pivot_y、sort_edge 互斥" % label)
	if (has_pivot and has_edge) or (group == "obstacles" and textured and not has_sort):
		problems.append("物件 %s 的 pivot_y、sort_edge 需要二选一" % label)
	if not has_sort:
		return
	var id: Variant = entry.get("id", "")
	if id is not String or id.strip_edges().is_empty() or ids.has(id):
		problems.append("物件 %s 的排序 id 需要非空且唯一" % label)
	else:
		ids[id] = true
	if has_pivot and not _is_coordinate(entry["pivot_y"]):
		problems.append("物件 %s 的 pivot_y 需要有限数值" % label)
	if has_edge:
		var edge: Variant = entry["sort_edge"]
		if edge is not Array or edge.size() < 2:
			problems.append("物件 %s 的 sort_edge 至少需要两个 [x, y] 点" % label)
			return
		var previous_x := -INF
		for pair: Variant in edge:
			if pair is not Array or pair.size() != 2 or not _is_coordinate(pair[0]) or not _is_coordinate(pair[1]) or float(pair[0]) <= previous_x:
				problems.append("物件 %s 的 sort_edge 需要有限的 [x, y] 数值且 X 严格递增" % label)
				return
			previous_x = float(pair[0])


## 布局坐标只接受有限的 JSON 数值，避免字符串被静默转换成零。
static func _is_coordinate(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))
