extends RefCounted
## 把酒馆的场景交互、点地移动和方向输入交给逻辑层，面板优先消费输入。

const TavernSim := preload("res://scripts/tavern/tavern_sim.gd")
const MovementInput := preload("res://scripts/input/movement_input.gd")

var sim: TavernSim
var movement := MovementInput.new()


## 每次绑定时丢弃从上一场按住的方向。
func setup(tavern_sim: TavernSim) -> void:
	sim = tavern_sim
	movement.interrupt()


## 左键仅响应可点击物件；队长本体和普通地面不改变当前命令。
func on_left_click(pos: Vector2, visible_captain_hit: Variant = null) -> Dictionary:
	if sim.panel != "":
		return {"ok": false, "reason": "panel_open"}
	var captain_hit := sim.captain_at(pos) if visible_captain_hit == null else bool(visible_captain_hit)
	var object_id := "" if captain_hit else sim.object_at(pos)
	if object_id.is_empty():
		return {"ok": true, "reason": "", "ignored": true}
	var result := sim.click_object(object_id)
	if result.get("ok", false):
		movement.interrupt()
	return result


## 右键只提交地面命令，失效落点不抢占当前移动。
func on_right_click(pos: Vector2) -> Dictionary:
	var result := sim.click_ground(pos)
	if result.get("ok", false):
		movement.interrupt()
	return result


## 将方向交给模拟步；面板、加载或无队长时等待重新输入。
func update_direction(enabled: bool) -> void:
	if enabled:
		sim.set_move_direction(movement.poll())
	else:
		movement.interrupt()
		sim.set_move_direction(Vector2.ZERO)


## Esc 一次只处理一层。
func on_escape() -> bool:
	return sim.escape()


## 失焦停止本次移动，直到按钮释放才能重新接管。
func on_focus_lost() -> void:
	movement.interrupt()
	sim.focus_lost()


## 悬停仅更新交互高亮。
func on_hover(pos: Vector2) -> void:
	sim.set_hover(pos)
