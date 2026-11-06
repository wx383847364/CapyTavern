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


## 返回问题列表，空表示可用。几何上的检查（落点是否可走）在 TavernNav 建好以后由调用方补。
static func validate(layout: Dictionary) -> PackedStringArray:
	var problems := PackedStringArray()
	for key in ["bounds", "cell", "captain", "spawn", "default_pos", "arrive_eps", "obstacles", "objects"]:
		if not layout.has(key):
			problems.append("缺字段 %s" % key)
	if not problems.is_empty():
		return problems
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
