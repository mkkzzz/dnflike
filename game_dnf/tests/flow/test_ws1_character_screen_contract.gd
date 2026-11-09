extends SceneTree
## ws1-owned character selection/create contract. Uses disposable character files.
const Loop = preload("res://flow/loop_root.gd")

var game
var screen
var checks := 0
var failures := 0
var capture_dir := ""

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var capture := "--capture" in args
	if capture:
		capture_dir = String(args[args.find("--output") + 1]) if args.find("--output") >= 0 and args.find("--output") + 1 < args.size() else ""
		if OS.get_environment("DNF_PRIVATE_DESKTOP") != "1" or DisplayServer.get_name() == "headless" or capture_dir == "":
			push_error("[WS1_CHARACTER] capture requires the private desktop and --output")
			quit(1)
			return
	elif DisplayServer.get_name() != "headless":
		push_error("[WS1_CHARACTER] headless display required")
		quit(1)
		return
	call_deferred("run")

func check(value: bool, message: String) -> void:
	checks += 1
	if value:
		print("[WS1_CHARACTER] PASS " + message)
	else:
		failures += 1
		push_error("[WS1_CHARACTER] FAIL " + message)

func wait_frames(count := 3) -> void:
	for i in count:
		await process_frame

func find_button(text: String) -> Button:
	for button: Button in screen.find_children("*", "Button", true, false):
		if button.text == text or String(button.get_meta("action_label", "")) == text:
			return button
	return null

func click_control(control: Control) -> void:
	var event := InputEventMouseButton.new()
	event.position = control.get_global_transform_with_canvas() * (control.size / 2)
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	game.get_viewport().push_input(event, true)
	event = event.duplicate()
	event.pressed = false
	game.get_viewport().push_input(event, true)

func create(name: String) -> bool:
	screen.show_create()
	await wait_frames(2)
	if not screen.creating or not is_instance_valid(screen.name_input):
		return false
	screen.name_input.text = name
	screen.create_character()
	await wait_frames(3)
	return not screen.creating and game.characters.entries.size() > 0

func layout_checks() -> void:
	check(screen.size == Vector2(800, 600), "character screen is the native 800x600 canvas")
	check(screen.slot_buttons.size() == game.characters.LIMIT, "roster exposes six native slots")
	var slots_ok := true
	for i in screen.slot_buttons.size():
		var slot: Button = screen.slot_buttons[i]
		slots_ok = slots_ok and slot.position == Vector2(38 + i * 122, 180) and slot.size == Vector2(119, 207)
	check(slots_ok, "all six card hit areas use native positions and size")
	check(screen.enter_button != null and screen.enter_button.disabled, "empty roster disables the enter button")
	var create := find_button("创建角色")
	check(create != null and not create.disabled, "empty roster enables the create button")
	check(screen.message_label.text.contains("创建一位鬼剑士"), "empty roster shows the creation hint")

func create_form_checks() -> void:
	screen.show_create()
	await wait_frames(2)
	check(screen.creating and is_instance_valid(screen.name_input) and screen.name_input.has_focus(),
		"create form focuses the real name input")
	check(screen.name_input.position == Vector2(464, 318) and screen.name_input.size.x == 252,
		"name input keeps the native form rectangle: actual_pos=%s actual_size=%s" % [
			str(screen.name_input.position), str(screen.name_input.size)])
	screen.name_input.text = ""
	screen.create_character()
	await wait_frames(2)
	check(screen.message_label.text != "" and game.characters.entries.is_empty() and screen.creating,
		"empty name shows an error without leaving the form")
	screen.handle_key(KEY_ESCAPE)
	await wait_frames(3)
	check(not screen.creating and screen.name_input == null and screen.slot_buttons.size() == 6,
		"Escape returns to the roster and releases the name field")
	check(root.gui_get_focus_owner() == null, "Escape clears the creation focus")

func multi_character_checks() -> void:
	check(await create("冒险家"), "first character is created")
	var first: String = screen.selected_path
	check(not first.is_empty() and game.characters.entries.size() == 1 and screen.actors.size() == 1,
		"created character is selected and has one preview actor")
	check(await create("红莲剑士"), "second character is created")
	var second: String = screen.selected_path
	check(second != first and game.characters.entries.size() == 2 and screen.actors.size() == 2,
		"second character has an independent file and preview actor")
	check(game.characters.entries.any(func(entry): return entry["path"] == first),
		"first character remains in the roster")
	screen.handle_key(KEY_LEFT)
	await wait_frames(3)
	check(screen.selected_path == first, "LEFT switches to the previous character")
	screen.handle_key(KEY_RIGHT)
	await wait_frames(3)
	check(screen.selected_path == second, "RIGHT switches to the next character")
	click_control(screen.slot_buttons[0])
	await wait_frames(3)
	check(screen.selected_path == first, "real pointer click selects the first card")
	check(screen.slot_buttons[0].get_meta("character_index") == 0, "selected card retains its roster index")
	check(screen.actors.size() == 2 and screen.actors.all(func(actor): return is_instance_valid(actor)),
		"all roster preview actors remain valid after selection changes")

func full_roster_checks() -> void:
	for name in ["剑士三", "剑士四", "剑士五", "剑士六"]:
		check(await create(name), "remaining character slot accepts " + name)
	check(game.characters.entries.size() == game.characters.LIMIT, "roster reaches the native six-character limit")
	check(screen.actors.size() == game.characters.LIMIT, "full roster renders six preview actors")
	var create := find_button("创建角色")
	check(create != null and create.disabled, "full roster disables the create button")
	screen.show_create()
	await wait_frames(2)
	check(not screen.creating and screen.message_label.text.contains("位置已满"),
		"full roster explains why creation cannot start")

func capture_frame(name: String) -> void:
	if capture_dir == "":
		return
	root.size = Vector2i(1600, 1200)
	root.content_scale_size = Vector2i(1600, 1200)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(capture_dir))
	var path := capture_dir.path_join(name + ".png")
	var error := root.get_texture().get_image().save_png(path)
	check(error == OK, "capture frame " + name + " writes actual pixels")
	if error == OK:
		print("[WS1_CHARACTER] CAPTURE " + path)

func entry_checks() -> void:
	screen.selected_path = game.characters.entries[0]["path"]
	screen.show_roster()
	await wait_frames(2)
	screen.enter_selected()
	await wait_frames(5)
	check(game.character_active and game.session.profile["name"] == "冒险家",
		"enter callback loads the selected character")
	game.show_character_selection()
	await wait_frames(4)
	screen = game.character_screen
	check(screen.selected_path == game.characters.entries[0]["path"],
		"returning to selection keeps the entered character selected")

func measure_once(label: String, action: Callable, budget_ms: float) -> float:
	var started := Time.get_ticks_usec()
	action.call()
	await process_frame
	var elapsed := (Time.get_ticks_usec() - started) / 1000.0
	print("[WS1_CHARACTER] PERF %s_ms=%.3f budget_ms=%.1f" % [label, elapsed, budget_ms])
	check(elapsed < budget_ms, label + " stays inside the budget")
	return elapsed

func measure_median(label: String, action: Callable, budget_ms: float) -> float:
	var samples: Array[float] = []
	for i in 3:
		var started := Time.get_ticks_usec()
		action.call()
		samples.append((Time.get_ticks_usec() - started) / 1000.0)
		await process_frame
	samples.sort()
	print("[WS1_CHARACTER] PERF %s_median_ms=%.3f peak_ms=%.3f budget_ms=%.1f" % [
		label, samples[1], samples[2], budget_ms])
	check(samples[1] < budget_ms, label + " median stays inside the budget")
	return samples[1]

func performance_checks() -> void:
	await measure_once("full_roster_first", func(): screen.show_roster(), 180.0)
	var first: String = game.characters.entries[0]["path"]
	var second: String = game.characters.entries[1]["path"]
	await measure_median("select_card", func(): screen.select_path(second), 10.0)
	screen.select_path(first)
	await measure_median("open_create_form", func(): screen.show_create(), 60.0)
	await measure_median("open_create_form_hot", func(): screen.show_create(), 60.0)

func run() -> void:
	game = Loop.new()
	root.add_child(game)
	await wait_frames(3)
	var unique := Crypto.new().generate_random_bytes(8).hex_encode()
	game.test_mode = true
	game.characters.directory = "res://../temp/ws1_character_tests/roster_" + unique
	game.characters.legacy_path = "res://../temp/ws1_character_tests/legacy_" + unique + ".json"
	game.store.path = "res://../temp/ws1_character_tests/profile_" + unique + ".json"
	game.show_character_selection()
	await wait_frames(4)
	screen = game.character_screen
	layout_checks()
	await create_form_checks()
	await multi_character_checks()
	if capture_dir != "":
		screen.show_create()
		await wait_frames(3)
		screen.name_input.text = "冒险家"
		await capture_frame("create_form")
		screen.handle_key(KEY_ESCAPE)
		await wait_frames(3)
	await full_roster_checks()
	if capture_dir != "":
		await capture_frame("full_roster")
	await entry_checks()
	await performance_checks()
	finish()

func finish() -> void:
	var code := 1 if failures else 0
	print("[WS1_CHARACTER] COMPLETE checks=%d failures=%d" % [checks, failures])
	if is_instance_valid(game):
		game.queue_free()
		await process_frame
	quit(code)
