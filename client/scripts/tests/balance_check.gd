extends SceneTree
## P2a 数值同步与防护自检（无窗口）。运行：
##   godot --headless --path client --script res://scripts/tests/balance_check.gd
## 覆盖：副本与 design/balance 逐字一致、天赋/两件套修正口径、非法天赋回默认、防护公式与取整、
## 站位字段保留。有失败时退出码 1。不改任何文件。
## 同步检查需要仓库里的 design/balance/；导出包里没有这个目录，会标「跳过」。

const BattleSim := preload("res://scripts/battle/battle_sim.gd")
const BattleEvents := preload("res://scripts/battle/battle_events.gd")
const BattleConfig := preload("res://scripts/battle/battle_config.gd")
const BalanceLoader := preload("res://scripts/data/balance_loader.gd")

var _failures: int = 0


func _initialize() -> void:
	_sync()
	_modifiers()
	_talent_fallback()
	_defense()
	_layout()
	print("RESULT: %s (%d 条失败)" % ["FAIL" if _failures > 0 else "ALL PASS", _failures])
	quit(1 if _failures > 0 else 0)


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		print("PASS  ", name)
	else:
		_failures += 1
		print("FAIL  ", name, "  ", detail)


func _near(a: float, b: float) -> bool:
	return absf(a - b) < 0.0001


func _skill(config: Dictionary, id: String) -> Dictionary:
	return config["skills"][id]


func _effect(config: Dictionary, skill_id: String, kind: String) -> Dictionary:
	for effect: Dictionary in _skill(config, skill_id)["effects"]:
		if String(effect["kind"]) == kind:
			return effect
	return {}


# ── 副本与源表逐字一致 ──

func _sync() -> void:
	var source_dir := ProjectSettings.globalize_path("res://").path_join("../design/balance")
	if not DirAccess.dir_exists_absolute(source_dir):
		print("SKIP  同步检查：找不到 design/balance（导出包里没有）")
		return
	for name in BalanceLoader.TABLES:
		var copy := FileAccess.get_file_as_bytes("res://data/balance/%s.json" % name)
		var source := FileAccess.get_file_as_bytes(source_dir.path_join("%s.json" % name))
		_check("副本 %s.json 与 design/balance 逐字一致（%d 字节）" % [name, source.size()], not source.is_empty() and copy == source, "副本 %d 字节，源 %d 字节" % [copy.size(), source.size()])


# ── 天赋与两件套 ──

func _modifiers() -> void:
	var base := BattleConfig.load_config({"modifiers": false})
	_check("无修正配置可读", not base.is_empty())
	var rows: Array = (JSON.parse_string(FileAccess.get_file_as_string("res://data/balance/modifiers.json")) as Dictionary)["rows"]
	var flat_params := {}
	for row: Dictionary in rows:
		if row["op"] == "add_flat":
			flat_params[row["param"]] = true
	_check("add_flat 只用于持续时间", flat_params.keys() == ["duration"], str(flat_params.keys()))

	var t1 := BattleConfig.load_config()
	_check("默认配置没有警告", (t1["warnings"] as Array).is_empty(), str(t1["warnings"]))
	_check("默认天赋都是 t1", (t1["talents"] as Dictionary).values().all(func(v): return v == "t1"), str(t1["talents"]))
	# 战士 t1：坚壁 持续 +2 秒（挑衅和减伤两个效果都加），消耗 +20%
	_check("战士 t1：挑衅守势消耗 20→24", int(_skill(t1, "defensive_taunt")["cost"]) == 24, str(_skill(t1, "defensive_taunt")["cost"]))
	_check("战士 t1：挑衅持续 5→7 秒", _near(float(_effect(t1, "defensive_taunt", "taunt")["duration"]), 7.0))
	_check("战士 t1：减伤状态持续 5→7 秒", _near(float(_effect(t1, "defensive_taunt", "status")["duration"]), 7.0))
	# 盗贼 t1：伤害 +25%，消耗 +20%（25→30）；伤害不提前取整
	_check("盗贼 t1：背刺伤害 30×1.25=37.5（不提前取整）", _near(float(_effect(t1, "kick_stab", "damage")["amount"]), 37.5), str(_effect(t1, "kick_stab", "damage")))
	_check("盗贼 t1：背刺消耗 25→30", int(_skill(t1, "kick_stab")["cost"]) == 30)
	# 牧师 t1：消耗 -25%（25→18.75→19），治疗 -10%
	_check("牧师 t1：强效治疗消耗 25×0.75=18.75→19", int(_skill(t1, "greater_heal")["cost"]) == 19, str(_skill(t1, "greater_heal")["cost"]))
	_check("牧师 t1：强效治疗 100×0.9=90", _near(float(_effect(t1, "greater_heal", "heal")["amount"]), 90.0))
	# 法师 t1：伤害 +25%，半径 -40%
	var mage_base_radius := float(_effect(base, "fire_burst", "damage").get("radius", 0.0))
	_check("法师 t1：火焰爆裂半径 ×0.6", mage_base_radius > 0.0 and _near(float(_effect(t1, "fire_burst", "damage")["radius"]), mage_base_radius * 0.6), "基础半径 %s" % mage_base_radius)

	var t2 := BattleConfig.load_config({"talents": {"warrior": "t2", "rogue": "t2", "mage": "t2", "priest": "t2"}})
	_check("战士 t2：挑衅守势消耗 20×0.75=15", int(_skill(t2, "defensive_taunt")["cost"]) == 15)
	_check("战士 t2：持续不变 5 秒", _near(float(_effect(t2, "defensive_taunt", "taunt")["duration"]), 5.0))
	_check("盗贼 t2：背刺冷却 10×0.75=7.5，伤害 ×0.8=24", _near(float(_skill(t2, "kick_stab")["cooldown"]), 7.5) and _near(float(_effect(t2, "kick_stab", "damage")["amount"]), 24.0))
	_check("牧师 t2：强效治疗 ×1.25=125，冷却 5×1.25=6.3（0.1 秒精度）", _near(float(_effect(t2, "greater_heal", "heal")["amount"]), 125.0) and _near(float(_skill(t2, "greater_heal")["cooldown"]), 6.3), str(_skill(t2, "greater_heal")["cooldown"]))
	_check("切换天赋从基础值重算，不叠层：t1 的盗贼消耗没带进 t2", int(_skill(t2, "kick_stab")["cost"]) == 25, str(_skill(t2, "kick_stab")["cost"]))
	var again := BattleConfig.load_config()
	_check("重新载入默认配置结果相同（不叠层）", int(_skill(again, "defensive_taunt")["cost"]) == 24 and _near(float(_effect(again, "kick_stab", "damage")["amount"]), 37.5))

	# 两件套：战士 +1 秒（flat），盗贼伤害同类加算 25%+5%=30%
	var sets := BattleConfig.load_config({"sets": ["warrior", "rogue"]})
	_check("战士两件套：持续 7+1=8 秒", _near(float(_effect(sets, "defensive_taunt", "taunt")["duration"]), 8.0))
	_check("盗贼两件套：与天赋同类加算 30%，30×1.3=39", _near(float(_effect(sets, "kick_stab", "damage")["amount"]), 39.0), str(_effect(sets, "kick_stab", "damage")))
	_check("没凑套的职业不受影响：牧师仍是 90", _near(float(_effect(sets, "greater_heal", "heal")["amount"]), 90.0))
	_check("原表里这些字段没被改写（读的是副本拷贝）", _near(float(_effect(base, "kick_stab", "damage")["amount"]), 30.0))


func _talent_fallback() -> void:
	var bad := BattleConfig.load_config({"talents": {"warrior": "t9", "rogue": "", "mage": "<script>", "priest": 7}})
	_check("非法天赋标识回默认 t1，不崩", not bad.is_empty() and (bad["talents"] as Dictionary).values().all(func(v): return v == "t1"), str(bad.get("talents")))
	var weird := BattleConfig.load_config({"talents": "not a dict"})
	_check("talents 不是字典也不崩，全部回默认", not weird.is_empty() and weird["talents"]["warrior"] == "t1")
	var mixed := BattleConfig.load_config({"talents": {"warrior": "t2", "rogue": "bogus"}})
	_check("合法的保留、非法的单个回默认", mixed["talents"]["warrior"] == "t2" and mixed["talents"]["rogue"] == "t1", str(mixed["talents"]))
	var rows: Array = (JSON.parse_string(FileAccess.get_file_as_string("res://data/balance/modifiers.json")) as Dictionary)["rows"]
	var ids_ok := true
	for class_id in ["warrior", "rogue", "mage", "priest"]:
		ids_ok = ids_ok and BalanceLoader.talent_ids(rows, class_id) == ["t1", "t2"]
	_check("四职业都是 t1/t2 二选一，共 8 个天赋", ids_ok)


# ── 防护 ──

func _arena(slots: Array = ["warrior", "rogue", "mage", "priest"]) -> Dictionary:
	var config := BattleConfig.load_config()
	var events := BattleEvents.new()
	var sim := BattleSim.new()
	sim.setup(config, slots, 1, events)
	return {"sim": sim, "events": events, "config": config}


func _hit(sim: BattleSim, victim: BattleSim.Unit, source: BattleSim.Unit, base: float, school: String) -> int:
	var before := victim.hp
	sim._damage(source, victim, base, "", false, school)
	return before - victim.hp


func _defense() -> void:
	var arena := _arena()
	var sim: BattleSim = arena["sim"]
	var attacker := sim.slot_unit(0)
	var target: BattleSim.Unit = sim.living("enemy")[0]
	target.max_hp = 100000
	target.hp = 100000
	_check("K 读自表：defense_formula.K = 100", _near(float(arena["config"]["defense_formula"]["K"]), 100.0))
	target.armor = 0.0
	target.magic_resist = 0.0
	_check("防护 0：100 点伤害 → 100", _hit(sim, target, attacker, 100.0, "physical") == 100)
	target.armor = 100.0
	_check("防护 100：同一伤害 → 50（100/(100+100)=50%）", _hit(sim, target, attacker, 100.0, "physical") == 50)
	_check("防护 100 的减伤比例 0.5", _near(sim.damage_reduction(target, "physical"), 0.5))
	target.armor = 60.0
	_check("防护 60：100 点 → 62.5 → 四舍五入 63（减伤比例不单独取整）", _hit(sim, target, attacker, 100.0, "physical") == 63, str(sim.damage_reduction(target, "physical")))
	target.armor = 100.0
	target.magic_resist = 0.0
	_check("魔法伤害吃魔抗不吃护甲：护甲 100、魔抗 0 → 100", _hit(sim, target, attacker, 100.0, "magic") == 100)
	target.armor = 0.0
	target.magic_resist = 100.0
	_check("魔抗 100 的魔法伤害 → 50，物理不受影响 → 100", _hit(sim, target, attacker, 100.0, "magic") == 50 and _hit(sim, target, attacker, 100.0, "physical") == 100)
	_check("school=none 不吃任何防护", _hit(sim, target, attacker, 100.0, "none") == 100)
	target.armor = 100.0
	_check("最小伤害为 1：1 点物理伤害打防护 100 → 1", _hit(sim, target, attacker, 1.0, "physical") == 1)
	_check("最小伤害为 1：0.4 点伤害 → 1", _hit(sim, target, attacker, 0.4, "physical") == 1)
	# 治疗不吃防护
	var ally := sim.slot_unit(3)
	ally.armor = 100.0
	ally.magic_resist = 100.0
	ally.hp = ally.max_hp - 200
	var heal_before := ally.hp
	sim._heal(sim.slot_unit(3), ally, 100.0, "")
	_check("治疗不吃防护：防护 100 的目标仍补满 100", ally.hp - heal_before == 100, str(ally.hp - heal_before))
	# 与减伤状态连乘：先防护再状态（0.5 × 0.6）
	target.armor = 100.0
	target.hp = target.max_hp
	sim._apply_status(target, "mitigate", attacker.id, 5.0, {"taken_mult": 0.6})
	_check("防护与减伤状态连乘：100 × 0.5 × 0.6 = 30", _hit(sim, target, attacker, 100.0, "physical") == 30)

	# 数据口径：各方的防护字段来自表
	var cfg: Dictionary = arena["config"]
	var warrior := sim.slot_unit(0)
	_check("战士防护读自职业表：armor 60 / magic_resist 20", _near(warrior.armor, float(cfg["classes"]["warrior"]["armor"])) and _near(warrior.magic_resist, float(cfg["classes"]["warrior"]["magic_resist"])))
	var enemy_ok := true
	for enemy in (_arena()["sim"] as BattleSim).living("enemy"):
		var def: Dictionary = cfg["enemies"][enemy.kind]
		enemy_ok = enemy_ok and _near(enemy.armor, float(def["armor"])) and _near(enemy.magic_resist, float(def["magic_resist"]))
	_check("敌人防护读自敌人表", enemy_ok)

	# 实打：近战怪普攻打战士（物理 23 × 0.375 防护 → 14.375 → 14）
	var fight := _arena(["warrior", "", "", ""])
	var fsim: BattleSim = fight["sim"]
	var melee: BattleSim.Unit = null
	for enemy in fsim.living("enemy"):
		if enemy.kind == "melee":
			melee = enemy
			break
	var scaled := float(fight["config"]["enemies"]["melee"]["damage"]) * melee.dmg_scale
	var warrior_unit := fsim.slot_unit(0)
	var taken := _hit(fsim, warrior_unit, melee, scaled, melee.attack_school)
	var expected := maxi(1, roundi(scaled * (1.0 - 60.0 / 160.0)))
	_check("近战怪打战士：%.2f × (1-60/160) 取整 = %d" % [scaled, expected], taken == expected, str(taken))


func _layout() -> void:
	var config := BattleConfig.load_config()
	var layout: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/battle_layout.json"))
	_check("站位字段读程序自有文件：arena、ally_spawn、unit_radius 原值保留", config["arena"] == layout["arena"] and config["ally_spawn"] == layout["ally_spawn"] and _near(float(config["unit_radius"]), float(layout["unit_radius"])))
	var wave: Array = config["wave"]
	var positions_ok := wave.size() == (layout["wave_positions"] as Array).size()
	for index in wave.size():
		positions_ok = positions_ok and _near(float(wave[index]["x"]), float(layout["wave_positions"][index]["x"])) and _near(float(wave[index]["y"]), float(layout["wave_positions"][index]["y"]))
	_check("wave 站位用程序文件的 x、y，敌人构成读数值表", positions_ok and config["wave"][0]["enemy"] == "melee")
	var problems := BattleConfig.validate(config)
	_check("合并后的配置通过校验", problems.is_empty(), ", ".join(problems))
	var scaling: Dictionary = config["party_scaling"]
	var source: Dictionary = (JSON.parse_string(FileAccess.get_file_as_string("res://data/balance/global.json")) as Dictionary)["party_scaling"]
	var scaling_ok := true
	for count in ["1", "2", "3", "4"]:
		scaling_ok = scaling_ok and _near(float(scaling[count]["hp"]), float(source[count]["hp"])) and _near(float(scaling[count]["dmg"]), float(source[count]["dmg"]))
	_check("party_scaling 四档都读自数值表（不写死数值）", scaling_ok, str(scaling))
