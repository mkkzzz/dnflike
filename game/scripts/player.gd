class_name Player
extends CharacterBody2D
## 玩家：状态机 + 帧表驱动动作 + 职业技能（数据来自 data/*.json）

signal hp_changed(hp: float, max_hp: float)

enum St { IDLE, RUN, JUMP, BACK_DASH, GUARD, ATK, UPPER, SKILL, HIT, AIR, DOWN, GETUP }

var cfg: Dictionary = {}
var fx: BattleFX
var monsters: Array = []
var state := St.IDLE
var facing := 1
var hp := 1000.0
var mp := 300.0
## 地面线（由 main 注入），用于把落地阴影钉在地面上
var ground_y := 0.0

# 移动 / 双击奔跑
var running := false
var last_tap_dir := 0
var last_tap_ms := -999

# 帧表驱动（物理帧）
var move_name := ""
var move_data := {}
var phase := ""        # windup / active / recovery / charge / custom
var phase_t := 0
var total_t := 0
var hit_emitted := false
var skill_hit_idx := 0
var move_scale := 1.0  # 当前动作的帧推进倍率（攻速）

# 连段窗口
var combo := 0
var combo_window := 0

# 职业与技能槽
var job := 0           # 0 基础 / 1 狂战士 / 2 剑魂
const JOB_SKILLS := {
	1: ["blood_rage", "rage_slash"],
	2: ["quick_draw", "thrust"],
}
const JOB_KEYS := {1: ["skill_a", "skill_s"], 2: ["skill_a", "skill_s"]}
var cds := {}

# buff / 无敌帧
var buff_data := {}
var buff_t := 0.0
var invincible := 0

func _ready() -> void:
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(28, 64)
	shape.shape = rect
	shape.position = Vector2(0, -32)
	add_child(shape)
	z_index = 1

func setup(data: Dictionary, battle_fx: BattleFX, monster_list: Array) -> void:
	cfg = data
	fx = battle_fx
	monsters = monster_list
	hp = data["max_hp"]
	mp = data["max_mp"]
	# 玩家只与地面（layer1）碰撞
	collision_layer = 2
	collision_mask = 1

func _physics_process(_delta: float) -> void:
	if fx != null and fx.freeze > 0:
		return
	_update_timers()
	match state:
		St.IDLE, St.RUN:
			_free_state()
		St.JUMP:
			_jump_state()
		St.ATK, St.UPPER, St.SKILL, St.BACK_DASH:
			_tick_frame_move()
		St.GUARD:
			_guard_state()
		St.HIT:
			_hit_state()
		St.AIR:
			_air_state()
	move_and_slide()
	queue_redraw()

func _update_timers() -> void:
	if invincible > 0:
		invincible -= 1
	if buff_t > 0.0:
		buff_t -= 1.0 / 60.0
		if buff_t <= 0.0:
			buff_data = {}
			print("[M1] buff end")
	if combo_window > 0:
		combo_window -= 1
		if combo_window <= 0 and state != St.ATK:
			combo = 0
	for k in cds.keys():
		cds[k] = maxi(0, cds[k] - 1)

func _dir_input() -> float:
	var d := 0.0
	if Input.is_action_pressed("move_left"):
		d -= 1.0
	if Input.is_action_pressed("move_right"):
		d += 1.0
	return d

func _update_double_tap(d: float) -> void:
	if d == 0.0:
		running = false
		return
	var dir := int(signf(d))
	var now := int(Time.get_ticks_msec())
	if Input.is_action_just_pressed("move_left") or Input.is_action_just_pressed("move_right"):
		if last_tap_dir == dir and now - last_tap_ms <= 300:
			running = true
			print("[M1] run start")
		last_tap_dir = dir
		last_tap_ms = now

func _free_state() -> void:
	var d := _dir_input()
	_update_double_tap(d)
	if d != 0.0:
		facing = int(signf(d))
	var spd: float = cfg["run_speed"] if running else cfg["walk_speed"]
	if buff_data.has("move_speed"):
		spd *= buff_data["move_speed"]
	velocity.x = d * spd
	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y += cfg["gravity"] * (1.0 / 60.0)
	state = St.RUN if d != 0.0 else St.IDLE
	if Input.is_action_just_pressed("jump"):
		if Input.is_action_pressed("move_down"):
			_start_move("back_dash")
		else:
			velocity.y = GameConfig.moves["jump"]["vy"]
			state = St.JUMP
			print("[M1] jump")
	elif Input.is_action_just_pressed("attack"):
		_start_attack()
	elif Input.is_action_just_pressed("generic_skill"):
		_start_move("upper")
	elif Input.is_action_just_pressed("guard"):
		state = St.GUARD
		velocity.x = 0
	elif _try_skill():
		pass

func _jump_state() -> void:
	var d := _dir_input()
	velocity.x = d * cfg["walk_speed"]
	velocity.y += cfg["gravity"] * (1.0 / 60.0)
	if is_on_floor():
		velocity.y = 0
		state = St.IDLE
	if Input.is_action_just_pressed("attack") and combo_window > 0:
		_start_attack()

func _start_attack() -> void:
	var idx := combo % 3
	var names := ["attack1", "attack2", "attack3"]
	move_name = names[idx]
	move_data = GameConfig.moves[move_name]
	_start_frame_move()
	combo = idx + 1
	combo_window = 0
	move_scale = _attack_speed()
	print("[M1] attack %d start (combo %d)" % [idx + 1, combo])

func _start_move(m: String) -> void:
	move_name = m
	move_data = GameConfig.moves[m]
	_start_frame_move()

func _start_frame_move() -> void:
	phase = "windup"
	phase_t = 0
	total_t = 0
	hit_emitted = false
	skill_hit_idx = 0
	velocity.x = 0
	match move_name:
		"upper":
			state = St.UPPER
		"back_dash":
			state = St.BACK_DASH
		_:
			if move_data.has("hits") or move_data.has("charge"):
				state = St.SKILL
			else:
				state = St.ATK

func _attack_speed() -> float:
	var s: float = cfg["attack_speed"]
	if buff_data.has("atk_speed"):
		s *= buff_data["atk_speed"]
	return clampf(s, 0.7, 1.6)

func _tick_frame_move() -> void:
	var step := 1.0
	if move_name in ["attack1", "attack2", "attack3"] or move_data.get("attack_speed_scaled", false):
		step = _attack_speed()
	phase_t += step
	total_t += 1
	match move_name:
		"back_dash":
			var t: int = int(phase_t)
			var mv: Dictionary = move_data
			var inv_f: int = mv.get("invincible", 0)
			if t <= inv_f:
				invincible = maxi(invincible, 1)
			if t < inv_f + 8:
				velocity.x = -facing * 420.0
			else:
				velocity.x = 0
			if t >= mv.get("recovery", 18):
				_end_frame_move()
		"quick_draw":
			_tick_quick_draw()
		_:
			_tick_normal_move()
	if state in [St.SKILL, St.ATK, St.UPPER]:
		velocity.y += cfg["gravity"] * (1.0 / 60.0)

func _tick_normal_move() -> void:
	var mv: Dictionary = move_data
	var w: int = mv.get("windup", 0)
	var a: int = mv.get("active", 0)
	var r: int = mv.get("recovery", 0)
	var t: int = int(phase_t)
	if t < w:
		phase = "windup"
		_apply_move_shift(mv, w + a)
	elif t < w + a:
		phase = "active"
		_apply_move_shift(mv, w + a)
		if not hit_emitted:
			hit_emitted = true
			_emit_melee(mv, 0.0)
	elif t < w + a + r:
		phase = "recovery"
		if Input.is_action_just_pressed("attack"):
			_start_attack()
			return
	else:
		_end_frame_move()
	if move_data.has("hits"):
		_tick_multi_hits(t)

func _tick_multi_hits(t: int) -> void:
	var hits: Array = move_data.get("hits", [])
	if skill_hit_idx < hits.size():
		var h: Dictionary = hits[skill_hit_idx]
		if t >= int(h.get("delay", 0)):
			if h.has("move"):
				velocity.x = facing * float(h["move"]) * 10.0
			_emit_melee(h, 0.0)
			skill_hit_idx += 1

func _tick_quick_draw() -> void:
	var mv: Dictionary = move_data
	var ch: int = mv.get("charge", 18)
	var ac: int = mv.get("active", 6)
	var rc: int = mv.get("recovery", 14)
	var t: int = int(phase_t)
	if t < ch:
		phase = "charge"
		velocity.x = 0
	elif t < ch + ac:
		phase = "active"
		invincible = maxi(invincible, 1)
		if not hit_emitted:
			hit_emitted = true
			_emit_melee(mv, 0.0)
	elif t < ch + ac + rc:
		phase = "recovery"
	else:
		_end_frame_move()

func _apply_move_shift(mv: Dictionary, spread: int) -> void:
	if mv.has("move") and spread > 0:
		velocity.x = facing * mv["move"] / float(spread) * 60.0

func _emit_melee(hit: Dictionary, _off: float) -> void:
	var hb: Dictionary = hit.get("hitbox", {})
	var x0: float = position.x if facing > 0 else position.x - hb["x"]
	var box := Rect2(x0, position.y - hb["h"], hb["x"], hb["h"])
	if hit.get("_debug", false):
		var dbg := "monsters=%d" % monsters.size()
		for m in monsters:
			if is_instance_valid(m):
				dbg += " [x=%.0f dead=%s]" % [m.position.x, m.dead]
		print("[M1] melee move=%s box=(%.0f..%.0f) %s" % [move_name, box.position.x, box.end.x, dbg])
	var upper_hit := false
	for m in monsters:
		if m == null or not is_instance_valid(m) or m.dead:
			continue
		var mbox := Rect2(m.position.x - 14, m.position.y - 60, 28, 60)
		if box.intersects(mbox):
			m.take_hit(hit.duplicate(), facing)
			print("[M1] player hit monster move=%s dmg=%d" % [move_name, hit.get("damage", 0)])
			if move_name == "upper":
				upper_hit = true
	if upper_hit:
		velocity.y = -420.0
		state = St.JUMP
		print("[M1] upper hit, player rises for air chase")

func _end_frame_move() -> void:
	var was_attack := move_name in ["attack1", "attack2", "attack3"]
	move_name = ""
	move_data = {}
	state = St.IDLE
	velocity.x = 0
	if was_attack:
		combo_window = 12

func _guard_state() -> void:
	velocity.x = 0
	if not is_on_floor():
		velocity.y += cfg["gravity"] * (1.0 / 60.0)
	else:
		velocity.y = 0
	if not Input.is_action_pressed("guard"):
		state = St.IDLE

func _hit_state() -> void:
	velocity.x = move_toward(velocity.x, 0, 300.0 * (1.0 / 60.0))
	if not is_on_floor():
		velocity.y += cfg["gravity"] * (1.0 / 60.0)
		if is_on_floor():
			state = St.IDLE
	else:
		velocity.y = 0
	st_hit_left -= 1
	if st_hit_left <= 0 and is_on_floor():
		state = St.IDLE

var st_hit_left := 0

func _air_state() -> void:
	velocity.y += cfg["gravity"] * (1.0 / 60.0)
	if is_on_floor():
		state = St.DOWN
		st_hit_left = 24

func _try_skill() -> bool:
	if job == 0:
		return false
	var ids: Array = JOB_SKILLS[job]
	var keys: Array = JOB_KEYS[job]
	for i in ids.size():
		var k: String = keys[i]
		if Input.is_action_just_pressed(k):
			var sid: String = ids[i]
			var sk: Dictionary = GameConfig.skills[sid]
			if cds.get(sid, 0) > 0:
				print("[M1] skill %s on cooldown" % sid)
				return true
			cds[sid] = int(sk["cd"] * 60)
			_cast_skill(sid, sk)
			return true
	return false

func _cast_skill(sid: String, sk: Dictionary) -> void:
	print("[M1] skill cast: %s" % sid)
	if sid == "blood_rage":
		buff_data = sk.duplicate()
		buff_t = sk["buff_time"]
		move_name = ""
		state = St.IDLE
		fx.spawn_number(position + Vector2(0, -110), "血怒", Color(1.0, 0.3, 0.25), 22)
		return
	move_name = sid
	move_data = sk
	_start_frame_move()

func take_hit(dmg: float) -> void:
	if invincible > 0:
		print("[M1] player hit ignored (invincible)")
		return
	if state == St.GUARD:
		var dmg_taken := dmg * 0.2
		hp -= dmg_taken
		hp_changed.emit(hp, cfg["max_hp"])
		fx.spawn_number(position + Vector2(0, -100), "格挡 %.0f" % dmg_taken, Color(0.6, 0.7, 1.0), 14)
		print("[M1] guard absorb dmg=%.0f" % dmg_taken)
		return
	if state == St.SKILL and move_data.get("super_armor", false):
		print("[M1] super armor absorbed hit")
		return
	hp -= dmg
	hp_changed.emit(hp, cfg["max_hp"])
	fx.spawn_number(position + Vector2(0, -100), str(roundi(dmg)), Color(1.0, 0.4, 0.3), 18)
	invincible = 10
	state = St.HIT
	st_hit_left = 14
	velocity.x = -facing * 160.0
	fx.add_shake(3.0)
	print("[M1] player hit dmg=%.0f hp=%.0f" % [dmg, hp])
	if hp <= 0:
		hp = cfg["max_hp"]
		position.x = 400
		print("[M1] player down, respawn (debug)")

func set_job(j: int) -> void:
	job = j
	print("[M1] job switch: %d" % job)

func _draw() -> void:
	# 落地阴影：钉在地面线上，随离地高度收缩（对齐 preview 的椭圆投影）
	var gy := ground_y - position.y
	if gy > -10.0 and gy < 160.0:
		var sh_w := 40.0 * (1.0 - minf(absf(gy), 140.0) / 280.0)
		draw_set_transform(Vector2(0.0, gy), 0.0, Vector2(1.0, 0.22))
		draw_circle(Vector2.ZERO, sh_w * 0.5, Color(0.0, 0.0, 0.0, 0.45))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
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
	# 无敌闪烁
	if invincible > 0 and invincible % 4 < 2:
		modulate = Color(1, 1, 1, 0.45)
	else:
		modulate = Color.WHITE
	# 血条
	draw_rect(Rect2(-18, -104, 36, 5), Color(0.1, 0.1, 0.1))
	draw_rect(Rect2(-18, -104, 36 * clampf(hp / cfg["max_hp"], 0, 1), 5), Color(0.85, 0.2, 0.2))
