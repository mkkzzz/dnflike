extends RefCounted
## Native maze special passive-object item groups compiled from DGN/STK sources.
const SOURCE := "res://data/native_box_loot.json"
const ART := "res://assets_local/items_original_v4/"
const DetRng = preload("res://core/det_rng.gd")
static var _source: Dictionary = {}
static var _active: Dictionary = {}

static func data() -> Dictionary:
	if _source.is_empty() and FileAccess.file_exists(SOURCE):
		var doc = JSON.parse_string(FileAccess.get_file_as_string(SOURCE))
		if doc is Dictionary and doc.get("schema") == "dnf_native_box_loot/1":_source = doc
	return _source

static func items() -> Dictionary:
	return data().get("items",{})

static func required(dungeon: Dictionary) -> bool:
	for room: Dictionary in dungeon.get("rooms",{}).values():
		for item: Dictionary in room.get("objects",[]):
			var raw: Array = item.get("raw",[])
			if item.get("source_tag") != "[special passive object]" or raw.size() < 11:continue
			var count := int(raw[4])
			if raw.size() != 5+6*count:continue
			for at in range(5,raw.size(),6):
				if raw[at] != "[item]":continue
				var draws := int(raw[at+2])
				if draws < 0 and at+3 < raw.size():draws = int(raw[at+3])
				if draws > 0:return true
	return false

static func ready(dungeon: Dictionary) -> bool:
	_active = data().get("dungeons",{}).get(String(dungeon.get("sha256","")),{})
	if _active.is_empty() or _active.get("source",{}).get("path") != dungeon.get("path") or items().is_empty():
		return false
	if not FileAccess.file_exists(ART+"manifest.json"):return false
	var manifest = JSON.parse_string(FileAccess.get_file_as_string(ART+"manifest.json"))
	if not manifest is Dictionary or manifest.get("schema") != "dnf_original_item_images/1":return false
	var used := {}
	for entries in _active.get("groups",{}).values():
		for entry in entries:used[String(entry[0])] = true
	for id: String in used:
		for group: String in ["items","field_images"]:
			var key = manifest.get(group,{}).get(id)
			var path := String(manifest.get("images",{}).get(key,{}).get("file",""))
			if path.is_empty() or not ResourceLoader.exists(ART+path,"Texture2D"):return false
	return true

static func draw_count(item: Dictionary) -> int:
	var raw: Array = item.get("raw",[])
	if item.get("source_tag") != "[special passive object]" or raw.size() < 11:return 0
	var count := int(raw[4])
	if raw.size() != 5+6*count:return 0
	for at in range(5,raw.size(),6):
		if raw[at] != "[item]":continue
		var group := str(int(raw[at+1]))
		if not _active.get("groups",{}).has(group):continue
		var draws := int(raw[at+2])
		if draws < 0 and at+3 < raw.size():draws = int(raw[at+3])
		if draws > 0:return draws
	return 0

## CObjectDrop 853825F draws from the inclusive 0..10000 stream. 853829C
## picks the first cumulative weight strictly greater than the roll.
static func pick(roll: int, group := "0") -> String:
	if roll < 0 or roll > 10000:return ""
	var upper := 0
	for row: Array in _active.get("groups",{}).get(group,[]):
		upper += int(row[1])
		if roll < upper:return String(row[0])
	return ""

static func prepare(draws: int, seed: int, group := "0") -> Array[String]:
	var result: Array[String] = []
	var rng := DetRng.new(seed)
	for index in draws:
		var id := pick(rng.range_int(0,10000),group)
		if not id.is_empty():result.append(id)
	return result
