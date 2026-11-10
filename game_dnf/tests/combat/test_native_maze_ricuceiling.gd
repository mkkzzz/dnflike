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
		push_error("[NATIVE_MAZE_RICUCEILING] FAIL " + label)

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
	var route: Dictionary = routes["ricuceiling"]
	check(route.get("name") == "利库天井"
		and route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("region") == "snowmt"
		and int(route.get("min_level", 0)) == 43 and int(route.get("monster_level", 0)) == 46,
		"Ricu Ceiling is a hidden level 43 Snow Mountain native-maze route with source basis level 46")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production Ricu Ceiling export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/act5/ricuceiling.dgn"
		and dungeon.get("sha256") == "e4ca542dfdbb447d5b3382fcb506e47ba20348b455bb14d8fb816cd62247f01a",
		"Ricu Ceiling export keeps the pinned DGN source identity")
	check(Array(dungeon.get("placements", [])).size() == 15
		and Dictionary(dungeon.get("rooms", {})).size() == 12
		and Dictionary(probe.data.get("images", {})).size() == 94,
		"Ricu Ceiling export contains 15 greed placements, 12 MAPs and 94 source images")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	var errors: Array = diagnostics.filter(func(row): return row.get("level") == "error")
	var warnings: Array = diagnostics.filter(func(row): return row.get("level") == "warning")
	var infos: Array = diagnostics.filter(func(row): return row.get("level") == "info")
	var aa_warnings := 0
	var unrendered := 0
	for row: Dictionary in warnings:
		if row.get("code") == "cell_without_map" and String(row.get("detail", "")).contains(" code AA"):
			aa_warnings += 1
		if row.get("code") == "object_unrendered":
			unrendered += 1
	check(errors.is_empty() and warnings.size() == 38 and aa_warnings == 10
		and unrendered == 28 and infos.size() == 73,
		"Ricu Ceiling preserves ten AA cells and 28 source objects without rendered sprites")

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
	check(cells.size() == 20 and starts == [Vector2i(1, 3)]
		and bosses == [Vector2i(2, 1), Vector2i(3, 0)],
		"Ricu Ceiling 5x4 grid exposes one start and two selectable boss cells")
	check(maze_blocks == 1 and quest_connections == 0 and spec_count == 8,
		"Ricu Ceiling consumes one ordinary layout with eight fixed normal MAP rows")
	check(event_monster != null and int(event_monster[2][2]) == 61728
		and seal_id != null and int(seal_id[0][2]) == 60029
		and seal_pos != null and [int(seal_pos[0][2]), int(seal_pos[1][2])] == [0, 2]
		and hell_value != null and int(hell_value[0][2]) == 1,
		"event monster 61728, seal door 60029 and hell mode remain preserved raw")

	for boss_slot in bosses.size():
		var case_maze := NativeMaze.new()
		check(case_maze.start(probe.data, SourceRolls.new([0, boss_slot, 0]), route.get("source", {})),
			"native maze starts with boss candidate %d" % boss_slot)
		check(case_maze.room_count() == 10,
			"boss candidate %d reaches all ten connected cells" % boss_slot)
	check(not NativeBoxLoot.required(dungeon), "Ricu Ceiling does not invent box item payloads")
	check(NativeJarTraps.ready(game.combat_assets), "shared source trap assets resolve")

	var boss_map_ids := []
	for path: String in dungeon.get("rooms", {}):
		if path.contains("ricuboss"):
			var room: Dictionary = dungeon["rooms"][path]
			var role := ""
			for span: Dictionary in room.get("raw", []):
				if span.get("tag") == "[type]":
					role = String(span["values"][0][2])
					break
			var boss_rows := Array(room.get("monsters", [])).filter(
				func(monster): return monster.get("raw", [])[-1] == "[boss]")
			boss_map_ids.append(int(room["map_id"]))
			check(role == "[boss]" and boss_rows.size() == 1,
				"source boss MAP has [type] boss and one [boss] monster row: " + path)
	check(boss_map_ids == [9004, 9007],
		"Ricu Ceiling has exactly two source boss MAP variants: " + str(boss_map_ids))
	var first_boss_maze := NativeMaze.new()
	first_boss_maze.start(probe.data, SourceRolls.new([0, 0, 0]), route.get("source", {}))
	var first_pools: Dictionary = first_boss_maze._pools
	var second_boss_maze := NativeMaze.new()
	second_boss_maze.start(probe.data, SourceRolls.new([0, 1, 0]), route.get("source", {}))
	var second_pools: Dictionary = second_boss_maze._pools
	check([int(first_pools[Vector2i(2, 1)][0]["map_id"])] == [9004]
		and [int(second_pools[Vector2i(3, 0)][0]["map_id"])] == [9007],
		"boss-row fallback filters ordinary same-layout MAPs from each selected boss cell")

	var source_monsters := {}
	var source_monster_counts := {}
	var source_monster_count := 0
	var source_boss_rows := 0
	var source_object_count := 0
	var source_breakables := 0
	var source_itempockets := 0
	var source_triggers := 0
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
			elif path.contains("/trap/"):
				source_triggers += 1
			else:
				source_static += 1
	check(source_monsters.size() == 12 and source_monster_count == 68 and source_boss_rows == 2,
		"Ricu Ceiling source has 68 direct placements, 12 MOBs and two boss rows")
	check(source_monster_counts == {
		"monster/bantu/bantuamazones.mob": 4,
		"monster/bantu/bantufighter.mob": 12,
		"monster/bantu/tower_bantuelite.mob": 2,
		"monster/goblin/flagseagab.mob": 6,
		"monster/goblin/seagab.mob": 6,
		"monster/newmonsters/bantu/wolfpatriarch/turmanbash.mob": 1,
		"monster/newmonsters/goblin/throwgoblin/goblinthrower.mob": 1,
		"monster/newmonsters/golem/icegolem/icegolem.mob": 17,
		"monster/newmonsters/golem/icewavegolem/icewavegolem.mob": 2,
		"monster/newmonsters/golem/ricu/ricu.mob": 2,
		"monster/newmonsters/golem/stormgolem/stormgolem.mob": 3,
		"monster/newmonsters/spider/slotorblind/slotorblind.mob": 12,
	}, "Ricu Ceiling keeps the exact source monster counts")
	check(source_object_count == 244 and source_breakables == 63
		and source_itempockets == 2 and source_triggers == 35
		and source_static == 144 and source_box_objects == 0,
		"Ricu Ceiling source has 244 objects: 63 breakables, two item pockets, "
		+ "35 behavior triggers, 144 static objects and no box draws "
		+ "(objects=%d breakables=%d pockets=%d triggers=%d static=%d boxes=%d)"
		% [source_object_count, source_breakables, source_itempockets,
			source_triggers, source_static, source_box_objects])
	for mob: String in source_monsters:
		check(not game.table.monster_by_mob(mob).is_empty(),
			"direct source MOB has runtime content: " + mob)

	var banks := {
		"monster/bantu/bantufighter.mob": ["bantu_bantufighter", 3, false],
		"monster/bantu/bantuamazones.mob": ["bantu_bantuamazones", 5, true],
		"monster/bantu/tower_bantuelite.mob": ["bantu_tower_bantuelite", 4, false],
		"monster/goblin/flagseagab.mob": ["goblin_flagseagab", 0, false],
		"monster/goblin/seagab.mob": ["goblin_ice", 0, true],
		"monster/newmonsters/bantu/wolfpatriarch/turmanbash.mob": ["newmonsters_bantu_wolfpatriarch_turmanbash", 10, false],
		"monster/newmonsters/goblin/throwgoblin/goblinthrower.mob": ["newmonsters_goblin_throwgoblin_goblinthrower", 3, false],
		"monster/newmonsters/golem/icegolem/icegolem.mob": ["newmonsters_golem_icegolem_icegolem", 1, false],
		"monster/newmonsters/golem/icewavegolem/icewavegolem.mob": ["newmonsters_golem_icewavegolem_icewavegolem", 2, false],
		"monster/newmonsters/golem/ricu/ricu.mob": ["newmonsters_golem_ricu_ricu", 9, false],
		"monster/newmonsters/golem/stormgolem/stormgolem.mob": ["newmonsters_golem_stormgolem_stormgolem", 2, false],
		"monster/newmonsters/spider/slotorblind/slotorblind.mob": ["newmonsters_spider_slotorblind_slotorblind", 2, false],
	}
	for mob: String in banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		check(String(definition.get("bank", "")) == banks[mob][0]
			and game.combat_assets.get("monsters", {}).has(banks[mob][0]),
			"Ricu Ceiling source bank is compiled: " + mob)
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
	flow.profile["level"] = 46
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "ricuceiling"})["ok"],
		"flow departs the hidden Ricu Ceiling route")
	route = flow.active_dungeon_route()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live Ricu Ceiling run selects one ordinary boss cell")
	check(live_maze.room_count() == 10,
		"live Ricu Ceiling graph contains ten rooms")
	check(session._validate_native_maze(probe, live_maze),
		"Ricu Ceiling room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "ricuceiling", "route": route,
		"room_id": "ricuceiling:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source Ricu Ceiling room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 10
			and game.view_snapshot()["hud"]["route"].size() == 10,
			"both public battle views report the complete Ricu Ceiling graph")
		check(game.view.audio.has_dungeon_music("ricuceiling")
			and String(game.view.audio.music.stream.resource_path).ends_with("riku_cave.ogg"),
			"Ricu Ceiling starts with the M_RIKU_CAVE normal track")

		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts,
			"Ricu Ceiling start room spawns its exact source monster lineup")

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
		check(interactive_props == 63,
			"all 63 source crystals and frozen trees build exactly once across 12 MAPs")
		check(box_props == 0, "Ricu Ceiling creates no item-box props")
		check(unknown_ids.is_empty(), "no executable breakable leaves an unresolved trap")
		var pocket: Array = all_gaps.get("passiveobject/mapobject/breakableobject/itempocket.obj", [])
		check("native_breakable_source" in pocket and "native_special_object" in pocket and 2211 in pocket,
			"item pocket remains an explicit breakable/special/2211 gap: " + str(pocket))
		for path in [
			"passiveobject/actionobject/trap/eventbarrier_3.obj",
			"passiveobject/actionobject/trap/snowcatapult.obj",
			"passiveobject/mapobject/trap/ricuniddle.obj",
			"passiveobject/mapobject/trap/snowfallmanager2.obj",
		]:
			check(all_gaps.get(path, []) == ["native_object_trigger"],
				"source behavior trigger remains an explicit gap: " + path)
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_RICUCEILING] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
