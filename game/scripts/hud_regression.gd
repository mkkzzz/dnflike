extends SceneTree
## Functional HUD checks. --hud-capture additionally records real framebuffer images.
var main_ref
var checks := 0
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures += 1
	print("[HUD_TEST] %s %s" % ["PASS" if condition else "FAIL", label])

func _frames(count: int) -> void:
	for i in count:
		await physics_frame

func _capture(label: String) -> void:
	if not "--hud-capture" in OS.get_cmdline_user_args():
		return
	await RenderingServer.frame_post_draw
	var directory := ProjectSettings.globalize_path("res://../temp/hud_runtime")
	DirAccess.make_dir_recursive_absolute(directory)
	var image := root.get_texture().get_image()
	_check(image.save_png(directory.path_join(label + ".png")) == OK, "runtime framebuffer saved: " + label)

func _run() -> void:
	main_ref = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main_ref)
	current_scene = main_ref
	await _frames(5)
	var hud: Hud = main_ref.hud
	_check(hud._root.scale == Vector2(0.5, 0.5) and hud._root.size == Vector2(2560, 1440), "native 2K canvas uses display-resolution rendering")
	_check(hud._textures.size() == 20 and hud._textures.values().all(func(value): return value is Texture2D), "all generated runtime artwork loads")
	_check(main_ref._fps_readout == null and not main_ref._hint.visible, "old FPS panel and debug help do not render")
	_check(not main_ref._wave_notice.text.contains("10001"), "room announcement contains no internal module ID")
	_check(InputMap.action_get_events("debug_job").is_empty() and InputMap.action_get_events("debug_reset").is_empty(), "T and R are no longer debug shortcuts")
	hud.skill_slots = hud._default_slots()
	_check(hud.skill_slots.size() == 12 and hud.skill_slots[6] == "quick_draw" and hud.skill_slots[7] == "thrust", "two real skills populate A/S in twelve slots")
	_check(hud._map_positions.size() == 5 and hud.room_idx == 0, "minimap uses actual five-room dungeon graph")
	main_ref.dungeon.room_index = 1
	main_ref._load_room({}, true)
	for monster in main_ref.monsters:
		monster.control_enabled = false
	await _frames(4)
	_check(hud.room_idx == 1 and hud.target != null, "room travel updates map and actual target")
	main_ref.player.hp = 640
	main_ref.player.mp = 160
	await _frames(2)
	_check(hud.vitals_hp == 640 and hud.vitals_mp == 160, "damage and mana changes reach reservoirs")
	hud.move_skill_slot(6, 0, false)
	_check(hud.skill_slots[0] == "quick_draw" and hud.skill_slots[6] == "", "skill can move from A to Q without changing its identity")
	var key := InputEventKey.new()
	key.physical_keycode = KEY_Q
	key.pressed = true
	main_ref._unhandled_input(key)
	await _frames(3)
	_check(main_ref.player.mp == 115 and main_ref.player.cds.get("quick_draw", 0) > 0, "rebound Q actually casts skill with real MP and cooldown")
	_check(float(hud._cooldowns.get(0, 0)) > 0, "cooldown follows skill after slot move")
	await _frames(48)
	main_ref.player.input_buffer.clear()
	main_ref.player.cds.clear()
	main_ref.player.mp = 0
	main_ref._unhandled_input(key)
	await _frames(3)
	_check(main_ref.player.mp == 0 and main_ref.player.cds.get("quick_draw", 0) == 0, "insufficient MP cannot cast through the new HUD")
	main_ref.player.input_buffer.clear()
	main_ref.player.hp = 500
	main_ref.player.potion_cd = 0
	main_ref._on_hud_action_requested("potion_hp")
	await _frames(3)
	_check(main_ref.player.hp == 800 and main_ref.player.potion_cd > 0, "potion slot uses existing healing and shared cooldown")
	hud.set_front_occlusion(1)
	_check(hud._bottom_layer.modulate.a < 0.4, "entire new bottom HUD yields at foreground")
	hud.set_front_occlusion(0)
	_check(hud._bottom_layer.modulate.a > 0.95, "bottom HUD returns behind road foreground")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = Vector2(715, 685)
	main_ref._unhandled_input(click)
	_check(main_ref._settings_card.visible and paused, "painted wheel gear opens real settings and pauses")
	main_ref._toggle_display_settings()
	_check(not main_ref._settings_card.visible and not paused, "settings close restores game control")
	hud.skill_slots = hud._default_slots()
	main_ref.player.input_buffer.clear()
	main_ref.player.cds.clear()
	main_ref.player.hp = 1000
	main_ref.player.mp = 300
	main_ref.player.potion_cd = 0
	if "--hud-capture" in OS.get_cmdline_user_args():
		# Arrange actual actors for a readable UI inspection, then stop their AI.
		main_ref.player.relocate_combat(Vector2(650, main_ref.GROUND_Y), 0)
		main_ref.player.invincible = 1000
		for i in main_ref.monsters.size():
			var monster = main_ref.monsters[i]
			monster.position.x = 900 + i * 150
			monster.depth_y = 0
			monster.state = monster.St.IDLE
			monster._anim_step()
			monster.process_mode = Node.PROCESS_MODE_DISABLED
	await _frames(125)
	await _capture("hud_live")
	main_ref.player.hp = 450
	main_ref.player.mp = 100
	main_ref.player.cds["quick_draw"] = 240
	main_ref.hit_chain = 7
	main_ref.last_hit_time = main_ref.elapsed
	hud.set_combo(7)
	await _frames(2)
	await _capture("hud_live_states")
	print("[HUD_TEST] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
