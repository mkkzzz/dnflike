extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const FlowSession = preload("res://flow/session.gd")
const NativeMaze = preload("res://combat/data/native_maze.gd")
const NativeBreakable = preload("res://combat/resolve/native_breakable.gd")
const NativeBoxLoot = preload("res://loot/native_box.gd")
const NativeJarTraps = preload("res://combat/resolve/native_jar_traps.gd")
const NativePotMonsters = preload("res://combat/resolve/native_pot_monsters.gd")
const DetRng = preload("res://core/det_rng.gd")
const EXPORT := "res://assets_local/native_maps/darkhell_v1/map_export.json"
const UNKNOWN_TRAPS := [2000, 2010, 2100, 2211, 2510, 2601, 2610, 48019, 48022]

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
		push_error("[NATIVE_MAZE_DARKHELL] FAIL " + label)

func run() -> void:
	game = session.mount(root)
	game.set_process(false)
	game.set_physics_process(false)
	var routes: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/dungeons.json"))["dungeons"]
	var route: Dictionary = routes["darkhell"]
	check(route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and int(route.get("min_level", 0)) == 29 and int(route.get("monster_level", 0)) == 32,
		"darkhell is a hidden level 29 native-maze route with source basis level 32")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production darkhell export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/act3/darkhell.dgn"
		and dungeon.get("sha256") == "fd954e4d7abc752b5ac7b6048a4099fa7bbfc7e752e3cefa37ecb7fe18639974",
		"darkhell export keeps the pinned DGN source identity")
	check(Array(dungeon.get("placements", [])).size() == 52
		and Dictionary(dungeon.get("rooms", {})).size() == 24,
		"darkhell export contains 52 placements across 24 source MAPs")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	var errors: Array = diagnostics.filter(func(row): return row.get("level") == "error")
	var warnings: Array = diagnostics.filter(func(row): return row.get("level") == "warning")
	var aa_warnings := 0
	for row: Dictionary in warnings:
		if row.get("code") == "cell_without_map" and String(row.get("detail", "")).contains(" code AA"):
			aa_warnings += 1
	check(errors.is_empty() and warnings.size() == 16 and aa_warnings == 16,
		"all 16 source warnings are empty AA cells")

	var maze := NativeMaze.new()
	var size: Vector2i = maze._point(dungeon.get("size"))
	var cells: Dictionary = maze._read_cells(dungeon.get("cells"), size)
	var starts: Array = maze._read_endpoint_cells(dungeon.get("start_map_raw"), cells, "start_candidate")
	var bosses: Array = maze._read_endpoint_cells(dungeon.get("boss_map_raw"), cells, "boss_candidate")
	var specs: Dictionary = maze._read_specifications(dungeon.get("raw"), cells)
	var spec_count := 0
	for rows: Dictionary in [specs.get("normal", {}), specs.get("boss", {})]:
		spec_count += rows.size()
	check(cells.size() == 30 and starts.size() == 2 and bosses.size() == 2,
		"darkhell source grid exposes 30 cells and both start/boss choices")
	check(spec_count == 4, "darkhell preserves all four fixed MAP specifications")

	for start_cell in starts:
		for boss_cell in bosses:
			var pools: Dictionary = maze._read_pools(dungeon, cells, start_cell, boss_cell)
			check(pools.size() == 14,
				"start/boss %s/%s reaches all 14 connected cells (pools=%d error=%s)"
				% [start_cell, boss_cell, pools.size(), maze.last_error])
	var start_rolls := SourceRolls.new([0, 0, 0])
	check(maze.start(probe.data, start_rolls, route.get("source", {})),
		"generic native maze accepts darkhell source")
	check(maze.room_count() == 14 and maze.required_map_paths().size() == 17,
		"darkhell preflight exposes 14 rooms across 17 eligible first-visit MAPs "
		+ "(rooms=%d maps=%d)" % [maze.room_count(), maze.required_map_paths().size()])
	check(NativeBoxLoot.ready(dungeon), "darkhell item groups and source art resolve")
	check(NativeJarTraps.ready(game.combat_assets), "shared source jar trap assets resolve")

	var source_monsters := {}
	var source_monster_count := 0
	var source_object_count := 0
	var source_breakables := 0
	var source_triggers := 0
	var source_monster_pots := 0
	for room: Dictionary in dungeon.get("rooms", {}).values():
		for monster: Dictionary in room.get("monsters", []):
			source_monsters[String(monster.get("mob", ""))] = true
			source_monster_count += 1
		for item: Dictionary in room.get("objects", []):
			source_object_count += 1
			var path := String(item.get("obj", "")).to_lower()
			if NativeBreakable.supports(item):
				source_breakables += 1
				if not NativePotMonsters.rows(item).is_empty():
					source_monster_pots += 1
			elif path.contains("/trap/"):
				source_triggers += 1
	check(source_monsters.size() == 9 and source_monster_count == 240,
		"darkhell source has 240 direct placements across 9 MOBs")
	check(source_object_count == 505 and source_breakables == 134 and source_triggers == 89,
		"darkhell source has 505 objects: 134 breakables and 89 behaviour triggers "
		+ "(objects=%d breakables=%d triggers=%d)" % [
			source_object_count, source_breakables, source_triggers])
	check(source_monster_pots == 11,
		"darkhell source has 11 [monster] pot payload objects")
	for mob: String in source_monsters:
		check(not game.table.monster_by_mob(mob).is_empty(),
			"direct source MOB has runtime content: " + mob)

	var flow := FlowSession.new()
	flow.profile["level"] = 29
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "darkhell"})["ok"],
		"flow departs the hidden darkhell route")
	route = flow.active_dungeon_route()
	NativePotMonsters.reset_catalog()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live darkhell run selects a source maze")
	NativePotMonsters.prepare_catalog(dungeon,
		DetRng.new(hash(String(flow.run["id"]) + ":pot-catalog")))
	check(session._validate_native_maze(probe, live_maze),
		"darkhell room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "darkhell", "route": route,
		"room_id": "darkhell:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source darkhell room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 14
			and game.view_snapshot()["hud"]["route"].size() == 14,
			"both public battle views report the complete darkhell graph")
		check(game.view.audio.has_dungeon_music("darkhell")
			and String(game.view.audio.music.stream.resource_path).ends_with("purgatory.ogg"),
			"darkhell starts with the original M_PURGATORY track")

		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts,
			"darkhell start room spawns its exact source monster lineup")

		var all_paths: Array[String] = []
		all_paths.assign(live_maze.required_map_paths())
		check(all_paths.size() == 17, "live darkhell run exposes its 17 eligible source MAPs")

		var interactive_props := 0
		var box_props := 0
		var pot_props := 0
		var known_jar_ids := {}
		var unknown_ids: Array[int] = []
		var trigger_paths := {}
		for path: String in dungeon.get("rooms", {}).keys():
			var room: Dictionary = probe.room(path)
			var room_props: Array = game.build_props(room)
			interactive_props += room_props.size()
			for prop: Dictionary in room_props:
				var source_path := String(prop.get("source_path", ""))
				if not (prop.get("box_items", []) as Array).is_empty():
					box_props += 1
				if not (prop.get("pot_monsters", []) as Array).is_empty():
					pot_props += 1
				var selection: Dictionary = prop.get("jar_trap", {})
				if not selection.is_empty():
					known_jar_ids[int(selection["id"])] = true
				for source_id in prop.get("unresolved_trap_ids", []):
					if int(source_id) not in unknown_ids:
						unknown_ids.append(int(source_id))
				check(not source_path.ends_with("droppingrocktrigger.obj")
					and not source_path.ends_with("entanglevinetrigger.obj"),
					"behaviour trigger is not materialised as a contact hazard: " + source_path)
			for gap_path: String in game.native_object_gaps:
				if gap_path.contains("/trap/"):
					trigger_paths[gap_path] = true
		unknown_ids.sort()
		check(interactive_props == 134,
			"all 134 source breakables build exactly once across active MAPs")
		check(box_props >= 10 and pot_props >= 1,
			"darkhell prepares original item boxes and monster pots "
			+ "(boxes=%d pots=%d)" % [box_props, pot_props])
		check(known_jar_ids.keys().all(func(id): return int(id) in [2200, 2210]),
			"only source-verified jar IDs execute")
		check(unknown_ids == UNKNOWN_TRAPS,
			"all nine unsupported trap IDs are recorded without execution: " + str(unknown_ids))
		check(trigger_paths.has("passiveobject/mapobject/trap/droppingrocktrigger.obj")
			and trigger_paths.has("passiveobject/mapobject/trap/entanglevinetrigger.obj"),
			"both darkhell behaviour triggers remain explicit runtime gaps")
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_DARKHELL] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
