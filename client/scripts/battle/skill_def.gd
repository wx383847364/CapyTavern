extends Resource
## 五技能唯一静态配置源；加载后只读，角色使用独立的派生字典副本。

# 使用脚本类型约束有序效果，无需注册全局类或依赖编辑器类缓存。
const SkillEffectDef := preload("res://scripts/battle/skill_effect_def.gd")

@export var skill_id: String = ""
@export var spec_id: String = ""
@export var name: String = ""
var icon_declared: bool = false
@export var icon: Texture2D = null:
	# null 是合法占位图，但必须由源文件显式声明，避免漏字段被默认值掩盖。
	set(value):
		icon = value
		icon_declared = true
@export var target_kind: String = ""
@export var cast_range_m: float = NAN
@export var mana_cost: float = NAN
@export var cooldown_s: float = NAN
## 场上 AI 的可选策略，空配置由玩家手动施放。
@export var auto_use: Dictionary = {}
@export var effects: Array[SkillEffectDef] = []
