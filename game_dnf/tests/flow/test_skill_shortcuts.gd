extends RefCounted
## Exercise every real drop target with both legacy and later active skills.
func run(game, host, driver) -> void:
	check_art(game.hud, host)
	var original: Array = game.session.profile["skill_slots"].duplicate()
	for entry in [[5, "hardattack"], [46, "upper"]]:
		for index in game.SkillSlots.COUNT:
			var source: Control = game.modal.find_child("skill_node_%d" % entry[0], true, false)
			var target: Control = game.hud.find_child("hud_skill_slot_%d" % index, true, false)
			await driver.drag_skill(source, target)
			host.check(game.session.profile["skill_slots"][index] == entry[1] and game.session.profile["skill_slots"].count(entry[1]) == 1,
				"tree drag binds %s to %s exactly once" % [entry[1], game.SkillSlots.LABELS[index]])
	game.build_hotbars()
	host.check(game.session.profile["skill_slots"][11] == "upper", "HUD refresh preserves a later active skill binding")
	var restored = game.Session.new()
	host.check(restored.restore(JSON.parse_string(JSON.stringify(game.session.serialize()))) and restored.profile["skill_slots"][11] == "upper", "save/load preserves a later active skill binding")
	for index in game.SkillSlots.COUNT:
		# Change the occupant on each drop so neither corner can pass as a no-op.
		for entry in [[5, "hardattack", Vector2(1, 1)], [46, "upper", Vector2(26, 26)]]:
			var source: Control = game.modal.find_child("skill_node_%d" % entry[0], true, false)
			var target: Control = game.hud.find_child("hud_skill_slot_%d" % index, true, false)
			var dropped: bool = await driver.drag_skill(source, target, entry[2])
			var slots: Array = game.session.profile["skill_slots"]
			host.check(dropped and slots[index] == entry[1] and slots.count(entry[1]) == 1,
				"skill drop replaces the binding in %s near %s" % [game.SkillSlots.LABELS[index], entry[2]])
	var before_gap: Array = game.session.profile["skill_slots"].duplicate()
	var gap_drop: bool = await driver.drag_skill(game.modal.find_child("skill_node_46", true, false),
		game.hud.find_child("hud_skill_slot_2", true, false), Vector2(29, 14))
	host.check(not gap_drop and game.session.profile["skill_slots"] == before_gap,
		"releasing in the gap between D and F preserves all twelve bindings")
	# D must accept replacement, swapping from either row, and a drop on itself.
	await driver.drag_skill(game.modal.find_child("skill_node_5", true, false), game.hud.find_child("hud_skill_slot_2", true, false))
	await driver.drag_skill(game.hud.find_child("hud_skill_slot_11", true, false), game.hud.find_child("hud_skill_slot_2", true, false))
	host.check(game.session.profile["skill_slots"][2] == "upper" and game.session.profile["skill_slots"][11] == "hardattack", "Y to occupied D swaps both learned skills")
	await driver.drag_skill(game.hud.find_child("hud_skill_slot_2", true, false), game.hud.find_child("hud_skill_slot_2", true, false))
	host.check(game.session.profile["skill_slots"][2] == "upper", "dropping onto D itself preserves the binding")
	await driver.drag_skill(game.modal.find_child("skill_node_5", true, false), game.hud.find_child("hud_skill_slot_2", true, false))
	host.check(game.session.profile["skill_slots"][2] == "hardattack" and game.session.profile["skill_slots"].count("hardattack") == 1, "tree drag replaces occupied D and removes its previous binding")
	for source in [{"place":"skill_catalog", "id":"physical_mastery"}, {"place":"skill_catalog", "id":"missing_skill"}, {"place":"skill_catalog", "id":"draw"}]:
		host.check(not game.can_drop_slot(source, {"place":"skill", "index":2}), "D drop preview rejects passive, unknown or unlearned skills")
	for index in [-1, 12]:
		host.check(not game.can_drop_slot({"place":"skill_catalog", "id":"upper"}, {"place":"skill", "index":index}), "drop preview rejects a nonexistent shortcut slot")
	# Fixed native canvas coordinates catch a displaced target even when the
	# current control-relative center and corner tests still pass.
	for entry in [[46, "upper", 6, Vector2(539, 521), true], [5, "hardattack", 6, Vector2(549, 550), false],
			[5, "hardattack", 6, Vector2(564, 546), true], [46, "upper", 2, Vector2(599, 559), true]]:
		var source: Control = game.modal.find_child("skill_node_%d" % entry[0], true, false)
		var target: Control = game.hud.find_child("hud_skill_slot_%d" % entry[2], true, false)
		var before: Array = game.session.profile["skill_slots"].duplicate()
		var native_point: Vector2 = entry[3]
		var dropped: bool = await driver.drag_skill(source, target, native_point - target.position)
		var after: Array = game.session.profile["skill_slots"]
		var binding_ok: bool = after != before and after[entry[2]] == entry[1] if entry[4] else after == before
		host.check(dropped == entry[4] and binding_ok, "original canvas drop boundary at %s" % native_point)
	game.session.profile["skill_slots"] = original
	game.build_hotbars()
	await host.ticks(2)

func check_art(hud: Control, host) -> void:
	var keys := ["A", "S", "D", "F", "G", "H", "Q", "W", "E", "R", "T", "Y"]
	var offsets := [22, 22, 22, 22, 22, 22, 22, 21, 22, 22, 21, 21]
	for index in keys.size():
		var key: String = keys[index]
		var origin := Vector2(538 + (index % 6) * 30, 558 if index < 6 else 520)
		var cell := hud.get_node_or_null("hud_skill_slot_%d" % index) as Control
		host.check(cell != null and cell.get_rect() == Rect2(origin, Vector2(28, 28)),
			"shortcut drop target uses the native cell bounds: " + key)
		var glyph := hud.get_node_or_null("skill_hotkey_" + key) as TextureRect
		host.check(glyph != null and glyph.position == origin + Vector2(offsets[index], 21) and glyph.size.y == 7
			and glyph.z_index > 0 and glyph.mouse_filter == Control.MOUSE_FILTER_IGNORE,
			"original key glyph fits above its icon without blocking drops: " + key)
		if index >= 6:
			var slot := hud.get_node_or_null("skill_extra_slot_%d" % index) as TextureRect
			host.check(slot != null and slot.get_rect() == Rect2(origin, Vector2(28, 28))
				and slot.mouse_filter == Control.MOUSE_FILTER_IGNORE, "extended backplate fits the original cell: " + key)
