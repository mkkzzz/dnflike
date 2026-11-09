extends RefCounted
## Atomic replace with previous valid save as recovery copy. No engine/global state.
var path := "user://native_loop_v1/profile.json"
var recovered := false
var last_error := ""
var _known_valid_on_disk := false
var _known_signature := ""

func read_into(session) -> bool:
	recovered = false
	last_error = ""
	for candidate: String in [path, path + ".bak"]:
		if not FileAccess.file_exists(candidate):continue
		if _restore_file(candidate,session):
			recovered = candidate.ends_with(".bak")
			_known_valid_on_disk = not recovered
			_known_signature = _signature(path) if not recovered else ""
			return true
	if FileAccess.file_exists(path):
		last_error = "主存档损坏，且没有可用备份"
	elif FileAccess.file_exists(path + ".bak"):
		last_error = "主存档不存在，备份也损坏"
	else:
		last_error = "存档不存在"
	return false

func write(session, profile_override: Dictionary = {}) -> bool:
	last_error = ""
	var absolute := ProjectSettings.globalize_path(path)
	var parent := absolute.get_base_dir()
	while not DirAccess.dir_exists_absolute(parent):
		if FileAccess.file_exists(parent):
			last_error = "存档目录被同名文件占用"
			return false
		var ancestor := parent.get_base_dir()
		if ancestor == parent:
			last_error = "无法定位存档目录"
			return false
		parent = ancestor
	if DirAccess.make_dir_recursive_absolute(absolute.get_base_dir()) != OK:
		last_error = "无法创建存档目录"
		return false
	var snapshot: Dictionary = session.serialize()
	if not profile_override.is_empty():snapshot["profile"] = profile_override
	var payload := JSON.stringify(snapshot, "\t")
	var temporary := absolute + ".tmp"
	var backup_temporary := absolute + ".bak.tmp"
	if FileAccess.file_exists(temporary) and DirAccess.remove_absolute(temporary) != OK:
		last_error = "无法清理上次未完成的临时存档"
		return false
	if FileAccess.file_exists(backup_temporary) and DirAccess.remove_absolute(backup_temporary) != OK:
		last_error = "无法清理上次未完成的备份文件"
		return false
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		last_error = "无法创建临时存档"
		return false
	file.store_string(payload)
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK or not _payload_parseable(temporary):
		DirAccess.remove_absolute(temporary)
		last_error = "临时存档写入失败，原存档未替换"
		return false
	# Only a valid existing save may replace the last known-good backup.
	if FileAccess.file_exists(path):
		if _primary_valid(session):
			if DirAccess.copy_absolute(absolute,backup_temporary) != OK \
				or DirAccess.rename_absolute(backup_temporary,absolute + ".bak") != OK:
				DirAccess.remove_absolute(backup_temporary)
				DirAccess.remove_absolute(temporary)
				last_error = "无法保护上一份存档，本次未提交"
				return false
	if DirAccess.rename_absolute(temporary,absolute) != OK:
		DirAccess.remove_absolute(temporary)
		last_error = "无法替换主存档，原存档未改变"
		return false
	_known_valid_on_disk = true
	_known_signature = "%d:%d:%d" % [payload.length(),payload.hash(),FileAccess.get_modified_time(path)]
	return true

func _restore_file(candidate: String, session) -> bool:
	if not FileAccess.file_exists(candidate):return false
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(candidate)) != OK:return false
	if not json.data is Dictionary:return false
	return session.restore(json.data)

func _payload_parseable(candidate: String) -> bool:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(candidate))
	return parsed is Dictionary

func _primary_valid(session) -> bool:
	var current_signature := _signature(path)
	if _known_valid_on_disk and _known_signature != "" and current_signature == _known_signature:
		return true
	var verifier = load("res://flow/session.gd").new()
	var valid := _restore_file(path,verifier)
	_known_valid_on_disk = valid
	_known_signature = current_signature if valid else ""
	return valid

func _signature(candidate: String) -> String:
	if not FileAccess.file_exists(candidate):return ""
	var payload := FileAccess.get_file_as_string(candidate)
	return "%d:%d:%d" % [payload.length(),payload.hash(),FileAccess.get_modified_time(candidate)]
