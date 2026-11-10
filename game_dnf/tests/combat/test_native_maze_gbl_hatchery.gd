extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const FlowSession = preload("res://flow/session.gd")
const NativeMaze = preload("res://combat/data/native_maze.gd")
const NativeBreakable = preload("res://combat/resolve/native_breakable.gd")
const NativeBoxLoot = preload("res://loot/native_box.gd")
const NativeJarTraps = preload("res://combat/resolve/native_jar_traps.gd")
const DetRng = preload("res://core/det_rng.gd")

const SOURCE_SHA := "266393055e4e3894218aa8f26b4ab35c1e7a416ec0b486b57cdfc1fe5b5b70ce"
const ROUTE_MAP_IDS := [13026, 13027, 13028, 13029, 13032, 13038]

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
		push_error("[NATIVE_MAZE_GBL_HATCHERY] FAIL " + label)

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
	var route: Dictionary = routes["gbl_hatchery"]
	check(route.get("name") == "GBL教孵化场"
		and route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("region") == "behemoth"
		and int(route.get("min_level", 0)) == 47 and int(route.get("monster_level", 0)) == 50,
		"GBL Hatchery is a hidden level 47 Behemoth native-maze route with basis level 50")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production GBL Hatchery export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/village/gbl/gbl_hatchery.dgn"
		and dungeon.get("sha256") == SOURCE_SHA,
		"GBL Hatchery export keeps the pinned DGN source identity")
	check(Array(dungeon.get("placements", [])).size() == 19
		and Dictionary(dungeon.get("rooms", {})).size() == 13
		and Dictionary(probe.data.get("images", {})).size() == 46,
		"GBL Hatchery export contains 19 placements, 13 MAPs and 46 source images")

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
	check(errors.is_empty() and warnings.size() == 85 and infos.size() == 52
		and unrendered == 82 and aa_warnings == 3 and scroll_absent == 39 and unhandled == 13,
		"GBL Hatchery preserves 82 unrendered objects, three AA cells, "
		+ "39 missing scrolls and 13 raw-tag MAPs")

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
		and starts == [Vector2i(3, 0)] and bosses == [Vector2i(2, 2)],
		"GBL Hatchery is a 4x4 source grid with start (3,0) and boss (2,2)")
	check(fixed_ids == [
		13027, 13028, 13029, 13030, 13031, 13032,
		13033, 13034, 13035, 13036, 13037,
	], "GBL Hatchery keeps eleven ordinary MAP specifications and selects endpoints by role")
	check(cells[Vector2i(3, 0)]["map_candidates"] == ["map/gbl3/g3(s)001.map"],
		"the start cell preserves the source start MAP")
	check(cells[Vector2i(2, 2)]["map_candidates"] == [
		"map/gbl3/g3(b)001.map",
		"map/gbl3/g3(n)002.map",
		"map/gbl3/g3(n)010.map",
	], "the boss cell preserves one source boss MAP and two normal candidates")

	var maze_blocks := 0
	var boss_specs := 0
	var boss_map = null
	var seal_id = null
	var seal_pos = null
	var event_monster = null
	var hell_value = null
	var special_items = null
	for span: Dictionary in dungeon.get("raw", []):
		var tag := String(span.get("tag", ""))
		var values: Array = span.get("values", [])
		if tag == "[maze info]":maze_blocks += 1
		if tag == "[boss map specification]":boss_specs += 1
		if tag == "[boss map]":boss_map = values
		if tag == "[seal door map index]":seal_id = values
		if tag == "[seal door pos]":seal_pos = values
		if tag == "[event monster]":event_monster = values
		if tag == "[hell dungeon]":hell_value = values
		if tag == "[special passive object item]":special_items = values
	check(maze_blocks == 1 and boss_specs == 0 and boss_map != null
		and [int(boss_map[0][2]), int(boss_map[1][2])] == [2, 2],
		"GBL Hatchery consumes one maze with an explicit boss-cell MAP")
	check(event_monster != null and int(event_monster[1][2]) == 10000
		and int(event_monster[2][2]) == 62502
		and seal_id != null and int(seal_id[0][2]) == 60042
		and seal_pos != null and [int(seal_pos[0][2]), int(seal_pos[1][2])] == [1, 1]
		and hell_value != null and int(hell_value[0][2]) == 1,
		"event monster 62502, seal door 60042 at (1,1) and hell mode remain preserved raw")
	check(special_items != null and int(special_items[0][2]) == 0
		and int(special_items[1][2]) == -1 and int(special_items[2][2]) == 3
		and [int(special_items[9][2]), int(special_items[10][2]), int(special_items[11][2])]
			== [1, -1, 0],
		"GBL Hatchery preserves its two source item groups and empty trailing group")

	var fixed_maze := NativeMaze.new()
	check(fixed_maze.start(probe.data, SourceRolls.new([0, 0, 0]), route.get("source", {})),
		"native maze starts the sole GBL Hatchery layout")
	check(fixed_maze.room_count() == 13,
		"GBL Hatchery reaches all thirteen connected cells")
	var selected_ids: Array[int] = [int(fixed_maze.current_room().get("source_map_id", 0))]
	var moves := ["left", "left", "down", "down", "right"]
	for step in moves.size():
		var current: Vector2i = fixed_maze.current_room().get("cell", Vector2i(-1, -1))
		var cleared: Dictionary = fixed_maze.clear_room(current, 0)
		var moved: Dictionary = fixed_maze.move(moves[step])
		check(not cleared.is_empty() and not moved.is_empty(),
			"GBL Hatchery clears and traverses source step %d" % step)
		selected_ids.append(int(moved.get("source_map_id", 0)))
	check(selected_ids == ROUTE_MAP_IDS,
		"GBL Hatchery shortest boss route selects MAPs 13026..13029,13032,13038")
	var final_clear: Dictionary = fixed_maze.clear_room(Vector2i(2, 2), 0)
	check(bool(final_clear.get("boss", false)) and bool(final_clear.get("final_room", false)),
		"the selected 13038 room is the sole boss and final room")

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
	check(source_monsters.size() == 7 and source_monster_count == 114 and source_boss_rows == 1,
		"GBL Hatchery has 114 direct placements, seven MOBs and one boss row")
	check(source_monster_counts == {
		"monster/newmonsters/gbl/combinetentacle/combinetentacle.mob": 33,
		"monster/newmonsters/aradman/gblrebirtharadman/gblrebirtharadman.mob": 28,
		"monster/newmonsters/gbl/thrower/thrower.mob": 27,
		"monster/newmonsters/goblin/tentaclerider/tentaclerider.mob": 22,
		"monster/newmonsters/gbl/gbltentaclenamed/gbltentaclenamed.mob": 2,
		"monster/newmonsters/gbl/cocoon/cocoon.mob": 1,
		"monster/newmonsters/gbl/vangelis/vangelis.mob": 1,
	}, "GBL Hatchery keeps the exact source monster counts")
	check(source_object_count == 150 and source_breakable_candidates == 65
		and source_runtime_breakables == 57 and source_traps == 1
		and source_static == 84,
		"GBL Hatchery has 150 objects: 57 executable breakables, "
		+ "8 breakable gaps, one trap and 84 static objects "
		+ "(objects=%d candidates=%d runtime=%d traps=%d static=%d)"
		% [source_object_count, source_breakable_candidates, source_runtime_breakables,
			source_traps, source_static])

	var banks := {
		"monster/newmonsters/gbl/combinetentacle/combinetentacle.mob": ["newmonsters_gbl_combinetentacle_combinetentacle", 2],
		"monster/newmonsters/aradman/gblrebirtharadman/gblrebirtharadman.mob": ["newmonsters_aradman_gblrebirtharadman_gblrebirtharadman", 2],
		"monster/newmonsters/gbl/thrower/thrower.mob": ["newmonsters_gbl_thrower_thrower", 4],
		"monster/newmonsters/goblin/tentaclerider/tentaclerider.mob": ["newmonsters_goblin_tentaclerider_tentaclerider", 2],
		"monster/newmonsters/gbl/gbltentaclenamed/gbltentaclenamed.mob": ["newmonsters_gbl_gbltentaclenamed_gbltentaclenamed", 3],
		"monster/newmonsters/gbl/cocoon/cocoon.mob": ["newmonsters_gbl_cocoon_cocoon", 6],
		"monster/newmonsters/gbl/vangelis/vangelis.mob": ["newmonsters_gbl_vangelis_vangelis", 6],
	}
	for mob: String in banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		check(String(definition.get("bank", "")) == banks[mob][0]
			and game.combat_assets.get("monsters", {}).has(banks[mob][0]),
			"GBL Hatchery source bank is compiled: " + mob)
		check(Array(definition.get("moves", [])).size() == int(banks[mob][1]),
			"GBL Hatchery attack slots compile for %s (moves=%d expected=%d)"
			% [mob, Array(definition.get("moves", [])).size(), int(banks[mob][1])])

	var content: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://assets_local/content/combat_content.json"))
	var vangelis: Dictionary = content["records"][
		"monster/newmonsters/gbl/vangelis/vangelis.mob"]["decoded"]
	var vangelis_infos: Array = vangelis.get("attack_infos", [])
	check(vangelis_infos.size() == 6 and vangelis_infos[2] == ""
		and vangelis_infos[3] == "",
		"Vangelis keeps summon slots 2 and 3 without invented direct ATK files")
	check(not NativeBoxLoot.required(dungeon),
		"GBL Hatchery source special pots have no [item] draw and do not invent box loot")
	check(NativeJarTraps.ready(game.combat_assets), "shared source trap assets resolve")

	var flow := FlowSession.new()
	flow.profile["level"] = 50
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "gbl_hatchery"})["ok"],
		"flow departs the hidden GBL Hatchery route")
	route = flow.active_dungeon_route()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live GBL Hatchery run selects the sole layout")
	check(session._validate_native_maze(probe, live_maze),
		"GBL Hatchery room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "gbl_hatchery", "route": route,
		"room_id": "gbl_hatchery:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source GBL Hatchery room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 13
			and game.view_snapshot()["hud"]["route"].size() == 13,
			"both public battle views report the complete GBL Hatchery graph")
		check(game.view.audio.has_dungeon_music("gbl_hatchery")
			and String(game.view.audio.music.stream.resource_path).ends_with("gblarad_hatchery.ogg"),
			"GBL Hatchery starts with the original M_GBLARAD_HATCHERY track")
		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts,
			"GBL Hatchery start room spawns its exact source monster lineup")

		var interactive_props := 0
		var box_props := 0
		var jar_traps := 0
		var unknown_ids: Array[int] = []
		var all_gaps := {}
		for path: String in dungeon.get("rooms", {}).keys():
			var room: Dictionary = probe.room(path)
			var room_props: Array = game.build_props(room)
			interactive_props += room_props.size()
			for prop: Dictionary in room_props:
				if not (prop.get("box_items", []) as Array).is_empty():box_props += 1
				if not (prop.get("jar_trap", {}) as Dictionary).is_empty():jar_traps += 1
				for source_id in prop.get("unresolved_trap_ids", []):
					if int(source_id) not in unknown_ids:unknown_ids.append(int(source_id))
				check(not String(prop.get("source_path", "")).contains("/trap/"),
					"trap trigger is not materialised as a contact hazard")
			merge_gaps(all_gaps, game.native_object_gaps)
		unknown_ids.sort()
		check(interactive_props == 57,
			"57 source pots, chests and altar breakables build exactly once across thirteen MAPs")
		check(box_props == 0 and jar_traps == 2 and unknown_ids.is_empty(),
			"two source 2210 pot payloads compile without box props or unresolved trap IDs")
		if box_props != 0 or jar_traps != 2 or not unknown_ids.is_empty():
			push_error("[NATIVE_MAZE_GBL_HATCHERY] DETAIL boxes=%d jars=%d unknown=%s"
				% [box_props, jar_traps, str(unknown_ids)])
		for path in [
			"passiveobject/actionobject/breakableobject/altar2.obj",
			"passiveobject/actionobject/breakableobject/altar3.obj",
		]:
			check(all_gaps.get(path, []) == ["native_breakable_source"],
				"GBL Hatchery action altar remains an explicit source-contract gap: " + path)
		check(all_gaps.get("passiveobject/actionobject/common/gblhelipad.obj", [])
			== ["native_action_object_behavior", "native_action_object_visual"],
			"motionless GBL helipad remains explicit runtime behaviour and visual gaps")
		check(all_gaps.get("passiveobject/actionobject/trap/bossaltar.obj", [])
			== ["native_object_trigger"],
			"boss altar remains a source trigger gap instead of a contact hazard")
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_GBL_HATCHERY] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
