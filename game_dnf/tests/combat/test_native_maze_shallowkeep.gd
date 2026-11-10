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
		push_error("[NATIVE_MAZE_SHALLOWKEEP] FAIL " + label)

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
	var route: Dictionary = routes["shallowkeep"]
	check(route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("region") == "noierfera"
		and int(route.get("min_level", 0)) == 37 and int(route.get("monster_level", 0)) == 40,
		"shallow keep is a hidden level 37 Noierfera native-maze route with source basis level 40")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production shallow keep export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/act4/shallowkeep.dgn"
		and dungeon.get("sha256") == "652be6d9a2d862210a92c767e5cb7c3cbb4d3f8e887868e0e98cc8fa9f9ab833",
		"shallow keep export keeps the pinned DGN source identity")
	check(Array(dungeon.get("placements", [])).size() == 88
		and Dictionary(dungeon.get("rooms", {})).size() == 38
		and Dictionary(probe.data.get("images", {})).size() == 81,
		"shallow keep export contains 88 placements, 38 MAPs and 81 source images")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	var errors: Array = diagnostics.filter(func(row): return row.get("level") == "error")
	var warnings: Array = diagnostics.filter(func(row): return row.get("level") == "warning")
	var infos: Array = diagnostics.filter(func(row): return row.get("level") == "info")
	var aa_warnings := 0
	for row: Dictionary in warnings:
		if row.get("code") == "cell_without_map" and String(row.get("detail", "")).contains(" code AA"):
			aa_warnings += 1
	check(errors.is_empty() and warnings.size() == 2 and aa_warnings == 2 and infos.size() == 38,
		"shallow keep preserves two empty AA cells and 38 raw MAP tag reports")

	var maze := NativeMaze.new()
	var size: Vector2i = maze._point(dungeon.get("size"))
	var cells: Dictionary = maze._read_cells(dungeon.get("cells"), size)
	var starts: Array = maze._read_endpoint_cells(dungeon.get("start_map_raw"), cells, "start_candidate")
	var bosses: Array = maze._read_endpoint_cells(dungeon.get("boss_map_raw"), cells, "boss_candidate")
	var specs: Dictionary = maze._read_specifications(dungeon.get("raw"), cells)
	var spec_count := 0
	for rows: Dictionary in [specs.get("normal", {}), specs.get("boss", {})]:
		spec_count += rows.size()
	var maze_blocks := 0
	var quest_connections := 0
	for span: Dictionary in dungeon.get("raw", []):
		if span.get("tag") == "[maze info]":maze_blocks += 1
		if span.get("tag") == "[quest connection]":quest_connections += 1
	check(cells.size() == 20 and starts.size() == 2 and bosses.size() == 2,
		"shallow keep 4x5 grid exposes two starts and two bosses")
	check(maze_blocks == 2 and quest_connections == 1 and spec_count == 4,
		"shallow keep selects the first ordinary layout and preserves the quest/hell selector raw")

	for start_cell in starts:
		for boss_cell in bosses:
			var pools: Dictionary = maze._read_pools(dungeon, cells, start_cell, boss_cell)
			check(pools.size() == 18,
				"start/boss %s/%s reaches all 18 connected cells (pools=%d error=%s)"
				% [start_cell, boss_cell, pools.size(), maze.last_error])
	check(maze.start(probe.data, SourceRolls.new([0, 0, 0, 0]), route.get("source", {})),
		"generic native maze accepts shallow keep ordinary layout")
	check(maze.room_count() == 18,
		"shallow keep preflight exposes 18 rooms (rooms=%d maps=%d)"
		% [maze.room_count(), maze.required_map_paths().size()])
	check(NativeBoxLoot.ready(dungeon), "shallow keep item groups and source art resolve")
	check(NativeJarTraps.ready(game.combat_assets), "shared source jar trap assets resolve")

	var source_monsters := {}
	var source_monster_count := 0
	var source_boss_rows := 0
	var source_object_count := 0
	var source_breakables := 0
	var source_specials := 0
	var source_static := 0
	var source_box_objects := 0
	for room: Dictionary in dungeon.get("rooms", {}).values():
		for monster: Dictionary in room.get("monsters", []):
			source_monsters[String(monster.get("mob", ""))] = true
			source_monster_count += 1
			var raw: Array = monster.get("raw", [])
			if not raw.is_empty() and raw[-1] == "[boss]":
				source_boss_rows += 1
		for item: Dictionary in room.get("objects", []):
			source_object_count += 1
			if NativeBoxLoot.draw_count(item) > 0:
				source_box_objects += 1
			var path := String(item.get("obj", "")).to_lower()
			if NativeBreakable.supports(item):
				source_breakables += 1
			elif item.get("source_tag") == "[special passive object]":
				source_specials += 1
			elif path.contains("/trap/"):
				source_specials += 1
			else:
				source_static += 1
	check(source_monsters.size() == 6 and source_monster_count == 344 and source_boss_rows == 2,
		"shallow keep source has 344 direct placements, 6 MOBs and two boss rows")
	check(source_object_count == 513 and source_breakables == 322
		and source_specials == 2 and source_static == 189 and source_box_objects == 138,
		"shallow keep source has 513 objects: 322 breakables, 2 freezing-luna specials, "
		+ "189 static obstacles and 138 item payload rows "
		+ "(objects=%d breakables=%d special=%d static=%d boxes=%d)"
		% [source_object_count, source_breakables, source_specials,
			source_static, source_box_objects])
	for mob: String in source_monsters:
		check(not game.table.monster_by_mob(mob).is_empty(),
			"direct source MOB has runtime content: " + mob)

	var flow := FlowSession.new()
	flow.profile["level"] = 40
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "shallowkeep"})["ok"],
		"flow departs the hidden shallow keep route")
	route = flow.active_dungeon_route()
	NativePotMonsters.reset_catalog()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live shallow keep run selects the ordinary layout")
	NativePotMonsters.prepare_catalog(dungeon, SourceRolls.new([0, 0, 0, 0]))
	check(session._validate_native_maze(probe, live_maze),
		"shallow keep room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "shallowkeep", "route": route,
		"room_id": "shallowkeep:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source shallow keep room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 18
			and game.view_snapshot()["hud"]["route"].size() == 18,
			"both public battle views report the complete shallow keep graph")
		check(game.view.audio.has_dungeon_music("shallowkeep")
			and String(game.view.audio.music.stream.resource_path).ends_with("underfoot.ogg"),
			"shallow keep starts with the original M_UNDERFOOT track")

		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts,
			"shallow keep start room spawns its exact source monster lineup")

		var interactive_props := 0
		var box_props := 0
		var known_jar_ids := {}
		var unknown_ids: Array[int] = []
		var all_gaps := {}
		for path: String in dungeon.get("rooms", {}).keys():
			var room: Dictionary = probe.room(path)
			var room_props: Array = game.build_props(room)
			interactive_props += room_props.size()
			for prop: Dictionary in room_props:
				if not (prop.get("box_items", []) as Array).is_empty():
					box_props += 1
				var selection: Dictionary = prop.get("jar_trap", {})
				if not selection.is_empty():
					known_jar_ids[int(selection["id"])] = true
				for source_id in prop.get("unresolved_trap_ids", []):
					if int(source_id) not in unknown_ids:
						unknown_ids.append(int(source_id))
			merge_gaps(all_gaps, game.native_object_gaps)
		unknown_ids.sort()
		check(interactive_props == 322,
			"all 322 source breakables build exactly once across 38 MAPs")
		check(box_props > 0 and box_props <= source_box_objects,
			"shallow keep prepares source item-box draws (prepared=%d source=%d)"
			% [box_props, source_box_objects])
		check(known_jar_ids.keys().all(func(id): return int(id) in [2200, 2210, 48003]),
			"only source-complete jar branches execute: " + str(known_jar_ids))
		check(unknown_ids == [2000, 2010, 2011, 2012, 2100, 2110, 2111, 2112, 2211, 2212,
			2300, 2310, 2311, 2400, 2411, 2500, 2511, 2600, 2611, 48022, 48023],
			"unsupported shallow keep trap IDs are recorded without execution: " + str(unknown_ids))
		check(all_gaps.get("passiveobject/mapobject/trap/shallowkeepfreezingluna.obj", [])
			== ["native_special_object"],
			"freezing Luna remains an explicit special-object gap")
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_SHALLOWKEEP] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
