extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const FlowSession = preload("res://flow/session.gd")
const NativeMaze = preload("res://combat/data/native_maze.gd")
const NativeBreakable = preload("res://combat/resolve/native_breakable.gd")
const NativeBoxLoot = preload("res://loot/native_box.gd")
const NativeJarTraps = preload("res://combat/resolve/native_jar_traps.gd")
const NativePotMonsters = preload("res://combat/resolve/native_pot_monsters.gd")
const DetRng = preload("res://core/det_rng.gd")
const ROUTE_MAP_IDS: Array[int] = [7101, 7102, 7103, 7104, 7105, 7106, 7107]
const ROUTE_MAPS: Array[String] = [
	"map/noirpera/map1(0,0)_start.map",
	"map/noirpera/map2(0,1).map",
	"map/noirpera/map3(1,1).map",
	"map/noirpera/map4(2,1).map",
	"map/noirpera/map5(2,0).map",
	"map/noirpera/map6(3,0).map",
	"map/noirpera/map7(4,0)_boss.map",
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
		push_error("[NATIVE_MAZE_NOIRPERA] FAIL " + label)

func run() -> void:
	game = session.mount(root)
	game.set_process(false)
	game.set_physics_process(false)
	var routes: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/dungeons.json"))["dungeons"]
	var route: Dictionary = routes["noirpera"]
	check(route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("name") == "诺伊佩拉" and route.get("region") == "noierfera"
		and int(route.get("min_level", 0)) == 59 and int(route.get("monster_level", 0)) == 55,
		"Noirpera is a hidden level 59 Dark Elf native-maze route with source basis level 55")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production Noirpera export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/ancient/noirpera.dgn"
		and dungeon.get("sha256") == "123d44302169bc52aae44ac4220e220b9caae708a221984a5298c8c788aab56f"
		and int(dungeon.get("index", -1)) == 1502,
		"Noirpera export keeps DGN index 1502 and the pinned source identity")
	check(Array(dungeon.get("placements", [])).size() == 7
		and Dictionary(dungeon.get("rooms", {})).size() == 7
		and Dictionary(probe.data.get("images", {})).size() == 81,
		"Noirpera export contains seven fixed placements, seven MAPs and 81 source images")
	check(int(dungeon.get("maze_block_index", -1)) == 0
		and dungeon.get("maze_block_selection") == "hell_base"
		and Array(dungeon.get("maze_blocks", [])).size() == 1,
		"Noirpera selects its single source hell-base block 0")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	var errors: Array = diagnostics.filter(func(row): return row.get("level") == "error")
	var warnings: Array = diagnostics.filter(func(row): return row.get("level") == "warning")
	var infos: Array = diagnostics.filter(func(row): return row.get("level") == "info")
	check(errors.is_empty(), "Noirpera export has no source image or ANI errors")
	check(warnings.size() == 3
		and warnings.filter(func(row): return row.get("code") == "cell_without_map").size() == 3,
		"Noirpera preserves three empty AA cells")
	check(infos.size() == 7
		and infos.filter(func(row): return row.get("code") == "unhandled_tags").size() == 7,
		"Noirpera preserves seven raw MAP tag reports")

	var maze := NativeMaze.new()
	var size: Vector2i = maze._point(dungeon.get("size"))
	var cells: Dictionary = maze._read_cells(dungeon.get("cells"), size)
	var starts: Array = maze._read_endpoint_cells(dungeon.get("start_map_raw"), cells, "start_candidate")
	var bosses: Array = maze._read_endpoint_cells(dungeon.get("boss_map_raw"), cells, "boss_candidate")
	var specs: Dictionary = maze._read_specifications(dungeon.get("raw"), cells, 0)
	check(cells.size() == 10 and starts.size() == 1 and bosses.size() == 1,
		"Noirpera 5x2 source grid exposes one start and one boss candidate")
	check(starts[0] == Vector2i(0, 0) and bosses[0] == Vector2i(4, 0),
		"Noirpera source endpoints are start (0,0) and boss (4,0)")
	check(cells.values().filter(func(cell): return not cell.get("doors", []).is_empty()).size() == 7
		and cells.values().filter(func(cell): return cell.get("code") == "AA").size() == 3,
		"Noirpera has seven connected cells and three empty AA cells")
	check(specs.get("normal", {}).size() == 5 and specs.get("boss", {}).is_empty(),
		"Noirpera preserves five normal specifications and resolves its boss from the endpoint MAP")
	var block: Dictionary = Array(dungeon.get("maze_blocks", []))[0]
	check(Array(block.get("map_specifications", [])).map(func(row): return int(row[2]))
		== [7102, 7103, 7104, 7105, 7106]
		and Array(block.get("boss_map_specifications", [])).is_empty()
		and Array(block.get("hell_dungeon", [])).map(func(value): return int(value)) == [1]
		and Array(block.get("seal_door_map_index", [])).map(func(value): return int(value)) == [60036]
		and Array(block.get("seal_door_pos", [])).map(func(value): return int(value)) == [3, 0]
		and Array(block.get("seal_door_appear_rate", [])).map(func(value): return int(value)) == [10],
		"Noirpera preserves fixed MAP IDs, hell mode and seal door 60036")

	var pools: Dictionary = maze._read_pools(dungeon, cells, starts[0], bosses[0])
	check(pools.size() == 7,
		"Noirpera start/boss reaches all seven connected cells (pools=%d error=%s)"
		% [pools.size(), maze.last_error])
	check(maze.start(probe.data, SourceRolls.new([0, 0]), route.get("source", {})),
		"generic native maze starts Noirpera")
	check(maze.room_count() == 7 and maze.required_map_paths().size() == 7,
		"Noirpera exposes seven rooms across seven source-fixed MAPs")
	var selected_ids: Array[int] = [int(maze.current_room().get("source_map_id", 0))]
	var doors := ["right", "down", "right", "up", "right", "right"]
	for step in doors.size():
		var current: Vector2i = maze.current_room().get("cell", Vector2i(-1, -1))
		var cleared: Dictionary = maze.clear_room(current, 0)
		var moved: Dictionary = maze.move(doors[step])
		check(not cleared.is_empty() and not moved.is_empty(),
			"Noirpera clears and traverses source step %d via %s" % [step, doors[step]])
		selected_ids.append(int(moved.get("source_map_id", 0)))
	check(selected_ids == ROUTE_MAP_IDS,
		"Noirpera selects MAP 7101..7107 in the fixed route order")
	var final_clear: Dictionary = maze.clear_room(Vector2i(4, 0), 0)
	check(bool(final_clear.get("boss", false)) and bool(final_clear.get("final_room", false)),
		"the Direzie illusion room is the sole boss and final room")
	check(not NativeBoxLoot.required(dungeon),
		"Noirpera has no executable special-object item groups")
	check(NativeJarTraps.ready(game.combat_assets), "shared source jar trap assets resolve")

	var source_monsters := {}
	var source_monster_count := 0
	var source_boss_rows := 0
	var source_object_count := 0
	var specific_ai_count := 0
	var npc_count := 0
	for room: Dictionary in dungeon.get("rooms", {}).values():
		for monster: Dictionary in room.get("monsters", []):
			source_monsters[String(monster.get("mob", ""))] = true
			source_monster_count += 1
			var raw: Array = monster.get("raw", [])
			if not raw.is_empty() and raw[-1] == "[boss]":source_boss_rows += 1
		source_object_count += Array(room.get("objects", [])).size()
		for span: Dictionary in room.get("raw", []):
			if span.get("tag") == "[monster specific AI]":
				specific_ai_count += Array(span.get("values", [])).size()
			elif span.get("tag") == "[NPC]":
				npc_count += 1
	check(source_monsters.size() == 11 and source_monster_count == 47 and source_boss_rows == 1,
		"Noirpera source has 47 direct placements, eleven MOBs and one boss row")
	check(source_object_count == 0,
		"Noirpera contains no direct map-object row in this source layout")
	check(specific_ai_count == 47 and npc_count == 1,
		"Noirpera preserves 47 normal AI rows and one boss NPC")
	for mob: String in source_monsters:
		check(not game.table.monster_by_mob(mob).is_empty(),
			"direct source MOB has runtime content: " + mob)

	var banks := {
		"monster/newmonsters/ancient/infected_ghoula/infected_ghoula.mob":
			["newmonsters_ancient_infected_ghoula_infected_ghoula", 2, [0], [1, 0]],
		"monster/newmonsters/ancient/infected_ghoulb/infected_ghoulb.mob":
			["newmonsters_ancient_infected_ghoulb_infected_ghoulb", 1, [0], [0]],
		"monster/newmonsters/ancient/noir_dimension_gate/noir_dimension_gate.mob":
			["newmonsters_ancient_noir_dimension_gate_noir_dimension_gate", 5, [], [1, 0, 2, 4]],
		"monster/newmonsters/direzie/direzie.mob":
			["newmonsters_direzie_direzie", 14, [0, 1, 2, 3, 5, 6, 9], [10, 11, 12]],
		"monster/newmonsters/disguiser/mummy_basic/mummy_basic.mob":
			["newmonsters_disguiser_mummy_basic_mummy_basic", 1, [0], [0]],
		"monster/newmonsters/disguiser/mummy_ghost/mummy_ghost.mob":
			["newmonsters_disguiser_mummy_ghost_mummy_ghost", 4, [0], [2, 1, 0]],
		"monster/newmonsters/grim_priest/grim_priest_1_2/grim_priest1.mob":
			["newmonsters_grim_priest_grim_priest_1_2_grim_priest1", 3, [], []],
		"monster/newmonsters/grim_priest/grim_priest_1_2/grim_priest2.mob":
			["newmonsters_grim_priest_grim_priest_1_2_grim_priest2", 3, [], []],
		"monster/newmonsters/grim_priest/grimpriest_nubelus/grimpriest_nubelus.mob":
			["newmonsters_grim_priest_grimpriest_nubelus_grimpriest_nubelus", 3, [], [1, 0, 2]],
		"monster/newmonsters/militiaman/militiaman/militiaman.mob":
			["newmonsters_militiaman_militiaman_militiaman", 4, [0, 1], [2, 1, 3, 0]],
		"monster/newmonsters/militiaman/militiamanboss/militiamanboss.mob":
			["newmonsters_militiaman_militiamanboss_militiamanboss", 4, [0, 1, 2], [3, 2, 0, 1]],
	}
	for mob: String in banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		check(String(definition.get("bank", "")) == banks[mob][0]
			and game.combat_assets.get("monsters", {}).has(banks[mob][0]),
			"Noirpera source bank is compiled: " + mob)
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
	check(bgm.get("dungeons", {}).get("noirpera", {}).get("normal") == "npera"
		and bgm.get("dungeons", {}).get("noirpera", {}).get("boss") == "npera_boss",
		"Noirpera maps its source M_NPERA normal and boss tracks")
	check(not bgm.get("source_gaps", {}).has("noirpera"),
		"Noirpera has no unresolved MAP music cue")

	var flow := FlowSession.new()
	flow.profile["level"] = 59
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "noirpera"})["ok"],
		"flow departs the hidden Noirpera route")
	route = flow.active_dungeon_route()
	NativePotMonsters.reset_catalog()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live Noirpera run selects its hell-base block")
	NativePotMonsters.prepare_catalog(dungeon, SourceRolls.new([0, 0, 0, 0]))
	check(session._validate_native_maze(probe, live_maze),
		"Noirpera room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "noirpera", "route": route,
		"room_id": "noirpera:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source Noirpera room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 7
			and game.view_snapshot()["hud"]["route"].size() == 7,
			"both public battle views report the complete seven-room Noirpera graph")
		check(game.view.audio.has_dungeon_music("noirpera")
			and String(game.view.audio.music.stream.resource_path).ends_with("npera.ogg"),
			"Noirpera starts with the source M_NPERA track")

		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts and int(source_counts.get(
			"monster/newmonsters/militiaman/militiaman/militiaman.mob", 0)) == 8,
			"Noirpera start room spawns its exact eight militia lineup")

		var interactive_props := 0
		var all_gaps := {}
		for path: String in ROUTE_MAPS:
			var room: Dictionary = probe.room(path)
			interactive_props += game.build_props(room).size()
			for path_key: String in game.native_object_gaps:
				all_gaps[path_key] = true
		check(interactive_props == 0 and all_gaps.is_empty(),
			"Noirpera contains no fake map props or object-specific runtime gaps")
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_NOIRPERA] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
