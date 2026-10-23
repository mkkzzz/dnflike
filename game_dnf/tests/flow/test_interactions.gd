extends Node
## Regression through Viewport mouse/keyboard dispatch, not direct slot callbacks.
var game
var host

func ticks(n := 4) -> void:
	await host.ticks(n)

func cell(place: String, index := -1, id := "") -> Control:
	for node in game.ui.find_children("*", "Button", true, false):
		if node.is_queued_for_deletion() or not node.is_visible_in_tree():continue
		if node.get_script() != game.ContentSlot:continue
		if node.cell.get("place") != place:continue
		if index >= 0 and node.cell.get("index", -1) != index:continue
		if id != "" and node.cell.get("id") != id:continue
		return node
	return null

func mouse(at: Vector2, down: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = at
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = down
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
	Input.parse_input_event(event)

func motion(at: Vector2, relative := Vector2.ZERO, held := false) -> void:
	var event := InputEventMouseMotion.new()
	event.position = at
	event.relative = relative
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if held else 0
	Input.parse_input_event(event)

func drag(source: Control, target: Control, label: String) -> void:
	if not is_instance_valid(source) or not is_instance_valid(target):
		host.check(false, "drag endpoints exist: " + label)
		return
	var start: Vector2 = source.get_global_transform_with_canvas() * (source.size / 2)
	var end: Vector2 = target.get_global_transform_with_canvas() * (target.size / 2)
	motion(start)
	await ticks(2)
	mouse(start, true)
	motion(start + Vector2(18, 0), Vector2(18, 0), true)
	await ticks(2)
	host.check(get_viewport().gui_is_dragging(), "native mouse starts drag: " + label)
	motion(end, end - start - Vector2(18, 0), true)
	await ticks(2)
	mouse(end, false)
	await ticks()
	host.check(not get_viewport().gui_is_dragging(), "native mouse completes drag: " + label)

func button(title: String) -> Control:
	for node in game.ui.find_children("*", "BaseButton", true, false):
		if not node.is_queued_for_deletion() and node.get_meta("action_label", "") == title and node.is_visible_in_tree():return node
	return null

func run() -> void:
	var original = game.session
	var path: String = game.store.path
	game.session = game.Session.new()
	game.store.path = "res://../temp/loop_tests/interaction_profile.json"
	game.build_hotbars()
	game.show_overlay("npc")
	await ticks()
	var native_button: Control = button("委托任务")
	await host.hover_control(native_button)
	var held := InputEventMouseButton.new()
	held.position = native_button.get_global_transform_with_canvas() * (native_button.size / 2)
	held.button_index = MOUSE_BUTTON_LEFT
	held.button_mask = MOUSE_BUTTON_MASK_LEFT
	held.pressed = true
	get_viewport().push_input(held, true)
	host.check(native_button.caption.position == Vector2(1, 1), "native button down moves caption with its pressed plate")
	held = held.duplicate()
	held.pressed = false
	held.button_mask = 0
	get_viewport().push_input(held, true)
	await ticks()
	game.show_overlay("")
	await ticks()
	game.session.profile["level"] = 2
	game.session.profile["xp"] = 100
	await ticks()
	await host.hover_control(game.hud.get_node("experience"))
	host.check(is_instance_valid(game.windows.tip) and game.windows.tip.get_node("gauge_value").text == "经验  100 / 200", "XP hover shows actual next-level threshold")
	await host.frame("13_experience_hover")
	await host.hover_control(cell("quick", 0))
	host.check(is_instance_valid(game.windows.tip) and game.windows.tip.get_node("tooltip_title").text == "恢复药剂", "quick item uses shared full item detail")
	host.check(cell("quick", 0).amount.text == "3", "hotbar quantity reflects owned stack")
	await host.frame("14_quick_item_hover")
	await host.hover_control(cell("skill", 0))
	host.check(is_instance_valid(game.windows.tip) and game.windows.tip.has_meta("skill") and game.windows.tip.size.y == 178, "skill hover shows brief description and live numeric costs")
	var actual: Dictionary = game.skill_catalog.get_skill("draw")
	host.check(actual["mp"] > 0 and actual["cooldown"] > 0, "skill numeric description comes from compiled runtime move")
	host.key(KEY_SHIFT, true)
	await ticks()
	host.check(is_instance_valid(game.windows.tip) and game.windows.tip.size.y == 260, "Shift expands actual hovered skill details")
	var contained := true
	for text: Control in game.windows.tip.find_children("*", "Label", true, false):
		if not Rect2(Vector2.ZERO, game.windows.tip.size).encloses(text.get_rect()):
			contained = false
			print("TEXT_OVERFLOW ",text.text, " ", text.get_rect())
	host.check(contained, "expanded skill text wraps inside native detail board")
	await host.frame("15_skill_detail")
	host.key(KEY_SHIFT, false)
	await ticks()
	await drag(cell("skill", 0), cell("skill", 5), "skill into empty H")
	host.check(game.session.profile["skill_slots"][5] == "draw" and game.session.profile["skill_slots"][0] == "", "skill moves to empty key and clears original")
	await drag(cell("skill", 5), cell("skill", 1), "skill occupied swap")
	host.check(game.session.profile["skill_slots"][1] == "draw" and game.session.profile["skill_slots"][5] == "triple", "occupied skill cells swap persisted bindings")
	game.session.add_item("forest_sword", 1)
	game.show_overlay("inventory")
	await ticks()
	host.click_item("林间太刀")
	await ticks()
	host.check(game.session.profile["equipped"] == "iron_sword", "single weapon click does not equip")
	host.click_item("林间太刀", true)
	await ticks()
	host.check(game.session.profile["equipped"] == "forest_sword", "double click equips without instruction in tooltip")
	await drag(cell("equipment"), cell("bag", 7), "unequip into empty bag")
	host.check(game.session.profile["equipped"] == "" and game.session.profile["bag_layout"]["weapon"][7] == "forest_sword", "equipment drag returns ownership to chosen bag cell")
	await drag(cell("bag", 7), cell("equipment"), "equip from bag")
	host.check(game.session.profile["equipped"] == "forest_sword", "bag drag equips into actual weapon slot")
	await drag(cell("bag", -1, "iron_sword"), cell("equipment"), "swap equipped weapon")
	host.check(game.session.profile["equipped"] == "iron_sword" and game.session.profile["bag_layout"]["weapon"].has("forest_sword"), "equipping returns previous weapon to bag without duplication")
	await drag(cell("bag", -1, "forest_sword"), cell("bag", 15), "bag cell relocation")
	host.check(game.session.profile["bag_layout"]["weapon"][15] == "forest_sword", "bag destination persists")
	host.click_text("消耗品")
	await ticks()
	await drag(cell("bag", -1, "potion"), cell("quick", 2), "bind item shortcut")
	host.check(game.session.profile["quick_items"][2] == "potion" and game.session.profile["inventory"]["potion"] == 3, "binding shortcut never copies owned item stack")
	await drag(cell("quick", 2), cell("quick", 4), "move item shortcut")
	host.check(game.session.profile["quick_items"][4] == "potion" and game.session.profile["quick_items"][2] == "", "quick item can move to empty cell")
	await drag(cell("quick", 4), cell("bag", 18), "shortcut back to bag")
	host.check(game.session.profile["quick_items"][4] == "" and game.session.profile["bag_layout"]["consumable"][18] == "potion", "shortcut drop returns stack position without duplicating inventory")
	await host.frame("16_inventory_polished")
	game.show_overlay("shop")
	await ticks()
	host.click_item("恢复药剂")
	await ticks()
	game.windows.purchase_count.get_line_edit().text = "3"
	game.windows.purchase_count.apply()
	await ticks()
	host.check(game.session.profile["gold"] == 300 and game.session.profile["inventory"]["potion"] == 3, "quantity editing never pays before confirmation")
	await host.frame("17_purchase_quantity")
	host.click_text("取消")
	await ticks()
	host.check(not is_instance_valid(game.windows.purchase) and game.session.profile["gold"] == 300, "cancel purchase leaves gold and stock intact")
	host.click_item("恢复药剂")
	await ticks()
	game.windows.purchase_count.get_line_edit().text = "3"
	host.click_text("确认购买")
	await ticks()
	host.check(game.session.profile["gold"] == 180 and game.session.profile["inventory"]["potion"] == 6, "confirmed quantity uses total price and shared hotbar count")
	host.check(cell("quick", 0).amount.text == "6", "purchase updates live shortcut quantity")
	var scroll := game.modal.find_child("shop_scroll", true, false) as VScrollBar
	var grid := game.modal.find_child("native_shop_grid", true, false) as Control
	var wheel := InputEventMouseButton.new()
	wheel.position = grid.get_global_transform_with_canvas() * Vector2(80, 80)
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel.pressed = true
	get_viewport().push_input(wheel, true)
	await ticks()
	host.check(scroll.value > 0 and grid.position.y == -scroll.value, "actual shop wheel moves content and scrollbar together")
	scroll.value = 0
	game.show_overlay("dungeon")
	await ticks()
	for expected in ["adventure", "king", "normal"]:
		host.click_control(game.modal.find_child("difficulty_next", true, false))
		await ticks()
		host.check(game.session.profile["difficulty"] == expected, "native difficulty selector: " + expected)
	await host.frame("18_difficulty_selector")
	game.show_overlay("")
	game.town.ground = Vector2(540, 230)
	await ticks()
	host.key(KEY_RIGHT, true)
	await ticks(30)
	host.key(KEY_RIGHT, false)
	var walk: float = game.town.ground.x - 540
	await ticks(20)
	game.town.ground = Vector2(540, 230)
	host.key(KEY_RIGHT, true)
	await ticks(1)
	host.key(KEY_RIGHT, false)
	await ticks(1)
	host.key(KEY_RIGHT, true)
	await ticks(30)
	host.key(KEY_RIGHT, false)
	var run_distance: float = game.town.ground.x - 540
	host.check(walk > 65 and run_distance > walk * 1.5, "actual town keyboard walk is faster and double-tap runs")
	host.check(game.town.constrain_ground(Vector2(540, 180)).y == 180 and game.town.constrain_ground(Vector2(540, 340)).y == 340, "upper grass and lower stone/grass foreground are walkable")
	var saved = game.Session.new()
	host.check(saved.restore(game.session.serialize()) and saved.profile["bag_layout"] == game.session.profile["bag_layout"] and saved.profile["skill_slots"] == game.session.profile["skill_slots"], "save roundtrip retains dragged cells and skill bindings")
	var legacy: Dictionary = game.session.serialize()
	for key in ["bag_layout", "quick_items", "skill_slots", "difficulty"]:legacy["profile"].erase(key)
	host.check(saved.restore(legacy) and saved.profile["skill_slots"] == game.session.Layout.DEFAULT_SKILLS, "old saves migrate to default layouts")
	game.depart()
	await ticks()
	host.key(KEY_S, true)
	await ticks(2)
	host.key(KEY_S, false)
	await ticks(2)
	host.check(float(game.combat.read_view()["cooldowns"].get("draw", 0)) > 0, "actual remapped S triggers draw skill after drag")
	game.act("flow.retreat")
	game.return_town()
	await ticks()
	game.session = original
	game.store.path = path
	game.build_hotbars()
	game.show_overlay("")
