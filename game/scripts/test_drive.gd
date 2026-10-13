extends Node
const AnimLib := preload("res://scripts/anim_lib.gd")
## --test: assertions and a complete encounter using gameplay actions.
## --capture: rendered title / arena / hit / result screenshots in temp/demo.
var main_ref
var checks := 0
var failures := 0
var observed_moves: Array = []

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if "--test" in OS.get_cmdline_user_args():
		_run_checks.call_deferred()
	elif "--capture" in OS.get_cmdline_user_args():
		_run_capture.call_deferred()

func _frames(count: int) -> void:
	for _index in count:
		await get_tree().physics_frame

func _release_inputs() -> void:
	for action in ["attack", "jump", "generic_skill", "skill_a", "skill_s", "guard", "dash", "move_left", "move_right", "move_up", "move_down", "potion_hp", "potion_mp"]:
		Input.action_release(action)

func _tap(action: String) -> void:
	Input.action_press(action)
	await _frames(2)
	Input.action_release(action)
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
	_check(main_ref.battle_state == main_ref.BattleState.READY, "title starts without combat")
	_check(not main_ref.player.control_enabled, "title blocks gameplay input")
	var audio: CombatAudio = main_ref.bm._audio
	_check(audio._voices.size() == 8 and audio._streams.size() == 11, "audio has a bounded eight-voice pool and eleven sounds")
	var audio_valid := true
	for stream in audio._streams.values():
		audio_valid = audio_valid and stream is AudioStreamWAV and stream.data.size() > 2000 and stream.format == AudioStreamWAV.FORMAT_16_BITS
	_check(audio_valid, "synthesized sounds contain valid sixteen-bit PCM")
	# Accelerated assertions are silent; --capture alone exercises real playback.
	audio.enabled = false
	var m: Monster = await _fresh()
	var p: Player = main_ref.player
	_check(p.anims.size() == 17 and m.anims.size() == 8, "all approved demo animation strips load")
	_check(AnimLib.frame_for_move(p.anims["attack1"], 7, GameConfig.moves["attack1"]) == 1, "attack pose matches active hit frame")
	_check(AnimLib.frame_for_move(p.anims["attack3"], 3, GameConfig.moves["attack3"]) == 0, "windup uses preparation pose")
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
	_check(is_equal_approx(m.hp, 1880), "three-hit chain deals configured 30+35+55 damage")
	var slow: int = await _attack_duration(0.7)
	var fast: int = await _attack_duration(1.3)
	_check(fast < slow and fast <= 18 and slow >= 28, "fractional attack speed changes actual duration")
	# A target entering after the first active frame must still be hit.
	m = await _fresh()
	m.position.x = 900
	p._start_attack()
	await _frames(8)
	m.position.x = p.position.x + 100
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
	_check(observed_moves.has("attack1"), "air attack follows uppercut")
	# Multi-hit skill tails, costs, cooldown and rejection.
	m = await _fresh(2)
	_check(p._try_skill_action("skill_s"), "thrust cast accepted")
	await _frames(65)
	_check(observed_moves.count("thrust") == 3, "all three thrust segments connect")
	_check(is_equal_approx(m.hp, 1920), "thrust deals 25+25+30")
	_check(p.mp == 270 and int(p.cds.get("thrust", 0)) > 0, "skill consumes MP and starts cooldown")
	_check(not p._try_skill_action("skill_s") and p.mp == 270, "cooldown rejection does not spend MP")
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
	main_ref._show_ready()
	_check(main_ref.battle_state == main_ref.BattleState.READY and not p.control_enabled, "result returns to class selection")
	print("[DEMO_TEST] COMPLETE checks=%d failures=%d" % [checks, failures])
	main_ref.bm.clear_fx()
	await _frames(3)
	get_tree().quit(0 if failures == 0 else 1)

func _capture(name_text: String) -> void:
	await RenderingServer.frame_post_draw
	var directory := ProjectSettings.globalize_path("res://../temp/demo")
	DirAccess.make_dir_recursive_absolute(directory)
	get_viewport().get_texture().get_image().save_png(directory.path_join(name_text + ".png"))
	print("[CAPTURE] " + name_text)

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
	get_tree().quit()
