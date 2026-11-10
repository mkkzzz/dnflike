extends RefCounted
## PTL per-instance motion, from client 0xE4F2C0 / 0xE4FBF0.
## Input is a prepared instance (after emitter randomization); this class does
## not choose templates, emit objects, attach animations, or randomize fields.
## Native XYZ are integer coordinates, including the 29% depth scale.
const TAU_NATIVE := 6.28318530717958
const DEG_NATIVE := 0.017453292519943295
const AXES := ["x", "y", "z"]
const MOVES := ["[stop]", "[straight line]", "[sin]", "[cos]"]
const CHANGES := ["[keep changing]", "[keep last value]", "[ping pong]"]
const LANDINGS := ["[pierce]", "[slide]", "[stop]", "[vanish]"]
var config: Dictionary
var origin: Vector3i
var position: Vector3i
var axis_scale := Vector3i(100, 29, 100)
var mirrored := false
var alive := true
var alpha := 100.0
var elapsed_ms := 0
var paused := false
var problems: Array[String] = []

static func f32(value: float) -> float:
	return PackedFloat32Array([value])[0]

static func ramp(a: float, b: float, time: float, term: float) -> float:
	# Preserve the SSE single-precision operation order.
	return f32(f32(f32(f32(b - a) * time) / term) + a)

static func trail_projection(point: Vector4i) -> Vector2i:
	return Vector2i(point.x,point.y-point.z)

static func trail_points(history: Array, head: Vector4i, count: int, spacing: int) -> Array[Vector4i]:
	var points: Array[Vector4i] = [head]
	var sample_index := history.size()-1
	# E2DC2C..E2E485 walks backwards from each layer, interpolating ten
	# pixels toward the first older sample far enough away.
	for layer in count:
		var previous: Vector4i = points.back()
		while sample_index >= 0:
			var sample: Vector4i = history[sample_index]
			var delta := Vector2(trail_projection(sample)-trail_projection(previous))
			var distance := int(delta.length())
			if sample.w < previous.w and distance >= spacing:
				# 11F0FF0/11F1060 index the original tenth-degree sine and cosine tables.
				var angle := mini(posmod(int(f32(delta.angle())*572.957914),3600),3559)
				var radians := f32(angle*0.0017453288892284036)
				var offset := Vector2.from_angle(radians)*spacing
				var height := int(ramp(previous.z,sample.z,spacing,distance))
				var stamp := int(ramp(previous.w,sample.w,spacing,distance))
				points.append(Vector4i(previous.x+roundi(offset.x),previous.y-previous.z+roundi(offset.y)+height,height,stamp))
				break
			sample_index -= 1
		if sample_index < 0:break
	return points

static func mean_ramp(a: float, b: float, time: float, term: float) -> float:
	return f32(f32(ramp(a, b, time, term) + a) * 0.5)

static func phase(time: float, period: float) -> float:
	if period == 0.0:
		return NAN
	# Native converts its float operands to double for this multiply/divide.
	return f32(time * TAU_NATIVE / period)

static func axis_displacement(axis: Dictionary, time_ms: int, term_ms: int, change: String) -> float:
	var kind: String = axis.get("move_type", "[stop]")
	if kind == "[stop]":
		return 0.0
	var values: Array = axis.get("move_variable_1", [0, 0])
	var a := f32(float(values[0]))
	var b := f32(float(values[1]))
	var t := f32(float(time_ms))
	var term := f32(float(term_ms))
	if kind == "[straight line]":
		if term_ms == 0:
			# IMUL wraps before CVTSI2SS in this one native branch.
			var product: int = (int(values[0]) * time_ms) & 0xffffffff
			if product >= 0x80000000:
				product -= 0x100000000
			return f32(f32(float(product)) * f32(0.001))
		if change == "[keep changing]" or (change == "[keep last value]" and time_ms < term_ms):
			return f32(f32(mean_ramp(a, b, t, term) * t) * f32(0.001))
		var full := f32(f32(f32(f32(a + b) * 0.5) * term) * f32(0.001))
		if change == "[keep last value]":
			return f32(full + f32(f32(f32(float(time_ms - term_ms)) * b) * f32(0.001)))
		@warning_ignore("integer_division")
		var cycles: int = time_ms / term_ms
		var rest := f32(float(time_ms % term_ms))
		if cycles % 2 != 0:
			var swap := a
			a = b
			b = swap
		return f32(f32(full * f32(float(cycles))) + f32(f32(mean_ramp(a, b, rest, term) * rest) * f32(0.001)))
	var periods: Array = axis.get("move_variable_2", [0, 0])
	var p := f32(float(periods[0]))
	var q := f32(float(periods[1]))
	var angle := 0.0
	var amplitude := a
	if term_ms == 0:
		angle = phase(t, p)
	elif change == "[keep changing]" or (change == "[keep last value]" and time_ms < term_ms):
		angle = phase(t, mean_ramp(p, q, t, term))
		amplitude = ramp(a, b, t, term)
	elif change == "[keep last value]":
		angle = f32(phase(term, f32(f32(p + q) * 0.5)) + phase(f32(float(time_ms - term_ms)), q))
		amplitude = b
	else:
		@warning_ignore("integer_division")
		var cycles: int = time_ms / term_ms
		var rest := f32(float(time_ms % term_ms))
		if cycles > 0:
			angle = f32(phase(term, f32(f32(p + q) * 0.5)) * f32(float(cycles)))
		if cycles % 2 != 0:
			var swap := a
			a = b
			b = swap
			swap = p
			p = q
			q = swap
		angle = f32(angle + phase(rest, mean_ramp(p, q, rest, term)))
		amplitude = ramp(a, b, rest, term)
	return f32((sin(angle) if kind == "[sin]" else cos(angle)) * amplitude)

static func rotate_pair(a: float, b: float, degrees: int) -> Vector2:
	if degrees % 360 == 0:
		return Vector2(a, b)
	# The update function calculates radius in x87, then stores a float.
	var radius := f32(sqrt(a * a + b * b))
	var angle := f32(f32(atan2(b, a)) + f32(float(degrees) * DEG_NATIVE))
	return Vector2(f32(cos(angle) * radius), f32(sin(angle) * radius))

func _init(prepared: Dictionary = {}, start := Vector3i.ZERO, mirror_x := false, initial_age_ms := 0) -> void:
	config = prepared.duplicate(true)
	origin = start
	position = start
	mirrored = mirror_x
	alpha = f32(float(config.get("transparent_value", [100, 100])[0]))
	if not CHANGES.has(config.get("changing_type", "[keep changing]")):
		problems.append("unsupported changing type")
	if not LANDINGS.has(config.get("landing_type", "[pierce]")):
		problems.append("unsupported landing type")
	if int(config.get("changing_term", 0)) < 0:
		problems.append("negative changing term needs native validation")
	if initial_age_ms < 0:
		problems.append("negative initial age")
	for key in AXES:
		var axis: Dictionary = config.get("axes", {}).get(key, {})
		if not MOVES.has(axis.get("move_type", "[stop]")):
			problems.append("unsupported movement type: " + key)
		for field in ["move_variable_1", "move_variable_2"]:
			if axis.has(field) and axis[field].size() != 2:
				problems.append("invalid movement pair: " + key + "/" + field)
	# Native reset (0xE4F230) immediately evaluates time zero after copying the
	# prepared instance. A pre-aged emission resets directly to that age; sampling
	# zero first could incorrectly land/vanish a cosine particle before its birth.
	if problems.is_empty():
		var life := int(config.get("life_time", 0))
		var age := mini(initial_age_ms, life) if life > 0 else initial_age_ms
		var initial := advance_to(age)
		if not initial.ok:
			for problem in initial.problems:
				problems.append(str(problem))

func advance_to(time_ms: int) -> Dictionary:
	if not problems.is_empty():
		return {"ok": false, "problems": problems.duplicate()}
	if time_ms < elapsed_ms or time_ms < 0:
		return {"ok": false, "problems": ["particle clock cannot move backwards"]}
	if paused:
		return snapshot()
	elapsed_ms = time_ms
	var life := int(config.get("life_time", 0))
	if life != 0 and time_ms >= life:
		alive = false
	# Native stop checks the previous height, before rotation/gravity/alpha.
	if config.get("landing_type", "[pierce]") == "[stop]" and position.z == 0:
		return snapshot()
	var motion := Vector3.ZERO
	for index in 3:
		motion[index] = axis_displacement(config.get("axes", {}).get(AXES[index], {}), time_ms,
			int(config.get("changing_term", 0)), config.get("changing_type", "[keep changing]"))
	if not motion.is_finite():
		return {"ok": false, "problems": ["nonfinite native displacement; inspect period fields"]}
	var angles: Array = config.get("rotation_angle", [0, 0, 0])
	var pair := rotate_pair(motion.z, motion.y, int(angles[2]))
	motion.z = pair.x
	motion.y = pair.y
	pair = rotate_pair(motion.x, motion.z, int(angles[1]))
	motion.x = pair.x
	motion.z = pair.y
	pair = rotate_pair(motion.x, motion.y, int(angles[0]))
	motion.x = pair.x
	motion.y = pair.y
	for index in 3:
		var factor := f32(0.01) if index == 0 and mirrored else f32(-0.01)
		position[index] = origin[index] - int(f32(f32(f32(float(axis_scale[index])) * motion[index]) * factor))
	var t := f32(float(time_ms))
	position.z += int(f32(f32(f32(f32(float(config.get("gravity", 0))) * t) * t) * f32(-0.0000005)))
	if position.z < 0:
		match config.get("landing_type", "[pierce]"):
			"[slide]", "[stop]": position.z = 0
			"[vanish]": alive = false
	if life != 0:
		var fade: Array = config.get("transparent_value", [100, 100])
		var fade_start := f32(float(fade[0]))
		var fade_end := f32(float(fade[1]))
		alpha = f32(fade_end if time_ms >= life else fade_start + (fade_end - fade_start) * float(time_ms) / float(life))
	return snapshot()

func snapshot() -> Dictionary:
	return {"ok": true, "position": position, "alpha": alpha, "alive": alive, "elapsed_ms": elapsed_ms}
