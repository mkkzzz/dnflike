extends SceneTree
## ws1-owned input regression for the first swordsman batch.
## Runs through loop_root and real InputEventKey dispatch; no visible window.
const Loop = preload("res://flow/loop_root.gd")
const TestApi = preload("res://debug/test_api.gd")

var game
var api
var checks := 0
var failures := 0
var held := {}

func _initialize() -> void:
	if DisplayServer.get_name() != "headless":
		push_error("[WS1_SWORDMAN_INPUTS] headless display required")
		quit(1)
		return
	call_deferred("run")

func check(value: bool, message: String) -> void:
	checks += 1
	if value:
		print("[WS1_SWORDMAN_INPUTS] PASS " + message)
	else:
		failures += 1
		push_error("[WS1_SWORDMAN_INPUTS] FAIL " + message)

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

func wait_action(target: String, timeout := 60) -> bool:
	for i in timeout:
		if String(api.p("action")) == target:
			return true
		await physics_frame
	print("[WS1_SWORDMAN_INPUTS] WAIT_ACTION target=%s state=%s action=%s stuck=%.1f" % [
		target, String(api.p("state")), String(api.p("action")), float(api.p("stuck_ms"))])
	return false

func wait_state(target: String, timeout := 90) -> bool:
	for i in timeout:
		if String(api.p("state")) == target:
			return true
		await physics_frame
	return false

func wait_hitstop(timeout := 60) -> bool:
	for i in timeout:
		if float(api.p("stuck_ms")) > 0.0:
			return true
		await physics_frame
	return false

func wait_stuck_clear(timeout := 30) -> bool:
	for i in timeout:
		if float(api.p("stuck_ms")) <= 0.0:
			return true
		await physics_frame
	return false

func session_with(ids: Array[String]) -> Variant:
	var session = game.Session.new()
	session.profile.name = "WS1输入回归"
	session.profile.level = 60
	session.profile.town_location = "seria_room"
	session.profile.town_position = [450.0, 200.0]
	for id in ids:
		session.Inventory.give(session.profile, id, 1)
	return session

func equip_weapon_from_profile(id: String) -> bool:
	for uid: String in game.session.profile.gear:
		if String(game.session.profile.gear[uid].definition) == id:
			return game.act("items.equip", {"uid": uid})
	return false

func start_battle() -> bool:
	game.selected_dungeon = "lorien"
	game.depart()
	for i in 12:
		await physics_frame
	return game.session.state == "battle" and is_instance_valid(game.battle) and is_instance_valid(game.combat)

func stop_battle() -> void:
	if is_instance_valid(game.combat):
		game.act("flow.retreat")
		game.return_town()
	for i in 6:
		await physics_frame

func face_target(target: Vector2) -> void:
	var pos: Vector2 = api.p("pos")
	api.set_p("pos", pos)
	api.set_p("facing", 1 if target.x >= pos.x else -1)
	api.set_p("z", 0.0)
	api.set_p("vz", 0.0)
	api.clear_direction_taps()

func clear_loot() -> void:
	if game.session.run.has("loot"):
		game.session.run["loot"]["drops"].clear()
		game.session.run["loot"]["seen"].clear()

func run() -> void:
	game = Loop.new()
	root.add_child(game)
	await process_frame
	await process_frame
	game.test_mode = true
	game.store.path = "res://../temp/ws1_input_tests/profile.json"
	game.characters.directory = "res://../temp/ws1_input_tests/characters"
	game.characters.legacy_path = "res://../temp/ws1_input_tests/legacy.json"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://../temp/ws1_input_tests"))

	var session = session_with(["original_27000", "original_27601"])
	var storage = game.Store.new()
	storage.path = "res://../temp/ws1_input_tests/hero.json"
	check(storage.write(session), "write disposable character fixture")
	check(game.enter_character(storage.path), "load disposable character into the real town")
	await physics_frame
	check(game.debug_panel.commands.execute("skill upper 1")["ok"], "grant Upper Slash through the normal debug command")
	check(equip_weapon_from_profile("original_27000"), "equip original short sword")
	await physics_frame
	check(await start_battle(), "enter the real Lorien combat session")
	if game.session.state != "battle" or not is_instance_valid(game.battle):
		finish()
		return

	api = TestApi.new(game.battle)
	var dummy = api.spawn_dummy(Vector2(455, 340))
	api.set_e(dummy, "hp", 9999999.0)
	api.set_e(dummy, "max_hp", 9999999.0)
	api.set_p("pos", Vector2(400, 340))
	face_target(Vector2(455, 340))
	await physics_frame
	check(api.view_weapon_item() == "original_27000", "short sword reaches the live combat view")

	var hits_before := int(api.hit_count())
	await tap(KEY_X)
	check(await wait_action("attack1", 30), "real X starts normal attack 1")
	check(await wait_hitstop(), "normal attack produces a real local hitstop")
	await tap(KEY_X)
	check(await wait_action("attack2", 70), "X during hitstop buffers normal attack 2")
	await tap(KEY_X)
	check(await wait_action("attack3", 70), "X during attack 2 reaches normal attack 3")
	check(await wait_state("idle", 120), "normal attack chain returns to idle")
	check(int(api.hit_count()) - hits_before >= 3, "three normal attacks hit the durable dummy")

	clear_loot()
	var fixture_dummy = api.spawn_dummy(Vector2(455, 340))
	api.set_e(fixture_dummy, "hp", 9999999.0)
	api.set_e(fixture_dummy, "max_hp", 9999999.0)
	api.set_p("pos", Vector2(400, 340))
	face_target(Vector2(455, 340))
	await physics_frame
	await tap(KEY_X)
	check(await wait_action("attack1", 30), "separate X starts a hitstop fixture")
	api.set_hitstop(90.0)
	var frozen_clock := float(api.p("clock"))
	await physics_frame
	var after_freeze := float(api.p("clock"))
	check(absf(after_freeze - frozen_clock) < 0.01, "local hitstop freezes the action clock")
	check(await wait_state("idle", 120), "hitstop fixture completes")
	check(await wait_stuck_clear(30), "hitstop releases the local clock")

	clear_loot()
	Input.flush_buffered_events()
	for i in 3:
		await process_frame
	game.combat.set_paused(true)
	var paused_state := String(api.p("state"))
	var paused_action := String(api.p("action"))
	game.combat.submit_key(KEY_X, true)
	await physics_frame
	game.combat.submit_key(KEY_X, false)
	for i in 4:
		await physics_frame
	check(String(api.p("state")) == paused_state and String(api.p("action")) == paused_action, "paused combat ignores X")
	game.combat.set_paused(false)
	game.combat.submit_key(KEY_X, true)
	await physics_frame
	game.combat.submit_key(KEY_X, false)
	check(await wait_action("attack1", 30), "resume accepts the next X")
	check(await wait_state("idle", 120), "resumed attack returns to idle")

	await stop_battle()
	check(game.session.state == "town", "retreat returns the fixture to town")
	check(equip_weapon_from_profile("original_27601"), "equip original katana")
	await physics_frame
	check(await start_battle(), "enter a second real combat session with katana")
	if game.session.state != "battle" or not is_instance_valid(game.battle):
		finish()
		return

	api = TestApi.new(game.battle)
	var katana_dummy = api.spawn_dummy(Vector2(455, 340))
	api.set_e(katana_dummy, "hp", 9999999.0)
	api.set_e(katana_dummy, "max_hp", 9999999.0)
	api.set_p("pos", Vector2(400, 340))
	face_target(Vector2(455, 340))
	await physics_frame
	check(api.view_weapon_item() == "original_27601", "katana reaches the live combat view")
	var mp_before := float(api.p("mp"))
	await tap(KEY_Z)
	check(await wait_action("upper", 30), "real Z starts Upper Slash")
	check(float(api.p("mp")) < mp_before, "Upper Slash consumes mana once")
	var actor = game.battle.view.player_actor
	var sampled := false
	for frame_index in 16:
		if actor.pose == "hitback" and actor.clock_ms >= 50.0 and actor.clock_ms < 100.0:
			sampled = int(actor.sample().img_frame) == 51 and actor.equipment_layers.all(
				func(layer): return int(layer.frame.get("img_frame", -1)) == 51)
			break
		await physics_frame
	check(sampled, "katana Upper Slash keeps body and both weapon layers on frame 51")
	check(await wait_state("idle", 120), "Upper Slash returns to idle")
	finish()

func finish() -> void:
	release_all()
	var code := 1 if failures else 0
	print("[WS1_SWORDMAN_INPUTS] COMPLETE checks=%d failures=%d" % [checks, failures])
	if is_instance_valid(game):
		game.queue_free()
	await process_frame
	quit(code)
