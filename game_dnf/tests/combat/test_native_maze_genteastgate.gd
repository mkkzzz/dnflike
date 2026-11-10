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
		push_error("[NATIVE_MAZE_GENTEASTGATE] FAIL " + label)

func route_s0b0() -> Array[String]:
	return [
		"map/genteastgate/start2(6,1).map",
		"map/genteastgate/09esay(5,1).map",
		"map/genteastgate/10normal(4,1).map",
		"map/genteastgate/04normal(3,1).map",
		"map/genteastgate/03normal(2,1).map",
		"map/genteastgate/11hard(3,0).map",
		"map/genteastgate/05hard(3,2).map",
		"map/genteastgate/02esay(1,1).map",
		"map/genteastgate/13hard(5,0).map",
		"map/genteastgate/07hard(1,2).map",
		"map/genteastgate/bonus2(2,0).map",
		"map/genteastgate/start1(0,1).map",
		"map/genteastgate/boss2(6,0).map",
	]

func route_s0b1() -> Array[String]:
	var result := route_s0b0()
	result.erase("map/genteastgate/boss2(6,0).map")
	result.append("map/genteastgate/bonus1(4,2).map")
	result.append("map/genteastgate/boss1(0,2).map")
	return result

func route_s1b0() -> Array[String]:
	return [
		"map/genteastgate/start1(0,1).map",
		"map/genteastgate/02esay(1,1).map",
		"map/genteastgate/03normal(2,1).map",
		"map/genteastgate/04normal(3,1).map",
		"map/genteastgate/10normal(4,1).map",
		"map/genteastgate/11hard(3,0).map",
		"map/genteastgate/05hard(3,2).map",
		"map/genteastgate/09esay(5,1).map",
		"map/genteastgate/13hard(5,0).map",
		"map/genteastgate/07hard(1,2).map",
		"map/genteastgate/bonus1(4,2).map",
		"map/genteastgate/start2(6,1).map",
		"map/genteastgate/boss2(6,0).map",
		"map/genteastgate/bonus2(2,0).map",
	]

func route_s1b1() -> Array[String]:
	var result := route_s1b0()
	result.erase("map/genteastgate/boss2(6,0).map")
	result.erase("map/genteastgate/bonus2(2,0).map")
	result.append("map/genteastgate/boss1(0,2).map")
	return result

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

func source_gaps(dungeon: Dictionary, paths: Array[String]) -> Dictionary:
	var candidates := 0
	var runtime := 0
	var unrendered := 0
	for path in paths:
		for item: Dictionary in dungeon["rooms"][path].get("objects", []):
			if item.get("sprite") == null:unrendered += 1
			if NativeBreakable.supports(item):
				candidates += 1
				if not game.content.record(String(item.get("obj", "")).to_lower()).get("native_breakable", {}).is_empty():
					runtime += 1
	return {"candidates": candidates, "runtime": runtime, "unrendered": unrendered}

func run() -> void:
	game = session.mount(root)
	game.set_process(false)
	game.set_physics_process(false)
	var routes: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/dungeons.json"))["dungeons"]
	var route: Dictionary = routes["genteastgate"]
	check(route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("name") == "根特东门" and route.get("region") == "gent"
		and int(route.get("min_level", 0)) == 56 and int(route.get("monster_level", 0)) == 59,
		"Gent East Gate is a hidden level 56 Gent native-maze route with source basis level 59")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production Gent East Gate export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/act7/genteastgate.dgn"
		and dungeon.get("sha256") == "064337edb39b84d7a4dc7c7fbef089378ae64c6c1b61857224f2f9371d06d1a0"
		and int(dungeon.get("index", -1)) == 81,
		"Gent East Gate export keeps DGN index 81 and the pinned source identity")
	check(Array(dungeon.get("placements", [])).size() == 71
		and Dictionary(dungeon.get("rooms", {})).size() == 19
		and Dictionary(probe.data.get("images", {})).size() == 47,
		"Gent East Gate export contains 71 greed-eligible placements, 19 MAPs and 47 source images")
	check(int(dungeon.get("maze_block_index", -1)) == 1
		and dungeon.get("maze_block_selection") == "hell_base"
		and Array(dungeon.get("maze_blocks", [])).size() == 2,
		"Gent East Gate preserves two blocks and selects hell-base block 1")
	var blocks: Array = dungeon.get("maze_blocks", [])
	var quest: Array = []
	var escape: Array = []
	for value in Array(blocks[0].get("quest_connection", [])):quest.append(int(value))
	for value in Array(blocks[0].get("escape_hell", [])):escape.append(int(value))
	check(quest == [0, 4212, -1] and escape == [1],
		"quest 4212/escape block 0 remains raw and unselected")
	check(Array(blocks[1].get("map_specifications", [])).size() == 6
		and Array(blocks[1].get("boss_map_specifications", [])).size() == 2,
		"hell-base block preserves six normal and two boss specifications")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	var errors: Array = diagnostics.filter(func(row): return row.get("level") == "error")
	var warnings: Array = diagnostics.filter(func(row): return row.get("level") == "warning")
	var infos: Array = diagnostics.filter(func(row): return row.get("level") == "info")
	check(errors.is_empty(), "Gent East Gate export has no source image or ANI errors")
	check(warnings.size() == 104
		and warnings.filter(func(row): return row.get("code") == "cell_without_map").size() == 8
		and warnings.filter(func(row): return row.get("code") == "object_unrendered").size() == 96,
		"Gent East Gate preserves eight AA cells and 96 source-only object warnings")
	check(infos.size() == 20
		and infos.filter(func(row): return row.get("code") == "unhandled_tags").size() == 19
		and infos.filter(func(row): return row.get("code") == "maze_block_selected").size() == 1,
		"Gent East Gate preserves unhandled tags and one selected-block record")

	var maze := NativeMaze.new()
	var size: Vector2i = maze._point(dungeon.get("size"))
	var cells: Dictionary = maze._read_cells(dungeon.get("cells"), size)
	var starts: Array = maze._read_endpoint_cells(dungeon.get("start_map_raw"), cells, "start_candidate")
	var bosses: Array = maze._read_endpoint_cells(dungeon.get("boss_map_raw"), cells, "boss_candidate")
	var specs: Dictionary = maze._read_specifications(dungeon.get("raw"), cells, 1)
	check(cells.size() == 21 and starts.size() == 2 and bosses.size() == 2,
		"Gent East Gate 7x3 source grid exposes two starts and two bosses")
	check(starts == [Vector2i(6, 1), Vector2i(0, 1)]
		and bosses == [Vector2i(5, 0), Vector2i(1, 2)],
		"Gent East Gate preserves source start and boss vector order")
	check(cells.values().filter(func(cell): return not cell.get("doors", []).is_empty()).size() == 13
		and cells.values().filter(func(cell): return cell.get("code") == "AA").size() == 8,
		"Gent East Gate base block has 13 connected cells and eight empty AA cells")
	check(specs.get("normal", {}).size() == 6 and specs.get("boss", {}).size() == 2,
		"Gent East Gate selected block preserves six normal and two boss specifications")

	var combos := [
		{"rolls": [0, 0], "start": 10001, "cell": Vector2i(6, 1), "boss": Vector2i(5, 0), "maps": route_s0b0()},
		{"rolls": [0, 1], "start": 10001, "cell": Vector2i(6, 1), "boss": Vector2i(1, 2), "maps": route_s0b1()},
		{"rolls": [1, 0], "start": 10000, "cell": Vector2i(0, 1), "boss": Vector2i(5, 0), "maps": route_s1b0()},
		{"rolls": [1, 1], "start": 10000, "cell": Vector2i(0, 1), "boss": Vector2i(1, 2), "maps": route_s1b1()},
	]
	var mazes: Array = []
	for combo: Dictionary in combos:
		var combo_maze := NativeMaze.new()
		check(combo_maze.start(probe.data, SourceRolls.new(combo["rolls"]), route.get("source", {})),
			"native maze starts Gent East combo %s" % str(combo["rolls"]))
		check(combo_maze.current_room().get("cell") == combo["cell"]
			and combo_maze.current_room().get("source_map_id") == combo["start"]
			and combo_maze._boss == combo["boss"] and combo_maze.room_count() == 13,
			"combo %s resolves expected start cell/MAP/boss and thirteen rooms" % str(combo["rolls"]))
		var required := {}
		for path in combo_maze.required_map_paths():required[path] = true
		check(required.size() == combo["maps"].size(),
			"combo %s exposes %d required MAPs" % [str(combo["rolls"]), combo["maps"].size()])
		for path: String in combo["maps"]:check(required.has(path), "combo retains MAP: " + path)
		mazes.append(combo_maze)

	var all_maps: Array[String] = []
	for path: String in dungeon.get("rooms", {}):
		all_maps.append(path)
	var all_source := aggregate_source(dungeon, all_maps)
	check(all_source["monsters"].size() == 8 and all_source["monster_count"] == 152
		and all_source["boss_rows"] == 3 and all_source["object_count"] == 162,
		"Gent East Gate source has 152 monsters, eight MOBs, three boss rows and 162 objects")

	var expected_runs := [
		[route_s0b0(), 101, 96, 2],
		[route_s0b1(), 106, 116, 3],
		[route_s1b0(), 106, 116, 3],
		[route_s1b1(), 98, 96, 2],
	]
	for row: Array in expected_runs:
		var paths: Array[String] = row[0]
		var aggregate := aggregate_source(dungeon, paths)
		check(aggregate["monster_count"] == int(row[1]) and aggregate["object_count"] == int(row[2])
			and aggregate["boss_rows"] == 1 and int(aggregate["tags"].get("[special passive object]", 0)) == int(row[3]),
			"source route aggregate matches monsters/objects/special sacks for %s" % str(row.slice(1)))
		var gaps := source_gaps(dungeon, paths)
		check(gaps["runtime"] == 0 and gaps["candidates"] == (55 if int(row[2]) < 100 else 56)
			and gaps["unrendered"] == (61 if int(row[2]) < 100 else 68),
			"source route breakables and unrendered objects remain explicit gaps for %s (actual=%s)"
			% [str(row.slice(1)), gaps])
	check(not NativeBoxLoot.required(dungeon),
		"Gent East Gate has no executable special-object item groups")
	check(NativeJarTraps.ready(game.combat_assets), "shared source jar trap assets resolve")

	var banks := {
		"monster/newmonsters/cartel/normalsoldier/normalsoldier.mob":
			["newmonsters_cartel_normalsoldier_normalsoldier", 2, [1, 0]],
		"monster/newmonsters/cartel/medic/medic.mob":
			["newmonsters_cartel_medic_medic", 0, [1]],
		"monster/newmonsters/heaven/specialforce/specialforce.mob":
			["newmonsters_heaven_specialforce_specialforce", 3, [0, 1]],
		"monster/newmonsters/cartel/minorsoldier/minorsoldier.mob":
			["newmonsters_cartel_minorsoldier_minorsoldier", 1, [0]],
		"monster/newmonsters/cartel/incendiarysoldier/incendiarysoldier.mob":
			["newmonsters_cartel_incendiarysoldier_incendiarysoldier", 2, [1, 0]],
		"monster/newmonsters/heaven/caspar/caspar.mob":
			["newmonsters_heaven_caspar_caspar", 0, [1, 0]],
		"monster/newmonsters/heaven/vulcherspecialforce/vulcherspecialforce.mob":
			["newmonsters_heaven_vulcherspecialforce_vulcherspecialforce", 2, [0, 1]],
		"monster/newmonsters/heaven/captainshured/captainshured.mob":
			["newmonsters_heaven_captainshured_captainshured", 10, [3, 4, 0, 2]],
	}
	for mob: String in banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		check(String(definition.get("bank", "")) == banks[mob][0]
			and game.combat_assets.get("monsters", {}).has(banks[mob][0]),
			"Gent East Gate source bank is compiled: " + mob)
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
	check(bgm.get("dungeons", {}).get("genteastgate", {}).get("normal") == "gentgate_east"
		and bgm.get("dungeons", {}).get("genteastgate", {}).get("boss") == "gentgate_east_boss",
		"Gent East Gate maps its source normal and boss tracks")
	check(not bgm.get("source_gaps", {}).has("genteastgate"),
		"Gent East Gate has no unresolved MAP music cue")

	var flow := FlowSession.new()
	flow.profile["level"] = 59
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "genteastgate"})["ok"],
		"flow departs the hidden Gent East Gate route")
	route = flow.active_dungeon_route()
	NativePotMonsters.reset_catalog()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live Gent East Gate run selects hell-base block 1")
	NativePotMonsters.prepare_catalog(dungeon, SourceRolls.new([0, 0, 0, 0]))
	check(session._validate_native_maze(probe, live_maze),
		"Gent East Gate room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "genteastgate", "route": route,
		"room_id": "genteastgate:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source Gent East Gate room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 13
			and game.view_snapshot()["hud"]["route"].size() == 13,
			"both public battle views report the complete thirteen-room Gent East graph")
		check(game.view.audio.has_dungeon_music("genteastgate")
			and String(game.view.audio.music.stream.resource_path).ends_with("gentgate_east.ogg"),
			"Gent East Gate starts with the source M_GENTGATE_EAST track")

		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts,
			"Gent East Gate start room spawns its exact source monster lineup")

		var interactive_props := 0
		var all_gaps := {}
		for path in game.native_maze.required_map_paths():
			var room: Dictionary = probe.room(path)
			var room_props: Array = game.build_props(room)
			interactive_props += room_props.size()
			for path_key: String in game.native_object_gaps:
				if not all_gaps.has(path_key):all_gaps[path_key] = []
				for gap in game.native_object_gaps[path_key]:
					if gap not in all_gaps[path_key]:all_gaps[path_key].append(gap)
		check(interactive_props == 0,
			"Gent East Gate does not materialise lamp/fruit-sack objects without native sources")
		check(all_gaps.get("passiveobject/actionobject/breakableobject/smalllamp.obj", [])
			== ["native_breakable_source"]
			and all_gaps.get("passiveobject/actionobject/breakableobject/roadlamp.obj", [])
			== ["native_breakable_source"]
			and all_gaps.get("passiveobject/actionobject/breakableobject/roadlamp_half.obj", [])
			== ["native_breakable_source"],
			"small/road lamp variants remain explicit breakable-source gaps")
		var sack_gaps: Array = all_gaps.get(
			"passiveobject/actionobject/breakableobject/fruitsack2.obj", [])
		check("native_breakable_source" in sack_gaps and "native_special_object" in sack_gaps,
			"fruit sacks preserve breakable/special-object gaps with their source trap IDs "
			+ "(actual=%s)" % str(sack_gaps))
		check(all_gaps.get("passiveobject/actionobject/trap/spidermine.obj", [])
			== ["native_object_trigger"],
			"spider mines remain explicit behavior triggers")
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_GENTEASTGATE] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
