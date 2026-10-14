class_name Player
extends CharacterBody2D
## Input, physical movement and combat clocks share the 60 Hz simulation.
## Artwork and the detachable weapon consume the same body_transform().
const AnimLib := preload("res://scripts/anim_lib.gd")
const SeqLib := preload("res://scripts/seq_lib.gd")
signal hp_changed(hp: float, max_hp: float)
signal died
signal landed_hit(monster: Node, damage: float)
signal action_feedback(message: String)
signal action_started(move_id: String)
signal seq_hitstop(tick: float, frame: int, blade: Vector2, point: Vector2, hitstop: int)
signal landed(impact_speed: float)

# Append states so existing scene/debug enum values remain stable.
enum St { IDLE, RUN, JUMP, BACK_DASH, GUARD, ATK, UPPER, SKILL, HIT, AIR, DOWN, GETUP, WALK, AIR_ATK, DASH_ATK }
const JOB_SKILLS := {1: ["blood_rage", "rage_slash"], 2: ["quick_draw", "thrust"]}
const JOB_KEYS := {1: ["skill_a", "skill_s"], 2: ["skill_a", "skill_s"]}
const BUFFER_ACTIONS := ["attack", "generic_skill", "jump", "back_dash", "guard", "skill_a", "skill_s", "potion_hp", "potion_mp"]
const FRAME_STATES := [St.ATK, St.UPPER, St.SKILL, St.BACK_DASH, St.AIR_ATK, St.DASH_ATK]

var cfg: Dictionary = {}
var fx: BattleFX
var weapon_attachment: Node2D
var monsters: Array = []
var state := St.IDLE
var facing := 1
var hp := 1000.0
var mp := 300.0
var ground_y := 576.0
var depth_y := 0.0
var arena_left := 64.0
var arena_right := 1216.0
var control_enabled := true
var dead := false
var running := false
var last_tap_dir := 0
var last_tap_ms := -999
var move_name := ""
var move_data: Dictionary = {}
var phase := ""
var phase_t := 0.0
var total_t := 0
var move_scale := 1.0
var hit_emitted := false
var skill_hit_idx := 0
var combo := 0
var combo_window := 0
var job := 0
var cds: Dictionary = {}
var buff_data: Dictionary = {}
var buff_t := 0.0
var invincible := 0
var potion_cd := 0
var st_hit_left := 0
var bounce_used := false
var upper_connected := false
var input_buffer: Array = []
var hit_targets: Dictionary = {}
var anims: Dictionary = {}
var anim_name := ""
var anim_frame := 0
var anim_tick := 0
var seq_data: Dictionary = {}
var seq_clips: Dictionary = {}
var seq_fx: Node = null
var last_hitstop := 0
var last_contact: Vector2 = Vector2.ZERO
var contact_log: Array = []

var coyote_left := 0
var _reset_grounded := false
var air_attack_count := 0
var _jump_running := false
var _jump_cut_pending := false
var _lane_velocity := 0.0
var _move_inertia := 0.0
var _event_segments: Dictionary = {}
var _landed_air_attack := false
var _landing_attack_left := 0
var _land_squash := 0.0
var _visual_clock := 0.0
var _anim_fraction := 0.0
var _step_distance := 0.0
var _death_t := 0.0
var _last_move_input := 0.0
var _guard_frames := 0
var _landing_visual_left := 0
var _seq_ground_done := false
var _input_clock_ms := 0.0
var _left_was_down := false
var _right_was_down := false
var _run_release_ms := 0.0
var _run_request_left := 0
var _run_request_dir := 0

func _ready() -> void:
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(40, 132)
	shape.shape = rect
	shape.position = Vector2(0, -66)
	add_child(shape)
	collision_layer = 2
	collision_mask = 1
	anims = AnimLib.load_group("player")
	_merge_seq_clips()
	anim_name = _pick_anim()

## V6：把 manifest 里 actor/<move> 的一体帧（角色与剑同一张原画）接到对应动作名上。
## 这四个 clip 自带逐 tick 时间轴与刀身采样线；其余动作仍走 V4 帧条。
func _merge_seq_clips() -> void:
	seq_data = GameConfig._load_json("res://data/seq_v6.json")
	seq_clips = SeqLib.load_clips()
	if seq_clips.is_empty():
		return
	var integrated := 0
	for name in seq_clips.keys():
		var prefix := "actor/"
		if not String(name).begins_with(prefix):
			continue
		var move := String(name).substr(prefix.length())
		var clip: Dictionary = seq_clips[name]
		if not _seq_move_valid(move, clip):
			continue
		anims[move] = _seq_clip_entry(move, clip)
		integrated += 1
	if integrated > 0:
		print("[SEQ6] integrated %d authored moves: %s" % [integrated, ", ".join(_seq_move_ids())])


func _seq_move_ids() -> Array:
	var ids: Array = []
	for move in anims:
		if anims[move].get("seq6", false):
			ids.append(String(move))
	ids.sort()
	return ids


## 只接管 manifest 明确按 tick 授权、且招式帧表长度与资源一致的招式
func _seq_move_valid(move: String, clip: Dictionary) -> bool:
	var authored: Dictionary = SeqLib.moves().get(move, {})
	if authored.is_empty():
		return false
	if int(authored.get("length", -1)) != int(clip["length_ticks"]):
		push_warning("[SEQ6] %s 帧表 %d tick 与 manifest %d 不一致，保留原表现" % [move, int(clip["length_ticks"]), int(authored.get("length", -1))])
		return false
	if not _seq_has_move_data(move):
		push_warning("[SEQ6] moves.json / skills.json 缺 %s，跳过接入" % move)
		return false
	return true


## 三段普攻在 moves.json，拔刀斩在 skills.json —— 两者都用同一套 manifest 帧表
func _seq_has_move_data(move: String) -> bool:
	return GameConfig.moves.has(move) or GameConfig.skills.has(move)


## 逐 tick 排帧的 clip 条目：durations 一个 tick 一项，actor 帧带刀身采样线。
func _seq_clip_entry(move: String, clip: Dictionary) -> Dictionary:
	# manifest 的 root_dx 是逐 tick 的累积参考位移；贴图本身已按固定解剖比例摆在画布上，
	# 所以这一项只做贴图偏移，绝不再平移角色节点。
	var durations: Array = []
	var blades: Array = []
	var offsets: Array = []
	var tick := 0
	for index in int(clip["length_ticks"]):
		durations.append(int(clip["spans"][index]))
		blades.append(clip["blade"][index * 2])
		blades.append(clip["blade"][index * 2 + 1])
		for _repeat in int(clip["spans"][index]):
			offsets.append(float(clip["root_dx"][tick]))
			tick += 1
	return {
		"name": move,
		"tex": clip["textures"][0],
		"frames": int(clip["length_ticks"]),
		"frame_w": float(clip["frame_w"]),
		"frame_h": float(clip["frame_h"]),
		"durations": durations,
		"loop": false,
		"ax": float(clip["anchor"].x),
		"ay": float(clip["anchor"].y),
		# 角色与剑一体原画：禁止再挂运行时武器，否则剑上会多一把剑
		"weapon_separated": false,
		"sockets": [],
		"phase_frames": {},
		"segments": [],
		"seq6": true,
		"seq_textures": clip["textures"],
		"seq_spans": clip["spans"],
		"seq_blade": blades,
		"seq_root_dx": offsets,
	}


## 本 tick 的 root_dx（美术参考位移，正数朝角色前方）。已经烘进原画，不能再平移节点。
func seq_root_offset(tick := -1.0) -> float:
	var offsets: Array = anims.get(anim_name, {}).get("seq_root_dx", [])
	if offsets.is_empty():
		return 0.0
	var at := phase_t if tick < 0.0 else tick
	return float(offsets[clampi(int(floor(at)), 0, offsets.size() - 1)])


## 该 tick 贴图相对 root 的左上角（含参考前冲）。1.0x 攻速时与预览逐像素一致。
func seq_texture_rect(tick := -1.0) -> Rect2:
	var clip: Dictionary = anims.get(anim_name, {})
	if clip.is_empty() or not clip.get("seq6", false):
		return Rect2()
	var at := phase_t if tick < 0.0 else tick
	var index := clampi(int(floor(at)), 0, int(clip["frames"]) - 1)
	return Rect2(Vector2(-float(clip["ax"]) + float(clip["seq_root_dx"][index]), -float(clip["ay"])),
		Vector2(float(clip["frame_w"]), float(clip["frame_h"])))


## 当前 action 是否由 V6 逐 tick 帧表驱动
func seq_active() -> bool:
	return bool(anims.get(anim_name, {}).get("seq6", false))


## V6 逐 tick 帧表的帧号换算（1.0x 攻速下帧号 == tick）
func _seq_frame_at(tick: float) -> int:
	var clip: Dictionary = anims.get(anim_name, {})
	if not clip.get("seq6", false):
		return anim_frame
	return AnimLib.frame_at_progress(clip, clampf(tick / maxf(1.0, _move_duration()), 0.0, 0.999999))


func _seq_blade_local(tick: float) -> Array:
	var clip: Dictionary = anims.get(anim_name, {})
	var blade: Array = clip.get("seq_blade", [])
	if blade.is_empty():
		return [Vector2.ZERO, Vector2.ZERO]
	var index := clampi(int(floor(tick)), 0, int(clip["frames"]) - 1)
	return [blade[index * 2], blade[index * 2 + 1]]


## 本 tick 的刀身采样线（世界坐标）。判定与刀光都用这一条实际可见的刃线。
func seq_blade_world(tick := -1.0) -> Array:
	var at := phase_t if tick < 0.0 else tick
	var local: Array = _seq_blade_local(at)
	var origin := visual_position()
	var guard: Vector2 = local[0]
	var tip: Vector2 = local[1]
	return [origin + Vector2(guard.x * float(facing), guard.y),
		origin + Vector2(tip.x * float(facing), tip.y)]


## 记录由战斗碰撞给出的真实接触点
func report_contact(point: Vector2, move: String, tick: float, segment: int, target: Node = null) -> void:
	last_contact = point
	# 记录命中那一刻目标的身体姿态，供验收核对接触点确实落在可见身体上
	var pose := {}
	if is_instance_valid(target):
		pose = {"anim": target.anim_name, "frame": target.anim_frame}
	contact_log.append({"move": move, "tick": tick, "segment": segment, "point": point, "target": pose, "id": target.get_instance_id() if is_instance_valid(target) else 0})
	if contact_log.size() > 64:
		contact_log.pop_front()


func _clear_seq_action() -> void:
	last_hitstop = 0
	if is_instance_valid(seq_fx):
		# 收招只清画面，接触/地裂/一闪记录留给验收日志
		seq_fx.call("reset", true)


func setup(data: Dictionary, battle_fx: BattleFX, monster_list: Array) -> void:
	cfg = data.duplicate(true)
	fx = battle_fx
	monsters = monster_list
	reset_combat(position)

func reset_combat(origin: Vector2) -> void:
	position = origin
	_reset_grounded = absf(origin.y - ground_y) < 1.0
	velocity = Vector2.ZERO
	hp = float(cfg.get("max_hp", 1000))
	mp = float(cfg.get("max_mp", 300))
	depth_y = float(cfg.get("depth_y", 0.0))
	state = St.IDLE
	facing = 1
	dead = false
	control_enabled = true
	running = false
	last_tap_dir = 0
	last_tap_ms = -999
	move_name = ""
	move_data = {}
	phase = ""
	phase_t = 0.0
	total_t = 0
	combo = 0
	combo_window = 0
	cds.clear()
	buff_data.clear()
	buff_t = 0.0
	invincible = 0
	potion_cd = 0
	st_hit_left = 0
	bounce_used = false
	upper_connected = false
	hit_emitted = false
	skill_hit_idx = 0
	move_scale = 1.0
	hit_targets.clear()
	input_buffer.clear()
	contact_log.clear()
	_event_segments.clear()
	coyote_left = int(cfg.get("coyote_frames", 6))
	air_attack_count = 0
	_jump_running = false
	_jump_cut_pending = false
	_lane_velocity = 0.0
	_move_inertia = 0.0
	_landed_air_attack = false
	_landing_attack_left = 0
	_land_squash = 0.0
	_visual_clock = 0.0
	_anim_fraction = 0.0
	_step_distance = 0.0
	_death_t = 0.0
	_last_move_input = 0.0
	_guard_frames = 0
	_landing_visual_left = 0
	_input_clock_ms = 0.0
	_left_was_down = false
	_right_was_down = false
	_run_release_ms = 0.0
	_run_request_left = 0
	_run_request_dir = 0
	anim_name = ""
	anim_frame = 0
	anim_tick = 0
	modulate = Color.WHITE
	_clear_seq_action()
	_anim_step()
	reset_physics_interpolation()
	hp_changed.emit(hp, float(cfg.get("max_hp", 1000)))
	queue_redraw()

func visual_position() -> Vector2:
	return global_position + Vector2(0, depth_y)

func body_transform() -> Transform2D:
	var squash := _land_squash
	var stretch := 0.0
	if not is_on_floor() and not dead and state != St.AIR:
		stretch = clampf(-velocity.y / maxf(1.0, absf(float(GameConfig.moves.get("jump", {}).get("vy", -870)))), 0.0, 1.0)
	var breathe := sin(_visual_clock * float(cfg.get("breath_rate", 3.4))) * float(cfg.get("breath_amount", 0.003)) if state == St.IDLE else 0.0
	var sx := 1.0 + squash * float(cfg.get("landing_squash_x", 0.045)) - stretch * float(cfg.get("jump_stretch_x", 0.015))
	var sy := 1.0 - squash * float(cfg.get("landing_squash_y", 0.065)) + stretch * float(cfg.get("jump_stretch_y", 0.025)) + breathe
	var lean := clampf(velocity.x / maxf(1.0, float(cfg.get("run_speed", 450))), -1.0, 1.0) * float(cfg.get("motion_lean", 0.016))
	if state in FRAME_STATES or dead:
		lean *= 0.35
	return Transform2D(lean, Vector2(float(facing) * sx, sy), 0.0, Vector2(0, depth_y))

func hurtbox() -> Rect2:
	var height := float(cfg.get("hurtbox_height", 190))
	return Rect2(global_position + Vector2(-22, depth_y - height), Vector2(44, height))

func _physics_process(delta: float) -> void:
	if dead:
		_tick_dead(delta)
		return
	if not control_enabled:
		input_buffer.clear()
		return
	# Hitstop pauses simulation, but never loses an input edge.
	_sample_input(delta)
	_tick_cooldowns()
	if fx != null and fx.freeze > 0:
		return
	_update_timers(delta)
	var was_grounded := is_on_floor() and velocity.y >= 0.0
	match state:
		St.IDLE, St.WALK, St.RUN:
			_free_state(delta)
		St.JUMP:
			_jump_state(delta)
		St.ATK, St.UPPER, St.SKILL, St.BACK_DASH, St.AIR_ATK, St.DASH_ATK:
			_tick_frame_move(delta)
		St.GUARD:
			velocity.x = move_toward(velocity.x, 0.0, float(cfg.get("guard_brake", 7200)) * delta)
			if not Input.is_action_pressed("guard"):
				state = St.IDLE if is_on_floor() else St.JUMP
				_consume_buffer()
		St.HIT:
			velocity.x = move_toward(velocity.x, 0.0, 640.0 * delta)
			st_hit_left -= 1
			if st_hit_left <= 0:
				state = St.IDLE if is_on_floor() else St.JUMP
		St.AIR:
			velocity.x = move_toward(velocity.x, 0.0, 240.0 * delta)
		St.DOWN:
			velocity.x = move_toward(velocity.x, 0.0, 800.0 * delta)
			st_hit_left -= 1
			if st_hit_left <= 0 or (st_hit_left <= int(cfg.get("down_time", 36)) / 2 and _has_buffer("jump")):
				input_buffer.clear()
				state = St.GETUP
				st_hit_left = int(cfg.get("getup_time", 12))
				invincible = st_hit_left + 1
		St.GETUP:
			velocity.x = 0.0
			st_hit_left -= 1
			if st_hit_left <= 0:
				state = St.IDLE
	_apply_jump_cut()
	if not is_on_floor() or velocity.y < 0.0:
		var gravity_scale := float(move_data.get("gravity_scale", 1.0)) if state in FRAME_STATES else 1.0
		velocity.y += float(cfg.get("gravity", 2100)) * gravity_scale * delta
	else:
		velocity.y = 0.0
	var falling_speed := velocity.y
	move_and_slide()
	_reset_grounded = false
	position.x = clampf(position.x, arena_left, arena_right)
	if is_on_floor() and falling_speed >= 0.0:
		if not was_grounded:
			_on_landed(falling_speed)
		if state == St.JUMP:
			state = St.IDLE
			_consume_buffer()
		elif state == St.AIR:
			if not bounce_used and falling_speed > float(cfg.get("bounce_speed_threshold", 480)):
				bounce_used = true
				velocity.y = -falling_speed * float(cfg.get("bounce_ratio", 0.35))
			else:
				state = St.DOWN
				st_hit_left = int(cfg.get("down_time", 36))
	elif state in [St.IDLE, St.WALK, St.RUN]:
		state = St.JUMP
	z_index = 100 + int(round(depth_y))
	_anim_step()
	if fx != null and buff_t > 0.0 and not buff_data.is_empty():
		fx.rage_aura(visual_position(), facing)
	queue_redraw()

func _sample_input(delta := 1.0 / 60.0) -> void:
	# Direction edges belong to input, not the free movement state. A double tap
	# during a slash or hitstop must survive until its legal movement cancel.
	_input_clock_ms += delta * 1000.0
	_update_double_tap(_dir_input())
	if _dir_input() == 0.0:
		_run_release_ms += delta * 1000.0
		if _run_release_ms > float(cfg.get("run_release_grace_ms", 140)) and (_run_request_left <= 0 or not state in FRAME_STATES):
			running = false
			_run_request_dir = 0
	else:
		_run_release_ms = 0.0
	for action in BUFFER_ACTIONS:
		if InputMap.has_action(action) and Input.is_action_just_pressed(action):
			buffer_action(action)
	if Input.is_action_just_released("jump"):
		_jump_cut_pending = true
		for entry in input_buffer:
			if entry["action"] == "jump":
				entry["released"] = true

func buffer_action(action: String) -> void:
	var ttl := int(cfg.get("jump_buffer_frames", 6) if action == "jump" else cfg.get("input_buffer_frames", 14))
	var crouching := InputMap.has_action("move_down") and Input.is_action_pressed("move_down")
	for entry in input_buffer:
		if entry["action"] == action:
			entry["ttl"] = ttl
			entry["down"] = crouching
			entry["released"] = false
			return
	input_buffer.append({"action": action, "ttl": ttl, "down": crouching, "released": false})

func _has_buffer(action: String) -> bool:
	for entry in input_buffer:
		if entry["action"] == action:
			return true
	return false

func _update_timers(delta: float) -> void:
	_landing_visual_left = maxi(0, _landing_visual_left - 1)
	invincible = maxi(0, invincible - 1)
	potion_cd = maxi(0, potion_cd - 1)
	_visual_clock += delta
	if state == St.GUARD:
		_guard_frames += 1
	_land_squash = move_toward(_land_squash, 0.0, delta * float(cfg.get("landing_settle_speed", 8.0)))
	if is_on_floor() and velocity.y >= 0.0 and state in [St.IDLE, St.WALK, St.RUN, St.GUARD]:
		coyote_left = int(cfg.get("coyote_frames", 6))
	else:
		coyote_left = maxi(0, coyote_left - 1)
	if buff_t > 0.0:
		buff_t = maxf(0.0, buff_t - delta)
		if buff_t == 0.0:
			buff_data.clear()
	if combo_window > 0:
		combo_window -= 1
	elif state not in [St.ATK, St.DASH_ATK]:
		combo = 0
	_run_request_left = maxi(0, _run_request_left - 1)
	for idx in range(input_buffer.size() - 1, -1, -1):
		input_buffer[idx]["ttl"] -= 1
		if int(input_buffer[idx]["ttl"]) < 0:
			input_buffer.remove_at(idx)

func _dir_input() -> float:
	return Input.get_axis("move_left", "move_right")

func _is_sprinting() -> bool:
	return running

func buffer_run(direction: int) -> void:
	if direction == 0:
		return
	running = true
	_run_request_dir = signi(direction)
	_run_request_left = int(cfg.get("run_input_buffer_frames", 36))
	_run_release_ms = 0.0

func _update_double_tap(d: float) -> void:
	var left_down := Input.is_action_pressed("move_left")
	var right_down := Input.is_action_pressed("move_right")
	var pressed := 0
	if left_down and not _left_was_down:
		pressed = -1
	if right_down and not _right_was_down:
		pressed = 1
	_left_was_down = left_down
	_right_was_down = right_down
	if pressed != 0:
		var direction := pressed
		var now := int(round(_input_clock_ms))
		if last_tap_dir == direction and now - last_tap_ms <= int(cfg.get("double_tap_ms", 250)):
			buffer_run(direction)
		last_tap_dir = direction
		last_tap_ms = now
	# Once running, a held opposite direction requests another run gait rather
	# than downgrading to walk. A prolonged release still clears the intention.
	if running and d != 0.0:
		_run_request_dir = int(signf(d))

func _tick_cooldowns() -> void:
	# One real physical tick, independently of attack speed and hitstop.
	for key in cds:
		cds[key] = maxi(0, int(cds[key]) - 1)

func _move_lane(delta: float, airborne := false) -> void:
	var lane := Input.get_axis("move_up", "move_down") if InputMap.has_action("move_up") else 0.0
	var speed := float(cfg.get("lane_speed", 100)) * (float(cfg.get("air_lane_scale", 0.65)) if airborne else 1.0)
	_lane_velocity = move_toward(_lane_velocity, lane * speed, float(cfg.get("lane_acceleration", 2200)) * delta)
	depth_y = clampf(depth_y + _lane_velocity * delta, float(cfg.get("lane_min", -40)), float(cfg.get("lane_max", 24)))

func _free_state(delta: float) -> void:
	var direction := _dir_input()
	var previous_velocity := velocity.x
	var previous_state := state
	_move_lane(delta)
	if direction != 0.0:
		facing = int(signf(direction))
	var sprinting := _is_sprinting()
	var speed := float(cfg.get("run_speed", 450) if sprinting else cfg.get("walk_speed", 225))
	speed *= float(cfg.get("move_speed", 1.0)) * float(buff_data.get("move_speed", 1.0))
	var accel := float(cfg.get("run_acceleration", 5400) if sprinting else cfg.get("walk_acceleration", 5200))
	if direction == 0.0:
		accel = float(cfg.get("ground_brake", 6500))
	elif velocity.x * direction < 0.0:
		accel = float(cfg.get("run_turn_acceleration", 18000) if sprinting else cfg.get("turn_acceleration", 12500))
	velocity.x = move_toward(velocity.x, direction * speed, accel * delta)
	state = (St.RUN if sprinting else St.WALK) if direction != 0.0 else St.IDLE
	if direction != 0.0 and sprinting:
		_run_request_left = 0
	if fx != null:
		if direction == 0.0 and _last_move_input != 0.0 and absf(previous_velocity) > float(cfg.get("stop_fx_speed", 260)):
			fx.locomotion_event(visual_position(), facing, "stop", clampf(absf(previous_velocity) / speed, 0.4, 1.0))
		elif direction != 0.0 and direction != _last_move_input and previous_velocity * direction < 0.0 and absf(previous_velocity) > float(cfg.get("turn_fx_speed", 120)):
			fx.locomotion_event(visual_position(), facing, "turn", 0.7)
		elif state == St.RUN and previous_state != St.RUN and direction != 0.0:
			fx.locomotion_event(visual_position(), facing, "run", 0.6)
	_last_move_input = direction
	_step_distance += absf(velocity.x) * delta
	var stride := float(cfg.get("run_stride", 152) if sprinting else cfg.get("walk_stride", 108))
	if direction != 0.0 and _step_distance >= stride:
		_step_distance = fmod(_step_distance, stride)
		if fx != null:
			fx.locomotion_event(visual_position(), facing, "run" if sprinting else "step", 0.9 if sprinting else 0.5)
	elif direction == 0.0:
		_step_distance = 0.0
	if not _consume_buffer() and Input.is_action_pressed("guard"):
		_start_guard()

func _jump_state(delta: float) -> void:
	_move_lane(delta, true)
	_air_control(delta)
	_consume_buffer()

func _air_control(delta: float) -> void:
	var direction := _dir_input()
	if direction != 0.0:
		facing = int(signf(direction))
		var cap := float(cfg.get("air_run_speed", 450) if _jump_running else cfg.get("air_walk_speed", 235)) * float(buff_data.get("move_speed", 1.0))
		var acceleration := float(cfg.get("air_turn_acceleration", 3700) if velocity.x * direction < 0.0 else cfg.get("air_acceleration", 2050))
		velocity.x = move_toward(velocity.x, direction * cap, acceleration * delta)
	else:
		velocity.x = move_toward(velocity.x, 0.0, float(cfg.get("air_drag", 140)) * delta)

func _consume_buffer(cancel_only := false) -> bool:
	var idx := 0
	while idx < input_buffer.size():
		var entry: Dictionary = input_buffer[idx]
		var action: String = entry["action"]
		if action in ["potion_hp", "potion_mp"]:
			input_buffer.remove_at(idx)
			if _use_potion(action):
				return true
			continue
		if cancel_only and not _can_cancel(action):
			idx += 1
			continue
		var grounded := (is_on_floor() or _reset_grounded) and velocity.y >= 0.0
		if action == "jump" and not grounded and coyote_left <= 0:
			idx += 1
			continue
		if action in ["back_dash", "guard", "generic_skill"] and not grounded:
			idx += 1
			continue
		if action == "attack" and not grounded and air_attack_count >= int(cfg.get("air_attacks_per_jump", 2)):
			idx += 1
			continue
		if action in ["skill_a", "skill_s"] and not grounded and not _skill_air_allowed(action):
			idx += 1
			continue
		var basic_id := ""
		if action == "generic_skill":
			basic_id = "upper"
		elif action == "back_dash" or (action == "jump" and bool(entry.get("down", false)) and grounded):
			basic_id = "back_dash"
		if not basic_id.is_empty() and not _basic_move_ready(basic_id):
			# A rejected cooldown request is discarded, but another valid input in
			# the same buffer may still execute during this physical frame.
			input_buffer.remove_at(idx)
			continue
		input_buffer.remove_at(idx)
		match action:
			"attack": _start_attack()
			"generic_skill": _start_move("upper")
			"jump":
				if bool(entry.get("down", false)) and grounded:
					_start_move("back_dash")
				else:
					_start_jump(bool(entry.get("released", false)))
			"back_dash": _start_move("back_dash")
			"guard": _start_guard()
			"skill_a", "skill_s":
				if not _try_skill_action(action):
					continue
			_: continue
		return true
	return false

func _can_cancel(action: String) -> bool:
	if state == St.BACK_DASH:
		return is_on_floor() and phase_t >= float(move_data.get("cancel_after", _move_duration())) and action in move_data.get("cancel_to", [])
	if state == St.AIR_ATK and _landed_air_attack:
		return _landing_attack_left <= int(move_data.get("landing_cancel_frames", 2))
	var allowed: Array = move_data.get("cancel_to", ["attack", "generic_skill", "skill_a", "skill_s", "back_dash", "guard", "jump"])
	if not action in allowed:
		return false
	if action == "attack":
		if state in [St.ATK, St.DASH_ATK] and combo >= 3:
			return false
		if state not in [St.ATK, St.DASH_ATK, St.AIR_ATK]:
			return false
	if action == "jump" and state == St.UPPER and upper_connected:
		return phase_t >= float(move_data.get("jump_cancel_after", 8))
	var threshold := float(move_data.get("hit_cancel_after", move_data.get("cancel_after", _move_duration()))) if hit_emitted else float(move_data.get("cancel_after", _move_duration()))
	if action in ["back_dash", "guard", "jump"]:
		threshold = float(move_data.get("defensive_cancel_after", threshold)) if hit_emitted else float(move_data.get("whiff_defensive_cancel_after", threshold))
	return phase_t >= threshold

func _start_guard() -> void:
	_clear_move()
	combo = 0
	combo_window = 0
	state = St.GUARD
	_guard_frames = 0
	velocity.x *= float(cfg.get("guard_momentum_retention", 0.1))
	_lane_velocity = 0.0
	action_started.emit("guard")

func _start_jump(short_jump := false) -> void:
	_landing_visual_left = 0
	_clear_move()
	_reset_grounded = false
	combo = 0
	combo_window = 0
	_jump_running = _is_sprinting() or absf(velocity.x) > float(cfg.get("jump_run_threshold", 290))
	_jump_cut_pending = short_jump
	velocity.y = float(GameConfig.moves["jump"].get("vy", -870))
	state = St.JUMP
	coyote_left = 0
	air_attack_count = 0
	_land_squash = 0.0
	# Consume every stale jump edge once. Holding C never causes a landing jump.
	for idx in range(input_buffer.size() - 1, -1, -1):
		if input_buffer[idx]["action"] == "jump":
			input_buffer.remove_at(idx)
	action_started.emit("jump")
	if fx != null:
		fx.locomotion_event(visual_position(), facing, "jump")

func _apply_jump_cut() -> void:
	if not _jump_cut_pending:
		return
	if state in [St.JUMP, St.AIR_ATK] and velocity.y < 0.0:
		velocity.y = maxf(velocity.y * float(cfg.get("jump_cut_ratio", 0.62)), float(cfg.get("jump_cut_speed", -535)))
	_jump_cut_pending = false

func _start_attack() -> void:
	if (not is_on_floor() and not _reset_grounded) or velocity.y < 0.0:
		if air_attack_count >= int(cfg.get("air_attacks_per_jump", 2)):
			return
		air_attack_count += 1
		combo = 0
		_start_move("air_attack")
		return
	if combo == 0 and state in [St.IDLE, St.WALK, St.RUN] and _is_sprinting() and velocity.x * float(facing) >= float(cfg.get("dash_attack_min_speed", 270)):
		_start_move("dash_attack")
		combo = 1
		return
	var idx := combo % 3
	move_name = ["attack1", "attack2", "attack3"][idx]
	move_data = GameConfig.moves[move_name]
	_start_frame_move()
	combo = idx + 1
	combo_window = 0

func _basic_move_ready(identifier: String, feedback := true) -> bool:
	if int(cds.get(identifier, 0)) <= 0:
		return true
	if feedback:
		var label := "上挑" if identifier == "upper" else "后跳"
		_notify("%s 冷却 %.1fs" % [label, float(cds[identifier]) / 60.0], Color(0.65, 0.78, 1.0))
	return false

func basic_cooldown_fraction(identifier: String) -> float:
	var data: Dictionary = GameConfig.moves.get(identifier, {})
	return clampf(float(cds.get(identifier, 0)) / maxf(1.0, float(data.get("cd", 0)) * 60.0), 0.0, 1.0)

func _start_move(action: String) -> bool:
	if action == "jump":
		_start_jump()
		return true
	if action in ["upper", "back_dash"] and not _basic_move_ready(action):
		return false
	move_name = action
	move_data = GameConfig.moves[action]
	if action != "upper":
		combo = 0
		combo_window = 0
	_start_frame_move()
	return true

func _start_frame_move() -> void:
	_landing_visual_left = 0
	var direction := _dir_input()
	if direction != 0.0:
		facing = int(signf(direction))
	phase = "charge" if move_data.has("charge") else "windup"
	phase_t = 0.0
	total_t = 0
	hit_emitted = false
	skill_hit_idx = 0
	hit_targets.clear()
	_event_segments.clear()
	upper_connected = false
	_landed_air_attack = false
	_landing_attack_left = 0
	_move_inertia = velocity.x * float(move_data.get("momentum_retention", 0.22))
	velocity.x = _move_inertia
	_lane_velocity = 0.0
	move_scale = _attack_speed() if move_name in ["attack1", "attack2", "attack3", "air_attack", "dash_attack"] or bool(move_data.get("attack_speed_scaled", false)) else 1.0
	_seq_ground_done = false
	if move_name in ["upper", "back_dash"]:
		cds[move_name] = int(round(float(move_data.get("cd", 0)) * 60.0))
	match move_name:
		"upper": state = St.UPPER
		"back_dash":
			state = St.BACK_DASH
			invincible = maxi(invincible, int(move_data.get("invincible", 7)))
			velocity.y = float(move_data.get("vy", -340))
			_move_inertia = 0.0
			coyote_left = 0
		"air_attack": state = St.AIR_ATK
		"dash_attack": state = St.DASH_ATK
		"attack1", "attack2", "attack3": state = St.ATK
		_: state = St.SKILL
	anim_name = _pick_anim()
	anim_frame = 0
	anim_tick = 0
	_anim_fraction = 0.0
	# V6 表现层必须在 phase_t 前进前拿到出招起点 root（刀光锚点固定在这里）
	action_started.emit(move_name)
	_emit_attack_event("windup", -1, move_data)

func _emit_attack_event(event_phase: String, segment: int, data: Dictionary) -> void:
	if fx == null:
		return
	var event := data.duplicate(true)
	event["phase"] = event_phase
	event["segment"] = segment
	event["job"] = job
	event["buffed"] = buff_t > 0.0
	event["airborne"] = not is_on_floor() or velocity.y < 0.0
	fx.attack_event(visual_position(), facing, move_name, event)

func _attack_speed() -> float:
	return clampf(float(cfg.get("attack_speed", 1.0)) * float(buff_data.get("atk_speed", 1.0)), float(cfg.get("attack_speed_min", 0.5)), float(cfg.get("attack_speed_max", 2.2)))

func _move_duration() -> float:
	if move_data.has("hits"):
		var last: Dictionary = move_data["hits"][-1]
		return float(last.get("delay", 0)) + float(last.get("active", 3)) + float(move_data.get("recovery", 0))
	return float(move_data.get("charge", move_data.get("windup", 0))) + float(move_data.get("active", 0)) + float(move_data.get("recovery", 0))

func _tick_frame_move(delta := 1.0 / 60.0) -> void:
	var previous := phase_t
	phase_t += move_scale
	total_t += 1
	_move_inertia = move_toward(_move_inertia, 0.0, float(move_data.get("recovery_drag", 1850) if phase == "recovery" else move_data.get("momentum_drag", 900)) * delta)
	velocity.x = _move_inertia
	if state == St.BACK_DASH:
		phase = "recovery"
		velocity.x = float(facing) * (_back_dash_offset(phase_t) - _back_dash_offset(previous)) / maxf(delta, 0.0001)
	elif seq_active():
		# V6：phase_t 就是 manifest 的动作 tick，前冲位移已经烘进原画，不再叠加节点平移
		phase = _seq_phase(phase_t)
		_seq_tick(previous)
		# 命中即停帧，但贴图必须停在真正的接触姿势上，所以先同步一次帧号再冻结
		_anim_step()
		if fx != null and fx.freeze > 0:
			return
		_finish_or_cancel_frame_move(delta)
		return
	elif move_data.has("hits"):
		phase = "windup"
		var hits: Array = move_data["hits"]
		for idx in hits.size():
			var hit: Dictionary = hits[idx]
			var start := float(hit.get("delay", 0))
			var span := float(hit.get("active", 3))
			if _window_overlaps(previous, phase_t, start, span):
				phase = "active"
				if not _event_segments.has(idx):
					_event_segments[idx] = true
					_emit_attack_event("active", idx, hit)
				_emit_melee(hit, float(idx))
				if hit.has("move"):
					var covered := maxf(0.0, minf(phase_t, start + span) - maxf(previous, start))
					velocity.x += facing * float(hit["move"]) * covered / span * 60.0
				skill_hit_idx = maxi(skill_hit_idx, idx + 1)
		var last: Dictionary = hits[-1]
		if phase_t > float(last.get("delay", 0)) + float(last.get("active", 3)):
			phase = "recovery"
	else:
		var windup := float(move_data.get("charge", move_data.get("windup", 0)))
		var active := float(move_data.get("active", 0))
		phase = "windup" if phase_t <= windup else ("active" if phase_t <= windup + active else "recovery")
		if move_data.has("charge") and phase == "windup":
			phase = "charge"
		var motion_start := float(move_data.get("motion_start", 0))
		var motion_end := float(move_data.get("motion_end", windup + active))
		if move_data.has("move") and _window_overlaps(previous, phase_t, motion_start, motion_end - motion_start):
			var covered := maxf(0.0, minf(phase_t, motion_end) - maxf(previous, motion_start))
			velocity.x += facing * float(move_data["move"]) * covered / maxf(1.0, motion_end - motion_start) * 60.0
		if _window_overlaps(previous, phase_t, windup, active):
			if not _event_segments.has(0):
				_event_segments[0] = true
				_emit_attack_event("active", 0, move_data)
			if int(move_data.get("invincible_active", 0)) > 0:
				invincible = maxi(invincible, 1)
			_emit_melee(move_data, 0.0)
	# Connected lunges plant the lead foot. Continuing the authored travel after
	# contact would pass through a close target and strand the following combo.
	if state == St.DASH_ATK and hit_emitted:
		_move_inertia = 0.0
		velocity.x = 0.0
	if state == St.AIR_ATK and not _landed_air_attack:
		_move_lane(delta, true)
		# Steering remains possible; attacking never grants upward velocity.
		var direction := _dir_input()
		if direction != 0.0:
			var cap := float(cfg.get("air_run_speed", 450) if _jump_running else cfg.get("air_walk_speed", 235)) * float(buff_data.get("move_speed", 1.0))
			_move_inertia = move_toward(_move_inertia, direction * cap, float(cfg.get("air_attack_acceleration", 950)) * delta)
			velocity.x = _move_inertia
	if fx != null and fx.freeze > 0:
		return
	_finish_or_cancel_frame_move(delta)

## 招式收尾判定：V6 逐 tick 帧表与旧帧表共用同一条结束/取消路径
func _finish_or_cancel_frame_move(delta: float) -> void:
	if _landed_air_attack:
		_landing_attack_left -= 1
		if _landing_attack_left <= 0:
			_finish_move_and_resume(delta)
			return
	if phase_t >= _move_duration():
		_finish_move_and_resume(delta)
	else:
		if not _consume_buffer(true):
			if Input.is_action_pressed("guard") and is_on_floor() and _can_cancel("guard"):
				_start_guard()
			elif _can_locomotion_cancel():
				_finish_move_and_resume(delta)

## V6 动作阶段按 manifest 的 active 窗口划分；命中窗口内每 tick 都用真实刃线做判定
func _seq_phase(tick: float) -> String:
	var window: Array = _seq_window()
	var start := float(window[0])
	var end := float(window[1])
	if tick < start:
		return "windup"
	return "active" if tick < end else "recovery"


func _seq_window() -> Array:
	if not is_instance_valid(seq_fx):
		return [0.0, 0.0]
	var entry: Dictionary = seq_fx.call("current_window")
	if entry.is_empty():
		return [0.0, 0.0]
	return [float(entry.get("start", 0.0)), float(entry.get("end", 0.0))]


## 逐 tick 推进 V6 招式：前冲只做视觉展现代价，不改存档的 move_data 位移
func _seq_tick(previous: float) -> void:
	var window: Array = _seq_window()
	var start := float(window[0])
	var end := float(window[1])
	var overlapping := _window_overlaps(previous, phase_t, start, end - start)
	if overlapping:
		if not _event_segments.has(0):
			_event_segments[0] = true
			var event := move_data.duplicate(true)
			event["seq6"] = true
			event["fx_kind"] = _seq_fx_kind()
			event["trail_life"] = _seq_trail_life()
			_emit_attack_event("active", 0, event)
			if fx != null:
				fx.call("seq_swing_sound", move_name, visual_position().x)
		_seq_hit(start, end)
		skill_hit_idx = 1
	if not _seq_ground_done and _seq_ground_reached():
		_seq_ground_done = true
		if is_instance_valid(seq_fx):
			seq_fx.call("spawn_ground", seq_ground_point())


func _seq_fx_kind() -> String:
	return str(_seq_move_data().get("fx", "light"))


func _seq_trail_life() -> int:
	return int(_seq_move_data().get("trail_life", 5))


func _seq_move_data() -> Dictionary:
	if is_instance_valid(seq_fx):
		return seq_fx.call("move_params")
	return {}


## 重劈地裂：只在可见刀尖真正落到地面线时触发一次，锚点取落地坐标
func _seq_ground_reached() -> bool:
	if not bool(_seq_move_data().get("ground", false)):
		return false
	var blade: Array = seq_blade_world()
	var tip: Vector2 = blade[1]
	return tip.y >= ground_y + depth_y - 3.5


func seq_ground_point() -> Vector2:
	var blade: Array = seq_blade_world()
	var tip: Vector2 = blade[1]
	return Vector2(tip.x, tip.y)


## 命中检测：沿本帧护手→刀尖的有效刃线逐点采样，与目标身体区域相交。
## 接触点必须是真实刃线接触，不能到了参考 tick 就强制伤害，也不能拿目标中心替代。
func _seq_hit(start: float, end: float) -> void:
	var hb: Dictionary = move_data.get("hitbox", {})
	if hb.is_empty():
		return
	# 上一 tick 的刃线 + 本 tick 的刃线：快速挥砍让刀刃在 tick 之间扫过目标也要算接触。
	# phase_t 用真实值而非夹到窗口末尾，这样停在末帧时停在真实的接触姿势上。
	var blade: Array = seq_blade_world()
	var guard: Vector2 = blade[0]
	var tip: Vector2 = blade[1]
	var swept_start := maxf(start, phase_t - 1.0)
	var swept: Array = seq_blade_world(swept_start)
	for monster in monsters.duplicate():
		if not is_instance_valid(monster) or monster.dead:
			continue
		if absf(depth_y - monster.depth_y) > float(hb.get("lane", cfg.get("lane_hit_tolerance", 24))):
			continue
		if not _within_reach(monster, hb):
			continue
		var key := "seq:%d" % monster.get_instance_id()
		if hit_targets.has(key):
			continue
		var contact := _blade_contact(swept[0], swept[1], guard, tip, monster, float(hb.get("lane", 24)) * 0.75)
		if contact == Vector2.INF:
			continue
		var payload := move_data.duplicate(true)
		payload["move_id"] = move_name
		payload["job"] = job
		payload["airborne"] = false
		payload["seq6"] = true
		payload["fx_kind"] = _seq_fx_kind()
		payload["contact_point"] = contact
		payload["material"] = "metal"
		if monster.take_hit(payload, facing):
			hit_targets[key] = true
			hit_emitted = true
			# 停帧只登记一次：动作时钟与两层刀光共享它，特效走独立时钟
			last_hitstop = int(move_data.get("hitstop", 0))
			report_contact(contact, move_name, phase_t, 0, monster)
			# 受击特效挂在真实接触点上，light 与 matter 分开按各自混合模式入层
			if is_instance_valid(seq_fx):
				seq_fx.call("spawn_hit", contact, str(payload.get("fx_kind", "light")))
			# 停帧第一帧的现场：动作时钟、actor 贴图与刀身采样线必须是同一 tick
			seq_hitstop.emit(phase_t, _seq_frame_at(phase_t), tip, contact, last_hitstop)
			landed_hit.emit(monster, float(move_data.get("damage", 0)))


## 刃线采样与目标可见身体轮廓的首个交点；返回 Vector2.INF 表示未接触。
## 接触点是真实刃线落在身体上的位置，所以火花出现在实际受击处，而不是被挪到胸口。
## 判定用「真实刃线 × 目标可见身体」；宽高全部取自 move_data 的 hitbox，不复制某一种怪的 ROI。
func _blade_contact(from_guard: Vector2, from_tip: Vector2, guard: Vector2, tip: Vector2, monster: Node, tolerance: float) -> Vector2:
	# 沿刃线密集取样：浅曲刀刃扫过身体侧面的有效区间可能只有几个像素宽。
	var samples := 48
	var box: Rect2 = monster.hurtbox()
	var window := box.grow(tolerance)
	var union := window.merge(monster.call("body_box"))
	var best := Vector2.INF
	var best_distance := INF
	for index in samples + 1:
		var k := float(index) / samples
		for candidate in [from_guard.lerp(from_tip, k), guard.lerp(tip, k)]:
			if _point_hits(window, box, monster, candidate):
				return candidate
			# 记住整段刃线上最接近判定区的一点：身体轮廓与 hurtbox 都不覆盖时用它做接触点
			var distance := _rect_distance(union, candidate)
			if distance < best_distance:
				best_distance = distance
				best = candidate
	if best != Vector2.INF and best_distance <= maxf(3.0, tolerance * 0.5):
		return best
	# 完全擦肩而过：接受 hurtbox 上最近的刃线点，避免整刀判成空挥
	if box.intersects(Rect2(guard, tip - guard).abs()):
		return best
	return Vector2.INF


## 点是否落在目标的可见身体或收纳 hurtbox 内
func _point_hits(window: Rect2, box: Rect2, monster: Node, point: Vector2) -> bool:
	if box.has_point(point):
		return true
	if not window.has_point(point):
		return false
	return bool(monster.call("body_contains", point))


func _rect_distance(box: Rect2, point: Vector2) -> float:
	var dx := maxf(maxf(box.position.x - point.x, point.x - box.end.x), 0.0)
	var dy := maxf(maxf(box.position.y - point.y, point.y - box.end.y), 0.0)
	return Vector2(dx, dy).length()

## 配置范围决定“够不够得着”，刃线轮廓决定“有没有真的碰到”。
## V6 的可见刃线比收纳 hurtbox 的窄矩形更靠前，所以横向范围按实际触及区域放宽；
## 只保留挥击方向那一侧，匕首朝后的余势不会打到身后的敌人。
func _within_reach(monster: Node, hb: Dictionary) -> bool:
	var reach := float(hb.get("x", 110)) * 1.55
	var height := float(hb.get("h", 190))
	var near := global_position.x - height * 0.14
	var far := global_position.x + reach
	if facing < 0:
		near = global_position.x - reach
		far = global_position.x + height * 0.14
	var box := Rect2(Vector2(near, global_position.y + depth_y - height), Vector2(far - near, height))
	return box.intersects(monster.hurtbox())


func _back_dash_offset(clock: float) -> float:
	var progress := clampf(clock / maxf(1.0, float(move_data.get("motion_frames", _move_duration()))), 0.0, 1.0)
	if str(move_data.get("motion_profile", "smoothstep")) == "smoothstep":
		progress = progress * progress * (3.0 - 2.0 * progress)
	return float(move_data.get("move", -120)) * progress

func _can_locomotion_cancel() -> bool:
	if phase != "recovery" or not is_on_floor() or _dir_input() == 0.0:
		return false
	var threshold := float(move_data.get("locomotion_cancel_after", _move_duration()))
	if _is_sprinting():
		threshold = float(move_data.get("run_cancel_after", threshold) if hit_emitted else move_data.get("whiff_run_cancel_after", threshold))
	return phase_t >= threshold

func _finish_move_and_resume(delta: float) -> void:
	_end_frame_move()
	if not _consume_buffer() and is_on_floor():
		# Move on the very same legal recovery frame; don't spend another tick in
		# IDLE and drop the run request captured during the preceding attack.
		_free_state(delta)

func _window_overlaps(begin: float, end: float, start: float, length: float) -> bool:
	return length > 0.0 and end > start and begin < start + length

func _emit_melee(hit: Dictionary, segment: float = 0.0) -> void:
	var hb: Dictionary = hit.get("hitbox", {})
	if hb.is_empty():
		return
	var reach := float(hb.get("x", 110))
	var height := float(hb.get("h", 190))
	var x0 := global_position.x + float(hb.get("offset", 0)) if facing > 0 else global_position.x - reach - float(hb.get("offset", 0))
	var box := Rect2(Vector2(x0, global_position.y + depth_y - height + float(hb.get("offset_y", 0))), Vector2(reach, height))
	if is_instance_valid(weapon_attachment):
		var weapon_region: Rect2 = weapon_attachment.call("attack_region")
		if weapon_region.has_area():
			box = box.merge(weapon_region)
	# Death handlers remove targets from the shared list during this loop.
	for monster in monsters.duplicate():
		if not is_instance_valid(monster) or monster.dead:
			continue
		if absf(depth_y - monster.depth_y) > float(hb.get("lane", cfg.get("lane_hit_tolerance", 24))):
			continue
		var key := "%d:%d" % [int(segment), monster.get_instance_id()]
		if hit_targets.has(key) or not box.intersects(monster.hurtbox()):
			continue
		var payload := hit.duplicate(true)
		payload["move_id"] = move_name
		payload["job"] = job
		payload["airborne"] = state == St.AIR_ATK
		if monster.take_hit(payload, facing):
			hit_targets[key] = true
			hit_emitted = true
			upper_connected = upper_connected or move_name == "upper"
			landed_hit.emit(monster, float(hit.get("damage", 0)))

func _on_landed(impact_speed: float) -> void:
	if state == St.JUMP and impact_speed > float(cfg.get("landing_fx_speed", 140)):
		_landing_visual_left = 8
	air_attack_count = 0
	_jump_cut_pending = false
	_jump_running = false
	_land_squash = clampf(impact_speed / float(cfg.get("landing_squash_speed", 620)), 0.25, 1.0)
	coyote_left = int(cfg.get("coyote_frames", 6))
	if state == St.AIR_ATK:
		_landed_air_attack = true
		_landing_attack_left = int(move_data.get("landing_recovery", 4))
		phase_t = maxf(phase_t, float(move_data.get("windup", 0)) + float(move_data.get("active", 0)))
		phase = "recovery"
		_move_inertia = velocity.x * float(cfg.get("landing_momentum_retention", 0.8))
	landed.emit(impact_speed)
	if fx != null and impact_speed > float(cfg.get("landing_fx_speed", 140)):
		var reference_speed := maxf(1.0, absf(float(GameConfig.moves["jump"].get("vy", -870))))
		fx.locomotion_event(visual_position(), facing, "land", clampf(impact_speed / reference_speed, 0.4, 1.0))

func _clear_move() -> void:
	move_name = ""
	move_data = {}
	phase = ""
	phase_t = 0.0
	total_t = 0
	_move_inertia = 0.0
	_landed_air_attack = false
	_landing_attack_left = 0
	_seq_ground_done = false
	_event_segments.clear()
	_clear_seq_action()

func _end_frame_move() -> void:
	var was_attack := move_name in ["attack1", "attack2", "attack3", "dash_attack"]
	_clear_move()
	state = St.IDLE if is_on_floor() and velocity.y >= 0.0 else St.JUMP
	if was_attack:
		combo_window = int(cfg.get("combo_window", 16))
	else:
		combo = 0

func _skill_air_allowed(action: String) -> bool:
	if job == 0:
		return false
	var idx: int = JOB_KEYS[job].find(action)
	if idx < 0:
		return false
	var skill: Dictionary = GameConfig.skills[JOB_SKILLS[job][idx]]
	return bool(skill.get("air_allowed", false))

func _try_skill() -> bool:
	for action in ["skill_a", "skill_s"]:
		if Input.is_action_just_pressed(action):
			return _try_skill_action(action)
	return false

func _try_skill_action(action: String) -> bool:
	if job == 0:
		return false
	var idx: int = JOB_KEYS[job].find(action)
	if idx < 0:
		return false
	var sid: String = JOB_SKILLS[job][idx]
	var skill: Dictionary = GameConfig.skills[sid]
	if int(cds.get(sid, 0)) > 0:
		_notify("冷却中", Color(0.65, 0.78, 1.0))
		return false
	var cost := float(skill.get("mp", 0))
	if mp < cost:
		_notify("魔力不足", Color(0.65, 0.78, 1.0))
		return false
	mp -= cost
	cds[sid] = int(float(skill.get("cd", 0)) * 60)
	_cast_skill(sid, skill)
	return true

func _cast_skill(sid: String, skill: Dictionary) -> void:
	combo = 0
	combo_window = 0
	if sid == "blood_rage":
		buff_data = skill.duplicate(true)
		buff_t = float(skill.get("buff_time", 8))
		_clear_move()
		state = St.IDLE if is_on_floor() else St.JUMP
		action_started.emit(sid)
		move_name = sid
		_emit_attack_event("windup", -1, skill)
		move_name = ""
		_notify("血怒", Color(1.0, 0.3, 0.25))
		return
	move_name = sid
	move_data = skill
	_start_frame_move()

func _use_potion(action: String) -> bool:
	if potion_cd > 0:
		_notify("药水冷却中", Color(0.65, 0.78, 1.0))
		return false
	if action == "potion_hp":
		if hp >= float(cfg.get("max_hp", 1000)):
			return false
		hp = minf(float(cfg.get("max_hp", 1000)), hp + float(cfg.get("max_hp", 1000)) * float(cfg.get("potion_hp_ratio", 0.3)))
		hp_changed.emit(hp, float(cfg.get("max_hp", 1000)))
		_notify("生命恢复", Color(0.5, 1.0, 0.6))
	else:
		if mp >= float(cfg.get("max_mp", 300)):
			return false
		mp = minf(float(cfg.get("max_mp", 300)), mp + float(cfg.get("max_mp", 300)) * float(cfg.get("potion_mp_ratio", 0.4)))
		_notify("魔力恢复", Color(0.5, 0.8, 1.0))
	potion_cd = int(float(cfg.get("potion_cd", 5)) * 60)
	return true

func _notify(text: String, color: Color) -> void:
	action_feedback.emit(text)
	if fx != null:
		fx.spawn_number(visual_position() + Vector2(0, -190), text, color, 17)

func take_hit(damage: float, from_dir: int = 0, hit: Dictionary = {}) -> bool:
	if dead or invincible > 0 or not control_enabled:
		return false
	var defense := maxf(0.1, float(cfg.get("defense", 1.0)) * float(buff_data.get("defense", 1.0)))
	var amount := damage / defense
	var guarding := state == St.GUARD and (from_dir == 0 or from_dir != facing or not bool(cfg.get("guard_directional", true)))
	var perfect_guard := guarding and _guard_frames <= int(cfg.get("perfect_guard_frames", 3))
	if guarding:
		amount *= float(cfg.get("perfect_guard_damage_scale", 0.05) if perfect_guard else cfg.get("guard_damage_scale", 0.2))
	hp = maxf(0.0, hp - amount)
	hp_changed.emit(hp, float(cfg.get("max_hp", 1000)))
	if fx != null:
		fx.spawn_number(visual_position() + Vector2(0, -170), ("格挡 " if guarding else "") + str(roundi(amount)), Color(1.0, 0.4, 0.3), 18)
		fx.add_shake(2.0 if guarding else 3.0)
		if guarding:
			fx.guard_event(visual_position(), facing, perfect_guard)
			if perfect_guard:
				fx.hitstop(int(cfg.get("perfect_guard_hitstop", 3)))
		else:
			fx.play_sound("hurt")
	if hp <= 0:
		dead = true
		control_enabled = false
		state = St.DOWN
		var direction := from_dir if from_dir != 0 else -facing
		velocity.x = float(direction) * float(cfg.get("death_knockback", 135))
		if is_on_floor():
			velocity.y = 0.0
		input_buffer.clear()
		_clear_move()
		invincible = 0
		coyote_left = 0
		_jump_cut_pending = false
		running = false
		_death_t = 0.0
		if fx != null:
			fx.play_sound("death")
		died.emit()
		_anim_step()
		anim_frame = maxi(0, int(anims.get(anim_name, {}).get("frames", 1)) - 1)
		queue_redraw()
		return true
	if guarding:
		velocity.x = float(from_dir if from_dir != 0 else -facing) * float(cfg.get("guard_pushback", 35))
		if perfect_guard:
			action_feedback.emit("精确格挡")
		return true
	var armored: bool = bool(buff_data.get("super_armor", false)) or (state == St.SKILL and bool(move_data.get("super_armor", false)))
	if armored:
		return true
	invincible = int(cfg.get("hit_invincible", 10)) + 1
	input_buffer.clear()
	combo = 0
	combo_window = 0
	_clear_move()
	coyote_left = 0
	_jump_cut_pending = false
	var direction := from_dir if from_dir != 0 else -facing
	if hit.has("launch"):
		var launch: Dictionary = hit["launch"]
		velocity = Vector2(direction * float(launch.get("vx", 120)), float(launch.get("vy", -520)))
		state = St.AIR
		bounce_used = false
	else:
		velocity.x = direction * float(hit.get("knockback", 160))
		state = St.HIT
		st_hit_left = int(hit.get("hardstun", cfg.get("hit_stun", 14)))
	_anim_step()
	queue_redraw()
	return true

func _tick_dead(delta: float) -> void:
	input_buffer.clear()
	if fx != null and fx.freeze > 0:
		return
	_death_t += delta
	velocity.x = move_toward(velocity.x, 0.0, float(cfg.get("death_brake", 950)) * delta)
	if not is_on_floor():
		velocity.y += float(cfg.get("gravity", 2100)) * delta
	else:
		velocity.y = 0.0
	move_and_slide()
	position.x = clampf(position.x, arena_left, arena_right)
	anim_name = AnimLib.pick(anims, ["down", "hit", "idle"], "idle")
	anim_frame = maxi(0, int(anims.get(anim_name, {}).get("frames", 1)) - 1)
	queue_redraw()

func set_job(value: int) -> void:
	job = clampi(value, 0, 2)

func _pick_anim() -> String:
	if state in FRAME_STATES:
		return AnimLib.pick(anims, [move_name, "attack1", "idle"], "idle")
	if state == St.WALK:
		return AnimLib.pick(anims, ["walk", "run", "idle"], "idle")
	if state == St.RUN:
		return AnimLib.pick(anims, ["run", "walk", "idle"], "idle")
	if state == St.JUMP:
		var jump_phase := "jump_apex" if absf(velocity.y) < 140 else ("jump_rise" if velocity.y < 0 else "jump_fall")
		return AnimLib.pick(anims, [jump_phase, "jump", "idle"], "idle")
	if state == St.IDLE and _landing_visual_left > 0:
		return AnimLib.pick(anims, ["jump_land", "idle"], "idle")
	var names := {St.IDLE: "idle", St.GUARD: "guard", St.HIT: "hit", St.AIR: "air", St.DOWN: "down", St.GETUP: "getup"}
	return AnimLib.pick(anims, [names.get(state, "idle"), "idle"], "idle")

func _anim_step() -> void:
	var wanted := _pick_anim()
	if wanted != anim_name:
		anim_name = wanted
		anim_frame = 0
		anim_tick = 0
		_anim_fraction = 0.0
	if not anims.has(anim_name):
		return
	if state in FRAME_STATES:
		if seq_active():
			# V6：帧序就是相位刻度，不按 durations 二次推进。
			# 1.0x 攻速下逐 tick 与美术预览一致；攻速加成只缩短实际时长，不改帧序。
			anim_frame = AnimLib.frame_at_progress(anims[anim_name], phase_t / maxf(1.0, _move_duration()))
		else:
			anim_frame = AnimLib.frame_for_move(anims[anim_name], phase_t, move_data)
	elif state == St.GETUP:
		anim_frame = AnimLib.frame_at_progress(anims[anim_name], 1.0 - float(st_hit_left) / maxf(1.0, float(cfg.get("getup_time", 12))))
	elif anim_name == "jump_land":
		anim_frame = AnimLib.frame_at_progress(anims[anim_name], 1.0 - float(_landing_visual_left) / 8.0)
	elif anim_name == "jump_rise":
		var launch_speed := absf(float(GameConfig.moves["jump"].get("vy", -870)))
		anim_frame = AnimLib.frame_at_progress(anims[anim_name], 1.0 - absf(velocity.y) / maxf(1, launch_speed))
	elif anim_name == "jump_fall":
		var launch_speed := absf(float(GameConfig.moves["jump"].get("vy", -870)))
		anim_frame = AnimLib.frame_at_progress(anims[anim_name], velocity.y / maxf(1, launch_speed))
	else:
		var speed := 1.0
		if state in [St.WALK, St.RUN]:
			var reference := float(cfg.get("run_speed", 450) if state == St.RUN else cfg.get("walk_speed", 225))
			speed = clampf(absf(velocity.x) / maxf(1.0, reference), float(cfg.get("locomotion_anim_min", 0.55)), float(cfg.get("locomotion_anim_max", 1.4)))
		_anim_fraction += speed
		while _anim_fraction >= 1.0:
			var result: Array = AnimLib.advance(anims[anim_name], anim_frame, anim_tick)
			anim_frame = int(result[0])
			anim_tick = int(result[1])
			_anim_fraction -= 1.0

func _draw() -> void:
	var height := ground_y - position.y
	if height > -10.0 and height < 320.0:
		var width := 80.0 * (1.0 - minf(absf(height), 280.0) / 560.0)
		draw_set_transform(Vector2(0.0, height + depth_y), 0.0, Vector2(1.0, 0.25))
		draw_circle(Vector2.ZERO, width * 0.5, Color(0.0, 0.0, 0.0, 0.4))
	draw_set_transform_matrix(body_transform())
	var clip: Dictionary = anims.get(anim_name, {})
	if clip.is_empty():
		_draw_placeholder()
	elif clip.get("seq6", false):
		_draw_seq_body(clip)
	else:
		var dst := Rect2(-clip["ax"], -clip["ay"], clip["frame_w"], clip["frame_h"])
		draw_texture_rect_region(clip["tex"], dst, AnimLib.src_rect(clip, anim_frame))
	draw_set_transform(Vector2.ZERO)
	if invincible > 0 and state == St.SKILL:
		modulate = Color(1.15, 1.15, 1.22)
	elif invincible > 0 and invincible % 4 < 2:
		modulate = Color(1, 1, 1, 0.72)
	else:
		modulate = Color.WHITE

func _draw_seq_body(clip: Dictionary) -> void:
	# 每个 tick 一张独立 PNG，UV 取样区就是整张图。不能用水平帧条的 src_rect：
	# 那会把单帧贴图当成第 N 格去采样，UV 落在纹理外，角色会整段消失。
	var full := Rect2(Vector2.ZERO, Vector2(float(clip["frame_w"]), float(clip["frame_h"])))
	var tex: Texture2D = clip["seq_textures"][anim_frame]
	# 拔刀一闪：预览在出刀窗口叠一层 13% 亮度的残影，偏移 25 px
	if move_name == "quick_draw" and phase_t >= 16.0 and phase_t < 20.0:
		var ghost := seq_texture_rect(phase_t - 2.0)
		draw_texture_rect_region(tex, Rect2(ghost.position - Vector2(25.0, 0.0), ghost.size), full, Color(1.0, 1.0, 1.0, 0.13))
	draw_texture_rect_region(tex, seq_texture_rect(), full)


func _draw_placeholder() -> void:
	# The body fallback deliberately has no weapon: WeaponRig owns its rendering.
	draw_rect(Rect2(-14, -40, 12, 40), Color(0.24, 0.22, 0.3))
	draw_rect(Rect2(2, -40, 12, 40), Color(0.28, 0.25, 0.34))
	var coat := Color(0.16, 0.17, 0.22)
	if job == 1:
		coat = Color(0.34, 0.13, 0.15)
	elif job == 2:
		coat = Color(0.15, 0.22, 0.34)
	draw_rect(Rect2(-14, -76, 28, 38), coat)
	draw_circle(Vector2(3, -86), 9, Color(0.94, 0.86, 0.8))
	draw_circle(Vector2(3, -89), 5, Color(0.88, 0.9, 0.95))
