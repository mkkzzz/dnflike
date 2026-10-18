extends Node2D
## Render-only native-layer adapter. Physics, cooldowns, damage and skill assets stay with Player.
const Library := preload("res://scripts/swordsman_v7_lib.gd")
const MotionBlend := preload("res://scripts/swordsman_motion_blend.gd")
var motion := MotionBlend.new()
var actor: Player
var enabled := true
var _state := -1
var _facing := 1
var _was_dead := false
var _transient := ""
var _transient_clock := 0.0
var _transient_duration := 0.0
var _loop_clock := 0.0
var _base := ""
var _last_attack_tick := -1.0
var _hit_kind := "hit_light"
var _hit_time_left := 0

func setup(player: Player) -> void:
	actor = player
	Library.data()
	motion.setup(self)
	# Existing baseline tests explicitly exercise V3/V4/V6; the V7 regression
	# enables this adapter separately and tests the real installed package.
	enabled = not "--test" in OS.get_cmdline_user_args()
	queue_redraw()

func set_enabled(value: bool) -> void:
	enabled = value
	_state = -1
	_transient = ""
	_loop_clock = 0.0
	motion.reset()
	queue_redraw()
	if is_instance_valid(actor):
		actor.queue_redraw()

func active() -> bool:
	return enabled and is_instance_valid(actor) and not Library.data().is_empty() and _base_clip() != ""

func profile() -> String:
	if is_instance_valid(actor) and is_instance_valid(actor.weapon_attachment):
		var spec: Dictionary = actor.weapon_attachment.get("profile")
		return String(spec.get("v7_profile", "katana"))
	return "katana"

func _base_clip() -> String:
	if not is_instance_valid(actor):
		return ""
	if actor.dead:
		return "death"
	match actor.state:
		Player.St.IDLE: return "idle"
		Player.St.WALK: return "walk"
		Player.St.RUN: return "run"
		Player.St.JUMP:
			return "jump_apex" if absf(actor.velocity.y) < 140 else ("jump_rise" if actor.velocity.y < 0 else "jump_fall")
		Player.St.BACK_DASH: return "back_dash"
		Player.St.GUARD: return "guard"
		Player.St.HIT: return _hit_kind
		Player.St.AIR: return "air_hit"
		Player.St.DOWN: return "down"
		Player.St.GETUP: return "getup"
		Player.St.ATK, Player.St.AIR_ATK, Player.St.DASH_ATK:
			return actor.move_name if Library.data().get("clips", {}).has(actor.move_name) else ""
	return ""

func begin_transition(name: String, duration := -1.0) -> void:
	if not enabled or Library.clip(name).is_empty():
		return
	_transient = name
	_transient_clock = 0.0
	_transient_duration = float(Library.clip(name)["duration_ticks"]) if duration <= 0 else duration

func guard_impact(perfect: bool) -> void:
	begin_transition("parry" if perfect else "guard_recoil")

func current_clip() -> String:
	var priority := is_instance_valid(actor) and (actor.dead or actor.state in [Player.St.ATK,Player.St.AIR_ATK,Player.St.DASH_ATK,Player.St.HIT,Player.St.AIR,Player.St.DOWN,Player.St.GETUP])
	return _transient if _transient != "" and active() and not priority else _base_clip()

func clock(requested := -1.0) -> float:
	var name := current_clip()
	if _transient != "" and name == _transient:
		return _transient_clock * float(Library.clip(name)["duration_ticks"]) / maxf(1.0, _transient_duration)
	if actor.dead:
		return actor._death_t * 60.0
	if actor.state in actor.FRAME_STATES:
		var tick := actor.phase_t if requested < 0 else requested
		return tick * float(Library.clip(name).get("duration_ticks", 1)) / maxf(1.0, actor._move_duration())
	if actor.state == Player.St.GETUP:
		return (1.0 - float(actor.st_hit_left) / maxf(1.0, float(actor.cfg.get("getup_time", 12)))) * float(Library.clip(name)["duration_ticks"])
	if actor.state == Player.St.HIT:
		# Keep the recoil extreme readable before the existing recovery frames.
		# This affects presentation only; damage, invulnerability and stun keep
		# their gameplay duration and hitstop still freezes the same clock.
		return maxf(0.0, _loop_clock - 3.0)
	return _loop_clock

func visual_facing() -> int:
	return actor.facing

func body_matrix() -> Transform2D:
	var horizontal := float(visual_facing())
	return Transform2D(0.0, Vector2(horizontal * 0.5, 0.5), 0.0, Vector2(0, actor.depth_y))

func is_rising_combo() -> bool:
	return active() and bool(Library.data().get("combo_rising",false))

func _motion_sample(requested := -1.0, present := false) -> Dictionary:
	var name := current_clip()
	var frozen := (actor.fx != null and actor.fx.freeze > 0) or (not actor.control_enabled and not actor.dead)
	motion.sync_context(name,clock(),bool(Library.clip(name).get("loop",false)),frozen)
	var targets := Library.samples(name,clock(requested))
	return motion.present(targets,profile()) if present else motion.sample(targets)

func blade_local(tick := -1.0) -> Array:
	if Library.continuous():
		var pose := _motion_sample(tick)
		var blade: Dictionary = pose["blades"][profile()]
		var matrix := body_matrix()
		var result: Array = []
		for key in ["guard","tip"]:
			var point: Vector2 = matrix * (blade[key]-Library.anchor()) - Vector2(0,actor.depth_y)
			result.append(Vector2(point.x / float(actor.facing),point.y))
		return result
	var frame := Library.record(current_clip(), clock(tick))
	var p: Dictionary = frame.get("profiles", {}).get(profile(), {})
	if p.is_empty():
		return [Vector2.ZERO, Vector2.ZERO]
	return [(Library.point(p["guard"]) - Library.anchor()) * 0.5, (Library.point(p["tip"]) - Library.anchor()) * 0.5]

func snapshot() -> Dictionary:
	if not active():
		return {}
	var result := {"clip": current_clip(), "clock": clock(), "frame": Library.record(current_clip(), clock()),
		"profile": profile(), "facing": visual_facing(), "matrix": body_matrix(),
		"height_source": "physics_node_only", "native_scale": 0.5}
	if Library.continuous():
		transform = body_matrix()
		var actual := _motion_sample(-1.0,true)
		result["body_sources"] = actual["sources"]
		result["motion_geometry"] = actual["geometry"]
		result["blade_profiles"] = actual["blades"]
		result["weapon_node"] = motion.front_weapon if actual["blades"][profile()]["front"] else motion.back_weapon
	return result

func _physics_process(_delta: float) -> void:
	if not is_instance_valid(actor):
		return
	if actor.state == Player.St.HIT and (_state != Player.St.HIT or actor.st_hit_left > _hit_time_left + 1):
		_hit_kind = "hit_heavy" if actor.st_hit_left > 18 else "hit_light"
		_loop_clock = 0.0
		_base = ""
	var base := _base_clip()
	if not active():
		motion.reset()
		transform = Transform2D.IDENTITY
		_transient = ""
		_state = actor.state
		_was_dead = actor.dead
		queue_redraw()
		return
	var priority := actor.dead or actor.state in [Player.St.ATK, Player.St.AIR_ATK, Player.St.DASH_ATK, Player.St.HIT, Player.St.AIR, Player.St.DOWN, Player.St.GETUP]
	if priority:
		_transient = ""
	elif _was_dead and not actor.dead:
		begin_transition("revive")
	elif actor.state != _state:
		_transient = ""
		if actor.state == Player.St.WALK: begin_transition("walk_start")
		elif actor.state == Player.St.RUN: begin_transition("run_start")
		elif actor.state == Player.St.GUARD: begin_transition("guard_start")
		elif actor.state == Player.St.JUMP: begin_transition("jump_start", 1.0)
		elif actor.state == Player.St.IDLE and actor._landing_visual_left > 0: begin_transition("jump_land")
		elif actor.state == Player.St.IDLE and _state == Player.St.GUARD: begin_transition("guard_end")
		elif actor.state == Player.St.IDLE and _state in [Player.St.WALK, Player.St.RUN]: begin_transition("run_stop" if _state == Player.St.RUN else "walk_stop")
	if base != _base:
		_loop_clock = 0.0
		_base = base
	_state = actor.state
	_hit_time_left = actor.st_hit_left
	_facing = actor.facing
	_was_dead = actor.dead
	var frozen := actor.fx != null and actor.fx.freeze > 0
	if not frozen and (actor.control_enabled or actor.dead):
		var speed := 1.0
		if actor.state in [Player.St.WALK, Player.St.RUN]:
			var reference := float(actor.cfg.get("run_speed", 450) if actor.state == Player.St.RUN else actor.cfg.get("walk_speed", 225))
			speed = clampf(Vector2(actor.velocity.x, actor._lane_velocity).length() / maxf(1, reference), 0.55, 1.4)
		_loop_clock += speed
		if _transient != "":
			_transient_clock += 1.0
			if _transient_clock >= _transient_duration:
				var last: Dictionary = Library.clip(_transient)["frames"][-1]
				_transient = ""
				# Join start clips to the next genuine gait phase, not back to phase one.
				if base in ["walk", "run"]:
					for f in Library.clip(base)["frames"]:
						if f["source_pose"] == last["source_pose"]:
							_loop_clock = float(f["start_tick"]) + float(f["duration_ticks"])
	# The only trail samples are from the visible current weapon and body clock.
	if actor.state in [Player.St.ATK, Player.St.AIR_ATK, Player.St.DASH_ATK] and actor.phase == "active" and actor.fx != null and (not frozen or actor.phase_t != _last_attack_tick):
		var blade := blade_local()
		var root := actor.visual_position()
		actor.fx.weapon_trail(root + Vector2(blade[0].x * actor.facing, blade[0].y), root + Vector2(blade[1].x * actor.facing, blade[1].y), Color("#c7e6fa"), actor.phase_t != _last_attack_tick)
	_last_attack_tick = actor.phase_t
	if Library.continuous():
		transform = body_matrix()
		_motion_sample(-1.0,true)
	else:
		motion.hide_all()
		transform = Transform2D.IDENTITY
	queue_redraw()

func _draw_layer(reference: Dictionary) -> void:
	if reference.is_empty():
		return
	var texture := Library.texture(reference)
	if texture == null:
		return
	var rect: Array = reference["rect"]
	draw_texture(texture, Vector2(float(rect[0]), float(rect[1])) - Library.anchor())

func _draw() -> void:
	if not active():
		return
	if Library.continuous():return
	var frame := Library.record(current_clip(), clock())
	if frame.is_empty():
		return
	var weapon: Dictionary = frame["profiles"][profile()]
	draw_set_transform_matrix(body_matrix())
	_draw_layer(weapon["back"])
	_draw_layer(frame["body"])
	_draw_layer(weapon["front"])
	_draw_layer(frame["fingers"])
