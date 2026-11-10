extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const FlowSession = preload("res://flow/session.gd")
const NativeMaze = preload("res://combat/data/native_maze.gd")
const NativeBreakable = preload("res://combat/resolve/native_breakable.gd")
const NativeBoxLoot = preload("res://loot/native_box.gd")
const NativeJarTraps = preload("res://combat/resolve/native_jar_traps.gd")
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
		push_error("[NATIVE_MAZE_THEBOYWITHCOLDHEART] FAIL " + label)

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
	var route: Dictionary = routes["theboywithcoldheart"]
	check(route.get("name") == "冰心少年"
		and route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("region") == "snowmt"
		and int(route.get("min_level", 0)) == 43 and int(route.get("monster_level", 0)) == 46,
		"cold-heart boy is a hidden level 43 Snow Mountain native-maze route with source basis level 46")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production cold-heart boy export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/act5/theboywithcoldheart.dgn"
		and dungeon.get("sha256") == "dcf7202c45f573b15c34dcd576872ffca34370ed7ec049464543229b4b562a03",
		"cold-heart boy export keeps the pinned DGN source identity")
	check(Array(dungeon.get("placements", [])).size() == 3
		and Dictionary(dungeon.get("rooms", {})).size() == 3
		and Dictionary(probe.data.get("images", {})).size() == 46,
		"cold-heart boy export contains three placements, three MAPs and 46 source images")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	var errors: Array = diagnostics.filter(func(row): return row.get("level") == "error")
	var warnings: Array = diagnostics.filter(func(row): return row.get("level") == "warning")
	var infos: Array = diagnostics.filter(func(row): return row.get("level") == "info")
	check(errors.is_empty() and warnings.is_empty() and infos.size() == 22,
		"cold-heart boy export has no errors or warnings and normalizes 22 empty tile passes")

	var maze := NativeMaze.new()
	var size: Vector2i = maze._point(dungeon.get("size"))
	var cells: Dictionary = maze._read_cells(dungeon.get("cells"), size)
	var starts: Array = maze._read_endpoint_cells(dungeon.get("start_map_raw"), cells, "start_candidate")
	var bosses: Array = maze._read_endpoint_cells(dungeon.get("boss_map_raw"), cells, "boss_candidate")
	var specs: Dictionary = maze._read_specifications(dungeon.get("raw"), cells)
	var spec_count := 0
	for rows: Dictionary in [specs.get("normal", {}), specs.get("boss", {})]:
		spec_count += rows.size()
	var maze_blocks := 0
	var quest_connections := 0
	var hell_value = null
	var seal_id = null
	var event_monster = null
	for span: Dictionary in dungeon.get("raw", []):
		if span.get("tag") == "[maze info]":maze_blocks += 1
		if span.get("tag") == "[quest connection]":quest_connections += 1
		if span.get("tag") == "[hell dungeon]":hell_value = span.get("values", [])
		if span.get("tag") == "[seal door map index]":seal_id = span.get("values", [])
		if span.get("tag") == "[event monster]":event_monster = span.get("values", [])
	check(cells.size() == 2 and starts == [Vector2i(1, 0)] and bosses == [Vector2i(0, 0)],
		"cold-heart boy 2x1 grid exposes its one start and one boss cell")
	check(maze_blocks == 1 and quest_connections == 0 and spec_count == 0,
		"cold-heart boy consumes one ordinary layout with no fixed MAP specification")
	check(hell_value == null and seal_id == null and event_monster != null
		and int(event_monster[2][2]) == 61728,
		"hell and seal door are absent while event monster 61728 remains preserved raw")

	check(maze._read_pools(dungeon, cells, starts[0], bosses[0]).size() == 2,
		"cold-heart boy start reaches both source cells")
	check(maze.start(probe.data, SourceRolls.new([0, 0]), route.get("source", {})),
		"generic native maze accepts the cold-heart boy layout")
	check(maze.room_count() == 2 and maze.required_map_paths().size() == 3,
		"cold-heart boy preflight exposes two rooms across all three first-visit MAP variants")
	check(not NativeBoxLoot.required(dungeon), "cold-heart boy does not invent box item payloads")
	check(NativeJarTraps.ready(game.combat_assets), "shared source trap assets resolve")

	var boss_rooms: Array = []
	for path: String in dungeon.get("rooms", {}):
		if path.contains("/b580"):
			boss_rooms.append(dungeon["rooms"][path])
	check(boss_rooms.size() == 2
		and boss_rooms[0].get("sha256") == boss_rooms[1].get("sha256")
		and int(boss_rooms[0]["greed_pairs"][0][0]) == 1 and int(boss_rooms[0]["greed_pairs"][0][1]) == 1
		and int(boss_rooms[1]["greed_pairs"][0][0]) == 1 and int(boss_rooms[1]["greed_pairs"][0][1]) == 1,
		"cold-heart boy preserves two byte-identical boss MAP candidates instead of inventing a variant "
		+ "(count=%d hashes=%s/%s pairs=%s/%s)"
		% [boss_rooms.size(), boss_rooms[0].get("sha256", ""), boss_rooms[1].get("sha256", ""),
			boss_rooms[0].get("greed_pairs", []), boss_rooms[1].get("greed_pairs", [])])

	var source_monsters := {}
	var source_monster_counts := {}
	var source_monster_count := 0
	var source_boss_rows := 0
	var source_object_count := 0
	var source_breakables := 0
	var source_specials := 0
	var source_triggers := 0
	var source_static := 0
	var source_box_objects := 0
	for room: Dictionary in dungeon.get("rooms", {}).values():
		for monster: Dictionary in room.get("monsters", []):
			var mob := String(monster.get("mob", ""))
			source_monsters[mob] = true
			source_monster_counts[mob] = 1 + int(source_monster_counts.get(mob, 0))
			source_monster_count += 1
			var raw: Array = monster.get("raw", [])
			if not raw.is_empty() and raw[-1] == "[boss]":
				source_boss_rows += 1
				check(mob == "monster/coldboy/coldboy.mob",
					"every source boss row is Cold Boy")
		for item: Dictionary in room.get("objects", []):
			source_object_count += 1
			if NativeBoxLoot.draw_count(item) > 0:
				source_box_objects += 1
			var path := String(item.get("obj", "")).to_lower()
			if NativeBreakable.supports(item) and not game.content.record(path).get("native_breakable", {}).is_empty():
				source_breakables += 1
			elif item.get("source_tag") == "[special passive object]":
				source_specials += 1
			elif path.contains("/trap/"):
				source_triggers += 1
			else:
				source_static += 1
	check(source_monsters.size() == 7 and source_monster_count == 16 and source_boss_rows == 2,
		"cold-heart boy source has 16 direct placements, seven MOBs and two boss rows")
	check(source_monster_counts == {
		"monster/spirit/waterspirit.mob": 4,
		"monster/toy/hiddena.mob": 2,
		"monster/toy/hiddenb.mob": 2,
		"monster/coldheart/coldheart.mob": 2,
		"monster/coldboy/coldboy.mob": 2,
		"monster/toy/hiddend.mob": 2,
		"monster/toy/hiddenc.mob": 2,
	}, "cold-heart boy keeps the exact source monster counts across both boss variants")
	check(source_object_count == 30 and source_breakables == 27
		and source_triggers == 3 and source_specials == 0
		and source_static == 0 and source_box_objects == 0,
		"cold-heart boy source has 30 objects: 27 crystals, three freezing-Luna trigger gaps "
		+ "and no item payloads "
		+ "(objects=%d breakables=%d triggers=%d special=%d static=%d boxes=%d)"
		% [source_object_count, source_breakables, source_triggers, source_specials,
			source_static, source_box_objects])
	for mob: String in source_monsters:
		check(not game.table.monster_by_mob(mob).is_empty(),
			"direct source MOB has runtime content: " + mob)

	var banks := {
		"monster/coldboy/coldboy.mob": ["coldboy_coldboy", 6, true],
		"monster/coldheart/coldheart.mob": ["coldheart_coldheart", 0, false],
		"monster/toy/hiddena.mob": ["toy_hiddena", 2, false],
		"monster/toy/hiddenb.mob": ["toy_hiddenb", 3, false],
		"monster/toy/hiddenc.mob": ["toy_hiddenc", 3, true],
		"monster/toy/hiddend.mob": ["toy_hiddend", 2, false],
		"monster/spirit/waterspirit.mob": ["spirit_waterspirit", 3, false],
	}
	for mob: String in banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		check(String(definition.get("bank", "")) == banks[mob][0]
			and game.combat_assets.get("monsters", {}).has(banks[mob][0]),
			"cold-heart boy source bank is compiled: " + mob)
		check(Array(definition.get("moves", [])).size() == int(banks[mob][1]),
			"source attack slots compile for %s (moves=%d expected=%d)"
			% [mob, Array(definition.get("moves", [])).size(), int(banks[mob][1])])
		if bool(banks[mob][2]):
			var projectile: Dictionary = definition.get("throw", {})
			check(not projectile.is_empty() and not Dictionary(projectile.get("object", {})).is_empty()
				and not Array(projectile.get("particles", [])).is_empty(),
				"source projectile object and PTL compile for " + mob)
		if int(banks[mob][1]) == 0:
			check(Array(definition.get("attack_timeline", [])).is_empty()
				and Dictionary(definition.get("atk", {})).is_empty(),
				"cold heart keeps its source fact of no attack animation or ATK")

	var flow := FlowSession.new()
	flow.profile["level"] = 46
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "theboywithcoldheart"})["ok"],
		"flow departs the hidden cold-heart boy route")
	route = flow.active_dungeon_route()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live cold-heart boy run selects the ordinary layout")
	check(session._validate_native_maze(probe, live_maze),
		"cold-heart boy room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "theboywithcoldheart", "route": route,
		"room_id": "theboywithcoldheart:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source cold-heart boy room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 2
			and game.view_snapshot()["hud"]["route"].size() == 2,
			"both public battle views report the complete cold-heart boy graph")
		check(game.view.audio.has_dungeon_music("theboywithcoldheart")
			and String(game.view.audio.music.stream.resource_path).ends_with("cold_boy.ogg"),
			"cold-heart boy starts with the original M_COLD_BOY track")

		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts and live_counts == {"monster/spirit/waterspirit.mob": 4},
			"cold-heart boy start room spawns its exact four-Water Spirit lineup")

		var interactive_props := 0
		var box_props := 0
		var known_jar_ids := {}
		var unknown_ids: Array[int] = []
		var all_gaps := {}
		for path: String in dungeon.get("rooms", {}).keys():
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
					if int(source_id) not in unknown_ids:
						unknown_ids.append(int(source_id))
			merge_gaps(all_gaps, game.native_object_gaps)
		unknown_ids.sort()
		check(interactive_props == 27,
			"all 27 source crystals build exactly once across the three MAP variants")
		check(box_props == 0, "cold-heart boy creates no item-box props")
		check(known_jar_ids.is_empty() and unknown_ids.is_empty(),
			"no jar branch or unresolved executable trap is invented for cold-heart boy")
		check(all_gaps == {
			"passiveobject/mapobject/trap/shallowkeepfreezingluna.obj": ["native_object_trigger"],
		}, "freezing Luna remains the only explicit trigger-object gap: " + str(all_gaps))
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_THEBOYWITHCOLDHEART] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
