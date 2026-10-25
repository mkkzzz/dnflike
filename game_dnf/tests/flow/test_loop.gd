extends Node
## State tests use event fixtures; the final run uses real inputs, damage and gates.
var game
var checks := 0
var failures := 0
var capture := false
var captured: Array = []
var controls: Dictionary = {}
const Language = preload("res://ui/flow/language_guard.gd")

func _ready() -> void:
	capture = "--capture" in OS.get_cmdline_user_args()
	call_deferred("run")

func check(value: bool, message: String) -> void:
	checks += 1
	if value:print("[LOOP_TEST] PASS " + message)
	else:
		failures += 1
		push_error("[LOOP_TEST] FAIL " + message)

func ticks(count: int) -> void:
	for i in count:await get_tree().physics_frame

func frame(name: String) -> void:
	var korean_found := false
	for node in get_tree().root.find_children("*", "Control", true, false):
		if node is Label or node is Button:
			if Language.contains_korean(node.text):korean_found = true
		if Language.contains_korean(node.tooltip_text):korean_found = true
	check(not korean_found, "Chinese screen text and tooltips: " + name)
	if not capture:return
	# Wait for deferred layouts and queued old overlays to finish drawing.
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var path := "res://../temp/loop_review/" + name + ".png"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	get_viewport().get_texture().get_image().save_png(ProjectSettings.globalize_path(path))
	captured.append(name)

func key(code: int, pressed: bool) -> void:
	if bool(controls.get(code, false)) == pressed:return
	controls[code] = pressed
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)

func release_all() -> void:
	for code in controls.keys():key(int(code), false)

func click_text(text: String) -> bool:
	for node in game.ui.find_children("*", "BaseButton", true, false):
		if ((node is Button and node.text == text) or node.get_meta("action_label", "") == text) and not node.is_queued_for_deletion():
			click_control(node)
			return true
	return false

func click_control(node: Control) -> void:
	# Viewport-local mouse events exercise GUI hit testing and button dispatch.
	var event := InputEventMouseButton.new()
	event.position = node.get_global_transform_with_canvas() * (node.size / 2)
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	get_viewport().push_input(event, true)
	event = event.duplicate()
	event.pressed = false
	get_viewport().push_input(event, true)

func hover_control(node: Control) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = node.get_global_transform_with_canvas() * (node.size / 2)
	get_viewport().push_input(motion, true)
	await ticks(3)

func click_item(name: String, twice := false) -> bool:
	for node in game.modal.find_children("*", "Button", true, false):
		if String(node.get_meta("item_name", "")).begins_with(name) and not node.is_queued_for_deletion():
			if twice:double_click_control(node)
			else:click_control(node)
			return true
	return false

func double_click_control(node: Control) -> void:
	var event := InputEventMouseButton.new()
	event.position = node.get_global_transform_with_canvas() * (node.size / 2)
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.double_click = true
	get_viewport().push_input(event, true)
	event = event.duplicate()
	event.pressed = false
	get_viewport().push_input(event, true)

func check_item_grid(name: String, columns: int, rows: int) -> void:
	var grid := game.modal.find_child(name, true, false) as Control
	check(is_instance_valid(grid), "native item grid exists: " + name)
	if not is_instance_valid(grid):return
	var occupied: Array[Rect2] = []
	for hit in grid.find_children("*", "Button", true, false):
		if hit.get_meta("item_id", "") == "":continue
		var icon := hit.get_node("item_icon") as TextureRect
		var bounds: Rect2 = hit.get_rect()
		var cavity := Rect2(Vector2(floorf(bounds.position.x / 32), floorf(bounds.position.y / 32)) * 32 + Vector2(2, 2), Vector2(28, 28))
		check(bounds == cavity and icon.get_rect() == Rect2(0, 0, 28, 28), "item icon and hit area fit native cell: " + String(hit.get_meta("item_name")))
		for previous in occupied:check(not previous.intersects(bounds), "adjacent item areas do not overlap")
		occupied.append(bounds)
	if not capture:return
	await RenderingServer.frame_post_draw
	var shot := get_viewport().get_texture().get_image()
	var source: Image = game.skin.texture("inventory_grid").get_image()
	var points := [Vector2i(0, 16), Vector2i(16, 0), Vector2i(columns * 32, 16), Vector2i(16, rows * 32)]
	var intact := true
	for point: Vector2i in points:
		var source_y := point.y % 128 if point.y < rows * 32 else ((rows - 1) % 4 + 1) * 32
		var expected := source.get_pixel(16 + point.x, 174 + source_y)
		var at: Vector2 = grid.get_global_transform_with_canvas() * (Vector2(point) + Vector2(0.5, 0.5))
		if not shot.get_pixel(int(at.x), int(at.y)).is_equal_approx(expected):intact = false
	check(intact, "rendered native grid retains all four borders: " + name)

func unit_states() -> void:
	var s = game.Session.new()
	check(not s.command("items.buy", {"id": "unknown"})["ok"], "reject unknown merchandise")
	check(not s.command("items.equip", {"id": "forest_sword"})["ok"], "cannot equip unowned gear")
	check(s.command("flow.accept_quest")["ok"], "accept quest")
	check(not s.command("flow.accept_quest")["ok"], "quest accept is not repeatable")
	s.command("flow.depart")
	var id: String = s.run["id"]
	check(not s.command("flow.depart")["ok"], "cannot depart twice")
	check(not s.command("items.equip", {"id": "iron_sword"})["ok"], "equipment locked during run")
	check(not s.combat_event({"type": "combat.room_combat_finished", "run_id": "stale", "final_room": true})["ok"], "reject events from another run")
	s.combat_event({"type": "combat.room_combat_finished", "run_id": id, "final_room": false})
	check(s.state == "battle", "non-final room does not settle run")
	s.combat_event({"type": "combat.room_combat_finished", "run_id": id, "final_room": true})
	var gold := int(s.profile["gold"])
	s.combat_event({"type": "combat.room_combat_finished", "run_id": id, "final_room": true})
	check(s.profile["gold"] == gold and s.profile["clears"] == 1, "duplicate victory pays exactly once")
	check(s.profile["level"] == 2 and s.profile["quest"] == "ready", "victory grants XP and quest progress")
	var snap: Dictionary = s.snapshot()
	snap["profile"]["gold"] = -9
	check(s.profile["gold"] == gold, "snapshot cannot mutate profile")
	var st = game.Store.new()
	st.path = "res://../temp/loop_tests/unit_profile.json"
	check(st.write(s), "atomic result save")
	check(st.write(s), "valid backup created")
	var corrupt := FileAccess.open(st.path, FileAccess.WRITE)
	corrupt.store_string("broken JSON")
	corrupt.close()
	var loaded = game.Session.new()
	check(st.read_into(loaded) and st.recovered, "corrupted primary recovers valid backup")
	check(loaded.state == "result" and loaded.profile["gold"] == gold, "result reward survives restore without replay")
	loaded.command("flow.return")
	loaded.command("flow.claim_quest")
	check(loaded.profile["gold"] == gold + 200 and loaded.profile["inventory"]["forest_sword"] == 1, "quest pays equipment and gold")
	check(not loaded.command("flow.claim_quest")["ok"], "quest reward cannot be claimed twice")
	loaded.command("items.equip", {"id": "forest_sword"})
	check(loaded.stats()["damage_multiplier"] == 1.2, "equipment changes next combat stat snapshot")
	loaded.command("flow.depart")
	var interrupted = game.Session.new()
	check(interrupted.restore(JSON.parse_string(JSON.stringify(loaded.serialize()))) and interrupted.state == "town", "interrupted run safely resumes in town")
	loaded.command("flow.retreat")
	check(loaded.result["gold"] == 0 and loaded.result["xp"] == 0, "retreat grants no clear reward")
	loaded.command("flow.return")
	loaded.command("flow.depart")
	var death_gold := int(loaded.profile["gold"])
	loaded.combat_event({"type": "combat.player_defeated", "run_id": loaded.run["id"], "stats": {"damage_taken": 700}})
	check(loaded.state == "defeated" and loaded.result.is_empty() and int(loaded.profile["gold"]) == death_gold, "death event waits for revival choice without clear reward")
	check(loaded.command("flow.abandon")["ok"] and loaded.state=="result" and not loaded.result["victory"],"abandoning pending death settles failure")
	var bad: Dictionary = loaded.serialize()
	bad["profile"]["inventory"]["potion"] = -4
	check(not interrupted.restore(bad), "reject malformed inventory")
	var bad_result: Dictionary = loaded.serialize()
	bad_result["result"]["stats"] = "invalid"
	check(not interrupted.restore(bad_result), "reject malformed result before replacing profile")
	var impossible_store = game.Store.new()
	impossible_store.path = "res://../temp/loop_tests/unit_profile.json/nested/file.json"
	check(not impossible_store.write(loaded), "write failure is reported without replacing primary save")

func run() -> void:
	await ticks(4)
	var character_tests = load("res://tests/flow/test_characters.gd").new()
	character_tests.game = game
	character_tests.host = self
	await character_tests.run()
	# Retain the old sample-loop regression alongside the separate original
	# chapter test. Its adapted task/reward is deliberately not source quest 101.
	game.town.set_location("elvengard",Vector2(540,230))
	game.session.profile["town_location"]="elvengard"
	game.selected_dungeon="forest_trial"
	if "--characters-only" in OS.get_cmdline_user_args():
		print("[LOOP_TEST] COMPLETE checks=%d failures=%d captures=%d" % [checks, failures, captured.size()])
		get_tree().quit(1 if failures else 0)
		return
	if "--interactions-only" in OS.get_cmdline_user_args():
		var suite = load("res://tests/flow/test_interactions.gd").new()
		suite.game = game
		suite.host = self
		add_child(suite)
		await suite.run()
		print("[LOOP_TEST] COMPLETE checks=%d failures=%d captures=%d" % [checks, failures, captured.size()])
		get_tree().quit(1 if failures else 0)
		return
	if "--numbers-only" in OS.get_cmdline_user_args():
		var suite = load("res://tests/flow/test_number_flow.gd").new()
		suite.game = game
		suite.host = self
		await suite.run()
		OS.delay_msec(100)
		await ticks(3)
		print("[LOOP_TEST] COMPLETE checks=%d failures=%d captures=%d" % [checks,failures,captured.size()])
		get_tree().quit(1 if failures else 0)
		return
	unit_states()
	check(Language.contains_korean(String.chr(0xac00)) and Language.contains_korean(String.chr(0x3131)), "Korean syllables and Jamo are rejected")
	check(not Language.contains_korean("背包 负重 普通难度 X HP 评价 S"), "Chinese text and normal key/rank notation are accepted")
	check(game.town.loader.errors.is_empty(), "all native town textures load")
	check(game.town.animated.size() >= 2, "source NPC/environment animation is active")
	var hotkeys: Array[String] = []
	for label in game.hud.find_children("*", "Label", true, false):
		if label.get_meta("skill_hotkey", false):
			hotkeys.append(label.text)
			check(label.z_index > 0, "skill key stays above its icon: " + label.text)
	check(hotkeys == ["A", "S", "D", "F", "G", "H"], "HUD shows ASDFGH without basic ZXC actions")
	check(not game.skill_views.has("upper"), "basic upper attack is absent from skill slots")
	check(game.get_window().content_scale_mode == Window.CONTENT_SCALE_MODE_VIEWPORT and game.get_window().content_scale_size == game.display_settings.OUTPUT, "fixed output keeps the original layout transform")
	var percentages := false
	for label in game.hud.find_children("*", "Label", true, false):
		if "%" in label.text:percentages = true
	check(not percentages, "orbs contain no persistent percentages")
	check(game.hud.get_node("hud_potion").get_rect() == Rect2(85, 558, 28, 28), "HUD item icon fits the native cavity")
	for id: String in game.skill_views:
		var view: Control = game.skill_views[id]["view"]
		check(view.size == Vector2(28, 28) and view.position.y == 558 and int(view.position.x - 538) % 30 == 0, "HUD skill stays inside native rim: " + id)
	await frame("01_town")
	if capture:
		var shot: Image = get_viewport().get_texture().get_image()
		var output_size := Vector2i(game.display_settings.OUTPUT)
		check(shot.get_size() == output_size, "capture matches the fixed output size %s" % str(output_size))
		check(not shot.get_pixel(output_size.x / 2, output_size.y - 126).is_equal_approx(Color.BLACK), "transparent HUD has original ground underneath")
		var bar := int(game.display_settings.CONTENT_OFFSET.x)
		if bar > 0:
			check(shot.get_pixel(bar / 2, output_size.y * 37 / 100).is_equal_approx(Color.BLACK) and shot.get_pixel(output_size.x - bar / 2, output_size.y * 37 / 100).is_equal_approx(Color.BLACK), "original 4:3 content stays within black pillarboxes")
		else:
			check(not shot.get_pixel(1, output_size.y * 37 / 100).is_equal_approx(Color.BLACK), "integer scale fills the window without pillarboxes")
	await hover_control(game.hp_bar)
	check(is_instance_valid(game.windows.tip) and game.windows.tip.has_meta("gauge"), "actual HP hover opens native value detail")
	if is_instance_valid(game.windows.tip):check(game.windows.tip.get_node("gauge_value").text == game.hp_bar.get_meta("value_text"), "HP detail shows current and maximum values")
	await frame("01d_hp_hover")
	await hover_control(game.mp_bar)
	check(is_instance_valid(game.windows.tip) and game.windows.tip.has_meta("gauge"), "actual MP hover opens native value detail")
	if is_instance_valid(game.windows.tip):check(game.windows.tip.get_node("gauge_value").text == game.mp_bar.get_meta("value_text"), "MP detail shows current and maximum values")
	await frame("01e_mp_hover")
	if capture:
		await RenderingServer.frame_post_draw
		var hud_shot := get_viewport().get_texture().get_image()
		var native_hud: Image = game.skin.texture("hud").get_image()
		var intact := true
		for point in [Vector2i(83, 62), Vector2i(98, 48), Vector2i(536, 62), Vector2i(550, 48), Vector2i(566, 62)]:
			var output := Vector2i((Vector2(point.x, point.y + 508) + Vector2(0.5, 0.5)) * game.display_settings.CONTENT_SCALE + game.display_settings.CONTENT_OFFSET)
			if not hud_shot.get_pixel(output.x, output.y).is_equal_approx(native_hud.get_pixel(point.x, point.y)):intact = false
		check(intact, "HUD item and skill icons preserve the baked top and side borders")
	game.town.ground = Vector2(1120, 230)
	await ticks(3)
	await frame("01b_town_east")
	game.town.ground = Vector2(445, 222)
	game.show_overlay("npc")
	await ticks(3)
	var portrait = game.modal.find_child("linus_dialogue_illustration", true, false)
	check(is_instance_valid(portrait) and portrait.texture.get_size() == Vector2(186, 226), "dialogue uses original Linus torso illustration at 1:1")
	await frame("02_linus")
	check(click_text("委托任务"), "NPC opens quest UI")
	await ticks(2)
	check(click_text("接受委托"), "quest button accepts quest")
	await ticks(2)
	check(game.session.profile["quest"] == "active", "UI quest state persists")
	await frame("03_quest")
	game.show_overlay("shop")
	await ticks(2)
	await frame("04_shop")
	await check_item_grid("native_shop_grid", 7, 6)
	await check_item_grid("native_inventory_grid", 8, 6)
	var merchandise: Control
	for node in game.modal.find_child("native_shop_grid", true, false).get_children():
		if node is Button and node.get_meta("item_id", "") == "forest_sword":merchandise = node
	if is_instance_valid(merchandise):
		check(merchandise.get_node("rarity_frame").get_meta("rarity") == 2, "rare merchandise carries its rarity frame")
		await hover_control(merchandise)
		var title := game.windows.tip.get_node("tooltip_title") as Label
		check(title.get_theme_font_size("font_size") == 16 and title.get_theme_color("font_color") == Color(game.Catalog.RARITIES[2]["color"]), "item detail title uses rarity color and larger type")
		await frame("04b_shop_detail")
	check(click_item("恢复药剂"), "click native shop item to purchase")
	await ticks(2)
	check(game.session.profile["gold"] == 300 and is_instance_valid(game.windows.purchase), "shop opens confirmation before exchanging gold")
	check(click_text("确认购买"), "confirm purchase through native dialog")
	await ticks(3)
	check(game.session.profile["gold"] == 260 and game.session.profile["inventory"]["potion"] == 4, "purchase exchanges gold for item")
	game.show_overlay("inventory")
	await ticks(3)
	await frame("05_inventory")
	var bag = game.modal.find_child("native_inventory", true, false)
	check(bag.get_global_rect().end.y < 508, "compact native bag ends above HUD")
	var weapon := bag.get_node("equipped_weapon") as Control
	check(Rect2(208, 86, 32, 32).encloses(weapon.get_rect()) and weapon.get_meta("item_id") == game.session.profile["equipped"], "equipped weapon sits in the source weapon slot")
	var close := bag.get_node("inventory_close") as Control
	check(not close.get_rect().intersects(Rect2(13, 0, 265, 32)), "close button clears the top page tabs")
	var item_grid := bag.get_node("native_inventory_grid") as Control
	check(bag.get_node("inventory_tab_0").position.x == item_grid.position.x and bag.get_node("inventory_tab_4").get_rect().end.x == item_grid.get_rect().end.x, "category tabs align with both grid edges")
	for entry in [["resurrection_coins", Rect2(20, 405, 125, 23)], ["duel_points", Rect2(153, 405, 125, 23)], ["cash_points", Rect2(20, 432, 125, 23)], ["gold", Rect2(153, 432, 125, 23)]]:
		check(entry[1].encloses(bag.get_node("inventory_" + entry[0]).get_rect()), "currency value stays in its own native field: " + entry[0])
	var tabs: Array[Rect2] = []
	for i in 5:
		tabs.append(bag.get_node("inventory_tab_" + str(i)).get_rect())
		if i > 0:check(tabs[i - 1].end.x <= tabs[i].position.x, "inventory tabs do not overlap: " + str(i))
	check(click_text("消耗品"), "inventory category tab responds to viewport clicks")
	await ticks(3)
	var potion_visible := false
	for node in game.modal.find_children("*", "Button", true, false):
		if node.get_meta("item_name", "") == "恢复药剂":potion_visible = true
	check(potion_visible, "consumable tab filters inventory to consumable items")
	await check_item_grid("native_inventory_grid", 8, 6)
	await frame("05c_inventory_consumables")
	check(click_text("装备"), "inventory equipment category can be restored")
	await ticks(3)
	var item_hit: Control
	for node in game.modal.find_children("*", "Button", true, false):
		if node.get_meta("item_name", "") == "练习太刀":item_hit = node
	if is_instance_valid(item_hit):
		var motion := InputEventMouseMotion.new()
		motion.position = item_hit.get_global_transform_with_canvas() * (item_hit.size / 2)
		get_viewport().push_input(motion, true)
		await ticks(3)
		check(is_instance_valid(game.windows.tip), "hover creates native item detail panel")
		if capture:
			await RenderingServer.frame_post_draw
			var shot := get_viewport().get_texture().get_image()
			var icon := item_hit.get_node("item_icon") as TextureRect
			var at: Vector2 = icon.get_global_transform_with_canvas() * Vector2(14.5, 14.5)
			check(shot.get_pixel(int(at.x), int(at.y)).is_equal_approx(icon.texture.get_image().get_pixel(14, 14)), "hover keeps the original item icon visible without button fill")
		if is_instance_valid(game.windows.tip):
			check(game.windows.tip.texture == game.skin.tooltip_texture, "item detail uses original translucent Global frame")
			var bounds: Rect2 = game.windows.tip.get_global_rect()
			check(Rect2(0, 0, 800, 600).encloses(bounds), "item detail panel stays inside native viewport")
		await frame("05b_inventory_hover")
	var closing := game.modal.find_child("inventory_close", true, false) as Control
	if is_instance_valid(closing):
		click_control(closing)
		await ticks(3)
		check(game.overlay == "", "relocated inventory close still responds to mouse input")
	game.show_overlay("dungeon")
	await ticks(3)
	await frame("06_departure")
	check(click_text("进入地下城"), "selection button starts actual combat port")
	await ticks(5)
	check(is_instance_valid(game.battle) and game.session.state == "battle", "real battle instantiated with managed run")
	await frame("07_battle")
	var previous_room := 0
	var healed := false
	# Let an actual enemy connect before testing a real potion; no synthetic HP edits.
	for i in 1800:
		var before: Dictionary = game.combat.read_view()
		if float(before["hp"]) <= float(before["hp_max"]) - 150:
			var old := int(game.session.profile["inventory"]["potion"])
			key(KEY_H, true)
			await ticks(2)
			key(KEY_H, false)
			check(int(game.session.profile["inventory"]["potion"]) == old, "H no longer consumes items")
			key(KEY_1, true)
			await ticks(2)
			key(KEY_1, false)
			healed = int(game.session.profile["inventory"]["potion"]) == old - 1
			check(healed, "number 1 consumes a potion through actual input")
			break
		await ticks(1)
	# Real combat autopilot: read copied snapshot and send normal physical input.
	# No god mode, HP edits, enemy removal, forged finish signal or teleportation.
	for i in 18000:
		if game.session.state != "battle":break
		var snap: Dictionary = game.combat.read_view()
		if int(snap["room"]) != previous_room:
			previous_room = int(snap["room"])
			print("[LOOP_TEST] ACTUAL ROOM ", previous_room)
			if previous_room > 1:await frame("08_room_%d" % previous_room)
		var pos: Vector2 = snap["pos"]
		var target := pos
		var enemy_near := false
		if snap["enemies"].is_empty():target = snap["exit_target"]
		else:
			var best := INF
			for enemy: Dictionary in snap["enemies"]:
				var distance := pos.distance_to(enemy["pos"])
				if distance < best:
					best = distance
					target = Vector2(enemy["pos"])
			var enemy_pos := target
			var side := -1 if pos.x <= enemy_pos.x else 1
			target.x += side * 52
			enemy_near = absf(enemy_pos.x - pos.x) < 80 and absf(enemy_pos.y - pos.y) < 14
			if enemy_near:
				target.x = pos.x
				var face := 1 if enemy_pos.x >= pos.x else -1
				if int(snap["facing"]) != face:
					target.x += face * 10
					enemy_near = false
		var direction := target - pos
		key(KEY_LEFT, direction.x < -7)
		key(KEY_RIGHT, direction.x > 7)
		key(KEY_UP, direction.y < -5)
		key(KEY_DOWN, direction.y > 5)
		key(KEY_X, enemy_near and i % 16 < 2)
		key(KEY_Z, enemy_near and i % 150 < 2)
		key(KEY_A, enemy_near and i % 330 < 2)
		key(KEY_S, enemy_near and i % 220 < 2)
		if float(snap["hp"]) < float(snap["hp_max"]) - 150 and int(game.session.profile["inventory"].get("potion", 0)) > 0:
			var old := int(game.session.profile["inventory"]["potion"])
			game.use_potion()
			healed = healed or int(game.session.profile["inventory"]["potion"]) < old
		if i == 700:await frame("09_combat_action")
		await ticks(1)
	release_all()
	await ticks(4)
	check(game.session.state == "result" and game.session.result.get("victory", false), "normal combat inputs clear five rooms and settle victory")
	check(previous_room == 5, "real gates traversed to final room")
	check(game.session.profile["quest"] == "ready", "real boss event advances quest")
	check(healed, "real damage permits consuming healing item")
	await frame("10_result")
	if game.session.state == "result":
		var card = game.modal.find_child("reward_card_0", true, false)
		check(is_instance_valid(card), "victory presents original reward card row")
		if is_instance_valid(card):click_control(card)
		await ticks(3)
		check(game.windows.selected_card == 0, "reward card flips through viewport input")
		var reward_gold := int(game.session.profile["gold"])
		game.show_overlay("result")
		await ticks(3)
		check(game.windows.selected_card == 0 and int(game.session.profile["gold"]) == reward_gold, "reopening settlement retains flipped card without paying twice")
		await frame("10b_result_reward")
		check(click_text("返回城镇"), "result button returns to town")
		await ticks(3)
		game.town.ground = Vector2(445, 222)
		game.show_overlay("quest")
		await ticks(3)
		check(click_text("领取报酬"), "quest hand-in button works near NPC")
		await ticks(3)
		check(game.session.profile["quest"] == "done", "full town battle result quest cycle complete")
		game.show_overlay("inventory")
		await ticks(3)
		check(click_item("林间太刀", true), "double-click inventory slot to equip quest reward")
		await ticks(3)
		check(game.session.profile["equipped"] == "forest_sword", "inventory GUI equips real profile item")
		await frame("11_reward_equipment")
		game.show_overlay("dungeon")
		await ticks(3)
		click_text("进入地下城")
		await ticks(4)
		var second: Dictionary = game.combat.read_view()
		check(is_equal_approx(float(second["hp_max"]),527.1) and is_equal_approx(float(second["attack_damage"]),30.24), "next adventure applies level and equipment to actual combat")
		game.show_overlay("menu")
		await ticks(3)
		check(click_text("撤退回城"), "retreat menu opens failure result")
		await ticks(3)
		check(not game.session.result["victory"] and game.session.result["gold"] == 0 and game.session.profile["clears"] == 1, "second run retreat preserves previous clear without new rewards")
		click_text("返回城镇")
		await ticks(4)
	var loaded = game.Session.new()
	check(game.store.read_into(loaded) and loaded.profile == game.session.profile, "save reload retains actual completed adventure")
	game.show_overlay("")
	await ticks(2)
	await frame("12_return_town")
	var debug_tests = load("res://tests/flow/test_debug.gd").new()
	debug_tests.game = game
	debug_tests.host = self
	add_child(debug_tests)
	await debug_tests.run()
	debug_tests.queue_free()
	var interactions = load("res://tests/flow/test_interactions.gd").new()
	interactions.game = game
	interactions.host = self
	add_child(interactions)
	await interactions.run()
	interactions.queue_free()
	# Dummy audio still releases its final Ogg playback on the mixer thread. At
	# fixed-fps headless speed the last run can start/stop in < one audio block.
	# Give that worker one bounded wall-clock drain before engine shutdown.
	OS.delay_msec(100)
	await ticks(3)
	print("[LOOP_TEST] COMPLETE checks=%d failures=%d captures=%d" % [checks, failures, captured.size()])
	get_tree().quit(1 if failures else 0)
