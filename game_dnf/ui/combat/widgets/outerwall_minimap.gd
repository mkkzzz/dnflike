extends RefCounted
## The original ordinary solo DungeonMinimap, using the active run's DGN21 cells.
const ORDER := 60
const MANIFEST := "res://assets_local/outerwall_minimap_v1/manifest.json"
const TextureCache = preload("res://view/texture_cache.gd")
const DOORS := {Vector2i.RIGHT:1,Vector2i.UP:2,Vector2i.LEFT:4,Vector2i.DOWN:8}

var _loaded := false
var _atlas: Texture2D
var _items: Dictionary = {}
var _layout: Dictionary = {}

func paint(h, state: Dictionary) -> void:
	var route: Array = state.get("route",[])
	if route.is_empty() or not route[0].has("source_map_id"):return
	if not _loaded:
		_loaded = true
		var manifest = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
		if manifest is Dictionary and manifest.get("schema") == "dnf_outerwall_minimap/1":
			_atlas = TextureCache.load_texture(manifest["texture"])
			_items = manifest["items"]
			_layout = manifest["layout"]
	if _atlas == null:return
	var current := {}
	for room: Dictionary in route:
		if room["current"]:
			current = room
			break
	if current.is_empty():return
	var pitch := int(_layout["pitch"])
	var x: float = h.canvas_width(state) + int(_layout["window_right"]) - int(_layout["grid"][0])*pitch
	var window := Vector2(x,int(_layout["window_top"]))
	_piece(h,"board",window,Color(1,1,1,float(_layout["alpha"])/255.0))
	# 0x102D83C: leave the title row above the first room.
	var origin := window + Vector2(0,int(_layout["grid_top"]))
	var now := Time.get_ticks_msec()
	for room: Dictionary in route:
		var frame := room_frame(room,current,now)
		if frame < 0:continue
		var at := origin + Vector2(_cell(room))*pitch
		_piece(h,"room_%d"%frame,at)
		if room["current"]:
			_piece(h,"player",at)
		elif room["boss"]:
			_piece(h,"boss",at)

static func room_frame(room: Dictionary, current: Dictionary, ms: int) -> int:
	# 0x102DC57, 0x102D0F0: the run's actual boss has the solo question tile until entered.
	if room["boss"] and not room["current"]:return 120
	if room["visited"]:
		# 0x102DA92, 0xE47F50, 0x4B1E40: three LCG draws from MAP ID * x * y.
		var cell := _cell(room)
		var seed := int(room["source_map_id"])*cell.x*cell.y
		for index in range(3):seed = (seed*0x41C64E6D+0x3039)&0xFFFFFFFF
		var variant := (seed >> 16)&3
		var mask := int(room["mask"])
		return (mask-1)*8 + variant + (4 if room["current"] else 0)
	# 0x102D908..92F, 0x102DF10: only a door from the current non-boss room reveals an unknown.
	var door := int(DOORS.get(_cell(room)-_cell(current),0))
	if current["boss"] or (int(current["mask"])&door) == 0:return -1
	return 121 if ms%500 < 250 else 120

static func _cell(room: Dictionary) -> Vector2i:
	var cell: Array = room["cell"]
	return Vector2i(int(cell[0]),int(cell[1]))

func _piece(h, key: String, point: Vector2, modulate := Color.WHITE) -> void:
	var item: Dictionary = _items[key]
	var r: Array = item["rect"]
	var offset: Array = item["offset"]
	var at := point + Vector2(float(offset[0]),float(offset[1]))
	var source := Rect2(float(r[0]),float(r[1]),float(r[2]),float(r[3]))
	h.trace.append(["minimap",key,at])
	h.draw_texture_rect_region(_atlas,Rect2(at,source.size),source,modulate)
