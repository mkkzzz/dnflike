extends "res://tests/flow/test_loop.gd"
## 任务指引面板的**城镇内**独立回归：建角进城镇后立即检查面板，不进副本、不跑整条循环。
## 运行：Godot --path game_dnf -- --test --quest-guide-only [--capture]
const GUIDE_ORIGIN := Vector2(641, 132)
const GUIDE_SIZE := Vector2(159, 98)
const NATIVE_BOARD := Vector2(239, 147)
const TITLE_COLOR := Color("f0d18a")

func guide() -> Control:
	return game.quest_windows.tracker

func rows() -> Array:
	var view: Control = guide()
	if not is_instance_valid(view):return []
	return view.get_meta("rows", [])

func row_texts() -> Array:
	var out: Array = []
	for row in rows():
		if is_instance_valid(row):out.append(String(row.text))
	return out

func row_colors() -> Array:
	var out: Array = []
	for row in rows():
		if is_instance_valid(row):out.append(row.get_theme_color("font_color"))
	return out

func pick_quest() -> String:
	var definitions: Dictionary = game.session.quests.catalog.definitions
	var keys := definitions.keys()
	keys.sort()
	for key: String in keys:
		var definition: Dictionary = definitions[key]
		if definition.get("legacy", false) or not definition.get("enabled", true):continue
		if definition.get("objectives", []).is_empty():continue
		return key
	return ""

func seed_quest(id: String, ready: bool) -> void:
	var definition: Dictionary = game.session.quests.catalog.definitions[id]
	var entry: Dictionary = game.session.quests.new_entry(definition)
	if ready:
		for o: Dictionary in definition["objectives"]:
			entry["progress"][o["id"]] = int(o["amount"])
	game.session.profile["quest_state"]["entries"][id] = entry
	game.session.profile["quest_state"]["tracked"] = [id]
	game.quest_windows.tracker_signature = ""
	game.quest_windows.refresh_tracker()

func run() -> void:
	await ticks(4)
	var state = game.Session.new()
	state.profile["name"]="指引旅人"
	state.profile["level"]=3
	state.profile["town_location"]="elvengard"
	state.profile["town_position"]=[445.0,222.0]
	var storage = game.Store.new()
	storage.path="res://../temp/quest_guide_tests/hero.json"
	check(storage.write(state) and game.enter_character(storage.path), "fixture character enters the town")
	await ticks(4)
	game.show_overlay("")
	game.set_debug_open(false)
	await ticks(3)
	var view: Control = guide()
	check(is_instance_valid(view) and view.visible, "quest guide is always visible in town")
	if not is_instance_valid(view):
		print("[GUIDE_TOWN] COMPLETE checks=%d failures=%d captures=%d" % [checks, failures, captured.size()])
		get_tree().quit(1)
		return
	var idle_texts := row_texts()
	check(idle_texts.any(func(t):return String(t)=="暂未追踪任务"), "empty town tracker explains nothing is tracked")
	await frame("quest_guide_01_idle")
	var id := pick_quest()
	check(id != "", "catalog offers a real quest to track")
	if id != "":
		seed_quest(id, false)
		await ticks(3)
		var expected: Vector2 = GUIDE_ORIGIN + (Vector2(0, game.quest_windows.GUIDE_TOAST_DROP) if game.toast_panel.visible else Vector2.ZERO)
		check(view.position.is_equal_approx(expected), "guide sits flush right and slightly above middle (%s)" % str(view.position))
		check(is_equal_approx(view.position.x + view.size.x, 800.0), "guide right edge meets the 800-wide canvas edge")
		check(view.size.is_equal_approx(GUIDE_SIZE), "guide is two thirds of the native 239x147 board")
		var board: Control = view.get_node_or_null("quest_guide_board")
		var icon: Control = view.get_node_or_null("quest_guide_icon")
		var rule: Control = view.get_node_or_null("quest_guide_rule")
		check(board != null and board.texture != null and board.texture.get_size() == NATIVE_BOARD, "board uses native quest.img frame 14")
		check(board != null and is_equal_approx(board.scale.x, 2.0/3.0) and is_equal_approx(board.scale.y, 2.0/3.0), "native frames render at two thirds")
		check(icon != null and icon.texture != null and icon.texture.get_size() == Vector2(39, 39), "icon uses native quest.img ring")
		check(rule != null and rule.texture != null, "divider uses native quest.img line")
		var texts := row_texts()
		var colors := row_colors()
		check(texts.size() >= 2, "tracked quest renders a title and objective rows")
		check(texts.size() >= 1 and texts[0] == game.skin.chinese(String(game.session.quests.catalog.definitions[id]["name"])), "first row is the quest name")
		check(colors.size() >= 1 and colors[0].is_equal_approx(TITLE_COLOR), "title uses the dialogue gold")
		check(texts.size() >= 2 and (String(texts[1]).begins_with("· ") or String(texts[1]).begins_with("✓ ")), "objectives show a pending or done mark")
		check(texts.size() >= 2 and String(texts[1]).contains("/"), "objective row carries live progress")
		check(rows()[0].get_theme_font_size("font_size") == 10 and rows()[1].get_theme_font_size("font_size") == 9, "type sizes stay dialogue-like at two thirds")
		await frame("quest_guide_02_tracked")
		seed_quest(id, true)
		await ticks(3)
		check(row_texts().any(func(t):return String(t).contains("交付")), "finished quest points back to the receiver")
		await frame("quest_guide_03_ready")
		game.session.profile["quest_state"]["tracked"] = []
		game.quest_windows.tracker_signature = ""
		game.quest_windows.refresh_tracker()
		await ticks(3)
		check(guide().visible and row_texts().any(func(t):return String(t)=="暂未追踪任务"), "guide stays on screen after untracking")
	# 地面掉落：本体要去掉背包格子底（透明背景），光柱用资源库烘出的原版贴图
	var potion_tex: Texture2D = game.loot_bridge.drop_texture("potion")
	check(potion_tex != null, "ground drop has an item body texture")
	if potion_tex != null:
		var body: Image = potion_tex.get_image()
		var corners_clear := true
		var body_opaque := 0
		var width := body.get_width()
		var height := body.get_height()
		for point in [Vector2i(0, 0), Vector2i(width - 1, 0), Vector2i(0, height - 1), Vector2i(width - 1, height - 1)]:
			if body.get_pixel(point.x, point.y).a > 0.1:corners_clear = false
		for y in height:
			for x in width:
				if body.get_pixel(x, y).a > 0.5:body_opaque += 1
		check(corners_clear, "inventory slot background is keyed out (corners transparent)")
		check(body_opaque > 20, "the item body itself stays visible (%d opaque pixels)" % body_opaque)
	check(game.loot_bridge.drop_texture("gold") != null, "gold keeps a drop body texture")
	var beam: Texture2D = game.loot_bridge.loot_beam_texture()
	check(beam != null and beam.get_size() == Vector2(179, 600), "baked original drop beam is available: " + (str(beam.get_size()) if beam != null else "missing"))
	print("[GUIDE_TOWN] COMPLETE checks=%d failures=%d captures=%d" % [checks, failures, captured.size()])
	get_tree().quit(1 if failures else 0)
