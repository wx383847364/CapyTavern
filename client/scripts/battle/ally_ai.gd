extends RefCounted
## 队友策略只读当前战斗状态，返回施法、接近或避让意图，结算仍由模拟器执行。

const SLOTS := ["q", "w", "e", "r"]
const DODGE_MARGIN := 6.0
const DIRECTIONS := 16


## 选存活且可被攻击的单位，失效的持续指令由模拟器按战士、最近敌人的顺序接续。
static func enemy_target(sim: Variant, id: int) -> Variant:
	var unit: Variant = sim.units.get(id)
	return unit if unit != null and unit.alive and unit.selectable and unit.side == "enemy" else null


## 自动动作按当前角色的技能配置选招，寒霜只有寒冰箭允许自动施放。
static func choose_skill(sim: Variant, actor: Variant, target: Variant, allies: Array, enemies: Array) -> Dictionary:
	var cast := {}
	var approach := {}
	var from_resource: bool = sim.formal_skill_sortie and actor.spec_id != "mage.frost"
	var slots: Dictionary = actor.resolved_slots if from_resource else actor.skills
	var scale: float = sim.SCENE_UNITS_PER_METER if from_resource else 1.0
	for slot in SLOTS:
		var skill: Dictionary = slots.get(slot, {})
		var rule: Dictionary = skill.get("auto_use", {})
		if rule.is_empty() or not sim.ai_skill_ready(actor, slot, skill):
			continue
		var kind := String(skill.get("target_kind", skill.get("target", ""))).to_upper()
		var receiver: Variant = actor if kind == "SELF" else target
		if receiver == null or (kind == "ENEMY" and receiver.side != "enemy") or (kind == "ALLY" and receiver.side != "ally"):
			continue
		var priority := _skill_priority(actor, receiver, rule, skill, allies, enemies, scale)
		if priority < 0:
			continue
		var reach: float = sim.ai_skill_range(skill)
		var choice := {"slot": slot, "target_id": int(receiver.id), "reach": reach, "priority": priority}
		if receiver == actor or actor.pos.distance_to(receiver.pos) <= reach:
			if cast.is_empty() or priority < int(cast["priority"]):
				cast = choice
		elif approach.is_empty() or priority < int(approach["priority"]):
			approach = choice
	return {"cast": cast, "approach": approach}


## 阈值与优先级来自技能配置，诸如回蓝条件可被其它技能复用。
static func _skill_priority(actor: Variant, target: Variant, rule: Dictionary, skill: Dictionary, allies: Array, enemies: Array, scale: float) -> int:
	var priority := int(rule["priority"])
	var threshold := float(rule.get("threshold", 0.0))
	match String(rule["condition"]):
		"ready":
			return priority
		"low_resource":
			return priority if actor.res_max > 0.0 and actor.res / actor.res_max < threshold else -1
		"low_hp":
			return priority if target.hp / target.max_hp < threshold else -1
		"unprotected":
			return priority if target.hp / target.max_hp < threshold and not _protected(target, rule["status"]) else -1
		"threatened":
			return priority if target.hp / target.max_hp < threshold and not _protected(target, rule["status"]) and _under_attack(target, enemies) else -1
		"interrupt":
			return priority if target.cast.get("interruptible", false) else -1
		"recover_aggro":
			var victim: int = target.target_id
			if victim != actor.id and target.statuses.get("taunt", {}).get("source") != actor.id:
				for ally: Variant in allies:
					if ally.id == victim:
						return priority
			return -1
		"basic_range":
			return priority if actor.pos.distance_to(target.pos) <= actor.attack_range and not _protected(actor, rule["status"]) else -1
		"damage_area":
			var radius := _area_radius(skill, "damage", scale)
			var count := 0
			for enemy: Variant in enemies:
				if actor.pos.distance_to(enemy.pos) <= radius + enemy.radius:
					count += 1
			if count > 0:
				return int(rule["crowd_priority"]) if count >= 2 else priority
		"heal_area":
			var radius := _area_radius(skill, "heal", scale)
			var count := 0
			for ally: Variant in allies:
				if ally.hp / ally.max_hp < threshold and actor.pos.distance_to(ally.pos) <= radius:
					count += 1
			if count >= int(rule["minimum"]):
				return priority
	return -1


## 护盾用权威盾池，旧版防护与加速读取活动状态。
static func _protected(unit: Variant, status: String) -> bool:
	return not unit.shield.is_empty() if status == "shield" else unit.statuses.has(status)


## 自保和护佑同时关心追击与敌方锁定的技能对象。
static func _under_attack(unit: Variant, enemies: Array) -> bool:
	for enemy: Variant in enemies:
		if enemy.target_id == unit.id or enemy.cast.get("target_id") == unit.id:
			return true
	return false


## 范围条件沿用效果半径；正式资源用米，旧表已经是场景单位。
static func _area_radius(skill: Dictionary, kind: String, scale: float) -> float:
	for effect: Dictionary in skill["effects"]:
		if String(effect["kind"]).to_lower() == kind:
			return float(effect.get("radius_m", effect.get("radius", 0.0))) * scale
	return 0.0


## 先比较危急档内是否能马上治疗，再比较生命比例；普通伤员优先原地施救。
static func heal_target(sim: Variant, actor: Variant, allies: Array) -> Variant:
	var best: Variant
	var rank := 99
	var lowest := INF
	var slots: Dictionary = actor.resolved_slots if sim.formal_skill_sortie else actor.skills
	var ready_heals: Array[Dictionary] = []
	for slot: String in SLOTS:
		var skill: Dictionary = slots.get(slot, {})
		var rule: Dictionary = skill.get("auto_use", {})
		if rule.is_empty() or String(skill.get("target_kind", skill.get("target", ""))).to_upper() != "ALLY":
			continue
		if not sim.ai_skill_ready(actor, slot, skill):
			continue
		for effect: Dictionary in skill["effects"]:
			if String(effect["kind"]).to_lower() == "heal":
				ready_heals.append({"reach": sim.ai_skill_range(skill), "threshold": rule.get("threshold", 1.0)})
				break
	for ally: Variant in allies:
		if not ally.selectable or ally.hp >= ally.max_hp:
			continue
		var ratio: float = ally.hp / ally.max_hp
		var distance: float = actor.pos.distance_to(ally.pos)
		var can_cast := false
		for heal in ready_heals:
			if ratio < float(heal["threshold"]) and distance <= float(heal["reach"]):
				can_cast = true
				break
		var can_basic: bool = distance <= actor.attack_range
		var tier := 4 if can_basic or can_cast else 6
		if ratio < 0.30:
			tier = 0 if can_cast or (can_basic and actor.next_attack_at <= sim.time) else 1
		elif ally.kind == "warrior" and ratio < 0.80:
			tier = 2
		elif ally.id == actor.auto_target_id:
			tier = 3 if can_basic or can_cast else 5
		if tier < rank or (tier == rank and (ratio < lowest or (ratio == lowest and ally.slot < best.slot))):
			rank = tier
			lowest = ratio
			best = ally
	return best


## 圆形读条沿用实际判伤半径；单体读条不产生走位意图。
static func hazards_for(actor: Variant, enemies: Array) -> Array[Vector3]:
	var circles: Array[Vector3] = []
	for enemy: Variant in enemies:
		var radius := float(enemy.cast.get("radius", 0.0))
		if radius > 0.0:
			var center: Vector2 = enemy.cast["center"]
			circles.append(Vector3(center.x, center.y, radius + actor.radius))
	return circles


## 检查整段路径而非终点，安全的 AI 走位不能穿回任意预警。
static func path_enters(start: Vector2, end: Vector2, circles: Array[Vector3]) -> bool:
	for circle in circles:
		var center := Vector2(circle.x, circle.y)
		if Geometry2D.get_closest_point_to_segment(center, start, end).distance_to(center) <= circle.z:
			return true
	return false


## 从最深的预警先尝试径向脱离；受阻后按固定角度找最近合法点。
static func escape_point(origin: Vector2, arena: Rect2, circles: Array[Vector3]) -> Vector2:
	var inside: Array[Vector3] = []
	for circle in circles:
		if origin.distance_to(Vector2(circle.x, circle.y)) <= circle.z:
			inside.append(circle)
	if inside.is_empty():
		return origin
	var deepest: Vector3 = inside[0]
	for circle in inside:
		if origin.distance_to(Vector2(circle.x, circle.y)) - circle.z < origin.distance_to(Vector2(deepest.x, deepest.y)) - deepest.z:
			deepest = circle
	var center := Vector2(deepest.x, deepest.y)
	var away := origin.direction_to(center) * -1.0 if origin != center else Vector2.LEFT
	var direct := _clamp_point(center + away * (deepest.z + DODGE_MARGIN), arena)
	if _clearance(direct, circles) > 0.0 and not _crosses_other(origin, direct, circles, inside):
		return direct
	var best := origin
	var best_dist := INF
	var fallback := origin
	var most_clear := _clearance(origin, circles)
	# 检查每个重叠圆边缘与场地裁剪点，保证同一输入得到同一避让方向。
	for circle in inside:
		var pivot := Vector2(circle.x, circle.y)
		for index in DIRECTIONS:
			var point := _clamp_point(pivot + away.rotated(TAU * index / DIRECTIONS) * (circle.z + DODGE_MARGIN), arena)
			if _crosses_other(origin, point, circles, inside):
				continue
			var clearance := _clearance(point, circles)
			if clearance > 0.0 and origin.distance_squared_to(point) < best_dist:
				best = point
				best_dist = origin.distance_squared_to(point)
			elif clearance > most_clear:
				fallback = point
				most_clear = clearance
	return best if best_dist < INF else fallback


## 原已受影响的圆允许从内向外跨越，其余圆仍阻止走位。
static func _crosses_other(origin: Vector2, point: Vector2, circles: Array[Vector3], inside: Array[Vector3]) -> bool:
	for circle in circles:
		var center := Vector2(circle.x, circle.y)
		if circle not in inside and Geometry2D.get_closest_point_to_segment(center, origin, point).distance_to(center) <= circle.z:
			return true
	return false


## 负数表示最深的重叠量，正数表示与最近预警的边界余量。
static func _clearance(point: Vector2, circles: Array[Vector3]) -> float:
	var clearance := INF
	for circle in circles:
		clearance = minf(clearance, point.distance_to(Vector2(circle.x, circle.y)) - circle.z)
	return clearance


## 输入矩形已经按单位半径向内缩，输出可直接用作走位目标。
static func _clamp_point(point: Vector2, arena: Rect2) -> Vector2:
	return point.clamp(arena.position, arena.end)
