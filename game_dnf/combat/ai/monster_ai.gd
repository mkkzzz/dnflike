extends RefCounted
## Monster AI driven by MOB fields (doc 29, F5): [sight], [attack delay], [move speed],
## attack motion reach (its own attack boxes) and [throw attack]. No per-monster code.
## Decides intent only; the battle scene executes movement, attacks and throws.
const CompanionProgram = preload("res://combat/action/companion_program.gd")

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

## Attack selection and movement use the same allowed distance band. The small
## margins account for the target's damage box starting near its anchor.
static func attack_band(span: Array) -> Vector2:
	if span.size() < 2:return Vector2.ZERO
	var lo := float(span[0]) - 4.0
	var hi := float(span[1]) - 6.0
	return Vector2(minf(lo, hi), maxf(lo, hi))


## 0x877CE0. Use the target's MOB/CHR dimensions and integer map axes.
static func native_target_in_attack_area(origin: Vector2i, facing: int, target: Dictionary, area: Array) -> bool:
	if (int(area[0]) == 0 and int(area[2]) == 0) or (int(area[4]) == 0 and int(area[6]) == 0):
		return false
	var delta := Vector2i(target["position"])-origin
	var quarter_size := Vector2i(target["size"])/4
	var front := delta.x*facing
	return front+quarter_size.x >= -int(area[2]) and front-quarter_size.x <= int(area[0]) \
		and (delta.x <= -int(area[1]) or delta.x >= int(area[3])) \
		and delta.y+quarter_size.y >= -int(area[4]) and delta.y-quarter_size.y <= int(area[6]) \
		and (delta.y <= -int(area[5]) or delta.y >= int(area[7]))


## 0x883750 / 0x8783A0. The battle supplies eligible hostile actor targets in
## room order and polls while the source actor is free to start an attack.
static func native_attack_poll(actor: Dictionary, policy: Dictionary, targets: Array, random_u31: Callable) -> Dictionary:
	var elapsed := int(actor["elapsed_ms"])
	var deadline := int(actor["next_attack_ms"])
	if elapsed < maxi(int(policy["initial_ms"]), deadline):
		return {"slot":-1, "next_attack_ms":deadline}
	var spread := int(policy["delay_spread_ms"])
	@warning_ignore("integer_division")
	deadline = elapsed+int(policy["delay_ms"])+int(random_u31.call())%spread-spread/2
	var origin := Vector2i(actor["position"])
	var facing := int(actor["facing"])
	var candidates: Array[int] = []
	for row: Dictionary in policy["slots"]:
		var eligible := false
		for target: Dictionary in targets:
			if not native_target_in_attack_area(origin, facing, target, row["area"]):
				continue
			if target["down"] and int(random_u31.call())%10000 >= int(policy["down_gate_percent"])*100:
				continue
			if int(random_u31.call())%10000 < int(row["standing_percent"])*100:
				eligible = true
				break
		# 0x878710 consumes the fallback draw even at a zero chance.
		if eligible or int(random_u31.call())%10000 < int(row["no_target_percent"])*100:
			candidates.append(int(row["slot"]))
	var slot := -1
	if not candidates.is_empty():
		slot = candidates[int(random_u31.call())%candidates.size()]
	return {"slot":slot, "next_attack_ms":deadline}


## Returns {"move": Vector2 direction, "face": int, "attack": bool}.
static func think(enemy: Dictionary, m: Dictionary, target: Vector2, target_z: float, blind := false) -> Dictionary:
	var offset: Vector2 = target-Vector2(enemy["pos"])
	var face := 1 if offset.x >= 0 else -1
	var out := {"move":Vector2.ZERO,"face":face,"attack":false,"move_index":-1,"visible":false}
	if blind:
		# 8B5CC1 halves monster back vision. 880487..8804D0 tests the
		# projected distance against trunc(back_vision * 1.4).
		var reduced_sight := int(float(m["sight"])*0.5)
		if reduced_sight != 0 and CompanionProgram.target_distance(enemy["pos"],target) > int(reduced_sight*1.4):
			out["face"] = int(enemy["facing"])
			return out
	elif offset.length() > float(m["sight"]):return out
	out["visible"] = true
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
		var moves: Array = m.get("moves", [])
		for rule: Dictionary in m["rules"]:
			var skill := int(rule["skill"])
			if skill < 0 or skill >= moves.size():continue
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
		for rule_index in range((m["rules"] as Array).size() - 1, -1, -1):
			var fallback: Dictionary = m["rules"][rule_index]
			var fallback_skill := int(fallback["skill"])
			if fallback_skill < 0 or fallback_skill >= moves.size():continue
			var span: Array = fallback.get("area", [])
			if span.is_empty():continue
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
				var band := attack_band(span)
				if span.size() < 2 or (candidate.get("segments", []) as Array).is_empty():continue
				if gap_x >= band.x and gap_x <= band.y:
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
			var band := attack_band(span)
			if span.size() < 2 or (candidate.get("segments", []) as Array).is_empty():continue
			nearest = minf(nearest, clampf(gap_x, band.x, band.y))
		if nearest == INF:return out
		var approach := gap_x - nearest
		out["move"] = Vector2(face*signf(approach) if absf(approach) > 0.01 else 0.0,
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
