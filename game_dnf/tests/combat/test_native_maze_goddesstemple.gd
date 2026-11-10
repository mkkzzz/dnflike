extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const FlowSession = preload("res://flow/session.gd")
const NativeMaze = preload("res://combat/data/native_maze.gd")
const NativeBreakable = preload("res://combat/resolve/native_breakable.gd")
const NativeJarTraps = preload("res://combat/resolve/native_jar_traps.gd")
const NativePotMonsters = preload("res://combat/resolve/native_pot_monsters.gd")
const DetRng = preload("res://core/det_rng.gd")
const EXPORT := "res://assets_local/native_maps/goddesstemple_v1/map_export.json"

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
		push_error("[NATIVE_MAZE_GODDESSTEMPLE] FAIL " + label)

func run() -> void:
	game = session.mount(root)
	game.set_process(false)
	game.set_physics_process(false)
	var routes: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/dungeons.json"))["dungeons"]
	var route: Dictionary = routes["goddesstemple"]
	check(route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and int(route.get("min_level", 0)) == 33 and int(route.get("monster_level", 0)) == 36,
		"goddesstemple is a hidden level 33 native-maze route with source basis level 36")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production goddess temple export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/act3/goddesstemple.dgn"
		and dungeon.get("sha256") == "88aa7ce4c942f1981c2df755691480e3991ac539ef60e9850822e5c33f375a04",
		"goddess temple export keeps the pinned DGN source identity")
	check(Array(dungeon.get("placements", [])).size() == 19
		and Dictionary(dungeon.get("rooms", {})).size() == 13
		and Dictionary(probe.data.get("images", {})).size() == 66,
		"goddess temple export contains 19 placements, 13 MAPs and 66 source images")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	var errors: Array = diagnostics.filter(func(row): return row.get("level") == "error")
	var warnings: Array = diagnostics.filter(func(row): return row.get("level") == "warning")
	var aa_warnings := 0
	var action_object_warnings := 0
	for row: Dictionary in warnings:
		if row.get("code") == "cell_without_map" and String(row.get("detail", "")).contains(" code AA"):
			aa_warnings += 1
		if (row.get("code") == "object_unrendered"
				and String(row.get("path", "")).ends_with("/gblhelipad.obj")):
			action_object_warnings += 1
	check(errors.is_empty() and warnings.size() == 51 and aa_warnings == 9
		and action_object_warnings == 42,
		"goddess temple preserves nine empty AA cells and 42 unrendered helipad objects")

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
		"goddess temple 4x5 grid exposes one start and two boss choices")
	check(spec_count == 12, "goddess temple preserves all twelve fixed MAP specifications")

	for start_cell in starts:
		for boss_cell in bosses:
			var pools: Dictionary = maze._read_pools(dungeon, cells, start_cell, boss_cell)
			check(pools.size() == 11,
				"start/boss %s/%s reaches all 11 connected cells (pools=%d error=%s)"
				% [start_cell, boss_cell, pools.size(), maze.last_error])
	check(maze.start(probe.data, SourceRolls.new([0, 0, 0, 0]), route.get("source", {})),
		"generic native maze accepts goddess temple source")
	check(maze.room_count() == 11 and maze.required_map_paths().size() == 11,
		"goddess temple preflight exposes 11 rooms across 11 active MAPs "
		+ "(rooms=%d maps=%d)" % [maze.room_count(), maze.required_map_paths().size()])
	check(NativeJarTraps.ready(game.combat_assets), "shared source jar trap assets resolve")

	var source_monsters := {}
	var source_monster_count := 0
	var source_boss_rows := 0
	var source_object_count := 0
	var source_breakables := 0
	var source_triggers := 0
	var source_special_gates := 0
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
				source_special_gates += 1
	check(source_monsters.size() == 9 and source_monster_count == 93 and source_boss_rows == 2,
		"goddess temple source has 93 direct placements, 9 MOBs and two boss rows")
	check(source_object_count == 278 and source_breakables == 142
		and source_triggers == 0 and source_special_gates == 0,
		"goddess temple source has 278 objects and 142 supported breakables "
		+ "(objects=%d breakables=%d triggers=%d opaque=%d)"
		% [source_object_count, source_breakables, source_triggers, source_special_gates])
	for mob: String in source_monsters:
		check(not game.table.monster_by_mob(mob).is_empty(),
			"direct source MOB has runtime content: " + mob)

	var new_banks := {
		"monster/newmonsters/gbl_goddess_temple/astray_gbl_devotee/astray_gbl_devotee.mob":
			"newmonsters_gbl_goddess_temple_astray_gbl_devotee_astray_gbl_devotee",
		"monster/newmonsters/gbl_goddess_temple/astray_gbl_w_devotee/astray_gbl_w_devotee.mob":
			"newmonsters_gbl_goddess_temple_astray_gbl_w_devotee_astray_gbl_w_devotee",
		"monster/newmonsters/gbl_goddess_temple/astray_alsor/astray_alsor.mob":
			"newmonsters_gbl_goddess_temple_astray_alsor_astray_alsor",
		"monster/newmonsters/gbl_goddess_temple/zookeeper/zookeeper.mob":
			"newmonsters_gbl_goddess_temple_zookeeper_zookeeper",
		"monster/newmonsters/gbl_goddess_temple/astray_gbl_pope/astray_gbl_pope.mob":
			"newmonsters_gbl_goddess_temple_astray_gbl_pope_astray_gbl_pope",
	}
	for mob: String in new_banks:
		var kind: String = game.table.monster_by_mob(mob)
		var bank := String(game.table.monsters.get(kind, {}).get("bank", ""))
		check(bank == new_banks[mob] and game.combat_assets.get("monsters", {}).has(bank),
			"goddess temple source bank is compiled: " + mob)
	var expected_moves := {
		"monster/newmonsters/gbl_goddess_temple/astray_gbl_devotee/astray_gbl_devotee.mob": 1,
		"monster/newmonsters/gbl_goddess_temple/astray_gbl_w_devotee/astray_gbl_w_devotee.mob": 1,
		"monster/newmonsters/gbl_goddess_temple/astray_alsor/astray_alsor.mob": 6,
		"monster/newmonsters/gbl_goddess_temple/zookeeper/zookeeper.mob": 4,
		"monster/newmonsters/gbl_goddess_temple/astray_gbl_pope/astray_gbl_pope.mob": 4,
	}
	var expected_rules := {
		"monster/newmonsters/gbl_goddess_temple/astray_gbl_devotee/astray_gbl_devotee.mob": 1,
		"monster/newmonsters/gbl_goddess_temple/astray_gbl_w_devotee/astray_gbl_w_devotee.mob": 1,
		"monster/newmonsters/gbl_goddess_temple/astray_alsor/astray_alsor.mob": 0,
		"monster/newmonsters/gbl_goddess_temple/zookeeper/zookeeper.mob": 3,
		"monster/newmonsters/gbl_goddess_temple/astray_gbl_pope/astray_gbl_pope.mob": 4,
	}
	for mob: String in new_banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
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
	flow.profile["level"] = 36
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "goddesstemple"})["ok"],
		"flow departs the hidden goddess temple route")
	route = flow.active_dungeon_route()
	NativePotMonsters.reset_catalog()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live goddess temple run selects a source maze")
	NativePotMonsters.prepare_catalog(dungeon, SourceRolls.new([0, 0, 0, 0]))
	check(session._validate_native_maze(probe, live_maze),
		"goddess temple room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "goddesstemple", "route": route,
		"room_id": "goddesstemple:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source goddess temple room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 11
			and game.view_snapshot()["hud"]["route"].size() == 11,
			"both public battle views report the complete goddess temple graph")
		check(game.view.audio.has_dungeon_music("goddesstemple")
			and String(game.view.audio.music.stream.resource_path).ends_with("goddess_temple.ogg"),
			"goddess temple starts with the original M_GODDESS_TEMPLE track")

		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts,
			"goddess temple start room spawns its exact source monster lineup")

		var interactive_props := 0
		var box_props := 0
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
		check(interactive_props == 142,
			"all 142 source breakables build exactly once across 13 MAPs")
		check(box_props == 0,
			"goddess temple has no source special-item box group to draw")
		check(unknown_ids == [2211],
			"unsupported 2211 trap rows are recorded without execution: " + str(unknown_ids))
		check(trigger_paths.is_empty(), "goddess temple has no standalone trap path objects")
		var helipad := "passiveobject/actionobject/common/gblhelipad.obj"
		check(all_gaps.get(helipad, []) == ["native_action_object_behavior", "native_action_object_visual"],
			"motionless GBL helipad remains explicit runtime behaviour and visual gaps")
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_GODDESSTEMPLE] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
