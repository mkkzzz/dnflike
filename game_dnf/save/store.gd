extends RefCounted
## Atomic replace with previous valid save as recovery copy. No engine/global state.
var path := "user://native_loop_v1/profile.json"
var recovered := false

func read_into(session) -> bool:
	recovered = false
	for candidate: String in [path, path + ".bak"]:
		if not FileAccess.file_exists(candidate):continue
		var json := JSON.new()
		if json.parse(FileAccess.get_file_as_string(candidate)) != OK:continue
		var parsed = json.data
		if parsed is Dictionary and session.restore(parsed):
			recovered = candidate.ends_with(".bak")
			return true
	return false

func write(session) -> bool:
	var absolute := ProjectSettings.globalize_path(path)
	var parent := absolute.get_base_dir()
	while not DirAccess.dir_exists_absolute(parent):
		if FileAccess.file_exists(parent):return false
		var ancestor := parent.get_base_dir()
		if ancestor == parent:return false
		parent = ancestor
	if DirAccess.make_dir_recursive_absolute(absolute.get_base_dir()) != OK:return false
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if file == null:return false
	file.store_string(JSON.stringify(session.serialize(), "\t"))
	file.flush()
	file.close()
	# Only a valid existing save may replace the last known-good backup.
	var old = null
	if FileAccess.file_exists(path):
		var json := JSON.new()
		if json.parse(FileAccess.get_file_as_string(path)) == OK:old = json.data
	if old is Dictionary:
		var verifier = load("res://flow/session.gd").new()
		if verifier.restore(old):
			if DirAccess.copy_absolute(absolute, absolute + ".bak") != OK:return false
	return DirAccess.rename_absolute(absolute + ".tmp", absolute) == OK
