extends Resource
## 五技能有序效果的静态源；缺失数值用 NAN 标记，不能被合法的零值掩盖。

@export var kind: String = ""
@export var selector: String = ""
@export var power_coeff: float = NAN
@export var flat_amount: float = NAN
@export var radius_m: float = NAN
@export var duration_s: float = NAN
# 二进制导出会省略与脚本默认值相同的属性。使用空哨兵同时保留显式 true 和 false，
# 由目录校验确保运行参数只能是布尔值，漏填的资源不会悄悄回落为关闭。
@export_storage var uses_stable_crit: Variant = null
@export_storage var uses_mastery: Variant = null
