class_name Monster
extends CharacterBody2D
## 哥布林：AI（巡逻/追击/攻击）+ 完整受击链（硬直/浮空/弹地/倒地/受身）+ 异常状态

signal died(m: Monster)

enum St { IDLE, PATROL, CHASE, ATTACK, HIT, AIR, DOWN, GETUP }

var cfg: Dictionary = {}
var state: int = St.IDLE
var facing := -1
var hp := 200.0
var st_t := 0
var patrol_dir := -1
var flash := 0
var bounce_used := false
var bleed_dps := 0.0
var bleed_left := 0.0
var bleed_tick := 0.0
var player_ref: Node2D
var fx: BattleFX
var atk_hit_done := false
var dead := false
## 纯视觉景深偏移（伪 3D 远近层次），不参与物理
var depth_y := 0.0
## 地面线（由 main 注入），用于把落地阴影钉在地面上
var ground_y := 0.0

func _ready() -> void:
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(26, 50)
	shape.shape = rect
	shape.position = Vector2(0, -25)
	add_child(shape)
	z_index = 1
	collision_layer = 4
	collision_mask = 1

func setup(data: Dictionary, player: Node2D, battle_fx: BattleFX) -> void:
	cfg = data
	hp = data["hp"]
	player_ref = player
	fx = battle_fx

func _physics_process(_delta: float) -> void:
	if dead:
		return
	if fx != null and fx.freeze > 0:
		return
	if flash > 0:
		flash -= 1
		modulate = Color(3, 3, 3) if flash % 2 == 0 else Color.WHITE
	else:
		modulate = Color.WHITE
	if bleed_left > 0.0:
		bleed_left -= _delta
		bleed_tick -= _delta
		if bleed_tick <= 0.0:
			bleed_tick = 0.5
			hp -= bleed_dps * 0.5
			fx.spawn_number(position + Vector2(0, -90), str(roundi(bleed_dps * 0.5)), Color(0.9, 0.2, 0.15), 14)
			print("[M1] bleed tick dmg=%.0f hp=%.0f" % [bleed_dps * 0.5, hp])
		if bleed_left <= 0.0:
			print("[M1] bleed end")
	match state:
		St.IDLE:
			_idle()
		St.PATROL:
			_patrol()
		St.CHASE:
			_chase()
		St.ATTACK:
			_attack()
		St.HIT:
			_hit_state(_delta)
		St.AIR:
			_air_state(_delta)
		St.DOWN:
			st_t -= 1
			if st_t <= 0:
				_getup()
		St.GETUP:
			st_t -= 1
			if st_t <= 0:
				_set_state(St.IDLE)
	queue_redraw()

func _idle() -> void:
	var d: float = player_ref.position.x - position.x
	facing = 1 if d > 0 else -1
	if absf(d) < cfg["detect_range"]:
		_set_state(St.CHASE)
	elif randf() < 0.01:
		_set_state(St.PATROL)

func _patrol() -> void:
	if not is_on_floor():
		velocity.y += 1500.0 * (1.0 / 60.0)
		move_and_slide()
		return
	velocity.x = patrol_dir * cfg["move_speed"]
	velocity.y = 0
	move_and_slide()
	if is_on_wall():
		patrol_dir = -patrol_dir
		st_t += 1
		if st_t > 90:
			st_t = 0
			_set_state(St.IDLE)

func _chase() -> void:
	var d: float = player_ref.position.x - position.x
	facing = 1 if d > 0 else -1
	if absf(d) > cfg["detect_range"] * 1.6:
		_set_state(St.PATROL)
		patrol_dir = facing
		return
	if absf(d) < cfg["attack_move"]["range"]:
		_set_state(St.ATTACK)
		return
	velocity.x = facing * cfg["chase_speed"]
	velocity.y = 0
	move_and_slide()

func _attack() -> void:
	st_t += 1
	var mv: Dictionary = cfg["attack_move"]
	velocity.x = 0
	move_and_slide()
	var d: float = player_ref.position.x - position.x
	facing = 1 if d > 0 else -1
	if st_t >= mv["windup"] and not atk_hit_done:
		atk_hit_done = true
		if absf(d) < mv["range"] + 20 and absf(player_ref.position.y - position.y) < 80:
			var p := player_ref as Player
			p.take_hit(mv["damage"])
			print("[M1] goblin hit player dmg=%d" % mv["damage"])
	if st_t >= mv["windup"] + mv["active"] + mv["recovery"]:
		atk_hit_done = false
		_set_state(St.CHASE)

func _hit_state(_delta: float) -> void:
	velocity.y += 1500.0 * (1.0 / 60.0)
	move_and_slide()
	st_t -= 1
	if st_t <= 0:
		_set_state(St.CHASE)

func _air_state(_delta: float) -> void:
	velocity.x = move_toward(velocity.x, 0, 200.0 * (1.0 / 60.0))
	velocity.y += 1500.0 * _delta
	var vy_before := velocity.y
	move_and_slide()
	if is_on_floor():
		if not bounce_used and vy_before > 480.0:
			bounce_used = true
			velocity.y = -velocity.y * 0.45
			fx.add_shake(2.0)
			print("[M1] monster bounce")
		else:
			bounce_used = false
			_set_state(St.DOWN)
			st_t = cfg["knockdown_time"]
			print("[M1] monster state: AIR -> DOWN")

func _getup() -> void:
	_set_state(St.GETUP)
	st_t = cfg["getup_time"]
	print("[M1] monster state: DOWN -> GETUP (受身)")

func _set_state(s: int) -> void:
	state = s
	st_t = 0

func take_hit(hit: Dictionary, from_dir: int) -> void:
	if dead:
		return
	hp -= hit.get("damage", 0)
	flash = 2
	fx.hitstop(hit.get("hitstop", 4))
	fx.add_shake(hit.get("shake", 2))
	fx.spawn_number(position + Vector2(0, -100), str(hit.get("damage", 0)), Color(1.0, 0.9, 0.3), 20)
	if hit.has("bleed"):
		bleed_dps = hit["bleed"]["dps"]
		bleed_left = hit["bleed"]["time"]
		bleed_tick = 0.0
		print("[M1] monster bleed start dps=%.0f time=%.1f" % [bleed_dps, bleed_left])
	if hit.has("launch"):
		var l: Dictionary = hit["launch"]
		velocity = Vector2(from_dir * l["vx"], l["vy"])
		_set_state(St.AIR)
		bounce_used = false
		print("[M1] monster state: HIT -> AIR (launch vy=%.0f)" % l["vy"])
	elif state == St.AIR:
		velocity.y = minf(velocity.y, -160.0)
		velocity.x = from_dir * 120.0
		print("[M1] monster juggled in air")
	elif hit.get("knockdown", false):
		velocity = Vector2(from_dir * 240.0, -220.0)
		_set_state(St.AIR)
		bounce_used = false
		print("[M1] monster state: HIT -> AIR (knockdown)")
	else:
		velocity.x = from_dir * hit.get("knockback", 80)
		_set_state(St.HIT)
		st_t = hit.get("hardstun", 12)
		print("[M1] monster state: HIT hardstun=%d" % st_t)
	if hp <= 0:
		_die()

func _die() -> void:
	dead = true
	velocity = Vector2(120.0 * -facing, -420.0)
	print("[M1] goblin died")
	died.emit(self)
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 0.0, 0.8)
	tw.tween_callback(queue_free)

func _draw() -> void:
	# 视觉景深：只偏移绘制，物理仍共用 GROUND_Y 一条地面线
	var base := Vector2(0.0, depth_y)
	draw_set_transform(base, 0.0, Vector2.ONE)
	# 落地阴影：钉在地面线上，随离地高度收缩
	var gy := ground_y - position.y
	if gy > -10.0 and gy < 160.0:
		var sh_w := 40.0 * (1.0 - minf(absf(gy), 140.0) / 280.0)
		draw_set_transform(Vector2(0.0, depth_y + gy), 0.0, Vector2(1.0, 0.22))
		draw_circle(Vector2.ZERO, sh_w * 0.5, Color(0.0, 0.0, 0.0, 0.45))
		draw_set_transform(base, 0.0, Vector2.ONE)
	# 哥布林占位：绿身 + 大耳 + 木棒
	draw_rect(Rect2(-13, -46, 26, 26), Color(0.44, 0.62, 0.27))  # 身
	draw_rect(Rect2(-13, -20, 26, 20), Color(0.36, 0.5, 0.22))  # 腿
	draw_circle(Vector2(0, -58), 12, Color(0.44, 0.62, 0.27))  # 头
	draw_circle(Vector2(-facing * 9, -60), 4, Color(1.0, 0.9, 0.3))  # 眼
	draw_line(Vector2(facing * 8, -50), Vector2(facing * 26, -38), Color(0.55, 0.38, 0.22), 4.0)  # 棒
	# 血条
	draw_rect(Rect2(-16, -76, 32, 4), Color(0.1, 0.1, 0.1))
	draw_rect(Rect2(-16, -76, 32 * clampf(hp / cfg["hp"], 0, 1), 4), Color(0.85, 0.2, 0.2))
