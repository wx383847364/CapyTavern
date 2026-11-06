extends Control
## 入口：选择出战人数进入战斗灰盒；同时保留 P0 的输入回显，方便核对 12 个动作。
## 单档命令行（P2b，无界面）：--save=PATH --do=recruit:warrior --do=claim:…，命令清单见 scripts/data/save_cli.gd。
## 无参数进酒馆（P3a）；--p0 进 P0 的动作回显页。
## 战斗命令行（`--` 之后）：--battle=1..4  --classes=a,b,c,d（空槽留空）  --seed=N  --autoplay  --fast  --passive  --talents=warrior:t2,mage:t1  --sets=warrior,priest

const BattleLaunch := preload("res://scripts/battle/battle_launch.gd")
const BATTLE_SCENE := "res://scenes/battle/battle.tscn"
const SaveCli := preload("res://scripts/data/save_cli.gd")
const TAVERN_SCENE := "res://scenes/tavern/tavern.tscn"

const ACTIONS: PackedStringArray = [
	"click_primary", "click_secondary",
	"slot_1", "slot_2", "slot_3", "slot_4",
	"skill_q", "skill_w", "skill_e", "skill_r",
	"cancel_layer", "pause",
]

@onready var _echo: Label = $Echo


func _ready() -> void:
	print("CapyTavern P2 ready, godot ", Engine.get_version_info().string)
	# 单档命令行模式：--do=命令，见 save_cli.gd。跑完直接退出，不进界面。
	if SaveCli.wanted(OS.get_cmdline_user_args()):
		get_tree().quit(SaveCli.run(OS.get_cmdline_user_args()))
		return
	for count in range(1, 5):
		var button: Button = get_node("Menu/Start%d" % count)
		button.pressed.connect(_start.bind(count))
	var args := _parse_args(OS.get_cmdline_user_args())
	if args.has("battle") or args.has("classes"):
		_apply_args(args)
		# 等一帧再切场景，避免在 _ready 里改场景树
		_enter_battle.call_deferred()
	elif not args.has("p0"):
		# 没带参数：进酒馆。--p0 留给 P0 的 12 个动作回显页，--battle / --do 行为不变。
		get_tree().change_scene_to_file.call_deferred(TAVERN_SCENE)


func _parse_args(raw: PackedStringArray) -> Dictionary:
	var result := {}
	for arg in raw:
		if not arg.begins_with("--"):
			continue
		var body := arg.substr(2)
		var eq := body.find("=")
		if eq < 0:
			result[body] = "true"
		else:
			result[body.substr(0, eq)] = body.substr(eq + 1)
	return result


func _apply_args(args: Dictionary) -> void:
	var count := int(args.get("battle", "4"))
	BattleLaunch.slots = BattleLaunch.default_slots(clampi(count, 1, 4))
	if args.has("classes"):
		var parts: PackedStringArray = String(args["classes"]).split(",")
		var slots: Array = ["", "", "", ""]
		for index in mini(4, parts.size()):
			slots[index] = parts[index].strip_edges()
		BattleLaunch.slots = slots
	BattleLaunch.seed = int(args.get("seed", "-1"))
	BattleLaunch.autoplay = args.has("autoplay")
	BattleLaunch.fast = args.has("fast")
	BattleLaunch.passive = args.has("passive")
	BattleLaunch.talents = {}
	for pair in String(args.get("talents", "")).split(",", false):
		var kv := pair.split(":")
		if kv.size() == 2:
			BattleLaunch.talents[kv[0].strip_edges()] = kv[1].strip_edges()
	BattleLaunch.sets = Array(String(args.get("sets", "")).split(",", false))


func _start(count: int) -> void:
	BattleLaunch.slots = BattleLaunch.default_slots(count)
	BattleLaunch.seed = -1
	BattleLaunch.autoplay = false
	BattleLaunch.fast = false
	BattleLaunch.passive = false
	BattleLaunch.talents = {}
	BattleLaunch.sets = []
	_enter_battle()


func _enter_battle() -> void:
	get_tree().change_scene_to_file(BATTLE_SCENE)


func _unhandled_input(event: InputEvent) -> void:
	for action in ACTIONS:
		if event.is_action_pressed(action):
			var line := "动作: %s" % action
			if event is InputEventMouseButton:
				line += "  位置: %s" % event.position
			_echo.text = line
			print(line)
			return
