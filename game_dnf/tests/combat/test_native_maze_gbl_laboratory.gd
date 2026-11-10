extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const FlowSession = preload("res://flow/session.gd")
const NativeMaze = preload("res://combat/data/native_maze.gd")
const NativeBreakable = preload("res://combat/resolve/native_breakable.gd")
const NativeBoxLoot = preload("res://loot/native_box.gd")
const NativeJarTraps = preload("res://combat/resolve/native_jar_traps.gd")
const DetRng = preload("res://core/det_rng.gd")

const SOURCE_SHA := "ee701f2b6a72085033a4b8fe8430d1374e9ddd4dbd5c88dc88455fd00ee9e379"
const ROUTE_MAP_IDS := [13014, 13015, 13016, 13017, 13018, 13019, 13021, 13025]

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
		push_error("[NATIVE_MAZE_GBL_LABORATORY] FAIL " + label)

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
	var route: Dictionary = routes["gbl_laboratory"]
	check(route.get("name") == "GBL教研究所"
		and route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("region") == "behemoth"
		and int(route.get("min_level", 0)) == 47 and int(route.get("monster_level", 0)) == 50,
		"GBL Laboratory is a hidden level 47 Behemoth native-maze route with basis level 50")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production GBL Laboratory export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/village/gbl/gbl_laboratory.dgn"
		and dungeon.get("sha256") == SOURCE_SHA,
		"GBL Laboratory export keeps the pinned DGN source identity")
	check(Array(dungeon.get("placements", [])).size() == 20
		and Dictionary(dungeon.get("rooms", {})).size() == 12
		and Dictionary(probe.data.get("images", {})).size() == 114,
		"GBL Laboratory export contains 20 placements, 12 MAPs and 114 source images")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	var errors: Array = diagnostics.filter(func(row): return row.get("level") == "error")
	var warnings: Array = diagnostics.filter(func(row): return row.get("level") == "warning")
	var infos: Array = diagnostics.filter(func(row): return row.get("level") == "info")
	var unrendered := 0
	var aa_warnings := 0
	var scroll_absent := 0
	var unhandled := 0
	for row: Dictionary in warnings:
		if row.get("code") == "object_unrendered":unrendered += 1
		if row.get("code") == "cell_without_map" and String(row.get("detail", "")).contains(" code AA"):
			aa_warnings += 1
	for row: Dictionary in infos:
		if row.get("code") == "scroll_absent":scroll_absent += 1
		if row.get("code") == "unhandled_tags":unhandled += 1
	check(errors.is_empty() and warnings.size() == 86 and infos.size() == 48
		and unrendered == 82 and aa_warnings == 4 and scroll_absent == 36 and unhandled == 12,
		"GBL Laboratory preserves 82 unrendered objects, four AA cells, "
		+ "36 missing scrolls and 12 raw-tag MAPs")

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
	check(size == Vector2i(4, 4) and cells.size() == 16
		and starts == [Vector2i(0, 3)] and bosses == [Vector2i(3, 1)],
		"GBL Laboratory is a 4x4 source grid with start (0,3) and boss (3,1)")
	check(fixed_ids == [
		13014, 13015, 13016, 13017, 13018, 13019,
		13020, 13021, 13022, 13023, 13024, 13025,
	], "GBL Laboratory keeps all twelve fixed ordinary MAP rows")
	var boss_candidates: Array = cells[Vector2i(3, 1)]["map_candidates"]
	check(boss_candidates == [
		"map/gbl2/g2(b)001.map", "map/gbl2/g2(n)006.map",
	], "the boss cell preserves one normal and one source boss candidate")

	var maze_blocks := 0
	var boss_specs := 0
	var seal_id = null
	var seal_pos = null
	var event_monster = null
	var hell_value = null
	for span: Dictionary in dungeon.get("raw", []):
		var tag := String(span.get("tag", ""))
		var values: Array = span.get("values", [])
		if tag == "[maze info]":maze_blocks += 1
		if tag == "[boss map specification]":boss_specs += 1
		if tag == "[seal door map index]":seal_id = values
		if tag == "[seal door pos]":seal_pos = values
		if tag == "[event monster]":event_monster = values
		if tag == "[hell dungeon]":hell_value = values
	check(maze_blocks == 1 and boss_specs == 0,
		"GBL Laboratory consumes one maze whose unique boss MAP is selected by room role")
	check(event_monster != null and int(event_monster[1][2]) == 10000
		and int(event_monster[2][2]) == 62502
		and seal_id != null and int(seal_id[0][2]) == 60041
		and seal_pos != null and [int(seal_pos[0][2]), int(seal_pos[1][2])] == [2, 1]
		and hell_value != null and int(hell_value[0][2]) == 1,
		"event monster 62502, seal door 60041 at (2,1) and hell mode remain preserved raw")

	var fixed_maze := NativeMaze.new()
	check(fixed_maze.start(probe.data, SourceRolls.new([0, 0, 0]), route.get("source", {})),
		"native maze starts the sole GBL Laboratory layout")
	check(fixed_maze.room_count() == 12,
		"GBL Laboratory reaches all twelve connected cells")
	var selected_ids: Array[int] = [int(fixed_maze.current_room().get("source_map_id", 0))]
	var moves := ["up", "up", "up", "right", "right", "down", "right"]
	for step in moves.size():
		var current: Vector2i = fixed_maze.current_room().get("cell", Vector2i(-1, -1))
		var cleared: Dictionary = fixed_maze.clear_room(current, 0)
		var moved: Dictionary = fixed_maze.move(moves[step])
		check(not cleared.is_empty() and not moved.is_empty(),
			"GBL Laboratory clears and traverses source step %d" % step)
		selected_ids.append(int(moved.get("source_map_id", 0)))
	check(selected_ids == ROUTE_MAP_IDS,
		"GBL Laboratory shortest route selects MAPs 13014..13019,13021,13025")
	var final_clear: Dictionary = fixed_maze.clear_room(Vector2i(3, 1), 0)
	check(bool(final_clear.get("boss", false)) and bool(final_clear.get("final_room", false)),
		"the selected 13025 room is the sole boss and final room")

	var source_monsters := {}
	var source_monster_counts := {}
	var source_monster_count := 0
	var source_boss_rows := 0
	var source_object_count := 0
	var source_breakable_candidates := 0
	var source_runtime_breakables := 0
	var source_traps := 0
	var source_static := 0
	for room: Dictionary in dungeon.get("rooms", {}).values():
		for monster: Dictionary in room.get("monsters", []):
			var mob := String(monster.get("mob", ""))
			source_monsters[mob] = true
			source_monster_counts[mob] = 1 + int(source_monster_counts.get(mob, 0))
			source_monster_count += 1
			if Array(monster.get("raw", []))[-1] == "[boss]":source_boss_rows += 1
		for item: Dictionary in room.get("objects", []):
			source_object_count += 1
			var path := String(item.get("obj", "")).to_lower()
			if NativeBreakable.supports(item):
				source_breakable_candidates += 1
				if not game.content.record(path).get("native_breakable", {}).is_empty():
					source_runtime_breakables += 1
			elif path.contains("/trap/"):
				source_traps += 1
			else:
				source_static += 1
	check(source_monsters.size() == 6 and source_monster_count == 94 and source_boss_rows == 1,
		"GBL Laboratory has 94 direct placements, six MOBs and one boss row")
	check(source_monster_counts == {
		"monster/newmonsters/gbl/blacktentacle/blacktentacle.mob": 25,
		"monster/newmonsters/gbl/invader/invader.mob": 31,
		"monster/newmonsters/gbl/hydracle/hydracle.mob": 1,
		"monster/newmonsters/gbl/ladyzealot/ladyzealot.mob": 33,
		"monster/newmonsters/gbl/acidra/acidra.mob": 3,
		"monster/newmonsters/gbl/stickcle/stickcle.mob": 1,
	}, "GBL Laboratory keeps the exact source monster counts")
	check(source_object_count == 778 and source_breakable_candidates == 276
		and source_runtime_breakables == 33 and source_traps == 413
		and source_static == 89,
		"GBL Laboratory has 778 objects: 33 executable breakables, "
		+ "243 breakable gaps, 413 traps and 89 static objects "
		+ "(objects=%d candidates=%d runtime=%d traps=%d static=%d)"
		% [source_object_count, source_breakable_candidates, source_runtime_breakables,
			source_traps, source_static])

	var banks := {
		"monster/newmonsters/gbl/blacktentacle/blacktentacle.mob": ["newmonsters_gbl_blacktentacle_blacktentacle", 1],
		"monster/newmonsters/gbl/invader/invader.mob": ["newmonsters_gbl_invader_invader", 3],
		"monster/newmonsters/gbl/hydracle/hydracle.mob": ["newmonsters_gbl_hydracle_hydracle", 8],
		"monster/newmonsters/gbl/ladyzealot/ladyzealot.mob": ["newmonsters_gbl_ladyzealot_ladyzealot", 4],
		"monster/newmonsters/gbl/acidra/acidra.mob": ["newmonsters_gbl_acidra_acidra", 3],
		"monster/newmonsters/gbl/stickcle/stickcle.mob": ["newmonsters_gbl_stickcle_stickcle", 3],
	}
	for mob: String in banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		check(String(definition.get("bank", "")) == banks[mob][0]
			and game.combat_assets.get("monsters", {}).has(banks[mob][0]),
			"GBL Laboratory source bank is compiled: " + mob)
		check(Array(definition.get("moves", [])).size() == int(banks[mob][1]),
			"GBL Laboratory attack slots compile for %s (moves=%d expected=%d)"
			% [mob, Array(definition.get("moves", [])).size(), int(banks[mob][1])])

	check(NativeBoxLoot.required(dungeon),
		"GBL Laboratory detects its jilef special item draw")
	check(NativeBoxLoot.ready(dungeon),
		"GBL Laboratory group 1 and original item images resolve")
	var prepared: Array[String] = NativeBoxLoot.prepare(1, 0, "1")
	check(prepared.size() == 1 and prepared[0].begins_with("original_"),
		"GBL Laboratory group 1 prepares one source item: " + str(prepared))
	check(NativeJarTraps.ready(game.combat_assets), "shared source trap assets resolve")

	var flow := FlowSession.new()
	flow.profile["level"] = 50
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "gbl_laboratory"})["ok"],
		"flow departs the hidden GBL Laboratory route")
	route = flow.active_dungeon_route()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live GBL Laboratory run selects the sole layout")
	check(session._validate_native_maze(probe, live_maze),
		"GBL Laboratory room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "gbl_laboratory", "route": route,
		"room_id": "gbl_laboratory:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source GBL Laboratory room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 12
			and game.view_snapshot()["hud"]["route"].size() == 12,
			"both public battle views report the complete GBL Laboratory graph")
		check(game.view.audio.has_dungeon_music("gbl_laboratory")
			and String(game.view.audio.music.stream.resource_path).ends_with("gblarad_lab.ogg"),
			"GBL Laboratory starts with the original M_GBLARAD_LAB track")
		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts,
			"GBL Laboratory start room spawns its exact source monster lineup")

		var interactive_props := 0
		var box_props := 0
		var unknown_ids: Array[int] = []
		var all_gaps := {}
		for path: String in dungeon.get("rooms", {}).keys():
			var room: Dictionary = probe.room(path)
			var room_props: Array = game.build_props(room)
			interactive_props += room_props.size()
			for prop: Dictionary in room_props:
				if not (prop.get("box_items", []) as Array).is_empty():box_props += 1
				for source_id in prop.get("unresolved_trap_ids", []):
					if int(source_id) not in unknown_ids:unknown_ids.append(int(source_id))
			merge_gaps(all_gaps, game.native_object_gaps)
		unknown_ids.sort()
		check(interactive_props == 33,
			"all 31 long pots and two treasure pots build exactly once across twelve MAPs")
		check(box_props == 0 and unknown_ids.is_empty(),
			"GBL Laboratory does not invent box props or unresolved special trap IDs")
		for path in [
			"passiveobject/actionobject/breakableobject/bookcase.obj",
			"passiveobject/actionobject/breakableobject/waterway.obj",
			"passiveobject/mapobject/breakableobject/largegrassmirkwood.obj",
			"passiveobject/mapobject/breakableobject/smallgrasssunderland.obj",
		]:
			check(all_gaps.get(path, []) == ["native_breakable_source"],
				"GBL Laboratory breakable remains an explicit source-contract gap: " + path)
		var jilef_gap: Array = all_gaps.get("passiveobject/actionobject/trap/jilef.obj", [])
		check("native_special_object" in jilef_gap
			and "native_action_object_behavior" in jilef_gap
			and "native_action_object_visual" in jilef_gap,
			"jilef keeps special/action/visual gaps despite compiled item data: " + str(jilef_gap))
		check(all_gaps.get("passiveobject/mapobject/trap/starfishegg.obj", [])
			== ["native_object_trigger"],
			"GBL Laboratory map trap remains an explicit behaviour gap")
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_GBL_LABORATORY] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
