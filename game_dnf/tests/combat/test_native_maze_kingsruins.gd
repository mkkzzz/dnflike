extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const FlowSession = preload("res://flow/session.gd")
const NativeMaze = preload("res://combat/data/native_maze.gd")
const NativeBreakable = preload("res://combat/resolve/native_breakable.gd")
const NativeBoxLoot = preload("res://loot/native_box.gd")
const NativeJarTraps = preload("res://combat/resolve/native_jar_traps.gd")
const NativePotMonsters = preload("res://combat/resolve/native_pot_monsters.gd")
const DetRng = preload("res://core/det_rng.gd")
const ROUTE_MAP_IDS: Array[int] = [4801, 4802, 4803, 4804, 4805, 4806]

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
		push_error("[NATIVE_MAZE_KINGSRUINS] FAIL " + label)

func run() -> void:
	game = session.mount(root)
	game.set_process(false)
	game.set_physics_process(false)
	var routes: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/dungeons.json"))["dungeons"]
	var route: Dictionary = routes["kingsruins"]
	check(route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("region") == "alphraira"
		and int(route.get("min_level", 0)) == 52 and int(route.get("monster_level", 0)) == 55,
		"King's Ruins is a hidden level 52 Alphraira native-maze route with source basis level 55")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production King's Ruins export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/act4/kingsruins.dgn"
		and dungeon.get("sha256") == "f03c598f40d969f903f61266b0c33c38ab09c4e6cbf2ee92a60ebdf5118d1346",
		"King's Ruins export keeps the pinned DGN source identity")
	check(Array(dungeon.get("placements", [])).size() == 18
		and Dictionary(dungeon.get("rooms", {})).size() == 6
		and Dictionary(probe.data.get("images", {})).size() == 45,
		"King's Ruins export contains 18 greed-eligible placements, six MAPs and 45 source images")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	var errors: Array = diagnostics.filter(func(row): return row.get("level") == "error")
	var warnings: Array = diagnostics.filter(func(row): return row.get("level") == "warning")
	var infos: Array = diagnostics.filter(func(row): return row.get("level") == "info")
	check(errors.is_empty() and warnings.is_empty() and infos.size() == 6,
		"King's Ruins preserves six raw MAP tag reports without export errors or warnings")

	var maze := NativeMaze.new()
	var size: Vector2i = maze._point(dungeon.get("size"))
	var cells: Dictionary = maze._read_cells(dungeon.get("cells"), size)
	var starts: Array = maze._read_endpoint_cells(dungeon.get("start_map_raw"), cells, "start_candidate")
	var bosses: Array = maze._read_endpoint_cells(dungeon.get("boss_map_raw"), cells, "boss_candidate")
	var specs: Dictionary = maze._read_specifications(dungeon.get("raw"), cells)
	var spec_count := int(specs.get("normal", {}).size()) + int(specs.get("boss", {}).size())
	var maze_blocks := 0
	var hell_value = null
	var seal_id = null
	var seal_pos = null
	var seal_rate = null
	for span: Dictionary in dungeon.get("raw", []):
		if span.get("tag") == "[maze info]":maze_blocks += 1
		if span.get("tag") == "[hell dungeon]":hell_value = span.get("values", [])
		if span.get("tag") == "[seal door map index]":seal_id = span.get("values", [])
		if span.get("tag") == "[seal door pos]":seal_pos = span.get("values", [])
		if span.get("tag") == "[seal door appear rate]":seal_rate = span.get("values", [])
	check(cells.size() == 6 and starts.size() == 1 and bosses.size() == 1,
		"King's Ruins 6x1 grid exposes one start and one boss candidate")
	check(maze_blocks == 1 and spec_count == 6 and specs.get("boss", {}).is_empty(),
		"King's Ruins consumes six fixed normal MAP rows and no separate boss specification")
	check(hell_value != null and int(hell_value[0][2]) == 1
		and seal_id != null and int(seal_id[0][2]) == 60026
		and seal_pos != null and int(seal_pos[0][2]) == 1 and int(seal_pos[1][2]) == 0
		and seal_rate != null and int(seal_rate[0][2]) == 10,
		"hell mode and seal door 60026 at cell 1,0 with rate 10 remain preserved raw")
	check(cells[Vector2i(5, 0)]["map_candidates"] == ["map/kingsruins/s4801.map"]
		and cells[Vector2i(0, 0)]["map_candidates"] == ["map/kingsruins/b4801.map"],
		"start and boss cells use their source-fixed MAPs")
	check(dungeon["rooms"]["map/kingsruins/s4801.map"].get("role_hint") == "start"
		and dungeon["rooms"]["map/kingsruins/b4801.map"].get("role_hint") == "boss",
		"source MAP types identify the start and Hammer King room")

	var pools: Dictionary = maze._read_pools(dungeon, cells, starts[0], bosses[0])
	check(pools.size() == 6,
		"start/boss reaches all six connected cells (pools=%d error=%s)"
		% [pools.size(), maze.last_error])
	var fixed_maze := NativeMaze.new()
	check(fixed_maze.start(probe.data, SourceRolls.new([0, 0, 0, 0, 0, 0, 0, 0]),
		route.get("source", {})), "generic native maze starts King's Ruins")
	check(fixed_maze.room_count() == 6 and fixed_maze.required_map_paths().size() == 6,
		"King's Ruins preflight exposes six rooms across six source-fixed MAPs")
	var selected_ids: Array[int] = [int(fixed_maze.current_room().get("source_map_id", 0))]
	for step in 5:
		var current: Vector2i = fixed_maze.current_room().get("cell", Vector2i(-1, -1))
		var cleared: Dictionary = fixed_maze.clear_room(current, 0)
		var moved: Dictionary = fixed_maze.move("left")
		check(not cleared.is_empty() and not moved.is_empty(),
			"King's Ruins clears and traverses source step %d" % step)
		selected_ids.append(int(moved.get("source_map_id", 0)))
	check(selected_ids == ROUTE_MAP_IDS,
		"King's Ruins selects MAPs 4801..4806 in the fixed guard-to-boss order")
	var final_clear: Dictionary = fixed_maze.clear_room(Vector2i(0, 0), 0)
	check(bool(final_clear.get("boss", false)) and bool(final_clear.get("final_room", false)),
		"the Hammer King room is the sole boss and final room")
	check(NativeBoxLoot.ready(dungeon), "King's Ruins item groups and v10 source art resolve")
	check(NativeJarTraps.ready(game.combat_assets), "shared source jar trap assets resolve")

	var source_monsters := {}
	var source_monster_count := 0
	var source_boss_rows := 0
	var source_object_count := 0
	var source_breakables := 0
	var source_runtime_breakables := 0
	var source_passive := 0
	var source_specials := 0
	var source_triggers := 0
	var source_static := 0
	var source_box_objects := 0
	for room: Dictionary in dungeon.get("rooms", {}).values():
		for monster: Dictionary in room.get("monsters", []):
			source_monsters[String(monster.get("mob", ""))] = true
			source_monster_count += 1
			var raw: Array = monster.get("raw", [])
			if not raw.is_empty() and raw[-1] == "[boss]":
				source_boss_rows += 1
				check(monster.get("mob") == "monster/soldier/hammerking.mob",
					"the sole source boss row is Hammer King")
		for item: Dictionary in room.get("objects", []):
			source_object_count += 1
			if item.get("source_tag") == "[passive object]":source_passive += 1
			elif item.get("source_tag") == "[special passive object]":source_specials += 1
			if NativeBreakable.supports(item):
				source_breakables += 1
				var source_path := String(item.get("obj", "")).to_lower()
				if not game.content.record(source_path).get("native_breakable", {}).is_empty():
					source_runtime_breakables += 1
				if NativeBoxLoot.draw_count(item) > 0:source_box_objects += 1
			elif String(item.get("obj", "")).to_lower().contains("/trap/"):
				source_triggers += 1
			else:
				source_static += 1
	check(source_monsters.size() == 6 and source_monster_count == 6 and source_boss_rows == 1,
		"King's Ruins source has six direct placements, six MOBs and one boss row")
	check(source_object_count == 31 and source_breakables == 31
		and source_runtime_breakables == 31 and source_passive == 4
		and source_specials == 27 and source_triggers == 0 and source_static == 0
		and source_box_objects == 24,
		"King's Ruins source has 31 executable breakables: 27 special objects and four passive coffins")
	var box_groups := {}
	for map_path: String in [
		"map/kingsruins/s4801.map",
		"map/kingsruins/n4801.map",
		"map/kingsruins/b4801.map",
	]:
		for item: Dictionary in dungeon["rooms"][map_path]["objects"]:
			var draw_spec: Dictionary = NativeBoxLoot.draw_spec(item)
			if not draw_spec.is_empty():
				box_groups[map_path] = String(draw_spec["group"])
				break
	check(box_groups.get("map/kingsruins/s4801.map") == "2"
		and box_groups.get("map/kingsruins/n4801.map") == "0"
		and box_groups.get("map/kingsruins/b4801.map") == "1",
		"source coffins and item boxes dispatch their original groups 0/1/2")
	for mob: String in source_monsters:
		check(not game.table.monster_by_mob(mob).is_empty(),
			"direct source MOB has runtime content: " + mob)

	var banks := {
		"monster/soldier/guard_wind.mob": ["soldier_guard_wind", 2],
		"monster/soldier/guard_block.mob": ["soldier_guard_block", 2],
		"monster/soldier/guard_ice.mob": ["soldier_guard_ice", 2],
		"monster/soldier/guard_fire.mob": ["soldier_guard_fire", 2],
		"monster/soldier/guard_light.mob": ["soldier_guard_light", 3],
		"monster/soldier/hammerking.mob": ["soldier_hammerking", 5],
	}
	for mob: String in banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		check(String(definition.get("bank", "")) == banks[mob][0]
			and game.combat_assets.get("monsters", {}).has(banks[mob][0]),
			"King's Ruins source bank is compiled: " + mob)
		check(Array(definition.get("moves", [])).size() == int(banks[mob][1]),
			"source attack slots compile for %s (moves=%d expected=%d)"
			% [mob, Array(definition.get("moves", [])).size(), int(banks[mob][1])])
		for move: Dictionary in Array(definition.get("moves", [])):
			if not move.has("atk_path"):continue
			check(not game.table.atk(String(move["atk_path"])).is_empty()
				and not Array(move.get("timeline", [])).is_empty(),
				"source attack motion and ATK compile together: " + mob)

	var flow := FlowSession.new()
	flow.profile["level"] = 55
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "kingsruins"})["ok"],
		"flow departs the hidden King's Ruins route")
	route = flow.active_dungeon_route()
	NativePotMonsters.reset_catalog()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live King's Ruins run selects the fixed source maze")
	NativePotMonsters.prepare_catalog(dungeon, SourceRolls.new([0, 0, 0, 0]))
	check(session._validate_native_maze(probe, live_maze),
		"King's Ruins room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "kingsruins", "route": route,
		"room_id": "kingsruins:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source King's Ruins room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 6
			and game.view_snapshot()["hud"]["route"].size() == 6,
			"both public battle views report the complete King's Ruins graph")
		check(game.view.audio.has_dungeon_music("kingsruins")
			and String(game.view.audio.music.stream.resource_path).ends_with("sc_b03.ogg"),
			"King's Ruins normal rooms start with the source M_SKYCASTLE_BOSS_03 track")

		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts,
			"King's Ruins start room spawns its exact source monster lineup")

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
			for path_key: String in game.native_object_gaps:
				if not all_gaps.has(path_key):all_gaps[path_key] = []
				for gap in game.native_object_gaps[path_key]:
					if gap not in all_gaps[path_key]:all_gaps[path_key].append(gap)
		unknown_ids.sort()
		check(interactive_props == 31,
			"all 31 source breakables build exactly once across six MAPs")
		check(box_props > 0 and box_props <= 13,
			"King's Ruins prepares only non-empty source box groups (prepared=%d source=%d)"
			% [box_props, source_box_objects])
		check(known_jar_ids.is_empty(),
			"no trap branch executes while supported 2210 mixes with unknown 2211")
		check(unknown_ids == [2010, 2011, 2110, 2111, 2211],
			"unsupported King's Ruins trap IDs remain explicit: " + str(unknown_ids))
		var box_gaps: Array = all_gaps.get(
			"passiveobject/mapobject/breakableobject/underfoot_treasurebox.obj", []).duplicate()
		box_gaps.sort()
		check(box_gaps == [2010, 2011, 2110, 2111, 2211],
			"item boxes keep their five unresolved trap IDs as raw gaps")
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_KINGSRUINS] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
