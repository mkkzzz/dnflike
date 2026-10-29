extends RefCounted
## Paid item requests only. Recovery follows simulation time; no inventory or save access.
static func valid(effect: Dictionary) -> bool:
	if effect.get("kind")!="restore":return false
	for key: String in ["hp","mp","duration_ms"]:
		var value=effect.get(key)
		if not (value is int or value is float) or not is_finite(float(value)) or value<0:return false
		if value>600000 and key=="duration_ms":return false
		if value>1000000000:return false
	return float(effect["hp"])+float(effect["mp"])>0

static func can_apply(game, effect: Dictionary) -> bool:
	if not valid(effect) or game.player.is_empty() or game.finished or game.paused or float(game.player["hp"])<=0:return false
	return (float(effect["hp"])>0 and float(game.player["hp"])<game.max_hp) or (float(effect["mp"])>0 and float(game.player["mp"])<game.max_mp)

static func apply(game, effect: Dictionary) -> bool:
	if not can_apply(game,effect):return false
	if float(effect["duration_ms"])==0:
		for resource: String in ["hp","mp"]:
			var maximum: float=game.max_hp if resource=="hp" else game.max_mp
			game.player[resource]=minf(maximum,float(game.player[resource])+float(effect[resource]))
	else:
		var entry:=effect.duplicate(true)
		entry["remaining_ms"]=float(effect["duration_ms"])
		game.item_restorations.append(entry)
	return true

static func step(game, ms: float) -> void:
	if game.player.is_empty() or game.finished or float(game.player["hp"])<=0:
		game.item_restorations.clear();return
	if game.paused:return
	for entry: Dictionary in game.item_restorations.duplicate():
		var elapsed:=minf(ms,float(entry["remaining_ms"]))
		for resource: String in ["hp","mp"]:
			var maximum: float=game.max_hp if resource=="hp" else game.max_mp
			game.player[resource]=minf(maximum,float(game.player[resource])+float(entry[resource])*elapsed/float(entry["duration_ms"]))
		entry["remaining_ms"]=maxf(0,float(entry["remaining_ms"])-elapsed)
		if entry["remaining_ms"]<=0:game.item_restorations.erase(entry)
