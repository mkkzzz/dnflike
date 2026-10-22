extends RefCounted
## Native pixels shared by the offline review and runtime. No gameplay clocks here.
const ROOTS := ["res://assets/swordsman_v7_c6/"]
const FIRST_CUT_ROOT := "res://assets/swordsman_v7_c8/"
const RUN_COMBO_ROOT := "res://assets/swordsman_v7_c10/"
const RUN_COMBO_CLIPS := ["run","run_start","run_stop","attack1","attack2","attack3"]
static var _root := ""
static var _data: Dictionary = {}
static var _textures: Dictionary = {}
static var _variant := "c6" if "--test" in OS.get_cmdline_user_args() else "c10"
static var _overlay_files: Dictionary = {}

static func select_variant(value: String) -> bool:
	if value not in ["c6", "c8", "c10"]:return false
	if value == "c8" and not _valid_first_cut():return false
	if value == "c10" and not _valid_run_combo():return false
	_variant = value
	_data.clear()
	_textures.clear()
	_overlay_files.clear()
	return not data().is_empty()

static func _valid_first_cut() -> bool:
	var path := FIRST_CUT_ROOT + "manifest.json"
	if not FileAccess.file_exists(path):return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:return false
	var overlay: Dictionary = parsed.get("runtime_overlay", {})
	return bool(parsed.get("validation", {}).get("passed", false)) and bool(parsed.get("authorization", {}).get("gm_preview_allowed", false)) and bool(overlay.get("explicit_gm_only", false)) and overlay.get("allowed_clips", []) == ["attack1"] and parsed.get("clips", {}).keys() == ["attack1"] and String(overlay.get("base_manifest_sha256", "")) == FileAccess.get_sha256(ROOTS[0] + "manifest.json")

static func _valid_run_combo() -> bool:
	var path := RUN_COMBO_ROOT + "manifest.json"
	if not FileAccess.file_exists(path):return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:return false
	var overlay: Dictionary = parsed.get("runtime_overlay", {})
	if not bool(parsed.get("validation", {}).get("passed", false)) or not bool(parsed.get("authorization", {}).get("runtime_trial_allowed", false)):return false
	if overlay.get("allowed_clips", []) != RUN_COMBO_CLIPS or String(overlay.get("base_manifest_sha256", "")) != FileAccess.get_sha256(ROOTS[0]+"manifest.json"):return false
	var clips: Dictionary = parsed.get("clips", {})
	if clips.size() != RUN_COMBO_CLIPS.size():return false
	for name in RUN_COMBO_CLIPS:
		if not clips.has(name):return false
	return bool(overlay.get("preserve_approved_idle", false))

static func data() -> Dictionary:
	if not _data.is_empty():
		return _data
	for folder in ROOTS:
		var path: String = folder + "manifest.json"
		if not FileAccess.file_exists(path):continue
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Dictionary and bool(parsed.get("validation", {}).get("passed", false)) and bool(parsed.get("coverage", {}).get("complete", false)) and bool(parsed.get("authorization", {}).get("runtime_trial_allowed", false)):
			_data = parsed
			_root = folder
			break
	if _variant == "c8" and not _data.is_empty() and _valid_first_cut():
		var trial: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FIRST_CUT_ROOT + "manifest.json"))
		_data["clips"]["attack1"] = trial["clips"]["attack1"]
		_overlay_files = trial["textures"]
		for key in _overlay_files:_data["textures"][key] = _overlay_files[key]
		_data["revision"] = trial["revision"]
		_data["trial_scope"] = ["attack1"]
	if _variant == "c10" and not _data.is_empty() and _valid_run_combo():
		var trial: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(RUN_COMBO_ROOT+"manifest.json"))
		for name in RUN_COMBO_CLIPS:_data["clips"][name] = trial["clips"][name]
		_overlay_files = trial["textures"]
		for key in _overlay_files:_data["textures"][key] = _overlay_files[key]
		# Per-clip weapon sets keep the accepted idle's original pixels and hilt.
		_data["weapon_sets"] = {"c10":trial["weapon_sources"]}
		_data["revision"] = trial["revision"]
		_data["trial_scope"] = RUN_COMBO_CLIPS.duplicate()
	return _data

static func continuous() -> bool:
	return data().get("schema", "") == "swordsman_runtime_layers/2"

static func samples(name: String, clock: float) -> Array:
	var c := clip(name)
	if c.is_empty():return []
	if not continuous():return [{"frame":record(name,clock),"weight":1.0}]
	var frames: Array = c["frames"]
	var tick := fposmod(clock,float(c["duration_ticks"])) if c["loop"] else clampf(clock,0,frames.size()-1)
	var index := mini(int(floor(tick)),frames.size()-1)
	var fraction: float = tick-floor(tick)
	if fraction < 0.00001:return [{"frame":frames[index],"weight":1.0}]
	var next := (index+1)%frames.size() if c["loop"] else mini(index+1,frames.size()-1)
	return [{"frame":frames[index],"weight":1.0-fraction},{"frame":frames[next],"weight":fraction}]

static func clip(name: String) -> Dictionary:
	return data().get("clips", {}).get(name, {})

static func record(name: String, clock: float) -> Dictionary:
	var c := clip(name)
	if c.is_empty():
		return {}
	var duration := float(c["duration_ticks"])
	var tick := fposmod(clock, duration) if bool(c["loop"]) else clampf(clock, 0, duration - 0.0001)
	for frame in c["frames"]:
		if tick < float(frame["start_tick"]) + float(frame["duration_ticks"]):
			return frame
	return c["frames"][-1]

static func texture(reference: Dictionary) -> Texture2D:
	var path := String(reference.get("file", ""))
	if path == "":
		return null
	if not _textures.has(path):
		data()
		var overlay_root := RUN_COMBO_ROOT if _variant == "c10" else FIRST_CUT_ROOT
		_textures[path] = load((overlay_root if _overlay_files.has(path) else _root) + path) as Texture2D
	return _textures[path]

static func anchor() -> Vector2:
	var a: Array = data().get("anchor", [448, 840])
	return Vector2(float(a[0]), float(a[1]))

static func point(value: Array) -> Vector2:
	return Vector2(float(value[0]), float(value[1]))
