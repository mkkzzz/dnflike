extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const FlowSession = preload("res://flow/session.gd")
const NativeMaze = preload("res://combat/data/native_maze.gd")
const NativeBreakable = preload("res://combat/resolve/native_breakable.gd")
const NativeBoxLoot = preload("res://loot/native_box.gd")
const NativeJarTraps = preload("res://combat/resolve/native_jar_traps.gd")
const NativePotMonsters = preload("res://combat/resolve/native_pot_monsters.gd")
const DetRng = preload("res://core/det_rng.gd")
const ROUTE_MAP_IDS: Array[int] = [6801, 6802, 6803, 6804, 6805, 6806]
const ROUTE_MAPS: Array[String] = [
	"map/screamingcave/s6801.map",
	"map/screamingcave/6802.map",
	"map/screamingcave/6803.map",
	"map/screamingcave/6804.map",
	"map/screamingcave/6805.map",
	"map/screamingcave/b6806.map",
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
		push_error("[NATIVE_MAZE_SCREAMINGCAVE] FAIL " + label)

func run() -> void:
	game = session.mount(root)
	game.set_process(false)
	game.set_physics_process(false)
	var routes: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/dungeons.json"))["dungeons"]
	var route: Dictionary = routes["screamingcave"]
	check(route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("name") == "悲鸣洞穴" and route.get("region") == "elvengard"
		and int(route.get("min_level", 0)) == 59 and int(route.get("monster_level", 0)) == 60,
		"Screaming Cave is a hidden level 59 route with source basis 61 adapted to level 60")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production Screaming Cave export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/ancient/screamingcave.dgn"
		and dungeon.get("sha256") == "af64830f63d7142e1ba7794dcc5f0b5b8731f79fbda68d881b8778797306c05a"
		and int(dungeon.get("index", -1)) == 1501,
		"Screaming Cave export keeps DGN index 1501 and the pinned source identity")
	check(Array(dungeon.get("placements", [])).size() == 18
		and Dictionary(dungeon.get("rooms", {})).size() == 9
		and Dictionary(probe.data.get("images", {})).size() == 102,
		"Screaming Cave export retains eighteen placements, nine source MAPs and 102 images")
	check(int(dungeon.get("maze_block_index", -1)) == 0
		and dungeon.get("maze_block_selection") == "hell_base"
		and Array(dungeon.get("maze_blocks", [])).size() == 3,
		"Screaming Cave selects hell-base block 0 and preserves all three blocks")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	var errors: Array = diagnostics.filter(func(row): return row.get("level") == "error")
	var warnings: Array = diagnostics.filter(func(row): return row.get("level") == "warning")
	var infos: Array = diagnostics.filter(func(row): return row.get("level") == "info")
	check(errors.is_empty(), "Screaming Cave export has no source image or ANI errors")
	check(warnings.size() == 12
		and warnings.filter(func(row): return row.get("code") == "object_unrendered").size() == 12,
		"Screaming Cave preserves twelve behavior objects without basic motions")
	check(infos.size() == 10
		and infos.filter(func(row): return row.get("code") == "unhandled_tags").size() == 9
		and infos.filter(func(row): return row.get("code") == "maze_block_selected").size() == 1,
		"Screaming Cave preserves nine MAP tag reports and one selected-block record")

	var maze := NativeMaze.new()
	var size: Vector2i = maze._point(dungeon.get("size"))
	var cells: Dictionary = maze._read_cells(dungeon.get("cells"), size)
	var starts: Array = maze._read_endpoint_cells(dungeon.get("start_map_raw"), cells, "start_candidate")
	var bosses: Array = maze._read_endpoint_cells(dungeon.get("boss_map_raw"), cells, "boss_candidate")
	var specs: Dictionary = maze._read_specifications(dungeon.get("raw"), cells, 0)
	check(cells.size() == 6 and starts.size() == 1 and bosses.size() == 1,
		"Screaming Cave 6x1 source grid exposes one start and one boss candidate")
	check(starts[0] == Vector2i(5, 0) and bosses[0] == Vector2i(0, 0),
		"Screaming Cave source endpoints are start (5,0) and boss (0,0)")
	check(cells.values().filter(func(cell): return not cell.get("doors", []).is_empty()).size() == 6,
		"Screaming Cave has six connected cells")
	check(specs.get("normal", {}).size() == 4 and specs.get("boss", {}).is_empty(),
		"Screaming Cave preserves four normal specifications and resolves its boss from the endpoint MAP")
	var block: Dictionary = Array(dungeon.get("maze_blocks", []))[0]
	check(Array(block.get("map_specifications", [])).map(func(row): return int(row[2]))
		== [6805, 6804, 6803, 6802]
		and Array(block.get("boss_map_specifications", [])).is_empty()
		and Array(block.get("hell_dungeon", [])).map(func(value): return int(value)) == [1]
		and Array(block.get("seal_door_map_index", [])).map(func(value): return int(value)) == [60037]
		and Array(block.get("seal_door_pos", [])).map(func(value): return int(value)) == [1, 0]
		and Array(block.get("seal_door_appear_rate", [])).map(func(value): return int(value)) == [10],
		"Screaming Cave preserves fixed MAP IDs, hell mode and seal door 60037")
	var blocks: Array = Array(dungeon.get("maze_blocks", []))
	check(Array(blocks[1].get("quest_connection", [])).map(func(value): return int(value)) == [0, 4358, 2]
		and Array(blocks[1].get("escape_hell", [])).map(func(value): return int(value)) == [1]
		and Array(blocks[2].get("quest_connection", [])).map(func(value): return int(value)) == [0, 4378, 2]
		and Array(blocks[2].get("escape_hell", [])).map(func(value): return int(value)) == [1],
		"Screaming Cave keeps quest 4358/4378 escape layouts raw and unselected")
	var special_item: Variant = null
	for span: Dictionary in dungeon.get("raw", []):
		if span.get("tag") == "[special passive object item]":special_item = span.get("values", [])
	check(special_item != null and special_item.size() == 5
		and int(special_item[0][2]) == 0 and int(special_item[1][2]) == -1
		and int(special_item[2][2]) == 1 and int(special_item[3][2]) == 3222
		and int(special_item[4][2]) == 10000,
		"Screaming Cave preserves item 3222 at weight 10000 as raw server loot")

	var pools: Dictionary = maze._read_pools(dungeon, cells, starts[0], bosses[0])
	check(pools.size() == 6,
		"Screaming Cave start/boss reaches all six connected cells (pools=%d error=%s)"
		% [pools.size(), maze.last_error])
	check(maze.start(probe.data, SourceRolls.new([0, 0]), route.get("source", {})),
		"generic native maze starts Screaming Cave")
	check(maze.room_count() == 6 and maze.required_map_paths().size() == 6,
		"Screaming Cave exposes six ordinary rooms across six source-fixed MAPs")
	var selected_ids: Array[int] = [int(maze.current_room().get("source_map_id", 0))]
	for step in 5:
		var current: Vector2i = maze.current_room().get("cell", Vector2i(-1, -1))
		var cleared: Dictionary = maze.clear_room(current, 0)
		var moved: Dictionary = maze.move("left")
		check(not cleared.is_empty() and not moved.is_empty(),
			"Screaming Cave clears and traverses source step %d" % step)
		selected_ids.append(int(moved.get("source_map_id", 0)))
	check(selected_ids == ROUTE_MAP_IDS,
		"Screaming Cave selects MAP 6801,6802..6805,6806 in the ordinary block order")
	var final_clear: Dictionary = maze.clear_room(Vector2i(0, 0), 0)
	check(bool(final_clear.get("boss", false)) and bool(final_clear.get("final_room", false)),
		"the King Nugol room is the ordinary block's sole boss and final room")
	check(not NativeBoxLoot.required(dungeon),
		"Screaming Cave item 3222 is not a referenced special-object payload")
	check(NativeJarTraps.ready(game.combat_assets), "shared source jar trap assets resolve")

	var all_monsters := {}
	var all_monster_count := 0
	var all_boss_rows := 0
	var all_object_count := 0
	var all_object_tags := {}
	var all_object_paths := {}
	var all_unrendered := 0
	var all_breakables := 0
	var all_ai_rows := 0
	var all_npc_rows := 0
	var ai_character_rows := 0
	for room: Dictionary in dungeon.get("rooms", {}).values():
		for monster: Dictionary in room.get("monsters", []):
			all_monsters[String(monster.get("mob", ""))] = true
			all_monster_count += 1
			var raw: Array = monster.get("raw", [])
			if not raw.is_empty() and raw[-1] == "[boss]":all_boss_rows += 1
		for item: Dictionary in room.get("objects", []):
			all_object_count += 1
			all_object_paths[String(item.get("obj", "")).to_lower()] = true
			var tag := String(item.get("source_tag", ""))
			all_object_tags[tag] = 1 + int(all_object_tags.get(tag, 0))
			if item.get("sprite") == null:all_unrendered += 1
			if NativeBreakable.supports(item):all_breakables += 1
		for span: Dictionary in room.get("raw", []):
			if span.get("tag") == "[monster specific AI]":
				all_ai_rows += Array(span.get("values", [])).size()
			elif span.get("tag") == "[NPC]":
				all_npc_rows += 1
			elif span.get("tag") == "[ai character]":
				ai_character_rows += 1
	check(all_monsters.size() == 13 and all_monster_count == 80 and all_boss_rows == 2,
		"Screaming Cave all source blocks retain 80 placements, thirteen MOBs and two boss rows")
	check(all_object_count == 45 and all_object_tags == {"[passive object]": 44,
		"[special passive object]": 1} and all_object_paths.size() == 15
		and all_unrendered == 12 and all_breakables == 0,
		"Screaming Cave retains 45 source objects, one special row and no breakable candidates")
	check(all_ai_rows == 80 and all_npc_rows == 2 and ai_character_rows == 1,
		"Screaming Cave keeps 80 AI rows, two NPC rows and one quest AI-character row")
	for mob: String in all_monsters:
		check(not game.table.monster_by_mob(mob).is_empty(),
			"source MOB has runtime content: " + mob)

	var route_monsters := {}
	var route_monster_count := 0
	var route_boss_rows := 0
	var route_object_count := 0
	var route_unrendered := 0
	var route_obstacles := 0
	for path: String in ROUTE_MAPS:
		var room: Dictionary = dungeon["rooms"][path]
		for monster: Dictionary in room.get("monsters", []):
			route_monsters[String(monster.get("mob", ""))] = true
			route_monster_count += 1
			var raw: Array = monster.get("raw", [])
			if not raw.is_empty() and raw[-1] == "[boss]":route_boss_rows += 1
		for item: Dictionary in room.get("objects", []):
			route_object_count += 1
			if item.get("sprite") == null:route_unrendered += 1
			if String(item.get("obj", "")).to_lower().contains("/obstacle/"):route_obstacles += 1
	check(route_monsters.size() == 10 and route_monster_count == 58 and route_boss_rows == 1,
		"Screaming Cave ordinary route retains 58 monsters, ten MOBs and one boss row")
	check(route_object_count == 29 and route_unrendered == 11 and route_obstacles == 10,
		"Screaming Cave ordinary route retains 29 objects, eleven unrendered and ten obstacles")

	var banks := {
		"monster/crimebuffalo/crimebuffalogeneral.mob":
			["crimebuffalo_crimebuffalogeneral", 3, [0, 1, 2], []],
		"monster/crimebuffalo/crimebuffalonormal.mob":
			["crimebuffalo_crimebuffalonormal", 0, [], []],
		"monster/newmonsters/screamingcave/babynugol/babynugol.mob":
			["newmonsters_screamingcave_babynugol_babynugol", 5, [0, 1, 2, 3, 4], [0, 4]],
		"monster/newmonsters/screamingcave/bloodystormhardy/bloodystormhardy.mob":
			["newmonsters_screamingcave_bloodystormhardy_bloodystormhardy", 3, [0, 2], []],
		"monster/newmonsters/screamingcave/eviledge1/eviledge1.mob":
			["newmonsters_screamingcave_eviledge1_eviledge1", 9, [0, 1, 2, 3, 4, 5], [7, 2, 5, 1]],
		"monster/newmonsters/screamingcave/eviledge2/eviledge2.mob":
			["newmonsters_screamingcave_eviledge2_eviledge2", 1, [0], [0]],
		"monster/newmonsters/screamingcave/graverobberking/graverobberking.mob":
			["newmonsters_screamingcave_graverobberking_graverobberking", 8,
			[0, 1, 2, 3, 4, 5, 6, 7], [0, 6]],
		"monster/newmonsters/screamingcave/highspectresslene/highspectresslene.mob":
			["newmonsters_screamingcave_highspectresslene_highspectresslene", 5, [0, 2, 4], [0, 3]],
		"monster/newmonsters/screamingcave/kingnugol/kingnugol.mob":
			["newmonsters_screamingcave_kingnugol_kingnugol", 14,
			[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12], []],
		"monster/newmonsters/screamingcave/skullkane/skullkane.mob":
			["newmonsters_screamingcave_skullkane_skullkane", 5, [0, 1, 2], [0, 1]],
	}
	for mob: String in banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		check(String(definition.get("bank", "")) == banks[mob][0]
			and game.combat_assets.get("monsters", {}).has(banks[mob][0]),
			"Screaming Cave source bank is compiled: " + mob)
		var moves: Array = Array(definition.get("moves", []))
		check(moves.size() == int(banks[mob][1]),
			"source action slots compile for %s (moves=%d expected=%d)"
			% [mob, moves.size(), int(banks[mob][1])])
		var atk_slots: Array[int] = []
		for index in moves.size():
			var move: Dictionary = moves[index]
			if not move.has("atk_path"):continue
			atk_slots.append(index)
			check(not game.table.atk(String(move["atk_path"])).is_empty()
				and not Array(move.get("timeline", [])).is_empty(),
				"source action and ATK compile together at %s slot %d" % [mob, index])
		check(atk_slots == banks[mob][2],
			"source attack-bearing slots match for %s (%s)" % [mob, atk_slots])
		var skills: Array[int] = []
		for rule: Dictionary in Array(definition.get("rules", [])):
			skills.append(int(rule.get("skill", -1)))
		check(skills == banks[mob][3],
			"source AI priority compiles for %s (%s)" % [mob, skills])
	var single_kind: String = game.table.monster_by_mob("monster/crimebuffalo/crimebuffalonormal.mob")
	var single: Dictionary = game.table.monsters.get(single_kind, {})
	check(not Dictionary(single.get("atk", {})).is_empty()
		and not Array(single.get("attack_timeline", [])).is_empty(),
		"single source buffalo attack remains available through the shared base attack path")

	var bgm: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/bgm.json"))
	check(bgm.get("dungeons", {}).get("screamingcave", {}).get("normal") == "screaming_cave"
		and bgm.get("dungeons", {}).get("screamingcave", {}).get("boss") == "screaming_cave_boss",
		"Screaming Cave maps its source normal and boss tracks")
	check(not bgm.get("source_gaps", {}).has("screamingcave"),
		"Screaming Cave has no unresolved MAP music cue")

	var flow := FlowSession.new()
	flow.profile["level"] = 60
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "screamingcave"})["ok"],
		"flow departs the hidden Screaming Cave route")
	route = flow.active_dungeon_route()
	NativePotMonsters.reset_catalog()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live Screaming Cave run selects hell-base block 0")
	NativePotMonsters.prepare_catalog(dungeon, SourceRolls.new([0, 0, 0, 0]))
	check(session._validate_native_maze(probe, live_maze),
		"Screaming Cave room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "screamingcave", "route": route,
		"room_id": "screamingcave:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source Screaming Cave room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 6
			and game.view_snapshot()["hud"]["route"].size() == 6,
			"both public battle views report the complete six-room Screaming Cave graph")
		check(game.view.audio.has_dungeon_music("screamingcave")
			and String(game.view.audio.music.stream.resource_path).ends_with("screaming_cave.ogg"),
			"Screaming Cave starts with the source normal track")

		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts and int(source_counts.get(
			"monster/crimebuffalo/crimebuffalonormal.mob", 0)) == 10
			and int(source_counts.get("monster/crimebuffalo/crimebuffalogeneral.mob", 0)) == 1,
			"Screaming Cave start room spawns ten buffalo miners and one captain")

		var interactive_props := 0
		var all_gaps := {}
		for path: String in ROUTE_MAPS:
			var room: Dictionary = probe.room(path)
			interactive_props += game.build_props(room).size()
			for path_key: String in game.native_object_gaps:
				if not all_gaps.has(path_key):all_gaps[path_key] = []
				for gap in game.native_object_gaps[path_key]:
					if gap not in all_gaps[path_key]:all_gaps[path_key].append(gap)
		check(interactive_props == 0,
			"Screaming Cave does not materialise traps or action objects as guessed props")
		check(all_gaps.size() == 11,
			"Screaming Cave ordinary route preserves eleven interactable object identities")
		check(all_gaps.get("passiveobject/mapobject/trap/ufvictima.obj", [])
			== ["native_object_trigger"]
			and all_gaps.get("passiveobject/mapobject/trap/sirocoscream1.obj", [])
			== ["native_object_trigger"]
			and all_gaps.get("passiveobject/mapobject/trap/sirocoscream2.obj", [])
			== ["native_object_trigger"]
			and all_gaps.get("passiveobject/mapobject/trap/sirocoscream3.obj", [])
			== ["native_object_trigger"],
			"Screaming Cave victim and scream traps remain explicit behavior triggers")
		for action_path in [
			"passiveobject/actionobject/monster/screamingcave/kanerebirth.obj",
			"passiveobject/actionobject/monster/screamingcave/magicdummy.obj",
			"passiveobject/actionobject/monster/screamingcave/dummypassive.obj",
			"passiveobject/actionobject/monster/screamingcave/comein/buffalo_stay1.obj",
			"passiveobject/actionobject/monster/screamingcave/comein/buffalo_stay2.obj",
			"passiveobject/actionobject/monster/screamingcave/comein/buffalo_stay3.obj",
			"passiveobject/actionobject/monster/screamingcave/comein/buffalo_stay4.obj",
		]:
			check("native_action_object_behavior" in all_gaps.get(action_path, [])
				and "native_action_object_visual" in all_gaps.get(action_path, []),
				"action object keeps behavior/visual gaps: " + action_path)
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_SCREAMINGCAVE] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
