extends SceneTree
## One-off rendered capture using the current checkout, without editing game/.
## Run with Godot 4.7.2 --path game --script <absolute path> -- --hud-environment-capture.

var main_ref
var output_dir := ""
var records: Array = []

func _initialize() -> void:
	_run.call_deferred()

func _save(label: String) -> void:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var error := image.save_png(output_dir.path_join(label + ".png"))
	if error != OK:
		push_error("HUD environment screenshot failed: " + str(error))
		quit(2)
	print("[HUD_ENVIRONMENT_CAPTURE] %s %s" % [label, image.get_size()])

func _run() -> void:
	output_dir = ProjectSettings.globalize_path("res://../temp/hud_environment_capture")
	DirAccess.make_dir_recursive_absolute(output_dir)
	var packed = load("res://scenes/Main.tscn")
	main_ref = packed.instantiate()
	root.add_child(main_ref)
	current_scene = main_ref
	await process_frame
	for room_index in [0, 1]:
		if room_index > 0:
			main_ref.dungeon.room_index = room_index
			main_ref._load_room({}, true)
		main_ref.player.control_enabled = false
		for monster in main_ref.monsters:
			monster.control_enabled = false
		main_ref._overlay.hide()
		main_ref.gm_panel.hide()
		main_ref._update_camera()
		for frame in 4:
			await physics_frame
		var label := "entrance" if room_index == 0 else "encounter"
		await _save(label + "_original_hud")
		main_ref.hud.hide()
		await process_frame
		await _save(label + "_clean")
		var target = main_ref._pick_target()
		var target_data: Dictionary = {}
		if target != null:
			target_data = {"name": target.cfg.get("name", "哥布林"), "hp": target.hp,
				"max_hp": target.cfg.get("hp", target.hp)}
		records.append({"label": label, "room_index": room_index,
			"room_number": main_ref.dungeon.room_number(), "room_count": main_ref.dungeon.room_count(),
			"module": main_ref.dungeon.module_id(), "dungeon_name": main_ref.dungeon.display_name(),
			"background": main_ref.dungeon.background_path(), "viewport": [root.size.x, root.size.y],
			"player_hp": main_ref.player.hp, "player_hp_max": main_ref.player.cfg["max_hp"],
			"player_mp": main_ref.player.mp, "player_mp_max": main_ref.player.cfg["max_mp"],
			"player_job": main_ref.player.job, "player_xy": [main_ref.player.position.x, main_ref.player.position.y],
			"monster_count": main_ref.monsters.size(), "target": target_data,
			"old_hud_hidden_for_clean_capture": not main_ref.hud.visible})
	var file := FileAccess.open(output_dir.path_join("capture_state.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(records, "\t"))
	file.close()
	print("[HUD_ENVIRONMENT_CAPTURE] COMPLETE")
	quit(0)
