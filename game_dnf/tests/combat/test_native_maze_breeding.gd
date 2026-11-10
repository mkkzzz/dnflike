extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const FlowSession = preload("res://flow/session.gd")
const NativeMaze = preload("res://combat/data/native_maze.gd")
const NativeBreakable = preload("res://combat/resolve/native_breakable.gd")
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
		push_error("[NATIVE_MAZE_BREEDING] FAIL " + label)

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
	var route: Dictionary = routes["breeding"]
	check(route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and int(route.get("min_level", 0)) == 35 and int(route.get("monster_level", 0)) == 38,
		"breeding is a hidden level 35 native-maze route with source basis level 38")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production breeding export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/act3/breeding.dgn"
		and dungeon.get("sha256") == "5ca157ff900f7f3522614e9f186e1712ec1d2470726daac32da6f6f40f23c8a5",
		"breeding export keeps the pinned DGN source identity")
	check(Array(dungeon.get("placements", [])).size() == 20
		and Dictionary(dungeon.get("rooms", {})).size() == 12
		and Dictionary(probe.data.get("images", {})).size() == 35,
		"breeding export contains 20 placements, 12 MAPs and 35 source images")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	var errors: Array = diagnostics.filter(func(row): return row.get("level") == "error")
	var warnings: Array = diagnostics.filter(func(row): return row.get("level") == "warning")
	var aa_warnings := 0
	var action_object_warnings := 0
	for row: Dictionary in warnings:
		if row.get("code") == "cell_without_map" and String(row.get("detail", "")).contains(" code AA"):
			aa_warnings += 1
		if (row.get("code") == "object_unrendered"
				and String(row.get("path", "")).contains("/actionobject/")):
			action_object_warnings += 1
	check(errors.is_empty() and warnings.size() == 156 and aa_warnings == 6
		and action_object_warnings == 150,
		"breeding preserves six empty AA cells and 150 behaviour-only action objects")

	var maze := NativeMaze.new()
	var size: Vector2i = maze._point(dungeon.get("size"))
	var cells: Dictionary = maze._read_cells(dungeon.get("cells"), size)
	var starts: Array = maze._read_endpoint_cells(dungeon.get("start_map_raw"), cells, "start_candidate")
	var bosses: Array = maze._read_endpoint_cells(dungeon.get("boss_map_raw"), cells, "boss_candidate")
	var specs: Dictionary = maze._read_specifications(dungeon.get("raw"), cells)
	var spec_count := 0
	for rows: Dictionary in [specs.get("normal", {}), specs.get("boss", {})]:
		spec_count += rows.size()
	check(cells.size() == 16 and starts.size() == 1 and bosses.size() == 2,
		"breeding 4x4 grid exposes one start and two boss choices")
	check(spec_count == 11, "breeding preserves all eleven fixed MAP specifications")

	for start_cell in starts:
		for boss_cell in bosses:
			var pools: Dictionary = maze._read_pools(dungeon, cells, start_cell, boss_cell)
			check(pools.size() == 10,
				"start/boss %s/%s reaches all 10 connected cells (pools=%d error=%s)"
				% [start_cell, boss_cell, pools.size(), maze.last_error])
	check(maze.start(probe.data, SourceRolls.new([0, 0, 0, 0]), route.get("source", {})),
		"generic native maze accepts breeding source")
	check(maze.room_count() == 10 and maze.required_map_paths().size() == 10,
		"breeding preflight exposes 10 rooms across 10 active MAPs "
		+ "(rooms=%d maps=%d)" % [maze.room_count(), maze.required_map_paths().size()])
	check(NativeJarTraps.ready(game.combat_assets), "shared source jar trap assets resolve")
	check(game.prepare_native_box_loot(dungeon),
		"breeding has no special item group and does not require box loot")

	var source_monsters := {}
	var source_monster_count := 0
	var source_boss_rows := 0
	var source_object_count := 0
	var source_breakables := 0
	var source_triggers := 0
	var source_actions := 0
	var source_static := 0
	var source_special_rows := 0
	for room: Dictionary in dungeon.get("rooms", {}).values():
		for monster: Dictionary in room.get("monsters", []):
			source_monsters[String(monster.get("mob", ""))] = true
			source_monster_count += 1
			var raw: Array = monster.get("raw", [])
			if not raw.is_empty() and raw[-1] == "[boss]":
				source_boss_rows += 1
		for item: Dictionary in room.get("objects", []):
			source_object_count += 1
			var path := String(item.get("obj", "")).to_lower()
			if NativeBreakable.supports(item):
				source_breakables += 1
			elif path.contains("/trap/"):
				source_triggers += 1
			elif item.get("source_tag") == "[special passive object]":
				source_special_rows += 1
			elif path.contains("/actionobject/"):
				source_actions += 1
			else:
				source_static += 1
	check(source_monsters.size() == 8 and source_monster_count == 102 and source_boss_rows == 2,
		"breeding source has 102 direct placements, 8 MOBs and two boss rows")
	check(source_object_count == 187 and source_breakables == 0 and source_triggers == 25
		and source_actions == 144 and source_static == 12 and source_special_rows == 6,
		"breeding source has 187 objects: 144 passive action objects, 25 flower triggers, "
		+ "6 special containers and 12 static obstacles "
		+ "(objects=%d breakables=%d triggers=%d actions=%d static=%d special=%d)"
		% [source_object_count, source_breakables, source_triggers, source_actions,
			source_static, source_special_rows])
	for mob: String in source_monsters:
		check(not game.table.monster_by_mob(mob).is_empty(),
			"direct source MOB has runtime content: " + mob)

	var new_banks := {
		"monster/newmonsters/gbl_breeding/flare_worm/flare_worm.mob":
			"newmonsters_gbl_breeding_flare_worm_flare_worm",
		"monster/dendroid/dendroid_breeding.mob": "dendroid_dendroid_breeding",
		"monster/newmonsters/gbl_breeding/dendroid_disguise/dendroid_disguise.mob":
			"newmonsters_gbl_breeding_dendroid_disguise_dendroid_disguise",
		"monster/newmonsters/gbl_breeding/new_gbl_nomal/new_gbl_nomal.mob":
			"newmonsters_gbl_breeding_new_gbl_nomal_new_gbl_nomal",
		"monster/newmonsters/gbl_breeding/new_gbl_woman/new_gbl_woman.mob":
			"newmonsters_gbl_breeding_new_gbl_woman_new_gbl_woman",
		"monster/newmonsters/gbl_breeding/woody_plant/woody_plant.mob":
			"newmonsters_gbl_breeding_woody_plant_woody_plant",
		"monster/newmonsters/gbl_breeding/flare_spawn/flare_spawn.mob":
			"newmonsters_gbl_breeding_flare_spawn_flare_spawn",
		"monster/newmonsters/gbl_breeding/dendroid_elder/dendroid_elder.mob":
			"newmonsters_gbl_breeding_dendroid_elder_dendroid_elder",
	}
	var expected_moves := {
		"monster/newmonsters/gbl_breeding/flare_worm/flare_worm.mob": 1,
		"monster/dendroid/dendroid_breeding.mob": 5,
		"monster/newmonsters/gbl_breeding/dendroid_disguise/dendroid_disguise.mob": 3,
		"monster/newmonsters/gbl_breeding/new_gbl_nomal/new_gbl_nomal.mob": 1,
		"monster/newmonsters/gbl_breeding/new_gbl_woman/new_gbl_woman.mob": 1,
		"monster/newmonsters/gbl_breeding/woody_plant/woody_plant.mob": 5,
		"monster/newmonsters/gbl_breeding/flare_spawn/flare_spawn.mob": 2,
		"monster/newmonsters/gbl_breeding/dendroid_elder/dendroid_elder.mob": 6,
	}
	var expected_rules := {
		"monster/newmonsters/gbl_breeding/flare_worm/flare_worm.mob": 1,
		"monster/dendroid/dendroid_breeding.mob": 0,
		"monster/newmonsters/gbl_breeding/dendroid_disguise/dendroid_disguise.mob": 2,
		"monster/newmonsters/gbl_breeding/new_gbl_nomal/new_gbl_nomal.mob": 1,
		"monster/newmonsters/gbl_breeding/new_gbl_woman/new_gbl_woman.mob": 1,
		"monster/newmonsters/gbl_breeding/woody_plant/woody_plant.mob": 1,
		"monster/newmonsters/gbl_breeding/flare_spawn/flare_spawn.mob": 1,
		"monster/newmonsters/gbl_breeding/dendroid_elder/dendroid_elder.mob": 6,
	}
	for mob: String in new_banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		var bank := String(definition.get("bank", ""))
		check(bank == new_banks[mob] and game.combat_assets.get("monsters", {}).has(bank),
			"breeding source bank is compiled: " + mob)
		var moves: Array = definition.get("moves", [])
		var rules: Array = definition.get("rules", [])
		check(moves.size() == expected_moves[mob] and rules.size() == expected_rules[mob],
			"source attack slots and AI rules compile for " + mob)
		for move: Dictionary in moves:
			if not move.has("atk_path"):continue
			check(not game.table.atk(String(move["atk_path"])).is_empty()
				and not Array(move.get("timeline", [])).is_empty(),
				"source attack motion and ATK compile together: " + mob)

	var flow := FlowSession.new()
	flow.profile["level"] = 38
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "breeding"})["ok"],
		"flow departs the hidden breeding route")
	route = flow.active_dungeon_route()
	NativePotMonsters.reset_catalog()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live breeding run selects a source maze")
	NativePotMonsters.prepare_catalog(dungeon, SourceRolls.new([0, 0, 0, 0]))
	check(session._validate_native_maze(probe, live_maze),
		"breeding room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "breeding", "route": route,
		"room_id": "breeding:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source breeding room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 10
			and game.view_snapshot()["hud"]["route"].size() == 10,
			"both public battle views report the complete breeding graph")
		check(game.view.audio.has_dungeon_music("breeding")
			and String(game.view.audio.music.stream.resource_path).ends_with("breeding_place.ogg"),
			"breeding starts with the original M_BREEDING_PLACE track")

		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts,
			"breeding start room spawns its exact source monster lineup")

		var interactive_props := 0
		var box_props := 0
		var all_gaps := {}
		for path: String in dungeon.get("rooms", {}).keys():
			var room: Dictionary = probe.room(path)
			var room_props: Array = game.build_props(room)
			interactive_props += room_props.size()
			for prop: Dictionary in room_props:
				if not (prop.get("box_items", []) as Array).is_empty():
					box_props += 1
			merge_gaps(all_gaps, game.native_object_gaps)
		check(interactive_props == 0 and box_props == 0,
			"behaviour-only breeding objects do not masquerade as breakables or item boxes")
		var trigger_paths := [
			"passiveobject/mapobject/trap/hallucinationflowerleft_breeding.obj",
			"passiveobject/mapobject/trap/hallucinationflowerright_breeding.obj",
		]
		for path: String in trigger_paths:
			check(all_gaps.get(path, []) == ["native_object_trigger"],
				"hallucination flower remains an explicit trigger gap: " + path)
		var action_paths := [
			"passiveobject/actionobject/monster/gbl_breeding/litteldend.obj",
			"passiveobject/actionobject/map/gbl_breeding/collectionboxforlotus.obj",
			"passiveobject/actionobject/monster/gbl_breeding/goliden_long_ob.obj",
			"passiveobject/actionobject/map/gbl_breeding/well.obj",
			"passiveobject/actionobject/map/gbl_breeding/die_tree.obj",
			"passiveobject/actionobject/map/gbl_breeding/die_tree2.obj",
			"passiveobject/actionobject/map/gbl_breeding/die_tree3.obj",
			"passiveobject/actionobject/map/gbl_breeding/die_tree4.obj",
			"passiveobject/actionobject/map/gbl_breeding/die_tree5.obj",
			"passiveobject/actionobject/map/gbl_breeding/die_tree6.obj",
		]
		for path: String in action_paths:
			var gaps: Array = all_gaps.get(path, [])
			check("native_action_object_behavior" in gaps and "native_action_object_visual" in gaps,
				"action-only object records both behaviour and visual gaps: " + path)
		var box := "passiveobject/actionobject/map/gbl_breeding/collectionboxforlotus.obj"
		var box_gaps: Array = all_gaps.get(box, [])
		check("native_special_object" in box_gaps and 2201 in box_gaps and 2501 in box_gaps,
			"special breeding containers preserve both unknown trap IDs: " + str(box_gaps))
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_BREEDING] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
