extends RefCounted
## Original PTL scheduler 0xE50B70 and instance preparation 0xE50660.
## Returns motion instances + original object entries. Animation/passive-object
## creation, attachment, sound and rendering belong to the caller, not this core.
const Motion = preload("res://combat/particles/native_motion.gd")
const Random = preload("res://combat/particles/native_random.gd")
const EPSILON := 0.00000011920928955078125
var config: Dictionary
var origin: Vector3i
var previous_origin: Vector3i
var mirrored := false
var density := 1.0
var quality := 2
var global_effect_scale := 1.0
var finished := false
var accumulator := 1.0
var previous_time := 0
var last_call_time := 0
var problems: Array[String] = []
var draw: Callable
static var cone_cumulative: Array[int] = []

func _init(definition: Dictionary, random_draw: Callable, start: Variant = null, mirror_x := false) -> void:
	config = definition.duplicate(true)
	draw = random_draw
	var creation: Array = config.get("creation_pos", [0, 0, 0])
	origin = Vector3i(int(creation[0]), int(creation[1]), int(creation[2])) if start == null else start
	previous_origin = origin
	mirrored = mirror_x
	if not draw.is_valid():
		problems.append("native random draw callback is required")
	if not ["[animation]", "[passive object]"].has(config.get("object_type", "[animation]")):
		problems.append("unsupported particle object type")
	if not ["[rectangle]", "[circle]"].has(config.get("rotation_angle_range_type", "[rectangle]")):
		problems.append("unsupported rotation range type")
	if not ["[randomize]", "[in order]"].has(config.get("how_to_create_object", "[randomize]")):
		problems.append("unsupported object selection")
	if int(config.get("random_range", 0)) < 0:
		problems.append("negative random range needs native validation")
	var spread: Array = config.get("rotation_angle_variable", [0, 0])
	if spread[0] < 0 or spread[1] < 0 or (config.get("rotation_angle_range_type", "[rectangle]") == "[circle]" and divided(int(spread[0]), 2) > 180):
		problems.append("rotation spread outside native lookup table")

static func near(a: float, b: float) -> bool:
	return absf(a - b) <= absf(a) * EPSILON

static func signed32(value: int) -> int:
	value &= 0xffffffff
	return value - 0x100000000 if value >= 0x80000000 else value

static func divided(value: int, divisor: int) -> int:
	@warning_ignore("integer_division")
	var result: int = value / divisor
	return result

func reset(position: Vector3i) -> void:
	origin = position
	previous_origin = position
	accumulator = 1.0
	density = 1.0
	previous_time = 0
	last_call_time = 0
	finished = false

func draw_mod(divisor: int) -> int:
	var value := int(draw.call())
	assert(value >= 0 and value <= 0x7fffffff, "native draw must be a nonnegative 31-bit integer")
	return value % divisor

func end_time(frequency: float) -> int:
	# 0xE50120 uses deadlines, not a second emitted-object counter. In particular
	# max number 1 and max time 1 each produce sentinel zero here.
	if frequency <= 0.0:
		return 0
	var maximum := int(config.get("maximum_create_time", 0))
	var limit := maximum - 1 if maximum != 0 else 0
	var count := int(config.get("maximum_create_number", 0))
	var count_limit := 0
	if count != 0:
		count_limit = int(Motion.f32(Motion.f32(float(signed32(count * 1000 - 1000))) / frequency))
	return count_limit if limit == 0 else (limit if count_limit == 0 else mini(limit, count_limit))

func weighted_count(value: float, selected_quality: int) -> float:
	var rates: Array = config.get("display_effect_rate", [100, 100, 100])
	# Native x87 keeps the intermediate products extended until the accumulator
	# is stored. Preserve float32 inputs, without rounding every product to f32.
	return float(rates[selected_quality]) * value * Motion.f32(0.01) * Motion.f32(density)

static func rotate_area(a: float, b: float, degrees: int) -> Vector2:
	if degrees % 360 == 0:
		return Vector2(a, b)
	# 0xE4F840 uses SSE squares/sum/sqrt; motion update uses x87 for its radius.
	var radius := Motion.f32(sqrt(Motion.f32(Motion.f32(a * a) + Motion.f32(b * b))))
	var angle := Motion.f32(Motion.f32(atan2(b, a)) + Motion.f32(float(degrees) * Motion.DEG_NATIVE))
	return Vector2(Motion.f32(cos(angle) * radius), Motion.f32(sin(angle) * radius))

static func cone_angle(half_width: int, value: int) -> int:
	if cone_cumulative.is_empty():
		cone_cumulative.append(0)
		for angle in range(1, 181):
			cone_cumulative.append(int(float(cone_cumulative[-1]) + Motion.f32(sin(float(angle) * Motion.DEG_NATIVE)) * 1000.0))
	# 0xA75770 lower_bound over [begin, begin+half_width), including the end
	# index when value lies above the last searched entry.
	var low := 0
	var high := half_width
	while low < high:
		var middle := divided(low + high, 2)
		if cone_cumulative[middle] < value:
			low = middle + 1
		else:
			high = middle
	return low

func prepare_instance() -> Dictionary:
	var prepared := config.duplicate(true)
	var offset := Vector3.ZERO
	var area: Array = config.get("create_area_size", [0, 0, 0])
	for axis in 3:
		var size := int(area[axis])
		if size > 0:
			offset[axis] = draw_mod(size + 1) - divided(size, 2)
	var area_angles: Array = config.get("create_area_rotation_angle", [0, 0, 0])
	var pair := rotate_area(offset.z, offset.y, int(area_angles[2]))
	offset.z = pair.x
	offset.y = pair.y
	pair = rotate_area(offset.x, offset.z, int(area_angles[1]))
	offset.x = pair.x
	offset.z = pair.y
	pair = rotate_area(offset.x, offset.y, int(area_angles[0]))
	offset.x = pair.x
	offset.y = pair.y
	var start := origin
	for axis in 3:
		var scale := 29 if axis == 1 else 100
		start[axis] += divided(signed32(int(offset[axis]) * scale), -100 if axis == 0 and mirrored else 100)
	var angles: Array = config.get("rotation_angle", [0, 0, 0]).duplicate()
	var spread: Array = config.get("rotation_angle_variable", [0, 0])
	if config.get("rotation_angle_range_type", "[rectangle]") == "[circle]":
		var azimuth := draw_mod(360)
		angles[2] = 90 - azimuth
		if int(spread[0]) != 0:
			var half := divided(int(spread[0]), 2)
			cone_angle(half, 0) # initialize the source cumulative sine table
			var local = Random.new(int(draw.call()))
			var radius := cone_angle(half, local.next_u31() % (cone_cumulative[half] + 1))
			angles[0] += int(float(radius) * Motion.f32(cos(float(azimuth) * Motion.DEG_NATIVE)))
			angles[1] += int(float(radius) * Motion.f32(sin(float(azimuth) * Motion.DEG_NATIVE)))
	else:
		for axis in 2:
			var width := int(spread[axis])
			if width != 0:
				angles[axis] += draw_mod(width + 1) - divided(width, 2)
	prepared["rotation_angle"] = angles
	var random_range := int(config.get("random_range", 0))
	if random_range != 0:
		var width := random_range * 10 + 1
		var amplitude := 1000 + draw_mod(width) - random_range * 5
		var period := 1000 + draw_mod(width) - random_range * 5
		var axes: Dictionary = prepared.get("axes", {})
		for key in Motion.AXES:
			var axis: Dictionary = axes.get(key, {})
			var kind: String = axis.get("move_type", "[stop]")
			if kind == "[straight line]":
				scale_pair(axis, "move_variable_1", 1000 + draw_mod(width) - random_range * 5)
			elif kind in ["[sin]", "[cos]"]:
				scale_pair(axis, "move_variable_1", amplitude)
				scale_pair(axis, "move_variable_2", period)
		prepared["changing_term"] = divided(signed32(int(config.get("changing_term", 0)) * (1000 + draw_mod(width) - random_range * 5)), 1000)
		if int(config.get("life_time", 0)) != 0:
			prepared["life_time"] = maxi(1, divided(signed32(int(config.life_time) * (1000 + draw_mod(width) - random_range * 5)), 1000))
	return {"config": prepared, "origin": start}

static func scale_pair(axis: Dictionary, field: String, factor: int) -> void:
	var values: Array = axis.get(field, [0, 0])
	axis[field] = [divided(signed32(int(values[0]) * factor), 1000), divided(signed32(int(values[1]) * factor), 1000)]

func emit_at(time_ms: int) -> Dictionary:
	if not problems.is_empty():
		return {"ok": false, "problems": problems.duplicate()}
	if time_ms < last_call_time or time_ms < 0:
		return {"ok": false, "problems": ["emitter clock cannot move backwards"]}
	last_call_time = time_ms
	var result := {"ok": true, "particles": [], "finished": finished}
	var entries: Array = config.get("object_entries", [])
	if finished or entries.is_empty():
		return result
	var frequency := Motion.f32(float(config.get("creation_frequency", 0.0)))
	if near(frequency, 0.0):
		finished = true
		result.finished = true
		return result
	var selected_quality := quality if quality in [0, 1, 2] else 0
	if int(config.get("display_effect_rate", [100, 100, 100])[selected_quality]) == 0 or near(Motion.f32(density), 0.0):
		return result
	var burst := near(frequency, -1.0)
	var delta := 0
	if burst:
		finished = true
		selected_quality = mini(selected_quality, 2 if near(Motion.f32(global_effect_scale), 1.0) else 1)
		accumulator = Motion.f32(weighted_count(Motion.f32(float(config.get("maximum_create_number", 0))), selected_quality))
	elif time_ms != previous_time:
		var limit := end_time(frequency)
		var capped := time_ms
		if limit != 0 and time_ms >= limit:
			finished = true
			capped = limit
		delta = capped - previous_time
		previous_time = capped
		var generated := Motion.f32(Motion.f32(Motion.f32(float(delta)) * frequency) * Motion.f32(0.001))
		accumulator = Motion.f32(accumulator + weighted_count(generated, selected_quality))
	result.finished = finished
	var count := int(accumulator)
	if count <= 0:
		return result
	accumulator = Motion.f32(accumulator - Motion.f32(float(count)))
	count = mini(count, 50)
	var motions: Array = []
	for index in count:
		var age := time_ms if burst else int(Motion.f32(Motion.f32(Motion.f32(float(index)) * Motion.f32(float(delta))) / Motion.f32(float(count))))
		var life := int(config.get("life_time", 0))
		if life != 0 and life <= age:
			continue
		var prepared := prepare_instance()
		if int(config.get("create_pos_correct", 0)) != 0:
			for axis in 3:
				if previous_origin[axis] != origin[axis]:
					prepared.origin[axis] = int(Motion.f32(float(origin[axis]))) if index + 1 == count else int(Motion.ramp(Motion.f32(float(previous_origin[axis])), Motion.f32(float(origin[axis])), Motion.f32(float(index + 1)), Motion.f32(float(count))))
		var motion = Motion.new(prepared.config, prepared.origin, mirrored, age)
		if not motion.problems.is_empty():
			return {"ok": false, "problems": motion.problems.duplicate()}
		motions.append({"motion": motion, "initial_age_ms": age})
	previous_origin = origin
	# The native generator prepares the whole motion vector BEFORE selecting
	# objects. Interleaving selection with preparation changes the random stream.
	for index in motions.size():
		var selected := draw_mod(entries.size()) if config.get("how_to_create_object", "[randomize]") == "[randomize]" else mini(index, entries.size() - 1)
		motions[index]["entry"] = entries[selected].duplicate(true)
		motions[index]["object_type"] = config.get("object_type", "[animation]")
	result.particles = motions
	return result
