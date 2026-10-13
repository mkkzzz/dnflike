class_name Player
extends CharacterBody2D
## 玩家：状态机 + 帧表驱动动作 + 职业技能（数据来自 data/*.json）
##
## 渲染：骨骼动画帧条贴图（game/art/player/*.png + art/anim.json），
## 由 tools/bake_game_assets.py 从 tools/render_preview.py 烘焙 —— 美术只在 Python 那一份。
## 本脚本只按状态取帧、按脚底锚点定位、朝左时水平翻转。

const AnimLib := preload("res://scripts/anim_lib.gd")

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

# 帧条动画（由 art/anim.json 驱动；取不到就退回占位绘制）
var anims: Dictionary = {}
var anim_name := ""
var anim_frame := 0
var anim_tick := 0

func _ready() -> void:
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(28, 64)
	shape.shape = rect
	shape.position = Vector2(0, -32)
	add_child(shape)
	z_index = 1
	anims = AnimLib.load_group("player")
	anim_name = _pick_anim()
	if anims.is_empty():
		push_warning("[ART] 玩家帧条不可用，退回占位绘制（先跑 python tools/bake_game_assets.py）")
	else:
		print("[ART] player anims=%d" % anims.size())

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
	_anim_step()
	queue_redraw()

## 每物理帧推进帧条动画（命中停顿期间 _physics_process 提前返回 → 动画也跟着停）
func _anim_step() -> void:
	var want := _pick_anim()
	if want != anim_name:
		anim_name = want
		anim_frame = 0
		anim_tick = 0
	if not anims.has(anim_name):
		return
	var r: Array = AnimLib.advance(anims[anim_name], anim_frame, anim_tick)
	anim_frame = r[0]
	anim_tick = r[1]

## 状态 → 帧条名。帧表动作（三段普攻 / 上挑 / 后跳 / 职业技能）用 move_name 区分。
func _pick_anim() -> String:
	match state:
		St.IDLE:
			return AnimLib.pick(anims, ["idle"], "idle")
		St.RUN:
			return AnimLib.pick(anims, ["run"], "idle")
		St.JUMP:
			return AnimLib.pick(anims, ["jump"], "idle")
		St.GUARD:
			return AnimLib.pick(anims, ["guard"], "idle")
		St.HIT:
			return AnimLib.pick(anims, ["hit"], "idle")
		St.AIR:
			return AnimLib.pick(anims, ["air"], "idle")
		St.DOWN:
			return AnimLib.pick(anims, ["down"], "idle")
		St.GETUP:
			return AnimLib.pick(anims, ["getup"], "idle")
	if state in [St.ATK, St.UPPER, St.SKILL, St.BACK_DASH]:
		# 专属帧条（attack1/2/3、upper、rage_slash、quick_draw、thrust、back_dash…）优先
		var by_state := "attack1"
		match state:
			St.UPPER:
				by_state = "upper"
			St.SKILL:
				by_state = "attack1"
			St.BACK_DASH:
				by_state = "back_dash"
		return AnimLib.pick(anims, [move_name, by_state, "attack1", "idle"], "idle")
	return AnimLib.pick(anims, ["idle"], "idle")

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
			if fx != null:
				fx.spawn_dust(position, 5)          # 起跳扬尘
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
		if fx != null:
			fx.spawn_dust(position, 6)              # 落地扬尘
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
	_swing_fx()

## 刀光：出招期间每帧喂一次「这一刀的进度」，由 battle_fx 累积成蓝白刀光带；
## 进入收招（recovery）就停手，避免刀光糊在收势上。
func _swing_fx() -> void:
	if fx == null:
		return
	var span := _swing_span()
	if span <= 0.0 or phase_t > span:
		return
	fx.on_swing(position, facing, clampf(phase_t / span, 0.0, 1.0))

## 这一刀的挥砍时长（物理帧）：普攻/上挑 = windup + active，
## 蓄力技（拔刀斩）= charge + active，多段技（怒斩/连突刺）= 最后一段的延迟。
func _swing_span() -> float:
	if move_data.has("charge"):
		return float(move_data.get("charge", 0)) + float(move_data.get("active", 0))
	if move_data.has("hits"):
		var hits: Array = move_data["hits"]
		return float(hits[-1].get("delay", 0)) if not hits.is_empty() else 0.0
	return float(move_data.get("windup", 0)) + float(move_data.get("active", 0))

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
		if fx != null:
			fx.spawn_dust(position, 8)              # 被打落地的扬尘

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
	# 落地阴影：钉在地面线上，随离地高度收缩（对齐 preview 的椭圆投影；
	# preview 世界 640x360 → 实机 1280x720 是 2 倍，所以这里的尺寸也是 preview 值的 2 倍）
	var gy := ground_y - position.y
	if gy > -10.0 and gy < 320.0:
		var sh_w := 80.0 * (1.0 - minf(absf(gy), 280.0) / 560.0)
		draw_set_transform(Vector2(0.0, gy), 0.0, Vector2(1.0, 0.25))
		draw_circle(Vector2.ZERO, sh_w * 0.5, Color(0.0, 0.0, 0.0, 0.45))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# 骨骼动画帧条：position 即脚底，用清单里的锚点反推左上角；朝左时以脚底为轴水平翻转
	var clip: Dictionary = anims.get(anim_name, {})
	if clip.is_empty():
		_draw_placeholder()
	else:
		var dst := Rect2(-clip["ax"], -clip["ay"], clip["frame_w"], clip["frame_h"])
		if facing < 0:
			draw_set_transform(Vector2.ZERO, 0.0, Vector2(-1.0, 1.0))
		draw_texture_rect_region(clip["tex"], dst, AnimLib.src_rect(clip, anim_frame))
		if facing < 0:
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# 无敌闪烁（modulate 对帧条同样生效）
	if invincible > 0 and invincible % 4 < 2:
		modulate = Color(1, 1, 1, 0.45)
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
