extends RefCounted
## Per-run selection for a verified native maze export. Placements, room
## contents and art stay shared with the original DGN/MAP export.

const SIDES := {"left":Vector2i.LEFT,"right":Vector2i.RIGHT,"up":Vector2i.UP,"down":Vector2i.DOWN}
const OPPOSITE := {"left":"right","right":"left","up":"down","down":"up"}
const MASK := {"right":1,"up":2,"left":4,"down":8}

var _rolls: RefCounted
var _size := Vector2i.ZERO
var basis_level := 0
var _cells: Dictionary = {}
var _pools: Dictionary = {}
var _visited: Dictionary = {}
var _cleared: Dictionary = {}
var _boss := Vector2i.ZERO
var _current := Vector2i.ZERO
var _ingress := ""
var _revisit := false
var last_error := ""

func start(export: Dictionary, roll_source: RefCounted, expected_source: Dictionary = {}) -> bool:
	last_error = ""
	if not _pools.is_empty() or roll_source == null or not roll_source.has_method("range_int"):return false
	var dungeon = export.get("dungeon")
	if export.get("schema") != "dnf_native_map/1" or not dungeon is Dictionary:return false
	var path = dungeon.get("path")
	var sha = dungeon.get("sha256")
	if not path is String or path.is_empty() or not sha is String or sha.is_empty() or not dungeon.get("crc_ok",false):return false
	if not expected_source.is_empty() and (path != expected_source.get("path") or sha != expected_source.get("sha256")):return false
	var size := _point(dungeon.get("size"))
	if size.x < 1 or size.y < 1:return false
	for field: Dictionary in dungeon.get("raw",[]):
		if field["tag"] == "[basis level]":
			basis_level = int(field["values"][0][2])
			break
	var cells := _read_cells(dungeon.get("cells"),size)
	var starts := _read_endpoint_cells(dungeon.get("start_map_raw"),cells,"start_candidate")
	var bosses := _read_endpoint_cells(dungeon.get("boss_map_raw"),cells,"boss_candidate")
	if starts.is_empty() or bosses.is_empty():return false
	# SetGridPath draws from the two source vectors separately. The local stream
	# is injected so the run can replay its rolls without using global randomness.
	var start_slot := _roll(roll_source,starts.size())
	var boss_slot := _roll(roll_source,bosses.size())
	if start_slot < 0 or boss_slot < 0:return false
	var entry: Vector2i = starts[start_slot]
	var boss: Vector2i = bosses[boss_slot]
	if entry == boss:return false
	var pools := _read_pools(dungeon,cells,entry,boss)
	if pools.is_empty():return false
	var entry_pool: Array = pools[entry]
	var map_slot := _roll(roll_source,entry_pool.size())
	if map_slot < 0:return false
	_rolls = roll_source
	_size = size
	_cells = cells
	_pools = pools
	_visited[entry] = entry_pool[map_slot]
	_boss = boss
	_current = entry
	return true

## Preflight the complete accessible run before assigning the live battle map.
func required_map_paths() -> Array[String]:
	var paths: Array[String] = []
	for pool: Array in _pools.values():
		for choice: Dictionary in pool:
			var path: String = choice["placement"]["map"]
			if path not in paths:paths.append(path)
	return paths

func room_count() -> int:
	return _pools.size()

func room_number() -> int:
	return _visited.keys().find(_current)+1

func route_view() -> Array:
	var route: Array = []
	for cell: Vector2i in _pools:
		var choice: Dictionary = _visited.get(cell,{})
		route.append({"cell":[cell.x,cell.y],"visited":_visited.has(cell),
			"current":cell == _current,"boss":cell == _boss,"mask":int(_cells[cell]["mask"]),
			"source_map_id":choice.get("map_id",0)})
	return route

func current_room() -> Dictionary:
	if _visited.is_empty():return {}
	var choice: Dictionary = _visited[_current]
	return {"cell":_current,"room_index":_current.y*_size.x+_current.x,
		"source_map_id":choice["map_id"],"placement":choice["placement"].duplicate(true),
		"ingress":_ingress,"visited_before":_revisit,"cleared":_cleared.has(_current),"boss":_current == _boss}

## Side is the departure door. A revisit reuses the original selection and
## clear state even when the new entrance would exclude that MAP on first visit.
func move(side: String) -> Dictionary:
	last_error = ""
	if not _cleared.has(_current):
		last_error = "current native room is not cleared"
		return {}
	if _cleared.has(_boss):
		last_error = "native boss room is already cleared"
		return {}
	if side not in _cells[_current]["doors"]:
		last_error = "native room has no %s exit" % side
		return {}
	var target: Vector2i = _current + SIDES[side]
	var revisited := _visited.has(target)
	if not revisited:
		var pool: Array = _pools[target]
		var slot := _roll(_rolls,pool.size())
		if slot < 0:
			last_error = "native map roll failed for cell %s" % target
			return {}
		_visited[target] = pool[slot]
	_current = target
	_ingress = OPPOSITE[side]
	_revisit = revisited
	return current_room()

## The battle supplies its remaining hostile count after normal hit/death
## processing. A stale or repeated room clear cannot finish the run.
func clear_room(cell: Vector2i, remaining_hostiles: int) -> Dictionary:
	if _visited.is_empty() or cell != _current or remaining_hostiles != 0 or _cleared.has(cell):return {}
	_cleared[cell] = true
	return {"cell":cell,"room_index":cell.y*_size.x+cell.x,"source_map_id":_visited[cell]["map_id"],
		"boss":cell == _boss,"final_room":cell == _boss}

func _read_pools(dungeon: Dictionary, cells: Dictionary, entry: Vector2i, boss: Vector2i) -> Dictionary:
	var rooms = dungeon.get("rooms")
	var placements = dungeon.get("placements")
	var slots = dungeon.get("pathgate_slots")
	var gates = dungeon.get("gate_objects")
	if not rooms is Dictionary or not placements is Array or not slots is Dictionary or not gates is Dictionary:
		last_error = "native maze lacks rooms, placements, gate slots or gate objects"
		return {}
	var specs := _read_specifications(dungeon.get("raw"),cells,
		int(dungeon.get("maze_block_index",0)))
	if specs.is_empty():
		last_error = "native maze specifications are incomplete"
		return {}
	var placed := {}
	for placement in placements:
		if not placement is Dictionary:
			last_error = "native maze placement is not a dictionary"
			return {}
		if placement.get("quest_maze","") != "":continue
		var cell := _point(placement.get("cell"))
		var path = placement.get("map")
		if not cells.has(cell) or not path is String or not rooms.has(path):
			last_error = "native maze placement references an unknown cell or map"
			return {}
		if not placed.has(cell):placed[cell] = {}
		if placed[cell].has(path):
			last_error = "native maze placement duplicates a cell map"
			return {}
		placed[cell][path] = placement
	# Reachability is checked from this run's start. The source graph may be a
	# tree or contain cycles; return paths never filter an already selected MAP.
	var pending: Array[Vector2i] = [entry]
	var arrivals := {entry:""}
	var pools := {}
	while not pending.is_empty():
		var cell: Vector2i = pending.pop_front()
		var spec: Dictionary = cells[cell]
		var ingress: String = arrivals[cell]
		var fixed: Array = [] if cell == entry else specs["boss" if cell == boss else "normal"].get(cell,[])
		var pool: Array[Dictionary] = []
		for path: String in spec["map_candidates"]:
			if not rooms.get(path) is Dictionary or not placed.get(cell,{}).has(path):
				last_error = "native maze cell %s has an unplaced map candidate %s" % [cell, path]
				return {}
			var room: Dictionary = rooms[path]
			if not _room_eligible(room,spec,cell == entry,cell == boss,ingress,fixed):continue
			var placement := _bind_gates(placed[cell][path],cell,boss,spec["doors"],slots,gates)
			if placement.is_empty():
				last_error = "native maze cell %s cannot bind all source gates for %s" % [cell, path]
				return {}
			pool.append({"map_id":int(room["map_id"]),"placement":placement})
		if pool.is_empty():
			last_error = "native maze cell %s has no eligible first-visit map" % cell
			return {}
		pools[cell] = pool
		for side: String in spec["doors"]:
			var neighbour: Vector2i = cell + SIDES[side]
			var opposite: String = OPPOSITE[side]
			if not cells.has(neighbour) or opposite not in cells[neighbour]["doors"]:
				last_error = "native maze cell %s has an unpaired %s door" % [cell, side]
				return {}
			if arrivals.has(neighbour):continue
			arrivals[neighbour] = opposite
			pending.append(neighbour)
	if not pools.has(boss):
		last_error = "native maze cannot reach the selected boss cell"
		return {}
	for cell: Vector2i in cells:
		if not cells[cell]["doors"].is_empty() and not pools.has(cell):
			last_error = "native maze cannot reach connected cell %s" % cell
			return {}
	return pools

func _room_eligible(room: Dictionary, cell: Dictionary, entry: bool, boss: bool, ingress: String, fixed: Array) -> bool:
	var map_id = room.get("map_id")
	if not _whole(map_id) or map_id <= 0 or not room.get("greed_pairs") is Array or not room.get("raw") is Array:return false
	if not fixed.is_empty() and int(map_id) not in fixed:return false
	var role := ""
	for span in room["raw"]:
		if not span is Dictionary:return false
		if span.get("tag") != "[type]":continue
		var values = span.get("values")
		if not values is Array or values.size() != 1 or not values[0] is Array or values[0].size() < 3:return false
		role = str(values[0][2])
	if role != ("[boss]" if boss else "[normal]"):return false
	if entry and (not room.get("start_area") is Array or room["start_area"].size() != 4):return false
	for pair in room["greed_pairs"]:
		if not pair is Array or pair.size() != 2 or not _whole(pair[0]) or not _whole(pair[1]):return false
		if fixed.is_empty() and int(pair[0]) != int(cell["mask"]):continue
		if entry or (int(pair[1]) & int(MASK[ingress])) != 0:return true
	return false

func _bind_gates(source: Dictionary, cell: Vector2i, boss: Vector2i, doors: Array,
		slots: Dictionary, gate_objects: Dictionary) -> Dictionary:
	if not source.get("id") is String or not source.get("gates") is Array:return {}
	var placement := source.duplicate(true)
	var bound: Array[String] = []
	for gate in placement["gates"]:
		if not gate is Dictionary:return {}
		var side = gate.get("direction")
		if not side is String or not SIDES.has(side):return {}
		if side not in doors:
			if gate.get("target_cell") != null:return {}
			continue
		var target: Vector2i = cell + SIDES[side]
		if side in bound or _point(gate.get("target_cell")) != target:return {}
		if not gate.get("anchor") is Array or gate["anchor"].size() != 3:return {}
		var kind := "boss" if cell == boss or target == boss else "normal"
		var slot = slots.get(side+"_"+kind)
		if not _whole(slot) or not gate_objects.has(str(int(slot))):return {}
		gate["kind"] = kind
		gate["object"] = str(int(slot))
		bound.append(side)
	return placement if bound.size() == doors.size() else {}

func _read_cells(rows, size: Vector2i) -> Dictionary:
	var cells := {}
	if not rows is Array:return cells
	for row in rows:
		if not row is Dictionary:return {}
		var point := _point([row.get("x"),row.get("y")])
		if point.x < 0 or point.y < 0 or point.x >= size.x or point.y >= size.y or cells.has(point):return {}
		var doors = row.get("doors")
		var candidates = row.get("map_candidates")
		var mask = row.get("mask")
		if not doors is Array or not candidates is Array or not _whole(mask):return {}
		var paths := {}
		for path in candidates:
			if not path is String or paths.has(path):return {}
			paths[path] = true
		var actual := 0
		for side in doors:
			if not MASK.has(side) or (actual & int(MASK[side])) != 0:return {}
			actual |= int(MASK[side])
		if actual != int(mask):return {}
		cells[point] = row
	return cells if cells.size() == size.x*size.y else {}

func _read_endpoint_cells(raw, cells: Dictionary, flag: String) -> Array[Vector2i]:
	var points: Array[Vector2i] = []
	if not raw is Array or raw.size()%2 != 0:return points
	for index in range(0,raw.size(),2):
		var point := _point(raw.slice(index,index+2))
		if not cells.has(point) or not cells[point].get(flag,false) or point in points:return []
		points.append(point)
	return points

func _read_specifications(raw, cells: Dictionary, selected_block: int = 0) -> Dictionary:
	if not raw is Array:return {}
	var pools := {"normal":{},"boss":{}}
	var maze_blocks := 0
	for span in raw:
		if not span is Dictionary:return {}
		var tag = span.get("tag")
		if tag == "[maze info]":
			maze_blocks += 1
			# Exporters may select a later ordinary block when earlier blocks are quest-only.
			if maze_blocks > selected_block + 1:break
			continue
		if maze_blocks != selected_block + 1:continue
		if tag == "[layered map specification]":return {}
		if tag not in ["[map specification]","[boss map specification]"]:continue
		var values = span.get("values")
		if maze_blocks == 0 or not values is Array or values.size() < 3:return {}
		var row: Array[int] = []
		for token in values:
			if not token is Array or token.size() < 3 or not _whole(token[2]):return {}
			row.append(int(token[2]))
		var point := Vector2i(row[0],row[1])
		if not cells.has(point):return {}
		pools["boss" if tag == "[boss map specification]" else "normal"][point] = row.slice(2)
	return pools if maze_blocks > selected_block else {}

func _roll(source: RefCounted, count: int) -> int:
	var result = source.range_int(0,count-1)
	return int(result) if _whole(result) and int(result) >= 0 and int(result) < count else -1

func _point(value) -> Vector2i:
	if not value is Array or value.size() != 2 or not _whole(value[0]) or not _whole(value[1]):return Vector2i(-1,-1)
	return Vector2i(int(value[0]),int(value[1]))

func _whole(value) -> bool:
	return value is int or (value is float and is_finite(value) and value == floor(value))
