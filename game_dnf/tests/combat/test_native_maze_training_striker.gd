extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const FlowSession = preload("res://flow/session.gd")
const NativeMaze = preload("res://combat/data/native_maze.gd")
const NativeBreakable = preload("res://combat/resolve/native_breakable.gd")
const NativeBoxLoot = preload("res://loot/native_box.gd")
const NativeJarTraps = preload("res://combat/resolve/native_jar_traps.gd")
const NativePotMonsters = preload("res://combat/resolve/native_pot_monsters.gd")
const DetRng = preload("res://core/det_rng.gd")

const SOURCE_SHA := "9a232e2ae73a73c78a2c587b1c005a3797e917cfbb0194b9f10657e9e96566dd"
const MAP_ORDER: Array[int] = [15111, 15112, 15113]

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
		push_error("[NATIVE_MAZE_TRAINING_STRIKER] FAIL " + label)

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
	var route: Dictionary = routes["training_striker"]
	check(route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("name") == "月光修炼场"
		and route.get("region") == "training_striker"
		and int(route.get("min_level", 0)) == 20
		and int(route.get("monster_level", 0)) == 23,
		"training_striker is an isolated hidden level 20/23 native route")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])),
		"production training_striker export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/quest/training_striker.dgn"
		and dungeon.get("sha256") == SOURCE_SHA
		and int(dungeon.get("index", -1)) == 505,
		"training_striker keeps DGN505 and the pinned source identity")
	check(Array(dungeon.get("placements", [])).size() == 3
		and Dictionary(dungeon.get("rooms", {})).size() == 3
		and Dictionary(probe.data.get("images", {})).size() == 43,
		"training_striker retains three rooms and 43 source images")
	check(String(dungeon.get("cell_map_rule", "")).contains("E-PARSE")
		and int(dungeon.get("maze_block_index", -1)) == 0
		and dungeon.get("maze_block_selection") == "ordinary"
		and Array(dungeon.get("maze_blocks", [])).size() == 1,
		"training_striker selects its single ordinary block")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	check(diagnostics.filter(func(row): return row.get("level") == "error").is_empty(),
		"training_striker has no source image or ANI errors")
	check(diagnostics.filter(func(row): return row.get("code") == "object_unrendered").size() == 20,
		"training_striker preserves twenty unrendered Aganzo furniture objects")
	check(diagnostics.filter(func(row): return row.get("code") == "unhandled_tags").size() == 3,
		"training_striker preserves three MAP tag reports")

	var maze := NativeMaze.new()
	var size: Vector2i = maze._point(dungeon.get("size"))
	var cells: Dictionary = maze._read_cells(dungeon.get("cells"), size)
	var starts: Array = maze._read_endpoint_cells(
		dungeon.get("start_map_raw"), cells, "start_candidate")
	var bosses: Array = maze._read_endpoint_cells(
		dungeon.get("boss_map_raw"), cells, "boss_candidate")
	var specs: Dictionary = maze._read_specifications(dungeon.get("raw"), cells, 0)
	check(size == Vector2i(3, 1) and cells.size() == 3
		and starts == [Vector2i(2, 0)] and bosses == [Vector2i(0, 0)],
		"training_striker exposes one start and one boss cell")
	check(specs.get("normal", {}).get(Vector2i(2, 0)) == [15111]
		and specs.get("normal", {}).get(Vector2i(1, 0)) == [15112]
		and specs.get("boss", {}).get(Vector2i(0, 0)) == [15113],
		"training_striker binds MAP15111, MAP15112 and boss MAP15113")
	check(raw_values(dungeon.get("raw", []), "[minimum required level]") == [20]
		and raw_values(dungeon.get("raw", []), "[basis level]") == [23]
		and raw_values(dungeon.get("raw", []), "[limit party count]") == [1]
		and raw_values(dungeon.get("raw", []), "[designate dungeon difficulty]") == [0],
		"training_striker preserves level, single-player and fixed-difficulty fields")
	check(raw_values(dungeon.get("raw", []), "[champion]") == [6, 12, 18, 24, 26]
		and raw_values(dungeon.get("raw", []), "[pathgate object]")
			== [5540, 5541, 5542, 5543, 5544, 5545, 5546, 5547, 5548, 5549],
		"training_striker preserves champion and pathgate source lists")

	var rooms := rooms_by_id(dungeon)
	check(rooms[15111]["monsters"].size() == 10 and rooms[15111]["objects"].size() == 4
		and rooms[15112]["monsters"].size() == 12 and rooms[15112]["objects"].size() == 13
		and rooms[15113]["monsters"].size() == 13 and rooms[15113]["objects"].size() == 6,
		"training_striker source room monster/object counts remain fixed")
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
	check(all_monsters.size() == 6 and monster_count == 35 and boss_rows == 1,
		"training_striker retains 35 monsters across six MOBs and one boss row")
	check(all_objects.size() == 23 and breakable_shaped == 20,
		"training_striker retains 23 objects including twenty furniture rows")
	var boss_mobs: Array[String] = []
	for monster: Dictionary in rooms[15113]["monsters"]:
		if Array(monster.get("raw", [])).has("[boss]"):
			boss_mobs.append(String(monster["mob"]))
	check(boss_mobs == ["monster/goblin/kinol.mob"],
		"training_striker preserves Kinol as its sole source boss row")
	check(Array(rooms[15113]["raw"]).filter(
		func(span): return span.get("tag") == "[NPC]").size() == 1,
		"training_striker boss MAP retains its independent NPC1000 row")
	check(Array(rooms[15113]["raw"]).filter(
		func(span): return span.get("tag") == "[ai character]").is_empty(),
		"training_striker has no AICharacter-only boss gate")

	var object_paths := {}
	for item: Dictionary in all_objects:
		var path := String(item.get("obj", ""))
		object_paths[path] = 1 + int(object_paths.get(path, 0))
	check(object_paths == {
		"passiveobject/actionobject/breakableobject/aganzo_chair.obj": 11,
		"passiveobject/actionobject/breakableobject/aganzo_namutong.obj": 7,
		"passiveobject/actionobject/breakableobject/aganzo_siktak.obj": 2,
		"passiveobject/actionobject/obstacle/pubtable.obj": 3,
	}, "training_striker preserves its exact Aganzo furniture counts")
	for path: String in [
		"passiveobject/actionobject/breakableobject/aganzo_chair.obj",
		"passiveobject/actionobject/breakableobject/aganzo_namutong.obj",
		"passiveobject/actionobject/breakableobject/aganzo_siktak.obj",
	]:
		check(Dictionary(game.content.record(path).get("native_breakable", {})).is_empty(),
			"training_striker furniture remains an explicit missing source: " + path)
	check(not NativeBoxLoot.required(dungeon),
		"training_striker has no special passive-object item payload")

	var banks := {
		"monster/goblin/goblin.mob": ["goblin", 2, [0]],
		"monster/goblin/cowardgoblin.mob": ["goblin_cowardgoblin", 0, []],
		"monster/goblin/goblinthrower.mob": ["goblin_thrower", 0, []],
		"monster/goblin/goblintaskmaster.mob": ["goblin_taskmaster", 0, []],
		"monster/goblin/goblinthrowertaskmaster.mob":
			["goblin_thrower_taskmaster", 0, []],
		"monster/goblin/kinol.mob": ["goblin_kinol", 3, [0]],
	}
	var total_moves := 0
	for mob: String in banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		check(String(definition.get("bank", "")) == banks[mob][0]
			and game.combat_assets.get("monsters", {}).has(banks[mob][0]),
			"training_striker source bank is compiled: " + mob)
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
		if int(banks[mob][1]) == 0:
			check(not Array(definition.get("attack_timeline", [])).is_empty()
				and not Dictionary(definition.get("atk", {})).is_empty(),
				"single source attack uses the legacy timeline: " + mob)
	check(total_moves == 5,
		"training_striker compiles five indexed slots; four MOBs use legacy fields")
	for mob in [
		"monster/goblin/goblinthrower.mob",
		"monster/goblin/goblinthrowertaskmaster.mob",
	]:
		var definition: Dictionary = game.table.monsters.get(
			game.table.monster_by_mob(mob), {})
		check(not Dictionary(definition.get("throw", {})).is_empty()
			and not Dictionary(definition.get("atk", {})).is_empty(),
			"source thrower motion retains the registered projectile adaptation: " + mob)
	check(NativeJarTraps.ready(game.combat_assets),
		"shared verified jar trap assets resolve")

	var bgm: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/bgm.json"))
	check(bgm.get("dungeons", {}).get("training_striker", {}).get("normal") == "aganzo"
		and bgm.get("dungeons", {}).get("training_striker", {}).get("boss") == "aganzo"
		and not bgm.get("source_gaps", {}).has("training_striker"),
		"training_striker maps M_AGANZO to both room roles")

	var sample := NativeMaze.new()
	check(sample.start(probe.data, SourceRolls.new([0, 0, 0, 0, 0, 0]),
		route.get("source", {})),
		"generic native maze starts training_striker")
	check(sample.room_count() == 3
		and int(sample.current_room().get("source_map_id", 0)) == 15111,
		"training_striker starts in MAP15111 with three rooms")
	var selected_ids: Array[int] = [15111]
	for expected in [15112, 15113]:
		var cleared: Dictionary = sample.clear_room(sample.current_room()["cell"], 0)
		var moved: Dictionary = sample.move("left")
		check(not cleared.is_empty() and not moved.is_empty(),
			"training_striker clears and traverses toward MAP%d" % expected)
		selected_ids.append(int(moved.get("source_map_id", 0)))
	check(selected_ids == MAP_ORDER,
		"training_striker selects MAP15111, MAP15112 and boss MAP15113")
	check(bool(sample.clear_room(Vector2i(0, 0), 0).get("final_room", false)),
		"training_striker boss room is final")

	var flow := FlowSession.new()
	flow.profile["level"] = 60
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "training_striker"})["ok"],
		"flow departs the hidden level 20 training_striker route")
	route = flow.active_dungeon_route()
	NativePotMonsters.reset_catalog()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})),
		"live training_striker run selects its source route")
	NativePotMonsters.prepare_catalog(dungeon, SourceRolls.new([0, 0, 0, 0]))
	check(session._validate_native_maze(probe, live_maze),
		"training_striker room, MOB, object and image dependencies validate ("
		+ session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "training_striker", "route": route,
		"room_id": "training_striker:0", "room_index": 0,
		"player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts level 20 training_striker (error=%s)"
		% session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 3
			and game.view_snapshot()["hud"]["route"].size() == 3,
			"both public battle views report the three-room graph")
		check(game.view.audio.has_dungeon_music("training_striker")
			and String(game.view.audio.music.stream.resource_path).ends_with("aganzo.ogg"),
			"training_striker starts with M_AGANZO")
		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		check(int(source_counts.get("monster/goblin/goblin.mob", 0)) == 10,
			"training_striker start room spawns all ten source goblins")
		var total_props := 0
		var all_gap_paths := {}
		for map_id: int in rooms:
			var room_props: Array = game.build_props(rooms[map_id])
			total_props += room_props.size()
			check(room_props.is_empty(),
				"training_striker furniture is not materialised as guessed props in MAP%d"
				% map_id)
			for path: String in game.native_object_gaps:
				all_gap_paths[path] = true
		check(total_props == 0,
			"training_striker keeps unsupported furniture out of runtime props")
		check(all_gap_paths.has(
			"passiveobject/actionobject/breakableobject/aganzo_chair.obj")
			and all_gap_paths.has(
				"passiveobject/actionobject/breakableobject/aganzo_namutong.obj")
			and all_gap_paths.has(
				"passiveobject/actionobject/breakableobject/aganzo_siktak.obj"),
			"all three training_striker furniture families remain explicit gaps")
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_TRAINING_STRIKER] COMPLETE checks=%d failures=%d"
		% [checks, failures])
	quit(0 if failures == 0 else 1)
