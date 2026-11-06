extends Node
## 酒馆界面（灰盒控件）：常驻栏（按槽位的队伍栏 + 三个功能按钮）和招募 / 整备 / 出征三个面板。
## 数据和规则都在 TavernRoster（背后是 P2 的存档服务）；这里只摆控件、把按钮接到 roster 的动作上。
## 面板开关走逻辑层（TavernSim）：这里不改 sim，只发信号请求，场景脚本去调 sim.open_panel / close_panel。
## 每次改动都是一次存档提交；写失败时数据回到改前，面板顶上出现「未保存，本次修改未生效」和重试。

const TavernRoster := preload("res://scripts/tavern/tavern_roster.gd")
const CjkFont := preload("res://scenes/ui/cjk_font.gd")

signal open_requested(kind: String)
signal close_requested
signal party_changed
signal notice(text: String)
## 确认出征成功（最新配置已保存）：场景据此锁定名单并加载战斗。
signal sortie_confirmed(roster_list: Array)
signal retry_load_requested

const PANEL_RECT := Rect2(360, 80, 1200, 860)
const TITLE := {"recruit": "招募伙伴", "prepare": "整备队伍", "sortie": "准备出征"}
const FAIL_TEXT := "未保存，本次修改未生效"
const REASON_TEXT := {
	"already_recruited": "已经在队伍里了",
	"no_free_slot": "队伍已满（4/4）",
	"edge": "已经在边缘，不能再移动",
	"not_owned": "还没有这件装备",
	"busy": "正在保存，请稍等",
	"blocked": "前置检查未通过",
	"class_complete": "该职业的奖励已经齐了，请换一个职业",
}
const GOOD := Color("7ad07a")
const BAD := Color("e07a6a")
const DIM := Color(1, 1, 1, 0.6)

var roster: TavernRoster
var _hud: Control
var _hud_party: VBoxContainer
var _backdrop: ColorRect
var _panel: PanelContainer
var _title: Label
var _banner_box: HBoxContainer
var _body: VBoxContainer

var _kind: String = ""
var _target: String = ""
var _prepare_return: String = ""
var _next_return: String = ""
var _sortie_mode: String = "main"
var _locked_roster: Array = []
var _load_state: String = ""
var _load_reason: String = ""
var _equip_slot: String = ""
var _preview_item: String = ""
var _banner: Dictionary = {}
var _busy: bool = false
var _dirty: bool = true


func setup(tavern_roster: TavernRoster) -> void:
	roster = tavern_roster
	var theme := Theme.new()
	theme.default_font = CjkFont.get_font()
	theme.default_font_size = 20
	_build_panel_layer(theme)
	_build_hud_layer(theme)
	_set_panel_visible(false)


# ── 搭骨架 ──

func _build_panel_layer(theme: Theme) -> void:
	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = theme
	layer.add_child(root)
	_backdrop = ColorRect.new()
	_backdrop.name = "backdrop"
	_backdrop.color = Color(0, 0, 0, 0.4)
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(_backdrop)
	_panel = PanelContainer.new()
	_panel.name = "panel"
	_panel.position = PANEL_RECT.position
	_panel.custom_minimum_size = PANEL_RECT.size
	_panel.size = PANEL_RECT.size
	_panel.clip_contents = true
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = Color("1b1410")
	style.border_color = Color(1, 1, 1, 0.35)
	style.set_border_width_all(3)
	style.set_content_margin_all(18)
	_panel.add_theme_stylebox_override("panel", style)
	root.add_child(_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	_panel.add_child(column)
	var header := HBoxContainer.new()
	column.add_child(header)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 34)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_title)
	var close := _button(header, "关闭", func() -> void:
		if _load_state != "loading":
			close_requested.emit(), "panel_close")
	close.custom_minimum_size = Vector2(96, 44)
	_banner_box = HBoxContainer.new()
	_banner_box.name = "banner"
	column.add_child(_banner_box)
	_body = VBoxContainer.new()
	_body.name = "body"
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 10)
	column.add_child(_body)


func _build_hud_layer(theme: Theme) -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	_hud = Control.new()
	_hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.theme = theme
	layer.add_child(_hud)
	var caption := Label.new()
	caption.text = "队伍"
	caption.position = Vector2(16, 110)
	caption.add_theme_color_override("font_color", DIM)
	_hud.add_child(caption)
	_hud_party = VBoxContainer.new()
	_hud_party.name = "party_bar"
	_hud_party.position = Vector2(16, 144)
	_hud.add_child(_hud_party)
	var bar := HBoxContainer.new()
	bar.name = "function_bar"
	bar.position = Vector2(960 - 270, 996)
	bar.add_theme_constant_override("separation", 12)
	_hud.add_child(bar)
	for pair: Array in [["recruit", "招募伙伴"], ["prepare", "队伍整备"], ["sortie", "出征准备"]]:
		var kind := String(pair[0])
		var btn := _button(bar, String(pair[1]), func() -> void: _open_from_hud(kind), "hud_" + kind)
		btn.custom_minimum_size = Vector2(170, 56)


func _set_panel_visible(shown: bool) -> void:
	_backdrop.visible = shown
	_panel.visible = shown


# ── 控件小工具 ──

func _button(parent: Node, text: String, action: Callable, node_name: String = "", disabled: bool = false) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.focus_mode = Control.FOCUS_NONE
	btn.disabled = disabled
	if node_name != "":
		btn.name = node_name
	btn.pressed.connect(action)
	parent.add_child(btn)
	return btn


func _label(parent: Node, text: String, size: int = 20, color: Color = Color.WHITE) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	if parent is VBoxContainer:
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	return label


func _vbox(parent: Node, width: float = 0.0, node_name: String = "") -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	if width > 0.0:
		box.custom_minimum_size = Vector2(width, 0)
	if node_name != "":
		box.name = node_name
	parent.add_child(box)
	return box


func _hbox(parent: Node, node_name: String = "") -> HBoxContainer:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	if node_name != "":
		box.name = node_name
	parent.add_child(box)
	return box


func _clear(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()


func find_button(node_name: String) -> Button:
	return get_tree().root.find_child(node_name, true, false) as Button if is_inside_tree() else null


# ── 与场景对接 ──

## 每帧调用：面板种类变了就换内容，数据脏了就重摆。
func sync(kind: String) -> void:
	if kind != _kind:
		_kind = kind
		_banner = {}
		_equip_slot = ""
		_preview_item = ""
		if kind == "prepare":
			_prepare_return = _next_return
		else:
			_prepare_return = ""
		_next_return = ""
		if kind == "sortie":
			_sortie_mode = "main"
			_load_state = ""
		_set_panel_visible(kind != "")
		_dirty = true
	if _dirty:
		_dirty = false
		_rebuild()


## Esc 先问这里：有更里面一层就退一层并返回 true，否则交给逻辑层关面板。
func handle_escape() -> bool:
	if _load_state == "loading":
		return true  # 加载中不接受任何操作
	if _load_state == "failed":
		return false  # 加载失败页：Esc 等于返回酒馆（关面板）
	if _kind == "prepare" and _prepare_return == "sortie":
		open_requested.emit("sortie")
		return true
	if _kind == "sortie" and _sortie_mode != "main":
		_sortie_mode = "main"
		_dirty = true
		return true
	return false


## 场景告诉界面加载战斗的进度：loading / failed / ""。
func set_load_state(state: String, reason: String) -> void:
	_load_state = state
	_load_reason = reason
	_dirty = true


func mark_dirty() -> void:
	_dirty = true


func has_failure_banner() -> bool:
	return not _banner.is_empty()


func _open_from_hud(kind: String) -> void:
	if _load_state == "loading":
		return
	_next_return = ""
	open_requested.emit(kind)


func _open_prepare_for(class_id: String, from_kind: String = "") -> void:
	if _load_state == "loading":
		return
	_target = class_id
	_next_return = from_kind
	_dirty = true
	open_requested.emit("prepare")


# ── 动作：全部走存档服务，写失败给重试 ──

func _run(action: Callable, ok_text: String = "", on_ok: Callable = Callable()) -> Dictionary:
	if _busy:
		return {"ok": false, "reason": "busy"}
	_busy = true
	var result: Dictionary = action.call()
	_busy = false
	if bool(result.get("ok", false)):
		_banner = {}
		if ok_text != "":
			notice.emit(ok_text)
		if on_ok.is_valid():
			on_ok.call(result)
		party_changed.emit()
	elif String(result.get("reason", "")) == "write_failed":
		_banner = {"retry": action, "ok_text": ok_text, "on_ok": on_ok}
	else:
		var reason := String(result.get("reason", ""))
		notice.emit(String(REASON_TEXT.get(reason, "操作未生效（%s）" % reason)))
	_dirty = true
	return result


func _retry() -> void:
	var failed := _banner
	if failed.is_empty():
		return
	_run(failed["retry"] as Callable, String(failed["ok_text"]), failed["on_ok"] as Callable)


# ── 重摆 ──

func _rebuild() -> void:
	_rebuild_hud()
	if _kind == "":
		return
	_title.text = String(TITLE.get(_kind, _kind))
	_rebuild_banner()
	_clear(_body)
	match _kind:
		"recruit":
			_build_recruit()
		"prepare":
			_build_prepare()
		"sortie":
			_build_sortie()


func _rebuild_hud() -> void:
	_clear(_hud_party)
	for slot: Dictionary in roster.slots_view():
		var class_id := String(slot["class_id"])
		var number := int(slot["number"])
		if class_id == "":
			var empty := _button(_hud_party, "%d  空位 ＋招募" % number, func() -> void: _open_from_hud("recruit"), "party_slot_%d" % number)
			empty.custom_minimum_size = Vector2(180, 44)
			empty.modulate = Color(1, 1, 1, 0.6)
		else:
			var text := "%d  %s%s" % [number, String(slot["name"]), "  ★队长" if bool(slot["captain"]) else ""]
			var member := _button(_hud_party, text, func() -> void: _open_prepare_for(class_id), "party_slot_%d" % number)
			member.custom_minimum_size = Vector2(180, 44)
			member.modulate = (slot["color"] as Color).lerp(Color.WHITE, 0.55)


func _rebuild_banner() -> void:
	_clear(_banner_box)
	if _banner.is_empty():
		return
	var text := _label(_banner_box, FAIL_TEXT, 22, BAD)
	text.name = "banner_text"
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_button(_banner_box, "重试", _retry, "banner_retry")


# ── 招募面板 ──

func _build_recruit() -> void:
	var count := roster.party_count()
	var line := "当前 %d/4 人" % count + ("，可出征" if count >= 1 else "，招募第一名队员后队长会出现在酒馆里")
	_label(_body, line, 22, GOOD if count >= 1 else Color(1, 0.9, 0.6)).name = "recruit_summary"
	var row := _hbox(_body, "recruit_cards")
	var buttons := _hbox(_body, "recruit_buttons")
	for class_id: String in roster.service.table.class_ids:
		var card := roster.class_card(class_id)
		var col := _vbox(row, 290, "card_" + class_id)
		var name_label := _label(col, String(card["name"]), 30, roster.class_color(class_id).lerp(Color.WHITE, 0.4))
		name_label.name = "card_name"
		_label(col, "生命 %d　护甲 %d　魔抗 %d　移速 %d" % [card["max_hp"], card["armor"], card["magic_resist"], card["speed"]], 17, DIM)
		_label(col, "资源：%s" % String(card["resource"]), 17, DIM)
		_label(col, String(card["attack"]), 17, DIM)
		for skill: Dictionary in card["skills"]:
			_label(col, "[%s] %s\n    %s" % [skill["key"], skill["name"], skill["text"]], 17)
		var joined := bool(card["recruited"])
		var full := roster.party_count() >= 4
		var text := "已加入" if joined else ("队伍已满" if full else "加入队伍")
		var btn := _button(buttons, text, func() -> void: _recruit(class_id), "recruit_" + class_id, joined or full)
		btn.custom_minimum_size = Vector2(280, 52)


func _recruit(class_id: String) -> void:
	var first := roster.party_count() == 0
	var label := roster.class_name_of(class_id)
	var text := "%s 已加入队伍" % label + ("，队长出现在酒馆里" if first else "")
	_run(func() -> Dictionary: return roster.service.recruit(class_id), text)


# ── 整备面板 ──

func _build_prepare() -> void:
	if roster.party_count() == 0:
		_label(_body, "还没有队员，先去招募第一名队员。", 24, Color(1, 0.9, 0.6))
		_button(_body, "去招募", func() -> void: open_requested.emit("recruit"), "prepare_to_recruit")
		return
	if _target == "" or not roster.service.is_recruited(_target):
		_target = roster.inspected_class()
	_build_prepare_heads()
	var cols := _hbox(_body, "prepare_cols")
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build_member_column(_vbox(cols, 360, "col_member"))
	_build_equip_column(_vbox(cols, 400, "col_equip"))
	_build_talent_column(_vbox(cols, 380, "col_talent"))
	var foot := _hbox(_body, "prepare_foot")
	if _prepare_return == "sortie":
		_button(foot, "返回出征", func() -> void: open_requested.emit("sortie"), "prepare_back_sortie")
	else:
		_button(foot, "去出征准备", func() -> void: open_requested.emit("sortie"), "prepare_to_sortie")


func _build_prepare_heads() -> void:
	var heads := _hbox(_body, "slot_heads")
	var slots: Array = roster.slots_view()
	for slot: Dictionary in slots:
		var class_id := String(slot["class_id"])
		var number := int(slot["number"])
		var col := _vbox(heads, 280, "head_%d" % number)
		if class_id == "":
			var empty := _button(col, "%d  空位：招募队员" % number, func() -> void: open_requested.emit("recruit"), "head_btn_%d" % number)
			empty.custom_minimum_size = Vector2(0, 46)
			continue
		var viewed := class_id == _target
		var text := "%s%d  %s%s" % ["▶ " if viewed else "", number, String(slot["name"]), " ★" if bool(slot["captain"]) else ""]
		var head := _button(col, text, func() -> void: _view_member(class_id), "head_btn_%d" % number)
		head.custom_minimum_size = Vector2(0, 46)
		head.modulate = (slot["color"] as Color).lerp(Color.WHITE, 0.55) if viewed else Color(1, 1, 1, 0.8)
		var moves := _hbox(col)
		var prev := _button(moves, "◀ 前移", func() -> void: _run(func() -> Dictionary: return roster.service.move_member(class_id, -1)), "move_prev_%d" % number, int(slot["slot"]) == 0)
		var next := _button(moves, "后移 ▶", func() -> void: _run(func() -> Dictionary: return roster.service.move_member(class_id, 1)), "move_next_%d" % number, int(slot["slot"]) == 3)
		prev.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		next.size_flags_horizontal = Control.SIZE_EXPAND_FILL


func _view_member(class_id: String) -> void:
	_target = class_id
	_equip_slot = ""
	_preview_item = ""
	_dirty = true


func _build_member_column(col: VBoxContainer) -> void:
	var view := roster.member_view(_target)
	_label(col, "%s%s" % [String(view["name"]), "（队长）" if bool(view["captain"]) else ""], 28, roster.class_color(_target).lerp(Color.WHITE, 0.4))
	_label(col, "生命 %d　护甲 %d　魔抗 %d　移速 %d" % [view["max_hp"], view["armor"], view["magic_resist"], view["speed"]], 17, DIM)
	_label(col, "资源：%s　%s" % [String(view["resource"]), String(view["attack"])], 17, DIM)
	var status: Dictionary = view["set"]
	_label(col, "套装：%s" % String(status["text"]), 18, GOOD if bool(status["active"]) else DIM).name = "set_status"
	var target := _target
	var captain_btn := _button(col, "已是队长" if bool(view["captain"]) else "设为队长", func() -> void: _run(func() -> Dictionary: return roster.service.set_captain(target), "已将 %s 设为队长" % roster.class_name_of(target)), "set_captain", bool(view["captain"]))
	captain_btn.custom_minimum_size = Vector2(0, 44)
	_label(col, "技能（含当前天赋与套装）", 18, DIM)
	for skill: Dictionary in view["skills"]:
		_label(col, "[%s] %s\n    %s" % [skill["key"], skill["name"], skill["text"]], 17)


func _build_equip_column(col: VBoxContainer) -> void:
	_label(col, "装备", 22, DIM)
	var rows := roster.equip_view(_target)
	for row: Dictionary in rows:
		var slot_id := String(row["slot"])
		var text := "%s：%s" % [row["slot_name"], row["current_name"]]
		var btn := _button(col, ("▶ " if slot_id == _equip_slot else "") + text, func() -> void: _pick_slot(slot_id), "equip_slot_" + slot_id)
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	if _equip_slot == "":
		_label(col, "点一个装备栏，查看可替换的装备", 17, DIM)
		return
	var chosen: Dictionary = {}
	for row: Dictionary in rows:
		if String(row["slot"]) == _equip_slot:
			chosen = row
	var candidates: Array = chosen.get("candidates", [])
	if candidates.is_empty():
		_label(col, "暂无其他可用装备", 18, Color(1, 0.9, 0.6)).name = "no_candidates"
		return
	_label(col, "可替换（点选预览，确认后才生效）", 17, DIM)
	for candidate: Dictionary in candidates:
		var item_id := String(candidate["id"])
		var cand_btn := _button(col, ("▶ " if item_id == _preview_item else "") + String(candidate["name"]), func() -> void: _pick_candidate(item_id), "candidate_" + item_id)
		cand_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	if _preview_item != "":
		var info := roster.preview(_target, _preview_item)
		_label(col, String(info.get("text", "")), 17, Color(0.9, 0.9, 0.6)).name = "preview_text"
		_button(col, "装备", func() -> void: _equip_previewed(), "equip_confirm")


func _pick_slot(slot_id: String) -> void:
	_equip_slot = slot_id
	_preview_item = ""
	_dirty = true


func _pick_candidate(item_id: String) -> void:
	_preview_item = item_id
	_dirty = true


func _equip_previewed() -> void:
	var item_id := _preview_item
	var target := _target
	_run(func() -> Dictionary: return roster.service.equip(target, item_id), "已装备 %s" % roster.item_name(item_id), func(_r: Dictionary) -> void: _preview_item = "")


func _build_talent_column(col: VBoxContainer) -> void:
	_label(col, "天赋（二选一）", 22, DIM)
	var names := {"t1": "天赋一", "t2": "天赋二"}
	for option: Dictionary in roster.talent_options(_target):
		var talent := String(option["id"])
		_label(col, "%s%s" % [String(names.get(talent, talent)), "（当前）" if bool(option["active"]) else ""], 22, GOOD if bool(option["active"]) else Color.WHITE)
		var joined_text := ""
		for line: Dictionary in option["lines"]:
			var l := _label(col, "%s %s" % ["▲" if bool(line["good"]) else "▼", String(line["text"])], 18, GOOD if bool(line["good"]) else BAD)
			joined_text += String(line["text"])
		for skill: Dictionary in option["skills"]:
			if joined_text.contains(String(skill["name"])):
				_label(col, "→ 最终：%s　%s" % [skill["name"], skill["text"]], 16, DIM)
		var btn := _button(col, "当前天赋" if bool(option["active"]) else "选择", func() -> void: _pick_talent(talent), "talent_" + talent, bool(option["active"]))
		btn.custom_minimum_size = Vector2(0, 40)


func _pick_talent(talent: String) -> void:
	var target := _target
	_run(func() -> Dictionary: return roster.service.set_talent(target, talent), "天赋已改为 %s" % talent)


# ── 出征面板 ──

func _build_sortie() -> void:
	match _sortie_mode:
		"reward":
			_build_reward()
		"locked":
			_build_locked()
		_:
			_build_sortie_main()


func _build_sortie_main() -> void:
	var view := roster.sortie_view()
	var stage: Dictionary = view["stage"]
	var cols := _hbox(_body, "sortie_cols")
	var left := _vbox(cols, 520, "stage_info")
	_label(left, String(stage["name"]), 30)
	_label(left, "目标：%s" % String(stage["goal"]), 20)
	var notes: Array = stage["enemy_notes"]
	if notes.is_empty():
		_label(left, "敌人：%s" % String(stage["enemies"]), 20)
	else:
		_label(left, "敌人", 20)
		for note: String in notes:
			_label(left, "· %s" % note, 18)
	for line: String in stage["mechanics"]:
		_label(left, "提示：%s" % line, 18, Color(0.95, 0.85, 0.55))
	_label(left, "奖励：%s" % String(stage["reward"]), 20, DIM)
	var right := _vbox(cols, 600, "party_summary")
	_label(right, "出战队伍", 24)
	for entry: Dictionary in view["party"]:
		var row := _hbox(right, "sortie_row_%d" % int(entry["number"]))
		var class_id := String(entry["class_id"])
		if class_id == "":
			var empty := _label(row, "%d  空位" % int(entry["number"]), 20, DIM)
			empty.custom_minimum_size = Vector2(500, 0)
			continue
		var text := "%d  %s%s　%s　天赋 %s" % [entry["number"], entry["name"], " ★" if bool(entry["captain"]) else "", entry["set_text"], entry["talent"]]
		var info := _label(row, text, 20, BAD if bool(entry["flagged"]) else Color.WHITE)
		info.custom_minimum_size = Vector2(470, 0)
		_button(row, "整备", func() -> void: _open_prepare_for(class_id, "sortie"), "sortie_prepare_%d" % int(entry["number"]))
	_label(right, String(view["hint"]), 16, DIM)
	_label(_body, String(view["summary"]), 22, GOOD if bool(view["ok"]) else Color(1, 0.9, 0.6)).name = "sortie_summary"
	for blocker: Dictionary in view["blockers"]:
		var row := _hbox(_body, "blocker_" + String(blocker["code"]))
		_label(row, String(blocker["text"]), 20, BAD)
		var action := String(blocker["action"])
		var class_id := String(blocker["class_id"])
		_button(row, String(blocker["action_text"]), func() -> void: _blocker_action(action, class_id), "blocker_action_" + String(blocker["code"]))
	var confirm := _button(_body, "确认出征", _confirm_sortie, "sortie_confirm", not bool(view["ok"]))
	confirm.custom_minimum_size = Vector2(260, 56)


func _blocker_action(action: String, class_id: String) -> void:
	match action:
		"recruit":
			open_requested.emit("recruit")
		"claim":
			_sortie_mode = "reward"
			_dirty = true
		"prepare":
			_open_prepare_for(class_id if class_id != "" else roster.inspected_class(), "sortie")


func _confirm_sortie() -> void:
	_run(func() -> Dictionary: return roster.confirm_sortie(), "", func(result: Dictionary) -> void:
		_locked_roster = result["roster"]
		_sortie_mode = "locked"
		_load_state = "loading"
		sortie_confirmed.emit(_locked_roster))


func _build_locked() -> void:
	_label(_body, "前置检查通过，最新配置已保存", 28, GOOD).name = "locked_title"
	_label(_body, "已锁定的出战名单（按战斗快捷键 1–4 顺序）：", 20, DIM)
	for entry: Dictionary in _locked_roster:
		_label(_body, "%d  %s%s　%s　天赋 %s" % [entry["slot"], entry["name"], " ★队长" if bool(entry["captain"]) else "", entry["set_text"], entry["talent"]], 22)
	if _load_state == "loading":
		_label(_body, "正在前往 %s …" % String(roster.stage_view()["name"]), 26, Color(1, 0.9, 0.6)).name = "loading_text"
	elif _load_state == "failed":
		_label(_body, "加载失败：%s" % _load_reason, 24, BAD).name = "load_failed_text"
		var row := _hbox(_body, "load_failed_row")
		_button(row, "重试", func() -> void: retry_load_requested.emit(), "load_retry")
		_button(row, "返回酒馆", func() -> void: close_requested.emit(), "load_back_tavern")
	else:
		_button(_body, "返回出征准备", _back_to_main, "locked_back")


func _build_reward() -> void:
	_label(_body, "领取战利品：先选职业，再选一件还没拥有的装备", 24)
	for entry: Dictionary in roster.reward_view():
		var class_id := String(entry["class_id"])
		var row := _hbox(_body, "reward_" + class_id)
		var title := _label(row, String(entry["name"]), 22)
		title.custom_minimum_size = Vector2(120, 0)
		if (entry["items"] as Array).is_empty():
			_label(row, "已经齐了，请换一个职业", 18, DIM)
		for item: Dictionary in entry["items"]:
			var item_id := String(item["id"])
			_button(row, "%s（%s）" % [item["name"], item["slot_name"]], func() -> void: _claim(class_id, item_id), "claim_" + item_id)
	_button(_body, "返回", _back_to_main, "reward_back")


func _claim(class_id: String, item_id: String) -> void:
	_run(func() -> Dictionary: return roster.service.claim(class_id, item_id), "已领取 %s" % roster.item_name(item_id), func(_r: Dictionary) -> void: _sortie_mode = "main")


func _back_to_main() -> void:
	_sortie_mode = "main"
	_dirty = true
