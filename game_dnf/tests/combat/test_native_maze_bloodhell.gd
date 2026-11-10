extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const FlowSession = preload("res://flow/session.gd")
const NativeMaze = preload("res://combat/data/native_maze.gd")
const NativeBreakable = preload("res://combat/resolve/native_breakable.gd")
const NativeBoxLoot = preload("res://loot/native_box.gd")
const NativeJarTraps = preload("res://combat/resolve/native_jar_traps.gd")
const NativePotMonsters = preload("res://combat/resolve/native_pot_monsters.gd")
const DetRng = preload("res://core/det_rng.gd")
const EXPORT := "res://assets_local/native_maps/bloodhell_v1/map_export.json"

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
		push_error("[NATIVE_MAZE_BLOODHELL] FAIL " + label)

func run() -> void:
	game = session.mount(root)
	game.set_process(false)
	game.set_physics_process(false)
	var routes: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/dungeons.json"))["dungeons"]
	var route: Dictionary = routes["bloodhell"]
	check(route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and int(route.get("min_level", 0)) == 36 and int(route.get("monster_level", 0)) == 39,
		"bloodhell is a hidden level 36 native-maze route with source basis level 39")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production bloodhell export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/act3/bloodhell.dgn"
		and dungeon.get("sha256") == "8b4d8a743b8b57bc3118575bab15c85f67277bc8991056dc82b3d1c4dcfc8a57",
		"bloodhell export keeps the pinned DGN source identity")
	check(Array(dungeon.get("placements", [])).size() == 16
		and Dictionary(dungeon.get("rooms", {})).size() == 13
		and Dictionary(probe.data.get("images", {})).size() == 68,
		"bloodhell export contains 16 placements, 13 MAPs and 68 source images")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	var errors: Array = diagnostics.filter(func(row): return row.get("level") == "error")
	var warnings: Array = diagnostics.filter(func(row): return row.get("level") == "warning")
	var aa_warnings := 0
	var opaque_blocks := 0
	for row: Dictionary in warnings:
		if row.get("code") == "cell_without_map" and String(row.get("detail", "")).contains(" code AA"):
			aa_warnings += 1
		if row.get("code") == "opaque_special_object":
			opaque_blocks += 1
	check(errors.is_empty() and warnings.size() == 11
		and aa_warnings == 10 and opaque_blocks == 1,
		"bloodhell preserves ten empty AA cells and one opaque hellparty block")

	var maze := NativeMaze.new()
	var size: Vector2i = maze._point(dungeon.get("size"))
	var cells: Dictionary = maze._read_cells(dungeon.get("cells"), size)
	var starts: Array = maze._read_endpoint_cells(dungeon.get("start_map_raw"), cells, "start_candidate")
	var bosses: Array = maze._read_endpoint_cells(dungeon.get("boss_map_raw"), cells, "boss_candidate")
	var specs: Dictionary = maze._read_specifications(dungeon.get("raw"), cells)
	var spec_count := 0
	for rows: Dictionary in [specs.get("normal", {}), specs.get("boss", {})]:
		spec_count += rows.size()
	check(cells.size() == 20 and starts.size() == 1 and bosses.size() == 2,
		"bloodhell 5x4 grid exposes one start and two boss choices")
	check(spec_count == 7, "bloodhell preserves all seven fixed MAP specifications")

	for start_cell in starts:
		for boss_cell in bosses:
			var pools: Dictionary = maze._read_pools(dungeon, cells, start_cell, boss_cell)
			check(pools.size() == 10,
				"start/boss %s/%s reaches all 10 connected cells (pools=%d error=%s)"
				% [start_cell, boss_cell, pools.size(), maze.last_error])
	check(maze.start(probe.data, SourceRolls.new([0, 0, 0]), route.get("source", {})),
		"generic native maze accepts bloodhell source")
	check(maze.room_count() == 10 and maze.required_map_paths().size() == 10,
		"bloodhell preflight exposes 10 rooms across 10 active MAPs "
		+ "(rooms=%d maps=%d)" % [maze.room_count(), maze.required_map_paths().size()])
	check(NativeBoxLoot.ready(dungeon), "bloodhell item groups and source art resolve")
	check(NativeJarTraps.ready(game.combat_assets), "shared source jar trap assets resolve")

	var source_monsters := {}
	var source_monster_count := 0
	var source_object_count := 0
	var source_breakables := 0
	var source_triggers := 0
	var source_special_gates := 0
	for room: Dictionary in dungeon.get("rooms", {}).values():
		for monster: Dictionary in room.get("monsters", []):
			source_monsters[String(monster.get("mob", ""))] = true
			source_monster_count += 1
		for item: Dictionary in room.get("objects", []):
			source_object_count += 1
			var path := String(item.get("obj", "")).to_lower()
			if NativeBreakable.supports(item):
				source_breakables += 1
			elif path.contains("/trap/"):
				source_triggers += 1
			elif item.get("source_tag") == "[special passive object]":
				source_special_gates += 1
	check(source_monsters.size() == 6 and source_monster_count == 106,
		"bloodhell source has 106 direct placements across 6 MOBs")
	check(source_object_count == 143 and source_breakables == 77
		and source_triggers == 25 and source_special_gates == 1,
		"bloodhell source has 143 objects: 77 breakables, 25 triggers and one opaque gate "
		+ "(objects=%d breakables=%d triggers=%d gates=%d)" % [
			source_object_count, source_breakables, source_triggers, source_special_gates])
	for mob: String in source_monsters:
		check(not game.table.monster_by_mob(mob).is_empty(),
			"direct source MOB has runtime content: " + mob)
	var leader: Dictionary = game.table.monsters.get("zealotrebirth_rebirthgblleader", {})
	var leader_throw: Dictionary = leader.get("throw", {})
	check(not leader_throw.is_empty() and leader_throw.get("particles", []).size() == 3
		and float(leader_throw.get("speed", 0.0)) > 0.0,
		"rebirth GBL leader preserves all three throw particle dependencies")

	var flow := FlowSession.new()
	flow.profile["level"] = 36
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "bloodhell"})["ok"],
		"flow departs the hidden bloodhell route")
	route = flow.active_dungeon_route()
	NativePotMonsters.reset_catalog()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live bloodhell run selects a source maze")
	NativePotMonsters.prepare_catalog(dungeon, SourceRolls.new([0, 0, 0, 0]))
	check(session._validate_native_maze(probe, live_maze),
		"bloodhell room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "bloodhell", "route": route,
		"room_id": "bloodhell:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source bloodhell room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 10
			and game.view_snapshot()["hud"]["route"].size() == 10,
			"both public battle views report the complete bloodhell graph")
		check(game.view.audio.has_dungeon_music("bloodhell")
			and String(game.view.audio.music.stream.resource_path).ends_with("bloodhell.ogg"),
			"bloodhell starts with the original M_BLOODHELL track")

		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts,
			"bloodhell start room spawns its exact source monster lineup")

		var interactive_props := 0
		var box_props := 0
		var known_jar_ids := {}
		var unknown_ids: Array[int] = []
		var trigger_paths := {}
		var all_gaps := {}
		for path: String in dungeon.get("rooms", {}).keys():
			var room: Dictionary = probe.room(path)
			var room_props: Array = game.build_props(room)
			interactive_props += room_props.size()
			for prop: Dictionary in room_props:
				var source_path := String(prop.get("source_path", ""))
				if not (prop.get("box_items", []) as Array).is_empty():
					box_props += 1
				var selection: Dictionary = prop.get("jar_trap", {})
				if not selection.is_empty():
					known_jar_ids[int(selection["id"])] = true
				for source_id in prop.get("unresolved_trap_ids", []):
					if int(source_id) not in unknown_ids:
						unknown_ids.append(int(source_id))
				check(not source_path.contains("/trap/"),
					"trap trigger is not materialised as a contact hazard: " + source_path)
			for gap_path: String in game.native_object_gaps:
				all_gaps[gap_path] = game.native_object_gaps[gap_path]
				if gap_path.contains("/trap/"):
					trigger_paths[gap_path] = true
		unknown_ids.sort()
		check(interactive_props == 77,
			"all 77 source breakables build exactly once across 13 MAPs")
		check(box_props >= 5,
			"bloodhell prepares original item box draws (boxes=%d)" % box_props)
		check(known_jar_ids.keys().all(func(id): return int(id) in [2210, 48003]),
			"only source-verified jar IDs execute")
		check(unknown_ids == [48021],
			"the unsupported trap ID is recorded without execution: " + str(unknown_ids))
		check(trigger_paths.has("passiveobject/mapobject/trap/swamp/vehemosswamp.obj")
			and trigger_paths.has("passiveobject/mapobject/trap/vehemosdigestivea.obj")
			and trigger_paths.has("passiveobject/mapobject/trap/vehemosdigestiveb.obj")
			and trigger_paths.has("passiveobject/mapobject/trap/vehemosdigestivec.obj"),
			"vehemos swamp and digestive triggers remain explicit runtime gaps")
		var sealed := "passiveobject/monster/cosmofiend/sealedgateofhelldungeon1.obj"
		check(all_gaps.get(sealed, []) == ["opaque_special_object"],
			"hellparty sealed gate remains an opaque special object")
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_BLOODHELL] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
