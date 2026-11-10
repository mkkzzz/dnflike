extends SceneTree
## ws1-owned skill panel contract. Uses the real panel and a disposable UI fixture.
const Loop = preload("res://flow/loop_root.gd")
const UIFont = preload("res://ui/flow/ui_font.gd")

var game
var panel
var checks := 0
var failures := 0

func _initialize() -> void:
	if DisplayServer.get_name() != "headless":
		push_error("[WS1_PANEL] headless display required")
		quit(1)
		return
	call_deferred("run")

func check(value: bool, message: String) -> void:
	checks += 1
	if value:
		print("[WS1_PANEL] PASS " + message)
	else:
		failures += 1
		push_error("[WS1_PANEL] FAIL " + message)

func find_button(node: Node, name: String) -> Button:
	return node.find_child(name, true, false) as Button

func find_control(node: Node, name: String) -> Control:
	return node.find_child(name, true, false) as Control

func find_close_button() -> Control:
	for control: Control in game.modal.find_children("*", "TextureButton", true, false):
		if control.position == Vector2(748, 8):
			return control
	return null

func long_skill_key() -> String:
	if panel._node_views.has("illusionslash"):
		return "illusionslash"
	var best := ""
	var best_length := 0
	for key: String in panel._node_views:
		var skill: Dictionary = panel._node_views[key]["skill"]
		var description := String(skill.get("explain", "")) + String(skill.get("basic_explain", ""))
		if description.length() > best_length:
			best = key
			best_length = description.length()
	return best if best != "" else panel.selected

func setup() -> void:
	game = Loop.new()
	game.town = game.Town.new()
	game.town.loader.load_export("res://assets_local/flow_v1/manifest.json")
	game.skin = game.NativeSkin.new(game.town.loader)
	game.windows = game.Windows.new(game)
	game.number_windows = game.NumberWindows.new(game)
	game.skill_catalog = game.SkillCatalog.new()
	game.recovery_bridge = game.RecoveryBridge.new(game)
	game.ui_audio = game.UIAudio.new()
	game.character_active = true
	game.ui = Control.new()
	game.ui.size = Vector2(800, 600)
	root.add_child(game.ui)
	game.modal = Control.new()
	game.modal.size = Vector2(800, 600)
	game.modal.mouse_filter = Control.MOUSE_FILTER_IGNORE
	game.ui.add_child(game.modal)
	game.hud = Control.new()
	game.ui.add_child(game.hud)
	game.store.path = "res://../temp/ws1_panel_contract/profile_%s.json" % Crypto.new().generate_random_bytes(8).hex_encode()
	game.session.profile["growtype"] = "weaponmaster"
	game.session.profile["level"] = 60
	game.session.profile["sp_bonus"] = 2000
	game.number_windows.tab = 1
	panel = game.number_windows.skill_panel

func open_panel() -> void:
	game.show_overlay("numbers")
	for i in 4:
		await process_frame

func layout_checks() -> void:
	var window := find_control(game.modal, "number_window")
	check(window != null and window.position == Vector2(14, 12) and window.size == Vector2(772, 490),
		"skill panel keeps the 772x490 native window")
	var tree := find_control(game.modal, "skill_tree_viewport")
	check(tree != null and tree.position == Vector2(10, 88) and tree.size == Vector2(540, 342),
		"tree viewport keeps the native 540x342 rectangle")
	var detail := find_control(game.modal, "skill_detail")
	check(detail != null and detail.position == Vector2(562, 35) and detail.size == Vector2(199, 402),
		"detail board keeps the native 199x402 rectangle")
	check(game.display_settings.CONTENT_SCALE == 2 and game.skin.font.oversampling == 2,
		"panel font uses the 2x canvas density")
	check(game.skin.font == UIFont.make(), "panel reuses the shared UI font cache")
	var close := find_close_button()
	check(close != null and close.position == Vector2(748, 8), "native close control stays at the top-right")

func interaction_checks() -> void:
	var upper := find_button(game.modal, "skill_node_46")
	var guard := find_button(game.modal, "skill_node_1")
	check(upper != null and guard != null, "tree exposes Upper Slash and Guard controls")
	if upper == null or guard == null:
		return
	var upper_base := upper.get_child(0) as TextureRect
	var guard_base := guard.get_child(0) as TextureRect
	var tree_content := find_control(game.modal, "skill_tree_content")
	var tree_scroll := game.modal.find_child("skill_tree_scroll", true, false) as VScrollBar
	panel.tree_scroll = 0.0
	if tree_scroll != null:
		tree_scroll.value = 0.0

	guard.mouse_entered.emit()
	check(guard_base.modulate == Color(1.25, 1.25, 1.25, 1.0), "hover brightens an unselected tree node")
	guard.mouse_exited.emit()
	check(guard_base.modulate == guard_base.get_meta("rest_tint", Color.WHITE), "hover exit restores the node rest tint")

	guard.pressed.emit()
	await process_frame
	var title := find_control(game.modal, "skill_detail_title") as Label
	check(panel.selected == guard.get_meta("skill_key") and title != null
		and title.text == String(panel.by_key[panel.selected]["name"]),
		"selecting Guard updates the title without rebuilding the tree")
	check(find_control(game.modal, "skill_tree_content") == tree_content,
		"skill selection retains the tree controls and drag sources")
	check(panel.tree_scroll == 0.0, "skill selection preserves the current tree scroll")

	upper.pressed.emit()
	await process_frame
	title = find_control(game.modal, "skill_detail_title") as Label
	check(panel.selected == upper.get_meta("skill_key") and title != null
		and title.text == String(panel.by_key[panel.selected]["name"]),
		"switching skills updates the detail title")
	check(upper_base.texture == panel._part("node_selected") and guard_base.texture == panel._part("node_slot"),
		"selection swaps the native node frame")
	check(find_control(game.modal, "skill_tree_content") == tree_content,
		"switching skills retains the tree")

	var guard_skill: Dictionary = panel.by_key[guard.get_meta("skill_key")]
	var original_level := int(game.session.profile["level"])
	game.session.profile["level"] = int(guard_skill["required_level"]) - 1
	panel._refresh_node(guard_skill["key"])
	check((guard.get_node("skill_tree_icon") as TextureRect).texture == panel._tex(guard_skill["icon_selected"]),
		"below base level uses the original disabled icon")
	game.session.profile["level"] = original_level
	panel._refresh_node(guard_skill["key"])
	check((guard.get_node("skill_tree_icon") as TextureRect).texture == panel._tex(guard_skill["icon"]),
		"restoring the level restores the color icon")

	var long_key := long_skill_key()
	if long_key != "" and panel._node_views.has(long_key):
		panel.select_skill(long_key)
		for i in 3:
			await process_frame
		var body := find_control(game.modal, "skill_detail_body") as RichTextLabel
		check(body != null and body.get_content_height() > body.size.y,
			"long descriptions overflow into the native scroll viewport")
		if body != null:
			var body_scroll := body.get_v_scroll_bar()
			check(body_scroll.max_value > body_scroll.page, "long descriptions expose a real vertical scrollbar")
			body_scroll.value = body_scroll.max_value - body_scroll.page
			await process_frame
			check(body_scroll.value > 0.0, "long descriptions can scroll to the last row")
	else:
		check(false, "fixture finds a long visible skill description")

	panel.selected = guard.get_meta("skill_key")
	game.show_overlay("numbers")
	await process_frame
	var retained_tree := find_control(game.modal, "skill_tree_content")
	var retained_scroll := find_control(game.modal, "skill_tree_scroll") as VScrollBar
	if retained_scroll != null:
		retained_scroll.value = 32.0
	panel.tree_scroll = 32.0
	game.session.command("numbers.skill_grant", {"id": "hardattack", "level": 1})
	panel._refresh_progress()
	await process_frame
	check(find_control(game.modal, "skill_tree_content") == retained_tree,
		"local learning refresh retains the tree control")
	check(panel.tree_scroll == 32.0 and retained_scroll != null and retained_scroll.value == 32.0,
		"local learning refresh retains the tree scroll")

func empty_state_check() -> void:
	var original_sp = panel.trees.get("sp", [])
	var original_job := String(game.session.profile["growtype"])
	var original_selected: String = panel.selected
	panel.trees["sp"] = [{"source_branch": "none", "nodes": [], "edges": []}]
	game.session.profile["growtype"] = "swordman"
	panel.selected = ""
	game.show_overlay("numbers")
	await process_frame
	var content := find_control(game.modal, "skill_tree_content")
	check(content != null and content.get_child_count() == 0 and panel._node_views.is_empty(),
		"empty job tree renders without phantom nodes")
	check(find_control(game.modal, "skill_detail") == null,
		"empty job tree does not leave a stale detail board")
	panel.trees["sp"] = original_sp
	game.session.profile["growtype"] = original_job
	panel.selected = original_selected
	game.show_overlay("numbers")
	await process_frame

func measure_once(label: String, action: Callable, budget_ms: float) -> float:
	var started := Time.get_ticks_usec()
	action.call()
	await process_frame
	var elapsed := (Time.get_ticks_usec() - started) / 1000.0
	print("[WS1_PANEL] PERF %s_ms=%.3f budget_ms=%.1f" % [label, elapsed, budget_ms])
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
	print("[WS1_PANEL] PERF %s_median_ms=%.3f peak_ms=%.3f budget_ms=%.1f" % [
		label, samples[1], samples[2], budget_ms])
	check(samples[1] < budget_ms, label + " median stays inside the budget")
	return samples[1]

func performance_checks() -> void:
	game.show_overlay("")
	await process_frame
	var learn_key := ""
	var rank_before := 0
	for key: String in panel._node_views:
		var skill: Dictionary = panel._node_views[key]["skill"]
		if String(skill.get("local_id", "")) != "" and bool(panel._state(skill)["ok"]):
			learn_key = key
			rank_before = int(game.session.profile["skills"].get(String(skill["local_id"]), 0))
			break
	check(learn_key != "", "performance fixture finds a learnable skill")
	await measure_once("first_open", func():
		game.number_windows.tab = 1
		game.show_overlay("numbers"), 120.0)
	await measure_median("hot_open", func():
		game.number_windows.tab = 1
		game.show_overlay("numbers"), 80.0)
	await measure_median("select_guard_upper", func():
		panel.select_skill("guard")
		panel.select_skill("upper"), 40.0)
	await measure_median("long_detail_refresh", func():
		panel.select_skill(long_skill_key())
		panel._refresh_progress(), 40.0)
	if learn_key != "":
		var local := String(panel.by_key[learn_key]["local_id"])
		await measure_once("actual_learn", func():
			panel.selected = learn_key
			panel.change(learn_key, 1), 500.0)
		check(int(game.session.profile["skills"].get(local, 0)) == rank_before + 1,
			"actual learn transaction updates the rank")
		await measure_once("actual_refund", func():
			panel.change(learn_key, -1), 500.0)
		check(int(game.session.profile["skills"].get(local, 0)) == rank_before,
			"actual refund restores the rank")

func run() -> void:
	setup()
	await open_panel()
	layout_checks()
	await interaction_checks()
	await empty_state_check()
	await performance_checks()
	await release_resources()

func release_resources() -> void:
	var code := 1 if failures else 0
	print("[WS1_PANEL] COMPLETE checks=%d failures=%d" % [checks, failures])
	if is_instance_valid(game):
		game.ui_audio.free()
		game.modal.free()
		game.hud.free()
		game.town.free()
		game.free()
	await process_frame
	quit(code)
