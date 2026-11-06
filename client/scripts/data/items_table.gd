extends RefCounted
## 物品表与职业/天赋清单的只读查询。数据来自 data/balance/（design/balance 的原样副本）。
## 这里不写任何物品 id 或数量，全部读表。

const ITEMS_PATH := "res://data/balance/items.json"
const CLASSES_PATH := "res://data/balance/classes.json"
const MODIFIERS_PATH := "res://data/balance/modifiers.json"
const BalanceLoader := preload("res://scripts/data/balance_loader.gd")

## 八个装备槽，顺序固定（与存档 equips 的键一致）。
var slots: Array[String] = []
var slot_names: Dictionary = {}  # slot id -> 中文名
var sets: Dictionary = {}        # set_id -> {name, class_id, pieces}
var items: Dictionary = {}       # id -> 行
var class_ids: Array[String] = []
var _modifier_rows: Array = []


## 读失败返回 false，原因进 push_error。
func load_tables(items_path: String = ITEMS_PATH) -> bool:
	var item_doc := _read(items_path)
	var class_doc := _read(CLASSES_PATH)
	var modifier_doc := _read(MODIFIERS_PATH)
	if item_doc.is_empty() or class_doc.is_empty() or modifier_doc.is_empty():
		return false
	slots.clear()
	slot_names.clear()
	for slot_id in (item_doc.get("_slots", {}) as Dictionary):
		slots.append(String(slot_id))
		slot_names[String(slot_id)] = String(item_doc["_slots"][slot_id])
	sets = (item_doc.get("_sets", {}) as Dictionary).duplicate(true)
	items.clear()
	for row: Dictionary in item_doc.get("rows", []):
		items[String(row["id"])] = row
	class_ids.clear()
	for key in class_doc:
		if not String(key).begins_with("_"):
			class_ids.append(String(key))
	_modifier_rows = modifier_doc.get("rows", [])
	return not slots.is_empty() and not items.is_empty() and not class_ids.is_empty()


## 某职业某组（talent / set）的修正行，给整备面板列收益和代价。
func modifier_rows(class_id: String, group: String) -> Array:
	var out: Array = []
	for row: Dictionary in _modifier_rows:
		if String(row["class_id"]) == class_id and String(row["group"]) == group:
			out.append(row)
	return out


func has_class(class_id: String) -> bool:
	return class_ids.has(class_id)


func has_item(item_id: String) -> bool:
	return items.has(item_id)


func item(item_id: String) -> Dictionary:
	return items.get(item_id, {})


## 该职业的初始装备 {slot: item_id}（source=initial）。
func initial_set(class_id: String) -> Dictionary:
	var out := {}
	for row: Dictionary in items.values():
		if String(row["class_id"]) == class_id and String(row["source"]) == "initial":
			out[String(row["slot"])] = String(row["id"])
	return out


## 该职业的奖励件 id 列表（source=reward），按 id 排序。
func reward_items(class_id: String) -> Array[String]:
	var out: Array[String] = []
	for row: Dictionary in items.values():
		if String(row["class_id"]) == class_id and String(row["source"]) == "reward":
			out.append(String(row["id"]))
	out.sort()
	return out


func all_reward_items() -> Array[String]:
	var out: Array[String] = []
	for class_id in class_ids:
		out.append_array(reward_items(class_id))
	return out


func talent_ids(class_id: String) -> Array[String]:
	return BalanceLoader.talent_ids(_modifier_rows, class_id)


func _read(path: String) -> Dictionary:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		push_error("表读不到：%s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("表不是 JSON 对象：%s" % path)
		return {}
	return parsed
