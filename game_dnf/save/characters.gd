extends RefCounted
## One atomic Store per character. Legacy profile is discovered in place, never moved.
const Store = preload("res://save/store.gd")
const Session = preload("res://flow/session.gd")
const LIMIT := 6
var directory := "user://native_loop_v1/characters"
var legacy_path := "user://native_loop_v1/profile.json"
var entries: Array[Dictionary] = []
var error := ""

func refresh() -> void:
	entries.clear()
	error = ""
	var paths: Array[String] = []
	if FileAccess.file_exists(legacy_path) or FileAccess.file_exists(legacy_path + ".bak"):paths.append(legacy_path)
	var dir := DirAccess.open(ProjectSettings.globalize_path(directory))
	if dir != null:
		var names: Array[String] = []
		for filename: String in dir.get_files():
			var clean := filename.trim_suffix(".bak")
			if clean.begins_with("character_") and clean.ends_with(".json") and clean not in names:names.append(clean)
		names.sort()
		for filename in names:paths.append(directory.path_join(filename))
	for path: String in paths:
		var save = Store.new()
		save.path = path
		var state = Session.new()
		if save.read_into(state):
			entries.append({"path":path, "name":state.profile["name"], "level":state.profile["level"], "recovered":save.recovered})
		else:error = "有角色存档无法读取，原文件已保留"

func name_error(value: String) -> String:
	if value.length() < 2 or value.length() > 12:return "角色名需要 2—12 个字符"
	for i in value.length():
		var code := value.unicode_at(i)
		if not (code >= 0x4e00 and code <= 0x9fff or code >= 65 and code <= 90 or code >= 97 and code <= 122 or code >= 48 and code <= 57):
			return "角色名仅支持中文、字母和数字"
	for entry in entries:
		if String(entry["name"]).to_lower() == value.to_lower():return "这个角色名已被使用"
	return ""

func create(value: String) -> Dictionary:
	refresh()
	if entries.size() >= LIMIT:return {"ok":false, "message":"角色位置已满"}
	var message := name_error(value)
	if message != "":return {"ok":false, "message":message}
	var state = Session.new()
	state.profile["name"] = value
	var save = Store.new()
	# Names never become paths; random identifiers prevent collisions and traversal.
	save.path = directory.path_join("character_%020d_%s.json" % [int(Time.get_unix_time_from_system() * 1000000), Crypto.new().generate_random_bytes(12).hex_encode()])
	if not save.write(state):return {"ok":false, "message":"角色创建失败，请检查存档目录"}
	refresh()
	return {"ok":true, "path":save.path}
