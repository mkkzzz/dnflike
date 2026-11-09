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
	var upper_icon: TextureRect = upper.get_node("skill_tree_icon")
	var upper_art: Texture2D = panel._tex(panel.by_id[46]["icon"])
	var disabled_art: Texture2D = panel._tex(panel.by_id[46]["icon_selected"])
	var peak_us := 0
	for button: Button in [guard, upper, guard, upper]:
		var start := Time.get_ticks_usec()
		host.click_control(button)
		peak_us = maxi(peak_us, Time.get_ticks_usec() - start)
		await host.ticks(2)
		host.check(panel.selected == button.get_meta("skill_key"), "viewport click selects the requested skill")
		host.check(is_instance_valid(content) and content == game.modal.find_child("skill_tree_content", true, false), "selection retains tree controls and drag sources")
		var skill: Dictionary = panel.by_key[panel.selected]
		var title: Label = game.modal.find_child("skill_detail_title", true, false)
		var rank: Label = game.modal.find_child("skill_detail_title_rank", true, false)
		var detail_icon: TextureRect = game.modal.find_child("skill_detail_icon", true, false)
		host.check(upper_art != disabled_art and upper_icon.texture == upper_art
			and detail_icon.texture == panel._tex(skill["icon"]),
			"skill selection changes the frame while the tree and Explain retain the original color artwork")
		host.check(title.position == Vector2(0, 13) and title.text == skill["name"] and title.get_theme_color("font_color") == Color("f7d65a"),
			"real skill clicks use the Explain title anchor and original active skill color")
		host.check(rank.position == Vector2(title.size.x, title.position.y) and rank.text == " Lv%d" % int(panel._effective_levels.get(skill["local_id"], 0)),
			"real skill clicks show the effective rank alongside the current name")
	var selected_frame: TextureRect = upper.get_child(0)
	upper.mouse_entered.emit()
	upper.mouse_exited.emit()
	host.check(selected_frame.modulate == Color.WHITE and selected_frame.texture == panel._part("node_selected"), "selection and hover use current state after an in-place update")
	host.check(peak_us < 250000, "warm selection avoids the previous multi-second main-thread stall")
	print("[SKILL_PERF] viewport_selection_peak_ms=%.3f" % (peak_us / 1000.0))
	await check_previews(game, host, panel, upper, guard)
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
	var guard_skill: Dictionary = panel.by_id[1]
	var guard_icon: TextureRect = guard.get_node("skill_tree_icon")
	game.session.profile["level"] = int(guard_skill["required_level"]) - 1
	panel._refresh_node(guard_skill["key"])
	host.check(guard_icon.texture == panel._tex(guard_skill["icon_selected"]),
		"original disabled art marks the tree node below its base level")
	game.session.profile["level"] += 1
	panel._refresh_node(guard_skill["key"])
	host.check(guard_icon.texture == panel._tex(guard_skill["icon"]) and guard_icon.modulate == Color.WHITE,
		"reaching the original base level restores the color tree art")
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
	var preview := game.modal.find_child("skill_detail_preview", true, false) as TextureRect
	host.click_control(action_button(game, "关闭"))
	await host.ticks(2)
	host.check(not is_instance_valid(preview), "closing the skill window releases the active demo")
	game.show_overlay("numbers")
	await host.ticks(3)

func check_previews(game, host, panel, upper: Button, guard: Button) -> void:
	var preview: TextureRect = await playing_preview(game, host)
	host.check(preview != null and preview.position == Vector2(22, 37) and preview.size == Vector2(160, 90),
		"Explain draws UpperSlash on the original video rectangle")
	if preview == null:return
	var atlas := preview.texture as AtlasTexture
	var fallback: TextureRect = game.modal.find_child("skill_detail_icon", true, false)
	host.check(atlas.atlas.resource_path.ends_with("/swordman_upperslash.png") and not fallback.is_visible_in_tree(),
		"original video replaces the static illustration and leaves the title readable")
	preview.set_process(false)
	preview._elapsed = 0.0
	preview._show_frame(0)
	preview._process(8.5 * 1001.0 / 30000.0)
	host.check(atlas.region == Rect2(0, 90, 160, 90), "original rational frame clock advances across atlas rows")
	await host.frame("62a_skill_preview_upper")
	preview._process(41.0 * 1001.0 / 30000.0)
	host.check(atlas.region.position == Vector2.ZERO, "UpperSlash loops after its original 49 frames")
	panel._replace_detail(true)
	host.check(preview == game.modal.find_child("skill_detail_preview", true, false),
		"refreshing the selected skill details retains the current playback")

	host.click_control(guard)
	var guard_preview: TextureRect = await playing_preview(game, host)
	host.check(guard_preview != null and guard_preview != preview and not is_instance_valid(preview)
		and guard_preview.texture.atlas.resource_path.ends_with("/swordman_guard.png"),
		"selecting Guard releases UpperSlash and starts the matching original clip")
	var unsupported: Button = game.modal.find_child("skill_node_5", true, false)
	host.click_control(unsupported)
	await host.ticks(2)
	fallback = game.modal.find_child("skill_detail_icon", true, false)
	host.check(panel.selected == unsupported.get_meta("skill_key")
		and not is_instance_valid(guard_preview) and fallback.is_visible_in_tree(),
		"selecting a skill without bundled media stops playback and retains its static fallback")
	host.click_control(upper)
	await host.ticks(2)

func playing_preview(game, host) -> TextureRect:
	for tick in range(60):
		var preview := game.modal.find_child("skill_detail_preview", true, false) as TextureRect
		if preview != null and preview.texture is AtlasTexture:return preview
		await host.ticks(1)
	return null

func action_button(game, title: String) -> Button:
	for button: Button in game.modal.find_children("*", "Button", true, false):
		if button.get_meta("action_label", "") == title:return button
	return null
