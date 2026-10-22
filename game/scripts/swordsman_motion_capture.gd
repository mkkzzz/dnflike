extends SceneTree
## Actual engine playback at native 2K. Run with --fixed-fps 60 and an offscreen
## desktop window; headless rendering cannot supply an acceptance screenshot.
var main: Node
var number := 0
var evidence: Array = []
var folder := "res://../temp/v7_c6_gameplay"

func _initialize() -> void:
	_run.call_deferred()

func _frames(count: int, tag := "") -> void:
	for i in count:
		await physics_frame
		if tag != "":
			await RenderingServer.frame_post_draw
			var lossless_webp := "--lossless-webp" in OS.get_cmdline_user_args()
			var path := ("%s/f%05d.webp" if lossless_webp else "%s/f%05d.png") % [folder,number]
			var framebuffer_rgb_sha256 := ""
			if not OS.has_feature("movie") or number in [0,85,100,115,175,195,275,310,410,460]:
				var framebuffer := root.get_texture().get_image()
				framebuffer.convert(Image.FORMAT_RGB8)
				var pixel_digest := HashingContext.new()
				pixel_digest.start(HashingContext.HASH_SHA256)
				pixel_digest.update(framebuffer.get_data())
				framebuffer_rgb_sha256 = pixel_digest.finish().hex_encode()
				# Image.save_webp's boolean is `lossy`, not `lossless`.
				if lossless_webp:framebuffer.save_webp(path,false,0.0)
				else:framebuffer.save_png(path)
			var snap: Dictionary = main.player.v7_renderer.call("snapshot")
			evidence.append({"frame":number,"render_frame":Engine.get_frames_drawn(),"physics_frame":Engine.get_physics_frames(),"tag":tag,"clip":snap.get("clip",""),"clock":snap.get("clock",0),"position":[main.player.position.x,main.player.position.y],"facing":main.player.facing,"profile":snap.get("profile","")})
			evidence[-1]["invincible"] = main.player.invincible
			evidence[-1]["framebuffer_rgb_sha256"] = framebuffer_rgb_sha256
			evidence[-1]["visible_tint"] = [main.player.modulate.r,main.player.modulate.g,main.player.modulate.b,main.player.modulate.a]
			evidence[-1]["source_pose"] = snap.get("frame",{}).get("source_pose","")
			evidence[-1]["body_layers"] = []
			for source in snap.get("body_sources",[]):evidence[-1]["body_layers"].append({"file":source["frame"]["body"].get("file",""),"weight":source["weight"]})
			number += 1

func _run() -> void:
	if OS.has_feature("movie"):folder="res://../temp/v7_c6_movie_opaque"
	if "--feedback" in OS.get_cmdline_user_args():folder="res://../temp/v7_c7_feedback_capture"
	if "--hurt-no-flash" in OS.get_cmdline_user_args():folder="res://../temp/v7_c7_hurt_no_flash"
	if "--first-cut-c8" in OS.get_cmdline_user_args():folder="res://../temp/v7_c8_first_cut"
	if "--run-combo-c10" in OS.get_cmdline_user_args():folder="res://../temp/v7_c10_run_combo_capture"
	if "--run-combo-c10" in OS.get_cmdline_user_args() and "--lossless-webp" in OS.get_cmdline_user_args():folder+="_webp_lossless"
	if "--c10-1080p-smoke" in OS.get_cmdline_user_args():folder="res://../temp/v7_c10_1080p_capture"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	await _frames(3)
	DisplayServer.window_set_size(Vector2i(2560,1440))
	if "--c10-1080p-smoke" in OS.get_cmdline_user_args():DisplayServer.window_set_size(Vector2i(1920,1080))
	main._start_demo(0)
	await _frames(3)
	var p: Player = main.player
	p.position = Vector2(570,p.ground_y)
	# Passive targets are moved out of range. Avoid the invulnerability blink,
	# which would otherwise look like a transparency/interpolation artifact.
	p.invincible = 0
	for monster in main.monsters:
		monster.control_enabled = false
		monster.position.x = 1190
	p.v7_renderer.call("set_enabled",true)
	main.bm.visible = false
	main.hud.hide()
	if "--first-cut-c8" in OS.get_cmdline_user_args():
		main._on_gm_command("art",PackedStringArray(["v7c8"]))
	if "--run-combo-c10" in OS.get_cmdline_user_args():
		main._on_gm_command("art",PackedStringArray(["v7c10"]))
	await _frames(120)
	if "--c10-1080p-smoke" in OS.get_cmdline_user_args():
		await _c10_resolution_smoke(p)
		return
	if "--run-combo-c10" in OS.get_cmdline_user_args():
		await _run_combo_c10_capture(p)
		return
	if "--first-cut-c8" in OS.get_cmdline_user_args():
		await _first_cut_capture(p)
		return
	if "--feedback" in OS.get_cmdline_user_args() or "--hurt-no-flash" in OS.get_cmdline_user_args():
		await _feedback_capture(p)
		return
	await _frames(12 if "--smoke" in OS.get_cmdline_user_args() else 72,"idle")
	if "--smoke" in OS.get_cmdline_user_args():
		p.combo=0
		for hold in [18,18,8]:
			Input.action_press("attack")
			await _frames(1,"combo")
			Input.action_release("attack")
			await _frames(hold-1,"combo")
		root.get_texture().get_image().save_png(folder+"/smoke_native_2k.png")
		print("[V7_CAPTURE] SMOKE COMPLETE")
		quit()
		return
	for profile in ["katana","greatsword","shortsword"]:
		main.weapon_rig.set_profile(profile)
		p.combo = 0
		for hold in [18,18,52]:
			Input.action_press("attack")
			await _frames(1,profile+"_combo")
			Input.action_release("attack")
			await _frames(hold-1,profile+"_combo")
		await _frames(12,profile+"_recover")
	Input.action_press("move_right")
	await _frames(28,"walk_start")
	Input.action_release("move_right")
	await _frames(22,"walk_stop")
	Input.action_press("jump")
	await _frames(10,"jump_rise")
	Input.action_release("jump")
	await _frames(55,"jump_land_recover")
	Input.action_press("move_left")
	await _frames(20,"turn_walk_left")
	Input.action_release("move_left")
	await _frames(20,"stop_left")
	main.hud.show()
	main.gm_panel.open()
	await _frames(2)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(folder+"/gm_native_2k.png")
	FileAccess.open(folder+"/timeline.json",FileAccess.WRITE).store_string(JSON.stringify(evidence,"\t"))
	print("[V7_CAPTURE] COMPLETE frames=",number," folder=",folder)
	quit()

func _first_cut_capture(p: Player) -> void:
	AudioServer.set_bus_mute(0,true)
	for profile in ["katana","greatsword","shortsword"]:
		for direction in [1,-1]:
			p._clear_move()
			p.state = Player.St.IDLE
			p.combo = 0
			p.position = Vector2(570,p.ground_y)
			p.velocity = Vector2.ZERO
			p.facing = direction
			main.bm.freeze = 0
			main.weapon_rig.set_profile(profile)
			await _frames(12,profile+"_idle_face"+str(direction))
			Input.action_press("attack")
			await _frames(1,profile+"_first_cut_face"+str(direction))
			Input.action_release("attack")
			await _frames(45,profile+"_first_cut_face"+str(direction))
	FileAccess.open(folder+"/timeline.json",FileAccess.WRITE).store_string(JSON.stringify(evidence,"\t"))
	var sources := {"base_manifest_sha256":FileAccess.get_sha256("res://assets/swordsman_v7_c6/manifest.json"),"trial_manifest_sha256":FileAccess.get_sha256("res://assets/swordsman_v7_c8/manifest.json"),"trigger":"actual GM art v7c8 and attack input; first cut only, other actions retain existing package"}
	FileAccess.open(folder+"/packages.json",FileAccess.WRITE).store_string(JSON.stringify(sources,"\t"))
	print("[V7_CAPTURE] C8 FIRST CUT COMPLETE frames=",number)
	quit()

func _run_combo_c10_capture(p: Player) -> void:
	AudioServer.set_bus_mute(0,true)
	for profile in ["katana","greatsword","shortsword"]:
		for direction in [1,-1]:
			p._clear_move()
			p.state=Player.St.IDLE
			p.position=Vector2(570,p.ground_y)
			p.velocity=Vector2.ZERO
			p.depth_y=0
			p.facing=direction
			p.running=false
			p.combo=0
			main.bm.freeze=0
			main.weapon_rig.set_profile(profile)
			var tag: String = profile+"_face"+str(direction)
			await _frames(8,tag+"_idle")
			var action := "move_right" if direction==1 else "move_left"
			p.buffer_run(direction)
			Input.action_press(action)
			await _frames(36,tag+"_run")
			Input.action_release(action)
			await _frames(16,tag+"_stop")
			p._clear_move()
			p.state=Player.St.IDLE
			p.running=false
			p.position=Vector2(570,p.ground_y)
			p.velocity=Vector2.ZERO
			p.facing=direction
			p.combo=0
			for hold in [18,18,60]:
				p.buffer_action("attack")
				await _frames(hold,tag+"_combo")
			await _frames(8,tag+"_recover")
			FileAccess.open(folder+"/timeline_progress.json",FileAccess.WRITE).store_string(JSON.stringify(evidence,"\t"))
	FileAccess.open(folder+"/timeline.json",FileAccess.WRITE).store_string(JSON.stringify(evidence,"\t"))
	FileAccess.open(folder+"/packages.json",FileAccess.WRITE).store_string(JSON.stringify({"base_manifest_sha256":FileAccess.get_sha256("res://assets/swordsman_v7_c6/manifest.json"),"c10_manifest_sha256":FileAccess.get_sha256("res://assets/swordsman_v7_c10/manifest.json"),"trigger":"actual run and buffered combo inputs, three profiles and both facings"},"\t"))
	print("[V7_CAPTURE] C10 RUN COMBO COMPLETE frames=",number)
	quit()

func _c10_resolution_smoke(p: Player) -> void:
	AudioServer.set_bus_mute(0,true)
	main._on_gm_command("art",PackedStringArray(["v7c10"]))
	p._clear_move()
	p.state=Player.St.IDLE
	p.running=false
	p.facing=1
	p.combo=0
	main.weapon_rig.set_profile("katana")
	p.buffer_run(1)
	Input.action_press("move_right")
	await _frames(4)
	await _resolution_still(p,"run_start")
	await _frames(16)
	await _resolution_still(p,"run")
	Input.action_release("move_right")
	for _wait in 30:
		await _frames(1)
		if p.v7_renderer.call("current_clip")=="run_stop":break
	await _frames(2)
	await _resolution_still(p,"run_stop")
	await _frames(12)
	p._clear_move()
	p.state=Player.St.IDLE
	p.running=false
	p.position=Vector2(570,p.ground_y)
	p.combo=0
	for name in ["attack1","attack2","attack3"]:
		p.buffer_action("attack")
		await _frames(12)
		await _resolution_still(p,name)
		await _frames(6)
	FileAccess.open(folder+"/resolution_proof.json",FileAccess.WRITE).store_string(JSON.stringify({"source":"actual Godot frame_post_draw","size":[1920,1080],"c10_manifest_sha256":FileAccess.get_sha256("res://assets/swordsman_v7_c10/manifest.json"),"frames":evidence},"\t"))
	print("[V7_CAPTURE] C10 1080P COMPLETE")
	quit()

func _resolution_still(p: Player, requested: String) -> void:
	await RenderingServer.frame_post_draw
	var file: String = requested+"_1080p.png"
	root.get_texture().get_image().save_png(folder+"/"+file)
	var snap: Dictionary = p.v7_renderer.call("snapshot")
	evidence.append({"file":file,"sha256":FileAccess.get_sha256(folder+"/"+file),"requested":requested,"actual_clip":snap["clip"],"clock":snap["clock"]})

func _feedback_capture(p: Player) -> void:
	var hurt_only := "--hurt-no-flash" in OS.get_cmdline_user_args()
	await _frames(12 if hurt_only else 24,"accepted_idle")
	for direction in ([] if hurt_only else [-1,1,-1,1]):
		p.facing = direction
		await _frames(8,"instant_facing")
	var attacker: Monster = main.monsters[0]
	attacker.position = Vector2(p.position.x-70,p.ground_y)
	attacker.depth_y = p.depth_y
	attacker.attack_facing = 1
	attacker.atk_hit_done = false
	attacker.st_t = int(attacker.cfg["attack_move"]["windup"])
	p.invincible = 0
	attacker.call("_attack")
	await _frames(30 if hurt_only else 36,"real_monster_hit_recover")
	attacker.position.x = 1190
	if not hurt_only:
		p.invincible = 0
		p.take_hit(25,-1,{"hardstun":22,"knockback":160})
		await _frames(42,"heavy_hit_recover")
	FileAccess.open(folder+"/timeline.json",FileAccess.WRITE).store_string(JSON.stringify(evidence,"\t"))
	print("[V7_CAPTURE] FEEDBACK COMPLETE frames=",number," folder=",folder)
	quit()
