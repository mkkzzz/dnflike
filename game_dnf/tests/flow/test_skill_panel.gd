extends RefCounted
## Real viewport input: keep the tree alive across selection, wheel and learning.

func run(game, host) -> void:
	var panel = game.number_windows.skill_panel
	var original_job: String = game.session.profile["growtype"]
	var original_selected: String = panel.selected
	var original_scroll: float = panel.tree_scroll
	var original_level: int = game.session.profile["level"]
	game.session.profile["level"] = 60
	var valid_states := true
	for job: String in panel.JOB_NAMES:
		game.session.profile["growtype"] = job
		for node: Dictionary in panel.tree_nodes():
			var state: Dictionary = panel._state(panel.by_id[int(node["id"])])
			valid_states = valid_states and state.has("ok") and state.has("reason")
	host.check(valid_states, "all five job trees handle missing SKL learning fields without script errors")
	game.session.profile["growtype"] = "weaponmaster"
	panel.tree_scroll = 0
	game.show_overlay("numbers")
	await host.ticks(3)
	var has_navigation := false
	for button: Button in game.modal.find_children("*", "Button", true, false):
		has_navigation = has_navigation or button.get_meta("action_label", "") in ["属性", "技能", "装备"]
	host.check(not has_navigation and game.modal.find_child("skill_window_title", true, false) != null, "skill window has a title and no cross-panel tabs")
	var ui_font = preload("res://ui/flow/ui_font.gd")
	host.check(game.skin.font.oversampling == game.display_settings.CONTENT_SCALE and game.skin.font == ui_font.make(), "UI font matches the 2x canvas density and reuses its glyph cache")
	var content: Control = game.modal.find_child("skill_tree_content", true, false)
	var scroll: VScrollBar = game.modal.find_child("skill_tree_scroll", true, false)
	var guard: Button = game.modal.find_child("skill_node_1", true, false)
	var upper: Button = game.modal.find_child("skill_node_46", true, false)
	var peak_us := 0
	for button: Button in [guard, upper, guard, upper]:
		var start := Time.get_ticks_usec()
		host.click_control(button)
		peak_us = maxi(peak_us, Time.get_ticks_usec() - start)
		await host.ticks(2)
		host.check(panel.selected == button.get_meta("skill_key"), "viewport click selects the requested skill")
		host.check(is_instance_valid(content) and content == game.modal.find_child("skill_tree_content", true, false), "selection retains tree controls and drag sources")
	var selected_frame: TextureRect = upper.get_child(0)
	upper.mouse_entered.emit()
	upper.mouse_exited.emit()
	host.check(selected_frame.modulate == Color.WHITE and selected_frame.texture == panel._part("node_selected"), "selection and hover use current state after an in-place update")
	host.check(peak_us < 250000, "warm selection avoids the previous multi-second main-thread stall")
	print("[SKILL_PERF] viewport_selection_peak_ms=%.3f" % (peak_us / 1000.0))
	var wheel := InputEventMouseButton.new()
	wheel.position = upper.get_global_transform_with_canvas() * (upper.size / 2)
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel.pressed = true
	game.get_viewport().push_input(wheel, true)
	await host.ticks(2)
	host.check(scroll.value > 0 and content.position.y == -scroll.value, "wheel over a skill icon reaches the tree scrollbar")
	var offset := scroll.value
	panel.select_skill(String(guard.get_meta("skill_key")))
	await host.ticks(2)
	host.check(scroll.value == offset and content.position.y == -offset, "changing detail keeps the tree scroll position")
	var edge: Line2D = game.modal.find_child("skill_edge_1_3", true, false)
	host.check(edge.default_color == Color("c39a54"), "prerequisite edge highlights update without rebuilding the tree")
	game.session.profile["growtype"] = original_job
	game.session.profile["level"] = original_level
	panel.selected = original_selected
	panel.tree_scroll = original_scroll
	game.show_overlay("numbers")
	await host.ticks(3)
	var footer: Array[Rect2] = []
	var separated := true
	for button: Button in game.modal.find_children("*", "Button", true, false):
		if button.position.y != 461:continue
		var rect := button.get_global_rect()
		for previous: Rect2 in footer:
			separated = separated and not previous.intersects(rect)
		footer.append(rect)
	host.check(footer.size() == 6 and separated, "all four job buttons remain separate from reset and close")
	var refund: Button = action_button(game, "退点")
	host.check(refund != null and refund.disabled, "gifted initial rank cannot offer an invalid refund")
	var learn: Button = action_button(game, "加点")
	var buttons_fit := true
	for button: Button in [learn, refund]:
		buttons_fit = buttons_fit and button.size == Vector2(18, 18) and button.position.y + button.size.y <= 176
		for state: String in ["normal", "hover", "pressed", "disabled"]:
			var style := button.get_theme_stylebox(state) as StyleBoxTexture
			buttons_fit = buttons_fit and style != null and style.texture != null and style.texture.get_size() == Vector2(18, 18)
	host.check(buttons_fit, "native rank button states fit above the scrollable description")

func action_button(game, title: String) -> Button:
	for button: Button in game.modal.find_children("*", "Button", true, false):
		if button.get_meta("action_label", "") == title:return button
	return null
