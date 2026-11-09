extends RefCounted
## Hidden OBJ771 monsters selected when the source map catalog is loaded.
const MOBS := {250:"monster/starfish/starfish.mob",260:"monster/zealot/raxy-a.mob"}
const GRAVITY := -1500.0
static var _catalog: Dictionary = {}

static func rows(item: Dictionary) -> Array:
	var raw: Array = item.get("raw",[])
	if item.get("source_tag") != "[special passive object]" or raw.size() < 11 or raw[0] != 771:return []
	var count := int(raw[4])
	if raw.size() != 5+6*count:return []
	var result: Array = []
	for at in range(5,raw.size(),6):
		if raw[at] != "[monster]" or not MOBS.has(int(raw[at+1])):return []
		if raw[at+2] < 1 or raw[at+2] > 200 or raw[at+4] <= 0:return []
		result.append(raw.slice(at+1,at+6))
	return result

static func prepare_catalog(dungeon: Dictionary, rolls = null) -> void:
	var key: String = dungeon["sha256"]
	if _catalog.has(key):return
	if rolls == null:
		rolls = RandomNumberGenerator.new()
		rolls.randomize()
	var maps := {}
	for room: Dictionary in dungeon["rooms"].values():
		var candidates := {}
		var objects: Array = room["objects"]
		for node in objects.size():
			var children := rows(objects[node])
			if children.is_empty():continue
			candidates[node] = select(children,rolls)
		if not candidates.is_empty():maps[room["sha256"]] = candidates
	_catalog[key] = maps

static func prepared(dungeon_sha: String, map_sha: String, node: int) -> Array:
	return _catalog.get(dungeon_sha,{}).get(map_sha,{}).get(node,[]).duplicate(true)

## 1031 CMap::set_map 834E5E8..6B4 uses a truncated percentage and an inclusive check.
static func select(children: Array, rolls) -> Array:
	var roster: Array = []
	for row: Array in children:
		var threshold := int(float(row[2])*100.0/float(row[3]))
		if rolls.randi_range(0,99) <= threshold:
			roster.append({"mob":MOBS[int(row[0])],"level":int(row[1]),"force_ground":row[4]!=-1})
	return roster

## A35970 sends the ground branch or the style 1, eight-byte launch payload.
## The receiver applies the two signed planar axes and a mode 2 jump height.
static func launch(rolls, force_ground: bool, height: float) -> Dictionary:
	if rolls.range_int(0,0x7fffffff)%2 == 0 or force_ground:return {}
	var vx: int = 50+rolls.range_int(0,0x7fffffff)%100
	var vy: int = 25+rolls.range_int(0,0x7fffffff)%50
	var sx := 1 if rolls.range_int(0,0x7fffffff)%2 == 0 else -1
	var sy := 1 if rolls.range_int(0,0x7fffffff)%2 == 0 else -1
	var lift: int = 40+rolls.range_int(0,0x7fffffff)%60
	return {"z":height+10.0,"velocity":Vector2(sx*vx,sy*vy),"lift":lift}
