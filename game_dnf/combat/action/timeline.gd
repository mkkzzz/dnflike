extends RefCounted
## ANI timeline executor (doc 29, F3). One shape for every motion, whether it comes from the
## compiled content pack (decoded.timeline) or from a raw ANI (frames + delay_ms + boxes):
##   [{frame, start_ms, end_ms, attack_boxes, damage_boxes, items}]
## Boxes are original six-value boxes; see core/box6.gd for axes.

## Raw ANI metadata (tools/build_dnf_*: frames with delay_ms and boxes) -> timeline.
static func from_ani(meta: Dictionary) -> Array:
	var out: Array = []
	var clock := 0.0
	for f: Dictionary in meta.get("frames",[]):
		var delay := float(f.get("delay_ms",0) if f.get("delay_ms") != null else 0)
		var attack: Array = []
		var damage: Array = []
		for b: Dictionary in f.get("boxes",[]):
			if b["kind"] == "attack":attack.append(b["box"])
			elif b["kind"] == "damage":damage.append(b["box"])
		out.append({"frame":int(f.get("frame",out.size())),"start_ms":clock,"end_ms":clock+delay,
			"attack_boxes":attack,"damage_boxes":damage,"items":f.get("items",{})})
		clock += delay
	return out

static func duration(timeline: Array) -> float:
	return 0.0 if timeline.is_empty() else float(timeline[-1]["end_ms"])

## Frame active at t (clamped to the last frame, or wrapped when looping).
static func frame_at(timeline: Array, t: float, loop := false) -> Dictionary:
	if timeline.is_empty():return {}
	var total := duration(timeline)
	if loop and total > 0:t = fposmod(t,total)
	for f: Dictionary in timeline:
		if t < float(f["end_ms"]):return f
	return timeline[-1]

## Contiguous runs of frames that carry attack boxes. Each run is one hit group: a target is
## hit at most once per run, and a gap without boxes starts a new run (E-INFER, matches the
## three separated thrusts of triplestab.ani and the single long box of dashattack.ani).
static func attack_segments(timeline: Array) -> Array:
	var out: Array = []
	var current: Dictionary = {}
	for f: Dictionary in timeline:
		if f["attack_boxes"].is_empty():
			if not current.is_empty():
				out.append(current)
				current = {}
			continue
		if current.is_empty():current = {"start":float(f["start_ms"]),"end":float(f["end_ms"]),"frames":[]}
		current["end"] = float(f["end_ms"])
		current["frames"].append({"start":float(f["start_ms"]),"end":float(f["end_ms"]),"boxes":f["attack_boxes"]})
	if not current.is_empty():out.append(current)
	return out

## Attack boxes of a segment that are live anywhere in (old_t, new_t].
static func segment_boxes(segment: Dictionary, old_t: float, new_t: float) -> Array:
	var out: Array = []
	for f: Dictionary in segment["frames"]:
		if new_t >= float(f["start"]) and old_t < float(f["end"]):out.append_array(f["boxes"])
	return out

## Frames whose start lies in (old_t, new_t]; used for per-frame cues such as ANI sound events.
static func crossed_frames(timeline: Array, old_t: float, new_t: float) -> Array:
	var out: Array = []
	for f: Dictionary in timeline:
		var s := float(f["start_ms"])
		if s > old_t and s <= new_t:out.append(f)
		elif s == 0.0 and old_t < 0.0 and new_t >= 0.0:out.append(f)
	return out

## Last instant at which any attack box is live; the earliest point a chain may cancel.
static func last_active_ms(segments: Array) -> float:
	var t := 0.0
	for s: Dictionary in segments:t = maxf(t,float(s["end"]))
	return t
