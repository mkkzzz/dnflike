extends RefCounted

const HitJudge = preload("res://combat/hit/hit_judge.gd")

## The final header field of a special row is its nested payload count.
static func supports(item: Dictionary) -> bool:
	var raw: Array = item.get("raw", [])
	var path := String(item.get("obj","")).to_lower()
	if raw.size() < 4 or not path.contains("breakableobject/"):return false
	match item.get("source_tag"):
		"[passive object]":return raw.size() == 4
		"[special passive object]":
			if raw.size() < 5:return false
			var count := int(raw[4])
			if raw.size() != 5+6*count:return false
			if count == 0:return true
			for at in range(5,raw.size(),6):
				if raw[at] in ["[item]", "[monster]", "[trap]"]:return true
	return false

static func create(item: Dictionary, source: Dictionary, damage_boxes: Array, node: int) -> Dictionary:
	var anchor: Array = item["anchor"]
	var pos := Vector3(float(anchor[0]), float(anchor[1]), float(anchor[2]))
	return {
		"id": "%s#%d" % [item["obj"], node], "node": node, "native_breakable": source,
		"source_path": String(item["obj"]).to_lower(),
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
