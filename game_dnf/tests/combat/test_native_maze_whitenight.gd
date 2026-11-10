extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const FlowSession = preload("res://flow/session.gd")
const NativeMaze = preload("res://combat/data/native_maze.gd")
const NativeBreakable = preload("res://combat/resolve/native_breakable.gd")
const NativeBoxLoot = preload("res://loot/native_box.gd")
const NativeJarTraps = preload("res://combat/resolve/native_jar_traps.gd")
const NativePotMonsters = preload("res://combat/resolve/native_pot_monsters.gd")
const DetRng = preload("res://core/det_rng.gd")
const EXPORT := "res://assets_local/native_maps/whitenight_v1/map_export.json"
const UNKNOWN_TRAPS := [
	2000, 2001, 2010, 2011, 2100, 2101, 2111, 2211, 2301,
	2311, 2401, 2411, 2501, 2511, 2601, 2602, 2611, 48020,
]

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
		push_error("[NATIVE_MAZE_WHITENIGHT] FAIL " + label)

func run() -> void:
	game = session.mount(root)
	game.set_process(false)
	game.set_physics_process(false)
	var routes: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/dungeons.json"))["dungeons"]
	var route: Dictionary = routes["whitenight"]
	check(route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and int(route.get("min_level", 0)) == 30 and int(route.get("monster_level", 0)) == 33,
		"whitenight is a hidden level 30 native-maze route with source basis level 33")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production whitenight export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/act3/whitenight.dgn"
		and dungeon.get("sha256") == "a50170f3734e0a88917e27a8b741834bb68e19fcd99ec25280228c8703f94a71",
		"whitenight export keeps the pinned DGN source identity")
	check(Array(dungeon.get("placements", [])).size() == 48
		and Dictionary(dungeon.get("rooms", {})).size() == 14
		and Dictionary(probe.data.get("images", {})).size() == 57,
		"whitenight export contains 48 placements, 14 MAPs and 57 source images")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	var errors: Array = diagnostics.filter(func(row): return row.get("level") == "error")
	var warnings: Array = diagnostics.filter(func(row): return row.get("level") == "warning")
	var aa_warnings := 0
	for row: Dictionary in warnings:
		if row.get("code") == "cell_without_map" and String(row.get("detail", "")).contains(" code AA"):
			aa_warnings += 1
	check(errors.is_empty() and warnings.size() == 9 and aa_warnings == 9,
		"all nine source warnings are empty AA cells")

	var maze := NativeMaze.new()
	var size: Vector2i = maze._point(dungeon.get("size"))
	var cells: Dictionary = maze._read_cells(dungeon.get("cells"), size)
	var starts: Array = maze._read_endpoint_cells(dungeon.get("start_map_raw"), cells, "start_candidate")
	var bosses: Array = maze._read_endpoint_cells(dungeon.get("boss_map_raw"), cells, "boss_candidate")
	var specs: Dictionary = maze._read_specifications(dungeon.get("raw"), cells)
	var spec_count := 0
	for rows: Dictionary in [specs.get("normal", {}), specs.get("boss", {})]:
		spec_count += rows.size()
	check(cells.size() == 21 and starts.size() == 1 and bosses.size() == 2,
		"whitenight 3x7 grid exposes one start and two boss choices")
	check(spec_count == 9, "whitenight preserves all nine fixed MAP specifications")

	for start_cell in starts:
		for boss_cell in bosses:
			var pools: Dictionary = maze._read_pools(dungeon, cells, start_cell, boss_cell)
			check(pools.size() == 12,
				"start/boss %s/%s reaches all 12 connected cells (pools=%d error=%s)"
				% [start_cell, boss_cell, pools.size(), maze.last_error])
	check(maze.start(probe.data, SourceRolls.new([0, 0, 0]), route.get("source", {})),
		"generic native maze accepts whitenight source")
	check(maze.room_count() == 12 and maze.required_map_paths().size() == 14,
		"whitenight preflight exposes 12 rooms across all 14 source MAPs "
		+ "(rooms=%d maps=%d)" % [maze.room_count(), maze.required_map_paths().size()])
	check(NativeBoxLoot.ready(dungeon), "whitenight item groups and source art resolve")
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
	check(source_monsters.size() == 8 and source_monster_count == 144,
		"whitenight source has 144 direct placements across 8 MOBs")
	check(source_object_count == 306 and source_breakables == 75
		and source_triggers == 53,
		"whitenight source has 306 objects: 75 breakables and 53 behaviour triggers "
		+ "(objects=%d breakables=%d triggers=%d)" % [
			source_object_count, source_breakables, source_triggers])
	check(source_monster_pots == 3,
		"whitenight source has three [monster] pot payload objects")
	for mob: String in source_monsters:
		check(not game.table.monster_by_mob(mob).is_empty(),
			"direct source MOB has runtime content: " + mob)

	var flow := FlowSession.new()
	flow.profile["level"] = 30
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "whitenight"})["ok"],
		"flow departs the hidden whitenight route")
	route = flow.active_dungeon_route()
	NativePotMonsters.reset_catalog()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live whitenight run selects a source maze")
	NativePotMonsters.prepare_catalog(dungeon, SourceRolls.new([0, 0, 0, 0, 0, 0]))
	check(session._validate_native_maze(probe, live_maze),
		"whitenight room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "whitenight", "route": route,
		"room_id": "whitenight:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source whitenight room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 12
			and game.view_snapshot()["hud"]["route"].size() == 12,
			"both public battle views report the complete whitenight graph")
		check(game.view.audio.has_dungeon_music("whitenight")
			and String(game.view.audio.music.stream.resource_path).ends_with("whitenight.ogg"),
			"whitenight starts with the original M_WHITENIGHT track")

		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts,
			"whitenight start room spawns its exact source monster lineup")

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
				check(not source_path.contains("/trap/"),
					"trap trigger is not materialised as a contact hazard: " + source_path)
			for gap_path: String in game.native_object_gaps:
				if gap_path.contains("/trap/"):
					trigger_paths[gap_path] = true
		unknown_ids.sort()
		check(interactive_props == 75,
			"all 75 source breakables build exactly once across 14 MAPs")
		check(box_props >= 10 and pot_props >= 1,
			"whitenight prepares original item boxes and monster pots "
			+ "(boxes=%d pots=%d)" % [box_props, pot_props])
		check(known_jar_ids.keys().all(func(id): return int(id) in [2210, 40002]),
			"only source-verified jar IDs execute")
		check(unknown_ids == UNKNOWN_TRAPS,
			"all 18 unsupported trap IDs are recorded without execution: " + str(unknown_ids))
		check(trigger_paths.has("passiveobject/mapobject/trap/bellforzealots.obj")
			and trigger_paths.has("passiveobject/mapobject/trap/hallucinationflowerleft.obj")
			and trigger_paths.has("passiveobject/mapobject/trap/hallucinationflowerright.obj")
			and trigger_paths.has("passiveobject/mapobject/trap/vehemoswen.obj"),
			"bell, hallucination flowers and VEHemoswen remain explicit runtime gaps")
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_WHITENIGHT] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
