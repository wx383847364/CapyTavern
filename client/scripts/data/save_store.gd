extends RefCounted
## 单档文件读写。先写临时文件再改名，写失败时原文件不动。
## 路径可以是 user://… 或绝对路径（命令行 --save=PATH）。

const DEFAULT_PATH := "user://save.json"

var path: String = DEFAULT_PATH
## 测试用：设为 true 让下一次写入失败（用来验证「中途失败两边回到写入前」）。
var fail_next_write: bool = false
## 测试用：接下来的 N 次写入都失败（导出包里用 --fail-writes=N 注入，验保存失败和重试）。
var fail_writes: int = 0


## 命令行 --save=PATH，没有就用默认路径。酒馆和战斗两个场景都用它，保证读写同一份存档。
static func path_from_args() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--save="):
			return arg.get_slice("=", 1)
	return DEFAULT_PATH


func _init(save_path: String = DEFAULT_PATH) -> void:
	path = save_path


func exists() -> bool:
	return FileAccess.file_exists(path)


## 读出原始字典。文件不存在返回 {"missing": true}；读不动或不是对象返回 {"corrupt": 原因}。
func read_raw() -> Dictionary:
	if not exists():
		return {"missing": true}
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return {"corrupt": "文件为空或读不动"}
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"corrupt": "不是 JSON 对象"}
	return {"data": parsed}


## 把坏档挪到 .corrupt 留证据，不删。返回挪到哪。
func quarantine() -> String:
	var target := path + ".corrupt"
	DirAccess.rename_absolute(ProjectSettings.globalize_path(path), ProjectSettings.globalize_path(target))
	return target


## 成功返回 OK；失败返回原错误码，原文件保持写入前内容，仅向标准输出记录失败阶段、错误码及注入标识。
func write(state: Dictionary) -> Error:
	if fail_next_write:
		fail_next_write = false
		print("save_write_failed stage=inject_next error=%d injected=true" % ERR_FILE_CANT_WRITE)
		return ERR_FILE_CANT_WRITE
	if fail_writes > 0:
		fail_writes -= 1
		print("save_write_failed stage=inject_count error=%d injected=true" % ERR_FILE_CANT_WRITE)
		return ERR_FILE_CANT_WRITE
	var absolute := ProjectSettings.globalize_path(path)
	var made := DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	if made != OK and not DirAccess.dir_exists_absolute(absolute.get_base_dir()):
		print("save_write_failed stage=mkdir error=%d injected=false" % made)
		return made
	var tmp := absolute + ".tmp"
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		# 先捕获本次打开的原始错误；日志不能影响后续取值或改变返回码。
		var open_error := FileAccess.get_open_error()
		print("save_write_failed stage=open error=%d injected=false" % open_error)
		return open_error
	file.store_string(JSON.stringify(state, "\t", true) + "\n")
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		DirAccess.remove_absolute(tmp)
		# 保留原临时文件清理顺序；以捕获的写入错误取证，不用文件残留推断阶段。
		print("save_write_failed stage=write error=%d injected=false" % write_error)
		return write_error
	var renamed := DirAccess.rename_absolute(tmp, absolute)
	if renamed != OK:
		DirAccess.remove_absolute(tmp)
		# 清理可能删除临时文件，但输出与返回仍使用原改名错误。
		print("save_write_failed stage=rename error=%d injected=false" % renamed)
	return renamed
