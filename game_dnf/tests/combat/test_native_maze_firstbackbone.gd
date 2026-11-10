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
		push_error("[NATIVE_MAZE_FIRSTBACKBONE] FAIL " + label)

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
	var route: Dictionary = routes["firstbackbone"]
	check(route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("region") == "behemoth"
		and int(route.get("min_level", 0)) == 32 and int(route.get("monster_level", 0)) == 35,
		"first spine is a hidden level 32 Behemoth native-maze route with source basis level 35")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production first spine export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/act3/1stbackbone.dgn"
		and dungeon.get("sha256") == "005a1cba836b48bd1f56f2a6a6dd5e72ffa91786c701cc0b2a6791027176da85",
		"first spine export keeps the pinned DGN source identity")
	check(Array(dungeon.get("placements", [])).size() == 28
		and Dictionary(dungeon.get("rooms", {})).size() == 20
		and Dictionary(probe.data.get("images", {})).size() == 50,
		"first spine export contains 28 greed-eligible placements, 20 MAPs and 50 source images")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	var errors: Array = diagnostics.filter(func(row): return row.get("level") == "error")
	var warnings: Array = diagnostics.filter(func(row): return row.get("level") == "warning")
	var infos: Array = diagnostics.filter(func(row): return row.get("level") == "info")
	var aa_warnings := 0
	for row: Dictionary in warnings:
		if row.get("code") == "cell_without_map" and String(row.get("detail", "")).contains(" code AA"):
			aa_warnings += 1
	check(errors.is_empty() and warnings.size() == 6 and aa_warnings == 6 and infos.size() == 20,
		"first spine preserves six empty AA cells and 20 raw MAP tag reports")

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
	check(cells.size() == 16 and starts.size() == 1 and bosses.size() == 2,
		"first spine 4x4 grid exposes one start and two boss candidates")
	check(maze_blocks == 2 and quest_connections == 1 and spec_count == 4,
		"first spine consumes only the first layout and preserves quest 4329 selector raw")

	for boss_cell in bosses:
		var pools: Dictionary = maze._read_pools(dungeon, cells, starts[0], boss_cell)
		check(pools.size() == 10,
			"start/boss %s/%s reaches all 10 connected cells (pools=%d error=%s)"
			% [starts[0], boss_cell, pools.size(), maze.last_error])
	check(maze.start(probe.data, SourceRolls.new([0, 0, 0, 0]), route.get("source", {})),
		"generic native maze accepts first spine ordinary layout")
	check(maze.room_count() == 10 and maze.required_map_paths().size() == 15,
		"first spine preflight exposes 10 rooms across 15 eligible first-visit MAPs "
		+ "(rooms=%d maps=%d)" % [maze.room_count(), maze.required_map_paths().size()])
	check(NativeBoxLoot.ready(dungeon), "first spine item groups and source art resolve")
	check(NativeJarTraps.ready(game.combat_assets), "shared source jar trap assets resolve")

	var source_monsters := {}
	var source_monster_count := 0
	var source_boss_rows := 0
	var source_pot_monster_rows := 0
	var source_pot_mobs := {}
	var source_object_count := 0
	var source_breakables := 0
	var source_triggers := 0
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
				check(monster.get("mob") == "monster/starfish/starfishking.mob",
					"every source boss row is the Starfish King")
		for item: Dictionary in room.get("objects", []):
			source_object_count += 1
			if NativeBoxLoot.draw_count(item) > 0:
				source_box_objects += 1
			for child: Dictionary in NativePotMonsters.rows(item):
				source_pot_monster_rows += 1
				source_pot_mobs[String(child.get("mob", ""))] = true
			var path := String(item.get("obj", "")).to_lower()
			if NativeBreakable.supports(item):
				source_breakables += 1
			elif item.get("source_tag") == "[special passive object]":
				source_specials += 1
			elif path.contains("/trap/"):
				source_triggers += 1
			else:
				source_static += 1
	check(source_monsters.size() == 8 and source_monster_count == 176 and source_boss_rows == 3,
		"first spine source has 176 direct placements, 8 MOBs and three boss rows")
	check(source_object_count == 341 and source_breakables == 118
		and source_specials == 12 and source_triggers == 36 and source_static == 175
		and source_box_objects == 42,
		"first spine source has 341 objects: 118 breakables, 12 special triggers, "
		+ "36 ordinary triggers, 175 static obstacles and 42 item payload rows "
		+ "(objects=%d breakables=%d special=%d triggers=%d static=%d boxes=%d)"
		% [source_object_count, source_breakables, source_specials,
			source_triggers, source_static, source_box_objects])
	check(source_pot_monster_rows == 20 and source_pot_mobs.size() == 4,
		"first spine special objects retain 20 source monster payload rows across 4 MOBs")
	for mob: String in source_monsters:
		check(not game.table.monster_by_mob(mob).is_empty(),
			"direct source MOB has runtime content: " + mob)
	for mob: String in source_pot_mobs:
		check(not game.table.monster_by_mob(mob).is_empty(),
			"special-object monster payload has runtime content: " + mob)

	var king_kind: String = game.table.monster_by_mob("monster/starfish/starfishking.mob")
	var king: Dictionary = game.table.monsters.get(king_kind, {})
	check(String(king.get("bank", "")) == "starfish_starfishking"
		and game.combat_assets.get("monsters", {}).has("starfish_starfishking")
		and Array(king.get("moves", [])).size() == 6,
		"Starfish King compiles six attack slots and its source atlas bank")
	for move: Dictionary in Array(king.get("moves", [])):
		if not move.has("atk_path"):continue
		check(not game.table.atk(String(move["atk_path"])).is_empty()
			and not Array(move.get("timeline", [])).is_empty(),
			"Starfish King attack motion and ATK compile together")

	var flow := FlowSession.new()
	flow.profile["level"] = 35
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "firstbackbone"})["ok"],
		"flow departs the hidden first spine route")
	route = flow.active_dungeon_route()
	NativePotMonsters.reset_catalog()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live first spine run selects the ordinary layout")
	NativePotMonsters.prepare_catalog(dungeon, SourceRolls.new([0, 0, 0, 0]))
	check(session._validate_native_maze(probe, live_maze),
		"first spine room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "firstbackbone", "route": route,
		"room_id": "firstbackbone:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source first spine room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 10
			and game.view_snapshot()["hud"]["route"].size() == 10,
			"both public battle views report the complete first spine graph")
		check(game.view.audio.has_dungeon_music("firstbackbone")
			and String(game.view.audio.music.stream.resource_path).ends_with("1st_spine.ogg"),
			"first spine starts with the original M_1ST_SPINE track")

		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts,
			"first spine start room spawns its exact source monster lineup")

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
		check(interactive_props == 118,
			"all 118 source breakables build exactly once across 20 MAPs")
		check(box_props > 0 and box_props <= source_box_objects,
			"first spine prepares source item-box draws (prepared=%d source=%d)"
			% [box_props, source_box_objects])
		check(known_jar_ids.is_empty(),
			"no fully source-complete jar branch executes when every known trap object mixes unknown IDs")
		check(unknown_ids == [1025, 1072, 2000, 2001, 2010, 2011, 2101, 2110, 2111,
			2201, 2211, 2311, 2401, 2411, 2412, 2511, 2512, 2601, 2611, 2612, 48020],
			"unsupported first spine trap IDs remain explicit: " + str(unknown_ids))
		check(all_gaps.get("passiveobject/mapobject/trap/starfishegg.obj", []) == ["native_object_trigger"],
			"starfish egg remains an explicit trigger gap")
		check(all_gaps.get("passiveobject/mapobject/trap/sweepinglegoflotustrigger.obj", [])
			== ["native_special_object", "native_object_trigger"],
			"sweeping Lotus trigger remains an explicit special/trigger gap")
		check(all_gaps.get("passiveobject/mapobject/trap/gravitychanger.obj", []) == ["native_special_object"],
			"gravity changer remains an explicit special-object gap")
		check(all_gaps.get("passiveobject/mapobject/breakableobject/collectionboxforlotus.obj", [])
			== [1025, 2412],
			"Lotus collection boxes retain their mixed unresolved trap IDs")
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_FIRSTBACKBONE] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
