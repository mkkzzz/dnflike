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
		push_error("[NATIVE_MAZE_GROZNI] FAIL " + label)

func expected_route() -> Dictionary:
	return {
		Vector2i(7, 0): [11201, "map/groznyoutside/grozny01.map"],
		Vector2i(6, 0): [11202, "map/groznyoutside/grozny02.map"],
		Vector2i(5, 0): [11204, "map/groznyoutside/grozny03-1.map"],
		Vector2i(4, 0): [11209, "map/groznyoutside/grozny08.map"],
		Vector2i(3, 0): [11212, "map/groznyoutside/grozny09.map"],
		Vector2i(2, 0): [11221, "map/groznyinside/grozny16.map"],
		Vector2i(4, 1): [11208, "map/groznyoutside/grozny07.map"],
		Vector2i(3, 1): [11213, "map/groznyoutside/grozny10.map"],
		Vector2i(2, 1): [11222, "map/groznyinside/grozny11.map"],
		Vector2i(1, 1): [11215, "map/groznyinside/grozny12.map"],
		Vector2i(0, 1): [11217, "map/groznyinside/grozny13.map"],
		Vector2i(4, 2): [11220, "map/groznyinside/grozny15.map"],
		Vector2i(3, 2): [11220, "map/groznyinside/grozny15.map"],
		Vector2i(2, 2): [11220, "map/groznyinside/grozny15.map"],
		Vector2i(1, 2): [11218, "map/groznyinside/grozny14.map"],
	}

func run() -> void:
	game = session.mount(root)
	game.set_process(false)
	game.set_physics_process(false)
	var routes: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/dungeons.json"))["dungeons"]
	var route: Dictionary = routes["grozni"]
	check(route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("name") == "绿都格罗兹尼" and route.get("region") == "westcoast"
		and int(route.get("min_level", 0)) == 53 and int(route.get("monster_level", 0)) == 56,
		"Green City Grozny is a hidden level 53 West Coast native-maze route with source basis level 56")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production Grozny export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/village/cartelarad/grozni.dgn"
		and dungeon.get("sha256") == "6573a9ef1a05fb400c903b97b2ae89543504fb5cdf804d778c1bc26a289b5970",
		"Grozny export keeps the pinned DGN source identity")
	check(Array(dungeon.get("placements", [])).size() == 69
		and Dictionary(dungeon.get("rooms", {})).size() == 32
		and Dictionary(probe.data.get("images", {})).size() == 87,
		"Grozny export contains 69 greed-eligible placements, 32 MAPs and 87 source images")
	check(int(dungeon.get("maze_block_index", -1)) == 8
		and Array(dungeon.get("maze_blocks", [])).size() == 10,
		"Grozny preserves ten maze blocks and selects ordinary block 8")
	var block_sizes: Array = []
	for block: Dictionary in dungeon.get("maze_blocks", []):
		var block_size: Array = block.get("size")
		block_sizes.append([int(block_size[0]), int(block_size[1])])
	check(block_sizes == [
		[3, 3], [4, 2], [5, 2], [7, 3], [8, 3],
		[8, 3], [8, 3], [8, 3], [8, 3], [8, 3],
	], "Grozny preserves source block sizes in order")

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
	check(warnings.size() == 70
		and warnings.filter(func(row): return row.get("code") == "cell_without_map").size() == 9
		and warnings.filter(func(row): return row.get("code") == "object_unrendered").size() == 61,
		"Grozny preserves nine AA cells and 61 action objects without basic motion")
	check(infos.size() == 129
		and infos.filter(func(row): return row.get("code") == "scroll_absent").size() == 96
		and infos.filter(func(row): return row.get("code") == "maze_block_selected").size() == 1,
		"Grozny preserves 96 scroll-absence notices and one selected-block record")

	var maze := NativeMaze.new()
	var size: Vector2i = maze._point(dungeon.get("size"))
	var cells: Dictionary = maze._read_cells(dungeon.get("cells"), size)
	var starts: Array = maze._read_endpoint_cells(dungeon.get("start_map_raw"), cells, "start_candidate")
	var bosses: Array = maze._read_endpoint_cells(dungeon.get("boss_map_raw"), cells, "boss_candidate")
	var specs: Dictionary = maze._read_specifications(dungeon.get("raw"), cells, 8)
	check(cells.size() == 24 and starts.size() == 1 and bosses.size() == 1,
		"Grozny 8x3 source grid exposes one start and one boss candidate")
	check(starts[0] == Vector2i(7, 0) and bosses[0] == Vector2i(0, 1),
		"Grozni source endpoints are start (7,0) and boss (0,1)")
	var connected := cells.values().filter(func(cell): return not cell.get("doors", []).is_empty())
	check(connected.size() == 15 and cells.values().filter(func(cell): return cell.get("code") == "AA").size() == 9,
		"Grozny ordinary block has 15 connected cells and nine empty AA cells")
	check(specs.get("normal", {}).size() == 14 and specs.get("boss", {}).size() == 1,
		"Grozny selected block preserves 14 normal and one boss specification")

	var pools: Dictionary = maze._read_pools(dungeon, cells, starts[0], bosses[0])
	check(pools.size() == 15,
		"Grozny start/boss reaches all 15 connected cells (pools=%d error=%s)"
		% [pools.size(), maze.last_error])
	var expected := expected_route()
	for cell: Vector2i in expected:
		var pool: Array = pools.get(cell, [])
		check(pool.size() == 1 and int(pool[0]["map_id"]) == int(expected[cell][0]),
			"source specification chooses MAP %d at cell %s" % [int(expected[cell][0]), cell])
	check(maze.start(probe.data, SourceRolls.new([0, 0, 0]), route.get("source", {})),
		"generic native maze starts Grozny")
	check(maze.room_count() == 15 and maze.required_map_paths().size() == 13,
		"Grozny exposes 15 rooms across 13 unique source MAPs")
	check(maze.current_room().get("source_map_id") == 11201,
		"Grozny start resolves the source start MAP rather than the same-cell boss candidate")

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
	check(source_monsters.size() == 10 and source_monster_count == 237 and source_boss_rows == 4,
		"Grozny source has 237 direct placements, ten MOBs and four boss rows")
	check(source_object_count == 121,
		"Grozny source has 121 map objects across all ten layout variants")

	var route_monster_count := 0
	var route_object_count := 0
	var route_breakable_candidates := 0
	var route_runtime_breakables := 0
	var route_unrendered := 0
	for cell: Vector2i in expected:
		var room: Dictionary = dungeon["rooms"][String(expected[cell][1])]
		route_monster_count += Array(room.get("monsters", [])).size()
		for item: Dictionary in room.get("objects", []):
			route_object_count += 1
			if item.get("sprite") == null:route_unrendered += 1
			if NativeBreakable.supports(item):
				route_breakable_candidates += 1
				if not game.content.record(String(item.get("obj", "")).to_lower()).get("native_breakable", {}).is_empty():
					route_runtime_breakables += 1
	check(route_monster_count == 129 and route_object_count == 67 and route_unrendered == 30,
		"Grozny ordinary route has 129 monsters and 67 objects, including 30 unrendered action objects")
	check(route_breakable_candidates == 30 and route_runtime_breakables == 0,
		"Grozny 21 stone, five odesabox and four cover candidates remain source-only gaps")
	check(not NativeBoxLoot.required(dungeon),
		"Grozny has no executable special-object item groups")
	check(NativeJarTraps.ready(game.combat_assets), "shared source jar trap assets resolve")

	var banks := {
		"monster/newmonsters/cartel/cypher/scarecrow/scarecrow.mob":
			["newmonsters_cartel_cypher_scarecrow_scarecrow", 1],
		"monster/newmonsters/cartel/cypher/aircrow/aircrow.mob":
			["newmonsters_cartel_cypher_aircrow_aircrow", 2],
		"monster/newmonsters/cartel/westcoast/tree_thrower/tree_thrower.mob":
			["newmonsters_cartel_westcoast_tree_thrower_tree_thrower", 0],
		"monster/newmonsters/cartel/cypher/stoneswarm/stoneswarm.mob":
			["newmonsters_cartel_cypher_stoneswarm_stoneswarm", 2],
		"monster/newmonsters/cartel/westcoast/trashcan_thrower/trashcan_thrower.mob":
			["newmonsters_cartel_westcoast_trashcan_thrower_trashcan_thrower", 1],
		"monster/newmonsters/cartel/cypher/poltergeistchair/poltergeistchair.mob":
			["newmonsters_cartel_cypher_poltergeistchair_poltergeistchair", 1],
		"monster/newmonsters/cartel/cypher/poltergeistobject/poltergeistobject.mob":
			["newmonsters_cartel_cypher_poltergeistobject_poltergeistobject", 2],
		"monster/newmonsters/cartel/cypher/darkcrow/darkcrow.mob":
			["newmonsters_cartel_cypher_darkcrow_darkcrow", 9],
		"monster/newmonsters/cartel/cypher/poltergeistbookshelf/poltergeistbookshelf.mob":
			["newmonsters_cartel_cypher_poltergeistbookshelf_poltergeistbookshelf", 11],
		"monster/newmonsters/cartel/cypher/cypher/cypher.mob":
			["newmonsters_cartel_cypher_cypher_cypher", 6],
	}
	for mob: String in banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		check(String(definition.get("bank", "")) == banks[mob][0]
			and game.combat_assets.get("monsters", {}).has(banks[mob][0]),
			"Grozny source bank is compiled: " + mob)
		check(Array(definition.get("moves", [])).size() == int(banks[mob][1]),
			"source attack slots compile for %s (moves=%d expected=%d)"
			% [mob, Array(definition.get("moves", [])).size(), int(banks[mob][1])])
		for move: Dictionary in Array(definition.get("moves", [])):
			if not move.has("atk_path"):continue
			check(not game.table.atk(String(move["atk_path"])).is_empty()
				and not Array(move.get("timeline", [])).is_empty(),
				"source attack motion and ATK compile together: " + mob)
	var cypher_kind: String = game.table.monster_by_mob(
		"monster/newmonsters/cartel/cypher/cypher/cypher.mob")
	var cypher: Dictionary = game.table.monsters.get(cypher_kind, {})
	var cypher_rules: Array = Array(cypher.get("rules", []))
	var cypher_skills: Array = []
	for rule: Dictionary in cypher_rules:
		cypher_skills.append(int(rule.get("skill", -1)))
	check(cypher_rules.size() == 3
		and cypher_skills == [4, 5, 0],
		"Cypher loads the source AI rule priority 4,5,0")
	var tree_kind: String = game.table.monster_by_mob(
		"monster/newmonsters/cartel/westcoast/tree_thrower/tree_thrower.mob")
	var trash_kind: String = game.table.monster_by_mob(
		"monster/newmonsters/cartel/westcoast/trashcan_thrower/trashcan_thrower.mob")
	check(Array(game.table.monsters[tree_kind].get("moves", [])).is_empty(),
		"tree thrower behavior-only attack action remains an explicit no-move gap")

	var flow := FlowSession.new()
	flow.profile["level"] = 56
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "grozni"})["ok"],
		"flow departs the hidden Grozny route")
	route = flow.active_dungeon_route()
	NativePotMonsters.reset_catalog()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live Grozny run selects ordinary block 8")
	NativePotMonsters.prepare_catalog(dungeon, SourceRolls.new([0, 0, 0, 0]))
	check(session._validate_native_maze(probe, live_maze),
		"Grozny room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "grozni", "route": route,
		"room_id": "grozni:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source Grozny room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 15
			and game.view_snapshot()["hud"]["route"].size() == 15,
			"both public battle views report the complete Grozny graph")
		check(game.view.audio.has_dungeon_music("grozni")
			and String(game.view.audio.music.stream.resource_path).ends_with("shallow_keep.ogg"),
			"Grozny starts with the source M_SHALLOWKEEP track")

		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts,
			"Grozny start room spawns its exact source monster lineup")

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
			"Grozny does not materialise unsupported stone/odesabox/cover objects")
		check(all_gaps.get("passiveobject/actionobject/breakableobject/stone.obj", [])
			== ["native_breakable_source"]
			and all_gaps.get("passiveobject/actionobject/breakableobject/odesabox.obj", [])
			== ["native_breakable_source"],
			"stone and odesabox remain explicit breakable-source gaps")
		var cover_gaps: Array = all_gaps.get("passiveobject/actionobject/breakableobject/cover.obj", [])
		check(cover_gaps
			== ["native_breakable_source", "native_special_object", 2000, 2010],
			"cover remains a special-object contract with unresolved trap IDs 2000 and 2010")
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_GROZNI] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
