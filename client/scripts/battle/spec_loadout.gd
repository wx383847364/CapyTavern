extends Resource
## 专精四槽顺序固定为 Q/W/E/R；空字符串对应规格 JSON 的 null 空槽。

@export var spec_id: String = ""
# 默认空数组使遗漏 slots 与合法的三个空槽能够区分。
@export var slots: Array[String] = []
