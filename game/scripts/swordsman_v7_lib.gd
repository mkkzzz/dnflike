extends RefCounted
## Native pixels shared by the offline review and runtime. No gameplay clocks here.
const ROOTS := ["res://assets/swordsman_v7_c6/"]
static var _root := ""
static var _data: Dictionary = {}
static var _textures: Dictionary = {}

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
		_textures[path] = load(_root + path) as Texture2D
	return _textures[path]

static func anchor() -> Vector2:
	var a: Array = data().get("anchor", [448, 840])
	return Vector2(float(a[0]), float(a[1]))

static func point(value: Array) -> Vector2:
	return Vector2(float(value[0]), float(value[1]))
