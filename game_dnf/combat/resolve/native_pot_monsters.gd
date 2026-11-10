extends RefCounted
## Hidden [monster] rows on special MAP objects, resolved through the original
## monster index instead of a dungeon-specific numeric whitelist.
const CATALOG := "res://data/monster_catalog.json"
const SPRING_MOB := "monster/starfish/starfish.mob"
const GRAVITY := -1500.0
static var _catalog: Dictionary = {}
static var _mob_by_id: Dictionary = {}

static func rows(item: Dictionary) -> Array:
	var raw: Array = item.get("raw",[])
	if item.get("source_tag") != "[special passive object]" or raw.size() < 11:return []
	var count := int(raw[4])
	if raw.size() != 5+6*count:return []
	var result: Array = []
	for at in range(5,raw.size(),6):
		if raw[at] != "[monster]":continue
		var monster_id := int(raw[at+1])
		var mob := _mob_path(monster_id)
		if mob.is_empty() or raw[at+2] < 1 or raw[at+2] > 200 or raw[at+3] <= 0 or raw[at+4] <= 0:return []
		result.append({"monster_id":monster_id,"mob":mob,"level":int(raw[at+2]),
			"chance":int(raw[at+3]),"limit":int(raw[at+4]),"force_ground":int(raw[at+5]) != -1})
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

static func reset_catalog() -> void:
	_catalog.clear()

static func prepared(dungeon_sha: String, map_sha: String, node: int) -> Array:
	return _catalog.get(dungeon_sha,{}).get(map_sha,{}).get(node,[]).duplicate(true)

## 1031 CMap::set_map 834E5E8..6B4 uses a truncated percentage and an inclusive check.
static func select(children: Array, rolls) -> Array:
	var roster: Array = []
	for row in children:
		var data: Dictionary = row if row is Dictionary else {}
		if data.is_empty():continue
		var threshold := int(float(data["chance"])*100.0/float(data["limit"]))
		var roll: int = rolls.randi_range(0,99) if rolls.has_method("randi_range") else rolls.range_int(0,99)
		if roll <= threshold:
			roster.append({"mob":String(data["mob"]),"monster_id":int(data["monster_id"]),
				"level":int(data["level"]),"force_ground":bool(data["force_ground"])})
	return roster

static func mob_path(monster_id: int) -> String:
	return _mob_path(monster_id)

static func _mob_path(monster_id: int) -> String:
	if _mob_by_id.is_empty():
		var doc = JSON.parse_string(FileAccess.get_file_as_string(CATALOG))
		if doc is Dictionary and doc.get("schema") == "dnf_monster_catalog/1":
			for entry in doc.get("monsters",{}).values():
				if entry is Dictionary and entry.has("id"):
					_mob_by_id[str(int(entry["id"]))] = String(entry.get("path","")).to_lower()
	return String(_mob_by_id.get(str(monster_id),"")).to_lower()

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
