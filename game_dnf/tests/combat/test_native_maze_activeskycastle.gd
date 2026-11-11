extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const FlowSession = preload("res://flow/session.gd")
const NativeMaze = preload("res://combat/data/native_maze.gd")
const NativeBreakable = preload("res://combat/resolve/native_breakable.gd")
const NativeBoxLoot = preload("res://loot/native_box.gd")
const NativeJarTraps = preload("res://combat/resolve/native_jar_traps.gd")
const NativePotMonsters = preload("res://combat/resolve/native_pot_monsters.gd")
const DetRng = preload("res://core/det_rng.gd")
const ROUTE_MAP_IDS: Array[int] = [16200, 16201, 16202, 16203, 16204, 16205]

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
		push_error("[NATIVE_MAZE_ACTIVESKYCASTLE] FAIL " + label)

func raw_values(spans: Array, tag: String) -> Array:
	for span: Dictionary in spans:
		if span.get("tag") != tag:
			continue
		var result: Array = []
		for token in span.get("values", []):
			if token is Array and token.size() >= 3:
				result.append(int(token[2]))
		return result
	return []

func room_role(room: Dictionary) -> String:
	for span: Dictionary in room.get("raw", []):
		if span.get("tag") != "[type]":
			continue
		var values: Array = span.get("values", [])
		if values.size() == 1 and values[0] is Array and values[0].size() >= 3:
			return String(values[0][2])
	return ""

func rule_skills(definition: Dictionary) -> Array[int]:
	var result: Array[int] = []
	for rule: Dictionary in Array(definition.get("rules", [])):
		result.append(int(rule.get("skill", -1)))
	return result

func run() -> void:
	game = session.mount(root)
	game.set_process(false)
	game.set_physics_process(false)
	var routes: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/dungeons.json"))["dungeons"]
	var route: Dictionary = routes["activeskycastle"]
	check(route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("name") == "真·天空之城" and route.get("region") == "dimension"
		and int(route.get("min_level", 0)) == 60
		and int(route.get("monster_level", 0)) == 60,
		"Active Sky Castle is a hidden level 60 native route")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])),
		"production Active Sky Castle export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/impossible/activeskycastle.dgn"
		and dungeon.get("sha256") == "bbe82a8a5cd3785d56f21c133a91be18274f077899badd0f8af6207e222f915e"
		and int(dungeon.get("index", -1)) == 63,
		"Active Sky Castle keeps DGN index 63 and the pinned source identity")
	check(Array(dungeon.get("placements", [])).size() == 18
		and Dictionary(dungeon.get("rooms", {})).size() == 6
		and Dictionary(probe.data.get("images", {})).size() == 80,
		"Active Sky Castle retains six rooms and 80 source images")
	check(int(dungeon.get("maze_block_index", -1)) == 0
		and dungeon.get("maze_block_selection") == "ordinary"
		and Array(dungeon.get("maze_blocks", [])).size() == 1,
		"Active Sky Castle selects its ordinary block")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	check(diagnostics.filter(func(row): return row.get("level") == "error").is_empty(),
		"Active Sky Castle has no source image or ANI errors")
	check(diagnostics.filter(func(row): return row.get("code") == "object_unrendered").size() == 5,
		"Active Sky Castle preserves five unrendered behavior objects")
	check(diagnostics.filter(func(row): return row.get("code") == "unhandled_tags").size() == 6,
		"Active Sky Castle preserves six MAP tag reports")

	var maze := NativeMaze.new()
	var size: Vector2i = maze._point(dungeon.get("size"))
	var cells: Dictionary = maze._read_cells(dungeon.get("cells"), size)
	var starts: Array = maze._read_endpoint_cells(dungeon.get("start_map_raw"), cells, "start_candidate")
	var bosses: Array = maze._read_endpoint_cells(dungeon.get("boss_map_raw"), cells, "boss_candidate")
	var specs: Dictionary = maze._read_specifications(dungeon.get("raw"), cells, 0)
	check(size == Vector2i(6, 1) and cells.size() == 6
		and starts == [Vector2i(0, 0)] and bosses == [Vector2i(5, 0)],
		"Active Sky Castle exposes one start and one boss endpoint")
	for cell_x in range(1, 5):
		check(specs.get("normal", {}).get(Vector2i(cell_x, 0)) == [16201 + cell_x - 1],
			"ordinary cell %d binds its source MAP" % cell_x)
	check(specs.get("normal", {}).get(Vector2i(5, 0)) == [16205]
		and specs.get("boss", {}).is_empty(),
		"boss cell binds source MAP 16205 as the source's normal specification")
	check(raw_values(dungeon.get("raw", []), "[necessary party]") == [3]
		and raw_values(dungeon.get("raw", []), "[dimension dungeon]") == [2, 3]
		and raw_values(dungeon.get("raw", []), "[coin limit]") == [8],
		"source party, dimension and coin fields remain raw")
	check(raw_values(dungeon.get("raw", []), "[champion]") == [0, 0, 0, 0, 0],
		"source champion thresholds remain zero")
	check(raw_values(dungeon.get("raw", []), "[pathgate object]")
		== [411, 412, 413, 414, 415, 416, 417, 418, 419, 420],
		"source pathgate object list remains intact")

	var all_monsters := {}
	var all_monster_count := 0
	var all_boss_rows := 0
	var all_objects := []
	var all_breakable_rows := 0
	var npc_rows := 0
	var ai_character_rows := 0
	var ai_spans := 0
	for room: Dictionary in dungeon.get("rooms", {}).values():
		for monster: Dictionary in room.get("monsters", []):
			all_monsters[String(monster.get("mob", ""))] = true
			all_monster_count += 1
			var raw: Array = monster.get("raw", [])
			if not raw.is_empty() and raw[-1] == "[boss]":
				all_boss_rows += 1
		for item: Dictionary in room.get("objects", []):
			all_objects.append(item)
			if NativeBreakable.supports(item):
				all_breakable_rows += 1
		for span: Dictionary in room.get("raw", []):
			if span.get("tag") == "[NPC]":
				npc_rows += 1
			elif span.get("tag") == "[ai character]":
				ai_character_rows += 1
			elif span.get("tag") == "[monster specific AI]":
				ai_spans += 1
	check(all_monsters.size() == 18 and all_monster_count == 36 and all_boss_rows == 1,
		"Active Sky Castle retains 36 monsters across eighteen MOBs and one boss row")
	check(all_objects.size() == 35 and all_breakable_rows == 6,
		"Active Sky Castle retains 35 objects with six breakable-shaped rows")
	check(npc_rows == 1 and ai_character_rows == 0 and ai_spans == 6,
		"Active Sky Castle retains one boss NPC and six MAP AI spans")
	var object_counts := {
		"passiveobject/mapobject/trap/flappingbanner.obj": 14,
		"passiveobject/mapobject/trap/crystalpillar.obj": 6,
		"passiveobject/actionobject/obstacle/marble_column03.obj": 4,
		"passiveobject/actionobject/breakableobject/rscbigjar.obj": 4,
		"passiveobject/mapobject/breakableobject/skycastle_squarebox.obj": 2,
		"passiveobject/actionobject/obstacle/sky_flash.obj": 1,
		"passiveobject/actionobject/obstacle/sky_flash1.obj": 1,
		"passiveobject/actionobject/obstacle/sky_flash2.obj": 1,
		"passiveobject/actionobject/monster/lizardman/lizard_stonebody5.obj": 1,
		"passiveobject/actionobject/monster/lizardman/lizard_stonebody3.obj": 1,
	}
	for path: String in object_counts:
		var count := 0
		for item: Dictionary in all_objects:
			if String(item.get("obj", "")).to_lower() == path:
				count += 1
		check(count == int(object_counts[path]),
			"source object count matches for " + path)
	check(not Dictionary(game.content.record(
		"passiveobject/mapobject/breakableobject/skycastle_squarebox.obj"
	).get("native_breakable", {})).is_empty(),
		"skycastle square box has a source-backed breakable definition")
	for path: String in [
		"passiveobject/actionobject/breakableobject/rscbigjar.obj",
		"passiveobject/mapobject/trap/flappingbanner.obj",
		"passiveobject/mapobject/trap/crystalpillar.obj",
	]:
		check(Dictionary(game.content.record(path).get("native_breakable", {})).is_empty(),
			"unimplemented object remains explicit without guessed breakable data: " + path)
	check(not NativeBoxLoot.required(dungeon),
		"Active Sky Castle has no DGN item drop group")

	var banks := {
		"monster/newmonsters/realsky/minius/minius.mob":
			["newmonsters_realsky_minius_minius", 6, [0, 2], [5, 0, 4, 3, 2]],
		"monster/newmonsters/realsky/mirkius/mirkius.mob":
			["newmonsters_realsky_mirkius_mirkius", 5, [0, 2], [4, 2]],
		"monster/newmonsters/dollmaster/teleport/body.mob":
			["newmonsters_dollmaster_teleport_body", 1, [0], [0]],
		"monster/newmonsters/dollmaster/underdog/body.mob":
			["newmonsters_dollmaster_underdog_body", 1, [0], [0]],
		"monster/newmonsters/dollmaster/calamary/body.mob":
			["newmonsters_dollmaster_calamary_body", 1, [0], [0]],
		"monster/newmonsters/dollmaster/lobotomy/body.mob":
			["newmonsters_dollmaster_lobotomy_body", 1, [0], [0]],
		"monster/newmonsters/lizardman/lizard_man/lizard_man.mob":
			["newmonsters_lizardman_lizard_man_lizard_man", 10,
			[0, 1, 2, 3, 4, 5, 6], [9, 0, 1, 5]],
		"monster/newmonsters/lizardman/dragon_man/dragon_man.mob":
			["newmonsters_lizardman_dragon_man_dragon_man", 10,
			[0, 1, 2, 3, 4, 5, 6], [0, 1, 5]],
		"monster/newmonsters/lizardman/avengers/tispone/body.mob":
			["newmonsters_lizardman_avengers_tispone_body", 5, [0, 3], [1]],
		"monster/newmonsters/lizardman/avengers/megaira/body.mob":
			["newmonsters_lizardman_avengers_megaira_body", 6, [0, 4, 5], [5]],
		"monster/newmonsters/lizardman/avengers/alecto/body.mob":
			["newmonsters_lizardman_avengers_alecto_body", 8, [6], [2, 1, 0, 5, 4, 3]],
		"monster/newmonsters/draconian/magneus/magneus.mob":
			["newmonsters_draconian_magneus_magneus", 14, [8, 9, 10, 13], []],
		"monster/newmonsters/lizardman/lizardman_guard/lizardman_guard.mob":
			["newmonsters_lizardman_lizardman_guard_lizardman_guard", 5, [3], [3]],
		"monster/newmonsters/lizardman/lizardman_guard/lizardman_guard01.mob":
			["newmonsters_lizardman_lizardman_guard_lizardman_guard01", 5, [3], [3]],
		"monster/newmonsters/lizardman/lizardman_guard/lizardman_guard02.mob":
			["newmonsters_lizardman_lizardman_guard_lizardman_guard02", 5, [3], [3]],
		"monster/newmonsters/lizardman/lizardman_guard/lizardman_guard03.mob":
			["newmonsters_lizardman_lizardman_guard_lizardman_guard03", 5, [3], [3]],
		"monster/newmonsters/lizardman/lizardman_guard/lizardman_guard04.mob":
			["newmonsters_lizardman_lizardman_guard_lizardman_guard04", 5, [3], [3]],
		"monster/newmonsters/lizardman/basilisk/basilisk.mob":
			["newmonsters_lizardman_basilisk_basilisk", 19,
			[0, 5, 7, 8, 14, 15, 16, 18], []],
	}
	var total_moves := 0
	for mob: String in banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		check(String(definition.get("bank", "")) == banks[mob][0]
			and game.combat_assets.get("monsters", {}).has(banks[mob][0]),
			"Active Sky Castle source bank is compiled: " + mob)
		var moves: Array = Array(definition.get("moves", []))
		total_moves += moves.size()
		check(moves.size() == int(banks[mob][1]),
			"source action slots compile for %s (moves=%d expected=%d)"
			% [mob, moves.size(), int(banks[mob][1])])
		var atk_slots: Array[int] = []
		for index in moves.size():
			var move: Dictionary = moves[index]
			if not move.has("atk_path"):
				continue
			atk_slots.append(index)
			check(not game.table.atk(String(move["atk_path"])).is_empty()
				and not Array(move.get("timeline", [])).is_empty(),
				"source action and ATK compile together at %s slot %d" % [mob, index])
		check(atk_slots == banks[mob][2],
			"source attack-bearing slots match for %s (%s)" % [mob, atk_slots])
		check(rule_skills(definition) == banks[mob][3],
			"source AI priority compiles for %s (%s)" % [mob, rule_skills(definition)])
	check(total_moves == 112,
		"Active Sky Castle compiles 112 source action slots")
	check(NativeJarTraps.ready(game.combat_assets),
		"shared verified jar trap assets resolve")

	var bgm: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/bgm.json"))
	check(bgm.get("dungeons", {}).get("activeskycastle", {}).get("normal") == "skycastle"
		and bgm.get("dungeons", {}).get("activeskycastle", {}).get("boss") == "skycastle_boss"
		and not bgm.get("source_gaps", {}).has("activeskycastle"),
		"Active Sky Castle maps both source skycastle tracks")

	var maze_run := NativeMaze.new()
	check(maze_run.start(probe.data, SourceRolls.new([0, 0, 0, 0, 0, 0, 0, 0]),
		route.get("source", {})),
		"generic native maze starts Active Sky Castle")
	var selected_ids: Array[int] = [int(maze_run.current_room().get("source_map_id", 0))]
	check(maze_run.room_count() == 6, "Active Sky Castle exposes six source rooms")
	for step in 5:
		var cell: Vector2i = maze_run.current_room().get("cell", Vector2i(-1, -1))
		var cleared: Dictionary = maze_run.clear_room(cell, 0)
		var moved: Dictionary = maze_run.move("right")
		check(not cleared.is_empty() and not moved.is_empty(),
			"Active Sky Castle clears and traverses source step %d" % step)
		selected_ids.append(int(moved.get("source_map_id", 0)))
	check(selected_ids == ROUTE_MAP_IDS,
		"Active Sky Castle selects MAP 16200..16205 in source order")
	var final_clear: Dictionary = maze_run.clear_room(Vector2i(5, 0), 0)
	check(bool(final_clear.get("boss", false)) and bool(final_clear.get("final_room", false)),
		"the Basilisk room is the six-room route's final room")

	var box_room: Dictionary = probe.room("map/realskycastle/realskycastle02.map")
	var jar_room: Dictionary = probe.room("map/realskycastle/realskycastle03.map")
	var trap_room: Dictionary = probe.room("map/realskycastle/realskycastle04.map")
	check(box_room.get("objects", []).size() == 4
		and jar_room.get("objects", []).size() == 11
		and trap_room.get("objects", []).size() == 8,
		"source object distribution remains fixed across rooms")

	var flow := FlowSession.new()
	flow.profile["level"] = 60
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "activeskycastle"})["ok"],
		"flow departs the hidden Active Sky Castle route")
	route = flow.active_dungeon_route()
	NativePotMonsters.reset_catalog()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})),
		"live Active Sky Castle run selects its source start and boss")
	NativePotMonsters.prepare_catalog(dungeon, SourceRolls.new([0, 0, 0, 0]))
	check(session._validate_native_maze(probe, live_maze),
		"Active Sky Castle room, MOB, object and particle dependencies validate ("
		+ session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "activeskycastle", "route": route,
		"room_id": "activeskycastle:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts Active Sky Castle (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 6
			and game.view_snapshot()["hud"]["route"].size() == 6,
			"both public battle views report six Active Sky Castle rooms")
		check(game.view.audio.has_dungeon_music("activeskycastle")
			and String(game.view.audio.music.stream.resource_path).ends_with("skycastle.ogg"),
			"Active Sky Castle starts with the source normal track")
		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		check(int(source_counts.get("monster/newmonsters/realsky/minius/minius.mob", 0)) == 6
			and int(source_counts.get("monster/newmonsters/realsky/mirkius/mirkius.mob", 0)) == 1,
			"start room spawns six Minius and one Mirkius")
		var box_props: Array = game.build_props(box_room)
		var box_gaps: Dictionary = game.native_object_gaps.duplicate(true)
		check(box_props.size() == 2
			and box_props.all(func(prop): return String(prop["source_path"]).ends_with(
				"skycastle_squarebox.obj")),
			"MAP 16201 materialises two source-backed skycastle boxes")
		check(box_gaps.get(
			"passiveobject/mapobject/trap/crystalpillar.obj", [])
			== ["native_object_trigger"],
			"crystal pillars remain explicit trap triggers")
		var jar_props: Array = game.build_props(jar_room)
		var jar_gaps: Dictionary = game.native_object_gaps.duplicate(true)
		check(jar_props.is_empty()
			and jar_gaps.get(
				"passiveobject/actionobject/breakableobject/rscbigjar.obj", [])
			== ["native_breakable_source"],
			"large jars retain an explicit breakable-source gap")
		var trap_props: Array = game.build_props(trap_room)
		var trap_gaps: Dictionary = game.native_object_gaps.duplicate(true)
		check(trap_props.is_empty()
			and trap_gaps.get("passiveobject/mapobject/trap/flappingbanner.obj", [])
			== ["native_object_trigger"]
			and "native_action_object_behavior" in trap_gaps.get(
				"passiveobject/actionobject/monster/lizardman/lizard_stonebody5.obj", []),
			"banner traps and lizard stone bodies remain explicit behavior gaps")
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_ACTIVESKYCASTLE] COMPLETE checks=%d failures=%d"
		% [checks, failures])
	quit(0 if failures == 0 else 1)
