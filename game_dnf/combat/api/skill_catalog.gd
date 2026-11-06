extends RefCounted
## Read-only UI projection of the same compiled SKL and move table as combat.
const ContentDB = preload("res://content/api/content_db.gd")
const MoveTable = preload("res://combat/data/move_table.gd")
const Numbers = preload("res://stats/api/numbers.gd")
var table = MoveTable.new()
func _init() -> void:
	var db = ContentDB.new()
	if not db.load_files("res://assets_local/manifest.json", "res://data/combat.json", "res://data/override"):return
	var assets: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets_local/combat/manifest.json"))
	table.build(db, db.rules(), assets)

func get_skill(id: String, rank := 1) -> Dictionary:
	# Standalone legacy preview has a fixed context, independent of prior UI calls.
	table.configure_skills({id:rank},"weaponmaster","katana")
	return _values(id)

## Same purchased -> effective rank projection and variant context as combat.
## A zero rank remains unlearned; the table's first row is only a preview.
func get_profile_skill(id: String, profile: Dictionary) -> Dictionary:
	var cfg := Numbers.shared_config()
	id = Numbers.SkillIdentity.canonical(id,cfg)
	var levels := Numbers.Skills.effective_levels(profile["skills"],cfg)
	var uid := String(profile.get("equipment",{}).get("weapon",""))
	var definition := String(profile.get("gear",{}).get(uid,{}).get("definition",""))
	var weapon := String(cfg["equipment"].get(definition,{}).get("weapon","katana"))
	table.configure_skills(levels,String(profile.get("growtype","swordman")),weapon)
	var result := _values(id)
	result["rank"] = int(levels.get(id,0))
	result["learned_rank"] = int(profile["skills"].get(id,0))
	return result

func _values(id: String) -> Dictionary:
	var move: Dictionary = table.moves.get(id, {})
	var percentages: Array = []
	for hit: Dictionary in move.get("hits", []):
		if not percentages.has(hit.get("percent", 100)):percentages.append(hit.get("percent", 100))
	return {"mp":float(move.get("mp", 0)), "cooldown":float(move.get("cool_ms", 0)) / 1000.0, "damage_percent":percentages, "source":move.get("skill", "")}
