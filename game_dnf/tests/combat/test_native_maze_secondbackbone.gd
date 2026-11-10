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
		push_error("[NATIVE_MAZE_SECONDBACKBONE] FAIL " + label)

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
	var route: Dictionary = routes["secondbackbone"]
	check(route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and int(route.get("min_level", 0)) == 34 and int(route.get("monster_level", 0)) == 37,
		"second spine is a hidden level 34 native-maze route with source basis level 37")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production second spine export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/act3/2ndbackbone.dgn"
		and dungeon.get("sha256") == "0c5b269fe35d1699c652beb77ec946eb6e3b6c417fd70f18d24a9bfa10e417cc",
		"second spine export keeps the pinned DGN source identity")
	check(Array(dungeon.get("placements", [])).size() == 62
		and Dictionary(dungeon.get("rooms", {})).size() == 37
		and Dictionary(probe.data.get("images", {})).size() == 58,
		"second spine export contains 62 placements, 37 MAPs and 58 source images")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	var errors: Array = diagnostics.filter(func(row): return row.get("level") == "error")
	var warnings: Array = diagnostics.filter(func(row): return row.get("level") == "warning")
	var infos: Array = diagnostics.filter(func(row): return row.get("level") == "info")
	var aa_warnings := 0
	for row: Dictionary in warnings:
		if row.get("code") == "cell_without_map" and String(row.get("detail", "")).contains(" code AA"):
			aa_warnings += 1
	check(errors.is_empty() and warnings.size() == 7 and aa_warnings == 7 and infos.size() == 37,
		"second spine preserves seven empty AA cells and 37 raw MAP tag reports")

	var maze := NativeMaze.new()
	var size: Vector2i = maze._point(dungeon.get("size"))
	var cells: Dictionary = maze._read_cells(dungeon.get("cells"), size)
	var starts: Array = maze._read_endpoint_cells(dungeon.get("start_map_raw"), cells, "start_candidate")
	var bosses: Array = maze._read_endpoint_cells(dungeon.get("boss_map_raw"), cells, "boss_candidate")
	var specs: Dictionary = maze._read_specifications(dungeon.get("raw"), cells)
	var spec_count := 0
	for rows: Dictionary in [specs.get("normal", {}), specs.get("boss", {})]:
		spec_count += rows.size()
	check(cells.size() == 20 and starts.size() == 1 and bosses.size() == 1,
		"second spine 5x4 grid exposes one start and one boss")
	check(spec_count == 8, "second spine preserves all eight fixed MAP specifications")

	for start_cell in starts:
		for boss_cell in bosses:
			var pools: Dictionary = maze._read_pools(dungeon, cells, start_cell, boss_cell)
			check(pools.size() == 13,
				"start/boss %s/%s reaches all 13 connected cells (pools=%d error=%s)"
				% [start_cell, boss_cell, pools.size(), maze.last_error])
	check(maze.start(probe.data, SourceRolls.new([0, 0, 0, 0]), route.get("source", {})),
		"generic native maze accepts second spine source")
	check(maze.room_count() == 13 and maze.required_map_paths().size() == 25,
		"second spine preflight exposes 13 rooms across 25 eligible first-visit MAPs "
		+ "(rooms=%d maps=%d)" % [maze.room_count(), maze.required_map_paths().size()])
	check(NativeBoxLoot.ready(dungeon), "second spine item groups and source art resolve")
	check(NativeJarTraps.ready(game.combat_assets), "shared source jar trap assets resolve")

	var source_monsters := {}
	var source_monster_count := 0
	var source_boss_rows := 0
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
				check(monster.get("mob") == "monster/lotus/lotus.mob",
					"the source boss row is the long-legged Lotus")
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
				source_triggers += 1
			else:
				source_static += 1
	check(source_monsters.size() == 12 and source_monster_count == 343 and source_boss_rows == 1,
		"second spine source has 343 direct placements, 12 MOBs and one boss row")
	check(source_object_count == 722 and source_breakables == 178 and source_specials == 12
		and source_triggers == 72 and source_static == 460 and source_box_objects == 19,
		"second spine source has 722 objects: 178 breakables, 12 bell specials, "
		+ "72 triggers, 460 static obstacles and 19 item boxes "
		+ "(objects=%d breakables=%d special=%d triggers=%d static=%d boxes=%d)"
		% [source_object_count, source_breakables, source_specials,
			source_triggers, source_static, source_box_objects])
	for mob: String in source_monsters:
		check(not game.table.monster_by_mob(mob).is_empty(),
			"direct source MOB has runtime content: " + mob)

	var new_banks := {
		"monster/starfish/starfishdevourer.mob": "starfish_starfishdevourer",
		"monster/vehicle/catapultlaser.mob": "vehicle_catapultlaser",
		"monster/zealot/father.mob": "zealot_father",
		"monster/lotus/lotus.mob": "lotus_lotus",
	}
	var expected_moves := {
		"monster/starfish/starfishdevourer.mob": 2,
		"monster/vehicle/catapultlaser.mob": 2,
		"monster/zealot/father.mob": 0,
		"monster/lotus/lotus.mob": 17,
	}
	for mob: String in new_banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		var bank := String(definition.get("bank", ""))
		check(bank == new_banks[mob] and game.combat_assets.get("monsters", {}).has(bank),
			"second spine source bank is compiled: " + mob)
		var moves: Array = definition.get("moves", [])
		check(moves.size() == expected_moves[mob],
			"source attack slots compile for " + mob)
		for move: Dictionary in moves:
			if not move.has("atk_path"):continue
			check(not game.table.atk(String(move["atk_path"])).is_empty()
				and not Array(move.get("timeline", [])).is_empty(),
				"source attack motion and ATK compile together: " + mob)
	var lotus_bank: Dictionary = game.combat_assets["monsters"]["lotus_lotus"]
	check(not lotus_bank.has("number_height"),
		"blank Lotus waiting frame keeps a clean bank without an invented number height")
	var father_kind: String = game.table.monster_by_mob("monster/zealot/father.mob")
	var father: Dictionary = game.table.monsters.get(father_kind, {})
	check(not Array(father.get("attack_timeline", [])).is_empty() and not father.get("atk", {}).is_empty(),
		"single-source Father attack compiles through the legacy attack timeline")

	var flow := FlowSession.new()
	flow.profile["level"] = 37
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "secondbackbone"})["ok"],
		"flow departs the hidden second spine route")
	route = flow.active_dungeon_route()
	NativePotMonsters.reset_catalog()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live second spine run selects a source maze")
	NativePotMonsters.prepare_catalog(dungeon, SourceRolls.new([0, 0, 0, 0]))
	check(session._validate_native_maze(probe, live_maze),
		"second spine room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "secondbackbone", "route": route,
		"room_id": "secondbackbone:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source second spine room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 13
			and game.view_snapshot()["hud"]["route"].size() == 13,
			"both public battle views report the complete second spine graph")
		check(game.view.audio.has_dungeon_music("secondbackbone")
			and String(game.view.audio.music.stream.resource_path).ends_with("2nd_spine.ogg"),
			"second spine starts with the original M_2ND_SPINE track")

		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts,
			"second spine start room spawns its exact source monster lineup")

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
		check(interactive_props == 178,
			"all 178 source breakables build exactly once across 37 MAPs")
		check(box_props > 0 and box_props <= source_box_objects,
			"second spine prepares source item-box draws (prepared=%d source=%d)"
			% [box_props, source_box_objects])
		check(known_jar_ids.keys().all(func(id): return int(id) in [2210]),
			"only the source-complete 2210 jar branch executes: " + str(known_jar_ids))
		check(unknown_ids == [1025, 1072, 2000, 2001, 2010, 2100, 2101, 2110, 2211, 2601, 48021],
			"unsupported mixed trap IDs are recorded without execution: " + str(unknown_ids))
		check(all_gaps.get("passiveobject/mapobject/trap/starfishegg.obj", []) == ["native_object_trigger"],
			"starfish egg remains an explicit trigger gap")
		check(all_gaps.get("passiveobject/mapobject/trap/gravitychanger.obj", []) == ["native_object_trigger"],
			"gravity changer remains an explicit trigger gap")
		check(all_gaps.get("passiveobject/mapobject/trap/bellforzealots.obj", []) == ["native_special_object"],
			"Zealot bell item payload remains an explicit special-object gap")
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_SECONDBACKBONE] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
