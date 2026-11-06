extends RefCounted
## Verified client state 24 / skill 20. Source ANI remains unmodified.
## 0xCC8AA0: cast minus frame1..3, divided by cast speed.
## 0xCC90A1: cast divided by attack speed plus SKL static[0].
## 0xCB2551: jump to frame1; 0xCB25FB: object once at frame3.
static func plan(move: Dictionary, attack_rate: float, cast_rate: float) -> Dictionary:
	var tl: Array = move["stages"][0]["timeline"]
	var lead := float(tl[3]["end_ms"])-float(tl[1]["start_ms"])
	# Native speed values use thousandths and IDIV truncation.
	var attack := maxi(1,int(attack_rate*1000.0))
	var cast := maxi(1,int(cast_rate*1000.0))
	return {"wait_ms":maxi(0,int((float(move["cast_ms"])-lead)*1000.0/cast)),
		"end_ms":int(float(move["cast_ms"])*1000.0/attack)+float(move["native_recovery_ms"]),
		"resume_ms":float(tl[1]["start_ms"]),"rate":attack/1000.0}

static func ani_clock(plan: Dictionary, elapsed: float) -> float:
	if elapsed < float(plan["wait_ms"]):return 0.0
	return float(plan["resume_ms"])+(elapsed-float(plan["wait_ms"]))*float(plan["rate"])
