extends SceneTree
## ws1-owned display geometry, letterbox, hit-test and F11 contract.
const Loop = preload("res://flow/loop_root.gd")
const DisplaySettings = preload("res://ui/flow/display_settings.gd")

var game
var checks := 0
var failures := 0
var capture_dir := ""

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var capture := "--capture" in args
	if capture:
		capture_dir = String(args[args.find("--output") + 1]) \
			if args.find("--output") >= 0 and args.find("--output") + 1 < args.size() else ""
		if OS.get_environment("DNF_PRIVATE_DESKTOP") != "1" \
			or DisplayServer.get_name() == "headless" or capture_dir == "":
			push_error("[WS1_DISPLAY] capture requires the private desktop and --output")
			quit(1)
			return
	elif DisplayServer.get_name() != "headless":
		push_error("[WS1_DISPLAY] headless display required")
		quit(1)
		return
	call_deferred("run")

func check(value: bool, message: String) -> void:
	checks += 1
	if value:
		print("[WS1_DISPLAY] PASS " + message)
	else:
		failures += 1
		push_error("[WS1_DISPLAY] FAIL " + message)

func frames(count := 3) -> void:
	for _index in count:
		await process_frame

func click_physical(point: Vector2i) -> void:
	var press := InputEventMouseButton.new()
	press.position = Vector2(point)
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	Input.parse_input_event(press)
	await frames(1)
	var release := press.duplicate() as InputEventMouseButton
	release.pressed = false
	Input.parse_input_event(release)
	await frames(4)

func press_key(code: int) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = true
	Input.parse_input_event(event)
	await frames(2)
	var release := event.duplicate() as InputEventKey
	release.pressed = false
	Input.parse_input_event(release)
	await frames(4)

func geometry_contract() -> void:
	check(DisplaySettings.owns_window(false) and not DisplaySettings.owns_window(true),
		"embedded editor delegates window ownership while standalone mode manages it")
	check(DisplaySettings.OUTPUT == Vector2i(1600,1200)
		and DisplaySettings.NATIVE == Vector2i(800,600)
		and is_equal_approx(DisplaySettings.CONTENT_SCALE,2.0),
		"native 800x600 canvas keeps the exact 1600x1200 two-times output")
	check(DisplaySettings.fit_window_size(Vector2i(2560,1400)) == Vector2i(1600,1200),
		"a full desktop keeps the exact fixed window")
	check(DisplaySettings.fit_window_size(Vector2i(1366,768)) == Vector2i(1024,768),
		"a smaller work area fits a proportional 4:3 window without leaving the desktop")
	var negative_area := Rect2i(-1920,0,1920,1080)
	var negative_size := DisplaySettings.fit_window_size(negative_area.size)
	var negative_center := DisplaySettings.centered_position(negative_area,negative_size)
	check(negative_size == Vector2i(1440,1080) and negative_area.encloses(Rect2i(negative_center,negative_size)),
		"negative-coordinate secondary screen keeps its origin and exact visible bounds")
	check(negative_center.x < 0 and negative_center == Vector2i(-1680,0),
		"center calculation does not incorrectly clamp a negative screen to zero")
	var preserved := DisplaySettings.restored_position(Vector2i(-1760,20),negative_area,negative_size)
	check(negative_area.encloses(Rect2i(preserved,negative_size)) and preserved.x == -1760 and preserved.y == 0,
		"a partially offscreen negative restore clamps inside that same screen")
	var current_area := Rect2i(0,0,1920,1040)
	var current_size := DisplaySettings.fit_window_size(current_area.size)
	var disconnected := DisplaySettings.restored_position(Vector2i(-1760,20),current_area,current_size)
	check(disconnected == DisplaySettings.centered_position(current_area,current_size)
		and current_area.encloses(Rect2i(disconnected,current_size)),
		"a disconnected original screen recenters the restored window on the current area")
	var partially_visible := DisplaySettings.restored_position(Vector2i(-100,30),Rect2i(0,0,1920,1200),Vector2i(1600,1200))
	check(partially_visible == Vector2i.ZERO,
		"a partially visible ordinary restore clamps to a fully usable position")
	check(DisplaySettings.letterbox_rect(Vector2i(1600,1200)) == Rect2i(0,0,1600,1200),
		"the exact 4:3 window has no pillarbox")
	check(DisplaySettings.letterbox_rect(Vector2i(1920,1080)) == Rect2i(240,0,1440,1080),
		"a 16:9 fullscreen frame produces exact black pillarboxes")
	check(DisplaySettings.window_to_native(Vector2i(239,540),Vector2i(1920,1080)) == Vector2i(-1,-1)
		and DisplaySettings.window_to_native(Vector2i(240,0),Vector2i(1920,1080)) == Vector2i.ZERO,
		"window hit testing rejects the black bar and accepts the content origin")
	check(DisplaySettings.window_to_native(Vector2i(1679,1079),Vector2i(1920,1080)) == Vector2i(799,599),
		"last visible fullscreen pixel maps inside the native canvas")
	check(DisplaySettings.native_to_window(Vector2(400,300),Vector2i(1920,1080)) == Vector2i(960,540),
		"logical center maps to the center of a pillarboxed fullscreen frame")

func setup_game() -> void:
	game = Loop.new()
	root.add_child(game)
	await frames(4)
	var unique := Crypto.new().generate_random_bytes(8).hex_encode()
	game.test_mode = true
	game.characters.directory = "res://../temp/ws1_display_tests/characters_" + unique
	game.characters.legacy_path = "res://../temp/ws1_display_tests/legacy_" + unique + ".json"
	game.store.path = "res://../temp/ws1_display_tests/profile_" + unique + ".json"
	game.show_character_selection()
	await frames(4)
	game.ui_audio.muted = true
	game.town.set_voice_enabled(false)
	game.town.stop_npc_voices(true)

func window_fixture_contract() -> void:
	var original_mode := root.mode
	var lens = DisplaySettings.new()
	lens.setup(root,true,Rect2i(-1920,0,1920,1080))
	check(lens.windowed_size == Vector2i(1440,1080) and root.size == lens.windowed_size,
		"window fixture applies a smaller 4:3 window for a short negative screen")
	check(root.content_scale_size == DisplaySettings.OUTPUT and root.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_KEEP,
		"small physical window still keeps the fixed 1600x1200 content setting")
	lens.window_position = Vector2i(-1760,0)
	root.position = lens.window_position
	lens.toggle_fullscreen(Rect2i(-1920,0,1920,1080))
	check(lens.is_fullscreen(),"fixture enters fullscreen through the published F11 method")
	if DisplayServer.get_name() != "headless":
		check(root.mode in [Window.MODE_FULLSCREEN,Window.MODE_EXCLUSIVE_FULLSCREEN],
			"private desktop observes the real fullscreen window mode")
	lens.window_position = Vector2i(-1760,0)
	lens.toggle_fullscreen(Rect2i(0,0,1920,1040))
	check(not lens.is_fullscreen() and lens.last_restore_recentered
		and Rect2i(0,0,1920,1040).encloses(Rect2i(root.position,root.size)),
		"disconnect during fullscreen restores into the current screen instead of an absent monitor")
	if DisplayServer.get_name() != "headless":
		check(root.mode == Window.MODE_WINDOWED,
			"private desktop restores the real windowed mode after monitor loss")
	for index in 4:
		lens.toggle_fullscreen(Rect2i(0,0,1920,1040))
		lens.toggle_fullscreen(Rect2i(0,0,1920,1040))
		check(not lens.is_fullscreen() and root.size == lens.windowed_size
			and Rect2i(0,0,1920,1040).encloses(Rect2i(root.position,root.size)),
			"repeated fullscreen cycle %d restores a valid fixed window" % (index + 1))
	lens.toggle_fullscreen(Rect2i(0,0,1366,768))
	lens.toggle_fullscreen(Rect2i(0,0,1366,768))
	check(root.size == Vector2i(1024,768)
		and Rect2i(0,0,1366,768).encloses(Rect2i(root.position,root.size)),
		"work area smaller than output restores a visible proportional window")
	root.mode = original_mode
	game.display_settings.setup(root,true,Rect2i(0,0,1920,1200))
	await frames(3)
	await press_key(KEY_F11)
	check(game.display_settings.is_fullscreen(),
		"F11 enters fullscreen through the formal input route")
	await press_key(KEY_F11)
	check(not game.display_settings.is_fullscreen(),
		"second F11 restores windowed mode through the same route")

func configure_frame(frame_size: Vector2i) -> void:
	root.mode = Window.MODE_WINDOWED
	root.min_size = Vector2i(1,1)
	root.max_size = Vector2i(8192,8192)
	root.content_scale_size = DisplaySettings.OUTPUT
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	root.content_scale_stretch = Window.CONTENT_SCALE_STRETCH_FRACTIONAL
	root.size = frame_size
	await frames(3)

func interactive_letterbox_contract() -> void:
	await configure_frame(Vector2i(1920,1080))
	var screen = game.character_screen
	check(screen.size == Vector2(800,600) and game.ui.size == Vector2(800,600),
		"fullscreen letterbox still presents the native 800x600 canvas")
	check(game.skin.font.oversampling == DisplaySettings.CONTENT_SCALE,
		"Chinese UI font renders at the fixed two-times density")
	await click_physical(Vector2i(100,987))
	check(not screen.creating,
		"physical clicks inside the black bar do not hit the native create action")
	var create_center := DisplaySettings.native_to_window(Vector2(94.5,548.5),Vector2i(1920,1080))
	await click_physical(create_center)
	check(screen.creating and is_instance_valid(screen.name_input),
		"physical click through the pillarbox reaches the scaled native create action")
	screen.handle_key(KEY_ESCAPE)
	await frames(3)

func capture_frame(name: String, frame_size: Vector2i) -> void:
	if capture_dir == "":
		return
	await configure_frame(frame_size)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(capture_dir))
	var path := capture_dir.path_join(name + ".png")
	var image: Image
	if frame_size == Vector2i(1920,1080):
		check(root.size == frame_size,
			"fullscreen test window owns the requested 1920x1080 client area")
		var content := root.get_texture().get_image()
		var content_rect := DisplaySettings.letterbox_rect(frame_size)
		content.resize(content_rect.size.x,content_rect.size.y,Image.INTERPOLATE_BILINEAR)
		image = Image.create(frame_size.x,frame_size.y,false,Image.FORMAT_RGBA8)
		image.fill(Color.BLACK)
		image.blit_rect(content,Rect2i(Vector2i.ZERO,content_rect.size),content_rect.position)
		check(content_rect == Rect2i(240,0,1440,1080),
			"layout composition uses the same exact pillarbox rectangle as hit testing")
	else:
		image = root.get_texture().get_image()
	var error := image.save_png(path)
	check(error == OK and image.get_size() == frame_size,
		"capture %s writes actual %dx%d pixels" % [name,image.get_width(),image.get_height()])
	var colored := 0
	for y in range(0,image.get_height(),20):
		for x in range(0,image.get_width(),20):
			if not image.get_pixel(x,y).is_equal_approx(Color.BLACK):
				colored += 1
	check(colored > 100,"capture %s contains a nonblank rendered frame" % name)
	if frame_size == Vector2i(1920,1080):
		var left := image.get_pixel(100,540)
		var inside := image.get_pixel(300,300)
		var right := image.get_pixel(1820,540)
		check(left.is_equal_approx(Color.BLACK) and right.is_equal_approx(Color.BLACK),
			"16:9 capture contains black pillarboxes on both sides")
		check(not inside.is_equal_approx(Color.BLACK),
			"the content area between the pillarboxes remains rendered")
	if error == OK:
		print("[WS1_DISPLAY] CAPTURE " + path)

func capture_contract() -> void:
	if capture_dir == "":
		return
	await capture_frame("display_windowed_1600x1200",Vector2i(1600,1200))
	await capture_frame("display_fullscreen_1920x1080",Vector2i(1920,1080))
	await configure_frame(Vector2i(1600,1200))

func environment_report() -> void:
	var usable := Rect2i()
	var screen := root.current_screen
	if DisplayServer.get_name() != "headless" and screen >= 0 and screen < DisplayServer.get_screen_count():
		usable = DisplayServer.screen_get_usable_rect(screen)
	print("[WS1_DISPLAY] ENV backend=%s embedded=%s screens=%d current=%d usable=%s output=%s" % [
		DisplayServer.get_name(),str(Engine.is_embedded_in_editor()),DisplayServer.get_screen_count(),
		screen,str(usable),str(DisplaySettings.OUTPUT)])

func run() -> void:
	geometry_contract()
	await setup_game()
	environment_report()
	await window_fixture_contract()
	await interactive_letterbox_contract()
	await capture_contract()
	finish()

func finish() -> void:
	var code := 1 if failures else 0
	print("[WS1_DISPLAY] COMPLETE checks=%d failures=%d" % [checks,failures])
	if is_instance_valid(game):
		game.queue_free()
		await process_frame
	quit(code)
