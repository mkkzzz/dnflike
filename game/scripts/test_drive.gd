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
	elif "--showcase" in OS.get_cmdline_user_args():
		_run_showcase.call_deferred()

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
	_check(audio._voices.size() >= 8 and audio._voices.size() <= 12 and audio._streams.size() >= 18, "audio loads layered variants with a bounded voice pool")
	var audio_valid := true
	for entry in audio._streams.values():
		var variants: Array = entry if entry is Array else [entry]
		for stream in variants:
			audio_valid = audio_valid and stream is AudioStreamWAV and stream.data.size() > 2000 and stream.format == AudioStreamWAV.FORMAT_16_BITS
	_check(audio_valid, "offline foley variants contain valid sixteen-bit PCM")
	# Accelerated assertions are silent; --capture alone exercises real playback.
	audio.enabled = false
	var m: Monster = await _fresh()
	var p: Player = main_ref.player
	_check(p.anims.size() >= 20 and m.anims.size() == 8, "separate body animations and monster animations load")
	var first_attack: Dictionary = GameConfig.moves["attack1"]
	var attack_pose: int = AnimLib.frame_for_move(p.anims["attack1"], float(first_attack["windup"]) + 1, first_attack)
	var active_pose_valid := false
	for pose_index in p.anims["attack1"]["phase_frames"]["active"]:
		active_pose_valid = active_pose_valid or attack_pose == int(pose_index)
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
	_check(observed_moves.has("air_attack"), "dedicated air attack follows uppercut")
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
	Input.action_press("move_right")
	Input.action_press("dash")
	await _frames(14)
	_check(p.state == Player.St.RUN and p.velocity.x > 380, "sprint transitions to run with its own gait")
	await _tap("attack")
	_check(p.move_name == "dash_attack", "running attack has a dedicated forward cut")
	Input.action_release("move_right")
	Input.action_release("dash")
	await _frames(60)
	m = await _fresh()
	m.position.x = 1120
	Input.action_press("move_right")
	Input.action_press("dash")
	await _frames(12)
	Input.action_press("jump")
	await _frames(3)
	_check(p.position.y < main_ref.GROUND_Y and p.velocity.x >= 300, "sprint jump keeps horizontal momentum")
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
	await _frames(9)
	p.buffer_action("generic_skill")
	await _frames(7)
	_check(observed_moves.has("upper") or p.move_name == "upper", "connected basic attacks can cancel into uppercut early")
	m = await _fresh()
	var rig: WeaponRig = main_ref.weapon_rig
	rig.update_attachment()
	_check(rig.visible and bool(p.anims["idle"].get("weapon_separated", false)), "weapon is a visible independent layer on weaponless body art")
	var sockets_valid := true
	for clip in p.anims.values():
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
	await _frames(8)
	_check(main_ref.bm._trails.size() >= 2 and main_ref.bm.freeze > 0, "contact frame already has real blade trail during hitstop")
	main_ref.bm.clear_fx()
	m = await _fresh()
	m.position.x = p.position.x + float(GameConfig.moves["attack1"]["hitbox"]["x"]) + float(GameConfig.moves["attack1"]["move"]) + 28
	p._start_attack()
	await _frames(30)
	_check(m.hp < 2000, "visible blade reach contributes to the actual melee hit region")
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
	_check(p.mp == 90 and int(p.cds["quick_draw"]) > 0, "training can preserve real mana and cooldowns")
	main_ref._reset_battle()
	await _frames(3)
	_check(main_ref.training_mode and main_ref.training_damage == 0 and main_ref.hit_count == 0 and not p.dead, "training reset clears drill metrics and action state")
	main_ref._toggle_pause()
	await _frames(2)
	_check(not p.control_enabled and get_tree().paused, "training can pause")
	main_ref._toggle_pause()
	_check(p.control_enabled and main_ref.training_mode, "training resumes its own mode")

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
	main_ref.bm.clear_fx()
	await _frames(3)
	get_tree().quit()

func _run_showcase() -> void:
	main_ref = get_parent()
	await _frames(36)
	main_ref._start_training(2)
	main_ref._wave_notice.hide()
	await _frames(36)
	Input.action_press("move_right")
	await _frames(20)
	Input.action_press("dash")
	await _frames(16)
	await _tap("attack")
	Input.action_release("dash")
	Input.action_release("move_right")
	await _frames(14)
	await _tap("attack")
	await _frames(14)
	await _tap("attack")
	await _frames(58)
	main_ref._reset_battle()
	main_ref._wave_notice.hide()
	Input.action_press("move_right")
	await _frames(27)
	Input.action_release("move_right")
	await _tap("generic_skill")
	await _frames(9)
	Input.action_press("jump")
	await _frames(9)
	await _tap("attack")
	Input.action_release("jump")
	await _frames(60)
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
	await _frames(10)
	await _tap("attack")
	await _frames(10)
	await _tap("attack")
	await _frames(60)
	_release_inputs()
	main_ref.bm.clear_fx()
	await _frames(3)
	get_tree().quit()
