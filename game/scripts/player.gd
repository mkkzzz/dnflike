class_name Player
extends CharacterBody2D
## 玩家：移动 / 跳跃 / 普攻 的占位实现（M1 手感骨架）

const SPEED := 320.0
const JUMP_VELOCITY := -620.0
const GRAVITY := 1500.0
const ATTACK_DURATION := 0.28

enum State { IDLE, RUN, JUMP, ATTACK }

var state := State.IDLE
var facing := 1
var attack_t := 0.0
var hp := 100.0

func _ready() -> void:
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(28, 64)
	shape.shape = rect
	shape.position = Vector2(0, -32)
	add_child(shape)
	z_index = 1

func _physics_process(delta: float) -> void:
	attack_t = maxf(0.0, attack_t - delta)
	if state == State.ATTACK and attack_t <= 0.0:
		state = State.IDLE

	var dir := 0.0
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
		dir -= 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
		dir += 1.0

	if state != State.ATTACK:
		if dir != 0.0:
			facing = int(sign(dir))
			state = State.RUN if is_on_floor() else State.JUMP
		elif is_on_floor():
			state = State.IDLE
		else:
			state = State.JUMP
		velocity.x = dir * SPEED

	if not is_on_floor():
		velocity.y += GRAVITY * delta

	if state != State.ATTACK and Input.is_physical_key_pressed(KEY_X):
		state = State.ATTACK
		attack_t = ATTACK_DURATION
		velocity.x = 0.0

	if state == State.ATTACK and is_on_floor():
		velocity.x = move_toward(velocity.x, 0.0, 600.0 * delta)

	if Input.is_physical_key_pressed(KEY_C) and is_on_floor() and state != State.ATTACK:
		velocity.y = JUMP_VELOCITY
		state = State.JUMP

	move_and_slide()
	queue_redraw()

func _draw() -> void:
	# 占位小人：深色轮廓 + 蓝衣 + 白刃
	var sway := 0.0
	if state == State.RUN:
		sway = sin(Time.get_ticks_msec() * 0.02) * 2.0
	draw_rect(Rect2(-14, -64, 28, 44), Color(0.22, 0.26, 0.42))  # 躯干
	draw_rect(Rect2(-14, -20, 28, 20), Color(0.25, 0.23, 0.3))  # 腿
	draw_circle(Vector2(0, -72 + sway * 0.2), 8, Color(0.94, 0.86, 0.8))  # 头
	draw_circle(Vector2(0, -74 + sway * 0.2), 4.5, Color(0.88, 0.9, 0.95))  # 发
	# 剑
	var base := Vector2(facing * 10.0, -50.0)
	var t := 0.0
	var sword_ang := -1.9
	if state == State.ATTACK:
		t = 1.0 - attack_t / ATTACK_DURATION
		sword_ang = lerpf(-1.9, 1.1, t)  # 从身后甩到身前
	var tip := base + Vector2(cos(sword_ang), sin(sword_ang)) * 46.0 * facing
	draw_line(base, tip, Color(0.82, 0.9, 0.96), 3.0)
	draw_line(tip, tip + Vector2(0, 0), Color(1, 1, 1), 1.0)
	if state == State.ATTACK:
		var k := sin(t * PI)
		draw_arc(base, 44.0, -2.0, 1.2, 16, Color(0.5, 0.8, 1.0, 0.55 * k), 6.0 * k)
	# 血量条
	draw_rect(Rect2(-16, -84, 32, 5), Color(0.12, 0.1, 0.1))
	draw_rect(Rect2(-16, -84, 32 * hp / 100.0, 5), Color(0.85, 0.2, 0.2))
