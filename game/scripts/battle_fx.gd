class_name BattleFX
extends Node2D
## Shared presentation clock: hitstop freezes all visual transients.
## Blade ribbons ONLY use WeaponRig endpoints. Move events add authored accents.

const TRAIL_LIFE := 0.115
const TRAIL_MAX := 26
const MAX_PARTICLES := 180
const MAX_LABELS := 32
const MAX_STROKES := 36
const MAX_RINGS := 18
const MAX_AFTERIMAGES := 10
const AUDIO_SCRIPT := preload("res://scripts/combat_audio.gd")
const STEEL := Color(0.67, 0.88, 1.0)
const IVORY := Color(1.0, 0.94, 0.79)
const BLOOD := Color(1.0, 0.21, 0.12)

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
var _strokes: Array = []
var _rings: Array = []
var _charges: Array = []
var _afterimages: Array = []
var _swing_group := 0
var _shake_clock := 0.0
var _shake_direction := Vector2.RIGHT
var _active_move := ""
var _rage_aura_cooldown := 0.0


func _ready() -> void:
	_audio = AUDIO_SCRIPT.new()
	add_child(_audio)


func play_sound(kind: String, world_x: float = NAN, intensity: float = 1.0) -> void:
	if _audio != null:
		_audio.play_sound(kind, world_x, intensity)


func set_listener_position(world_x: float) -> void:
	if _audio != null:
		_audio.set_listener_position(world_x)


func hitstop(frames: int) -> void:
	freeze = maxi(freeze, frames)


func add_shake(amount: float, direction: Vector2 = Vector2.ZERO) -> void:
	shake = clampf(maxf(shake, amount), 0.0, 7.0)
	if direction.length_squared() > 0.01:
		_shake_direction = direction.normalized()
	_shake_clock = 0.008
	if camera != null:
		camera.offset = _shake_direction * shake * 0.65


func spawn_number(world_pos: Vector2, text: String, color: Color, size: int = 18) -> void:
	var label := _take_label()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	var origin := world_pos + Vector2(randf_range(-12, 12), -20)
	label.position = origin
	label.scale = Vector2.ONE * 1.1
	label.modulate.a = 1.0
	_numbers.append({"label": label, "origin": origin, "age": 0.0, "life": 0.70})


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
	label.add_theme_color_override("font_outline_color", Color(0.035, 0.018, 0.026))
	label.add_theme_constant_override("outline_size", 3)
	add_child(label)
	pool.append(label)
	return label


func _process(delta: float) -> void:
	if freeze > 0:
		return
	_rage_aura_cooldown = maxf(0.0, _rage_aura_cooldown - delta)
	_update_fx(delta)
	_update_numbers(delta)
	if shake > 0.10:
		_shake_clock += delta
		shake *= exp(-14.5 * delta)
		if camera != null:
			var across := Vector2(-_shake_direction.y, _shake_direction.x)
			camera.offset = (_shake_direction * sin(_shake_clock * 107.0) + across * sin(_shake_clock * 79.0) * 0.28) * shake
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
		label.position = origin + Vector2(0, -42.0 * (1.0 - exp(-age * 4.0)))
		label.scale = Vector2.ONE * (1.0 + 0.1 * exp(-age * 25.0))
		label.modulate.a = clampf((float(entry["life"]) - age) / 0.20, 0.0, 1.0)


func start_swing() -> void:
	_swing_group += 1
	queue_redraw()


func weapon_trail(base: Vector2, tip: Vector2, color: Color = IVORY, contact_sample := false) -> void:
	if freeze > 0 and not contact_sample:
		return
	if not _trails.is_empty():
		var last: Dictionary = _trails[-1]
		var last_tip: Vector2 = last["p1"]
		if last["group"] == _swing_group and last_tip.distance_squared_to(tip) < 1.5:
			return
		if last_tip.distance_to(tip) > 350.0 and not contact_sample:
			_swing_group += 1
	_trails.append({"p0": base, "p1": tip, "t": 0.0, "group": _swing_group, "col": color})
	_bound(_trails, TRAIL_MAX)
	queue_redraw()


func spawn_trail(base: Vector2, tip: Vector2) -> void:
	weapon_trail(base, tip)


func on_swing(_pos: Vector2, _facing: int, _swing01: float, _reach: float = 158.0) -> void:
	# Legacy entry point. WeaponRig supplies actual blade samples now.
	pass


func attack_event(pos: Vector2, facing: int, move_id: String, data: Dictionary,
		phase: String = "start", segment: int = 0) -> void:
	phase = str(data.get("phase", phase))
	segment = int(data.get("segment", segment))
	if phase == "windup":
		phase = "start"
	var reach := float(data.get("hitbox", {}).get("x", 165.0))
	var hand := pos + Vector2(facing * 20.0, -108.0)
	var forward := Vector2(float(facing), 0.0)
	_active_move = move_id
	if phase == "start":
		match move_id:
			"quick_draw":
				var life := clampf(float(data.get("charge", 18.0)) / 60.0, 0.15, 0.8)
				_charges.append({"pos": hand, "t": 0.0, "life": life, "col": STEEL, "facing": facing})
				_bound(_charges, 3)
				for index in range(8):
					var angle := float(index) * TAU / 8.0 + 0.25
					var radial := Vector2(cos(angle), sin(angle))
					_particle(hand + radial * 37.0, -radial * 102.0, STEEL, life, "mote", 0.0, 1.7)
				play_sound("charge", pos.x)
			"blood_rage":
				spawn_glow(pos + Vector2(-facing * 14.0, -114.0), 43.0, BLOOD, 0.48)
				_ring(pos + Vector2(0, -78), 12.0, 56.0, BLOOD, 0.24, 0.55)
				for index in range(13):
					_particle(pos + Vector2(randf_range(-20, 20), randf_range(-140, -55)), Vector2(randf_range(-24, 24), randf_range(-120, -60)), BLOOD, randf_range(0.25, 0.45), "ember", -30.0, 2.8)
				play_sound("rage", pos.x)
			"back_dash":
				spawn_dust(pos, 5)
				_speed_lines(pos, -facing, Color(0.75, 0.83, 0.87, 0.32), 4, 0.17)
				play_sound("dash", pos.x, 0.65)
			"jump":
				spawn_dust(pos, 4)
				play_sound("jump", pos.x)
			"dash_attack":
				_speed_lines(pos, facing, STEEL, 7, 0.19)
				spawn_dust(pos - forward * 10.0, 6)
			_: pass
	elif phase == "active":
		start_swing()
		match move_id:
			"attack1":
				_stroke(hand + forward * 46.0 + Vector2(0, -20), hand + forward * reach + Vector2(0, 22), IVORY, 2.0, 0.11, 0.58)
				play_sound("swing_light", pos.x)
			"attack2":
				_stroke(hand + forward * 48.0 + Vector2(0, 33), hand + forward * reach + Vector2(0, -33), STEEL, 1.5, 0.12, 0.40)
				play_sound("swing_back", pos.x)
			"attack3":
				_stroke(hand + forward * 65.0 + Vector2(0, -65), hand + forward * reach + Vector2(0, 60), IVORY, 3.0, 0.13, 0.52)
				play_sound("swing_heavy", pos.x)
			"air_attack":
				_speed_lines(hand + Vector2(0, 52), facing, Color(0.74, 0.88, 1.0, 0.5), 3, 0.12)
				play_sound("swing_air", pos.x)
			"dash_attack":
				_speed_lines(pos, facing, STEEL, 5, 0.13)
				_stroke(hand - forward * 30.0, hand + forward * (reach + 24.0), STEEL, 1.8, 0.12, 0.65)
				play_sound("dash_strike", pos.x)
			"upper":
				var rise := pos + Vector2(facing * 67.0, -112.0)
				_stroke(rise + Vector2(-facing * 15.0, 44.0), rise + Vector2(facing * 24.0, -94.0), IVORY, 2.5, 0.15, 0.64)
				for index in range(5):
					_particle(rise + Vector2(randf_range(-14, 14), 26), Vector2(facing * randf_range(10, 45), randf_range(-240, -135)), STEEL, 0.17, "spark", 180.0, 1.2)
				play_sound("swing_upper", pos.x)
			"quick_draw":
				_charges.clear()
				var end := hand + forward * (reach + 45.0) + Vector2(0, -8)
				_stroke(hand - forward * 17.0, end, STEEL, 8.0, 0.15, 0.18)
				_stroke(hand - forward * 16.0 + Vector2(0, -2), end + Vector2(0, -2), Color(0.92, 0.99, 1.0), 2.2, 0.17, 0.95)
				_ring(end, 4.0, 29.0, STEEL, 0.17, 0.40)
				for index in range(10):
					_particle(hand.lerp(end, float(index + 1) / 11.0), Vector2(facing * randf_range(20, 70), randf_range(-42, 42)), STEEL, randf_range(0.16, 0.30), "mote", 0.0, 1.3)
				add_shake(1.3, forward)
				play_sound("draw_strike", pos.x)
			"rage_slash":
				var offset := -1.0 if segment % 2 == 0 else 1.0
				var from := hand + forward * 25.0 + Vector2(0, -60.0 * offset)
				var to := hand + forward * (reach + 8.0) + Vector2(0, 54.0 * offset)
				_stroke(from, to, BLOOD, 7.0, 0.16, 0.33)
				_stroke(from + Vector2(0, -8), to + Vector2(0, -8), Color(1, 0.56, 0.28), 1.8, 0.18, 0.70)
				spawn_glow(hand, 30.0, BLOOD, 0.17)
				for index in range(7):
					_particle(from.lerp(to, randf()), Vector2(facing * randf_range(80, 180), randf_range(-80, 25)), BLOOD, randf_range(0.15, 0.28), "ember", -40.0, 2.0)
				play_sound("rage_strike", pos.x)
			"thrust":
				var endpoint := hand + forward * (reach + 36.0) + Vector2(0, float(segment - 1) * 7.0)
				_stroke(hand + forward * 30.0, endpoint, STEEL, 5.0, 0.11, 0.23)
				_stroke(hand + forward * 28.0, endpoint + forward * 9.0, IVORY, 1.5, 0.12, 0.84)
				_ring(endpoint - forward * 20.0, 6.0, 23.0, STEEL, 0.14, 0.5, 0.45)
				play_sound("thrust", pos.x, 0.9 + segment * 0.07)
			_: pass
	elif phase == "recovery" and move_id == "quick_draw":
		_particle(hand + forward * reach, Vector2(facing * 60, -25), STEEL, 0.19, "mote", 0.0, 1.4)
	queue_redraw()


func locomotion_event(pos: Vector2, facing: int, kind: String, strength: float = 1.0) -> void:
	match kind:
		"land":
			spawn_dust(pos, 7 if strength >= 0.85 else 4)
			_ring(pos + Vector2(0, -1), 10, 35.0 * strength, Color(0.69, 0.63, 0.53), 0.18, 0.24, 0.18)
			play_sound("land", pos.x, strength)
		"step", "walk": play_sound("step", pos.x, strength)
		"run":
			spawn_dust(pos - Vector2(facing * 8.0, 0), 2)
			play_sound("run_step", pos.x, strength)
		"stop", "turn":
			spawn_dust(pos, 5)
			play_sound("run_stop", pos.x, strength)
		"jump":
			spawn_dust(pos, 4)
			play_sound("jump", pos.x, strength)
		_: pass


func rage_aura(pos: Vector2, facing: int) -> void:
	# Safe to call from the buff state each frame: presentation clock owns the cadence.
	if freeze > 0 or _rage_aura_cooldown > 0.0:
		return
	_rage_aura_cooldown = 0.11
	var arm := pos + Vector2(-facing * 14.0, -114.0)
	spawn_glow(arm, 24.0, BLOOD, 0.18)
	for index in range(2):
		_particle(arm + Vector2(randf_range(-6, 6), randf_range(-8, 12)),
			Vector2(randf_range(-12, 12), randf_range(-67, -32)),
			BLOOD if index == 0 else Color(1.0, 0.54, 0.15, 0.8), 0.19, "ember", -30.0, 1.3)
	queue_redraw()


func guard_event(pos: Vector2, facing: int, perfect: bool = false) -> void:
	var center := pos + Vector2(facing * 38.0, -115.0)
	spawn_sparks(center, -facing, 12 if perfect else 8, "metal")
	_ring(center, 6.0, 35.0 if perfect else 23.0, STEEL, 0.16, 0.67)
	_flashes.append({"pos": center, "t": 0.0, "life": 0.055, "size": 19.0, "col": Color(0.8, 0.94, 1.0)})
	_bound(_flashes, 20)
	add_shake(1.5, Vector2(-facing, 0))
	play_sound("guard", pos.x)
	queue_redraw()


func sample_afterimage(texture: Texture2D, src_rect: Rect2, dst_rect: Rect2,
		actor_transform: Transform2D, color: Color = Color(0.48, 0.73, 1.0, 0.17)) -> void:
	if freeze > 0 or texture == null:
		return
	_afterimages.append({"tex": texture, "src": src_rect, "dst": dst_rect,
		"transform": global_transform.affine_inverse() * actor_transform, "col": color, "t": 0.0, "life": 0.13})
	_bound(_afterimages, MAX_AFTERIMAGES)
	queue_redraw()


func spawn_slash(pos: Vector2, facing: int, radius: float = 96.0, arc_deg: float = 150.0,
		thickness: float = 14.0, color: Color = STEEL) -> void:
	_slashes.append({"pos": pos, "facing": facing, "r": radius, "arc": deg_to_rad(arc_deg),
		"th": thickness, "col": color, "t": 0.0, "life": 0.10})
	_bound(_slashes, 12)
	queue_redraw()


func spawn_glow(pos: Vector2, radius: float = 40.0, color: Color = BLOOD, life: float = 0.25) -> void:
	_glows.append({"pos": pos, "r": radius, "col": color, "t": 0.0, "life": life})
	_bound(_glows, 12)
	queue_redraw()


func spawn_sparks(pos: Vector2, direction: int = 1, count: int = 7, material: String = "flesh") -> void:
	for index in range(count):
		var angle := randf_range(-1.0, 1.0)
		var speed := randf_range(145.0, 390.0)
		var color := Color(0.72, 0.9, 1.0) if material == "metal" else Color(1.0, randf_range(0.66, 0.9), 0.4)
		_particle(pos, Vector2(cos(angle) * speed * direction, sin(angle) * speed - 50.0),
			color, randf_range(0.09, 0.23), "spark", 700.0, randf_range(1.0, 1.7))
	queue_redraw()


func spawn_dust(pos: Vector2, count: int = 5) -> void:
	for index in range(count):
		_particle(pos + Vector2(randf_range(-12, 12), -2), Vector2(randf_range(-80, 80), randf_range(-60, -15)),
			Color(0.64, 0.57, 0.47, 0.38), randf_range(0.17, 0.31), "dust", 130.0, randf_range(2.1, 4.2))
	queue_redraw()


func _particle(pos: Vector2, velocity: Vector2, color: Color, life: float,
		kind: String = "spark", gravity: float = 0.0, size: float = 1.5) -> void:
	_parts.append({"pos": pos, "vel": velocity, "col": color, "t": 0.0,
		"life": life, "grav": gravity, "kind": kind, "size": size, "spark": kind == "spark"})
	_bound(_parts, MAX_PARTICLES)


func _stroke(from: Vector2, to: Vector2, color: Color, width: float, life: float, alpha: float) -> void:
	color.a *= alpha
	_strokes.append({"from": from, "to": to, "col": color, "width": width, "t": 0.0, "life": life})
	_bound(_strokes, MAX_STROKES)


func _ring(pos: Vector2, start: float, radius: float, color: Color, life: float,
		alpha: float, flatten: float = 1.0) -> void:
	color.a *= alpha
	_rings.append({"pos": pos, "r0": start, "r1": radius, "col": color, "t": 0.0, "life": life, "flat": flatten})
	_bound(_rings, MAX_RINGS)


func _speed_lines(pos: Vector2, facing: int, color: Color, count: int, life: float) -> void:
	for index in range(count):
		var origin := pos + Vector2(-facing * randf_range(12, 58), randf_range(-172, -25))
		_stroke(origin, origin - Vector2(facing * randf_range(28, 75), 0), color, 1.0, life * randf_range(0.7, 1.0), 0.28)


func on_hit(world_pos: Vector2, direction: int, damage: float, hit: Dictionary) -> void:
	log_hits += 1
	hitstop(int(hit.get("hitstop", 4)))
	var move_id := str(hit.get("move_id", _active_move))
	var launch: bool = hit.has("launch") or str(hit.get("kind", "")) == "launch"
	var heavy: bool = launch or bool(hit.get("knockdown", false)) or str(hit.get("kind", "")) == "knock" or int(hit.get("hitstop", 4)) >= 6
	var vertical := -0.45 if launch else 0.12
	add_shake(float(hit.get("shake", 2.0)), Vector2(direction, vertical))
	var impact := world_pos + Vector2(0, -float(hit.get("impact_height", 88.0)))
	spawn_number(world_pos + Vector2(0, -112), str(roundi(damage)),
		Color(1.0, 0.87, 0.63) if heavy else Color(0.96, 0.93, 0.86), 26 if heavy else 21)
	var material := str(hit.get("material", "flesh"))
	spawn_sparks(impact, direction, 12 if heavy else 6, material)
	var hit_color := BLOOD if move_id == "rage_slash" else (STEEL if material == "metal" else IVORY)
	_flashes.append({"pos": impact, "t": 0.0, "life": 0.06 if heavy else 0.045,
		"size": 25.0 if heavy else 16.0, "col": hit_color})
	_bound(_flashes, 20)
	_ring(impact, 3.0, 42.0 if heavy else 24.0, hit_color, 0.18 if heavy else 0.12, 0.55 if heavy else 0.32)
	if heavy:
		for index in range(4):
			_particle(impact, Vector2(direction * randf_range(90, 220), randf_range(-155, -55)), Color(0.26, 0.21, 0.18), 0.24, "chip", 1000.0, randf_range(2.0, 3.8))
	play_sound("metal_hit" if material == "metal" else ("launch" if launch else ("heavy" if heavy else "light")), world_pos.x)
	queue_redraw()


func _bound(collection: Array, capacity: int) -> void:
	while collection.size() > capacity:
		collection.pop_front()


func clear_fx() -> void:
	freeze = 0
	shake = 0.0
	_shake_clock = 0.0
	_active_move = ""
	_rage_aura_cooldown = 0.0
	if camera != null:
		camera.offset = Vector2.ZERO
	for collection in [_trails, _slashes, _glows, _parts, _flashes, _strokes, _rings, _charges, _afterimages, _numbers]:
		collection.clear()
	for label in pool:
		label.visible = false
		label.modulate.a = 0.0
	_swing_group += 1
	if _audio != null:
		_audio.stop_all()
	queue_redraw()


func _update_fx(delta: float) -> void:
	var had_fx := false
	for collection in [_trails, _slashes, _glows, _parts, _flashes, _strokes, _rings, _charges, _afterimages]:
		had_fx = had_fx or not collection.is_empty()
		for index in range(collection.size() - 1, -1, -1):
			var entry: Dictionary = collection[index]
			entry["t"] = float(entry["t"]) + delta
			if float(entry["t"]) >= float(entry.get("life", TRAIL_LIFE)):
				collection.remove_at(index)
	for entry in _parts:
		var velocity: Vector2 = entry["vel"]
		velocity += Vector2(0, float(entry["grav"]) * delta)
		entry["pos"] = (entry["pos"] as Vector2) + velocity * delta
		entry["vel"] = velocity * exp(-2.6 * delta)
	if had_fx:
		queue_redraw()


func _draw() -> void:
	for ghost in _afterimages:
		var tint: Color = ghost["col"]
		tint.a *= pow(1.0 - float(ghost["t"]) / float(ghost["life"]), 1.5)
		draw_set_transform_matrix(ghost["transform"])
		draw_texture_rect_region(ghost["tex"], ghost["dst"], ghost["src"], tint)
		draw_set_transform_matrix(Transform2D.IDENTITY)
	for index in range(1, _trails.size()):
		var previous: Dictionary = _trails[index - 1]
		var current: Dictionary = _trails[index]
		if previous["group"] != current["group"]:
			continue
		var fade := clampf(1.0 - maxf(float(previous["t"]), float(current["t"])) / TRAIL_LIFE, 0.0, 1.0)
		var base_a: Vector2 = previous["p0"]
		var tip_a: Vector2 = previous["p1"]
		var base_b: Vector2 = current["p0"]
		var tip_b: Vector2 = current["p1"]
		var tint: Color = current["col"]
		var broad := tint
		broad.a *= fade * 0.10
		_quad(base_a.lerp(tip_a, 0.28), tip_a, tip_b, base_b.lerp(tip_b, 0.28), broad)
		var edge := tint
		edge.a *= fade * 0.34
		_quad(base_a.lerp(tip_a, 0.72), tip_a, tip_b, base_b.lerp(tip_b, 0.72), edge)
		draw_line(tip_a, tip_b, Color(1.0, 0.98, 0.91, fade * tint.a * 0.88), 1.8, true)
	for glow in _glows:
		var progress := float(glow["t"]) / float(glow["life"])
		var color: Color = glow["col"]
		for ring in range(4, 0, -1):
			var radius := float(glow["r"]) * float(ring) / 4.0 * (1.0 + progress * 0.2)
			color.a = (1.0 - progress) * 0.025
			draw_circle(glow["pos"], radius, color)
	for charge in _charges:
		var progress := float(charge["t"]) / float(charge["life"])
		var center: Vector2 = charge["pos"]
		var color: Color = charge["col"]
		color.a = 0.34 + progress * 0.25
		var radius := lerpf(35.0, 4.0, progress * progress)
		draw_arc(center, radius, -PI * 0.7, PI * 0.15, 16, color, 1.3, true)
		draw_arc(center, radius, PI * 0.3, PI * 1.15, 16, color, 1.3, true)
		color.a *= progress
		draw_line(center - Vector2(5, 0), center + Vector2(5, 0), color, 1.1, true)
	for stroke in _strokes:
		var progress := float(stroke["t"]) / float(stroke["life"])
		var color: Color = stroke["col"]
		color.a *= pow(1.0 - progress, 1.35)
		var from: Vector2 = stroke["from"]
		var to: Vector2 = stroke["to"]
		draw_line(from.lerp(to, progress * 0.30), to, color, maxf(0.6, float(stroke["width"]) * (1.0 - progress * 0.55)), true)
	for ring in _rings:
		var progress := float(ring["t"]) / float(ring["life"])
		var color: Color = ring["col"]
		color.a *= pow(1.0 - progress, 1.6)
		var radius := lerpf(float(ring["r0"]), float(ring["r1"]), 1.0 - pow(1.0 - progress, 2.0))
		draw_set_transform(ring["pos"], 0.0, Vector2(1.0, float(ring["flat"])))
		draw_arc(Vector2.ZERO, radius, 0.0, TAU, 30, color, 1.2, true)
		draw_set_transform_matrix(Transform2D.IDENTITY)
	for slash in _slashes:
		var progress := float(slash["t"]) / float(slash["life"])
		var color: Color = slash["col"]
		color.a *= (1.0 - progress) * 0.35
		_crescent(slash["pos"], float(slash["facing"]), float(slash["r"]) * (0.9 + 0.1 * progress), float(slash["arc"]), float(slash["th"]) * (1.0 - progress * 0.5), color)
	for flash in _flashes:
		var color: Color = flash["col"]
		color.a *= 1.0 - float(flash["t"]) / float(flash["life"])
		var center: Vector2 = flash["pos"]
		var size := float(flash["size"])
		draw_line(center + Vector2(-size, -size * 0.30), center + Vector2(size, size * 0.30), color, 1.7, true)
		draw_line(center + Vector2(-size * 0.25, size), center + Vector2(size * 0.25, -size), color, 1.5, true)
		draw_circle(center, 2.3, Color(1.0, 0.99, 0.95, color.a))
	for particle in _parts:
		var progress := float(particle["t"]) / float(particle["life"])
		var color: Color = particle["col"]
		color.a *= 1.0 - progress
		var pos: Vector2 = particle["pos"]
		var size := float(particle["size"])
		match str(particle["kind"]):
			"spark":
				var velocity: Vector2 = particle["vel"]
				draw_line(pos, pos - velocity.normalized() * (9.0 - progress * 5.0), color, size, true)
			"chip":
				_triangle(pos + Vector2(-size, size * 0.3), pos + Vector2(size, size * 0.8), pos + Vector2(0, -size), color)
			"dust":
				draw_set_transform(pos, 0.0, Vector2(1.7, 0.75))
				draw_circle(Vector2.ZERO, size * (1.0 + progress * 1.4), color)
				draw_set_transform_matrix(Transform2D.IDENTITY)
			"ember":
				draw_line(pos, pos + Vector2(0, 5.0 * (1.0 - progress)), color, size, true)
			_:
				draw_circle(pos, size * (1.0 - progress * 0.5), color)


func _quad(a: Vector2, b: Vector2, c: Vector2, d: Vector2, color: Color) -> void:
	# Explicit triangles handle folded ribbons without polygon triangulation errors.
	_triangle(a, b, c, color)
	_triangle(a, c, d, color)


func _triangle(a: Vector2, b: Vector2, c: Vector2, color: Color) -> void:
	if absf((b - a).cross(c - a)) >= 0.20:
		draw_colored_polygon(PackedVector2Array([a, b, c]), color)


func _crescent(center: Vector2, facing: float, radius: float, arc: float, thickness: float, color: Color) -> void:
	for index in range(16):
		var angle_a := -arc * 0.5 + arc * float(index) / 16.0
		var angle_b := -arc * 0.5 + arc * float(index + 1) / 16.0
		var dir_a := Vector2(cos(angle_a) * facing, sin(angle_a))
		var dir_b := Vector2(cos(angle_b) * facing, sin(angle_b))
		_quad(center + dir_a * radius, center + dir_b * radius,
			center + dir_b * (radius - thickness), center + dir_a * (radius - thickness), color)
