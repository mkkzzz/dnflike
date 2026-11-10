extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const FlowSession = preload("res://flow/session.gd")
const NativeMaze = preload("res://combat/data/native_maze.gd")
const NativeBreakable = preload("res://combat/resolve/native_breakable.gd")
const NativeBoxLoot = preload("res://loot/native_box.gd")
const NativeJarTraps = preload("res://combat/resolve/native_jar_traps.gd")
const NativePotMonsters = preload("res://combat/resolve/native_pot_monsters.gd")
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
		push_error("[NATIVE_MAZE_UNDERFOOT] FAIL " + label)

func expected_route() -> Dictionary:
	return {
		Vector2i(0, 0): [6602, "map/underfoot/e6602(0,0).map"],
		Vector2i(1, 0): [6604, "map/underfoot/e6604(1,0).map"],
		Vector2i(3, 0): [6611, "map/underfoot/n6611(3,0).map"],
		Vector2i(4, 0): [6612, "map/underfoot/n6612(4,0).map"],
		Vector2i(0, 1): [6601, "map/underfoot/s6601.map"],
		Vector2i(1, 1): [6606, "map/underfoot/n6606(1,1).map"],
		Vector2i(2, 1): [6607, "map/underfoot/h6607(2,1).map"],
		Vector2i(3, 1): [6609, "map/underfoot/h6609(3,1).map"],
		Vector2i(4, 1): [6613, "map/underfoot/h6613(4,1).map"],
		Vector2i(5, 1): [6615, "map/underfoot/b6615.map"],
		Vector2i(0, 2): [6603, "map/underfoot/e6603(0,2).map"],
		Vector2i(1, 2): [6605, "map/underfoot/e6605(1,2).map"],
		Vector2i(2, 2): [6608, "map/underfoot/n6608(2,2).map"],
		Vector2i(3, 2): [6610, "map/underfoot/n6610(3,2).map"],
		Vector2i(4, 2): [6614, "map/underfoot/n6614(4,2).map"],
	}

func run() -> void:
	game = session.mount(root)
	game.set_process(false)
	game.set_physics_process(false)
	var routes: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/dungeons.json"))["dungeons"]
	var route: Dictionary = routes["underfoot"]
	check(route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("name") == "暗黑城入口" and route.get("region") == "noierfera"
		and int(route.get("min_level", 0)) == 51 and int(route.get("monster_level", 0)) == 54,
		"Underfoot is a hidden level 51 Dark Elf native-maze route with source basis level 54")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production Underfoot export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/act4/underfoot.dgn"
		and dungeon.get("sha256") == "01413357d13471901ca0dcceabc466ada9449f3f888eba97c00cd5dfd8687546"
		and int(dungeon.get("index", -1)) == 36,
		"Underfoot export keeps DGN index 36 and the pinned source identity")
	check(Array(dungeon.get("placements", [])).size() == 23
		and Dictionary(dungeon.get("rooms", {})).size() == 15
		and Dictionary(probe.data.get("images", {})).size() == 111,
		"Underfoot export contains 23 greed-eligible placements, 15 MAPs and 111 source images")
	check(int(dungeon.get("maze_block_index", -1)) == 0
		and dungeon.get("maze_block_selection") == "hell_base"
		and Array(dungeon.get("maze_blocks", [])).size() == 1,
		"Underfoot selects its single source hell-base block 0")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	var errors: Array = diagnostics.filter(func(row): return row.get("level") == "error")
	var warnings: Array = diagnostics.filter(func(row): return row.get("level") == "warning")
	var infos: Array = diagnostics.filter(func(row): return row.get("level") == "info")
	check(errors.is_empty(), "Underfoot export has no source image or ANI errors")
	check(warnings.size() == 3
		and warnings.filter(func(row): return row.get("code") == "cell_without_map").size() == 3
		and warnings.filter(func(row): return row.get("code") == "object_unrendered").is_empty(),
		"Underfoot preserves three AA cells and every source object renders")
	check(infos.size() == 15
		and infos.filter(func(row): return row.get("code") == "unhandled_tags").size() == 15,
		"Underfoot preserves fifteen unhandled MAP tags and has no synthetic error record")

	var maze := NativeMaze.new()
	var size: Vector2i = maze._point(dungeon.get("size"))
	var cells: Dictionary = maze._read_cells(dungeon.get("cells"), size)
	var starts: Array = maze._read_endpoint_cells(dungeon.get("start_map_raw"), cells, "start_candidate")
	var bosses: Array = maze._read_endpoint_cells(dungeon.get("boss_map_raw"), cells, "boss_candidate")
	var specs: Dictionary = maze._read_specifications(dungeon.get("raw"), cells, 0)
	check(cells.size() == 18 and starts.size() == 1 and bosses.size() == 1,
		"Underfoot 6x3 source grid exposes one start and one boss candidate")
	check(starts[0] == Vector2i(0, 1) and bosses[0] == Vector2i(5, 1),
		"Underfoot source endpoints are start (0,1) and boss (5,1)")
	var connected := cells.values().filter(func(cell): return not cell.get("doors", []).is_empty())
	check(connected.size() == 15 and cells.values().filter(func(cell): return cell.get("code") == "AA").size() == 3,
		"Underfoot has 15 connected cells and three empty AA cells")
	check(specs.get("normal", {}).size() == 13 and specs.get("boss", {}).is_empty(),
		"Underfoot preserves thirteen normal specifications and resolves its boss from the endpoint MAP")

	var pools: Dictionary = maze._read_pools(dungeon, cells, starts[0], bosses[0])
	check(pools.size() == 15,
		"Underfoot start/boss reaches all 15 connected cells (pools=%d error=%s)"
		% [pools.size(), maze.last_error])
	var expected := expected_route()
	for cell: Vector2i in expected:
		var pool: Array = pools.get(cell, [])
		check(pool.size() == 1 and int(pool[0]["map_id"]) == int(expected[cell][0]),
			"source route chooses MAP %d at cell %s" % [int(expected[cell][0]), cell])
	check(maze.start(probe.data, SourceRolls.new([0, 0, 0]), route.get("source", {})),
		"generic native maze starts Underfoot")
	check(maze.room_count() == 15 and maze.required_map_paths().size() == 15,
		"Underfoot exposes 15 rooms across 15 source MAPs")
	check(maze.current_room().get("source_map_id") == 6601,
		"Underfoot start resolves source start MAP 6601")

	var source_monsters := {}
	var source_monster_count := 0
	var source_boss_rows := 0
	var source_object_count := 0
	var source_tags := {}
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
	check(source_monsters.size() == 7 and source_monster_count == 120 and source_boss_rows == 1,
		"Underfoot source has 120 direct placements, seven MOBs and one headless-knight boss row")
	check(source_object_count == 222 and source_tags == {
		"[passive object]": 219,
		"[special passive object]": 3,
	}, "Underfoot source has 222 objects, including three special coffin payloads")

	var route_monster_count := 0
	var route_boss_rows := 0
	var route_object_count := 0
	var route_breakable_candidates := 0
	var route_runtime_breakables := 0
	var route_objects := {}
	for cell: Vector2i in expected:
		var room: Dictionary = dungeon["rooms"][String(expected[cell][1])]
		for monster: Dictionary in room.get("monsters", []):
			route_monster_count += 1
			var raw: Array = monster.get("raw", [])
			if not raw.is_empty() and raw[-1] == "[boss]":route_boss_rows += 1
		for item: Dictionary in room.get("objects", []):
			route_object_count += 1
			var path := String(item.get("obj", "")).to_lower()
			route_objects[path] = 1 + int(route_objects.get(path, 0))
			if NativeBreakable.supports(item):
				route_breakable_candidates += 1
				if not game.content.record(path).get("native_breakable", {}).is_empty():
					route_runtime_breakables += 1
	check(route_monster_count == 120 and route_boss_rows == 1,
		"Underfoot 15-room route carries all 120 monsters and one boss row")
	check(route_object_count == 222,
		"Underfoot 15-room route carries all 222 source objects")
	check(route_objects.get("passiveobject/mapobject/breakableobject/actiontorchilght.obj") == 60
		and route_objects.get("passiveobject/mapobject/breakableobject/actionbrazier.obj") == 20
		and route_objects.get("passiveobject/mapobject/breakableobject/shallowkeepsphere.obj") == 10
		and route_objects.get("passiveobject/mapobject/breakableobject/shallowkeepcoffin.obj") == 3,
		"Underfoot preserves 60 torches, 20 braziers, ten spheres and three coffin payloads")
	check(route_objects.get("passiveobject/mapobject/trap/lightningbugghost.obj") == 19
		and route_objects.get("passiveobject/mapobject/trap/underfootgate.obj") == 1,
		"Underfoot preserves 19 lightning-bug traps and one gate")
	check(route_breakable_candidates == 93 and route_runtime_breakables == 13,
		"Underfoot compiles three coffins and ten spheres while 80 torch/brazier sources remain gaps")
	check(not NativeBoxLoot.required(dungeon),
		"Underfoot has no executable special-object item groups")
	check(NativeJarTraps.ready(game.combat_assets), "shared source jar trap assets resolve")

	var banks := {
		"monster/ghoul/ghoulheadless.mob": ["ghoul_ghoulheadless", 0],
		"monster/darkelf/darkelf_guard.mob": ["darkelf_darkelf_guard", 2],
		"monster/headlessknight/headlessknight.mob": ["headlessknight_headlessknight", 7],
		"monster/magma/incompletegoliath.mob": ["magma_incompletegoliath", 2],
		"monster/skeleton/skeleton_headless.mob": ["skeleton_skeleton_headless", 4],
		"monster/dingo_humpri/dingo.mob": ["dingo_humpri_dingo", 3],
		"monster/dingo_humpri/humpri.mob": ["dingo_humpri_humpri", 0],
	}
	for mob: String in banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		check(String(definition.get("bank", "")) == banks[mob][0]
			and game.combat_assets.get("monsters", {}).has(banks[mob][0]),
			"Underfoot source bank is compiled: " + mob)
		check(Array(definition.get("moves", [])).size() == int(banks[mob][1]),
			"source attack slots compile for %s (moves=%d expected=%d)"
			% [mob, Array(definition.get("moves", [])).size(), int(banks[mob][1])])
		check(Array(definition.get("rules", [])).is_empty(),
			"Underfoot source family exposes no scripted selection rule for " + mob)
		for move: Dictionary in Array(definition.get("moves", [])):
			if not move.has("atk_path"):continue
			check(not game.table.atk(String(move["atk_path"])).is_empty()
				and not Array(move.get("timeline", [])).is_empty(),
				"source attack motion and ATK compile together: " + mob)
	for mob in ["monster/ghoul/ghoulheadless.mob", "monster/dingo_humpri/humpri.mob"]:
		var single_kind: String = game.table.monster_by_mob(mob)
		var single: Dictionary = game.table.monsters.get(single_kind, {})
		check(not Dictionary(single.get("atk", {})).is_empty()
			and not Array(single.get("attack_timeline", [])).is_empty(),
			"single source attack remains available through the shared base attack path: " + mob)

	var bgm: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/bgm.json"))
	check(bgm.get("dungeons", {}).get("underfoot", {}).get("normal") == "underfoot_enterence"
		and bgm.get("dungeons", {}).get("underfoot", {}).get("boss") == "underfoot_enterence_boss",
		"Underfoot maps its source entrance and boss tracks")

	var flow := FlowSession.new()
	flow.profile["level"] = 54
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "underfoot"})["ok"],
		"flow departs the hidden Underfoot route")
	route = flow.active_dungeon_route()
	NativePotMonsters.reset_catalog()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live Underfoot run selects its hell-base block")
	NativePotMonsters.prepare_catalog(dungeon, SourceRolls.new([0, 0, 0, 0]))
	check(session._validate_native_maze(probe, live_maze),
		"Underfoot room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "underfoot", "route": route,
		"room_id": "underfoot:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source Underfoot room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 15
			and game.view_snapshot()["hud"]["route"].size() == 15,
			"both public battle views report the complete Underfoot graph")
		check(game.view.audio.has_dungeon_music("underfoot")
			and String(game.view.audio.music.stream.resource_path).ends_with("underfoot_enterence.ogg"),
			"Underfoot starts with the source M_UNDERFOOT_ENTER track")

		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts,
			"Underfoot start room spawns its exact source monster lineup")

		var interactive_props := 0
		var all_gaps := {}
		for path: String in expected_route().values().map(func(value): return String(value[1])):
			var room: Dictionary = probe.room(path)
			var room_props: Array = game.build_props(room)
			interactive_props += room_props.size()
			for path_key: String in game.native_object_gaps:
				if not all_gaps.has(path_key):all_gaps[path_key] = []
				for gap in game.native_object_gaps[path_key]:
					if gap not in all_gaps[path_key]:all_gaps[path_key].append(gap)
		check(interactive_props == 13,
			"Underfoot materialises three coffins and ten spheres")
		check(all_gaps.get("passiveobject/mapobject/breakableobject/actiontorchilght.obj", [])
			== ["native_breakable_source"]
			and all_gaps.get("passiveobject/mapobject/breakableobject/actionbrazier.obj", [])
			== ["native_breakable_source"],
			"torches and braziers remain explicit breakable-source gaps")
		var coffin_gaps: Array = all_gaps.get(
			"passiveobject/mapobject/breakableobject/shallowkeepcoffin.obj", [])
		check(2211 in coffin_gaps,
			"coffins preserve unresolved source trap 2211 (actual=%s)" % str(coffin_gaps))
		check(all_gaps.get("passiveobject/mapobject/trap/lightningbugghost.obj", [])
			== ["native_object_trigger"]
			and all_gaps.get("passiveobject/mapobject/trap/actxnecklessknight.obj", [])
			== ["native_object_trigger"]
			and all_gaps.get("passiveobject/mapobject/trap/underfootgate.obj", [])
			== ["native_object_trigger"],
			"lightning bugs, neckless-knight triggers and the entrance gate remain explicit behavior gaps")
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_UNDERFOOT] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
