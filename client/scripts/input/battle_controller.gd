extends RefCounted
## 将选人、选目标、瞄准和鼠标指令转换为模拟器命令。
## 角色与技能目标属于当前战斗，不写回队长或存档。

const MovementInput := preload("res://scripts/input/movement_input.gd")
const BattleSim := preload("res://scripts/battle/battle_sim.gd")
const BattleEvents := preload("res://scripts/battle/battle_events.gd")

var sim: BattleSim
var events: BattleEvents
var movement := MovementInput.new()
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
const FPS_CHOICES := [0, 60, 120, 240, 480, 720, 1000]
const RESOLUTION_CHOICES := [0, 720, 1080, 1440, 2160]
const PREF_DEFAULTS := {"names": false, "release_cast": false, "tab_health": false, "teammate_health": true, "fps": 0, "resolution": 0}
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
	movement.interrupt()
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


## 切换槽位时结束旧角色的持续走位，再交接控制权和界面反馈。
func select_slot(slot_index: int) -> bool:
	if _skill_input_mode and not _skill_binding_current():
		return false
	if slot_index < 0 or slot_index >= BattleSim.SLOT_COUNT:
		return false
	if sim.slot_unit(slot_index) == null:
		return false
	if slot_index != selected_slot:
		interrupt_direction()
		selected_slot = slot_index
		_reset_tab()
		if sim.controlled_actor_id >= 0:
			sim.set_controlled_actor(selected_unit().id)
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
		if _valid_preference(key, value):
			preferences[key] = value


## 旧版开关仍按原入口切换，显示档位使用明确的档位值。
func toggle_preference(key: String, path: String = PREFS_PATH) -> bool:
	if not preferences.get(key) is bool:
		return false
	return set_preference(key, not preferences[key], path)


## 只接受面板支持的档位或已有开关，坏配置回到跟随系统。
static func _valid_preference(key: String, value: Variant) -> bool:
	match key:
		"fps":
			return value is int and value in FPS_CHOICES
		"resolution":
			return value is int and value in RESOLUTION_CHOICES
		_:
			return PREF_DEFAULTS.get(key) is bool and value is bool


## 优先持久化再更新面板状态；写失败时保留原设置。
func set_preference(key: String, value: Variant, path: String = PREFS_PATH) -> bool:
	if not _valid_preference(key, value):
		return false
	var updated := preferences.duplicate()
	updated[key] = value
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


## 实战右键按可见命中分流，点合法单位下达普攻或普疗，点地面提交走位。
func player_right_click(pos: Vector2, target_id: int = -1) -> void:
	var actor := selected_unit()
	if actor == null or not actor.alive or sim.finished or (_skill_input_mode and not _skill_binding_current()):
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
		if last_input["queued"]:
			interrupt_direction()
			# 观察目标即时反馈，排队执行不覆盖较晚的左键选择。
			if target != null:
				select_target(target.id)
	elif target != null:
		if sim.issue_player_target(actor, target):
			interrupt_direction()
			select_target(target.id)
	elif sim.order_move(actor.id, pos):
		interrupt_direction()


## 每步只提交变化后的方向，正式场按与鼠标和技能相同的顺序执行。
func update_direction(enabled: bool) -> bool:
	var actor := selected_unit()
	if not enabled or actor == null or not actor.alive or not actor.controllable or actor.statuses.has("ice_block") or actor.statuses.has("frozen") or (_skill_input_mode and not _skill_binding_current()):
		interrupt_direction()
		return false
	var previous := movement.direction
	if not previous.is_zero_approx() and actor.order_kind != "direction" and not sim.direction_pending(actor.id):
		# 已执行的技能或目标指令可能在模拟步里接管，等待原输入回中。
		movement.interrupt()
		return false
	var direction := movement.poll()
	if direction.is_equal_approx(previous):
		return false
	var accepted: bool
	if _skill_input_mode:
		var result := sim._enqueue_skill_command("direction", {"battle_id": _skill_bound_id, "caster_id": actor.id, "direction": direction})
		accepted = result["queued"]
	else:
		accepted = sim.order_direction(actor.id, direction)
	if not accepted:
		movement.interrupt()
	return accepted and not direction.is_zero_approx()


## 暂停、切人或打开瞄准入口时结束持续命令，旧的摇杆方向不会转交给新角色。
func interrupt_direction() -> void:
	var actor := selected_unit()
	if actor != null and (actor.order_kind == "direction" or not movement.direction.is_zero_approx()):
		sim.clear_direction(actor.id)
	movement.interrupt()


## 投影合法目标及实际地面落点，单位超距时仍允许提交接近命令。
func aim_view(key: String, pointer: Vector2, on_ground: bool) -> Dictionary:
	var actor := selected_unit()
	if actor == null or not actor.alive:
		return {}
	var from_resource := _skill_input_mode and actor.spec_id != "mage.frost"
	var skill: Dictionary = actor.resolved_slots.get(key, {}) if from_resource else actor.skills.get(key, {})
	if skill.is_empty():
		return {}
	var target := target_for(actor)
	var target_kind := String(skill.get("target_kind", skill.get("target", ""))).to_upper()
	var burst: bool = skill.get("skill_id", skill.get("id")) in ["mage.fire.flame_burst", "fire_burst"]
	var scale := BattleSim.SCENE_UNITS_PER_METER if from_resource else 1.0
	var reach := float(skill.get("cast_range_m", skill.get("range", 0.0))) * scale
	if target_kind == "DIRECTION":
		var landing := sim.blink_landing(actor, pointer, reach)
		return {"aim": {"point": pointer}, "ground": true, "direction": true,
			"center": landing if landing.is_finite() else actor.pos, "radius": actor.radius, "reach": reach,
			"origin": actor.pos, "valid": on_ground and landing.is_finite(), "reason": "NO_BLINK_LANDING",
			"show": true, "target": -1}
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
	var approach := sim.player_controls and location_ok and not is_ground and not in_range
	var aim: Dictionary = {"point": center} if is_ground else {"target": target_id}
	if is_ground and location_ok and sim.player_controls:
		center = sim.ground_cast_center(actor.pos, pointer, reach)
		if not from_resource:
			aim["point"] = center
	return {"aim": aim, "ground": is_ground, "center": center, "radius": radius, "reach": reach,
		"origin": actor.pos, "valid": location_ok and (in_range or approach or (is_ground and sim.player_controls)), "approach": approach,
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


## 旧版左键点可见队友选人，普通地面维持当前命令。
func on_left_click(world_pos: Vector2, seen_target_id: Variant = null) -> void:
	if (_skill_input_mode and not _skill_binding_current()) or sim.finished:
		return
	var ally: BattleSim.Unit = sim.unit_at(world_pos, "ally") if seen_target_id == null else sim.units.get(seen_target_id)
	if ally != null and ally.side == "ally" and ally.alive:
		select_slot(ally.slot)


## 兼容旧版和验证场的右键入口，保留各自的目标处理方式。
func on_right_click(world_pos: Vector2, seen_target_id: Variant = null) -> void:
	if (_skill_input_mode and not _skill_binding_current()) or sim.finished:
		return
	var actor := selected_unit()
	if actor == null or not actor.alive:
		return
	var target: BattleSim.Unit = sim.units.get(seen_target_id) if seen_target_id != null else sim.unit_at(world_pos, "enemy")
	if target == null and seen_target_id == null and (not _skill_input_mode or actor.attack_kind == "heal"):
		target = sim.unit_at(world_pos, "ally")
	if _skill_input_mode:
		if target != null:
			if sim.formal_skill_sortie and target.side != ("ally" if actor.attack_kind == "heal" else "enemy"):
				return
			last_input = sim._enqueue_skill_command("target", {"battle_id": _skill_bound_id, "caster_id": actor.id, "target_id": target.id}).duplicate(true)
		else:
			last_input = sim._enqueue_skill_command("move", {"battle_id": _skill_bound_id, "caster_id": actor.id, "pos": world_pos}).duplicate(true)
		if last_input["queued"]:
			interrupt_direction()
		return
	var accepted: bool
	if target == null:
		accepted = sim.order_move(actor.id, world_pos)
	elif target.side == "enemy":
		accepted = sim.order_attack(actor.id, target.id)
	else:
		accepted = sim.order_heal(actor.id, target.id)
	if accepted:
		interrupt_direction()


## 正式输入返回入队状态。混编真人允许接近，具体施法由模拟器结算。
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
	var check := sim.check_cast(unit.id, key, aim, sim.player_controls and aim.has("target"))
	var applied := sim.cast_skill(unit.id, key, aim)
	last_input = {"queued": applied, "reason": "" if applied else check["reason"]}
	return applied


## 撤回当前角色尚未施放的命令。正式场和移动、施法按同一队列排序。
func cancel_skill_approach() -> void:
	var actor := selected_unit()
	if actor == null or not sim.player_controls:
		return
	if _skill_input_mode:
		sim._enqueue_skill_command("cancel_cast", {"battle_id": _skill_bound_id, "caster_id": actor.id})
	else:
		sim.cancel_player_approach(actor.id)


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
