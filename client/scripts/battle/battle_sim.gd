extends RefCounted
## 战斗结算（逻辑层）。纯数据、固定步长，不依赖场景、动画或帧率。
## 随机只来自 setup 时的种子；所有数值读 BattleConfig（data/balance/ 正式表 + data/battle_layout.json）。
## 结算结果通过 BattleEvents 对外发信号，表现只订阅，不回写这里。

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
	var max_hp: int = 1
	var hp: int = 1
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
	var target_id: int = -1
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
	# 状态：status_id -> {until, source, ...参数}
	var statuses: Dictionary = {}
	# 敌方
	var threat: Dictionary = {}
	var spell: Dictionary = {}
	var cast: Dictionary = {}
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
var _arena: Rect2 = Rect2()


## slots：长度 4，元素是职业 id，空槽用 ""。
func setup(cfg: Dictionary, slots: Array, seed: int, bus: BattleEvents) -> void:
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

	events.fire(&"battle_started", [seed_value, party_size, wave.size()])

	for slot_index in SLOT_COUNT:
		if slot_index >= slots.size() or String(slots[slot_index]) == "":
			continue
		_spawn_ally(slot_index, String(slots[slot_index]))
	for entry: Dictionary in wave:
		_spawn_enemy(entry, float(scaling["hp"]), float(scaling["dmg"]))


func _new_unit() -> Unit:
	var unit := Unit.new()
	unit.id = _next_id
	_next_id += 1
	units[unit.id] = unit
	_ids.append(unit.id)
	return unit


func _spawn_ally(slot_index: int, class_id: String) -> void:
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
	for key in SKILL_KEYS:
		var skill_id: String = class_skills[key]
		var skill: Dictionary = (config["skills"][skill_id] as Dictionary).duplicate(true)
		skill["id"] = skill_id
		unit.skills[key] = skill
	events.fire(&"unit_spawned", [unit.id, "ally", slot_index, class_id, unit.max_hp, unit.pos])


func _spawn_enemy(entry: Dictionary, hp_scale: float, dmg_scale: float) -> void:
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
	events.fire(&"unit_spawned", [unit.id, "enemy", -1, enemy_id, unit.max_hp, unit.pos])


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
	return unit


func order_move(unit_id: int, pos: Vector2) -> bool:
	var unit := _gate(unit_id, "move")
	if unit == null:
		return false
	unit.order_kind = "move"
	unit.order_pos = Vector2(clampf(pos.x, _arena.position.x + unit.radius, _arena.end.x - unit.radius), clampf(pos.y, _arena.position.y + unit.radius, _arena.end.y - unit.radius))
	unit.target_id = -1
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


func set_paused(value: bool) -> void:
	if not finished:
		paused = value


## 不发事件、不改状态的技能检查。返回 {ok, reason, target_id}。
func check_cast(unit_id: int, key: String) -> Dictionary:
	var unit: Unit = units.get(unit_id)
	if unit == null or not unit.alive:
		return {"ok": false, "reason": "unit_down", "target_id": -1}
	if paused:
		return {"ok": false, "reason": "paused", "target_id": -1}
	if not unit.skills.has(key):
		return {"ok": false, "reason": "no_target", "target_id": -1}
	var skill: Dictionary = unit.skills[key]
	if time < float(unit.cd_until.get(key, 0.0)):
		return {"ok": false, "reason": "cooldown", "target_id": -1}
	if not bool(skill.get("off_gcd", false)) and time < unit.gcd_until:
		return {"ok": false, "reason": "gcd", "target_id": -1}
	var target_id := -1
	var skill_range := float(skill["range"])
	match String(skill["target"]):
		"enemy":
			var target := _resolve_enemy_target(unit)
			if target == null:
				return {"ok": false, "reason": "no_target", "target_id": -1}
			if target.pos.distance_to(unit.pos) > skill_range:
				return {"ok": false, "reason": "out_of_range", "target_id": target.id}
			target_id = target.id
		"ally":
			var target := _resolve_ally_target(unit)
			if target == null:
				return {"ok": false, "reason": "no_target", "target_id": -1}
			if target.pos.distance_to(unit.pos) > skill_range:
				return {"ok": false, "reason": "out_of_range", "target_id": target.id}
			target_id = target.id
	if float(skill["cost"]) > unit.res:
		return {"ok": false, "reason": "no_resource", "target_id": target_id}
	return {"ok": true, "reason": "", "target_id": target_id}


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


## 放技能。无效时发 command_rejected，不扣资源、不进冷却。
func cast_skill(unit_id: int, key: String) -> bool:
	var check := check_cast(unit_id, key)
	if not bool(check["ok"]):
		var unit_missing: Unit = units.get(unit_id)
		if unit_missing != null and not finished:
			_reject(unit_id, "skill", String(check["reason"]))
		return false
	var unit: Unit = units[unit_id]
	var skill: Dictionary = unit.skills[key]
	var target_id: int = int(check["target_id"])
	var target: Unit = units.get(target_id)
	var cost := float(skill["cost"])
	if String(skill["target"]) != "self" and target != null:
		unit.target_id = target_id

	events.fire(&"command_issued", [unit_id, "skill", target_id, target.pos if target != null else unit.pos])
	if cost > 0.0:
		_change_resource(unit, -cost)
	unit.cd_until[key] = time + float(skill["cooldown"])
	if not bool(skill.get("off_gcd", false)):
		unit.gcd_until = time + float(config["gcd"])
	events.fire(&"skill_cast", [unit_id, String(skill["id"]), target_id, int(cost), float(unit.cd_until[key])])

	for effect: Dictionary in skill["effects"]:
		_apply_effect(unit, target, String(skill["id"]), effect)
	return true


func _apply_effect(caster: Unit, target: Unit, skill_id: String, effect: Dictionary) -> void:
	match String(effect["kind"]):
		"damage":
			var center := _effect_center(caster, target, String(effect.get("center", "target")))
			var radius := float(effect.get("radius", 0.0))
			var victims: Array[Unit] = []
			if radius > 0.0:
				for enemy in living("enemy"):
					if enemy.pos.distance_to(center) <= radius + enemy.radius:
						victims.append(enemy)
			elif target != null and target.alive:
				victims.append(target)
			for victim in victims:
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
				_apply_status(target, "taunt", caster.id, float(effect["duration"]), {})
		"interrupt":
			if target != null and target.alive and not target.cast.is_empty() and bool((target.cast as Dictionary).get("interruptible", false)):
				target.cast = {}
				target.cast_cd_until = time + float(target.spell.get("cooldown", 0.0))
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

## 加成全算完、减伤之后才四舍五入，最小为 1（口径见 design/balance/README.md）。
func _damage(source: Unit, victim: Unit, base: float, skill_id: String, can_crit: bool, school: String = "physical") -> void:
	if not victim.alive:
		return
	var amount := base
	var is_crit := false
	if can_crit and rng.randf() < float(config.get("crit_chance", 0.0)):
		is_crit = true
		amount *= float(config.get("crit_mult", 1.5))
	amount *= 1.0 - damage_reduction(victim, school)
	amount *= taken_mult(victim)
	var final_amount := maxi(1, roundi(amount))
	victim.hp = maxi(0, victim.hp - final_amount)
	events.fire(&"damage_dealt", [source.id, victim.id, final_amount, skill_id, is_crit, victim.hp])
	if source.side == "ally" and victim.side == "enemy":
		victim.threat[source.id] = float(victim.threat.get(source.id, 0.0)) + float(final_amount) * source.threat_coef
	if victim.hp <= 0:
		_down(victim, source.id)


func _heal(source: Unit, receiver: Unit, base: float, skill_id: String) -> void:
	if not receiver.alive:
		return
	var amount := roundi(base)
	var effective := mini(amount, receiver.max_hp - receiver.hp)
	receiver.hp += effective
	events.fire(&"heal_done", [source.id, receiver.id, amount, effective, skill_id, receiver.hp])
	if effective > 0:
		var threat_gain := float(effective) * float(config.get("heal_threat", 0.5))
		for enemy in living("enemy"):
			enemy.threat[source.id] = float(enemy.threat.get(source.id, 0.0)) + threat_gain


func _down(unit: Unit, by_id: int) -> void:
	unit.alive = false
	unit.hp = 0
	unit.order_kind = "none"
	unit.target_id = -1
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


func _expire_status(unit: Unit, status_id: String) -> void:
	var entry: Dictionary = unit.statuses[status_id]
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

func step(dt: float) -> void:
	if finished or paused:
		return
	time += dt
	events.now = time
	for id in _ids:
		var unit: Unit = units[id]
		for status_id: String in unit.statuses.keys():
			if time >= float((unit.statuses[status_id] as Dictionary)["until"]):
				_expire_status(unit, status_id)
	for id in _ids:
		var unit: Unit = units[id]
		if not unit.alive:
			continue
		if unit.side == "ally":
			_regen(unit, dt)
			_tick_ally(unit, dt)
		else:
			_tick_enemy(unit, dt)
	_separate()
	_check_end()


func _regen(unit: Unit, dt: float) -> void:
	if unit.res_regen <= 0.0 or unit.res >= unit.res_max:
		return
	unit.res = minf(unit.res_max, unit.res + unit.res_regen * dt)
	var value := int(floor(unit.res))
	# 自然回复最多一秒报一次，避免日志被刷满
	if value != unit.res_emit_value and time - unit.res_emit_at >= 1.0:
		unit.res_emit_value = value
		unit.res_emit_at = time
		events.fire(&"resource_changed", [unit.id, unit.res_kind, value, int(unit.res_max)])


func _tick_ally(unit: Unit, dt: float) -> void:
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
	if best != null:
		return best
	return _nearest(unit.pos, "ally")


func _tick_enemy(unit: Unit, dt: float) -> void:
	if not unit.cast.is_empty():
		if time >= float((unit.cast as Dictionary)["ends_at"]):
			_resolve_cast(unit)
		return
	var target := _enemy_target(unit)
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
			var shift := (min_dist - dist) * 0.5
			a.pos -= push * shift
			b.pos += push * shift


func _check_end() -> void:
	if finished:
		return
	if living("enemy").is_empty():
		_finish("win", "all_enemies_down")
	elif living("ally").is_empty():
		_finish("lose", "all_allies_down")
	elif time >= float(config["time_limit"]):
		_finish("lose", "timeout")


func _finish(outcome: String, why: String) -> void:
	finished = true
	result = outcome
	reason = why
	events.fire(&"battle_ended", [outcome, why, time])


## 给表现层读的只读快照。里面全是基本类型，表现层不碰 Unit。
func snapshot() -> Dictionary:
	var unit_list: Array = []
	var skill_map: Dictionary = {}
	for id in _ids:
		var unit: Unit = units[id]
		var cast_view: Dictionary = {}
		if not unit.cast.is_empty():
			var cast_data: Dictionary = unit.cast
			var total := maxf(0.001, float(cast_data["ends_at"]) - float(cast_data["started"]))
			cast_view = {
				"name": cast_data["name"],
				"progress": clampf((time - float(cast_data["started"])) / total, 0.0, 1.0),
				"center": cast_data["center"],
				"radius": cast_data["radius"],
				"interruptible": cast_data["interruptible"],
			}
		unit_list.append({
			"id": unit.id, "side": unit.side, "slot": unit.slot, "kind": unit.kind,
			"name": unit.display_name, "color": unit.color_hex, "radius": unit.radius,
			"pos": unit.pos, "hp": unit.hp, "max_hp": unit.max_hp, "alive": unit.alive,
			"res_kind": unit.res_kind, "res": unit.res, "res_max": unit.res_max,
			"target_id": unit.target_id, "order_kind": unit.order_kind, "order_pos": unit.order_pos,
			"statuses": unit.statuses.keys(), "cast": cast_view, "attack_kind": unit.attack_kind,
		})
		if unit.side == "ally":
			var skill_views: Array = []
			for key in SKILL_KEYS:
				var skill: Dictionary = unit.skills[key]
				var check := check_cast(unit.id, key)
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
	}
