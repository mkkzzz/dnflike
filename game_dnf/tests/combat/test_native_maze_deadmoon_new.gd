extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const FlowSession = preload("res://flow/session.gd")
const NativeMaze = preload("res://combat/data/native_maze.gd")
const NativeBreakable = preload("res://combat/resolve/native_breakable.gd")
const NativeBoxLoot = preload("res://loot/native_box.gd")
const NativeJarTraps = preload("res://combat/resolve/native_jar_traps.gd")
const NativePotMonsters = preload("res://combat/resolve/native_pot_monsters.gd")
const DetRng = preload("res://core/det_rng.gd")

const SOURCE_SHA := "7bcb3e4d0b6964e05ffd80cc4e1f4eb5dcd2784be30c679d5093d162c722d7fd"
const MAP_ORDER: Array[int] = [13301, 13302, 13303, 13304, 13305, 13306, 13307, 13308, 13300]
const ROUTE_SIDES := ["up", "right", "right", "down", "right", "up", "right", "right"]

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
		push_error("[NATIVE_MAZE_DEADMOON_NEW] FAIL " + label)

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
	var route: Dictionary = routes["deadmoon_new"]
	check(route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("name") == "亡月雷鸣废墟" and route.get("region") == "deadmoon"
		and int(route.get("min_level", 0)) == 15
		and int(route.get("monster_level", 0)) == 18,
		"Dead Moon is an isolated hidden level 15/18 native route")
	check(Array(route.get("rooms", [])).size() == 9
		and route["rooms"][0]["placement"] == "0_1:start1"
		and route["rooms"][-1]["placement"] == "5_0:boss1"
		and bool(route["rooms"][-1].get("boss", false)),
		"route metadata exposes one representative nine-room source path")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])),
		"production Dead Moon export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/quest/deadmoon_new.dgn"
		and dungeon.get("sha256") == SOURCE_SHA
		and int(dungeon.get("index", -1)) == 521,
		"Dead Moon keeps DGN index 521 and the pinned source identity")
	check(Array(dungeon.get("placements", [])).size() == 13
		and Dictionary(dungeon.get("rooms", {})).size() == 9
		and Dictionary(probe.data.get("images", {})).size() == 151,
		"Dead Moon retains nine rooms, thirteen placements and 151 source images")
	check(String(dungeon.get("cell_map_rule", "")).contains("E-PARSE")
		and int(dungeon.get("maze_block_index", -1)) == 0
		and dungeon.get("maze_block_selection") == "ordinary"
		and Array(dungeon.get("maze_blocks", [])).size() == 1,
		"Dead Moon selects its ordinary block with paired MAP masks")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	check(diagnostics.filter(func(row): return row.get("level") == "error").is_empty(),
		"Dead Moon has no source image or ANI errors")
	check(diagnostics.filter(func(row): return row.get("code") == "cell_without_map").size() == 3,
		"Dead Moon preserves three empty AA cells as map warnings")
	check(diagnostics.filter(func(row): return row.get("code") == "unhandled_tags").size() == 9,
		"Dead Moon preserves one raw-tag report for each MAP")

	var maze := NativeMaze.new()
	var size: Vector2i = maze._point(dungeon.get("size"))
	var cells: Dictionary = maze._read_cells(dungeon.get("cells"), size)
	var starts: Array = maze._read_endpoint_cells(dungeon.get("start_map_raw"), cells, "start_candidate")
	var bosses: Array = maze._read_endpoint_cells(dungeon.get("boss_map_raw"), cells, "boss_candidate")
	var specs: Dictionary = maze._read_specifications(dungeon.get("raw"), cells, 0)
	check(size == Vector2i(6, 2) and cells.size() == 12
		and starts == [Vector2i(0, 1)] and bosses == [Vector2i(5, 0)],
		"Dead Moon exposes one start and one boss endpoint")
	check(specs.get("normal", {}).get(Vector2i(0, 0)) == [13302]
		and specs.get("normal", {}).get(Vector2i(1, 0)) == [13303]
		and specs.get("normal", {}).get(Vector2i(3, 0)) == [13307]
		and specs.get("normal", {}).get(Vector2i(4, 0)) == [13308]
		and specs.get("boss", {}).get(Vector2i(5, 0)) == [13300],
		"source MAP specifications disambiguate both shared JJ and FF layouts")
	check(raw_values(dungeon.get("raw", []), "[minimum required level]") == [15]
		and raw_values(dungeon.get("raw", []), "[basis level]") == [18]
		and raw_values(dungeon.get("raw", []), "[limit party count]") == [1]
		and raw_values(dungeon.get("raw", []), "[designate dungeon difficulty]") == [0],
		"source level, single-player and fixed-difficulty fields remain intact")
	check(raw_values(dungeon.get("raw", []), "[pathgate object]")
		== [381, 382, 383, 384, 385, 386, 387, 388, 389, 390],
		"source pathgate object list remains intact")

	var rooms := rooms_by_id(dungeon)
	var expected_counts := {
		13300: [11, 27], 13301: [4, 0], 13302: [10, 44], 13303: [7, 59],
		13304: [7, 29], 13305: [3, 19], 13306: [5, 4], 13307: [10, 13],
		13308: [9, 27],
	}
	var all_monsters := {}
	var all_objects := []
	var monster_count := 0
	var boss_rows := 0
	var breakable_shaped := 0
	for map_id: int in expected_counts:
		var room: Dictionary = rooms[map_id]
		check(room["monsters"].size() == int(expected_counts[map_id][0])
			and room["objects"].size() == int(expected_counts[map_id][1]),
			"source room counts match MAP%d" % map_id)
		for monster: Dictionary in room["monsters"]:
			all_monsters[String(monster["mob"])] = true
			monster_count += 1
			if Array(monster.get("raw", [])).has("[boss]"):
				boss_rows += 1
		for item: Dictionary in room["objects"]:
			all_objects.append(item)
			if NativeBreakable.supports(item):
				breakable_shaped += 1
	check(all_monsters.size() == 13 and monster_count == 66 and boss_rows == 1,
		"Dead Moon retains 66 monsters across thirteen MOBs and one boss row")
	check(all_objects.size() == 222 and breakable_shaped == 135,
		"Dead Moon retains all 222 objects and 135 breakable-shaped rows")
	check(room_role(rooms[13301]) == "[normal]" and room_role(rooms[13300]) == "[boss]"
		and String(rooms[13300]["monsters"].filter(
			func(row): return Array(row["raw"]).has("[boss]"))[0]["mob"])
			== "monster/zombie/zombieghoulgwish.mob",
		"the zombie ghoul boss remains the final source row")
	check(Array(rooms[13306]["monsters"]).filter(
		func(row): return Array(row["raw"]).size() == 11).size() == 1,
		"MAP13306 preserves its one eleven-field source monster row")
	check(Array(rooms[13300]["raw"]).filter(
		func(span): return span.get("tag") == "[NPC]").size() == 1,
		"boss MAP retains its independent NPC1000 row")

	var map_pairs := {}
	for map_id: int in rooms:
		var normalized: Array = []
		for pair in rooms[map_id].get("greed_pairs", []):
			normalized.append([int(pair[0]), int(pair[1])])
		map_pairs[map_id] = normalized
	check(map_pairs == {
		13300: [[4, 4]], 13301: [[2, 2]], 13302: [[9, 9]],
		13303: [[5, 5]], 13304: [[12, 12]], 13305: [[3, 3]],
		13306: [[6, 6]], 13307: [[9, 9]], 13308: [[5, 5]],
	}, "every MAP preserves its layout and ingress mask pair")

	var object_paths := {}
	for item: Dictionary in all_objects:
		var path := String(item.get("obj", ""))
		object_paths[path] = 1 + int(object_paths.get(path, 0))
	check(object_paths.size() == 27
		and int(object_paths.get(
			"passiveobject/mapobject/breakableobject/barrel.obj", 0)) == 61
		and int(object_paths.get(
			"passiveobject/mapobject/breakableobject/treasurebox.obj", 0)) == 4
		and int(object_paths.get(
			"passiveobject/mapobject/breakableobject/actionstonepillar.obj", 0)) == 5,
		"source object identities and key counts remain pinned")
	check(not Dictionary(game.content.record(
		"passiveobject/mapobject/breakableobject/barrel.obj"
	).get("native_breakable", {})).is_empty(),
		"barrel has a source-backed native breakable definition")
	for path: String in [
		"passiveobject/mapobject/breakableobject/actionstonepillar.obj",
		"passiveobject/mapobject/breakableobject/actiontree1sunderland.obj",
		"passiveobject/mapobject/breakableobject/actiontree2sunderland.obj",
		"passiveobject/mapobject/breakableobject/largegrasssunderland.obj",
		"passiveobject/mapobject/breakableobject/smallgrasssunderland.obj",
		"passiveobject/mapobject/breakableobject/treasurebox.obj",
	]:
		check(Dictionary(game.content.record(path).get("native_breakable", {})).is_empty(),
			"unsupported breakable remains explicit without guessed data: " + path)

	check(NativeBoxLoot.required(dungeon),
		"Dead Moon special objects require the source item groups")
	check(NativeBoxLoot.ready(dungeon),
		"Dead Moon group 0 and immutable v12 item art resolve")
	check(NativeBoxLoot.pick(0, "0") == "original_1000"
		and NativeBoxLoot.pick(768, "0") == "original_1000"
		and NativeBoxLoot.pick(769, "0") == "original_1004"
		and NativeBoxLoot.pick(2268, "0") == "original_1004"
		and NativeBoxLoot.pick(2269, "0") == "",
		"group 0 preserves the 769/1500 cumulative source weights")
	var prepared := NativeBoxLoot.prepare(4, 20261111, "0")
	check(prepared.size() <= 4
		and prepared.all(func(id): return id in ["original_1000", "original_1004"]),
		"four deterministic group-0 draws preserve empty outcomes and original identities")

	var banks := {
		"monster/goblin/goblinthrower.mob": ["goblin_thrower", 0, []],
		"monster/goblin/kinol.mob": ["goblin_kinol", 3, [0]],
		"monster/lugaru/kurogaru.mob": ["kurogaru", 4, [0, 1, 2, 3]],
		"monster/lugaru/penril.mob": ["lugaru_penril", 5, [0, 1, 2, 3, 4]],
		"monster/soceress/keraha.mob": ["soceress_keraha", 3, [0]],
		"monster/soceress/vinoshu.mob": ["soceress_vinoshu", 0, []],
		"monster/tau/shauta.mob": ["tau_shauta", 4, [0, 1]],
		"monster/tau/tauarmy.mob": ["tau_army", 2, [0, 1]],
		"monster/tau/taubeast.mob": ["tau_beast", 3, [0, 1, 2]],
		"monster/zombie/kalkazak.mob": ["zombie_kalkazak", 2, [0, 1]],
		"monster/zombie/zombieghoulgwish.mob":
			["zombie_zombieghoulgwish", 2, [0, 1]],
		"monster/zombie/zombieholloweye.mob": ["zombie_zombieholloweye", 3, [0, 1, 2]],
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
	var goblin_thrower: Dictionary = game.table.monsters[
		game.table.monster_by_mob("monster/goblin/goblinthrower.mob")]
	var vinoshu: Dictionary = game.table.monsters[
		game.table.monster_by_mob("monster/soceress/vinoshu.mob")]
	check(not Array(goblin_thrower.get("attack_timeline", [])).is_empty()
		and not Dictionary(goblin_thrower.get("throw", {})).is_empty(),
		"goblin thrower keeps its projectile clock and legacy attack timeline "
		+ "(timeline=%d atk=%s throw=%s)" % [
			Array(goblin_thrower.get("attack_timeline", [])).size(),
			str(goblin_thrower.get("atk", {})),
			str(goblin_thrower.get("throw", {})),
		])
	check(not Array(vinoshu.get("attack_timeline", [])).is_empty()
		and not Dictionary(vinoshu.get("atk", {})).is_empty(),
		"single direct-attack Vinoshu uses the legacy timeline instead of a moves array")
	check(total_moves == 33,
		"Dead Moon compiles 33 indexed source action slots; actual=%d" % total_moves)

	var bgm: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/bgm.json"))
	check(bgm.get("dungeons", {}).get("deadmoon_new", {}).get("normal") == "sunderland"
		and bgm.get("dungeons", {}).get("deadmoon_new", {}).get("boss") == "sunderland_boss"
		and not bgm.get("source_gaps", {}).has("deadmoon_new"),
		"Dead Moon maps both source M_SUNDERLAND cues")

	var sample := NativeMaze.new()
	check(sample.start(probe.data, SourceRolls.new([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
		route.get("source", {})),
		"generic native maze starts Dead Moon")
	check(sample.room_count() == 9 and int(sample.current_room().get("source_map_id", 0)) == 13301,
		"Dead Moon exposes nine rooms and starts in MAP13301")
	var selected_ids: Array[int] = [int(sample.current_room().get("source_map_id", 0))]
	for side: String in ROUTE_SIDES:
		var cell: Vector2i = sample.current_room().get("cell", Vector2i(-1, -1))
		var cleared: Dictionary = sample.clear_room(cell, 0)
		var moved: Dictionary = sample.move(side)
		check(not cleared.is_empty() and not moved.is_empty(),
			"Dead Moon clears and traverses source step " + side)
		selected_ids.append(int(moved.get("source_map_id", 0)))
	check(selected_ids == MAP_ORDER,
		"Dead Moon selects MAP13301..13308 and boss MAP13300 in source order")
	var final_clear: Dictionary = sample.clear_room(Vector2i(5, 0), 0)
	check(bool(final_clear.get("boss", false)) and bool(final_clear.get("final_room", false)),
		"the source boss room is the nine-room route's final room")

	var flow := FlowSession.new()
	flow.profile["level"] = 60
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "deadmoon_new"})["ok"],
		"flow departs the hidden Dead Moon route")
	route = flow.active_dungeon_route()
	NativePotMonsters.reset_catalog()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})),
		"live Dead Moon run selects its source route")
	NativePotMonsters.prepare_catalog(dungeon, SourceRolls.new([0, 0, 0, 0]))
	check(session._validate_native_maze(probe, live_maze),
		"Dead Moon room, MOB, object, image and box dependencies validate ("
		+ session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "deadmoon_new", "route": route,
		"room_id": "deadmoon_new:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts Dead Moon (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 9
			and game.view_snapshot()["hud"]["route"].size() == 9,
			"both public battle views report the nine-room graph")
		check(game.view.audio.has_dungeon_music("deadmoon_new")
			and String(game.view.audio.music.stream.resource_path).ends_with("sunderland.ogg"),
			"Dead Moon starts with its source normal track")
		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		check(int(source_counts.get("monster/goblin/goblinthrower.mob", 0)) == 4,
			"start room spawns four source goblin throwers")
		var start_props: Array = game.build_props(rooms[13301])
		check(start_props.is_empty(),
			"start room has no source objects or guessed props")

	var total_props := 0
	var h3_barrel: Dictionary = {}
	var h3_gaps := {}
	for map_id: int in rooms:
		var props: Array = game.build_props(rooms[map_id])
		total_props += props.size()
		check(props.all(func(prop): return String(prop["source_path"]).ends_with("/barrel.obj")),
			"only source-backed barrels materialise as native breakables in MAP%d" % map_id)
		if map_id == 13304:
			h3_gaps = game.native_object_gaps.duplicate(true)
			for item: Dictionary in rooms[map_id]["objects"]:
				if item["obj"].ends_with("/barrel.obj") \
					and int(item["anchor"][0]) == 631 and int(item["anchor"][1]) == 221 \
					and int(item["anchor"][2]) == 0:
					h3_barrel = item
	check(total_props == 61,
		"all 61 source barrels materialise across the nine rooms")
	check("native_breakable_source" in h3_gaps.get(
		"passiveobject/mapobject/breakableobject/actiontree1sunderland.obj", [])
		and "native_breakable_source" in h3_gaps.get(
			"passiveobject/mapobject/breakableobject/actiontree2sunderland.obj", []),
		"the two group-0 loot trees remain explicit unreachable breakable gaps")
	check(NativeJarTraps.unresolved_ids(h3_barrel).has(48022)
		and NativeJarTraps.unresolved_ids(h3_barrel).has(2101),
		"mixed barrel preserves unknown trap IDs 48022 and 2101")
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_DEADMOON_NEW] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
