extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const FlowSession = preload("res://flow/session.gd")
const NativeMaze = preload("res://combat/data/native_maze.gd")
const NativeBreakable = preload("res://combat/resolve/native_breakable.gd")
const NativeBoxLoot = preload("res://loot/native_box.gd")
const NativeJarTraps = preload("res://combat/resolve/native_jar_traps.gd")
const NativePotMonsters = preload("res://combat/resolve/native_pot_monsters.gd")
const DetRng = preload("res://core/det_rng.gd")
const ROUTE_MAP_IDS: Array[int] = [15057, 15058, 15059, 15060, 15061, 15062]
const ROUTE_MAPS: Array[String] = [
	"map/leshphon/(1,0)start.map",
	"map/leshphon/(0,0)named.map",
	"map/leshphon/(0,1)normal.map",
	"map/leshphon/(1,1)named.map",
	"map/leshphon/(1,2)named.map",
	"map/leshphon/(0,2)boss.map",
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
		push_error("[NATIVE_MAZE_LESHPHON] FAIL " + label)

func run() -> void:
	game = session.mount(root)
	game.set_process(false)
	game.set_physics_process(false)
	var routes: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/dungeons.json"))["dungeons"]
	var route: Dictionary = routes["leshphon"]
	check(route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("name") == "痛苦之村列瑟芬" and route.get("region") == "northmyre"
		and int(route.get("min_level", 0)) == 55 and int(route.get("monster_level", 0)) == 55,
		"Leshphon is a hidden level 55 North Myre native-maze route")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production Leshphon export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/ancient/leshphon.dgn"
		and dungeon.get("sha256") == "523a5924b9faeae3da4e63c2cbac7f8f7fdb0bd27a7155d7b0b8388714365293"
		and int(dungeon.get("index", -1)) == 1506,
		"Leshphon export keeps DGN index 1506 and the pinned source identity")
	check(Array(dungeon.get("placements", [])).size() == 6
		and Dictionary(dungeon.get("rooms", {})).size() == 6
		and Dictionary(probe.data.get("images", {})).size() == 79,
		"Leshphon export contains six fixed placements, six MAPs and 79 source images")
	check(int(dungeon.get("maze_block_index", -1)) == 0
		and dungeon.get("maze_block_selection") == "hell_base"
		and Array(dungeon.get("maze_blocks", [])).size() == 1,
		"Leshphon selects its single source hell-base block 0")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	var errors: Array = diagnostics.filter(func(row): return row.get("level") == "error")
	var warnings: Array = diagnostics.filter(func(row): return row.get("level") == "warning")
	var infos: Array = diagnostics.filter(func(row): return row.get("level") == "info")
	check(errors.is_empty(), "Leshphon export has no source image or ANI errors")
	check(warnings.size() == 1
		and warnings[0].get("code") == "object_unrendered"
		and String(warnings[0].get("path", "")).ends_with("hyungteo_comein.obj"),
		"Leshphon preserves one behavior object without a basic motion")
	check(infos.size() == 24
		and infos.filter(func(row): return row.get("code") == "scroll_absent").size() == 18
		and infos.filter(func(row): return row.get("code") == "unhandled_tags").size() == 6,
		"Leshphon preserves 18 missing-scroll defaults and six raw MAP tag reports")

	var maze := NativeMaze.new()
	var size: Vector2i = maze._point(dungeon.get("size"))
	var cells: Dictionary = maze._read_cells(dungeon.get("cells"), size)
	var starts: Array = maze._read_endpoint_cells(dungeon.get("start_map_raw"), cells, "start_candidate")
	var bosses: Array = maze._read_endpoint_cells(dungeon.get("boss_map_raw"), cells, "boss_candidate")
	var specs: Dictionary = maze._read_specifications(dungeon.get("raw"), cells, 0)
	check(cells.size() == 6 and starts.size() == 1 and bosses.size() == 1,
		"Leshphon 2x3 source grid exposes one start and one boss candidate")
	check(starts[0] == Vector2i(1, 0) and bosses[0] == Vector2i(0, 2),
		"Leshphon source endpoints are start (1,0) and boss (0,2)")
	check(specs.get("normal", {}).size() == 5 and specs.get("boss", {}).size() == 1,
		"Leshphon preserves five normal and one boss MAP specification")
	var block: Dictionary = Array(dungeon.get("maze_blocks", []))[0]
	check(Array(block.get("map_specifications", [])).map(func(row): return int(row[2]))
		== [15057, 15058, 15059, 15060, 15061]
		and Array(block.get("boss_map_specifications", [])).map(func(row): return int(row[2]))
		== [15062]
		and Array(block.get("hell_dungeon", [])).map(func(value): return int(value)) == [1]
		and Array(block.get("seal_door_map_index", [])).map(func(value): return int(value)) == [60053]
		and Array(block.get("seal_door_pos", [])).map(func(value): return int(value)) == [0, 1]
		and Array(block.get("seal_door_appear_rate", [])).map(func(value): return int(value)) == [10],
		"Leshphon preserves fixed MAP IDs, hell mode and seal door 60053")

	var pools: Dictionary = maze._read_pools(dungeon, cells, starts[0], bosses[0])
	check(pools.size() == 6,
		"Leshphon start/boss reaches all six connected cells (pools=%d error=%s)"
		% [pools.size(), maze.last_error])
	check(maze.start(probe.data, SourceRolls.new([0, 0]), route.get("source", {})),
		"generic native maze starts Leshphon")
	check(maze.room_count() == 6 and maze.required_map_paths().size() == 6,
		"Leshphon exposes six rooms across six source-fixed MAPs")
	var selected_ids: Array[int] = [int(maze.current_room().get("source_map_id", 0))]
	for step in 5:
		var current: Vector2i = maze.current_room().get("cell", Vector2i(-1, -1))
		var cleared: Dictionary = maze.clear_room(current, 0)
		var next_door := "left" if step in [0, 4] else "down" if step in [1, 3] else "right"
		var moved: Dictionary = maze.move(next_door)
		check(not cleared.is_empty() and not moved.is_empty(),
			"Leshphon clears and traverses source step %d via %s" % [step, next_door])
		selected_ids.append(int(moved.get("source_map_id", 0)))
	check(selected_ids == ROUTE_MAP_IDS,
		"Leshphon selects MAP 15057..15062 in the fixed zig-zag order")
	var final_clear: Dictionary = maze.clear_room(Vector2i(0, 2), 0)
	check(bool(final_clear.get("boss", false)) and bool(final_clear.get("final_room", false)),
		"the Black Plague Direzie room is the sole boss and final room")
	check(not NativeBoxLoot.required(dungeon),
		"Leshphon has no executable special-object item groups")
	check(NativeJarTraps.ready(game.combat_assets), "shared source jar trap assets resolve")

	var source_monsters := {}
	var source_monster_count := 0
	var source_boss_rows := 0
	var source_object_count := 0
	var source_passive := 0
	var source_specials := 0
	var source_breakables := 0
	var source_unrendered := 0
	var source_action_objects := 0
	var source_object_paths := {}
	var event_position_count := 0
	var specific_ai_count := 0
	var npc_count := 0
	for room: Dictionary in dungeon.get("rooms", {}).values():
		for monster: Dictionary in room.get("monsters", []):
			source_monsters[String(monster.get("mob", ""))] = true
			source_monster_count += 1
			var raw: Array = monster.get("raw", [])
			if not raw.is_empty() and raw[-1] == "[boss]":source_boss_rows += 1
		for item: Dictionary in room.get("objects", []):
			source_object_count += 1
			var path := String(item.get("obj", "")).to_lower()
			source_object_paths[path] = true
			if item.get("source_tag") == "[passive object]":source_passive += 1
			if item.get("source_tag") == "[special passive object]":source_specials += 1
			if NativeBreakable.supports(item):source_breakables += 1
			if item.get("sprite") == null:source_unrendered += 1
			if path.contains("/actionobject/"):source_action_objects += 1
		for span: Dictionary in room.get("raw", []):
			if span.get("tag") == "[event monster position]":
				event_position_count += int(Array(span.get("values", [])).size()) / 3
			elif span.get("tag") == "[monster specific AI]":
				specific_ai_count += Array(span.get("values", [])).size()
			elif span.get("tag") == "[NPC]":
				npc_count += 1
	check(source_monsters.size() == 7 and source_monster_count == 28 and source_boss_rows == 1,
		"Leshphon source has 28 direct placements, seven MOBs and one boss row")
	check(source_object_count == 113 and source_passive == 113 and source_specials == 0
		and source_action_objects == 113 and source_object_paths.size() == 15,
		"Leshphon source has 113 action objects across 15 identities and no special-passive row")
	check(source_breakables == 0 and source_unrendered == 1,
		"Leshphon has no breakable candidate and one object without a source sprite")
	check(event_position_count == 24 and specific_ai_count == 28 and npc_count == 1,
		"Leshphon preserves four event positions per room, 28 normal AI rows and one boss NPC")
	for mob: String in source_monsters:
		check(not game.table.monster_by_mob(mob).is_empty(),
			"direct source MOB has runtime content: " + mob)

	var banks := {
		"monster/newmonsters/leshphon/divol/divol1.mob":
			["newmonsters_leshphon_divol_divol1", 4, [0], [1, 0, 2, 3]],
		"monster/newmonsters/leshphon/duke_juris/duke_juris.mob":
			["newmonsters_leshphon_duke_juris_duke_juris", 5, [1], [1, 3]],
		"monster/newmonsters/leshphon/hyungteo/hyungteo.mob":
			["newmonsters_leshphon_hyungteo_hyungteo", 8, [0, 1, 2, 5, 6], []],
		"monster/newmonsters/leshphon/isangoma_nazaloh/isangoma_nazaloh.mob":
			["newmonsters_leshphon_isangoma_nazaloh_isangoma_nazaloh", 6, [0], [0, 4]],
		"monster/newmonsters/leshphon/melt_knight/melt_knight.mob":
			["newmonsters_leshphon_melt_knight_melt_knight", 4, [0, 3], [0, 3]],
		"monster/newmonsters/leshphon/scavenger/scavenger.mob":
			["newmonsters_leshphon_scavenger_scavenger", 2, [0, 1], [1, 0]],
		"monster/newmonsters/leshphon/the_wicked_disease_direzie/the_wicked_disease_direzie.mob":
			["newmonsters_leshphon_the_wicked_disease_direzie_the_wicked_disease_direzie",
			22, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 14, 15, 16, 17, 20], []],
	}
	for mob: String in banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		check(String(definition.get("bank", "")) == banks[mob][0]
			and game.combat_assets.get("monsters", {}).has(banks[mob][0]),
			"Leshphon source bank is compiled: " + mob)
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

	var bgm: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/bgm.json"))
	check(bgm.get("dungeons", {}).get("leshphon", {}).get("normal") == "leshphon"
		and bgm.get("dungeons", {}).get("leshphon", {}).get("boss") == "leshphon_boss",
		"Leshphon maps its source M_LESHPHON normal and boss tracks")
	check(not bgm.get("source_gaps", {}).has("leshphon"),
		"Leshphon has no unresolved MAP music cue")

	var flow := FlowSession.new()
	flow.profile["level"] = 55
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "leshphon"})["ok"],
		"flow departs the hidden Leshphon route")
	route = flow.active_dungeon_route()
	NativePotMonsters.reset_catalog()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live Leshphon run selects its hell-base block")
	NativePotMonsters.prepare_catalog(dungeon, SourceRolls.new([0, 0, 0, 0]))
	check(session._validate_native_maze(probe, live_maze),
		"Leshphon room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "leshphon", "route": route,
		"room_id": "leshphon:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source Leshphon room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 6
			and game.view_snapshot()["hud"]["route"].size() == 6,
			"both public battle views report the complete six-room Leshphon graph")
		check(game.view.audio.has_dungeon_music("leshphon")
			and String(game.view.audio.music.stream.resource_path).ends_with("leshphon.ogg"),
			"Leshphon starts with the source M_LESHPHON track")

		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts and int(source_counts.get(
			"monster/newmonsters/leshphon/melt_knight/melt_knight.mob", 0)) == 7,
			"Leshphon start room spawns its exact seven Melt Knight lineup")

		var interactive_props := 0
		var all_gaps := {}
		for path: String in ROUTE_MAPS:
			var room: Dictionary = probe.room(path)
			var room_props: Array = game.build_props(room)
			interactive_props += room_props.size()
			for path_key: String in game.native_object_gaps:
				if not all_gaps.has(path_key):all_gaps[path_key] = []
				for gap in game.native_object_gaps[path_key]:
					if gap not in all_gaps[path_key]:all_gaps[path_key].append(gap)
		check(interactive_props == 0,
			"Leshphon does not materialise action objects as guessed battle props")
		check(all_gaps.size() == 15,
			"all fifteen Leshphon action-object identities remain explicit")
		var all_have_behavior := true
		for path_key: String in all_gaps:
			if "native_action_object_behavior" not in all_gaps[path_key]:
				all_have_behavior = false
		check(all_have_behavior,
			"every Leshphon action object keeps a behavior gap")
		var comein_gaps: Array = all_gaps.get(
			"passiveobject/actionobject/monster/leshphon/hyungteo_comein.obj", [])
		check("native_action_object_behavior" in comein_gaps
			and "native_action_object_visual" in comein_gaps,
			"Hyungteo entrance keeps both action and missing-sprite gaps")
		check(all_gaps.get("passiveobject/actionobject/monster/direzie/disease_wind.obj", [])
			== ["native_action_object_behavior"],
			"Direzie disease wind remains a behavior-only source object")
		check(all_gaps.get("passiveobject/actionobject/map/leshphon/obwall1.obj", [])
			== ["native_action_object_behavior"],
			"Leshphon pass-blocking walls remain explicit behavior gaps")
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_LESHPHON] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
