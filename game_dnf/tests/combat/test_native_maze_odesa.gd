extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const FlowSession = preload("res://flow/session.gd")
const NativeMaze = preload("res://combat/data/native_maze.gd")
const NativeBreakable = preload("res://combat/resolve/native_breakable.gd")
const NativeBoxLoot = preload("res://loot/native_box.gd")
const NativeJarTraps = preload("res://combat/resolve/native_jar_traps.gd")
const NativePotMonsters = preload("res://combat/resolve/native_pot_monsters.gd")
const DetRng = preload("res://core/det_rng.gd")

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
		push_error("[NATIVE_MAZE_ODESA] FAIL " + label)

func expected_route() -> Dictionary:
	return {
		Vector2i(0, 0): [11100, "map/odesa2/odesa01.map"],
		Vector2i(1, 0): [11101, "map/odesa2/odesa02.map"],
		Vector2i(2, 0): [11103, "map/odesa2/odesa03-1.map"],
		Vector2i(2, 1): [11107, "map/odesa2/odesa07.map"],
		Vector2i(2, 2): [11118, "map/odesa2/odesa15-1.map"],
		Vector2i(3, 1): [11108, "map/odesa2/odesa08.map"],
		Vector2i(3, 2): [11111, "map/odesa2/odesa11.map"],
		Vector2i(3, 3): [11120, "map/odesa2/odesa17.map"],
		Vector2i(4, 2): [11113, "map/odesa2/odesa12-1.map"],
		Vector2i(4, 3): [11122, "map/odesa2/odesa18-1.map"],
		Vector2i(5, 2): [11114, "map/odesa2/odesa13.map"],
		Vector2i(5, 3): [11123, "map/odesa2/odesa19.map"],
		Vector2i(6, 2): [11115, "map/odesa2/odesa14.map"],
	}

func run() -> void:
	game = session.mount(root)
	game.set_process(false)
	game.set_physics_process(false)
	var routes: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/dungeons.json"))["dungeons"]
	var route: Dictionary = routes["odesa"]
	check(route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("name") == "热血八番街" and route.get("region") == "westcoast"
		and int(route.get("min_level", 0)) == 52 and int(route.get("monster_level", 0)) == 55,
		"Odesa is a hidden level 52 West Coast native-maze route with source basis level 55")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production Odesa export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/village/cartelarad/odesa.dgn"
		and dungeon.get("sha256") == "1fed07147d1f2be9a4071572589b208a7e2c493410925df8f92d8655f7d5ed7b"
		and int(dungeon.get("index", -1)) == 60,
		"Odesa export keeps DGN index 60 and the pinned source identity")
	check(Array(dungeon.get("placements", [])).size() == 47
		and Dictionary(dungeon.get("rooms", {})).size() == 26
		and Dictionary(probe.data.get("images", {})).size() == 69,
		"Odesa export contains 47 greed-eligible placements, 26 MAPs and 69 source images")
	check(int(dungeon.get("maze_block_index", -1)) == 4
		and dungeon.get("maze_block_selection") == "hell_base"
		and Array(dungeon.get("maze_blocks", [])).size() == 5,
		"Odesa preserves five blocks and selects the non-quest hell-base block 4")
	var block_sizes: Array = []
	var block_quests: Array = []
	var block_hell: Array = []
	for block: Dictionary in dungeon.get("maze_blocks", []):
		var block_size: Array = block.get("size")
		block_sizes.append([int(block_size[0]), int(block_size[1])])
		var quest = block.get("quest_connection")
		var hell = block.get("hell_dungeon")
		var quest_values: Array = []
		var hell_values: Array = []
		for value in (quest if quest is Array else []):quest_values.append(int(value))
		for value in (hell if hell is Array else []):hell_values.append(int(value))
		block_quests.append(quest_values)
		block_hell.append(hell_values)
	check(block_sizes == [[4, 2], [5, 2], [7, 3], [6, 4], [7, 4]],
		"Odesa preserves source block sizes in order")
	check(block_quests == [
		[0, 3901, -1], [0, 3903, -1], [0, 3904, 1], [0, 3906, 1], [],
	], "Odesa keeps the four quest-only block links raw (actual=%s)" % str(block_quests))
	check(block_hell == [[], [], [], [], [1]],
		"only the selected base layout carries the source hell-dungeon marker (actual=%s)" % str(block_hell))

	var diagnostics: Array = probe.data.get("diagnostics", [])
	var errors: Array = diagnostics.filter(func(row): return row.get("level") == "error")
	var warnings: Array = diagnostics.filter(func(row): return row.get("level") == "warning")
	var infos: Array = diagnostics.filter(func(row): return row.get("level") == "info")
	var missing_wall_errors := 0
	for row: Dictionary in errors:
		if row.get("code") == "image_missing" and String(row.get("path", "")).contains("cartelarad/ca_"):
			missing_wall_errors += 1
	check(errors.size() == 4 and missing_wall_errors == 4,
		"the only export errors are four unavailable Cartel Arad wall-gate frames")
	check(warnings.size() == 82
		and warnings.filter(func(row): return row.get("code") == "cell_without_map").size() == 15
		and warnings.filter(func(row): return row.get("code") == "object_unrendered").size() == 67,
		"Odesa preserves fifteen AA cells and 67 action objects without basic motion")
	check(infos.size() == 105
		and infos.filter(func(row): return row.get("code") == "scroll_absent").size() == 78
		and infos.filter(func(row): return row.get("code") == "unhandled_tags").size() == 26
		and infos.filter(func(row): return row.get("code") == "maze_block_selected").size() == 1,
		"Odesa preserves scroll/unhandled-tag notices and one selected-block record")

	var maze := NativeMaze.new()
	var size: Vector2i = maze._point(dungeon.get("size"))
	var cells: Dictionary = maze._read_cells(dungeon.get("cells"), size)
	var starts: Array = maze._read_endpoint_cells(dungeon.get("start_map_raw"), cells, "start_candidate")
	var bosses: Array = maze._read_endpoint_cells(dungeon.get("boss_map_raw"), cells, "boss_candidate")
	var specs: Dictionary = maze._read_specifications(dungeon.get("raw"), cells, 4)
	check(cells.size() == 28 and starts.size() == 1 and bosses.size() == 1,
		"Odesa 7x4 source grid exposes one start and one boss candidate")
	check(starts[0] == Vector2i(0, 0) and bosses[0] == Vector2i(5, 3),
		"Odesa source endpoints are start (0,0) and boss (5,3)")
	var connected := cells.values().filter(func(cell): return not cell.get("doors", []).is_empty())
	check(connected.size() == 13 and cells.values().filter(func(cell): return cell.get("code") == "AA").size() == 15,
		"Odesa base block has 13 connected cells and fifteen empty AA cells")
	check(specs.get("normal", {}).size() == 16 and specs.get("boss", {}).size() == 1,
		"Odesa selected block preserves sixteen normal and one boss specification")

	var pools: Dictionary = maze._read_pools(dungeon, cells, starts[0], bosses[0])
	check(pools.size() == 13,
		"Odesa start/boss reaches all 13 connected cells (pools=%d error=%s)"
		% [pools.size(), maze.last_error])
	var expected := expected_route()
	for cell: Vector2i in expected:
		var pool: Array = pools.get(cell, [])
		check(pool.size() == 1 and int(pool[0]["map_id"]) == int(expected[cell][0]),
			"source route chooses MAP %d at cell %s" % [int(expected[cell][0]), cell])
	check(maze.start(probe.data, SourceRolls.new([0, 0, 0]), route.get("source", {})),
		"generic native maze starts Odesa")
	check(maze.room_count() == 13 and maze.required_map_paths().size() == 13,
		"Odesa exposes 13 rooms across 13 fixed source MAPs")
	check(maze.current_room().get("source_map_id") == 11100,
		"Odesa start resolves source start MAP 11100")

	var source_monsters := {}
	var source_monster_count := 0
	var source_boss_rows := 0
	var source_object_count := 0
	for room: Dictionary in dungeon.get("rooms", {}).values():
		for monster: Dictionary in room.get("monsters", []):
			source_monsters[String(monster.get("mob", ""))] = true
			source_monster_count += 1
			var raw: Array = monster.get("raw", [])
			if not raw.is_empty() and raw[-1] == "[boss]":source_boss_rows += 1
		source_object_count += Array(room.get("objects", [])).size()
	check(source_monsters.size() == 8 and source_monster_count == 195 and source_boss_rows == 3,
		"Odesa source has 195 direct placements, eight MOBs and three boss rows")
	check(source_object_count == 100,
		"Odesa source has 100 map objects across all five layout variants")

	var route_monster_count := 0
	var route_monsters := {}
	var route_boss_rows := 0
	var route_object_count := 0
	var route_breakable_candidates := 0
	var route_runtime_breakables := 0
	var route_unrendered := 0
	var route_objects := {}
	for cell: Vector2i in expected:
		var room: Dictionary = dungeon["rooms"][String(expected[cell][1])]
		for monster: Dictionary in room.get("monsters", []):
			route_monster_count += 1
			route_monsters[String(monster.get("mob", ""))] = true
			var raw: Array = monster.get("raw", [])
			if not raw.is_empty() and raw[-1] == "[boss]":route_boss_rows += 1
		for item: Dictionary in room.get("objects", []):
			route_object_count += 1
			var path := String(item.get("obj", "")).to_lower()
			route_objects[path] = 1 + int(route_objects.get(path, 0))
			if item.get("sprite") == null:route_unrendered += 1
			if NativeBreakable.supports(item):
				route_breakable_candidates += 1
				if not game.content.record(path).get("native_breakable", {}).is_empty():
					route_runtime_breakables += 1
	check(route_monster_count == 114 and route_monsters.size() == 8 and route_boss_rows == 1,
		"Odesa ordinary route has 114 monsters, eight MOBs and one RocketMan boss row "
		+ "(actual=%d/%d/%d)" % [route_monster_count, route_monsters.size(), route_boss_rows])
	check(route_object_count == 43 and route_unrendered == 29,
		"Odesa ordinary route has 43 objects, including 29 unrendered breakable objects")
	check(route_objects == {
		"passiveobject/actionobject/breakableobject/trashcan.obj": 20,
		"passiveobject/actionobject/breakableobject/odesabox.obj": 9,
		"passiveobject/actionobject/obstacle/odesarice1.obj": 12,
		"passiveobject/actionobject/obstacle/odesarice0.obj": 2,
	}, "Odesa route preserves its source object distribution")
	check(route_breakable_candidates == 29 and route_runtime_breakables == 0,
		"Odesa 20 trashcans and nine Odesa boxes remain source-only breakable gaps")
	check(NativeBoxLoot.required(dungeon),
		"Odesa exposes an executable special-object item draw")
	check(NativeBoxLoot.ready(dungeon),
		"Odesa box group 0 and original item 3230 artwork resolve")
	check(NativeBoxLoot.pick(0, "0") == "original_3230"
		and NativeBoxLoot.pick(1699, "0") == "original_3230"
		and NativeBoxLoot.pick(1700, "0") == "",
		"Odesa box group 0 preserves item 3230 weight 1700")
	check(NativeJarTraps.ready(game.combat_assets), "shared source jar trap assets resolve")

	var banks := {
		"monster/newmonsters/cartel/westcoast/rod_aradman/rod_aradman.mob":
			["newmonsters_cartel_westcoast_rod_aradman_rod_aradman", 2, [1, 0]],
		"monster/newmonsters/cartel/westcoast/special_rod_aradman/special_rod_aradman.mob":
			["newmonsters_cartel_westcoast_special_rod_aradman_special_rod_aradman", 2, [0, 1]],
		"monster/newmonsters/cartel/westcoast/junk_thrower/junk_thrower.mob":
			["newmonsters_cartel_westcoast_junk_thrower_junk_thrower", 4, [0]],
		"monster/newmonsters/cartel/westcoast/macgee/macgee.mob":
			["newmonsters_cartel_westcoast_macgee_macgee", 8, [2, 7, 4, 5, 0]],
		"monster/newmonsters/cartel/westcoast/launcher/launcher.mob":
			["newmonsters_cartel_westcoast_launcher_launcher", 2, [0]],
		"monster/newmonsters/cartel/westcoast/bunkertank/bunkertank.mob":
			["newmonsters_cartel_westcoast_bunkertank_bunkertank", 2, [0]],
		"monster/newmonsters/cartel/rocketman/rocketman.mob":
			["newmonsters_cartel_rocketman_rocketman", 17, []],
	}
	for mob: String in banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		check(String(definition.get("bank", "")) == banks[mob][0]
			and game.combat_assets.get("monsters", {}).has(banks[mob][0]),
			"Odesa source bank is compiled: " + mob)
		check(Array(definition.get("moves", [])).size() == int(banks[mob][1]),
			"source attack slots compile for %s (moves=%d expected=%d)"
			% [mob, Array(definition.get("moves", [])).size(), int(banks[mob][1])])
		var skills: Array = []
		for rule: Dictionary in Array(definition.get("rules", [])):
			skills.append(int(rule.get("skill", -1)))
		check(skills == banks[mob][2],
			"source AI priority compiles for %s (%s)" % [mob, skills])
		for move: Dictionary in Array(definition.get("moves", [])):
			if not move.has("atk_path"):continue
			check(not game.table.atk(String(move["atk_path"])).is_empty()
				and not Array(move.get("timeline", [])).is_empty(),
				"source attack motion and ATK compile together: " + mob)
	var alternate_boss: String = game.table.monster_by_mob(
		"monster/newmonsters/cartel/westcoast/rod_boss/rod_boss.mob")
	var alternate: Dictionary = game.table.monsters.get(alternate_boss, {})
	var alternate_skills: Array = []
	for rule: Dictionary in Array(alternate.get("rules", [])):
		alternate_skills.append(int(rule.get("skill", -1)))
	check(String(alternate.get("bank", "")) == "newmonsters_cartel_westcoast_rod_boss_rod_boss"
		and Array(alternate.get("moves", [])).size() == 5
		and alternate_skills == [1, 0, 4],
		"alternate rod_boss block data is prepared but not reachable from block 4")

	var bgm: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/bgm.json"))
	check(bgm.get("dungeons", {}).get("odesa", {}).get("normal") == "odesa_new"
		and bgm.get("dungeons", {}).get("odesa", {}).get("boss") == "odesa_boss_new",
		"Odesa maps the source normal and boss tracks")
	check(Array(bgm.get("source_gaps", {}).get("odesa", {}).get(
		"map/odesa2/odesa15-1.map", {}).get("sound", [])) == ["M_TEMP_MCGEE", "AMB_TOWN_02"],
		"Odesa records the one unresolved M_TEMP_MCGEE MAP cue instead of inventing a track")

	var flow := FlowSession.new()
	flow.profile["level"] = 55
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "odesa"})["ok"],
		"flow departs the hidden Odesa route")
	route = flow.active_dungeon_route()
	NativePotMonsters.reset_catalog()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live Odesa run selects the hell-base block 4")
	NativePotMonsters.prepare_catalog(dungeon, SourceRolls.new([0, 0, 0, 0]))
	check(session._validate_native_maze(probe, live_maze),
		"Odesa room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "odesa", "route": route,
		"room_id": "odesa:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source Odesa room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 13
			and game.view_snapshot()["hud"]["route"].size() == 13,
			"both public battle views report the complete Odesa graph")
		check(game.view.audio.has_dungeon_music("odesa")
			and String(game.view.audio.music.stream.resource_path).ends_with("odesa_new.ogg"),
			"Odesa starts with the source M_TEMP_ODESA track")

		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts,
			"Odesa start room spawns its exact source monster lineup")

		var interactive_props := 0
		var all_gaps := {}
		for path: String in expected_route().values().map(func(value): return String(value[1])):
			var room: Dictionary = probe.room(path)
			var room_props: Array = game.build_props(room)
			interactive_props += room_props.size()
			for path_key: String in game.native_object_gaps:
				if not all_gaps.has(path_key):all_gaps[path_key] = []
				for gap in game.native_object_gaps[path_key]:
					if gap not in all_gaps[path_key]:all_gaps[path_key].append(gap)
		check(interactive_props == 0,
			"Odesa does not materialise unsupported trashcan/Odesa-box objects")
		var trash_gaps: Array = all_gaps.get(
			"passiveobject/actionobject/breakableobject/trashcan.obj", [])
		var box_gaps: Array = all_gaps.get(
			"passiveobject/actionobject/breakableobject/odesabox.obj", [])
		check(trash_gaps == ["native_breakable_source", "native_special_object"],
			"trashcan remains an explicit breakable and special-object gap")
		check(box_gaps == ["native_breakable_source", "native_special_object", 2010, 2110],
			"Odesa boxes remain explicit breakable/special-object contracts with unresolved traps 2010 and 2110 "
			+ "(actual=%s)" % str(box_gaps))
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_ODESA] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
