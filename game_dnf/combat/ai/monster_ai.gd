extends RefCounted
## Monster AI driven by MOB fields (doc 29, F5): [sight], [attack delay], [move speed],
## attack motion reach (its own attack boxes) and [throw attack]. No per-monster code.
## Decides intent only; the battle scene executes movement, attacks and throws.

## Horizontal distance band in which the monster's own attack boxes can reach a target whose
## damage box starts near its anchor (E-INFER from box data: goblin attack1 box x 23..54).
static func reach(m: Dictionary) -> Vector2:
	var lo := INF
	var hi := -INF
	for s: Dictionary in m.get("attack_segments",[]):
		for f: Dictionary in s["frames"]:
			for b: Array in f["boxes"]:
				lo = minf(lo,float(b[0]))
				hi = maxf(hi,float(b[0])+float(b[3]))
	if lo == INF:return Vector2(0,40)
	return Vector2(lo,hi)

## Returns {"move": Vector2 direction, "face": int, "attack": bool}.
static func think(enemy: Dictionary, m: Dictionary, target: Vector2, target_z: float) -> Dictionary:
	var offset: Vector2 = target-Vector2(enemy["pos"])
	var face := 1 if offset.x >= 0 else -1
	var out := {"move":Vector2.ZERO,"face":face,"attack":false}
	if offset.length() > float(m["sight"]):return out
	var ready := float(enemy["cooldown_ms"]) <= 0 and target_z < 40
	if m.has("throw"):
		var keep := float(m["keep_distance"])
		var lane := absf(offset.y) <= 6
		if ready and lane and absf(offset.x) <= float(m["sight"]):
			out["attack"] = true
			return out
		var want_x := -face*keep
		var dx := (Vector2(enemy["pos"]).x-target.x)-want_x
		out["move"] = Vector2(-signf(dx) if absf(dx) > 12 else 0.0,signf(offset.y) if absf(offset.y) > 3 else 0.0)
		return out
	var band := reach(m)
	var ideal := (band.x+band.y)*0.5
	var ahead := absf(offset.x)
	var in_band := ahead >= band.x-4 and ahead <= band.y-6
	var lane := absf(offset.y) <= 8
	if ready and in_band and lane:
		out["attack"] = true
		return out
	var dx := ahead-ideal
	out["move"] = Vector2(face*signf(dx) if absf(dx) > 4 else 0.0,signf(offset.y) if absf(offset.y) > 3 else 0.0)
	return out
