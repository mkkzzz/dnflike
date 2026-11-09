extends RefCounted
## DGN21 fixed item group used by the special MAP rows for OBJ300.
const SOURCE := "res://data/outerwall_box_loot.json"
const ART := "res://assets_local/items_original_v4/"
const DetRng = preload("res://core/det_rng.gd")
static var _source: Dictionary = {}

static func data() -> Dictionary:
	if _source.is_empty() and FileAccess.file_exists(SOURCE):
		var doc = JSON.parse_string(FileAccess.get_file_as_string(SOURCE))
		if doc is Dictionary and doc.get("schema") == "dnf_outerwall_box_loot/1":_source = doc
	return _source

static func items() -> Dictionary:
	return data().get("items",{})

static func ready(dungeon: Dictionary) -> bool:
	if data().get("source",{}).get("sha256") != dungeon.get("sha256") or items().size() != 5:return false
	if not FileAccess.file_exists(ART+"manifest.json"):return false
	var manifest = JSON.parse_string(FileAccess.get_file_as_string(ART+"manifest.json"))
	if not manifest is Dictionary or manifest.get("schema") != "dnf_original_item_images/1":return false
	for id: String in items():
		for group: String in ["items","field_images"]:
			var key = manifest.get(group,{}).get(id)
			var path := String(manifest.get("images",{}).get(key,{}).get("file",""))
			if path.is_empty() or not ResourceLoader.exists(ART+path,"Texture2D"):return false
	return true

static func draw_count(item: Dictionary) -> int:
	var raw: Array = item.get("raw",[])
	if item.get("source_tag") != "[special passive object]" or raw.size() != 11:return 0
	if raw[0] != 300 or raw[4] != 1 or raw[5] != "[item]" or raw[6] != 0:return 0
	if raw[8] != -1 or raw[9] != -1 or raw[10] != -1:return 0
	return int(raw[7]) if raw[7] == 1 or raw[7] == 2 else 0

## CObjectDrop 853825F draws from the inclusive 0..10000 stream. 853829C
## picks the first cumulative weight strictly greater than the roll.
static func pick(roll: int) -> String:
	if roll < 0 or roll > 10000:return ""
	var upper := 0
	for row: Array in data()["groups"]["0"]:
		upper += int(row[1])
		if roll < upper:return String(row[0])
	return ""

static func prepare(draws: int, seed: int) -> Array[String]:
	var result: Array[String] = []
	var rng := DetRng.new(seed)
	for index in draws:
		var id := pick(rng.range_int(0,10000))
		if not id.is_empty():result.append(id)
	return result
