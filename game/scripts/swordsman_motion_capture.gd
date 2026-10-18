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
			var path := "%s/f%05d.png" % [folder,number]
			if not OS.has_feature("movie") or number in [0,85,100,115,175,195,275,310,410,460]:
				root.get_texture().get_image().save_png(path)
			var snap: Dictionary = main.player.v7_renderer.call("snapshot")
			evidence.append({"frame":number,"render_frame":Engine.get_frames_drawn(),"physics_frame":Engine.get_physics_frames(),"tag":tag,"clip":snap.get("clip",""),"clock":snap.get("clock",0),"position":[main.player.position.x,main.player.position.y],"facing":main.player.facing,"profile":snap.get("profile","")})
			evidence[-1]["invincible"] = main.player.invincible
			evidence[-1]["visible_tint"] = [main.player.modulate.r,main.player.modulate.g,main.player.modulate.b,main.player.modulate.a]
			number += 1

func _run() -> void:
	if OS.has_feature("movie"):folder="res://../temp/v7_c6_movie_opaque"
	if "--feedback" in OS.get_cmdline_user_args():folder="res://../temp/v7_c7_feedback_capture"
	if "--hurt-no-flash" in OS.get_cmdline_user_args():folder="res://../temp/v7_c7_hurt_no_flash"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	await _frames(3)
	DisplayServer.window_set_size(Vector2i(2560,1440))
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
	await _frames(120)
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
