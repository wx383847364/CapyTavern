extends Resource
## 五技能有序效果的静态源；缺失数值用 NAN 标记，不能被合法的零值掩盖。

@export var kind: String = ""
@export var selector: String = ""
@export var power_coeff: float = NAN
@export var flat_amount: float = NAN
@export var radius_m: float = NAN
@export var duration_s: float = NAN
# 布尔默认值本身不能表达“未填写”，加载显式字段时记录存在性。
var stable_crit_declared: bool = false
var mastery_declared: bool = false
@export var uses_stable_crit: bool = false:
	# 记录显式赋值，确保遗漏 false 字段也会被配置校验拦截。
	set(value):
		uses_stable_crit = value
		stable_crit_declared = true
@export var uses_mastery: bool = false:
	# 记录显式赋值；这是配置存在性信息，不是运行时专精状态。
	set(value):
		uses_mastery = value
		mastery_declared = true
