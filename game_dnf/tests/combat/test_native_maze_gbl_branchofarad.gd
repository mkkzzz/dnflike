extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const FlowSession = preload("res://flow/session.gd")
const NativeMaze = preload("res://combat/data/native_maze.gd")
const NativeBreakable = preload("res://combat/resolve/native_breakable.gd")
const NativeBoxLoot = preload("res://loot/native_box.gd")
const NativeJarTraps = preload("res://combat/resolve/native_jar_traps.gd")
const DetRng = preload("res://core/det_rng.gd")

const SOURCE_SHA := "8666193f452687ae3eed7e27bf05d3b2b3721efa0952985eab4e6bb9fac357b8"
const ROUTE_MAP_IDS := [13001, 13002, 13003, 13004, 13006, 13008, 13013]
const ORDINARY_MAP_IDS := [
	13001, 13002, 13003, 13004, 13005, 13006, 13007,
	13008, 13009, 13010, 13011, 13012, 13013,
]

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
		push_error("[NATIVE_MAZE_GBL_BRANCHOFARAD] FAIL " + label)

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
	var route: Dictionary = routes["gbl_branchofarad"]
	check(route.get("name") == "GBL教阿拉德分部"
		and route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("region") == "behemoth"
		and int(route.get("min_level", 0)) == 46 and int(route.get("monster_level", 0)) == 49,
		"GBL Arad Branch is a hidden level 46 Behemoth native-maze route with basis level 49")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production GBL Arad Branch export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/village/gbl/gbl_branchofarad.dgn"
		and dungeon.get("sha256") == SOURCE_SHA,
		"GBL Arad Branch export keeps the pinned DGN source identity")
	check(Array(dungeon.get("placements", [])).size() == 27
		and Dictionary(dungeon.get("rooms", {})).size() == 17
		and Dictionary(probe.data.get("images", {})).size() == 48,
		"GBL Arad Branch export contains 27 placements, 17 MAPs and 48 source images")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	var errors: Array = diagnostics.filter(func(row): return row.get("level") == "error")
	var warnings: Array = diagnostics.filter(func(row): return row.get("level") == "warning")
	var infos: Array = diagnostics.filter(func(row): return row.get("level") == "info")
	var unrendered := 0
	var aa_warnings := 0
	var scroll_absent := 0
	var unhandled := 0
	for row: Dictionary in warnings:
		if row.get("code") == "object_unrendered":unrendered += 1
		if row.get("code") == "cell_without_map" and String(row.get("detail", "")).contains(" code AA"):
			aa_warnings += 1
	for row: Dictionary in infos:
		if row.get("code") == "scroll_absent":scroll_absent += 1
		if row.get("code") == "unhandled_tags":unhandled += 1
	check(errors.is_empty() and warnings.size() == 85 and infos.size() == 68
		and unrendered == 82 and aa_warnings == 3 and scroll_absent == 51 and unhandled == 17,
		"GBL Arad Branch preserves 82 unrendered objects, three AA cells, "
		+ "51 missing scrolls and 17 raw-tag MAPs")

	var maze := NativeMaze.new()
	var size: Vector2i = maze._point(dungeon.get("size"))
	var cells: Dictionary = maze._read_cells(dungeon.get("cells"), size)
	var starts: Array = maze._read_endpoint_cells(dungeon.get("start_map_raw"), cells, "start_candidate")
	var bosses: Array = maze._read_endpoint_cells(dungeon.get("boss_map_raw"), cells, "boss_candidate")
	var specs: Dictionary = maze._read_specifications(dungeon.get("raw"), cells)
	var normal_ids: Array[int] = []
	for point: Vector2i in specs.get("normal", {}):
		for map_id in specs["normal"][point]:normal_ids.append(int(map_id))
	normal_ids.sort()
	check(size == Vector2i(4, 4) and cells.size() == 16
		and starts == [Vector2i(3, 1)] and bosses == [Vector2i(2, 2)],
		"GBL Arad Branch is a 4x4 source grid with start (3,1) and boss (2,2)")
	check(normal_ids == [13002, 13003, 13004, 13005, 13006, 13007, 13008, 13009, 13010, 13011, 13012],
		"the ordinary maze keeps eleven fixed normal MAPs")
	var start_candidates: Array = cells[Vector2i(3, 1)]["map_candidates"]
	var boss_candidates: Array = cells[Vector2i(2, 2)]["map_candidates"]
	check(start_candidates == ["map/gbl1/g1(s)002.map"],
		"the start cell uniquely binds source start MAP 13001")
	check(boss_candidates.has("map/gbl1/g1(b)002.map")
		and boss_candidates.has("map/gbl1/maze(2,2).map"),
		"the boss cell preserves both ordinary and quest source candidates")

	var maze_blocks := 0
	var first_map_specs := 0
	var first_boss_specs := 0
	var quest_ids: Array[int] = []
	var boss_specs: Array[int] = []
	var seal_ids: Array[int] = []
	var seal_positions: Array = []
	var event_monster = null
	var hell_value = null
	var escape_hell = null
	for span: Dictionary in dungeon.get("raw", []):
		var tag := String(span.get("tag", ""))
		var values: Array = span.get("values", [])
		if tag == "[maze info]":maze_blocks += 1
		if tag == "[map specification]" and maze_blocks == 1:first_map_specs += 1
		if tag == "[boss map specification]":
			boss_specs.append(int(values[2][2]))
			if maze_blocks == 1:first_boss_specs += 1
		if tag == "[quest connection]":quest_ids.append(int(values[1][2]))
		if tag == "[seal door map index]":seal_ids.append(int(values[0][2]))
		if tag == "[seal door pos]":seal_positions.append([int(values[0][2]), int(values[1][2])])
		if tag == "[event monster]":event_monster = values
		if tag == "[hell dungeon]":hell_value = values
		if tag == "[escape hell]":escape_hell = values
	check(maze_blocks == 3 and quest_ids == [3802, 3803],
		"GBL Arad Branch preserves the ordinary maze plus quest 3802 and 3803")
	check(first_map_specs == 11 and first_boss_specs == 0
		and boss_specs == [13059, 13058],
		"ordinary and quest boss MAPs 13013/13059/13058 remain separated by layout")
	check(seal_ids == [60040, 60040]
		and seal_positions == [[1, 0], [1, 0]],
		"ordinary and hell layouts keep seal 60040 at (1,0)")
	check(event_monster != null and int(event_monster[1][2]) == 1300
		and int(event_monster[2][2]) == 62502
		and hell_value != null and int(hell_value[0][2]) == 1
		and escape_hell != null and int(escape_hell[0][2]) == 1,
		"quest 3803 keeps event monster 62502, hell and escape-hell flags raw")

	var fixed_maze := NativeMaze.new()
	check(fixed_maze.start(probe.data, SourceRolls.new([0, 0, 0]), route.get("source", {})),
		"native maze starts the sole ordinary GBL Arad Branch layout")
	check(fixed_maze.room_count() == 13,
		"GBL Arad Branch ordinary graph reaches all thirteen connected cells")
	var selected_ids: Array[int] = [int(fixed_maze.current_room().get("source_map_id", 0))]
	var moves := ["up", "left", "left", "down", "right", "down"]
	for step in moves.size():
		var current: Vector2i = fixed_maze.current_room().get("cell", Vector2i(-1, -1))
		var cleared: Dictionary = fixed_maze.clear_room(current, 0)
		var moved: Dictionary = fixed_maze.move(moves[step])
		check(not cleared.is_empty() and not moved.is_empty(),
			"GBL Arad Branch clears and traverses source step %d" % step)
		selected_ids.append(int(moved.get("source_map_id", 0)))
	check(selected_ids == ROUTE_MAP_IDS,
		"GBL Arad Branch shortest source route selects MAPs 13001,13002,13003,13004,13006,13008,13013")
	var final_clear: Dictionary = fixed_maze.clear_room(Vector2i(2, 2), 0)
	check(bool(final_clear.get("boss", false)) and bool(final_clear.get("final_room", false)),
		"the selected 13013 room is the sole ordinary boss and final room")

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
		if int(room.get("map_id", 0)) not in ORDINARY_MAP_IDS:continue
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
				if not game.content.record(path).get("native_breakable", {}).is_empty():
					source_runtime_breakables += 1
			elif path.contains("/trap/"):
				source_traps += 1
			else:
				source_static += 1
	check(source_monsters.size() == 6 and source_monster_count == 104 and source_boss_rows == 1,
		"GBL Arad Branch first run has 104 direct placements, six MOBs and one boss row")
	check(source_monster_counts == {
		"monster/newmonsters/aradwoman/gbl_chief_libraian/gbl_chief_libraian.mob": 4,
		"monster/newmonsters/aradwoman/gbl_libraian/gbl_libraian.mob": 38,
		"monster/newmonsters/gbl/gblcolossus/gblcolossus.mob": 1,
		"monster/newmonsters/gbl/gbltentacle/gbltentacle.mob": 47,
		"monster/newmonsters/gbl/isadora/isadora.mob": 1,
		"monster/newmonsters/gbl/webcannon/webcannon.mob": 13,
	}, "GBL Arad Branch keeps the exact ordinary source monster counts")
	check(source_object_count == 178 and source_breakable_candidates == 150
		and source_runtime_breakables == 96 and source_traps == 14
		and source_static == 14 and source_box_objects == 0,
		"GBL Arad Branch has 178 objects: 96 executable breakables, "
		+ "54 action-object gaps, 14 traps, 14 static objects and no box draws "
		+ "(objects=%d candidates=%d runtime=%d traps=%d static=%d boxes=%d)"
		% [source_object_count, source_breakable_candidates, source_runtime_breakables,
			source_traps, source_static, source_box_objects])

	var banks := {
		"monster/newmonsters/aradwoman/gbl_libraian/gbl_libraian.mob":
			["newmonsters_aradwoman_gbl_libraian_gbl_libraian", 1],
		"monster/newmonsters/aradwoman/gbl_chief_libraian/gbl_chief_libraian.mob":
			["newmonsters_aradwoman_gbl_chief_libraian_gbl_chief_libraian", 4],
		"monster/newmonsters/gbl/gbltentacle/gbltentacle.mob":
			["newmonsters_gbl_gbltentacle_gbltentacle", 4],
		"monster/newmonsters/gbl/webcannon/webcannon.mob":
			["newmonsters_gbl_webcannon_webcannon", 1],
		"monster/newmonsters/gbl/gblcolossus/gblcolossus.mob":
			["newmonsters_gbl_gblcolossus_gblcolossus", 6],
		"monster/newmonsters/gbl/isadora/isadora.mob":
			["newmonsters_gbl_isadora_isadora", 13],
	}
	for mob: String in banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		check(String(definition.get("bank", "")) == banks[mob][0]
			and game.combat_assets.get("monsters", {}).has(banks[mob][0]),
			"GBL Arad Branch source bank is compiled: " + mob)
		check(Array(definition.get("moves", [])).size() == int(banks[mob][1]),
			"GBL Arad Branch source attack slots compile for %s (moves=%d expected=%d)"
			% [mob, Array(definition.get("moves", [])).size(), int(banks[mob][1])])
	for mob in [
		"monster/newmonsters/gbl/ladyzealot/ladyzealot_characterteam.mob",
		"monster/newmonsters/gbl/isadora/isadora2.mob",
	]:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		check(not kind.is_empty() and game.combat_assets.get("monsters", {}).has(
			String(definition.get("bank", ""))),
			"quest-only source MOB remains compiled but outside the ordinary route: " + mob)
	var isadora: Dictionary = game.table.monsters.get(
		game.table.monster_by_mob("monster/newmonsters/gbl/isadora/isadora.mob"), {})
	var isadora_stems: Array[String] = []
	for move: Dictionary in isadora.get("moves", []):isadora_stems.append(String(move.get("stem", "")))
	check(isadora_stems == [
		"fireattack", "lightningattack", "darkattack", "iceattack", "buster",
		"summonice", "telleport", "telleport2", "dashattack1", "dashattack2",
		"summonice2", "spiritbomb", "buster2",
	], "Isadora keeps all thirteen source attack actions in slot order")
	check(not NativeBoxLoot.required(dungeon), "GBL Arad Branch does not invent box loot")
	check(NativeJarTraps.ready(game.combat_assets), "shared source trap assets resolve")

	var flow := FlowSession.new()
	flow.profile["level"] = 49
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "gbl_branchofarad"})["ok"],
		"flow departs the hidden GBL Arad Branch route")
	route = flow.active_dungeon_route()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live GBL Arad Branch run selects its sole ordinary layout")
	check(session._validate_native_maze(probe, live_maze),
		"GBL Arad Branch room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "gbl_branchofarad", "route": route,
		"room_id": "gbl_branchofarad:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source GBL Arad Branch room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 13
			and game.view_snapshot()["hud"]["route"].size() == 13,
			"both public battle views report the complete GBL Arad Branch graph")
		check(game.view.audio.has_dungeon_music("gbl_branchofarad")
			and String(game.view.audio.music.stream.resource_path).ends_with("gblarad.ogg"),
			"GBL Arad Branch starts with the original M_GBLARAD track")
		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts,
			"GBL Arad Branch start room spawns its exact source monster lineup")

		var interactive_props := 0
		var box_props := 0
		var unknown_ids: Array[int] = []
		var all_gaps := {}
		for path: String in dungeon.get("rooms", {}).keys():
			var room: Dictionary = probe.room(path)
			if int(room.get("map_id", 0)) not in ORDINARY_MAP_IDS:continue
			var room_props: Array = game.build_props(room)
			interactive_props += room_props.size()
			for prop: Dictionary in room_props:
				if not (prop.get("box_items", []) as Array).is_empty():box_props += 1
				for source_id in prop.get("unresolved_trap_ids", []):
					if int(source_id) not in unknown_ids:unknown_ids.append(int(source_id))
			merge_gaps(all_gaps, game.native_object_gaps)
		unknown_ids.sort()
		check(interactive_props == 96,
			"all 96 ordinary source breakables build exactly once across thirteen MAPs")
		check(box_props == 0, "GBL Arad Branch creates no item-box props")
		check(unknown_ids == [2000, 2100],
			"mixed long-pot rows preserve only the unverified trap IDs 2000/2100")
		for path in [
			"passiveobject/actionobject/breakableobject/aganzo_chair.obj",
			"passiveobject/actionobject/breakableobject/bookcase.obj",
			"passiveobject/actionobject/breakableobject/halfbookcase.obj",
		]:
			check(all_gaps.get(path, []) == ["native_breakable_source"],
				"GBL Arad Branch action-object breakable remains explicit: " + path)
		check(all_gaps.get("passiveobject/actionobject/trap/bookcasetrap.obj", [])
			== ["native_object_trigger"],
			"GBL Arad Branch bookcase trap remains an explicit behaviour gap")
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_GBL_BRANCHOFARAD] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
