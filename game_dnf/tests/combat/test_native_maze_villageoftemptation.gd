extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const FlowSession = preload("res://flow/session.gd")
const NativeMaze = preload("res://combat/data/native_maze.gd")
const NativeBreakable = preload("res://combat/resolve/native_breakable.gd")
const NativeBoxLoot = preload("res://loot/native_box.gd")
const NativeJarTraps = preload("res://combat/resolve/native_jar_traps.gd")
const NativePotMonsters = preload("res://combat/resolve/native_pot_monsters.gd")
const DetRng = preload("res://core/det_rng.gd")
const SAMPLE_MAPS: Array[int] = [6401, 6402, 6403, 6405, 6407, 6408, 6410, 6423]
const SAMPLE_STEPS: Array[String] = ["up", "left", "up", "up", "right", "up", "left"]
const DUMMY_MAPS: Array[int] = [6418, 6420, 6424]

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
		push_error("[NATIVE_MAZE_VILLAGE_OF_TEMPTATION] FAIL " + label)

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

func run() -> void:
	game = session.mount(root)
	game.set_process(false)
	game.set_physics_process(false)
	var routes: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/dungeons.json"))["dungeons"]
	var route: Dictionary = routes["villageoftemptation"]
	check(route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("name") == "迷乱之村哈穆林" and route.get("region") == "northmyre"
		and int(route.get("min_level", 0)) == 50
		and int(route.get("monster_level", 0)) == 53,
		"Village of Temptation is a hidden North Myre route at source levels 50/53")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])),
		"production Village of Temptation export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/act6/villageoftemptation.dgn"
		and dungeon.get("sha256") == "8a5c04698a9c51fa62c86e87a4cc33f1af1dd69643d64081adba4dafb03f2aa2"
		and int(dungeon.get("index", -1)) == 51,
		"Village of Temptation keeps DGN index 51 and the pinned source identity")
	check(Array(dungeon.get("placements", [])).size() == 46
		and Dictionary(dungeon.get("rooms", {})).size() == 22
		and Dictionary(probe.data.get("images", {})).size() == 75,
		"Village of Temptation export retains 46 placements, 22 source MAPs and 75 images")
	check(int(dungeon.get("maze_block_index", -1)) == 0
		and dungeon.get("maze_block_selection") == "hell_base"
		and Array(dungeon.get("maze_blocks", [])).size() == 1,
		"Village of Temptation selects its sole hell-base block")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	var errors: Array = diagnostics.filter(func(row): return row.get("level") == "error")
	var warnings: Array = diagnostics.filter(func(row): return row.get("level") == "warning")
	var infos: Array = diagnostics.filter(func(row): return row.get("level") == "info")
	check(errors.is_empty(), "Village of Temptation export has no source image or ANI errors")
	check(warnings.size() == 9
		and warnings.filter(func(row): return row.get("code") == "cell_without_map").size() == 9,
		"Village of Temptation preserves nine empty AA cells")
	check(infos.size() == 22
		and infos.filter(func(row): return row.get("code") == "unhandled_tags").size() == 22
		and infos.filter(func(row): return row.get("code") == "maze_block_selected").is_empty(),
		"Village of Temptation preserves 22 MAP tag reports without a redundant block report")

	var maze := NativeMaze.new()
	var size: Vector2i = maze._point(dungeon.get("size"))
	var cells: Dictionary = maze._read_cells(dungeon.get("cells"), size)
	var starts: Array = maze._read_endpoint_cells(dungeon.get("start_map_raw"), cells, "start_candidate")
	var bosses: Array = maze._read_endpoint_cells(dungeon.get("boss_map_raw"), cells, "boss_candidate")
	var specs: Dictionary = maze._read_specifications(dungeon.get("raw"), cells, 0)
	check(cells.size() == 25 and starts == [Vector2i(2, 4)]
		and bosses == [Vector2i(0, 0), Vector2i(0, 1), Vector2i(1, 0)],
		"Village of Temptation exposes one start and three source boss candidates")
	check(cells.values().filter(func(cell): return not cell.get("doors", []).is_empty()).size() == 16,
		"Village of Temptation has sixteen connected source cells")
	check(specs.get("normal", {}).size() == 3 and specs.get("boss", {}).is_empty()
		and specs["normal"][Vector2i(2, 0)] == [6410]
		and specs["normal"][Vector2i(2, 3)] == [6402]
		and specs["normal"][Vector2i(4, 1)] == [6415],
		"Village of Temptation preserves three fixed normal MAP specifications")
	var block: Dictionary = Array(dungeon.get("maze_blocks", []))[0]
	check(Array(block.get("hell_dungeon", [])).map(func(value): return int(value)) == [1]
		and Array(block.get("seal_door_map_index", [])).map(func(value): return int(value)) == [60019]
		and Array(block.get("seal_door_pos", [])).map(func(value): return int(value)) == [3, 0]
		and Array(block.get("seal_door_appear_rate", [])).map(func(value): return int(value)) == [1],
		"Village of Temptation preserves hell mode and seal door 60019")
	check(raw_values(dungeon.get("raw", []), "[special passive object item]")
		== [0, -1, 3, 1089, 1000, 1090, 1000, 3217, 3000],
		"Village of Temptation preserves its three-item source drop group")
	check(raw_values(dungeon.get("raw", []), "[champion]") == [6, 12, 18, 24, 26]
		and raw_values(dungeon.get("raw", []), "[hit count]") == [50, 50, 50, 50, 50]
		and raw_values(dungeon.get("raw", []), "[dummy appear count]") == [2],
		"Village of Temptation preserves champion, hit-count and dummy-count raw fields")
	check(raw_values(dungeon.get("raw", []), "[event monster]")
		== [1, 10000, 61728, 1, 300, 80, 1],
		"Village of Temptation preserves event monster 61728")

	var roles := {}
	for path: String in dungeon.get("rooms", {}):
		var room: Dictionary = dungeon["rooms"][path]
		roles[int(room["map_id"])] = room_role(room)
	for map_id: int in DUMMY_MAPS:
		check(roles.get(map_id) == "[dummy]",
			"source MAP %d remains an unconsumed dummy role" % map_id)

	var boss_pool_sizes: Array[int] = []
	for boss_slot in 3:
		var probe_maze := NativeMaze.new()
		check(probe_maze.start(probe.data, SourceRolls.new([0, boss_slot, 0]),
			route.get("source", {})),
			"generic native maze starts boss candidate %d" % boss_slot)
		boss_pool_sizes.append(probe_maze.required_map_paths().size())
		check(probe_maze.room_count() == 16,
			"boss candidate %d reaches all sixteen ordinary cells" % boss_slot)
		var allowed_ids: Array[int] = []
		for path: String in probe_maze.required_map_paths():
			allowed_ids.append(int(dungeon["rooms"][path]["map_id"]))
		for dummy_id: int in DUMMY_MAPS:
			check(dummy_id not in allowed_ids,
				"boss candidate %d excludes dummy MAP %d" % [boss_slot, dummy_id])
	check(boss_pool_sizes == [17, 16, 17],
		"three boss choices expose their source-backed map unions (%s)" % [boss_pool_sizes])

	var sample_maze := NativeMaze.new()
	check(sample_maze.start(probe.data,
		SourceRolls.new([0, 2, 0, 0, 0, 0, 0, 0, 0, 0]), route.get("source", {})),
		"generic native maze starts the shortest source sample")
	check(int(sample_maze.current_room().get("source_map_id", 0)) == SAMPLE_MAPS[0],
		"sample starts in source MAP 6401")
	for step in SAMPLE_STEPS.size():
		var cell: Vector2i = sample_maze.current_room().get("cell", Vector2i(-1, -1))
		check(not sample_maze.clear_room(cell, 0).is_empty(),
			"sample clears step %d" % step)
		var moved: Dictionary = sample_maze.move(SAMPLE_STEPS[step])
		check(int(moved.get("source_map_id", 0)) == SAMPLE_MAPS[step + 1],
			"sample traverses %s to MAP %d" % [SAMPLE_STEPS[step], SAMPLE_MAPS[step + 1]])
	var final_clear: Dictionary = sample_maze.clear_room(Vector2i(1, 0), 0)
	check(bool(final_clear.get("boss", false)) and bool(final_clear.get("final_room", false)),
		"source boss candidate (1,0) is the sample's final room")

	var all_monsters := {}
	var all_monster_count := 0
	var all_boss_rows := 0
	var all_object_count := 0
	var all_passive_count := 0
	var all_special_count := 0
	var all_breakables := 0
	var all_object_paths := {}
	var special_item_rows := 0
	var special_trap_rows := 0
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
			all_object_count += 1
			all_object_paths[String(item.get("obj", "")).to_lower()] = true
			if item.get("source_tag") == "[passive object]":
				all_passive_count += 1
			elif item.get("source_tag") == "[special passive object]":
				all_special_count += 1
				if "[item]" in item.get("raw", []):
					special_item_rows += 1
				if "[trap]" in item.get("raw", []):
					special_trap_rows += 1
			if NativeBreakable.supports(item):
				all_breakables += 1
		for span: Dictionary in room.get("raw", []):
			if span.get("tag") == "[NPC]":
				npc_rows += 1
			elif span.get("tag") == "[ai character]":
				ai_character_rows += 1
			elif span.get("tag") == "[monster specific AI]":
				ai_spans += 1
	check(all_monsters.size() == 9 and all_monster_count == 172 and all_boss_rows == 6,
		"all source maps retain 172 monsters, nine MOBs and six boss rows")
	check(all_object_count == 337 and all_passive_count == 320
		and all_special_count == 17 and all_object_paths.size() == 15,
		"all source maps retain 337 objects across fifteen identities")
	check(all_breakables == 27,
		"Village of Temptation exposes twenty-seven source breakable rows")
	check(special_item_rows == 16 and special_trap_rows == 1,
		"special objects retain sixteen item payloads and one unresolved trap")
	check(npc_rows == 3 and ai_character_rows == 0 and ai_spans == 21,
		"source maps retain three NPC rows, no AI character and 21 AI spans")
	for mob: String in all_monsters:
		check(not game.table.monster_by_mob(mob).is_empty(),
			"source MOB has runtime content: " + mob)

	var banks := {
		"monster/peterthepiper/bigrat.mob": ["peterthepiper_bigrat", 2],
		"monster/peterthepiper/biterat.mob": ["peterthepiper_biterat", 3],
		"monster/peterthepiper/fake_peterthepiper.mob":
			["peterthepiper_fake_peterthepiper", 10],
		"monster/peterthepiper/peterthepiper.mob": ["peterthepiper_peterthepiper", 10],
		"monster/thief/mouseheadsue.mob": ["thief_mouseheadsue", 4],
		"monster/thief/racksha.mob": ["thief_racksha", 6],
		"monster/thief/thieffemale.mob": ["thief_thieffemale", 5],
		"monster/thief/thiefmale.mob": ["thief_thiefmale", 3],
		"monster/thief/thiefmalemad.mob": ["thief_thiefmalemad", 3],
	}
	for mob: String in banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		check(String(definition.get("bank", "")) == banks[mob][0]
			and game.combat_assets.get("monsters", {}).has(banks[mob][0]),
			"Village of Temptation source bank is compiled: " + mob)
		var moves: Array = Array(definition.get("moves", []))
		check(moves.size() == int(banks[mob][1]),
			"source action slots compile for %s (moves=%d expected=%d)"
			% [mob, moves.size(), int(banks[mob][1])])
		for index in moves.size():
			var move: Dictionary = moves[index]
			check(move.has("atk_path")
				and not game.table.atk(String(move["atk_path"])).is_empty()
				and not Array(move.get("timeline", [])).is_empty(),
				"source action and ATK compile together at %s slot %d" % [mob, index])
		check(Array(definition.get("rules", [])).is_empty(),
			"no unsupported selection rule is fabricated for " + mob)

	var object_paths := {}
	for room: Dictionary in dungeon.get("rooms", {}).values():
		for item: Dictionary in room.get("objects", []):
			object_paths[String(item.get("obj", "")).to_lower()] = true
	for path: String in object_paths:
		if not path.contains("breakableobject/"):
			continue
		check(not Dictionary(game.content.record(path).get("native_breakable", {})).is_empty(),
			"source breakable definition compiles: " + path)
	var box_rows := 0
	var unresolved_trap_ids: Array[int] = []
	for room: Dictionary in dungeon.get("rooms", {}).values():
		for item: Dictionary in room.get("objects", []):
			if item.get("source_tag") != "[special passive object]":
				continue
			if "[item]" in item.get("raw", []):
				box_rows += 1
			for source_id: int in NativeJarTraps.unresolved_ids(item):
				if source_id not in unresolved_trap_ids:
					unresolved_trap_ids.append(source_id)
	check(box_rows == 16 and unresolved_trap_ids == [2211],
		"box item payloads are counted separately from unresolved trap 2211")
	check(NativeJarTraps.ready(game.combat_assets),
		"shared verified jar trap assets still resolve")
	check(NativeBoxLoot.required(dungeon) and NativeBoxLoot.ready(dungeon),
		"Village of Temptation native box loot and item art resolve")
	check(NativeBoxLoot.pick(0) == "original_1089"
		and NativeBoxLoot.pick(1000) == "original_1090"
		and NativeBoxLoot.pick(2000) == "original_3217"
		and NativeBoxLoot.pick(5000) == "",
		"source item group preserves its 1000/1000/3000 cumulative boundaries")
	var prepared: Array = NativeBoxLoot.prepare(3, 20261111)
	check(prepared.size() <= 3 and prepared.all(func(item): return item in [
		"original_1089", "original_1090", "original_3217",
	]),
		"native box loot preparation returns only source item identities")
	var bgm: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/bgm.json"))
	check(bgm.get("dungeons", {}).get("villageoftemptation", {}).get("normal") == "hameln"
		and bgm.get("dungeons", {}).get("villageoftemptation", {}).get("boss") == "hameln_boss",
		"Village of Temptation maps its normal and boss source tracks")
	var source_gaps: Dictionary = bgm.get("source_gaps", {}).get("villageoftemptation", {})
	var gap_rows: Array = source_gaps.values()
	check(gap_rows.size() == 3
		and gap_rows.all(func(gap): return gap.get("role") == "[dummy]"),
		"three dummy MAPs remain explicit BGM source gaps")

	var flow := FlowSession.new()
	flow.profile["level"] = 60
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "villageoftemptation"})["ok"],
		"flow departs the hidden Village of Temptation route")
	route = flow.active_dungeon_route()
	NativePotMonsters.reset_catalog()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})),
		"live Village of Temptation run selects a source start and boss")
	NativePotMonsters.prepare_catalog(dungeon, SourceRolls.new([0, 0, 0, 0]))
	check(session._validate_native_maze(probe, live_maze),
		"Village of Temptation room, MOB, object and breakable dependencies validate ("
		+ session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "villageoftemptation", "route": route,
		"room_id": "villageoftemptation:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source Village of Temptation room (error=%s)"
		% session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 16
			and game.view_snapshot()["hud"]["route"].size() == 16,
			"both public battle views report the complete sixteen-room graph")
		check(game.view.audio.has_dungeon_music("villageoftemptation")
			and String(game.view.audio.music.stream.resource_path).ends_with("hameln.ogg"),
			"Village of Temptation starts with the source normal track")
		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts
			and int(source_counts.get("monster/thief/thieffemale.mob", 0)) == 4
			and int(source_counts.get("monster/thief/thiefmale.mob", 0)) == 4,
			"Village of Temptation start room spawns four source thieves of each gender")
		var breakable_room: Dictionary = probe.room("map/villigeoftemptation/e6414.map")
		var breakable_props: Array = game.build_props(breakable_room)
		check(breakable_props.size() == 7
			and breakable_props.all(func(prop): return prop.has("native_breakable")),
			"MAP 6414 materialises seven source-backed breakable statues (got=%d gaps=%s)"
			% [breakable_props.size(), game.native_object_gaps])
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_VILLAGE_OF_TEMPTATION] COMPLETE checks=%d failures=%d"
		% [checks, failures])
	quit(0 if failures == 0 else 1)
