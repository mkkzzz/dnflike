extends SceneTree
## ws1-owned attributes/equipment window contract and render evidence.
const Loop = preload("res://flow/loop_root.gd")
const Numbers = preload("res://stats/api/numbers.gd")

var game
var checks := 0
var failures := 0
var capture_dir := ""
var gear_uids: Dictionary = {}

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var capture := "--capture" in args
	if capture:
		capture_dir = String(args[args.find("--output") + 1]) \
			if args.find("--output") >= 0 and args.find("--output") + 1 < args.size() else ""
		if OS.get_environment("DNF_PRIVATE_DESKTOP") != "1" \
			or DisplayServer.get_name() == "headless" or capture_dir == "":
			push_error("[WS1_NUMBER] capture requires the private desktop and --output")
			quit(1)
			return
	elif DisplayServer.get_name() != "headless":
		push_error("[WS1_NUMBER] headless display required")
		quit(1)
		return
	call_deferred("run")

func check(value: bool, message: String) -> void:
	checks += 1
	if value:
		print("[WS1_NUMBER] PASS " + message)
	else:
		failures += 1
		push_error("[WS1_NUMBER] FAIL " + message)

func frames(count := 3) -> void:
	for _index in count:
		await process_frame

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
	await frames(3)

func find_control(node_name: String) -> Control:
	for node in game.modal.find_children(node_name, "Control", true, false):
		var control := node as Control
		if control != null and not control.is_queued_for_deletion():
			return control
	return null

func find_action(label: String) -> Button:
	for node in game.modal.find_children("*", "Button", true, false):
		if node.is_queued_for_deletion():
			continue
		if node.text == label or String(node.get_meta("action_label", "")) == label:
			return node
	return null

func press_action(label: String) -> bool:
	var button := find_action(label)
	if button == null or button.disabled:
		return false
	button.pressed.emit()
	return true

func label_text(root_node: Node) -> String:
	var result := ""
	for node in root_node.find_children("*", "Label", true, false):
		var label := node as Label
		if label != null and not label.is_queued_for_deletion():
			result += label.text + "\n"
	return result

func setup_game() -> void:
	game = Loop.new()
	root.add_child(game)
	await frames(4)
	var unique := Crypto.new().generate_random_bytes(8).hex_encode()
	game.store.path = "res://../temp/ws1_number_tests/profile_" + unique + ".json"
	game.session = game.Session.new()
	game.session.profile["name"] = "属性契约旅人"
	game.session.profile["level"] = 1
	game.session.profile["stat_modifiers"] = []
	for index in 16:
		game.session.profile["stat_modifiers"].append({
			"source": "试炼增益 %02d · 用于验证长来源文本换行与纵向滚动" % index,
			"stat": "hp_max",
			"op": "add",
			"value": index + 1,
		})
	var fixture_gear := [
		["forest_sword", 100],
		["forest_sword", 0],
		["iron_sword", 65],
		["training_coat", 80],
		["training_coat", 20],
		["training_necklace", 50],
		["original_10580", 90],
		["iron_sword", 35],
		["iron_sword", 10],
		["forest_sword", 50],
	]
	for entry: Array in fixture_gear:
		var definition := String(entry[0])
		var response: Dictionary = game.session.command("numbers.gear_give", {
			"id": definition,
			"quality": int(entry[1]),
		})
		check(response.get("ok", false), "fixture creates equipment instance " + definition)
		if response.get("ok", false):
			var items: Array = gear_uids.get(definition, [])
			items.append(String(response["uid"]))
			gear_uids[definition] = items
	check(game.store.write(game.session), "disposable attributes character is written")
	check(game.enter_character(game.store.path), "disposable attributes character enters the real town flow")
	await frames(4)
	game.ui_audio.muted = true
	game.town.set_voice_enabled(false)
	game.town.stop_npc_voices(true)

func format_contract() -> void:
	var windows = game.number_windows
	check(windows.format_value("physical_crit", 0.321) == "32.1%", "percentage stats use one-decimal percent units")
	check(windows.format_value("cooldown_rate", 0.85) == "0.850×", "cooldown rate keeps an explicit ratio unit")
	check(windows.format_value("hp_regen", 12.5) == "12.50/s", "regeneration stats show per-second units")
	check(windows.format_value("carry_capacity", 72.25) == "72.3 kg", "carry capacity shows a readable weight unit")
	check(windows.format_value("hp_max", 527.1) == "527", "resource limits avoid false decimal precision")
	check(windows.format_source_value("physical_crit", "percent", 0.1) == "+10.0%", "percentage sources show their signed contribution")
	check(windows.format_source_value("damage_rate", "mul", 1.2) == "×1.200", "multiplicative sources show a multiplier")

func open_and_attribute_contract() -> void:
	await press_key(KEY_O)
	check(game.overlay == "numbers", "O opens the attributes window through the real keyboard route")
	var window: Control = game.number_windows.window
	check(window != null and window.position == Vector2(28, 38) and window.size == Vector2(744, 458),
		"attributes keep the native 744x458 board")
	check(game.number_windows.window_builds == 1, "attributes use one stable root build")
	var builds: int = game.number_windows.window_builds
	var root_before: Node = game.modal.find_child("number_window", true, false)
	var content_before := find_control("number_window_content")
	var list_scroll := find_control("number_attribute_list_scroll") as ScrollContainer
	var source_scroll := find_control("number_source_scroll") as ScrollContainer
	check(list_scroll != null and list_scroll.position == Vector2(162, 104) and list_scroll.size == Vector2(264, 284),
		"attribute rows keep a dedicated native-scale scroll viewport")
	check(list_scroll.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED,
		"attribute rows never introduce horizontal layout drift")
	check(source_scroll != null and source_scroll.position == Vector2(8, 38) and source_scroll.size == Vector2(276, 270),
		"source details keep a separate native-scale scroll viewport")
	var source_body := find_control("number_source_body") as VBoxContainer
	check(source_body != null and source_body.get_combined_minimum_size().y > source_scroll.size.y,
		"long source details exceed the viewport instead of clipping silently")
	var source_bar := source_scroll.get_v_scroll_bar()
	check(source_bar.max_value > source_bar.page, "long source details expose a real vertical scrollbar")
	source_scroll.scroll_vertical = int(source_bar.max_value - source_bar.page)
	await frames(2)
	check(source_scroll.scroll_vertical > 0, "source details reach the final wrapped contribution")
	var group_button := find_control("number_group_attack") as Button
	check(group_button != null, "attribute categories render as real buttons")
	if group_button != null:
		group_button.pressed.emit()
	await frames(4)
	check(game.number_windows.selected_group == "attack" and game.number_windows.selected_stat == "physical_attack",
		"category switch selects the first meaningful attack stat")
	check(game.modal.find_child("number_window", true, false) == root_before
		and find_control("number_window_content") == content_before
		and game.number_windows.window_builds == builds,
		"category switch refreshes content without rebuilding the modal root")
	var title := find_control("number_source_title") as Label
	check(title != null and title.text.contains("基础物攻"), "source title follows the selected attribute")
	var stat_row := find_control("number_stat_physical_panel") as Button
	check(stat_row != null, "panel attack is selectable inside the attack category")
	if stat_row != null:
		stat_row.pressed.emit()
	await frames(3)
	title = find_control("number_source_title") as Label
	check(game.number_windows.selected_stat == "physical_panel"
		and title != null and title.text.contains("物理攻击面板"),
		"attribute selection updates the source detail in place")
	check(game.modal.find_child("number_window", true, false) == root_before,
		"attribute selection retains the stable window root")
	var focus_ok := true
	for group: Button in game.number_windows.group_buttons:
		focus_ok = focus_ok and group.focus_mode == Control.FOCUS_ALL
	check(focus_ok, "all attribute categories accept keyboard focus")

func duplicate_uids(definition: String) -> Array:
	return (gear_uids.get(definition, []) as Array).duplicate()

func reach_same_name_page(first_uid: String, second_uid: String) -> int:
	var total := maxi(1, ceili(float(game.session.profile["gear"].size()) / 5.0))
	for target in total:
		game.number_windows.page = target
		game.number_windows._render_content()
		await frames(3)
		if find_control("number_gear_" + first_uid) != null \
			and find_control("number_gear_" + second_uid) != null:
			return target
	return -1

func equipment_contract() -> void:
	var root_before: Node = game.modal.find_child("number_window", true, false)
	var builds: int = game.number_windows.window_builds
	var equipment_tab := find_control("number_tab_2") as Button
	check(equipment_tab != null, "equipment tab is available from the same growth window")
	if equipment_tab != null:
		equipment_tab.pressed.emit()
	await frames(4)
	check(game.number_windows.tab == 2 and find_control("number_equipment_list_scroll") != null,
		"equipment tab renders the instance board")
	check(game.modal.find_child("number_window", true, false) == root_before
		and game.number_windows.window_builds == builds,
		"attributes-to-equipment switch does not rebuild the modal root")
	var coats := duplicate_uids("training_coat")
	check(coats.size() == 2, "same-name coat fixtures have two distinct instance UIDs")
	var pair_page := await reach_same_name_page(String(coats[0]), String(coats[1]))
	check(pair_page >= 0, "two same-name equipment instances can appear together on one page")
	var first_row := find_control("number_gear_" + String(coats[0])) as Button
	var second_row := find_control("number_gear_" + String(coats[1])) as Button
	check(first_row != null and second_row != null, "same-name equipment renders one row per exact UID")
	if first_row != null and second_row != null:
		check(first_row.text.contains("编号" + String(coats[0]).trim_prefix("gear_"))
			and second_row.text.contains("编号" + String(coats[1]).trim_prefix("gear_"))
			and first_row.text != second_row.text,
			"same-name rows expose their unique instance number")
		first_row.pressed.emit()
	await frames(3)
	check(game.number_windows.selected_gear_uid == String(coats[0]),
		"selecting a row records the exact equipment UID")
	var selected_before: String = game.number_windows.selected_gear_uid
	var next_page := find_control("number_equipment_next") as Button
	if next_page != null and game.number_windows.page < ceili(float(game.session.profile["gear"].size()) / 5.0) - 1:
		next_page.pressed.emit()
	await frames(4)
	check(game.number_windows.selected_gear_uid == selected_before,
		"paging keeps the selected equipment UID even when its row leaves the page")
	check(game.number_windows.page > pair_page, "equipment paging advances only the list content")

	var swords := duplicate_uids("forest_sword")
	game.number_windows.select_gear(String(swords[0]))
	await frames(3)
	var detail := find_control("number_equipment_detail") as VBoxContainer
	check(detail != null and label_text(detail).contains("换装比较"),
		"selected equipment compares its preview panel with the current slot")
	check(label_text(detail).contains("物理攻击面板"), "comparison lists the primary panel change")
	game.number_windows.select_gear(String(swords[1]))
	await frames(3)
	check(game.number_windows.selected_gear_uid == String(swords[1]),
		"same-name sword selection retains the newly selected exact UID")
	check(label_text(detail) != "" and label_text(detail).contains("编号 " + String(swords[1]).trim_prefix("gear_")),
		"same-name sword detail names the selected instance identity")

	var original_coats := duplicate_uids("original_10580")
	var action := find_action("装备")
	game.number_windows.select_gear(String(original_coats[0]))
	await frames(3)
	var equipment_before := JSON.stringify(game.session.profile["equipment"])
	check(press_action("装备"), "high-level coat exposes an equipment action")
	await frames(4)
	var feedback := find_control("number_window_feedback") as Label
	check(game.session.profile["equipment"].get("coat", "") == ""
		and JSON.stringify(game.session.profile["equipment"]) == equipment_before
		and feedback != null and feedback.visible and feedback.text.contains("等级不足"),
		"equipment rejection preserves the slot and reports the reason in-window")

	game.number_windows.select_gear(String(coats[0]))
	await frames(3)
	check(press_action("装备"), "eligible coat can be equipped from the selected instance")
	await frames(4)
	check(game.session.profile["equipment"].get("coat", "") == String(coats[0]),
		"successful equipment commits the exact selected UID")
	feedback = find_control("number_window_feedback") as Label
	check(feedback != null and feedback.visible and feedback.text.contains("已装备"),
		"successful equipment shows an in-window receipt")
	action = find_action("卸下")
	check(action != null, "equipped instance immediately exposes its matching unequip action")
	check(press_action("卸下"), "equipped instance can be removed through the same action")
	await frames(4)
	check(not game.session.profile["equipment"].has("coat"),
		"unequip clears the actual equipment transaction")
	feedback = find_control("number_window_feedback") as Label
	check(feedback != null and feedback.visible and feedback.text.contains("已卸下"),
		"unequip keeps its result inside the equipment board")

	var gear_backup: Dictionary = game.session.profile["gear"].duplicate(true)
	var equipment_backup: Dictionary = game.session.profile["equipment"].duplicate(true)
	game.session.profile["gear"] = {}
	game.session.profile["equipment"] = {}
	game.number_windows._render_content()
	await frames(3)
	check(find_control("number_equipment_empty") != null,
		"empty equipment renders an explicit empty state")
	game.session.profile["gear"] = gear_backup
	game.session.profile["equipment"] = equipment_backup
	game.number_windows.selected_gear_uid = String(swords[0])
	game.number_windows._render_content()
	await frames(3)

func capture_contract() -> void:
	if capture_dir == "":
		return
	game.notification = ""
	game.notification_seconds = 0.0
	if is_instance_valid(game.toast_panel):
		game.toast_panel.hide()
	game.number_windows.tab = 2
	game.number_windows.selected_gear_uid = String((gear_uids["forest_sword"] as Array)[0])
	game.show_overlay("numbers")
	await frames(4)
	await capture_frame("number_equipment_1x", 1)
	await capture_frame("number_equipment_2x", 2)
	game.number_windows.tab = 0
	game.number_windows.selected_group = "core"
	game.number_windows.selected_stat = "hp_max"
	game.show_overlay("numbers")
	await frames(4)
	await capture_frame("number_attributes_1x", 1)
	await capture_frame("number_attributes_2x", 2)

func capture_frame(name: String, scale_factor: int) -> void:
	root.min_size = Vector2i(1, 1)
	root.max_size = Vector2i(8192, 8192)
	root.content_scale_size = Vector2i(800, 600) * scale_factor
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	root.size = root.content_scale_size
	game.transform = Transform2D(0.0, Vector2.ONE * scale_factor, 0.0, Vector2.ZERO)
	(game.ui.get_parent() as CanvasLayer).transform = Transform2D(0.0, Vector2.ONE * scale_factor, 0.0, Vector2.ZERO)
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
	check(colored > 100, "capture %s contains a nonblank rendered board" % name)
	if error == OK:
		print("[WS1_NUMBER] CAPTURE " + path)

func skill_and_battle_contract() -> void:
	game.show_overlay("")
	await frames(3)
	await press_key(KEY_K)
	check(game.overlay == "numbers" and game.number_windows.tab == 1,
		"K opens the existing skill page directly")
	check(find_control("skill_tree_viewport") != null,
		"K bypasses the redundant attributes/equipment shell")
	await press_key(KEY_ESCAPE)
	check(game.overlay == "", "Esc closes the skill page through the shared route")
	game.number_windows.tab = 0
	game.show_overlay("numbers")
	await frames(4)
	var town_stats: Dictionary = game.number_windows.live_stats()["values"]
	check(town_stats == game.session.stats()["numbers"],
		"town attributes read the published profile numeric snapshot")
	game.show_overlay("")
	game.depart()
	await frames(5)
	check(game.combat.is_running(), "numeric window fixture starts a real battle")
	if not game.combat.is_running():
		return
	game.number_windows.tab = 0
	game.show_overlay("numbers")
	await frames(4)
	var battle_stats: Dictionary = game.combat.read_view()["numbers"]
	var live_stats: Dictionary = game.number_windows.live_stats()["values"]
	check(live_stats["physical_panel"] == battle_stats["physical_panel"]
		and live_stats["physical_defense"] == battle_stats["physical_defense"],
		"battle attributes read the live combat numeric view")
	var strength_before := float(live_stats["strength"])
	check(game.debug_panel.commands.execute("buff strength_potion")["ok"],
		"temporary effect fixture applies through the published debug transaction")
	game.show_overlay("numbers")
	await frames(4)
	var source_body := find_control("number_source_body") as VBoxContainer
	var sources_text := label_text(source_body)
	check(game.number_windows.live_stats()["values"]["strength"] > strength_before,
		"temporary effect changes the live computed attribute")
	check(sources_text.contains("当前效果") and sources_text.contains("力量"),
		"temporary effect is visible in the source panel")
	game.show_overlay("")

func run() -> void:
	await setup_game()
	format_contract()
	await open_and_attribute_contract()
	await equipment_contract()
	await capture_contract()
	await skill_and_battle_contract()
	finish()

func finish() -> void:
	var code := 1 if failures else 0
	print("[WS1_NUMBER] COMPLETE checks=%d failures=%d" % [checks, failures])
	if is_instance_valid(game):
		game.queue_free()
		await process_frame
	quit(code)
