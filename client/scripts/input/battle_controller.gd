extends RefCounted
## 战斗输入翻译：把「选人 / 点地 / 右键 / 技能键」变成对模拟器的命令。
## 不画界面、不算伤害；选中只记在这里，不写回存档，也不影响队长。

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


## 按 1～4 或点头像。空槽不改变当前选择。
func select_slot(slot_index: int) -> bool:
	if _skill_input_mode and not _skill_binding_current():
		return false
	if slot_index < 0 or slot_index >= BattleSim.SLOT_COUNT:
		return false
	if sim.slot_unit(slot_index) == null:
		return false
	if slot_index != selected_slot:
		selected_slot = slot_index
		events.select(slot_index)
	return true


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
func press_skill(key: String) -> bool:
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
		_skill_request_seq += 1
		var request := {"battle_id": _skill_bound_id, "request_seq": _skill_request_seq, "caster_id": caster.id, "slot": slot.to_upper(), "expected_skill_id": skill["skill_id"]}
		last_input = sim._enqueue_skill_command("cast", request).duplicate(true)
		return bool(last_input.get("queued", false))
	if sim.finished:
		return false
	var unit := selected_unit()
	if unit == null:
		return false
	return sim.cast_skill(unit.id, key)


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
