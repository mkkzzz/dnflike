extends RefCounted
## Slot positions and shortcut bindings never duplicate item ownership counts.
const KINDS := ["weapon", "consumable", "material", "profession", "quest"]
const DEFAULT_SKILLS := ["draw", "triple", "rage_slash", "buff", "guard", ""]
static func normalize(profile: Dictionary, catalog: Dictionary) -> void:
	if not profile.has("bag_layout"):profile["bag_layout"] = {}
	if not profile.has("quick_items"):profile["quick_items"] = ["potion", "", "", "", "", ""]
	if not profile.has("skill_slots"):profile["skill_slots"] = DEFAULT_SKILLS.duplicate()
	if not profile.has("difficulty"):profile["difficulty"] = "normal"
	for kind: String in KINDS:
		var cells: Array = profile["bag_layout"].get(kind, [])
		cells.resize(32)
		var seen := {}
		for i in cells.size():
			var id: String = cells[i] if cells[i] is String else ""
			if id == "" or not catalog.has(id) or catalog[id]["kind"] != kind or available(profile, id) < 1 or seen.has(id):cells[i] = ""
			else:seen[id] = true
		for id: String in catalog:
			if catalog[id]["kind"] != kind or available(profile, id) < 1 or seen.has(id):continue
			var empty := cells.find("")
			if empty >= 0:cells[empty] = id
		profile["bag_layout"][kind] = cells

static func available(p: Dictionary, id: String) -> int:
	return int(p["inventory"].get(id, 0)) - (1 if p["equipped"] == id else 0)

static func valid(p: Dictionary, catalog: Dictionary) -> bool:
	if p.has("difficulty") and p["difficulty"] not in ["normal", "adventure", "king"]:return false
	if p.has("bag_layout"):
		if not p["bag_layout"] is Dictionary:return false
		for key in p["bag_layout"]:
			if key not in KINDS or not p["bag_layout"][key] is Array or p["bag_layout"][key].size() != 32:return false
			for id in p["bag_layout"][key]:
				if not id is String or (id != "" and (not catalog.has(id) or catalog[id]["kind"] != key)):return false
	for key in ["quick_items", "skill_slots"]:
		if not p.has(key):continue
		if not p[key] is Array or p[key].size() != 6:return false
		var seen := {}
		for id in p[key]:
			if not id is String:return false
			if id == "":continue
			if key == "quick_items" and (not catalog.has(id) or catalog[id]["kind"] != "consumable"):return false
			if key == "skill_slots" and (not id in DEFAULT_SKILLS or seen.has(id)):return false
			seen[id] = true
	return true

static func move(p: Dictionary, catalog: Dictionary, source: Dictionary, target: Dictionary) -> bool:
	normalize(p, catalog)
	var from: String = source.get("place", "")
	var to: String = target.get("place", "")
	var id: String = source.get("id", "")
	if from not in ["bag", "quick", "equipment", "skill"]:return false
	var index := int(target.get("index", -1))
	if from == "skill" and to == "skill" and index >= 0 and index < 6:
		var old := int(source.get("index", -1))
		if old < 0 or old >= 6 or p["skill_slots"][old] != id:return false
		p["skill_slots"][old] = p["skill_slots"][index]
		p["skill_slots"][index] = id
		return true
	if not catalog.has(id) or int(p["inventory"].get(id, 0)) < 1 or from == "shop":return false
	if from == "quick" and (int(source.get("index", -1)) not in range(6) or p["quick_items"][int(source["index"])] != id):return false
	if from == "equipment" and p["equipped"] != id:return false
	if from == "bag":
		var index_from := int(source.get("index", -1))
		var source_cells: Array = p["bag_layout"].get(source.get("category", ""), [])
		if available(p, id) < 1 or index_from not in range(source_cells.size()) or source_cells[index_from] != id:return false
	if to == "quick" and index in range(6) and catalog[id]["kind"] == "consumable":
		if from == "quick":p["quick_items"][int(source["index"])] = p["quick_items"][index]
		p["quick_items"][index] = id
		return true
	if to == "equipment" and catalog[id]["kind"] == "weapon":
		var old: String = p["equipped"]
		p["equipped"] = id
		if from == "bag" and old != id and available(p, id) == 0:p["bag_layout"]["weapon"][int(source["index"])] = old
		normalize(p, catalog)
		return true
	var category: String = target.get("category", "")
	if to != "bag" or category != catalog[id]["kind"] or index not in range(32):return false
	var cells: Array = p["bag_layout"][category]
	var previous: String = cells[index]
	if from == "equipment":p["equipped"] = previous
	else:
		var old := cells.find(id)
		if old < 0:return false
		cells[old] = previous
		if from == "quick":p["quick_items"][int(source["index"])] = ""
	cells[index] = id
	normalize(p, catalog)
	return true
