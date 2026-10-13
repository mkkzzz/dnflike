class_name BattleFX
extends Node2D
## One combat presentation clock: hitstop freezes trails, particles and floating numbers.
## Main decrements freeze at 60 Hz; actor scripts share that counter.

const TRAIL_LIFE := 0.075
const TRAIL_MAX := 14
const MAX_PARTICLES := 120
const MAX_LABELS := 32
const AUDIO_SCRIPT := preload("res://scripts/combat_audio.gd")

var freeze := 0
var shake := 0.0
var camera: Camera2D
var number_font: Font
var pool: Array[Label] = []
var log_hits := 0

var _audio: CombatAudio
var _numbers: Array = []
var _trails: Array = []
var _slashes: Array = []
var _glows: Array = []
var _parts: Array = []
var _flashes: Array = []
var _swing_group := 0
var _swing_progress := -1.0
var _last_swing_tick := 0
var _last_swing_pos := Vector2.ZERO


func _ready() -> void:
	_audio = AUDIO_SCRIPT.new()
	add_child(_audio)


func play_sound(kind: String) -> void:
	if _audio != null:
		_audio.play_sound(kind)


func hitstop(frames: int) -> void:
	freeze = maxi(freeze, frames)


func add_shake(amount: float) -> void:
	shake = clampf(maxf(shake, amount), 0.0, 8.0)
	# The first impact offset remains visible throughout hitstop.
	if camera != null:
		camera.offset = Vector2(randf_range(-1, 1), randf_range(-0.45, 0.45)) * shake


func spawn_number(world_pos: Vector2, text: String, color: Color, size: int = 18) -> void:
	var label := _take_label()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	var origin := world_pos + Vector2(randf_range(-14, 14), -20)
	label.position = origin
	label.scale = Vector2.ONE * 1.10
	label.modulate.a = 1.0
	_numbers.append({"label": label, "origin": origin, "age": 0.0, "life": 0.72})


func _take_label() -> Label:
	for label in pool:
		if not label.visible:
			label.visible = true
			return label
	if pool.size() >= MAX_LABELS:
		var recycled: Dictionary = _numbers.pop_front()
		return recycled["label"] as Label
	var label := Label.new()
	label.z_index = 50
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if number_font != null:
		label.add_theme_font_override("font", number_font)
	label.add_theme_color_override("font_outline_color", Color(0.04, 0.02, 0.025))
	label.add_theme_constant_override("outline_size", 3)
	add_child(label)
	pool.append(label)
	return label


func _process(delta: float) -> void:
	if freeze > 0:
		return
	_update_fx(delta)
	_update_numbers(delta)
	if shake > 0.12:
		shake *= exp(-18.0 * delta)
		if camera != null:
			camera.offset = Vector2(randf_range(-1, 1), randf_range(-0.45, 0.45)) * shake
	else:
		shake = 0.0
		if camera != null:
			camera.offset = Vector2.ZERO


func _update_numbers(delta: float) -> void:
	for index in range(_numbers.size() - 1, -1, -1):
		var entry: Dictionary = _numbers[index]
		entry["age"] = float(entry["age"]) + delta
		var age := float(entry["age"])
		var label: Label = entry["label"]
		if age >= float(entry["life"]):
			label.visible = false
			_numbers.remove_at(index)
			continue
		var origin: Vector2 = entry["origin"]
		label.position = origin + Vector2(0, -40.0 * (1.0 - exp(-age * 4.0)))
		label.scale = Vector2.ONE * (1.0 + 0.10 * exp(-age * 25.0))
		label.modulate.a = clampf((float(entry["life"]) - age) / 0.22, 0.0, 1.0)


func spawn_trail(base: Vector2, tip: Vector2) -> void:
	_trails.append({"p0": base, "p1": tip, "t": 0.0, "group": _swing_group})
	if _trails.size() > TRAIL_MAX:
		_trails.pop_front()
	queue_redraw()


func spawn_slash(pos: Vector2, facing: int, radius: float = 96.0, arc_deg: float = 150.0,
		thickness: float = 14.0, color: Color = Color(0.73, 0.81, 0.87)) -> void:
	_slashes.append({"pos": pos, "facing": facing, "r": radius, "arc": deg_to_rad(arc_deg),
		"th": thickness, "col": color, "t": 0.0, "life": 0.12})
	queue_redraw()


func spawn_glow(pos: Vector2, radius: float = 40.0,
		color: Color = Color(0.95, 0.22, 0.16), life: float = 0.25) -> void:
	_glows.append({"pos": pos, "r": radius, "col": color, "t": 0.0, "life": life})
	queue_redraw()


func spawn_sparks(pos: Vector2, direction: int = 1, count: int = 7) -> void:
	for index in range(count):
		var angle := randf_range(-1.1, 1.1)
		var speed := randf_range(160.0, 390.0)
		_parts.append({"pos": pos,
			"vel": Vector2(cos(angle) * speed * direction, sin(angle) * speed - 65.0),
			"col": Color(1.0, 0.76, 0.39), "t": 0.0, "life": randf_range(0.10, 0.21),
			"grav": 740.0, "spark": true})
	_limit_particles()
	queue_redraw()


func spawn_dust(pos: Vector2, count: int = 5) -> void:
	for index in range(count):
		_parts.append({"pos": pos + Vector2(randf_range(-10, 10), 0),
			"vel": Vector2(randf_range(-70, 70), randf_range(-72, -20)),
			"col": Color(0.52, 0.46, 0.39, 0.6), "t": 0.0, "life": randf_range(0.18, 0.32),
			"grav": 130.0, "spark": false})
	_limit_particles()
	queue_redraw()


func _limit_particles() -> void:
	while _parts.size() > MAX_PARTICLES:
		_parts.pop_front()


func on_hit(world_pos: Vector2, direction: int, damage: float, hit: Dictionary) -> void:
	log_hits += 1
	hitstop(int(hit.get("hitstop", 4)))
	add_shake(float(hit.get("shake", 2.0)))
	var launch: bool = hit.has("launch") or str(hit.get("kind", "")) == "launch"
	var heavy: bool = launch or bool(hit.get("knockdown", false)) or str(hit.get("kind", "")) == "knock" or int(hit.get("hitstop", 4)) >= 6
	var impact := world_pos + Vector2(0, -float(hit.get("impact_height", 72.0)))
	spawn_number(world_pos + Vector2(0, -108), str(roundi(damage)),
		Color(1.0, 0.87, 0.63) if heavy else Color(0.95, 0.91, 0.78), 25 if heavy else 21)
	spawn_sparks(impact, direction, 10 if heavy else 6)
	_flashes.append({"pos": impact, "t": 0.0, "life": 0.065, "size": 20.0 if heavy else 14.0})
	if heavy:
		spawn_slash(impact, direction, 62.0, 115.0, 9.0, Color(0.94, 0.73, 0.48))
	play_sound("launch" if launch else ("heavy" if heavy else "light"))
	queue_redraw()


func start_swing() -> void:
	_trails.clear()
	_swing_group += 1
	_swing_progress = -1.0
	_last_swing_tick = 0
	queue_redraw()


func on_swing(pos: Vector2, facing: int, swing01: float, reach: float = 158.0) -> void:
	# Shoulder matches a 190px actor. Sounds are issued once by the action state.
	var now := Time.get_ticks_msec()
	if swing01 < _swing_progress or now - _last_swing_tick > 100 or pos.distance_to(_last_swing_pos) > 42.0:
		_swing_group += 1
	_swing_progress = swing01
	_last_swing_tick = now
	_last_swing_pos = pos
	var shoulder := pos + Vector2(0.0, -136.0)
	var angle := lerpf(-1.95, 0.95, clampf(swing01, 0.0, 1.0))
	var direction := Vector2(cos(angle) * facing, sin(angle))
	spawn_trail(shoulder + direction * reach * 0.40, shoulder + direction * reach)


func clear_fx() -> void:
	freeze = 0
	shake = 0.0
	if camera != null:
		camera.offset = Vector2.ZERO
	_trails.clear()
	_slashes.clear()
	_glows.clear()
	_parts.clear()
	_flashes.clear()
	_numbers.clear()
	for label in pool:
		label.visible = false
		label.modulate.a = 0.0
	_swing_progress = -1.0
	_last_swing_tick = 0
	_swing_group += 1
	if _audio != null:
		_audio.stop_all()
	queue_redraw()


func _update_fx(delta: float) -> void:
	var had_fx := not (_trails.is_empty() and _slashes.is_empty() and _glows.is_empty()
		and _parts.is_empty() and _flashes.is_empty())
	for collection in [_trails, _slashes, _glows, _parts, _flashes]:
		for index in range(collection.size() - 1, -1, -1):
			var entry: Dictionary = collection[index]
			entry["t"] = float(entry["t"]) + delta
			if float(entry["t"]) >= float(entry.get("life", TRAIL_LIFE)):
				collection.remove_at(index)
	for entry in _parts:
		var velocity: Vector2 = entry["vel"]
		velocity += Vector2(0, float(entry["grav"]) * delta)
		entry["pos"] = (entry["pos"] as Vector2) + velocity * delta
		entry["vel"] = velocity * exp(-3.0 * delta)
	if had_fx:
		queue_redraw()


func _draw() -> void:
	for index in range(1, _trails.size()):
		var previous: Dictionary = _trails[index - 1]
		var current: Dictionary = _trails[index]
		if previous["group"] != current["group"]:
			continue
		var fade := clampf(1.0 - maxf(previous["t"], current["t"]) / TRAIL_LIFE, 0.0, 1.0)
		var base_a: Vector2 = previous["p0"]
		var tip_a: Vector2 = previous["p1"]
		var base_b: Vector2 = current["p0"]
		var tip_b: Vector2 = current["p1"]
		_quad(base_a, tip_a, tip_b, base_b, Color(0.65, 0.75, 0.82, fade * 0.22))
		_quad(base_a.lerp(tip_a, 0.66), tip_a, tip_b, base_b.lerp(tip_b, 0.66),
			Color(0.95, 0.91, 0.78, fade * 0.53))
		draw_line(tip_a, tip_b, Color(1.0, 0.96, 0.84, fade * 0.82), 1.5, true)
	for slash in _slashes:
		var progress := clampf(float(slash["t"]) / float(slash["life"]), 0.0, 1.0)
		var color: Color = slash["col"]
		color.a *= (1.0 - progress) * 0.65
		_crescent(slash["pos"], float(slash["facing"]), float(slash["r"]) * (0.9 + 0.1 * progress),
			float(slash["arc"]), float(slash["th"]) * (1.0 - progress * 0.5), color)
	for glow in _glows:
		var progress := clampf(float(glow["t"]) / float(glow["life"]), 0.0, 1.0)
		var color: Color = glow["col"]
		for ring in range(4, 0, -1):
			var radius := float(glow["r"]) * float(ring) / 4.0 * (1.0 + progress * 0.2)
			color.a = (1.0 - progress) * 0.035
			draw_circle(glow["pos"], radius, color)
	for flash in _flashes:
		var color := Color(1.0, 0.94, 0.75, 1.0 - float(flash["t"]) / float(flash["life"]))
		var center: Vector2 = flash["pos"]
		var size := float(flash["size"])
		draw_line(center + Vector2(-size, -size * 0.55), center + Vector2(size, size * 0.55), color, 2.0, true)
		draw_line(center + Vector2(-size * 0.6, size), center + Vector2(size * 0.6, -size), color, 2.0, true)
		draw_circle(center, 3.0, Color(1.0, 0.98, 0.90, color.a))
	for particle in _parts:
		var progress := clampf(float(particle["t"]) / float(particle["life"]), 0.0, 1.0)
		var color: Color = particle["col"]
		color.a *= 1.0 - progress
		var position: Vector2 = particle["pos"]
		if bool(particle["spark"]):
			var velocity: Vector2 = particle["vel"]
			draw_line(position, position - velocity.normalized() * (7.0 - progress * 4.0), color, 1.7, true)
		else:
			draw_circle(position, 2.0 + progress * 2.0, color)


func _quad(point_a: Vector2, point_b: Vector2, point_c: Vector2, point_d: Vector2, color: Color) -> void:
	# A moving/turning actor can fold the ribbon into a bow tie. Draw two explicit
	# triangles, skipping zero area samples, instead of asking Godot to triangulate it.
	_triangle(point_a, point_b, point_c, color)
	_triangle(point_a, point_c, point_d, color)


func _triangle(point_a: Vector2, point_b: Vector2, point_c: Vector2, color: Color) -> void:
	if absf((point_b - point_a).cross(point_c - point_a)) < 0.20:
		return
	draw_colored_polygon(PackedVector2Array([point_a, point_b, point_c]), color)


func _crescent(center: Vector2, facing: float, radius: float, arc: float,
		thickness: float, color: Color) -> void:
	var outer := PackedVector2Array()
	var inner := PackedVector2Array()
	for index in range(17):
		var angle := -arc * 0.5 + arc * float(index) / 16.0
		var direction := Vector2(cos(angle) * facing, sin(angle))
		outer.append(center + direction * radius)
		inner.append(center + direction * maxf(2.0, radius - thickness))
	inner.reverse()
	outer.append_array(inner)
	draw_colored_polygon(outer, color)
