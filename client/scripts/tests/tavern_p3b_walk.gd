extends SceneTree
## P3b 整段走查（开窗口，真的用注入鼠标点控件中心）：从空存档起走操作稿 §1.11 的四个示例，
## 加上顺序调整、Esc 层级、保存失败和重试。前后存档 JSON 与截图写到 --out 目录。用法：
##   godot --path client --script res://scripts/tests/tavern_p3b_walk.gd -- --save=/tmp/p3b.json --out=/tmp/p3b
## --save 指向的文件会先被删掉。打印 PASS / FAIL，有失败退出码 1。

var _dir: String = "/tmp/p3b"
var _save: String = "/tmp/p3b.json"
var _scene: Node = null
var _failures: int = 0
var _opened: Array[String] = []
const SortieSession := preload("res://scripts/tavern/sortie_session.gd")


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_dir = arg.get_slice("=", 1)
		if arg.begins_with("--save="):
			_save = arg.get_slice("=", 1)
	DirAccess.make_dir_recursive_absolute(_dir)
	if FileAccess.file_exists(_save):
		DirAccess.remove_absolute(_save)
	_scene = load("res://scenes/tavern/tavern.tscn").instantiate()
	root.add_child(_scene)
	_run.call_deferred()


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		print("PASS  ", name)
	else:
		_failures += 1
		print("FAIL  ", name, "  ", detail)


func _shot(name: String) -> void:
	for i in 5:
		await process_frame
	root.get_texture().get_image().save_png("%s/%s.png" % [_dir, name])


func _dump(name: String) -> Dictionary:
	var text := FileAccess.get_file_as_string(_save) if FileAccess.file_exists(_save) else "{}"
	var file := FileAccess.open("%s/%s.json" % [_dir, name], FileAccess.WRITE)
	file.store_string(text)
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


func _file_text() -> String:
	return FileAccess.get_file_as_string(_save) if FileAccess.file_exists(_save) else ""


func _mouse(button: int, canvas_pos: Vector2) -> void:
	var pos := canvas_pos / 1.5
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	motion.global_position = pos
	Input.parse_input_event(motion)
	await process_frame
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.position = pos
	event.global_position = pos
	event.pressed = true
	Input.parse_input_event(event)
	await process_frame
	event.pressed = false
	Input.parse_input_event(event)
	await process_frame
	await process_frame


func _node(node_name: String) -> Control:
	return root.find_child(node_name, true, false) as Control


func _click(node_name: String) -> bool:
	await process_frame
	await process_frame
	var node := _node(node_name)
	if node == null or not node.is_visible_in_tree():
		print("  （找不到可见控件 %s）" % node_name)
		return false
	await _mouse(MOUSE_BUTTON_LEFT, node.get_global_rect().get_center())
	for i in 3:
		await process_frame
	return true


func _has(node_name: String) -> bool:
	var node := _node(node_name)
	return node != null and node.is_visible_in_tree()


func _disabled(node_name: String) -> bool:
	var node := _node(node_name) as Button
	return node != null and node.disabled


func _esc() -> void:
	var event := InputEventAction.new()
	event.action = "cancel_layer"
	event.pressed = true
	Input.parse_input_event(event)
	await process_frame
	event.pressed = false
	Input.parse_input_event(event)
	await process_frame
	await process_frame


func _wait_idle() -> void:
	var guard := 0
	while _scene.sim.is_moving() and guard < 150:
		await create_timer(0.2).timeout
		guard += 1
	await process_frame


func _run() -> void:
	var sim = _scene.sim
	var service = _scene.service
	sim.events.panel_opened.connect(func(kind: String) -> void: _opened.append(kind))
	await create_timer(0.4).timeout

	print("── 示例一：首次出征（空存档）──")
	_check("空存档：场景里没有队长，队伍 0/4", not sim.has_captain and service.members().is_empty())
	await _shot("A00_empty")
	_dump("A00_save_before_missing")
	await _click("hud_sortie")
	_check("零成员打开出征面板：确认出征禁用，出现「至少需要一名队员」", sim.panel == "sortie" and _disabled("sortie_confirm") and _has("blocker_no_party"))
	await _shot("A01_sortie_zero")
	await _click("blocker_action_no_party")
	_check("点「去招募」：切到招募面板", sim.panel == "recruit", sim.panel)
	_check("招募卡四个都在，「加入队伍」可点", _has("recruit_warrior") and _has("recruit_mage") and not _disabled("recruit_warrior"))
	await _shot("A02_recruit_panel")
	await _click("recruit_warrior")
	var after := _dump("A03_save_after_first_recruit")
	_check("第一人入队：存档 slots[0]=warrior、队长槽 0、8 件装备", (after["slots"] as Array)[0] == "warrior" and int(after["captainSlot"]) == 0 and (after["equips"]["warrior"] as Dictionary).size() == 8, str(after.get("slots")))
	_check("队长出现在出生点，是战士", sim.has_captain and sim.captain_class == "warrior" and sim.captain_pos == sim.spawn_pos())
	_check("「已加入」且不能重复", _disabled("recruit_warrior") and (_node("recruit_warrior") as Button).text == "已加入")
	await _shot("A04_first_recruited")
	await _click("recruit_rogue")
	_check("第二人入队：队长仍是战士，没有第二个角色", sim.captain_class == "warrior" and service.members().size() == 2)
	await _click("panel_close")
	_check("关闭面板", sim.panel == "")
	await _click("hud_sortie")
	_check("出征面板：2/4 人，确认可点，没有强制补人要求", not _disabled("sortie_confirm") and not _has("blocker_no_party"))
	await _shot("A05_sortie_ready")
	var before_confirm := _file_text()
	# P4 起确认出征会真的加载战斗；这段只看前置检查，所以注入一次加载失败并拦住场景切换。
	SortieSession.goto_scene = func(_path: String) -> void: pass
	SortieSession.fail_load_left = 1
	await _click("sortie_confirm")
	_check("确认出征：前置检查通过，显示已锁定名单（本段注入加载失败，不进战斗）", _has("locked_title") and _has("load_failed_text"))
	_check("确认出征只做前置检查，存档内容不变（原样写盘）", JSON.stringify(JSON.parse_string(_file_text())) == JSON.stringify(JSON.parse_string(before_confirm)))
	await _shot("A06_sortie_locked")
	await _esc()
	_check("加载失败页按 Esc：关闭面板回酒馆", sim.panel == "")

	print("── 示例二：重复挑战（领奖 → 头像 → 换装 → 天赋 → 出征）──")
	var settled: Dictionary = service.settle("run_p3b_1", "win")
	_check("模拟一场胜利：待领奖", bool(settled["ok"]) and service.state["pendingReward"] != null, str(settled))
	_scene.ui.mark_dirty()
	await _click("hud_sortie")
	_check("有待领奖：确认出征禁用，出现领取战利品入口", _disabled("sortie_confirm") and _has("blocker_pending_reward"))
	await _shot("B00_pending")
	await _click("blocker_action_pending_reward")
	_check("点「领取战利品」：出现按职业的领取列表", _has("reward_warrior") and _has("claim_warrior_shoulder_set"))
	var owned_before: int = (service.state["ownedItems"] as Array).size()
	await _click("claim_warrior_shoulder_set")
	_check("领取后：多一件装备、待领奖清除、确认出征可点", (service.state["ownedItems"] as Array).size() == owned_before + 1 and service.state["pendingReward"] == null and not _disabled("sortie_confirm"))
	await _click("panel_close")
	await _click("party_slot_1")
	_check("点队伍栏战士头像：打开整备面板，场景队长不变", sim.panel == "prepare" and sim.captain_class == "warrior")
	await _click("equip_slot_shoulder")
	_check("肩膀栏有一件可替换的装备", _has("candidate_warrior_shoulder_set"))
	var equips_before: String = JSON.stringify(service.state["equips"])
	await _click("candidate_warrior_shoulder_set")
	_check("对比预览不改穿戴", JSON.stringify(service.state["equips"]) == equips_before and _has("preview_text"))
	await _shot("B01_preview")
	_dump("B02_save_before_equip")
	await _click("equip_confirm")
	_dump("B03_save_after_equip")
	_check("点「装备」后：肩膀换成奖励件，存档一致", service.state["equips"]["warrior"]["shoulder"] == "warrior_shoulder_set" and _file_text().contains("warrior_shoulder_set"))
	await _click("equip_slot_boots")
	_check("鞋子还没拿到：提示暂无其他可用装备", _has("no_candidates"))
	await _click("talent_t2")
	_check("改天赋：存档 talentId.warrior=t2，当前天赋按钮禁用", service.state["talentId"]["warrior"] == "t2" and _disabled("talent_t2"))
	await _shot("B04_prepare_after")
	await _click("hud_sortie")
	_check("出征面板显示 2 人摘要和天赋", _has("sortie_row_1") and _has("sortie_summary"))
	await _shot("B05_sortie_summary")
	await _click("panel_close")

	print("── 示例三：改变途中目标 ──")
	await _mouse(MOUSE_BUTTON_LEFT, Vector2(1100, 800))
	await _wait_idle()
	print("  起点 ", sim.captain_pos, " panel=", sim.panel)
	_opened.clear()
	await _mouse(MOUSE_BUTTON_LEFT, Vector2(280, 180))
	await create_timer(0.4).timeout
	_check("正在走向招募公告板", sim.is_moving() and sim.pending_object == "recruit", str(sim.pending_object))
	await _mouse(MOUSE_BUTTON_LEFT, Vector2(1400, 330))
	await _wait_idle()
	await create_timer(0.3).timeout
	print("  终点 ", sim.captain_pos, " panel=", sim.panel, " pending=", sim.pending_object)
	_check("改点整备桌：到达后开整备面板，招募面板没有随后弹出", sim.panel == "prepare" and not _opened.has("recruit") and _opened.count("prepare") == 1, str(_opened))
	await _click("panel_close")

	print("── 示例四：切换队长 ──")
	var slots_before: String = JSON.stringify(service.state["slots"])
	var equips_all: String = JSON.stringify(service.state["equips"])
	var pos_before: Vector2 = sim.captain_pos
	var facing_before: float = sim.captain_facing
	await _click("party_slot_2")
	_check("点盗贼头像查看：场景仍是战士", sim.panel == "prepare" and sim.captain_class == "warrior")
	await _shot("D00_view_rogue")
	_dump("D01_save_before_captain")
	await _click("set_captain")
	_dump("D02_save_after_captain")
	_check("设为队长：场景原地改为盗贼，位置朝向不变", sim.captain_class == "rogue" and sim.captain_pos == pos_before and is_equal_approx(sim.captain_facing, facing_before), "%s %s/%s %s/%s" % [sim.captain_class, sim.captain_pos, pos_before, sim.captain_facing, facing_before])
	_check("槽位顺序、全队装备不变，队长槽变为 1", JSON.stringify(service.state["slots"]) == slots_before and JSON.stringify(service.state["equips"]) == equips_all and int(service.state["captainSlot"]) == 1)
	_check("「设为队长」按钮变成「已是队长」且禁用", _disabled("set_captain"))
	await _shot("D03_captain_rogue")

	print("── 顺序调整 ──")
	await _click("move_prev_2")
	_check("盗贼前移：槽位 [rogue, warrior]，队长跟着到槽 0，查看对象仍是盗贼", service.state["slots"][0] == "rogue" and int(service.state["captainSlot"]) == 0 and _has("head_btn_1"))
	_check("最前面的成员「前移」禁用", _disabled("move_prev_1"))
	await _click("move_next_1")
	await _click("move_next_2")
	await _click("move_next_3")
	_check("连续后移到最后：槽位 [warrior, '', '', rogue]（跨过空槽）", service.state["slots"] == ["warrior", "", "", "rogue"], str(service.state["slots"]))
	_check("最后一格「后移」禁用", _disabled("move_next_4"))
	await _shot("E00_moved")

	print("── Esc 层级 ──")
	await _click("hud_sortie")
	await _click("sortie_prepare_1")
	_check("从出征点「整备」：进整备面板且有「返回出征」", sim.panel == "prepare" and _has("prepare_back_sortie"))
	await _esc()
	_check("Esc 返回出征面板", sim.panel == "sortie")
	await _click("sortie_prepare_4")
	await _click("prepare_back_sortie")
	_check("点「返回出征」回到出征面板", sim.panel == "sortie")
	await _esc()
	_check("出征面板 Esc 关闭", sim.panel == "")
	await _click("party_slot_1")
	await _esc()
	_check("队伍栏打开的整备：Esc 直接关回酒馆", sim.panel == "")

	print("── 面板打开时点场景 ──")
	await _click("hud_prepare")
	var pos_panel: Vector2 = sim.captain_pos
	await _mouse(MOUSE_BUTTON_LEFT, Vector2(1000, 1000 - 150))
	await _mouse(MOUSE_BUTTON_RIGHT, Vector2(200, 700))
	_check("面板打开：点面板外、右键都不会让队长移动，面板还在", sim.panel == "prepare" and not sim.is_moving() and sim.captain_pos == pos_panel)
	await _click("panel_close")

	print("── 保存失败与重试 ──")
	service.store.fail_writes = 1
	await _click("hud_prepare")
	var file_before := _file_text()
	await _click("talent_t1")
	_check("保存失败：出现「未保存，本次修改未生效」和重试", _has("banner_text") and (_node("banner_text") as Label).text == "未保存，本次修改未生效" and _has("banner_retry"))
	_check("失败后内存和文件都还是改前（天赋没变）", service.state["talentId"].get("rogue", "t1") == "t1" and service.state["talentId"].get("warrior", "t2") == "t2")
	await _shot("F00_save_failed")
	service.store.fail_writes = 0
	await _click("banner_retry")
	_check("点重试：保存成功，提示消失", not _has("banner_text"))
	service.store.fail_writes = 1
	var before_recruit := _file_text()
	await _click("hud_recruit")
	await _click("recruit_mage")
	_check("招募保存失败：没有留下半个成员，法师还没加入", not service.is_recruited("mage") and _file_text() == before_recruit and _has("banner_retry"))
	service.store.fail_writes = 0
	await _click("banner_retry")
	_check("重试后法师加入，队长不变", service.is_recruited("mage") and sim.captain_class != "mage")
	await _click("panel_close")
	service.store.fail_writes = 1
	await _click("hud_sortie")
	await _click("sortie_confirm")
	_check("确认出征保存失败：留在出征面板，不显示锁定名单", sim.panel == "sortie" and not _has("locked_title") and _has("banner_retry"))
	service.store.fail_writes = 0
	SortieSession.fail_load_left = 1
	await _click("banner_retry")
	_check("重试后进入锁定名单", _has("locked_title"))

	print("── F1/F2 调试键已删除 ──")
	await _click("panel_close")
	var members_now: int = service.members().size()
	var key := InputEventKey.new()
	key.keycode = KEY_F1
	key.physical_keycode = KEY_F1
	key.pressed = true
	Input.parse_input_event(key)
	await process_frame
	await process_frame
	_check("按 F1 不再招募", service.members().size() == members_now)

	print("RESULT: %s (%d 条失败)" % ["FAIL" if _failures > 0 else "ALL PASS", _failures])
	quit(1 if _failures > 0 else 0)
