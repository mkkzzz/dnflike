extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const FlowSession = preload("res://flow/session.gd")
const NativeMaze = preload("res://combat/data/native_maze.gd")
const NativeBreakable = preload("res://combat/resolve/native_breakable.gd")
const NativeBoxLoot = preload("res://loot/native_box.gd")
const NativeJarTraps = preload("res://combat/resolve/native_jar_traps.gd")
const DetRng = preload("res://core/det_rng.gd")

const SOURCE_SHA := "13c7ece1b64c949af4870f9413334459c723812fea0d56ee6bf0347143e7dd16"
const ROUTE_MAP_IDS := [9100, 9103, 9102, 9101, 9104, 9108]

var session := CombatSession.new()
var game
var checks := 0
var failures := 0

class SourceRolls extends RefCounted:
	var values: Array[int]
	var index := 0
	func _init(sequence: Array[int]) -> void:
		values = sequence
	func range_int(_low: int, _high: int) -> int:
		var value := values[index] if index < values.size() else 0
		index += 1
		return value

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("[NATIVE_MAZE_ICEPALACE] FAIL " + label)

func merge_gaps(target: Dictionary, source: Dictionary) -> void:
	for path: String in source:
		if not target.has(path):target[path] = []
		var values: Array = target[path]
		for value in source[path]:
			if value not in values:values.append(value)

func run() -> void:
	game = session.mount(root)
	game.set_process(false)
	game.set_physics_process(false)
	var routes: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/dungeons.json"))["dungeons"]
	var route: Dictionary = routes["icepalace"]
	check(route.get("name") == "冰雪宫殿"
		and route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("region") == "snowmt"
		and int(route.get("min_level", 0)) == 46 and int(route.get("monster_level", 0)) == 49,
		"Ice Palace is a hidden level 46 Snow Mountain native-maze route with basis level 49")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production Ice Palace export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/act5/icepalace.dgn"
		and dungeon.get("sha256") == SOURCE_SHA,
		"Ice Palace export keeps the pinned DGN source identity")
	check(Array(dungeon.get("placements", [])).size() == 11
		and Dictionary(dungeon.get("rooms", {})).size() == 9
		and Dictionary(probe.data.get("images", {})).size() == 72,
		"Ice Palace export contains 11 placements, nine MAPs and 72 source images")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	var errors: Array = diagnostics.filter(func(row): return row.get("level") == "error")
	var warnings: Array = diagnostics.filter(func(row): return row.get("level") == "warning")
	var infos: Array = diagnostics.filter(func(row): return row.get("level") == "info")
	var unrendered := 0
	var empty_tiles := 0
	var unhandled := 0
	for row: Dictionary in warnings:
		if row.get("code") == "object_unrendered":unrendered += 1
	for row: Dictionary in infos:
		if row.get("code") == "empty_tile":empty_tiles += 1
		if row.get("code") == "unhandled_tags":unhandled += 1
	check(errors.is_empty() and warnings.size() == 46 and infos.size() == 46
		and unrendered == 46 and empty_tiles == 37 and unhandled == 9,
		"Ice Palace preserves 46 unrendered objects, 37 empty tiles and nine raw-tag MAPs")

	var maze := NativeMaze.new()
	var size: Vector2i = maze._point(dungeon.get("size"))
	var cells: Dictionary = maze._read_cells(dungeon.get("cells"), size)
	var starts: Array = maze._read_endpoint_cells(dungeon.get("start_map_raw"), cells, "start_candidate")
	var bosses: Array = maze._read_endpoint_cells(dungeon.get("boss_map_raw"), cells, "boss_candidate")
	var specs: Dictionary = maze._read_specifications(dungeon.get("raw"), cells)
	var fixed_ids: Array[int] = []
	for point: Vector2i in specs.get("normal", {}):
		for map_id in specs["normal"][point]:fixed_ids.append(int(map_id))
	fixed_ids.sort()
	check(size == Vector2i(3, 3) and cells.size() == 9
		and starts == [Vector2i(0, 1)] and bosses == [Vector2i(1, 1)],
		"Ice Palace is a 3x3 source grid with start (0,1) and central boss (1,1)")
	check(fixed_ids == [9101, 9102, 9103, 9104, 9105, 9106, 9107],
		"the seven non-endpoint cells keep fixed MAPs 9101..9107")
	var duplicate_layout: Array = cells[Vector2i(1, 0)]["map_candidates"]
	check(duplicate_layout == [
		"map/icepalace/l2(1,0)icepalace.map",
		"map/icepalace/l6(1,2)icepalace.map",
	], "Ice Palace keeps both source F-layout MAPs in the shared candidate pool")

	var maze_blocks := 0
	var map_specs := 0
	var boss_specs := 0
	var event_monster = null
	var seal_id = null
	var seal_pos = null
	var hell_value = null
	for span: Dictionary in dungeon.get("raw", []):
		var tag := String(span.get("tag", ""))
		var values: Array = span.get("values", [])
		if tag == "[maze info]":maze_blocks += 1
		if tag == "[map specification]":map_specs += 1
		if tag == "[boss map specification]":boss_specs += 1
		if tag == "[event monster]":event_monster = values
		if tag == "[seal door map index]":seal_id = values
		if tag == "[seal door pos]":seal_pos = values
		if tag == "[hell dungeon]":hell_value = values
	check(maze_blocks == 1 and map_specs == 7 and boss_specs == 0,
		"Ice Palace consumes one maze with seven fixed normal MAP rows")
	check(event_monster != null and int(event_monster[1][2]) == 9000
		and int(event_monster[2][2]) == 61728
		and seal_id != null and int(seal_id[0][2]) == 60029
		and seal_pos != null and [int(seal_pos[0][2]), int(seal_pos[1][2])] == [2, 1]
		and hell_value != null and int(hell_value[0][2]) == 1,
		"event monster 61728, seal door 60029 at (2,1) and hell mode remain preserved raw")

	var ai_characters: Array = []
	for path: String in dungeon.get("rooms", {}):
		var room: Dictionary = dungeon["rooms"][path]
		for span: Dictionary in room.get("raw", []):
			if span.get("tag") == "[ai character]":
				ai_characters.append(int(span["values"][0][2]))
	check(ai_characters == [609],
		"the light-spirit room preserves AI character 609 (swordman/crux2/crux.aic) as a gap")

	var fixed_maze := NativeMaze.new()
	check(fixed_maze.start(probe.data, SourceRolls.new([0, 0, 0]), route.get("source", {})),
		"native maze starts the sole Ice Palace layout")
	check(fixed_maze.room_count() == 9, "Ice Palace ordinary graph reaches all nine source cells")
	var selected_ids: Array[int] = [int(fixed_maze.current_room().get("source_map_id", 0))]
	var moves := ["up", "right", "right", "down", "left"]
	for step in moves.size():
		var current: Vector2i = fixed_maze.current_room().get("cell", Vector2i(-1, -1))
		var cleared: Dictionary = fixed_maze.clear_room(current, 0)
		var moved: Dictionary = fixed_maze.move(moves[step])
		check(not cleared.is_empty() and not moved.is_empty(),
			"Ice Palace clears and traverses source step %d" % step)
		selected_ids.append(int(moved.get("source_map_id", 0)))
	check(selected_ids == ROUTE_MAP_IDS,
		"Ice Palace shortest source route selects MAPs 9100,9103,9102,9101,9104,9108")
	var final_clear: Dictionary = fixed_maze.clear_room(Vector2i(1, 1), 0)
	check(bool(final_clear.get("boss", false)) and bool(final_clear.get("final_room", false)),
		"the selected 9108 room is the sole Ice Palace boss and final room")

	var source_monsters := {}
	var source_monster_counts := {}
	var source_monster_count := 0
	var source_boss_rows := 0
	var source_object_count := 0
	var source_breakable_candidates := 0
	var source_runtime_breakables := 0
	var source_traps := 0
	var source_static := 0
	var source_box_objects := 0
	for room: Dictionary in dungeon.get("rooms", {}).values():
		for monster: Dictionary in room.get("monsters", []):
			var mob := String(monster.get("mob", ""))
			source_monsters[mob] = true
			source_monster_counts[mob] = 1 + int(source_monster_counts.get(mob, 0))
			source_monster_count += 1
			if Array(monster.get("raw", []))[-1] == "[boss]":source_boss_rows += 1
		for item: Dictionary in room.get("objects", []):
			source_object_count += 1
			if NativeBoxLoot.draw_count(item) > 0:source_box_objects += 1
			var path := String(item.get("obj", "")).to_lower()
			if NativeBreakable.supports(item):
				source_breakable_candidates += 1
				if not game.content.record(path).get("native_breakable", {}).is_empty():
					source_runtime_breakables += 1
			elif path.contains("/trap/"):
				source_traps += 1
			else:
				source_static += 1
	check(source_monsters.size() == 12 and source_monster_count == 53 and source_boss_rows == 1,
		"Ice Palace has 53 direct placements, 12 MOBs and one boss row")
	check(source_monster_counts == {
		"monster/bantu/bantuamazones.mob": 16,
		"monster/newmonsters/bantu/emeldir/emeldir.mob": 1,
		"monster/newmonsters/bantu/isil/isil.mob": 1,
		"monster/newmonsters/bantu/mohini/mohini.mob": 1,
		"monster/newmonsters/bantu/rabbitwoman/rabbitwoman.mob": 11,
		"monster/newmonsters/bantu/ratree/ratree.mob": 1,
		"monster/newmonsters/bantu/sati/sati.mob": 1,
		"monster/newmonsters/queen_rosi/queen_rosi.mob": 1,
		"monster/newmonsters/rosiclock/rosiclock.mob": 5,
		"monster/spirit/lighthigherspirit.mob": 4,
		"monster/spirit/waterhigherspirit.mob": 2,
		"monster/spirit/waterspirit.mob": 9,
	}, "Ice Palace keeps the exact source monster counts")
	check(source_object_count == 176 and source_breakable_candidates == 104
		and source_runtime_breakables == 50 and source_traps == 9
		and source_static == 63 and source_box_objects == 0,
		"Ice Palace has 176 objects: 50 executable breakables, "
		+ "54 breakable gaps, nine traps, 63 static objects and no box draws "
		+ "(objects=%d candidates=%d runtime=%d traps=%d static=%d boxes=%d)"
		% [source_object_count, source_breakable_candidates, source_runtime_breakables,
			source_traps, source_static, source_box_objects])

	var banks := {
		"monster/bantu/bantuamazones.mob": ["bantu_bantuamazones", 5],
		"monster/newmonsters/bantu/rabbitwoman/rabbitwoman.mob": ["newmonsters_bantu_rabbitwoman_rabbitwoman", 2],
		"monster/spirit/waterhigherspirit.mob": ["spirit_waterhigherspirit", 2],
		"monster/newmonsters/queen_rosi/queen_rosi.mob": ["newmonsters_queen_rosi_queen_rosi", 4],
		"monster/newmonsters/rosiclock/rosiclock.mob": ["newmonsters_rosiclock_rosiclock", 1],
		"monster/newmonsters/bantu/ratree/ratree.mob": ["newmonsters_bantu_ratree_ratree", 7],
		"monster/spirit/lighthigherspirit.mob": ["spirit_lighthigherspirit", 2],
		"monster/newmonsters/bantu/emeldir/emeldir.mob": ["newmonsters_bantu_emeldir_emeldir", 4],
		"monster/newmonsters/bantu/isil/isil.mob": ["newmonsters_bantu_isil_isil", 4],
		"monster/newmonsters/bantu/sati/sati.mob": ["newmonsters_bantu_sati_sati", 6],
		"monster/newmonsters/bantu/mohini/mohini.mob": ["newmonsters_bantu_mohini_mohini", 4],
		"monster/spirit/waterspirit.mob": ["spirit_waterspirit", 3],
	}
	for mob: String in banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		check(String(definition.get("bank", "")) == banks[mob][0]
			and game.combat_assets.get("monsters", {}).has(banks[mob][0]),
			"Ice Palace source bank is compiled: " + mob)
		check(Array(definition.get("moves", [])).size() == int(banks[mob][1]),
			"Ice Palace source attack slots compile for %s (moves=%d expected=%d)"
			% [mob, Array(definition.get("moves", [])).size(), int(banks[mob][1])])

	var queen: Dictionary = game.table.monsters.get(
		game.table.monster_by_mob("monster/newmonsters/queen_rosi/queen_rosi.mob"), {})
	var queen_stems: Array[String] = []
	for move: Dictionary in queen.get("moves", []):queen_stems.append(String(move.get("stem", "")))
	check(queen_stems == ["attack1", "attack2", "command1", "command2"],
		"Queen Rosi keeps all four source action-list slots")
	check([float(queen["moves"][0].get("cool_ms", -1)), float(queen["moves"][1].get("cool_ms", -1)),
		float(queen["moves"][2].get("cool_ms", -1)), float(queen["moves"][3].get("cool_ms", -1))]
		== [10000.0, 10000.0, 5000.0, 5000.0],
		"Queen Rosi four action slots retain source cooldowns")
	check(not NativeBoxLoot.required(dungeon), "Ice Palace does not invent box loot from item pocket")
	check(NativeJarTraps.ready(game.combat_assets), "shared source trap assets resolve")

	var flow := FlowSession.new()
	flow.profile["level"] = 49
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "icepalace"})["ok"],
		"flow departs the hidden Ice Palace route")
	route = flow.active_dungeon_route()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live Ice Palace run selects its sole ordinary layout")
	check(session._validate_native_maze(probe, live_maze),
		"Ice Palace room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "icepalace", "route": route,
		"room_id": "icepalace:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source Ice Palace room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 9
			and game.view_snapshot()["hud"]["route"].size() == 9,
			"both public battle views report the complete Ice Palace graph")
		check(game.view.audio.has_dungeon_music("icepalace")
			and String(game.view.audio.music.stream.resource_path).ends_with("icepalace.ogg"),
			"Ice Palace starts with the original M_ICEPALACE track")
		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts,
			"Ice Palace start room spawns its exact source monster lineup")

		var interactive_props := 0
		var box_props := 0
		var all_gaps := {}
		for path: String in dungeon.get("rooms", {}).keys():
			var room: Dictionary = probe.room(path)
			var room_props: Array = game.build_props(room)
			interactive_props += room_props.size()
			for prop: Dictionary in room_props:
				if not (prop.get("box_items", []) as Array).is_empty():box_props += 1
			merge_gaps(all_gaps, game.native_object_gaps)
		check(interactive_props == 50,
			"all 26 crystals and 24 frozen trees build exactly once across nine MAPs")
		check(box_props == 0, "Ice Palace creates no item-box props")
		for path in [
			"passiveobject/actionobject/breakableobject/ice.obj",
			"passiveobject/actionobject/breakableobject/icecolumn.obj",
			"passiveobject/actionobject/breakableobject/iceflower.obj",
			"passiveobject/actionobject/breakableobject/iceshisuke.obj",
		]:
			check(all_gaps.get(path, []) == ["native_breakable_source"],
				"Ice Palace breakable remains an explicit source-contract gap: " + path)
		var pocket_gap: Array = all_gaps.get(
			"passiveobject/mapobject/breakableobject/itempocket.obj", [])
		check("native_breakable_source" in pocket_gap and "native_special_object" in pocket_gap
			and 2211 in pocket_gap,
			"Ice Palace item pocket remains a breakable/special/2211 gap: " + str(pocket_gap))
		for path in [
			"passiveobject/actionobject/trap/bantuman.obj",
			"passiveobject/actionobject/trap/bantuwoman.obj",
			"passiveobject/actionobject/trap/rosi_left_stone.obj",
			"passiveobject/actionobject/trap/rosi_right_stone.obj",
		]:
			check(all_gaps.get(path, []) == ["native_object_trigger"],
				"Ice Palace trap remains an explicit behaviour gap: " + path)
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_ICEPALACE] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
