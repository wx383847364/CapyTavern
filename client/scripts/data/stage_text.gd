extends RefCounted
## 关卡文案：读 client/data/text/stages.json（design/text/stages.json 的原样副本，不手改）。
## 文案归策划；读不到时返回空字典，界面退回用数值表推出来的说明。

const PATH := "res://data/text/stages.json"


static func load_stage(stage_id: String = "stage_1", path: String = PATH) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	for entry: Variant in (parsed as Dictionary).get("stages", []):
		if typeof(entry) == TYPE_DICTIONARY and str((entry as Dictionary).get("id", "")) == stage_id:
			return entry
	return {}
