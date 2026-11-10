extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const FlowSession = preload("res://flow/session.gd")
const NativeMaze = preload("res://combat/data/native_maze.gd")
const NativeBreakable = preload("res://combat/resolve/native_breakable.gd")
const NativeBoxLoot = preload("res://loot/native_box.gd")
const NativeJarTraps = preload("res://combat/resolve/native_jar_traps.gd")
const NativePotMonsters = preload("res://combat/resolve/native_pot_monsters.gd")
const DetRng = preload("res://core/det_rng.gd")
const ROUTE_MAP_IDS: Array[int] = [5201, 5202, 5203, 5204, 5205, 5206]
const ROUTE_MAPS: Array[String] = [
	"map/vilmark/s5201.map",
	"map/vilmark/h5201.map",
	"map/vilmark/h5202.map",
	"map/vilmark/h5203.map",
	"map/vilmark/h5204.map",
	"map/vilmark/b5201.map",
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
		push_error("[NATIVE_MAZE_VILMARK] FAIL " + label)

func run() -> void:
	game = session.mount(root)
	game.set_process(false)
	game.set_physics_process(false)
	var routes: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/dungeons.json"))["dungeons"]
	var route: Dictionary = routes["vilmark"]
	check(route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("name") == "比尔马克帝国试验场" and route.get("region") == "elvengard"
		and int(route.get("min_level", 0)) == 55 and int(route.get("monster_level", 0)) == 58,
		"Vilmark is a hidden level 55 Elvengard native-maze route with source basis level 58")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production Vilmark export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/ancient/vilmark.dgn"
		and dungeon.get("sha256") == "4505427c9068da16427cd32547f070e9f912352d7d9f9cd00ae51dcd26fee45d"
		and int(dungeon.get("index", -1)) == 1500,
		"Vilmark export keeps DGN index 1500 and the pinned source identity")
	check(Array(dungeon.get("placements", [])).size() == 18
		and Dictionary(dungeon.get("rooms", {})).size() == 6
		and Dictionary(probe.data.get("images", {})).size() == 47,
		"Vilmark export contains 18 greed-eligible placements, six MAPs and 47 source images")
	check(int(dungeon.get("maze_block_index", -1)) == 0
		and dungeon.get("maze_block_selection") == "hell_base"
		and Array(dungeon.get("maze_blocks", [])).size() == 1,
		"Vilmark selects its single source hell-base block 0")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	var errors: Array = diagnostics.filter(func(row): return row.get("level") == "error")
	var warnings: Array = diagnostics.filter(func(row): return row.get("level") == "warning")
	var infos: Array = diagnostics.filter(func(row): return row.get("level") == "info")
	check(errors.is_empty() and warnings.is_empty(),
		"Vilmark export has no source image, ANI or object warnings")
	check(infos.size() == 6
		and infos.filter(func(row): return row.get("code") == "unhandled_tags").size() == 6,
		"Vilmark preserves six unhandled source tag reports")

	var maze := NativeMaze.new()
	var size: Vector2i = maze._point(dungeon.get("size"))
	var cells: Dictionary = maze._read_cells(dungeon.get("cells"), size)
	var starts: Array = maze._read_endpoint_cells(dungeon.get("start_map_raw"), cells, "start_candidate")
	var bosses: Array = maze._read_endpoint_cells(dungeon.get("boss_map_raw"), cells, "boss_candidate")
	var specs: Dictionary = maze._read_specifications(dungeon.get("raw"), cells, 0)
	check(cells.size() == 6 and starts.size() == 1 and bosses.size() == 1,
		"Vilmark 6x1 source grid exposes one start and one boss candidate")
	check(starts[0] == Vector2i(0, 0) and bosses[0] == Vector2i(5, 0),
		"Vilmark source endpoints are start (0,0) and boss (5,0)")
	check(cells.values().filter(func(cell): return not cell.get("doors", []).is_empty()).size() == 6,
		"Vilmark has six connected cells")
	check(specs.get("normal", {}).size() == 6 and specs.get("boss", {}).is_empty(),
		"Vilmark preserves six fixed normal MAP specifications and no separate boss specification")
	var block: Dictionary = Array(dungeon.get("maze_blocks", []))[0]
	check(Array(block.get("map_specifications", [])).map(func(row): return int(row[2]))
		== [5206, 5205, 5204, 5203, 5202, 5201]
		and Array(block.get("hell_dungeon", [])).map(func(value): return int(value)) == [1]
		and Array(block.get("seal_door_map_index", [])).map(func(value): return int(value)) == [60038]
		and Array(block.get("seal_door_pos", [])).map(func(value): return int(value)) == [4, 0]
		and Array(block.get("seal_door_appear_rate", [])).map(func(value): return int(value)) == [10],
		"Vilmark preserves MAP 5201..5206, hell mode and seal door 60038 at 4,0 with rate 10")

	var pools: Dictionary = maze._read_pools(dungeon, cells, starts[0], bosses[0])
	check(pools.size() == 6,
		"Vilmark start/boss reaches all six connected cells (pools=%d error=%s)"
		% [pools.size(), maze.last_error])
	check(maze.start(probe.data, SourceRolls.new([0, 0]), route.get("source", {})),
		"generic native maze starts Vilmark")
	check(maze.room_count() == 6 and maze.required_map_paths().size() == 6,
		"Vilmark exposes six rooms across six source-fixed MAPs")
	var selected_ids: Array[int] = [int(maze.current_room().get("source_map_id", 0))]
	for step in 5:
		var current: Vector2i = maze.current_room().get("cell", Vector2i(-1, -1))
		var cleared: Dictionary = maze.clear_room(current, 0)
		var moved: Dictionary = maze.move("right")
		check(not cleared.is_empty() and not moved.is_empty(),
			"Vilmark clears and traverses source step %d" % step)
		selected_ids.append(int(moved.get("source_map_id", 0)))
	check(selected_ids == ROUTE_MAP_IDS,
		"Vilmark selects MAP 5201..5206 in the fixed start-to-boss order")
	var final_clear: Dictionary = maze.clear_room(Vector2i(5, 0), 0)
	check(bool(final_clear.get("boss", false)) and bool(final_clear.get("final_room", false)),
		"the source Meta Tau room is the sole boss and final room")
	check(NativeBoxLoot.ready(dungeon), "Vilmark item groups and v11 source art resolve")
	check(NativeJarTraps.ready(game.combat_assets), "shared source jar trap assets resolve")

	var source_monsters := {}
	var source_monster_count := 0
	var source_boss_rows := 0
	var source_object_count := 0
	var source_tags := {}
	var source_objects := {}
	var source_breakable_candidates := 0
	var source_runtime_breakables := 0
	var source_box_objects := 0
	var source_jar_candidates := 0
	var source_unknown_trap_ids := {}
	var treasure_box_item := {}
	for room: Dictionary in dungeon.get("rooms", {}).values():
		for monster: Dictionary in room.get("monsters", []):
			source_monsters[String(monster.get("mob", ""))] = true
			source_monster_count += 1
			var raw: Array = monster.get("raw", [])
			if not raw.is_empty() and raw[-1] == "[boss]":source_boss_rows += 1
		for item: Dictionary in room.get("objects", []):
			source_object_count += 1
			var tag := String(item.get("source_tag", ""))
			source_tags[tag] = 1 + int(source_tags.get(tag, 0))
			var source_path := String(item.get("obj", "")).to_lower()
			source_objects[source_path] = 1 + int(source_objects.get(source_path, 0))
			if source_path.ends_with("/treasurebox.obj"):treasure_box_item = item
			if NativeBreakable.supports(item):
				source_breakable_candidates += 1
				if not game.content.record(source_path).get("native_breakable", {}).is_empty():
					source_runtime_breakables += 1
				if NativeBoxLoot.draw_count(item) > 0:source_box_objects += 1
			if not NativeJarTraps.candidate_rows(item).is_empty():source_jar_candidates += 1
			for source_id in NativeJarTraps.unresolved_ids(item):
				source_unknown_trap_ids[int(source_id)] = true
	check(source_monsters.size() == 6 and source_monster_count == 37 and source_boss_rows == 1,
		"Vilmark source has 37 direct placements, six MOBs and one boss row")
	check(source_object_count == 209 and source_tags == {
		"[passive object]": 159,
		"[special passive object]": 50,
	}, "Vilmark source has 209 objects, including 50 special passive-object rows")
	check(source_objects.get("passiveobject/mapobject/breakableobject/transporter_1.obj") == 24
		and source_objects.get("passiveobject/mapobject/breakableobject/vilmarkbox.obj") == 39
		and source_objects.get("passiveobject/mapobject/breakableobject/transporter_2.obj") == 14
		and source_objects.get("passiveobject/mapobject/breakableobject/largegrassmirkwood.obj") == 49
		and source_objects.get("passiveobject/mapobject/breakableobject/smallgrassmirkwood.obj") == 33
		and source_objects.get("passiveobject/mapobject/breakableobject/eventbarrier_2.obj") == 16
		and source_objects.get("passiveobject/mapobject/breakableobject/mobgen_1.obj") == 3
		and source_objects.get("passiveobject/mapobject/breakableobject/mobgen_2.obj") == 2
		and source_objects.get("passiveobject/mapobject/breakableobject/treasurebox.obj") == 1
		and source_objects.get("passiveobject/mapobject/obstacle/burnttree1.obj") == 4
		and source_objects.get("passiveobject/mapobject/obstacle/burnttree2.obj") == 16,
		"Vilmark preserves its 12 source object identities and counts")
	check(source_breakable_candidates == 189 and source_runtime_breakables == 77
		and source_box_objects == 19 and source_jar_candidates == 26,
		"Vilmark compiles 77 of 189 breakable candidates, 19 box rows and 26 known jar rows")
	check(not treasure_box_item.is_empty() and NativeBoxLoot.draw_count(treasure_box_item) == 7,
		"Vilmark treasure box preserves its seven group-2 item draws")
	var unknown_ids: Array[int] = []
	for source_id: int in source_unknown_trap_ids:unknown_ids.append(source_id)
	unknown_ids.sort()
	check(unknown_ids == [2010, 2011, 2110, 2111, 2211, 2212, 2311, 2510, 2511, 2610, 2611],
		"Vilmark leaves eleven mixed transporter trap IDs unresolved")
	for mob: String in source_monsters:
		check(not game.table.monster_by_mob(mob).is_empty(),
			"direct source MOB has runtime content: " + mob)

	var banks := {
		"monster/goblin/goblinkrazyivancaptain.mob": ["goblin_goblinkrazyivancaptain", 2],
		"monster/lugaru/bloodlugaru.mob": ["lugaru_bloodlugaru", 5],
		"monster/lugaru/ciel.mob": ["lugaru_ciel", 5],
		"monster/lugaru/heart.mob": ["lugaru_heart", 5],
		"monster/tau/taucaptain.mob": ["tau_taucaptain", 2],
		"monster/tau/taumetacow.mob": ["tau_taumetacow", 6],
	}
	for mob: String in banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		check(String(definition.get("bank", "")) == banks[mob][0]
			and game.combat_assets.get("monsters", {}).has(banks[mob][0]),
			"Vilmark source bank is compiled: " + mob)
		check(Array(definition.get("moves", [])).size() == int(banks[mob][1]),
			"source attack slots compile for %s (moves=%d expected=%d)"
			% [mob, Array(definition.get("moves", [])).size(), int(banks[mob][1])])
		var expected_rules: Array = [0, 1] if mob == "monster/lugaru/bloodlugaru.mob" else []
		var actual_rules: Array = []
		for rule: Dictionary in Array(definition.get("rules", [])):
			actual_rules.append(int(rule.get("skill", -1)))
		check(actual_rules == expected_rules,
			"Vilmark source selection rules compile for " + mob)
		for move: Dictionary in Array(definition.get("moves", [])):
			if not move.has("atk_path"):continue
			check(not game.table.atk(String(move["atk_path"])).is_empty()
				and not Array(move.get("timeline", [])).is_empty(),
				"source attack motion and ATK compile together: " + mob)

	var bgm: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/bgm.json"))
	check(bgm.get("dungeons", {}).get("vilmark", {}).get("normal") == "vilmark"
		and bgm.get("dungeons", {}).get("vilmark", {}).get("boss") == "vilmark_boss",
		"Vilmark maps its source M_VILMARK normal and boss tracks")
	check(not bgm.get("source_gaps", {}).has("vilmark"),
		"Vilmark has no unresolved MAP music cue")

	var flow := FlowSession.new()
	flow.profile["level"] = 58
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "vilmark"})["ok"],
		"flow departs the hidden Vilmark route")
	route = flow.active_dungeon_route()
	NativePotMonsters.reset_catalog()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live Vilmark run selects its hell-base block")
	NativePotMonsters.prepare_catalog(dungeon, SourceRolls.new([0, 0, 0, 0]))
	check(session._validate_native_maze(probe, live_maze),
		"Vilmark room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "vilmark", "route": route,
		"room_id": "vilmark:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source Vilmark room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 6
			and game.view_snapshot()["hud"]["route"].size() == 6,
			"both public battle views report the complete six-room Vilmark graph")
		check(game.view.audio.has_dungeon_music("vilmark")
			and String(game.view.audio.music.stream.resource_path).ends_with("vilmark.ogg"),
			"Vilmark starts with the source M_VILMARK track")

		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts and int(source_counts.get(
			"monster/lugaru/bloodlugaru.mob", 0)) == 6,
			"Vilmark start room spawns its exact six Blood Lugaru lineup")

		var interactive_props := 0
		var box_props := 0
		var known_jar_ids := {}
		var live_unknown_ids: Array[int] = []
		var all_gaps := {}
		for path: String in ROUTE_MAPS:
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
					if int(source_id) not in live_unknown_ids:
						live_unknown_ids.append(int(source_id))
			for path_key: String in game.native_object_gaps:
				if not all_gaps.has(path_key):all_gaps[path_key] = []
				for gap in game.native_object_gaps[path_key]:
					if gap not in all_gaps[path_key]:all_gaps[path_key].append(gap)
		live_unknown_ids.sort()
		check(interactive_props == 77,
			"all 77 contracted Vilmark breakables build exactly once across six MAPs")
		check(box_props > 0 and box_props <= 19,
			"Vilmark prepares non-empty source item-box draws (prepared=%d source=19)" % box_props)
		check(known_jar_ids.keys().size() == 2 and known_jar_ids.has(40002)
			and known_jar_ids.has(48003),
			"Vilmark transporter rows execute their two verified source jar traps")
		check(live_unknown_ids == [2010, 2011, 2110, 2111, 2211, 2212, 2311, 2510, 2511, 2610, 2611],
			"unsupported Vilmark transporter traps remain explicit: " + str(live_unknown_ids))
		check(all_gaps.get("passiveobject/mapobject/breakableobject/largegrassmirkwood.obj", [])
			== ["native_breakable_source"]
			and all_gaps.get("passiveobject/mapobject/breakableobject/smallgrassmirkwood.obj", [])
			== ["native_breakable_source"]
			and all_gaps.get("passiveobject/mapobject/breakableobject/eventbarrier_2.obj", [])
			== ["native_breakable_source"]
			and all_gaps.get("passiveobject/mapobject/breakableobject/mobgen_1.obj", [])
			== ["native_breakable_source"],
			"grass, event barriers and monster generators remain explicit breakable-source gaps")
		check(not all_gaps.has("passiveobject/mapobject/obstacle/burnttree1.obj")
			and not all_gaps.has("passiveobject/mapobject/obstacle/burnttree2.obj"),
			"burnt tree obstacles remain source-only instead of false runtime triggers")
		var treasure_gaps: Array = all_gaps.get(
			"passiveobject/mapobject/breakableobject/treasurebox.obj", [])
		check("native_breakable_source" in treasure_gaps and "native_special_object" in treasure_gaps,
			"the treasure box keeps both breakable and item-group gaps (actual=%s)"
			% str(treasure_gaps))
		var transporter_gaps: Array = all_gaps.get(
			"passiveobject/mapobject/breakableobject/transporter_2.obj", [])
		check(2211 in transporter_gaps and 2212 in transporter_gaps,
			"transporter_2 preserves traps 2211/2212 (actual=%s)" % str(transporter_gaps))
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_VILMARK] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
