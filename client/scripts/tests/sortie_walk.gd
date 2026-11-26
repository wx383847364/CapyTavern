extends SceneTree
## P4 整段走查（开窗口，经 Viewport 合成点击真实控件，切换正式场景）：从空存档起招 1/2/3/4 人各出征一次，
## 加载失败重试、保存失败不加载、结算失败不返回、待领奖闸门、选中角色不变成队长。用法：
##   godot --path client --script res://scripts/tests/sortie_walk.gd -- --save=/tmp/p4.json --out=/tmp/p4
## 打印 PASS / FAIL，有失败退出码 1。证据（存档前后 JSON、事件日志、截图）写到 --out。

const SortieSession := preload("res://scripts/tavern/sortie_session.gd")
const BattleController := preload("res://scripts/input/battle_controller.gd")
const BattleSim := preload("res://scripts/battle/battle_sim.gd")
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


## 缺少后续取值的前提时，先记录首败，再由调用方停止当前流程。
func _require(name: String, ok: bool, detail: String = "") -> bool:
	_check(name, ok, detail)
	if not ok:
		_finish()
	return ok


## 成功结束和前置失败共用唯一汇总，缺事件也以非零状态退出。
func _finish() -> void:
	print("RESULT: %s (%d 条失败)" % ["FAIL" if _failures > 0 else "ALL PASS", _failures])
	quit(1 if _failures > 0 else 0)


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


## 从按钮局部中心变换到当前 viewport；输入仍经过 GUI 命中和按钮的原信号。
func _mouse(button: Button) -> bool:
	var local_center := button.size * 0.5
	var pos := button.get_global_transform_with_canvas() * local_center
	var control_name := String(button.name)
	var observed: Array[bool] = []
	# 只旁听本次按钮是否触发；业务动作仍由原连接执行。
	var observe := func() -> void: observed.append(true)
	button.pressed.connect(observe)
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	motion.global_position = pos
	root.push_input(motion, true)
	# 坐标已在 viewport 内，true 避免再次换算。配对投递独立的按下和释放，避免两边沿之间面板重排。
	for down: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		if down:
			event.button_mask = MOUSE_BUTTON_MASK_LEFT
		event.position = pos
		event.global_position = pos
		event.pressed = down
		root.push_input(event, true)
	print("WALK_CLICK control=%s local_center=%s viewport_pos=%s viewport=%s pressed=%d" % [control_name, local_center, pos, root.get_visible_rect(), observed.size()])
	if is_instance_valid(button):
		button.pressed.disconnect(observe)
	return _require("按钮 %s 触发一次" % control_name, observed.size() == 1, "viewport_pos=%s" % pos)


func _node(node_name: String) -> Control:
	return root.find_child(node_name, true, false) as Control


## 每次从当前树取按钮，并留帧让容器完成布局；控件缺失或不可操作时给出首败。
func _click(node_name: String) -> bool:
	for frame in 40:
		if _has(node_name):
			break
		await process_frame
	await process_frame
	await process_frame
	var button := _node(node_name) as Button
	if button == null or not button.is_visible_in_tree() or button.disabled or not Rect2(Vector2.ZERO, button.size).has_area():
		return _require("按钮 %s 可操作" % node_name, false)
	if not _mouse(button):
		return false
	# 招募与领奖会在后续帧重建按钮，下一步再查找新实例。
	await process_frame
	await process_frame
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


## 只读本分支起点后的事件；空名称保留完整链路，供顺序和数量断言。
func _events(name: String, since: int = 0) -> Array:
	var out: Array = []
	for line in SortieSession.bus().lines.slice(since):
		var record: Dictionary = JSON.parse_string(line)
		if name.is_empty() or String(record["e"]) == name:
			out.append(record)
	return out


func _ally_count_in_battle_log() -> int:
	var count := 0
	for line in FileAccess.get_file_as_string("user://battle_log.jsonl").split("\n", false):
		var record: Variant = JSON.parse_string(line)
		if typeof(record) == TYPE_DICTIONARY and String(record.get("e", "")) == "unit_spawned" and String(record.get("side", "")) == "ally":
			count += 1
	return count


## 验证每次点击后的实际入队；少一人就停止，避免再对空队伍发起出征。
func _recruit(count: int) -> bool:
	if not (await _click("hud_recruit")):
		return false
	var expected := 0
	for class_id in ["warrior", "rogue", "mage", "priest"].slice(0, count):
		if not (await _click("recruit_" + class_id)):
			return false
		expected += 1
		var members: Array[String] = _scene.service.members()
		if not _require("招募 %s：队伍达到 %d 人" % [class_id, expected], members.size() == expected and members.has(class_id), str(members)):
			return false
	return await _click("panel_close")


## 使用真实 HUD 打开出征面板；确认按钮允许被待领奖等业务闸门禁用。
func _open_sortie() -> bool:
	if not (await _click("hud_sortie")):
		return false
	for frame in 40:
		if _scene.sim.panel == "sortie" and _has("sortie_confirm"):
			return true
		await process_frame
	return _require("已打开出征确认面板", false, str(_scene.sim.panel))


## 执行各条正式出征分支；事件或场景缺失时停止依赖该前提的后续访问。
func _run() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://sortie_log.jsonl"))
	SortieSession.bus()
	print("══ 人数 1/2/3/4 各出征一次（快速自动战斗，种子 7）══")
	for count in [1, 2, 3, 4]:
		await _fresh_tavern()
		SortieSession.args_override = FAST
		if not (await _recruit(count)) or not (await _open_sortie()):
			return
		var before := _dump("N%d_save_before_sortie" % count)
		var event_start := SortieSession.bus().lines.size()
		await _shot("N%d_sortie_panel" % count)
		var old := _scene.get_instance_id()
		if not (await _click("sortie_confirm")):
			return
		var locks := _events("sortie_locked", event_start)
		if not _require("%d 人：确认后锁定名单一次" % count, locks.size() == 1, str(locks)):
			return
		var back := await _wait_scene("Tavern", old)
		var chain := _events("", event_start)
		if not _require("%d 人：战斗加载后回到酒馆" % count, back, str(chain)):
			return
		var after := _dump("N%d_save_after_sortie" % count)
		# 只在本轮四个事件严格按序且各一次后取值，不能误取上一场。
		var kinds: Array = chain.map(func(record: Dictionary) -> String: return String(record["e"]))
		if not _require("%d 人：事件顺序 sortie_locked → battle_loaded → battle_settled → battle_returned，各一次" % count, kinds == ["sortie_locked", "battle_loaded", "battle_settled", "battle_returned"], str(kinds)):
			return
		var locked: Dictionary = chain[0]["party"]
		var loaded: Dictionary = chain[1]
		var settled: Dictionary = chain[2]
		_check("%d 人：三处 run_id 相同" % count, String(locked["run_id"]) == String(loaded["run_id"]) and String(loaded["run_id"]) == String(settled["run_id"]), str(locked["run_id"]))
		_check("%d 人：返场结果与结算相同" % count, chain[3]["result"] == settled["result"])
		_check("%d 人：战斗只生成 %d 个己方，槽位与锁定名单一致" % [count, count], _ally_count_in_battle_log() == count and (locked["slots"] as Array).filter(func(c): return c != "").size() == count, "log=%d slots=%s" % [_ally_count_in_battle_log(), str(locked["slots"])])
		var roster_keys := ["slots", "captainSlot", "equips", "talentId", "ownedItems", "pendingReward"]
		if not _require("%d 人：出征前后存档字段可读" % count, before.has_all(roster_keys) and after.has_all(roster_keys)):
			return
		_check("%d 人：队长、槽位、装备、天赋不被战斗改动" % count, JSON.stringify(after["slots"]) == JSON.stringify(before["slots"]) and int(after["captainSlot"]) == int(before["captainSlot"]) and JSON.stringify(after["equips"]) == JSON.stringify(before["equips"]) and JSON.stringify(after["talentId"]) == JSON.stringify(before["talentId"]))
		var sim = _scene.sim
		_check("%d 人：酒馆里只有队长，在固定返回点" % count, sim.has_captain and sim.captain_class == before["slots"][int(before["captainSlot"])] and sim.captain_pos == sim.default_pos())
		var won := String(settled["result"]) == "win"
		print("  本场结果 ", settled["result"], " outcome=", settled["outcome"])
		if won:
			_check("%d 人：胜利后待领奖，出征确认不可用" % count, after["pendingReward"] != null and String(after["pendingReward"]["run_id"]) == String(locked["run_id"]))
			if not (await _open_sortie()):
				return
			_check("%d 人：出征面板提示先领奖" % count, _disabled("sortie_confirm") and _has("blocker_pending_reward"))
			await _shot("N%d_pending_reward" % count)
			if not (await _click("blocker_action_pending_reward")):
				return
			var owned_before: int = (after["ownedItems"] as Array).size()
			var claim_btn: Button = null
			for node in root.find_children("claim_*", "Button", true, false):
				claim_btn = node
				break
			if not _require("有可领取的装备按钮", claim_btn != null):
				return
			if not (await _click(String(claim_btn.name))):
				return
			var claimed := _dump("N%d_save_after_claim" % count)
			_check("%d 人：领奖后多一件装备、待领奖清除、可再次出征" % count, claimed.has_all(["ownedItems", "pendingReward"]) and (claimed["ownedItems"] as Array).size() == owned_before + 1 and claimed["pendingReward"] == null and _has("sortie_confirm") and not _disabled("sortie_confirm"))
		else:
			_check("%d 人：失败不发奖、不留待领奖、装备不变" % count, after["pendingReward"] == null and (after["ownedItems"] as Array).size() == (before["ownedItems"] as Array).size())
			if not (await _open_sortie()):
				return
			_check("%d 人：失败后可以直接再出征" % count, not _disabled("sortie_confirm"))
		await _shot("N%d_back_in_tavern" % count)

	print("══ 加载失败：重试，不发奖、不增加战斗次数 ══")
	await _fresh_tavern()
	SortieSession.args_override = FAST
	if not (await _recruit(2)) or not (await _open_sortie()):
		return
	var save_before_fail := _dump("L00_save_before")
	SortieSession.fail_load_left = 2
	var failed_start := SortieSession.bus().lines.size()
	if not (await _click("sortie_confirm")):
		return
	await create_timer(0.3).timeout
	if not _require("加载失败：留在酒馆，显示失败原因、重试、返回酒馆", current_scene == _scene and _has("load_failed_text") and _has("load_retry") and _has("load_back_tavern")):
		return
	await _shot("L01_load_failed")
	# 存档相同不能掩盖意外的加载或结算事件。
	_check("失败请求：没有 battle_loaded、没有结算、存档原样", _events("battle_loaded", failed_start).is_empty() and _events("battle_settled", failed_start).is_empty() and JSON.parse_string(_file_text()) == save_before_fail)
	var failed_locks := _events("sortie_locked", failed_start)
	var injected := _events("battle_load_failed", failed_start)
	if not _require("第一次加载失败：锁定和失败事件各一次", failed_locks.size() == 1 and injected.size() == 1, str(_events("", failed_start))):
		return
	var failed_run: String = failed_locks[0]["party"]["run_id"]
	if not (await _click("load_retry")):
		return
	await create_timer(0.3).timeout
	injected = _events("battle_load_failed", failed_start)
	if not _require("重试仍失败（第二次注入）：继续停在失败页", _has("load_failed_text") and injected.size() == 2, str(injected)):
		return
	_check("两次加载失败均沿用锁定的 run_id", String(injected[0]["run_id"]) == failed_run and String(injected[1]["run_id"]) == failed_run)
	var old2 := _scene.get_instance_id()
	if not (await _click("load_retry")):
		return
	var back2 := await _wait_scene("Tavern", old2)
	var retried_loads := _events("battle_loaded", failed_start)
	if not _require("第三次加载成功：进战斗打完回酒馆", back2 and retried_loads.size() == 1, str(_events("", failed_start))):
		return
	var retried_settles := _events("battle_settled", failed_start)
	_check("重试沿用同一个 run_id，只结算一次", _events("sortie_locked", failed_start).size() == 1 and String(retried_loads[0]["run_id"]) == failed_run and retried_settles.size() == 1 and String(retried_settles[0]["run_id"]) == failed_run)
	await _fresh_tavern()
	SortieSession.args_override = FAST
	if not (await _recruit(1)) or not (await _open_sortie()):
		return
	SortieSession.fail_load_left = 1
	if not (await _click("sortie_confirm")):
		return
	await create_timer(0.3).timeout
	if not (await _click("load_back_tavern")):
		return
	_check("点「返回酒馆」：面板关闭，队长还在，可再开出征面板", _scene.sim.panel == "" and _scene.sim.has_captain)
	if not (await _open_sortie()):
		return
	_check("再开出征面板回到正常状态", _has("sortie_confirm") and not _disabled("sortie_confirm"))

	print("══ 保存失败：不加载战斗 ══")
	await _fresh_tavern()
	SortieSession.args_override = FAST
	if not (await _recruit(1)) or not (await _open_sortie()):
		return
	var locked_n := _events("sortie_locked").size()
	var loaded_n := _events("battle_loaded").size()
	_scene.service.store.fail_writes = 1
	if not (await _click("sortie_confirm")):
		return
	await create_timer(0.3).timeout
	if not _require("确认出征保存失败：留在出征面板，有「未保存」和重试，没有锁名单、没有加载", current_scene == _scene and _has("banner_retry") and _events("sortie_locked").size() == locked_n and _events("battle_loaded").size() == loaded_n):
		return
	var old3 := _scene.get_instance_id()
	if not (await _click("banner_retry")):
		return
	var back3 := await _wait_scene("Tavern", old3)
	_check("重试保存成功后继续：进战斗、回酒馆", back3 and _events("battle_loaded").size() == loaded_n + 1)

	print("══ 手动战斗：默认选中队长；换选角色不会变队长；结算失败不返回 ══")
	await _fresh_tavern()
	SortieSession.args_override = PackedStringArray(["--seed=7"])
	if not (await _recruit(2)):
		return
	if not (await _click("party_slot_2")) or not (await _click("set_captain")) or not (await _click("panel_close")):
		return
	var sel_before := _dump("M00_save_before")
	if not _require("队长是盗贼（槽位 2）", sel_before.has_all(["captainSlot", "selectedSlot", "ownedItems"]) and int(sel_before["captainSlot"]) == 1):
		return
	if not (await _open_sortie()):
		return
	var old4 := _scene.get_instance_id()
	if not (await _click("sortie_confirm")):
		return
	var in_battle := await _wait_scene("Battle", old4)
	if not _require("进入战斗场景", in_battle):
		return
	var battle := current_scene
	_check("战斗默认选中队长（槽位 2）", battle.controller.selected_slot == 1, str(battle.controller.selected_slot))
	await _shot("M01_battle_start")
	battle.controller.select_slot(0)
	_check("手动改选战士", battle.controller.selected_slot == 0)
	SortieSession.fail_settle_left = 1
	battle.service_fail_hook() if battle.has_method("service_fail_hook") else null
	battle._service.store.fail_writes = 1
	var settle_start := SortieSession.bus().lines.size()
	var guard := 0
	while not battle.sim.finished and guard < 4000:
		battle.sim.step(0.05)
		guard += 1
	await create_timer(0.2).timeout
	# 实际结束且收到写盘失败才算命中注入；失焦暂停等原因可能耗尽步数而未结算。
	var settle_fails := _events("settle_failed", settle_start)
	if not _require("战斗结束；结算写盘失败时留在结果页，提示未保存", current_scene == battle and battle.sim.finished and not battle._settled and settle_fails.size() == 1 and settle_fails[0]["reason"] == "write_failed", "steps=%d events=%s" % [guard, str(_events("", settle_start))]):
		return
	await _shot("M02_settle_failed")
	var mid := _dump("M03_save_while_unsettled")
	_check("结算失败：存档没有待领奖、没有 selectedSlot 变化", mid.has_all(["pendingReward", "selectedSlot"]) and mid["pendingReward"] == null and int(mid["selectedSlot"]) == int(sel_before["selectedSlot"]))
	var done_result: String = battle._result
	var old5 := _scene.get_instance_id()
	await _press("ui_accept")
	var back5 := await _wait_scene("Tavern", old5)
	if not _require("再按「回酒馆」重试：结算成功、回到酒馆", back5):
		return
	var done := _dump("M04_save_after")
	if not _require("重试后结算存档字段可读", done.has_all(["pendingReward", "ownedItems", "selectedSlot", "captainSlot"])):
		return
	_check("本场（不下命令）结果 %s：失败不发奖、不留待领奖、装备不变" % String(done_result), String(done_result) != "lose" or (done["pendingReward"] == null and (done["ownedItems"] as Array).size() == (sel_before["ownedItems"] as Array).size()))
	_check("选中的是战士，但队长仍是盗贼（selectedSlot 不写回队长）", int(done["selectedSlot"]) == 0 and int(done["captainSlot"]) == 1 and _scene.sim.captain_class == "rogue")

	# 先完成原 157 项，再对正式专精补齐单人、双人、套装和同场返程。
	for case: Array in [["F1_solo", false, false, false], ["F2_duo", true, false, true], ["F3_sets", true, true, false]]:
		if not (await _formal_walk(case[0], case[1], case[2], case[3])):
			return
	for case: Array in [["AI_前排单人", 1], ["AI_四人", 4], ["AI_法牧", 2]]:
		if not (await _ally_ai_sortie_walk(case[0], case[1])):
			return
	await _hit_feedback_walk()
	_finish()


## 从正常酒馆入口跑三类实战，完成后只统计同一战斗的真实事件。
func _ally_ai_sortie_walk(tag: String, count: int) -> bool:
	await _fresh_tavern()
	SortieSession.args_override = PackedStringArray(["--seed=131"])
	var recruited: bool = await _formal_prepare_party(true, false) if count == 2 else await _recruit(count)
	if not recruited or not (await _open_sortie()):
		return false
	var old := _scene.get_instance_id()
	if not (await _click("sortie_confirm")) or not (await _wait_scene("Battle", old)):
		return _require(tag + " 实战入口", false)
	_scene.set_process(false)
	var sim: BattleSim = _scene.sim
	sim.events.echo_stdout = false
	sim.set_paused(false)
	var front := sim.slot_unit(0)
	var target: BattleSim.Unit = sim.living("enemy")[0]
	_check(tag + " 真人出征默认启用 AI", sim.player_controls and sim.ally_ai_enabled and sim.formal_skill_sortie == (count == 2))
	var at_start := front.pos
	_formal_click(_scene, target.pos, MOUSE_BUTTON_RIGHT)
	_formal_steps(sim, 1)
	_check(tag + " 右键首个攻击对象", front.auto_target_id == target.id)
	if count != 2:
		_check(tag + " 近战点击后立即主动接近", front.pos.distance_to(target.pos) < at_start.distance_to(target.pos))
	else:
		# 浮点自然回蓝先于决策，按实际决策时刻构造 10% 与 9.9% 边界。
		var dt := float(sim.config["tick"])
		front.res = 10.0 - dt * front.res_regen
		_formal_steps(sim, 1)
		_check(tag + " 正式唤醒等于10%不放", near_resource(front.res, 10.0) and not front.skill_ready_at.has("mage.fire.evocation"))
		front.res = 9.9 - dt * front.res_regen
		_formal_steps(sim, 1)
		_check(tag + " 正式唤醒低于10%自动事务成功且不覆盖手动结果",
			front.res >= 44.8 and front.skill_ready_at.has("mage.fire.evocation") and _scene.last_cast_result.is_empty())
		# 同场接着手动施盾，序号必须排在自动唤醒之后，HUD 只展示手动结果。
		front.gcd_until = 0.0
		_battle_key(KEY_E, true)
		_battle_key(KEY_E, false)
		_formal_steps(sim, 1)
		_check(tag + " 自动和人工请求同场不碰撞且 HUD 收到人工结果",
			_scene.last_cast_result.get("accepted", false) and _scene.last_cast_result.get("skill_id") == "mage.fire.flame_barrier"
			and int(_scene.last_cast_result.get("request_seq", -1)) >= 2)
	var guard := 0
	while not sim.finished and guard < 3000:
		sim.step(float(sim.config["tick"]))
		guard += 1
	_check(tag + " 无后续指令的战斗自行结束", sim.finished and sim.result in ["win", "lose"] and front.damage_done > 0.0)
	var tally := {"auto": 0, "interrupt": 0, "evade": 0, "heal": 0.0, "overheal": 0.0}
	for line: String in sim.events.lines:
		var event: Dictionary = JSON.parse_string(line)
		match String(event["e"]):
			"ai_skill_cast":
				tally["auto"] += 1
			"enemy_cast_interrupted":
				tally["interrupt"] += 1
			"ai_evade":
				if event["active"]:
					tally["evade"] += 1
			"heal_done":
				tally["heal"] += event["effective"]
				tally["overheal"] += maxi(0, int(event["amount"]) - int(event["effective"]))
			"cast_resolved":
				var result: Dictionary = event["result"]
				if result.get("source") == "ai" and result.get("accepted", false):
					tally["auto"] += 1
				for effect: Dictionary in result.get("details", {}).get("effects", []):
					if effect.get("effect_kind") == "HEAL":
						tally["heal"] += effect["actual_amount"]
						tally["overheal"] += effect["overheal_amount"]
	print("ALLY_AI_WALK ", tag, " outcome=", sim.result, " elapsed=", sim.time, " ", JSON.stringify(tally))
	_check(tag + " 自动技能走真实结算日志", tally["auto"] > 0)
	await _shot(tag + "_result")
	return true


## 资源边界用近似相等报告决策点值，是否施法仍以实际技能状态判断。
func near_resource(actual: float, expected: float) -> bool:
	return absf(actual - expected) < 0.00001


## 在真实战斗场景用普攻和旋风斩核对受击目标，并保留首帧窗口截图。
func _hit_feedback_walk() -> void:
	current_scene.free()
	current_scene = null
	BattleLaunch.from_tavern = false
	BattleLaunch.autoplay = false
	BattleLaunch.slots = BattleLaunch.default_slots(4)
	BattleLaunch.seed = 121
	var battle: Node = load("res://scenes/battle/battle.tscn").instantiate()
	root.add_child(battle)
	current_scene = battle
	battle.set_process(false)
	var sim: BattleSim = battle.sim
	# 该夹具只检查一次手动打击的画面；完整 AI 由上面的出征验收覆盖。
	sim.ally_ai_enabled = false
	var view: Node2D = battle.get_node("View")
	var tank := sim.slot_unit(0)
	var mage := sim.slot_unit(2)
	var foes := sim.living("enemy")
	var first := foes[0]
	var second := foes[1]
	tank.pos = Vector2(600, 400)
	mage.pos = Vector2(500, 525)
	first.pos = Vector2(660, 400)
	second.pos = Vector2(590, 490)
	foes[2].pos = Vector2(800, 440)
	foes[3].pos = Vector2(900, 620)
	for foe in foes:
		foe.speed = 0.0
		foe.next_attack_at = INF
		foe.cast_cd_until = INF
	sim.set_paused(false)
	sim.config["crit_chance"] = 0.0
	battle.controller.player_right_click(first.pos, first.id)
	sim.step(0.05)
	battle._refresh_view()
	var plain: Dictionary = view._enemy_hits.get(first.id, {})
	_check("命中反馈：普攻只点亮受伤怪且没有暴击环",
		view._enemy_hits.size() == 1 and not plain.is_empty()
		and int(plain["flash_at"]) - int(plain["critical_at"]) == view.CRITICAL_RING_MS)
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var center := Vector2i(first.pos * Vector2(image.get_size()) / root.get_visible_rect().size)
	var flash_pixel := image.get_pixelv(center)
	_check("命中反馈：普通命中帧怪物中心实际闪白", flash_pixel.g > 0.45 and flash_pixel.b > 0.45, str(flash_pixel))
	_check("命中反馈：普通命中截图保存", image.save_png(_dir.path_join("H01_hit_flash.png")) == OK)

	await create_timer(0.17).timeout
	battle._refresh_view()
	_check("命中反馈：到时清除普攻闪白", view._enemy_hits.is_empty())
	await RenderingServer.frame_post_draw
	var normal_pixel := root.get_texture().get_image().get_pixelv(center)
	_check("命中反馈：闪白结束后恢复怪物原色", normal_pixel.g < 0.34 and normal_pixel.b < 0.34, str(normal_pixel))

	# 让精英预警与群攻同帧显示，截图可核对怪物本体、短环与地面预警的层次。
	sim._start_cast(foes[3], tank)
	sim.config["crit_chance"] = 1.0
	var cast: bool = battle.controller.submit_player_skill("e", Vector2.ZERO, false)
	battle._refresh_view()
	var first_crit: Dictionary = view._enemy_hits.get(first.id, {})
	var second_crit: Dictionary = view._enemy_hits.get(second.id, {})
	_check("命中反馈：旋风斩只给两只命中的怪各一圈暴击环", cast and view._enemy_hits.size() == 2
		and not first_crit.is_empty() and first_crit["flash_at"] == first_crit["critical_at"]
		and not second_crit.is_empty() and second_crit["flash_at"] == second_crit["critical_at"])
	await RenderingServer.frame_post_draw
	_check("命中反馈：旋风斩暴击和地面预警截图保存",
		root.get_texture().get_image().save_png(_dir.path_join("H02_critical_whirlwind.png")) == OK)

	# 只挪动显示计时以避免依赖毫秒整数相等；再次命中仍走真实普攻。
	if not first_crit.is_empty():
		var ring_start := int(first_crit["critical_at"])
		first_crit["flash_at"] -= 15
		var previous_flash := int(first_crit["flash_at"])
		tank.next_attack_at = 0.0
		sim.step(0.05)
		_check("命中反馈：连续暴击刷新闪白但不重开短环",
			first_crit["flash_at"] > previous_flash and first_crit["critical_at"] == ring_start)
	sim.set_paused(true)
	battle._refresh_view()
	_check("命中反馈：暂停清除在播反馈", view._enemy_hits.is_empty())
	sim.set_paused(false)
	battle.controller.select_slot(mage.slot)
	var empty: bool = battle.controller.submit_player_skill("q", Vector2(300, 740), true)
	_check("命中反馈：范围技能空放不闪白", empty and view._enemy_hits.is_empty())

	battle.controller.select_slot(tank.slot)
	battle.controller.player_right_click(first.pos, first.id)
	first.hp = 1.0
	tank.next_attack_at = 0.0
	sim.step(0.05)
	_check("命中反馈：击杀也有反馈，结算立即清理", not first.alive and view._enemy_hits.has(first.id))
	sim._finish("win", "all_enemies_down")
	_check("命中反馈：结果页没有残留反馈", view._enemy_hits.is_empty())
	var bus := sim.events
	root.remove_child(battle)
	_check("命中反馈：离场断开伤害订阅", not bus.damage_dealt.is_connected(battle._on_damage_dealt))
	battle.free()
	current_scene = null


## 在测试存档中准备已有套装与 t2；仍通过真实出征按钮锁定，不直接构造 BattleLaunch。
func _formal_prepare_party(duo: bool, equipped: bool) -> bool:
	if not (await _click("hud_recruit")):
		return false
	for class_id: String in (["mage", "priest"] if duo else ["mage"]):
		if not (await _click("recruit_" + class_id)) or not _require("正式招募 " + class_id, _scene.service.is_recruited(class_id)):
			return false
	if not (await _click("panel_close")):
		return false
	var draft: Dictionary = _scene.service.state.duplicate(true)
	for class_id: String in _scene.service.members():
		draft["talentId"][class_id] = "t2" if equipped or not duo else "t1"
		if equipped:
			# 仅在本轮夹具存档装备已存在的两件奖励件，不改物品表。
			for slot: String in ["shoulder", "boots"]:
				var item_id := "%s_%s_set" % [class_id, slot]
				draft["ownedItems"].append(item_id)
				draft["equips"][class_id][slot] = item_id
	var written: Dictionary = _scene.service._commit(draft)
	return _require("正式夹具存档可写", written["ok"], str(written))


## 正式战场合成鼠标走当前 viewport 的实际变换和 Scene 入参，不直接调用控制器。
func _formal_click(canvas_node: Node2D, local_pos: Vector2, index: MouseButton) -> void:
	_scene._refresh_view()
	var viewport_pos := canvas_node.get_global_transform_with_canvas() * local_pos
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = index
		if pressed:
			event.button_mask = MOUSE_BUTTON_MASK_LEFT if index == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT
		event.position = viewport_pos
		event.global_position = viewport_pos
		event.pressed = pressed
		root.push_input(event, true)


## 投递真实键位形状，由战斗场景的 InputMap 判定而不是直接调用控制器。
func _battle_key(key: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = key
	event.pressed = pressed
	root.push_input(event, true)


## 在正式出征复用实际 View、设置和技能队列，覆盖两层血条与按住取消。
func _formal_target_hud(tag: String, mage: BattleSim.Unit, priest: BattleSim.Unit, enemy: BattleSim.Unit) -> void:
	var sim: BattleSim = _scene.sim
	var view: Node2D = _scene.get_node("View")
	enemy.target_id = mage.id
	_scene.controller.select_target(enemy.id)
	_scene._refresh_view()
	_check(tag + " 正式顶部血条命中当前敌人",
		view.hit_test(view.TARGET_BAR.get_center()).get("id") == enemy.id)
	_formal_click(view, view.TARGET_OF_TARGET_BAR.get_center(), MOUSE_BUTTON_LEFT)
	_check(tag + " 点击目标的目标只切目标，队伍操控槽保持",
		_scene.controller.selected_slot == mage.slot and mage.selected_target_id == mage.id)
	_formal_click(view, view._portrait_rect(priest.slot).get_center(), MOUSE_BUTTON_LEFT)
	_check(tag + " 队伍头像只切治疗或观察目标",
		_scene.controller.selected_slot == mage.slot and mage.selected_target_id == priest.id)
	_battle_key(KEY_F2, true)
	_battle_key(KEY_F2, false)
	_check(tag + " F2 与数字槽共用操控角色", _scene.controller.selected_slot == priest.slot)
	_formal_click(view, view._world_label_rect(view._by_id[mage.id]).get_center(), MOUSE_BUTTON_LEFT)
	_check(tag + " 头顶血条和头像命中治疗目标", priest.selected_target_id == mage.id)
	mage.hp -= 18.25
	_scene._refresh_view()
	_check(tag + " 正式治疗投影预览与生命仍分开",
		is_equal_approx(view._hud["heal_preview"], 18.25) and mage.hp == mage.max_hp - 18.25)
	mage.hp = mage.max_hp
	_formal_click(view, view.OUTPUT_PANEL.get_center(), MOUSE_BUTTON_RIGHT)
	_check(tag + " 统计窗拦截右键走位", sim._skill_pending.is_empty())
	_formal_click(view, view.SETTINGS_BUTTON.get_center(), MOUSE_BUTTON_LEFT)
	_formal_click(view, view._option_rect(1).get_center(), MOUSE_BUTTON_LEFT)
	_check(tag + " 设置打开会暂停且写入独立偏好",
		_scene._settings_open and sim.paused and _scene.controller.preferences["release_cast"])
	var loaded := BattleController.new()
	loaded.load_preferences()
	_check(tag + " 独立控制器读回施法偏好", loaded.preferences["release_cast"])
	_formal_click(view, view.SETTINGS_CLOSE.get_center(), MOUSE_BUTTON_LEFT)
	_check(tag + " 关闭设置仍暂停", sim.paused and not _scene._settings_open)
	_battle_key(KEY_P, true)
	_battle_key(KEY_P, false)
	_battle_key(KEY_F1, true)
	_battle_key(KEY_F1, false)
	_scene.controller.select_target(enemy.id)
	_battle_key(KEY_Q, true)
	_check(tag + " 按住范围技能只显示预览不入队", _scene._aim_key == "q" and sim._skill_pending.is_empty() and view._hud["aim"]["radius"] == 200.0)
	_battle_key(KEY_ESCAPE, true)
	_battle_key(KEY_ESCAPE, false)
	_battle_key(KEY_Q, false)
	_check(tag + " Esc 后松手不释放", _scene._aim_key.is_empty() and sim._skill_pending.is_empty())
	_scene.controller.select_target(mage.id)
	_scene._pointer = Vector2(625, 325)
	var mana := mage.res
	_battle_key(KEY_Q, true)
	_battle_key(KEY_Q, false)
	var empty := _formal_cast(tag, "mage.fire.flame_burst")
	_check(tag + " 无敌方目标时按住松开一次地面空放",
		not empty.is_empty() and empty["effects"].is_empty() and mage.res < mana and _scene._skill_result_notice.contains("未命中"))
	_check(tag + " 空放未开启自动攻击", mage.auto_target_id == -1 and mage.damage_done == 0)
	_check(tag + " 正式范围空放无命中反馈", view._enemy_hits.is_empty())
	# 后续历史回归仍从资源和技能计时的标准状态开始。
	mage.res = mana
	mage.skill_ready_at.erase("mage.fire.flame_burst")
	mage.gcd_until = 0.0
	_formal_click(view, view.SETTINGS_BUTTON.get_center(), MOUSE_BUTTON_LEFT)
	_formal_click(view, view._option_rect(1).get_center(), MOUSE_BUTTON_LEFT)
	_formal_click(view, view.SETTINGS_CLOSE.get_center(), MOUSE_BUTTON_LEFT)
	_battle_key(KEY_P, true)
	_battle_key(KEY_P, false)


## 用正常步长跨过公共冷却或到期点，保留期间发生的正式动作。
func _formal_steps(sim: BattleSim, count: int) -> void:
	for i in count:
		sim.step(float(sim.config["tick"]))


## 执行一次已经通过输入链入队的技能，用原事件取最终结果，缺结果时尽早退出。
func _formal_cast(tag: String, id: String) -> Dictionary:
	var sim: BattleSim = _scene.sim
	var previous: Dictionary = _scene.last_cast_result
	_formal_steps(sim, 1)
	var result: Dictionary = _scene.last_cast_result
	if not _require(tag + " 正式事务已提交 " + id, result.get("accepted", false) and result.get("skill_id") == id and result != previous, str(result)):
		return {}
	return result["details"]


## 对照实际遇敌后的权威关系和两类治疗；自动治疗的仇恨只由一次真实治疗增加。
func _formal_heals(tag: String, mage: BattleSim.Unit, priest: BattleSim.Unit, first: BattleSim.Unit, second: BattleSim.Unit, equipped: bool) -> bool:
	var sim: BattleSim = _scene.sim
	mage.pos = Vector2(510, 330)
	priest.pos = Vector2(510, 650)
	mage.hp = mage.max_hp - 30.25
	await _press("slot_%d" % (priest.slot + 1))
	_formal_click(_scene, mage.pos, MOUSE_BUTTON_RIGHT)
	await _press("skill_q")
	var details := _formal_cast(tag, "priest.holy.greater_heal")
	if details.is_empty():
		return false
	var effect: Dictionary = details["effects"][0]
	var expected := 2.40 * 77.0 * (1.05 if equipped else 1.0) * 1.025
	var shares: Array = effect["threat_changes"]
	_check(tag + " Q 治疗量只受自己的套装修正，保留浮点实得",
		is_equal_approx(effect["requested_amount"], expected) and is_equal_approx(effect["actual_amount"], 30.25) and effect["target_id"] == mage.id)
	_check(tag + " 实得治疗的 20% 按两个命中的敌人均分",
		shares.size() == 2 and shares[0]["enemy_id"] == first.id and shares[1]["enemy_id"] == second.id
		and is_equal_approx(shares[0]["amount"], 3.025) and is_equal_approx(shares[1]["amount"], 3.025)
		and first.engaged_allies.has(priest.id) and second.engaged_allies.has(priest.id), str(shares))
	_check(tag + " 牧师 Q 中文结果", _scene._skill_result_notice.contains("强效治疗") and _scene._skill_result_notice.contains("有效治疗 30"))
	mage.hp = mage.max_hp - 10.5
	priest.next_attack_at = 0.0
	var first_before := float(first.threat.get(priest.id, 0.0))
	var second_before := float(second.threat.get(priest.id, 0.0))
	var before: int = sim.events.lines.size()
	_formal_steps(sim, 1)
	priest.next_attack_at = 1000.0
	var heals := 0
	for line: String in sim.events.lines.slice(before):
		var event: Dictionary = JSON.parse_string(line)
		if event["e"] == "heal_done" and event["source_id"] == priest.id and event["target_id"] == mage.id:
			heals += 1
	_check(tag + " 自动治疗只记一次有效量及仇恨", heals == 1 and mage.hp == mage.max_hp
		and is_equal_approx(float(first.threat.get(priest.id, 0.0)) - first_before, 1.05)
		and is_equal_approx(float(second.threat.get(priest.id, 0.0)) - second_before, 1.05))
	await _press("skill_w")
	_check(tag + " 牧师 W 空槽不入队", _scene.controller.last_input.get("reason") == "EMPTY_SLOT")
	return true


## 从重新布置的接敌站位开始验证暗影箭；起读条不能提前建立交战。
func _formal_enemy_spell(tag: String, mage: BattleSim.Unit, caster: BattleSim.Unit) -> void:
	var sim: BattleSim = _scene.sim
	# 本用例重新布置初始接敌，清掉此前走查阶段的追击对象。
	caster.pos = mage.pos + Vector2(260, 0)
	caster.target_id = -1
	caster.cast_cd_until = 0.0
	var before := mage.hp
	_formal_steps(sim, 1)
	_check(tag + " 敌方正常读条，尚未激活", caster.cast.get("skill_id") == "shadow_bolt" and not caster.activated)
	_formal_steps(sim, 41)
	_check(tag + " 暗影箭正常命中、扣血并建立实际交战", caster.cast.is_empty() and caster.activated
		and caster.engaged_allies.has(mage.id) and mage.hp < before)


## 走查真实出征、正式技能及命中反馈和返场，固定部分站位使数值与结果可重复。
func _formal_walk(tag: String, duo: bool, equipped: bool, win: bool) -> bool:
	print("══ 正式五技能 ", tag, " ══")
	await _fresh_tavern()
	SortieSession.args_override = PackedStringArray(["--seed=7"])
	if not (await _formal_prepare_party(duo, equipped)) or not (await _open_sortie()):
		return false
	var before := _dump(tag + "_save_before")
	var start := SortieSession.bus().lines.size()
	var old := _scene.get_instance_id()
	if equipped:
		SortieSession.fail_load_left = 1
	if not (await _click("sortie_confirm")):
		return false
	if equipped:
		# 注入快照错值后重试，须拒绝且保留原 run_id，恢复后走同一个确认结果。
		await create_timer(0.3).timeout
		if not _require(tag + " 正式重试面板可见", _has("load_retry")):
			return false
		var specs: Array = _scene._formal_lock["specs"].duplicate()
		_scene._formal_lock["specs"] = ["bad"]
		if not (await _click("load_retry")):
			return false
		await create_timer(0.3).timeout
		var failures := _events("battle_load_failed", start)
		if not _require(tag + " 无效专精快照走加载失败，不加载不结算",
			failures.size() == 2 and failures[0]["run_id"] == failures[1]["run_id"]
			and String(failures[1]["reason"]).contains("专精快照无效") and _events("battle_loaded", start).is_empty()
			and _events("battle_settled", start).is_empty() and JSON.parse_string(_file_text()) == before):
			return false
		_scene._formal_lock["specs"] = specs
		if not (await _click("load_retry")):
			return false
	var arrived := await _wait_scene("Battle", old)
	if not _require(tag + " 到达实际 BattleScene", arrived):
		return false
	_scene.set_process(false)
	var sim: BattleSim = _scene.sim
	# 保留旧数值夹具的逐技能输入与断言，实战 AI 另走完整入口。
	sim.ally_ai_enabled = false
	sim.set_paused(false)
	var locks := _events("sortie_locked", start)
	var loads := _events("battle_loaded", start)
	if not _require(tag + " 正式专精非隔离，加载沿用锁定身份",
		sim.formal_skill_sortie and not _scene._skill_validation_mode and locks.size() == 1 and loads.size() == 1
		and locks[0]["party"]["run_id"] == loads[0]["run_id"] and locks[0]["party"]["slots"] == before["slots"]):
		return false
	var run_id: String = loads[0]["run_id"]
	var allies := sim.living("ally")
	var enemies := sim.living("enemy")
	if not _require(tag + " 正式人数、标准波次和初始套装", allies.size() == (2 if duo else 1) and enemies.size() == 4):
		return false
	var mage: BattleSim.Unit = allies[0]
	var priest: BattleSim.Unit = allies[1] if duo else null
	var first: BattleSim.Unit = enemies[0]
	var second: BattleSim.Unit = enemies[1]
	var views: Dictionary = sim.snapshot()["skills"]
	# 仅提取技能投影名称，保留原四槽顺序。
	_check(tag + " 法师出战满血满蓝，专精及 Q/W/E/R 与数值表一致", mage.kind == "mage" and mage.spec_id == "mage.fire" and mage.hp == 375.0 and mage.res == 100.0
		and mage.armor == 5.0 and mage.magic_resist == 40.0 and mage.formal_q_set == equipped and _scene.controller.selected_slot == mage.slot
		and views[mage.id].map(func(view: Dictionary) -> String: return view["name"]) == ["烈焰爆破", "火球", "烈焰屏障", "唤醒"])
	if duo:
		_check(tag + " 牧师出战满血满蓝，Q 治疗，W/E/R 空", priest.kind == "priest" and priest.spec_id == "priest.holy" and priest.hp == 425.0 and priest.res == 100.0
			and priest.formal_q_set == equipped and views[priest.id][0]["name"] == "强效治疗"
			and views[priest.id][1]["empty"] and views[priest.id][2]["empty"] and views[priest.id][3]["empty"])
	_check(tag + " 敌人在实际开场均未激活，采用各人数原缩放", enemies.all(
		# 同时核查权威关系与仇恨，待 AI 实际命中才建立。
		func(enemy: BattleSim.Unit) -> bool: return not enemy.activated and enemy.engaged_allies.is_empty() and enemy.threat.is_empty())
		and first.max_hp == (299.0 if duo else 282.0) and first.dmg_scale == (0.6 if duo else 0.331))
	await _shot(tag + "_start")
	mage.pos = Vector2(510, 330)
	mage.next_attack_at = 1000.0
	for index: int in enemies.size():
		var enemy: BattleSim.Unit = enemies[index]
		enemy.pos = Vector2(1720, 300 + 170 * index)
		enemy.next_attack_at = 1000.0
		enemy.cast_cd_until = 1000.0
	if duo:
		priest.pos = Vector2(510, 650)
		mage.hp -= 20.25
		_formal_steps(sim, 1)
		# 空交战快照不能被站位、自动选敌或受疗本身扩张。
		_check(tag + " 空交战可自动治疗，所有敌人仇恨仍为空", mage.hp == mage.max_hp - 0.25
			and enemies.all(func(enemy: BattleSim.Unit) -> bool: return enemy.threat.is_empty() and not enemy.activated))
		mage.hp = mage.max_hp
		priest.next_attack_at = 1000.0
		_formal_target_hud(tag, mage, priest, first)
	await _press("skill_e")
	var barrier := _formal_cast(tag, "mage.fire.flame_barrier")
	if barrier.is_empty():
		return false
	_check(tag + " E 固定 111 盾，套装和旧天赋不改盾量", is_equal_approx(float(mage.shield.get("remaining", 0.0)), 111.0))
	var shield_before := float(mage.shield.get("remaining", 0.0))
	first.pos = mage.pos + Vector2(50, 0)
	first.next_attack_at = 0.0
	_formal_steps(sim, 1)
	_check(tag + " 首次敌方普攻全吸收，扣同一盾池且登记交战", mage.hp == mage.max_hp
		and float(mage.shield.get("remaining", 0.0)) < shield_before and first.activated and first.engaged_allies.has(mage.id)
		and first.threat.is_empty())
	first.next_attack_at = 1000.0
	first.pos = Vector2(1490, 330)
	_formal_steps(sim, 125)
	_check(tag + " 盾自然到期且距离不解除交战", mage.shield.is_empty() and first.activated and first.engaged_allies.has(mage.id))

	# 复位到两个真实出生的存活目标，验证右键接既有普攻命令及 Q 的有序范围快照。
	mage.pos = Vector2(510, 330)
	first.pos = Vector2(1170, 330)
	second.pos = Vector2(1350, 330)
	enemies[2].pos = Vector2(1700, 800)
	enemies[3].pos = Vector2(1650, 840)
	_formal_click(_scene, first.pos, MOUSE_BUTTON_RIGHT)
	await _press("skill_q")
	var burst := _formal_cast(tag, "mage.fire.flame_burst")
	if burst.is_empty():
		return false
	var targets: Array = burst["effects"]
	var q_expected := 1.7 * 74.0 * (1.05 if equipped else 1.0) * 1.025
	_check(tag + " Q 保留范围名单顺序及套装单次 5%", targets.size() == 2 and targets[0]["target_id"] == first.id
		and targets[1]["target_id"] == second.id and is_equal_approx(targets[0]["raw_amount"], q_expected)
		and is_equal_approx(targets[1]["raw_amount"], q_expected) and mage.auto_target_id == first.id, str(targets))
	_check(tag + " Q 中文结果", _scene._skill_result_notice.contains("2 个目标") and _scene._skill_result_notice.contains("烈焰爆破"))
	var view: Node2D = _scene.get_node("View")
	var first_hit: Dictionary = view._enemy_hits.get(first.id, {})
	var second_hit: Dictionary = view._enemy_hits.get(second.id, {})
	_check(tag + " 正式范围伤害只让两个实际扣血目标闪白",
		view._enemy_hits.size() == 2 and not first_hit.is_empty() and not second_hit.is_empty()
		and int(first_hit["flash_at"]) - int(first_hit["critical_at"]) == view.CRITICAL_RING_MS
		and int(second_hit["flash_at"]) - int(second_hit["critical_at"]) == view.CRITICAL_RING_MS)
	_formal_steps(sim, 21)
	var fireball_button: Rect2 = view.call("_skill_rect", 1)
	_formal_click(view, fireball_button.get_center(), MOUSE_BUTTON_LEFT)
	var ball := _formal_cast(tag, "mage.fire.fireball")
	if ball.is_empty():
		return false
	_check(tag + " W 按钮命中，伤害不吃 Q 套装或旧天赋", is_equal_approx(ball["effects"][0]["raw_amount"], 1.1 * 74.0 * 1.025))
	_formal_steps(sim, 21)
	var evocation_button: Rect2 = view.call("_skill_rect", 3)
	_formal_click(view, evocation_button.get_center(), MOUSE_BUTTON_LEFT)
	var echo := _formal_cast(tag, "mage.fire.evocation")
	if echo.is_empty():
		return false
	_check(tag + " R 实得按最大法力裁剪，套装和旧天赋不加成",
		is_equal_approx(echo["effects"][0]["actual_amount"], minf(35.0, 100.0 - float(echo["mana_before"]))))
	if duo and not (await _formal_heals(tag, mage, priest, first, second, equipped)):
		return false
	_formal_enemy_spell(tag, mage, enemies[2])
	_scene._refresh_view()
	await _shot(tag + "_cast")

	# 胜负测试只调整夹具站位和剩余生命，仍由原普攻、结束判定和结算实际触发。
	if win:
		var offset := 0
		for enemy: BattleSim.Unit in sim.living("enemy"):
			enemy.hp = 1.0
			enemy.pos = mage.pos + Vector2(55 + 85 * offset, 15)
			enemy.speed = 0.0
			offset += 1
		# 治疗后当前操控仍是牧师，先用实际快捷键切回输出角色再逐个右键。
		_battle_key(KEY_F1, true)
		_battle_key(KEY_F1, false)
		for enemy: BattleSim.Unit in sim.living("enemy"):
			_formal_click(_scene, enemy.pos, MOUSE_BUTTON_RIGHT)
			mage.next_attack_at = 0.0
			_formal_steps(sim, 1)
	else:
		mage.hp = 1.0
		first.pos = mage.pos + Vector2(50, 0)
		first.next_attack_at = 0.0
		if duo:
			priest.hp = 1.0
			second.pos = priest.pos + Vector2(50, 0)
			second.next_attack_at = 0.0
		_formal_steps(sim, 1)
	var expected := "win" if win else "lose"
	if not _require(tag + " 正式一场胜负均可结算 " + expected, sim.finished and sim.result == expected, "%s %s" % [sim.result, sim.reason]):
		return false
	_check(tag + " 战斗结束清理盾、激活、关系及仇恨", mage.shield.is_empty() and enemies.all(
		# 包含阵亡及战败后存活的敌人。
		func(enemy: BattleSim.Unit) -> bool: return not enemy.activated and enemy.engaged_allies.is_empty() and enemy.threat.is_empty()))
	var battle_id := _scene.get_instance_id()
	await _press("ui_accept")
	var returned := await _wait_scene("Tavern", battle_id)
	var settles := _events("battle_settled", start)
	var returns := _events("battle_returned", start)
	if not _require(tag + " 正式同 run_id 结算一次并返场一次",
		returned and settles.size() == 1 and settles[0]["run_id"] == run_id and settles[0]["result"] == expected
		and returns.size() == 1 and returns[0]["result"] == expected):
		return false
	_check(tag + " 离场解绑，清遗留队列及关系", not sim._skill_schedule_active and sim.skill_battle_id.is_empty() and sim._skill_pending.is_empty())
	var after := _dump(tag + "_save_after")
	_check(tag + " 返场保留原队长、四槽、装备和旧天赋", after.get("captainSlot") == before["captainSlot"] and after.get("slots") == before["slots"]
		and after.get("equips") == before["equips"] and after.get("talentId") == before["talentId"])
	if not win:
		_check(tag + " 战败无奖励", after.get("pendingReward") == null and after.get("ownedItems") == before["ownedItems"])
		return true
	var pending: Variant = after.get("pendingReward")
	if not _require(tag + " 正式胜利待领同 run_id", pending is Dictionary and pending.get("run_id") == run_id):
		return false
	if not (await _open_sortie()) or not (await _click("blocker_action_pending_reward")):
		return false
	var buttons := root.find_children("claim_*", "Button", true, false)
	if not _require(tag + " 有真实领奖按钮", not buttons.is_empty()) or not (await _click(String(buttons[0].name))):
		return false
	var claimed := _dump(tag + "_save_claimed")
	var repeated: Dictionary = _scene.service.claim("mage")
	_check(tag + " 同场只能成功领奖一次", claimed.get("pendingReward") == null
		and claimed["claimedRuns"].count(run_id) == 1 and claimed["ownedItems"].size() == before["ownedItems"].size() + 1
		and not repeated["ok"] and JSON.parse_string(_file_text()) == claimed)
	return true
