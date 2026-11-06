extends RefCounted
## 战斗输入翻译：把「选人 / 点地 / 右键 / 技能键」变成对模拟器的命令。
## 不画界面、不算伤害；选中只记在这里，不写回存档，也不影响队长。

const BattleSim := preload("res://scripts/battle/battle_sim.gd")
const BattleEvents := preload("res://scripts/battle/battle_events.gd")

var sim: BattleSim
var events: BattleEvents
## 当前选中的槽位 0～3；没有可选成员时为 -1。
var selected_slot: int = -1


## preferred_slot：默认选中的槽位（出征时传队长）；无效就选第一名在场成员。
func setup(battle_sim: BattleSim, bus: BattleEvents, preferred_slot: int = -1) -> void:
	sim = battle_sim
	events = bus
	if preferred_slot >= 0 and sim.slot_unit(preferred_slot) != null:
		selected_slot = preferred_slot
		return
	for slot_index in BattleSim.SLOT_COUNT:
		if sim.slot_unit(slot_index) != null:
			selected_slot = slot_index
			return


func selected_unit() -> BattleSim.Unit:
	return sim.slot_unit(selected_slot) if selected_slot >= 0 else null


## 按 1～4 或点头像。空槽不改变当前选择。
func select_slot(slot_index: int) -> bool:
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
	if sim.finished:
		return
	var ally := sim.unit_at(world_pos, "ally")
	if ally != null:
		select_slot(ally.slot)
		return
	var unit := selected_unit()
	if unit == null:
		return
	sim.order_move(unit.id, world_pos)


## 右键。点敌人攻击；牧师点队友治疗；其他情况不改当前命令。
func on_right_click(world_pos: Vector2) -> void:
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


## Q/W/E/R。只在按下的那一次触发，按住不连发（调用方要过滤 echo）。
func press_skill(key: String) -> bool:
	if sim.finished:
		return false
	var unit := selected_unit()
	if unit == null:
		return false
	return sim.cast_skill(unit.id, key)


func toggle_pause() -> void:
	sim.set_paused(not sim.paused)
