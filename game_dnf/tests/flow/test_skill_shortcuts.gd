extends RefCounted
## Exercise every real drop target with both legacy and later active skills.
func run(game, host, driver) -> void:
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
	game.session.profile["skill_slots"] = original
	game.build_hotbars()
	await host.ticks(2)
