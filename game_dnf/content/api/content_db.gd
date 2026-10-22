extends RefCounted
## ContentDB: one read-only view over three layers, later layers win.
##   base     — compiled from original data (E-PARSE+): runtime manifest clips + content pack records
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

# --- compiled original content pack (tools/compile_dnf_content.py, dnf_combat_content/1) ---
# Records are keyed by original archive path (e.g. "character/swordman/attackinfo/attack1.atk"),
# so they live beside the "/"-path tree instead of inside it. Loaded lazily on first query.
const PACK_SCHEMA := "dnf_combat_content/1"
var pack_path := "res://assets_local/content/combat_content.json"
var _pack: Dictionary = {}
var _pack_tried := false

func has_pack() -> bool:
	_ensure_pack()
	return not _pack.is_empty()

func pack_info() -> Dictionary:
	_ensure_pack()
	if _pack.is_empty():return {}
	return {"schema":_pack["schema"],"asset_version":_pack["asset_version"],"compiler_version":_pack["compiler_version"],
		"records":_pack["records"].size(),"missing_references":_pack["missing_references"].size()}

func record(id: String) -> Dictionary:
	_ensure_pack()
	return _pack.get("records",{}).get(id.to_lower(),{})

## Decoded original field of a record, or default when the record or field is absent.
func original(id: String, key: String, default_value = null):
	return record(id).get("decoded",{}).get(key,default_value)

func evidence(id: String, key: String) -> String:
	return String(record(id).get("evidence",{}).get(key,""))

func record_ids(kind: String) -> Array:
	_ensure_pack()
	var out: Array = []
	for id: String in _pack.get("records",{}):
		if _pack["records"][id]["kind"] == kind:out.append(id)
	return out

## Original ID tables, e.g. index("swordman_skills")["46"] -> "skill/swordman/upperslash.skl".
func index(name: String) -> Dictionary:
	_ensure_pack()
	return _pack.get("indexes",{}).get(name,{})

func _ensure_pack() -> void:
	if _pack_tried:return
	_pack_tried = true
	if not FileAccess.file_exists(pack_path):return
	var doc = JSON.parse_string(FileAccess.get_file_as_string(pack_path))
	if doc is Dictionary and doc.get("schema","") == PACK_SCHEMA:_pack = doc
	else:push_warning("Content pack schema mismatch: "+pack_path)

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
