extends RefCounted
## 战斗结算（逻辑层）。纯数据、固定步长，不依赖场景、动画或帧率。
## 随机只来自 setup 时的种子；所有数值读 BattleConfig（data/balance/ 正式表 + data/battle_layout.json）。
## 结算结果通过 BattleEvents 对外发信号，表现只订阅，不回写这里。

const BattleConfig := preload("res://scripts/battle/battle_config.gd")
const SCENE_UNITS_PER_METER := 100.0
const SKILL_FIXED_STEP := 1.0 / 60.0

const BattleEvents := preload("res://scripts/battle/battle_events.gd")

const SKILL_KEYS: Array[String] = ["q", "w", "e", "r"]
const SLOT_COUNT := 4


class Unit:
	extends RefCounted
	var id: int = 0
	var side: String = "ally"
	var slot: int = -1
	var kind: String = ""
	var display_name: String = ""
	var color_hex: String = "ffffff"
	var radius: float = 22.0
	var max_hp: float = 1.0
	var hp: float = 1.0
	var pos: Vector2 = Vector2.ZERO
	var speed: float = 100.0
	var alive: bool = true
	# 普攻（友方 damage / heal；敌方近战）
	var attack_kind: String = "damage"
	var attack_range: float = 0.0
	var attack_damage: float = 0.0
	var attack_interval: float = 1.0
	var next_attack_at: float = 0.0
	# 命令
	var order_kind: String = "none"
	var order_pos: Vector2 = Vector2.ZERO
	## 玩家选中的施法目标、持续指令对象与已计入统计的扣血分别记录。
	var target_id: int = -1
	var selected_target_id: int = -1
	var auto_target_id: int = -1
	var manual_target_id: int = -1
	var ai_joined: bool = false
	var ai_personal_order: bool = false
	var ai_contact: bool = false
	var ai_evading: bool = false
	var damage_done: float = 0.0
	# 资源
	var res_kind: String = ""
	var res: float = 0.0
	var res_max: float = 0.0
	var res_regen: float = 0.0
	var res_on_attack: float = 0.0
	var res_emit_at: float = 0.0
	var res_emit_value: int = -1
	var threat_coef: float = 1.0
	# 技能（友方）
	var skills: Dictionary = {}
	var cd_until: Dictionary = {}
	var gcd_until: float = 0.0
	# 正式资源槽与配表槽独立；寒霜在两种阵容中使用配表槽。
	var spec_id: String = ""
	var resolved_slots: Dictionary = {}
	var skill_ready_at: Dictionary = {}
	# 仅正式专精 Q 使用出征时锁定的套装资格，不改 Skill Resource 或其他技能。
	var formal_q_set: bool = false
	# 仅显式启用隔离事务时安装，不能从旧回蓝速度反推评级。
	var combat_stats: Dictionary = {}
	var controllable: bool = true
	var selectable: bool = true
	# 状态：status_id -> {until, source, ...参数}
	var statuses: Dictionary = {}
	# 单一常规盾池；空字典无盾，身份与剩余量不能由表现或旧状态表代管。
	var shield: Dictionary = {}
	# 敌方
	var threat: Dictionary = {}
	# 完整数值隔离场的权威关系；不能从仇恨键、距离或当前目标反推。
	var activated: bool = false
	var engaged_allies: Dictionary = {}
	var spell: Dictionary = {}
	var cast: Dictionary = {}
	## 真人点单位技能在进入射程前只保存一条命令。
	var cast_approach: Dictionary = {}
	var cast_cd_until: float = 0.0
	var dmg_scale: float = 1.0
	# 防护与普攻伤害类型（physical / magic / none）
	var armor: float = 0.0
	var magic_resist: float = 0.0
	var attack_school: String = "physical"


var config: Dictionary = {}
var events: BattleEvents
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var seed_value: int = 0
var time: float = 0.0
var paused: bool = false
var finished: bool = false
var result: String = ""
var reason: String = ""
var units: Dictionary = {}
var _ids: Array[int] = []
var _next_id: int = 1
## 真人战斗采用显式指令；自动走查和隔离夹具继续使用既有入口。
var player_controls: bool = false
## 只有真人出征开启队友 AI；同一模拟器的历史自检可独立构造纯规则夹具。
const AllyAI := preload("res://scripts/battle/ally_ai.gd")
var ally_ai_enabled: bool = false
var controlled_actor_id: int = -1
var _player_projectiles: Array[Dictionary] = []
var _ai_open_target: int = -1
var _ai_tank_wait: int = -1
var _ai_aim_actor: int = -1
var _ai_manual_cast: Dictionary = {}
var _player_cast_seq: int = 0
var _arena: Rect2 = Rect2()
# 只供新准备入口的战斗身份与输入锁；旧 setup/check_cast/cast_skill 不读取。
var skill_battle_id: String = ""
var skill_input_locked: bool = false
# 隔离夹具显式开场才启用；没有第二份角色状态，也不转接旧 step/输入。
var _skill_schedule_active: bool = false
var _skill_generation: int = 0
var _skill_tick: int = 0
var _skill_accumulator: float = 0.0
var _skill_receive_seq: int = 0
var _skill_queue_epoch: int = 0
var _skill_pending: Array[Dictionary] = []
var _skill_seen_requests: Dictionary = {}
var _skill_advancing: bool = false
var _skill_transactions_enabled: bool = false
# 完整模式只由全校验安装置位；离场后重建新Sim才能恢复旧入口。
var _skill_full_numeric: bool = false
# 封闭解析范围；默认旧无盾，只有完整安装成功才可切换。
var _skill_resolution_scope: String = "S2_2_UNSHIELDED"
var _skill_requires_rebuild: bool = false
var _skill_cast_dispatching: bool = false
# 离开显式模式恢复旧周期值，避免评级副作用无意延续到下一场。
var _skill_previous_regen: Dictionary = {}
# 非空表示调用尚未正常返回；跨函数错误不会被当作可继续的空结果。
var _skill_transaction_pending: Dictionary = {}
var _skill_validation_error: Dictionary = {}
# 正式出征使用原战斗步长和战术周期；只共享输入队列、事务及单一状态。
var formal_skill_sortie: bool = false


## 保留四槽队伍/实际波次出生。正式预检可暂缓发事件，成功交接后按原顺序发布。
func setup(cfg: Dictionary, slots: Array, seed: int, bus: BattleEvents, publish: bool = true) -> void:
	config = cfg
	events = bus
	seed_value = seed if seed >= 0 else int(Time.get_ticks_usec() & 0x7fffffff)
	rng.seed = seed_value
	var arena: Dictionary = cfg["arena"]
	_arena = Rect2(float(arena["x"]), float(arena["y"]), float(arena["w"]), float(arena["h"]))

	var party_size := 0
	for slot_index in SLOT_COUNT:
		if slot_index < slots.size() and String(slots[slot_index]) != "":
			party_size += 1
	var scaling: Dictionary = cfg["party_scaling"].get(str(party_size), {"hp": 1.0, "dmg": 1.0})
	var wave: Array = cfg["wave"]

	if publish:
		events.fire(&"battle_started", [seed_value, party_size, wave.size()])

	for slot_index in SLOT_COUNT:
		if slot_index >= slots.size() or String(slots[slot_index]) == "":
			continue
		_spawn_ally(slot_index, String(slots[slot_index]), publish)
	for entry: Dictionary in wave:
		_spawn_enemy(entry, float(scaling["hp"]), float(scaling["dmg"]), publish)


## 预建正式出征。寒霜复用阵容初始化和资源属性，技能用共用配表。
func prepare_formal_sortie(cfg: Dictionary, locked: Dictionary, seed: int, bus: BattleEvents, catalog: Dictionary) -> PackedStringArray:
	setup(cfg, locked["slots"], seed, bus, false)
	if units.is_empty() or _begin_skill_schedule().is_empty():
		return PackedStringArray(["正式出征候选未建立"])
	var stats: Dictionary = {}
	var relations: Dictionary = {}
	var problems := PackedStringArray()
	for id: int in _ids:
		var unit: Unit = units[id]
		if not unit.pos.is_finite():
			problems.append("正式单位 %d 的初始坐标无效" % id)
		var fields := {"armor": unit.armor, "magic_resistance": unit.magic_resist, "evasion_rating": 0.0, "damage_reduction": 0.0}
		if unit.side == "ally":
			# 本批为 L=1；当前装备只有套装规则，没有装备强度或其他评级输入。
			fields.merge({"intellect": 24.0 if unit.kind == "mage" else 18.0,
				"spirit": 12.0 if unit.kind == "mage" else 24.0,
				"equipment_power": 0.0, "temporary_power": 0.0, "power_bonus": 0.0,
				"precision_rating": 0.0, "critical_rating": 0.0, "haste_rating": 0.0,
				"mastery_rating": 0.0, "penetration_rating": 0.0,
				"damage_bonus": 0.0, "healing_bonus": 0.0, "shield_bonus": 0.0, "critical_bonus": 0.0})
			if unit.spec_id != BattleConfig.MAGE_FROST:
				problems.append_array(install_skill_loadout(id, locked["specs"][unit.slot], catalog))
				unit.formal_q_set = locked["sets"].has(unit.kind)
			elif locked["specs"][unit.slot] != unit.spec_id:
				problems.append("寒霜配置与锁定的专精不一致")
		else:
			relations[id] = {"activated": false, "engaged_allies": {}}
		stats[id] = fields
	if not problems.is_empty():
		return problems
	problems = _enable_skill_transactions(stats, true, relations, "S2_3_SHIELD_AWARE")
	if not problems.is_empty():
		return problems
	for ally: Unit in living("ally"):
		if ally.spec_id == BattleConfig.MAGE_FROST:
			continue
		var expected: Array = ["mage.fire.flame_burst", "mage.fire.fireball", "mage.fire.flame_barrier", "mage.fire.evocation"] if ally.kind == "mage" else ["priest.holy.greater_heal", "", "", ""]
		for index: int in SKILL_KEYS.size():
			var skill: Dictionary = ally.resolved_slots[SKILL_KEYS[index]]
			if skill.get("skill_id", "") != expected[index]:
				problems.append("%s.%s: 正式技能槽与冻结专精不一致" % [ally.spec_id, SKILL_KEYS[index]])
			elif not skill.is_empty():
				problems.append_array(_skill_transaction_problems(ally, skill))
	formal_skill_sortie = problems.is_empty()
	return problems


## 预检的同一实例进入正式战斗树后补发首帧既有事件，顺序和字段与旧出征相同。
func publish_formal_start() -> void:
	events.fire(&"battle_started", [seed_value, living("ally").size(), living("enemy").size()])
	for id: int in _ids:
		var unit: Unit = units[id]
		events.fire(&"unit_spawned", [unit.id, unit.side, unit.slot, unit.kind, int(unit.max_hp), unit.pos])


func _new_unit() -> Unit:
	var unit := Unit.new()
	unit.id = _next_id
	_next_id += 1
	units[unit.id] = unit
	_ids.append(unit.id)
	return unit


## 出生按配表取整数基础生命，并按本场锁定的专精选技能和普攻。
func _spawn_ally(slot_index: int, class_id: String, publish: bool = true) -> void:
	var cls: Dictionary = config["classes"][class_id]
	var spawn: Dictionary = config["ally_spawn"]
	var unit := _new_unit()
	unit.side = "ally"
	unit.slot = slot_index
	unit.kind = class_id
	unit.display_name = String(cls["name"])
	unit.color_hex = String(cls["color"])
	unit.radius = float(config.get("unit_radius", 22.0))
	unit.max_hp = int(cls["max_hp"])
	unit.hp = unit.max_hp
	unit.pos = Vector2(float(spawn["x"]), float(spawn["y0"]) + float(spawn["dy"]) * slot_index)
	unit.speed = float(cls["speed"])
	unit.threat_coef = float(cls.get("threat_coef", 1.0))
	var attack: Dictionary = cls["attack"]
	unit.attack_kind = String(attack["kind"])
	unit.attack_range = float(attack["range"])
	unit.attack_damage = float(attack["damage"])
	unit.armor = float(cls.get("armor", 0.0))
	unit.magic_resist = float(cls.get("magic_resist", 0.0))
	unit.attack_school = String((config.get("attack_school", {}) as Dictionary).get(class_id, "physical"))
	unit.attack_interval = float(attack["interval"])
	var resource: Dictionary = cls["resource"]
	unit.res_kind = String(resource["kind"])
	unit.res_max = float(resource["max"])
	unit.res = float(resource["start"])
	unit.res_regen = float(resource["regen"])
	unit.res_on_attack = float(resource.get("on_attack", 0.0))
	unit.res_emit_value = int(floor(unit.res))
	var class_skills: Dictionary = cls["skills"]
	if class_id == "mage" and config.get("mage_spec") == BattleConfig.MAGE_FROST:
		var frost: Dictionary = cls["frost"]
		unit.spec_id = BattleConfig.MAGE_FROST
		unit.attack_damage = float(frost["attack_damage"])
		class_skills = frost["skills"]
	for key in SKILL_KEYS:
		var skill_id: String = class_skills[key]
		var skill: Dictionary = (config["skills"][skill_id] as Dictionary).duplicate(true)
		skill["id"] = skill_id
		unit.skills[key] = skill
	if publish:
		events.fire(&"unit_spawned", [unit.id, "ally", slot_index, class_id, int(unit.max_hp), unit.pos])


## 旧敌方缩放保留原整数取整；出生事件继续提供整数生命。
func _spawn_enemy(entry: Dictionary, hp_scale: float, dmg_scale: float, publish: bool = true) -> void:
	var enemy_id: String = entry["enemy"]
	var def: Dictionary = config["enemies"][enemy_id]
	var unit := _new_unit()
	unit.side = "enemy"
	unit.kind = enemy_id
	unit.display_name = String(def["name"])
	unit.color_hex = String(def["color"])
	unit.radius = float(def["radius"])
	unit.max_hp = maxi(1, roundi(float(def["max_hp"]) * hp_scale))
	unit.hp = unit.max_hp
	unit.pos = Vector2(float(entry["x"]), float(entry["y"]))
	unit.speed = float(def["speed"])
	unit.attack_range = float(def["attack_range"])
	unit.attack_damage = float(def["damage"])
	unit.attack_interval = float(def["interval"])
	unit.dmg_scale = dmg_scale
	unit.armor = float(def.get("armor", 0.0))
	unit.magic_resist = float(def.get("magic_resist", 0.0))
	unit.attack_school = String(def.get("school", "physical"))
	if def.has("spell"):
		unit.spell = (def["spell"] as Dictionary).duplicate(true)
		unit.cast_cd_until = float(unit.spell["first_at"])
	if publish:
		events.fire(&"unit_spawned", [unit.id, "enemy", -1, enemy_id, int(unit.max_hp), unit.pos])


# ── 查询 ──

func slot_unit(slot_index: int) -> Unit:
	for id in _ids:
		var unit: Unit = units[id]
		if unit.side == "ally" and unit.slot == slot_index:
			return unit
	return null


func living(side: String) -> Array[Unit]:
	var result_list: Array[Unit] = []
	for id in _ids:
		var unit: Unit = units[id]
		if unit.side == side and unit.alive:
			result_list.append(unit)
	return result_list


func unit_at(pos: Vector2, side: String, slack: float = 8.0) -> Unit:
	var best: Unit = null
	var best_dist := INF
	for id in _ids:
		var unit: Unit = units[id]
		if unit.side != side:
			continue
		if side == "enemy" and not unit.alive:
			continue
		var dist := unit.pos.distance_to(pos)
		if dist <= unit.radius + slack and dist < best_dist:
			best = unit
			best_dist = dist
	return best


func _nearest(from: Vector2, side: String, max_dist: float = INF) -> Unit:
	var best: Unit = null
	var best_dist := max_dist
	for unit in living(side):
		var dist := unit.pos.distance_to(from)
		if dist <= best_dist:
			best = unit
			best_dist = dist
	return best


func _lowest_ratio_ally(from: Vector2, max_dist: float, hurt_only: bool) -> Unit:
	var best: Unit = null
	var best_ratio := 2.0
	for unit in living("ally"):
		if hurt_only and unit.hp >= unit.max_hp:
			continue
		if unit.pos.distance_to(from) > max_dist:
			continue
		var ratio := float(unit.hp) / float(unit.max_hp)
		if ratio < best_ratio:
			best = unit
			best_ratio = ratio
	return best


func taken_mult(unit: Unit) -> float:
	var mult := 1.0
	for status_id: String in unit.statuses:
		mult *= float((unit.statuses[status_id] as Dictionary).get("taken_mult", 1.0))
	return mult


func interval_mult(unit: Unit) -> float:
	var mult := 1.0
	for status_id: String in unit.statuses:
		mult *= float((unit.statuses[status_id] as Dictionary).get("interval_mult", 1.0))
	return mult


# ── 命令 ──

func _reject(unit_id: int, kind: String, why: String) -> bool:
	events.fire(&"command_rejected", [unit_id, kind, why])
	return false


## 移动和目标命令只作用于可行动角色，冰箱期间拒绝新指令。
func _gate(unit_id: int, kind: String) -> Unit:
	var unit: Unit = units.get(unit_id)
	if finished or unit == null:
		return null
	if not unit.alive:
		_reject(unit_id, kind, "unit_down")
		return null
	if paused:
		_reject(unit_id, kind, "paused")
		return null
	if unit.statuses.has("ice_block"):
		_reject(unit_id, kind, "ICE_BLOCKED")
		return null
	return unit


## 真人右键走位接管自动接近和读条，随后保存新的移动目的地。
func order_move(unit_id: int, pos: Vector2) -> bool:
	var unit := _gate(unit_id, "move")
	if unit == null:
		return false
	_cancel_cast_approach(unit)
	unit.order_kind = "move"
	unit.order_pos = Vector2(clampf(pos.x, _arena.position.x + unit.radius, _arena.end.x - unit.radius), clampf(pos.y, _arena.position.y + unit.radius, _arena.end.y - unit.radius))
	unit.target_id = -1
	if controlled_actor_id >= 0:
		unit.manual_target_id = -1
		unit.auto_target_id = -1
		_cancel_player_cast(unit, "CAST_INTERRUPTED")
	events.fire(&"command_issued", [unit_id, "move", -1, unit.order_pos])
	return true


## 右键点敌人。不能攻击的职业（牧师）和无效目标不改变当前命令，也不发事件。
func order_attack(unit_id: int, target_id: int) -> bool:
	var target: Unit = units.get(target_id)
	var unit: Unit = units.get(unit_id)
	if unit == null or target == null or unit.side != "ally" or target.side != "enemy" or not target.alive:
		return false
	if unit.attack_kind != "damage":
		return false
	unit = _gate(unit_id, "attack")
	if unit == null:
		return false
	unit.order_kind = "attack"
	unit.target_id = target_id
	events.fire(&"command_issued", [unit_id, "attack", target_id, target.pos])
	return true


## 牧师右键点队友。其他职业和无效目标不改变当前命令，也不发事件。
func order_heal(unit_id: int, target_id: int) -> bool:
	var target: Unit = units.get(target_id)
	var unit: Unit = units.get(unit_id)
	if unit == null or target == null or unit.side != "ally" or target.side != "ally" or not target.alive:
		return false
	if unit.attack_kind != "heal":
		return false
	unit = _gate(unit_id, "heal")
	if unit == null:
		return false
	unit.order_kind = "heal"
	unit.target_id = target_id
	events.fire(&"command_issued", [unit_id, "heal", target_id, target.pos])
	return true


## 地面技能预览和执行共用射程裁剪，边缘的小余量消除坐标舍入的超距。
func ground_cast_center(origin: Vector2, point: Vector2, reach: float) -> Vector2:
	var center := origin.move_toward(point, reach)
	if origin.distance_to(center) > reach:
		return origin.move_toward(point, maxf(0.0, reach - 0.001))
	return center


## 只裁剪玩家指向战场内的地面落点，方向闪现使用自己的落点规则。
func _ground_cast_aim(actor: Unit, skill: Dictionary, aim: Dictionary) -> Dictionary:
	var point: Variant = aim.get("point")
	if point is Vector2 and has_arena_point(point):
		return {"point": ground_cast_center(actor.pos, point, ai_skill_range(skill))}
	return aim


## 判断地面技能落点是否在战场中，保持瞄准和结算的边界一致。
func has_arena_point(point: Vector2) -> bool:
	return point.is_finite() and _arena.has_point(point)


## 过滤失效的观察目标，供技能预检和输入投影使用。
func player_selected_target(actor: Unit) -> Unit:
	if actor == null:
		return null
	var target: Unit = units.get(actor.selected_target_id)
	return target if target != null and target.alive and target.selectable else null


## 技能栏只做可用性预检；闪现预检使用朝场内的方向，实际指令取玩家鼠标。
func _player_skill_projection_aim(actor: Unit, skill_id: String) -> Dictionary:
	if skill_id == "mage.frost.blink":
		var center := _arena.get_center()
		return {"point": center if center != actor.pos else center + Vector2.RIGHT}
	var target := player_selected_target(actor)
	if skill_id in ["mage.fire.flame_burst", "fire_burst"] and (target == null or target.side != "enemy"):
		return {"point": actor.pos}
	return {"target": target.id if target != null else -1}


## 仅返回当前 Q 对指定单位预计能补回的血量，沿用正式或旧版的真实计算。
func player_heal_preview(actor: Unit, target: Unit) -> float:
	if actor == null or target == null or not actor.alive or not target.alive or actor.attack_kind != "heal" or target.side != "ally" or target.hp >= target.max_hp or finished or paused:
		return 0.0
	var aim := {"target": target.id}
	if formal_skill_sortie:
		var skill: Dictionary = actor.resolved_slots.get("q", {})
		var predicted := _prepare_skill_transaction({"battle_id": skill_battle_id, "caster_id": actor.id,
			"slot": "Q", "expected_skill_id": skill.get("skill_id", ""), "aim": aim})
		if predicted["preparable"]:
			return float(predicted["details"]["effects"][0]["actual_amount"])
		return 0.0
	if not check_cast(actor.id, "q", aim)["ok"]:
		return 0.0
	for effect: Dictionary in actor.skills["q"]["effects"]:
		if effect["kind"] == "heal":
			return _effective_legacy_heal(target, roundi(float(effect["amount"])))
	return 0.0


## 旧治疗的真实结算与预览都使用取整后的缺血量。
func _effective_legacy_heal(receiver: Unit, amount: int) -> int:
	return mini(amount, int(receiver.max_hp) - int(receiver.hp))


## 右键目标接管待施法并记录持续指令，超距追击才打断已开始的读条。
func issue_player_target(actor: Unit, target: Unit) -> bool:
	if _gate(actor.id, "target") == null or not target.alive or not target.selectable:
		return false
	var healing := actor.attack_kind == "heal"
	if target.side != ("ally" if healing else "enemy"):
		return false
	_cancel_cast_approach(actor)
	actor.auto_target_id = target.id
	actor.order_kind = "none"
	if controlled_actor_id >= 0:
		actor.manual_target_id = target.id
		if actor.pos.distance_to(target.pos) > actor.attack_range:
			_cancel_player_cast(actor, "CAST_INTERRUPTED")
	if ally_ai_enabled and not healing:
		actor.ai_joined = true
		actor.ai_personal_order = true
		_open_ally_combat(actor, target.id)
	events.fire(&"command_issued", [actor.id, "heal" if healing else "attack", target.id, target.pos])
	return true


## 实战的手动技能可带队开怪，只有明确右键才写入玩家普攻目标。
func _finish_player_attack(actor: Unit, primary_id: int, center: Vector2, hits: Array[int]) -> void:
	if not actor.alive or actor.attack_kind != "damage" or hits.is_empty():
		return
	if ally_ai_enabled:
		# 首击即使已击倒目标也算开怪；后续选敌会跳过尸体。
		var opener := primary_id if primary_id in hits else hits[0]
		_open_ally_combat(actor, opener)
	if controlled_actor_id >= 0:
		return
	if ally_ai_enabled:
		actor.ai_personal_order = true
		if AllyAI.enemy_target(self, actor.auto_target_id) != null:
			return
	var best: Unit
	var distance := INF
	for id in hits:
		var target: Unit = units.get(id)
		if target == null or not target.alive or target.side != "enemy":
			continue
		var next := target.pos.distance_squared_to(center)
		if id == primary_id:
			best = target
			break
		if next < distance or (next == distance and best != null and id < best.id):
			distance = next
			best = target
	if best != null:
		actor.auto_target_id = best.id
		actor.ai_joined = ally_ai_enabled


## 实际生命差额直接入战斗累计，避免旧兼容事件中的取整和溢出。
func _record_player_damage(actor: Unit, actual: float) -> void:
	if player_controls:
		actor.damage_done += actual


## 真人战士在基础倍率上叠乘技能仇恨；旋风斩按每只命中怪的实际扣血建立群拉仇恨。
func _damage_threat(actor: Unit, damage: float, skill_id: String) -> float:
	var bonus := 1.0
	if player_controls and actor.kind == "warrior":
		match skill_id:
			"slam": bonus = 1.5
			"whirlwind": bonus = 3.5
	return damage * actor.threat_coef * bonus


## 切换控制权时只继承玩家指令，AI 临时选择不会成为手动攻击目标。
func set_controlled_actor(actor_id: int) -> void:
	controlled_actor_id = actor_id
	var actor: Unit = units.get(actor_id)
	if actor != null:
		actor.auto_target_id = actor.manual_target_id
		actor.target_id = -1


## 当前角色执行显式右键指令，其他角色按现有 AI 和兼容规则推进。
func _tick_player_ally(actor: Unit, dt: float) -> void:
	if not actor.cast.is_empty():
		return
	if actor.id == controlled_actor_id:
		_set_ai_evading(actor, false)
		actor.target_id = -1
		if actor.order_kind == "move":
			if _move_toward(actor, actor.order_pos, dt, 3.0):
				actor.order_kind = "none"
			return
		var commanded: Unit = units.get(actor.manual_target_id)
		if commanded == null or not commanded.alive or not commanded.selectable:
			actor.manual_target_id = -1
			actor.auto_target_id = -1
			return
		actor.target_id = commanded.id
		if actor.attack_kind == "heal" and commanded.hp >= commanded.max_hp:
			return
		if actor.pos.distance_to(commanded.pos) > actor.attack_range:
			_move_toward(actor, commanded.pos, dt, actor.attack_range * 0.95)
		if actor.pos.distance_to(commanded.pos) <= actor.attack_range:
			_try_attack(actor, commanded)
		return
	if ally_ai_enabled:
		_tick_ally_ai(actor, dt)
		return
	actor.target_id = -1
	if actor.order_kind == "move":
		if _move_toward(actor, actor.order_pos, dt, 3.0):
			actor.order_kind = "none"
		return
	var target: Unit = units.get(actor.auto_target_id)
	if target == null or not target.alive:
		actor.auto_target_id = -1
		target = null
	if actor.attack_kind == "heal":
		if target == null or target.hp >= target.max_hp or actor.pos.distance_to(target.pos) > actor.attack_range:
			target = _lowest_ratio_ally(actor.pos, actor.attack_range, true)
	if target != null and actor.pos.distance_to(target.pos) <= actor.attack_range:
		actor.target_id = target.id
		_try_attack(actor, target)


## 锁住开场跟随目标；接怪等待只用于由战士发起的这一次开战。
func _open_ally_combat(actor: Unit, target_id: int) -> void:
	if _ai_open_target >= 0:
		return
	_ai_open_target = target_id
	if actor.kind == "warrior" and not actor.ai_contact:
		_ai_tank_wait = actor.id


## 精确按发起角色记录瞄准，不依赖 UI 当前操控的槽位。
func set_ally_aim_actor(actor_id: int) -> void:
	_ai_aim_actor = actor_id


## 即使手动提交在输入层被拒绝，也让出这个角色的下一次自动决策。
func reserve_manual_cast(actor_id: int) -> void:
	if ally_ai_enabled and not paused and not finished:
		_ai_manual_cast[actor_id] = true


## 正式实战的手动和自动共用请求序号；隔离夹具仍可使用其显式序号。
func next_player_cast_seq() -> int:
	_player_cast_seq += 1
	while _skill_seen_requests.has(_player_cast_seq):
		_player_cast_seq += 1
	return _player_cast_seq


## Resource 的射程从米换算，JSON 技能已经使用场景单位。
func ai_skill_range(skill: Dictionary) -> float:
	if skill.has("cast_range_m"):
		return float(skill["cast_range_m"]) * SCENE_UNITS_PER_METER
	return float(skill["range"])


## AI 只驱动可行动队友，寒霜在两条出征路径共用冷却。
func ai_skill_ready(actor: Unit, slot: String, skill: Dictionary) -> bool:
	if not actor.controllable or actor.id == controlled_actor_id or not actor.cast.is_empty() or actor.statuses.has("ice_block"):
		return false
	if formal_skill_sortie and actor.spec_id != BattleConfig.MAGE_FROST:
		return (
			not skill_input_locked and _skill_transactions_enabled
			and actor.res >= float(skill["mana_cost"])
			and not _skill_deadline_pending(actor.gcd_until)
			and not _skill_deadline_pending(float(actor.skill_ready_at.get(skill["skill_id"], 0.0)))
		)
	return (
		actor.res >= float(skill["cost"])
		and time >= float(actor.cd_until.get(slot, 0.0))
		and (skill.get("off_gcd", false) or time >= actor.gcd_until)
	)


## 死亡后跟随当前战士目标或稳定最近敌人；首次加入才用开怪目标。
func _ally_attack_target(actor: Unit, allies: Array[Unit], enemies: Array[Unit]) -> Unit:
	var target: Unit = AllyAI.enemy_target(self, actor.auto_target_id)
	if target != null:
		return target
	if not actor.ai_joined:
		target = AllyAI.enemy_target(self, _ai_open_target)
	actor.ai_joined = true
	if target == null:
		for ally in allies:
			if ally != actor and ally.kind == "warrior":
				target = AllyAI.enemy_target(self, ally.auto_target_id)
				if target != null:
					break
	if target == null:
		var distance := INF
		for enemy in enemies:
			var next := actor.pos.distance_squared_to(enemy.pos)
			if enemy.selectable and (next < distance or (next == distance and target != null and enemy.id < target.id)):
				distance = next
				target = enemy
	actor.auto_target_id = target.id if target != null else -1
	return target


## 正式场的自动施法和真人指令共用固定步队列，寒霜身份来自配表。
func _cast_ally_ai(actor: Unit, choice: Dictionary) -> void:
	var slot: String = choice["slot"]
	var aim := {"target": choice["target_id"]}
	if not formal_skill_sortie:
		if check_cast(actor.id, slot, aim)["ok"]:
			cast_skill(actor.id, slot, aim, true)
		return
	var request := {"battle_id": skill_battle_id, "caster_id": actor.id,
		"request_seq": next_player_cast_seq(), "slot": slot.to_upper(),
		"expected_skill_id": actor.skills[slot]["id"] if actor.spec_id == BattleConfig.MAGE_FROST else actor.resolved_slots[slot]["skill_id"], "aim": aim}
	if _enqueue_skill_command("cast", request, true)["queued"]:
		# 本次自动命令是末项；同步回调产生的玩家命令仍留给下一固定步。
		var command: Dictionary = _skill_pending.pop_back()
		_execute_skill_command(command)


## 手动动作、圆形避让、主动技和普通动作按固定顺序推进，保持玩家观察目标独立。
func _tick_ally_ai(actor: Unit, dt: float) -> void:
	var handoff := _ai_manual_cast.erase(actor.id)
	actor.target_id = -1
	if actor.order_kind == "move":
		_set_ai_evading(actor, false)
		if _move_toward(actor, actor.order_pos, dt, 3.0):
			actor.order_kind = "none"
		return
	if handoff or actor.id == _ai_aim_actor or not actor.controllable:
		_set_ai_evading(actor, false)
		return
	var enemies := living("enemy")
	var circles := AllyAI.hazards_for(actor, enemies)
	var in_danger := AllyAI.path_enters(actor.pos, actor.pos, circles)
	_set_ai_evading(actor, in_danger)
	if in_danger:
		var escape := AllyAI.escape_point(actor.pos, _arena.grow(-actor.radius), circles)
		if escape != actor.pos:
			_move_toward(actor, escape, dt, 0.0)
		return
	var healing := actor.attack_kind == "heal"
	if not healing and _ai_open_target < 0:
		return
	var allies := living("ally")
	var target: Unit = AllyAI.heal_target(self, actor, allies) if healing else _ally_attack_target(actor, allies, enemies)
	var decision := AllyAI.choose_skill(self, actor, target, allies, enemies)
	var tank: Unit = units.get(_ai_tank_wait)
	var waiting_for_tank := tank != null and tank.alive and tank.controllable and not tank.ai_contact
	var can_act := healing or actor.ai_personal_order or not waiting_for_tank
	var cast: Dictionary = decision["cast"]
	var approach: Dictionary = decision["approach"]
	if can_act and not cast.is_empty():
		var epoch := _skill_queue_epoch
		_cast_ally_ai(actor, cast)
		if paused or finished or not actor.alive or not actor.cast.is_empty() or (formal_skill_sortie and epoch != _skill_queue_epoch):
			return
	if target == null or not target.alive:
		return
	actor.target_id = target.id
	var close_combat := actor.kind in ["warrior", "rogue"]
	if close_combat:
		_move_ally_safely(actor, target, actor.attack_range, dt, circles)
	elif not approach.is_empty() and (cast.is_empty() or not can_act):
		_move_ally_safely(actor, target, approach["reach"], dt, circles)
	elif healing and cast.is_empty():
		_move_ally_safely(actor, target, actor.attack_range, dt, circles)
	if can_act and actor.pos.distance_to(target.pos) <= actor.attack_range and (not healing or target.hp < target.max_hp):
		_try_attack(actor, target)


## 只记录避让状态切换，便于用试玩日志复核撤离和恢复。
func _set_ai_evading(actor: Unit, active: bool) -> void:
	if actor.ai_evading != active:
		actor.ai_evading = active
		events.fire(&"ai_evade", [actor.id, active])


## 按本步移动路径预判红圈，返回是否允许尝试移动，供施法接近区分挡路和卡住。
func _move_ally_safely(actor: Unit, target: Unit, reach: float, dt: float, circles: Array[Vector3]) -> bool:
	var distance := actor.pos.distance_to(target.pos)
	if distance <= reach:
		return true
	# 留少量入圈余量，避免分离推动后马上卡在射程边线。
	var stop := reach * 0.96
	var next := actor.pos.move_toward(target.pos, minf(actor.speed * dt, distance - stop))
	var safe_arena := _arena.grow(-actor.radius)
	var clamped := next.clamp(safe_arena.position, safe_arena.end)
	if AllyAI.path_enters(actor.pos, clamped, circles):
		return false
	_move_toward(actor, target.pos, dt, stop)
	return true


## 真人暂停保留已接收命令，冻结步进；隔离调度沿用清队列的验证规则。
func set_paused(value: bool) -> void:
	if not finished:
		paused = value
		if value:
			_ai_manual_cast.clear()
			_ai_aim_actor = -1
		if value and _skill_schedule_active:
			_skill_queue_epoch += 1
			# 正式真人的预接收输入保留顺序，恢复后从完整步开始处理。
			if not (formal_skill_sortie and player_controls):
				_skill_pending.clear()
			_skill_accumulator = 0.0


## 纯查询技能可用性；只有真人接近预检允许略过单位射程。
func check_cast(unit_id: int, key: String, aim: Dictionary = {}, ignore_unit_range: bool = false) -> Dictionary:
	var unit: Unit = units.get(unit_id)
	var frost := unit != null and unit.spec_id == BattleConfig.MAGE_FROST
	if formal_skill_sortie and not frost:
		var view := get_skill_view(unit_id, key.to_upper())
		return {"ok": view["implemented"] and view["preparable"], "reason": view["reason"], "target_id": unit.target_id if unit != null else -1}
	if unit == null or not unit.alive:
		return {"ok": false, "reason": "unit_down", "target_id": -1}
	if paused:
		return {"ok": false, "reason": "paused", "target_id": -1}
	if not unit.skills.has(key) or (frost and not unit.controllable):
		return {"ok": false, "reason": "no_target", "target_id": -1}
	var skill: Dictionary = unit.skills[key]
	if frost and (finished or unit.statuses.has("ice_block")):
		return {"ok": false, "reason": "ICE_BLOCKED" if not finished else "INPUT_LOCKED", "target_id": -1}
	# 闪现和冰箱用于应急，其余技能等待当前读条结束。
	if not unit.cast.is_empty() and not (frost and key in ["e", "r"]):
		return {"ok": false, "reason": "CAST_IN_PROGRESS", "target_id": -1}
	var clock := time + 0.0000000001 if frost else time
	if clock < float(unit.cd_until.get(key, 0.0)):
		return {"ok": false, "reason": "cooldown", "target_id": -1}
	if not bool(skill.get("off_gcd", false)) and clock < unit.gcd_until:
		return {"ok": false, "reason": "gcd", "target_id": -1}
	var target_id := -1
	var skill_range := float(skill["range"])
	var directed := not aim.is_empty()
	var landing := Vector2.INF
	match String(skill["target"]):
		"direction":
			var point: Variant = aim.get("point")
			if point is Vector2:
				landing = blink_landing(unit, point, skill_range)
			if not landing.is_finite():
				return {"ok": false, "reason": "NO_BLINK_LANDING", "target_id": -1}
		"enemy":
			if aim.has("point") and skill["id"] == "fire_burst":
				var point: Vector2 = aim["point"]
				if not _arena.has_point(point) or unit.pos.distance_to(point) > skill_range:
					return {"ok": false, "reason": "out_of_range", "target_id": -1}
				if float(skill["cost"]) > unit.res:
					return {"ok": false, "reason": "no_resource", "target_id": -1}
				return {"ok": true, "reason": "", "target_id": -1}
			var target: Unit = units.get(aim.get("target")) if directed else _resolve_enemy_target(unit)
			if target == null or not target.alive or not target.selectable or target.side != "enemy":
				return {"ok": false, "reason": "no_target", "target_id": -1}
			if not ignore_unit_range and target.pos.distance_to(unit.pos) > skill_range:
				return {"ok": false, "reason": "out_of_range", "target_id": target.id}
			target_id = target.id
		"ally":
			var target: Unit = units.get(aim.get("target")) if directed else _resolve_ally_target(unit)
			if target == null or not target.alive or not target.selectable or target.side != "ally":
				return {"ok": false, "reason": "no_target", "target_id": -1}
			if not ignore_unit_range and target.pos.distance_to(unit.pos) > skill_range:
				return {"ok": false, "reason": "out_of_range", "target_id": target.id}
			target_id = target.id
	if frost and key == "w" and _frost_nova_targets(unit, float(skill["effects"][0]["radius"])).is_empty():
		return {"ok": false, "reason": "NO_FREEZE_TARGET", "target_id": -1}
	if float(skill["cost"]) > unit.res:
		return {"ok": false, "reason": "no_resource", "target_id": target_id}
	return {"ok": true, "reason": "", "target_id": target_id, "landing": landing} if frost else {"ok": true, "reason": "", "target_id": target_id}


## 只选圆内可被攻击的小怪，精英和首领同时免疫伤害与冻结。
func _frost_nova_targets(caster: Unit, radius: float) -> Array[Unit]:
	var targets: Array[Unit] = []
	for enemy: Unit in living("enemy"):
		if enemy.selectable and enemy.kind not in ["elite", "boss"] and caster.pos.distance_squared_to(enemy.pos) <= radius * radius:
			targets.append(enemy)
	return targets


## 沿鼠标射线裁到场内；若终点重叠，从最远处退到重叠区的近边界。
func blink_landing(caster: Unit, pointer: Vector2, reach: float) -> Vector2:
	var delta := pointer - caster.pos
	if not delta.is_finite() or delta.length_squared() < 0.000001:
		return Vector2.INF
	var direction := delta.normalized()
	var bounds := _arena.grow(-caster.radius)
	var distance := reach
	for axis in 2:
		if absf(direction[axis]) > 0.000001:
			var edge := bounds.end[axis] if direction[axis] > 0.0 else bounds.position[axis]
			distance = minf(distance, (edge - caster.pos[axis]) / direction[axis])
	# 每次退过一个占用区间，直到找到射线上最远的合法位置。
	var overlaps: Array[Vector2] = []
	for id: int in _ids:
		var other: Unit = units[id]
		if not other.alive or other == caster:
			continue
		var offset := other.pos - caster.pos
		var projection := offset.dot(direction)
		var clearance := caster.radius + other.radius
		var chord_squared := clearance * clearance - (offset - direction * projection).length_squared()
		if chord_squared > 0.0:
			var chord := sqrt(chord_squared)
			overlaps.append(Vector2(projection - chord, projection + chord))
	for pass_index in overlaps.size():
		var before := distance
		for interval: Vector2 in overlaps:
			if distance > interval.x and distance < interval.y:
				distance = interval.x
		if before == distance:
			break
	var landing := caster.pos + direction * distance
	if distance <= 0.000001:
		return Vector2.INF
	return Vector2(clampf(landing.x, bounds.position.x, bounds.end.x), clampf(landing.y, bounds.position.y, bounds.end.y))


## 寒霜保留配表平值和强度系数，正式场用派生强度，混编用当前基础强度。
func _frost_damage(caster: Unit, effect: Dictionary) -> float:
	var power := float(config["classes"]["mage"]["frost"]["power"])
	if formal_skill_sortie:
		power = float(_skill_derived_parameters(caster)["power"])
	return float(effect["amount"]) + float(effect["power_coeff"]) * power


## 在当前目标失效后按已有规则找可攻击的敌人。
func _resolve_enemy_target(unit: Unit) -> Unit:
	var current: Unit = units.get(unit.target_id)
	if current != null and current.alive and current.side == "enemy":
		return current
	return _nearest(unit.pos, "enemy")


func _resolve_ally_target(unit: Unit) -> Unit:
	var current: Unit = units.get(unit.target_id)
	if current != null and current.alive and current.side == "ally":
		return current
	return _lowest_ratio_ally(unit.pos, INF, false)


## 记录原地读条及最初的目标身份，后续点选不改变已发出的施法。
func _start_player_cast(caster: Unit, target: Unit, skill: Dictionary, command: Dictionary) -> void:
	caster.order_kind = "none"
	caster.cast = {"name": skill["name"], "skill_id": skill.get("skill_id", skill.get("id")),
		"started": time, "ends_at": time + float(skill["cast_time_s"]), "target_id": target.id,
		"center": target.pos, "radius": 0.0, "interruptible": true, "command": command}
	if not formal_skill_sortie:
		events.fire(&"command_issued", [caster.id, "skill", target.id, target.pos])


## 取消未发射的读条，正式队列的原请求得到唯一拒绝，旧入口沿用普通拒绝提示。
func _cancel_player_cast(caster: Unit, code: String) -> void:
	if caster.side != "ally" or caster.cast.is_empty():
		return
	var cast_data := caster.cast
	caster.cast = {}
	_report_player_cast_failure(caster.id, cast_data["command"], code)


## 保留正式请求身份。自动施法失败不覆盖玩家提示。
func _report_player_cast_failure(caster_id: int, command: Dictionary, code: String) -> void:
	if formal_skill_sortie and command.has("request"):
		var request: Dictionary = command["request"]
		var result := {"battle_id": request["battle_id"], "request_seq": request["request_seq"],
			"caster_id": caster_id, "skill_id": request["expected_skill_id"], "accepted": false, "reason": code, "details": {}}
		if command["automatic"]:
			result["source"] = "ai"
		events.fire(&"cast_resolved", [result])
	elif not command["automatic"]:
		_reject(caster_id, "skill", code)


## 推进读条和飞弹。寒霜队友遇到新预警时让出读条，交回原避让逻辑。
func _advance_player_casts() -> void:
	var battle_id := skill_battle_id
	var queue_epoch := _skill_queue_epoch
	for caster in living("ally"):
		if paused or finished or (formal_skill_sortie and not _skill_point_current(battle_id, queue_epoch)):
			return
		if caster.cast.is_empty():
			continue
		var target: Unit = units.get(caster.cast["target_id"])
		if target == null or not target.alive or not target.selectable:
			_cancel_player_cast(caster, "INVALID_TARGET")
		elif (caster.spec_id == BattleConfig.MAGE_FROST and caster.id != controlled_actor_id and ally_ai_enabled
				and AllyAI.path_enters(caster.pos, caster.pos, AllyAI.hazards_for(caster, living("enemy")))):
			_cancel_player_cast(caster, "CAST_INTERRUPTED")
		elif time + 0.0000000001 >= float(caster.cast["ends_at"]):
			_launch_player_projectile(caster, target)
	for flight: Dictionary in _player_projectiles.duplicate():
		if paused or finished or (formal_skill_sortie and not _skill_point_current(battle_id, queue_epoch)):
			return
		var target: Unit = units.get(flight["target_id"])
		if target == null or not target.alive or not target.selectable:
			_player_projectiles.erase(flight)
			_report_player_cast_failure(flight["source_id"], flight, "PROJECTILE_MISSED")
		elif time + 0.0000000001 >= float(flight["ends_at"]):
			_player_projectiles.erase(flight)
			if formal_skill_sortie and flight["skill_id"] != "mage.frost.frostbolt":
				_skill_cast_dispatching = true
				_execute_skill_transaction(flight["request"], flight["automatic"], flight)
				_skill_cast_dispatching = false
			else:
				var caster: Unit = units[flight["source_id"]]
				var before := target.hp
				_damage(caster, target, flight["base"], flight["skill_id"], false, flight["school"], flight["critical"], true)
				if not flight["automatic"]:
					_finish_player_attack(caster, target.id, target.pos, [target.id])
				if flight.has("request"):
					_publish_cast_outcome(flight["request"], flight["automatic"], "", {"damage": before - target.hp})


## 发射前复核射程和费用；寒霜立即允许下一次读条，飞弹独立飞行至命中。
func _launch_player_projectile(caster: Unit, target: Unit) -> void:
	var cast_data := caster.cast
	var command: Dictionary = cast_data["command"]
	var launch_data := {"source_id": caster.id, "target_id": target.id, "skill_id": cast_data["skill_id"],
		"started": time, "origin": caster.pos, "automatic": command["automatic"]}
	var aim := {"target": target.id}
	var skill: Dictionary
	caster.cast = {}
	var frost := caster.spec_id == BattleConfig.MAGE_FROST
	if formal_skill_sortie and not frost:
		var request: Dictionary = command["request"].duplicate(true)
		request["aim"] = aim
		var prepared := _prepare_skill(request, true)
		if not prepared["preparable"]:
			caster.cast = cast_data
			_cancel_player_cast(caster, prepared["reason"])
			return
		skill = prepared["skill"]
		var derived := _skill_derived_parameters(caster)
		var cost := float(skill["mana_cost"])
		launch_data.merge({"request": request, "prepared": prepared, "derived": derived,
			"mana_before": caster.res, "mana_after": caster.res - cost,
			"gcd_ready_at": time + float(derived["gcd"]), "skill_ready_at": time + float(skill["cooldown_s"])})
		caster.res = launch_data["mana_after"]
		caster.gcd_until = launch_data["gcd_ready_at"]
		caster.skill_ready_at[cast_data["skill_id"]] = launch_data["skill_ready_at"]
	else:
		var key: String = command["slot"]
		var check := check_cast(caster.id, key, aim)
		if not check["ok"]:
			caster.cast = cast_data
			_cancel_player_cast(caster, check["reason"])
			return
		skill = caster.skills[key]
		launch_data["base"] = _frost_damage(caster, skill["effects"][0]) if frost else float(skill["effects"][0]["amount"])
		launch_data["school"] = _skill_school(cast_data["skill_id"])
		launch_data["critical"] = rng.randf() < float(config.get("crit_chance", 0.0))
		caster.cd_until[key] = time + float(skill["cooldown"])
		if not skill.get("off_gcd", false):
			caster.gcd_until = time + float(config["gcd"])
		if command.has("request"):
			launch_data["request"] = command["request"]
	var speed := float(skill["projectile_speed_mps"]) * SCENE_UNITS_PER_METER
	launch_data["ends_at"] = time + maxf(0.15, caster.pos.distance_to(target.pos) / speed)
	_player_projectiles.append(launch_data)
	if not formal_skill_sortie or frost:
		# 先登记飞弹和冷却，再通知订阅者，回调中的重复输入也必须经过冷却。
		var cost := float(skill["cost"])
		if cost > 0.0:
			_change_resource(caster, -cost)
		events.fire(&"skill_cast", [caster.id, cast_data["skill_id"], target.id, int(cost), float(caster.cd_until[command["slot"]])])
		if command["automatic"]:
			events.fire(&"ai_skill_cast", [caster.id, cast_data["skill_id"], target.id])


## 混编真人技能可在超距时接近；已进范围的旧技能和寒霜仍走原结算。
func cast_skill(unit_id: int, key: String, aim: Dictionary = {}, automatic: bool = false, request: Dictionary = {}) -> bool:
	var actor: Unit = units.get(unit_id)
	var frost := actor != null and actor.spec_id == BattleConfig.MAGE_FROST
	if _skill_requires_rebuild and not (formal_skill_sortie and frost):
		return false
	var manual := player_controls and not automatic and actor != null
	if manual and not formal_skill_sortie and key in actor.skills and actor.skills[key]["id"] == "fire_burst":
		aim = _ground_cast_aim(actor, actor.skills[key], aim)
	var check := check_cast(unit_id, key, aim)
	if manual and not formal_skill_sortie and check["reason"] == "out_of_range" and aim.has("target"):
		check = check_cast(unit_id, key, aim, true)
		if check["ok"]:
			var skill: Dictionary = actor.skills[key]
			_start_cast_approach(actor, skill, check["target_id"], key)
			return true
	if not bool(check["ok"]):
		var unit_missing: Unit = units.get(unit_id)
		if unit_missing != null and not finished:
			_reject(unit_id, "skill", String(check["reason"]))
		return false
	var unit: Unit = units[unit_id]
	if manual and not formal_skill_sortie:
		_cancel_cast_approach(unit)
	var skill: Dictionary = unit.skills[key]
	var target_id: int = int(check["target_id"])
	var target: Unit = units.get(target_id)
	if (controlled_actor_id >= 0 or frost) and float(skill.get("cast_time_s", 0.0)) > 0.0:
		var command := {"slot": key, "automatic": automatic}
		if not request.is_empty():
			command["request"] = request
		_start_player_cast(unit, target, skill, command)
		return true
	if frost and key in ["e", "r"]:
		# 应急技能通过验证后才结束自己的读条和原走位。
		_cancel_player_cast(unit, "CAST_INTERRUPTED")
		unit.order_kind = "none"
	var cost := float(skill["cost"])
	if aim.is_empty() and String(skill["target"]) != "self" and target != null:
		unit.target_id = target_id

	var impact: Vector2 = check["landing"] if frost and key == "e" else aim.get("point", target.pos if target != null else unit.pos)
	events.fire(&"command_issued", [unit_id, "skill", target_id, impact])
	if cost > 0.0:
		_change_resource(unit, -cost)
	unit.cd_until[key] = time + float(skill["cooldown"])
	if not bool(skill.get("off_gcd", false)):
		unit.gcd_until = time + float(config["gcd"])
	events.fire(&"skill_cast", [unit_id, String(skill["id"]), target_id, int(cost), float(unit.cd_until[key])])
	if automatic:
		events.fire(&"ai_skill_cast", [unit_id, String(skill["id"]), target_id])

	var hit_ids: Array[int] = []
	for effect: Dictionary in skill["effects"]:
		var effect_aim := {"point": impact} if frost and key == "e" else aim
		_apply_effect(unit, target, String(skill["id"]), effect, effect_aim, hit_ids)
	if not aim.is_empty() and not automatic:
		_finish_player_attack(unit, target_id, impact, hit_ids)
		# 有害控制由状态语义识别，破法突刺等伤害附带打断仍开启普攻。
		if controlled_actor_id < 0 and hit_ids.is_empty() and target != null and target.id == unit.auto_target_id:
			for effect: Dictionary in skill["effects"]:
				if effect["kind"] == "status" and effect.get("to") == "target" and effect.get("status") in ["polymorph", "sleep", "fear", "stun"]:
					unit.auto_target_id = -1
	return true


## 按效果结算伤害、治疗和状态。寒霜的冻结、位移与冰箱也在此生效。
func _apply_effect(caster: Unit, target: Unit, skill_id: String, effect: Dictionary, aim: Dictionary, hit_ids: Array[int]) -> void:
	match String(effect["kind"]):
		"freeze":
			for enemy: Unit in _frost_nova_targets(caster, float(effect["radius"])):
				hit_ids.append(enemy.id)
				_damage(caster, enemy, _frost_damage(caster, effect), skill_id, true, _skill_school(skill_id))
				if enemy.alive and not enemy.statuses.has("frozen"):
					_apply_status(enemy, "frozen", caster.id, float(effect["duration"]), {"started_at": time})
		"blink":
			caster.pos = aim["point"]
		"ice_block":
			var base: Dictionary = config["classes"][caster.kind]
			var duration := float(effect["duration"])
			var interval := float(effect["tick"])
			var ticks := roundi(duration / interval)
			_apply_status(caster, "ice_block", caster.id, duration, {
				"next_tick": time + interval, "interval": interval, "ticks_left": ticks,
				"mana": float(base["resource"]["max"]) * float(effect["mana_fraction"]) / ticks,
				"health": float(base["max_hp"]) * float(effect["health_fraction"]) / ticks,
				"skill_id": skill_id,
			})
		"damage":
			var center: Vector2 = aim.get("point", _effect_center(caster, target, String(effect.get("center", "target"))))
			var radius := float(effect.get("radius", 0.0))
			var victims: Array[Unit] = []
			if radius > 0.0:
				for enemy in living("enemy"):
					if enemy.pos.distance_to(center) <= radius + enemy.radius:
						victims.append(enemy)
			elif target != null and target.alive:
				victims.append(target)
			for victim in victims:
				hit_ids.append(victim.id)
				_damage(caster, victim, float(effect["amount"]), skill_id, true, _skill_school(skill_id))
		"heal":
			var center := _effect_center(caster, target, String(effect.get("center", "target")))
			var radius := float(effect.get("radius", 0.0))
			var receivers: Array[Unit] = []
			if radius > 0.0:
				for ally in living("ally"):
					if ally.pos.distance_to(center) <= radius:
						receivers.append(ally)
			elif target != null and target.alive:
				receivers.append(target)
			for receiver in receivers:
				_heal(caster, receiver, float(effect["amount"]), skill_id)
		"status":
			var holder := caster if String(effect.get("to", "self")) == "self" else target
			if holder != null and holder.alive:
				var params := {}
				for param_key in ["taken_mult", "interval_mult"]:
					if effect.has(param_key):
						params[param_key] = float(effect[param_key])
				_apply_status(holder, String(effect["status"]), caster.id, float(effect["duration"]), params)
		"taunt":
			if target != null and target.alive:
				if player_controls and caster.kind == "warrior":
					var highest := 0.0
					for ally in living("ally"):
						if ally.id != caster.id:
							highest = maxf(highest, float(target.threat.get(ally.id, 0.0)))
					target.threat[caster.id] = maxf(float(target.threat.get(caster.id, 0.0)), highest + maxf(1.0, highest * 0.1))
					caster.ai_contact = ally_ai_enabled
				_apply_status(target, "taunt", caster.id, float(effect["duration"]), {})
		"interrupt":
			if target != null and target.alive and not target.cast.is_empty() and bool((target.cast as Dictionary).get("interruptible", false)):
				target.cast = {}
				# 冻结中的读条仍能被打断，新冷却从解冻后开始。
				var clock := float(target.statuses.get("frozen", {}).get("started_at", time))
				target.cast_cd_until = clock + float(target.spell.get("cooldown", 0.0))
				events.fire(&"enemy_cast_interrupted", [target.id, caster.id])
		"restore":
			_change_resource(caster, float(effect["amount"]))


## 技能的伤害类型；表里没写就按物理。
func _skill_school(skill_id: String) -> String:
	var skill: Dictionary = config["skills"].get(skill_id, {})
	return String(skill.get("school", "physical"))


## 防护减伤比例 = 防护 / (防护 + K)。school 为 none（治疗等）不吃防护。
func damage_reduction(victim: Unit, school: String) -> float:
	var defense := 0.0
	match school:
		"physical":
			defense = victim.armor
		"magic":
			defense = victim.magic_resist
		_:
			return 0.0
	if defense <= 0.0:
		return 0.0
	var k := float((config["defense_formula"] as Dictionary)["K"])
	return defense / (defense + k)


func _effect_center(caster: Unit, target: Unit, which: String) -> Vector2:
	if which == "self" or target == null:
		return caster.pos
	return target.pos


# ── 结算原语 ──

## 冰箱在防护和护盾前免疫伤害，飞弹使用发射时确定的暴击。
func _damage(source: Unit, victim: Unit, base: float, skill_id: String, can_crit: bool, school: String = "physical", locked_crit: bool = false, projectile: bool = false) -> void:
	if (_skill_requires_rebuild and not formal_skill_sortie) or not victim.alive or victim.statuses.has("ice_block"):
		return
	var amount := base
	var is_crit := locked_crit or (can_crit and rng.randf() < float(config.get("crit_chance", 0.0)))
	if is_crit:
		amount *= float(config.get("crit_mult", 1.5))
	amount *= 1.0 - damage_reduction(victim, school)
	amount *= taken_mult(victim)
	var final_amount := maxi(1, roundi(amount))
	if formal_skill_sortie:
		var hit := _skill_absorb_damage(victim.shield, float(final_amount))
		if not victim.shield.is_empty():
			if hit["remaining"] == 0.0:
				_retire_skill_shield(victim.shield)
				victim.shield = {}
			else:
				victim.shield["remaining"] = hit["remaining"]
		var before := victim.hp
		victim.hp = maxf(0.0, before - hit["hp_budget"])
		var actual := before - victim.hp
		_record_damage_engagement(source, victim, actual, skill_id)
		# 公共旧事件仍报整数；取整只用于事件，不回写生命或仇恨。
		events.fire(&"damage_dealt", [source.id, victim.id, roundi(actual), skill_id, is_crit, roundi(victim.hp)])
		_show_health_effect(source, victim, actual, false, is_crit, projectile)
		if victim.hp <= 0.0:
			_down(victim, source.id)
		return
	var old_hp := victim.hp
	# 混编寒霜的冰箱会产生小数生命，实际扣血保留这部分。
	victim.hp = maxf(0.0, victim.hp - final_amount) if victim.spec_id == BattleConfig.MAGE_FROST else maxi(0, int(victim.hp) - final_amount)
	if player_controls:
		_record_damage_engagement(source, victim, old_hp - victim.hp, skill_id)
	events.fire(&"damage_dealt", [source.id, victim.id, final_amount, skill_id, is_crit, int(victim.hp)])
	_show_health_effect(source, victim, old_hp - victim.hp, false, is_crit, projectile)
	if not player_controls and source.side == "ally" and victim.side == "enemy":
		victim.threat[source.id] = float(victim.threat.get(source.id, 0.0)) + _damage_threat(source, final_amount, skill_id)
	if victim.hp <= 0:
		_down(victim, source.id)


## 实际扣血参与统计，已倒下的飞弹来源不重新加入仇恨表或交战关系。
func _record_damage_engagement(source: Unit, victim: Unit, actual: float, skill_id: String) -> void:
	var enemy := victim if victim.side == "enemy" else source
	var ally := source if source.side == "ally" else victim
	if enemy.side != "enemy" or ally.side != "ally":
		return
	if source == ally and actual > 0.0:
		_record_player_damage(ally, actual)
	if not ally.alive:
		return
	enemy.activated = true
	enemy.engaged_allies[ally.id] = true
	if ally_ai_enabled:
		ally.ai_contact = true
	if source == ally and actual > 0.0:
		enemy.threat[ally.id] = float(enemy.threat.get(ally.id, 0.0)) + _damage_threat(ally, actual, skill_id)


## 治疗按实际回血登记仇恨。冰箱分跳保留小数，公共事件沿用整数格式。
func _heal(source: Unit, receiver: Unit, base: float, skill_id: String) -> void:
	if (_skill_requires_rebuild and not formal_skill_sortie) or not receiver.alive:
		return
	var amount := roundi(base)
	if formal_skill_sortie or receiver.spec_id == BattleConfig.MAGE_FROST:
		var before := receiver.hp
		var applied := base if skill_id == "mage.frost.ice_block" else float(amount)
		receiver.hp = minf(receiver.max_hp, before + applied)
		var actual := receiver.hp - before
		_record_heal_engagement(source, receiver, actual)
		events.fire(&"heal_done", [source.id, receiver.id, amount, roundi(actual), skill_id, roundi(receiver.hp)])
		_show_health_effect(source, receiver, actual, true, false, false)
		return
	var effective := _effective_legacy_heal(receiver, amount)
	receiver.hp += effective
	if player_controls:
		_record_heal_engagement(source, receiver, float(effective))
	events.fire(&"heal_done", [source.id, receiver.id, amount, effective, skill_id, int(receiver.hp)])
	_show_health_effect(source, receiver, float(effective), true, false, false)
	if not player_controls and effective > 0:
		var threat_gain := float(effective) * float(config.get("heal_threat", 0.5))
		for enemy in living("enemy"):
			enemy.threat[source.id] = float(enemy.threat.get(source.id, 0.0)) + threat_gain


## 只通知友方有效伤害和有效治疗，战斗日志继续保持原整数或事务格式。
func _show_health_effect(source: Unit, target: Unit, actual: float, healing: bool, critical: bool, projectile: bool) -> void:
	if player_controls and source.side == "ally" and actual > 0.0:
		events.health_effect_applied.emit(source.id, target.id, actual, healing, critical, projectile)


## 按受疗者的交战快照均分有效治疗仇恨；只有正增量入账才登记治疗者交战。
func _record_heal_engagement(source: Unit, receiver: Unit, actual: float) -> void:
	if actual <= 0.0:
		return
	var engaged := _skill_engaged_enemies(receiver.id)
	var share := _skill_heal_threat_share(actual, engaged.size())
	for enemy_id: int in engaged:
		var enemy: Unit = units[enemy_id]
		var previous := float(enemy.threat.get(source.id, 0.0))
		var updated := previous + share
		if updated > previous:
			enemy.threat[source.id] = updated
			enemy.engaged_allies[source.id] = true


## 死亡时清理自己的接近、交战和护盾，已施加给其他单位的盾继续存在。
func _down(unit: Unit, by_id: int) -> void:
	unit.alive = false
	unit.hp = 0.0
	_cancel_cast_approach(unit, "CASTER_DOWN")
	if _skill_requires_rebuild or player_controls:
		_clear_skill_engagements(unit.id)
	if _skill_requires_rebuild:
		_retire_skill_shield(unit.shield)
		unit.shield = {}
	unit.order_kind = "none"
	unit.target_id = -1
	if unit.side == "ally":
		_cancel_player_cast(unit, "CASTER_DOWN")
	unit.cast = {}
	for status_id: String in unit.statuses.keys():
		_expire_status(unit, status_id)
	events.fire(&"unit_downed", [unit.id, by_id])


func _apply_status(unit: Unit, status_id: String, source_id: int, duration: float, params: Dictionary) -> void:
	var entry: Dictionary = params.duplicate()
	entry["until"] = time + duration
	entry["source"] = source_id
	unit.statuses[status_id] = entry
	events.fire(&"status_applied", [unit.id, status_id, source_id, float(entry["until"])])


## 解冻后恢复原来剩余的读条和攻击计时，避免累积多次动作。
func _expire_status(unit: Unit, status_id: String) -> void:
	var entry: Dictionary = unit.statuses[status_id]
	if status_id == "frozen" and unit.alive:
		var started := float(entry["started_at"])
		var duration := float(entry["until"]) - started
		if not unit.cast.is_empty():
			unit.cast["started"] += duration
			unit.cast["ends_at"] += duration
		if unit.next_attack_at > started:
			unit.next_attack_at += duration
		if unit.cast_cd_until > started:
			unit.cast_cd_until += duration
	unit.statuses.erase(status_id)
	events.fire(&"status_expired", [unit.id, status_id, int(entry["source"]), float(entry["until"])])


func _change_resource(unit: Unit, delta: float) -> void:
	var before := unit.res
	unit.res = clampf(unit.res + delta, 0.0, unit.res_max)
	var value := int(floor(unit.res))
	if unit.res != before and value != unit.res_emit_value:
		unit.res_emit_value = value
		unit.res_emit_at = time
		events.fire(&"resource_changed", [unit.id, unit.res_kind, value, int(unit.res_max)])


# ── 推进 ──

## 保持正式配置的周期；正式专精在普攻和 AI 前推进本步的技能队列，隔离场仍走独立入口。
func step(dt: float) -> void:
	if finished or paused or (_skill_requires_rebuild and not formal_skill_sortie):
		return
	if formal_skill_sortie:
		if not _skill_point_current(skill_battle_id) or _skill_advancing or not is_finite(dt) or dt <= 0.0:
			return
		_skill_advancing = true
		_step_battle(dt)
		if not _skill_transaction_pending.is_empty():
			_abort_skill_validation(_skill_transaction_pending)
		_skill_advancing = false
	else:
		_step_battle(dt)


## 固定步先处理状态跳点再接收输入，完成读条前仍可被本步走位打断。
func _step_battle(dt: float) -> void:
	var battle_id := skill_battle_id
	var queue_epoch := _skill_queue_epoch
	var commands: Array[Dictionary] = []
	if formal_skill_sortie:
		commands = _skill_pending
		_skill_pending = []
	time += dt
	events.now = time
	if formal_skill_sortie:
		_expire_skill_shields()
	for id in _ids:
		var unit: Unit = units[id]
		if unit.statuses.has("ice_block"):
			_tick_ice_block(unit)
		for status_id: String in unit.statuses.keys():
			var clock := time + 0.0000000001 if status_id in ["ice_block", "frozen"] else time
			if clock >= float((unit.statuses[status_id] as Dictionary)["until"]):
				_expire_status(unit, status_id)
				if formal_skill_sortie and not _skill_point_current(battle_id, queue_epoch):
					return
	if formal_skill_sortie:
		for ally: Unit in living("ally"):
			_regen(ally, dt)
			if not _skill_point_current(battle_id, queue_epoch):
				return
		for command: Dictionary in commands:
			if not _skill_point_current(battle_id, queue_epoch):
				return
			_execute_skill_command(command)
		if not _skill_point_current(battle_id, queue_epoch):
			return
	if controlled_actor_id >= 0 or config.get("mage_spec") == BattleConfig.MAGE_FROST:
		_advance_player_casts()
		if paused or finished or (formal_skill_sortie and not _skill_point_current(battle_id, queue_epoch)):
			return
	for id in _ids:
		var unit: Unit = units[id]
		if not unit.alive:
			continue
		if unit.side == "ally":
			if not formal_skill_sortie:
				_regen(unit, dt)
			_tick_ally(unit, dt)
		else:
			_tick_enemy(unit, dt)
		if formal_skill_sortie and not _skill_point_current(battle_id, queue_epoch):
			return
	_separate()
	_check_end()


## 按绝对游戏时钟补齐冰箱的所有应到跳点，最后一跳先于解除无敌。
func _tick_ice_block(unit: Unit) -> void:
	var block: Dictionary = unit.statuses["ice_block"]
	while int(block["ticks_left"]) > 0 and time + 0.0000000001 >= float(block["next_tick"]):
		block["ticks_left"] -= 1
		block["next_tick"] += block["interval"]
		_change_resource(unit, float(block["mana"]))
		_heal(unit, unit, float(block["health"]), block["skill_id"])
		if paused or finished:
			return


## 冰箱的蓝量只由技能跳点恢复；常规自然恢复继续用已有资源时钟。
func _regen(unit: Unit, dt: float) -> void:
	if unit.res_regen <= 0.0 or unit.res >= unit.res_max or unit.statuses.has("ice_block"):
		return
	unit.res = minf(unit.res_max, unit.res + unit.res_regen * dt)
	var value := int(floor(unit.res))
	# 自然回复最多一秒报一次，避免日志被刷满
	if value != unit.res_emit_value and time - unit.res_emit_at >= 1.0:
		unit.res_emit_value = value
		unit.res_emit_at = time
		events.fire(&"resource_changed", [unit.id, unit.res_kind, value, int(unit.res_max)])


## 手动施法接近优先于队友 AI 和普通持续指令，切换控制权不影响执行。
func _tick_ally(unit: Unit, dt: float) -> void:
	if unit.statuses.has("ice_block"):
		return
	if player_controls and not unit.cast_approach.is_empty():
		_tick_cast_approach(unit, dt)
		return
	if player_controls:
		_tick_player_ally(unit, dt)
		return
	if unit.spec_id == BattleConfig.MAGE_FROST and not unit.cast.is_empty():
		return
	match unit.order_kind:
		"move":
			if _move_toward(unit, unit.order_pos, dt, 3.0):
				unit.order_kind = "none"
			return
		"attack":
			var target: Unit = units.get(unit.target_id)
			if target == null or not target.alive:
				unit.order_kind = "none"
				unit.target_id = -1
			else:
				if unit.pos.distance_to(target.pos) <= unit.attack_range:
					_try_attack(unit, target)
				else:
					_move_toward(unit, target.pos, dt, unit.attack_range * 0.9)
				return
		"heal":
			var target: Unit = units.get(unit.target_id)
			if target == null or not target.alive:
				unit.order_kind = "none"
				unit.target_id = -1
			else:
				if unit.pos.distance_to(target.pos) > unit.attack_range:
					_move_toward(unit, target.pos, dt, unit.attack_range * 0.9)
				elif target.hp < target.max_hp:
					_try_attack(unit, target)
				return
	# 没有命令：只在射程内自动选目标，不追
	if unit.attack_kind == "damage":
		var current: Unit = units.get(unit.target_id)
		if current == null or not current.alive or current.side != "enemy" or current.pos.distance_to(unit.pos) > unit.attack_range:
			current = _nearest(unit.pos, "enemy", unit.attack_range)
		unit.target_id = current.id if current != null else -1
		if current != null:
			_try_attack(unit, current)
	else:
		var current_ally: Unit = units.get(unit.target_id)
		if current_ally == null or not current_ally.alive or current_ally.side != "ally" or current_ally.hp >= current_ally.max_hp or current_ally.pos.distance_to(unit.pos) > unit.attack_range:
			current_ally = _lowest_ratio_ally(unit.pos, unit.attack_range, true)
		unit.target_id = current_ally.id if current_ally != null else -1
		if current_ally != null:
			_try_attack(unit, current_ally)


func _try_attack(unit: Unit, target: Unit) -> void:
	if time < unit.next_attack_at:
		return
	unit.next_attack_at = time + unit.attack_interval * interval_mult(unit)
	if unit.attack_kind == "heal":
		_heal(unit, target, unit.attack_damage, "")
	else:
		_damage(unit, target, unit.attack_damage, "", true, unit.attack_school)
		if unit.res_on_attack > 0.0:
			_change_resource(unit, unit.res_on_attack)


func _move_toward(unit: Unit, dest: Vector2, dt: float, stop_dist: float) -> bool:
	var delta := dest - unit.pos
	var dist := delta.length()
	if dist <= stop_dist:
		return true
	var travel := minf(unit.speed * dt, dist - stop_dist)
	unit.pos += delta / dist * travel
	unit.pos = Vector2(clampf(unit.pos.x, _arena.position.x + unit.radius, _arena.end.x - unit.radius), clampf(unit.pos.y, _arena.position.y + unit.radius, _arena.end.y - unit.radius))
	return dist - travel <= stop_dist + 0.001


## 嘲讽优先，真人场只有挑战者严格越过门槛才换下仍有效的目标。
func _enemy_target(unit: Unit) -> Unit:
	var taunt: Dictionary = unit.statuses.get("taunt", {})
	if not taunt.is_empty():
		var taunter: Unit = units.get(int(taunt["source"]))
		if taunter != null and taunter.alive:
			return taunter
	var best: Unit = null
	var best_threat := 0.0
	for ally in living("ally"):
		var value := float(unit.threat.get(ally.id, 0.0))
		if value > best_threat:
			best = ally
			best_threat = value
	if player_controls:
		var current: Unit = units.get(unit.target_id)
		# 没有正仇恨时也保留已接敌目标；零仇恨的目标可被任意正仇恨挑战。
		if current != null and current.alive and current.side == "ally":
			if best_threat <= float(unit.threat.get(current.id, 0.0)) * 1.10:
				return current
	if best != null:
		return best
	return _nearest(unit.pos, "ally")


## 冻结暂停敌人的移动、攻击和读条；正常施法仍锁定最初的对象。
func _tick_enemy(unit: Unit, dt: float) -> void:
	if unit.statuses.has("frozen"):
		return
	if not unit.cast.is_empty():
		if time >= float((unit.cast as Dictionary)["ends_at"]):
			_resolve_cast(unit)
		return
	var target := _enemy_target(unit)
	if player_controls:
		unit.target_id = target.id if target != null else -1
	if target == null:
		return
	var distance := unit.pos.distance_to(target.pos)
	if not unit.spell.is_empty() and time >= unit.cast_cd_until and distance <= float(unit.spell["range"]):
		_start_cast(unit, target)
		return
	if unit.attack_range > 0.0:
		if distance <= unit.attack_range:
			if time >= unit.next_attack_at:
				unit.next_attack_at = time + unit.attack_interval
				_damage(unit, target, unit.attack_damage * unit.dmg_scale, "", false, unit.attack_school)
		else:
			_move_toward(unit, target.pos, dt, unit.attack_range * 0.9)
	elif not unit.spell.is_empty():
		var hold := float(unit.spell["range"]) * 0.9
		if distance > hold:
			_move_toward(unit, target.pos, dt, hold)


func _start_cast(unit: Unit, target: Unit) -> void:
	var ends_at := time + float(unit.spell["cast_time"])
	unit.cast = {
		"skill_id": String(unit.spell["id"]),
		"name": String(unit.spell["name"]),
		"started": time,
		"ends_at": ends_at,
		"target_id": target.id,
		"center": target.pos,
		"radius": float(unit.spell["radius"]),
		"interruptible": bool(unit.spell["interruptible"]),
		"school": String(unit.spell.get("school", "physical")),
	}
	events.fire(&"enemy_cast_started", [unit.id, String(unit.spell["id"]), ends_at])


func _resolve_cast(unit: Unit) -> void:
	var cast_data: Dictionary = unit.cast
	unit.cast = {}
	unit.cast_cd_until = time + float(unit.spell["cooldown"])
	var damage := float(unit.spell["damage"]) * unit.dmg_scale
	var skill_id: String = cast_data["skill_id"]
	var radius: float = cast_data["radius"]
	var school: String = cast_data["school"]
	if radius > 0.0:
		var center: Vector2 = cast_data["center"]
		for ally in living("ally"):
			if ally.pos.distance_to(center) <= radius + ally.radius:
				_damage(unit, ally, damage, skill_id, false, school)
	else:
		var target: Unit = units.get(int(cast_data["target_id"]))
		if target != null and target.alive:
			_damage(unit, target, damage, skill_id, false, school)


## 冻结或冰箱期间角色保持原位，只有可移动的碰撞对象退让。
func _separate() -> void:
	var alive_units: Array[Unit] = []
	for id in _ids:
		var unit: Unit = units[id]
		if unit.alive:
			alive_units.append(unit)
	for i in alive_units.size():
		for j in range(i + 1, alive_units.size()):
			var a := alive_units[i]
			var b := alive_units[j]
			var min_dist := (a.radius + b.radius) * 0.85
			var delta := b.pos - a.pos
			var dist := delta.length()
			if dist >= min_dist:
				continue
			var push := Vector2.RIGHT.rotated(float(a.id * 7 + b.id)) if dist < 0.001 else delta / dist
			var a_fixed := a.statuses.has("frozen") or a.statuses.has("ice_block")
			var b_fixed := b.statuses.has("frozen") or b.statuses.has("ice_block")
			if a_fixed and b_fixed:
				continue
			if not a_fixed:
				a.pos -= push * (min_dist - dist) * (1.0 if b_fixed else 0.5)
			if not b_fixed:
				b.pos += push * (min_dist - dist) * (1.0 if a_fixed else 0.5)


func _check_end() -> void:
	if finished:
		return
	if living("enemy").is_empty():
		_finish("win", "all_enemies_down")
	elif living("ally").is_empty():
		_finish("lose", "all_allies_down")
	elif time >= float(config["time_limit"]):
		_finish("lose", "timeout")


## 结束通知前清理接近、读条及交战状态，回调不能复活旧命令。
func _finish(outcome: String, why: String) -> void:
	finished = true
	_clear_player_casts()
	if _skill_requires_rebuild or player_controls:
		_clear_skill_engagements()
	if _skill_requires_rebuild:
		_clear_skill_shields()
	if _skill_schedule_active:
		_skill_queue_epoch += 1
		_skill_pending.clear()
		_skill_accumulator = 0.0
	result = outcome
	reason = why
	events.fire(&"battle_ended", [outcome, why, time])


## 只投影飞行所需数据，表现层不接触施法请求、伤害参数或提交状态。
func _snapshot_projectiles() -> Array[Dictionary]:
	var views: Array[Dictionary] = []
	for flight: Dictionary in _player_projectiles:
		var target: Unit = units.get(flight["target_id"])
		if target != null and target.alive:
			var progress := clampf((time - float(flight["started"])) / (float(flight["ends_at"]) - float(flight["started"])), 0.0, 1.0)
			views.append({"skill_id": flight["skill_id"], "origin": flight["origin"], "target": target.pos, "progress": progress})
	return views


## 结算、离场或事务终止时清除友方接近、读条与飞弹。
func _clear_player_casts() -> void:
	_player_projectiles.clear()
	for unit: Unit in units.values():
		if unit.side == "ally":
			unit.cast = {}
			unit.cast_approach = {}


## 深复制权威战斗数据；冻结的读条停在冻结前进度，寒霜生命保留小数。
func snapshot(skill_validation: bool = false) -> Dictionary:
	var unit_list: Array = []
	var skill_map: Dictionary = {}
	for id in _ids:
		var unit: Unit = units[id]
		var cast_view: Dictionary = {}
		if not unit.cast.is_empty():
			var cast_data: Dictionary = unit.cast
			var total := maxf(0.001, float(cast_data["ends_at"]) - float(cast_data["started"]))
			var progress_at := float(unit.statuses.get("frozen", {}).get("started_at", time))
			cast_view = {
				"name": cast_data["name"],
				"progress": clampf((progress_at - float(cast_data["started"])) / total, 0.0, 1.0),
				"center": cast_data["center"],
				"radius": cast_data["radius"],
				"interruptible": cast_data["interruptible"],
			}
		# 使用Variant显式分支保留旧int，避免混合数值条件表达式把旧分支提升为float。
		var hp_view: Variant
		var max_hp_view: Variant
		if _skill_requires_rebuild or unit.spec_id == BattleConfig.MAGE_FROST:
			hp_view = unit.hp
			max_hp_view = unit.max_hp
		else:
			hp_view = int(unit.hp)
			max_hp_view = int(unit.max_hp)
		unit_list.append({
			"id": unit.id, "side": unit.side, "slot": unit.slot, "kind": unit.kind,
			"name": unit.display_name, "color": unit.color_hex, "radius": unit.radius,
			"pos": unit.pos, "hp": hp_view, "max_hp": max_hp_view, "alive": unit.alive,
			"res_kind": unit.res_kind, "res": unit.res, "res_max": unit.res_max,
			"target_id": unit.target_id, "order_kind": unit.order_kind, "order_pos": unit.order_pos,
			"statuses": unit.statuses.keys(), "cast": cast_view, "attack_kind": unit.attack_kind,
		})
		if player_controls:
			var frame: Dictionary = unit_list.back()
			frame["auto_target_id"] = unit.auto_target_id
			frame["damage_done"] = unit.damage_done
			frame["threat"] = unit.threat
			frame["cast_target_id"] = unit.cast.get("target_id", -1)
		if unit.side == "ally":
			var skill_views: Array = []
			for key in SKILL_KEYS:
				if skill_validation or formal_skill_sortie:
					skill_views.append(get_skill_view(unit.id, key.to_upper()))
					continue
				var skill: Dictionary = unit.skills[key]
				var aim := _player_skill_projection_aim(unit, skill["id"]) if player_controls else {}
				var check := check_cast(unit.id, key, aim)
				skill_views.append({
					"key": key, "name": skill["name"], "cost": skill["cost"],
					"cooldown": skill["cooldown"],
					"cd_left": maxf(0.0, float(unit.cd_until.get(key, 0.0)) - time),
					"reason": check["reason"],
				})
			skill_map[unit.id] = skill_views
	return {
		"time": time, "limit": float(config["time_limit"]), "paused": paused,
		"finished": finished, "result": result, "reason": reason,
		"arena": _arena, "units": unit_list, "skills": skill_map,
		"projectiles": _snapshot_projectiles(),
		# 新标记仅在显式模式存在；默认快照字段和旧调用语义保持。
	}.merged({"skill_validation": true} if skill_validation else {}).merged(
		{"skill_formal": true, "skill_full_input": true} if formal_skill_sortie else {}).duplicate(true)


## 逐槽只读查询，寒霜投影使用与混编场相同的配置及施放检查。
func get_skill_view(caster_id: int, slot: String) -> Dictionary:
	var view := {"caster_id": caster_id, "slot": slot, "empty": true, "skill_id": "", "name": "",
		"target_kind": "", "cast_range_m": null, "mana_cost": null, "effects": [], "cooldown": null,
		"skill_ready_at": null, "cd_left": null, "gcd_ready_at": null, "gcd_left": null,
		"preparable": false, "reason": "", "details": {}, "implemented": false}
	var caster: Unit = units.get(caster_id)
	if not _skill_schedule_active or skill_battle_id.is_empty():
		view["reason"] = "STALE_BATTLE"
	elif caster == null or caster.side != "ally" or not caster.controllable:
		view["reason"] = "NO_CASTER"
	elif slot not in ["Q", "W", "E", "R"]:
		view["reason"] = "EMPTY_SLOT"
	elif caster.spec_id == BattleConfig.MAGE_FROST:
		var key := slot.to_lower()
		var frost: Dictionary = caster.skills[key]
		var aim := _player_skill_projection_aim(caster, frost["id"])
		var check := check_cast(caster_id, key, aim)
		var ready := float(caster.cd_until.get(key, 0.0))
		var gcd := 0.0 if frost.get("off_gcd", false) else caster.gcd_until
		return view.merged({
			"empty": false, "implemented": true, "skill_id": frost["id"], "name": frost["name"],
			"target_kind": String(frost["target"]).to_upper(), "cast_range_m": ai_skill_range(frost) / SCENE_UNITS_PER_METER,
			"mana_cost": frost["cost"], "cooldown": frost["cooldown"], "effects": frost["effects"].duplicate(true),
			"skill_ready_at": ready, "cd_left": maxf(0.0, ready - time),
			"gcd_ready_at": gcd, "gcd_left": maxf(0.0, gcd - time),
			"preparable": check["ok"], "reason": check["reason"],
		}, true)
	else:
		var raw: Variant = caster.resolved_slots.get(slot.to_lower(), {})
		if not raw is Dictionary:
			view["reason"] = "CONFIG_ERROR"
			view["details"] = {"problems": PackedStringArray(["unit[%d].slots.%s: 非字典配置" % [caster_id, slot]])}
		elif raw.is_empty():
			view["reason"] = "EMPTY_SLOT"
		else:
			view["empty"] = false
			# 显示字段不包含 icon 或任何额外对象；错误值保留 null，不伪造配置为零。
			for field: String in ["skill_id", "name", "target_kind"]:
				if raw.get(field) is String:
					view[field] = raw[field]
			for pair: Array in [["cast_range_m", "cast_range_m"], ["mana_cost", "mana_cost"], ["cooldown_s", "cooldown"]]:
				var value: Variant = raw.get(pair[0])
				if (value is float or value is int) and is_finite(float(value)):
					view[pair[1]] = value
			if raw.get("effects") is Array:
				for effect: Variant in raw["effects"]:
					var data: Dictionary = {}
					if effect is Dictionary:
						for field: String in ["kind", "selector", "power_coeff", "flat_amount", "radius_m", "duration_s", "uses_stable_crit", "uses_mastery"]:
							var value: Variant = effect.get(field)
							if value == null or value is String or value is bool or value is int or (value is float and is_finite(value)):
								data[field] = value
							else:
								data[field] = null
					view["effects"].append(data)
			view["implemented"] = view["skill_id"] == "mage.fire.evocation" or (_skill_full_numeric and (view["skill_id"] in ["mage.fire.fireball", "priest.holy.greater_heal"] or (_skill_resolution_scope == "S2_3_SHIELD_AWARE" and view["skill_id"] in ["mage.fire.flame_barrier", "mage.fire.flame_burst"])))
			# 非字符串 ID 先给只读诊断，避免旧配置校验的 String 构造接到任意对象。
			var prepared: Dictionary
			if not raw.get("skill_id") is String:
				prepared = {"preparable": false, "reason": "CONFIG_ERROR", "problems": PackedStringArray(["unit[%d].slots.%s.skill_id: 缺少字符串 ID" % [caster_id, slot]])}
			else:
				# 同一纯函数保留失败优先级；已接入技能额外校验事务所需属性，但不调用停场入口。
				var query := {"battle_id": skill_battle_id, "caster_id": caster_id, "slot": slot, "expected_skill_id": raw["skill_id"]}
				if player_controls:
					query["aim"] = _player_skill_projection_aim(caster, raw["skill_id"])
				# 完整模式的已接入技能同时预演最终数值，HUD不把可溢出的准备误报为可执行。
				prepared = _prepare_skill_transaction(query) if _skill_full_numeric and view["implemented"] else _prepare_skill(query, view["implemented"] and _skill_transactions_enabled)
			view["preparable"] = prepared["preparable"]
			view["reason"] = prepared["reason"]
			view["details"] = prepared.get("details", {}).duplicate(true)
			if prepared.has("problems"):
				view["details"]["problems"] = prepared["problems"].duplicate()
		# 即使暂停/拒绝也展示独立双钟；可用性仍取上面的权威执行点判断。
		if is_finite(time) and time >= 0.0 and is_finite(caster.gcd_until) and caster.gcd_until >= 0.0:
			view["gcd_ready_at"] = caster.gcd_until
			view["gcd_left"] = maxf(0.0, caster.gcd_until - time)
		var ready: Variant = caster.skill_ready_at.get(view["skill_id"], 0.0)
		if not view["empty"] and not view["skill_id"].is_empty() and (ready is int or ready is float) and is_finite(float(ready)) and ready >= 0.0 and is_finite(time) and time >= 0.0:
			view["skill_ready_at"] = ready
			view["cd_left"] = maxf(0.0, float(ready) - time)
	return view.duplicate(true)


# ── 新五技能准备阶段：仅由隔离验证和后续事务调用，旧入口不转接 ──
## 显式安装已校验的独立槽位副本；仅写入派生配置，不初始化或推进战斗状态。
func install_skill_loadout(unit_id: int, spec_id: String, catalog: Dictionary) -> PackedStringArray:
	var unit: Unit = units.get(unit_id)
	if unit == null or unit.side != "ally" or unit.kind != spec_id.get_slice(".", 0):
		return PackedStringArray(["%s.unit[%d]: 角色与专精不匹配" % [spec_id, unit_id]])
	var resolved := BattleConfig.resolve_spec(catalog, spec_id)
	if not resolved["problems"].is_empty():
		return resolved["problems"]
	unit.spec_id = spec_id
	unit.resolved_slots = resolved["slots"]
	return PackedStringArray()


## 只读准备检查。正式真人超距预检可略过单位射程，真实结算始终重新检查。
## slot 使用 Q/W/E/R，预检不消费请求身份。
func _prepare_skill(request: Dictionary, transaction: bool = false, ignore_unit_range: bool = false) -> Dictionary:
	if skill_battle_id.is_empty() or request.get("battle_id") != skill_battle_id:
		return _skill_blocked("STALE_BATTLE")
	if paused:
		return _skill_blocked("BATTLE_PAUSED")
	if finished or skill_input_locked:
		return _skill_blocked("INPUT_LOCKED")
	var caster_id: Variant = request.get("caster_id")
	var caster: Unit = units.get(caster_id) if caster_id is int else null
	if caster == null or caster.side != "ally" or not caster.controllable:
		return _skill_blocked("NO_CASTER")
	if not caster.alive:
		return _skill_blocked("CASTER_DOWN")
	if not caster.cast.is_empty():
		return _skill_blocked("CAST_IN_PROGRESS")
	var slot: Variant = request.get("slot")
	if slot not in ["Q", "W", "E", "R"]:
		return _skill_blocked("EMPTY_SLOT")
	var skill: Dictionary = caster.resolved_slots.get(String(slot).to_lower(), {})
	if skill.is_empty():
		return _skill_blocked("EMPTY_SLOT")
	if request.get("expected_skill_id") != skill.get("skill_id") or skill.get("spec_id") != caster.spec_id:
		return _skill_blocked("SKILL_CHANGED")
	# 配置错误属于内部准备失败，不伪装成可施法；后续验证入口据此阻止继续。
	var problems := BattleConfig.validate_resolved_skill(skill)
	# 真实事务的额外输入在同一配置优先级校验；旧纯预检默认路径不改变。
	if transaction and problems.is_empty():
		problems.append_array(_skill_transaction_problems(caster, skill))
	if not _skill_state_numbers_valid(caster, skill):
		problems.append("%s.unit[%d]: 法力、位置或计时字段缺失/非有限/非法" % [skill.get("skill_id"), caster.id])
	if not problems.is_empty():
		return {"preparable": false, "reason": "CONFIG_ERROR", "problems": problems}
	var aim: Dictionary = request.get("aim", {})
	var target: Unit = caster if skill["target_kind"] == "SELF" else units.get(aim.get("target", caster.target_id))
	var ground: bool = aim.has("point") and skill["skill_id"] == "mage.fire.flame_burst"
	var target_side: String = caster.side if skill["target_kind"] != "ENEMY" else "enemy"
	if not ground and (target == null or not target.alive or not target.selectable or target.side != target_side):
		return _skill_blocked("INVALID_TARGET")
	var center: Vector2 = aim["point"] if ground else target.pos
	if not center.is_finite():
		var problem := "skill.point: 非有限位置" if ground else "unit[%d].pos: 非有限位置" % target.id
		return {"preparable": false, "reason": "CONFIG_ERROR", "problems": PackedStringArray([problem])}
	# 正式路径的圈和结算都使用中心距；地面圆心还必须位于战场内。
	var out_of_range := caster.pos.distance_to(center) / SCENE_UNITS_PER_METER > float(skill["cast_range_m"])
	if (ground and (not _arena.has_point(center) or out_of_range)) or (not ground and not ignore_unit_range and skill["target_kind"] != "SELF" and out_of_range):
		return _skill_blocked("OUT_OF_RANGE", {"range_m": skill["cast_range_m"]})
	var effect_targets: Array = []
	for effect: Dictionary in skill["effects"]:
		var ids: Array[int] = []
		if not ground:
			ids.append(target.id)
		if effect["selector"] == "SELF":
			ids = [caster.id]
		elif effect["selector"] == "ENEMIES_AROUND_PRIMARY":
			var secondary: Array[int] = []
			for id: int in units:
				var candidate: Unit = units[id]
				if id in ids or candidate.side != "enemy" or not candidate.alive or not candidate.selectable:
					continue
				if not candidate.pos.is_finite():
					return {"preparable": false, "reason": "CONFIG_ERROR", "problems": PackedStringArray(["unit[%d].pos: 非有限位置" % id])}
				if center.distance_to(candidate.pos) / SCENE_UNITS_PER_METER <= float(effect["radius_m"]):
					secondary.append(id)
			# 主目标先，其余保持稳定顺序，地面空放也得到有效的空名单。
			secondary.sort()
			ids.append_array(secondary)
		effect_targets.append(ids)
	if caster.res < float(skill["mana_cost"]):
		return _skill_blocked("NOT_ENOUGH_MANA", {"cost": skill["mana_cost"]})
	# 隔离调度统一用执行点判截止；未启用时仍按 S1a 原始秒数比较。
	if _skill_deadline_pending(caster.gcd_until):
		return _skill_blocked("GCD_ACTIVE", {"seconds": caster.gcd_until - time})
	var ready_at: float = caster.skill_ready_at.get(skill["skill_id"], 0.0)
	if _skill_deadline_pending(ready_at):
		return _skill_blocked("SKILL_COOLDOWN", {"seconds": ready_at - time})
	# 只锁定当前可知的参数与有序目标；输出属性/结算准备待数值合同补齐。
	return {"preparable": true, "reason": "", "skill": skill.duplicate(true), "caster_id": caster.id,
		"target_id": -1 if ground else target.id, "prepared_at": time, "effect_targets": effect_targets, "impact": center}


## 构造独立的内部拒绝信息；不发布事件，也不复用成功施法字段。
func _skill_blocked(code: String, details: Dictionary = {}) -> Dictionary:
	return {"preparable": false, "reason": code, "details": details}


## 校验准备阶段实际读取的数值；首次未写独立 CD 表示开战可用，不代表配置缺值。
func _skill_state_numbers_valid(caster: Unit, skill: Dictionary) -> bool:
	if not caster.pos.is_finite() or not is_finite(time) or time < 0.0:
		return false
	for value in [caster.res, caster.res_max, caster.gcd_until]:
		if not is_finite(float(value)) or float(value) < 0.0:
			return false
	if caster.res_max != 100.0 or caster.res > caster.res_max:
		return false
	if caster.skill_ready_at.has(skill.get("skill_id")):
		var ready: Variant = caster.skill_ready_at[skill["skill_id"]]
		if not (ready is float or ready is int) or not is_finite(float(ready)) or float(ready) < 0.0:
			return false
	return true


# ── 隔离调度：只供夹具显式调用，真实事务须另外显式启用 ──
## 开启独立调度；完整数值曾安装的实例须重建，不能以换代复活残留单位或回旧模式。
func _begin_skill_schedule() -> String:
	if _skill_requires_rebuild or events == null:
		return ""
	# 发布时允许回调换场；其他阶段遗留保护说明程序异常，不能借换场继续半结算。
	if not _skill_transaction_pending.is_empty() and _skill_transaction_pending.get("phase") != "publish":
		_abort_skill_validation(_skill_transaction_pending)
		return ""
	_disable_skill_transactions()
	_skill_validation_error = {}
	_skill_generation += 1
	_skill_queue_epoch += 1
	# 实例身份加递增代次，不接受外部复用旧 battle_id；同实例重开也不会复活旧请求。
	skill_battle_id = "skill:%d:%d" % [get_instance_id(), _skill_generation]
	_skill_schedule_active = true
	_skill_tick = 0
	_skill_accumulator = 0.0
	_skill_receive_seq = 0
	_skill_pending.clear()
	_skill_seen_requests.clear()
	time = 0.0
	events.now = 0.0
	paused = false
	finished = false
	result = ""
	reason = ""
	skill_input_locked = false
	return skill_battle_id


## 显式离场使本场立即失效；保留 Unit 供检查，不发布业务事件或自动创建新场。
func _leave_skill_schedule() -> void:
	_clear_player_casts()
	_disable_skill_transactions()
	_skill_schedule_active = false
	_skill_queue_epoch += 1
	skill_battle_id = ""
	_skill_pending.clear()
	_skill_accumulator = 0.0


## 校验正式输入的角色、目标或落点，取消施法命令只携带角色身份。
func _skill_command_shape_valid(kind: Variant, payload: Variant) -> bool:
	if not kind is String or kind not in ["move", "target", "prepare", "cast", "cancel_cast"] or not payload is Dictionary:
		return false
	if not payload.get("battle_id") is String or not payload.get("caster_id") is int:
		return false
	match kind:
		"cancel_cast":
			return formal_skill_sortie and player_controls and payload.size() == 2
		"prepare", "cast":
			var shape_ok: bool = payload.get("request_seq") is int and payload["request_seq"] >= 0 and payload.get("slot") is String and payload.get("expected_skill_id") is String
			if not shape_ok or payload.size() == 5:
				return shape_ok
			var aim: Variant = payload.get("aim")
			if not player_controls or payload.size() != 6 or not aim is Dictionary or aim.size() != 1:
				return false
			var point: Variant = aim.get("point")
			return aim.get("target") is int or (payload["expected_skill_id"] in ["mage.fire.flame_burst", "mage.frost.blink"] and point is Vector2 and point.is_finite())
		"move":
			return payload.size() == 3 and payload.get("pos") is Vector2 and payload["pos"].is_finite()
		"target":
			return payload.size() == 3 and payload.get("target_id") is int
	return false


## 接收统一队列并返回入队状态，暂停时只接收撤销命令。
func _enqueue_skill_command(kind: Variant, payload: Variant, automatic: bool = false) -> Dictionary:
	# 正常发布回调可以入队；调用栈已退出却遗留的事务保护必须先停场。
	if not _skill_transaction_pending.is_empty() and (not _skill_advancing or _skill_transaction_pending.get("phase") != "publish"):
		_abort_skill_validation(_skill_transaction_pending)
		return {"queued": false, "reason": "INPUT_LOCKED"}
	if not _skill_command_shape_valid(kind, payload):
		return {"queued": false, "reason": "INVALID_REQUEST"}
	if not _skill_schedule_active or payload["battle_id"] != skill_battle_id:
		return {"queued": false, "reason": "STALE_BATTLE"}
	if kind == "cast" and not _skill_transactions_enabled:
		return {"queued": false, "reason": "TRANSACTIONS_DISABLED"}
	if kind in ["prepare", "cast"]:
		var request_seq: int = payload["request_seq"]
		if _skill_seen_requests.has(request_seq):
			return {"queued": false, "reason": "DUPLICATE_REQUEST"}
		# 本场有效形状的请求即已见，包含暂停丢弃和后续预检失败；不以最大序号判断。
		_skill_seen_requests[request_seq] = true
	# 真人暂停时只允许撤销，排在暂停前已经接收的指令之后。
	if paused and kind != "cancel_cast":
		return {"queued": false, "reason": "BATTLE_PAUSED"}
	if finished or skill_input_locked:
		return {"queued": false, "reason": "INPUT_LOCKED"}
	_skill_receive_seq += 1
	var command := {"kind": kind, "receive_seq": _skill_receive_seq, "payload": payload.duplicate(true)}
	if automatic:
		command["automatic"] = true
	_skill_pending.append(command)
	return {"queued": true, "reason": "", "receive_seq": _skill_receive_seq}


## 截止时刻统一映射到首个不早于截止的固定执行点；仅消除二进制浮点边界噪声。
## 未启用隔离调度时保留旧纯预检的原始秒比较，不改变已验 S1a 行为。
func _skill_deadline_pending(ready_at: float) -> bool:
	if not _skill_schedule_active or formal_skill_sortie:
		# 正式周期来自实际加载表，不把正式时间换算成隔离固定点序号。
		return time + (0.0000000001 if formal_skill_sortie else 0.0) < ready_at
	return _skill_tick < ceili(ready_at / SKILL_FIXED_STEP - 0.0000000001)


## 回调可能暂停、结束、离场或换场；清理代次还能识别同回调暂停再恢复，令局部旧批次失效。
func _skill_point_current(battle_id: String, queue_epoch: int = -1) -> bool:
	return _skill_schedule_active and skill_battle_id == battle_id and not paused and not finished and (queue_epoch < 0 or queue_epoch == _skill_queue_epoch)


## 固定点先到期及恢复；两字段唤醒仍跑旧周期，完整场只推进显式移动、绝不跑旧攻击/敌方施法。
func _skill_periodic_point(battle_id: String, queue_epoch: int) -> void:
	# 来源真正查无时也要可诊断收尾；不能让稳定ID残留变成数组/字典下标错误。
	if _skill_full_numeric:
		for id: int in _ids:
			if not units.get(id) is Unit:
				_abort_skill_validation({"battle_id": battle_id, "request_seq": -1, "skill_id": "", "phase": "shield_periodic", "problems": PackedStringArray(["shield.registry: 本场单位查无"])})
				return
	# 恢复前校验所有必要输入，避免坏评级/派生值先污染浮点法力再被技能校验发现。
	if _skill_transactions_enabled:
		for id: int in _ids:
			var participant: Unit = units[id]
			if participant.side != "ally":
				continue
			var derived := _skill_derived_parameters(participant)
			if not derived["problems"].is_empty() or not is_finite(participant.res) or participant.res < 0.0 or participant.res_max != 100.0 or participant.res > participant.res_max or participant.res_regen != derived.get("regen"):
				_abort_skill_validation({"battle_id": battle_id, "request_seq": -1, "skill_id": "", "phase": "periodic", "problems": derived["problems"] if not derived["problems"].is_empty() else PackedStringArray(["unit[%d].res/res_max/res_regen: 非法或与显式派生值不一致" % id])})
				return
	if _skill_full_numeric:
		var shield_problems := PackedStringArray()
		for id: int in _ids:
			shield_problems.append_array(_skill_shield_problems(units[id]))
		if not shield_problems.is_empty():
			_abort_skill_validation({"battle_id": battle_id, "request_seq": -1, "skill_id": "", "phase": "shield_periodic", "problems": shield_problems})
			return
		# 全部合法才清到期盾；此段早于任何同刻命令，也不发布虚构施法或永久日志。
		_expire_skill_shields()
	for id in _ids:
		var unit: Unit = units[id]
		for status_id: String in unit.statuses.keys():
			if not _skill_deadline_pending(float((unit.statuses[status_id] as Dictionary)["until"])):
				_expire_status(unit, status_id)
				if not _skill_point_current(battle_id, queue_epoch):
					return
	for id in _ids:
		var unit: Unit = units[id]
		if unit.alive and unit.side == "ally":
			_regen(unit, SKILL_FIXED_STEP)
			if not _skill_point_current(battle_id, queue_epoch):
				return
	for id in _ids:
		var unit: Unit = units[id]
		if not unit.alive:
			continue
		if _skill_full_numeric:
			# 只复用移动原语，不借_tick_ally带入自动选敌/普攻；目标命令仍只选目标。
			if unit.side == "ally" and unit.order_kind == "move" and _move_toward(unit, unit.order_pos, SKILL_FIXED_STEP, 3.0):
				unit.order_kind = "none"
			continue
		if unit.side == "ally":
			_tick_ally(unit, SKILL_FIXED_STEP)
		else:
			_tick_enemy(unit, SKILL_FIXED_STEP)
		if not _skill_point_current(battle_id, queue_epoch):
			return
	_separate()
	_check_end()


## 按接收顺序处理输入；正式真人可登记接近，进射程后复用此执行入口。
func _execute_skill_command(command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	if not _skill_transaction_pending.is_empty():
		_abort_skill_validation(_skill_transaction_pending)
		return {"reason": "INPUT_LOCKED"}
	if command["kind"] == "cast":
		var automatic: bool = command.get("automatic", false)
		if not automatic:
			reserve_manual_cast(payload["caster_id"])
		var caster: Unit = units.get(payload["caster_id"])
		if formal_skill_sortie and player_controls and not automatic and caster != null:
			if payload["expected_skill_id"] == "mage.fire.flame_burst" and payload.has("aim"):
				var skill: Dictionary = caster.resolved_slots.get("q", {})
				if skill.has("cast_range_m"):
					payload["aim"] = _ground_cast_aim(caster, skill, payload.get("aim", {}))
			var handling := _prepare_manual_approach(caster, command)
			if not handling.is_empty():
				return handling
		if formal_skill_sortie and caster != null and caster.spec_id == BattleConfig.MAGE_FROST:
			return _execute_frost_command(caster, command, automatic)
		if controlled_actor_id >= 0 and payload["expected_skill_id"] == "mage.fire.fireball":
			var planned := _prepare_skill(payload, true)
			if planned["preparable"] and float(planned["skill"].get("cast_time_s", 0.0)) > 0.0:
				_start_player_cast(units[payload["caster_id"]], units[planned["target_id"]], planned["skill"],
					{"request": payload.duplicate(true), "automatic": automatic})
				return {"receive_seq": command["receive_seq"], "kind": "cast", "pending": true}
		_skill_cast_dispatching = true
		var resolved := _execute_skill_transaction(payload, automatic)
		_skill_cast_dispatching = false
		# GDScript 子调用运行时错误可返回到调用者；标记未清就停场，绝不继续下条命令。
		if not _skill_transaction_pending.is_empty():
			_abort_skill_validation(_skill_transaction_pending)
		return {"receive_seq": command["receive_seq"], "kind": "cast", "result": resolved}
	if command["kind"] == "prepare":
		return {"receive_seq": command["receive_seq"], "kind": "prepare", "preparation": _prepare_skill_transaction(payload) if _skill_full_numeric else _prepare_skill(payload)}
	var unit: Unit = units.get(payload["caster_id"])
	var issue := ""
	if unit == null or unit.side != "ally" or not unit.controllable:
		issue = "NO_CASTER"
	elif not unit.alive:
		issue = "CASTER_DOWN"
	elif command["kind"] == "cancel_cast":
		cancel_player_approach(unit.id)
	elif command["kind"] == "target":
		var target: Unit = units.get(payload["target_id"])
		if target == null or not target.alive or not target.selectable:
			issue = "INVALID_TARGET"
		elif player_controls:
			if not issue_player_target(unit, target):
				issue = "INVALID_TARGET"
		elif formal_skill_sortie:
			var applied := order_attack(unit.id, target.id) if target.side == "enemy" else order_heal(unit.id, target.id)
			if not applied:
				issue = "INVALID_TARGET"
		else:
			unit.target_id = target.id
	else:
		# 复用旧移动的场内裁剪与通知；同步回调只能向下一固定点入队。
		if not order_move(unit.id, payload["pos"]):
			issue = "INPUT_LOCKED"
	return {"receive_seq": command["receive_seq"], "kind": command["kind"], "applied": issue.is_empty(), "reason": issue}


## 正式真人命令因超距时单独核验其他条件；资源不足或冷却中不给角色下达走位。
func _prepare_manual_approach(caster: Unit, command: Dictionary) -> Dictionary:
	var request: Dictionary = command["payload"]
	var aim: Dictionary = request.get("aim", {})
	var key := String(request["slot"]).to_lower()
	var frost := caster.spec_id == BattleConfig.MAGE_FROST
	var checked: Dictionary
	if frost:
		var skill: Dictionary = caster.skills.get(key, {})
		if skill.get("id") != request["expected_skill_id"]:
			return {}
		checked = check_cast(caster.id, key, aim)
	else:
		checked = _prepare_skill(request, true)
	var ready_key := "ok" if frost else "preparable"
	if checked[ready_key]:
		_cancel_cast_approach(caster)
		return {}
	if checked["reason"] not in ["out_of_range", "OUT_OF_RANGE"] or not aim.has("target"):
		return {}

	var validation := check_cast(caster.id, key, aim, true) if frost else _prepare_skill(request, true, true)
	var record := {"receive_seq": command["receive_seq"], "kind": "cast"}
	if not validation[ready_key]:
		record["result"] = _publish_cast_outcome(request, false, validation["reason"], validation.get("details", {}))
		return record
	var skill: Dictionary = caster.skills[key] if frost else validation["skill"]
	_start_cast_approach(caster, skill, validation["target_id"], key, command)
	record["pending"] = true
	return record


## 一条手动技能接管此前的持续命令，锁定单位身份和本次使用的射程。
func _start_cast_approach(caster: Unit, skill: Dictionary, target_id: int, key: String, command: Dictionary = {}) -> void:
	_cancel_cast_approach(caster)
	caster.order_kind = "none"
	caster.target_id = -1
	caster.manual_target_id = -1
	caster.auto_target_id = -1
	caster.cast_approach = {"slot": key, "name": skill["name"], "reach": ai_skill_range(skill), "target_id": target_id,
		"command": command, "stalled": 0.0, "previous_pos": Vector2.INF}


## 逐步接近锁定目标。避让先于施法，真正进射程后先消费命令再调用原结算。
func _tick_cast_approach(caster: Unit, dt: float) -> void:
	var approach := caster.cast_approach
	var target: Unit = units.get(approach["target_id"])
	if target == null or not target.alive or not target.selectable:
		_cancel_cast_approach(caster, "INVALID_TARGET")
		return
	var circles := AllyAI.hazards_for(caster, living("enemy"))
	if AllyAI.path_enters(caster.pos, caster.pos, circles):
		var escape := AllyAI.escape_point(caster.pos, _arena.grow(-caster.radius), circles)
		_move_toward(caster, escape, dt, 0.0)
		approach["stalled"] = 0.0
		approach["previous_pos"] = Vector2.INF
		return
	var reach: float = approach["reach"]
	if caster.pos.distance_to(target.pos) <= reach:
		caster.cast_approach = {}
		if formal_skill_sortie:
			_execute_skill_command(approach["command"])
		else:
			cast_skill(caster.id, approach["slot"], {"target": target.id})
		return
	var before := caster.pos
	var safe := _move_ally_safely(caster, target, reach, dt, circles)
	# 比较两步之间分离后的实际位置，避免把被碰撞推回原位当成前进。
	var previous: Vector2 = approach["previous_pos"]
	if safe and before.distance_squared_to(previous) < 0.0025:
		approach["stalled"] += dt
	else:
		approach["stalled"] = 0.0
	approach["previous_pos"] = before if safe else Vector2.INF
	if approach["stalled"] + 0.0000000001 >= 1.0:
		_cancel_cast_approach(caster, "CANNOT_APPROACH")


## Esc 只撤回仍在接近的命令，已经开始的读条保持现有打断规则。
func cancel_player_approach(caster_id: int) -> void:
	var caster: Unit = units.get(caster_id)
	if caster != null and not finished:
		_cancel_cast_approach(caster)


## 先摘除命令再报告结果，正式请求即使被覆盖也只得到一次终态。
func _cancel_cast_approach(caster: Unit, reason: String = "APPROACH_CANCELLED") -> void:
	if caster.cast_approach.is_empty():
		return
	var command: Dictionary = caster.cast_approach["command"]
	caster.cast_approach = {}
	if not command.is_empty():
		_publish_cast_outcome(command["payload"], false, reason)
	elif reason != "CASTER_DOWN":
		_reject(caster.id, "skill", reason)


## 正式队列用技能标识防止换槽串线，校验后交由混编也使用的结算入口。
func _execute_frost_command(caster: Unit, command: Dictionary, automatic: bool) -> Dictionary:
	var request: Dictionary = command["payload"]
	var slot := String(request["slot"]).to_lower()
	var skill: Dictionary = caster.skills.get(slot, {})
	var aim: Dictionary = request.get("aim", {})
	var record := {"receive_seq": command["receive_seq"], "kind": "cast"}
	if skill.is_empty() or skill["id"] != request["expected_skill_id"]:
		record["result"] = _publish_cast_outcome(request, automatic, "SKILL_CHANGED")
		return record
	var check := check_cast(caster.id, slot, aim)
	if not check["ok"]:
		record["result"] = _publish_cast_outcome(request, automatic, check["reason"])
		return record
	var origin := caster.pos
	var dealt := caster.damage_done
	var targets: Array[Unit] = []
	if slot == "w":
		targets = _frost_nova_targets(caster, float(skill["effects"][0]["radius"]))
	if not cast_skill(caster.id, slot, aim, automatic, request):
		record["result"] = _publish_cast_outcome(request, automatic, "INPUT_LOCKED")
	elif slot == "q":
		record["pending"] = true
	else:
		var frozen_count := 0
		for enemy: Unit in targets:
			if enemy.statuses.has("frozen"):
				frozen_count += 1
		var details := {"damage": caster.damage_done - dealt, "frozen": frozen_count,
			"distance_m": origin.distance_to(caster.pos) / SCENE_UNITS_PER_METER}
		record["result"] = _publish_cast_outcome(request, automatic, "", details)
	return record


## 发布单次正式技能结果；队友执行继续标记为 AI，避免覆盖手动操作提示。
func _publish_cast_outcome(request: Dictionary, automatic: bool, reason: String, details: Dictionary = {}) -> Dictionary:
	var resolved := {"battle_id": request["battle_id"], "request_seq": request["request_seq"],
		"caster_id": request["caster_id"], "skill_id": request["expected_skill_id"],
		"accepted": reason.is_empty(), "reason": reason, "details": details}
	if automatic:
		resolved["source"] = "ai"
	events.fire(&"cast_resolved", [resolved])
	return resolved


## 真实时间换成更多相同的 1/60 步；不截帧、不限制追赶次数，余量跨普通帧保留。
## 返回本次执行记录；prepare 仍非 CastResult，只有显式 cast 分支含真实结果。回调重入不推进。
func _advance_skill_schedule(real_dt: float, speed: int = 1) -> Array[Dictionary]:
	var inspections: Array[Dictionary] = []
	if formal_skill_sortie:
		return inspections
	# 同栈回调属于正常重入拒绝；非推进状态的遗留保护则是错误停场。
	if _skill_advancing:
		# 只有发布阶段可合法回调；提交/效果阶段无外部调用，遗留标记即应停场。
		if not _skill_transaction_pending.is_empty() and _skill_transaction_pending.get("phase") != "publish":
			_abort_skill_validation(_skill_transaction_pending)
		return inspections
	if not _skill_transaction_pending.is_empty():
		_abort_skill_validation(_skill_transaction_pending)
		return inspections
	if not _skill_point_current(skill_battle_id) or _skill_advancing:
		return inspections
	if not is_finite(real_dt) or real_dt < 0.0 or speed not in [1, 2] or not is_finite(real_dt * speed + _skill_accumulator):
		return inspections
	_skill_advancing = true
	# 将实际点循环放在直接子调用中：子调用错误返回/中止时，外层仍能检查完成标志并停场。
	var batch: Variant = _run_skill_points(real_dt, speed)
	if not _skill_transaction_pending.is_empty():
		_abort_skill_validation(_skill_transaction_pending)
	elif not batch is Dictionary or not batch.get("completed", false):
		_abort_skill_validation({"battle_id": skill_battle_id, "request_seq": -1, "skill_id": "", "phase": "advance", "problems": PackedStringArray(["schedule: 执行点调用未正常完成"])})
	_skill_advancing = false
	if batch is Dictionary and batch.get("completed", false):
		return batch["inspections"]
	return inspections


## 直接执行既定固定点循环，正常末尾才返回完成标志；无回调注入，不吞运行时错误或补发结果。
func _run_skill_points(real_dt: float, speed: int) -> Dictionary:
	var inspections: Array[Dictionary] = []
	var battle_id := skill_battle_id
	var queue_epoch := _skill_queue_epoch
	_skill_accumulator += real_dt * speed
	# 一次计算本帧步数，避免大帧逐次减法积累误差；余量含微小浮点负债仍保留。
	var remaining_steps := floori((_skill_accumulator + 0.000000000001) / SKILL_FIXED_STEP)
	_skill_accumulator -= remaining_steps * SKILL_FIXED_STEP
	# 生命周期变化会清余量并中止剩余步；正常帧不截断、不丢弃任何完整步。
	while remaining_steps > 0 and _skill_point_current(battle_id, queue_epoch):
		remaining_steps -= 1
		_skill_tick += 1
		time = _skill_tick * SKILL_FIXED_STEP
		events.now = time
		# 在周期通知之前截取本点批次；所有回调新命令（含周期回调）均留待下一点。
		var commands: Array[Dictionary] = _skill_pending
		_skill_pending = []
		_skill_periodic_point(battle_id, queue_epoch)
		for command: Dictionary in commands:
			if not _skill_point_current(battle_id, queue_epoch) or skill_input_locked:
				break
			inspections.append(_execute_skill_command(command))
			if not _skill_transaction_pending.is_empty():
				_abort_skill_validation(_skill_transaction_pending)
				break
	return {"completed": true, "inspections": inspections}


# ── 隔离唤醒事务：只在显式评级安装后由固定点队列执行 ──
## 默认两字段唤醒不变；先拒绝非法scope/初始盾，避免进入旧失败停场分支造成副作用。
func _enable_skill_transactions(stats_by_unit: Dictionary, full_numeric: bool = false, engagements: Dictionary = {}, resolution_scope: String = "S2_2_UNSHIELDED", initial_shields_by_unit: Dictionary = {}) -> PackedStringArray:
	if resolution_scope not in ["S2_2_UNSHIELDED", "S2_3_SHIELD_AWARE"] or (not full_numeric and resolution_scope != "S2_2_UNSHIELDED") or (not initial_shields_by_unit.is_empty() and (not full_numeric or resolution_scope != "S2_3_SHIELD_AWARE")):
		return PackedStringArray(["transactions.scope/initial_shields: 非法模式或初始盾入口"])
	if full_numeric:
		return _install_full_skill_stats(stats_by_unit, engagements, resolution_scope, initial_shields_by_unit)
	if _skill_requires_rebuild:
		return PackedStringArray(["transactions.enable: 完整场残留单位须重建Sim"])
	var problems := PackedStringArray()
	if not _skill_schedule_active or _skill_tick != 0 or _skill_receive_seq != 0 or not _skill_pending.is_empty() or _skill_advancing or _skill_transactions_enabled or finished or paused:
		problems.append("transactions.enable: 必须在首步及入队前显式启用一次")
	var prepared: Dictionary = {}
	for id: int in _ids:
		var unit: Unit = units[id]
		if unit.side != "ally":
			continue
		var supplied: Variant = stats_by_unit.get(id)
		if not supplied is Dictionary:
			problems.append("unit[%d].combat_stats: 缺少显式评级字典" % id)
			continue
		var derived := _skill_derived_parameters(unit, supplied)
		problems.append_array(derived["problems"])
		prepared[id] = {"stats": supplied.duplicate(true), "derived": derived}
	for id: Variant in stats_by_unit:
		if not id is int or not prepared.has(id):
			problems.append("combat_stats[%s]: 非参与友方角色" % str(id))
	if not problems.is_empty():
		_abort_skill_validation({"battle_id": skill_battle_id, "request_seq": -1, "skill_id": "", "phase": "enable", "problems": problems})
		return problems
	# 任何一人失败均不会先安装其他人，失败停场只写诊断及生命周期字段。
	for id: int in prepared:
		var unit: Unit = units[id]
		_skill_previous_regen[id] = unit.res_regen
		unit.combat_stats = prepared[id]["stats"]
		unit.res_regen = prepared[id]["derived"]["regen"]
	_skill_transactions_enabled = true
	return problems


## 两字段唤醒沿用原计算；完整场从唯一防护与独立属性副本只读派生，不存第二份P或防护。
func _skill_derived_parameters(unit: Unit, supplied: Variant = null) -> Dictionary:
	if _skill_full_numeric and supplied == null:
		var full: Dictionary = unit.combat_stats.duplicate(true)
		full["armor"] = unit.armor
		full["magic_resistance"] = unit.magic_resist
		return _full_skill_parameters(unit, full)
	var stats: Dictionary = unit.combat_stats if supplied == null else supplied
	var problems := PackedStringArray()
	for field in ["spirit", "haste_rating"]:
		var value: Variant = stats.get(field)
		if not (value is float or value is int) or not is_finite(float(value)) or float(value) < 0.0:
			problems.append("unit[%d].combat_stats.%s: 缺失、错型、非有限或负数" % [unit.id, field])
	if stats.size() != 2:
		problems.append("unit[%d].combat_stats: 仅允许spirit/haste_rating" % unit.id)
	if unit.kind not in ["mage", "priest"]:
		problems.append("unit[%d].kind: 本单只支持法师/牧师" % unit.id)
	if not problems.is_empty():
		return {"problems": problems}
	var spirit := float(stats["spirit"])
	var rating := float(stats["haste_rating"])
	# 按已给公式计算；派生溢出也必须拒绝，不能把未知强度等属性补成零。
	var haste := 0.30 * rating / (rating + 1000.0)
	var gcd := maxf(0.75, 1.0 / (1.0 + haste))
	var base := 3.0 + 0.035 * spirit if unit.kind == "mage" else 3.0 + 0.035 * minf(spirit, 150.0) + 0.003 * maxf(spirit - 150.0, 0.0)
	var regen := base * (1.0 + 0.50 * haste)
	if not is_finite(haste) or not is_finite(gcd) or not is_finite(regen) or regen < 0.0:
		problems.append("unit[%d].derived.haste/gcd/regen: 非有限派生结果" % unit.id)
	return {"problems": problems, "haste": haste, "gcd": gcd, "regen": regen}


## 同一配置优先级检查事务支持范围；先验证全部效果，禁止空效果或同效果冒充其他技能。
func _skill_transaction_problems(caster: Unit, skill: Dictionary) -> PackedStringArray:
	var problems: PackedStringArray = _skill_derived_parameters(caster)["problems"]
	if not _skill_transactions_enabled:
		problems.append("transactions.enabled: 未显式启用")
	# 爆破仅完整S23开放，严格冻结单效果参数；不以同类魔法效果开放其他技能或旧scope。
	if _skill_full_numeric and _skill_resolution_scope == "S2_3_SHIELD_AWARE" and skill["skill_id"] == "mage.fire.flame_burst":
		var expected := {"spec_id": "mage.fire", "target_kind": "ENEMY", "cast_range_m": 8.0, "mana_cost": 25.0, "cooldown_s": 8.0}
		if caster.kind != "mage":
			problems.append("burst.caster: 职业不匹配")
		for field: String in expected:
			if skill[field] != expected[field]:
				problems.append("burst.%s: 非冻结爆破参数" % field)
		if skill["effects"].size() != 1:
			problems.append("burst.effects: 必须单一效果")
		var expected_effect := {"kind": "MAGIC_DAMAGE", "selector": "ENEMIES_AROUND_PRIMARY", "power_coeff": 1.70, "flat_amount": 0.0, "radius_m": 2.0, "duration_s": 0.0, "uses_stable_crit": true, "uses_mastery": false}
		for effect: Dictionary in skill["effects"]:
			for field: String in expected_effect:
				if effect[field] != expected_effect[field]:
					problems.append("burst.effects.%s: 非冻结爆破参数" % field)
		return problems
	# S23屏障仅SELF且精确匹配资源；不影响默认S22及两字段入口。
	if _skill_full_numeric and _skill_resolution_scope == "S2_3_SHIELD_AWARE" and skill["skill_id"] == "mage.fire.flame_barrier":
		var expected := {"spec_id": "mage.fire", "target_kind": "SELF", "cast_range_m": 0.0, "mana_cost": 20.0, "cooldown_s": 16.0}
		if caster.kind != "mage":
			problems.append("shield.caster: 职业不匹配")
		for field: String in expected:
			if skill[field] != expected[field]:
				problems.append("shield.%s: 非冻结屏障参数" % field)
		if skill["effects"].size() != 1:
			problems.append("shield.effects: 必须单一效果")
		var expected_effect := {"kind": "SHIELD", "selector": "SELF", "power_coeff": 1.50, "flat_amount": 0.0, "radius_m": 0.0, "duration_s": 6.0, "uses_stable_crit": false, "uses_mastery": false}
		for effect: Dictionary in skill["effects"]:
			for field: String in expected_effect:
				if effect[field] != expected_effect[field]:
					problems.append("shield.effects.%s: 非冻结屏障参数" % field)
		return problems
	# 两个单体技能复用完整场公式，不以同类效果冒充其他技能。
	if _skill_full_numeric and skill["skill_id"] in ["mage.fire.fireball", "priest.holy.greater_heal"]:
		var damage: bool = skill["skill_id"] == "mage.fire.fireball"
		var expected := {"spec_id": "mage.fire" if damage else "priest.holy", "target_kind": "ENEMY" if damage else "ALLY",
			"cast_range_m": 8.0, "mana_cost": 15.0 if damage else 25.0, "cooldown_s": 3.0 if damage else 5.0}
		if caster.kind != ("mage" if damage else "priest"):
			problems.append("%s.caster: 职业不匹配" % skill["skill_id"])
		for field: String in expected:
			if skill[field] != expected[field]:
				problems.append("%s.%s: 非冻结单体参数" % [skill["skill_id"], field])
		if skill["effects"].size() != 1:
			problems.append("%s.effects: 必须为单一效果" % skill["skill_id"])
		var effect_expected := {"kind": "MAGIC_DAMAGE" if damage else "HEAL", "selector": "PRIMARY",
			"power_coeff": 1.10 if damage else 2.40, "flat_amount": 0.0, "radius_m": 0.0,
			"duration_s": 0.0, "uses_stable_crit": true, "uses_mastery": true}
		for effect: Dictionary in skill["effects"]:
			for field: String in effect_expected:
				if effect[field] != effect_expected[field]:
					problems.append("%s.effects.%s: 非冻结单体参数" % [skill["skill_id"], field])
		return problems
	if skill["skill_id"] != "mage.fire.evocation" or caster.kind != "mage" or skill["spec_id"] != "mage.fire":
		problems.append("%s.skill_id: 本单只支持mage.fire.evocation" % skill["skill_id"])
	if skill["target_kind"] != "SELF" or skill["mana_cost"] != 0.0 or skill["cooldown_s"] != 20.0:
		problems.append("%s.target_kind/mana_cost/cooldown_s: 非首版唤醒参数" % skill["skill_id"])
	if skill["effects"].size() != 1:
		problems.append("%s.effects: 首版唤醒须为单一回蓝效果，仍逐项检查不支持效果" % skill["skill_id"])
	for i in skill["effects"].size():
		var effect: Dictionary = skill["effects"][i]
		if effect["kind"] != "RESTORE_MANA" or effect["selector"] != "SELF" or effect["flat_amount"] != 35.0:
			problems.append("%s.effects[%d]: 仅支持首版RESTORE_MANA/SELF/35" % [skill["skill_id"], i])
	return problems


## 纯查询全部输入及最终数值，预先计算有序效果快照；不消费身份、不触碰状态或发布反馈。
func _prepare_skill_transaction(request: Dictionary) -> Dictionary:
	var prepared := _prepare_skill(request, true)
	if not prepared["preparable"]:
		return prepared
	var caster: Unit = units[prepared["caster_id"]]
	var skill: Dictionary = prepared["skill"]
	# 唤醒也校验本场盾，原回蓝明细不扩字段；纯校验不清真实到期盾。
	if _skill_full_numeric:
		for id: int in _ids:
			var participant: Unit = units.get(id)
			if participant == null:
				return {"preparable": false, "reason": "CONFIG_ERROR", "problems": PackedStringArray(["shield.registry: 本场单位查无"])}
			var shield_problems := _skill_shield_problems(participant)
			if not shield_problems.is_empty():
				return {"preparable": false, "reason": "CONFIG_ERROR", "problems": shield_problems}
	# 工作副本不暴露给事件订阅者；S23屏障及爆破复用相同全量准备与提交入口。
	if _skill_full_numeric and skill["skill_id"] in ["mage.fire.fireball", "priest.holy.greater_heal", "mage.fire.flame_barrier", "mage.fire.flame_burst"]:
		if skill["skill_id"] == "mage.fire.flame_barrier":
			prepared["request_seq"] = request.get("request_seq", -1)
		return _prepare_single_skill_transaction(prepared)
	var derived := _skill_derived_parameters(caster)
	var mana_after := caster.res - float(skill["mana_cost"])
	var effects: Array[Dictionary] = []
	for i in skill["effects"].size():
		for j in prepared["effect_targets"][i].size():
			var before := mana_after
			var amount := minf(float(skill["effects"][i]["flat_amount"]), caster.res_max - before)
			mana_after += amount
			effects.append({"effect_index": i, "target_index": j, "source_id": caster.id, "target_id": prepared["effect_targets"][i][j], "effect_kind": "RESTORE_MANA", "requested_amount": float(skill["effects"][i]["flat_amount"]), "actual_amount": amount, "mana_before": before, "mana_after": mana_after})
	var gcd_ready := time + float(derived["gcd"])
	var skill_ready := time + float(skill["cooldown_s"])
	if not is_finite(mana_after) or not is_finite(gcd_ready) or not is_finite(skill_ready):
		return {"preparable": false, "reason": "CONFIG_ERROR", "problems": PackedStringArray(["%s.final: 非有限提交数值" % skill["skill_id"]])}
	prepared["details"] = {"executed_at": time, "mana_before": caster.res, "mana_cost": float(skill["mana_cost"]), "mana_after": mana_after, "gcd_ready_at": gcd_ready, "skill_ready_at": skill_ready, "effects": effects}
	return prepared


## 纯预演伤害与治疗事务；飞弹复用发射时的输出与费用快照，目标状态取当前固定步。
func _prepare_single_skill_transaction(prepared: Dictionary, flight: Dictionary = {}) -> Dictionary:
	var staged: Dictionary = {}
	var parameters: Dictionary = {}
	var problems := PackedStringArray()
	# 校验随后会读取/清理的全部生命和关系，避免坏状态被空集或致死分支掩盖。
	for id: int in _ids:
		var unit: Unit = units[id]
		var derived: Dictionary = flight["derived"] if id == prepared["caster_id"] and not flight.is_empty() else _skill_derived_parameters(unit)
		problems.append_array(derived["problems"])
		parameters[id] = derived
		if not is_finite(unit.hp) or not is_finite(unit.max_hp) or unit.max_hp < 1.0 or unit.hp < 0.0 or unit.hp > unit.max_hp or unit.alive != (unit.hp > 0.0):
			problems.append("unit[%d].hp: 非法或存活状态不一致" % id)
		staged[id] = {"hp": unit.hp, "alive": unit.alive, "activated": unit.activated,
			"engaged_allies": unit.engaged_allies.duplicate(true), "threat": unit.threat.duplicate(true), "dirty": false}
		if _skill_resolution_scope == "S2_3_SHIELD_AWARE":
			staged[id]["shield"] = unit.shield.duplicate(true) if unit.shield.is_empty() or _skill_deadline_pending(unit.shield["expires_at"]) else {}
			staged[id]["dirty"] = staged[id]["shield"] != unit.shield
		if unit.side != "enemy":
			continue
		if (not unit.alive or not unit.activated) and not unit.engaged_allies.is_empty():
			problems.append("unit[%d].engaged_allies: 死亡或未激活时不能有关系" % id)
		if not unit.alive and (unit.activated or not unit.threat.is_empty()):
			problems.append("unit[%d].threat: 死亡敌人未完成清理" % id)
		for ally_id: Variant in unit.engaged_allies:
			var ally: Unit = units.get(ally_id) if ally_id is int else null
			if ally == null or ally.side != "ally" or not ally.alive or not unit.engaged_allies[ally_id] is bool or unit.engaged_allies[ally_id] != true:
				problems.append("unit[%d].engaged_allies: 非法关系" % id)
		for source_id: Variant in unit.threat:
			var source: Unit = units.get(source_id) if source_id is int else null
			var value: Variant = unit.threat[source_id]
			if source == null or source.side != "ally" or not source.alive or not (value is float or value is int) or not is_finite(float(value)) or float(value) < 0.0:
				problems.append("unit[%d].threat: 非法来源或仇恨量" % id)
	if not problems.is_empty():
		return {"preparable": false, "reason": "CONFIG_ERROR", "problems": problems}
	var caster: Unit = units[prepared["caster_id"]]
	var skill: Dictionary = prepared["skill"]
	var derived: Dictionary = parameters[caster.id]
	if skill["skill_id"] == "mage.fire.flame_barrier":
		return _prepare_barrier_transaction(prepared, staged, derived)
	var burst: bool = skill["skill_id"] == "mage.fire.flame_burst"
	var effects: Array[Dictionary] = []
	var shield_changes: Array[Dictionary] = []
	var defeated: Array[int] = []
	var notices: Array[Dictionary] = []
	var mana_after := caster.res - float(skill["mana_cost"])
	var gcd_ready: float = time + float(derived["gcd"])
	var skill_ready: float = time + float(skill["cooldown_s"])
	if not flight.is_empty():
		mana_after = flight["mana_after"]
		gcd_ready = flight["gcd_ready_at"]
		skill_ready = flight["skill_ready_at"]
	# 名单来自已校验快照；参数预先全量派生，循环中不重新选人或发布事件。
	# 爆破晚期错误仅在既有problems中附已完成效果副本及目标索引，不新增取证状态或事件。
	var targets: Array = prepared["effect_targets"][0].duplicate()
	for target_index: int in targets.size():
		var target: Unit = units[targets[target_index]]
		var damage: bool = skill["skill_id"] in ["mage.fire.fireball", "mage.fire.flame_burst"]
		var intermediate: Array[float] = []
		var raw: float = (1.70 if burst else (1.10 if damage else 2.40)) * float(derived["power"])
		# 套装只给冻结专精的 Q 增加一次原始量，不改 P、W/E/R 或自动动作。
		if formal_skill_sortie and caster.formal_q_set and (burst or not damage):
			raw *= 1.05
		intermediate.append(raw)
		raw *= float(derived["damage_multiplier"] if damage else derived["healing_multiplier"])
		intermediate.append(raw)
		raw *= 1.0 + (0.0 if burst else float(derived["mastery"]))
		intermediate.append(raw)
		if damage:
			# 精准/回避分母及每一步也要有限；乘零、封顶或后续防护不能遮蔽中间溢出。
			var precision: float = derived["stats"]["precision_rating"]
			var evasion: float = parameters[target.id]["stats"]["evasion_rating"]
			var denominator := precision + evasion + 1000.0
			var q := 1.0 + 0.25 * (precision - evasion) / denominator
			intermediate.append_array([denominator, q])
			raw *= q
			intermediate.append(raw)
		raw *= float(derived["critical_multiplier"])
		intermediate.append(raw)
		var requested := raw
		if damage:
			var resistance := maxf(0.0, target.magic_resist * (1.0 - float(derived["penetration"])))
			var denominator := 1000.0 + resistance
			var mitigation := 1000.0 / denominator
			requested *= mitigation
			intermediate.append_array([resistance, denominator, mitigation, requested])
			requested *= float(parameters[target.id]["damage_taken_multiplier"])
		intermediate.append(requested)
		intermediate.append_array([mana_after, gcd_ready, skill_ready])
		for value: float in intermediate:
			if not is_finite(value) or value < 0.0:
				return {"preparable": false, "reason": "CONFIG_ERROR", "problems": PackedStringArray(["single.final: 公式/费用/截止中间值非有限或负数"] + (["burst.target_index=%d target_id=%d" % [target_index, target.id], "burst.prepared_effects:" + JSON.stringify(effects)] if burst else []))}
		var absorbed := 0.0
		var shield_intended := 0.0
		var absorptions: Array[Dictionary] = []
		var shield_before: Dictionary = staged[target.id].get("shield", {}).duplicate(true)
		if damage and not shield_before.is_empty() and requested > 0.0:
			var allocation := _skill_absorb_damage(shield_before, requested)
			var shield_remaining: float = allocation["remaining"]
			absorbed = allocation["absorbed"]
			shield_intended = allocation["intended"]
			# 实得仅取真实池差；舍入可略超名义预算，但池必须单调、未越容量且确实减少。
			if not is_finite(shield_remaining) or not is_finite(absorbed) or shield_remaining < 0.0 or shield_remaining > float(shield_before["remaining"]) or absorbed <= 0.0 or absorbed > float(shield_before["remaining"]):
				return {"preparable": false, "reason": "CONFIG_ERROR", "problems": PackedStringArray(["shield.absorb: 正量不可表达或池状态越界"] + (["burst.target_index=%d target_id=%d" % [target_index, target.id], "burst.prepared_effects:" + JSON.stringify(effects)] if burst else []))}
			var next_shield := shield_before.duplicate(true)
			next_shield["remaining"] = shield_remaining
			staged[target.id]["shield"] = {} if shield_remaining == 0.0 else next_shield
			var absorption := shield_before.duplicate(true)
			absorption.merge({"remaining_before": shield_before["remaining"], "remaining_after": shield_remaining, "absorbed_amount": absorbed, "depleted": shield_remaining == 0.0})
			absorptions.append(absorption)
			shield_changes.append({"target_id": target.id, "reason": "depleted" if shield_remaining == 0.0 else "absorbed", "before": shield_before.duplicate(true), "after": staged[target.id]["shield"].duplicate(true)})
		# 生命只接收未被名义吸收覆盖的预算，不能用舍入后的池差反算剩余伤害。
		var hp_budget := requested - shield_intended
		var before := target.hp
		var available := before if damage else target.max_hp - before
		var intended := minf(hp_budget, available)
		var after := maxf(0.0, before - intended) if damage else minf(target.max_hp, before + intended)
		var actual := before - after if damage else after - before
		# 不设epsilon或最低1；有可结算正量却完全不能改变生命时拒绝，不能虚报实得。
		if not is_finite(after) or not is_finite(actual) or (intended > 0.0 and actual <= 0.0):
			return {"preparable": false, "reason": "CONFIG_ERROR", "problems": PackedStringArray(["single.hp: 正增量不可表达或生命运算非有限"] + (["burst.target_index=%d target_id=%d" % [target_index, target.id], "burst.prepared_effects:" + JSON.stringify(effects)] if burst else []))}
		# 新scope保留真实状态单调与容量约束，不要求真实差等于名义分配量；旧S22入口不改。
		if _skill_resolution_scope == "S2_3_SHIELD_AWARE" and (not is_finite(hp_budget) or hp_budget < 0.0 or after < 0.0 or after > target.max_hp or actual < 0.0 or actual > available or (damage and after > before) or (not damage and after < before)):
			return {"preparable": false, "reason": "CONFIG_ERROR", "problems": PackedStringArray(["shield.hp: 生命预算或最终状态越界"] + (["burst.target_index=%d target_id=%d" % [target_index, target.id], "burst.prepared_effects:" + JSON.stringify(effects)] if burst else []))}
		staged[target.id]["hp"] = after
		staged[target.id]["dirty"] = true
		var effect := {"effect_index": 0, "target_index": target_index, "source_id": caster.id, "target_id": target.id,
			"effect_kind": "MAGIC_DAMAGE" if damage else "HEAL", "requested_amount": requested, "actual_amount": actual,
			"hp_before": before, "hp_after": after, "threat_changes": [], "engagements_added": []}
		var enemies: Array[int] = []
		if damage:
			# 旧S22明细完全保留；新scope吸收与生命差分别归属，剩余预算才记过量。
			effect.merge({"raw_amount": raw, "absorbed_amount": absorbed, "overkill_amount": maxf(0.0, hp_budget - before)})
			if _skill_resolution_scope == "S2_3_SHIELD_AWARE":
				# 数学守恒不是浮点分项逐位相加门禁；过量仅为名义生命预算超出生命容量。
				effect["absorptions"] = absorptions
			# 来源倒下后，已发射的飞弹仍扣血，仇恨表继续只保留活人。
			if caster.alive:
				enemies.append(target.id)
		else:
			effect["overheal_amount"] = maxf(0.0, requested - actual)
			# 在添加治疗者关系前取权威快照；空集合和零有效不产生任何仇恨。
			enemies = _skill_engaged_enemies(target.id)
		var threat_amount := actual if damage else _skill_heal_threat_share(actual, enemies.size())
		if not is_finite(threat_amount) or (actual > 0.0 and not enemies.is_empty() and threat_amount <= 0.0):
			return {"preparable": false, "reason": "CONFIG_ERROR", "problems": PackedStringArray(["single.threat: 仇恨运算溢出或正量下溢"] + (["burst.target_index=%d target_id=%d" % [target_index, target.id], "burst.prepared_effects:" + JSON.stringify(effects)] if burst else []))}
		for enemy_id: int in enemies:
			var state: Dictionary = staged[enemy_id]
			if threat_amount > 0.0:
				var threat_before := float(state["threat"].get(caster.id, 0.0))
				var threat_after := threat_before + threat_amount
				if not is_finite(threat_after) or threat_after <= threat_before:
					return {"preparable": false, "reason": "CONFIG_ERROR", "problems": PackedStringArray(["single.threat: 正增量不可表达或累加溢出"] + (["burst.target_index=%d target_id=%d" % [target_index, target.id], "burst.prepared_effects:" + JSON.stringify(effects)] if burst else []))}
				state["threat"][caster.id] = threat_after
				effect["threat_changes"].append({"enemy_id": enemy_id, "source_id": caster.id, "amount": threat_amount, "before": threat_before, "after": threat_after})
			if damage or threat_amount > 0.0:
				state["activated"] = true
				if not state["engaged_allies"].has(caster.id):
					state["engaged_allies"][caster.id] = true
					effect["engagements_added"].append(enemy_id)
				state["dirty"] = true
		if damage and after == 0.0:
			# 只清目标自身盾；来源死亡不能清其他存活目标的盾，死亡不是伤害耗尽。
			if _skill_resolution_scope == "S2_3_SHIELD_AWARE" and not staged[target.id]["shield"].is_empty():
				shield_changes.append({"target_id": target.id, "reason": "death", "before": staged[target.id]["shield"].duplicate(true), "after": {}})
				staged[target.id]["shield"] = {}
			# 只缓存通知；绝不调用会同步发事件的旧_down/_expire_status。
			defeated.append(target.id)
			staged[target.id].merge({"alive": false, "activated": false, "engaged_allies": {}, "threat": {},
				"order_kind": "none", "target_id": -1, "cast": {}, "statuses": {}}, true)
			for status_id: Variant in target.statuses:
				var status: Variant = target.statuses[status_id]
				if not status_id is String or not status is Dictionary or not status.get("source") is int or not (status.get("until") is int or status.get("until") is float) or not is_finite(float(status["until"])):
					return {"preparable": false, "reason": "CONFIG_ERROR", "problems": PackedStringArray(["single.death.status: 无法缓存合法清理通知"] + (["burst.target_index=%d target_id=%d" % [target_index, target.id], "burst.prepared_effects:" + JSON.stringify(effects)] if burst else []))}
				notices.append({"event": &"status_expired", "args": [target.id, status_id, status["source"], float(status["until"])]})
			notices.append({"event": &"unit_downed", "args": [target.id, caster.id]})
		if _skill_resolution_scope == "S2_3_SHIELD_AWARE":
			effect["shield_before"] = shield_before.duplicate(true)
			effect["shield_after"] = staged[target.id]["shield"].duplicate(true)
		# 只有本目标数值、仇恨和死亡通知准备完毕才登记；前目标死亡不截断锁定名单。
		effects.append(effect)
	prepared["details"] = {"executed_at": time, "mana_before": flight.get("mana_before", caster.res), "mana_cost": float(skill["mana_cost"]),
		"mana_after": mana_after, "gcd_ready_at": gcd_ready, "skill_ready_at": skill_ready,
		"resolution_scope": _skill_resolution_scope, "defeated_ids": defeated, "effects": effects}
	if _skill_resolution_scope == "S2_3_SHIELD_AWARE":
		prepared["details"]["shield_changes"] = shield_changes
	prepared["commit_units"] = staged
	prepared["death_notices"] = notices
	return prepared.duplicate(true)


## 提交瞬发效果或已经付费的飞弹命中，发布结果后才派发死亡和胜负。
func _execute_skill_transaction(request: Dictionary, automatic: bool = false, flight: Dictionary = {}) -> Dictionary:
	if not _skill_transaction_pending.is_empty():
		return {"ignored": true, "reason": "TRANSACTION_REENTRY"}
	if not _skill_advancing or not _skill_cast_dispatching or not _skill_command_shape_valid("cast", request):
		return {"ignored": true, "reason": "INVALID_EXECUTION"}
	var battle_id := skill_battle_id
	var queue_epoch := _skill_queue_epoch
	var death_notices: Array = []
	_skill_transaction_pending = {"battle_id": battle_id, "request_seq": request["request_seq"], "caster_id": request["caster_id"], "skill_id": request["expected_skill_id"], "phase": "prepare", "problems": PackedStringArray(["transaction: 调用未正常完成"])}
	var prepared := _prepare_skill_transaction(request) if flight.is_empty() else _prepare_single_skill_transaction(flight["prepared"], flight)
	var resolved := {"battle_id": battle_id, "request_seq": request["request_seq"], "caster_id": request["caster_id"], "skill_id": request["expected_skill_id"], "accepted": prepared["preparable"], "reason": prepared["reason"], "details": {}}
	if automatic:
		resolved["source"] = "ai"
	if not prepared["preparable"]:
		resolved["details"] = prepared.get("details", {}).duplicate(true)
		if prepared["reason"] == "SKILL_CHANGED":
			var changed: Unit = units.get(request["caster_id"])
			if changed != null:
				resolved["details"]["current_skill_id"] = changed.resolved_slots.get(request["slot"].to_lower(), {}).get("skill_id", "")
		if prepared["reason"] == "CONFIG_ERROR":
			resolved["details"]["problems"] = prepared["problems"].duplicate()
			var context := _skill_transaction_pending.duplicate(true)
			context["problems"] = prepared["problems"]
			_abort_skill_validation(context)
	else:
		var caster: Unit = units[request["caster_id"]]
		var details: Dictionary = prepared["details"]
		var cast_id := battle_id + ":" + str(request["request_seq"])
		resolved["cast_id"] = cast_id
		_skill_transaction_pending["phase"] = "commit"
		# 此段只有预校验过的数据写入，不调用会中途通知的旧资源/施法路径。
		if flight.is_empty():
			caster.res = float(details["mana_before"]) - float(details["mana_cost"])
			caster.gcd_until = details["gcd_ready_at"]
			caster.skill_ready_at[request["expected_skill_id"]] = details["skill_ready_at"]
		_skill_transaction_pending["phase"] = "effects"
		if prepared.has("commit_units"):
			# 所有派生与最终值均已验证；只写标记过的单位，不暴露临时引用，也不在提交中通知。
			for id: int in prepared["commit_units"]:
				var state: Dictionary = prepared["commit_units"][id]
				if not state["dirty"]:
					continue
				var unit: Unit = units[id]
				if state.has("shield"):
					# 池身份退出后撤销其活动来源资格；仅减少余量保留同一身份，不能重放耗尽盾。
					if unit.shield.get("shield_id") != state["shield"].get("shield_id"):
						_retire_skill_shield(unit.shield)
					unit.shield = state["shield"].duplicate(true)
				unit.hp = state["hp"]
				unit.alive = state["alive"]
				unit.activated = state["activated"]
				unit.engaged_allies = state["engaged_allies"].duplicate(true)
				unit.threat = state["threat"].duplicate(true)
				if not state["alive"]:
					unit.order_kind = state["order_kind"]
					unit.target_id = state["target_id"]
					unit.cast = state["cast"].duplicate(true)
					unit.statuses = state["statuses"].duplicate(true)
			death_notices = prepared["death_notices"].duplicate(true)
		var hit_ids: Array[int] = []
		for effect: Dictionary in details["effects"]:
			if player_controls and effect["effect_kind"] == "MAGIC_DAMAGE":
				_record_player_damage(caster, float(effect["actual_amount"]))
				hit_ids.append(effect["target_id"])
			if effect["effect_kind"] == "RESTORE_MANA":
				caster.res = effect["mana_after"]
			effect["cast_id"] = cast_id
			effect["skill_id"] = request["expected_skill_id"]
		if player_controls and not automatic:
			_finish_player_attack(caster, prepared["target_id"], prepared["impact"], hit_ids)
		# 仅新建/替换盾登记已成功的真实施法身份；复用去重项，不新增事件或取证集合。
		if prepared.get("shield_issued", false):
			var issued: Dictionary = details["effects"][0]["shield_after"]
			_skill_seen_requests[request["request_seq"]] = {"shield_id": issued["shield_id"], "source_id": caster.id, "target_id": caster.id, "expires_at": issued["expires_at"], "capacity": issued["remaining"]}
		resolved["details"] = details.duplicate(true)
	# 成功与普通拒绝均只发一次；复制隔离订阅者与返回值，不泄露Unit/配置引用。
	_skill_transaction_pending["phase"] = "publish"
	events.fire(&"cast_resolved", [resolved.duplicate(true)])
	if resolved["accepted"] and skill_battle_id == battle_id and _skill_schedule_active:
		for effect: Dictionary in resolved["details"]["effects"]:
			if effect["effect_kind"] in ["MAGIC_DAMAGE", "HEAL"]:
				_show_health_effect(units[effect["source_id"]], units[effect["target_id"]],
					float(effect["actual_amount"]), effect["effect_kind"] == "HEAL", false, not flight.is_empty())
	# 暂停不撤销已提交的死亡事实；只有实际离场/换场才停止旧通知，不能按暂停队列代次误丢通知。
	for notice: Dictionary in death_notices:
		if not _skill_schedule_active or skill_battle_id != battle_id:
			break
		events.fire(notice["event"], notice["args"].duplicate(true))
	# 结果和死亡回调均可能换场/暂停；胜负不能作用于新场或越过暂停的批次边界。
	if _skill_point_current(battle_id, queue_epoch):
		_check_end()
	# 结束通知也可能回调，整条调用链正常返回前保持重入保护。
	_skill_transaction_pending = {}
	return resolved


## 严重错误保留上下文并清盾及关系、停场；不捕获/回滚异常，不补发成功或递归结束事件。
func _abort_skill_validation(context: Dictionary) -> void:
	if not _skill_validation_error.is_empty():
		return
	_clear_player_casts()
	if _skill_requires_rebuild:
		_clear_skill_engagements()
		_clear_skill_shields()
	_skill_validation_error = context.duplicate(true)
	_skill_transactions_enabled = false
	skill_input_locked = true
	finished = true
	result = "error"
	reason = "skill_validation_error"
	_skill_queue_epoch += 1
	_skill_pending.clear()
	_skill_accumulator = 0.0
	printerr("SKILL_VALIDATION_ERROR " + JSON.stringify(_skill_validation_error))


## 关闭事务并还原恢复速度；完整场清盾和关系但保留须重建标记，绝不解禁旧路径。
func _disable_skill_transactions() -> void:
	if _skill_requires_rebuild:
		_clear_skill_engagements()
		_clear_skill_shields()
	_skill_full_numeric = false
	_skill_resolution_scope = "S2_2_UNSHIELDED"
	_skill_transactions_enabled = false
	for id: int in _ids:
		var unit: Unit = units.get(id)
		if unit == null:
			continue
		if _skill_previous_regen.has(id):
			unit.res_regen = _skill_previous_regen[id]
		unit.combat_stats = {}
	_skill_previous_regen.clear()


## 全字段数值校验及公式派生，纯查询；防护只在安装成功后映射至Unit的既有字段。
func _full_skill_parameters(unit: Unit, supplied: Variant) -> Dictionary:
	var problems := PackedStringArray()
	if not supplied is Dictionary:
		return {"problems": PackedStringArray(["unit[%d].stats: 必须为完整字典" % unit.id])}
	var fields: Array[String] = ["armor", "magic_resistance", "evasion_rating", "damage_reduction"]
	if unit.side == "ally":
		if unit.kind not in ["mage", "priest"]:
			problems.append("unit[%d].kind: 完整场友方只支持法师/牧师" % unit.id)
		fields.append_array(["intellect", "spirit", "equipment_power", "temporary_power", "power_bonus", "precision_rating", "critical_rating", "haste_rating", "mastery_rating", "penetration_rating", "damage_bonus", "healing_bonus", "shield_bonus", "critical_bonus"])
	elif unit.side != "enemy":
		problems.append("unit[%d].side: 非法阵营" % unit.id)
	var stats: Dictionary = {}
	for field: String in fields:
		var raw: Variant = supplied.get(field)
		if not (raw is int or raw is float) or not is_finite(float(raw)):
			problems.append("unit[%d].%s: 缺失、错型或非有限" % [unit.id, field])
			continue
		var value := float(raw)
		# 只有显式增量和临时强度可负；伤害净修正/暴伤/减伤在派生时按原稿限幅。
		if field != "temporary_power" and not field.ends_with("_bonus") and value < 0.0:
			problems.append("unit[%d].%s: 不允许负数" % [unit.id, field])
		stats[field] = value
	for field: Variant in supplied:
		if not field is String or field not in fields:
			problems.append("unit[%d].stats: 多余或非字符串字段%s" % [unit.id, str(field)])
	if not problems.is_empty():
		return {"problems": problems}
	var derived := {"damage_taken_multiplier": 1.0 - clampf(stats["damage_reduction"], 0.0, 0.60)}
	if unit.side == "ally":
		# 已有效的智力/精神只代入一次职业P，不重复做等级装备来源映射。
		var primary := 2.0 * float(stats["intellect"]) + 0.5 * float(stats["spirit"]) if unit.kind == "mage" else 2.0 * float(stats["spirit"]) + 0.5 * float(stats["intellect"])
		var raw_power := 20.0 + float(stats["equipment_power"]) + float(stats["temporary_power"]) + primary
		var power_multiplier := maxf(0.0, 1.0 + float(stats["power_bonus"]))
		var power := maxf(0.0, raw_power) * power_multiplier
		var critical := 0.05 + 0.45 * float(stats["critical_rating"]) / (float(stats["critical_rating"]) + 1000.0)
		var extra_critical := clampf(0.50 + float(stats["critical_bonus"]), 0.0, 1.50)
		var haste := 0.30 * float(stats["haste_rating"]) / (float(stats["haste_rating"]) + 1000.0)
		var mastery := 0.45 * float(stats["mastery_rating"]) / (float(stats["mastery_rating"]) + 1000.0)
		var penetration := 0.35 * float(stats["penetration_rating"]) / (float(stats["penetration_rating"]) + 1000.0)
		var spirit := float(stats["spirit"])
		var base_regen := 3.0 + 0.035 * spirit if unit.kind == "mage" else 3.0 + 0.035 * minf(spirit, 150.0) + 0.003 * maxf(spirit - 150.0, 0.0)
		derived.merge({"power": power, "critical": critical, "critical_multiplier": 1.0 + critical * extra_critical,
			"haste": haste, "gcd": maxf(0.75, 1.0 / (1.0 + haste)), "mastery": mastery, "penetration": penetration,
			"regen": base_regen * (1.0 + 0.50 * haste), "damage_multiplier": 1.0 + maxf(-0.60, stats["damage_bonus"]),
			"healing_multiplier": maxf(0.0, 1.0 + float(stats["healing_bonus"])), "shield_multiplier": maxf(0.0, 1.0 + float(stats["shield_bonus"]))})
		# 限幅不能掩盖中间溢出；例如正负极值相消或乘零不能把无效P变成合法零。
		for value: float in [primary, raw_power, power_multiplier, base_regen]:
			if not is_finite(value):
				problems.append("unit[%d].derived: P或恢复中间值溢出" % unit.id)
	for field: String in derived:
		if not is_finite(float(derived[field])) or float(derived[field]) < 0.0:
			problems.append("unit[%d].derived.%s: 非有限或负派生量" % [unit.id, field])
	return {"problems": problems, "stats": stats, "derived": derived}.merged(derived)


## 原子安装完整属性、关系与初始盾；首次建场全量验证，任何失败不写状态或诊断。
func _install_full_skill_stats(stats_by_unit: Dictionary, engagements: Dictionary, resolution_scope: String = "S2_2_UNSHIELDED", initial_shields_by_unit: Dictionary = {}) -> PackedStringArray:
	var problems := PackedStringArray()
	if not _skill_schedule_active or _skill_tick != 0 or _skill_receive_seq != 0 or not _skill_pending.is_empty() or _skill_advancing or _skill_transactions_enabled or _skill_requires_rebuild or finished or paused:
		problems.append("full.enable: 仅首步及入队前显式安装一次")
	if resolution_scope not in ["S2_2_UNSHIELDED", "S2_3_SHIELD_AWARE"] or (resolution_scope != "S2_3_SHIELD_AWARE" and not initial_shields_by_unit.is_empty()):
		problems.append("full.scope: 非法模式或初始盾")
	var initial := _prepare_initial_skill_shields(initial_shields_by_unit)
	problems.append_array(initial["problems"])
	var prepared: Dictionary = {}
	for id: int in _ids:
		var unit: Unit = units[id]
		if not unit.shield.is_empty():
			problems.append("full.shield: 首次安装前不能已有未授权盾")
		var checked := _full_skill_parameters(unit, stats_by_unit.get(id))
		problems.append_array(checked["problems"])
		prepared[id] = checked
		if not is_finite(unit.hp) or not is_finite(unit.max_hp) or unit.max_hp < 1.0 or unit.hp < 0.0 or unit.hp > unit.max_hp or unit.alive != (unit.hp > 0.0):
			problems.append("unit[%d].hp/max_hp/alive: 非法单一生命状态" % id)
		if unit.side == "ally" and (not is_finite(unit.res) or unit.res_max != 100.0 or unit.res < 0.0 or unit.res > unit.res_max):
			problems.append("unit[%d].res: 非法初始法力" % id)
	for id: Variant in stats_by_unit:
		if not id is int or id not in _ids:
			problems.append("stats[%s]: 非本场整数ID" % str(id))
	var prepared_relations: Dictionary = {}
	for id: int in _ids:
		var enemy: Unit = units[id]
		if enemy.side != "enemy":
			continue
		var supplied: Variant = engagements.get(id)
		if not supplied is Dictionary or supplied.size() != 2 or not supplied.get("activated") is bool or not supplied.get("engaged_allies") is Dictionary:
			problems.append("enemy[%d].relations: 必须显式提供activated和engaged_allies集合" % id)
			continue
		var relation: Dictionary = supplied["engaged_allies"]
		if (not supplied["activated"] or not enemy.alive) and not relation.is_empty():
			problems.append("enemy[%d].relations: 未激活或死亡的敌人集合必须为空" % id)
		if not enemy.alive and supplied["activated"]:
			problems.append("enemy[%d].activated: 死亡敌人不得激活" % id)
		for ally_id: Variant in relation:
			var ally: Unit = units.get(ally_id) if ally_id is int else null
			if ally == null or ally.side != "ally" or not ally.alive or not relation[ally_id] is bool or relation[ally_id] != true:
				problems.append("enemy[%d].engaged_allies[%s]: 必须为存活同场友方整数ID且值为true" % [id, str(ally_id)])
		prepared_relations[id] = supplied.duplicate(true)
	for id: Variant in engagements:
		if not id is int or id not in prepared_relations:
			problems.append("relations[%s]: 非本场敌方整数ID" % str(id))
	if not problems.is_empty():
		return problems
	# 只在全部校验及派生成功后提交；防护仅存在Unit，评级副本不会成为第二份防护。
	for id: int in prepared:
		var unit: Unit = units[id]
		var stats: Dictionary = prepared[id]["stats"].duplicate(true)
		unit.armor = stats["armor"]
		unit.magic_resist = stats["magic_resistance"]
		stats.erase("armor")
		stats.erase("magic_resistance")
		unit.combat_stats = stats
		unit.shield = initial["shields"].get(id, {}).duplicate(true)
		if not unit.shield.is_empty():
			# 复用本场请求所有权表的独立字符串键，不消费整数请求号，也不新增永久取证集合。
			_skill_seen_requests[unit.shield["source_cast_id"]] = {"shield_id": unit.shield["shield_id"], "source_id": unit.shield["source_id"], "target_id": id, "expires_at": unit.shield["expires_at"], "capacity": unit.shield["remaining"]}
		if unit.side == "ally":
			_skill_previous_regen[id] = unit.res_regen
			unit.res_regen = prepared[id]["regen"]
		else:
			unit.activated = prepared_relations[id]["activated"]
			unit.engaged_allies = prepared_relations[id]["engaged_allies"]
	_skill_resolution_scope = resolution_scope
	_skill_full_numeric = true
	_skill_requires_rebuild = true
	_skill_transactions_enabled = true
	return problems


## 正式数值场与真人场共用权威交战快照，仅按存活、激活和关联筛选。
func _skill_engaged_enemies(ally_id: int) -> Array[int]:
	var ids: Array[int] = []
	var ally: Unit = units.get(ally_id)
	if (not _skill_full_numeric and not player_controls) or ally == null or ally.side != "ally" or not ally.alive:
		return ids
	for id: int in _ids:
		var enemy: Unit = units[id]
		if enemy.side == "enemy" and enemy.alive and enemy.activated and enemy.engaged_allies.has(ally_id):
			ids.append(id)
	ids.sort()
	return ids


## 只清理既有关系；S2-1不建立接敌。指定死亡者时精确移除，全场收尾时清空激活/关系/仇恨。
func _clear_skill_engagements(unit_id: int = -1) -> void:
	for id: int in _ids:
		var enemy: Unit = units.get(id)
		# 查无来源时仍须完成停场清理，跳过已离场实体而不是解引用空值。
		if enemy == null or enemy.side != "enemy":
			continue
		if unit_id < 0 or unit_id == id:
			enemy.activated = false
			enemy.engaged_allies.clear()
			enemy.threat.clear()
		else:
			enemy.engaged_allies.erase(unit_id)
			enemy.threat.erase(unit_id)


## 明确停用仅对当前完整场敌人有效；清该敌人关系及仇恨，不推断其他敌人的脱战。
func _deactivate_skill_enemy(enemy_id: int) -> bool:
	var enemy: Unit = units.get(enemy_id)
	if not _skill_full_numeric or enemy == null or enemy.side != "enemy":
		return false
	enemy.activated = false
	enemy.engaged_allies.clear()
	enemy.threat.clear()
	return true


## 初始盾只接受三字段；和属性/关系一起准备，身份仅由本场已验证的来源与目标生成。
func _prepare_initial_skill_shields(supplied: Dictionary) -> Dictionary:
	var problems := PackedStringArray()
	var shields: Dictionary = {}
	for target_id: Variant in supplied:
		var target: Unit = units.get(target_id) if target_id is int and target_id in _ids else null
		var entry: Variant = supplied[target_id]
		if target == null or target.id != target_id or not target.alive or not entry is Dictionary:
			problems.append("initial_shield.target: 必须为本场存活整数ID及字典")
			continue
		if entry.size() != 3 or not entry.get("source_id") is int or not (entry.get("remaining") is float or entry.get("remaining") is int) or not (entry.get("expires_at") is float or entry.get("expires_at") is int):
			problems.append("initial_shield.fields: 仅source_id/remaining/expires_at且拒绝bool")
			continue
		var source: Unit = units.get(entry["source_id"]) if entry["source_id"] in _ids else null
		var remaining := float(entry["remaining"])
		var expires_at := float(entry["expires_at"])
		if source == null or source.id != entry["source_id"] or source.side != target.side or not is_finite(remaining) or remaining <= 0.0 or not is_finite(expires_at) or expires_at <= time:
			problems.append("initial_shield.source/amount/deadline: 来源同阵营且在场，正量及未来截止")
			continue
		# 初始化命名空间不属于真实cast_id；不消耗请求号、不宣称施法或产生成本事件。
		var identity := "%s:initial:%d:%d" % [skill_battle_id, source.id, target.id]
		shields[target.id] = {"shield_id": identity + ":shield", "source_cast_id": identity, "source_id": source.id, "remaining": remaining, "expires_at": expires_at}
	return {"problems": problems, "shields": shields}


## 只读校验五字段及本场来源；死亡仍在场有效，真实盾还须对应已提交的请求所有权。
func _skill_shield_problems(target: Unit) -> PackedStringArray:
	var shield := target.shield
	if shield.is_empty():
		return PackedStringArray()
	if _skill_resolution_scope != "S2_3_SHIELD_AWARE" or not target.alive or shield.size() != 5 or not shield.get("shield_id") is String or not shield.get("source_cast_id") is String or not shield.get("source_id") is int or not shield.get("remaining") is float or not shield.get("expires_at") is float:
		return PackedStringArray(["unit[%d].shield: 非盾scope/死亡目标或非法五字段" % target.id])
	var source: Unit = units.get(shield["source_id"]) if shield["source_id"] in _ids else null
	if source == null or source.id != shield["source_id"] or source.side != target.side or not is_finite(shield["remaining"]) or shield["remaining"] <= 0.0 or not is_finite(shield["expires_at"]) or shield["expires_at"] < 0.0:
		return PackedStringArray(["unit[%d].shield: 来源不在场/阵营错或非法量" % target.id])
	var initial := "%s:initial:%d:%d" % [skill_battle_id, source.id, target.id]
	if shield["source_cast_id"] == initial and shield["shield_id"] == initial + ":shield":
		var installed: Variant = _skill_seen_requests.get(initial)
		if installed is Dictionary and installed.get("shield_id") == shield["shield_id"] and installed.get("source_id") == source.id and installed.get("target_id") == target.id and installed.get("expires_at") == shield["expires_at"] and shield["remaining"] <= installed.get("capacity", 0.0):
			return PackedStringArray()
		return PackedStringArray(["shield.identity: 查无本场原子安装的初始盾"])

	var prefix := skill_battle_id + ":"
	var suffix: String = shield["source_cast_id"].trim_prefix(prefix)
	if not shield["source_cast_id"].begins_with(prefix) or not suffix.is_valid_int() or suffix != str(suffix.to_int()) or suffix.to_int() < 0:
		return PackedStringArray(["shield.identity: 非本场合法真实施法身份"])
	var issued: Variant = _skill_seen_requests.get(suffix.to_int())
	# 去重项只有统一提交成功新盾后才转为此所有权记录；已见/失败/预检请求的true绝非施法证明。
	if not issued is Dictionary or issued.get("source_id") != source.id or issued.get("target_id") != target.id or issued.get("shield_id") != shield["shield_id"] or shield["shield_id"] != "%s:shield:0:%d" % [shield["source_cast_id"], target.id] or issued.get("expires_at") != shield["expires_at"] or shield["remaining"] > issued.get("capacity", 0.0):
		return PackedStringArray(["shield.identity: 查无对应成功施法或盾来源/目标/截止不一致"])
	return PackedStringArray()


## 屏障只在工作副本计算；净增取真实池差且不反向重建总量，公共生命字段保持不变。
func _prepare_barrier_transaction(prepared: Dictionary, staged: Dictionary, derived: Dictionary) -> Dictionary:
	var caster: Unit = units[prepared["caster_id"]]
	var skill: Dictionary = prepared["skill"]
	var base: float = 1.50 * float(derived["power"])
	var amount: float = base * float(derived["shield_multiplier"])
	var expires_at := time + 6.0
	var mana_after := caster.res - float(skill["mana_cost"])
	var gcd_ready: float = time + float(derived["gcd"])
	var skill_ready: float = time + float(skill["cooldown_s"])
	for number: float in [base, amount, expires_at, mana_after, gcd_ready, skill_ready]:
		if not is_finite(number) or number < 0.0:
			return {"preparable": false, "reason": "CONFIG_ERROR", "problems": PackedStringArray(["shield.final: 非有限中间量或截止"])}
	if base > 0.0 and float(derived["shield_multiplier"]) > 0.0 and amount == 0.0:
		return {"preparable": false, "reason": "CONFIG_ERROR", "problems": PackedStringArray(["shield.amount: 正生成量运算下溢"])}
	if expires_at <= time:
		return {"preparable": false, "reason": "CONFIG_ERROR", "problems": PackedStringArray(["shield.deadline: 正持续时间不可表达"])}
	var before: Dictionary = staged[caster.id]["shield"].duplicate(true)
	var old_amount := float(before.get("remaining", 0.0))
	var action := "zero"
	var actual := 0.0
	var changes: Array[Dictionary] = []
	if amount > 0.0:
		action = "retained"
		if amount > old_amount:
			action = "created" if before.is_empty() else "replaced"
			actual = amount - old_amount
			# 严格更大的新池才安装；净增须有限且可表达，不以旧池加净增的逆运算逐位相等作门禁。
			if not is_finite(actual) or actual <= 0.0 or actual > amount:
				return {"preparable": false, "reason": "CONFIG_ERROR", "problems": PackedStringArray(["shield.gain: 净增加不可表达或越池容量"])}
			var cast_id := skill_battle_id + ":" + str(prepared["request_seq"])
			staged[caster.id]["shield"] = {"shield_id": "%s:shield:0:%d" % [cast_id, caster.id], "source_cast_id": cast_id, "source_id": caster.id, "remaining": amount, "expires_at": expires_at}
			staged[caster.id]["dirty"] = true
			prepared["shield_issued"] = true
			if not before.is_empty():
				changes.append({"target_id": caster.id, "reason": "replaced", "before": before.duplicate(true), "after": staged[caster.id]["shield"].duplicate(true)})
	var effect := {"effect_index": 0, "target_index": 0, "source_id": caster.id, "target_id": caster.id, "effect_kind": "SHIELD", "requested_amount": amount, "actual_amount": actual, "hp_before": caster.hp, "hp_after": caster.hp, "shield_action": action, "shield_before": before, "shield_after": staged[caster.id]["shield"].duplicate(true)}
	prepared["details"] = {"executed_at": time, "mana_before": caster.res, "mana_cost": float(skill["mana_cost"]), "mana_after": mana_after, "gcd_ready_at": gcd_ready, "skill_ready_at": skill_ready, "resolution_scope": _skill_resolution_scope, "defeated_ids": [], "effects": [effect], "shield_changes": changes}
	prepared["commit_units"] = staged
	prepared["death_notices"] = []
	return prepared.duplicate(true)


## 伤害事务和正式普通命中共用盾池分配。生命预算扣名义吸收，实吸收取真实池差。
func _skill_absorb_damage(shield: Dictionary, requested: float) -> Dictionary:
	var before := float(shield.get("remaining", 0.0))
	var intended := minf(before, requested)
	var remaining := maxf(0.0, before - intended)
	return {"remaining": remaining, "intended": intended, "absorbed": before - remaining, "hp_budget": requested - intended}


## 主动与自动治疗共用仇恨比例；传入受疗者的存活交战敌人数，空集不产生仇恨。
func _skill_heal_threat_share(actual: float, enemy_count: int) -> float:
	return actual * 0.20 / float(enemy_count) if enemy_count > 0 else 0.0


## 两条推进路径都在输入和攻击前移除到期盾，不另造伤害或吸收通知。
func _expire_skill_shields() -> void:
	for id: int in _ids:
		var unit: Unit = units[id]
		if not unit.shield.is_empty() and not _skill_deadline_pending(unit.shield["expires_at"]):
			_retire_skill_shield(unit.shield)
			unit.shield = {}


## 结束、离场和严重错误清全部池；不把施法外移除伪造成吸收/耗尽或新增取证日志。
func _clear_skill_shields() -> void:
	for unit: Unit in units.values():
		_retire_skill_shield(unit.shield)
		unit.shield = {}


## 池退出时撤销活动来源记录；真实请求保留去重墓碑，初始身份删除，不累计耗尽日志。
func _retire_skill_shield(shield: Dictionary) -> void:
	if not shield.get("source_cast_id") is String or not shield.get("shield_id") is String:
		return
	var cast_id: String = shield["source_cast_id"]
	var key: Variant = cast_id
	if not _skill_seen_requests.has(key):
		var suffix := cast_id.trim_prefix(skill_battle_id + ":")
		if not suffix.is_valid_int() or suffix != str(suffix.to_int()) or suffix.to_int() < 0:
			return
		key = suffix.to_int()
	var issued: Variant = _skill_seen_requests.get(key)
	if issued is Dictionary and issued.get("shield_id") == shield["shield_id"]:
		if key is int:
			_skill_seen_requests[key] = true
		else:
			_skill_seen_requests.erase(key)
