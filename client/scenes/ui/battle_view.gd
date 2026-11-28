extends Node2D
## 矿洞、战场单位和 HUD 分层绘制。界面只读战斗快照，绘制和输入共用控件位置。

const MINE_BACKDROP := preload("res://assets/art/battle/00_mine_backdrop.png")
const MINE_FLOOR := preload("res://assets/art/battle/01_walk_floor.png")
const MINE_FOREGROUND := preload("res://assets/art/battle/02_mine_foreground.png")
const HUD_ATLAS := preload("res://assets/ui/battle/hud_atlas.png")
const TEXTURE_TARGET := Rect2(416, 2, 454, 82)
const TEXTURE_TARGET_OF_TARGET := Rect2(416, 88, 292, 82)
const TEXTURE_METER := Rect2(416, 176, 262, 181)
const TEXTURE_ROW := Rect2(416, 362, 186, 41)
const TEXTURE_HP_TRACK := Rect2(416, 407, 152, 36)
const TEXTURE_HP_GREEN := Rect2(416, 447, 144, 24)
const TEXTURE_HP_RED := Rect2(416, 475, 144, 24)
const TEXTURE_RETREAT := Rect2(2, 502, 110, 90)
const TEXTURE_KEYCAP := Rect2(118, 502, 34, 34)
const TEXTURE_ELITE := Rect2(158, 502, 42, 48)
const TEXTURE_MAGE := Rect2(208, 502, 42, 48)
const FLOOR_ORIGIN := Vector2(0, 270)
const FOREGROUND_ORIGIN := Vector2(0, 824)
const CLASS_ATLAS_ROW := {"rogue": 0, "warrior": 1, "mage": 2, "priest": 3}
const SKILL_KEYS := ["Q", "W", "E", "R"]
const PORTRAIT_X := 35.0
const PORTRAIT_Y := 20.0
const PORTRAIT_W := 393.0
const PORTRAIT_H := 47.0
const SKILL_W := 87.0
const SKILL_H := 103.0
const SKILL_GAP := 4.0
const SKILL_Y := 956.0
const BACK_BUTTON := Rect2(830, 650, 260, 70)
const TARGET_BAR := Rect2(596, 11, 454, 82)
const TARGET_OF_TARGET_BAR := Rect2(1057, 11, 292, 82)
const OUTPUT_PANEL := Rect2(1375, 15, 253, 181)
const THREAT_PANEL := Rect2(1633, 15, 262, 181)
const SETTINGS_BUTTON := Rect2(535, 108, 92, 37)
const RETREAT_BUTTON := Rect2(1784, 942, 110, 120)
const SETTINGS_PANEL := Rect2(658, 331, 604, 533)
const SETTINGS_CLOSE := Rect2(1101, 799, 125, 40)
const DisplayPreferences := preload("res://scripts/input/battle_controller.gd")
const SETTINGS_OPTIONS := ["names", "release_cast", "tab_health"]
const HIT_FLASH_MS := 100
const CRITICAL_RING_MS := 150
const COMBAT_NUMBER_MS := 720

const REASON_TEXT := {
	"no_target": "没有目标",
	"out_of_range": "距离不足",
	"cooldown": "冷却中",
	"gcd": "公共冷却中",
	"no_resource": "资源不足",
	"unit_down": "已倒下",
	"paused": "战斗已暂停",
	"EMPTY_SLOT": "空槽", "NOT_IMPLEMENTED": "未接入", "STALE_BATTLE": "场次失效",
	"NO_CASTER": "无角色", "CASTER_DOWN": "已倒下", "BATTLE_PAUSED": "已暂停",
	"INPUT_LOCKED": "输入关闭", "SKILL_CHANGED": "技能已变化", "CONFIG_ERROR": "配置异常",
	"INVALID_TARGET": "目标无效", "OUT_OF_RANGE": "距离不足", "NOT_ENOUGH_MANA": "法力不足",
	"GCD_ACTIVE": "公共冷却中", "SKILL_COOLDOWN": "技能冷却中",
	"DUPLICATE_REQUEST": "请求重复", "INVALID_REQUEST": "请求无效",
	"CAST_IN_PROGRESS": "正在施法", "CAST_INTERRUPTED": "移动打断了施法", "PROJECTILE_MISSED": "飞弹落空",
	"TRANSACTIONS_DISABLED": "技能输入未启用",
	"ICE_BLOCKED": "冰箱期间无法行动", "NO_FREEZE_TARGET": "范围内没有可冻结的小怪",
	"NO_BLINK_LANDING": "这个方向没有可用落点",
	"APPROACH_CANCELLED": "已取消接近施法", "CANNOT_APPROACH": "无法接近目标",
}
const SKILL_TARGET_TEXT := {"SELF": "自身", "ALLY": "友方", "ENEMY": "敌方", "DIRECTION": "方向"}
const RESOURCE_COLOR := {"rage": Color("c8553d"), "energy": Color("e0b341"), "mana": Color("4f8fe0")}
const RESOURCE_NAME := {"rage": "怒气", "energy": "能量", "mana": "法力"}
const STATUS_COLOR := {"mitigate": Color("5ab0ff"), "haste": Color("ffd54a"), "taunt": Color("ff5a5a"),
	"frozen": Color("8bd9ff"), "ice_block": Color("c3eeff")}
const RESULT_REASON := {
	"all_enemies_down": "敌人全部倒下",
	"all_allies_down": "出战成员全部倒下",
	"timeout": "120 秒内没打完",
	"skill_validation_error": "技能配置异常",
	"retreated": "已撤离本场战斗",
}

var _snap: Dictionary = {}
var _by_id: Dictionary = {}
var _hud: Dictionary = {}
var _live_units: Array[Dictionary] = []
var _world_labels: Array[Dictionary] = []
var _controlled: Dictionary = {}
var _enemy_hits: Dictionary = {}
var _combat_numbers: Array[Dictionary] = []
var _projectile_impacts: Array[Dictionary] = []
var _selected_slot: int = -1
var _back_text: String = "返回（Enter）"
var _notice: String = ""
var _toast: String = ""
var _font: Font = preload("res://scenes/ui/cjk_font.gd").get_font()
var _foreground_mask: Image


## 缓存前景透明度，点击由实际遮挡轮廓决定。
func _ready() -> void:
	_foreground_mask = MINE_FOREGROUND.get_image()


## 接收纯数据副本，同时更新绘制与命中共用的本体和头顶标签，并清理过期反馈。
func render(snapshot: Dictionary, selected_slot: int, toast: String, _log_path: String) -> void:
	_snap = snapshot.duplicate(true)
	_hud = _snap.get("player_hud", {})
	_selected_slot = selected_slot
	_by_id.clear()
	_live_units.clear()
	_controlled = {}
	for unit: Dictionary in _snap["units"]:
		_by_id[unit["id"]] = unit
		if unit["side"] == "ally" and int(unit["slot"]) == _selected_slot:
			_controlled = unit
		if unit["alive"]:
			_live_units.append(unit)
	# 圆形及菱形使用同一帧的显示位置作为接地点，同 Y 按单位 ID 固定前后。
	_live_units.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ay: float = a["pos"].y
		var by: float = b["pos"].y
		return ay < by if ay != by else int(a["id"]) < int(b["id"]))
	_update_world_labels()
	if _snap["paused"] or _snap["finished"]:
		clear_enemy_hits(true)
	else:
		var now := Time.get_ticks_msec()
		while not _combat_numbers.is_empty() and now - int(_combat_numbers[0]["started"]) >= COMBAT_NUMBER_MS:
			_combat_numbers.pop_front()
		while not _projectile_impacts.is_empty() and now - int(_projectile_impacts[0]["started"]) >= CRITICAL_RING_MS:
			_projectile_impacts.pop_front()
		for target_id: int in _enemy_hits.keys():
			var hit: Dictionary = _enemy_hits[target_id]
			if not _by_id.has(target_id) or (now - hit["flash_at"] >= HIT_FLASH_MS and now - hit["critical_at"] >= CRITICAL_RING_MS):
				_enemy_hits.erase(target_id)
	_toast = toast
	queue_redraw()


## 每只怪只刷新一次闪白计时，尚在扩散的暴击环合并后续暴击。
func show_enemy_hit(target_id: int, critical: bool) -> void:
	var now := Time.get_ticks_msec()
	var hit: Dictionary = _enemy_hits.get(target_id, {"critical_at": now - CRITICAL_RING_MS})
	hit["flash_at"] = now
	if critical and now - hit["critical_at"] >= CRITICAL_RING_MS:
		hit["critical_at"] = now
	_enemy_hits[target_id] = hit
	queue_redraw()


## 切人清个人反馈；暂停、结算、离场也清理飞弹冲击。
func clear_enemy_hits(all_effects: bool = false) -> void:
	_enemy_hits.clear()
	_combat_numbers.clear()
	if all_effects:
		_projectile_impacts.clear()
	queue_redraw()


## 数字随受击或受疗目标浮起，目标离场时沿用命中位置，同目标数字左右错开。
## 接收脚点和本体半径，计算飘字独立于地面碰撞的显示锚点。
func show_combat_number(target_id: int, pos: Vector2, radius: float, amount: float, healing: bool, critical: bool) -> void:
	var occupied := 0
	for number in _combat_numbers:
		if number["target_id"] == target_id:
			occupied += 1
	var offsets := [0.0, -42.0, 42.0, -65.0, 65.0]
	# 起点避开头顶读条和选中箭头，之后再沿动画上浮。
	var offset := Vector2(offsets[occupied % offsets.size()], -radius - 64.0 - 18.0 * float(occupied % 3))
	var text := "<1" if amount < 0.5 else skill_amount_text(amount)
	if healing:
		text = "+" + text
	_combat_numbers.append({"target_id": target_id, "pos": pos - Vector2(0, radius), "offset": offset, "started": Time.get_ticks_msec(),
		"text": text, "healing": healing, "critical": critical})
	if _combat_numbers.size() > 32:
		_combat_numbers.pop_front()
	queue_redraw()


## 只记录真实命中的冲击点，飞弹速度和抵达由模拟层决定。
func show_projectile_impact(pos: Vector2) -> void:
	_projectile_impacts.append({"pos": pos, "started": Time.get_ticks_msec()})
	queue_redraw()


## 出征进来的战斗：返回按钮写「回酒馆」。结果页底部的提示（如保存失败）用 set_notice。
func set_back_text(text: String) -> void:
	_back_text = text


func set_notice(text: String) -> void:
	_notice = text
	queue_redraw()


func reason_text(reason: String) -> String:
	return String(REASON_TEXT.get(reason, reason))


## 非负业务值仅在显示时恰半向上；大到已无小数精度时直接格式化，避免缩放溢出。
static func skill_amount_text(amount: float, decimal: bool = false) -> String:
	if not decimal:
		return "%.0f" % roundf(amount)
	var rounded := roundf(amount * 10.0) / 10.0 if amount < 1.0e16 else amount
	return "%.1f" % rounded


## HUD 优先于战场；前景遮住本体，但右键仍可命中前景下的合法地面。
func hit_test(pos: Vector2, movement: bool = false) -> Dictionary:
	if _snap.is_empty():
		return {}
	if bool(_snap["finished"]):
		return {"kind": "back"} if BACK_BUTTON.has_point(pos) else {"kind": "hud"}
	if _hud.get("settings", false):
		for index in SETTINGS_OPTIONS.size():
			if _option_rect(index).has_point(pos):
				return {"kind": "preference", "key": SETTINGS_OPTIONS[index]}
		for row in 2:
			var key := "fps" if row == 0 else "resolution"
			var choices := DisplayPreferences.FPS_CHOICES if row == 0 else DisplayPreferences.RESOLUTION_CHOICES
			for index in choices.size():
				if _display_option_rect(row, index).has_point(pos):
					var value: int = choices[index]
					if value == 0 or value <= int(_hud.get("display", {}).get(key, 0)):
						return {"kind": "display_preference", "key": key, "value": value}
		return {"kind": "settings_close"} if SETTINGS_CLOSE.has_point(pos) else {"kind": "hud"}
	for slot_index in 4:
		if _portrait_rect(slot_index).has_point(pos):
			if _hud.is_empty():
				return {"kind": "portrait", "slot": slot_index}
			for unit: Dictionary in _snap["units"]:
				if unit["side"] == "ally" and unit["slot"] == slot_index and unit["alive"]:
					return {"kind": "target", "id": unit["id"]}
			return {"kind": "hud"}
	for index in 4:
		if _skill_rect(index).grow_side(SIDE_TOP, 7.0).has_point(pos):
			return {"kind": "skill", "key": SKILL_KEYS[index].to_lower()}
	if not _snap.get("skill_validation", false) and RETREAT_BUTTON.has_point(pos):
		return {"kind": "retreat"}
	var bar := Rect2(_skill_rect(0).position.x - 8, SKILL_Y - 8, 4 * SKILL_W + 3 * SKILL_GAP + 16, SKILL_H + 16)
	var panel := _portrait_rect(0).merge(_portrait_rect(3)).grow(8.0)
	if bar.has_point(pos) or panel.has_point(pos):
		return {"kind": "hud"}
	if not _hud.is_empty():
		if SETTINGS_BUTTON.has_point(pos):
			return {"kind": "settings"}
		if OUTPUT_PANEL.has_point(pos) or THREAT_PANEL.has_point(pos):
			return {"kind": "hud"}
		var target: Dictionary = _by_id.get(_hud["target"], {})
		if TARGET_BAR.has_point(pos):
			return {"kind": "target", "id": target["id"]} if not target.is_empty() else {"kind": "hud"}
		var other := _target_of(target)
		if not other.is_empty() and TARGET_OF_TARGET_BAR.has_point(pos):
			return {"kind": "target", "id": other["id"]}
	var arena: Rect2 = _snap["arena"]
	var front_point := pos - FOREGROUND_ORIGIN
	if _foreground_mask != null and Rect2(Vector2.ZERO, MINE_FOREGROUND.get_size()).has_point(front_point):
		if _foreground_mask.get_pixelv(Vector2i(front_point)).a >= 0.5:
			return {} if movement and arena.has_point(pos) else {"kind": "hud"}
	if not _hud.is_empty():
		for unit in _world_labels:
			if _world_label_rect(unit).has_point(pos):
				return {"kind": "world_target", "id": unit["id"]}
	# 本体按绘制顺序反查；倒下的单位属于地面层，已排除。
	for index in range(_live_units.size() - 1, -1, -1):
		var unit := _live_units[index]
		var offset := pos - _body_center(unit)
		var diamond: bool = unit["side"] == "enemy" and unit["kind"] == "caster"
		var distance := absf(offset.x) + absf(offset.y) if diamond else offset.length()
		if distance <= float(unit["radius"]):
			return {"kind": "world_target", "id": unit["id"]}
	# 岩壁、底部岩石外侧及其透明留白都在可走矩形之外。
	return {} if arena.has_point(pos) else {"kind": "hud"}


## 按队伍槽位返回卡片矩形，绘制及命中共用同一位置。
func _portrait_rect(slot_index: int) -> Rect2:
	return Rect2(PORTRAIT_X, PORTRAIT_Y + slot_index * PORTRAIT_H, PORTRAIT_W, PORTRAIT_H)


## 正下方四个快捷槽，图标、冷却和鼠标命中共享同一矩形。
func _skill_rect(index: int) -> Rect2:
	return Rect2(780.0 + index * (SKILL_W + SKILL_GAP), SKILL_Y, SKILL_W, SKILL_H)


func _text(pos: Vector2, text: String, size: int, color: Color, width: float = -1.0, align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT) -> void:
	draw_string(_font, pos, text, align, width, size, color)


## 地面、本体、世界反馈、标签与界面分层绘制，结果提示沿用原有遮罩顺序。
func _draw() -> void:
	if _snap.is_empty():
		return
	draw_texture(MINE_FLOOR, FLOOR_ORIGIN)
	draw_texture(MINE_BACKDROP, Vector2.ZERO)
	var units: Array = _snap["units"]
	_draw_telegraphs(units, false)
	_draw_aim()
	if not _controlled.is_empty() and bool(_controlled["alive"]):
		_draw_orders(_controlled, _by_id)
	var now := Time.get_ticks_msec()
	for unit: Dictionary in units:
		if not unit["alive"]:
			_draw_unit(unit, false, now)
	for unit in _live_units:
		_draw_unit(unit, unit["id"] == _controlled.get("id", -1), now)
	if not _hud.is_empty():
		_draw_projectile_feedback(now)
	_draw_telegraphs(units, true)
	# 优先级从低到高绘制，重要标记与命中的顺序一致。
	for index in range(_world_labels.size() - 1, -1, -1):
		var unit := _world_labels[index]
		if _hud.is_empty():
			_draw_legacy_world_label(unit)
		else:
			_draw_world_label(unit, unit["id"] == _controlled.get("id", -1))
	if not _hud.is_empty():
		_draw_combat_numbers(now)
		_draw_friendly_cast_bar(_controlled)
	# 前景山石高于战场单位和地面反馈，HUD 始终绘制在前景上方。
	draw_texture(MINE_FOREGROUND, FOREGROUND_ORIGIN)
	_draw_portraits(units)
	_draw_skill_bar(_controlled)
	_draw_top()
	if not _hud.is_empty():
		_draw_player_hud(_controlled)
	var finished: bool = _snap["finished"]
	if not finished and not _snap.get("skill_validation", false):
		draw_texture_rect_region(HUD_ATLAS, Rect2(RETREAT_BUTTON.position, TEXTURE_RETREAT.size), TEXTURE_RETREAT)
		_text(RETREAT_BUTTON.position + Vector2(0, 113), "撤退", 25, Color("ffe4a1"), RETREAT_BUTTON.size.x, HORIZONTAL_ALIGNMENT_CENTER)
	var show_final_notice: bool = finished and _snap.get("skill_full_input", false)
	if show_final_notice:
		_draw_result()
	if _toast != "":
		_text(Vector2(0, 930), _toast, 30, Color("ffd9a0"), 1920.0, HORIZONTAL_ALIGNMENT_CENTER)
	if finished and not show_final_notice:
		_draw_result()
	if not finished and _hud.get("settings", false):
		_draw_settings()


## 飞弹用战斗快照定位，瞬时冲击用显示时间，二者都画在标签下方。
func _draw_projectile_feedback(now: int) -> void:
	for flight: Dictionary in _snap.get("projectiles", []):
		var origin: Vector2 = flight["origin"]
		var target: Vector2 = flight["target"]
		var head := origin.lerp(target, float(flight["progress"]))
		var tail := head.move_toward(origin, 30.0)
		var ink := Color("ff995a") if flight["skill_id"] == "mage.fire.fireball" else Color("c39aff")
		draw_line(tail, head, Color(ink, 0.42), 8.0, true)
		draw_circle(head, 8.0, ink, true, -1.0, true)
		draw_circle(head, 3.5, Color("fff2d6"), true, -1.0, true)
	for impact in _projectile_impacts:
		var progress := float(now - int(impact["started"])) / CRITICAL_RING_MS
		if progress < 1.0:
			draw_circle(impact["pos"], lerpf(5.0, 17.0, progress), Color(1.0, 0.8, 0.56, 0.65 * (1.0 - progress)), true, -1.0, true)


## 飘字跟随可见本体，使用既有显示计时和偏移。
func _draw_combat_numbers(now: int) -> void:
	for number in _combat_numbers:
		var age := float(now - int(number["started"]))
		var progress := age / COMBAT_NUMBER_MS
		if progress >= 1.0:
			continue
		var ink := Color("8cf79a") if number["healing"] else (Color("ffdb59") if number["critical"] else Color.WHITE)
		ink.a = 1.0 - smoothstep(0.40, 1.0, progress)
		var size := 30
		if number["critical"]:
			size = roundi(32.0 * lerpf(1.35, 1.0, clampf(age / 140.0, 0.0, 1.0)))
		var target: Dictionary = _by_id.get(number["target_id"], {})
		var anchor: Vector2 = number["pos"] if target.is_empty() else _body_center(target)
		var pos: Vector2 = anchor + number["offset"] + Vector2(-80.0, -56.0 * progress)
		var text: String = number["text"]
		draw_string_outline(_font, pos, text, HORIZONTAL_ALIGNMENT_CENTER, 160.0, size, 7, Color(0.06, 0.07, 0.10, ink.a))
		_text(pos, text, size, ink, 160.0, HORIZONTAL_ALIGNMENT_CENTER)


## 当前角色的大读条只投影技能名和固定步进度，队友仍用头顶短条。
func _draw_friendly_cast_bar(actor: Dictionary) -> void:
	var cast: Dictionary = actor.get("cast", {})
	if cast.is_empty():
		return
	var rect := Rect2(740.0, 873.0, 440.0, 36.0)
	draw_rect(rect, Color("202737"))
	draw_rect(Rect2(rect.position, Vector2(rect.size.x * float(cast["progress"]), rect.size.y)), Color("9b6538"))
	draw_rect(rect, Color("ffca75"), false, 1.5)
	_text(rect.position + Vector2(0, 25), cast["name"], 22, Color("fff3dd"), rect.size.x, HORIZONTAL_ALIGNMENT_CENTER)


## 同一份预警数据分两次绘制，底色留在地面，边线跨过本体以保持可读。
func _draw_telegraphs(units: Array, outline_only: bool) -> void:
	for unit: Dictionary in units:
		var cast: Dictionary = unit["cast"]
		if cast.is_empty():
			continue
		var radius: float = cast["radius"]
		if radius <= 0.0:
			continue
		var center: Vector2 = cast["center"]
		if outline_only:
			draw_arc(center, radius, 0.0, TAU, 48, Color(1.0, 0.35, 0.35, 0.9), 3.0)
		else:
			var progress: float = cast["progress"]
			draw_circle(center, radius, Color(0.9, 0.2, 0.2, 0.12))
			draw_circle(center, radius * progress, Color(0.9, 0.2, 0.2, 0.25))


## 路线贴地绘制，单位目标环围绕可见本体。
func _draw_orders(selected: Dictionary, by_id: Dictionary) -> void:
	var pos: Vector2 = selected["pos"]
	var order_kind: String = selected["order_kind"]
	if order_kind == "move":
		var dest: Vector2 = selected["order_pos"]
		draw_line(pos, dest, Color(1, 1, 1, 0.35), 2.0)
		draw_arc(dest, 12.0, 0.0, TAU, 24, Color("ffffff"), 2.0)
		draw_line(dest + Vector2(-6, 0), dest + Vector2(6, 0), Color("ffffff"), 2.0)
		draw_line(dest + Vector2(0, -6), dest + Vector2(0, 6), Color("ffffff"), 2.0)
	if not _hud.is_empty():
		return
	var target_id: int = selected["target_id"]
	if target_id >= 0 and by_id.has(target_id):
		var target: Dictionary = by_id[target_id]
		if bool(target["alive"]):
			var color := Color("6fe08a") if selected["attack_kind"] == "heal" else Color("ffd54a")
			draw_line(pos, target["pos"], Color(color.r, color.g, color.b, 0.7), 2.0)
			draw_arc(_body_center(target), float(target["radius"]) + 7.0, 0.0, TAU, 32, color, 2.0)


## 本体从脚点向上展开，绘制、标签和鼠标命中使用同一个中心。
func _body_center(unit: Dictionary) -> Vector2:
	return (unit["pos"] as Vector2) - Vector2(0, float(unit["radius"]))


## 从脚点绘制本体、命中反馈和冰冻状态。
func _draw_unit(unit: Dictionary, is_selected: bool, now: int) -> void:
	var pos := _body_center(unit)
	var radius: float = unit["radius"]
	var alive: bool = unit["alive"]
	var color := Color.html(String(unit["color"]))
	if not alive:
		color = Color(0.35, 0.35, 0.38)
	var enemy: bool = unit["side"] == "enemy"
	if enemy and _enemy_hits.has(unit["id"]):
		var hit: Dictionary = _enemy_hits[unit["id"]]
		var flash_age := now - int(hit["flash_at"])
		if flash_age < HIT_FLASH_MS:
			color = color.lerp(Color.WHITE, 0.9 * (1.0 - float(flash_age) / HIT_FLASH_MS))
		var ring_age := now - int(hit["critical_at"])
		if ring_age < CRITICAL_RING_MS:
			var progress := float(ring_age) / CRITICAL_RING_MS
			var ring_color := Color(1.0, 0.87, 0.58, 0.88 * (1.0 - progress))
			draw_arc(pos, radius + lerpf(8.0, 22.0, progress), 0.0, TAU, 40, ring_color, 2.5, true)
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
	if "frozen" in unit["statuses"] or "ice_block" in unit["statuses"]:
		var ice := Color("b2e9ff") if "ice_block" in unit["statuses"] else Color("76c8ff")
		draw_circle(pos, radius + 3.0, Color(ice, 0.25))
		draw_arc(pos, radius + 5.0, 0.0, TAU, 40, ice, 2.5, true)
	if is_selected and _hud.is_empty():
		draw_arc(pos, radius + 6.0, 0.0, TAU, 40, Color.WHITE, 3.0)
	if not enemy:
		_text(pos + Vector2(-8, 8), str(int(unit["slot"]) + 1), 24, Color(0.05, 0.05, 0.08), 16.0, HORIZONTAL_ALIGNMENT_CENTER)
	if not _hud.is_empty():
		for index: int in unit["statuses"].size():
			var status: String = unit["statuses"][index]
			draw_circle(pos + Vector2(-radius + 8.0 + index * 12.0, radius + 10.0), 4.0, STATUS_COLOR.get(status, Color.WHITE))
		return
	var status_x := pos.x - maxf(54.0, radius * 2.4) * 0.5
	for status_id: String in unit["statuses"]:
		draw_circle(Vector2(status_x + 5.0, pos.y + radius + 12.0), 5.0, STATUS_COLOR.get(status_id, Color.WHITE))
		status_x += 14.0


## 旧版标签从本体中心定位血条、读条和名称。
func _draw_legacy_world_label(unit: Dictionary) -> void:
	var pos := _body_center(unit)
	var radius: float = unit["radius"]
	var enemy: bool = unit["side"] == "enemy"
	var bar_w := maxf(54.0, radius * 2.4)
	var bar_pos := pos + Vector2(-bar_w * 0.5, -radius - 16.0)
	var ratio := float(unit["hp"]) / float(unit["max_hp"])
	draw_rect(Rect2(bar_pos, Vector2(bar_w, 7)), Color(0, 0, 0, 0.7))
	draw_rect(Rect2(bar_pos, Vector2(bar_w * ratio, 7)), Color("6fe08a") if not enemy else Color("e86a6a"))
	_draw_world_mana(unit, bar_pos + Vector2(0, 9), bar_w)
	var cast: Dictionary = unit["cast"]
	if not cast.is_empty():
		var cast_pos := bar_pos + Vector2(0, -12)
		draw_rect(Rect2(cast_pos, Vector2(bar_w, 7)), Color(0, 0, 0, 0.7))
		var cast_color := Color("ffcf5a") if cast["interruptible"] else Color("ff6b6b")
		draw_rect(Rect2(cast_pos, Vector2(bar_w * float(cast["progress"]), 7)), cast_color)
		_text(cast_pos + Vector2(0, -4), String(cast["name"]), 15, cast_color, bar_w, HORIZONTAL_ALIGNMENT_CENTER)
	_text(pos + Vector2(-50, radius + 34.0), String(unit["name"]), 16, Color(1, 1, 1, 0.8), 100.0, HORIZONTAL_ALIGNMENT_CENTER)


## 队伍槽位使用原素材布局；生命值、资源以及小技能的冷却由当前快照绘制。
func _draw_portraits(units: Array) -> void:
	var by_slot: Dictionary = {}
	for unit: Dictionary in units:
		if unit["side"] == "ally":
			by_slot[int(unit["slot"])] = unit
	for slot_index in 4:
		var rect := _portrait_rect(slot_index)
		var origin := rect.position
		var unit: Dictionary = by_slot.get(slot_index, {})
		var keycap := Rect2(origin + Vector2(4, 25), Vector2(25, 22))
		draw_texture_rect_region(HUD_ATLAS, keycap, TEXTURE_KEYCAP)
		_text(keycap.position + Vector2(0, 16), str(slot_index + 1), 16, Color.WHITE, keycap.size.x, HORIZONTAL_ALIGNMENT_CENTER)
		draw_texture_rect_region(HUD_ATLAS, Rect2(origin + Vector2(41, 3), Vector2(157, 41)), TEXTURE_ROW)
		if unit.is_empty():
			_text(origin + Vector2(57, 29), "空槽", 17, Color("bca286"))
			continue
		var atlas_column := int(CLASS_ATLAS_ROW.get(unit["kind"], 0)) * 100 + 2
		var alive: bool = unit["alive"]
		var tint := Color.WHITE if alive else Color(0.45, 0.45, 0.45)
		draw_texture_rect_region(HUD_ATLAS, Rect2(origin + Vector2(27, 1), Vector2(47, 46)),
			Rect2(atlas_column, 402, 48, 48), tint)
		draw_texture_rect_region(HUD_ATLAS, Rect2(origin, Vector2(30, 25)), Rect2(atlas_column, 458, 32, 30), tint)
		_draw_hud_health(Rect2(origin + Vector2(78, 6), Vector2(118, 33)), unit)
		var res_ratio := float(unit["res"]) / maxf(1.0, float(unit["res_max"]))
		draw_rect(Rect2(origin + Vector2(84, 42), Vector2(105, 3)), Color("25180e"))
		draw_rect(Rect2(origin + Vector2(84, 42), Vector2(105 * res_ratio, 3)), RESOURCE_COLOR.get(unit["res_kind"], Color.GRAY))
		var views: Array = _snap["skills"].get(unit["id"], [])
		for index in mini(views.size(), 4):
			_draw_skill_icon(Rect2(origin + Vector2(201 + index * 47, 4), Vector2(43, 40)), unit, index, views[index])
		if slot_index == _selected_slot:
			draw_rect(rect, Color(1.0, 0.76, 0.31, 0.75), false, 1.5)


## 技能图标按职业和槽位取原图，冷却及可用状态只读取当前技能投影。
func _draw_skill_icon(rect: Rect2, actor: Dictionary, index: int, view: Dictionary) -> void:
	if view.is_empty() or bool(view.get("empty", false)):
		draw_texture_rect_region(HUD_ATLAS, rect, TEXTURE_KEYCAP, Color(0.6, 0.6, 0.6))
		return
	var row := int(CLASS_ATLAS_ROW.get(actor.get("kind", ""), 0))
	var usable := bool(actor.get("alive", false)) and bool(view.get("preparable", view.get("reason", "") == ""))
	var tint := Color.WHITE if usable else Color(0.56, 0.56, 0.56)
	draw_texture_rect_region(HUD_ATLAS, rect, Rect2(2 + index * 100, 2 + row * 100, 96, 96), tint)
	var cd: float = float(view["cd_left"]) if view.get("cd_left") != null else 0.0
	if cd > 0.0:
		var configured: float = float(view["cooldown"]) if view.get("cooldown") != null else cd
		var fraction := clampf(cd / maxf(0.01, configured), 0.0, 1.0)
		var mask := Rect2(rect.position + Vector2(4, 4), Vector2(rect.size.x - 8, (rect.size.y - 8) * fraction))
		draw_rect(mask, Color(0, 0, 0, 0.48))
		var font_size := 14 if rect.size.x < 50.0 else 25
		_text(rect.position + Vector2(0, rect.size.y * 0.62), skill_amount_text(cd, true), font_size,
			Color("ffe2a1"), rect.size.x, HORIZONTAL_ALIGNMENT_CENTER)


## 底部只显示当前角色的四个快捷按钮；悬停保留真实技能名称、消耗及两种冷却。
func _draw_skill_bar(selected: Dictionary) -> void:
	var views: Array = _snap["skills"].get(selected.get("id", -1), [])
	var hovered := -1
	for index in 4:
		var rect := _skill_rect(index)
		var view: Dictionary = views[index] if index < views.size() else {}
		_draw_skill_icon(Rect2(rect.position + Vector2(0, 4), Vector2(rect.size.x, 88)), selected, index, view)
		var keycap := Rect2(rect.position + Vector2(4, -7), Vector2(33, 34))
		draw_texture_rect_region(HUD_ATLAS, keycap, TEXTURE_KEYCAP)
		_text(keycap.position + Vector2(0, 24), SKILL_KEYS[index], 20, Color.WHITE, keycap.size.x, HORIZONTAL_ALIGNMENT_CENTER)
		if not view.is_empty() and not bool(view.get("empty", false)):
			var label := Rect2(rect.position + Vector2(0, 84), Vector2(rect.size.x, 21))
			draw_rect(label, Color(0.15, 0.08, 0.03, 0.9))
			_text(label.position + Vector2(0, 16), String(view["name"]), 15, Color("ffe9bd"), label.size.x, HORIZONTAL_ALIGNMENT_CENTER)
			if rect.has_point(get_local_mouse_position()):
				hovered = index
	if hovered < 0 or _hud.get("settings", false) or _snap["finished"]:
		return
	var view: Dictionary = views[hovered]
	var hint_rect := Rect2(756, 858, 408, 84)
	_draw_panel(hint_rect)
	_text(hint_rect.position + Vector2(14, 23), String(view["name"]), 19, Color("ffe9bd"))
	var detail := ""
	if view.has("mana_cost"):
		detail = _full_skill_cost_text(view)
	else:
		detail = "无消耗" if float(view["cost"]) <= 0.0 else "消耗 %s %s" % [skill_amount_text(float(view["cost"])), RESOURCE_NAME.get(selected["res_kind"], "")]
	_text(hint_rect.position + Vector2(14, 46), detail, 16, Color.WHITE)
	var clock := "冷却 %s秒" % str(view.get("cd_left", 0.0) if view.get("cd_left") != null else "?")
	if view.get("gcd_left") != null:
		clock += "   公共 %s秒" % skill_amount_text(float(view["gcd_left"]), true)
	var reason := String(view.get("reason", ""))
	if not reason.is_empty():
		clock += "   " + reason_text(reason)
	_text(hint_rect.position + Vector2(14, 69), clock, 15, Color("ffd79d"))


## 完整隔离技能栏中文化目标和法力消耗；配置缺值显示问号。
func _full_skill_cost_text(view: Dictionary) -> String:
	if view["empty"]:
		return "未配置技能"
	var target := String(SKILL_TARGET_TEXT.get(view["target_kind"], "未知目标"))
	var reach := str(view["cast_range_m"]) if view["cast_range_m"] != null else "?"
	var mana := skill_amount_text(float(view["mana_cost"]), true) if view["mana_cost"] != null else "?"
	return "%s %s米 / 耗%s法力" % [target, reach, mana]


## 顶部保留计时与移动操作说明，暂停提示覆盖战场中央。
func _draw_top() -> void:
	var left := maxf(0.0, float(_snap["limit"]) - float(_snap["time"]))
	var minutes := int(left) / 60
	var seconds := int(left) % 60
	var timer := Rect2(846, 104, 228, 45)
	_draw_panel(timer)
	_text(timer.position + Vector2(0, 32), "剩余 %d:%02d" % [minutes, seconds], 29, Color("ffe9bd"), timer.size.x, HORIZONTAL_ALIGNMENT_CENTER)
	var guide := "1–4 换人　左键选人　右键走位／攻击／普疗　方向键／左摇杆　QWER 技能　P 暂停"
	if not _hud.is_empty():
		guide = "1–4 换人　左键选目标　右键走位／攻击／普疗　方向键／左摇杆　Tab 切敌　QWER 技能　P 暂停"
	elif _snap.get("skill_validation", false):
		guide = "技能验证 · 右键走位／设目标　方向键／左摇杆移动　Q/W/E/R 选技能"
	var guide_rect := Rect2(519, 196, 827, 34)
	_draw_panel(guide_rect)
	_text(guide_rect.position + Vector2(12, 23), guide, 16, Color("ffecda"), guide_rect.size.x - 24, HORIZONTAL_ALIGNMENT_CENTER)
	if _snap.get("skill_validation", false):
		_text(Vector2(532, 250), _skill_configuration_text(), 14, Color("ffecda"), 810.0)
	elif _snap.get("skill_formal", false) and _hud.is_empty():
		_text(Vector2(532, 250), "旧天赋本批暂不生效，两件套只加对应 Q", 16, Color("ffecda"))
	if bool(_snap["paused"]):
		draw_rect(Rect2(660, 380, 600, 120), Color(0, 0, 0, 0.7))
		_text(Vector2(660, 442), "已暂停  按 P 继续", 40, Color("ffd9a0"), 600.0, HORIZONTAL_ALIGNMENT_CENTER)


## 血条共用有效治疗预览，实心血量和半透明预补区域不重叠。
func _draw_health(rect: Rect2, unit: Dictionary) -> void:
	var maximum := maxf(1.0, float(unit["max_hp"]))
	var hp := clampf(float(unit["hp"]), 0.0, maximum)
	var color := Color("6fe08a") if unit["side"] == "ally" else Color("e86a6a")
	var filled := rect.size.x * hp / maximum
	draw_rect(rect, Color("101823"))
	draw_rect(Rect2(rect.position, Vector2(filled, rect.size.y)), color)
	if unit["id"] == _hud.get("target", -1):
		var preview := minf(maximum - hp, float(_hud.get("heal_preview", 0.0)))
		if preview > 0.0:
			draw_rect(Rect2(rect.position + Vector2(filled, 0), Vector2(rect.size.x * preview / maximum, rect.size.y)), Color(0.55, 1.0, 0.64, 0.46))


## 按目标、受控角色、读条者和其他单位取舍标签；同优先级先保留前面的本体。
func _update_world_labels() -> void:
	_world_labels.clear()
	var controlled_id: int = _controlled.get("id", -1)
	var target_id: int = _hud.get("target", _controlled.get("target_id", -1))
	var priority_groups: Array = [[], [], [], []]
	for index in range(_live_units.size() - 1, -1, -1):
		var unit := _live_units[index]
		var priority := 3
		if unit["id"] == target_id:
			priority = 0
		elif unit["id"] == controlled_id:
			priority = 1
		elif not (unit["cast"] as Dictionary).is_empty():
			priority = 2
		priority_groups[priority].append(unit)

	var occupied: Array[Rect2] = []
	for group: Array in priority_groups:
		for unit: Dictionary in group:
			var bounds := _world_label_bounds(unit, controlled_id, target_id)
			# 只将实际绘制的标签加入列表，隐藏标签也随之失去命中区域。
			var overlaps := false
			for rect in bounds:
				for other in occupied:
					if rect.intersects(other):
						overlaps = true
						break
				if overlaps:
					break
			if not overlaps:
				occupied.append_array(bounds)
				_world_labels.append(unit)


## 标签按本体中心定位，避让区域同时包含读条、目标箭头和细蓝条。
func _world_label_bounds(unit: Dictionary, controlled_id: int, target_id: int) -> Array[Rect2]:
	var casting := not (unit["cast"] as Dictionary).is_empty()
	if _hud.is_empty():
		var pos := _body_center(unit)
		var radius: float = unit["radius"]
		var width := maxf(54.0, radius * 2.4)
		var top := pos.y - radius - (47.0 if casting else 16.0)
		# 旧版名称位于脚下，蓝条则随头顶血条一起参与避让。
		var bar_bottom := pos.y - radius - (3.0 if unit["res_kind"] == "mana" else 9.0)
		return [
			Rect2(pos.x - width * 0.5, top, width, bar_bottom - top),
			Rect2(pos.x - 50.0, pos.y + radius + 18.0, 100.0, 21.0),
		]
	var top_margin := 0.0
	if unit["id"] == target_id or unit["id"] == controlled_id:
		top_margin = 27.0
	elif casting:
		top_margin = 9.0
	return [_world_label_rect(unit).grow_side(SIDE_TOP, top_margin)]


## 血条和身份标识共用跟随本体的命中矩形。
func _world_label_rect(unit: Dictionary) -> Rect2:
	var radius: float = unit["radius"]
	var bar_width := maxf(64.0, radius * 2.4)
	var badge := 78.0 if _hud.get("prefs", {}).get("names", false) else 26.0
	var pos := _body_center(unit)
	return Rect2(pos + Vector2(-bar_width * 0.5, -radius - 36.0), Vector2(bar_width + badge, 24.0))


## 使用灰盒自绘职业与怪物图标；名称偏好和未知类型都显示可读文字。
func _draw_identity(rect: Rect2, unit: Dictionary) -> void:
	var shapes := {"warrior": "shield", "rogue": "blade", "mage": "flame", "priest": "plus",
		"elite": "crown", "caster": "rune", "melee": "claw"}
	var shape := String(shapes.get(unit["kind"], ""))
	if _hud.get("prefs", {}).get("names", false) or shape.is_empty():
		_text(rect.position + Vector2(2, rect.size.y * 0.5 + 5), unit["name"], 15, Color("eef3ff"), rect.size.x - 4, HORIZONTAL_ALIGNMENT_CENTER)
		return
	draw_rect(rect.grow(-2), Color.html(String(unit["color"])).darkened(0.54))
	draw_rect(rect.grow(-2), Color("adc1df"), false, 1.0)
	var center := rect.get_center()
	var ink := Color("eef3ff")
	var path := PackedVector2Array()
	match shape:
		"shield":
			path = PackedVector2Array([Vector2(-6, -6), Vector2(6, -6), Vector2(5, 2), Vector2(0, 7), Vector2(-5, 2)])
		"blade":
			path = PackedVector2Array([Vector2(-6, 6), Vector2(-5, 2), Vector2(6, -7), Vector2(4, 0), Vector2(0, 3)])
		"flame":
			path = PackedVector2Array([Vector2(-6, 2), Vector2(-2, -3), Vector2(1, -8), Vector2(6, 1), Vector2(5, 6), Vector2(-4, 6)])
		"plus":
			draw_rect(Rect2(center + Vector2(-6, -2), Vector2(12, 4)), ink)
			draw_rect(Rect2(center + Vector2(-2, -6), Vector2(4, 12)), ink)
		"crown":
			path = PackedVector2Array([Vector2(-8, -5), Vector2(-3, 0), Vector2(0, -6), Vector2(3, 0), Vector2(8, -5), Vector2(6, 6), Vector2(-6, 6)])
		"rune":
			draw_arc(center, 6, 0, TAU, 20, ink, 1.5, true)
			draw_line(center + Vector2(-5, 5), center + Vector2(5, -5), ink, 1.5, true)
		"claw":
			for index in range(-1, 2):
				draw_line(center + Vector2(index * 4 - 2, 5), center + Vector2(index * 4 + 2, -5), ink, 1.5, true)
	if not path.is_empty():
		for index in path.size():
			path[index] += center
		draw_colored_polygon(path, ink)


## 头顶依次显示读条、血量和法力，操控及目标标记仍与身份图标分开。
func _draw_world_label(unit: Dictionary, controlled: bool) -> void:
	var rect := _world_label_rect(unit)
	var icon_width := 78.0 if _hud["prefs"]["names"] else 26.0
	var badge := Rect2(rect.end.x - icon_width, rect.position.y, icon_width, rect.size.y)
	var bar_width := rect.size.x - icon_width
	_draw_health(Rect2(rect.position + Vector2(0, 8), Vector2(bar_width, 8)), unit)
	_draw_world_mana(unit, rect.position + Vector2(0, 18), bar_width)
	_draw_identity(badge, unit)
	var cast: Dictionary = unit["cast"]
	if not cast.is_empty():
		var cast_pos := rect.position + Vector2(0, -9)
		var cast_width := rect.size.x - icon_width
		draw_rect(Rect2(cast_pos, Vector2(cast_width, 4)), Color("26303c"))
		draw_rect(Rect2(cast_pos, Vector2(cast_width * float(cast["progress"]), 4)), Color("ffcf5a"))
	var targeted: bool = unit["id"] == _hud["target"]
	var center: Vector2 = Vector2(unit["pos"].x, rect.position.y - 13)
	if controlled:
		var base := center + Vector2(-10 if targeted else 0, 0)
		draw_colored_polygon(PackedVector2Array([base + Vector2(-8, -12), base + Vector2(8, -12), base + Vector2(0, 0)]), Color("73f6ac"))
	if targeted:
		var base := center + Vector2(10 if controlled else 0, 0)
		draw_polyline(PackedVector2Array([base + Vector2(-8, -12), base + Vector2(8, -12), base + Vector2(0, 0), base + Vector2(-8, -12)]), Color("ff777d"), 2.4, true)


## 头顶只给有法力的友方绘制资源，空蓝仍保留细条底槽。
func _draw_world_mana(unit: Dictionary, pos: Vector2, width: float) -> void:
	if unit["side"] != "ally" or unit["res_kind"] != "mana":
		return
	var fraction := clampf(float(unit["res"]) / maxf(1.0, float(unit["res_max"])), 0.0, 1.0)
	draw_rect(Rect2(pos, Vector2(width, 4)), Color("182b43"))
	draw_rect(Rect2(pos, Vector2(width * fraction, 4)), RESOURCE_COLOR["mana"])


## 锁定的读条目标优先；若它已倒下，仍显示锁定事实但由输入入口拒绝选择。
func _target_of(target: Dictionary) -> Dictionary:
	if target.is_empty():
		return {}
	var id: int = target.get("cast_target_id", -1)
	if id >= 0:
		return _by_id.get(id, {})
	var other: Dictionary = _by_id.get(target.get("target_id", -1), {})
	return other if other.get("alive", false) else {}


## 顶部使用原目标框素材，内层血条和目标身份随当前快照更新。
func _draw_target_bar(rect: Rect2, unit: Dictionary, label: String) -> void:
	var region := TEXTURE_TARGET if rect == TARGET_BAR else TEXTURE_TARGET_OF_TARGET
	draw_texture_rect_region(HUD_ATLAS, rect, region)
	if unit.is_empty():
		_text(rect.position + Vector2(19, 33), label, 20, Color("ddc6a7"))
		return
	var badge_width := 67.0 if _hud["prefs"]["names"] else 42.0
	var badge := Rect2(rect.end.x - badge_width - 15.0, rect.position.y + 17.0, badge_width, 46.0)
	if not _hud["prefs"]["names"] and unit["kind"] == "mage":
		draw_texture_rect_region(HUD_ATLAS, badge, TEXTURE_MAGE)
	elif not _hud["prefs"]["names"] and unit["side"] == "enemy" and unit["kind"] == "elite":
		draw_texture_rect_region(HUD_ATLAS, badge, TEXTURE_ELITE)
	else:
		_draw_identity(badge, unit)
	_text(rect.position + Vector2(20, 31), "%s%s" % [label, unit["name"]], 20, Color("fff0d0"), rect.size.x - badge_width - 47)
	_draw_hud_health(Rect2(rect.position + Vector2(17, 38), Vector2(rect.size.x - badge_width - 46, 30)), unit)


## 生命条按实际比例从左到右裁切图集，治疗预览只延伸到未填满的部分。
func _draw_hud_health(rect: Rect2, unit: Dictionary) -> void:
	draw_texture_rect_region(HUD_ATLAS, rect, TEXTURE_HP_TRACK)
	var maximum := maxf(1, float(unit["max_hp"]))
	var fraction := clampf(float(unit["hp"]) / maximum, 0.0, 1.0)
	var inner := rect.grow(-4.0)
	var fill := TEXTURE_HP_GREEN if unit["side"] == "ally" else TEXTURE_HP_RED
	if fraction > 0.0:
		draw_texture_rect_region(HUD_ATLAS, Rect2(inner.position, Vector2(inner.size.x * fraction, inner.size.y)),
			Rect2(fill.position, Vector2(fill.size.x * fraction, fill.size.y)))
	if unit["id"] == _hud.get("target", -1):
		var preview := clampf(float(_hud.get("heal_preview", 0.0)) / maximum, 0.0, 1.0 - fraction)
		if preview > 0.0:
			draw_rect(Rect2(inner.position + Vector2(inner.size.x * fraction, 0),
				Vector2(inner.size.x * preview, inner.size.y)), Color(0.55, 1.0, 0.64, 0.46))
	_text(rect.position + Vector2(0, rect.size.y * 0.68), "%d/%d" % [roundi(unit["hp"]), roundi(unit["max_hp"])],
		16, Color.WHITE, rect.size.x, HORIZONTAL_ALIGNMENT_CENTER)


## 瞄准层展示实际落点、闪现方向与超距单位的接近提示。
func _draw_aim() -> void:
	var aim: Dictionary = _hud.get("aim", {})
	if not aim.get("show", false):
		return
	var center: Vector2 = aim["center"]
	var color := Color("78c8ff") if aim["valid"] else Color("ff7278")
	var reach: float = aim["reach"]
	if reach > 0.0:
		draw_arc(aim["origin"], reach, 0, TAU, 64, Color(color, 0.32), 1.5, true)
	if aim.get("direction", false):
		draw_line(aim["origin"], center, color, 2.0, true)
	var target: Dictionary = _by_id.get(aim["target"], {})
	var radius: float = aim["radius"]
	if radius > 0.0:
		draw_circle(center, radius, Color(color, 0.12))
	elif not target.is_empty():
		radius = float(target["radius"]) + 7.0
	else:
		radius = 12.0
	draw_arc(center, radius, 0, TAU, 56, color, 2.0, true)
	if not aim["valid"]:
		_text(center + Vector2(14, 24), "落点不可用／超出射程", 16, color)
	elif aim.get("approach", false):
		_text(center + Vector2(14, 24), "施放时接近", 16, color)


## 两个统计窗从战斗快照读取，每场按当前模拟时间计算 DPS。
func _draw_player_hud(actor: Dictionary) -> void:
	var target: Dictionary = _by_id.get(_hud["target"], {})
	var other := _target_of(target)
	_draw_target_bar(TARGET_BAR, target, "未选中目标" if target.is_empty() else "")
	if not other.is_empty():
		_draw_target_bar(TARGET_OF_TARGET_BAR, other, "读条目标  " if target.get("cast_target_id", -1) >= 0 else "目标的目标  ")
	var auto: Dictionary = _by_id.get(actor.get("auto_target_id", -1), {})
	if auto.get("alive", false) and auto["id"] != _hud["target"] and actor.get("attack_kind") == "damage":
		_text(TARGET_BAR.position + Vector2(12, 163), "普攻：%s" % auto["name"], 17, Color("ffcf80"))
	_draw_panel(SETTINGS_BUTTON)
	_text(SETTINGS_BUTTON.position + Vector2(0, 26), "设置", 19, Color("e3efff"), SETTINGS_BUTTON.size.x, HORIZONTAL_ALIGNMENT_CENTER)
	_draw_meter(OUTPUT_PANEL, target, false)
	_draw_meter(THREAT_PANEL, target, true)


## 仇恨和输出分别排序，怪物实际目标标记与榜首相互独立。
func _draw_meter(rect: Rect2, target: Dictionary, threat: bool) -> void:
	draw_texture_rect_region(HUD_ATLAS, rect, TEXTURE_METER)
	_text(rect.position + Vector2(17, 30), "仇恨" if threat else "输出  ·  总伤害 / DPS", 19, Color("fff0d0"))
	if threat and target.get("side") != "enemy":
		_text(rect.position + Vector2(12, 55), "选中敌人查看仇恨", 17, Color("a7b5c7"))
		return
	var rows: Array[Dictionary] = []
	var threat_by_unit: Dictionary = target.get("threat", {})
	for unit: Dictionary in _snap["units"]:
		if unit["side"] == "ally" and (not threat or unit["alive"]):
			rows.append({"id": unit["id"], "name": unit["name"], "value": float(threat_by_unit.get(unit["id"], 0.0)) if threat else float(unit["damage_done"])})
	# 数值相同时稳定排序，列表不会在等额更新时抖动。
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["id"] < b["id"] if a["value"] == b["value"] else a["value"] > b["value"])
	var elapsed := float(_snap["time"])
	var base_y := 57.0
	for row in rows:
		var active: bool = threat and row["id"] == target.get("target_id", -1)
		var value: float = row["value"]
		var amount := "%d" % roundi(value) if threat else "%d / %.1f" % [roundi(value), value / elapsed if elapsed > 0.0 else 0.0]
		var lead: float = maxf(1.0, rows[0]["value"])
		var color := Color("ffd28d") if active else Color("dce9f9")
		draw_rect(Rect2(rect.position + Vector2(9, base_y - 13), Vector2((rect.size.x - 18) * value / lead, 19)), Color(0.28, 0.40, 0.58, 0.35))
		_text(rect.position + Vector2(12, base_y + 2), ("▶ " if active else "") + row["name"], 17, color)
		_text(rect.position + Vector2(73, base_y + 2), amount, 16, color, rect.size.x - 85, HORIZONTAL_ALIGNMENT_RIGHT)
		base_y += 27
	if threat and "taunt" in target.get("statuses", []):
		_text(rect.position + Vector2(12, 163), "嘲讽中", 15, Color("ffd28d"))


## 为信息框和设置项提供一致的暗底、描边及可点击边界。
func _draw_panel(rect: Rect2) -> void:
	draw_rect(rect, Color("101925ee"))
	draw_rect(rect, Color("52657c"), false, 1.0)


## 当前设置值与实际命中矩形共用行定义。
func _option_rect(index: int) -> Rect2:
	return Rect2(692, 404 + 69 * index, 532, 50)


## 两组显示档位使用同一行几何，保证不可用档位也能正确拦截点击。
func _display_option_rect(row: int, index: int) -> Rect2:
	if index == 0:
		return Rect2(692, 625 + 82 * row, 106, 34)
	return Rect2(804 + 71 * (index - 1), 625 + 82 * row, 65, 34)


## 标记玩家选择并灰显超过当前上限的档位，生效回退时标记跟随系统。
func _draw_display_options(prefs: Dictionary) -> void:
	var limits: Dictionary = _hud.get("display", {})
	for row in 2:
		var key := "fps" if row == 0 else "resolution"
		var choices := DisplayPreferences.FPS_CHOICES if row == 0 else DisplayPreferences.RESOLUTION_CHOICES
		var limit := int(limits.get(key, 0))
		var selected := int(prefs.get(key, 0))
		var header := "画面帧率上限" if row == 0 else "显示分辨率"
		_text(Vector2(694, 617 + 82 * row), header, 19, Color("adc1df"))
		for index in choices.size():
			var value: int = choices[index]
			var rect := _display_option_rect(row, index)
			var available := value == 0 or value <= limit
			var active := available and (value == selected or value == 0 and selected > limit)
			var label := "跟随系统" if value == 0 else ("%d Hz" % value if row == 0 else ("%dp" % value if value < 2160 else "4K"))
			draw_rect(rect, Color("254267") if active else Color("101925"))
			draw_rect(rect, Color("668dba") if active else Color("39485d"), false, 1.0)
			_text(rect.position + Vector2(0, 23), label, 16, Color("eef3ff") if available else Color("65738a"), rect.size.x, HORIZONTAL_ALIGNMENT_CENTER)


## 暂停设置保留清晰的模态边界，关闭操作与鼠标选项均由场景消费。
func _draw_settings() -> void:
	draw_rect(Rect2(0, 0, 1920, 1080), Color(0, 0, 0, 0.60))
	_draw_panel(SETTINGS_PANEL)
	_text(SETTINGS_PANEL.position + Vector2(34, 47), "战斗设置", 30, Color("eef3ff"))
	var prefs: Dictionary = _hud["prefs"]
	var items := ["身份显示     %s" % ("名称" if prefs["names"] else "头像"),
		"施法方式     %s" % ("按住预览，松开施放" if prefs["release_cast"] else "按下立即施放"),
		"Tab 排序     %s" % ("当前生命值最低" if prefs["tab_health"] else "就近")]
	for index in items.size():
		var row := _option_rect(index)
		_draw_panel(row)
		_text(row.position + Vector2(15, 33), items[index], 21, Color("eef3ff"))
	_draw_display_options(prefs)
	_draw_panel(SETTINGS_CLOSE)
	_text(SETTINGS_CLOSE.position + Vector2(27, 27), "关闭", 18, Color("eef3ff"))
	_text(Vector2(693, 826), _toast if not _toast.is_empty() else "关闭后按 P 继续", 18, Color("adc1df"))


## 保留原结果矩形和样式；隔离画面只说明验证结束，不宣称奖励、存档或正式出征。
func _draw_result() -> void:
	draw_rect(Rect2(0, 0, 1920, 1080), Color(0, 0, 0, 0.6))
	var won: bool = _snap["result"] == "win"
	var title_color := Color("6fe08a") if won else Color("ff6b6b")
	var title := "胜利" if won else "失败"
	if _snap["reason"] == "retreated":
		title = "已撤退"
	if _snap.get("skill_formal", false) and _snap["result"] == "error":
		title = "战斗中止"
	_text(Vector2(0, 460), title, 96, title_color, 1920.0, HORIZONTAL_ALIGNMENT_CENTER)
	_text(Vector2(0, 520), String(RESULT_REASON.get(_snap["reason"], _snap["reason"])), 30, Color.WHITE, 1920.0, HORIZONTAL_ALIGNMENT_CENTER)
	_text(Vector2(0, 566), "用时 %.1f 秒" % float(_snap["time"]), 26, Color(1, 1, 1, 0.8), 1920.0, HORIZONTAL_ALIGNMENT_CENTER)
	# 原日志路径行改为玩家提示；保存异常不能被领奖指引盖住，提示均放在返回按钮上方。
	if _notice != "":
		_text(Vector2(0, 606), _notice, 26, Color("ffb070"), 1920.0, HORIZONTAL_ALIGNMENT_CENTER)
	elif won:
		_text(Vector2(0, 606), "隔离验证结束；未接正式出征、奖励或存档。" if _snap.get("skill_validation", false) else "返回酒馆，在「出征准备」中查看并领取战利品。", 26, Color("6fe08a"), 1920.0, HORIZONTAL_ALIGNMENT_CENTER)
	else:
		_text(Vector2(0, 606), "隔离验证结束；未接正式出征、奖励或存档。" if _snap.get("skill_validation", false) else "本次没有奖励，也不会损失已有装备，可回酒馆整备后再试。", 26, Color(1, 1, 1, 0.85), 1920.0, HORIZONTAL_ALIGNMENT_CENTER)
	draw_rect(BACK_BUTTON, Color(0.15, 0.2, 0.3, 0.95))
	draw_rect(BACK_BUTTON, Color.WHITE, false, 2.0)
	_text(BACK_BUTTON.position + Vector2(0, 46), "验证已结束" if _snap.get("skill_validation", false) else _back_text, 28, Color.WHITE, BACK_BUTTON.size.x, HORIZONTAL_ALIGNMENT_CENTER)


## 长配置参数放在既有文字提示行，不挪矩形或缩字号；参数是配置而非预计结算值。
func _skill_configuration_text() -> String:
	for unit: Dictionary in _snap.get("units", []):
		if unit["side"] != "ally" or unit["slot"] != _selected_slot:
			continue
		for view: Dictionary in _snap["skills"].get(unit["id"], []):
			if view["slot"] != _snap.get("skill_focus_slot", "R"):
				continue
			if view["empty"]:
				return String(view["slot"]) + " 空槽"
			var status: String = reason_text(view["reason"]) if not view["preparable"] else "规则准备通过"
			var text: String = "%s %s；%s；%s。配置：" % [view["slot"], view["name"], "已接入" if view["implemented"] else "未接入", status]
			for effect: Dictionary in view["effects"]:
				text += "%s/%s %sP+%s 半径%sm 时长%ss 暴击%s 专精%s " % [{"MAGIC_DAMAGE": "伤害", "SHIELD": "盾", "HEAL": "治疗", "RESTORE_MANA": "回蓝"}.get(effect.get("kind"), "?"), {"SELF": "自身", "PRIMARY": "主目标", "ENEMIES_AROUND_PRIMARY": "目标周边"}.get(effect.get("selector"), "?"), effect.get("power_coeff"), effect.get("flat_amount"), effect.get("radius_m"), effect.get("duration_s"), effect.get("uses_stable_crit"), effect.get("uses_mastery")]
			return text
	return "未选择角色"
