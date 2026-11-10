extends SceneTree
## ws1 regression: an actual skill +/- action must return without stalling the frame.
const Loop = preload("res://flow/loop_root.gd")

var game
var checks := 0
var failures := 0

func _initialize() -> void:
	if DisplayServer.get_name() != "headless":
		push_error("[WS1_SKILL_LEARN] headless display required")
		quit(1)
		return
	call_deferred("run")

func check(value: bool, message: String) -> void:
	checks += 1
	if value:
		print("[WS1_SKILL_LEARN] PASS " + message)
	else:
		failures += 1
		push_error("[WS1_SKILL_LEARN] FAIL " + message)

func frames(count := 3) -> void:
	for _index in count:
		await process_frame

func find_action(label: String) -> Button:
	for node in game.modal.find_children("*", "Button", true, false):
		var button := node as Button
		if button != null and not button.is_queued_for_deletion() \
			and String(button.get_meta("action_label", "")) == label:
			return button
	return null

func setup_game() -> void:
	game = Loop.new()
	root.add_child(game)
	await frames(4)
	var unique := Crypto.new().generate_random_bytes(8).hex_encode()
	game.test_mode = true
	game.store.path = "res://../temp/ws1_skill_learning_tests/profile_" + unique + ".json"
	game.characters.directory = "res://../temp/ws1_skill_learning_tests/characters_" + unique
	game.characters.legacy_path = "res://../temp/ws1_skill_learning_tests/legacy_" + unique + ".json"
	game.session = game.Session.new()
	game.session.profile["name"] = "加点延迟剑士"
	game.session.profile["level"] = 60
	game.session.profile["growtype"] = "weaponmaster"
	game.session.profile["sp_bonus"] = 2000
	game.session.profile["town_location"] = "elvengard"
	game.session.profile["town_position"] = [445.0,222.0]
	check(game.store.write(game.session),"disposable level-60 character is written")
	check(game.enter_character(game.store.path),"disposable character enters the formal town flow")
	await frames(5)
	game.ui_audio.muted = true
	game.town.set_voice_enabled(false)
	game.town.stop_npc_voices(true)

func measure_action(button: Button, label: String, budget_ms: float) -> float:
	var started := Time.get_ticks_usec()
	button.pressed.emit()
	var callback_ms := (Time.get_ticks_usec() - started) / 1000.0
	await frames(2)
	var total_ms := (Time.get_ticks_usec() - started) / 1000.0
	print("[WS1_SKILL_LEARN] PERF %s_callback_ms=%.3f total_ms=%.3f budget_ms=%.1f" % [
		label,callback_ms,total_ms,budget_ms])
	check(callback_ms < budget_ms,"%s callback returns inside the frame budget" % label)
	return callback_ms

func run() -> void:
	await setup_game()
	game.number_windows.tab = 1
	game.number_windows.skill_panel.select_skill("upper")
	game.show_overlay("numbers")
	await frames(5)
	var learn := find_action("加点")
	var refund := find_action("退点")
	check(learn != null and not learn.disabled,"formal skill panel exposes an enabled learn action")
	check(refund != null and refund.disabled,"initial grant rank does not advertise a false refund")
	if learn == null or refund == null:
		finish()
		return
	var before := int(game.session.profile["skills"].get("upper",0))
	await measure_action(learn,"first_learn",250.0)
	check(int(game.session.profile["skills"].get("upper",0)) == before + 1,
		"first learn commits the skill rank")
	refund = find_action("退点")
	check(refund != null and not refund.disabled,"committed rank enables refund")
	if refund == null:
		finish()
		return
	await measure_action(refund,"first_refund",250.0)
	check(int(game.session.profile["skills"].get("upper",0)) == before,
		"refund restores the original rank")
	learn = find_action("加点")
	await measure_action(learn,"second_learn",250.0)
	check(int(game.session.profile["skills"].get("upper",0)) == before + 1,
		"second learn remains responsive and commits once")
	finish()

func finish() -> void:
	var code := 1 if failures else 0
	print("[WS1_SKILL_LEARN] COMPLETE checks=%d failures=%d" % [checks,failures])
	if is_instance_valid(game):
		game.queue_free()
		await process_frame
	quit(code)
