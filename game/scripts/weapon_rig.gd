class_name WeaponRig
extends Node2D
## Render-only weapon attachment: profile geometry + authored frame grip sockets.
## Equipment can later select a profile without rebaking or changing body sprites.
const AnimLib := preload("res://scripts/anim_lib.gd")
var actor: Player
var fx: BattleFX
var profile: Dictionary = {}
var profile_id := "blacksteel"
var hand := Vector2.ZERO
var blade_angle := 0.0
var socket_layer := "front"
var _clip: Dictionary = {}
var _frame := 0
var _previous_tip := Vector2.ZERO
var _previous_base := Vector2.ZERO
var _previous_clock := -1.0
var _previous_move := ""
var _previous_phase := ""
var _previous_facing := 1
var _afterimage_clock := 0.0

func setup(player: Player, effects: BattleFX) -> void:
	actor = player
	fx = effects
	set_profile("blacksteel")
	actor.action_started.connect(_on_action_started)
	update_attachment()

func set_profile(identifier: String) -> bool:
	var table: Dictionary = GameConfig._load_json("res://data/weapons.json")
	var profiles: Dictionary = table.get("profiles", {})
	if not profiles.has(identifier):
		return false
	profile_id = identifier
	profile = profiles[identifier].duplicate(true)
	queue_redraw()
	return true

func _on_action_started(_identifier: String) -> void:
	_previous_tip = Vector2.ZERO
	_afterimage_clock = 0.0

func reset_pose() -> void:
	_previous_tip = Vector2.ZERO
	_previous_base = Vector2.ZERO
	_previous_clock = -1.0
	_previous_move = ""
	_afterimage_clock = 0.0
	update_attachment()

func socket_pose(clip: Dictionary, frame: int) -> Dictionary:
	var sockets: Array = clip.get("sockets", [])
	if sockets.is_empty():
		return {"hand": [14, -107], "angle": 32, "layer": "front"}
	return sockets[clampi(frame, 0, sockets.size() - 1)]

func update_attachment() -> void:
	if not is_instance_valid(actor):
		return
	_clip = actor.anims.get(actor.anim_name, {})
	_frame = actor.anim_frame
	if not actor.move_data.is_empty() and actor.state in actor.FRAME_STATES:
		_frame = AnimLib.frame_for_move(_clip, actor.phase_t, actor.move_data)
	# Legacy sprites contain a sword, so never render a second weapon on them.
	visible = bool(_clip.get("weapon_separated", false)) and not _clip.is_empty()
	if not visible:
		return
	var pose := socket_pose(_clip, _frame)
	var point: Array = pose.get("hand", [14, -107])
	hand = Vector2(float(point[0]), float(point[1]))
	blade_angle = _smooth_angle(pose)
	blade_angle = _floor_clear_angle(blade_angle)
	socket_layer = str(pose.get("layer", "front"))
	transform = actor.body_transform() * Transform2D(blade_angle, hand)
	z_index = -1 if socket_layer == "back" else 1
	# Keep the weapon as readable as its body during short invincibility flashes.
	modulate = Color.WHITE
	queue_redraw()

func _floor_clear_angle(angle: float) -> float:
	var body_world := actor.global_transform * actor.body_transform()
	var pivot := body_world * hand
	var length := float(profile.get("length", 144))
	var curve := float(profile.get("curve", 5))
	var a := body_world.x.y * length + body_world.y.y * curve
	var b := body_world.y.y * length - body_world.x.y * curve
	var clearance := actor.ground_y + actor.depth_y - 3.0 - pivot.y
	if a * cos(angle) + b * sin(angle) <= clearance:
		return angle
	var radius := maxf(1.0, sqrt(a * a + b * b))
	var shift := atan2(a, b)
	var limit := asin(clampf(clearance / radius, -0.995, 0.995))
	return (limit if cos(angle + shift) >= 0 else PI - limit) - shift

func _smooth_angle(pose: Dictionary) -> float:
	var angle := deg_to_rad(float(pose.get("angle", 32)))
	var frames := int(_clip.get("frames", 1))
	var authored: Dictionary = _clip.get("phase_frames", {})
	if authored.is_empty() or actor.move_data.is_empty():
		return angle
	var indices: Array = authored.get("windup", [])
	var start := 0.0
	var duration := float(actor.move_data.get("charge", actor.move_data.get("windup", 1)))
	if actor.move_data.has("hits"):
		var previous_end := 0.0
		var segments: Array = _clip.get("segments", [])
		for index in actor.move_data["hits"].size():
			var hit: Dictionary = actor.move_data["hits"][index]
			var delay := float(hit.get("delay", 0))
			var span := float(hit.get("active", 3))
			var segment: Dictionary = segments[mini(index, segments.size() - 1)] if not segments.is_empty() else authored
			if actor.phase_t <= delay:
				indices = segment.get("windup", [])
				start = previous_end
				duration = delay - previous_end
				break
			if actor.phase_t <= delay + span:
				indices = segment.get("active", [])
				start = delay
				duration = span
				break
			previous_end = delay + span
			indices = authored.get("recovery", [])
			start = previous_end
			duration = float(actor.move_data.get("recovery", 1))
	elif actor.phase == "active":
		indices = authored.get("active", [])
		start = duration
		duration = float(actor.move_data.get("active", 1))
	elif actor.phase == "recovery":
		indices = authored.get("recovery", [])
		start = duration + float(actor.move_data.get("active", 0))
		duration = float(actor.move_data.get("recovery", 1))
	if indices.is_empty():
		return angle
	var clock := clampf((actor.phase_t - start) / maxf(1, duration), 0, 0.99999) * indices.size()
	var index := mini(indices.size() - 1, int(clock))
	var next_index := mini(index + 1, indices.size() - 1)
	var next_frame := clampi(int(indices[next_index]), 0, frames - 1)
	var next_pose := socket_pose(_clip, next_frame)
	return lerp_angle(angle, deg_to_rad(float(next_pose.get("angle", 32))), clock - floorf(clock))

func blade_base_global() -> Vector2:
	return global_transform * Vector2(13, 0)

func blade_tip_global() -> Vector2:
	return global_transform * Vector2(float(profile.get("length", 144)), float(profile.get("curve", 5)))

func attack_region() -> Rect2:
	update_attachment()
	if not visible:
		return Rect2()
	var points := [blade_base_global(), blade_tip_global()]
	if _previous_phase == "active" and _previous_tip != Vector2.ZERO:
		points.append(_previous_base)
		points.append(_previous_tip)
	var bounds := Rect2(points[0], Vector2.ZERO)
	for point in points:
		bounds = bounds.expand(point)
	bounds = bounds.grow(7.0)
	var root_x := actor.global_position.x
	# Each move owns its facing cone; a rear windup never hits behind the actor.
	var left := maxf(root_x, bounds.position.x) if actor.facing > 0 else bounds.position.x
	var right := bounds.end.x if actor.facing > 0 else minf(root_x, bounds.end.x)
	return Rect2(left, bounds.position.y, maxf(0, right - left), bounds.size.y)

func _physics_process(delta: float) -> void:
	update_attachment()
	if not visible or fx == null or not is_instance_valid(actor):
		return
	if not actor.control_enabled or actor.dead:
		return
	var pose_changed := actor.phase_t != _previous_clock or actor.move_name != _previous_move
	var was_active := _previous_phase == "active"
	_previous_clock = actor.phase_t
	_previous_move = actor.move_name
	_previous_phase = actor.phase
	var tip := blade_tip_global()
	if actor.facing != _previous_facing or (_previous_tip != Vector2.ZERO and tip.distance_to(_previous_tip) > 380):
		fx.start_swing()
	_previous_facing = actor.facing
	if actor.phase == "active" and (fx.freeze <= 0 or pose_changed):
		var tint := Color(str(profile.get("trail", "#c7e6fa")))
		if actor.job == 1:
			tint = Color(1.0, 0.24, 0.32)
		if not was_active and _previous_tip != Vector2.ZERO:
			fx.weapon_trail(_previous_base, _previous_tip, tint, true)
		fx.weapon_trail(blade_base_global(), tip, tint, pose_changed)
	_previous_tip = tip
	_previous_base = blade_base_global()
	if fx.freeze > 0:
		return
	_afterimage_clock += delta
	if actor.move_name in ["dash_attack", "quick_draw", "thrust"] and actor.phase == "active" and _afterimage_clock >= 0.045:
		_afterimage_clock = 0.0
		if fx.has_method("sample_afterimage"):
			var source := AnimLib.src_rect(_clip, _frame)
			var destination := Rect2(-float(_clip["ax"]), -float(_clip["ay"]), float(_clip["frame_w"]), float(_clip["frame_h"]))
			fx.call("sample_afterimage", _clip["tex"], source, destination, actor.global_transform * actor.body_transform(), Color(0.54, 0.75, 1.0, 0.3))

func _color(key: String, fallback: String) -> Color:
	return Color(str(profile.get(key, fallback)))

func _draw() -> void:
	if profile.is_empty() or not visible:
		return
	var length := float(profile.get("length", 144))
	var width := float(profile.get("blade_width", 6.5))
	var curve := float(profile.get("curve", 5))
	var guard := float(profile.get("guard", 10))
	var grip := float(profile.get("grip", 24))
	var outline := PackedVector2Array([Vector2(13, -width * 0.6), Vector2(length * 0.58, -width * 0.48),
		Vector2(length - 16, curve - width * 0.38), Vector2(length, curve),
		Vector2(length - 17, curve + width * 0.46), Vector2(length * 0.55, width * 0.62), Vector2(13, width * 0.52)])
	draw_colored_polygon(outline, Color(0.045, 0.05, 0.065))
	var blade := PackedVector2Array([Vector2(14, -width * 0.37), Vector2(length * 0.58, -width * 0.3),
		Vector2(length - 16, curve - width * 0.18), Vector2(length - 2, curve),
		Vector2(length - 17, curve + width * 0.24), Vector2(length * 0.55, width * 0.4), Vector2(14, width * 0.3)])
	draw_polygon(blade, PackedColorArray([_color("spine", "#465e70"), _color("steel", "#b9cedb"),
		_color("steel", "#b9cedb"), _color("edge", "#ecf4f2"), _color("edge", "#ecf4f2"),
		_color("edge", "#ecf4f2"), _color("steel", "#b9cedb")]))
	draw_polyline(PackedVector2Array([Vector2(15, width * 0.17), Vector2(length * 0.55, width * 0.32),
		Vector2(length - 17, curve + width * 0.1), Vector2(length - 2, curve)]), _color("edge", "#ecf4f2"), 1.0, true)
	draw_line(Vector2(16, -width * 0.19), Vector2(length * 0.67, -width * 0.12), Color(0.6, 0.82, 0.91, 0.4), 1.0, true)
	# Handle, red leather binding, forged guard and pommel.
	draw_line(Vector2(-grip, 0), Vector2(13, 0), Color(0.03, 0.026, 0.035), 7.0, true)
	draw_line(Vector2(-grip + 3, 0), Vector2(11, 0), _color("handle", "#151822"), 5.0, true)
	for index in 5:
		var x := -grip + 4 + index * ((grip + 2) / 5.0)
		draw_line(Vector2(x, -2.0), Vector2(x + 3.5, 2.0), _color("wrap", "#8e2736"), 1.7, true)
	draw_line(Vector2(12, -guard * 0.55), Vector2(12, guard * 0.55), Color(0.07, 0.07, 0.09), 5.0, true)
	draw_line(Vector2(13, -guard * 0.48), Vector2(13, guard * 0.48), _color("metal", "#a89b7d"), 2.0, true)
	draw_line(Vector2(-grip - 1, -3.0), Vector2(-grip - 1, 3.0), _color("metal", "#a89b7d"), 3.0, true)
	# Restore the body's fist above the grip for convincing hand occlusion.
	if socket_layer == "front" and not _clip.is_empty():
		draw_set_transform_matrix(Transform2D(-blade_angle, Vector2.ZERO))
		var source := Rect2(float(_frame) * float(_clip["frame_w"]) + float(_clip["ax"]) + hand.x - 8,
			float(_clip["ay"]) + hand.y - 7, 16, 14)
		draw_texture_rect_region(_clip["tex"], Rect2(-8, -7, 16, 14), source)
		draw_set_transform_matrix(Transform2D.IDENTITY)
