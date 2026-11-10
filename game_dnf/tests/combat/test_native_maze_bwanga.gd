extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const FlowSession = preload("res://flow/session.gd")
const NativeMaze = preload("res://combat/data/native_maze.gd")
const NativeBreakable = preload("res://combat/resolve/native_breakable.gd")
const NativeBoxLoot = preload("res://loot/native_box.gd")
const NativeJarTraps = preload("res://combat/resolve/native_jar_traps.gd")
const DetRng = preload("res://core/det_rng.gd")

const SOURCE_SHA := "87a37cd9a924747b4a7ab422e4ac4788a26c9443716c5acafad572f96cac6021"
const FIRST_MAP_IDS := [16010, 16011, 16012, 16013, 16014, 16015, 16016, 16017, 16018, 16019]

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
		push_error("[NATIVE_MAZE_BWANGA] FAIL " + label)

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
	var route: Dictionary = routes["bwanga"]
	check(route.get("name") == "布万加的修炼场"
		and route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("region") == "snowmt"
		and int(route.get("min_level", 0)) == 45 and int(route.get("monster_level", 0)) == 48,
		"Bwanga is a hidden level 45 Snow Mountain native-maze route with basis level 48")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production Bwanga export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/act5/bwanga.dgn"
		and dungeon.get("sha256") == SOURCE_SHA,
		"Bwanga export keeps the pinned DGN source identity")
	check(Array(dungeon.get("placements", [])).size() == 116
		and Dictionary(dungeon.get("rooms", {})).size() == 15
		and Dictionary(probe.data.get("images", {})).size() == 84,
		"Bwanga export contains 116 placements, 15 MAPs and 84 source images")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	var errors: Array = diagnostics.filter(func(row): return row.get("level") == "error")
	var warnings: Array = diagnostics.filter(func(row): return row.get("level") == "warning")
	var infos: Array = diagnostics.filter(func(row): return row.get("level") == "info")
	var warning_unrendered := 0
	var empty_tiles := 0
	for row: Dictionary in warnings:
		if row.get("code") == "object_unrendered":warning_unrendered += 1
	for row: Dictionary in infos:
		if row.get("code") == "empty_tile":empty_tiles += 1
	check(errors.is_empty() and warnings.size() == 3 and infos.size() == 75
		and warning_unrendered == 3 and empty_tiles == 60,
		"Bwanga preserves 60 empty-tile rows, 75 info rows and three unrendered totem warnings")

	var maze := NativeMaze.new()
	var size: Vector2i = maze._point(dungeon.get("size"))
	var cells: Dictionary = maze._read_cells(dungeon.get("cells"), size)
	var starts: Array = maze._read_endpoint_cells(dungeon.get("start_map_raw"), cells, "start_candidate")
	var bosses: Array = maze._read_endpoint_cells(dungeon.get("boss_map_raw"), cells, "boss_candidate")
	var specs: Dictionary = maze._read_specifications(dungeon.get("raw"), cells)
	var normal_specs: Dictionary = specs.get("normal", {})
	var boss_specs: Dictionary = specs.get("boss", {})
	var normal_ids: Array[int] = []
	var boss_ids: Array[int] = []
	for point: Vector2i in normal_specs:
		for map_id in normal_specs[point]:normal_ids.append(int(map_id))
	for point: Vector2i in boss_specs:
		for map_id in boss_specs[point]:boss_ids.append(int(map_id))
	normal_ids.sort()
	boss_ids.sort()
	check(size == Vector2i(10, 1) and cells.size() == 10
		and starts == [Vector2i(0, 0)] and bosses == [Vector2i(9, 0)],
		"Bwanga is a ten-cell source row with start (0,0) and boss (9,0)")
	check(normal_ids == [16011, 16012, 16013, 16014, 16015, 16016, 16017, 16018]
		and boss_ids == [16019],
		"the first maze uses eight fixed ordinary MAPs and boss MAP 16019")

	var maze_blocks := 0
	var first_normal_specs: Array[int] = []
	var first_boss_specs: Array[int] = []
	var quest_ids: Array[int] = []
	var all_boss_specs: Array[int] = []
	var seal_ids: Array[int] = []
	var seal_positions: Array = []
	var event_monster = null
	var hell_value = null
	var escape_hell = null
	var ai_characters: Array = []
	for span: Dictionary in dungeon.get("raw", []):
		var tag := String(span.get("tag", ""))
		var values: Array = span.get("values", [])
		if tag == "[maze info]":maze_blocks += 1
		if tag == "[map specification]" and maze_blocks == 1:
			first_normal_specs.append(int(values[2][2]))
		if tag == "[boss map specification]":
			all_boss_specs.append(int(values[2][2]))
			if maze_blocks == 1:first_boss_specs.append(int(values[2][2]))
		if tag == "[quest connection]":quest_ids.append(int(values[1][2]))
		if tag == "[seal door map index]":seal_ids.append(int(values[0][2]))
		if tag == "[seal door pos]":seal_positions.append([int(values[0][2]), int(values[1][2])])
		if tag == "[event monster]":event_monster = values
		if tag == "[hell dungeon]":hell_value = values
		if tag == "[escape hell]":escape_hell = values
	check(maze_blocks == 7 and quest_ids == [4002, 4003, 4004, 4005, 4006, 4007],
		"Bwanga preserves the ordinary maze plus six quest 4002..4007 layouts")
	check(first_normal_specs == [16011, 16012, 16013, 16014, 16015, 16016, 16017, 16018]
		and first_boss_specs == [16019]
		and all_boss_specs == [16019, 16020, 16021, 16022, 16023, 16024, 16019],
		"quest boss MAPs 16020..16024 remain outside the ordinary first layout")
	check(seal_ids == [60020, 60020, 60020, 60020, 60020, 60031]
		and seal_positions.size() == 6 and seal_positions[0] == [8, 0],
		"ordinary/quest seals 60020 and the final hell seal 60031 stay in source order")
	check(event_monster != null and int(event_monster[2][2]) == 61728
		and hell_value != null and int(hell_value[0][2]) == 1
		and escape_hell != null and int(escape_hell[0][2]) == 1,
		"event monster 61728, hell and escape-hell flags remain preserved raw")

	for path: String in dungeon.get("rooms", {}):
		var room: Dictionary = dungeon["rooms"][path]
		if int(room.get("map_id", 0)) not in [16018, 16024]:continue
		for span: Dictionary in room.get("raw", []):
			if span.get("tag") == "[ai character]":
				ai_characters.append(int(span["values"][0][2]))
	check(ai_characters == [20607, 20607],
		"both water-spirit rooms preserve source AI character 20607 as an explicit gap")

	var fixed_maze := NativeMaze.new()
	check(fixed_maze.start(probe.data, SourceRolls.new([0, 0, 0]), route.get("source", {})),
		"native maze starts the sole ordinary Bwanga layout")
	check(fixed_maze.room_count() == 10, "Bwanga ordinary route reaches all ten source cells")
	var selected_ids: Array[int] = [int(fixed_maze.current_room().get("source_map_id", 0))]
	for step in 9:
		var cleared: Dictionary = fixed_maze.clear_room(
			Vector2i(selected_ids.size() - 1, 0), 0)
		var moved: Dictionary = fixed_maze.move("right")
		check(not cleared.is_empty() and not moved.is_empty(),
			"Bwanga clears and traverses source step %d" % step)
		selected_ids.append(int(moved.get("source_map_id", 0)))
	check(selected_ids == FIRST_MAP_IDS,
		"Bwanga first run selects source MAPs 16010..16019 in order")
	var final_clear: Dictionary = fixed_maze.clear_room(Vector2i(9, 0), 0)
	check(bool(final_clear.get("boss", false)) and bool(final_clear.get("final_room", false)),
		"the selected 16019 room is the sole ordinary boss and final room")

	var source_monsters := {}
	var source_monster_counts := {}
	var source_monster_count := 0
	var source_boss_rows := 0
	var source_object_count := 0
	var source_breakable_candidates := 0
	var source_itempockets := 0
	var source_static := 0
	var source_box_objects := 0
	for room: Dictionary in dungeon.get("rooms", {}).values():
		if int(room.get("map_id", 0)) not in FIRST_MAP_IDS:continue
		for monster: Dictionary in room.get("monsters", []):
			var mob := String(monster.get("mob", ""))
			source_monsters[mob] = true
			source_monster_counts[mob] = 1 + int(source_monster_counts.get(mob, 0))
			source_monster_count += 1
			if Array(monster.get("raw", []))[-1] == "[boss]":source_boss_rows += 1
		for item: Dictionary in room.get("objects", []):
			source_object_count += 1
			if NativeBoxLoot.draw_count(item) > 0:source_box_objects += 1
			var path := String(item.get("obj", "")).to_lower()
			if NativeBreakable.supports(item):
				source_breakable_candidates += 1
				if path.ends_with("/itempocket.obj"):source_itempockets += 1
			else:
				source_static += 1
	check(source_monsters.size() == 10 and source_monster_count == 57 and source_boss_rows == 1,
		"Bwanga first run has 57 direct placements, ten MOBs and one boss row")
	check(source_monster_counts == {
		"monster/newmonsters/bantu/rabbitman/rabbitman.mob": 12,
		"monster/newmonsters/bantu/_rabbitbird/rabbitbird.mob": 1,
		"monster/newmonsters/bantu/buffaloman/buffaloman.mob": 12,
		"monster/newmonsters/bantu/_buffalomalaga/buffalomalaga.mob": 1,
		"monster/newmonsters/bantu/buffalowoman/buffalowoman.mob": 11,
		"monster/newmonsters/bantu/_buffalorari/buffalorari.mob": 1,
		"monster/newmonsters/bantu/rabbitwoman/rabbitwoman.mob": 14,
		"monster/newmonsters/bantu/_rabbitmedusa/rabbitmedusa.mob": 1,
		"monster/spirit/waterhigherspirit.mob": 3,
		"monster/newmonsters/bwanga/bwanga.mob": 1,
	}, "Bwanga keeps the exact first-run source monster counts")
	check(source_object_count == 93 and source_breakable_candidates == 6
		and source_itempockets == 3 and source_static == 87 and source_box_objects == 0,
		"Bwanga first run keeps 93 objects: six breakable candidates, "
		+ "three item pockets, 87 static objects and no item draws "
		+ "(objects=%d candidates=%d pockets=%d static=%d boxes=%d)"
		% [source_object_count, source_breakable_candidates, source_itempockets, source_static, source_box_objects])

	var banks := {
		"monster/newmonsters/bantu/rabbitman/rabbitman.mob": ["newmonsters_bantu_rabbitman_rabbitman", 3],
		"monster/newmonsters/bantu/_rabbitbird/rabbitbird.mob": ["newmonsters_bantu__rabbitbird_rabbitbird", 6],
		"monster/newmonsters/bantu/buffaloman/buffaloman.mob": ["newmonsters_bantu_buffaloman_buffaloman", 4],
		"monster/newmonsters/bantu/_buffalomalaga/buffalomalaga.mob": ["newmonsters_bantu__buffalomalaga_buffalomalaga", 8],
		"monster/newmonsters/bantu/buffalowoman/buffalowoman.mob": ["newmonsters_bantu_buffalowoman_buffalowoman", 2],
		"monster/newmonsters/bantu/_buffalorari/buffalorari.mob": ["newmonsters_bantu__buffalorari_buffalorari", 5],
		"monster/newmonsters/bantu/rabbitwoman/rabbitwoman.mob": ["newmonsters_bantu_rabbitwoman_rabbitwoman", 2],
		"monster/newmonsters/bantu/_rabbitmedusa/rabbitmedusa.mob": ["newmonsters_bantu__rabbitmedusa_rabbitmedusa", 6],
		"monster/spirit/waterhigherspirit.mob": ["spirit_waterhigherspirit", 2],
		"monster/newmonsters/bwanga/bwanga.mob": ["newmonsters_bwanga_bwanga", 12],
	}
	for mob: String in banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		check(String(definition.get("bank", "")) == banks[mob][0]
			and game.combat_assets.get("monsters", {}).has(banks[mob][0]),
			"Bwanga source bank is compiled: " + mob)
		check(Array(definition.get("moves", [])).size() == int(banks[mob][1]),
			"Bwanga source attack slots compile for %s (moves=%d expected=%d)"
			% [mob, Array(definition.get("moves", [])).size(), int(banks[mob][1])])
	var medusa_source: Dictionary = game.content.record(
		"monster/newmonsters/bantu/_rabbitmedusa/rabbitmedusa.mob")
	check(Array(medusa_source.get("decoded", {}).get("attack_actions", [])).size() == 8
		and Array(game.table.monsters.get(
			game.table.monster_by_mob("monster/newmonsters/bantu/_rabbitmedusa/rabbitmedusa.mob"), {}
		).get("moves", [])).size() == 6,
		"Rabbit Medusa keeps eight source slots while two ACTs without BASE ANI remain unavailable")

	var boss_definition: Dictionary = game.table.monsters.get(
		game.table.monster_by_mob("monster/newmonsters/bwanga/bwanga.mob"), {})
	var boss_stems: Array[String] = []
	for move: Dictionary in boss_definition.get("moves", []):boss_stems.append(String(move.get("stem", "")))
	check(boss_stems == [
		"5bbatta_ready", "5bbatta_loop", "combo1", "combo2", "combo3",
		"combo4_hardattack", "jumpandcrash", "casting_superarmor", "superarmorend",
		"teleport", "overthestar_up", "overthestar_shoot",
	], "Bwanga [action list] keeps all twelve source attack actions in slot order")
	var expected_cooltimes := [3000.0, 0.0, 1200.0, 0.0, 0.0, 0.0, 15000.0, 25000.0, 0.0, 20000.0, 5000.0, 5000.0]
	var cooltimes: Array[float] = []
	for move: Dictionary in boss_definition.get("moves", []):
		cooltimes.append(float(move.get("cool_ms", -1.0)))
	check(cooltimes == expected_cooltimes,
		"Bwanga twelve action slots retain their source cooldowns")
	var atk_slots: Array[int] = []
	for index in Array(boss_definition.get("moves", [])).size():
		var move: Dictionary = boss_definition["moves"][index]
		if not String(move.get("atk_path", "")).is_empty():atk_slots.append(index)
	check(atk_slots == [0, 1, 2, 3, 4, 5, 6, 10, 11],
		"Bwanga attack-info slots 7..9 remain action-only and aligned")
	check(not NativeBoxLoot.required(dungeon),
		"Bwanga does not invent box loot from trap-only item pockets")
	check(NativeJarTraps.ready(game.combat_assets), "shared source trap assets resolve")

	var flow := FlowSession.new()
	flow.profile["level"] = 48
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "bwanga"})["ok"],
		"flow departs the hidden Bwanga route")
	route = flow.active_dungeon_route()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live Bwanga run selects its sole ordinary layout")
	check(session._validate_native_maze(probe, live_maze),
		"Bwanga room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "bwanga", "route": route,
		"room_id": "bwanga:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source Bwanga room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 10
			and game.view_snapshot()["hud"]["route"].size() == 10,
			"both public battle views report the complete Bwanga graph")
		check(game.view.audio.has_dungeon_music("bwanga")
			and String(game.view.audio.music.stream.resource_path).ends_with("bwanga.ogg"),
			"Bwanga starts with the original M_BWANGA track")
		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts,
			"Bwanga start room spawns its exact source monster lineup")

		var interactive_props := 0
		var box_props := 0
		var all_gaps := {}
		for path: String in dungeon.get("rooms", {}).keys():
			var room: Dictionary = probe.room(path)
			if int(room.get("map_id", 0)) not in FIRST_MAP_IDS:continue
			var room_props: Array = game.build_props(room)
			interactive_props += room_props.size()
			for prop: Dictionary in room_props:
				if not (prop.get("box_items", []) as Array).is_empty():box_props += 1
			merge_gaps(all_gaps, game.native_object_gaps)
		check(interactive_props == 0 and box_props == 0,
			"Bwanga does not invent runtime breakables or box loot without source contracts")
		var totem_gap: Array = all_gaps.get(
			"passiveobject/actionobject/breakableobject/bwanga_totem.obj", [])
		var totem1_gap: Array = all_gaps.get(
			"passiveobject/actionobject/breakableobject/bwanga_totem1.obj", [])
		var pocket_gap: Array = all_gaps.get(
			"passiveobject/mapobject/breakableobject/itempocket.obj", [])
		check(totem_gap == ["native_breakable_source"]
			and totem1_gap == ["native_breakable_source"],
			"Bwanga totems remain explicit native-breakable gaps")
		check("native_breakable_source" in pocket_gap
			and "native_special_object" in pocket_gap and 2211 in pocket_gap,
			"Bwanga item pockets remain breakable/special/2211 gaps: " + str(pocket_gap))
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_BWANGA] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
