extends Node2D
## 战斗灰盒的画面：只读逻辑层给的快照（基本类型字典）来画，不碰结算对象，
## 也不调用玩法脚本。图形全用引擎内置绘制，不引外部资源。

const PORTRAIT_X := 16.0
const PORTRAIT_Y := 96.0
const PORTRAIT_W := 270.0
const PORTRAIT_H := 84.0
const PORTRAIT_GAP := 10.0
const SKILL_W := 196.0
const SKILL_H := 96.0
const SKILL_GAP := 12.0
const SKILL_Y := 962.0
const BACK_BUTTON := Rect2(830, 650, 260, 70)

const REASON_TEXT := {
	"no_target": "没有目标",
	"out_of_range": "距离不足",
	"cooldown": "冷却中",
	"gcd": "公共冷却中",
	"no_resource": "资源不足",
	"unit_down": "已倒下",
	"paused": "战斗已暂停",
}
const RESOURCE_COLOR := {"rage": Color("c8553d"), "energy": Color("e0b341"), "mana": Color("4f8fe0")}
const RESOURCE_NAME := {"rage": "怒气", "energy": "能量", "mana": "法力"}
const STATUS_COLOR := {"mitigate": Color("5ab0ff"), "haste": Color("ffd54a"), "taunt": Color("ff5a5a")}
const RESULT_REASON := {
	"all_enemies_down": "敌人全部倒下",
	"all_allies_down": "出战成员全部倒下",
	"timeout": "120 秒内没打完",
}

var _snap: Dictionary = {}
var _selected_slot: int = -1
var _back_text: String = "返回（Enter）"
var _notice: String = ""
var _toast: String = ""
var _log_path: String = ""
var _font: Font = preload("res://scenes/ui/cjk_font.gd").get_font()


func render(snapshot: Dictionary, selected_slot: int, toast: String, log_path: String) -> void:
	_snap = snapshot
	_selected_slot = selected_slot
	_toast = toast
	_log_path = log_path
	queue_redraw()


## 出征进来的战斗：返回按钮写「回酒馆」。结果页底部的提示（如保存失败）用 set_notice。
func set_back_text(text: String) -> void:
	_back_text = text


func set_notice(text: String) -> void:
	_notice = text
	queue_redraw()


func reason_text(reason: String) -> String:
	return String(REASON_TEXT.get(reason, reason))


## 点击落在哪块界面上。空字典表示点在战场上。
func hit_test(pos: Vector2) -> Dictionary:
	if _snap.is_empty():
		return {}
	if bool(_snap["finished"]):
		return {"kind": "back"} if BACK_BUTTON.has_point(pos) else {"kind": "hud"}
	for slot_index in 4:
		if _portrait_rect(slot_index).has_point(pos):
			return {"kind": "portrait", "slot": slot_index}
	for index in 4:
		if _skill_rect(index).has_point(pos):
			return {"kind": "skill", "key": ["q", "w", "e", "r"][index]}
	var bar := Rect2(_skill_rect(0).position.x - 8, SKILL_Y - 8, 4 * SKILL_W + 3 * SKILL_GAP + 16, SKILL_H + 16)
	var panel := Rect2(PORTRAIT_X - 8, PORTRAIT_Y - 8, PORTRAIT_W + 16, 4 * PORTRAIT_H + 3 * PORTRAIT_GAP + 16)
	if bar.has_point(pos) or panel.has_point(pos):
		return {"kind": "hud"}
	return {}


func _portrait_rect(slot_index: int) -> Rect2:
	return Rect2(PORTRAIT_X, PORTRAIT_Y + slot_index * (PORTRAIT_H + PORTRAIT_GAP), PORTRAIT_W, PORTRAIT_H)


func _skill_rect(index: int) -> Rect2:
	var total := 4.0 * SKILL_W + 3.0 * SKILL_GAP
	var start_x := (1920.0 - total) * 0.5
	return Rect2(start_x + index * (SKILL_W + SKILL_GAP), SKILL_Y, SKILL_W, SKILL_H)


func _text(pos: Vector2, text: String, size: int, color: Color, width: float = -1.0, align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT) -> void:
	draw_string(_font, pos, text, align, width, size, color)


func _draw() -> void:
	if _snap.is_empty():
		return
	var arena: Rect2 = _snap["arena"]
	draw_rect(arena, Color("1b2430"))
	draw_rect(arena.grow(-6), Color("233040"), false, 2.0)
	var units: Array = _snap["units"]
	var by_id: Dictionary = {}
	for unit: Dictionary in units:
		by_id[unit["id"]] = unit
	_draw_telegraphs(units)
	var selected: Dictionary = {}
	for unit: Dictionary in units:
		if unit["side"] == "ally" and int(unit["slot"]) == _selected_slot:
			selected = unit
	if not selected.is_empty() and bool(selected["alive"]):
		_draw_orders(selected, by_id)
	for unit: Dictionary in units:
		_draw_unit(unit, not selected.is_empty() and unit["id"] == selected["id"])
	_draw_portraits(units)
	_draw_skill_bar(selected)
	_draw_top()
	if _toast != "":
		_text(Vector2(0, 930), _toast, 30, Color("ffd9a0"), 1920.0, HORIZONTAL_ALIGNMENT_CENTER)
	if bool(_snap["finished"]):
		_draw_result()


func _draw_telegraphs(units: Array) -> void:
	for unit: Dictionary in units:
		var cast: Dictionary = unit["cast"]
		if cast.is_empty():
			continue
		var radius: float = cast["radius"]
		if radius <= 0.0:
			continue
		var center: Vector2 = cast["center"]
		var progress: float = cast["progress"]
		draw_circle(center, radius, Color(0.9, 0.2, 0.2, 0.12))
		draw_circle(center, radius * progress, Color(0.9, 0.2, 0.2, 0.25))
		draw_arc(center, radius, 0.0, TAU, 48, Color(1.0, 0.35, 0.35, 0.9), 3.0)


func _draw_orders(selected: Dictionary, by_id: Dictionary) -> void:
	var pos: Vector2 = selected["pos"]
	var order_kind: String = selected["order_kind"]
	if order_kind == "move":
		var dest: Vector2 = selected["order_pos"]
		draw_line(pos, dest, Color(1, 1, 1, 0.35), 2.0)
		draw_arc(dest, 12.0, 0.0, TAU, 24, Color("ffffff"), 2.0)
		draw_line(dest + Vector2(-6, 0), dest + Vector2(6, 0), Color("ffffff"), 2.0)
		draw_line(dest + Vector2(0, -6), dest + Vector2(0, 6), Color("ffffff"), 2.0)
	var target_id: int = selected["target_id"]
	if target_id >= 0 and by_id.has(target_id):
		var target: Dictionary = by_id[target_id]
		if bool(target["alive"]):
			var color := Color("6fe08a") if selected["attack_kind"] == "heal" else Color("ffd54a")
			draw_line(pos, target["pos"], Color(color.r, color.g, color.b, 0.7), 2.0)
			draw_arc(target["pos"], float(target["radius"]) + 7.0, 0.0, TAU, 32, color, 2.0)


func _draw_unit(unit: Dictionary, is_selected: bool) -> void:
	var pos: Vector2 = unit["pos"]
	var radius: float = unit["radius"]
	var alive: bool = unit["alive"]
	var color := Color.html(String(unit["color"]))
	if not alive:
		color = Color(0.35, 0.35, 0.38)
	var enemy: bool = unit["side"] == "enemy"
	if enemy and unit["kind"] == "caster":
		var points := PackedVector2Array([pos + Vector2(0, -radius), pos + Vector2(radius, 0), pos + Vector2(0, radius), pos + Vector2(-radius, 0)])
		draw_colored_polygon(points, color)
	else:
		draw_circle(pos, radius, color)
		if enemy and unit["kind"] == "elite":
			draw_arc(pos, radius + 3.0, 0.0, TAU, 40, Color("ffb347"), 4.0)
	if not alive:
		draw_line(pos + Vector2(-radius, -radius) * 0.6, pos + Vector2(radius, radius) * 0.6, Color(0.1, 0.1, 0.1), 4.0)
		draw_line(pos + Vector2(radius, -radius) * 0.6, pos + Vector2(-radius, radius) * 0.6, Color(0.1, 0.1, 0.1), 4.0)
		return
	if is_selected:
		draw_arc(pos, radius + 6.0, 0.0, TAU, 40, Color.WHITE, 3.0)
	if not enemy:
		_text(pos + Vector2(-8, 8), str(int(unit["slot"]) + 1), 24, Color(0.05, 0.05, 0.08), 16.0, HORIZONTAL_ALIGNMENT_CENTER)
	var bar_w := maxf(54.0, radius * 2.4)
	var bar_pos := pos + Vector2(-bar_w * 0.5, -radius - 16.0)
	var ratio := float(unit["hp"]) / float(unit["max_hp"])
	draw_rect(Rect2(bar_pos, Vector2(bar_w, 7)), Color(0, 0, 0, 0.7))
	draw_rect(Rect2(bar_pos, Vector2(bar_w * ratio, 7)), Color("6fe08a") if not enemy else Color("e86a6a"))
	var cast: Dictionary = unit["cast"]
	if not cast.is_empty():
		var cast_pos := bar_pos + Vector2(0, -12)
		draw_rect(Rect2(cast_pos, Vector2(bar_w, 7)), Color(0, 0, 0, 0.7))
		var cast_color := Color("ffcf5a") if cast["interruptible"] else Color("ff6b6b")
		draw_rect(Rect2(cast_pos, Vector2(bar_w * float(cast["progress"]), 7)), cast_color)
		_text(cast_pos + Vector2(0, -4), String(cast["name"]), 15, cast_color, bar_w, HORIZONTAL_ALIGNMENT_CENTER)
	var status_x := bar_pos.x
	for status_id: String in unit["statuses"]:
		draw_circle(Vector2(status_x + 5.0, pos.y + radius + 12.0), 5.0, STATUS_COLOR.get(status_id, Color.WHITE))
		status_x += 14.0
	_text(pos + Vector2(-50, radius + 34.0), String(unit["name"]), 16, Color(1, 1, 1, 0.8), 100.0, HORIZONTAL_ALIGNMENT_CENTER)


func _draw_portraits(units: Array) -> void:
	var by_slot: Dictionary = {}
	for unit: Dictionary in units:
		if unit["side"] == "ally":
			by_slot[int(unit["slot"])] = unit
	for slot_index in 4:
		var rect := _portrait_rect(slot_index)
		var unit: Dictionary = by_slot.get(slot_index, {})
		var selected := slot_index == _selected_slot and not unit.is_empty()
		draw_rect(rect, Color(0.06, 0.08, 0.12, 0.85))
		draw_rect(rect, Color.WHITE if selected else Color(1, 1, 1, 0.15), false, 3.0 if selected else 1.0)
		_text(rect.position + Vector2(10, 30), str(slot_index + 1), 26, Color(1, 1, 1, 0.9))
		if unit.is_empty():
			_text(rect.position + Vector2(50, 50), "空槽", 22, Color(1, 1, 1, 0.3))
			continue
		var alive: bool = unit["alive"]
		var color := Color.html(String(unit["color"]))
		draw_circle(rect.position + Vector2(52, 42), 22.0, color if alive else Color(0.3, 0.3, 0.33))
		_text(rect.position + Vector2(86, 30), String(unit["name"]) + ("  倒下" if not alive else ""), 20, Color.WHITE if alive else Color(1, 1, 1, 0.4))
		var ratio := float(unit["hp"]) / float(unit["max_hp"])
		draw_rect(Rect2(rect.position + Vector2(86, 40), Vector2(170, 10)), Color(0, 0, 0, 0.7))
		draw_rect(Rect2(rect.position + Vector2(86, 40), Vector2(170 * ratio, 10)), Color("6fe08a"))
		var res_ratio := float(unit["res"]) / maxf(1.0, float(unit["res_max"]))
		draw_rect(Rect2(rect.position + Vector2(86, 56), Vector2(170, 8)), Color(0, 0, 0, 0.7))
		draw_rect(Rect2(rect.position + Vector2(86, 56), Vector2(170 * res_ratio, 8)), RESOURCE_COLOR.get(unit["res_kind"], Color.GRAY))
		_text(rect.position + Vector2(86, 78), "%d/%d  %s %d" % [unit["hp"], unit["max_hp"], RESOURCE_NAME.get(unit["res_kind"], ""), int(unit["res"])], 13, Color(1, 1, 1, 0.65))


func _draw_skill_bar(selected: Dictionary) -> void:
	var views: Array = []
	if not selected.is_empty():
		views = _snap["skills"].get(selected["id"], [])
	for index in 4:
		var rect := _skill_rect(index)
		draw_rect(rect, Color(0.06, 0.08, 0.12, 0.9))
		var view: Dictionary = views[index] if index < views.size() else {}
		if view.is_empty():
			draw_rect(rect, Color(1, 1, 1, 0.1), false, 1.0)
			continue
		var reason: String = view["reason"]
		var cd_left: float = view["cd_left"]
		var usable := reason == ""
		draw_rect(rect, Color(1, 1, 1, 0.9) if usable else Color(1, 1, 1, 0.2), false, 2.0)
		_text(rect.position + Vector2(10, 34), String(view["key"]).to_upper(), 30, Color.WHITE if usable else Color(1, 1, 1, 0.45))
		_text(rect.position + Vector2(52, 30), String(view["name"]), 22, Color.WHITE if usable else Color(1, 1, 1, 0.45))
		var cost_text := "无消耗" if float(view["cost"]) <= 0.0 else "耗 %d %s" % [int(view["cost"]), RESOURCE_NAME.get(selected["res_kind"], "")]
		_text(rect.position + Vector2(10, 62), cost_text, 16, Color(1, 1, 1, 0.7))
		_text(rect.position + Vector2(10, 84), "冷却 %ds" % int(view["cooldown"]), 14, Color(1, 1, 1, 0.5))
		if cd_left > 0.0:
			var fraction := clampf(cd_left / maxf(0.01, float(view["cooldown"])), 0.0, 1.0)
			draw_rect(Rect2(rect.position, Vector2(rect.size.x, rect.size.y * fraction)), Color(0, 0, 0, 0.55))
			_text(rect.position + Vector2(rect.size.x - 60, 60), "%.1f" % cd_left, 26, Color("ffd9a0"), 50.0, HORIZONTAL_ALIGNMENT_RIGHT)
		elif not usable:
			_text(rect.position + Vector2(rect.size.x - 100, 84), String(REASON_TEXT.get(reason, reason)), 14, Color("ff9a9a"), 90.0, HORIZONTAL_ALIGNMENT_RIGHT)


func _draw_top() -> void:
	var left := maxf(0.0, float(_snap["limit"]) - float(_snap["time"]))
	var minutes := int(left) / 60
	var seconds := int(left) % 60
	_text(Vector2(0, 54), "剩余 %d:%02d" % [minutes, seconds], 34, Color.WHITE, 1920.0, HORIZONTAL_ALIGNMENT_CENTER)
	_text(Vector2(24, 54), "战斗灰盒（数值 v0.1，待复核）", 22, Color(1, 1, 1, 0.55))
	if bool(_snap["paused"]):
		draw_rect(Rect2(660, 380, 600, 120), Color(0, 0, 0, 0.7))
		_text(Vector2(660, 442), "已暂停  按 P 继续", 40, Color("ffd9a0"), 600.0, HORIZONTAL_ALIGNMENT_CENTER)


func _draw_result() -> void:
	draw_rect(Rect2(0, 0, 1920, 1080), Color(0, 0, 0, 0.6))
	var won: bool = _snap["result"] == "win"
	var title_color := Color("6fe08a") if won else Color("ff6b6b")
	_text(Vector2(0, 460), "胜利" if won else "失败", 96, title_color, 1920.0, HORIZONTAL_ALIGNMENT_CENTER)
	_text(Vector2(0, 520), String(RESULT_REASON.get(_snap["reason"], _snap["reason"])), 30, Color.WHITE, 1920.0, HORIZONTAL_ALIGNMENT_CENTER)
	_text(Vector2(0, 566), "用时 %.1f 秒" % float(_snap["time"]), 26, Color(1, 1, 1, 0.8), 1920.0, HORIZONTAL_ALIGNMENT_CENTER)
	if _log_path != "":
		_text(Vector2(0, 606), "结算日志：" + _log_path, 18, Color(1, 1, 1, 0.5), 1920.0, HORIZONTAL_ALIGNMENT_CENTER)
	if _notice != "":
		_text(Vector2(0, 660), _notice, 30, Color("ffb070"), 1920.0, HORIZONTAL_ALIGNMENT_CENTER)
	draw_rect(BACK_BUTTON, Color(0.15, 0.2, 0.3, 0.95))
	draw_rect(BACK_BUTTON, Color.WHITE, false, 2.0)
	_text(BACK_BUTTON.position + Vector2(0, 46), _back_text, 28, Color.WHITE, BACK_BUTTON.size.x, HORIZONTAL_ALIGNMENT_CENTER)
