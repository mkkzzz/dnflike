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
		push_error("[NATIVE_MAZE_MARPISSALAIR] FAIL " + label)

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
	var route: Dictionary = routes["marpissalair"]
	check(route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("region") == "noierfera"
		and int(route.get("min_level", 0)) == 38 and int(route.get("monster_level", 0)) == 41,
		"spider lair is a hidden level 38 Noierfera native-maze route with source basis level 41")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production spider lair export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/act4/marpissalair.dgn"
		and dungeon.get("sha256") == "10848752c082de15b0929fb171fc827165fe995009bff7ff5786658754a308c7",
		"spider lair export keeps the pinned DGN source identity")
	check(Array(dungeon.get("placements", [])).size() == 77
		and Dictionary(dungeon.get("rooms", {})).size() == 30
		and Dictionary(probe.data.get("images", {})).size() == 76,
		"spider lair export contains 77 greed-eligible placements, 30 MAPs and 76 source images")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	var errors: Array = diagnostics.filter(func(row): return row.get("level") == "error")
	var warnings: Array = diagnostics.filter(func(row): return row.get("level") == "warning")
	var infos: Array = diagnostics.filter(func(row): return row.get("level") == "info")
	var aa_warnings := 0
	for row: Dictionary in warnings:
		if row.get("code") == "cell_without_map" and String(row.get("detail", "")).contains(" code AA"):
			aa_warnings += 1
	check(errors.is_empty() and warnings.size() == 13 and aa_warnings == 13 and infos.size() == 30,
		"spider lair preserves 13 empty AA cells and 30 raw MAP tag reports")

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
	check(cells.size() == 30 and starts.size() == 1 and bosses.size() == 3,
		"spider lair 6x5 grid exposes one start and three boss candidates")
	check(maze_blocks == 3 and quest_connections == 2 and spec_count == 7,
		"spider lair consumes only the first layout and preserves quests 4408/4421 selector raw")

	for boss_cell in bosses:
		var pools: Dictionary = maze._read_pools(dungeon, cells, starts[0], boss_cell)
		check(pools.size() == 17,
			"start/boss %s/%s reaches all 17 connected cells (pools=%d error=%s)"
			% [starts[0], boss_cell, pools.size(), maze.last_error])
	check(maze.start(probe.data, SourceRolls.new([0, 0, 0, 0]), route.get("source", {})),
		"generic native maze accepts spider lair ordinary layout")
	check(maze.room_count() == 17 and maze.required_map_paths().size() == 24,
		"spider lair preflight exposes 17 rooms across 24 eligible first-visit MAPs "
		+ "(rooms=%d maps=%d)" % [maze.room_count(), maze.required_map_paths().size()])
	check(NativeBoxLoot.ready(dungeon), "spider lair item groups and source art resolve")
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
				check(monster.get("mob") == "monster/spider/spiderboss.mob",
					"every source boss row is the Spider Boss")
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
	check(source_monsters.size() == 7 and source_monster_count == 266 and source_boss_rows == 3,
		"spider lair source has 266 direct placements, 7 MOBs and three boss rows")
	check(source_object_count == 255 and source_breakables == 151
		and source_specials == 43 and source_triggers == 16 and source_static == 45
		and source_box_objects == 125,
		"spider lair source has 255 objects: 151 breakables, 43 special triggers, "
		+ "16 ordinary triggers, 45 static obstacles and 125 item payload rows "
		+ "(objects=%d breakables=%d special=%d triggers=%d static=%d boxes=%d)"
		% [source_object_count, source_breakables, source_specials,
			source_triggers, source_static, source_box_objects])
	check(source_pot_monster_rows == 43 and source_pot_mobs.size() == 2,
		"spider lair special objects retain 43 source monster payload rows across 2 MOBs")
	for mob: String in source_monsters:
		check(not game.table.monster_by_mob(mob).is_empty(),
			"direct source MOB has runtime content: " + mob)
	for mob: String in source_pot_mobs:
		check(not game.table.monster_by_mob(mob).is_empty(),
			"special-object monster payload has runtime content: " + mob)

	var new_banks := {
		"monster/spider/spider.mob": ["spider_spider", 3],
		"monster/spider/spiderpoison.mob": ["spider_spiderpoison", 2],
		"monster/spider/spiderboss.mob": ["spider_spiderboss", 6],
		"monster/ghoul/ghoulnomercy.mob": ["ghoul_ghoulnomercy", 2],
		"monster/wraith/wraithspectress.mob": ["wraith_wraithspectress", 4],
	}
	for mob: String in new_banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		check(String(definition.get("bank", "")) == new_banks[mob][0]
			and game.combat_assets.get("monsters", {}).has(new_banks[mob][0]),
			"spider lair source bank is compiled: " + mob)
		check(Array(definition.get("moves", [])).size() == int(new_banks[mob][1]),
			"source attack slots compile for %s (moves=%d expected=%d)"
			% [mob, Array(definition.get("moves", [])).size(), int(new_banks[mob][1])])
		for move: Dictionary in Array(definition.get("moves", [])):
			if not move.has("atk_path"):continue
			check(not game.table.atk(String(move["atk_path"])).is_empty()
				and not Array(move.get("timeline", [])).is_empty(),
				"source attack motion and ATK compile together: " + mob)

	var flow := FlowSession.new()
	flow.profile["level"] = 41
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "marpissalair"})["ok"],
		"flow departs the hidden spider lair route")
	route = flow.active_dungeon_route()
	NativePotMonsters.reset_catalog()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live spider lair run selects the ordinary layout")
	NativePotMonsters.prepare_catalog(dungeon, SourceRolls.new([0, 0, 0, 0]))
	check(session._validate_native_maze(probe, live_maze),
		"spider lair room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "marpissalair", "route": route,
		"room_id": "marpissalair:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source spider lair room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 17
			and game.view_snapshot()["hud"]["route"].size() == 17,
			"both public battle views report the complete spider lair graph")
		check(game.view.audio.has_dungeon_music("marpissalair")
			and String(game.view.audio.music.stream.resource_path).ends_with("spider.ogg"),
			"spider lair starts with the original M_SPIDER track")

		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts,
			"spider lair start room spawns its exact source monster lineup")

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
		check(interactive_props == 151,
			"all 151 source breakables build exactly once across 30 MAPs")
		check(box_props > 0 and box_props <= source_box_objects,
			"spider lair prepares source item-box draws (prepared=%d source=%d)"
			% [box_props, source_box_objects])
		check(known_jar_ids.is_empty(),
			"no spider lair jar branch executes when known branches mix with unknown IDs")
		check(unknown_ids == [2000, 2100, 2211, 2301, 2310, 2311, 2401, 2510,
			2511, 2610, 2611, 48019],
			"unsupported spider lair trap IDs remain explicit: " + str(unknown_ids))
		check(all_gaps.get("passiveobject/mapobject/trap/shallowkeepskeletonpile.obj", [])
			== ["native_special_object"],
			"skeleton pile remains an explicit special-object gap")
		check(all_gaps.get("passiveobject/mapobject/trap/spidercavespiderspawn.obj", [])
			== ["native_object_trigger"],
			"spider cave spawn remains an explicit trigger gap")
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_MARPISSALAIR] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
