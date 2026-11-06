extends RefCounted
## Verified client state 24 / skills 20, 21, 22. Source ANI remains unmodified.
## 0xCC8AA0: cast minus frame1..3, divided by cast speed.
## 0xCC90A1: cast divided by the branch speed plus its SKL recovery column.
## 0xCB2551: jump to frame1; 0xCB25FB: object once at the branch trigger frame.
static func plan(move: Dictionary, attack_rate: float, cast_rate: float) -> Dictionary:
	var tl: Array = move["stages"][0]["timeline"]
	var lead := float(tl[3]["end_ms"])-float(tl[1]["start_ms"])
	# Native speed values use thousandths and IDIV truncation.
	var attack := maxi(1,int(attack_rate*1000.0))
	var cast := maxi(1,int(cast_rate*1000.0))
	# Skill20 alone switches to ATTACK/ATTACK at 0xCC8BD9.
	var active_speed := cast if move.get("native_state","") == "wave_cast" else attack
	# Native +0x3188 scales both velocity and acceleration, not time squared.
	var velocity := float(move["native_move"]["speed"])*attack/1000.0
	var acceleration := int(float(move["native_move"]["accel"])*attack/1000.0)
	return {"wait_ms":maxi(0,int((float(move["cast_ms"])-lead)*1000.0/cast)),
		"end_ms":int(float(move["cast_ms"])*1000.0/active_speed)+float(move["native_recovery_ms"]),
		"resume_ms":float(tl[1]["start_ms"]),"rate":active_speed/1000.0,
		"velocity":velocity,"acceleration":acceleration,
		"stop_ms":int(-velocity*1000.0/acceleration) if velocity*acceleration<0 else -1}

static func ani_clock(plan: Dictionary, elapsed: float) -> float:
	if elapsed < float(plan["wait_ms"]):return 0.0
	return float(plan["resume_ms"])+(elapsed-float(plan["wait_ms"]))*float(plan["rate"])

## Native parameter/stop-time translation. Continuous integration is the current
## engine adapter; original per-update quantization remains separately unverified.
static func distance(plan: Dictionary, elapsed: float) -> float:
	var end := float(plan["end_ms"])
	if int(plan["stop_ms"])>=0:end = minf(end,float(plan["stop_ms"]))
	var seconds := clampf(elapsed,0.0,end)/1000.0
	return float(plan["velocity"])*seconds+0.5*float(plan["acceleration"])*seconds*seconds
