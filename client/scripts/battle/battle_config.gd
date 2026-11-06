extends RefCounted
## 战斗配置入口。数值来自 data/balance/（策划表的原样副本）+ data/battle_layout.json（站位）。
## 所有战斗数值只从这里来，脚本里不写死。读不到时返回空字典，调用方自己决定怎么报。
## options 见 BalanceLoader.load_balance：talents、sets、dir。

const BalanceLoader := preload("res://scripts/data/balance_loader.gd")


static func load_config(options: Dictionary = {}) -> Dictionary:
	return BalanceLoader.load_balance(options)


## 校验必要字段，返回问题列表；空表示可用。
static func validate(config: Dictionary) -> PackedStringArray:
	var problems := PackedStringArray()
	for key in ["tick", "time_limit", "gcd", "classes", "skills", "enemies", "wave", "party_scaling", "arena", "ally_spawn", "defense_formula"]:
		if not config.has(key):
			problems.append("缺字段 %s" % key)
	if not problems.is_empty():
		return problems
	for class_id in config["classes"]:
		var cls: Dictionary = config["classes"][class_id]
		for slot_key in ["q", "w", "e", "r"]:
			var skill_id: String = cls.get("skills", {}).get(slot_key, "")
			if skill_id.is_empty() or not config["skills"].has(skill_id):
				problems.append("职业 %s 的 %s 技能 %s 未定义" % [class_id, slot_key, skill_id])
	for entry in config["wave"]:
		if not config["enemies"].has(entry.get("enemy", "")):
			problems.append("wave 里有未定义的敌人 %s" % entry.get("enemy", ""))
	return problems


static func color_of(hex: String) -> Color:
	return Color.html(hex)
