extends SceneTree
## P4 整段走查（开窗口，真点控件，真切场景）：从空存档起招 1/2/3/4 人各出征一次，
## 加载失败重试、保存失败不加载、结算失败不返回、待领奖闸门、选中角色不变成队长。用法：
##   godot --path client --script res://scripts/tests/sortie_walk.gd -- --save=/tmp/p4.json --out=/tmp/p4
## 打印 PASS / FAIL，有失败退出码 1。证据（存档前后 JSON、事件日志、截图）写到 --out。

const SortieSession := preload("res://scripts/tavern/sortie_session.gd")
const BattleLaunch := preload("res://scripts/battle/battle_launch.gd")

var _dir: String = "/tmp/p4"
var _save: String = "/tmp/p4.json"
var _scene: Node = null
var _failures: int = 0
const FAST: PackedStringArray = ["--autoplay", "--fast", "--seed=7"]


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_dir = arg.get_slice("=", 1)
		if arg.begins_with("--save="):
			_save = arg.get_slice("=", 1)
	DirAccess.make_dir_recursive_absolute(_dir)
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


func _fresh_tavern() -> void:
	if current_scene != null:
		current_scene.queue_free()
		current_scene = null
		await process_frame
	if FileAccess.file_exists(_save):
		DirAccess.remove_absolute(_save)
	SortieSession.locked = {}
	SortieSession.returned = {}
	var scene: Node = load("res://scenes/tavern/tavern.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	_scene = scene
	await create_timer(0.4).timeout


func _mouse(canvas_pos: Vector2) -> void:
	var pos := canvas_pos / 1.5
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	motion.global_position = pos
	Input.parse_input_event(motion)
	await process_frame
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
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
	var waited := 0
	while waited < 40 and not _has(node_name):
		await process_frame
		waited += 1
	await process_frame
	await process_frame
	var node := _node(node_name)
	if node == null or not node.is_visible_in_tree():
		print("  （找不到可见控件 %s）" % node_name)
		return false
	await _mouse(node.get_global_rect().get_center())
	return true


func _has(node_name: String) -> bool:
	var node := _node(node_name)
	return node != null and node.is_visible_in_tree()


func _disabled(node_name: String) -> bool:
	var node := _node(node_name) as Button
	return node != null and node.disabled


func _press(action: String) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	Input.parse_input_event(event)
	await process_frame
	event.pressed = false
	Input.parse_input_event(event)
	await process_frame


## 等到当前场景的名字是 want（Tavern 或 Battle），并且换成了新实例。
func _wait_scene(want: String, old_id: int, seconds: float = 30.0) -> bool:
	var waited := 0.0
	while waited < seconds:
		if current_scene != null and current_scene.name == want and current_scene.get_instance_id() != old_id:
			await create_timer(0.4).timeout
			_scene = current_scene
			return true
		await create_timer(0.1).timeout
		waited += 0.1
	return false


func _events(name: String) -> Array:
	var out: Array = []
	for line in SortieSession.bus().lines:
		var record: Dictionary = JSON.parse_string(line)
		if String(record["e"]) == name:
			out.append(record)
	return out


func _ally_count_in_battle_log() -> int:
	var count := 0
	for line in FileAccess.get_file_as_string("user://battle_log.jsonl").split("\n", false):
		var record: Variant = JSON.parse_string(line)
		if typeof(record) == TYPE_DICTIONARY and String(record.get("e", "")) == "unit_spawned" and String(record.get("side", "")) == "ally":
			count += 1
	return count


func _recruit(count: int) -> void:
	await _click("hud_recruit")
	for class_id in ["warrior", "rogue", "mage", "priest"].slice(0, count):
		await _click("recruit_" + class_id)
	await _click("panel_close")


func _open_sortie() -> void:
	for attempt in 3:
		await _click("hud_sortie")
		var waited := 0
		while waited < 40 and not (_scene.sim.panel == "sortie" and _has("sortie_confirm")):
			await process_frame
			waited += 1
		if _scene.sim.panel == "sortie":
			break
	for i in 4:
		await process_frame


func _run() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://sortie_log.jsonl"))
	SortieSession.bus()
	print("══ 人数 1/2/3/4 各出征一次（快速自动战斗，种子 7）══")
	for count in [1, 2, 3, 4]:
		await _fresh_tavern()
		SortieSession.args_override = FAST
		await _recruit(count)
		await _open_sortie()
		var before := _dump("N%d_save_before_sortie" % count)
		var locked_before := _events("sortie_locked").size()
		var loaded_before := _events("battle_loaded").size()
		await _shot("N%d_sortie_panel" % count)
		var old := _scene.get_instance_id()
		await _click("sortie_confirm")
		var back := await _wait_scene("Tavern", old)
		_check("%d 人：战斗加载后回到酒馆" % count, back)
		var after := _dump("N%d_save_after_sortie" % count)
		_check("%d 人：事件顺序 sortie_locked → battle_loaded → battle_settled → battle_returned，各一次" % count, _events("sortie_locked").size() == locked_before + 1 and _events("battle_loaded").size() == loaded_before + 1 and _events("battle_returned").size() >= 1)
		var locked: Dictionary = _events("sortie_locked")[-1]["party"]
		var loaded: Dictionary = _events("battle_loaded")[-1]
		var settled: Dictionary = _events("battle_settled")[-1]
		_check("%d 人：三处 run_id 相同" % count, String(locked["run_id"]) == String(loaded["run_id"]) and String(loaded["run_id"]) == String(settled["run_id"]), str(locked["run_id"]))
		_check("%d 人：战斗只生成 %d 个己方，槽位与锁定名单一致" % [count, count], _ally_count_in_battle_log() == count and (locked["slots"] as Array).filter(func(c): return c != "").size() == count, "log=%d slots=%s" % [_ally_count_in_battle_log(), str(locked["slots"])])
		_check("%d 人：队长、槽位、装备、天赋不被战斗改动" % count, JSON.stringify(after["slots"]) == JSON.stringify(before["slots"]) and int(after["captainSlot"]) == int(before["captainSlot"]) and JSON.stringify(after["equips"]) == JSON.stringify(before["equips"]) and JSON.stringify(after["talentId"]) == JSON.stringify(before["talentId"]))
		var sim = _scene.sim
		_check("%d 人：酒馆里只有队长，在固定返回点" % count, sim.has_captain and sim.captain_class == before["slots"][int(before["captainSlot"])] and sim.captain_pos == sim.default_pos())
		var won := String(settled["result"]) == "win"
		print("  本场结果 ", settled["result"], " outcome=", settled["outcome"])
		if won:
			_check("%d 人：胜利后待领奖，出征确认不可用" % count, after["pendingReward"] != null and String(after["pendingReward"]["run_id"]) == String(locked["run_id"]))
			await _open_sortie()
			_check("%d 人：出征面板提示先领奖" % count, _disabled("sortie_confirm") and _has("blocker_pending_reward"))
			await _shot("N%d_pending_reward" % count)
			await _click("blocker_action_pending_reward")
			var owned_before: int = (after["ownedItems"] as Array).size()
			var claim_btn: Button = null
			for node in root.find_children("claim_*", "Button", true, false):
				claim_btn = node
				break
			if claim_btn != null:
				await _mouse(claim_btn.get_global_rect().get_center())
			var claimed := _dump("N%d_save_after_claim" % count)
			_check("%d 人：领奖后多一件装备、待领奖清除、可再次出征" % count, (claimed["ownedItems"] as Array).size() == owned_before + 1 and claimed["pendingReward"] == null and not _disabled("sortie_confirm"))
		else:
			_check("%d 人：失败不发奖、不留待领奖、装备不变" % count, after["pendingReward"] == null and (after["ownedItems"] as Array).size() == (before["ownedItems"] as Array).size())
			await _open_sortie()
			_check("%d 人：失败后可以直接再出征" % count, not _disabled("sortie_confirm"))
		await _shot("N%d_back_in_tavern" % count)

	print("══ 加载失败：重试，不发奖、不增加战斗次数 ══")
	await _fresh_tavern()
	SortieSession.args_override = FAST
	await _recruit(2)
	await _open_sortie()
	var save_before_fail := _dump("L00_save_before")
	var loaded_count := _events("battle_loaded").size()
	var settled_count := _events("battle_settled").size()
	SortieSession.fail_load_left = 2
	await _click("sortie_confirm")
	await create_timer(0.3).timeout
	_check("加载失败：留在酒馆，显示失败原因、重试、返回酒馆", current_scene.name == "Tavern" and _has("load_failed_text") and _has("load_retry") and _has("load_back_tavern"))
	await _shot("L01_load_failed")
	_check("失败请求：没有 battle_loaded、没有结算、存档原样", _events("battle_loaded").size() == loaded_count and _events("battle_settled").size() == settled_count and _file_text() == JSON.stringify(save_before_fail, "", true) or JSON.stringify(JSON.parse_string(_file_text())) == JSON.stringify(save_before_fail))
	var failed_run: String = _events("sortie_locked")[-1]["party"]["run_id"]
	var failed_before := _events("battle_load_failed").size()
	for attempt in 3:  # 注入的点击偶尔落在界面重排的空档里，没点中就再点（计数以事件为准，不会多算）
		await _click("load_retry")
		await create_timer(0.3).timeout
		if _events("battle_load_failed").size() > failed_before:
			break
	_check("重试仍失败（第二次注入）：继续停在失败页", _has("load_failed_text") and _events("battle_load_failed").size() >= 2)
	var old2 := _scene.get_instance_id()
	await _click("load_retry")
	var back2 := await _wait_scene("Tavern", old2)
	_check("第三次重试成功：进战斗打完回酒馆", back2 and _events("battle_loaded").size() == loaded_count + 1)
	_check("重试沿用同一个 run_id，只结算一次", String(_events("battle_loaded")[-1]["run_id"]) == failed_run and _events("battle_settled").size() == settled_count + 1)
	await _fresh_tavern()
	SortieSession.args_override = FAST
	await _recruit(1)
	await _open_sortie()
	SortieSession.fail_load_left = 1
	await _click("sortie_confirm")
	await create_timer(0.3).timeout
	await _click("load_back_tavern")
	_check("点「返回酒馆」：面板关闭，队长还在，可再开出征面板", _scene.sim.panel == "" and _scene.sim.has_captain)
	await _open_sortie()
	_check("再开出征面板回到正常状态", _has("sortie_confirm") and not _disabled("sortie_confirm"))

	print("══ 保存失败：不加载战斗 ══")
	await _fresh_tavern()
	SortieSession.args_override = FAST
	await _recruit(1)
	await _open_sortie()
	var locked_n := _events("sortie_locked").size()
	var loaded_n := _events("battle_loaded").size()
	_scene.service.store.fail_writes = 1
	await _click("sortie_confirm")
	await create_timer(0.3).timeout
	_check("确认出征保存失败：留在出征面板，有「未保存」和重试，没有锁名单、没有加载", current_scene.name == "Tavern" and _has("banner_retry") and _events("sortie_locked").size() == locked_n and _events("battle_loaded").size() == loaded_n)
	var old3 := _scene.get_instance_id()
	await _click("banner_retry")
	var back3 := await _wait_scene("Tavern", old3)
	_check("重试保存成功后继续：进战斗、回酒馆", back3 and _events("battle_loaded").size() == loaded_n + 1)

	print("══ 手动战斗：默认选中队长；换选角色不会变队长；结算失败不返回 ══")
	await _fresh_tavern()
	SortieSession.args_override = PackedStringArray(["--seed=7"])
	await _recruit(2)
	await _click("party_slot_2")
	await _click("set_captain")
	await _click("panel_close")
	var sel_before := _dump("M00_save_before")
	_check("队长是盗贼（槽位 2）", int(sel_before["captainSlot"]) == 1)
	await _open_sortie()
	var old4 := _scene.get_instance_id()
	await _click("sortie_confirm")
	var in_battle := await _wait_scene("Battle", old4)
	_check("进入战斗场景", in_battle)
	var battle := current_scene
	_check("战斗默认选中队长（槽位 2）", battle.controller.selected_slot == 1, str(battle.controller.selected_slot))
	await _shot("M01_battle_start")
	battle.controller.select_slot(0)
	_check("手动改选战士", battle.controller.selected_slot == 0)
	SortieSession.fail_settle_left = 1
	battle.service_fail_hook() if battle.has_method("service_fail_hook") else null
	battle._service.store.fail_writes = 1
	var guard := 0
	while not battle.sim.finished and guard < 4000:
		battle.sim.step(0.05)
		guard += 1
	await create_timer(0.2).timeout
	_check("战斗结束；结算写盘失败时留在结果页，提示未保存", current_scene == battle and not battle._settled)
	await _shot("M02_settle_failed")
	var mid := _dump("M03_save_while_unsettled")
	_check("结算失败：存档没有待领奖、没有 selectedSlot 变化", mid["pendingReward"] == null and int(mid["selectedSlot"]) == int(sel_before["selectedSlot"]))
	var done_result: String = battle._result
	var old5 := _scene.get_instance_id()
	await _press("ui_accept")
	var back5 := await _wait_scene("Tavern", old5)
	_check("再按「回酒馆」重试：结算成功、回到酒馆", back5)
	var done := _dump("M04_save_after")
	_check("本场（不下命令）结果 %s：失败不发奖、不留待领奖、装备不变" % String(done_result), String(done_result) != "lose" or (done["pendingReward"] == null and (done["ownedItems"] as Array).size() == (sel_before["ownedItems"] as Array).size()))
	_check("选中的是战士，但队长仍是盗贼（selectedSlot 不写回队长）", int(done["selectedSlot"]) == 0 and int(done["captainSlot"]) == 1 and _scene.sim.captain_class == "rogue")

	print("RESULT: %s (%d 条失败)" % ["FAIL" if _failures > 0 else "ALL PASS", _failures])
	quit(1 if _failures > 0 else 0)
