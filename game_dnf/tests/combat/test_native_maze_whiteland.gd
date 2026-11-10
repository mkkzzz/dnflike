extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const FlowSession = preload("res://flow/session.gd")
const NativeMaze = preload("res://combat/data/native_maze.gd")
const NativeBreakable = preload("res://combat/resolve/native_breakable.gd")
const NativeBoxLoot = preload("res://loot/native_box.gd")
const NativeJarTraps = preload("res://combat/resolve/native_jar_traps.gd")
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
		push_error("[NATIVE_MAZE_WHITELAND] FAIL " + label)

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
	var route: Dictionary = routes["whiteland"]
	check(route.get("name") == "白色废墟"
		and route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("region") == "snowmt"
		and int(route.get("min_level", 0)) == 44 and int(route.get("monster_level", 0)) == 47,
		"White Land is a hidden level 44 Snow Mountain native-maze route with source basis level 47")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production White Land export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/act5/whiteland.dgn"
		and dungeon.get("sha256") == "096575dbf1ac14fab9681071a8ddc00189008977353d07c706006d0aa5e11f25",
		"White Land export keeps the pinned DGN source identity")
	check(Array(dungeon.get("placements", [])).size() == 20
		and Dictionary(dungeon.get("rooms", {})).size() == 12
		and Dictionary(probe.data.get("images", {})).size() == 62,
		"White Land export contains 20 placements, 12 MAPs and 62 source images")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	var errors: Array = diagnostics.filter(func(row): return row.get("level") == "error")
	var warnings: Array = diagnostics.filter(func(row): return row.get("level") == "warning")
	var infos: Array = diagnostics.filter(func(row): return row.get("level") == "info")
	var aa_warnings := 0
	var warning_unrendered := 0
	var info_unrendered := 0
	for row: Dictionary in warnings:
		if row.get("code") == "cell_without_map" and String(row.get("detail", "")).contains(" code AA"):
			aa_warnings += 1
		if row.get("code") == "object_unrendered":
			warning_unrendered += 1
	for row: Dictionary in infos:
		if row.get("code") == "object_unrendered":
			info_unrendered += 1
	check(errors.is_empty() and warnings.size() == 11 and infos.size() == 77
		and aa_warnings == 6 and warning_unrendered == 5 and info_unrendered == 12,
		"White Land preserves six AA cells and 17 source objects without rendered sprites")

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
	var event_monster = null
	var seal_id = null
	var seal_pos = null
	var hell_value = null
	for span: Dictionary in dungeon.get("raw", []):
		if span.get("tag") == "[maze info]":maze_blocks += 1
		if span.get("tag") == "[quest connection]":quest_connections += 1
		if span.get("tag") == "[event monster]":event_monster = span.get("values", [])
		if span.get("tag") == "[seal door map index]":seal_id = span.get("values", [])
		if span.get("tag") == "[seal door pos]":seal_pos = span.get("values", [])
		if span.get("tag") == "[hell dungeon]":hell_value = span.get("values", [])
	check(cells.size() == 16 and starts == [Vector2i(1, 3)]
		and bosses == [Vector2i(0, 0), Vector2i(3, 0)],
		"White Land 4x4 grid exposes one start and two selectable boss cells")
	check(maze_blocks == 1 and quest_connections == 0 and spec_count == 0,
		"White Land consumes one ordinary layout with no fixed MAP specification")
	check(event_monster != null and int(event_monster[1][2]) == 9000
		and int(event_monster[2][2]) == 61728
		and seal_id != null and int(seal_id[0][2]) == 60029
		and seal_pos != null and [int(seal_pos[0][2]), int(seal_pos[1][2])] == [2, 1]
		and hell_value != null and int(hell_value[0][2]) == 1,
		"event monster 61728, seal door 60029 and hell mode remain preserved raw")

	for boss_slot in bosses.size():
		var case_maze := NativeMaze.new()
		check(case_maze.start(probe.data, SourceRolls.new([0, boss_slot, 0]), route.get("source", {})),
			"native maze starts with White Land boss candidate %d" % boss_slot)
		check(case_maze.room_count() == 10,
			"White Land boss candidate %d reaches all ten connected cells" % boss_slot)
	check(not NativeBoxLoot.required(dungeon), "White Land does not invent box item payloads")
	check(NativeJarTraps.ready(game.combat_assets), "shared source trap assets resolve")

	var boss_maps := {}
	for path: String in dungeon.get("rooms", {}):
		if path.ends_with("boss(0,0).map") or path.ends_with("boss(3,0).map"):
			var room: Dictionary = dungeon["rooms"][path]
			boss_maps[int(room["map_id"])] = room
	check(boss_maps.keys() == [9210, 9211],
		"White Land has exactly two source boss MAPs: " + str(boss_maps.keys()))
	for map_id: int in boss_maps:
		var room: Dictionary = boss_maps[map_id]
		var role := ""
		for span: Dictionary in room["raw"]:
			if span.get("tag") == "[type]":
				role = String(span["values"][0][2])
				break
		var boss_rows := Array(room.get("monsters", [])).filter(
			func(monster): return monster.get("raw", [])[-1] == "[boss]")
		check(role == "[boss]" and boss_rows.size() == 1
			and String(boss_rows[0].get("mob", "")) == "monster/newmonsters/snowman/sasquatch/sasquatch.mob",
			"source boss MAP has one Sasquatch boss row: " + str(map_id))

	var source_monsters := {}
	var source_monster_counts := {}
	var source_monster_count := 0
	var source_boss_rows := 0
	var source_object_count := 0
	var source_breakables := 0
	var source_itempockets := 0
	var source_icefields := 0
	var source_blizzards := 0
	var source_static := 0
	var source_box_objects := 0
	for room: Dictionary in dungeon.get("rooms", {}).values():
		for monster: Dictionary in room.get("monsters", []):
			var mob := String(monster.get("mob", ""))
			source_monsters[mob] = true
			source_monster_counts[mob] = 1 + int(source_monster_counts.get(mob, 0))
			source_monster_count += 1
			if Array(monster.get("raw", []))[-1] == "[boss]":
				source_boss_rows += 1
		for item: Dictionary in room.get("objects", []):
			source_object_count += 1
			if NativeBoxLoot.draw_count(item) > 0:
				source_box_objects += 1
			var path := String(item.get("obj", "")).to_lower()
			if NativeBreakable.supports(item) and not game.content.record(path).get("native_breakable", {}).is_empty():
				source_breakables += 1
			elif path.ends_with("/itempocket.obj"):
				source_itempockets += 1
			elif path.ends_with("/trap/icefield.obj"):
				source_icefields += 1
			elif path.ends_with("/particlefactory/blizzard.obj"):
				source_blizzards += 1
			else:
				source_static += 1
	check(source_monsters.size() == 7 and source_monster_count == 93 and source_boss_rows == 2,
		"White Land source has 93 direct placements, seven MOBs and two boss rows")
	check(source_monster_counts == {
		"monster/goblin/seagab.mob": 10,
		"monster/icetiger/icetiger.mob": 3,
		"monster/newmonsters/bantu/rabbitman/rabbitman.mob": 18,
		"monster/newmonsters/snowman/louis/louis.mob": 25,
		"monster/newmonsters/snowman/sasquatch/sasquatch.mob": 2,
		"monster/newmonsters/snowman/snowman/snowman.mob": 31,
		"monster/spirit/firehigherspirit.mob": 4,
	}, "White Land keeps the exact source monster counts")
	check(source_object_count == 265 and source_breakables == 93
		and source_itempockets == 6 and source_icefields == 5 and source_blizzards == 12
		and source_static == 149 and source_box_objects == 0,
		"White Land source has 265 objects: 93 breakables, six item pockets, "
		+ "five ice fields, 12 blizzards, 149 static objects and no box draws "
		+ "(objects=%d breakables=%d pockets=%d icefields=%d blizzards=%d static=%d boxes=%d)"
		% [source_object_count, source_breakables, source_itempockets,
			source_icefields, source_blizzards, source_static, source_box_objects])
	for mob: String in source_monsters:
		check(not game.table.monster_by_mob(mob).is_empty(),
			"direct source MOB has runtime content: " + mob)

	var banks := {
		"monster/goblin/seagab.mob": ["goblin_ice", 0, true],
		"monster/icetiger/icetiger.mob": ["icetiger_icetiger", 3, false],
		"monster/newmonsters/bantu/rabbitman/rabbitman.mob": ["newmonsters_bantu_rabbitman_rabbitman", 3, false],
		"monster/newmonsters/snowman/louis/louis.mob": ["newmonsters_snowman_louis_louis", 5, false],
		"monster/newmonsters/snowman/sasquatch/sasquatch.mob": ["newmonsters_snowman_sasquatch_sasquatch", 6, false],
		"monster/newmonsters/snowman/snowman/snowman.mob": ["newmonsters_snowman_snowman_snowman", 1, false],
		"monster/spirit/firehigherspirit.mob": ["spirit_firehigherspirit", 2, false],
	}
	for mob: String in banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		check(String(definition.get("bank", "")) == banks[mob][0]
			and game.combat_assets.get("monsters", {}).has(banks[mob][0]),
			"White Land source bank is compiled: " + mob)
		check(Array(definition.get("moves", [])).size() == int(banks[mob][1]),
			"source attack slots compile for %s (moves=%d expected=%d)"
			% [mob, Array(definition.get("moves", [])).size(), int(banks[mob][1])])
		if bool(banks[mob][2]):
			var projectile: Dictionary = definition.get("throw", {})
			check(not projectile.is_empty() and not Dictionary(projectile.get("object", {})).is_empty()
				and not Array(projectile.get("particles", [])).is_empty(),
				"source projectile object and PTL compile for " + mob)
		if int(banks[mob][1]) == 0:
			check(not Array(definition.get("attack_timeline", [])).is_empty(),
				"single source attack keeps its legacy timeline: " + mob)

	var flow := FlowSession.new()
	flow.profile["level"] = 47
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "whiteland"})["ok"],
		"flow departs the hidden White Land route")
	route = flow.active_dungeon_route()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live White Land run selects one ordinary boss cell")
	check(session._validate_native_maze(probe, live_maze),
		"White Land room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "whiteland", "route": route,
		"room_id": "whiteland:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source White Land room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 10
			and game.view_snapshot()["hud"]["route"].size() == 10,
			"both public battle views report the complete White Land graph")
		check(game.view.audio.has_dungeon_music("whiteland")
			and String(game.view.audio.music.stream.resource_path).ends_with("whiteland.ogg"),
			"White Land starts with the original M_WHITELAND track")

		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts,
			"White Land start room spawns its exact source monster lineup")

		var interactive_props := 0
		var box_props := 0
		var unknown_ids: Array[int] = []
		var all_gaps := {}
		for path: String in dungeon.get("rooms", {}).keys():
			var room: Dictionary = probe.room(path)
			var room_props: Array = game.build_props(room)
			interactive_props += room_props.size()
			for prop: Dictionary in room_props:
				if not (prop.get("box_items", []) as Array).is_empty():
					box_props += 1
				for source_id in prop.get("unresolved_trap_ids", []):
					if int(source_id) not in unknown_ids:
						unknown_ids.append(int(source_id))
			merge_gaps(all_gaps, game.native_object_gaps)
		unknown_ids.sort()
		check(interactive_props == 93,
			"all 93 source crystals and frozen trees build exactly once across 12 MAPs")
		check(box_props == 0, "White Land creates no item-box props")
		check(unknown_ids.is_empty(), "no executable breakable leaves an unresolved trap")
		var pocket: Array = all_gaps.get("passiveobject/mapobject/breakableobject/itempocket.obj", [])
		check("native_breakable_source" in pocket and "native_special_object" in pocket and 2211 in pocket,
			"item pocket remains an explicit breakable/special/2211 gap: " + str(pocket))
		check(all_gaps.get("passiveobject/actionobject/trap/icefield.obj", [])
			== ["native_object_trigger"], "ice field remains an explicit trigger gap")
		check(all_gaps.get("passiveobject/mapobject/particlefactory/blizzard.obj", [])
			== ["native_particle_factory"], "blizzard factory remains an explicit particle gap")
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_WHITELAND] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
