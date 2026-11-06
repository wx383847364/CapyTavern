extends SceneTree
## P3b 面板数据层自检（无界面）：TavernRoster 与存档服务新增的 move_member / validate_party / save_now / fail_writes。
## 用法：godot --headless --path client --script res://scripts/tests/roster_check.gd

const ItemsTable := preload("res://scripts/data/items_table.gd")
const SaveStore := preload("res://scripts/data/save_store.gd")
const SaveService := preload("res://scripts/data/save_service.gd")
const TavernRoster := preload("res://scripts/tavern/tavern_roster.gd")

var _failures: int = 0


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		print("PASS  ", name)
	else:
		_failures += 1
		print("FAIL  ", name, "  ", detail)


func _fresh(path: String) -> SaveService:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var table := ItemsTable.new()
	table.load_tables()
	var service := SaveService.new(table, SaveStore.new(path))
	service.load_state()
	return service


func _initialize() -> void:
	var service := _fresh("/tmp/roster_check.json")
	var roster := TavernRoster.new(service, {})
	var view := roster.sortie_view()
	_check("空档：不能出征，只有 no_party，入口是去招募", not view["ok"] and view["blockers"].size() == 1 and view["blockers"][0]["code"] == "no_party" and view["blockers"][0]["action"] == "recruit")
	_check("空档：整备面板没有查看对象", roster.inspected_class() == "")
	var card := roster.class_card("warrior")
	_check("招募卡：四个技能概要、面板数值", card["skills"].size() == 4 and int(card["max_hp"]) > 0 and not bool(card["recruited"]))
	service.recruit("warrior")
	_check("一人：可出征，摘要「当前 1/4 人，可出征」", roster.sortie_view()["ok"] and roster.sortie_view()["summary"] == "当前 1/4 人，可出征")
	_check("整备面板默认看队长", roster.inspected_class() == "warrior")

	# 顺序调整
	_check("最前面的成员前移：edge", service.move_member("warrior", -1)["reason"] == "edge")
	service.recruit("rogue")
	service.recruit("mage")
	var moved := service.move_member("mage", -1)
	_check("法师前移一格，与盗贼互换", moved["ok"] and service.state["slots"] == ["warrior", "mage", "rogue", ""], str(service.state["slots"]))
	service.set_captain("mage")
	service.move_member("mage", -1)
	_check("队长跟着槽位走", service.state["slots"][0] == "mage" and int(service.state["captainSlot"]) == 0)
	service.move_member("rogue", 1)
	_check("后移可以换进空槽", service.state["slots"] == ["mage", "warrior", "", "rogue"], str(service.state["slots"]))
	_check("最后一格后移：edge", service.move_member("rogue", 1)["reason"] == "edge")
	_check("没招募的职业不能移动", service.move_member("priest", 1)["reason"] == "not_recruited")

	# 装备与预览
	var rows := roster.equip_view("warrior")
	_check("8 个装备栏", rows.size() == 8)
	_check("初始没有替换件：肩膀栏无候选", rows[3]["candidates"].is_empty() and rows[3]["slot"] == "shoulder")
	var before := JSON.stringify(service.state)
	var pre := roster.preview("warrior", "warrior_shoulder_set")
	_check("预览不改存档，也不要求已拥有", JSON.stringify(service.state) == before and not pre.is_empty())
	service.settle("r1", "win")
	service.claim("warrior", "warrior_shoulder_set")
	_check("领到奖励件后肩膀栏有一个候选", roster.equip_view("warrior")[3]["candidates"].size() == 1)
	_check("预览：套装 0/2 → 1/2", roster.preview("warrior", "warrior_shoulder_set")["set_after"] == 1)
	service.equip("warrior", "warrior_shoulder_set")
	_check("穿上后套装 1/2，未生效", roster.set_status("warrior")["have"] == 1 and not roster.set_status("warrior")["active"])

	# 天赋
	var talents := roster.talent_options("warrior")
	_check("两个天赋，各有收益/代价条目，当前是 t1", talents.size() == 2 and talents[0]["active"] and talents[1]["lines"].size() >= 1)
	var t1_good := false
	var t1_bad := false
	for line: Dictionary in talents[0]["lines"]:
		t1_good = t1_good or bool(line["good"])
		t1_bad = t1_bad or not bool(line["good"])
	_check("天赋一：既有收益也有代价（持续 +2 秒好，消耗 +20% 坏）", t1_good and t1_bad)

	# 出征检查：配置非法
	service.state["equips"]["warrior"]["weapon"] = "rogue_weapon"
	var bad := roster.sortie_view()
	_check("装备不合法：阻止出征并标出成员", not bad["ok"] and bad["blockers"].any(func(b): return b["code"] == "equip_invalid" and b["class_id"] == "warrior"))
	_check("出现问题的成员在摘要里标红（flagged）", bad["party"].any(func(e): return e.get("class_id", "") == "warrior" and bool(e.get("flagged", false))))
	service.state["equips"]["warrior"]["weapon"] = "warrior_weapon"
	service.state["talentId"]["mage"] = "t9"
	_check("天赋不合法：阻止出征", roster.sortie_view()["blockers"].any(func(b): return b["code"] == "talent_invalid"))
	service.state["talentId"]["mage"] = "t1"
	service.state["captainSlot"] = 3  # 指向空槽
	var fixed := roster.sortie_view()
	_check("队长指针失效：自动回到有效队长，不阻止出征", fixed["ok"] and service.state["slots"][int(service.state["captainSlot"])] != "")
	service.state["pendingReward"] = {"run_id": "x"}
	var pending := roster.sortie_view()
	_check("待领奖：阻止出征，入口是领取战利品", not pending["ok"] and pending["blockers"][0]["action"] == "claim")
	service.state["pendingReward"] = null
	service.state["equips"]["warrior"].erase("amulet")
	_check("缺一件装备也算不合法", not roster.sortie_view()["ok"])
	service.state["equips"]["warrior"]["amulet"] = "warrior_amulet"

	# 确认出征与写盘失败
	var good := roster.sortie_view()
	_check("恢复后可以出征", good["ok"], str(good["blockers"]))
	service.store.fail_writes = 1
	var failed := roster.confirm_sortie()
	_check("确认出征写盘失败：返回 write_failed，不给名单", not failed["ok"] and failed["reason"] == "write_failed" and not failed.has("roster"))
	var sealed := roster.confirm_sortie()
	_check("再试一次成功，名单按槽位顺序、含队长标记", sealed["ok"] and sealed["roster"].size() == 3 and sealed["roster"].any(func(e): return bool(e["captain"])), str(sealed))
	_check("名单槽位号与队伍栏一致", sealed["roster"][0]["slot"] == 1 and sealed["roster"][0]["class_id"] == "mage")

	# fail_writes 计数：N 次后恢复
	service.store.fail_writes = 2
	var a := service.set_captain("warrior")
	var b := service.set_captain("warrior")
	var c := service.set_captain("warrior")
	_check("fail_writes=2：前两次失败第三次成功", a["reason"] == "write_failed" and b["reason"] == "write_failed" and c["ok"])

	# 战利品列表
	service.state["pendingReward"] = {"run_id": "z"}
	var reward := roster.reward_view()
	_check("战利品视图：每个已招募职业一条，战士还剩一件（鞋子）", reward.size() == 3 and reward.any(func(e): return e["class_id"] == "warrior" and e["items"].size() == 1))

	# 舞台信息来自数值表
	var stage := roster.stage_view()
	_check("关卡信息：敌人构成、两条机制、限时都来自数值表", String(stage["enemies"]).contains("近战小怪×2") and stage["mechanics"].size() == 2 and String(stage["goal"]).contains("120"), str(stage))
	var text_stage := TavernRoster.new(service, preload("res://scripts/data/stage_text.gd").load_stage()).stage_view()
	_check("关卡文案来自 data/text/stages.json：名称、3 条敌人说明、4 条提示、限时", text_stage["name"] == "酒馆外的伏击" and text_stage["enemy_notes"].size() == 3 and text_stage["mechanics"].size() == 4 and String(text_stage["goal"]).contains("限时 120"), str(text_stage))
	print("RESULT: %s (%d 条失败)" % ["FAIL" if _failures > 0 else "ALL PASS", _failures])
	quit(1 if _failures > 0 else 0)
