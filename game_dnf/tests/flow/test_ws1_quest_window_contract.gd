extends SceneTree
## ws1-owned quest window, dialogue and tracker contract.
const Loop = preload("res://flow/loop_root.gd")

var game
var checks := 0
var failures := 0
var capture_dir := ""
var original_definitions: Dictionary = {}
var fixture_ids: Array[String] = []

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var capture := "--capture" in args
	if capture:
		capture_dir = String(args[args.find("--output") + 1]) \
			if args.find("--output") >= 0 and args.find("--output") + 1 < args.size() else ""
		if OS.get_environment("DNF_PRIVATE_DESKTOP") != "1" \
			or DisplayServer.get_name() == "headless" or capture_dir == "":
			push_error("[WS1_QUEST] capture requires the private desktop and --output")
			quit(1)
			return
	elif DisplayServer.get_name() != "headless":
		push_error("[WS1_QUEST] headless display required")
		quit(1)
		return
	call_deferred("run")

func check(value: bool, message: String) -> void:
	checks += 1
	if value:
		print("[WS1_QUEST] PASS " + message)
	else:
		failures += 1
		push_error("[WS1_QUEST] FAIL " + message)

func frames(count := 3) -> void:
	for _index in count:
		await process_frame

func find_control(name: String) -> Control:
	return game.modal.find_child(name, true, false) as Control

func find_button_by_action(label: String) -> Button:
	for node in game.modal.find_children("*", "Button", true, false):
		if node.is_queued_for_deletion():
			continue
		if node.text == label or String(node.get_meta("action_label", "")) == label:
			return node
	return null

func find_quest_row(id: String) -> Button:
	for node in game.modal.find_children("*", "Button", true, false):
		if not node.is_queued_for_deletion() and String(node.get_meta("quest_id", "")) == id:
			return node
	return null

func press_action(label: String) -> bool:
	var button := find_button_by_action(label)
	if button == null or button.disabled:
		return false
	button.pressed.emit()
	return true

func move_to_npc(npc: String) -> bool:
	game.show_overlay("")
	for location: String in game.town.world.data["locations"]:
		var scene: Dictionary = game.town.world.scene(location)
		if not scene.get("npcs", {}).has(npc):
			continue
		var at: Array = scene["npcs"][npc]
		game.town.set_location(location, game.session.TownWorld.vec(at))
		game.session.profile["town_location"] = location
		game.session.profile["town_position"] = at.duplicate()
		return true
	return false

func move_away_from_npcs() -> void:
	var scene: Dictionary = game.town.world.scene("elvengard")
	var at: Vector2 = game.session.TownWorld.vec(scene["spawn"])
	game.town.set_location("elvengard", at)
	game.session.profile["town_location"] = "elvengard"
	game.session.profile["town_position"] = [at.x, at.y]

func setup_game() -> void:
	game = Loop.new()
	root.add_child(game)
	await frames(4)
	var unique := Crypto.new().generate_random_bytes(8).hex_encode()
	game.store.path = "res://../temp/ws1_quest_tests/profile_" + unique + ".json"
	game.session = game.Session.new()
	game.session.profile["name"] = "任务契约旅人"
	game.session.profile["level"] = 1
	check(game.store.write(game.session), "disposable quest character is written")
	check(game.enter_character(game.store.path), "disposable quest character enters the real town flow")
	await frames(4)
	game.ui_audio.muted = true
	game.town.set_voice_enabled(false)
	game.town.stop_npc_voices(true)

func dialogue_contract() -> void:
	check(move_to_npc("linus"), "dialogue fixture moves beside Linus")
	await frames(2)
	var npc_row: Dictionary = game.town.world.data["npcs"]["linus"]
	var original_line := String(npc_row["dialogue"])
	var long_line: String = ("这是一段用于验证对话滚动、换行和末行可达性的长文本。"
		+ "铁匠铺里的炉火不会熄灭，冒险者仍需逐行确认每一句委托说明。").repeat(8)
	npc_row["dialogue"] = long_line
	game.show_overlay("npc")
	await frames(4)
	var dialogue := find_control("quest_dialogue")
	check(dialogue != null and dialogue.position == Vector2(41, 343) and dialogue.size == Vector2(718, 165),
		"NPC dialogue keeps the native 718x165 board")
	var speech := find_control("quest_dialogue_speech_scroll") as ScrollContainer
	var speech_text := find_control("quest_dialogue_speech") as Label
	check(speech != null and speech.position == Vector2(215, 51) and speech.size == Vector2(475, 62),
		"dialogue body keeps the native speech viewport")
	await frames(2)
	check(speech_text != null and speech_text.size.y > speech.size.y,
		"long NPC speech exceeds its viewport instead of clipping silently")
	if speech != null:
		var scrollbar := speech.get_v_scroll_bar()
		check(scrollbar.max_value > scrollbar.page, "long dialogue exposes a real vertical scrollbar")
		scrollbar.value = scrollbar.max_value - scrollbar.page
		await frames(2)
		check(scrollbar.value > 0.0, "long dialogue reaches its final wrapped line")
	var actions: Array = dialogue.get_meta("action_buttons", []) if dialogue != null else []
	check(actions.size() >= 3, "dialogue publishes its task, service and close actions")
	check(not actions.is_empty() and root.gui_get_focus_owner() == actions[0],
		"dialogue focuses the first task action when it opens")
	var focus_ok := true
	for button: Button in actions:
		focus_ok = focus_ok and button.focus_mode == Control.FOCUS_ALL
	check(focus_ok, "all dialogue actions accept keyboard focus")
	if actions.size() >= 2:
		var first: Button = actions[0]
		var second: Button = actions[1]
		check(first.focus_neighbor_right != NodePath() and first.get_node_or_null(first.focus_neighbor_right) == second,
			"dialogue focus chain advances to the next action")
		second.grab_focus()
		await frames(2)
		check(root.gui_get_focus_owner() == second, "dialogue focus can move without rebuilding the panel")
	npc_row["dialogue"] = original_line
	game.show_overlay("")
	await frames(3)

func real_accept_and_failure_contract() -> void:
	check(move_to_npc("seria"), "available fixture moves beside Seria")
	await frames(2)
	game.show_overlay("npc")
	await frames(3)
	check(press_action("委托任务"), "NPC task action opens the quest window")
	await frames(3)
	var quest_id := "elvengard.meet_linus"
	check(game.session.quests.status(game.session.profile, quest_id) == "available", "first source quest starts available")
	check(find_quest_row(quest_id) != null, "available tab lists the source quest")
	check(press_action("接受委托"), "accept button uses the published callback")
	await frames(4)
	check(game.session.quests.status(game.session.profile, quest_id) == "active",
		"successful acceptance commits the real quest transaction")
	check(game.quest_windows.tab == 1 and game.quest_windows.selected == quest_id,
		"accepted quest follows into the active tab without losing selection")
	check(move_to_npc("linus"), "active fixture moves beside Linus")
	await frames(3)
	game.show_overlay("npc")
	await frames(3)
	check(game.session.quests.status(game.session.profile, quest_id) == "ready",
		"real NPC visit advances the meet objective")
	check(press_action("委托任务"), "ready dialogue opens the active quest")
	await frames(3)
	check(press_action("领取报酬"), "ready claim button uses the published transaction")
	await frames(4)
	check(game.session.quests.status(game.session.profile, quest_id) == "completed",
		"successful claim commits completion")
	check(game.quest_windows.tab == 2 and game.quest_windows.selected == quest_id,
		"completed quest follows into the completed tab")

	var next_id := "lorien.first_clear"
	game.show_overlay("npc")
	await frames(3)
	check(press_action("委托任务"), "next available task opens from Linus")
	await frames(3)
	check(find_quest_row(next_id) != null, "prerequisite completion unlocks the next source quest")
	check(press_action("接受委托"), "next source quest accepts through the same callback")
	await frames(4)
	var entry: Dictionary = game.session.profile["quest_state"]["entries"][next_id]
	for objective: Dictionary in game.session.quests.catalog.definitions[next_id]["objectives"]:
		entry["progress"][objective["id"]] = int(objective["amount"])
	check(game.session.quests.status(game.session.profile, next_id) == "ready", "fixture reaches ready without bypassing task state")
	move_away_from_npcs()
	game.quest_windows.tab = 1
	game.quest_windows.selected = next_id
	game.show_overlay("quest")
	await frames(4)
	var gold_before := int(game.session.profile["gold"])
	check(press_action("领取报酬"), "claim can be attempted from the unsaved remote quest window")
	await frames(4)
	check(game.session.quests.status(game.session.profile, next_id) == "ready"
		and int(game.session.profile["gold"]) == gold_before,
		"failed NPC proximity receipt does not mutate quest or reward")
	var feedback := find_control("quest_window_feedback") as Label
	check(feedback != null and feedback.visible and feedback.text.contains("林纳斯"),
		"failed transaction shows an in-window receipt instead of an unseen toast")
	check(move_to_npc("linus"), "retry fixture returns beside the receiver")
	await frames(2)
	game.show_overlay("quest")
	await frames(4)
	check(press_action("领取报酬"), "failed action can be retried from the same quest window contract")
	await frames(4)
	check(game.session.quests.status(game.session.profile, next_id) == "completed",
		"retry with valid proximity commits exactly once")

func fixture_definition(id: String, display_name: String, objective_count := 1) -> Dictionary:
	var objectives: Array = []
	for index in objective_count:
		objectives.append({"id": "objective_%d" % index, "type": "meet_npc",
			"target": "linus", "amount": index + 2})
	return {
		"id": id,
		"name": display_name,
		"category": "side",
		"chapter": "ws1 契约",
		"min_level": 1,
		"requires": [],
		"giver": "linus",
		"receiver": "linus",
		"objectives": objectives,
		"description": "用于验证任务窗滚动、选择、焦点和局部刷新的隔离契约，不属于原版内容。",
		"reward": {"gold": 321, "xp": 45, "items": {"potion": 2}, "choices": [], "conditional_items": []},
		"consume": {},
		"enabled": true,
		"abandonable": true,
		"lifecycle": "once",
		"dialogue": {"accept": "契约任务", "complete": "契约完成"},
		"eligibility": {"jobs": [-1], "grow_types": [-1]},
	}

func add_entry(definition: Dictionary, progress_ratio := 0.0) -> void:
	var entry: Dictionary = game.session.quests.new_entry(definition)
	for objective: Dictionary in definition["objectives"]:
		entry["progress"][objective["id"]] = mini(int(objective["amount"]),
			ceili(float(objective["amount"]) * progress_ratio))
	game.session.profile["quest_state"]["entries"][definition["id"]] = entry

func install_fixtures() -> void:
	original_definitions = game.session.quests.catalog.definitions.duplicate(true)
	game.session.quests.catalog.definitions.clear()
	game.session.profile["quest_state"] = {"revision": 1, "entries": {}, "transactions": {}, "tracked": []}
	fixture_ids.clear()
	for index in 7:
		var id := "ws1.fixture.available.%d" % index
		var definition := fixture_definition(id, "可接委托 %d" % (index + 1), 2)
		game.session.quests.catalog.definitions[id] = definition
		fixture_ids.append(id)
	var active := fixture_definition("ws1.fixture.active", "进行中的长追踪委托", 4)
	game.session.quests.catalog.definitions[active["id"]] = active
	add_entry(active, 0.5)
	fixture_ids.append(active["id"])
	var ready := fixture_definition("ws1.fixture.ready", "长目标与奖励浏览", 12)
	ready["description"] = ("这是一段用于验证任务详情纵向滚动、奖励换行和固定操作区不重叠的长说明。"
		+ "每一项目标都必须保留独立计数、颜色和最后一行可达性。").repeat(6)
	ready["reward"]["items"] = {"potion": 9, "forest_sword": 1, "scrap_iron": 7,
		"iron_sword": 1, "training_coat": 1, "training_necklace": 1}
	ready["reward"]["choices"] = [
		{"id": "choice_potion", "item": "potion", "amount": 5},
		{"id": "choice_scrap", "item": "scrap_iron", "amount": 8},
		{"id": "choice_sword", "item": "forest_sword", "amount": 1},
	]
	game.session.quests.catalog.definitions[ready["id"]] = ready
	add_entry(ready, 1.0)
	fixture_ids.append(ready["id"])
	var completed := fixture_definition("ws1.fixture.completed", "已完成契约", 1)
	game.session.quests.catalog.definitions[completed["id"]] = completed
	var done_entry: Dictionary = game.session.quests.new_entry(completed)
	done_entry["state"] = "completed"
	game.session.profile["quest_state"]["entries"][completed["id"]] = done_entry
	game.session.profile["quest_state"]["transactions"]["quest:" + String(completed["id"]) + ":once"] = true
	fixture_ids.append(completed["id"])
	game.session.profile["quest_state"]["tracked"] = [active["id"], ready["id"]]

func restore_catalog() -> void:
	game.session.quests.catalog.definitions.clear()
	game.session.quests.catalog.definitions.merge(original_definitions, true)

func open_fixture_tab(index: int, selected_id := "") -> void:
	game.quest_windows.tab = index
	game.quest_windows.selected = selected_id
	game.quest_windows.focus_npc = ""
	game.show_overlay("quest")

func fixture_states_contract() -> void:
	install_fixtures()
	open_fixture_tab(0)
	await frames(4)
	var root_window := find_control("quest_window")
	check(root_window != null and root_window.position == Vector2(112, 55) and root_window.size == Vector2(576, 416),
		"quest window keeps the native 576x416 board")
	var list_scroll := find_control("quest_window_list_scroll") as ScrollContainer
	var detail_scroll := find_control("quest_window_detail_scroll") as ScrollContainer
	check(list_scroll != null and list_scroll.position == Vector2(20, 78) and list_scroll.size == Vector2(228, 278),
		"quest list keeps its native viewport")
	check(detail_scroll != null and detail_scroll.position == Vector2(279, 85) and detail_scroll.size == Vector2(272, 268),
		"quest detail keeps its native viewport and clear footer")
	var builds: int = game.quest_windows.window_builds
	var list_content := find_control("quest_window_list_content")
	list_scroll.scroll_vertical = 72
	await frames(2)
	var previous_id: String = game.quest_windows.selected
	var next_id: String = fixture_ids[0] if previous_id != fixture_ids[0] else fixture_ids[1]
	game.quest_windows.select_quest(next_id)
	await frames(4)
	check(game.quest_windows.selected == next_id, "task selection updates without clearing the window")
	check(is_instance_valid(root_window) and find_control("quest_window") == root_window,
		"task selection retains the quest root")
	check(find_control("quest_window_list_content") == list_content,
		"task selection retains the list controls")
	check(game.quest_windows.window_builds == builds, "task selection performs no modal window rebuild")
	check(list_scroll.scroll_vertical > 0, "task selection preserves list scroll")

	open_fixture_tab(1, "ws1.fixture.active")
	await frames(4)
	check(find_quest_row("ws1.fixture.active") != null, "active tab renders an active quest")
	check(game.quest_windows.primary_action == null and find_control("quest_window_track") != null,
		"active quest exposes tracking without a claim action")

	open_fixture_tab(1, "ws1.fixture.ready")
	await frames(5)
	detail_scroll = find_control("quest_window_detail_scroll") as ScrollContainer
	var content := find_control("quest_window_detail_content") as VBoxContainer
	check(content != null and content.get_combined_minimum_size().y > detail_scroll.size.y,
		"long objectives and rewards exceed the detail viewport")
	var detail_bar := detail_scroll.get_v_scroll_bar()
	check(detail_bar.max_value > detail_bar.page, "long quest detail exposes a vertical scrollbar")
	detail_scroll.scroll_vertical = 180
	await frames(2)
	var preserved_scroll := detail_scroll.scroll_vertical
	check(preserved_scroll > 0, "long quest detail can scroll into the reward list")
	var primary: Button = game.quest_windows.primary_action
	check(primary != null and primary.disabled, "claim is disabled until a reward choice is selected")
	var choice: Button = find_control("quest_window_choice_0") as Button
	check(choice != null, "reward choices use real focusable controls")
	if choice != null:
		choice.pressed.emit()
		await frames(2)
		check(game.quest_windows.selected_choices.get("ws1.fixture.ready", "") == "choice_potion",
			"reward choice selection is retained in window state")
		check(is_instance_valid(primary) and not primary.disabled, "valid reward choice enables the claim action")
		check(find_control("quest_window_detail_scroll") == detail_scroll and detail_scroll.scroll_vertical == preserved_scroll,
			"reward choice preserves the detail control and scroll position")
		var cancel := find_control("quest_window_choice_cancel") as Button
		check(cancel != null and cancel.visible, "selected reward exposes an explicit cancel action")
		if cancel != null:
			cancel.pressed.emit()
			await frames(2)
		check(not game.quest_windows.selected_choices.has("ws1.fixture.ready") and primary.disabled,
			"reward selection can be cancelled without changing the task")

	open_fixture_tab(2, "ws1.fixture.completed")
	await frames(4)
	check(find_quest_row("ws1.fixture.completed") != null, "completed tab renders completed history")
	check(game.quest_windows.primary_action == null and find_control("quest_window_status") != null,
		"completed quest does not expose a duplicate claim button")

	var saved_definitions: Dictionary = game.session.quests.catalog.definitions
	game.session.quests.catalog.definitions = {}
	game.quest_windows.tab = 0
	game.quest_windows.selected = ""
	game.quest_windows.focus_npc = ""
	game.show_overlay("quest")
	await frames(4)
	check(find_control("quest_window_empty") != null, "empty task category renders an explicit empty state")
	game.session.quests.catalog.definitions = saved_definitions

func tracker_local_update_contract() -> void:
	game.show_overlay("")
	await frames(4)
	game.quest_windows.tracker_signature = ""
	game.quest_windows.refresh_tracker()
	await frames(3)
	var tracker: Control = game.quest_windows.tracker
	check(tracker != null and tracker.visible, "tracker returns immediately after closing the quest window")
	var rows_before: Array = tracker.get_meta("rows", []).duplicate()
	check(rows_before.size() >= 2, "tracker renders tracked quest content")
	var objective_before := String(rows_before[1].text)
	var active_entry: Dictionary = game.session.profile["quest_state"]["entries"]["ws1.fixture.active"]
	active_entry["progress"]["objective_0"] = int(active_entry["progress"]["objective_0"]) + 1
	game.quest_windows.tracker_signature = ""
	game.quest_windows.refresh_tracker()
	await frames(3)
	var rows_after: Array = tracker.get_meta("rows", [])
	check(tracker == game.quest_windows.tracker and rows_after.size() >= 2,
		"tracker refresh retains the native guide root")
	check(rows_after.size() >= rows_before.size() and rows_after[0] == rows_before[0],
		"tracker reuses its title row during a progress-only update")
	check(String(rows_after[1].text) != objective_before,
		"tracker updates live objective text in place")

func measure_median(label: String, action: Callable) -> float:
	var samples: Array[float] = []
	for _index in 5:
		var started := Time.get_ticks_usec()
		action.call()
		await process_frame
		samples.append((Time.get_ticks_usec() - started) / 1000.0)
	samples.sort()
	var median := samples[2]
	print("[WS1_QUEST] PERF %s_median_ms=%.3f peak_ms=%.3f" % [label, median, samples[4]])
	check(median < 40.0, label + " stays inside the local-refresh budget")
	return median

func performance_contract() -> void:
	open_fixture_tab(0, fixture_ids[0])
	await frames(4)
	var first: String = fixture_ids[0]
	var second: String = fixture_ids[1]
	var builds: int = game.quest_windows.window_builds
	await measure_median("task_switch", func(): game.quest_windows.select_quest(second if game.quest_windows.selected == first else first))
	check(game.quest_windows.window_builds == builds, "measured task switching never rebuilds the window")

func capture_frame(name: String, scale_factor: int) -> void:
	if capture_dir == "":
		return
	root.min_size = Vector2i(1, 1)
	root.max_size = Vector2i(8192, 8192)
	root.content_scale_size = Vector2i(800, 600) * scale_factor
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	root.size = root.content_scale_size
	game.transform = Transform2D(0.0, Vector2.ONE * scale_factor, 0.0, Vector2.ZERO)
	var layer := game.ui.get_parent() as CanvasLayer
	layer.transform = Transform2D(0.0, Vector2.ONE * scale_factor, 0.0, Vector2.ZERO)
	await frames(3)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(capture_dir))
	var path := capture_dir.path_join(name + ".png")
	var image := root.get_texture().get_image()
	var error := image.save_png(path)
	check(error == OK and image.get_size() == Vector2i(800, 600) * scale_factor,
		"capture %s writes actual %dx%d pixels" % [name, image.get_width(), image.get_height()])
	var colored := 0
	for y in range(0, image.get_height(), 20):
		for x in range(0, image.get_width(), 20):
			if not image.get_pixel(x, y).is_equal_approx(Color.BLACK):
				colored += 1
	check(colored > 100, "capture %s contains a nonblank rendered window" % name)
	if error == OK:
		print("[WS1_QUEST] CAPTURE " + path)

func capture_contract() -> void:
	if capture_dir == "":
		return
	check(move_to_npc("linus"), "capture fixture reaches Linus for dialogue")
	await frames(3)
	var npc_row: Dictionary = game.town.world.data["npcs"]["linus"]
	var original_line := String(npc_row["dialogue"])
	var capture_definitions: Dictionary = game.session.quests.catalog.definitions
	game.session.quests.catalog.definitions = {}
	npc_row["dialogue"] = ("长按委托说明可以逐行核对话内容，关闭按钮与任务、服务和结束对话按钮共享清晰的键盘焦点。"
		+ "这一段同时验证原版底板、立绘边缘、文字滚动和按钮热区。").repeat(5)
	game.show_overlay("npc")
	await frames(4)
	await capture_frame("quest_dialogue_long_1x", 1)
	await capture_frame("quest_dialogue_long_2x", 2)
	npc_row["dialogue"] = original_line
	game.session.quests.catalog.definitions = capture_definitions
	game.show_overlay("")
	await frames(3)
	open_fixture_tab(1, "ws1.fixture.ready")
	await frames(4)
	await capture_frame("quest_window_long_1x", 1)
	await capture_frame("quest_window_long_2x", 2)
	root.min_size = Vector2i(1600, 1200)
	root.max_size = Vector2i(1600, 1200)
	root.content_scale_size = Vector2i(1600, 1200)
	root.size = Vector2i(1600, 1200)
	game.transform = Transform2D(0.0, Vector2.ONE * 2.0, 0.0, Vector2.ZERO)
	(game.ui.get_parent() as CanvasLayer).transform = Transform2D(0.0, Vector2.ONE * 2.0, 0.0, Vector2.ZERO)
	await frames(2)

func run() -> void:
	await setup_game()
	await dialogue_contract()
	await real_accept_and_failure_contract()
	await fixture_states_contract()
	await tracker_local_update_contract()
	await performance_contract()
	await capture_contract()
	restore_catalog()
	finish()

func finish() -> void:
	var code := 1 if failures else 0
	print("[WS1_QUEST] COMPLETE checks=%d failures=%d" % [checks, failures])
	if is_instance_valid(game):
		game.queue_free()
		await process_frame
	quit(code)
