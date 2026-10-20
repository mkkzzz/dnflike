extends Node
const AnimLib := preload("res://scripts/anim_lib.gd")
const DungeonRegressionScript := preload("res://scripts/dungeon_regression.gd")
## --test: assertions and a complete encounter using gameplay actions.
## --capture: rendered title / arena / hit / result screenshots in temp/demo.
var main_ref
var checks := 0
var failures := 0
var observed_moves: Array = []
var _feedback_actions: Array[String] = []

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if "--test" in OS.get_cmdline_user_args():
		_run_checks.call_deferred()
	elif "--capture" in OS.get_cmdline_user_args():
		_run_capture.call_deferred()
	elif "--showcase" in OS.get_cmdline_user_args():
		_run_showcase.call_deferred()
	elif "--seq6" in OS.get_cmdline_user_args():
		_run_seq6_showcase.call_deferred()
	elif "--v6-freeze-test" in OS.get_cmdline_user_args():
		_run_v6_freeze_only.call_deferred()
	elif "--movement-feedback-test" in OS.get_cmdline_user_args():
		_run_movement_feedback_only.call_deferred()
	elif "--movement-feedback-capture" in OS.get_cmdline_user_args():
		_run_movement_feedback_capture.call_deferred()

func _frames(count: int) -> void:
	for _index in count:
		await get_tree().physics_frame

func _release_inputs() -> void:
	for action in ["attack", "jump", "generic_skill", "skill_a", "skill_s", "guard", "move_left", "move_right", "move_up", "move_down", "potion_hp", "potion_mp"]:
		Input.action_release(action)

func _tap(action: String) -> void:
	Input.action_press(action)
	await _frames(2)
	Input.action_release(action)
	await _frames(1)

func _hold_double_tap(direction: String) -> void:
	await _tap(direction)
	Input.action_press(direction)
	await _frames(1)

func _check(condition: bool, label: String) -> void:
	checks += 1
	if condition:
		print("[DEMO_TEST] PASS " + label)
	else:
		failures += 1
		push_error("[DEMO_TEST] FAIL " + label)

func _observe(_monster, _damage: float) -> void:
	observed_moves.append(main_ref.player.move_name)

func _observe_feedback_action(identifier: String) -> void:
	_feedback_actions.append(identifier)

func _fresh(job_id := 0) -> Monster:
	_release_inputs()
	main_ref._start_demo(job_id)
	await _frames(3)
	var p: Player = main_ref.player
	p.position = Vector2(500, main_ref.GROUND_Y)
	p.depth_y = 0
	p.invincible = 99999
	p.cfg["attack_speed"] = float(GameConfig.player.get("attack_speed", 1.0))
	for monster in main_ref.monsters:
		monster.control_enabled = false
		monster.position.x = 1100
	var target: Monster = main_ref.monsters[0]
	target.position.x = 620
	target.depth_y = 0
	target.hp = 2000
	target.cfg["hp"] = 2000
	observed_moves.clear()
	main_ref.bm.clear_fx()
	await _frames(2)
	return target

## 在指定 tick 上取一次 V6 刃线（确定性，不依赖物理帧到达顺序）
func _blade_at(actor: Player, move: String, tick: float, face: int) -> Array:
	actor._start_move(move)
	actor.facing = face
	actor.phase_t = tick
	actor.anim_name = move
	return actor.seq_blade_world(tick)


func _rect_gap(box: Rect2, point: Vector2) -> float:
	var dx := maxf(maxf(box.position.x - point.x, point.x - box.end.x), 0.0)
	var dy := maxf(maxf(box.position.y - point.y, point.y - box.end.y), 0.0)
	return Vector2(dx, dy).length()


## 从真正的 Sprite2D 绘制矩形求 PNG 像素的世界坐标。
## 不能用 node.position/offset 代替：centered=true 会额外减掉半张画布。
func _sprite_pixel_world(sprite: Sprite2D, pixel: Vector2) -> Vector2:
	var rect := sprite.get_rect()
	var uv := pixel / sprite.texture.get_size()
	if sprite.flip_h:
		uv.x = 1.0 - uv.x
	if sprite.flip_v:
		uv.y = 1.0 - uv.y
	return sprite.to_global(rect.position + uv * rect.size)


func _actor_pixel_world(actor: Player, pixel: Vector2) -> Vector2:
	return actor.global_transform * actor.body_transform() * (actor.seq_texture_rect().position + pixel)


## 取真正有 alpha 的纹理像素，避免只验收空透明画布或元数据。
func _painted_pixel(texture: Texture2D) -> Vector2:
	var painted := texture.get_image()
	if painted == null:
		return Vector2.INF
	if painted.is_compressed():
		painted.decompress()
	for y in range(0, painted.get_height(), 4):
		for x in range(0, painted.get_width(), 4):
			if painted.get_pixel(x, y).a > 0.05:
				return Vector2(x + 0.5, y + 0.5)
	return Vector2.INF


func _paint_near(texture: Texture2D, pixel: Vector2) -> bool:
	var painted := texture.get_image()
	if painted == null:
		return false
	if painted.is_compressed():
		painted.decompress()
	for y in range(maxi(0, int(pixel.y) - 4), mini(painted.get_height(), int(pixel.y) + 5)):
		for x in range(maxi(0, int(pixel.x) - 4), mini(painted.get_width(), int(pixel.x) + 5)):
			if painted.get_pixel(x, y).a > 0.03:
				return true
	return false


func _canvas_z(item: CanvasItem) -> int:
	var value := item.z_index
	if item.z_as_relative and item.get_parent() is CanvasItem:
		value += _canvas_z(item.get_parent())
	return value


func _nearest_entity_slice(entity: DungeonEntity, world_x: float) -> Sprite2D:
	var nearest: Sprite2D = null
	var distance := INF
	for slice in entity.render_slices:
		var gap := absf(float(slice.get_meta("ground_x")) - world_x)
		if gap < distance:
			nearest = slice
			distance = gap
	return nearest


func _start_v6_move(actor: Player, move: String) -> bool:
	if move == "quick_draw":
		actor.set_job(2)
		actor.mp = 300.0
		actor.cds.clear()
		return actor._try_skill_action("skill_a")
	return actor._start_move(move)


func _attack_duration(speed: float) -> int:
	var target: Monster = await _fresh()
	target.position.x = 1000
	var p: Player = main_ref.player
	p.cfg["attack_speed"] = speed
	p._start_attack()
	var count := 0
	while p.state == Player.St.ATK and count < 100:
		count += 1
		await _frames(1)
	return count

func _run_checks() -> void:
	main_ref = get_parent()
	main_ref.player.landed_hit.connect(_observe)
	await _frames(3)
	# 默认入口是副本 10001 的入口房（10001-R01：无怪、门已开启）
	_check(main_ref.dungeon_mode and main_ref.dungeon != null and main_ref.dungeon.room_count() == 5, "boot enters dungeon 10001-A with five rooms")
	_check(main_ref.battle_state == main_ref.BattleState.ROOM_CLEAR and main_ref.alive_count() == 0, "entrance room starts without combat")
	_check(main_ref.player.control_enabled and main_ref.current_door != null and main_ref.current_door.opened, "entrance door is open and the player can move")
	var audio: CombatAudio = main_ref.bm._audio
	_check(audio._voices.size() >= 8 and audio._voices.size() <= 12 and audio._streams.size() >= 18, "audio loads layered variants with a bounded voice pool")
	var audio_valid := true
	for entry in audio._streams.values():
		var variants: Array = entry if entry is Array else [entry]
		for stream in variants:
			audio_valid = audio_valid and stream is AudioStreamWAV and stream.data.size() > 2000 and stream.format == AudioStreamWAV.FORMAT_16_BITS
	_check(audio_valid, "offline foley variants contain valid sixteen-bit PCM")
	# 哥布林死亡声由受击声派生：3 变体齐全，且时长是受击的 2 倍（tools/bake_goblin_death.py）
	var death_takes: Array = audio._streams.get("goblin_death", [])
	var hurt_takes: Array = audio._streams.get("goblin_hurt", [])
	_check(death_takes.size() == 3 and hurt_takes.size() == 3, "goblin death sound ships three baked variants")
	var ratio_ok := death_takes.size() == 3 and hurt_takes.size() == 3
	if ratio_ok:
		for index in 3:
			var death_stream: AudioStreamWAV = death_takes[index]
			var hurt_stream: AudioStreamWAV = hurt_takes[index]
			var span := death_stream.get_length() / maxf(0.001, hurt_stream.get_length())
			ratio_ok = ratio_ok and absf(span - 2.0) < 0.06
	_check(ratio_ok, "goblin death sound lasts twice as long as its hurt take")
	# 技能命中声：四个技能各一记自己的声音，且不与普攻命中声共用
	var impact_cues := {}
	var impact_ready := true
	for move in BattleFX.SKILL_IMPACT:
		var cue := str(BattleFX.SKILL_IMPACT[move])
		impact_cues[cue] = true
		var takes: Array = audio._streams.get(cue, [])
		impact_ready = impact_ready and takes.size() == 3
	_check(impact_ready and impact_cues.size() == 4, "each skill ships its own three-variant impact sound")
	var clash := false
	for cue in impact_cues:
		clash = clash or BattleFX.NORMAL_ATTACK_HIT_SWING.values().has(cue)
	_check(not clash, "skill impacts never reuse the normal-attack hit cues")
	# Accelerated assertions are silent; --capture alone exercises real playback.
	audio.enabled = false
	var m: Monster = await _fresh()
	var p: Player = main_ref.player
	_check(p.anims.size() >= 20 and m.anims.size() == 8, "separate body animations and monster animations load")
	var first_attack: Dictionary = GameConfig.moves["attack1"]
	# V6 三段普攻与拔刀斩改由 manifest 的逐 tick 帧表驱动，帧序就是相位刻度；
	# 其余动作仍走 V4 的相位关键姿势映射。
	var seq_tick := int(float(first_attack["windup"])) + 1
	var seq_pose: int = AnimLib.frame_at_progress(p.anims["attack1"], float(seq_tick) / float(p.anims["attack1"]["frames"]))
	var active_pose_valid := seq_pose == seq_tick
	for pose_index in p.anims["attack1"].get("phase_frames", {}).get("active", []):
		active_pose_valid = active_pose_valid or seq_pose == int(pose_index)
	_check(active_pose_valid, "attack pose matches active hit frame")
	_check(AnimLib.frame_for_move(p.anims["attack3"], 1, GameConfig.moves["attack3"]) == 0, "windup uses preparation pose")
	var club: Dictionary = GameConfig.monsters["goblin"]["attack_move"]
	_check(AnimLib.frame_for_move(m.anims["attack"], float(club["windup"]) + 1, club) == 2, "monster smash pose matches its active frame")
	_check(main_ref.alive_count() == 2, "first wave spawns two enemies")
	# Real Input API: early second press is buffered through the first hitstop.
	await _tap("attack")
	await _frames(5)
	await _tap("attack")
	await _frames(18)
	await _tap("attack")
	await _frames(50)
	_check(observed_moves.has("attack1") and observed_moves.has("attack2") and observed_moves.has("attack3"), "buffered three-hit chain connects")
	_check(observed_moves.size() == 3, "each target is hit once per attack segment")
	var basic_damage := float(GameConfig.moves["attack1"]["damage"]) + float(GameConfig.moves["attack2"]["damage"]) + float(GameConfig.moves["attack3"]["damage"])
	_check(is_equal_approx(m.hp, 2000 - basic_damage), "three-hit chain deals configured damage")
	var slow: int = await _attack_duration(0.7)
	var fast: int = await _attack_duration(1.3)
	_check(fast < slow and slow - fast >= 6, "fractional attack speed changes actual duration")
	# A target entering during the authored active window must still be hit.
	m = await _fresh()
	m.position.x = 900
	p._start_attack()
	await _frames(int(GameConfig.moves["attack1"]["windup"]) + 3)
	m.position.x = p.position.x + 120
	await _frames(30)
	_check(observed_moves.size() == 1, "late active-window entry connects once")
	m = await _fresh()
	m.depth_y = -35
	await _tap("attack")
	await _frames(30)
	_check(m.hp == 2000, "different depth lanes do not hit")
	# Launch, jump cancel and air basic attack are all playable inputs.
	m = await _fresh()
	m.control_enabled = true
	m.cfg["detect_range"] = 0
	m.cfg["chase_speed"] = 0
	await _tap("generic_skill")
	await _frames(7)
	_check(m.state == Monster.St.AIR, "uppercut launches target")
	await _tap("jump")
	await _frames(4)
	_check(p.position.y < main_ref.GROUND_Y, "uppercut can cancel to a manual jump")
	await _tap("attack")
	await _frames(15)
	_check(observed_moves.has("air_attack"), "dedicated air attack follows uppercut")
	# Multi-hit skill tails, costs, cooldown and rejection.
	m = await _fresh(2)
	_check(p._try_skill_action("skill_s"), "thrust cast accepted")
	await _frames(65)
	_check(observed_moves.count("thrust") == 3, "all three thrust segments connect")
	_check(is_equal_approx(m.hp, 1920), "thrust deals 25+25+30")
	# 自然回复（默认 1%/s）会让 MP 在 65 帧里回涨约 3 点，所以这里按区间判断
	# "消耗了 30 点"，不再比对绝对值。
	_check(p.mp > 270.0 and p.mp < 276.0 and int(p.cds.get("thrust", 0)) > 0, "skill consumes MP and starts cooldown")
	var mp_before_reject := p.mp
	_check(not p._try_skill_action("skill_s") and p.mp == mp_before_reject, "cooldown rejection does not spend MP")
	p.cds.clear()
	p.mp = 0
	_check(not p._try_skill_action("skill_a"), "insufficient MP blocks skill")
	m = await _fresh(1)
	p._try_skill_action("skill_s")
	await _frames(60)
	_check(observed_moves.count("rage_slash") == 2 and m.bleed_left > 0, "rage slash connects both segments and applies bleed")
	m = await _fresh(1)
	p.invincible = 0
	p._try_skill_action("skill_a")
	p.take_hit(70)
	_check(is_equal_approx(p.hp, 900) and p.state != Player.St.HIT, "blood rage armor takes amplified damage without hitstun")
	m = await _fresh(1)
	p.invincible = 0
	p._try_skill_action("skill_s")
	p.take_hit(100)
	_check(p.hp == 900 and p.state == Player.St.SKILL, "skill armor prevents stun but still takes damage")
	m = await _fresh()
	p.invincible = 0
	p.state = Player.St.GUARD
	p._guard_frames = 6
	p.take_hit(100)
	_check(p.hp == 980, "guard absorbs eighty percent")
	m = await _fresh()
	p.invincible = 0
	Input.action_press("move_down")
	await _tap("jump")
	Input.action_release("move_down")
	_check(p.state == Player.St.BACK_DASH and p.invincible > 0, "down+jump starts invincible backdash")
	var health := p.hp
	p.take_hit(100)
	_check(p.hp == health, "backdash invincibility rejects damage")
	await _frames(25)
	_check(p.position.x < 410, "backdash covers configured retreat distance")
	m = await _fresh()
	p.hp = 400
	p.mp = 100
	_check(p._use_potion("potion_hp") and p.hp == 700, "HP potion restores configured health")
	_check(not p._use_potion("potion_mp") and p.mp == 100, "HP and MP potions share cooldown")
	p.potion_cd = 0
	_check(p._use_potion("potion_mp") and p.mp == 220, "MP potion restores configured mana")
	# Actual falling physics must bounce, reach DOWN and then GETUP.
	m = await _fresh()
	p.control_enabled = false
	m.control_enabled = true
	m.cfg["detect_range"] = 0
	m.take_hit({"damage": 1, "launch": {"vx": 0, "vy": -740}, "hitstop": 0}, 1)
	var bounced := false
	var saw_down := false
	var saw_getup := false
	var protected_getup := false
	for _index in 180:
		await _frames(1)
		bounced = bounced or (m.bounce_used and m.velocity.y < -50)
		saw_down = saw_down or m.state == Monster.St.DOWN
		if m.state == Monster.St.GETUP:
			saw_getup = true
			protected_getup = protected_getup or not m.take_hit({"damage": 5}, 1)
	_check(bounced and saw_down and saw_getup, "monster physically bounces then goes down and gets up")
	_check(protected_getup, "monster getup has invincibility")
	m = await _fresh()
	p.control_enabled = false
	m.control_enabled = true
	m.hp = 5
	m.take_hit({"damage": 0, "bleed": {"dps": 20, "time": 1.0}, "hitstop": 0}, 1)
	await _frames(35)
	_check(m.dead and main_ref.kills == 1, "bleed death uses the death event and kill count")
	m = await _fresh()
	p.invincible = 0
	p.take_hit(5, 1, {"launch": {"vx": 0, "vy": -600}})
	var player_down := false
	var player_getup := false
	for _index in 150:
		await _frames(1)
		player_down = player_down or p.state == Player.St.DOWN
		player_getup = player_getup or p.state == Player.St.GETUP
	_check(player_down and player_getup and p.state == Player.St.IDLE, "player down/getup returns to playable state")
	# Pause freezes simulation and resume restores control.
	m = await _fresh()
	main_ref._toggle_pause()
	var pause_time: float = main_ref.elapsed
	await _frames(8)
	_check(main_ref.elapsed == pause_time and not p.control_enabled, "pause stops encounter time and control")
	main_ref._toggle_pause()
	_check(p.control_enabled and not get_tree().paused, "pause resumes combat")
	p.invincible = 0
	p.hp = 1
	p.take_hit(10)
	_check(p.dead and main_ref.battle_state == main_ref.BattleState.DEFEAT, "death enters defeat without debug respawn")
	main_ref._reset_battle()
	await _frames(2)
	_check(not p.dead and p.hp == 1000 and p.mp == 300 and p.cds.is_empty() and p.buff_data.is_empty() and p.potion_cd == 0 and p.combo == 0, "retry resets health MP cooldowns buff and combo")
	_check(main_ref.bm.freeze == 0 and main_ref.wave_index == 0 and main_ref.kills == 0, "retry clears effects and encounter state")
	# Exercise every real wave through the player's hit and AI physics.
	main_ref._start_demo(2)
	p.invincible = 999999
	for frame in 3600:
		await _frames(1)
		if main_ref.battle_state == main_ref.BattleState.VICTORY:
			break
		if main_ref.battle_state != main_ref.BattleState.FIGHT:
			_release_inputs()
			continue
		var target = main_ref._pick_target()
		if target == null:
			continue
		var dx: float = target.position.x - p.position.x
		Input.action_release("move_left")
		Input.action_release("move_right")
		Input.action_release("move_up")
		Input.action_release("move_down")
		if absf(dx) > 88:
			Input.action_press("move_right" if dx > 0 else "move_left")
		elif p.state in [Player.St.IDLE, Player.St.RUN]:
			p.facing = 1 if dx > 0 else -1
		if absf(p.depth_y - target.depth_y) > 8:
			Input.action_press("move_down" if p.depth_y < target.depth_y else "move_up")
		if dx * p.facing < -20:
			p.input_buffer.clear()
		if frame % 9 == 0 and absf(dx) < 145 and dx * p.facing >= 0:
			p.buffer_action("attack")
		if frame % 150 == 0 and absf(dx) < 180 and dx * p.facing >= 0:
			p.buffer_action("skill_a")
		if frame % 600 == 0:
			print("[DEMO_TEST] bot wave=%d kills=%d player=(%.0f,%.0f) facing=%d state=%d target=(%.0f,%.0f) hp=%.0f state=%d inv=%d" % [main_ref.wave_index + 1, main_ref.kills, p.position.x, p.depth_y, p.facing, p.state, target.position.x, target.depth_y, target.hp, target.state, target.invincible])
	_release_inputs()
	_check(main_ref.battle_state == main_ref.BattleState.VICTORY and main_ref.kills == 8, "gameplay clears all three waves and reaches victory")
	_check(main_ref.hit_count > 20 and main_ref.best_chain >= 3, "results track actual hits and chain")
	if "--capture" in OS.get_cmdline_user_args() and main_ref.battle_state == main_ref.BattleState.VICTORY:
		await _capture("04_result")
	await _run_v3_checks()
	await _run_v4_checks()
	await _run_v6_checks()
	await _run_movement_feedback_checks()
	await _run_dungeon_checks()
	await DungeonRegressionScript.new().run(main_ref, _check, _frames)
	await preload("res://scripts/swordsman_v7_regression.gd").new().run(main_ref, _check, _frames, _capture)
	main_ref._show_ready()
	_check(main_ref.battle_state == main_ref.BattleState.READY and not p.control_enabled, "result returns to class selection")
	print("[DEMO_TEST] COMPLETE checks=%d failures=%d" % [checks, failures])
	main_ref.bm.clear_fx()
	await _frames(3)
	get_tree().quit(0 if failures == 0 else 1)

## 副本 10001-A 竖切：房间推进、清怪开门、BOSS 结算与 GM 面板命令。
func _run_dungeon_checks() -> void:
	var p: Player = main_ref.player
	print("[DEMO_TEST] frame budget at dungeon checks start = %d / %d" % [Engine.get_physics_frames(), int(GameConfig.runtime["tests"]["frame_budget"])])
	main_ref.gm_panel.close()
	main_ref._enter_dungeon("10001")
	await _frames(3)
	_check(main_ref.dungeon_mode and main_ref.dungeon.room_number() == 1, "dungeon restart returns to room 1")
	_check(main_ref.alive_count() == 0 and main_ref.room_cleared and main_ref.current_door != null and main_ref.current_door.opened, "entrance room has no enemies and an open door")
	if "--capture" in OS.get_cmdline_user_args():
		await _capture("10_dungeon_entrance")
	# 可行动范围必须贴合画面里的路面，而不是整幅图
	_check(p.arena_left >= main_ref.room_road_left and p.arena_right <= main_ref.room_road_right, "player arena stays inside the painted road")
	_check(main_ref.current_door.position.x <= main_ref.room_road_right, "the exit door sits inside the painted road")
	# 景深带必须逐图取该图自己的路面纵向范围，而不是统一的上下留边
	var expect_top: float = main_ref.room_bg_rect.position.y + main_ref.dungeon.ground_line_ratio() * main_ref.room_bg_rect.size.y - main_ref.GROUND_Y
	var expect_front: float = minf(main_ref.VIEW_H, main_ref.room_bg_rect.position.y + main_ref.dungeon.road_front_ratio() * main_ref.room_bg_rect.size.y) - main_ref.GROUND_Y
	_check(absf(main_ref.room_depth_min - expect_top) < 2.0, "depth band back edge = this image's ground line")
	_check(absf(main_ref.room_depth_max - expect_front) < 2.0, "depth band front edge = this image's road front")
	_check(p.lane_min() >= main_ref.room_depth_min - 1.0 and p.lane_max() <= main_ref.room_depth_max + 1.0, "lane limits follow the room's road band")
	_check(main_ref.room_depth_max - main_ref.room_depth_min > 160.0, "the depth band is wider than the old fixed strip")
	var band_room_one: float = main_ref.room_depth_max - main_ref.room_depth_min
	# 景深方向真的能走：先站到靠后处，再按住“上”走到该图路面的后端
	p.depth_y = p.lane_min() + 60.0
	await _frames(2)
	var depth_start: float = p.depth_y
	Input.action_press("move_up")
	var lane_frames := 0
	while lane_frames < 90:
		p.invincible = 999999
		await _frames(1)
		lane_frames += 1
	Input.action_release("move_up")
	await _frames(2)
	p.invincible = 999999
	_check(depth_start - p.depth_y > 30.0, "the player can actually walk backwards into the road band")
	_check(absf(p.depth_y - p.lane_min()) < 3.0, "the player reaches the back edge of this image's road")
	_check(main_ref.hud._bottom_layer.modulate.a > 0.95, "the bottom HUD stays fully opaque while the player is back in the road")
	if "--capture" in OS.get_cmdline_user_args():
		await _capture("16_dungeon_depth_back")
	# 再走到景深带前沿（该图路面下沿）
	p.depth_y = p.lane_max() - 60.0
	await _frames(2)
	Input.action_press("move_down")
	var front_frames := 0
	while front_frames < 90:
		p.invincible = 999999
		await _frames(1)
		front_frames += 1
	Input.action_release("move_down")
	await _frames(2)
	p.invincible = 999999
	_check(absf(p.depth_y - p.lane_max()) < 3.0, "the player can reach the front edge of this image's road")
	_check(main_ref.hud._bottom_layer.modulate.a < 0.4, "the bottom HUD fades out so the player stays visible at the road front")
	if "--capture" in OS.get_cmdline_user_args():
		await _capture("18_dungeon_depth_front")
	# 场景实体确实挡人（站到与木桩同一条景深上）
	var stump = null
	var bush = null
	for child in main_ref.room_root.get_children():
		if child is DungeonEntity and child.entity_id == "stump":
			stump = child
		if child is DungeonEntity and child.entity_id == "bush":
			bush = child
	_check(stump != null and bush != null, "entrance room places both a stump and a bush")
	var footprint_bounds := Rect2()
	var first_point := true
	for polygon in stump.footprints:
		for point in polygon:
			if first_point:
				footprint_bounds = Rect2(point, Vector2.ZERO)
				first_point = false
			else:
				footprint_bounds = footprint_bounds.expand(point)
	_check(not stump.geometry.is_empty() and not first_point and stump.collision_rect.position.distance_to(footprint_bounds.position) < 0.1 and stump.collision_rect.size.distance_to(footprint_bounds.size) < 0.1 and absf(footprint_bounds.size.x - 136.0) < 2.0 and absf(footprint_bounds.size.y - 28.0) < 2.0, "the stump collider uses its own calibrated thick root footprint, not the vertical sprite")
	_check(bush != null and not bush.collision_enabled and bush.collision_rect == Rect2(), "decorative entities carry no collision at all")
	var stump_depth: float = stump.position.y - main_ref.GROUND_Y
	var stump_bounds: Rect2 = stump.world_solid_rect()
	var player_half_depth := float(p.cfg["collision_half_depth"])
	# 1) 同一景深从左侧撞过去 -> 被挡住
	p.depth_y = stump_depth
	p.position = Vector2(stump.position.x - 180.0, main_ref.GROUND_Y)
	Input.action_press("move_right")
	var push_frames := 0
	while push_frames < 80:
		p.invincible = 999999
		await _frames(1)
		push_frames += 1
	Input.action_release("move_right")
	await _frames(2)
	p.invincible = 999999
	_check(p.position.x < stump.position.x - 30.0, "the stump blocks the player standing in the same depth lane")
	if "--capture" in OS.get_cmdline_user_args():
		await _capture("15_dungeon_entity_block")
	# 2) 站在实体前面：不受约束（不被弹开），且画在实体前面
	p.depth_y = stump_depth + 90.0
	p.position = Vector2(stump.position.x, main_ref.GROUND_Y)
	await _frames(20)
	p.invincible = 999999
	_check(absf(p.position.x - stump.position.x) < 6.0, "standing in front of the prop imposes no block")
	_check(p.z_index > stump.z_index, "feet further front means drawn on top of the prop")
	var front_slice := _nearest_entity_slice(stump, p.position.x)
	_check(front_slice != null and front_slice.visible and not front_slice.z_as_relative and p.z_index > front_slice.z_index and not stump._body.visible, "the stump's actual image slice near player x draws behind front feet without duplicate body")
	# 2b) 从实体后面真实走过去（之前报的 bug：后面被挡死）
	p.depth_y = stump_depth - 90.0
	p.position = Vector2(stump.position.x - 180.0, main_ref.GROUND_Y)
	Input.action_press("move_right")
	var back_pass := 0
	while back_pass < 90:
		p.invincible = 999999
		await _frames(1)
		back_pass += 1
	Input.action_release("move_right")
	await _frames(3)
	p.invincible = 999999
	_check(p.position.x > stump.position.x + 20.0, "the player walks past the stump from behind it")
	_check(p.z_index < stump.z_index, "feet further back means drawn behind the prop")
	var back_slice := _nearest_entity_slice(stump, p.position.x)
	_check(back_slice != null and back_slice.visible and not back_slice.z_as_relative and p.z_index < back_slice.z_index, "the stump's actual image slice near player x draws above back feet")
	# 3) 沿景深撞进去 -> 对称地停在前/后两条边界上，不会被挤歪
	p.depth_y = stump_depth + 100.0
	p.position = Vector2(stump.position.x - 10.0, main_ref.GROUND_Y)
	await _frames(2)
	var stop_x: float = p.position.x
	Input.action_press("move_up")
	var axis_frames := 0
	while axis_frames < 50:
		p.invincible = 999999
		await _frames(1)
		axis_frames += 1
	Input.action_release("move_up")
	await _frames(3)
	p.invincible = 999999
	_check(absf(p.depth_y - (stump_bounds.end.y + player_half_depth)) < 1.0, "walking into the prop along depth stops at its calibrated root front plus player half-depth")
	_check(absf(p.position.x - stop_x) < 6.0, "stopping on the depth axis does not shove the player sideways")
	p.depth_y = stump_depth - 100.0
	p.position = Vector2(stump.position.x - 10.0, main_ref.GROUND_Y)
	Input.action_press("move_down")
	var axis_back := 0
	while axis_back < 50:
		p.invincible = 999999
		await _frames(1)
		axis_back += 1
	Input.action_release("move_down")
	await _frames(3)
	p.invincible = 999999
	_check(absf(p.depth_y - (stump_bounds.position.y - player_half_depth)) < 1.0, "walking into the prop from behind stops at its calibrated root back minus player half-depth")
	# 装饰件：站在它的景深与 x 范围内也不被弹开
	p.depth_y = bush.position.y - main_ref.GROUND_Y
	p.position = Vector2(bush.position.x, main_ref.GROUND_Y)
	await _frames(20)
	p.invincible = 999999
	_check(absf(p.position.x - bush.position.x) < 6.0, "a decorative bush never blocks the player")
	var bush_slice := _nearest_entity_slice(bush, p.position.x)
	_check(bush_slice != null and bush_slice.visible and not bush_slice.z_as_relative and not bush._body.visible, "decorative bush uses actual image slices without duplicating its body")
	for offset in [-10.0, 10.0]:
		p.depth_y = bush.front_depth_at(p.position.x) + offset
		p.velocity = Vector2.ZERO
		await _frames(3)
		var slice_is_behind: bool = bush_slice != null and p.z_index > bush_slice.z_index
		_check(slice_is_behind if offset > 0.0 else bush_slice != null and p.z_index < bush_slice.z_index, "decorative bush nearest-x slice sorts across its own root front at depth " + str(offset))
		_check(absf(p.position.x - bush.position.x) < 6.0 and absf(p.depth_y - bush.front_depth_at(p.position.x) - offset) < 0.1, "decorative bush never blocks nearby root depth " + str(offset))
	# 怪物同样会被实体挡住
	p.depth_y = stump_depth
	p.position = Vector2(stump.position.x - 260.0, main_ref.GROUND_Y)
	main_ref._spawn_room_monster({"cfg": GameConfig.monsters["goblin"].duplicate(true),
		"x": stump.position.x + 240.0, "depth": stump_depth, "preset": "goblin"})
	await _frames(2)
	var chaser = main_ref.monsters[main_ref.monsters.size() - 1]
	var chase_frames := 0
	while chase_frames < 90:
		p.invincible = 999999
		await _frames(1)
		chase_frames += 1
	p.invincible = 999999
	_check(chaser.position.x > stump.position.x + 40.0, "a monster chasing the player is blocked by the stump")

	# GM 命令切房：第 2 房按配置刷 3 只普通哥布林，门保持未开启
	main_ref._on_gm_command("room", PackedStringArray(["2"]))
	await _frames(3)
	p.invincible = 999999
	_check(main_ref.dungeon.room_number() == 2 and main_ref.alive_count() == 3, "gm room command loads room 2 with three goblins")
	_check(not main_ref.room_cleared and main_ref.current_door != null and not main_ref.current_door.opened, "room 2 door stays locked while enemies live")
	_check(main_ref.battle_state == main_ref.BattleState.FIGHT, "room with enemies runs the fight state")
	if "--capture" in OS.get_cmdline_user_args():
		await _capture("11_dungeon_room2")

	# 清空本房 -> 门开启 -> 走进门切到第 3 房
	main_ref._on_gm_command("clear", PackedStringArray())
	await _frames(4)
	p.invincible = 999999
	_check(main_ref.alive_count() == 0 and main_ref.room_cleared, "gm clear wipes the room")
	_check(main_ref.current_door.opened and main_ref.battle_state == main_ref.BattleState.ROOM_CLEAR, "cleared room opens its door")
	# 真实输入走到门口。整房 2000+ px 走完会吃掉 --quit-after 预算，
	# 所以先确认夹取边界能到门，再用真实输入走最后一程并触发切房。
	# 门可能是四向中的任一方向，探针与走向都按门方向取。
	var door_side := str(main_ref.current_door.side)
	var door_pos: Vector2 = main_ref.current_door.position
	var approach := 220.0
	var probe: Vector2
	var walk_action := "move_right"
	match door_side:
		"left":
			p.depth_y = door_pos.y - main_ref.GROUND_Y
			p.position = Vector2(door_pos.x + approach, main_ref.GROUND_Y)
			probe = Vector2(p.arena_left, main_ref.GROUND_Y + p.depth_y)
			walk_action = "move_left"
		"up":
			p.depth_y = clampf(door_pos.y - main_ref.GROUND_Y + approach, main_ref.room_depth_min, main_ref.room_depth_max)
			p.position = Vector2(door_pos.x, main_ref.GROUND_Y)
			probe = Vector2(door_pos.x, main_ref.GROUND_Y + main_ref.room_depth_min)
			walk_action = "move_up"
		"down":
			p.depth_y = clampf(door_pos.y - main_ref.GROUND_Y - approach, main_ref.room_depth_min, main_ref.room_depth_max)
			p.position = Vector2(door_pos.x, main_ref.GROUND_Y)
			probe = Vector2(door_pos.x, main_ref.GROUND_Y + main_ref.room_depth_max)
			walk_action = "move_down"
		_:
			p.depth_y = door_pos.y - main_ref.GROUND_Y
			p.position = Vector2(door_pos.x - approach, main_ref.GROUND_Y)
			probe = Vector2(p.arena_right, main_ref.GROUND_Y + p.depth_y)
			walk_action = "move_right"
	_check(main_ref.current_door.contains_actor(probe), "the player's approach point reaches the %s door at its real depth" % door_side)
	await _frames(3)
	if "--capture" in OS.get_cmdline_user_args():
		await _capture("14_dungeon_door_open")
	_release_inputs()
	Input.action_press(walk_action)
	var walk_frames := 0
	while main_ref.dungeon.room_number() == 2 and walk_frames < 240:
		p.invincible = 999999
		await _frames(1)
		walk_frames += 1
	Input.action_release(walk_action)
	await _frames(2)
	p.invincible = 999999
	print("[DEMO_TEST] walk frames=%d player_x=%.0f door_x=%.0f state=%d room=%d control=%s" % [
		walk_frames, p.position.x, main_ref.current_door.position.x if main_ref.current_door != null else -1.0,
		main_ref.battle_state, main_ref.dungeon.room_number(), str(p.control_enabled)])
	_check(main_ref.dungeon.room_number() == 3 and main_ref.dungeon.module_id() == "10001-R03", "walking into the opened door advances to room 3 with real input")

	# 精英房：单只精英，血量高于普通怪
	_check(main_ref.alive_count() == 1 and float(main_ref.monsters[0].cfg.get("hp", 0)) > 200.0, "elite room spawns one stronger elite")

	# R04 竖幅房：修正地平线目标后，它的路面与景深带同样要成立
	main_ref._on_gm_command("room", PackedStringArray(["4"]))
	await _frames(3)
	p.invincible = 999999
	_check(main_ref.dungeon.module_id() == "10001-R04" and main_ref.alive_count() == 2, "portrait room 4 loads its two goblins")
	_check(main_ref.room_depth_max - main_ref.room_depth_min > 160.0, "the portrait room also gets a usable depth band")
	_check(absf((main_ref.room_depth_max - main_ref.room_depth_min) - band_room_one) > 20.0, "the portrait room's depth band differs from room 1's, so values are per image")
	_check(p.arena_left >= main_ref.room_road_left and p.arena_right <= main_ref.room_road_right, "the portrait room arena follows its own road")
	if "--capture" in OS.get_cmdline_user_args():
		await _capture("17_dungeon_room4_portrait")

	# BOSS 房：无出口门；击败 BOSS 直接结束副本并结算
	main_ref._on_gm_command("room", PackedStringArray(["5"]))
	await _frames(3)
	p.invincible = 999999
	_check(main_ref.dungeon.is_boss_room() and main_ref.current_door == null, "boss room has no exit door")
	_check(main_ref.alive_count() == 1 and str(main_ref.monsters[0].cfg.get("name", "")) == "哥布林头目", "boss room spawns the goblin chief")
	if "--capture" in OS.get_cmdline_user_args():
		await _capture("12_dungeon_boss")
	# BOSS 必须能被真实攻击打到（1500 血打满会超出 --quit-after 预算，所以只验伤害，
	# 死亡到结算的链路走下面同一条死亡处理）
	var boss = main_ref.monsters[0]
	p.invincible = 999999
	p.depth_y = boss.depth_y
	p.position = Vector2(clampf(boss.position.x - 88.0, 60.0, main_ref.room_world_width - 60.0), main_ref.GROUND_Y)
	p.facing = 1
	var boss_hp_before: float = boss.hp
	var swings := 0
	while boss.hp >= boss_hp_before and swings < 40:
		p.position = Vector2(clampf(boss.position.x - 88.0, 60.0, main_ref.room_world_width - 60.0), main_ref.GROUND_Y)
		p.buffer_action("attack")
		await _frames(3)
		p.invincible = 999999
		swings += 1
	_check(boss.hp < boss_hp_before, "the boss takes damage from real player attacks")
	main_ref._on_gm_command("clear", PackedStringArray())
	await _frames(5)
	p.invincible = 999999
	_check(main_ref.battle_state == main_ref.BattleState.VICTORY and main_ref.dungeon_finished, "defeating the boss ends the dungeon with victory")
	_check(main_ref._settlement.visible and p.control_enabled, "settlement shows and the player keeps control afterwards")
	if "--capture" in OS.get_cmdline_user_args():
		await _capture("13_dungeon_settlement")

	# BOSS 房没有出口：胜利后门保持关闭，走到门口也不能离开
	var boss_door = main_ref.retreat_door
	_check(boss_door != null and not boss_door.opened, "boss room doors stay locked after victory")
	p.depth_y = clampf(boss_door.position.y - main_ref.GROUND_Y - 200.0, main_ref.room_depth_min, main_ref.room_depth_max)
	p.position = Vector2(boss_door.position.x, main_ref.GROUND_Y)
	Input.action_press("move_down")
	await _frames(60)
	Input.action_release("move_down")
	await _frames(3)
	p.invincible = 999999
	_check(main_ref.dungeon.room_number() == 5 and main_ref.dungeon_finished, "walking into the boss room door does not leave the dungeon")

	# 结算按钮：再打一次 / 离开地下城（只给提示）
	main_ref._on_retry_dungeon()
	await _frames(3)
	p.invincible = 999999
	_check(main_ref.dungeon_mode and main_ref.dungeon.room_number() == 1 and not main_ref.dungeon_finished, "retry button restarts the dungeon at room 1")
	main_ref._on_leave_dungeon()
	_check(main_ref._toast.visible and main_ref._toast.text.contains("尚未开放"), "leave-dungeon button only shows a toast")

	# 门是双向的，但未清房间的返程门必须保持关闭；清空后才开
	main_ref._on_gm_command("room", PackedStringArray(["3"]))
	await _frames(3)
	p.invincible = 999999
	_check(main_ref.retreat_door != null and not main_ref.retreat_door.opened, "return door stays locked while enemies live")
	main_ref._on_gm_command("clear", PackedStringArray())
	await _frames(4)
	p.invincible = 999999
	_check(main_ref.retreat_door.opened, "clearing the room opens the return door")
	var back_door = main_ref.retreat_door
	p.depth_y = clampf(back_door.position.y - main_ref.GROUND_Y - 200.0, main_ref.room_depth_min, main_ref.room_depth_max)
	p.position = Vector2(back_door.position.x, main_ref.GROUND_Y)
	Input.action_press("move_down")
	var back_frames := 0
	while main_ref.dungeon.room_number() == 3 and back_frames < 120:
		p.invincible = 999999
		await _frames(1)
		back_frames += 1
	Input.action_release("move_down")
	await _frames(3)
	p.invincible = 999999
	_check(main_ref.dungeon.room_number() == 2, "walking into the return door goes back to the previous room")
	_check(main_ref.alive_count() == 3 and not main_ref.room_cleared, "the room you return to keeps its uncleared monsters")
	_check(not main_ref.retreat_door.opened, "the returned room's doors stay locked until it is cleared")

	# GM 模式命令在两个模式之间切换；未知命令不改状态
	main_ref._on_gm_command("mode", PackedStringArray(["demo"]))
	await _frames(2)
	_check(not main_ref.dungeon_mode and main_ref.battle_state == main_ref.BattleState.READY, "gm mode command returns to the legacy encounter mode")
	main_ref._on_gm_command("dungeon", PackedStringArray(["10001"]))
	await _frames(2)
	p.invincible = 999999
	_check(main_ref.dungeon_mode and main_ref.dungeon.room_number() == 1, "gm dungeon command re-enters the dungeon")
	main_ref._on_gm_command("nonsense", PackedStringArray())
	_check(main_ref.dungeon_mode and main_ref.dungeon.room_number() == 1, "unknown gm command leaves the game state untouched")

	# GM 面板本体：P 键开关、输入框聚焦时收回操作权、按钮真的派发命令
	var panel = main_ref.gm_panel
	_check(not panel.is_open(), "gm panel starts closed")
	var p_key := InputEventKey.new()
	p_key.physical_keycode = KEY_P
	p_key.keycode = KEY_P
	p_key.pressed = true
	Input.parse_input_event(p_key)
	await _frames(3)
	_check(panel.is_open(), "P key opens the gm panel")
	_check(panel.visible and panel._root.is_visible_in_tree(), "P key opens a panel whose ancestor CanvasLayer is visible")
	p_key.echo = true
	Input.parse_input_event(p_key)
	await _frames(2)
	_check(panel.is_open(), "holding P does not repeatedly toggle the panel")
	p_key.echo = false
	Input.parse_input_event(p_key)
	await _frames(3)
	_check(not panel.is_open(), "P key closes the gm panel again")
	Input.parse_input_event(p_key)
	await _frames(2)
	p.invincible = 999999
	panel._input.grab_focus()
	await _frames(3)
	_check(panel.is_typing() and not p.control_enabled, "focusing the command box takes gameplay control away")
	panel._input.text = ""
	p_key.unicode = 112
	Input.parse_input_event(p_key)
	await _frames(2)
	_check(panel.is_open() and panel._input.text == "p", "GM command editor accepts P in commands without closing")
	var close_key := InputEventKey.new()
	close_key.physical_keycode = KEY_ESCAPE
	close_key.keycode = KEY_ESCAPE
	close_key.pressed = true
	Input.parse_input_event(close_key)
	await _frames(4)
	p.invincible = 999999
	_check(not panel.is_typing() and p.control_enabled, "closing the panel gives gameplay control back")
	var first_button: Button = panel._grid.get_child(0) as Button
	_check(first_button != null and first_button.text == "选择模式", "panel exposes the extendable button grid")
	first_button.emit_signal("pressed")
	await _frames(3)
	_check(not main_ref.dungeon_mode and main_ref.battle_state == main_ref.BattleState.READY, "a panel button dispatches its command")
	panel.close()
	main_ref._job_buttons[0].grab_focus()
	Input.parse_input_event(p_key)
	await _frames(2)
	_check(panel.is_open() and panel._root.is_visible_in_tree(), "P opens GM while another GUI control has keyboard focus")
	if "--capture" in OS.get_cmdline_user_args():
		await _capture("gm_p_visible")
	panel.close()


func _capture(name_text: String) -> void:
	await RenderingServer.frame_post_draw
	var directory := ProjectSettings.globalize_path("res://../temp/demo")
	DirAccess.make_dir_recursive_absolute(directory)
	get_viewport().get_texture().get_image().save_png(directory.path_join(name_text + ".png"))
	print("[CAPTURE] " + name_text)

func _jump_height(short_press: bool) -> float:
	var target: Monster = await _fresh()
	target.position.x = 1100
	var p: Player = main_ref.player
	Input.action_press("jump")
	await _frames(2)
	if short_press:
		Input.action_release("jump")
	var highest := p.position.y
	for index in 65:
		await _frames(1)
		highest = minf(highest, p.position.y)
		if index == 30:
			Input.action_release("jump")
	return main_ref.GROUND_Y - highest

func _run_v3_checks() -> void:
	var m: Monster = await _fresh()
	var p: Player = main_ref.player
	m.position.x = 1120
	Input.action_press("move_right")
	await _frames(2)
	_check(p.velocity.x > 0 and p.velocity.x < float(p.cfg["walk_speed"]), "walk responds immediately with a brief acceleration ramp")
	await _frames(10)
	_check(p.state == Player.St.WALK and p.velocity.x >= float(p.cfg["walk_speed"]) * 0.95, "walk uses a distinct animation and reaches target speed")
	Input.action_release("move_right")
	await _frames(2)
	_check(p.velocity.x >= 0 and p.velocity.x < float(p.cfg["walk_speed"]), "release brakes movement without reversing")
	await _frames(10)
	_check(absf(p.velocity.x) < 1, "braking settles quickly with no indefinite slide")
	await _hold_double_tap("move_right")
	await _frames(14)
	_check(p.state == Player.St.RUN and p.velocity.x > 380, "double tapping transitions to run with its own gait")
	await _tap("attack")
	_check(p.move_name == "dash_attack", "running attack has a dedicated forward cut")
	Input.action_release("move_right")
	await _frames(60)
	m = await _fresh()
	m.position.x = 1120
	await _hold_double_tap("move_right")
	await _frames(12)
	Input.action_press("jump")
	await _frames(3)
	_check(p.position.y < main_ref.GROUND_Y and p.velocity.x >= 300, "running jump keeps horizontal momentum")
	_release_inputs()
	var short_height: float = await _jump_height(true)
	var full_height: float = await _jump_height(false)
	_check(short_height > 20 and full_height > short_height * 1.3, "short and held jumps have distinctly different apex heights")
	m = await _fresh()
	m.position.x = 1120
	Input.action_press("jump")
	await _frames(4)
	await _tap("attack")
	_check(p.move_name == "air_attack", "jump attack uses its own aerial action")
	await _frames(14)
	Input.action_release("jump")
	await _frames(60)
	_check(p.is_on_floor() and p.state in [Player.St.IDLE, Player.St.WALK, Player.St.RUN], "air attack settles into a playable ground state")
	m = await _fresh()
	m.position.x = 1120
	p.collision_mask = 0
	await _frames(2)
	p.buffer_action("jump")
	await _frames(2)
	_check(p.velocity.y < -300, "coyote jump produces a real rising impulse")
	p.collision_mask = 1
	m = await _fresh()
	m.position.x = 1120
	p.buffer_action("attack")
	await _frames(3)
	main_ref.bm.freeze = 12
	var old_position := p.position
	var old_clock := p.phase_t
	var old_frame := p.anim_frame
	p.buffer_action("generic_skill")
	await _frames(5)
	_check(p.position == old_position and p.phase_t == old_clock and p.anim_frame == old_frame, "hitstop freezes movement action clock and body frame")
	_check(p._has_buffer("generic_skill"), "input survives hitstop")
	main_ref.bm.clear_fx()
	m = await _fresh()
	p.invincible = 0
	Input.action_press("guard")
	await _frames(2)
	p.take_hit(100, -1)
	_check(p.state == Player.St.GUARD and is_equal_approx(p.hp, 995), "precise front guard gives its stronger mitigation")
	Input.action_release("guard")
	m = await _fresh()
	p.invincible = 0
	p.state = Player.St.GUARD
	p._guard_frames = 10
	p.take_hit(100, 1)
	_check(p.hp == 900 and p.state == Player.St.HIT, "attacks from behind bypass directional guard")
	m = await _fresh()
	m.position.x = 1120
	p._start_attack()
	await _frames(6)
	p.buffer_action("generic_skill")
	await _frames(2)
	_check(p.move_name == "attack1", "whiffed basic attacks cannot cancel at the early hit-confirm window")
	m = await _fresh()
	p._start_attack()
	await _frames(int(GameConfig.moves["attack1"]["windup"]) + 2)
	p.buffer_action("generic_skill")
	await _frames(int(GameConfig.moves["attack1"]["hit_cancel_after"]) - int(GameConfig.moves["attack1"]["windup"]) + int(GameConfig.moves["attack1"]["hitstop"]) + 2)
	_check(observed_moves.has("upper") or p.move_name == "upper", "connected basic attacks can cancel into uppercut early")
	m = await _fresh()
	var rig: WeaponRig = main_ref.weapon_rig
	rig.update_attachment()
	_check(rig.visible and bool(p.anims["idle"].get("weapon_separated", false)), "weapon is a visible independent layer on weaponless body art")
	var sockets_valid := true
	for clip in p.anims.values():
		if bool(clip.get("seq6", false)):
			# V6 是角色与剑一体的原画，本来就不该有独立武器插槽
			sockets_valid = sockets_valid and not bool(clip.get("weapon_separated", true))
			continue
		sockets_valid = sockets_valid and bool(clip.get("weapon_separated", false)) and clip.get("sockets", []).size() == int(clip["frames"])
	_check(sockets_valid, "every body frame has an authored weapon socket")
	p.position.y = main_ref.GROUND_Y - 85
	p.state = Player.St.JUMP
	await _frames(2)
	main_ref._start_demo(0)
	p.buffer_action("attack")
	await _frames(2)
	_check(p.move_name == "attack1", "immediate attack after an airborne retry stays grounded")
	m = await _fresh()
	p._start_attack()
	for _index in int(GameConfig.moves["attack1"]["windup"]) + 5:
		await _frames(1)
		if p.hit_emitted:
			break
	# V6 命中帧的表现是两层序列帧刀光 + 受击特效，不再依赖运行时刀身拖尾。
	var seq_move: String = p.move_name
	var seq_frame: int = p.anim_frame
	var seq_contact: Vector2 = p.last_contact
	_check(main_ref.bm.freeze > 0 and main_ref.seq_fx.contacts.size() >= 1, "contact frame already has real blade trail during hitstop [freeze=%d hits=%d]" % [main_ref.bm.freeze, main_ref.seq_fx.contacts.size()])
	var held_blade: Array = p.seq_blade_world()
	_check(seq_contact != Vector2.ZERO and held_blade[1].distance_to(seq_contact) < 110.0, "contact point comes from the actual blade line [pt=%s tip=%s face=%d]" % [str(seq_contact), str(held_blade[1]), p.facing])
	var stop_clock := p.phase_t
	var fx_clock: float = main_ref.seq_fx.effect_clock
	var hit_ticks: Dictionary = {}
	for node in main_ref.seq_fx._hits:
		if node.visible:
			hit_ticks[node.get_instance_id()] = float(node.get_meta("seq")["tick"])
	await _frames(1)
	var hit_advanced := false
	for node in main_ref.seq_fx._hits:
		if node.visible and hit_ticks.has(node.get_instance_id()):
			hit_advanced = hit_advanced or float(node.get_meta("seq")["tick"]) > float(hit_ticks[node.get_instance_id()])
	_check(main_ref.bm.freeze > 0 and p.phase_t == stop_clock and main_ref.seq_fx.effect_clock > fx_clock and hit_advanced, "during actual hitstop the actor stays frozen while an existing hit PNG advances")
	await _frames(3)
	var frozen: Dictionary = main_ref.seq_fx.freeze_samples[-1] if not main_ref.seq_fx.freeze_samples.is_empty() else {}
	var held: Dictionary = main_ref.seq_fx.debug_state()
	_check(not frozen.is_empty() and int(frozen["frame"]) == int(float(frozen["tick"])), "actor artwork freezes on the same tick as the action clock")
	_check(held["slash_back_visible"] and held["slash_front_visible"], "both slash layers stay on screen during hitstop")
	await _frames(14)
	var after: Dictionary = main_ref.seq_fx.debug_state()
	_check(main_ref.seq_fx.effect_clock > fx_clock + 3.0, "the independent effect clock continues after hitstop")
	main_ref.bm.clear_fx()
	main_ref.seq_fx.reset()
	m = await _fresh()
	m.position.x = p.position.x + float(p.anims["attack1"]["seq_root_dx"][-1]) + 118.0
	p._start_attack()
	var probe := ""
	for _index in 30:
		await _frames(1)
		if p.phase_t >= 8.0 and p.phase_t <= 12.0:
			var bl: Array = p.seq_blade_world()
			probe += "|t%.0f tip=%s body=%s anim=%s det=%s" % [p.phase_t, str(bl[1]), str(m.body_contains(bl[1])), m.anim_name,
				str(m.body_contains(m.position + Vector2(0, -66))) + "/" + str(m.body_contains(m.position + Vector2(0, -30))) + "/" + str(m.body_contains(m.position + Vector2(0, -120)))]
	_check(m.hp < 2000, "visible blade reach contributes to the actual melee hit region [hp=%.0f%s]" % [m.hp, probe])
	_check(p.contact_log.size() >= 1 and p.contact_log[-1]["point"].x > 0.0, "melee contact is logged from the real blade sample [n=%d]" % p.contact_log.size())
	p.contact_log.clear()
	m = await _fresh()
	var body_texture = p.anims["idle"]["tex"]
	var long_reach := rig.blade_tip_global().distance_to(rig.blade_base_global())
	_check(rig.set_profile("verification_short_blade"), "weapon profile can render an alternate geometry without body changes")
	rig.update_attachment()
	_check(rig.blade_tip_global().distance_to(rig.blade_base_global()) < long_reach - 35 and p.anims["idle"]["tex"] == body_texture, "weapon length changes independently of the same body texture")
	rig.set_profile("blacksteel")
	p.facing = -1
	rig.update_attachment()
	var left_tip := rig.blade_tip_global()
	p.facing = 1
	rig.update_attachment()
	_check(is_equal_approx(left_tip.x + rig.blade_tip_global().x, p.position.x * 2), "facing mirrors weapon and socket about the actor root")
	p._start_attack()
	var floor_clear := true
	for _index in 30:
		await _frames(1)
		floor_clear = floor_clear and rig.blade_tip_global().y <= main_ref.GROUND_Y + p.depth_y + 0.5
	_check(floor_clear, "rendered blade clears the floor through a grounded swing")
	main_ref._start_training(2)
	await _frames(5)
	_check(main_ref.training_mode and main_ref.alive_count() == 2, "training has two passive recoverable targets")
	var target: Monster = main_ref.monsters[0]
	var old_target_position := target.position
	await _frames(25)
	_check(target.position == old_target_position and target.state == Monster.St.IDLE, "training targets never patrol or attack")
	target.take_hit({"damage": 100000, "hardstun": 1, "hitstop": 0}, 1)
	_check(not target.dead and target.hp >= 1, "training targets survive lethal damage")
	await _frames(15)
	p.position.x = target.position.x - 105
	p.depth_y = target.depth_y
	p._start_attack()
	await _frames(40)
	_check(main_ref.training_damage > 0 and main_ref.hit_count > 0, "training damage and hit metrics come from actual connected attacks")
	_check(main_ref.training_chain_damage > 0, "first connected hit is retained in current chain damage")
	var before_bleed: float = main_ref.training_damage
	target.invincible = 0
	target.take_hit({"damage": 0, "bleed": {"dps": 20, "time": 1.1}, "hitstop": 0}, 1)
	await _frames(35)
	_check(main_ref.training_damage >= before_bleed + 10, "training damage and DPS include bleed ticks")
	p.mp = 0
	p.cds["quick_draw"] = 500
	await _frames(2)
	_check(p.mp == float(p.cfg["max_mp"]) and int(p.cds["quick_draw"]) == 0, "unlimited training replenishes mana and skill cooldowns")
	main_ref.training_free_skills = false
	p.mp = 90
	p.cds["quick_draw"] = 50
	await _frames(3)
	# 关了免费技能后蓝量应保持低位（自然回复只让它每天一点点回涨，不会灌满）
	_check(p.mp >= 90.0 and p.mp < 100.0 and int(p.cds["quick_draw"]) > 0, "training can preserve real mana and cooldowns")
	main_ref._reset_battle()
	await _frames(3)
	_check(main_ref.training_mode and main_ref.training_damage == 0 and main_ref.hit_count == 0 and not p.dead, "training reset clears drill metrics and action state")
	main_ref._toggle_pause()
	await _frames(2)
	_check(not p.control_enabled and get_tree().paused, "training can pause")
	main_ref._toggle_pause()
	_check(p.control_enabled and main_ref.training_mode, "training resumes its own mode")

func _run_v4_checks() -> void:
	var m: Monster = await _fresh()
	var p: Player = main_ref.player
	m.position.x = 1120
	_check(not InputMap.has_action("dash"), "Shift sprint has been removed from gameplay bindings")
	_check(is_equal_approx(float(p.cfg["attack_speed"]), 1.0), "fresh combat uses the standard attack speed attribute")
	var standard_duration: int = await _attack_duration(1.0)
	_check(standard_duration >= 29 and standard_duration <= 34, "standard first slash has a readable preparation and recovery")
	m = await _fresh()
	await _hold_double_tap("move_right")
	await _frames(10)
	await _tap("attack")
	Input.action_release("move_right")
	await _frames(18)
	await _tap("attack")
	await _frames(20)
	await _tap("attack")
	await _frames(70)
	_check(observed_moves.has("dash_attack") and observed_moves.has("attack2") and observed_moves.has("attack3"), "close running cut connects into the second and third strikes without passing through its target")
	m = await _fresh()
	m.position.x = 1120
	p._start_move("attack3")
	await _frames(4)
	await _hold_double_tap("move_right")
	_check(p.state == Player.St.ATK, "double tap does not erase heavy attack preparation")
	await _frames(40)
	_check(p.state == Player.St.RUN and p.velocity.x > 380, "double tap during an attack flows directly into a run")
	m = await _fresh()
	m.position.x = 1120
	p._start_attack()
	main_ref.bm.freeze = 12
	var frozen_x := p.position.x
	await _hold_double_tap("move_left")
	_check(is_equal_approx(p.position.x, frozen_x) and p.running, "double tap is recorded while hitstop freezes movement")
	main_ref.bm.freeze = 0
	await _frames(35)
	_check(p.state == Player.St.RUN and p.velocity.x < -380, "hitstop run request survives into the legal recovery cancel")
	Input.action_release("move_left")
	await _frames(1)
	Input.action_press("move_right")
	await _frames(5)
	_check(p.state == Player.St.RUN and p.facing == 1 and p.velocity.x > 380, "left run reverses into right run without falling back to walk")
	Input.action_release("move_right")
	await _frames(13)
	_check(not p.running and absf(p.velocity.x) < 1, "a deliberate release clears run intention and stops the actor")
	var full_height: float = await _jump_height(false)
	_check(full_height >= 165 and full_height <= 195, "held jump reaches a higher controlled apex")
	m = await _fresh()
	m.position.x = 1120
	var jump_phases: Dictionary = {}
	Input.action_press("jump")
	for index in 61:
		await _frames(1)
		jump_phases[p.anim_name] = true
	Input.action_release("jump")
	_check(jump_phases.has("jump_rise") and jump_phases.has("jump_apex") and jump_phases.has("jump_fall") and jump_phases.has("jump_land"), "jump animation follows rising apex falling and landing phases")
	_check(p.is_on_floor() and p.state == Player.St.IDLE, "holding jump never repeats the jump after landing")
	m = await _fresh()
	m.position.x = 1120
	Input.action_press("jump")
	await _frames(4)
	main_ref._toggle_pause()
	Input.action_release("jump")
	await _frames(3)
	main_ref._toggle_pause()
	await _frames(2)
	_check(p.velocity.y < 0 and p.velocity.y > -535, "releasing jump while paused still shortens the jump when combat resumes")
	m = await _fresh()
	m.position.x = 1120
	_check(p._start_move("back_dash") and int(p.cds.get("back_dash", 0)) > 0, "backjump starts a real short cooldown")
	_check(not p._start_move("back_dash"), "backjump cannot be restarted during its cooldown")
	var hop_top := 0.0
	var retreat := p.position.x
	var hop_frames: Dictionary = {}
	for index in 30:
		await _frames(1)
		hop_top = maxf(hop_top, main_ref.GROUND_Y - p.position.y)
		if p.state == Player.St.BACK_DASH:
			hop_frames[p.anim_frame] = true
	_check(hop_top >= 15 and hop_top < 55 and retreat - p.position.x >= 110 and p.is_on_floor(), "backjump completes a low retreat arc and lands cleanly")
	_check(hop_frames.size() >= 5, "backjump plays distinct preparation flight and landing poses")
	_check(p._start_move("back_dash"), "backjump cooldown expires by the next nearly seamless retreat")
	m = await _fresh()
	m.position.x = 1120
	_check(p._start_move("upper") and int(p.cds.get("upper", 0)) >= 119, "uppercut starts its two-second cooldown at release")
	await _frames(36)
	var cooldown_before := int(p.cds["upper"])
	_check(not p._start_move("upper") and int(p.cds["upper"]) == cooldown_before, "uppercut cooldown rejection preserves the current timer")
	p.buffer_action("generic_skill")
	p.buffer_action("attack")
	await _frames(2)
	_check(p.move_name == "attack1", "a cooling-down uppercut does not swallow a following attack input")
	p.cfg["attack_speed"] = 1.8
	main_ref.bm.freeze = 8
	var frozen_cd := int(p.cds["upper"])
	await _frames(4)
	_check(abs(int(p.cds["upper"]) - (frozen_cd - 4)) <= 1, "basic cooldown follows real ticks through hitstop independently of attack speed")
	main_ref.bm.clear_fx()
	await _run_v4_fx_checks()
	main_ref._start_training(2)
	await _frames(3)
	p.cds["upper"] = 60
	p.cds["back_dash"] = 15
	p.cds["quick_draw"] = 400
	await _frames(3)
	_check(int(p.cds["upper"]) > 0 and int(p.cds["back_dash"]) > 0 and int(p.cds["quick_draw"]) == 0, "unlimited training preserves basic skill cooldowns")
	main_ref._hud_cooldowns()
	_check(float(main_ref.hud._cooldowns.get(8, 0)) > 0 and float(main_ref.hud._cooldowns.get(9, 0)) > 0, "HUD exposes uppercut and backjump cooldowns")
	p.set_job(1)
	p.cds["blood_rage"] = 600
	p.set_job(2)
	main_ref._hud_cooldowns()
	_check(float(main_ref.hud._cooldowns.get(0, 0)) == 0, "changing class never overlays the old class cooldown on the new skill")
	_check(int(p.anims["idle"]["frames"]) >= 8 and int(p.anims["back_dash"]["frames"]) >= 8, "idle and backjump use expanded dedicated body frames")
	var old_limit: int = main_ref.fps_limit
	var old_vsync: bool = main_ref.vsync_enabled
	main_ref._toggle_display_settings()
	_check(main_ref._settings_card.visible and get_tree().paused and not p.control_enabled, "display settings pause combat without losing training state")
	if "--capture" in OS.get_cmdline_user_args():
		await _capture("06_display_settings")
	main_ref._fps_choice.item_selected.emit(3)
	main_ref._vsync_choice.toggled.emit(false)
	_check(main_ref.fps_limit == 120 and not main_ref.vsync_enabled and Engine.physics_ticks_per_second == 60 and is_equal_approx(Engine.time_scale, 1), "frame limit and vsync controls preserve combat simulation speed")
	main_ref._toggle_display_settings()
	_check(main_ref.training_mode and not get_tree().paused and p.control_enabled, "closing display settings resumes the same training session")
	main_ref.fps_limit = old_limit
	main_ref.vsync_enabled = old_vsync
	main_ref._apply_display_settings(false)

func _run_v4_fx_checks() -> void:
	var m: Monster = await _fresh()
	var p: Player = main_ref.player
	var ribbon: Array = main_ref.bm.blade_ribbon_points({"p0": Vector2.ZERO, "p1": Vector2(100, 0), "t": 0}, {"p0": Vector2.ZERO, "p1": Vector2(0, 100), "t": 0})
	var ribbon_middle: Vector2 = ribbon[int(ribbon.size() / 2)]["tip"]
	_check(ribbon.size() >= 19 and ribbon_middle.length() > 99 and ribbon_middle.x > 65 and ribbon_middle.y > 65, "rotating blade trail follows a rounded sweep instead of a straight chord")
	_check((ribbon[0]["tip"] as Vector2).is_equal_approx(Vector2(100, 0)) and (ribbon[-1]["tip"] as Vector2).is_equal_approx(Vector2(0, 100)), "curved trail preserves both actual blade endpoints")
	p.control_enabled = false
	var before_box := m.hurtbox()
	var before_position := m.position
	m.take_hit({"damage": 10, "hitstop": 8, "hardstun": 8, "knockback": 0}, 1)
	var impact: Dictionary = m.impact_visual_state()
	_check(float(impact["flash"]) > 0.5 and (impact["scale"] as Vector2) != Vector2.ONE and (impact["offset"] as Vector2).length() > 3, "connected hits immediately flash compress and recoil the visible body")
	_check(m.position == before_position and m.hurtbox() == before_box, "impact deformation leaves collision position and hurtbox intact")
	var particle_stats: Dictionary = main_ref.bm.native_particle_stats()
	var native_nodes := true
	for emitter in main_ref.bm._particle_emitters:
		native_nodes = native_nodes and emitter is CPUParticles2D and emitter.texture != null and emitter.amount <= 28
	_check(native_nodes and int(particle_stats["active"]) > 0, "impact produces textured native Godot particle emitters")
	var impact_age := float(impact["age"])
	await _frames(3)
	_check(bool(main_ref.bm.native_particle_stats()["all_active_frozen"]) and is_equal_approx(float(m.impact_visual_state()["age"]), impact_age), "hitstop freezes native particles and hit deformation together")
	main_ref.bm.clear_fx()
	_check(int(main_ref.bm.native_particle_stats()["active"]) == 0, "reset clears every native particle burst")
	await _frames(6)
	_check(float(m.impact_visual_state()["age"]) > impact_age, "impact deformation resumes decay when hitstop ends")
	for index in 60:
		main_ref.bm.burst_particles(Vector2(640, 400), "steel", Vector2.RIGHT, 28, 0.25, 140, Color.WHITE, 1)
	particle_stats = main_ref.bm.native_particle_stats()
	_check(int(particle_stats["emitters"]) <= 20 and int(particle_stats["particle_capacity"]) <= 560, "repeated native bursts stay inside a fixed emitter and particle budget")
	main_ref.bm.clear_fx()
	m = await _fresh(1)
	var before_bursts: int = main_ref.bm.native_particle_stats()["bursts"]
	p._try_skill_action("skill_a")
	await _frames(20)
	_check(int(main_ref.bm.native_particle_stats()["bursts"]) > before_bursts + 1 and int(main_ref.bm.native_particle_stats()["active"]) > 0, "blood rage feeds a persistent live ember particle effect")
	main_ref.bm.clear_fx()

func _run_v6_checks() -> void:
	## V6 接入验收：帧表、一体原画、刀光锚点、停帧只停一次、真实接触点、地裂与拔刀一闪。
	var p: Player = main_ref.player
	var seq: SeqFX = main_ref.seq_fx
	var seq_lib = load("res://scripts/seq_lib.gd")
	var manifest: Dictionary = seq_lib.moves()
	_check(seq_lib.clip_names().size() == 21 and not bool(seq_lib.hitstop_baked()), "V6 manifest exposes 21 clips with no baked hit-stop")
	_check(manifest.size() == 4 and p.seq_clips.size() == 21, "authored V6 move parameters and clips load for four moves")
	var lengths := {"attack1": 30, "attack2": 32, "attack3": 41, "quick_draw": 36}
	var timeline_ok := true
	var seq_integrated := 0
	for move in lengths:
		var clip: Dictionary = p.anims.get(move, {})
		if not bool(clip.get("seq6", false)):
			seq_integrated -= 1
			continue
		seq_integrated += 1
		timeline_ok = timeline_ok and int(clip["frames"]) == int(lengths[move])
		timeline_ok = timeline_ok and clip["seq_spans"].size() == int(lengths[move])
		timeline_ok = timeline_ok and clip["seq_blade"].size() == int(lengths[move]) * 2
		timeline_ok = timeline_ok and clip["durations"].size() == int(lengths[move])
		timeline_ok = timeline_ok and int(p.seq_clips["actor/%s" % move]["length_ticks"]) == int(lengths[move])
		timeline_ok = timeline_ok and not bool(clip["weapon_separated"])
	_check(timeline_ok and seq_integrated == 4, "four authored moves play integer tick timelines instead of PNG indices")
	# 每个 tick 一张独立 PNG：UV 必须取整张图，帧条式 src_rect 会让角色整段消失
	var uv_ok := true
	for name in main_ref.seq_fx.clips:
		var seq_clip: Dictionary = main_ref.seq_fx.clips[name]
		for index in range(0, seq_clip["textures"].size(), 7):
			var tex: Texture2D = seq_clip["textures"][index]
			uv_ok = uv_ok and int(tex.get_width()) == int(seq_clip["frame_w"]) and int(tex.get_height()) == int(seq_clip["frame_h"])
	_check(uv_ok, "every authored tick texture matches its canvas so full-image UV sampling is valid")
	# manifest 逐 tick 转成 SpriteFrames：每个 tick 一格，作者写的整数时长保留
	var frames_clip: Dictionary = p.seq_clips["actor/attack3"]
	var sprite_frames: SpriteFrames = seq_lib.sprite_frames(frames_clip, "attack3")
	var named: PackedStringArray = sprite_frames.get_animation_names()
	var tick_frames := 0
	if named.size() > 0:
		tick_frames = sprite_frames.get_frame_count(named[0])
	var duration_total := 0.0
	for index in tick_frames:
		duration_total += sprite_frames.get_frame_duration(named[0], index)
	_check(named.size() == 1 and named[0] == "attack3" and tick_frames == 41 and is_equal_approx(duration_total, 41.0), "manifest converts to SpriteFrames without losing authored integer tick durations")
	# 逐帧抓取：帧序就是相位刻度，1.0x 攻速下与美术预览逐 tick 对齐
	await _fresh()
	var p_v6: Player = p
	var frame_ok := true
	for tick in [0, 7, 8, 9, 12, 21, 29]:
		p_v6._start_move("attack1")
		p_v6.phase_t = float(tick)
		p_v6.anim_name = "attack1"
		p_v6._anim_step()
		frame_ok = frame_ok and p_v6.anim_frame == tick
	_check(frame_ok, "every authored tick maps to its own frame during a swing")
	var m: Monster = await _fresh()
	p_v6.position.x = m.position.x - 128.0
	var log_before: int = p_v6.contact_log.size()
	var samples_before: int = main_ref.seq_fx.freeze_samples.size()
	p_v6._start_attack()
	await _frames(40)
	_check(p_v6.contact_log.size() == log_before + 1 and observed_moves.has("attack1"), "manifest spacing lands exactly one authentic blade contact")
	var contact_tick := float(p_v6.contact_log[-1]["tick"]) if p_v6.contact_log.size() > log_before else -1.0
	_check(contact_tick >= 8.0 and contact_tick < 12.0, "contact lands inside the authored active window, not at a forced reference tick")
	var launch_sample: Dictionary = main_ref.seq_fx.freeze_samples[-1] if main_ref.seq_fx.freeze_samples.size() > samples_before else {}
	_check(int(launch_sample.get("hitstop", -1)) == int(manifest["attack1"]["hitstop"]), "the recorded freeze uses the authored hit-stop length")
	_check(p_v6.hit_targets.size() == 1, "one target is hit once per swing segment")
	# 接触点必须落在命中当帧目标可见身体上，而不是被挪到胸口或脚底
	var record: Dictionary = p_v6.contact_log[-1] if p_v6.contact_log.size() > log_before else {}
	var contact: Vector2 = record.get("point", Vector2.ZERO)
	var pose: Dictionary = record.get("target", {})
	_check(m.body_contains_at(contact, str(pose.get("anim", "idle")), int(pose.get("frame", 0))), "impact point registers on the target's own painted body silhouette")
	# 可见刀刃能扫到伸出 hurtbox 的头与手臂，接触点必须落在刃线上并紧贴判定区
	var sample_tip: Vector2 = launch_sample.get("blade", Vector2.ZERO) if launch_sample.get("blade", Vector2.ZERO) is Vector2 else Vector2.ZERO
	_check(launch_sample.is_empty() or contact.distance_to(sample_tip) < 120.0, "impact point sits on the recorded blade line")
	_check(_rect_gap(m.hurtbox(), contact) <= 24.0, "impact point stays on the target's hurt region or the body that overlaps it")
	# 停帧只停一次：actor 与两层刀光共享动作时钟，特效走自己的时钟
	m = await _fresh()
	var stop_p: Player = p
	m.position.x = stop_p.position.x + 118.0
	var hitstops_before: int = main_ref.bm.hitstops
	var effects_before: float = main_ref.seq_fx.effect_clock
	var grounds_before_stop: int = main_ref.seq_fx.ground_events.size()
	var freeze_before: int = main_ref.seq_fx.freeze_samples.size()
	stop_p._start_attack()
	var froze := false
	for _index in 20:
		await _frames(1)
		if main_ref.bm.freeze > 0:
			froze = true
			break
	var sample: Dictionary = main_ref.seq_fx.freeze_samples[-1] if main_ref.seq_fx.freeze_samples.size() > freeze_before else {}
	# 停帧期间动作时钟与演员贴图必须一起冻住，特效走自己的时钟
	var effect_tick_before: float = main_ref.seq_fx.effect_clock
	while main_ref.bm.freeze > 0:
		await _frames(1)
	await _frames(2)
	_check(froze and main_ref.bm.hitstops == hitstops_before + 1, "a V6 connect freezes exactly once")
	_check(not sample.is_empty() and int(sample["frame"]) == int(float(sample["tick"])), "the action clock and sequence frame are frozen on the contact tick")
	_check(main_ref.seq_fx.effect_clock > effect_tick_before and main_ref.seq_fx.effect_clock > effects_before, "V6 hit effects keep playing on their own clock")
	await _frames(24)
	# 参考前冲：节点必须按 manifest 的 root_dx 真实前进，否则贴图/刀光/接触特效会整体偏离实际位置
	m = await _fresh()
	var slash_p: Player = p
	m.position.x = 1180
	slash_p.position.x = 400.0
	slash_p._start_attack()
	await _frames(10)
	var start_origin: Vector2 = main_ref.seq_fx.slash_origin
	var travel_seen := 0.0
	var aligned := true
	var worst := 0.0
	var worst_detail := ""
	while true:
		await _frames(1)
		# 招式结束时 anim_name 已切回 idle，必须先判结束再读参考曲线
		if not slash_p.seq_active():
			break
		travel_seen = maxf(travel_seen, absf(slash_p.position.x - 400.0))
		# 贴图偏移必须等于节点已走的参考位移：视觉 root 与物理 root 重合
		var reference := slash_p.seq_root_offset()
		var gap := absf(absf(slash_p.position.x - 400.0) - reference)
		if gap > worst:
			worst = gap
			worst_detail = "tick=%.1f node=%.2f ref=%.2f" % [slash_p.phase_t, slash_p.position.x - 400.0, reference]
		aligned = aligned and gap <= 0.51
	_check(aligned, "sprite travel and node travel use the same reference curve every tick [worst=%.2f %s]" % [worst, worst_detail])
	_check(travel_seen >= 10.0, "authored forward travel actually moves the actor root")
	_check(main_ref.seq_fx.slash_origin == start_origin, "slash layers stay anchored to the move start root")
	# 拔刀斩的前冲量级最大，单独确认节点真的走满了参考位移
	await _fresh(2)
	var dash_p: Player = p
	main_ref.monsters[0].position.x = 1180
	dash_p.position.x = 400.0
	dash_p.mp = 300.0
	dash_p.cds.clear()
	dash_p._try_skill_action("skill_a")
	var dash_seen := 0.0
	while true:
		await _frames(1)
		if not dash_p.seq_active():
			break
		dash_seen = maxf(dash_seen, absf(dash_p.position.x - 400.0))
	_check(dash_seen >= float(dash_p.anims["quick_draw"]["seq_root_dx"][-1]) - 1.0, "the quick-draw dash covers its authored 104 px reference")
	# 重劈：地裂只在可见刀尖真正落地时触发一次
	m = await _fresh()
	var ground_p: Player = p
	m.position.x = ground_p.position.x + 120.0
	ground_p.position.x = 300.0
	var grounds_before: int = main_ref.seq_fx.ground_events.size()
	ground_p._start_move("attack3")
	var ground_probe: Array = []
	for _index in 60:
		await _frames(1)
		if ground_p.move_name == "attack3" and ground_p.phase_t >= 10.0 and ground_p.phase_t <= 15.0:
			var params: Dictionary = ground_p._seq_move_data()
			var tip: Vector2 = ground_p.seq_blade_world()[1]
			ground_probe.append({"tick": ground_p.phase_t, "root": [ground_p.position.x, ground_p.position.y],
				"tip": [tip.x, tip.y], "floor": ground_p.ground_y + ground_p.depth_y,
				"ground_flag": params.get("ground", null), "ground_tick": params.get("ground_tick", null),
				"reached": ground_p._seq_ground_reached(), "emitted": ground_p._seq_ground_done,
				"event_count": main_ref.seq_fx.ground_events.size()})
	var ground_events: Array = main_ref.seq_fx.ground_events
	var ground_event_ticks: Array = []
	for entry in ground_events:
		ground_event_ticks.append(entry["tick"])
	if ground_events.size() != grounds_before + 1:
		print("[DEMO_TEST] ground diagnostic " + JSON.stringify({"before": grounds_before, "after": ground_events.size(),
			"event_ticks": ground_event_ticks, "final_move": ground_p.move_name, "final_phase": ground_p.phase_t,
			"samples": ground_probe}))
	_check(ground_events.size() == grounds_before + 1, "the heavy chop cracks the ground exactly once [before=%d after=%d ticks=%s]" % [grounds_before, ground_events.size(), str(ground_event_ticks)])
	if ground_events.size() > grounds_before:
		var ground_point: Vector2 = ground_events[-1]["point"]
		_check(absf(ground_point.y - (main_ref.GROUND_Y + ground_p.depth_y)) <= 3.5, "ground crack anchors at the visible blade tip's landing coordinate")
		var ground_tick: float = float(ground_events[-1]["tick"])
		var ground_clip: Dictionary = ground_p.seq_clips["actor/attack3"]
		var ground_index: int = seq_lib.tick_index(ground_clip, ground_tick)
		var expected_tip := Vector2(300.0 + float(ground_clip["root_dx"][ground_index]), main_ref.GROUND_Y + ground_p.depth_y) + (seq_lib.blade_local(ground_clip, ground_tick)[1] as Vector2)
		var expected_landing := Vector2(expected_tip.x, main_ref.GROUND_Y + ground_p.depth_y)
		_check(ground_point.distance_to(expected_landing) < 0.01, "ground crack uses the painted tip x projected onto the actual ground plane")
	# 拔刀斩：独立一闪 + 短暂压暗，长线挂接触点
	m = await _fresh(2)
	var iai_p: Player = p
	m.position.x = iai_p.position.x + 205.0
	iai_p.mp = 300.0
	var flash_before: int = main_ref.seq_fx.dims.size()
	var contacts_before: int = main_ref.seq_fx.contacts.size()
	var flashes_before: int = main_ref.seq_fx._flashes.size()
	var freeze_before_iai: int = main_ref.seq_fx.freeze_samples.size()
	_check(iai_p._try_skill_action("skill_a"), "quick draw casts with the authored charge window")
	var dim_seen := 0.0
	var peak_alpha := 0.0
	for _index in 30:
		await _frames(1)
		peak_alpha = maxf(peak_alpha, float(main_ref.seq_fx.debug_state()["dim_alpha"]))
		if main_ref.seq_fx.contacts.size() > contacts_before:
			dim_seen = float(main_ref.seq_fx.debug_state()["dim_left"])
			break
	# 接触点由战斗碰撞给出，一闪与压暗必须在同一物理帧内挂上
	var iai_freeze: Dictionary = main_ref.seq_fx.freeze_samples[-1] if main_ref.seq_fx.freeze_samples.size() > freeze_before_iai else {}
	var iai_point: Vector2 = iai_freeze.get("point", Vector2.ZERO)
	var flash_at: Vector2 = iai_freeze.get("flash", Vector2.INF)
	var dim_at_hit: float = float(iai_freeze.get("dim_alpha", 0.0))
	var flash_node: Sprite2D = main_ref.seq_fx.last_flash
	var iai_events: int = main_ref.seq_fx.dims.size()
	_check(main_ref.seq_fx.contacts.size() == contacts_before + 1 and int(iai_freeze.get("hitstop", -1)) == int(manifest["quick_draw"]["hitstop"]), "iai contact uses the authored hit-stop and lands once")
	_check(flash_node != null and flash_at == iai_point and str(main_ref.seq_fx.last_kind) == "iai", "the long streak is attached to the real contact point [node=%s at=%s pt=%s]" % ["null" if flash_node == null else str(flash_node.position), str(flash_at), str(iai_point)])
	_check(iai_events == flash_before + 1 and dim_at_hit > 0.0 and peak_alpha > 0.0, "iai contact dims the world and releases it on its own clock [ev=%d/%d at=%.2f peak=%.2f]" % [iai_events, flash_before, dim_at_hit, peak_alpha])
	if flash_node != null:
		_check(int(flash_node.texture.get_width()) == 960 and absf(flash_node.offset.x) <= 480.0, "the streak keeps its full canvas width instead of being cropped")
	_check(bool(main_ref.seq_fx.config.get("iai", {}).get("no_bloom", false)), "iai presentation adds no extra bloom")
	# 左右朝向翻转：整套图像与锚点一起镜像
	m = await _fresh()
	var flip_p: Player = p
	m.position.x = 1180
	flip_p.position.x = 500.0
	var right_blade: Array = _blade_at(flip_p, "attack1", 9.0, 1)
	var left_blade: Array = _blade_at(flip_p, "attack1", 9.0, -1)
	_check(is_equal_approx(right_blade[1].x + left_blade[1].x, flip_p.position.x * 2.0), "facing mirrors the authored blade line about the actor root")
	flip_p.facing = -1
	main_ref.seq_fx._seq_apply(main_ref.seq_fx._slash_front, main_ref.seq_fx.clips["slash_front/attack1"], 9.0, true)
	var slash_clip: Dictionary = main_ref.seq_fx.clips["slash_front/attack1"]
	_check(main_ref.seq_fx._slash_front.flip_h and is_equal_approx(main_ref.seq_fx._slash_front.offset.x, -(float(slash_clip["frame_w"]) - float(slash_clip["anchor"].x))), "left facing mirrors non-centred artwork with width - anchor.x")
	# 序列帧自带火花与刀光，不能再叠一份程序化拖尾/粒子
	m = await _fresh()
	var fx_p: Player = p
	m.position.x = fx_p.position.x + 118.0
	var bursts_before: int = int(main_ref.bm.native_particle_stats()["bursts"])
	var trails_before: int = main_ref.bm._trails.size()
	fx_p._start_attack()
	await _frames(30)
	_check(main_ref.bm._trails.size() == trails_before and int(main_ref.bm.native_particle_stats()["bursts"]) == bursts_before, "authored V6 clips are not duplicated by procedural trails or particles [trails=%d/%d bursts=%d/%d]" % [main_ref.bm._trails.size(), trails_before, int(main_ref.bm.native_particle_stats()["bursts"]), bursts_before])
	# 一体原画：这四招期间旧武器层必须完全停用，回归时也要还原
	var rig: WeaponRig = main_ref.weapon_rig
	m = await _fresh()
	var w_p: Player = p
	m.position.x = 1180
	w_p._start_attack()
	await _frames(10)
	rig.update_attachment()
	_check(not rig.visible and w_p.move_name == "attack1", "the four authored moves never attach a second runtime blade")
	await _frames(24)
	rig.update_attachment()
	_check(rig.visible, "the independent weapon layer returns for moves that still need it")
	main_ref._start_training(2)
	await _frames(4)
	_check(main_ref.weapon_rig.visible and bool(w_p.anims["idle"].get("weapon_separated", false)), "idle still renders the independent weapon after V6 moves")
	await _run_v6_freeze_checks()
	await _run_v6_geometry_checks()
	main_ref.bm.clear_fx()
	main_ref.seq_fx.reset()


func _measure_v6_swing(move: String, connect: bool) -> Dictionary:
	var target: Monster = await _fresh(2)
	var p: Player = main_ref.player
	var seq: SeqFX = main_ref.seq_fx
	p.position.x = 500.0
	p.facing = 1
	p.cfg["attack_speed"] = 1.0
	target.position.x = p.position.x + (205.0 if move == "quick_draw" else 120.0) if connect else 1180.0
	main_ref.monsters[1].position.x = 1180.0
	var contacts_before := seq.contacts.size()
	var hitstops_before: int = main_ref.bm.hitstops
	_start_v6_move(p, move)
	var elapsed := 0
	var contact_tick := -1.0
	var held_pose_samples := 0
	var contact_freeze := -1
	var freeze_trace: Array = []
	while p.move_name == move and elapsed < 150:
		await _frames(1)
		elapsed += 1
		if seq.contacts.size() > contacts_before and contact_tick < 0.0:
			contact_tick = p.phase_t
			contact_freeze = int(main_ref.bm.freeze)
		if contact_tick >= 0.0 and p.move_name == move and p.phase_t == contact_tick:
			held_pose_samples += 1
			freeze_trace.append(int(main_ref.bm.freeze))
	return {"frames": elapsed, "contacts": seq.contacts.size() - contacts_before,
		"hitstops": main_ref.bm.hitstops - hitstops_before, "contact_tick": contact_tick,
		"held_pose_samples": held_pose_samples, "contact_freeze": contact_freeze, "trace": freeze_trace}


func _run_v6_freeze_checks() -> void:
	var manifest: Dictionary = main_ref.seq_fx.moves
	for move in ["attack1", "attack2", "attack3", "quick_draw"]:
		var whiff: Dictionary = await _measure_v6_swing(move, false)
		var hit: Dictionary = await _measure_v6_swing(move, true)
		var expected := int(manifest[move]["hitstop"])
		var detail := "%s source_stop=%d hold=%d freeze=%d extra=%d trace=%s" % [move, expected,
			int(hit["held_pose_samples"]), int(hit["contact_freeze"]), int(hit["frames"]) - int(whiff["frames"]), str(hit["trace"])]
		# preview_v6.py 先绘制 contact，再扣 N 次 freeze 而不推进 clock。
		# 因而含原接触帧共显示 N+1 帧，命中总时长必须比挥空恰好多 N 帧；
		# tools/test_seq_v6.py 也明确断言该差值。实机调度补偿不能改变资源里的 N。
		_check(int(hit["contacts"]) == 1 and int(hit["hitstops"]) == 1 and int(whiff["contacts"]) == 0
			and int(hit["held_pose_samples"]) == expected + 1, "actual contact pose repeats for the same real-frame count as the approved preview [" + detail + "]")
		_check(int(hit["frames"]) - int(whiff["frames"]) == expected,
			"the real connected action adds exactly the manifest stop ticks over a whiff [" + detail + "]")


func _run_v6_freeze_only() -> void:
	main_ref = get_parent()
	await _frames(3)
	main_ref.bm._audio.enabled = false
	await _run_v6_freeze_checks()
	print("[DEMO_TEST] FREEZE COMPLETE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(0 if failures == 0 else 1)


## Gameplay feedback checks use actual direction/attack/jump edges and observed
## action signals. They guard against passing state-only tests with frozen poses,
## attacks queued into a later landing, or a retreat delayed until the full move.
func _run_movement_feedback_only() -> void:
	main_ref = get_parent()
	await _frames(3)
	await _run_movement_feedback_checks()
	_release_inputs()
	print("[DEMO_TEST] COMPLETE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(0 if failures == 0 else 1)


func _feedback_jump_attacks(extra: int = 0, active_bonus := false) -> Dictionary:
	var target: Monster = await _fresh()
	target.position.x = 1120
	var p: Player = main_ref.player
	p.buff_data = {"extra_air_attacks": extra}
	p.buff_t = 2.0 if active_bonus else 0.0
	_feedback_actions.clear()
	Input.action_press("jump")
	await _frames(4)
	var maximum := 0
	var landed := false
	for tick in 80:
		if tick % 4 == 0:
			Input.action_press("attack")
		elif tick % 4 == 2:
			Input.action_release("attack")
		await _frames(1)
		maximum = maxi(maximum, p.air_attack_count)
		if p.is_on_floor() and p.velocity.y >= 0.0:
			landed = true
			break
	_release_inputs()
	await _frames(9)
	return {"air": _feedback_actions.count("air_attack"), "ground": _feedback_actions.count("attack1"),
		"maximum": maximum, "landed": landed, "count_after_landing": p.air_attack_count}


func _feedback_backhop(move: String, connect: bool, attack_speed := 1.0, press_during_hitstop := false) -> Dictionary:
	var target: Monster = await _fresh(2 if move == "quick_draw" else 0)
	var p: Player = main_ref.player
	target.position.x = 620 if connect else 1120
	if move == "quick_draw" and connect:
		p.position.x = target.position.x - 205.0
	p.cfg["attack_speed"] = attack_speed
	_start_v6_move(p, move)
	if press_during_hitstop:
		for tick in 55:
			await _frames(1)
			if p.hit_emitted and main_ref.bm.freeze > 0:
				break
	else:
		await _frames(2)
	var request_tick := p.phase_t
	var clock_before_freeze := p.phase_t
	Input.action_press("move_down")
	Input.action_press("jump")
	await _frames(2)
	var early_preserved := p.move_name == move
	var frozen_preserved := p.phase_t == clock_before_freeze and p._has_buffer("back_dash")
	Input.action_release("jump")
	Input.action_release("move_down")
	var previous_clock := p.phase_t
	var final_clock := -1.0
	var connected := p.hit_emitted
	var saw_idle := false
	var stopped_after_active := false
	var prior_data := p.move_data.duplicate(true)
	for tick in 100:
		await _frames(1)
		if p.move_name == "back_dash":
			final_clock = previous_clock
			stopped_after_active = previous_clock + p.move_scale >= float(prior_data.get("windup", prior_data.get("charge", 0))) + float(prior_data.get("active", 0))
			break
		saw_idle = saw_idle or p.state == Player.St.IDLE
		connected = connected or p.hit_emitted
		previous_clock = p.phase_t
	_release_inputs()
	return {"started": p.move_name == "back_dash", "connected": connected, "request_tick": request_tick,
		"cancel_tick": final_clock, "early_preserved": early_preserved, "frozen_preserved": frozen_preserved,
		"saw_idle": saw_idle, "after_active": stopped_after_active}


## 原版 DNF 手感：起跳后仍可自由加速、转向并保留惯性。用真实 Input 边沿与
## 完整游戏流程验证空中机动，防止又退回“起跳即锁方向”的弱手感。
func _feedback_air_steer(from_run: bool) -> Dictionary:
	var target: Monster = await _fresh()
	target.position.x = 1120
	var p: Player = main_ref.player
	if from_run:
		await _hold_double_tap("move_right")
		await _frames(6)
	Input.action_press("jump")
	await _frames(4)
	var cap := float(p.cfg["air_run_speed"] if from_run else p.cfg["air_walk_speed"])
	Input.action_press("move_right")
	var accel_ticks := 0
	while p.velocity.x < cap * 0.9 and accel_ticks < 12:
		await _frames(1)
		accel_ticks += 1
	var accelerated := p.velocity.x >= cap * 0.9
	Input.action_release("move_right")
	Input.action_press("move_left")
	var reverse_ticks := 0
	while p.velocity.x > -cap * 0.9 and reverse_ticks < 16 and not p.is_on_floor():
		await _frames(1)
		reverse_ticks += 1
	var reversed := p.velocity.x <= -cap * 0.9
	Input.action_release("move_left")
	var glide_speed := p.velocity.x
	var glide_ticks := 0
	while not p.is_on_floor() and glide_ticks < 6:
		await _frames(1)
		glide_ticks += 1
	var glide := absf(p.velocity.x) >= absf(glide_speed) * 0.55
	var landed := false
	for _tick in 60:
		if p.is_on_floor() and p.velocity.y >= 0.0:
			landed = true
			break
		await _frames(1)
	var landed_ok := landed
	if landed:
		await _frames(8)
		landed_ok = p.is_on_floor() and p.state in [Player.St.IDLE, Player.St.WALK, Player.St.RUN]
	_release_inputs()
	return {"accelerated": accelerated, "accel_ticks": accel_ticks, "reversed": reversed,
		"reverse_ticks": reverse_ticks, "glide": glide, "landed_ok": landed_ok}


func _run_movement_feedback_checks() -> void:
	var p: Player = main_ref.player
	if not p.action_started.is_connected(_observe_feedback_action):
		p.action_started.connect(_observe_feedback_action)
	for direction in ["move_up", "move_down"]:
		var target: Monster = await _fresh()
		target.position.x = 1120
		var upper := float(p.cfg["lane_min"])
		var lower := float(p.cfg["lane_max"])
		p.depth_y = lower if direction == "move_up" else upper
		p.facing = -1 if direction == "move_up" else 1
		var initial_facing := p.facing
		var initial_x := p.position.x
		var destination := upper if direction == "move_up" else lower
		var walking_frames: Dictionary = {}
		var animated_while_moving := true
		var travel_ticks := 0
		Input.action_press(direction)
		while not is_equal_approx(p.depth_y, destination) and travel_ticks < 60:
			var previous_depth := p.depth_y
			await _frames(1)
			travel_ticks += 1
			if p.depth_y != previous_depth:
				animated_while_moving = animated_while_moving and p.state == Player.St.WALK and p.anim_name == "walk"
				walking_frames[p.anim_frame] = true
		_check(animated_while_moving and walking_frames.size() >= 3, direction + " alone advances multiple walk poses instead of sliding in idle")
		_check(p.facing == initial_facing and is_equal_approx(p.position.x, initial_x), direction + " preserves horizontal facing and does not drift sideways")
		_check(is_equal_approx(p.depth_y, destination) and travel_ticks <= 33, direction + " crosses the full 64px lane faster than the former 100px/s movement")
		await _frames(4)
		_check(p.state == Player.St.IDLE and p.anim_name == "idle", direction + " stops the walk gait at the lane boundary even while the key stays held")
		_release_inputs()
		await _frames(10)
	var target: Monster = await _fresh()
	target.position.x = 1120
	Input.action_press("move_right")
	Input.action_press("move_up")
	await _frames(7)
	_check(p.state == Player.St.WALK and p.velocity.x > 200 and p.depth_y < -8, "diagonal movement combines the established horizontal gait with faster lane travel")
	_release_inputs()
	await _frames(12)
	_check(p.state == Player.St.IDLE and absf(p.velocity.x) < 1, "releasing diagonal movement settles into idle promptly")
	var ordinary: Dictionary = await _feedback_jump_attacks()
	_check(ordinary["air"] == 1 and ordinary["maximum"] == 1, "repeated attack edges launch only one ordinary air slash per default jump")
	_check(ordinary["landed"] and ordinary["count_after_landing"] == 0, "landing restores the ordinary aerial attack allowance")
	_check(ordinary["ground"] == 0, "rejected extra aerial attacks do not leak into a ground slash after landing")
	_feedback_actions.clear()
	Input.action_press("jump")
	await _frames(4)
	await _tap("attack")
	_check(_feedback_actions.count("air_attack") == 1, "a subsequent real jump can attack again after the previous landing")
	_release_inputs()
	var bonus: Dictionary = await _feedback_jump_attacks(1, true)
	_check(bonus["air"] == 2 and bonus["maximum"] == 2 and bonus["ground"] == 0, "an explicit active skill bonus grants exactly one additional aerial attack")
	var inactive: Dictionary = await _feedback_jump_attacks(3, false)
	_check(inactive["air"] == 1, "inactive or expired skill bonus data does not increase aerial attack allowance")
	var negative: Dictionary = await _feedback_jump_attacks(-2, true)
	_check(negative["air"] == 1, "invalid negative skill bonus cannot remove the default single aerial attack")
	target = await _fresh(1)
	target.position.x = 1120
	_feedback_actions.clear()
	Input.action_press("jump")
	await _frames(4)
	await _tap("attack")
	await _frames(19)
	await _tap("skill_a")
	await _tap("attack")
	_check(_feedback_actions.has("blood_rage") and _feedback_actions.count("air_attack") == 1 and p.buff_t > 0, "a permitted airborne skill remains usable after the ordinary slash without silently granting extra slashes")
	_release_inputs()
	for move: String in ["attack1", "attack2", "attack3", "quick_draw"]:
		for connect: bool in [false, true]:
			var retreat: Dictionary = await _feedback_backhop(move, connect)
			var context := move + (" hit" if connect else " whiff")
			_check(retreat["connected"] == connect, context + " retreat test exercised its real contact condition")
			_check(retreat["started"] and retreat["early_preserved"] and not retreat["saw_idle"] and retreat["after_active"], context + " preserves early Down+C and enters backhop directly after the active swing")
			var earliest: float = float({"attack1": 16, "attack2": 16, "attack3": 21, "quick_draw": 25}[move]) + float(0 if connect else 2)
			_check(retreat["cancel_tick"] >= float(earliest) - 1.0 and retreat["cancel_tick"] <= float(earliest) + 1.0, context + " retreats in the first approved safe recovery window")
	var slow: Dictionary = await _feedback_backhop("attack3", false, 0.5)
	_check(slow["started"] and slow["cancel_tick"] >= 22 and slow["cancel_tick"] <= 23, "early backhop request survives a slow heavy swing beyond the ordinary fixed input lifetime")
	var frozen: Dictionary = await _feedback_backhop("attack3", true, 1.0, true)
	_check(frozen["frozen_preserved"] and frozen["started"] and not frozen["saw_idle"], "real heavy-hit stop preserves Down+C and resumes straight into a legal backhop")
	target = await _fresh()
	target.position.x = 1120
	_feedback_actions.clear()
	p._start_move("attack3")
	await _frames(2)
	await _tap("jump")
	await _frames(55)
	_check(not _feedback_actions.has("jump") and not _feedback_actions.has("back_dash"), "an early plain jump keeps its short buffer and is not reinterpreted as a retreat")
	target = await _fresh()
	p._start_move("upper")
	for tick in 25:
		await _frames(1)
		if p.upper_connected and p.phase_t >= 9:
			break
	_feedback_actions.clear()
	await _tap("jump")
	await _frames(6)
	_check(_feedback_actions.has("jump") and not _feedback_actions.has("back_dash") and p.position.y < main_ref.GROUND_Y, "connected uppercut still accepts a plain jump for its aerial follow-up")
	_release_inputs()
	# 空中机动：起跳后按方向应能快速加速、反向与保留惯性（原版 DNF 手感）。
	var steer: Dictionary = await _feedback_air_steer(false)
	_check(steer["accelerated"] and steer["accel_ticks"] <= 6, "a standing jump accelerates sideways to air speed within a few ticks")
	_check(steer["reversed"] and steer["reverse_ticks"] <= 8, "mid-air reversal completes in about an eighth of a second")
	_check(steer["glide"], "releasing the stick in mid-air keeps the jump's horizontal momentum")
	_check(steer["landed_ok"], "landing returns to grounded movement without a stuck drift")
	var run_steer: Dictionary = await _feedback_air_steer(true)
	_check(run_steer["accelerated"] and run_steer["reversed"] and run_steer["reverse_ticks"] <= 9, "a sprint jump keeps its speed and still reverses cleanly before landing")
	target = await _fresh()
	target.position.x = 1120
	Input.action_press("jump")
	await _frames(4)
	var air_lane_start := p.depth_y
	Input.action_press("move_up")
	await _frames(8)
	_check(p.depth_y <= air_lane_start - 8.0, "jump air lane movement still adjusts depth like on the ground")
	_release_inputs()


func _feedback_capture_pose(name_text: String) -> void:
	get_tree().paused = true
	await _capture(name_text)
	get_tree().paused = false


func _run_movement_feedback_capture() -> void:
	main_ref = get_parent()
	await _frames(8)
	for face in [1, -1]:
		var target: Monster = await _fresh()
		target.position.x = 1120
		var p: Player = main_ref.player
		p.invincible = 0
		p.position.x = 660
		p.reset_physics_interpolation()
		await _hold_double_tap("move_right" if face > 0 else "move_left")
		await _frames(10)
		await _feedback_capture_pose("10_movement_run_" + ("right" if face > 0 else "left"))
		await _frames(5)
		await _feedback_capture_pose("10_movement_run_" + ("right" if face > 0 else "left") + "_next_pose")
		_release_inputs()
	for direction in ["move_up", "move_down"]:
		var target: Monster = await _fresh()
		target.position.x = 1120
		var p: Player = main_ref.player
		p.invincible = 0
		p.depth_y = float(p.cfg["lane_max"] if direction == "move_up" else p.cfg["lane_min"])
		p.reset_physics_interpolation()
		Input.action_press(direction)
		await _frames(7)
		await _feedback_capture_pose("10_movement_" + direction + "_walk")
		await _frames(9)
		await _feedback_capture_pose("10_movement_" + direction + "_walk_next_pose")
		_release_inputs()
	var target: Monster = await _fresh()
	var p: Player = main_ref.player
	p.invincible = 0
	target.position.x = 620
	await _tap("attack")
	Input.action_press("move_down")
	await _tap("jump")
	Input.action_release("move_down")
	for tick in 55:
		await _frames(1)
		if p.move_name == "back_dash":
			break
	await _frames(7)
	await _feedback_capture_pose("10_movement_attack_to_backhop")
	_release_inputs()
	await _frames(3)
	get_tree().quit()


func _run_v6_geometry_checks() -> void:
	## 从源 manifest 独立核对合并 duration 的非 actor 时间轴。
	## actor 恰好一 tick 一 record；只测试 actor 会遗漏刀光/受击所有合并帧。
	var seq: SeqFX = main_ref.seq_fx
	var seq_lib = load("res://scripts/seq_lib.gd")
	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/seq_v6/manifest.json"))
	var timeline_ok := true
	var timeline_detail := ""
	for name in raw["clips"]:
		var runtime: Dictionary = seq.clips[name]
		for authored in raw["clips"][name]["frames"]:
			var first := int(authored["start_tick"])
			var last := first + int(authored["duration_ticks"]) - 1
			for tick in range(first, last + 1):
				var texture: Texture2D = seq_lib.texture_at(runtime, float(tick))
				var expected := "res://assets/seq_v6/" + str(authored["file"])
				if texture == null or texture.resource_path != expected:
					timeline_ok = false
					timeline_detail = "%s tick%d" % [name, tick]
	_check(timeline_ok, "every clip holds the source PNG for its complete authored duration [" + timeline_detail + "]")

	await _fresh(2)
	var p: Player = main_ref.player
	p.control_enabled = false
	var poses := {"attack1": 9.0, "attack2": 9.0, "attack3": 12.0, "quick_draw": 17.0}
	for move in poses:
		for face in [1, -1]:
			for at_edge in [false, true]:
				seq.reset()
				p._clear_move()
				p.facing = face
				var start_x := (p.arena_right - 2.0 if face > 0 else p.arena_left + 2.0) if at_edge else 500.0
				p.position = Vector2(start_x, main_ref.GROUND_Y)
				p.depth_y = 13.0
				p.z_index = 113
				_start_v6_move(p, move)
				p.phase_t = float(poses[move])
				p.anim_name = move
				p._anim_step()
				var reference: float = p.seq_root_offset()
				p.position.x = clampf(start_x + float(face) * reference, p.arena_left, p.arena_right)
				# 上一招残余的压身/惯性不能把一体原画与刀光扭成两套几何。
				p._land_squash = 0.8
				p.velocity.x = 250.0
				seq._refresh_action()
				var label := "%s %s %s" % [move, "right" if face > 0 else "left", "arena edge" if at_edge else "open arena"]
				var root := p.visual_position()
				var actor_anchor := Vector2(224.0, 280.0)
				var blade: Array = p.seq_blade_world()
				var local_blade: Array = seq_lib.blade_local(seq.clips["actor/" + move], p.phase_t)
				var painted_root := _actor_pixel_world(p, actor_anchor)
				var painted_tip := _actor_pixel_world(p, actor_anchor + (local_blade[1] as Vector2))
				var actor_texture: Texture2D = seq_lib.texture_at(seq.clips["actor/" + move], p.phase_t)
				var tip_has_paint := _paint_near(actor_texture, actor_anchor + (local_blade[1] as Vector2))
				_check(tip_has_paint and painted_root.distance_to(root) < 0.01 and painted_tip.distance_to(blade[1]) < 0.01,
					"actual actor PNG root and sword tip match collision coordinates: " + label)
				var slash_anchor := Vector2(256.0, 288.0)
				var slash_root := root - Vector2(float(face) * reference, 0.0)
				var slash_ok := seq.active()
				var painted_count := 0
				for node in [seq._slash_back, seq._slash_front]:
					slash_ok = slash_ok and node.visible and _sprite_pixel_world(node, slash_anchor).distance_to(slash_root) < 0.01
					var pixel := _painted_pixel(node.texture)
					if pixel != Vector2.INF:
						painted_count += 1
						var expected_pixel := slash_root + Vector2(float(face) * (pixel.x - slash_anchor.x), pixel.y - slash_anchor.y)
						slash_ok = slash_ok and _sprite_pixel_world(node, pixel).distance_to(expected_pixel) < 0.01
				_check(slash_ok and painted_count > 0, "visible slash PNG pixels follow the actor without duplicate travel: " + label)

	# 效果的像素锚点与出生朝向独立于随后角色移动、转向和下一招。
	for face in [1, -1]:
		seq.reset()
		p._clear_move()
		p.position = Vector2(500.0, main_ref.GROUND_Y)
		p.depth_y = 0.0
		p.z_index = 100
		p.facing = face
		_start_v6_move(p, "attack3")
		seq.spawn_ground(Vector2(725.0, main_ref.GROUND_Y))
		_start_v6_move(p, "quick_draw")
		seq.spawn_hit(Vector2(685.0, 440.0), "iai")
		var saved: Array = []
		var geometry_ok := true
		var blend_ok := true
		for node in seq._hits + seq._grounds + seq._flashes:
			if not node.visible:
				continue
			var entry: Dictionary = node.get_meta("seq")
			var clip: Dictionary = entry["clip"]
			var anchor := Vector2(256.0, 128.0) if str(clip["name"]).begins_with("ground/") else (Vector2(480.0, 40.0) if str(clip["name"]) == "iai/flash" else Vector2(192.0, 192.0))
			var origin: Vector2 = entry["origin"]
			geometry_ok = geometry_ok and _sprite_pixel_world(node, anchor).distance_to(origin) < 0.01
			var pixel := _painted_pixel(node.texture)
			if pixel != Vector2.INF:
				var expected_pixel := origin + Vector2(float(face) * (pixel.x - anchor.x), pixel.y - anchor.y)
				geometry_ok = geometry_ok and _sprite_pixel_world(node, pixel).distance_to(expected_pixel) < 0.01
			var material := node.material as CanvasItemMaterial
			var wanted := CanvasItemMaterial.BLEND_MODE_ADD if str(clip["blend"]) == "add" else CanvasItemMaterial.BLEND_MODE_MIX
			blend_ok = blend_ok and material != null and material.blend_mode == wanted
			saved.append({"node": node, "anchor": anchor, "origin": origin, "flip": node.flip_h})
		_check(geometry_ok and saved.size() == 5, "hit matter/light, ground matter/light and full-width flash use their actual PNG anchors (face %d)" % face)
		_check(blend_ok, "straight-alpha matter and light keep their distinct render blend modes (face %d)" % face)
		p.facing = -face
		p.position.x += 150.0
		await _frames(3)
		var facing_locked := true
		for sample in saved:
			var node: Sprite2D = sample["node"]
			facing_locked = facing_locked and node.visible and node.flip_h == bool(sample["flip"])
			facing_locked = facing_locked and _sprite_pixel_world(node, sample["anchor"]).distance_to(sample["origin"]) < 0.01
		_check(facing_locked, "existing contact and ground PNGs retain their birth facing and world point after the actor turns (face %d)" % face)
		var layers_ok := _canvas_z(seq._slash_back) < _canvas_z(p) and _canvas_z(p) < _canvas_z(seq._slash_front)
		for sample in saved:
			var node: Sprite2D = sample["node"]
			var name: String = str(node.get_meta("seq")["clip"]["name"])
			if name.begins_with("ground/"):
				layers_ok = layers_ok and _canvas_z(node) < _canvas_z(seq._slash_back)
			else:
				layers_ok = layers_ok and _canvas_z(seq._slash_front) < _canvas_z(node)
		_check(layers_ok, "effective scene z places ground behind actor and front slash ahead of actor (face %d)" % face)
		# 下一招起手既不能清掉已有受击/一闪，也不能把一闪的压暗时钟重置。
		var clock_before := seq.effect_clock
		_start_v6_move(p, "attack1")
		var survive := seq.effect_clock >= clock_before
		for sample in saved:
			survive = survive and (sample["node"] as Sprite2D).visible
		_check(survive, "a new action preserves existing effect nodes and their independent clock (face %d)" % face)
		await _frames(20)
		_check(not seq._dim_layer.visible and is_zero_approx(seq._dim.color.a), "iai dim expires after its authored hold and fade ticks (face %d)" % face)
	# Observe the actual earlier root at a wall, rather than reconstructing it
	# with an unclamped travel delta after quick-draw has already stopped.
	for face in [1, -1]:
		await _fresh(2)
		for target in main_ref.monsters:
			target.position.x = 640.0
		p.position.x = p.arena_right - 1.0 if face > 0 else p.arena_left + 1.0
		p.facing = face
		p.cfg["attack_speed"] = 1.0
		_start_v6_move(p, "quick_draw")
		while p.phase_t < 16.0:
			await _frames(1)
		var earlier_root := p.visual_position()
		await _frames(1)
		var line: Array = p.seq_blade_world(16.0)
		var local: Array = seq_lib.blade_local(seq_lib.clip("actor/quick_draw"), 16.0)
		var expected := earlier_root + Vector2((local[1] as Vector2).x * float(face), (local[1] as Vector2).y)
		_check((line[1] as Vector2).distance_to(expected) < 0.01, "swept blade history uses the actual clamped earlier root (face %d)" % face)
	p._land_squash = 0.0
	p.velocity = Vector2.ZERO
	p.control_enabled = true
	await _fresh()

func _run_capture() -> void:
	main_ref = get_parent()
	await _frames(8)
	await _capture("01_title")
	var target: Monster = await _fresh(2)
	main_ref._wave_notice.hide()
	main_ref.player.invincible = 0
	target.hp = 200
	target.cfg["hp"] = 200
	target.position.x = 680
	target.depth_y = 0
	target._anim_step()
	target.queue_redraw()
	await _frames(18)
	await _capture("02_arena")
	target.position.x = 630
	main_ref.player.buffer_action("skill_a")
	await _frames(22)
	main_ref.bm.freeze = 8
	await _capture("03_hit")
	main_ref.bm.clear_fx()
	await _frames(3)
	main_ref._start_training(1)
	main_ref._wave_notice.hide()
	main_ref.player.position.x = 520
	await _frames(4)
	main_ref.player.buffer_action("skill_s")
	await _frames(19)
	await _capture("05_training_rage")
	main_ref._toggle_display_settings()
	await _frames(2)
	await _capture("06_display_settings")
	main_ref._toggle_display_settings()
	main_ref.bm.clear_fx()
	await _frames(3)
	await _capture_v6_contacts()
	main_ref.bm.clear_fx()
	await _frames(3)
	get_tree().quit()

func _capture_v6_contacts() -> void:
	## 抓实际碰撞事件，不把参考 tick 或预设 freeze 冒充命中帧。
	## 暂停战斗后等一次真实渲染，PNG 才能和记录的 actor/slash/contact 同帧。
	var evidence: Array = []
	for face in [1, -1]:
		for move in ["attack1", "attack2", "attack3", "quick_draw"]:
			var target: Monster = await _fresh(2)
			var p: Player = main_ref.player
			main_ref._wave_notice.hide()
			# Training targets are passive; do not capture the test fixture's
			# invulnerability flicker as if it were part of the authored artwork.
			p.invincible = 0
			target.position.x = 640.0
			p.position.x = target.position.x - float(face) * (205.0 if move == "quick_draw" else 120.0)
			p.depth_y = target.depth_y
			p.facing = face
			p.cfg["attack_speed"] = 1.0
			main_ref.monsters[1].position.x = 1160.0
			var seq: SeqFX = main_ref.seq_fx
			var contacts_before := seq.contacts.size()
			_start_v6_move(p, move)
			var connected := false
			for _index in 80:
				await _frames(1)
				if seq.contacts.size() > contacts_before:
					connected = true
					break
			var name: String = ("08_v6_quick_draw" if move == "quick_draw" else "07_v6_" + move) + ("_left" if face < 0 else "")
			if not connected:
				push_error("[CAPTURE] no authentic V6 contact for " + name)
				continue
			get_tree().paused = true
			await _capture(name)
			evidence.append(_v6_capture_geometry(name))
			get_tree().paused = false
			if move in ["attack3", "quick_draw"]:
				await _frames(5)
				get_tree().paused = true
				await _capture(name + "_fx_age5")
				evidence.append(_v6_capture_geometry(name + "_fx_age5"))
				get_tree().paused = false
	# 挥空重劈也应在真实刀尖处裂地，且没有凭空受击或停帧。
	await _fresh(2)
	var p: Player = main_ref.player
	var seq: SeqFX = main_ref.seq_fx
	main_ref._wave_notice.hide()
	p.position.x = 500.0
	p.facing = 1
	p.invincible = 0
	for target in main_ref.monsters:
		target.position.x = 1180.0
	var ground_before := seq.ground_events.size()
	_start_v6_move(p, "attack3")
	for _index in 60:
		await _frames(1)
		if seq.ground_events.size() > ground_before:
			break
	get_tree().paused = true
	await _capture("09_v6_ground_whiff")
	evidence.append(_v6_capture_geometry("09_v6_ground_whiff"))
	get_tree().paused = false
	await _frames(5)
	get_tree().paused = true
	await _capture("09_v6_ground_whiff_fx_age5")
	evidence.append(_v6_capture_geometry("09_v6_ground_whiff_fx_age5"))
	get_tree().paused = false
	var directory := ProjectSettings.globalize_path("res://../temp/demo")
	var record := FileAccess.open(directory.path_join("v6_contact_geometry.json"), FileAccess.WRITE)
	if record != null:
		record.store_string(JSON.stringify(evidence, "\t"))


func _v6_capture_geometry(name: String) -> Dictionary:
	var p: Player = main_ref.player
	var seq: SeqFX = main_ref.seq_fx
	var effects: Array = []
	for node in [seq._slash_back, seq._slash_front] + seq._hits + seq._grounds + seq._flashes:
		if not node.visible:
			continue
		var entry: Dictionary = node.get_meta("seq", {})
		var slash_name := ("slash_back/" if node == seq._slash_back else "slash_front/") + p.move_name
		var clip: Dictionary = entry.get("clip", seq.clips.get(slash_name, {}))
		if clip.is_empty():
			continue
		var anchor: Vector2 = clip["anchor"]
		var pixel_anchor := _sprite_pixel_world(node, anchor)
		effects.append({"clip": clip["name"], "tick": entry.get("tick", p.phase_t), "texture": node.texture.resource_path,
			"png_anchor_world": [pixel_anchor.x, pixel_anchor.y], "flip_h": node.flip_h, "effective_z": _canvas_z(node)})
	var blade := p.seq_blade_world()
	return {"capture": name, "move": p.move_name, "tick": p.phase_t, "facing": p.facing,
		"root": [p.visual_position().x, p.visual_position().y], "tip": [blade[1].x, blade[1].y],
		"contact": [p.last_contact.x, p.last_contact.y], "freeze": main_ref.bm.freeze, "effects": effects}


func _run_seq6_showcase() -> void:
	# Controlled per-move comparison: restore the passive target before each
	# action so a previous knockdown cannot make the next authored move whiff.
	main_ref = get_parent()
	await _frames(30)
	for pair in [["attack1", 1], ["attack2", 1], ["attack3", 1], ["quick_draw", 1], ["attack1", -1]]:
		var move := str(pair[0])
		var face := int(pair[1])
		main_ref._start_training(2)
		main_ref._wave_notice.hide()
		var p: Player = main_ref.player
		var target: Monster = main_ref.monsters[0]
		target.position.x = 640.0
		main_ref.monsters[1].position.x = 1120.0
		p.position.x = target.position.x - float(face) * (205.0 if move == "quick_draw" else 120.0)
		p.depth_y = target.depth_y
		p.facing = face
		p.invincible = 0
		p.cfg["attack_speed"] = 1.0
		p.reset_physics_interpolation()
		target.reset_physics_interpolation()
		await _frames(12)
		_start_v6_move(p, move)
		var authored: Dictionary = main_ref.seq_fx.moves[move]
		await _frames(int(authored["length"]) + int(authored["hitstop"]) + 18)
		print("[V6_SHOWCASE] move=%s facing=%d contacts=%d" % [move, face, main_ref.seq_fx.contacts.size()])
		if main_ref.seq_fx.contacts.size() != 1:
			push_error("[V6_SHOWCASE] expected one real contact for " + move)
			get_tree().quit(1)
			return
	_release_inputs()
	await _frames(10)
	get_tree().quit()

func _run_showcase() -> void:
	main_ref = get_parent()
	await _frames(36)
	main_ref._start_training(2)
	main_ref._wave_notice.hide()
	await _frames(132)
	Input.action_press("move_right")
	await _frames(20)
	Input.action_release("move_right")
	await _frames(1)
	await _hold_double_tap("move_right")
	await _frames(16)
	await _tap("attack")
	Input.action_release("move_right")
	await _frames(18)
	await _tap("attack")
	await _frames(20)
	await _tap("attack")
	await _frames(58)
	await _tap("attack")
	await _hold_double_tap("move_right")
	await _frames(30)
	Input.action_release("move_right")
	await _frames(1)
	await _hold_double_tap("move_left")
	await _frames(18)
	Input.action_release("move_left")
	await _frames(10)
	main_ref._reset_battle()
	main_ref._wave_notice.hide()
	Input.action_press("move_right")
	await _frames(27)
	Input.action_release("move_right")
	await _tap("generic_skill")
	await _frames(13)
	Input.action_press("jump")
	await _frames(17)
	await _tap("attack")
	await _frames(12)
	Input.action_release("jump")
	await _frames(60)
	Input.action_press("move_down")
	await _tap("jump")
	Input.action_release("move_down")
	await _frames(30)
	Input.action_press("move_right")
	await _frames(29)
	Input.action_release("move_right")
	await _frames(5)
	await _tap("skill_a")
	await _frames(52)
	await _tap("skill_s")
	await _frames(54)
	main_ref._start_training(1)
	main_ref._wave_notice.hide()
	Input.action_press("move_right")
	await _frames(28)
	Input.action_release("move_right")
	await _tap("skill_a")
	await _frames(12)
	await _tap("skill_s")
	await _frames(75)
	await _tap("attack")
	await _frames(18)
	await _tap("attack")
	await _frames(20)
	await _tap("attack")
	await _frames(60)
	_release_inputs()
	main_ref.bm.clear_fx()
	await _frames(3)
	get_tree().quit()
