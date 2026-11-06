extends RefCounted
## 进入战斗前的参数。主菜单写，战斗场景读；P4 接出征衔接后改成由出征名单填。
## 只放运行时临时数据，不是存档。

## 长度 4，元素是职业 id，空槽 ""。
static var slots: Array = ["warrior", "", "", ""]
## 随机种子；负数表示每次随机一个，并写进日志。
static var seed: int = -1
## 无人值守：由 BattleBot 通过控制器操作。
static var autoplay: bool = false
## 与 autoplay 一起用：自动操作员什么都不做，用来造「失败」场景。
static var passive: bool = false
## 与 autoplay 一起用：不画帧，直接算完并退出（导出包验证用）。
static var fast: bool = false
## 各职业选的天赋 {class_id: "t1"|"t2"}；缺省或非法回默认 t1。P2b 接存档后由存档填。
static var talents: Dictionary = {}
## 已凑齐两件套的职业 id 列表。P2b 接装备后由穿戴算出。
static var sets: Array = []


## 出征衔接（P4）：从酒馆确认出征进来时为 true；战斗结束写结算并回酒馆。
static var from_tavern: bool = false
## 本场的 run_id（P2b 场次）。
static var run_id: String = ""
## 默认选中的槽位：队长。负数表示选第一名在场成员（旧入口）。
static var captain_slot: int = -1


static func default_slots(count: int) -> Array:
	match count:
		1:
			return ["warrior", "", "", ""]
		2:
			return ["warrior", "", "", "priest"]
		3:
			return ["warrior", "mage", "", "priest"]
	return ["warrior", "rogue", "mage", "priest"]
