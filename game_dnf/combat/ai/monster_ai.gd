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
	var out := {"move":Vector2.ZERO,"face":face,"attack":false,"move_index":-1}
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
	# 原版选招规则（由 .ai 反编译提取）：无条件分支优先（多为“大招冷却好就放”），
	# 其余按 area[0]（原版 is target in attack area 的第一个数）由近到远。
	# 每条规则检查**自己那一招**的冷却，与原版 [is the skill in cooltime() N] 一致。
	if m.has("rules"):
		var cd: Dictionary = enemy.get("skill_cd", {})
		for rule: Dictionary in m["rules"]:
			var skill := int(rule["skill"])
			if float(cd.get(skill, 0.0)) > 0:continue
			var area: Array = rule.get("area", [])
			if area.is_empty():
				out["attack"] = true
				out["move_index"] = skill
				return out
			if absf(offset.x) <= float(area[0]) + 4 and absf(offset.y) <= 24:
				out["attack"] = true
				out["move_index"] = skill
				return out
		# 没有规则可用：靠近到最小范围那一招
		if not (m["rules"] as Array).is_empty():
			var first: Dictionary = m["rules"][m["rules"].size() - 1]
			var span: Array = first.get("area", [])
			if not span.is_empty():
				var gap := absf(offset.x) - float(span[0])
				out["move"] = Vector2(face*signf(gap) if absf(gap) > 8 else 0.0,
					signf(offset.y) if absf(offset.y) > 3 else 0.0)
				return out
	# 多套招式（BOSS）：按「当前距离落在哪一招的判定范围」选招。
	# 范围来自该招 ANI 的 damage 判定盒，不是写死的模板。
	if m.has("moves"):
		var gap_x := absf(offset.x)
		var same_lane := absf(offset.y) <= 8
		if ready and same_lane:
			var picks: Array = []
			for index in (m["moves"] as Array).size():
				var candidate: Dictionary = m["moves"][index]
				var span: Array = candidate.get("reach", [])
				if span.size() < 2:continue
				if gap_x >= float(span[0]) - 4 and gap_x <= float(span[1]) - 6:
					picks.append([index, float((candidate.get("atk", {}) as Dictionary).get("damage_bonus", 0))])
			if not picks.is_empty():
				# 多招都打得到时，按 .mob 里的招式顺序取第一个（原版顺序，不额外加权）。
				out["attack"] = true
				out["move_index"] = int(picks[0][0])
				return out
		# 没有能命中的招：朝最近一招的有效距离走过去。
		var nearest := INF
		for candidate: Dictionary in m["moves"]:
			var span: Array = candidate.get("reach", [])
			if span.size() < 2:continue
			nearest = minf(nearest, clampf(gap_x, float(span[0]), float(span[1])))
		var approach := gap_x - nearest
		out["move"] = Vector2(face*signf(approach) if absf(approach) > 4 else 0.0,
			signf(offset.y) if absf(offset.y) > 3 else 0.0)
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
