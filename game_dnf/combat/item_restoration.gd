extends RefCounted
## Shared HP/MP restoration follows simulation time; no inventory or save access.
static func valid(effect: Dictionary) -> bool:
	if effect.get("kind")!="restore":return false
	for key: String in ["hp","mp","duration_ms"]:
		var value=effect.get(key)
		if not (value is int or value is float) or not is_finite(float(value)) or value<0:return false
		if value>600000 and key=="duration_ms":return false
		if value>1000000000:return false
	if effect.has("cure") and effect["cure"]!="bleed":return false
	if effect.has("self_stun"):
		var stun=effect["self_stun"]
		if not stun is Dictionary or not stun.has_all(["chance_percent","status_level","duration_ms"]):return false
		for key: String in ["chance_percent","status_level","duration_ms"]:
			var value=stun[key]
			var limit:=600000 if key=="duration_ms" else 100
			if not (value is int or value is float) or not is_finite(float(value)) or value!=floorf(value) or value<=0 or value>limit:return false
	return float(effect["hp"])+float(effect["mp"])>0

static func can_apply(game, effect: Dictionary) -> bool:
	if not valid(effect) or game.player.is_empty() or game.finished or game.paused or float(game.player["hp"])<=0:return false
	return (float(effect["hp"])>0 and float(game.player["hp"])<game.max_hp) \
		or (float(effect["mp"])>0 and float(game.player["mp"])<game.max_mp) \
		or (effect.get("cure")=="bleed" and game.numeric_player!=null and game.numeric_player.effects.active.has("bleed"))

static func apply(game, effect: Dictionary) -> bool:
	if not can_apply(game,effect):return false
	if float(effect["duration_ms"])==0:
		for resource: String in ["hp","mp"]:
			var maximum: float=game.max_hp if resource=="hp" else game.max_mp
			game.player[resource]=minf(maximum,float(game.player[resource])+float(effect[resource]))
	else:
		queue(game,float(effect["hp"]),float(effect["mp"]),float(effect["duration_ms"]))
	if effect.get("cure")=="bleed":
		game.apply_effect({"kind":"remove_effect","id":"bleed"})
	var stun: Dictionary=effect.get("self_stun",{})
	if not stun.is_empty() and game.numeric_player!=null and game.rng.range_int(0,0x7fffffff)%100<int(stun["chance_percent"]):
		if game.numeric_player.apply_item_stun(int(stun["status_level"]),int(stun["duration_ms"])):
			if not String(game.player["action"]).is_empty():game.end_action()
			game.bus.emit("combat.status",{"target":game.player["id"],"id":"stun","change":"added"})
	return true

static func queue(game, hp: float, mp: float, duration: float) -> Dictionary:
	var entry := {"hp":hp,"mp":mp,"duration_ms":duration,"remaining_ms":duration}
	game.item_restorations.append(entry)
	return entry

static func step(game, ms: float) -> void:
	if game.player.is_empty() or game.finished or float(game.player["hp"])<=0:
		game.item_restorations.clear();return
	if game.paused:return
	for entry: Dictionary in game.item_restorations.duplicate():
		advance(game,entry,ms)

static func advance(game, entry: Dictionary, ms: float) -> void:
	var elapsed := minf(ms,float(entry["remaining_ms"]))
	for resource: String in ["hp","mp"]:
		var maximum: float = game.max_hp if resource=="hp" else game.max_mp
		game.player[resource] = minf(maximum,float(game.player[resource])+float(entry[resource])*elapsed/float(entry["duration_ms"]))
	entry["remaining_ms"] -= elapsed
	if entry["remaining_ms"] <= 0:game.item_restorations.erase(entry)
