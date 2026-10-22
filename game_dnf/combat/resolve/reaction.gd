extends RefCounted
## Hit reaction and body physics driven by original ATK fields (doc 29, F4).
## Handled ATK fields (see combat/fields/handled.json): damage reaction, attack direction,
## push aside, lift up. Units are scaled by the adapt layer's "reaction" table (E-ADAPT).
const MoveTable = preload("res://combat/data/move_table.gd")

## Applies one hit's reaction to a body dictionary. Returns the reaction kind actually used:
## "none" (damage only), "stagger", "launch", "down" (knocked down in place) or "air".
## Body fields: pos, z, vz, state, stun_ms, push_v, push_ms, hit_motion, bounced, down_ms.
static func apply(body: Dictionary, atk: Dictionary, attacker_facing: int, rp: Dictionary, recovery: float, lift_override := -1.0) -> String:
	var reaction := MoveTable.enum_value(atk,"damage_reaction","[damage]")
	var direction := MoveTable.enum_value(atk,"attack_direction","[hit horizon]")
	var push := float(atk.get("push_aside",0))
	var lift := lift_override if lift_override >= 0 else float(atk.get("lift_up",0))
	var airborne := float(body["z"]) > 0 or float(body["vz"]) > 0
	var downed := String(body["state"]) == "down"
	if reaction == "[none]" and not airborne:return "none"
	if push > 0:
		body["push_v"] = attacker_facing*push*float(rp["push_speed_per_unit"])
		body["push_ms"] = float(rp["push_decay_ms"])
	# Original motion pair: [hit down] uses damage motion 1, horizontal hits damage motion 2 (E-INFER).
	body["hit_motion"] = "damage1" if direction == "[hit down]" else "damage2"
	if airborne or reaction == "[down]" or (downed and lift > 0):
		if lift > 0:
			body["vz"] = maxf(float(body["vz"]),lift*float(rp["lift_speed_per_unit"]))
			body["z"] = maxf(1.0,float(body["z"]))
			body["state"] = "air"
			body["bounced"] = false
			return "air" if airborne else "launch"
		if airborne:
			body["state"] = "air"
			return "air"
		body["state"] = "down"
		body["down_ms"] = 0.0
		return "down"
	if downed:
		body["down_ms"] = 0.0
		return "down"
	body["state"] = "hurt"
	body["stun_ms"] = float(rp["stun_base_ms"])*float(rp["stun_reference_recovery"])/maxf(1.0,recovery)
	return "stagger"

## Advances knockback slide, gravity, landing/bounce and the down/get-up hold.
## `move` is a Callable(from: Vector2, delta: Vector2) -> Vector2 that applies world collision.
## Returns "landed" on the frame a launched body comes to rest on the ground, else "".
static func step_body(body: Dictionary, ms: float, gravity: float, rp: Dictionary, move: Callable) -> String:
	var dt := ms/1000.0
	var result := ""
	if float(body.get("push_ms",0)) > 0:
		var decay := float(rp["push_decay_ms"])
		var v := float(body["push_v"])*float(body["push_ms"])/decay
		body["pos"] = move.call(Vector2(body["pos"]),Vector2(v*dt,0))
		body["push_ms"] = maxf(0,float(body["push_ms"])-ms)
	var state := String(body["state"])
	if float(body["z"]) > 0 or float(body["vz"]) > 0:
		body["z"] = maxf(0,float(body["z"])+float(body["vz"])*dt)
		body["vz"] = float(body["vz"])-gravity*dt
		if float(body["z"]) == 0 and float(body["vz"]) < 0:
			if state == "air" and not body.get("bounced",false) and float(body["vz"]) < -float(rp["bounce_min_speed"]):
				body["vz"] = float(rp["bounce_speed"])
				body["z"] = 1.0
				body["bounced"] = true
			else:
				body["vz"] = 0.0
				if state == "air":
					body["state"] = "down"
					body["down_ms"] = 0.0
					result = "landed"
	elif state == "hurt":
		body["stun_ms"] = maxf(0,float(body["stun_ms"])-ms)
		if float(body["stun_ms"]) <= 0:body["state"] = "idle"
	elif state == "down":
		body["down_ms"] = float(body["down_ms"])+ms
		if float(body["down_ms"]) >= float(rp["down_hold_ms"])+float(rp["getup_ms"]):body["state"] = "idle"
	return result

## Down-motion clock: lying pose during the hold, then the original get-up frames.
## Original down ANIs hold frames 2-3 for 10 s each and get up on the last frame (E-PARSE).
static func down_clock(body: Dictionary, rp: Dictionary, timeline: Array) -> float:
	var held := float(body.get("down_ms",0))
	var hold := float(rp["down_hold_ms"])
	if timeline.size() < 3:return held
	if held < hold:return float(timeline[2]["start_ms"])+minf(held,float(timeline[2]["end_ms"])-float(timeline[2]["start_ms"])-1)
	return float(timeline[-1]["start_ms"])+(held-hold)*maxf(0.001,float(timeline[-1]["end_ms"])-float(timeline[-1]["start_ms"]))/float(rp["getup_ms"])

## Damage = attack power x percent (normal attacks: 100 + [damage bonus]; skills: level info).
static func damage(power: float, percent: float) -> int:
	return maxi(1,roundi(power*percent/100.0))
