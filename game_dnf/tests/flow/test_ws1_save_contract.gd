extends SceneTree
## ws1-owned save commit, backup recovery and roster contract.
const Loop = preload("res://flow/loop_root.gd")
const Session = preload("res://flow/session.gd")
const Store = preload("res://save/store.gd")
const Characters = preload("res://save/characters.gd")

var checks := 0
var failures := 0
var capture_dir := ""
var root_dir := ""
var game
var screen
var legacy_path := ""
var valid_path := ""
var recovered_path := ""
var corrupt_path := ""
var blocked_path := ""

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var capture := "--capture" in args
	if capture:
		capture_dir = String(args[args.find("--output") + 1]) \
			if args.find("--output") >= 0 and args.find("--output") + 1 < args.size() else ""
		if OS.get_environment("DNF_PRIVATE_DESKTOP") != "1" \
			or DisplayServer.get_name() == "headless" or capture_dir == "":
			push_error("[WS1_SAVE] capture requires the private desktop and --output")
			quit(1)
			return
	elif DisplayServer.get_name() != "headless":
		push_error("[WS1_SAVE] headless display required")
		quit(1)
		return
	call_deferred("run")

func check(value: bool, message: String) -> void:
	checks += 1
	if value:
		print("[WS1_SAVE] PASS " + message)
	else:
		failures += 1
		push_error("[WS1_SAVE] FAIL " + message)

func frames(count := 3) -> void:
	for _index in count:
		await process_frame

func make_session(character_name: String, gold: int) -> Session:
	var state = Session.new()
	state.profile["name"] = character_name
	state.profile["gold"] = gold
	return state

func write_text(path: String, text: String) -> bool:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(text)
	file.flush()
	var error := file.get_error()
	file.close()
	return error == OK

func read_text(path: String) -> String:
	return FileAccess.get_file_as_string(path)

func profile_gold(path: String) -> int:
	var parsed = JSON.parse_string(read_text(path))
	if not parsed is Dictionary:
		return -1
	return int((parsed as Dictionary).get("profile", {}).get("gold", -1))

func store_contract() -> void:
	var path := root_dir.path_join("profile.json")
	var storage = Store.new()
	storage.path = path
	var first = make_session("提交剑士",111)
	check(storage.write(first),"first main save commits")
	check(FileAccess.file_exists(path) and not FileAccess.file_exists(path + ".bak"),
		"first commit creates no fake recovery copy")
	var second = make_session("提交剑士",222)
	check(storage.write(second),"second main save commits")
	check(FileAccess.file_exists(path + ".bak")
		and profile_gold(path) == 222 and profile_gold(path + ".bak") == 111,
		"valid previous main becomes the one-generation backup")
	var loaded = Session.new()
	check(storage.read_into(loaded) and loaded.profile["name"] == "提交剑士"
		and int(loaded.profile["gold"]) == 222 and not storage.recovered,
		"main save round-trips the complete current session")
	check(write_text(path,"broken primary"),"fixture interrupts the current main save")
	var recovered = make_session("未应覆盖",900)
	check(storage.read_into(recovered) and storage.recovered
		and int(recovered.profile["gold"]) == 111,
		"same Store object detects external corruption and restores the valid backup")
	recovered.profile["gold"] = 333
	check(storage.write(recovered),"recovered character can commit again")
	check(profile_gold(path) == 333 and profile_gold(path + ".bak") == 111
		and not FileAccess.file_exists(path + ".tmp"),
		"recovery commit replaces only the damaged main and preserves the last good backup")
	var fresh = Session.new()
	check(storage.read_into(fresh) and not storage.recovered and int(fresh.profile["gold"]) == 333,
		"fresh read returns the recovered main without repeated backup fallback")
	fresh.profile["gold"] = 444
	check(storage.write(fresh),"restored main accepts the next ordinary save")
	check(profile_gold(path + ".bak") == 333,"second ordinary save advances the backup boundary")

	check(write_text(path + ".tmp","partial main") and write_text(path + ".bak.tmp","partial backup"),
		"fixture leaves interrupted main and backup staging files")
	fresh.profile["gold"] = 555
	check(storage.write(fresh),"new save cleans prior interrupted staging files")
	check(not FileAccess.file_exists(path + ".tmp")
		and not FileAccess.file_exists(path + ".bak.tmp")
		and profile_gold(path) == 555,
		"temporary files never become roster saves")

	var both := root_dir.path_join("both_corrupt.json")
	var both_store = Store.new()
	both_store.path = both
	check(both_store.write(make_session("双损坏剑士",610))
		and both_store.write(make_session("双损坏剑士",620)),
		"fixture creates a main and backup for double corruption")
	check(write_text(both,"broken main") and write_text(both + ".bak","broken backup"),
		"fixture damages both save generations")
	var untouched = make_session("保持原状态",999)
	check(not both_store.read_into(untouched) and int(untouched.profile["gold"]) == 999,
		"double corruption rejects without mutating the target session")
	check(read_text(both) == "broken main" and read_text(both + ".bak") == "broken backup"
		and both_store.last_error.contains("损坏"),
		"double corruption preserves both original files and reports the failure")

	blocked_path = root_dir.path_join("blocked")
	check(write_text(blocked_path,"not a directory"),"fixture creates an unwritable parent path")
	var blocked_store = Store.new()
	blocked_store.path = blocked_path.path_join("profile.json")
	check(not blocked_store.write(make_session("失败剑士",1))
		and read_text(blocked_path) == "not a directory"
		and blocked_store.last_error != "",
		"write failure leaves the blocking file and reports a retryable error")

func write_character(directory: String, character_name: String, gold: int, serial: int) -> String:
	var path := directory.path_join("character_%020d_fixture.json" % serial)
	var storage = Store.new()
	storage.path = path
	check(storage.write(make_session(character_name,gold)),"fixture writes character " + character_name)
	return path

func roster_fixture() -> void:
	var base := root_dir.path_join("roster")
	legacy_path = root_dir.path_join("legacy.json")
	var legacy_store = Store.new()
	legacy_store.path = legacy_path
	check(legacy_store.write(make_session("旧档剑士",300)),"legacy single save is created")
	valid_path = write_character(base,"冒险家",400,30)
	recovered_path = write_character(base,"备份剑士",700,10)
	var recovered_store = Store.new()
	recovered_store.path = recovered_path
	check(recovered_store.write(make_session("备份剑士",701)),"recovered character receives a newer main generation")
	check(write_text(recovered_path,"broken primary"),"fixture damages one character main")
	corrupt_path = write_character(base,"损坏剑士",800,20)
	var corrupt_store = Store.new()
	corrupt_store.path = corrupt_path
	check(corrupt_store.write(make_session("损坏剑士",801)),"corrupt character receives a backup generation")
	check(write_text(corrupt_path,"broken main") and write_text(corrupt_path + ".bak","broken backup"),
		"fixture damages both generations of one roster slot")
	check(write_text(base.path_join("character_99999999999999999999_fixture.json.tmp"),"partial")
		and write_text(base.path_join("character_99999999999999999999_fixture.json.bak.tmp"),"partial"),
		"fixture leaves two interrupted roster staging files")

func roster_contract() -> void:
	var roster = Characters.new()
	roster.directory = root_dir.path_join("roster")
	roster.legacy_path = legacy_path
	roster.refresh()
	check(roster.entries.size() == 3,
		"legacy and two readable character slots coexist despite one failed slot")
	check(roster.invalid_paths.size() == 1 and roster.invalid_paths[0] == corrupt_path,
		"one double-corrupt slot is isolated from valid entries")
	check(roster.recovered_names == ["备份剑士"],
		"one valid backup is surfaced as a recovered character")
	check(roster.ignored_temp_files == 2 and roster.error.contains("备份恢复")
		and roster.error.contains("存档损坏") and roster.error.contains("临时文件"),
		"roster warning reports recovery, isolated corruption and ignored staging files")
	var recovered_entry: Dictionary = {}
	for entry: Dictionary in roster.entries:
		if entry["path"] == recovered_path:
			recovered_entry = entry
	check(recovered_entry.get("recovered",false) and int(recovered_entry.get("level",0)) >= 1,
		"roster keeps recovered CHARACTER metadata instead of a path-only placeholder")
	check(roster.name_error("冒险家").contains("使用"),
		"duplicate character names are rejected case-insensitively")
	check(roster.name_error("a/b") != "" and roster.name_error("a").contains("2"),
		"path separators and short names are rejected before file creation")
	var before: int = roster.entries.size()
	var failed = roster.create("路径/失败")
	check(not failed["ok"] and roster.entries.size() == before,
		"invalid creation cannot add or overwrite a roster file")

func setup_game() -> void:
	game = Loop.new()
	root.add_child(game)
	await frames(4)
	game.test_mode = true
	game.characters.directory = root_dir.path_join("roster")
	game.characters.legacy_path = legacy_path
	game.store.path = valid_path
	game.show_character_selection()
	await frames(4)
	screen = game.character_screen
	game.ui_audio.muted = true
	game.town.set_voice_enabled(false)
	game.town.stop_npc_voices(true)

func formal_ui_contract() -> void:
	check(screen.slot_buttons.size() == Characters.LIMIT
		and game.characters.entries.size() == 3,
		"formal selection renders six slots with three readable characters")
	check(screen.message_label != null and screen.message_label.text.contains("备份恢复")
		and screen.message_label.text.contains("损坏"),
		"formal selection exposes isolated recovery and corruption state")
	var recovered_index := -1
	for index in game.characters.entries.size():
		if game.characters.entries[index]["path"] == recovered_path:
			recovered_index = index
	check(recovered_index >= 0 and screen.slot_buttons[recovered_index].tooltip_text.contains("备份恢复"),
		"recovered slot has a distinct backup-recovery tooltip")

func create_failure_contract() -> void:
	screen.show_create()
	await frames(2)
	check(screen.creating and screen.name_input.has_focus(),"creation form remains the formal entry")
	screen.name_input.text = "失败新建"
	var original: String = game.characters.directory
	game.characters.directory = blocked_path.path_join("roster")
	screen.create_character()
	await frames(3)
	check(screen.creating and is_instance_valid(screen.name_input)
		and screen.message_label.text.contains("角色创建失败"),
		"failed creation keeps the form open with an inline retry reason")
	check(game.characters.error.contains("角色创建失败"),
		"failed creation publishes the Store error to the character module")
	game.characters.directory = original
	screen.show_roster()
	await frames(3)
	check(not screen.creating and game.characters.entries.size() == 3,
		"failed creation leaves all existing roster slots intact")

func formal_entry_contract() -> void:
	screen.selected_path = recovered_path
	screen.show_roster()
	await frames(2)
	screen.enter_selected()
	await frames(5)
	check(game.character_active and game.session.profile["name"] == "备份剑士"
		and int(game.session.profile["gold"]) == 700 and game.store.recovered,
		"formal enter loads the backup-recovered character and reports the recovery source")
	game.show_character_selection()
	await frames(4)
	screen = game.character_screen

func full_roster_contract() -> void:
	var index := 1
	while game.characters.entries.size() < Characters.LIMIT:
		var response: Dictionary = game.characters.create("补充剑士%d" % index)
		check(response.get("ok",false),"valid creation fills roster slot %d" % game.characters.entries.size())
		index += 1
	check(game.characters.entries.size() == Characters.LIMIT,"roster reaches the six-character limit")
	screen.show_roster()
	await frames(3)
	var create := find_button("创建角色")
	check(create != null and create.disabled,"full roster disables the create action")
	var rejected: Dictionary = game.characters.create("第七位剑士")
	check(not rejected["ok"] and String(rejected["message"]).contains("位置已满")
		and game.characters.entries.size() == Characters.LIMIT,
		"full roster rejects a seventh character without replacing any file")

func find_button(text: String) -> Button:
	for node in screen.find_children("*", "Button", true, false):
		var button := node as Button
		if button != null and (button.text == text or String(button.get_meta("action_label","")) == text):
			return button
	return null

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
	check(colored > 100,"capture %s contains a nonblank roster" % name)
	if error == OK:
		print("[WS1_SAVE] CAPTURE " + path)

func capture_contract() -> void:
	if capture_dir == "":
		return
	screen.show_roster()
	await frames(4)
	await capture_frame("save_recovery_roster_1x",1)
	await capture_frame("save_recovery_roster_2x",2)
	root.min_size = Vector2i(1,1)
	root.max_size = Vector2i(8192,8192)
	root.content_scale_size = Vector2i(800,600)
	root.size = Vector2i(800,600)
	game.transform = Transform2D.IDENTITY
	(game.ui.get_parent() as CanvasLayer).transform = Transform2D.IDENTITY
	await frames(2)

func run() -> void:
	var unique := Crypto.new().generate_random_bytes(8).hex_encode()
	root_dir = "res://../temp/ws1_save_tests/" + unique
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(root_dir))
	store_contract()
	roster_fixture()
	roster_contract()
	await setup_game()
	formal_ui_contract()
	await capture_contract()
	await create_failure_contract()
	await formal_entry_contract()
	await full_roster_contract()
	finish()

func finish() -> void:
	var code := 1 if failures else 0
	print("[WS1_SAVE] COMPLETE checks=%d failures=%d" % [checks,failures])
	if is_instance_valid(game):
		game.queue_free()
		await process_frame
	quit(code)
