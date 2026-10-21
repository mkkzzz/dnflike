extends RefCounted
const Library := preload("res://scripts/swordsman_v7_lib.gd")

func run(main, check: Callable, frames: Callable, capture: Callable) -> void:
	main._start_demo(0)
	await frames.call(3)
	var p: Player = main.player
	var renderer: Node2D = p.v7_renderer
	for monster in main.monsters:
		monster.control_enabled = false
		monster.position.x = 1100
	p.position = Vector2(500, p.ground_y)
	p.depth_y = 0
	p.invincible = 99999
	renderer.call("set_enabled", true)
	await frames.call(2)
	check.call(p.is_v7_active() and Library.data()["clips"].size() == 32, "v7 installs all 32 non-skill source/derived clips")
	check.call(bool(Library.data()["validation"]["passed"]) and bool(Library.data()["coverage"]["complete"]), "v7 installed layers passed source/trim/clock coverage validation")
	var textures_ok := true
	for reference in Library.data()["textures"].values():
		var texture: Texture2D = Library.texture(reference)
		textures_ok = textures_ok and texture != null and texture.get_width() == int(reference["size"][0]) and texture.get_height() == int(reference["size"][1])
	check.call(textures_ok, "v7 loads the actual native cropped PNGs without resampling")
	p._start_move("attack1")
	await frames.call(10)
	p.control_enabled = false
	var body_file := ""
	var lengths: Array = []
	for profile in ["katana", "greatsword", "shortsword"]:
		var before := p.position
		var tick := p.phase_t
		check.call(main.weapon_rig.set_profile(profile), "v7 equipment selects " + profile)
		var snap: Dictionary = renderer.call("snapshot")
		var frame: Dictionary = snap["frame"]
		var file: String = frame["body"]["file"]
		if body_file == "": body_file = file
		check.call(file == body_file and p.phase_t == tick and p.position == before, "v7 weapon change preserves body pixels/action clock/root " + profile)
		var points: Dictionary = snap["blade_profiles"][profile] if Library.continuous() else frame["profiles"][profile]
		var matrix: Transform2D = p.global_transform * renderer.call("body_matrix")
		var guard: Vector2 = points["guard"] if Library.continuous() else Library.point(points["guard"])
		var tip: Vector2 = points["tip"] if Library.continuous() else Library.point(points["tip"])
		var expected_guard := matrix * (guard - Library.anchor())
		var expected_tip := matrix * (tip - Library.anchor())
		if Library.continuous():
			var drawn: Sprite2D = snap["weapon_node"]
			var raw: Dictionary = Library.data()["weapon_sources"][profile]["marks"]
			expected_guard = drawn.global_transform * (Library.point(raw["guard"])+drawn.offset)
			expected_tip = drawn.global_transform * (Library.point(raw["tip"])+drawn.offset)
		var actual := p.seq_blade_world()
		check.call(actual[0].distance_to(expected_guard) < 0.01 and actual[1].distance_to(expected_tip) < 0.01, "v7 hit line matches the drawn weapon " + profile)
		lengths.append(actual[0].distance_to(actual[1]))
		main.weapon_rig.update_attachment()
		main.seq_fx._refresh_action()
		check.call(not main.weapon_rig.visible and not main.seq_fx._slash_back.visible and not main.seq_fx._slash_front.visible, "v7 suppresses the old duplicate sword and body-specific slash " + profile)
		if "--capture" in OS.get_cmdline_user_args():
			p.control_enabled = false
			await capture.call("v7_attack1_" + profile)
			p.control_enabled = true
	check.call(float(lengths[1]) > float(lengths[0]) and float(lengths[0]) > float(lengths[2]), "v7 weapon silhouettes have distinct authored blade lengths")
	p.facing = -1
	var mirrored := p.seq_blade_world()
	var local_tip: Vector2 = (renderer.call("snapshot")["blade_profiles"]["shortsword"]["tip"]-Library.anchor())*0.5 if Library.continuous() else (Library.point(Library.record("attack1",renderer.call("clock"))["profiles"]["shortsword"]["tip"]) - Library.anchor()) * 0.5
	check.call(mirrored[1].distance_to(p.visual_position() + Vector2(-local_tip.x, local_tip.y)) < 0.01, "v7 left-facing blade reflects all coordinates around the same root")
	p._clear_move()
	p.state = Player.St.JUMP
	p.position.y = p.ground_y - 100
	p.velocity = Vector2.ZERO
	renderer.set("_transient", "")
	var airborne: Dictionary = renderer.call("snapshot")
	var body_matrix: Transform2D = airborne["matrix"]
	check.call(airborne["clip"] == "jump_apex" and body_matrix.origin.y == p.depth_y and body_matrix.y.length() == 0.5, "v7 jump uses physics height once and rigid native-to-world scale")
	p.position.y = p.ground_y
	p.state = Player.St.IDLE
	renderer.set("_state", Player.St.IDLE)
	renderer.set("_base", "idle")
	renderer.set("_loop_clock", 10.0)
	main.bm.freeze = 4
	renderer.call("_physics_process", 1.0 / 60.0)
	check.call(float(renderer.get("_loop_clock")) == 10.0, "v7 native layer clock holds during hitstop")
	main.bm.freeze = 0
	p.state = Player.St.GUARD
	renderer.set("_state", Player.St.GUARD)
	renderer.call("guard_impact", true)
	check.call(renderer.call("current_clip") == "parry", "v7 perfect guard uses its dedicated response")
	p.state = Player.St.SKILL
	p.move_name = "quick_draw"
	check.call(not p.is_v7_active(), "v7 non-skill package leaves existing skill assets active")
	p._clear_move()
	p.dead = true
	p._death_t = 0
	renderer.set("_transient", "")
	var first: Dictionary = renderer.call("snapshot")
	p._death_t = 0.5
	var final: Dictionary = renderer.call("snapshot")
	check.call(first["frame"]["reused_from"] == "hit_heavy" and final["frame"]["source_pose"] == "death_2", "v7 death plays reaction/down/rest instead of only holding a resting drawing")
	if "--capture" in OS.get_cmdline_user_args():
		p.control_enabled = false
		await capture.call("v7_death_rest")
	p.dead = false
	p.control_enabled = true
	main._start_demo(0)
	for trial in [["attack1","katana",1],["attack2","katana",1],["attack3","katana",1],["attack1","greatsword",1],["attack2","greatsword",1],["attack3","greatsword",1],["attack1","shortsword",1],["attack2","shortsword",1],["attack3","shortsword",1],["attack1","katana",-1],["attack2","katana",-1],["attack3","katana",-1]]:
		var move: String = trial[0]
		p._clear_move()
		p.state = Player.St.IDLE
		p.position = Vector2(500, p.ground_y)
		p.velocity = Vector2.ZERO
		p.depth_y = 0
		p.facing = int(trial[2])
		p.invincible = 99999
		main.bm.freeze = 0
		main.weapon_rig.set_profile(trial[1])
		for monster in main.monsters:
			monster.control_enabled = false
			monster.position.x = 1100
		var target: Monster = main.monsters[0]
		target.position = Vector2(500+100*p.facing, p.ground_y)
		target.depth_y = 0
		target.hp = 2000
		target.invincible = 0
		p._start_move(move)
		await frames.call(50)
		check.call(target.hp < 2000 and not p.contact_log.is_empty(), "v7 visible blade actually hits during gameplay %s %s face%d" % [move,trial[1],p.facing])
		if Library.continuous() and move == "attack3":check.call(not p._seq_ground_done,"v7 rising third cut does not emit the retired downward ground slam")
	if Library.continuous():
		p._clear_move()
		p.state = Player.St.IDLE
		p.combo = 0
		p.facing = 1
		main.bm.freeze = 0
		for monster in main.monsters:monster.position.x=1100
		var seen: Array = []
		for tick in 100:
			if tick in [0,18,36]:p.buffer_action("attack")
			await frames.call(1)
			if p.move_name.begins_with("attack") and p.move_name not in seen:seen.append(p.move_name)
		check.call(seen==["attack1","attack2","attack3"],"v7 queued gameplay input executes the complete three-cut combo")
		await _motion_checks(main,p,renderer,check,frames)
		await _c8_trial_checks(main,p,renderer,check,frames)
	renderer.call("set_enabled", false)
	main.weapon_rig.set_profile("blacksteel")
	await frames.call(2)
	check.call(not p.is_v7_active() and p.anims["attack1"].get("seq6", false), "v7 trial switch restores the unchanged V6 fallback")

func _motion_checks(main,p: Player,renderer: Node2D,check: Callable,frames: Callable) -> void:
	p._clear_move()
	p.state = Player.St.IDLE
	p.control_enabled = false
	main.bm.freeze = 0
	renderer.call("set_enabled",true)
	var before: Dictionary = renderer.call("snapshot")
	p.state = Player.St.DOWN
	var onset: Dictionary = renderer.call("snapshot")
	check.call(Library.point(onset["motion_geometry"]["head_center"]).distance_to(Library.point(before["motion_geometry"]["head_center"])) < 0.001,"v7 state entry starts from the actually displayed pose")
	var motion = renderer.get("motion")
	motion.set("_elapsed",4.0)
	var middle: Dictionary = renderer.call("snapshot")
	var end := Library.point(Library.record("down",0)["motion_geometry"]["head_center"])
	var start := Library.point(before["motion_geometry"]["head_center"])
	var halfway := Library.point(middle["motion_geometry"]["head_center"])
	check.call(halfway.distance_to(start)>1 and halfway.distance_to(end)>1 and middle["body_sources"].size()>=2,"v7 state recovery moves through an intermediate body geometry")
	var elapsed := float(motion.get("_elapsed"))
	main.bm.freeze = 4
	await frames.call(2)
	p.seq_blade_world()
	renderer.call("snapshot")
	check.call(float(motion.get("_elapsed"))==elapsed,"v7 hitstop freezes transition geometry as well as the clip clock")
	main.bm.freeze = 0
	middle = renderer.call("snapshot")
	p._start_move("attack2")
	var interrupted: Dictionary = renderer.call("snapshot")
	check.call(Library.point(interrupted["motion_geometry"]["head_center"]).distance_to(Library.point(middle["motion_geometry"]["head_center"]))<0.001,"v7 an interrupted transition continues from its visible intermediate pose")
	check.call(interrupted["body_sources"].size()<=8 and bool(motion.body.visible) and bool(motion.fingers.visible),"v7 body and finger surfaces stay coupled with bounded source count")
	p._clear_move()
	p.state = Player.St.IDLE
	renderer.call("begin_transition","jump_land")
	check.call(float(renderer.get("_transient_duration"))==18.0,"v7 landing keeps its full gradual recovery instead of an eight-tick shortcut")
	var fractional := Library.samples("walk",2.5)
	check.call(fractional.size()==2 and is_equal_approx(float(fractional[0]["weight"]),0.5) and is_equal_approx(float(fractional[1]["weight"]),0.5),"v7 fractional clocks sample both neighboring native frames")
	# Facing is an immediate reflection of the same pose. Never play the old
	# paper-thin turn clip or restart a gait merely because input changed side.
	for facing_state in [Player.St.IDLE,Player.St.WALK,Player.St.RUN]:
		p.state = facing_state
		p.facing = 1
		renderer.set("_state",facing_state)
		renderer.set("_base",renderer.call("_base_clip"))
		renderer.set("_transient","")
		renderer.call("snapshot")
		var facing_clock: float = renderer.call("clock")
		var pose_before: Dictionary = renderer.call("snapshot")
		p.facing = -1
		renderer.call("_physics_process",1.0/60.0)
		var pose_after: Dictionary = renderer.call("snapshot")
		var face_matrix: Transform2D = pose_after["matrix"]
		check.call(face_matrix.x == Vector2(-0.5,0) and pose_after["facing"] == -1 and pose_after["clip"] != "turn" and renderer.call("clock") == facing_clock and pose_after["body_sources"] == pose_before["body_sources"],"v7 instant facing keeps full body width, pose and gait clock state%d" % facing_state)
	p.facing = 1
	p.state = Player.St.HIT
	p.st_hit_left = 22
	renderer.set("_state",Player.St.HIT)
	renderer.set("_hit_time_left",3)
	renderer.set("_loop_clock",14.0)
	renderer.call("_physics_process",1.0/60.0)
	check.call(float(renderer.get("_loop_clock"))==0.0 and renderer.call("current_clip")=="hit_heavy","v7 a repeated hit restarts its response without waiting for a state change")
	p.control_enabled = true
	await _actual_hit_checks(main,p,renderer,check,frames)

func _actual_hit_checks(main,p: Player,renderer: Node2D,check: Callable,frames: Callable) -> void:
	p._clear_move()
	p.state = Player.St.IDLE
	p.invincible = 0
	p.hp = float(p.cfg.get("max_hp",1000))
	p.buff_data.clear()
	p.position = Vector2(500,p.ground_y)
	p.depth_y = 0
	p.velocity = Vector2.ZERO
	main.bm.freeze = 0
	for monster in main.monsters:monster.position.x=1100
	await frames.call(10)
	var idle: Dictionary = renderer.call("snapshot")
	var health := p.hp
	var attacker: Monster = main.monsters[0]
	attacker.position = Vector2(430,p.ground_y)
	attacker.depth_y = 0
	attacker.attack_facing = 1
	attacker.atk_hit_done = false
	attacker.st_t = int(attacker.cfg["attack_move"]["windup"])
	attacker.call("_attack")
	check.call(attacker.atk_hit_done and p.hp < health and p.state == Player.St.HIT,"v7 real monster attack damages the player and enters HIT")
	await frames.call(3)
	var recoil: Dictionary = renderer.call("snapshot")
	var head_shift := Library.point(recoil["motion_geometry"]["head_center"]).distance_to(Library.point(idle["motion_geometry"]["head_center"]))
	var response = renderer.get("motion")
	check.call(recoil["clip"]=="hit_light" and recoil["clock"]<=1 and head_shift>40 and response.body.visible and p.position.x>500,"v7 real damage visibly reaches and holds recoil peak with knockback")
	var visible_recoil_ticks := 0
	var opaque_feedback := true
	for tick in 15:
		if p.state == Player.St.HIT and renderer.call("current_clip")=="hit_light":visible_recoil_ticks+=1
		opaque_feedback = opaque_feedback and is_equal_approx(p.modulate.a,1.0)
		await frames.call(1)
	check.call(visible_recoil_ticks>=9 and p.state==Player.St.IDLE,"v7 recoil remains readable through original stun then recovers without extending gameplay stun")
	check.call(opaque_feedback,"v7 hurt invulnerability feedback keeps the complete silhouette opaque instead of flashing alpha")

func _c8_trial_checks(main,p: Player,renderer: Node2D,check: Callable,frames: Callable) -> void:
	var original: Dictionary = Library.data().duplicate(true)
	p._clear_move()
	p.state = Player.St.IDLE
	main._on_gm_command("art",PackedStringArray(["v7c8"]))
	await frames.call(2)
	check.call(Library.data().get("trial_scope",[])==["attack1"] and Library.record("attack1",3)["source_pose"]=="c8_attack1_windup","c8 GM command selects only the new first cut")
	var retained := true
	for name in original["clips"]:
		if name != "attack1":retained = retained and Library.clip(name)==original["clips"][name]
	check.call(retained and Library.data()["clips"].size()==32,"c8 preserves the accepted idle and all other 31 clip records")
	var textures_ok := true
	for reference in Library.data()["textures"].values():
		var texture: Texture2D = Library.texture(reference)
		textures_ok = textures_ok and texture != null and texture.get_width()==int(reference["size"][0]) and texture.get_height()==int(reference["size"][1])
	check.call(textures_ok,"c8 trial and base textures load at their original cropped dimensions")
	for profile in ["katana","greatsword","shortsword"]:
		for facing in [1,-1]:
			p._clear_move()
			p.state = Player.St.IDLE
			p.position = Vector2(500,p.ground_y)
			p.depth_y = 0
			p.velocity = Vector2.ZERO
			p.facing = facing
			p.invincible = 99999
			p.control_enabled = true
			main.bm.freeze = 0
			main.weapon_rig.set_profile(profile)
			for monster in main.monsters:
				monster.control_enabled = false
				monster.position.x = 1100
			var target: Monster = main.monsters[0]
			target.position = Vector2(500+100*facing,p.ground_y)
			target.depth_y = 0
			target.hp = 2000
			target.invincible = 0
			p._start_move("attack1")
			await frames.call(50)
			check.call(target.hp<2000 and not p.contact_log.is_empty(),"c8 first cut hits with actual gameplay blade %s face%d" % [profile,facing])
	p._clear_move()
	p.state = Player.St.IDLE
	main._on_gm_command("art",PackedStringArray(["v7"]))
	await frames.call(2)
	check.call(Library.clip("attack1")==original["clips"]["attack1"] and not Library.data().has("trial_scope"),"c8 GM trial returns to the original c6 package without stale surfaces")
