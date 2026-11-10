extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const FlowSession = preload("res://flow/session.gd")
const NativeMaze = preload("res://combat/data/native_maze.gd")
const NativeBreakable = preload("res://combat/resolve/native_breakable.gd")
const NativeBoxLoot = preload("res://loot/native_box.gd")
const NativeJarTraps = preload("res://combat/resolve/native_jar_traps.gd")
const DetRng = preload("res://core/det_rng.gd")

const SOURCE_SHA := "72925d7c530658a4a7f9a4196fe5dccbef11d068c327c4f0d77dff85d40f81d8"
const ROUTE_MAP_IDS := [6213, 6202, 6203, 6205, 6206, 6207, 6208, 6209, 6211]

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
		push_error("[NATIVE_MAZE_ASTRAYTHIEF] FAIL " + label)

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
	var route: Dictionary = routes["astraythief"]
	check(route.get("name") == "堕落的盗贼"
		and route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("region") == "noierfera"
		and int(route.get("min_level", 0)) == 48 and int(route.get("monster_level", 0)) == 51,
		"Astray Thief is a hidden level 48 Noierfera native-maze route with basis level 51")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production Astray Thief export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/act6/astraythief.dgn"
		and dungeon.get("sha256") == SOURCE_SHA,
		"Astray Thief export keeps the pinned DGN source identity")
	check(Array(dungeon.get("placements", [])).size() == 19
		and Dictionary(dungeon.get("rooms", {})).size() == 14
		and Dictionary(probe.data.get("images", {})).size() == 102,
		"Astray Thief export contains 19 placements, 14 MAPs and 102 source images")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	var errors: Array = diagnostics.filter(func(row): return row.get("level") == "error")
	var warnings: Array = diagnostics.filter(func(row): return row.get("level") == "warning")
	var infos: Array = diagnostics.filter(func(row): return row.get("level") == "info")
	var aa_warnings := 0
	var unhandled := 0
	var layout_absent: Array[String] = []
	for row: Dictionary in warnings:
		if row.get("code") == "cell_without_map" and String(row.get("detail", "")).contains(" code AA"):
			aa_warnings += 1
	for row: Dictionary in infos:
		if row.get("code") == "unhandled_tags":unhandled += 1
		if row.get("code") == "layout_absent":layout_absent.append(String(row.get("path", "")))
	check(errors.is_empty() and warnings.size() == 8 and infos.size() == 15
		and aa_warnings == 8 and unhandled == 14
		and layout_absent == ["map/astraythief/q6220.map"],
		"Astray Thief preserves eight AA cells, fourteen raw-tag MAPs "
		+ "and one layoutless quest MAP")

	var maze := NativeMaze.new()
	var size: Vector2i = maze._point(dungeon.get("size"))
	var cells: Dictionary = maze._read_cells(dungeon.get("cells"), size)
	var starts: Array = maze._read_endpoint_cells(dungeon.get("start_map_raw"), cells, "start_candidate")
	var bosses: Array = maze._read_endpoint_cells(dungeon.get("boss_map_raw"), cells, "boss_candidate")
	var specs: Dictionary = maze._read_specifications(dungeon.get("raw"), cells)
	var fixed_ids: Array[int] = []
	for point: Vector2i in specs.get("normal", {}):
		for map_id in specs["normal"][point]:fixed_ids.append(int(map_id))
	fixed_ids.sort()
	check(size == Vector2i(5, 4) and cells.size() == 20
		and starts == [Vector2i(3, 0)]
		and bosses == [Vector2i(4, 3), Vector2i(3, 2)],
		"Astray Thief is a 5x4 source grid with start (3,0) and bosses (4,3)/(3,2)")
	check(fixed_ids == [6202, 6203, 6205, 6206, 6207, 6208, 6209],
		"Astray Thief keeps seven ordinary MAP specifications")
	check(cells[Vector2i(3, 0)]["map_candidates"] == [
		"map/astraythief/b6202.map",
		"map/astraythief/h6204.map",
		"map/astraythief/s6201.map",
	], "the start cell preserves boss-layout alternatives and the start MAP")
	check(Array(dungeon["rooms"]["map/astraythief/h6204.map"].get("start_area", [])).size() == 4
		and Array(dungeon["rooms"]["map/astraythief/s6201.map"].get("start_area", [])).size() == 4,
		"both source start-area MAP variants remain eligible")
	check(cells[Vector2i(4, 3)]["map_candidates"] == [
		"map/astraythief/b6202.map",
		"map/astraythief/h6204.map",
		"map/astraythief/s6201.map",
	], "the first boss cell preserves its source candidate set")
	check(cells[Vector2i(3, 2)]["map_candidates"] == [
		"map/astraythief/b6201.map",
		"map/astraythief/h6203.map",
	], "the second boss cell preserves its source candidate set")
	check(dungeon["rooms"]["map/astraythief/s6201.map"].get("role_hint") == "start"
		and dungeon["rooms"]["map/astraythief/b6201.map"].get("role_hint") == "boss"
		and dungeon["rooms"]["map/astraythief/b6202.map"].get("role_hint") == "boss",
		"source start and boss MAPs keep their explicit role metadata")
	check(dungeon["rooms"]["map/astraythief/q6220.map"].get("greed_pairs") == [],
		"the q6220 quest MAP remains raw without an ordinary [greed] layout")

	var boss_specs := 0
	var boss_map = null
	var seal_id = null
	var seal_pos = null
	var seal_rate = null
	var event_monster = null
	var hell_value = null
	var special_items = null
	var champion = null
	for span: Dictionary in dungeon.get("raw", []):
		var tag := String(span.get("tag", ""))
		var values: Array = span.get("values", [])
		if tag == "[boss map specification]":boss_specs += 1
		if tag == "[boss map]":boss_map = values
		if tag == "[seal door map index]":seal_id = values
		if tag == "[seal door pos]":seal_pos = values
		if tag == "[seal door appear rate]":seal_rate = values
		if tag == "[event monster]":event_monster = values
		if tag == "[hell dungeon]":hell_value = values
		if tag == "[special passive object item]":special_items = values
		if tag == "[champion]":champion = values
	check(boss_specs == 0 and boss_map != null
		and [int(boss_map[0][2]), int(boss_map[1][2]), int(boss_map[2][2]), int(boss_map[3][2])]
			== [4, 3, 3, 2],
		"Astray Thief keeps two boss cells without inventing boss map specifications")
	check(event_monster != null and int(event_monster[1][2]) == 10000
		and int(event_monster[2][2]) == 61728
		and seal_id != null and int(seal_id[0][2]) == 60018
		and seal_pos != null and [int(seal_pos[0][2]), int(seal_pos[1][2])] == [1, 3]
		and seal_rate != null and int(seal_rate[0][2]) == 1
		and hell_value != null and int(hell_value[0][2]) == 1,
		"event monster 61728, seal door 60018 at (1,3) and hell mode remain preserved raw")
	check(champion != null and Array(champion).map(func(token): return int(token[2]))
		== [6, 12, 18, 24, 26],
		"Astray Thief preserves the five source champion thresholds")
	check(special_items != null and int(special_items[0][2]) == 0
		and int(special_items[1][2]) == -1 and int(special_items[2][2]) == 3
		and [int(special_items[3][2]), int(special_items[5][2]), int(special_items[7][2])]
			== [1089, 1090, 3217]
		and int(special_items[9][2]) == 1 and int(special_items[11][2]) == 1
		and int(special_items[12][2]) == 3217,
		"Astray Thief preserves its three-item ordinary group and one-item second group")

	var fixed_maze := NativeMaze.new()
	check(fixed_maze.start(probe.data, SourceRolls.new([0, 0, 0]), route.get("source", {})),
		"native maze starts Astray Thief with the first source boss cell")
	check(fixed_maze.room_count() == 12,
		"Astray Thief reaches all twelve connected cells")
	var selected_ids: Array[int] = [int(fixed_maze.current_room().get("source_map_id", 0))]
	var moves := ["left", "left", "down", "right", "down", "down", "right", "right"]
	for step in moves.size():
		var current: Vector2i = fixed_maze.current_room().get("cell", Vector2i(-1, -1))
		var cleared: Dictionary = fixed_maze.clear_room(current, 0)
		var moved: Dictionary = fixed_maze.move(moves[step])
		check(not cleared.is_empty() and not moved.is_empty(),
			"Astray Thief clears and traverses source step %d" % step)
		selected_ids.append(int(moved.get("source_map_id", 0)))
	check(selected_ids == ROUTE_MAP_IDS,
		"Astray Thief first boss route selects MAPs 6213,6202..6203,6205..6209,6211")
	if selected_ids != ROUTE_MAP_IDS:
		push_error("[NATIVE_MAZE_ASTRAYTHIEF] DETAIL route=" + str(selected_ids))
	var final_clear: Dictionary = fixed_maze.clear_room(Vector2i(4, 3), 0)
	check(bool(final_clear.get("boss", false)) and bool(final_clear.get("final_room", false)),
		"the selected 6211 room is a boss and final room")

	var source_monsters := {}
	var source_monster_counts := {}
	var source_monster_count := 0
	var source_boss_rows := 0
	var source_object_count := 0
	var source_breakable_candidates := 0
	var source_runtime_breakables := 0
	var source_traps := 0
	var source_static := 0
	var source_box_objects := 0
	for room: Dictionary in dungeon.get("rooms", {}).values():
		for monster: Dictionary in room.get("monsters", []):
			var mob := String(monster.get("mob", ""))
			source_monsters[mob] = true
			source_monster_counts[mob] = 1 + int(source_monster_counts.get(mob, 0))
			source_monster_count += 1
			if Array(monster.get("raw", []))[-1] == "[boss]":source_boss_rows += 1
		for item: Dictionary in room.get("objects", []):
			source_object_count += 1
			var path := String(item.get("obj", "")).to_lower()
			if NativeBreakable.supports(item):
				source_breakable_candidates += 1
				if not game.content.record(path).get("native_breakable", {}).is_empty():
					source_runtime_breakables += 1
				if NativeJarTraps.candidate_rows(item).is_empty() and item.get("source_tag") == "[special passive object]":
					for at in range(5, Array(item.get("raw", [])).size(), 6):
						if item["raw"][at] == "[item]":source_box_objects += 1
			elif path.contains("/trap/"):
				source_traps += 1
			else:
				source_static += 1
	check(source_monsters.size() == 9 and source_monster_count == 141 and source_boss_rows == 2,
		"Astray Thief has 141 direct placements, nine MOBs and two boss rows")
	check(source_monster_counts == {
		"monster/dog/dog.mob": 62,
		"monster/thief/thiefmale.mob": 26,
		"monster/thief/thieffemale.mob": 20,
		"monster/thief/thiefmalemad.mob": 16,
		"monster/statue/statue.mob": 12,
		"monster/thief/myojin.mob": 2,
		"monster/cityhallgate/cityhallgate.mob": 1,
		"monster/thief/hakudo.mob": 1,
		"monster/thief/thiefghostrunner.mob": 1,
	}, "Astray Thief keeps the exact source monster counts")
	check(source_object_count == 118 and source_breakable_candidates == 9
		and source_runtime_breakables == 9 and source_traps == 5
		and source_static == 104 and source_box_objects == 4,
		"Astray Thief has 118 objects: 9 executable breakables, "
		+ "5 trap paths, 104 static/special and four source item draws "
		+ "(objects=%d candidates=%d runtime=%d traps=%d static=%d boxes=%d)"
		% [source_object_count, source_breakable_candidates, source_runtime_breakables,
			source_traps, source_static, source_box_objects])

	var banks := {
		"monster/dog/dog.mob": ["dog_dog", 2],
		"monster/thief/thiefmale.mob": ["thief_thiefmale", 3],
		"monster/thief/thieffemale.mob": ["thief_thieffemale", 5],
		"monster/thief/thiefmalemad.mob": ["thief_thiefmalemad", 3],
		"monster/statue/statue.mob": ["statue_statue", 0],
		"monster/thief/myojin.mob": ["thief_myojin", 8],
		"monster/cityhallgate/cityhallgate.mob": ["cityhallgate_cityhallgate", 0],
		"monster/thief/hakudo.mob": ["thief_hakudo", 6],
		"monster/thief/thiefghostrunner.mob": ["thief_thiefghostrunner", 6],
	}
	for mob: String in banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		check(String(definition.get("bank", "")) == banks[mob][0]
			and game.combat_assets.get("monsters", {}).has(banks[mob][0]),
			"Astray Thief source bank is compiled: " + mob)
		check(Array(definition.get("moves", [])).size() == int(banks[mob][1]),
			"Astray Thief attack slots compile for %s (moves=%d expected=%d)"
			% [mob, Array(definition.get("moves", [])).size(), int(banks[mob][1])])

	var content: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://assets_local/content/combat_content.json"))
	var expected_attack_infos := {
		"monster/dog/dog.mob": 2,
		"monster/thief/thiefmale.mob": 3,
		"monster/thief/thieffemale.mob": 5,
		"monster/thief/thiefmalemad.mob": 3,
		"monster/statue/statue.mob": 1,
		"monster/thief/myojin.mob": 8,
		"monster/cityhallgate/cityhallgate.mob": 1,
		"monster/thief/hakudo.mob": 5,
		"monster/thief/thiefghostrunner.mob": 6,
	}
	for mob: String in expected_attack_infos:
		var decoded: Dictionary = content["records"][mob]["decoded"]
		check(Array(decoded.get("attack_infos", [])).size() == expected_attack_infos[mob],
			"Astray Thief preserves source ATK row count for " + mob)

	check(NativeBoxLoot.required(dungeon),
		"Astray Thief detects its ordinary statue item draws")
	check(NativeBoxLoot.ready(dungeon),
		"Astray Thief group 0 and v9 original item images resolve")
	var statue_item := {}
	for item: Dictionary in dungeon["rooms"]["map/astraythief/e6201.map"]["objects"]:
		if String(item.get("obj", "")).ends_with("/act6statue1.obj"):
			statue_item = item
			break
	check(not statue_item.is_empty() and NativeBoxLoot.draw_count(statue_item) == 1,
		"the ordinary statue item draw resolves through the active v9 group")
	check(NativeBoxLoot.pick(0, "0") == "original_1089"
		and NativeBoxLoot.pick(1000, "0") == "original_1090"
		and NativeBoxLoot.pick(2000, "0") == "original_3217"
		and NativeBoxLoot.pick(3000, "0") == "",
		"Astray Thief group 0 preserves its three equal source weights")
	var prepared: Array[String] = []
	for seed in 32:
		prepared = NativeBoxLoot.prepare(1, seed, "0")
		if not prepared.is_empty():break
	check(prepared.size() == 1
		and prepared[0] in ["original_1089", "original_1090", "original_3217"],
		"Astray Thief group 0 prepares one pinned source item: " + str(prepared))
	check(NativeJarTraps.ready(game.combat_assets), "shared source trap assets resolve")

	var flow := FlowSession.new()
	flow.profile["level"] = 51
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "astraythief"})["ok"],
		"flow departs the hidden Astray Thief route")
	route = flow.active_dungeon_route()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live Astray Thief run selects one source boss layout")
	check(session._validate_native_maze(probe, live_maze),
		"Astray Thief room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "astraythief", "route": route,
		"room_id": "astraythief:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source Astray Thief room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 12
			and game.view_snapshot()["hud"]["route"].size() == 12,
			"both public battle views report the complete Astray Thief graph")
		check(game.view.audio.has_dungeon_music("astraythief")
			and String(game.view.audio.music.stream.resource_path).ends_with("thief.ogg"),
			"Astray Thief starts with the original M_THIEF track")
		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts,
			"Astray Thief start room spawns its exact source monster lineup")
		check(NativeBoxLoot.draw_count(statue_item) == 1,
			"starting the battle does not clear the active Astray Thief box group")

		var placed_maps := {}
		for placement: Dictionary in dungeon.get("placements", []):
			placed_maps[String(placement.get("map", ""))] = true
		check(not placed_maps.has("map/astraythief/q6220.map"),
			"layoutless q6220 remains outside ordinary MAP placements")
		var interactive_props := 0
		var placed_props := 0
		var box_props := 0
		var placed_box_props := 0
		var placed_box_draws := 0
		var unknown_ids: Array[int] = []
		var all_gaps := {}
		for path: String in dungeon.get("rooms", {}).keys():
			var room: Dictionary = probe.room(path)
			var room_props: Array = game.build_props(room)
			interactive_props += room_props.size()
			if placed_maps.has(path):placed_props += room_props.size()
			if placed_maps.has(path):
				for item: Dictionary in room.get("objects", []):
					if NativeBoxLoot.draw_count(item) > 0:placed_box_draws += 1
			for prop: Dictionary in room_props:
				if not (prop.get("box_items", []) as Array).is_empty():
					box_props += 1
					if placed_maps.has(path):placed_box_props += 1
				for source_id in prop.get("unresolved_trap_ids", []):
					if int(source_id) not in unknown_ids:unknown_ids.append(int(source_id))
				check(not String(prop.get("source_path", "")).contains("/trap/"),
					"trap trigger is not materialised as a contact hazard")
			merge_gaps(all_gaps, game.native_object_gaps)
		unknown_ids.sort()
		check(interactive_props == 9 and placed_props == 6,
			"nine source breakables compile, with six reachable in ordinary placements")
		check(source_box_objects == 4 and placed_box_draws == 3
			and box_props <= 4 and placed_box_props <= 3
			and placed_box_props <= box_props,
			"four source item draws compile, with three ordinary-placement candidates "
			+ "and only source-weighted non-empty rolls materialised")
		if (
			source_box_objects != 4 or placed_box_draws != 3 or box_props > 4
			or placed_box_props > 3 or placed_box_props > box_props
		):
			push_error("[NATIVE_MAZE_ASTRAYTHIEF] DETAIL draws=%d placed=%d boxes=%d placed_boxes=%d"
				% [source_box_objects, placed_box_draws, box_props, placed_box_props])
		check(unknown_ids == [2211],
			"the unsupported act6box 2211 row is recorded without execution: " + str(unknown_ids))
		check(all_gaps.get("passiveobject/mapobject/breakableobject/act6box.obj", []) == [2211],
			"act6box remains a breakable with an explicit unresolved trap payload")
		check(all_gaps.get("passiveobject/mapobject/trap/act6dogpost.obj", [])
			== ["native_object_trigger"],
			"act6 dog posts remain source trigger gaps")
		check(all_gaps.get("passiveobject/mapobject/breakableobject/epicquestrescueshylockquestcage.obj", [])
			== ["native_special_object"],
			"q6220 rescue cage remains an explicit quest special-object gap")
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_ASTRAYTHIEF] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
