extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const FlowSession = preload("res://flow/session.gd")
const NativeMaze = preload("res://combat/data/native_maze.gd")
const NativeBreakable = preload("res://combat/resolve/native_breakable.gd")
const NativeBoxLoot = preload("res://loot/native_box.gd")
const NativeJarTraps = preload("res://combat/resolve/native_jar_traps.gd")
const NativePotMonsters = preload("res://combat/resolve/native_pot_monsters.gd")
const DetRng = preload("res://core/det_rng.gd")

const SOURCE_SHA := "07b325e117ca93583d08afc7e2e6b4d278dff87263e7b582ba8a02748311bdb4"
const MAP_ORDER: Array[int] = [15093, 15108, 15094]

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
		push_error("[NATIVE_MAZE_DEADMOON] FAIL " + label)

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

func rooms_by_id(dungeon: Dictionary) -> Dictionary:
	var result := {}
	for path: String in dungeon.get("rooms", {}):
		var room: Dictionary = dungeon["rooms"][path]
		result[int(room["map_id"])] = room
	return result

func run() -> void:
	game = session.mount(root)
	game.set_process(false)
	game.set_physics_process(false)
	var routes: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/dungeons.json"))["dungeons"]
	var route: Dictionary = routes["deadmoon"]
	check(route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("name") == "亡月雷鸣废墟" and route.get("region") == "deadmoon"
		and int(route.get("min_level", 0)) == 20
		and int(route.get("monster_level", 0)) == 23,
		"level 20 Dead Moon is an isolated hidden native route")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])),
		"production level 20 Dead Moon export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/quest/deadmoon.dgn"
		and dungeon.get("sha256") == SOURCE_SHA
		and int(dungeon.get("index", -1)) == 503,
		"level 20 Dead Moon keeps DGN index 503 and the pinned source identity")
	check(Array(dungeon.get("placements", [])).size() == 3
		and Dictionary(dungeon.get("rooms", {})).size() == 3
		and Dictionary(probe.data.get("images", {})).size() == 67,
		"level 20 Dead Moon retains three rooms and 67 source images")
	check(String(dungeon.get("cell_map_rule", "")).contains("E-PARSE")
		and int(dungeon.get("maze_block_index", -1)) == 0
		and dungeon.get("maze_block_selection") == "ordinary"
		and Array(dungeon.get("maze_blocks", [])).size() == 1,
		"level 20 Dead Moon selects its single ordinary block")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	check(diagnostics.filter(func(row): return row.get("level") == "error").is_empty()
		and diagnostics.filter(func(row): return row.get("level") == "warning").is_empty(),
		"level 20 Dead Moon has no source dependency diagnostics")
	check(diagnostics.filter(func(row): return row.get("code") == "unhandled_tags").size() == 3,
		"level 20 Dead Moon preserves three MAP tag reports")

	var maze := NativeMaze.new()
	var size: Vector2i = maze._point(dungeon.get("size"))
	var cells: Dictionary = maze._read_cells(dungeon.get("cells"), size)
	var starts: Array = maze._read_endpoint_cells(dungeon.get("start_map_raw"), cells, "start_candidate")
	var bosses: Array = maze._read_endpoint_cells(dungeon.get("boss_map_raw"), cells, "boss_candidate")
	var specs: Dictionary = maze._read_specifications(dungeon.get("raw"), cells, 0)
	check(size == Vector2i(3, 1) and cells.size() == 3
		and starts == [Vector2i(2, 0)] and bosses == [Vector2i(0, 0)],
		"level 20 Dead Moon exposes one start and one boss cell")
	check(specs.get("normal", {}).get(Vector2i(2, 0)) == [15093]
		and specs.get("normal", {}).get(Vector2i(1, 0)) == [15108]
		and specs.get("boss", {}).get(Vector2i(0, 0)) == [15094],
		"level 20 Dead Moon binds MAP15093, MAP15108 and boss MAP15094")
	check(raw_values(dungeon.get("raw", []), "[minimum required level]") == [20]
		and raw_values(dungeon.get("raw", []), "[basis level]") == [23]
		and raw_values(dungeon.get("raw", []), "[limit party count]") == [1]
		and raw_values(dungeon.get("raw", []), "[designate dungeon difficulty]") == [0],
		"level 20 Dead Moon preserves level, single-player and fixed-difficulty fields")
	check(raw_values(dungeon.get("raw", []), "[champion]") == [3, 6, 9, 12, 14]
		and raw_values(dungeon.get("raw", []), "[pathgate object]")
			== [381, 382, 383, 384, 385, 386, 387, 388, 389, 390],
		"level 20 Dead Moon preserves champion and pathgate source lists")

	var rooms := rooms_by_id(dungeon)
	check(rooms[15093]["monsters"].size() == 7 and rooms[15093]["objects"].size() == 4
		and rooms[15108]["monsters"].size() == 11 and rooms[15108]["objects"].size() == 2
		and rooms[15094]["monsters"].size() == 12 and rooms[15094]["objects"].size() == 34,
		"level 20 Dead Moon source room monster/object counts remain fixed")
	var all_monsters := {}
	var all_objects := []
	var monster_count := 0
	var boss_rows := 0
	var breakable_shaped := 0
	for room: Dictionary in rooms.values():
		for monster: Dictionary in room["monsters"]:
			all_monsters[String(monster["mob"])] = true
			monster_count += 1
			if Array(monster.get("raw", [])).has("[boss]"):
				boss_rows += 1
		for item: Dictionary in room["objects"]:
			all_objects.append(item)
			if NativeBreakable.supports(item):
				breakable_shaped += 1
	check(all_monsters.size() == 8 and monster_count == 30 and boss_rows == 2,
		"level 20 Dead Moon retains 30 monsters across eight MOBs and two boss rows")
	check(all_objects.size() == 40 and breakable_shaped == 29,
		"level 20 Dead Moon retains 40 objects including twenty-nine breakable-shaped grasses")
	var boss_mobs: Array[String] = []
	for monster: Dictionary in rooms[15094]["monsters"]:
		if Array(monster.get("raw", [])).has("[boss]"):
			boss_mobs.append(String(monster["mob"]))
	check(boss_mobs == [
		"monster/lugaru/penril.mob",
		"monster/zombie/zombieghoulgwish.mob",
	], "level 20 Dead Moon preserves both source boss rows")
	check(Array(rooms[15094]["raw"]).filter(
		func(span): return span.get("tag") == "[NPC]").size() == 1,
		"level 20 Dead Moon boss MAP retains its independent NPC1000 row")

	var object_paths := {}
	for item: Dictionary in all_objects:
		var path := String(item.get("obj", ""))
		object_paths[path] = 1 + int(object_paths.get(path, 0))
	check(object_paths == {
		"passiveobject/mapobject/breakableobject/largegrasssunderland.obj": 10,
		"passiveobject/mapobject/breakableobject/smallgrasssunderland.obj": 19,
		"passiveobject/mapobject/obstacle/smallpillar2.obj": 5,
		"passiveobject/mapobject/obstacle/stonepillar2.obj": 6,
	}, "level 20 Dead Moon preserves exact grass and pillar counts")
	for path: String in [
		"passiveobject/mapobject/breakableobject/largegrasssunderland.obj",
		"passiveobject/mapobject/breakableobject/smallgrasssunderland.obj",
	]:
		check(Dictionary(game.content.record(path).get("native_breakable", {})).is_empty(),
			"Dead Moon grass remains an explicit missing source: " + path)
	check(not NativeBoxLoot.required(dungeon),
		"Dead Moon DGN item groups are not referenced by special objects")

	var banks := {
		"monster/lugaru/lugaru.mob": ["lugaru", 4, [0, 1, 2, 3]],
		"monster/lugaru/sirogaru.mob": ["lugaru_sirogaru", 6, [0, 1, 2, 3, 4]],
		"monster/villageattacked/goblinthrowertaskmaster.mob":
			["villageattacked_goblinthrowertaskmaster", 0, []],
		"monster/lugaru/kurogaru.mob": ["kurogaru", 4, [0, 1, 2, 3]],
		"monster/lugaru/penril.mob": ["lugaru_penril", 5, [0, 1, 2, 3, 4]],
		"monster/zombie/zombieghoulgwish.mob":
			["zombie_zombieghoulgwish", 2, [0, 1]],
		"monster/zombie/zombieholloweye.mob":
			["zombie_zombieholloweye", 3, [0, 1, 2]],
		"monster/zombie/zombiezombie.mob": ["zombie_zombiezombie", 2, [0, 1]],
	}
	var total_moves := 0
	for mob: String in banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		check(String(definition.get("bank", "")) == banks[mob][0]
			and game.combat_assets.get("monsters", {}).has(banks[mob][0]),
			"Dead Moon source bank is compiled: " + mob)
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
	var thrower: Dictionary = game.table.monsters[
		game.table.monster_by_mob("monster/villageattacked/goblinthrowertaskmaster.mob")]
	check(not Array(thrower.get("attack_timeline", [])).is_empty()
		and Dictionary(thrower.get("throw", {})).is_empty(),
		"goblin thrower taskmaster keeps its source timeline without inventing throw data")
	check(total_moves == 26,
		"level 20 Dead Moon compiles 26 indexed action slots; actual=%d" % total_moves)
	check(NativeJarTraps.ready(game.combat_assets),
		"shared verified jar trap assets resolve")

	var bgm: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/bgm.json"))
	check(bgm.get("dungeons", {}).get("deadmoon", {}).get("normal") == "sunderland_boss"
		and bgm.get("dungeons", {}).get("deadmoon", {}).get("boss") == "sunderland_boss"
		and not bgm.get("source_gaps", {}).has("deadmoon"),
		"level 20 Dead Moon maps its all-boss M_SUNDERLAND_BOSS cue")

	var sample := NativeMaze.new()
	check(sample.start(probe.data, SourceRolls.new([0, 0, 0, 0, 0, 0]),
		route.get("source", {})),
		"generic native maze starts level 20 Dead Moon")
	check(sample.room_count() == 3
		and int(sample.current_room().get("source_map_id", 0)) == 15093,
		"level 20 Dead Moon starts in MAP15093 with three rooms")
	var selected_ids: Array[int] = [15093]
	for expected in [15108, 15094]:
		var cleared: Dictionary = sample.clear_room(sample.current_room()["cell"], 0)
		var moved: Dictionary = sample.move("left")
		check(not cleared.is_empty() and not moved.is_empty(),
			"level 20 Dead Moon clears and traverses toward MAP%d" % expected)
		selected_ids.append(int(moved.get("source_map_id", 0)))
	check(selected_ids == MAP_ORDER,
		"level 20 Dead Moon selects MAP15093, MAP15108 and boss MAP15094")
	check(bool(sample.clear_room(Vector2i(0, 0), 0).get("final_room", false)),
		"level 20 Dead Moon boss room is final")

	var flow := FlowSession.new()
	flow.profile["level"] = 60
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "deadmoon"})["ok"],
		"flow departs the hidden level 20 Dead Moon route")
	route = flow.active_dungeon_route()
	NativePotMonsters.reset_catalog()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})),
		"live level 20 Dead Moon run selects its source route")
	NativePotMonsters.prepare_catalog(dungeon, SourceRolls.new([0, 0, 0, 0]))
	check(session._validate_native_maze(probe, live_maze),
		"level 20 Dead Moon room, MOB, object and image dependencies validate ("
		+ session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "deadmoon", "route": route,
		"room_id": "deadmoon:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts level 20 Dead Moon (error=%s)"
		% session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 3
			and game.view_snapshot()["hud"]["route"].size() == 3,
			"both public battle views report the three-room graph")
		check(game.view.audio.has_dungeon_music("deadmoon")
			and String(game.view.audio.music.stream.resource_path).ends_with(
				"sunderland_boss.ogg"),
			"level 20 Dead Moon starts with M_SUNDERLAND_BOSS")
		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		check(int(source_counts.get(
			"monster/villageattacked/goblinthrowertaskmaster.mob", 0)) == 2
			and int(source_counts.get("monster/zombie/zombiezombie.mob", 0)) == 5,
			"level 20 Dead Moon start room spawns two taskmasters and five zombies")
		var total_props := 0
		var all_gap_paths := {}
		for map_id: int in rooms:
			var room_props: Array = game.build_props(rooms[map_id])
			total_props += room_props.size()
			check(room_props.is_empty(),
				"level 20 Dead Moon grasses do not become guessed props in MAP%d" % map_id)
			for path: String in game.native_object_gaps:
				all_gap_paths[path] = true
		check(total_props == 0, "level 20 Dead Moon has no executable breakable props")
		check(all_gap_paths.has(
			"passiveobject/mapobject/breakableobject/largegrasssunderland.obj")
			and all_gap_paths.has(
				"passiveobject/mapobject/breakableobject/smallgrasssunderland.obj"),
			"both grass families remain explicit native-breakable gaps")
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_DEADMOON] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
