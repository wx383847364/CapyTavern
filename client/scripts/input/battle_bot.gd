extends RefCounted
## 自动操作员：只通过 BattleController 发和玩家一样的命令，用来在无人值守时打完一场。
## 导出包 `-- --battle=N --autoplay` 和自检脚本都用它。它不改结算，也不绕过校验。

const BattleSim := preload("res://scripts/battle/battle_sim.gd")
const BattleController := preload("res://scripts/input/battle_controller.gd")

const THINK_INTERVAL := 0.3

var sim: BattleSim
var controller: BattleController
## 为 true 时只选人、不下别的命令，用来造「失败」场景
var passive: bool = false
var _next_think: float = 0.0


func setup(battle_sim: BattleSim, battle_controller: BattleController) -> void:
	sim = battle_sim
	controller = battle_controller


func tick() -> void:
	if sim.finished or sim.paused or sim.time < _next_think:
		return
	_next_think = sim.time + THINK_INTERVAL
	if passive:
		return
	var previous := controller.selected_slot
	for slot_index in BattleSim.SLOT_COUNT:
		var unit := sim.slot_unit(slot_index)
		if unit == null or not unit.alive:
			continue
		controller.select_slot(slot_index)
		if _dodge(unit):
			continue
		if unit.attack_kind == "heal":
			_play_healer(unit)
		else:
			_play_fighter(unit)
	controller.select_slot(previous)


## 站在震地预警圈里就往外走。
func _dodge(unit: BattleSim.Unit) -> bool:
	for enemy in sim.living("enemy"):
		if enemy.cast.is_empty():
			continue
		var radius: float = enemy.cast["radius"]
		if radius <= 0.0:
			continue
		var center: Vector2 = enemy.cast["center"]
		if unit.pos.distance_to(center) > radius + unit.radius + 15.0:
			continue
		var away := unit.pos - center
		if away.length() < 1.0:
			away = Vector2.LEFT
		sim.order_move(unit.id, center + away.normalized() * (radius + unit.radius + 60.0))
		return true
	return false


func _play_healer(unit: BattleSim.Unit) -> void:
	var hurt: Array[BattleSim.Unit] = []
	for ally in sim.living("ally"):
		if float(ally.hp) / float(ally.max_hp) < 0.85:
			hurt.append(ally)
	if not hurt.is_empty():
		var lowest := hurt[0]
		for candidate in hurt:
			if float(candidate.hp) / float(candidate.max_hp) < float(lowest.hp) / float(lowest.max_hp):
				lowest = candidate
		if unit.order_kind != "heal" or unit.target_id != lowest.id:
			controller.on_right_click(lowest.pos)
		var ratio := float(lowest.hp) / float(lowest.max_hp)
		if ratio < 0.55 and _ready(unit, "q"):
			controller.press_skill("q")
			return
		var wounded := 0
		for candidate in hurt:
			if float(candidate.hp) / float(candidate.max_hp) < 0.75 and candidate.pos.distance_to(unit.pos) <= 300.0:
				wounded += 1
		if wounded >= 2 and _ready(unit, "w"):
			controller.press_skill("w")
			return
	if unit.res < 25.0 and _ready(unit, "r"):
		controller.press_skill("r")


func _play_fighter(unit: BattleSim.Unit) -> void:
	var enemies := sim.living("enemy")
	if enemies.is_empty():
		return
	var target := _pick_target(unit, enemies)
	if unit.order_kind != "attack" or unit.target_id != target.id:
		controller.on_right_click(target.pos)
	for key in BattleSim.SKILL_KEYS:
		if not _ready(unit, key):
			continue
		if _wants(unit, key, target, enemies):
			controller.press_skill(key)
			return


func _pick_target(unit: BattleSim.Unit, enemies: Array[BattleSim.Unit]) -> BattleSim.Unit:
	if unit.kind == "rogue":
		for enemy in enemies:
			if enemy.kind == "caster":
				return enemy
	var best := enemies[0]
	for enemy in enemies:
		if unit.kind == "mage":
			if enemy.hp < best.hp:
				best = enemy
		elif enemy.pos.distance_to(unit.pos) < best.pos.distance_to(unit.pos):
			best = enemy
	return best


func _wants(unit: BattleSim.Unit, key: String, target: BattleSim.Unit, enemies: Array[BattleSim.Unit]) -> bool:
	var hp_ratio := float(unit.hp) / float(unit.max_hp)
	match unit.kind + ":" + key:
		"warrior:e":
			var near := 0
			for enemy in enemies:
				if enemy.pos.distance_to(unit.pos) <= 120.0:
					near += 1
			return near >= 2
		"warrior:r":
			return unit.res < 25.0
		"warrior:w":
			return target.kind == "elite" or target.kind == "melee"
		"rogue:q":
			return not target.cast.is_empty()
		"rogue:e":
			return hp_ratio < 0.5
		"rogue:r":
			return true
		"mage:e":
			return hp_ratio < 0.6
		"mage:r":
			return unit.res < 30.0
	return true


func _ready(unit: BattleSim.Unit, key: String) -> bool:
	return bool(sim.check_cast(unit.id, key)["ok"])
