extends RefCounted
## One container per combatant. Simulation milliseconds only; no timers or global state.
var active: Dictionary = {}

func add(id: String, definition: Dictionary, rank := 1) -> bool:
	if definition.is_empty():return false
	var old: Dictionary = active.get(id,{})
	var stacks := 1
	if definition.get("stacking","refresh") == "stack":stacks = mini(int(old.get("stacks",0))+1,int(definition.get("max_stacks",1)))
	active[id] = {"id":id,"definition":definition.duplicate(true),"remaining_ms":float(definition.get("duration_ms",0)),"tick_ms":float(old.get("tick_ms",0)),"stacks":stacks,"rank":rank}
	return true

func remove(id: String) -> bool:
	return active.erase(id)

func modifiers() -> Array:
	var result: Array = []
	for effect: Dictionary in active.values():
		for mod: Dictionary in effect["definition"].get("modifiers",[]):
			var entry := mod.duplicate(true)
			entry["source"] = effect["definition"].get("name",effect["id"])
			var count := int(effect["stacks"])
			var value := float(mod["value"])+float(mod.get("per_level",0))*(int(effect["rank"])-1)
			entry["value"] = pow(value,count) if mod.get("op","add")=="mul" else value*count
			result.append(entry)
	return result

func flag(key: String) -> bool:
	for effect: Dictionary in active.values():
		if effect["definition"].get(key,false):return true
	return false

func controlled() -> bool:
	return flag("control")

func step(ms: float) -> Array:
	var events: Array = []
	for id: String in active.keys():
		var effect: Dictionary = active[id]
		var duration := maxf(0,minf(ms,float(effect["remaining_ms"])))
		effect["remaining_ms"] = maxf(0,float(effect["remaining_ms"])-ms)
		var definition: Dictionary = effect["definition"]
		var interval := float(definition.get("interval_ms",0))
		if interval > 0:
			effect["tick_ms"] = float(effect["tick_ms"])+duration
			while float(effect["tick_ms"]) >= interval:
				effect["tick_ms"] -= interval
				events.append({"type":"tick","id":id,"damage":float(definition.get("tick_damage",0))*int(effect["stacks"]),"damage_type":definition.get("damage_type","physical")})
		if float(effect["remaining_ms"]) <= 0:
			active.erase(id)
			events.append({"type":"removed","id":id})
	return events

func view() -> Array:
	return active.values().duplicate(true)
