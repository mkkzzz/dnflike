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
	elif "--seq6" in OS.get_cmdline_user_args():
		_run_seq6_showcase.call_deferred()

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
	await _run_v4_checks()
	await _run_v6_checks()
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
	await _frames(4)
	var frozen: Dictionary = main_ref.seq_fx.freeze_samples[-1] if not main_ref.seq_fx.freeze_samples.is_empty() else {}
	var held: Dictionary = main_ref.seq_fx.debug_state()
	_check(not frozen.is_empty() and int(frozen["frame"]) == int(float(frozen["tick"])), "actor artwork freezes on the same tick as the action clock")
	_check(held["slash_back_visible"] and held["slash_front_visible"], "both slash layers stay on screen during hitstop")
	await _frames(14)
	var after: Dictionary = main_ref.seq_fx.debug_state()
	_check(after["hit_nodes"] >= 1 or int(main_ref.seq_fx.effect_clock * 60.0) > 0, "hit effects keep their own clock while the action clock is frozen")
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
	_check(p.mp == 90 and int(p.cds["quick_draw"]) > 0, "training can preserve real mana and cooldowns")
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
	await _frames(60)
	var ground_events: Array = main_ref.seq_fx.ground_events
	_check(ground_events.size() == grounds_before + 1, "the heavy chop cracks the ground exactly once")
	if ground_events.size() > grounds_before:
		var ground_point: Vector2 = ground_events[-1]["point"]
		_check(absf(ground_point.y - (main_ref.GROUND_Y + ground_p.depth_y)) <= 3.5, "ground crack anchors at the visible blade tip's landing coordinate")
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
	main_ref.bm.clear_fx()
	main_ref.seq_fx.reset()

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
	# V6 三段普攻与拔刀斩：接触帧截图（一体原画 + 分层序列帧特效）
	main_ref._start_training(0)
	main_ref._wave_notice.hide()
	var v6_target: Monster = main_ref.monsters[0]
	v6_target.position.x = 700
	main_ref.monsters[1].position.x = 1100
	main_ref.player.position.x = 580
	main_ref.player.depth_y = 0
	main_ref.player.invincible = 99999
	await _frames(18)
	for pair in [["attack3", 13], ["attack1", 9]]:
		main_ref.player.position.x = v6_target.position.x - 120.0
		main_ref.player.cfg["attack_speed"] = 1.0
		await _frames(3)
		main_ref.player._start_move(str(pair[0]))
		while main_ref.player.phase_t < float(pair[1]):
			await _frames(1)
		await _capture("07_v6_%s" % str(pair[0]))
		while main_ref.player.move_name == str(pair[0]):
			await _frames(1)
		await _frames(4)
	main_ref.player.position.x = v6_target.position.x - 210.0
	# 拔刀斩属于剑魂（job 2）的技能槽
	main_ref.player.set_job(2)
	main_ref.player.mp = 300.0
	main_ref.player.cds.clear()
	await _frames(3)
	main_ref.player._try_skill_action("skill_a")
	var guard := 0
	while main_ref.player.phase_t < 17.0 and guard < 200:
		guard += 1
		await _frames(1)
	await _capture("08_v6_quick_draw")
	main_ref.bm.clear_fx()
	await _frames(3)
	get_tree().quit()

func _run_seq6_showcase() -> void:
	## V6 四招实机录像驱动：同一镜头下依次打出一段/二段/三段与拔刀斩，
	## 用来逐帧核对一体原画、前后两层刀光、受击 light/matter、地裂与一闪。
	main_ref = get_parent()
	await _frames(30)
	main_ref._start_training(2)
	main_ref._wave_notice.hide()
	var target: Monster = main_ref.monsters[0]
	target.position.x = 620
	main_ref.monsters[1].position.x = 1100
	await _frames(24)
	# 三段普攻连段：贴着 manifest 的接触间距
	for pair in [["attack1", 40], ["attack2", 40], ["attack3", 54]]:
		main_ref.player.position.x = target.position.x - 120.0
		main_ref.player.depth_y = target.depth_y
		main_ref.player.cfg["attack_speed"] = 1.0
		await _frames(3)
		main_ref.player._start_move(str(pair[0]))
		await _frames(int(pair[1]))
	# 拔刀斩：蓄力、前冲、命中一闪与压暗
	main_ref.player.position.x = target.position.x - 210.0
	main_ref.player.mp = 300.0
	main_ref.player.cds.clear()
	main_ref.player.cfg["attack_speed"] = 1.0
	await _frames(4)
	main_ref.player._try_skill_action("skill_a")
	await _frames(70)
	# 左向翻转验收：同一套图像与锚点一起镜像
	main_ref.player.position.x = target.position.x + 120.0
	main_ref.player.facing = -1
	await _frames(3)
	main_ref.player._start_move("attack1")
	await _frames(40)
	_release_inputs()
	main_ref.bm.clear_fx()
	await _frames(3)
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
