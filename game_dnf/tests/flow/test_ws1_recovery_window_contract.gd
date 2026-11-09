extends SceneTree
## ws1-owned death/revival window, focus and retry contract.
const Loop = preload("res://flow/loop_root.gd")
const Recovery = preload("res://flow/recovery.gd")
const EventBus = preload("res://core/event_bus.gd")

class FakeCombat:
	var revive_allowed := true
	var apply_allowed := true
	var revive_calls := 0
	var paused := false
	var bus = EventBus.new()

	func can_revive(_spec: Dictionary) -> bool:
		return revive_allowed

	func revive(_spec: Dictionary) -> bool:
		revive_calls += 1
		return apply_allowed

	func set_paused(value: bool) -> void:
		paused = value

	func events():
		return bus

	func read_view() -> Dictionary:
		return {"room_cleared":false}

var checks := 0
var failures := 0
var capture_dir := ""
var game
var fake: FakeCombat
var store_path := ""
var initial_gold := 0
var next_death := 1

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var capture := "--capture" in args
	if capture:
		capture_dir = String(args[args.find("--output") + 1]) \
			if args.find("--output") >= 0 and args.find("--output") + 1 < args.size() else ""
		if OS.get_environment("DNF_PRIVATE_DESKTOP") != "1" \
			or DisplayServer.get_name() == "headless" or capture_dir == "":
			push_error("[WS1_RECOVERY] capture requires the private desktop and --output")
			quit(1)
			return
	elif DisplayServer.get_name() != "headless":
		push_error("[WS1_RECOVERY] headless display required")
		quit(1)
		return
	call_deferred("run")

func check(value: bool, message: String) -> void:
	checks += 1
	if value:
		print("[WS1_RECOVERY] PASS " + message)
	else:
		failures += 1
		push_error("[WS1_RECOVERY] FAIL " + message)

func frames(count := 3) -> void:
	for _index in count:
		await process_frame

func find_control(node_name: String) -> Control:
	for node in game.modal.find_children(node_name, "Control", true, false):
		var control := node as Control
		if control != null and not control.is_queued_for_deletion():
			return control
	return null

func press_key(code: int) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = true
	Input.parse_input_event(event)
	await frames(1)
	var release := event.duplicate() as InputEventKey
	release.pressed = false
	Input.parse_input_event(release)
	await frames(4)

func setup_game() -> void:
	game = Loop.new()
	root.add_child(game)
	await frames(4)
	var unique := Crypto.new().generate_random_bytes(8).hex_encode()
	store_path = "res://../temp/ws1_recovery_window_tests/profile_" + unique + ".json"
	game.test_mode = true
	game.store.path = store_path
	game.characters.directory = "res://../temp/ws1_recovery_window_tests/characters_" + unique
	game.characters.legacy_path = "res://../temp/ws1_recovery_window_tests/legacy_" + unique + ".json"
	game.session = game.Session.new()
	game.session.profile["name"] = "复活契约剑士"
	game.session.profile["gold"] = 1000
	game.session.profile["resurrection_coins"] = 3
	initial_gold = int(game.session.profile["gold"])
	check(game.store.write(game.session),"disposable revival character is written")
	check(game.enter_character(store_path),"disposable revival character enters the formal flow")
	await frames(4)
	game.ui_audio.muted = true
	game.town.set_voice_enabled(false)
	game.town.stop_npc_voices(true)
	check(game.session.command("flow.depart")["ok"],"fixture starts a complete adventure state")
	fake = FakeCombat.new()
	game.combat = fake

func death_event() -> Dictionary:
	var event_id := next_death
	next_death += 1
	return {
		"type":"combat.player_defeated",
		"run_id":game.session.run["id"],
		"room_id":"forest_trial:0",
		"room_index":0,
		"event_id":event_id,
		"stats":{"time_ms":1000.0 + event_id,"damage_taken":500},
	}

func open_death() -> void:
	var response: Dictionary = game.session.combat_event(death_event())
	check(response.get("ok",false),"fixture enters the published defeated state")
	game.recovery_bridge.reset()
	game.show_overlay("death")
	await frames(4)

func layout_contract() -> void:
	var window := find_control("death_window")
	check(window != null and window.position == Vector2(200,118) and window.size == Vector2(400,272),
		"death prompt keeps the native 400x272 board")
	var revive := find_control("recovery_window_revive") as Button
	var back := find_control("recovery_window_return") as Button
	var feedback := find_control("recovery_window_feedback") as Label
	check(revive != null and not revive.disabled and back != null and not back.disabled,
		"affordable death exposes enabled revive and return actions")
	check(feedback != null and not feedback.visible,
		"normal quote starts without a stale error receipt")
	check(root.gui_get_focus_owner() == revive,
		"death prompt focuses the primary revive action")
	check(revive.focus_mode == Control.FOCUS_ALL and back.focus_mode == Control.FOCUS_ALL,
		"both death actions accept keyboard focus")
	check(revive.focus_neighbor_right != NodePath()
		and revive.get_node_or_null(revive.focus_neighbor_right) == back,
		"revive focus chain reaches the return action")

func insufficient_and_success_contract() -> void:
	game.session.profile["resurrection_coins"] = 0
	game.show_overlay("death")
	await frames(4)
	var revive := find_control("recovery_window_revive") as Button
	var back := find_control("recovery_window_return") as Button
	check(revive != null and revive.disabled and back != null and not back.disabled,
		"insufficient coins disable revival and leave return available")
	check(root.gui_get_focus_owner() == back,
		"disabled revival routes focus to the available return action")
	await press_key(KEY_X)
	var feedback := find_control("recovery_window_feedback") as Label
	check(game.session.state == "defeated" and int(game.session.profile["resurrection_coins"]) == 0
		and feedback != null and feedback.visible and feedback.text.contains("不足"),
		"X reports insufficient coins in-window without changing the death state")
	game.session.profile["resurrection_coins"] = 3
	game.show_overlay("death")
	await frames(4)
	var calls_before := fake.revive_calls
	await press_key(KEY_X)
	check(game.session.state == "battle" and game.overlay == ""
		and int(game.session.profile["resurrection_coins"]) == 2
		and fake.revive_calls == calls_before + 1,
		"X commits one revival and closes the prompt exactly once")

func unavailable_and_save_failure_contract() -> void:
	await open_death()
	fake.revive_allowed = false
	var coins_before := int(game.session.profile["resurrection_coins"])
	await press_key(KEY_X)
	var feedback := find_control("recovery_window_feedback") as Label
	check(game.session.state == "defeated"
		and int(game.session.profile["resurrection_coins"]) == coins_before
		and feedback != null and feedback.visible and feedback.text.contains("无法原地复活"),
		"cross-room or unavailable combat rejects before charging a coin")
	fake.revive_allowed = true
	game.store.path = "res://data/recovery.json/cannot_write.json"
	await press_key(KEY_X)
	feedback = find_control("recovery_window_feedback") as Label
	check(game.session.state == "defeated"
		and int(game.session.profile["resurrection_coins"]) == coins_before
		and feedback != null and feedback.visible and feedback.text.contains("存档写入失败"),
		"failed revival save keeps the coin and reports an in-window retry reason")
	game.store.path = store_path
	var calls_before := fake.revive_calls
	await press_key(KEY_X)
	check(game.session.state == "battle"
		and int(game.session.profile["resurrection_coins"]) == coins_before - 1
		and fake.revive_calls == calls_before + 1,
		"retry after save failure charges exactly one coin")

func effect_retry_contract() -> void:
	await open_death()
	fake.apply_allowed = false
	var coins_before := int(game.session.profile["resurrection_coins"])
	var calls_before := fake.revive_calls
	await press_key(KEY_X)
	var retry := find_control("recovery_window_retry_effect") as Button
	check(game.session.state == "battle" and not game.recovery_bridge.pending_effect.is_empty()
		and int(game.session.profile["resurrection_coins"]) == coins_before - 1,
		"combat effect failure saves one charge and preserves a retry token")
	check(retry != null and root.gui_get_focus_owner() == retry,
		"failed combat effect focuses the dedicated retry action")
	fake.apply_allowed = true
	await press_key(KEY_X)
	check(game.session.state == "battle" and game.overlay == ""
		and game.recovery_bridge.pending_effect.is_empty()
		and int(game.session.profile["resurrection_coins"]) == coins_before - 1
		and fake.revive_calls == calls_before + 2,
		"X retries the saved revival effect without charging again")

func limit_and_return_contract() -> void:
	await open_death()
	var revive := find_control("recovery_window_revive") as Button
	var back := find_control("recovery_window_return") as Button
	var text := ""
	for label in find_control("death_window").find_children("*","Label",true,false):
		text += (label as Label).text
	check(revive != null and revive.disabled and text.contains("次数已用完"),
		"adventure revival limit disables the action and explains the reason")
	check(back != null and not back.disabled and root.gui_get_focus_owner() == back,
		"limit fallback focuses the only available return action")
	var settled_before: Dictionary = game.session.profile["settled"].duplicate(true)
	back.pressed.emit()
	await frames(6)
	check(game.session.state == "town" and game.session.run.is_empty()
		and int(game.session.profile["gold"]) == initial_gold,
		"return town settles the failed adventure without clear reward")
	check(game.session.profile["settled"] != settled_before,
		"failed return records the settled adventure exactly once")

func capture_frame(name: String, scale_factor: int) -> void:
	if capture_dir == "":
		return
	root.min_size = Vector2i(1,1)
	root.max_size = Vector2i(8192,8192)
	root.content_scale_size = Vector2i(800,600) * scale_factor
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	root.size = root.content_scale_size
	game.transform = Transform2D(0.0,Vector2.ONE * scale_factor,0.0,Vector2.ZERO)
	(game.ui.get_parent() as CanvasLayer).transform = Transform2D(0.0,Vector2.ONE * scale_factor,0.0,Vector2.ZERO)
	await frames(3)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(capture_dir))
	var path := capture_dir.path_join(name + ".png")
	var image := root.get_texture().get_image()
	var error := image.save_png(path)
	check(error == OK and image.get_size() == Vector2i(800,600) * scale_factor,
		"capture %s writes actual %dx%d pixels" % [name,image.get_width(),image.get_height()])
	var colored := 0
	for y in range(0,image.get_height(),20):
		for x in range(0,image.get_width(),20):
			if not image.get_pixel(x,y).is_equal_approx(Color.BLACK):
				colored += 1
	check(colored > 100,"capture %s contains a nonblank death prompt" % name)
	if error == OK:
		print("[WS1_RECOVERY] CAPTURE " + path)

func capture_contract() -> void:
	if capture_dir == "":
		return
	game.session.profile["resurrection_coins"] = 3
	game.show_overlay("death")
	await frames(4)
	await capture_frame("recovery_window_1x",1)
	await capture_frame("recovery_window_2x",2)
	root.min_size = Vector2i(1,1)
	root.max_size = Vector2i(8192,8192)
	root.content_scale_size = Vector2i(800,600)
	root.size = Vector2i(800,600)
	game.transform = Transform2D.IDENTITY
	(game.ui.get_parent() as CanvasLayer).transform = Transform2D.IDENTITY
	await frames(2)

func run() -> void:
	await setup_game()
	await open_death()
	layout_contract()
	await capture_contract()
	await insufficient_and_success_contract()
	await unavailable_and_save_failure_contract()
	await effect_retry_contract()
	await limit_and_return_contract()
	finish()

func finish() -> void:
	var code := 1 if failures else 0
	print("[WS1_RECOVERY] COMPLETE checks=%d failures=%d" % [checks,failures])
	if is_instance_valid(game):
		game.queue_free()
		await process_frame
	quit(code)
