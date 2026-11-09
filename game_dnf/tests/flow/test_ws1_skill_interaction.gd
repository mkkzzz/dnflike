extends SceneTree
## ws1-owned shortcut regression for the first swordsman batch.
## Uses the real flow HUD and save path; all rendering stays headless.
const Loop = preload("res://flow/loop_root.gd")
const TestApi = preload("res://debug/test_api.gd")
const SkillSlots = preload("res://stats/api/skill_slots.gd")

var game
var api
var checks := 0
var failures := 0
var held := {}

func _initialize() -> void:
	if DisplayServer.get_name() != "headless":
		push_error("[WS1_SKILL_INTERACTION] headless display required")
		quit(1)
		return
	call_deferred("run")

func check(value: bool, message: String) -> void:
	checks += 1
	if value:
		print("[WS1_SKILL_INTERACTION] PASS " + message)
	else:
		failures += 1
		push_error("[WS1_SKILL_INTERACTION] FAIL " + message)

func key(code: int, pressed: bool) -> void:
	held[code] = pressed
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)

func tap(code: int) -> void:
	key(code, false)
	await process_frame
	await physics_frame
	key(code, true)
	await process_frame
	await physics_frame
	key(code, false)
	await process_frame
	await physics_frame

func release_all() -> void:
	for code in held.keys():
		key(int(code), false)
	await process_frame

func wait_action(target: String, timeout := 60) -> bool:
	for i in timeout:
		if String(api.p("action")) == target:
			return true
		await physics_frame
	print("[WS1_SKILL_INTERACTION] WAIT_ACTION target=%s state=%s action=%s" % [
		target, String(api.p("state")), String(api.p("action"))])
	return false

func wait_state(target: String, timeout := 90) -> bool:
	for i in timeout:
		if String(api.p("state")) == target:
			return true
		await physics_frame
	return false

func measure_once(label: String, action: Callable, budget_ms: float) -> float:
	var started := Time.get_ticks_usec()
	action.call()
	await process_frame
	var elapsed := (Time.get_ticks_usec() - started) / 1000.0
	print("[WS1_SKILL_INTERACTION] PERF %s_ms=%.3f budget_ms=%.1f" % [label, elapsed, budget_ms])
	check(elapsed < budget_ms, label + " stays inside the warm budget")
	return elapsed

func measure_median(label: String, action: Callable, budget_ms: float) -> float:
	var samples: Array[float] = []
	for i in 3:
		var started := Time.get_ticks_usec()
		action.call()
		samples.append((Time.get_ticks_usec() - started) / 1000.0)
		await process_frame
	samples.sort()
	var median := samples[1]
	print("[WS1_SKILL_INTERACTION] PERF %s_median_ms=%.3f peak_ms=%.3f budget_ms=%.1f" % [
		label, median, samples[2], budget_ms])
	check(median < budget_ms, label + " median stays inside the warm budget")
	return median

func empty_slots() -> Array:
	var slots := []
	slots.resize(SkillSlots.COUNT)
	slots.fill("")
	return slots

func bind(id: String, index: int) -> bool:
	return game.act("slots.move", {
		"source": {"place": "skill_catalog", "id": id},
		"target": {"place": "skill", "index": index},
	})

func move_slot(from: int, to: int) -> bool:
	var slots: Array = game.session.profile["skill_slots"]
	return game.act("slots.move", {
		"source": {"place": "skill", "index": from, "id": String(slots[from])},
		"target": {"place": "skill", "index": to},
	})

func check_geometry() -> void:
	var keys := ["A", "S", "D", "F", "G", "H", "Q", "W", "E", "R", "T", "Y"]
	var offsets := [22, 22, 22, 22, 22, 22, 22, 21, 22, 22, 21, 21]
	for index in keys.size():
		var key_name: String = keys[index]
		var origin := Vector2(538 + (index % 6) * 30, 558 if index < 6 else 520)
		var cell := game.hud.get_node_or_null("hud_skill_slot_%d" % index) as Control
		check(cell != null and cell.get_rect() == Rect2(origin, Vector2(28, 28)),
			"native shortcut cell bounds: " + key_name)
		var glyph := game.hud.get_node_or_null("skill_hotkey_" + key_name) as TextureRect
		check(glyph != null and glyph.position == origin + Vector2(offsets[index], 21)
			and glyph.size.y == 7 and glyph.z_index > 0
			and glyph.mouse_filter == Control.MOUSE_FILTER_IGNORE,
			"original key glyph is visible and non-blocking: " + key_name)
		if index >= 6:
			var plate := game.hud.get_node_or_null("skill_extra_slot_%d" % index) as TextureRect
			check(plate != null and plate.get_rect() == Rect2(origin, Vector2(28, 28))
				and plate.mouse_filter == Control.MOUSE_FILTER_IGNORE,
				"native extended backplate fits the cell: " + key_name)

func session_fixture() -> Variant:
	var session = game.Session.new()
	session.profile.name = "WS1快捷栏回归"
	session.profile.level = 60
	session.profile.town_location = "seria_room"
	session.profile.town_position = [450.0, 200.0]
	return session

func run() -> void:
	game = Loop.new()
	root.add_child(game)
	await process_frame
	await process_frame
	game.test_mode = true
	game.store.path = "res://../temp/ws1_skill_tests/profile.json"
	game.characters.directory = "res://../temp/ws1_skill_tests/characters"
	game.characters.legacy_path = "res://../temp/ws1_skill_tests/legacy.json"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://../temp/ws1_skill_tests"))

	var session = session_fixture()
	var storage = game.Store.new()
	storage.path = "res://../temp/ws1_skill_tests/hero.json"
	check(storage.write(session), "write disposable shortcut fixture")
	check(game.enter_character(storage.path), "load disposable shortcut fixture into the real town")
	await physics_frame
	for id in ["upper", "hardattack", "triple", "guard"]:
		check(game.debug_panel.commands.execute("skill %s 1" % id)["ok"], "grant " + id)
	check(SkillSlots.COUNT == 12, "flow exposes twelve shortcut slots")
	check(SkillSlots.KEYS == [KEY_A, KEY_S, KEY_D, KEY_F, KEY_G, KEY_H, KEY_Q, KEY_W, KEY_E, KEY_R, KEY_T, KEY_Y],
		"lower ASDFGH and upper QWERTY key map is stable")
	check(SkillSlots.LABELS == ["A", "S", "D", "F", "G", "H", "Q", "W", "E", "R", "T", "Y"],
		"shortcut labels match the actual physical keys")

	game.session.profile["skill_slots"] = empty_slots()
	game.build_hotbars()
	await physics_frame
	check_geometry()

	check(bind("hardattack", 0), "bind Heuk Slash to A")
	check(bind("triple", 1), "bind Triple Slash to S")
	check(bind("guard", 2), "bind Guard to D")
	check(bind("upper", 6), "bind Upper Slash to Q")
	var slots: Array = game.session.profile["skill_slots"]
	check(slots[0] == "hardattack" and slots[1] == "triple" and slots[2] == "guard" and slots[6] == "upper",
		"both rows accept learned active skills")
	check(slots.count("hardattack") == 1 and slots.count("triple") == 1 and slots.count("guard") == 1 and slots.count("upper") == 1,
		"each learned skill occupies exactly one shortcut")

	check(move_slot(6, 2), "move Q across rows onto occupied D")
	slots = game.session.profile["skill_slots"]
	check(slots[2] == "upper" and slots[6] == "guard", "cross-row occupied D swaps both bindings")
	check(move_slot(2, 3), "move D to the adjacent empty F")
	slots = game.session.profile["skill_slots"]
	check(slots[3] == "upper" and slots[2] == "", "moving to an empty adjacent slot clears D")
	check(move_slot(3, 2), "move the skill back to D")
	check(move_slot(0, 4), "move A to the empty G slot")
	slots = game.session.profile["skill_slots"]
	check(slots[4] == "hardattack" and slots[0] == "", "moving out of A leaves no duplicate")
	check(move_slot(4, 0), "restore the A binding")
	var expected_slots: Array = game.session.profile["skill_slots"].duplicate()

	check(not game.can_drop_slot({"place": "skill_catalog", "id": "physical_mastery"},
		{"place": "skill", "index": 2}), "passive skill cannot bind")
	check(not game.can_drop_slot({"place": "skill_catalog", "id": "waveeye"},
		{"place": "skill", "index": 2}), "unlearned active skill cannot bind")
	check(not game.can_drop_slot({"place": "skill_catalog", "id": "missing_skill"},
		{"place": "skill", "index": 2}), "unknown skill cannot bind")
	check(not game.can_drop_slot({"place": "skill_catalog", "id": "upper"},
		{"place": "skill", "index": -1}), "negative slot is rejected")
	check(not game.can_drop_slot({"place": "skill_catalog", "id": "upper"},
		{"place": "skill", "index": 12}), "out-of-range slot is rejected")

	var serialized = game.session.serialize()
	var restored = game.Session.new()
	check(restored.restore(JSON.parse_string(JSON.stringify(serialized))), "save roundtrip restores the shortcut profile")
	check(restored.profile["skill_slots"] == game.session.profile["skill_slots"]
		and restored.profile["skill_slots"].size() == 12, "all twelve slots survive save and load")
	var legacy: Dictionary = game.session.serialize()
	for key_name in ["bag_layout", "quick_items", "skill_slots", "difficulty"]:
		legacy["profile"].erase(key_name)
	var migrated = game.Session.new()
	check(migrated.restore(legacy) and migrated.profile["skill_slots"].size() == 12,
		"legacy six-slot saves migrate to twelve slots")

	await measure_once("first_skill_panel", func():
		game.number_windows.tab = 1
		game.show_overlay("numbers"), 120.0)
	await measure_median("hot_skill_panel", func():
		game.number_windows.tab = 1
		game.show_overlay("numbers"), 80.0)
	await measure_median("skill_hover", func():
		game.windows.skill_tip("guard", Rect2(20, 20, 28, 28), true), 60.0)
	await measure_median("skill_drag_preview", func():
		game.can_drop_slot({"place": "skill", "index": 2, "id": "upper"},
			{"place": "skill", "index": 3}), 20.0)
	check(game.session.profile["skill_slots"] == expected_slots,
		"panel hover and drag preview do not mutate bindings")
	game.show_overlay("")
	game.build_hotbars()
	await physics_frame

	check(game.session.profile["skill_slots"][2] == "upper", "D remains bound to Upper Slash before battle")
	game.selected_dungeon = "lorien"
	game.depart()
	for i in 12:
		await physics_frame
	check(game.session.state == "battle" and is_instance_valid(game.battle), "enter the real battle through the normal flow")
	if game.session.state != "battle" or not is_instance_valid(game.battle):
		finish()
		return
	api = TestApi.new(game.battle)
	api.set_p("pos", Vector2(400, 340))
	api.set_p("facing", 1)
	api.set_p("z", 0.0)
	api.set_p("vz", 0.0)
	await physics_frame
	await tap(KEY_D)
	check(await wait_action("upper", 30), "D dispatches the bound Upper Slash")
	check(float(game.combat.read_view()["cooldowns"].get("upper", 0.0)) > 0.0,
		"D invocation starts the real skill cooldown")
	check(await wait_state("idle", 120), "D-bound skill returns to idle")
	game.act("flow.retreat")
	game.return_town()
	for i in 6:
		await physics_frame
	check(game.session.state == "town" and game.session.profile["skill_slots"][2] == "upper",
		"returning to town preserves the D binding")
	finish()

func finish() -> void:
	release_all()
	var code := 1 if failures else 0
	print("[WS1_SKILL_INTERACTION] COMPLETE checks=%d failures=%d" % [checks, failures])
	if is_instance_valid(game):
		game.queue_free()
	await process_frame
	quit(code)
