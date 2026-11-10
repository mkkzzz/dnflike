extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const FlowSession = preload("res://flow/session.gd")
const NativeMaze = preload("res://combat/data/native_maze.gd")
const NativeBreakable = preload("res://combat/resolve/native_breakable.gd")
const NativeBoxLoot = preload("res://loot/native_box.gd")
const NativeJarTraps = preload("res://combat/resolve/native_jar_traps.gd")
const DetRng = preload("res://core/det_rng.gd")

const SOURCE_SHA := "882dc960c67fc9378e11b20e2331ad628cf012f78cc581c6e2f463280461524e"
const ROUTE_MAP_IDS := [16000, 16001, 16002, 16003, 16006, 16007, 16008, 16009]

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
		push_error("[NATIVE_MAZE_AGANZO] FAIL " + label)

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
	var route: Dictionary = routes["aganzo"]
	check(route.get("name") == "月光酒馆"
		and route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("region") == "noierfera"
		and int(route.get("min_level", 0)) == 49 and int(route.get("monster_level", 0)) == 52,
		"Moonlight Tavern is a hidden level 49 Noierfera native-maze route with basis level 52")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production Moonlight Tavern export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/village/moonlightpub/aganzo.dgn"
		and dungeon.get("sha256") == SOURCE_SHA,
		"Moonlight Tavern export keeps the pinned DGN source identity")
	check(Array(dungeon.get("placements", [])).size() == 21
		and Dictionary(dungeon.get("rooms", {})).size() == 13
		and Dictionary(probe.data.get("images", {})).size() == 95,
		"Moonlight Tavern export contains 21 placements, 13 MAPs and 95 source images")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	var errors: Array = diagnostics.filter(func(row): return row.get("level") == "error")
	var warnings: Array = diagnostics.filter(func(row): return row.get("level") == "warning")
	var infos: Array = diagnostics.filter(func(row): return row.get("level") == "info")
	var unrendered := 0
	var aa_warnings := 0
	var unhandled := 0
	var selected_diag := ""
	for row: Dictionary in warnings:
		if row.get("code") == "object_unrendered":unrendered += 1
		if row.get("code") == "cell_without_map" and String(row.get("detail", "")).contains(" code AA"):
			aa_warnings += 1
	for row: Dictionary in infos:
		if row.get("code") == "unhandled_tags":unhandled += 1
		if row.get("code") == "maze_block_selected":
			selected_diag = String(row.get("detail", ""))
	check(errors.is_empty() and warnings.size() == 145 and infos.size() == 14
		and unrendered == 135 and aa_warnings == 10 and unhandled == 13
		and selected_diag.contains("selected maze block 4 of 6"),
		"Moonlight Tavern preserves 135 unrendered action objects, ten AA cells "
		+ "and the selected ordinary maze block")

	check(dungeon.get("maze_block_index") == 4
		and Array(dungeon.get("maze_blocks", [])).size() == 6,
		"Moonlight Tavern records all six source maze blocks and selects block four")
	var sizes: Array = []
	var selected: Array[int] = []
	var ordinary: Array[int] = []
	for block: Dictionary in dungeon.get("maze_blocks", []):
		var block_size: Array = block.get("size", [])
		sizes.append([int(block_size[0]), int(block_size[1])])
		if block.get("selected"):selected.append(int(block.get("index", -1)))
		if (
			not block.get("quest_connection") and not block.get("escape_hell")
			and not block.get("hell_dungeon")
		):
			ordinary.append(int(block.get("index", -1)))
	check(str(sizes) == "[[2, 1], [2, 1], [5, 1], [5, 2], [5, 4], [5, 4]]",
		"Moonlight Tavern preserves the six source maze block sizes")
	check(selected == [4] and ordinary == [4],
		"Moonlight Tavern keeps five quest/hell variants and one ordinary block")
	var selected_block: Dictionary = dungeon["maze_blocks"][4]
	var selected_specs: Array[int] = []
	for row: Array in selected_block.get("map_specifications", []):selected_specs.append(int(row[2]))
	check(selected_specs == [16005, 16003, 16002, 16001, 16006, 16007, 16008],
		"the ordinary block preserves seven normal MAP specifications")
	var boss_specs: Array = selected_block.get("boss_map_specifications", [])
	var boss_spec: Array = boss_specs[0] if boss_specs.size() == 1 else []
	check(boss_spec.size() == 3 and int(boss_spec[0]) == 3
		and int(boss_spec[1]) == 3 and int(boss_spec[2]) == 16009,
		"the ordinary block preserves its boss MAP specification")
	var seal_index: Array = selected_block.get("seal_door_map_index", [])
	check(seal_index.size() == 1 and int(seal_index[0]) == 60039,
		"the ordinary block keeps seal door 60039")
	var seal_pos: Array = selected_block.get("seal_door_pos", [])
	check(seal_pos.size() == 2 and int(seal_pos[0]) == 3 and int(seal_pos[1]) == 1
		and selected_block.get("escape_hell") == null
		and selected_block.get("hell_dungeon") == null,
		"the ordinary block keeps its seal door while excluding quest/hell markers")

	var maze := NativeMaze.new()
	var size: Vector2i = maze._point(dungeon.get("size"))
	var cells: Dictionary = maze._read_cells(dungeon.get("cells"), size)
	var starts: Array = maze._read_endpoint_cells(dungeon.get("start_map_raw"), cells, "start_candidate")
	var bosses: Array = maze._read_endpoint_cells(dungeon.get("boss_map_raw"), cells, "boss_candidate")
	check(size == Vector2i(5, 4) and cells.size() == 20
		and starts == [Vector2i(4, 1)] and bosses == [Vector2i(3, 3)],
		"Moonlight Tavern selects the ordinary 5x4 grid with start (4,1) and boss (3,3)")
	var connected_cells := 0
	for cell: Dictionary in cells.values():
		if cell.get("code") != "AA":connected_cells += 1
	check(connected_cells == 10,
		"Moonlight Tavern ordinary block has ten connected cells")
	check(cells[Vector2i(4, 1)]["map_candidates"] == [
		"map/aganzo/(3.3)aganzoboss.map",
		"map/aganzo/(4,1)aganzostart.map",
	], "the start cell preserves the boss-layout alternative and start MAP")
	check(cells[Vector2i(3, 3)]["map_candidates"] == [
		"map/aganzo/(3.3)aganzoboss.map",
		"map/aganzo/(4,1)aganzostart.map",
	], "the boss cell preserves the source candidate pair")
	check(dungeon["rooms"]["map/aganzo/(4,1)aganzostart.map"].get("role_hint") == "start"
		and dungeon["rooms"]["map/aganzo/(3.3)aganzoboss.map"].get("role_hint") == "boss",
		"source start and boss MAPs use their MAP type instead of filename prefixes")

	var raw_event = null
	var raw_hell = null
	for span: Dictionary in dungeon.get("raw", []):
		if span.get("tag") == "[event monster]":raw_event = span.get("values")
		if span.get("tag") == "[hell dungeon]":raw_hell = span.get("values")
	check(raw_event != null and int(raw_event[1][2]) == 1300
		and int(raw_event[2][2]) == 61728
		and raw_hell != null and int(raw_hell[0][2]) == 1,
		"event monster 61728 in MAP 1300 and the final hell variant remain raw")

	var fixed_maze := NativeMaze.new()
	check(fixed_maze.start(probe.data, SourceRolls.new([0, 0, 0]), route.get("source", {})),
		"native maze starts the selected Moonlight Tavern ordinary block")
	check(fixed_maze.room_count() == 10,
		"Moonlight Tavern reaches all ten connected cells")
	var selected_ids: Array[int] = [int(fixed_maze.current_room().get("source_map_id", 0))]
	var moves := ["left", "left", "left", "down", "down", "right", "right"]
	for step in moves.size():
		var current: Vector2i = fixed_maze.current_room().get("cell", Vector2i(-1, -1))
		var cleared: Dictionary = fixed_maze.clear_room(current, 0)
		var moved: Dictionary = fixed_maze.move(moves[step])
		check(not cleared.is_empty() and not moved.is_empty(),
			"Moonlight Tavern clears and traverses source step %d" % step)
		selected_ids.append(int(moved.get("source_map_id", 0)))
	check(selected_ids == ROUTE_MAP_IDS,
		"Moonlight Tavern ordinary route selects MAPs 16000..16003,16006..16009")
	if selected_ids != ROUTE_MAP_IDS:
		push_error("[NATIVE_MAZE_AGANZO] DETAIL route=" + str(selected_ids))
	var final_clear: Dictionary = fixed_maze.clear_room(Vector2i(3, 3), 0)
	check(bool(final_clear.get("boss", false)) and bool(final_clear.get("final_room", false)),
		"the selected 16009 room is the sole boss and final room")

	var source_monsters := {}
	var source_monster_counts := {}
	var source_monster_count := 0
	var source_boss_rows := 0
	var route_monster_count := 0
	var route_monster_counts := {}
	var route_maps := {
		"map/aganzo/(4,1)aganzostart.map": true,
		"map/aganzo/(3.1)aganzo.map": true,
		"map/aganzo/(2.1)aganzo.map": true,
		"map/aganzo/(1.1)aganzo.map": true,
		"map/aganzo/(1.2)aganzo.map": true,
		"map/aganzo/(1.3)aganzo.map": true,
		"map/aganzo/(2.3)aganzo.map": true,
		"map/aganzo/(3.3)aganzoboss.map": true,
	}
	var source_object_count := 0
	var source_breakable_candidates := 0
	var source_runtime_breakables := 0
	var source_traps := 0
	var source_static := 0
	var route_object_count := 0
	var route_breakable_candidates := 0
	for path: String in dungeon.get("rooms", {}):
		var room: Dictionary = dungeon["rooms"][path]
		for monster: Dictionary in room.get("monsters", []):
			var mob := String(monster.get("mob", ""))
			source_monsters[mob] = true
			source_monster_counts[mob] = 1 + int(source_monster_counts.get(mob, 0))
			source_monster_count += 1
			if route_maps.has(path):
				route_monster_count += 1
				route_monster_counts[mob] = 1 + int(route_monster_counts.get(mob, 0))
			if Array(monster.get("raw", []))[-1] == "[boss]":source_boss_rows += 1
		for item: Dictionary in room.get("objects", []):
			source_object_count += 1
			var source_path := String(item.get("obj", "")).to_lower()
			if NativeBreakable.supports(item):
				source_breakable_candidates += 1
				if route_maps.has(path):route_breakable_candidates += 1
				if not game.content.record(source_path).get("native_breakable", {}).is_empty():
					source_runtime_breakables += 1
			elif source_path.contains("/trap/"):
				source_traps += 1
			else:
				source_static += 1
			if route_maps.has(path):route_object_count += 1
	check(source_monsters.size() == 5 and source_monster_count == 104 and source_boss_rows == 0,
		"Moonlight Tavern has 104 direct placements, five MOBs and no [boss] source rows")
	check(source_monster_counts == {
		"monster/newmonsters/aganzo/gang2/gang2.mob": 40,
		"monster/newmonsters/aganzo/gang/gang.mob": 23,
		"monster/newmonsters/aganzo/pubman/gang3.mob": 20,
		"monster/newmonsters/aganzo/cutpurse/cutpurse.mob": 19,
		"monster/newmonsters/aganzo/sinead/sinead.mob": 2,
	}, "Moonlight Tavern keeps the exact source monster counts")
	check(route_monster_count == 62 and route_monster_counts == {
		"monster/newmonsters/aganzo/gang2/gang2.mob": 20,
		"monster/newmonsters/aganzo/gang/gang.mob": 9,
		"monster/newmonsters/aganzo/pubman/gang3.mob": 12,
		"monster/newmonsters/aganzo/cutpurse/cutpurse.mob": 19,
		"monster/newmonsters/aganzo/sinead/sinead.mob": 2,
	}, "the ordinary route preserves its exact 62-monster lineup")
	check(source_object_count == 204 and source_breakable_candidates == 137
		and source_runtime_breakables == 2 and source_traps == 0
		and source_static == 67,
		"Moonlight Tavern has 204 source objects: 137 breakable candidates, "
		+ "two runtime contracts and 67 static objects")
	check(route_object_count == 106 and route_breakable_candidates == 82,
		"the ordinary route contains 106 objects and 82 unresolved breakable candidates")

	var banks := {
		"monster/newmonsters/aganzo/gang2/gang2.mob": ["newmonsters_aganzo_gang2_gang2", 2],
		"monster/newmonsters/aganzo/gang/gang.mob": ["newmonsters_aganzo_gang_gang", 3],
		"monster/newmonsters/aganzo/pubman/gang3.mob": ["newmonsters_aganzo_pubman_gang3", 1],
		"monster/newmonsters/aganzo/cutpurse/cutpurse.mob": ["newmonsters_aganzo_cutpurse_cutpurse", 2],
		"monster/newmonsters/aganzo/sinead/sinead.mob": ["newmonsters_aganzo_sinead_sinead", 6],
	}
	for mob: String in banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		check(String(definition.get("bank", "")) == banks[mob][0]
			and game.combat_assets.get("monsters", {}).has(banks[mob][0]),
			"Moonlight Tavern source bank is compiled: " + mob)
		check(Array(definition.get("moves", [])).size() == int(banks[mob][1]),
			"Moonlight Tavern attack slots compile for %s (moves=%d expected=%d)"
			% [mob, Array(definition.get("moves", [])).size(), int(banks[mob][1])])

	var content: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://assets_local/content/combat_content.json"))
	var expected_attack_infos := {
		"monster/newmonsters/aganzo/gang2/gang2.mob": 2,
		"monster/newmonsters/aganzo/gang/gang.mob": 3,
		"monster/newmonsters/aganzo/pubman/gang3.mob": 1,
		"monster/newmonsters/aganzo/cutpurse/cutpurse.mob": 2,
		"monster/newmonsters/aganzo/sinead/sinead.mob": 5,
	}
	for mob: String in expected_attack_infos:
		var decoded: Dictionary = content["records"][mob]["decoded"]
		check(Array(decoded.get("attack_infos", [])).size() == expected_attack_infos[mob],
			"Moonlight Tavern preserves source ATK row count for " + mob)

	check(not NativeBoxLoot.required(dungeon),
		"Moonlight Tavern has no ordinary box item group")
	check(NativeJarTraps.ready(game.combat_assets), "shared source trap assets resolve")
	var bgm: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/bgm.json"))
	check(bgm["dungeons"]["aganzo"] == {"normal": "aganzo", "boss": "aganzo"}
		and bgm["tracks"].has("aganzo"),
		"both source music cues resolve to the pinned aganzo.ogg track")

	var flow := FlowSession.new()
	flow.profile["level"] = 52
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "aganzo"})["ok"],
		"flow departs the hidden Moonlight Tavern route")
	route = flow.active_dungeon_route()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live Moonlight Tavern run selects the ordinary block")
	check(session._validate_native_maze(probe, live_maze),
		"Moonlight Tavern room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "aganzo", "route": route,
		"room_id": "aganzo:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source Moonlight Tavern room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 10
			and game.view_snapshot()["hud"]["route"].size() == 10,
			"both public battle views report the ordinary Moonlight Tavern graph")
		check(game.view.audio.has_dungeon_music("aganzo")
			and String(game.view.audio.music.stream.resource_path).ends_with("aganzo.ogg"),
			"Moonlight Tavern starts with the source M_AGANZO track")
		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts,
			"Moonlight Tavern start room spawns its exact source monster lineup")

		var interactive_props := 0
		var route_props := 0
		var unknown_ids: Array[int] = []
		var all_gaps := {}
		for path: String in dungeon.get("rooms", {}).keys():
			var room: Dictionary = probe.room(path)
			var room_props: Array = game.build_props(room)
			interactive_props += room_props.size()
			if route_maps.has(path):route_props += room_props.size()
			for prop: Dictionary in room_props:
				for source_id in prop.get("unresolved_trap_ids", []):
					if int(source_id) not in unknown_ids:unknown_ids.append(int(source_id))
			merge_gaps(all_gaps, game.native_object_gaps)
		unknown_ids.sort()
		check(interactive_props == 2 and route_props == 0,
			"two treasure boxes build outside the ordinary route; the route has no executable props")
		check(unknown_ids == [2211],
			"Moonlight Tavern records unsupported 2211 trap rows without execution")
		for path in [
			"passiveobject/actionobject/breakableobject/aganzo_chair.obj",
			"passiveobject/actionobject/breakableobject/aganzo_siktak.obj",
			"passiveobject/actionobject/breakableobject/aganzo_namutong.obj",
		]:
			var expected: Array = ["native_breakable_source"]
			if path.ends_with("/aganzo_namutong.obj"):
				expected.append_array(["native_special_object", 2211])
			check(all_gaps.get(path, []) == expected,
				"Moonlight Tavern action furniture keeps its explicit source gap: " + path)
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_AGANZO] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
