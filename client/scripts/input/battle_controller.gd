extends RefCounted
## 将选人、选目标、瞄准和鼠标指令转换为模拟器命令。
## 角色与技能目标属于当前战斗，不写回队长或存档。

const BattleSim := preload("res://scripts/battle/battle_sim.gd")
const BattleEvents := preload("res://scripts/battle/battle_events.gd")

var sim: BattleSim
var events: BattleEvents
## 当前选中的槽位 0～3；没有可选成员时为 -1。
var selected_slot: int = -1
## 隔离绑定保持原场身份；失效后不能回退旧施法或自动认领下一场。
var _skill_input_mode: bool = false
var _skill_full_input: bool = false
var _skill_bound_id: String = ""
var _skill_request_seq: int = 0
## 只记录接收诊断，执行结果由场景订阅 cast_resolved 单独保存。
var last_input: Dictionary = {}
const PREFS_PATH := "user://battle_preferences.cfg"
const PREF_DEFAULTS := {"names": false, "release_cast": false, "tab_health": false}
var preferences := PREF_DEFAULTS.duplicate()
var _tab_ids: Array[int] = []
var _tab_next: int = 0



## 显式隔离或由酒馆预建的正式场可绑定技能队列，旧路径与同场重复绑定语义保留。
func setup(battle_sim: BattleSim, bus: BattleEvents, preferred_slot: int = -1, skill_validation: bool = false) -> bool:
	var use_queue := skill_validation or (battle_sim != null and battle_sim.formal_skill_sortie)
	if use_queue:
		if battle_sim == null or bus == null or battle_sim.events != bus or not battle_sim._skill_schedule_active or not battle_sim._skill_transactions_enabled or battle_sim.skill_battle_id.is_empty() or battle_sim.finished or battle_sim.skill_input_locked:
			return false
		var same_binding := _skill_input_mode and sim == battle_sim and events == bus and _skill_bound_id == battle_sim.skill_battle_id
		# 控制器一旦隔离绑定只能留在原场；新场必须显式创建新控制器。
		if _skill_input_mode and not same_binding:
			return false
		if not same_binding:
			var full_input := battle_sim._skill_full_numeric and battle_sim._skill_resolution_scope == "S2_3_SHIELD_AWARE"
			# 只有全量隔离首绑接受原子安装的初始盾登记；整数号已占用时不能从零开始。
			if not _skill_first_binding_available(battle_sim, full_input):
				return false
			_skill_full_input = full_input
			_skill_request_seq = 0
		_skill_input_mode = true
		_skill_bound_id = battle_sim.skill_battle_id
	elif _skill_input_mode:
		return false
	sim = battle_sim
	events = bus
	if use_queue:
		last_input = {}
		selected_slot = -1
	if preferred_slot >= 0 and sim.slot_unit(preferred_slot) != null:
		selected_slot = preferred_slot
		return true
	for slot_index in BattleSim.SLOT_COUNT:
		if sim.slot_unit(slot_index) != null:
			selected_slot = slot_index
			return true
	return true


## 首绑复核已有登记。初始盾须对应本场目标及 Sim 校验过的安装身份。
func _skill_first_binding_available(battle_sim: BattleSim, full_input: bool) -> bool:
	for key: Variant in battle_sim._skill_seen_requests:
		if not full_input or not key is String:
			return false
		var entry: Variant = battle_sim._skill_seen_requests[key]
		if not entry is Dictionary or not entry.get("target_id") is int:
			return false
		var target: BattleSim.Unit = battle_sim.units.get(entry["target_id"])
		if target == null or target.shield.get("source_cast_id") != key or not battle_sim._skill_shield_problems(target).is_empty():
			return false
	return true


## 读取当前查看对象；解绑后安全返回空，不影响任何 Unit 状态。
func selected_unit() -> BattleSim.Unit:
	return sim.slot_unit(selected_slot) if sim != null and selected_slot >= 0 else null


## 真人只通过数字键或功能键换人；兼容入口仍可调用同一槽位选择。
func select_slot(slot_index: int) -> bool:
	if _skill_input_mode and not _skill_binding_current():
		return false
	if slot_index < 0 or slot_index >= BattleSim.SLOT_COUNT:
		return false
	if sim.slot_unit(slot_index) == null:
		return false
	if slot_index != selected_slot:
		selected_slot = slot_index
		_reset_tab()
		events.select(slot_index)
	return true


## 本地偏好与角色存档独立，逐字段校验以兼容旧档和损坏配置。
func load_preferences(path: String = PREFS_PATH) -> void:
	preferences = PREF_DEFAULTS.duplicate()
	var config := ConfigFile.new()
	if config.load(path) != OK:
		return
	for key in PREF_DEFAULTS:
		var value: Variant = config.get_value("battle", key, PREF_DEFAULTS[key])
		if value is bool:
			preferences[key] = value


## 优先持久化再更新面板状态；写失败时调用方可显示明确提示。
func toggle_preference(key: String, path: String = PREFS_PATH) -> bool:
	if not preferences.has(key):
		return false
	var updated := preferences.duplicate()
	updated[key] = not updated[key]
	var config := ConfigFile.new()
	for option in updated:
		config.set_value("battle", option, updated[option])
	if config.save(path) != OK:
		return false
	preferences = updated
	if key == "tab_health":
		_reset_tab()
	return true


## 重置只丢弃遍历快照，角色已经选定的目标仍然保留。
func _reset_tab() -> void:
	_tab_ids.clear()
	_tab_next = 0


## 查询本角色的存活选择；尸体、离场单位和禁用单位不会显示或施法。
func target_for(actor: BattleSim.Unit) -> BattleSim.Unit:
	return sim.player_selected_target(actor)


## 地图与血条点击共用此纯选择，不写入持续指令。
func select_target(id: int) -> void:
	var actor := selected_unit()
	var target: BattleSim.Unit = sim.units.get(id)
	if actor != null and actor.alive and target != null and target.alive and target.selectable and not sim.finished:
		actor.selected_target_id = id


## 每轮固定顺序，只在队列耗尽时重新采样血量或距离。
func cycle_target() -> void:
	var actor := selected_unit()
	if actor == null or not actor.alive or sim.finished:
		return
	while _tab_next < _tab_ids.size():
		var id := _tab_ids[_tab_next]
		_tab_next += 1
		var enemy: BattleSim.Unit = sim.units.get(id)
		if enemy != null and enemy.alive and enemy.selectable and enemy.side == "enemy":
			select_target(id)
			return
	_reset_tab()
	var candidates: Array[Dictionary] = []
	for enemy in sim.living("enemy"):
		if enemy.selectable:
			candidates.append({"id": enemy.id, "rank": enemy.hp if preferences["tab_health"] else actor.pos.distance_squared_to(enemy.pos)})
	# 相同排名按单位 ID，避免同一场中受容器插入顺序影响。
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["id"] < b["id"] if a["rank"] == b["rank"] else a["rank"] < b["rank"])
	for entry in candidates:
		_tab_ids.append(entry["id"])
	if not _tab_ids.is_empty():
		select_target(_tab_ids[0])
		_tab_next = 1


## 右键场上单位交持续指令；右键地面仍由模型裁剪到可走区域。
func player_right_click(pos: Vector2, target_id: int = -1) -> void:
	var actor := selected_unit()
	if actor == null or not actor.alive or sim.finished:
		return
	var target: BattleSim.Unit = sim.units.get(target_id)
	if target != null and target.side != ("ally" if actor.attack_kind == "heal" else "enemy"):
		return
	if _skill_input_mode:
		var kind := "target" if target != null else "move"
		var payload := {"battle_id": _skill_bound_id, "caster_id": actor.id}
		if target != null:
			payload["target_id"] = target.id
		else:
			payload["pos"] = pos
		last_input = sim._enqueue_skill_command(kind, payload)
		# 记录即时观察目标，后续命令显式冻结此选择，排队执行不覆盖较晚的左键。
		if target != null and last_input["queued"]:
			select_target(target.id)
	elif target != null:
		if sim.issue_player_target(actor, target):
			select_target(target.id)
	else:
		sim.order_move(actor.id, pos)


## 从已有技能定义投影瞄准形态；技能身份与实际落点由模拟器在执行时再验证。
func aim_view(key: String, pointer: Vector2, on_ground: bool) -> Dictionary:
	var actor := selected_unit()
	if actor == null or not actor.alive:
		return {}
	var skill: Dictionary = actor.resolved_slots.get(key, {}) if _skill_input_mode else actor.skills.get(key, {})
	if skill.is_empty():
		return {}
	var target := target_for(actor)
	var target_kind := String(skill.get("target_kind", skill.get("target", ""))).to_upper()
	var burst: bool = skill.get("skill_id", skill.get("id")) in ["mage.fire.flame_burst", "fire_burst"]
	var scale := BattleSim.SCENE_UNITS_PER_METER if _skill_input_mode else 1.0
	var reach := float(skill.get("cast_range_m", skill.get("range", 0.0))) * scale
	var radius := 0.0
	for effect: Dictionary in skill["effects"]:
		radius = maxf(radius, float(effect.get("radius_m", effect.get("radius", 0.0))) * scale)
	var target_id := target.id if target != null else -1
	var is_ground := burst and (target == null or target.side != "enemy")
	var matches := target != null and (target.side == ("ally" if target_kind == "ALLY" else "enemy"))
	var center := actor.pos
	if is_ground:
		center = pointer
	elif matches and target_kind != "SELF":
		center = target.pos
	var location_ok := on_ground and sim.has_arena_point(center) if is_ground else (target_kind == "SELF" or matches)
	var in_range := target_kind == "SELF" or actor.pos.distance_to(center) <= reach
	var aim: Dictionary = {"point": center} if is_ground else {"target": target_id}
	return {"aim": aim, "ground": is_ground, "center": center, "radius": radius, "reach": reach,
		"origin": actor.pos, "valid": location_ok and in_range,
		"reason": "out_of_range" if location_ok else "no_target",
		"show": is_ground or matches or target_kind == "SELF", "target": -1 if is_ground or target_kind == "SELF" else target_id}


## 真人入口先确认瞄准位置，再把身份和落点随请求传到统一技能入口。
func submit_player_skill(key: String, pointer: Vector2, on_ground: bool) -> bool:
	var actor := selected_unit()
	if actor != null:
		sim.reserve_manual_cast(actor.id)
	var view := aim_view(key, pointer, on_ground)
	if view.is_empty() or not view["valid"]:
		last_input = {"queued": false, "reason": view.get("reason", "EMPTY_SLOT")}
		return false
	return press_skill(key, view["aim"])


## 左键。点己方只选人；点地才移动。没有选中英雄时战场指令无效。
func on_left_click(world_pos: Vector2) -> void:
	if _skill_input_mode and not _skill_binding_current():
		return
	if sim.finished:
		return
	var ally := sim.unit_at(world_pos, "ally")
	if ally != null:
		select_slot(ally.slot)
		return
	var unit := selected_unit()
	if unit == null:
		return
	if _skill_input_mode:
		last_input = sim._enqueue_skill_command("move", {"battle_id": _skill_bound_id, "caster_id": unit.id, "pos": world_pos}).duplicate(true)
		return
	sim.order_move(unit.id, world_pos)


## 右键进入同一队列时，正式按原职业派发攻击/治疗，隔离只设目标；旧模式即时执行。
func on_right_click(world_pos: Vector2) -> void:
	if _skill_input_mode:
		if not _skill_binding_current():
			return
		var caster := selected_unit()
		if caster == null:
			return
		var target := sim.unit_at(world_pos, "enemy")
		if target == null and caster.kind == "priest":
			target = sim.unit_at(world_pos, "ally")
		if target != null:
			# 正式牧师右键仍只接受友方。执行点再检查目标是否存活，不把命令提前写回。
			if sim.formal_skill_sortie and caster.attack_kind == "heal" and target.side != "ally":
				return
			last_input = sim._enqueue_skill_command("target", {"battle_id": _skill_bound_id, "caster_id": caster.id, "target_id": target.id}).duplicate(true)
		return
	if sim.finished:
		return
	var unit := selected_unit()
	if unit == null:
		return
	var enemy := sim.unit_at(world_pos, "enemy")
	if enemy != null:
		sim.order_attack(unit.id, enemy.id)
		return
	var ally := sim.unit_at(world_pos, "ally")
	if ally != null:
		sim.order_heal(unit.id, ally.id)


## Q/W/E/R 由调用方过滤重复按下；隔离返回只表示入队。旧两字段场仍只接唤醒。
func press_skill(key: String, aim: Dictionary = {}) -> bool:
	if _skill_input_mode:
		if not _skill_binding_current():
			return false
		var caster := selected_unit()
		if caster == null:
			last_input = {"queued": false, "reason": "NO_CASTER"}
			return false
		var slot := key.to_lower()
		if slot not in BattleSim.SKILL_KEYS:
			last_input = {"queued": false, "reason": "EMPTY_SLOT"}
			return false
		var skill: Dictionary
		var implemented: bool
		if _skill_full_input:
			# 完整场只读实现标识。目标、法力、冷却等条件按队列顺序在执行点裁定。
			skill = sim.get_skill_view(caster.id, slot.to_upper())
			if skill["empty"]:
				last_input = {"queued": false, "reason": skill["reason"]}
				return false
			implemented = skill["implemented"]
		else:
			skill = caster.resolved_slots.get(slot, {})
			if skill.is_empty():
				last_input = {"queued": false, "reason": "EMPTY_SLOT"}
				return false
			implemented = skill.get("skill_id") == "mage.fire.evocation"
		if not implemented:
			last_input = {"queued": false, "reason": "NOT_IMPLEMENTED"}
			return false
		# 即使暂停丢弃或执行失败，已生成的身份也永不重用；切人不影响递增序号。
		_skill_request_seq = sim.next_player_cast_seq() if sim.ally_ai_enabled else _skill_request_seq + 1
		var request := {"battle_id": _skill_bound_id, "request_seq": _skill_request_seq, "caster_id": caster.id, "slot": slot.to_upper(), "expected_skill_id": skill["skill_id"]}
		if not aim.is_empty():
			request["aim"] = aim
		last_input = sim._enqueue_skill_command("cast", request).duplicate(true)
		return bool(last_input.get("queued", false))
	if sim.finished:
		return false
	var unit := selected_unit()
	if unit == null:
		return false
	last_input = {"queued": false, "reason": sim.check_cast(unit.id, key, aim).get("reason", "")}
	var applied := sim.cast_skill(unit.id, key, aim)
	last_input["queued"] = applied
	return applied


## 暂停仍交模拟器处理；隔离绑定失效时不能影响新场。
func toggle_pause() -> void:
	if _skill_input_mode and not _skill_binding_current():
		return
	sim.set_paused(not sim.paused)


## 校验固定场身份及输入生命周期，暂停仍允许切人；战术丢弃交统一接收入口。
func _skill_binding_current() -> bool:
	if sim == null or events == null or sim.events != events or _skill_bound_id.is_empty() or sim.skill_battle_id != _skill_bound_id or not sim._skill_schedule_active:
		last_input = {"queued": false, "reason": "STALE_BATTLE"}
		return false
	if sim.finished or sim.skill_input_locked or not sim._skill_transactions_enabled:
		last_input = {"queued": false, "reason": "INPUT_LOCKED"}
		return false
	return true


## 场景拥有清场职责；控制器解除引用但保留隔离标记，避免旧引用回退即时旧入口。
func release_skill_validation() -> void:
	if not _skill_input_mode:
		return
	_skill_bound_id = ""
	sim = null
	events = null
	selected_slot = -1
	last_input = {"queued": false, "reason": "INPUT_LOCKED"}
