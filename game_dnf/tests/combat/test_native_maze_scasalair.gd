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
	func _init(sequence: Array) -> void:
		for value in sequence:values.append(int(value))
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
		push_error("[NATIVE_MAZE_SCASALAIR] FAIL " + label)

func required_maps() -> Array[String]:
	return [
		"map/scasalair/boss(0,0).map",
		"map/scasalair/e1(2,3).map",
		"map/scasalair/e2(start).map",
		"map/scasalair/h1(2,0).map",
		"map/scasalair/h2(1,0).map",
		"map/scasalair/n1(0,2).map",
		"map/scasalair/n2(1,2).map",
		"map/scasalair/n3(2,2).map",
		"map/scasalair/n4(2,1).map",
		"map/scasalair/qn2(1,2).map",
		"map/scasalair/start1(0,3).map",
		"map/scasalair/start2(1,3).map",
	]

func aggregate_source(dungeon: Dictionary, paths: Array[String]) -> Dictionary:
	var mobs := {}
	var objects := {}
	var tags := {}
	var monster_count := 0
	var object_count := 0
	var boss_rows := 0
	for path in paths:
		var room: Dictionary = dungeon["rooms"][path]
		for monster: Dictionary in room.get("monsters", []):
			monster_count += 1
			mobs[String(monster.get("mob", ""))] = true
			var raw: Array = monster.get("raw", [])
			if not raw.is_empty() and raw[-1] == "[boss]":boss_rows += 1
		for item: Dictionary in room.get("objects", []):
			object_count += 1
			var obj_path := String(item.get("obj", "")).to_lower()
			objects[obj_path] = 1 + int(objects.get(obj_path, 0))
			var tag := String(item.get("source_tag", ""))
			tags[tag] = 1 + int(tags.get(tag, 0))
	return {
		"monsters": mobs, "monster_count": monster_count, "boss_rows": boss_rows,
		"objects": objects, "object_count": object_count, "tags": tags,
	}

func run() -> void:
	game = session.mount(root)
	game.set_process(false)
	game.set_physics_process(false)
	var routes: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/dungeons.json"))["dungeons"]
	var route: Dictionary = routes["scasalair"]
	check(route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("name") == "斯卡萨之巢" and route.get("region") == "snowmt"
		and int(route.get("min_level", 0)) == 54 and int(route.get("monster_level", 0)) == 57,
		"Scasa's Lair is a hidden level 54 Snow Mountain native-maze route with source basis level 57")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production Scasa's Lair export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/act5/scasalair.dgn"
		and dungeon.get("sha256") == "33d86d36e372ad3d17ed062ce82a80710ec54395b19785c784a9419e760cb536"
		and int(dungeon.get("index", -1)) == 45,
		"Scasa's Lair export keeps DGN index 45 and the pinned source identity")
	check(Array(dungeon.get("placements", [])).size() == 21
		and Dictionary(dungeon.get("rooms", {})).size() == 16
		and Dictionary(probe.data.get("images", {})).size() == 74,
		"Scasa's Lair export contains 21 greed-eligible placements, 16 MAPs and 74 source images")
	check(int(dungeon.get("maze_block_index", -1)) == 0
		and dungeon.get("maze_block_selection") == "hell_base"
		and Array(dungeon.get("maze_blocks", [])).size() == 2,
		"Scasa's Lair preserves two blocks and selects the non-quest hell base")
	var blocks: Array = dungeon.get("maze_blocks", [])
	var base_specs: Array = []
	var base_starts: Array = []
	for value in Array(blocks[0].get("start_map_raw", [])):base_starts.append(int(value))
	for row in Array(blocks[0].get("boss_map_specifications", [])):
		var normalized: Array = []
		for value in row:normalized.append(int(value))
		base_specs.append(normalized)
	check(Array(blocks[0].get("map_specifications", [])).is_empty()
		and base_specs == [[0, 0, 9310]] and base_starts == [1, 3, 0, 3],
		"base block keeps two start cells, zero normal specs and fixed boss MAP 9310 "
		+ "(specs=%s starts=%s)" % [base_specs, base_starts])
	var quest_values: Array = []
	var escape_values: Array = []
	for value in Array(blocks[1].get("quest_connection", [])):quest_values.append(int(value))
	for value in Array(blocks[1].get("escape_hell", [])):escape_values.append(int(value))
	check(quest_values == [0, 4571, 2] and escape_values == [1],
		"quest 4571/escape block remains raw and unselected "
		+ "(quest=%s escape=%s)" % [quest_values, escape_values])

	var diagnostics: Array = probe.data.get("diagnostics", [])
	var errors: Array = diagnostics.filter(func(row): return row.get("level") == "error")
	var warnings: Array = diagnostics.filter(func(row): return row.get("level") == "warning")
	var infos: Array = diagnostics.filter(func(row): return row.get("level") == "info")
	check(errors.is_empty(), "Scasa's Lair export has no source image or ANI errors")
	check(warnings.size() == 37
		and warnings.filter(func(row): return row.get("code") == "cell_without_map").size() == 2
		and warnings.filter(func(row): return row.get("code") == "object_unrendered").size() == 35,
		"Scasa's Lair preserves two AA cells and 35 unrendered egg warnings")
	check(infos.size() == 91
		and infos.filter(func(row): return row.get("code") == "empty_tile").size() == 72
		and infos.filter(func(row): return row.get("code") == "unhandled_tags").size() == 16
		and infos.filter(func(row): return row.get("code") == "object_unrendered").size() == 2
		and infos.filter(func(row): return row.get("code") == "maze_block_selected").size() == 1,
		"Scasa's Lair preserves tile, unhandled-tag and selected-block metadata")

	var maze := NativeMaze.new()
	var size: Vector2i = maze._point(dungeon.get("size"))
	var cells: Dictionary = maze._read_cells(dungeon.get("cells"), size)
	var starts: Array = maze._read_endpoint_cells(dungeon.get("start_map_raw"), cells, "start_candidate")
	var bosses: Array = maze._read_endpoint_cells(dungeon.get("boss_map_raw"), cells, "boss_candidate")
	var specs: Dictionary = maze._read_specifications(dungeon.get("raw"), cells, 0)
	check(cells.size() == 12 and starts.size() == 2 and bosses.size() == 1,
		"Scasa's Lair 3x4 source grid exposes two starts and one boss")
	check(starts == [Vector2i(1, 3), Vector2i(0, 3)] and bosses[0] == Vector2i(0, 0),
		"source start cells and boss follow the DGN vector order")
	var connected := cells.values().filter(func(cell): return not cell.get("doors", []).is_empty())
	check(connected.size() == 10 and cells.values().filter(func(cell): return cell.get("code") == "AA").size() == 2,
		"Scasa's Lair base block has ten connected cells and two empty AA cells")
	check(specs.get("normal", {}).is_empty() and specs.get("boss", {}).size() == 1,
		"base block uses mask-based normal pools and fixes only the boss MAP")

	var maze_a := NativeMaze.new()
	check(maze_a.start(probe.data, SourceRolls.new([0, 0, 0]), route.get("source", {})),
		"native maze starts Scasa's Lair at source start slot 0")
	check(maze_a.current_room().get("cell") == Vector2i(1, 3)
		and maze_a.current_room().get("source_map_id") == 9300,
		"start slot 0 resolves cell (1,3) through start1 MAP 9300")
	check(maze_a.room_count() == 10 and maze_a.required_map_paths().size() == 12,
		"Scasa's Lair exposes ten rooms from twelve source MAP candidates "
		+ "(rooms=%d maps=%d paths=%s error=%s)"
		% [maze_a.room_count(), maze_a.required_map_paths().size(), maze_a.required_map_paths(), maze_a.last_error])
	var required := {}
	for path in maze_a.required_map_paths():required[path] = true
	for path in required_maps():check(required.has(path), "required MAP candidate is retained: " + path)
	check(maze_a._pools[Vector2i(1, 3)].size() == 2 and maze_a._pools[Vector2i(0, 3)].size() == 4,
		"entry cell keeps two start-area MAPs while the other CC cell keeps all four normal MAPs")

	var maze_b := NativeMaze.new()
	check(maze_b.start(probe.data, SourceRolls.new([1, 0, 1]), route.get("source", {})),
		"native maze starts Scasa's Lair at source start slot 1")
	check(maze_b.current_room().get("cell") == Vector2i(0, 3)
		and maze_b.current_room().get("source_map_id") == 9301,
		"start slot 1 resolves cell (0,3) through start2 MAP 9301")

	var all_maps: Array[String] = []
	for path: String in dungeon.get("rooms", {}):
		all_maps.append(path)
	var all_source := aggregate_source(dungeon, all_maps)
	check(all_source["monsters"].size() == 8 and all_source["monster_count"] == 97
		and all_source["boss_rows"] == 2,
		"Scasa's Lair source has 97 direct monsters, eight MOBs and two boss rows")
	check(all_source["object_count"] == 374 and all_source["tags"] == {
		"[passive object]": 373,
		"[special passive object]": 1,
	}, "Scasa's Lair source has 374 objects across both blocks")

	var base_source := aggregate_source(dungeon, required_maps())
	check(base_source["monsters"].size() == 8 and base_source["monster_count"] == 76
		and base_source["boss_rows"] == 1,
		"hell-base candidate pool has 76 monsters, eight MOBs and one Scasa boss row")
	check(base_source["object_count"] == 273 and base_source["tags"] == {
		"[passive object]": 272,
		"[special passive object]": 1,
	}, "hell-base candidate pool has 273 objects and one special item pocket")

	var breakable_candidates := 0
	var runtime_breakables := 0
	var unrendered := 0
	for path in required_maps():
		for item: Dictionary in dungeon["rooms"][path].get("objects", []):
			if item.get("sprite") == null:unrendered += 1
			if NativeBreakable.supports(item):
				breakable_candidates += 1
				if not game.content.record(String(item.get("obj", "")).to_lower()).get("native_breakable", {}).is_empty():
					runtime_breakables += 1
	check(unrendered == 28,
		"base candidate pool has 28 scasa eggs/blizzard objects without static sprite (actual=%d)" % unrendered)
	check(breakable_candidates == 135 and runtime_breakables == 107,
		"base candidate pool compiles 107 crystal/tree/tomb objects while 28 eggs/item pocket remain gaps")
	check(not NativeBoxLoot.required(dungeon),
		"Scasa's Lair item pocket carries trap 2211 but no executable item group")
	check(NativeJarTraps.ready(game.combat_assets), "shared source jar trap assets resolve")

	var banks := {
		"monster/newmonsters/dragon/scasa/scasa.mob": ["newmonsters_dragon_scasa_scasa", 27, []],
		"monster/newmonsters/bantu/buffaloman/buffaloman.mob": ["newmonsters_bantu_buffaloman_buffaloman", 4, [0, 1, 2]],
		"monster/newmonsters/bantu/buffalowoman/buffalowoman.mob": ["newmonsters_bantu_buffalowoman_buffalowoman", 2, [0, 1]],
		"monster/newmonsters/spider/slotor/slotor.mob": ["newmonsters_spider_slotor_slotor", 3, [1, 0, 2]],
		"monster/newmonsters/scasababy/scasababy.mob": ["newmonsters_scasababy_scasababy", 2, [0, 1]],
		"monster/newmonsters/bantu/elitebuffaloman/elitebuffaloman.mob": ["newmonsters_bantu_elitebuffaloman_elitebuffaloman", 9, [1, 2, 3, 5]],
		"monster/newmonsters/bantu/elitebuffalowoman/elitebuffalowoman.mob": ["newmonsters_bantu_elitebuffalowoman_elitebuffalowoman", 8, [0, 1, 5, 2, 6]],
		"monster/newmonsters/spider/slotor1/slotor1.mob": ["newmonsters_spider_slotor1_slotor1", 9, [7, 6, 3, 2, 0, 1, 5]],
	}
	for mob: String in banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		check(String(definition.get("bank", "")) == banks[mob][0]
			and game.combat_assets.get("monsters", {}).has(banks[mob][0]),
			"Scasa's Lair source bank is compiled: " + mob)
		check(Array(definition.get("moves", [])).size() == int(banks[mob][1]),
			"source attack slots compile for %s (moves=%d expected=%d)"
			% [mob, Array(definition.get("moves", [])).size(), int(banks[mob][1])])
		var skills: Array = []
		for rule: Dictionary in Array(definition.get("rules", [])):
			skills.append(int(rule.get("skill", -1)))
		check(skills == banks[mob][2],
			"source AI priority compiles for %s (%s)" % [mob, skills])
		for move: Dictionary in Array(definition.get("moves", [])):
			if not move.has("atk_path"):continue
			check(not game.table.atk(String(move["atk_path"])).is_empty()
				and not Array(move.get("timeline", [])).is_empty(),
				"source attack motion and ATK compile together: " + mob)

	var bgm: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/bgm.json"))
	check(bgm.get("dungeons", {}).get("scasalair", {}).get("normal") == "skasa"
		and bgm.get("dungeons", {}).get("scasalair", {}).get("boss") == "skasa_boss",
		"Scasa's Lair maps the source normal and boss tracks")
	check(not bgm.get("source_gaps", {}).has("scasalair"),
		"Scasa's Lair has no unresolved MAP music cue")

	var flow := FlowSession.new()
	flow.profile["level"] = 57
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "scasalair"})["ok"],
		"flow departs the hidden Scasa's Lair route")
	route = flow.active_dungeon_route()
	NativePotMonsters.reset_catalog()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live Scasa's Lair run selects the hell-base block")
	NativePotMonsters.prepare_catalog(dungeon, SourceRolls.new([0, 0, 0, 0]))
	check(session._validate_native_maze(probe, live_maze),
		"Scasa's Lair room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "scasalair", "route": route,
		"room_id": "scasalair:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source Scasa's Lair room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 10
			and game.view_snapshot()["hud"]["route"].size() == 10,
			"both public battle views report the complete ten-room Scasa graph")
		check(game.view.audio.has_dungeon_music("scasalair")
			and String(game.view.audio.music.stream.resource_path).ends_with("skasa.ogg"),
			"Scasa's Lair starts with the source M_SKASA track")

		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts,
			"Scasa's Lair start room spawns its exact source monster lineup")

		var interactive_props := 0
		var all_gaps := {}
		for path in required_maps():
			var room: Dictionary = probe.room(path)
			var room_props: Array = game.build_props(room)
			interactive_props += room_props.size()
			for path_key: String in game.native_object_gaps:
				if not all_gaps.has(path_key):all_gaps[path_key] = []
				for gap in game.native_object_gaps[path_key]:
					if gap not in all_gaps[path_key]:all_gaps[path_key].append(gap)
		check(interactive_props == 107,
			"Scasa's Lair materialises 56 crystals, 39 frozen trees and 12 tombs")
		check(all_gaps.get("passiveobject/actionobject/breakableobject/scasaegg_breakable.obj", [])
			== ["native_breakable_source"]
			and all_gaps.get("passiveobject/actionobject/breakableobject/scasaegg_active.obj", [])
			== ["native_breakable_source"],
			"breakable and active scasa eggs remain explicit source gaps")
		var pocket_gaps: Array = all_gaps.get(
			"passiveobject/mapobject/breakableobject/itempocket.obj", [])
		check(pocket_gaps == ["native_breakable_source", "native_special_object", 2211],
			"item pocket preserves missing breakable source, special payload and trap 2211 "
			+ "(actual=%s)" % str(pocket_gaps))
		check(all_gaps.get("passiveobject/mapobject/particlefactory/blizzard.obj", [])
			== ["native_particle_factory"],
			"blizzard particle factory remains an explicit behavior gap")
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_SCASALAIR] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
