extends RefCounted
## ContentDB: one read-only view over three layers, later layers win.
##   base     — compiled from original data (E-PARSE+); currently the runtime manifest clips
##   adapt    — temporary values where original semantics are unknown (E-ADAPT, data/combat.json)
##   override — post-baseline enhancements (data/override/*.json), switchable as a whole
## Adapt may only fill paths the base does not define; collisions are reported, base wins.

const LAYERS := ["base", "adapt", "override"]

var runtime: Dictionary = {}
var conflicts: Array = []
var override_enabled := true
var _base: Dictionary = {}
var _adapt: Dictionary = {}
var _override: Dictionary = {}
var _override_reasons: Dictionary = {}
var _merged: Dictionary = {}

func load_files(manifest_path: String, adapt_path: String, override_dir: String) -> bool:
	if not FileAccess.file_exists(manifest_path):
		return false
	runtime = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	# Manifest clip keys look like "player/attack1"; nest them so content paths stay "/"-separated.
	var clips := {}
	for key: String in runtime.get("clips", {}):
		var group := key.get_slice("/", 0)
		if not clips.has(group):clips[group] = {}
		clips[group][key.substr(group.length() + 1)] = runtime["clips"][key]
	_base = {"clips": clips}
	_adapt = JSON.parse_string(FileAccess.get_file_as_string(adapt_path)) if FileAccess.file_exists(adapt_path) else {}
	_override = {}
	_override_reasons.clear()
	var dir := DirAccess.open(override_dir)
	if dir != null:
		var names := Array(dir.get_files()).filter(func(n: String) -> bool: return n.ends_with(".json"))
		names.sort()
		for name: String in names:
			var doc = JSON.parse_string(FileAccess.get_file_as_string(override_dir.path_join(name)))
			for entry: Dictionary in doc.get("entries", []):
				_set_path(_override, String(entry["path"]), entry["value"])
				_override_reasons[String(entry["path"])] = String(entry.get("reason", ""))
	conflicts.clear()
	_collect_conflicts(_base, _adapt, "")
	_rebuild()
	return true

func set_override_enabled(enabled: bool) -> void:
	override_enabled = enabled
	_rebuild()

## Merged tree. Callers must treat it as read-only.
func rules() -> Dictionary:
	return _merged

func value(path: String, default_value = null):
	var node = _merged
	for part in path.split("/"):
		if not node is Dictionary or not node.has(part):
			return default_value
		node = node[part]
	return node

func layer_of(path: String) -> String:
	if override_enabled and _has_path(_override, path):return "override"
	if _has_path(_base, path):return "base"
	if _has_path(_adapt, path):return "adapt"
	return ""

func override_reason(path: String) -> String:
	return _override_reasons.get(path, "")

func clips(group: String) -> Dictionary:
	return _merged.get("clips", {}).get(group, {})

func _rebuild() -> void:
	_merged = _base.duplicate(true)
	_merge_fill(_merged, _adapt)
	if override_enabled:
		_merge_replace(_merged, _override)

func _merge_fill(target: Dictionary, source: Dictionary) -> void:
	for key in source:
		if not target.has(key):
			target[key] = source[key].duplicate(true) if source[key] is Dictionary or source[key] is Array else source[key]
		elif target[key] is Dictionary and source[key] is Dictionary:
			_merge_fill(target[key], source[key])

func _merge_replace(target: Dictionary, source: Dictionary) -> void:
	for key in source:
		if target.has(key) and target[key] is Dictionary and source[key] is Dictionary:
			_merge_replace(target[key], source[key])
		else:
			target[key] = source[key].duplicate(true) if source[key] is Dictionary or source[key] is Array else source[key]

func _collect_conflicts(base: Dictionary, adapt: Dictionary, prefix: String) -> void:
	for key in adapt:
		if not base.has(key):continue
		var path: String = prefix + str(key)
		if base[key] is Dictionary and adapt[key] is Dictionary:
			_collect_conflicts(base[key], adapt[key], path + "/")
		else:
			conflicts.append(path)

func _has_path(tree: Dictionary, path: String) -> bool:
	var node = tree
	for part in path.split("/"):
		if not node is Dictionary or not node.has(part):
			return false
		node = node[part]
	return true

func _set_path(tree: Dictionary, path: String, v) -> void:
	var parts := path.split("/")
	var node: Dictionary = tree
	for i in parts.size() - 1:
		if not node.has(parts[i]) or not node[parts[i]] is Dictionary:
			node[parts[i]] = {}
		node = node[parts[i]]
	node[parts[-1]] = v
