extends RefCounted
## 酒馆输入控制器：把「已经没被界面接住」的点击、右键、Esc 翻译成逻辑层命令。
## 界面优先级（场景加载遮罩 → 弹窗 → 功能面板 → 常驻栏 → 场景对象 → 地面）里，
## 前面几层由场景脚本先处理；到这里只剩「对象 → 地面」两层。一次点击只做一件事。
## 酒馆里数字键 1～4 和 Q/W/E/R 不执行任何战斗动作，这里也就没有对应入口。

const TavernSim := preload("res://scripts/tavern/tavern_sim.gd")

var sim: TavernSim


func setup(tavern_sim: TavernSim) -> void:
	sim = tavern_sim


## 左键。面板打开时场景不处理（由逻辑层拒绝并记日志）；点队长自己什么都不做；先判对象再判地面。
func on_left_click(pos: Vector2) -> Dictionary:
	if sim.panel != "":
		return sim.click_ground(pos)
	if sim.captain_at(pos):
		return {"ok": true, "reason": "", "ignored": true}
	var object_id := sim.object_at(pos)
	if object_id != "":
		return sim.click_object(object_id)
	return sim.click_ground(pos)


func on_right_click() -> Dictionary:
	return sim.right_click()


## Esc 一次只处理一层。
func on_escape() -> bool:
	return sim.escape()


func on_focus_lost() -> void:
	sim.focus_lost()


func on_hover(pos: Vector2) -> void:
	sim.set_hover(pos)
