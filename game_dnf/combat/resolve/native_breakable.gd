extends RefCounted

const HitJudge = preload("res://combat/hit/hit_judge.gd")
const NativeBoxLoot = preload("res://loot/native_box.gd")
const NativePotMonsters = preload("res://combat/resolve/native_pot_monsters.gd")
const OBJECT_IDS := [300, 770, 771]

## The final header field of a special row is its nested payload count.
static func supports(item: Dictionary) -> bool:
	var raw: Array = item.get("raw", [])
	if raw.size() < 4 or int(raw[0]) not in OBJECT_IDS:return false
	match item.get("source_tag"):
		"[passive object]":return raw.size() == 4
		"[special passive object]":return (raw.size() == 5 and int(raw[4]) == 0) or NativeBoxLoot.draw_count(item) > 0 or not NativePotMonsters.rows(item).is_empty()
	return false

static func create(item: Dictionary, source: Dictionary, damage_boxes: Array, node: int) -> Dictionary:
	var anchor: Array = item["anchor"]
	var pos := Vector3(float(anchor[0]), float(anchor[1]), float(anchor[2]))
	return {
		"id": "%s#%d" % [item["obj"], node], "node": node, "native_breakable": source,
		"pos": Vector2(pos.x, pos.y), "z": pos.z, "facing": 1, "hp": int(source["hp"]),
		"stage": 0, "broken": false, "damage_boxes": HitJudge.world_boxes(damage_boxes, pos, 1),
	}

## Original state 1 subtracts at 7FAEB7. A36600 advances one stage per
## depletion and restores base HP. A368D0 requests removal at the final stage.
static func apply_damage(prop: Dictionary, amount: int) -> bool:
	var source: Dictionary = prop["native_breakable"]
	if amount <= 0 or prop["broken"]:return false
	prop["hp"] = int(prop["hp"]) - amount
	if int(prop["hp"]) > 0 or int(prop["stage"]) >= int(source["stages"]):return false
	prop["stage"] = int(prop["stage"]) + 1
	prop["hp"] = int(source["hp"])
	prop["broken"] = int(prop["stage"]) == int(source["stages"]) and bool(source["destroy_on_final_stage"])
	return bool(prop["broken"])
