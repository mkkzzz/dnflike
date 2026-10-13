class_name Monster
extends CharacterBody2D
## 哥布林：AI（巡逻/追击/攻击）+ 完整受击链（硬直/浮空/弹地/倒地/受身）+ 异常状态
##
## 渲染：骨骼动画帧条贴图（game/art/monster/*.png + art/anim.json），
## 由 tools/bake_game_assets.py 从 tools/render_preview.py 烘焙 —— 美术只在 Python 那一份。
## 本脚本只按状态取帧、按脚底锚点 + depth_y 定位、朝左时水平翻转。

const AnimLib := preload("res://scripts/anim_lib.gd")

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

# 帧条动画（由 art/anim.json 驱动；取不到就退回占位绘制）
var anims: Dictionary = {}
var anim_name := ""
var anim_frame := 0
var anim_tick := 0

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
	anims = AnimLib.load_group("monster")
	anim_name = _pick_anim()
	if anims.is_empty():
		push_warning("[ART] 哥布林帧条不可用，退回占位绘制（先跑 python tools/bake_game_assets.py）")
	else:
		print("[ART] monster anims=%d" % anims.size())

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

## 状态 → 帧条名（与 render_preview.py 里的 MONSTER_STATE_NAMES 一一对应）
func _pick_anim() -> String:
	var want := "idle"
	match state:
		St.IDLE:
			want = "idle"
		St.PATROL:
			want = "patrol"
		St.CHASE:
			want = "chase"
		St.ATTACK:
			want = "attack"
		St.HIT:
			want = "hit"
		St.AIR:
			want = "air"
		St.DOWN:
			want = "down"
		St.GETUP:
			want = "getup"
	return AnimLib.pick(anims, [want, "idle"], "idle")

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
	# 命中表现一站式入口（停帧 + 震屏 + 跳字 + 火花 + 重击刀光），别在这里再各调一遍
	if fx != null:
		fx.on_hit(position, from_dir, float(hit.get("damage", 0)), hit)
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
	# 落地阴影：钉在地面线上，随离地高度收缩（preview 世界 → 实机是 2 倍，尺寸同样 ×2）
	var gy := ground_y - position.y
	if gy > -10.0 and gy < 320.0:
		var sh_w := 80.0 * (1.0 - minf(absf(gy), 280.0) / 560.0)
		draw_set_transform(Vector2(0.0, depth_y + gy), 0.0, Vector2(1.0, 0.25))
		draw_circle(Vector2.ZERO, sh_w * 0.5, Color(0.0, 0.0, 0.0, 0.45))
		draw_set_transform(base, 0.0, Vector2.ONE)
	# 骨骼动画帧条：position 即脚底，锚点反推左上角，depth_y 只影响绘制；朝左时以脚底为轴翻转
	var clip: Dictionary = anims.get(anim_name, {})
	if clip.is_empty():
		_draw_placeholder()
	else:
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		var dst := Rect2(-clip["ax"], -clip["ay"] + depth_y, clip["frame_w"], clip["frame_h"])
		if facing < 0:
			draw_set_transform(Vector2.ZERO, 0.0, Vector2(-1.0, 1.0))
		draw_texture_rect_region(clip["tex"], dst, AnimLib.src_rect(clip, anim_frame))
		draw_set_transform(base, 0.0, Vector2.ONE)
	# 头顶血条已移除：preview 里怪物只有屏幕顶部中央的目标铭牌（HUD 负责），世界空间不画血条

## 帧条缺失时的兜底：沿用 M1 的 draw_rect 占位哥布林
func _draw_placeholder() -> void:
	draw_rect(Rect2(-13, -46, 26, 26), Color(0.44, 0.62, 0.27))  # 身
	draw_rect(Rect2(-13, -20, 26, 20), Color(0.36, 0.5, 0.22))  # 腿
	draw_circle(Vector2(0, -58), 12, Color(0.44, 0.62, 0.27))  # 头
	draw_circle(Vector2(-facing * 9, -60), 4, Color(1.0, 0.9, 0.3))  # 眼
	draw_line(Vector2(facing * 8, -50), Vector2(facing * 26, -38), Color(0.55, 0.38, 0.22), 4.0)  # 棒
