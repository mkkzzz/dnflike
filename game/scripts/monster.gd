class_name Monster
extends CharacterBody2D
## 方向锁定前摇、活动窗口判定、景深追击与完整受击链。
const AnimLib := preload("res://scripts/anim_lib.gd")
signal died(m: Monster)
signal damaged(m: Monster, amount: float, direct: bool)
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
var control_enabled := true
var depth_y := 0.0
var ground_y := 576.0
var arena_left := 64.0
var arena_right := 1216.0
var attack_facing := -1
var attack_cooldown := 0
var invincible := 0
var hit_chain := 0
var air_frames := 0
var anims: Dictionary = {}
var anim_name := ""
var anim_frame := 0
var anim_tick := 0
var training_mode := false
var training_origin := Vector2.ZERO
var training_depth := 0.0
var training_rest := 0.0
var _body_sprite: Sprite2D
var _impact_material: ShaderMaterial
var _impact_age := 1.0
var _impact_life := 0.24
var _impact_strength := 0.0
var _impact_direction := 1
var _impact_tint := Color(1.0, 0.96, 0.84)

func _ready() -> void:
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(38, 90)
	shape.shape = rect
	shape.position = Vector2(0, -45)
	add_child(shape)
	collision_layer = 4
	collision_mask = 1
	anims = AnimLib.load_group("monster")
	anim_name = _pick_anim()
	var impact_shader := Shader.new()
	impact_shader.code = """shader_type canvas_item;
uniform float hit_flash : hint_range(0.0, 1.0) = 0.0;
uniform vec4 impact_tint : source_color = vec4(1.0, 0.96, 0.84, 1.0);
void fragment() {
	COLOR.rgb = mix(COLOR.rgb, impact_tint.rgb, hit_flash);
}
"""
	_impact_material = ShaderMaterial.new()
	_impact_material.shader = impact_shader
	_body_sprite = Sprite2D.new()
	_body_sprite.name = "ImpactBodyVisual"
	_body_sprite.centered = false
	_body_sprite.region_enabled = true
	_body_sprite.region_filter_clip_enabled = true
	_body_sprite.material = _impact_material
	_body_sprite.z_index = 1
	add_child(_body_sprite)
	_sync_body_visual()

func setup(data: Dictionary, player: Node2D, battle_fx: BattleFX) -> void:
	cfg = data.duplicate(true)
	hp = float(cfg.get("hp", 200))
	player_ref = player
	fx = battle_fx
	attack_cooldown = randi_range(0, int(cfg.get("attack_cooldown", 42)))

func visual_position() -> Vector2:
	return position + Vector2(0, depth_y)

func hurtbox() -> Rect2:
	var height := float(cfg.get("hurtbox_height", 132))
	if state == St.DOWN:
		height *= 0.45
	return Rect2(position + Vector2(-24, depth_y - height), Vector2(48, height))

func _physics_process(delta: float) -> void:
	if dead or not control_enabled:
		return
	if fx != null and fx.freeze > 0:
		return
	if training_mode:
		training_rest += delta
		if training_rest > 4.0 and state in [St.IDLE, St.PATROL, St.CHASE]:
			position.x = move_toward(position.x, training_origin.x, delta * 210)
			depth_y = move_toward(depth_y, training_depth, delta * 65)
			hp = float(cfg.get("hp", 4000))
	invincible = maxi(0, invincible - 1)
	attack_cooldown = maxi(0, attack_cooldown - 1)
	flash = maxi(0, flash - 1)
	modulate = Color.WHITE
	_tick_bleed(delta)
	if dead:
		return
	match state:
		St.IDLE:
			_idle()
		St.PATROL:
			_patrol()
		St.CHASE:
			_chase(delta)
		St.ATTACK:
			_attack()
		St.HIT:
			velocity.x = move_toward(velocity.x, 0.0, 380.0 * delta)
			st_t -= 1
			if st_t <= 0:
				_set_state(St.CHASE)
		St.AIR:
			velocity.x = move_toward(velocity.x, 0.0, 200.0 * delta)
			air_frames += 1
			if air_frames >= int(cfg.get("max_air_frames", 150)):
				bounce_used = true
				velocity.y = maxf(velocity.y, 340.0)
		St.DOWN:
			velocity.x = move_toward(velocity.x, 0.0, 700.0 * delta)
			st_t -= 1
			if st_t <= 0:
				_getup()
		St.GETUP:
			velocity.x = 0.0
			st_t -= 1
			if st_t <= 0:
				_set_state(St.IDLE)
	if not is_on_floor() or velocity.y < 0.0:
		velocity.y += float(cfg.get("gravity", 1700)) * delta
	else:
		velocity.y = 0.0
	var falling_speed := velocity.y
	move_and_slide()
	position.x = clampf(position.x, arena_left, arena_right)
	if state == St.AIR and is_on_floor() and falling_speed >= 0.0:
		if not bounce_used and falling_speed > float(cfg.get("bounce_threshold", 400)):
			bounce_used = true
			# 必须使用碰撞之前的落速，move_and_slide 会把 velocity.y 清零。
			velocity.y = -falling_speed * float(cfg.get("bounce_ratio", 0.42))
			if fx != null:
				fx.add_shake(2.0)
				fx.spawn_dust(visual_position(), 6)
			print("[M1] monster bounce")
		else:
			_set_state(St.DOWN)
			st_t = int(cfg.get("knockdown_time", 36))
			print("[M1] monster state: AIR -> DOWN")
	z_index = 100 + int(round(depth_y))
	_anim_step()
	_sync_body_visual()
	queue_redraw()


func _process(delta: float) -> void:
	if fx != null and fx.freeze > 0:
		return
	if _impact_age < _impact_life:
		_impact_age += delta
		_sync_body_visual()


func impact_visual_state() -> Dictionary:
	# Render offsets never move the body collider, hurtbox or combat position.
	var pressure := exp(-_impact_age * 18.0) * _impact_strength if _impact_age < _impact_life else 0.0
	var recoil := sin(_impact_age * 57.0) * exp(-_impact_age * 22.0) * 1.5 * _impact_strength
	var contact_flash := clampf(exp(-_impact_age * 43.0) * _impact_strength * 0.77, 0, 0.96) if _impact_age < 0.13 else 0.0
	return {"age": _impact_age, "offset": Vector2(_impact_direction * (pressure * 7.5 + recoil), -pressure * 1.2),
		"scale": Vector2(1.0 - pressure * 0.11, 1.0 + pressure * 0.065),
		"rotation": _impact_direction * pressure * 0.032,
		"flash": contact_flash}


func _sync_body_visual() -> void:
	if _body_sprite == null:
		return
	var clip: Dictionary = anims.get(anim_name, {})
	_body_sprite.visible = not clip.is_empty()
	if clip.is_empty():
		return
	var visual := impact_visual_state()
	var squash: Vector2 = visual["scale"]
	_body_sprite.position = Vector2(0, depth_y) + (visual["offset"] as Vector2)
	_body_sprite.rotation = float(visual["rotation"])
	_body_sprite.scale = Vector2(float(facing) * squash.x, squash.y)
	_body_sprite.texture = clip["tex"]
	_body_sprite.region_rect = AnimLib.src_rect(clip, anim_frame)
	_body_sprite.offset = Vector2(-float(clip["ax"]), -float(clip["ay"]))
	_impact_material.set_shader_parameter("hit_flash", float(visual["flash"]))
	_impact_material.set_shader_parameter("impact_tint", _impact_tint)

func _tick_bleed(delta: float) -> void:
	if bleed_left <= 0.0:
		return
	bleed_left = maxf(0.0, bleed_left - delta)
	bleed_tick -= delta
	if bleed_tick <= 0.0:
		bleed_tick += 0.5
		var damage := bleed_dps * 0.5
		hp = maxf(0.0, hp - damage)
		damaged.emit(self, damage, false)
		if fx != null:
			fx.spawn_number(visual_position() + Vector2(0, -132), str(roundi(damage)), Color(0.9, 0.2, 0.15), 14)
		print("[M1] bleed tick dmg=%.0f hp=%.0f" % [damage, hp])
		if hp <= 0.0:
			_die()

func _player_alive() -> bool:
	return is_instance_valid(player_ref) and not (player_ref as Player).dead

func _idle() -> void:
	velocity.x = 0.0
	if training_mode:
		return
	if not _player_alive():
		return
	var d := player_ref.position.x - position.x
	facing = 1 if d >= 0 else -1
	st_t += 1
	if absf(d) <= float(cfg.get("detect_range", 680)):
		_set_state(St.CHASE)
	elif st_t >= int(cfg.get("idle_time", 45)):
		_set_state(St.PATROL)

func _patrol() -> void:
	if training_mode:
		velocity.x = 0
		_set_state(St.IDLE)
		return
	if not _player_alive():
		velocity.x = 0.0
		return
	if absf(player_ref.position.x - position.x) <= float(cfg.get("detect_range", 680)):
		_set_state(St.CHASE)
		return
	st_t += 1
	if position.x <= arena_left + 30 or position.x >= arena_right - 30:
		patrol_dir = 1 if position.x <= arena_left + 30 else -1
	facing = patrol_dir
	velocity.x = patrol_dir * float(cfg.get("move_speed", 130))
	if st_t >= int(cfg.get("patrol_time", 80)):
		patrol_dir *= -1
		_set_state(St.IDLE)

func _chase(delta: float) -> void:
	if training_mode:
		velocity.x = 0
		_set_state(St.IDLE)
		return
	if not _player_alive():
		_set_state(St.IDLE)
		velocity.x = 0.0
		return
	var player := player_ref as Player
	var distance := player.position.x - position.x
	facing = 1 if distance >= 0 else -1
	depth_y = move_toward(depth_y, player.depth_y, float(cfg.get("lane_speed", 65)) * delta)
	var reach := float(cfg.get("attack_move", {}).get("range", 100))
	if absf(distance) <= reach and absf(depth_y - player.depth_y) <= float(cfg.get("attack_lane", 20)):
		velocity.x = 0.0
		if attack_cooldown == 0 and absf(player.position.y - position.y) <= float(cfg.get("attack_height", 100)):
			attack_facing = facing
			_set_state(St.ATTACK)
	else:
		velocity.x = facing * float(cfg.get("chase_speed", 180))

func _attack() -> void:
	st_t += 1
	velocity.x = 0.0
	facing = attack_facing
	var move: Dictionary = cfg.get("attack_move", {})
	var windup := int(move.get("windup", 20))
	var active := int(move.get("active", 4))
	if st_t > windup and st_t <= windup + active and not atk_hit_done and _player_alive():
		var reach := float(move.get("range", 100)) + float(move.get("extension", 12))
		var x0 := position.x if attack_facing > 0 else position.x - reach
		var attack_box := Rect2(Vector2(x0, position.y + depth_y - float(move.get("height", 150))), Vector2(reach, float(move.get("height", 150))))
		var player := player_ref as Player
		if absf(depth_y - player.depth_y) <= float(cfg.get("attack_lane", 20)) and attack_box.intersects(player.hurtbox()):
			if player.take_hit(float(move.get("damage", cfg.get("attack", 25))), attack_facing, move):
				atk_hit_done = true
				print("[M1] goblin hit player")
	if st_t >= windup + active + int(move.get("recovery", 20)):
		attack_cooldown = int(cfg.get("attack_cooldown", 42))
		_set_state(St.CHASE)

func _getup() -> void:
	_set_state(St.GETUP)
	st_t = int(cfg.get("getup_time", 12))
	invincible = st_t + 1
	attack_cooldown = int(cfg.get("attack_cooldown", 42))
	print("[M1] monster state: DOWN -> GETUP")

func _set_state(value: int) -> void:
	state = value
	st_t = 0
	if value == St.ATTACK:
		atk_hit_done = false
	if value in [St.IDLE, St.PATROL, St.CHASE]:
		hit_chain = 0
		air_frames = 0
	# 状态切换与贴图选择同步；命中后的停帧不能先把贴图清空。
	anim_name = _pick_anim()
	anim_frame = 0
	anim_tick = 0

func take_hit(hit: Dictionary, from_dir: int) -> bool:
	if dead or invincible > 0 or state == St.GETUP:
		return false
	var damage := float(hit.get("damage", 0))
	hp = maxf(0.0, hp - damage)
	if training_mode:
		training_rest = 0.0
		hp = maxf(1, hp)
	damaged.emit(self, damage, true)
	hit_chain += 1
	flash = int(cfg.get("hit_flash", 2)) + 1
	var heavy: bool = hit.has("launch") or bool(hit.get("knockdown", false)) or int(hit.get("hitstop", 4)) >= 6
	_impact_age = 0.0
	_impact_strength = 1.6 if heavy else 1.0
	_impact_direction = from_dir if from_dir != 0 else -facing
	_impact_tint = Color(0.83, 0.95, 1.0) if str(hit.get("material", "flesh")) == "metal" else Color(1.0, 0.96, 0.84)
	_sync_body_visual()
	if fx != null:
		var feedback := hit.duplicate(true)
		feedback["material"] = str(cfg.get("hit_material", hit.get("material", "flesh")))
		if not feedback.has("contact_point"):
			feedback["contact_point"] = _blade_contact_point(from_dir)
		if hit.has("launch"):
			feedback["kind"] = "launch"
		elif hit.get("knockdown", false):
			feedback["kind"] = "knock"
		fx.on_hit(visual_position(), from_dir, damage, feedback)
	if hit.has("bleed"):
		bleed_dps = float(hit["bleed"].get("dps", 10))
		bleed_left = float(hit["bleed"].get("time", 3))
		bleed_tick = 0.5
	if hp <= 0.0:
		_die()
		return true
	attack_cooldown = maxi(attack_cooldown, int(cfg.get("hit_attack_delay", 18)))
	if hit_chain >= int(cfg.get("max_hit_chain", 8)) and state != St.AIR and is_on_floor():
		_getup()
		invincible = int(cfg.get("protection_invincible", 18)) + 1
		velocity = Vector2.ZERO
		_sync_body_visual()
		return true
	if hit.has("launch"):
		var launch: Dictionary = hit["launch"]
		velocity = Vector2(from_dir * float(launch.get("vx", 120)), float(launch.get("vy", -680)))
		_set_state(St.AIR)
		bounce_used = false
		print("[M1] monster launch")
	elif hit.get("knockdown", false):
		velocity = Vector2(from_dir * float(hit.get("knockback", 180)), 300.0 if state == St.AIR else -260.0)
		_set_state(St.AIR)
		bounce_used = false
	elif state == St.AIR and air_frames < int(cfg.get("max_air_frames", 150)):
		velocity.y = minf(velocity.y, float(cfg.get("juggle_vy", -240)))
		velocity.x = from_dir * float(hit.get("knockback", 90))
		print("[M1] monster juggled in air")
	elif state == St.AIR:
		# 浮空保护：仍然结算伤害，但不再重置下落，避免无限悬空。
		velocity.y = maxf(velocity.y, 340.0)
	else:
		velocity.x = from_dir * float(hit.get("knockback", 80))
		_set_state(St.HIT)
		st_t = int(hit.get("hardstun", cfg.get("hardstun", 12)))
		print("[M1] monster HIT")
	_sync_body_visual()
	queue_redraw()
	return true


func _blade_contact_point(from_dir: int) -> Vector2:
	var bounds := hurtbox()
	var contact := visual_position() + Vector2(-from_dir * 10.0, -bounds.size.y * 0.64)
	if player_ref is Player:
		var attachment: Node2D = (player_ref as Player).weapon_attachment
		if is_instance_valid(attachment) and attachment.has_method("blade_base_global"):
			var blade_base: Vector2 = attachment.call("blade_base_global")
			var blade_tip: Vector2 = attachment.call("blade_tip_global")
			var edge := blade_tip - blade_base
			var along := clampf((contact - blade_base).dot(edge) / maxf(edge.length_squared(), 0.001), 0, 1)
			var closest := blade_base + edge * along
			contact = Vector2(clampf(closest.x, bounds.position.x + 4, bounds.end.x - 4),
				clampf(closest.y, bounds.position.y + 9, bounds.end.y - 10))
	return contact

func _die() -> void:
	if training_mode:
		hp = 1
		return
	if dead:
		return
	dead = true
	control_enabled = false
	bleed_left = 0.0
	velocity = Vector2.ZERO
	state = St.DOWN
	_anim_step()
	anim_frame = maxi(0, int(anims.get(anim_name, {}).get("frames", 1)) - 1)
	_sync_body_visual()
	queue_redraw()
	if fx != null:
		fx.play_sound("death")
	print("[M1] goblin died")
	died.emit(self)
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, 0.65)
	tween.tween_callback(queue_free)

func _pick_anim() -> String:
	var names := {St.IDLE: "idle", St.PATROL: "patrol", St.CHASE: "chase", St.ATTACK: "attack", St.HIT: "hit", St.AIR: "air", St.DOWN: "down", St.GETUP: "getup"}
	return AnimLib.pick(anims, [names.get(state, "idle"), "idle"], "idle")

func _anim_step() -> void:
	var wanted := _pick_anim()
	if wanted != anim_name:
		anim_name = wanted
		anim_frame = 0
		anim_tick = 0
	if not anims.has(anim_name):
		return
	if state == St.ATTACK:
		var move: Dictionary = cfg.get("attack_move", {})
		anim_frame = AnimLib.frame_for_move(anims[anim_name], float(st_t), move)
	elif state == St.GETUP:
		anim_frame = AnimLib.frame_at_progress(anims[anim_name], 1.0 - float(st_t) / maxf(1.0, float(cfg.get("getup_time", 12))))
	else:
		var result: Array = AnimLib.advance(anims[anim_name], anim_frame, anim_tick)
		anim_frame = int(result[0])
		anim_tick = int(result[1])

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
	# 地面的红色范围与朝向线让前摇可读；锁定后玩家可绕到身后。
	if state == St.ATTACK:
		var attack: Dictionary = cfg.get("attack_move", {})
		var startup := maxf(1.0, float(attack.get("windup", 20)))
		var progress := clampf(float(st_t) / startup, 0.0, 1.0)
		var reach := float(attack.get("range", 96))
		var warning := Color(1.0, 0.23, 0.12, 0.25 + progress * 0.6)
		if st_t > startup:
			warning = Color(1.0, 0.72, 0.25, 0.65)
		draw_set_transform(Vector2(0, depth_y + gy), 0.0, Vector2(1, 0.32))
		draw_arc(Vector2.ZERO, reach, -PI, PI, 40, warning, 2.5)
		draw_line(Vector2.ZERO, Vector2(attack_facing * reach * progress, 0), warning, 5.0)
		draw_set_transform(base, 0.0, Vector2.ONE)
	# 骨骼动画帧条：position 即脚底，锚点反推左上角，depth_y 只影响绘制；朝左时以脚底为轴翻转
	if anims.get(anim_name, {}).is_empty():
		_draw_placeholder()
	# 头顶血条已移除：preview 里怪物只有屏幕顶部中央的目标铭牌（HUD 负责），世界空间不画血条

## 帧条缺失时的兜底：沿用 M1 的 draw_rect 占位哥布林
func _draw_placeholder() -> void:
	draw_rect(Rect2(-13, -46, 26, 26), Color(0.44, 0.62, 0.27))  # 身
	draw_rect(Rect2(-13, -20, 26, 20), Color(0.36, 0.5, 0.22))  # 腿
	draw_circle(Vector2(0, -58), 12, Color(0.44, 0.62, 0.27))  # 头
	draw_circle(Vector2(-facing * 9, -60), 4, Color(1.0, 0.9, 0.3))  # 眼
	draw_line(Vector2(facing * 8, -50), Vector2(facing * 26, -38), Color(0.55, 0.38, 0.22), 4.0)  # 棒
