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
	table.bind_swordman_weapon("",{})
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
	var job := String(profile.get("growtype","swordman"))
	var equipment_changed: bool = table.bind_swordman_weapon(definition,table.assets.get("player_clips",{}))
	# Selection and hover only change the requested skill. Rebuild moves when
	# ranks or the context for choosing native variants actually change.
	if equipment_changed or table.skill_levels != levels or table.job != job or table.weapon != weapon:
		table.configure_skills(levels,job,weapon)
	var result := _values(id)
	result["rank"] = int(levels.get(id,0))
	result["learned_rank"] = int(profile["skills"].get(id,0))
	return result

func _values(id: String) -> Dictionary:
	var move: Dictionary = table.moves.get(id, {})
	var percentages: Array = []
	for hit: Dictionary in move.get("hits", []):
		if not percentages.has(hit.get("percent", 100)):percentages.append(hit.get("percent", 100))
	var damage_lines: Array[String] = []
	# Guard enters its defensive state before the legacy adapter's hit list runs.
	if id != "guard":
		for stage: Dictionary in move.get("stages", [move]):
			for hit: Dictionary in stage.get("hits", []):
				_append_damage_line(damage_lines, hit)
				var successor: Dictionary = hit.get("native_controller", {}).get("child", {})
				if not successor.is_empty():_append_damage_line(damage_lines, successor)
	return {"mp":float(table.skill_mp_cost(move)), "cooldown":table.weapon_cooldown_ms(move, int(move.get("cool_ms", 0))) / 1000.0,
		"damage_percent":percentages, "damage_lines":damage_lines, "source":move.get("skill", "")}

func _append_damage_line(lines: Array[String], hit: Dictionary) -> void:
	var segments: Array = hit.get("segments", [])
	if hit.get("kind") == "object":
		segments = table.object(String(hit["object"])).get("segments", [])
	# Saya attacks through the field's timed radius check, independent of ANI boxes.
	if segments.is_empty() and hit.get("native_controller", {}).get("kind") != "saya_field":return
	var parts: Array[String] = []
	var percent := float(hit.get("percent", 0))
	var fixed := float(hit.get("fixed", 0))
	var additional := float(hit.get("true_damage", 0))
	if percent != 0.0:parts.append(String.num(percent).trim_suffix(".0") + "%")
	if fixed != 0.0:parts.append("固定 " + String.num(fixed).trim_suffix(".0"))
	if additional != 0.0:parts.append("额外 " + String.num(additional).trim_suffix(".0"))
	if parts.is_empty():return
	var label := "魔法攻击力：" if hit.get("damage_type") == "magical" else "物理攻击力："
	var line := label + " + ".join(parts)
	if line not in lines:lines.append(line)
