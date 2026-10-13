class_name Player
extends CharacterBody2D
## 配置帧表、停帧输入缓冲、三段连击与景深战斗。
const AnimLib := preload("res://scripts/anim_lib.gd")
signal hp_changed(hp: float, max_hp: float)
signal died
signal landed_hit(monster: Node, damage: float)
signal action_feedback(message: String)
enum St { IDLE, RUN, JUMP, BACK_DASH, GUARD, ATK, UPPER, SKILL, HIT, AIR, DOWN, GETUP }
const JOB_SKILLS := {1: ["blood_rage", "rage_slash"], 2: ["quick_draw", "thrust"]}
const JOB_KEYS := {1: ["skill_a", "skill_s"], 2: ["skill_a", "skill_s"]}
const BUFFER_ACTIONS := ["attack", "generic_skill", "jump", "back_dash", "skill_a", "skill_s", "potion_hp", "potion_mp"]
var cfg: Dictionary = {}
var fx: BattleFX
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
	anim_name = _pick_anim()

func setup(data: Dictionary, battle_fx: BattleFX, monster_list: Array) -> void:
	cfg = data.duplicate(true)
	fx = battle_fx
	monsters = monster_list
	reset_combat(position)

func reset_combat(origin: Vector2) -> void:
	position = origin
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
	anim_name = ""
	anim_frame = 0
	anim_tick = 0
	modulate = Color.WHITE
	_anim_step()
	hp_changed.emit(hp, float(cfg.get("max_hp", 1000)))
	queue_redraw()

func visual_position() -> Vector2:
	return position + Vector2(0, depth_y)

func hurtbox() -> Rect2:
	var height := float(cfg.get("hurtbox_height", 190))
	return Rect2(position + Vector2(-22, depth_y - height), Vector2(44, height))

func _physics_process(delta: float) -> void:
	if not control_enabled or dead:
		input_buffer.clear()
		return
	_sample_input()
	if fx != null and fx.freeze > 0:
		return
	_update_timers(delta)
	match state:
		St.IDLE, St.RUN:
			_free_state(delta)
		St.JUMP:
			_jump_state(delta)
		St.ATK, St.UPPER, St.SKILL, St.BACK_DASH:
			_tick_frame_move()
		St.GUARD:
			velocity.x = 0
			if not Input.is_action_pressed("guard"):
				state = St.IDLE
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
			velocity.x = 0
			st_hit_left -= 1
			if st_hit_left <= 0:
				state = St.IDLE
	if not is_on_floor() or velocity.y < 0.0:
		velocity.y += float(cfg.get("gravity", 2600)) * delta
	else:
		velocity.y = 0.0
	var falling_speed := velocity.y
	move_and_slide()
	position.x = clampf(position.x, arena_left, arena_right)
	if is_on_floor() and falling_speed >= 0.0:
		if state == St.JUMP:
			state = St.IDLE
			if fx != null:
				fx.spawn_dust(visual_position(), 6)
		elif state == St.AIR:
			if not bounce_used and falling_speed > 480.0:
				bounce_used = true
				velocity.y = -falling_speed * 0.45
			else:
				state = St.DOWN
				st_hit_left = int(cfg.get("down_time", 36))
	z_index = 100 + int(round(depth_y))
	_anim_step()
	queue_redraw()

func _sample_input() -> void:
	for action in BUFFER_ACTIONS:
		if InputMap.has_action(action) and Input.is_action_just_pressed(action):
			buffer_action(action)

func buffer_action(action: String) -> void:
	for entry in input_buffer:
		if entry["action"] == action:
			entry["ttl"] = int(cfg.get("input_buffer_frames", 12))
			return
	input_buffer.append({"action": action, "ttl": int(cfg.get("input_buffer_frames", 12))})

func _has_buffer(action: String) -> bool:
	for entry in input_buffer:
		if entry["action"] == action:
			return true
	return false

func _update_timers(delta: float) -> void:
	invincible = maxi(0, invincible - 1)
	potion_cd = maxi(0, potion_cd - 1)
	if buff_t > 0.0:
		buff_t = maxf(0.0, buff_t - delta)
		if buff_t == 0.0:
			buff_data.clear()
	if combo_window > 0:
		combo_window -= 1
	elif state != St.ATK:
		combo = 0
	for key in cds:
		cds[key] = maxi(0, int(cds[key]) - 1)
	for idx in range(input_buffer.size() - 1, -1, -1):
		input_buffer[idx]["ttl"] -= 1
		if input_buffer[idx]["ttl"] < 0:
			input_buffer.remove_at(idx)

func _dir_input() -> float:
	return Input.get_axis("move_left", "move_right")

func _update_double_tap(d: float) -> void:
	if d == 0.0:
		running = false
		return
	var direction := int(signf(d))
	if Input.is_action_just_pressed("move_left") or Input.is_action_just_pressed("move_right"):
		var now := Time.get_ticks_msec()
		if last_tap_dir == direction and now - last_tap_ms <= int(cfg.get("double_tap_ms", 280)):
			running = true
		last_tap_dir = direction
		last_tap_ms = now

func _move_lane(delta: float) -> void:
	var lane := Input.get_axis("move_up", "move_down") if InputMap.has_action("move_up") else 0.0
	depth_y = clampf(depth_y + lane * float(cfg.get("lane_speed", 90)) * delta, float(cfg.get("lane_min", -40)), float(cfg.get("lane_max", 24)))

func _free_state(delta: float) -> void:
	var d := _dir_input()
	_update_double_tap(d)
	_move_lane(delta)
	if d != 0.0:
		facing = int(signf(d))
	var sprinting := running or (InputMap.has_action("dash") and Input.is_action_pressed("dash"))
	var spd := float(cfg.get("run_speed", 420) if sprinting else cfg.get("walk_speed", 200))
	velocity.x = d * spd * float(buff_data.get("move_speed", 1.0))
	state = St.RUN if d != 0.0 else St.IDLE
	if not _consume_buffer() and Input.is_action_pressed("guard"):
		state = St.GUARD
		velocity.x = 0.0

func _jump_state(delta: float) -> void:
	_move_lane(delta)
	velocity.x = _dir_input() * float(cfg.get("walk_speed", 200))
	_consume_buffer()

func _consume_buffer(cancel_only := false) -> bool:
	for idx in range(input_buffer.size()):
		var action: String = input_buffer[idx]["action"]
		if action in ["potion_hp", "potion_mp"]:
			input_buffer.remove_at(idx)
			_use_potion(action)
			return true
		if cancel_only:
			var cancel_at := float(move_data.get("cancel_after", _move_duration()))
			var jump_cancel := state == St.UPPER and upper_connected and action == "jump" and phase_t >= float(move_data.get("windup", 5)) + float(move_data.get("active", 3))
			if phase_t < cancel_at and not jump_cancel:
				continue
			if action == "attack" and (state != St.ATK or combo >= 3):
				continue
			if state == St.BACK_DASH:
				continue
		if action == "jump" and (not is_on_floor() or velocity.y < 0):
			continue
		if action == "back_dash" and not is_on_floor():
			continue
		input_buffer.remove_at(idx)
		match action:
			"attack": _start_attack()
			"generic_skill": _start_move("upper")
			"jump":
				if Input.is_action_pressed("move_down"):
					_start_move("back_dash")
				else:
					_start_jump()
			"back_dash": _start_move("back_dash")
			"skill_a", "skill_s": _try_skill_action(action)
			_: continue
		return true
	return false

func _start_jump() -> void:
	move_name = ""
	move_data = {}
	velocity.y = float(GameConfig.moves["jump"].get("vy", -840))
	state = St.JUMP
	if fx != null:
		fx.spawn_dust(visual_position(), 5)

func _start_attack() -> void:
	var idx := combo % 3
	move_name = ["attack1", "attack2", "attack3"][idx]
	move_data = GameConfig.moves[move_name]
	_start_frame_move()
	combo = idx + 1
	combo_window = 0
	print("[M1] attack %d start" % (idx + 1))

func _start_move(action: String) -> void:
	move_name = action
	move_data = GameConfig.moves[action]
	if action != "upper":
		combo = 0
		combo_window = 0
	_start_frame_move()

func _start_frame_move() -> void:
	var direction := _dir_input()
	if direction != 0.0:
		facing = int(signf(direction))
	phase = "windup"
	phase_t = 0.0
	total_t = 0
	hit_emitted = false
	skill_hit_idx = 0
	hit_targets.clear()
	upper_connected = false
	velocity.x = 0.0
	move_scale = _attack_speed() if move_name in ["attack1", "attack2", "attack3"] or move_data.get("attack_speed_scaled", false) else 1.0
	match move_name:
		"upper": state = St.UPPER
		"back_dash":
			state = St.BACK_DASH
			invincible = maxi(invincible, int(move_data.get("invincible", 6)))
			velocity.y = float(move_data.get("vy", -260))
		"attack1", "attack2", "attack3": state = St.ATK
		_: state = St.SKILL
	anim_name = _pick_anim()
	anim_frame = 0
	anim_tick = 0
	if fx != null:
		fx.start_swing()
	if fx != null and state != St.BACK_DASH:
		fx.play_sound("swing")

func _attack_speed() -> float:
	return clampf(float(cfg.get("attack_speed", 1.0)) * float(buff_data.get("atk_speed", 1.0)), 0.7, 1.6)

func _move_duration() -> float:
	if move_data.has("hits"):
		var last: Dictionary = move_data["hits"][-1]
		return float(last.get("delay", 0)) + float(last.get("active", 3)) + float(move_data.get("recovery", 0))
	return float(move_data.get("charge", move_data.get("windup", 0))) + float(move_data.get("active", 0)) + float(move_data.get("recovery", 0))

func _tick_frame_move() -> void:
	var previous := phase_t
	phase_t += move_scale
	total_t += 1
	velocity.x = 0.0
	if state == St.BACK_DASH:
		phase = "recovery"
		velocity.x = facing * float(move_data.get("move", -120)) * 60.0 / maxf(_move_duration(), 1.0)
	elif move_data.has("hits"):
		phase = "windup"
		var hits: Array = move_data["hits"]
		for idx in hits.size():
			var hit: Dictionary = hits[idx]
			var start := float(hit.get("delay", 0))
			var span := float(hit.get("active", 3))
			if _window_overlaps(previous, phase_t, start, span):
				phase = "active"
				if previous <= start and fx != null:
					fx.start_swing()
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
		if previous < windup + active and move_data.has("move"):
			var covered := minf(phase_t, windup + active) - previous
			velocity.x = facing * float(move_data["move"]) * covered / maxf(1.0, windup + active) * 60.0
		if _window_overlaps(previous, phase_t, windup, active):
			if move_data.get("invincible_active", 0) > 0:
				invincible = maxi(invincible, 1)
			_emit_melee(move_data, 0.0)
	if phase == "active" and fx != null:
		fx.on_swing(visual_position(), facing, clampf(phase_t / maxf(1.0, _move_duration() - float(move_data.get("recovery", 0))), 0.0, 1.0), float(move_data.get("hitbox", {}).get("x", 120)))
	if phase_t >= _move_duration():
		_end_frame_move()
		_consume_buffer()
	else:
		_consume_buffer(true)

func _window_overlaps(begin: float, end: float, start: float, length: float) -> bool:
	return length > 0.0 and end > start and begin < start + length

func _emit_melee(hit: Dictionary, segment: float = 0.0) -> void:
	var hb: Dictionary = hit.get("hitbox", {})
	if hb.is_empty():
		return
	var reach := float(hb.get("x", 110))
	var height := float(hb.get("h", 190))
	var x0 := position.x + float(hb.get("offset", 0)) if facing > 0 else position.x - reach - float(hb.get("offset", 0))
	var box := Rect2(Vector2(x0, position.y + depth_y - height), Vector2(reach, height))
	# 死亡信号会从主场景阵列移除目标，因此使用快照避免范围攻击漏掉下一个目标。
	for monster in monsters.duplicate():
		if not is_instance_valid(monster) or monster.dead:
			continue
		if absf(depth_y - monster.depth_y) > float(hb.get("lane", cfg.get("lane_hit_tolerance", 24))):
			continue
		var key := "%d:%d" % [int(segment), monster.get_instance_id()]
		if hit_targets.has(key) or not box.intersects(monster.hurtbox()):
			continue
		if monster.take_hit(hit.duplicate(true), facing):
			hit_targets[key] = true
			hit_emitted = true
			upper_connected = upper_connected or move_name == "upper"
			landed_hit.emit(monster, float(hit.get("damage", 0)))
			print("[M1] player hit monster move=%s dmg=%d" % [move_name, hit.get("damage", 0)])

func _end_frame_move() -> void:
	var was_attack := move_name in ["attack1", "attack2", "attack3"]
	move_name = ""
	move_data = {}
	phase = ""
	state = St.IDLE if is_on_floor() else St.JUMP
	if was_attack:
		combo_window = int(cfg.get("combo_window", 12))
	else:
		combo = 0

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
	print("[M1] skill cast: %s" % sid)
	combo = 0
	combo_window = 0
	if fx != null:
		fx.play_sound("skill")
	if sid == "blood_rage":
		buff_data = skill.duplicate(true)
		buff_t = float(skill.get("buff_time", 8))
		move_name = ""
		move_data = {}
		state = St.IDLE if is_on_floor() else St.JUMP
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
	if state == St.GUARD:
		amount *= float(cfg.get("guard_damage_scale", 0.2))
	hp = maxf(0.0, hp - amount)
	hp_changed.emit(hp, float(cfg.get("max_hp", 1000)))
	if fx != null:
		fx.spawn_number(visual_position() + Vector2(0, -170), ("格挡 " if state == St.GUARD else "") + str(roundi(amount)), Color(1.0, 0.4, 0.3), 18)
		fx.add_shake(2.0 if state == St.GUARD else 3.0)
		fx.play_sound("guard" if state == St.GUARD else "hurt")
	if hp <= 0:
		dead = true
		control_enabled = false
		state = St.DOWN
		velocity = Vector2.ZERO
		input_buffer.clear()
		move_name = ""
		move_data = {}
		if fx != null:
			fx.play_sound("death")
		died.emit()
		_anim_step()
		anim_frame = maxi(0, int(anims.get(anim_name, {}).get("frames", 1)) - 1)
		queue_redraw()
		return true
	if state == St.GUARD:
		return true
	var armored: bool = bool(buff_data.get("super_armor", false)) or (state == St.SKILL and bool(move_data.get("super_armor", false)))
	if armored:
		return true
	invincible = int(cfg.get("hit_invincible", 10)) + 1
	input_buffer.clear()
	combo = 0
	combo_window = 0
	move_name = ""
	move_data = {}
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

func set_job(value: int) -> void:
	job = clampi(value, 0, 2)
	print("[M1] job switch: %d" % job)

func _pick_anim() -> String:
	if state in [St.ATK, St.UPPER, St.SKILL, St.BACK_DASH]:
		return AnimLib.pick(anims, [move_name, "attack1", "idle"], "idle")
	if state == St.RUN:
		var sprinting := running or (InputMap.has_action("dash") and Input.is_action_pressed("dash"))
		return AnimLib.pick(anims, ["run" if sprinting else "walk", "run", "idle"], "idle")
	var names := {St.IDLE: "idle", St.RUN: "run", St.JUMP: "jump", St.GUARD: "guard", St.HIT: "hit", St.AIR: "air", St.DOWN: "down", St.GETUP: "getup"}
	return AnimLib.pick(anims, [names.get(state, "idle"), "idle"], "idle")

func _anim_step() -> void:
	var wanted := _pick_anim()
	if wanted != anim_name:
		anim_name = wanted
		anim_frame = 0
		anim_tick = 0
	if not anims.has(anim_name):
		return
	if state in [St.ATK, St.UPPER, St.SKILL, St.BACK_DASH]:
		anim_frame = AnimLib.frame_for_move(anims[anim_name], phase_t, move_data)
	elif state == St.GETUP:
		anim_frame = AnimLib.frame_at_progress(anims[anim_name], 1.0 - float(st_hit_left) / maxf(1.0, float(cfg.get("getup_time", 12))))
	else:
		var result: Array = AnimLib.advance(anims[anim_name], anim_frame, anim_tick)
		anim_frame = int(result[0])
		anim_tick = int(result[1])

func _draw() -> void:
	# 落地阴影：钉在地面线上，随离地高度收缩（对齐 preview 的椭圆投影；
	# preview 世界 640x360 → 实机 1280x720 是 2 倍，所以这里的尺寸也是 preview 值的 2 倍）
	var gy := ground_y - position.y
	if gy > -10.0 and gy < 320.0:
		var sh_w := 80.0 * (1.0 - minf(absf(gy), 280.0) / 560.0)
		draw_set_transform(Vector2(0.0, gy + depth_y), 0.0, Vector2(1.0, 0.25))
		draw_circle(Vector2.ZERO, sh_w * 0.5, Color(0.0, 0.0, 0.0, 0.45))
		draw_set_transform(Vector2(0, depth_y), 0.0, Vector2.ONE)
	# 骨骼动画帧条：position 即脚底，用清单里的锚点反推左上角；朝左时以脚底为轴水平翻转
	draw_set_transform(Vector2(0, depth_y), 0.0, Vector2.ONE)
	var clip: Dictionary = anims.get(anim_name, {})
	if clip.is_empty():
		_draw_placeholder()
	else:
		var dst := Rect2(-clip["ax"], -clip["ay"], clip["frame_w"], clip["frame_h"])
		if facing < 0:
			draw_set_transform(Vector2(0, depth_y), 0.0, Vector2(-1.0, 1.0))
		draw_texture_rect_region(clip["tex"], dst, AnimLib.src_rect(clip, anim_frame))
		if facing < 0:
			draw_set_transform(Vector2(0, depth_y), 0.0, Vector2.ONE)
	# 无敌闪烁（modulate 对帧条同样生效）
	if invincible > 0 and state == St.SKILL:
		modulate = Color(1.15, 1.15, 1.22)
	elif invincible > 0 and invincible % 4 < 2:
		modulate = Color(1, 1, 1, 0.72)
	else:
		modulate = Color.WHITE
	# 头顶血条已移除：preview 里玩家血量在下角球体（HUD 负责），世界空间不画血条

## 帧条缺失时的兜底：沿用 M1 的 draw_rect 占位小人（保证任何情况下都有东西可看）
func _draw_placeholder() -> void:
	# 腿
	draw_rect(Rect2(-14, -40, 12, 40), Color(0.24, 0.22, 0.3))
	draw_rect(Rect2(2, -40, 12, 40), Color(0.28, 0.25, 0.34))
	# 躯干（转职配色）
	var coat := Color(0.16, 0.17, 0.22)
	if job == 1:
		coat = Color(0.34, 0.13, 0.15)
	elif job == 2:
		coat = Color(0.15, 0.22, 0.34)
	draw_rect(Rect2(-14, -76, 28, 38), coat)
	# 头 + 发
	draw_circle(Vector2(facing * 3, -86), 9, Color(0.94, 0.86, 0.8))
	draw_circle(Vector2(facing * 3, -89), 5, Color(0.88, 0.9, 0.95))
	# 剑：待机斜垂，攻击时从后上方挥到前下方
	var sword_a := -1.5
	if state in [St.ATK, St.UPPER, St.SKILL]:
		var prog := clampf(float(total_t) / 12.0, 0.0, 1.0)
		sword_a = lerpf(-1.9, 1.2, prog)
	var base := Vector2(facing * 12, -70)
	var tip := base + Vector2(cos(sword_a) * facing, sin(sword_a)) * 44.0
	draw_line(base, tip, Color(0.82, 0.9, 0.96), 3.0)
