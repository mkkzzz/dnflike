extends RefCounted
## Read-only UI projection of the same compiled SKL and move table as combat.
const ContentDB = preload("res://content/api/content_db.gd")
const MoveTable = preload("res://combat/data/move_table.gd")
var table = MoveTable.new()
func _init() -> void:
	var db = ContentDB.new()
	if not db.load_files("res://assets_local/manifest.json", "res://data/combat.json", "res://data/override"):return
	var assets: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets_local/combat/manifest.json"))
	table.build(db, db.rules(), assets)

func get_skill(id: String, rank := 1) -> Dictionary:
	table.configure_skills({id:rank})
	var move: Dictionary = table.moves.get(id, {})
	var percentages: Array = []
	for hit: Dictionary in move.get("hits", []):
		if not percentages.has(hit.get("percent", 100)):percentages.append(hit.get("percent", 100))
	return {"mp":float(move.get("mp", 0)), "cooldown":float(move.get("cool_ms", 0)) / 1000.0, "damage_percent":percentages, "source":move.get("skill", "")}
