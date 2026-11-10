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
		push_error("[NATIVE_MAZE_OUTERGENT] FAIL " + label)

func common_maps() -> Array[String]:
	return [
		"map/outergent/01start(2,2).map",
		"map/outergent/02easy1(1,2).map",
		"map/outergent/03easy1(3,2).map",
		"map/outergent/04normal1(1,1).map",
		"map/outergent/05normal1(3,3).map",
		"map/outergent/06normal1(1,0).map",
		"map/outergent/07normal1(3,4).map",
		"map/outergent/08normal1(0,0).map",
		"map/outergent/09normal1(4,4).map",
		"map/outergent/10hard(0,1).map",
		"map/outergent/11hard(4,3).map",
		"map/outergent/12bonus(2,0).map",
		"map/outergent/13bonus(2,4).map",
	]

func west_boss_maps() -> Array[String]:
	var result := common_maps()
	result.append("map/outergent/boss1(0,2).map")
	result.append("map/outergent/boss_not(4,2).map")
	return result

func east_boss_maps() -> Array[String]:
	var result := common_maps()
	result.append("map/outergent/boss_not(0,2).map")
	result.append("map/outergent/boss2(4,2).map")
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

func run() -> void:
	game = session.mount(root)
	game.set_process(false)
	game.set_physics_process(false)
	var routes: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/dungeons.json"))["dungeons"]
	var route: Dictionary = routes["outergent"]
	check(route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("name") == "根特周边" and route.get("region") == "gent"
		and int(route.get("min_level", 0)) == 55 and int(route.get("monster_level", 0)) == 58,
		"Outer Gent is a hidden level 55 Gent native-maze route with source basis level 58")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production Outer Gent export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/act7/outergent.dgn"
		and dungeon.get("sha256") == "246884645ad85315f63f144f86b1347fa52b4d8cc5df29006bccd2ff6d3dfdb7"
		and int(dungeon.get("index", -1)) == 80,
		"Outer Gent export keeps DGN index 80 and the pinned source identity")
	check(Array(dungeon.get("placements", [])).size() == 29
		and Dictionary(dungeon.get("rooms", {})).size() == 17
		and Dictionary(probe.data.get("images", {})).size() == 53,
		"Outer Gent export contains 29 greed-eligible placements, 17 MAPs and 53 source images")
	check(int(dungeon.get("maze_block_index", -1)) == 0
		and dungeon.get("maze_block_selection") == "hell_base"
		and Array(dungeon.get("maze_blocks", [])).size() == 1,
		"Outer Gent selects its single source hell-base block")
	var block: Dictionary = dungeon["maze_blocks"][0]
	var normalized_specs: Array = []
	for row in Array(block.get("map_specifications", [])):
		var normalized: Array = []
		for value in row:normalized.append(int(value))
		normalized_specs.append(normalized)
	check(normalized_specs == [
		[0, 1, 10059], [1, 1, 10053], [3, 3, 10054], [4, 3, 10060],
	] and Array(block.get("boss_map_specifications", [])).is_empty(),
		"Outer Gent preserves four normal specs and resolves two boss cells from endpoints "
		+ "(actual=%s)" % str(normalized_specs))

	var diagnostics: Array = probe.data.get("diagnostics", [])
	var errors: Array = diagnostics.filter(func(row): return row.get("level") == "error")
	var warnings: Array = diagnostics.filter(func(row): return row.get("level") == "warning")
	var infos: Array = diagnostics.filter(func(row): return row.get("level") == "info")
	check(errors.is_empty(), "Outer Gent export has no source image or ANI errors")
	check(warnings.size() == 152
		and warnings.filter(func(row): return row.get("code") == "cell_without_map").size() == 10
		and warnings.filter(func(row): return row.get("code") == "object_unrendered").size() == 142,
		"Outer Gent preserves ten AA cells and 142 source-only object warnings")
	check(infos.size() == 17
		and infos.filter(func(row): return row.get("code") == "unhandled_tags").size() == 17,
		"Outer Gent preserves seventeen unhandled MAP tag notices")

	var maze := NativeMaze.new()
	var size: Vector2i = maze._point(dungeon.get("size"))
	var cells: Dictionary = maze._read_cells(dungeon.get("cells"), size)
	var starts: Array = maze._read_endpoint_cells(dungeon.get("start_map_raw"), cells, "start_candidate")
	var bosses: Array = maze._read_endpoint_cells(dungeon.get("boss_map_raw"), cells, "boss_candidate")
	var specs: Dictionary = maze._read_specifications(dungeon.get("raw"), cells, 0)
	check(cells.size() == 25 and starts.size() == 1 and bosses.size() == 2,
		"Outer Gent 5x5 source grid exposes one start and two boss candidates")
	check(starts[0] == Vector2i(2, 2) and bosses == [Vector2i(0, 2), Vector2i(4, 2)],
		"Outer Gent source endpoints preserve west/east boss order")
	check(cells.values().filter(func(cell): return not cell.get("doors", []).is_empty()).size() == 15
		and cells.values().filter(func(cell): return cell.get("code") == "AA").size() == 10,
		"Outer Gent base block has 15 connected cells and ten empty AA cells")
	check(specs.get("normal", {}).size() == 4 and specs.get("boss", {}).is_empty(),
		"Outer Gent preserves four normal specifications")

	var maze_west := NativeMaze.new()
	check(maze_west.start(probe.data, SourceRolls.new([0, 0]), route.get("source", {})),
		"native maze starts Outer Gent with the west boss roll")
	check(maze_west.current_room().get("cell") == Vector2i(2, 2)
		and maze_west.current_room().get("source_map_id") == 10050,
		"Outer Gent start resolves MAP 10050 at cell (2,2)")
	check(maze_west._boss == Vector2i(0, 2) and maze_west.room_count() == 15
		and maze_west.required_map_paths().size() == 15,
		"west-boss run exposes fifteen rooms from fifteen required MAPs")
	var west_required := {}
	for path in maze_west.required_map_paths():west_required[path] = true
	for path in west_boss_maps():check(west_required.has(path), "west boss run retains MAP: " + path)
	check(west_required.has("map/outergent/boss_not(4,2).map")
		and not west_required.has("map/outergent/boss2(4,2).map"),
		"west boss run converts the east boss cell to its normal boss_not MAP")

	var maze_east := NativeMaze.new()
	check(maze_east.start(probe.data, SourceRolls.new([0, 1]), route.get("source", {})),
		"native maze starts Outer Gent with the east boss roll")
	check(maze_east._boss == Vector2i(4, 2) and maze_east.room_count() == 15
		and maze_east.required_map_paths().size() == 15,
		"east-boss run exposes fifteen rooms from fifteen required MAPs")
	var east_required := {}
	for path in maze_east.required_map_paths():east_required[path] = true
	for path in east_boss_maps():check(east_required.has(path), "east boss run retains MAP: " + path)
	check(east_required.has("map/outergent/boss_not(0,2).map")
		and not east_required.has("map/outergent/boss1(0,2).map"),
		"east boss run converts the west boss cell to its normal boss_not MAP")

	var all_maps: Array[String] = []
	for path: String in dungeon.get("rooms", {}):
		all_maps.append(path)
	var all_source := aggregate_source(dungeon, all_maps)
	check(all_source["monsters"].size() == 6 and all_source["monster_count"] == 149
		and all_source["boss_rows"] == 2,
		"Outer Gent source has 149 direct monsters, six MOBs and two boss rows")
	check(all_source["object_count"] == 186,
		"Outer Gent source has 186 objects across both boss branches")
	var west_source := aggregate_source(dungeon, west_boss_maps())
	var east_source := aggregate_source(dungeon, east_boss_maps())
	check(west_source["monster_count"] == 131 and west_source["boss_rows"] == 1
		and west_source["object_count"] == 160 and west_source["tags"] == {
			"[passive object]": 158, "[special passive object]": 2,
		}, "west boss run carries 131 monsters and 160 objects")
	check(east_source["monster_count"] == 131 and east_source["boss_rows"] == 1
		and east_source["object_count"] == 153 and east_source["tags"] == {
			"[passive object]": 151, "[special passive object]": 2,
		}, "east boss run carries 131 monsters and 153 objects")

	var west_breakables := 0
	var west_runtime := 0
	var west_unrendered := 0
	for path in west_boss_maps():
		for item: Dictionary in dungeon["rooms"][path].get("objects", []):
			if item.get("sprite") == null:west_unrendered += 1
			if NativeBreakable.supports(item):
				west_breakables += 1
				if not game.content.record(String(item.get("obj", "")).to_lower()).get("native_breakable", {}).is_empty():
					west_runtime += 1
	check(west_breakables == 73 and west_runtime == 0 and west_unrendered == 116,
		"west boss run has 73 source-only breakables and 43 source-only drum traps")
	var east_breakables := 0
	var east_runtime := 0
	var east_unrendered := 0
	for path in east_boss_maps():
		for item: Dictionary in dungeon["rooms"][path].get("objects", []):
			if item.get("sprite") == null:east_unrendered += 1
			if NativeBreakable.supports(item):
				east_breakables += 1
				if not game.content.record(String(item.get("obj", "")).to_lower()).get("native_breakable", {}).is_empty():
					east_runtime += 1
	check(east_breakables == 72 and east_runtime == 0 and east_unrendered == 109,
		"east boss run has 72 source-only breakables and 37 source-only drum traps")
	check(not NativeBoxLoot.required(dungeon),
		"Outer Gent has no executable special-object item groups")
	check(NativeJarTraps.ready(game.combat_assets), "shared source jar trap assets resolve")

	var banks := {
		"monster/newmonsters/cartel/normalsoldier/normalsoldier.mob":
			["newmonsters_cartel_normalsoldier_normalsoldier", 2, [1, 0]],
		"monster/newmonsters/cartel/incendiarysoldier/incendiarysoldier.mob":
			["newmonsters_cartel_incendiarysoldier_incendiarysoldier", 2, [1, 0]],
		"monster/newmonsters/cartel/minorsoldier/minorsoldier.mob":
			["newmonsters_cartel_minorsoldier_minorsoldier", 1, [0]],
		"monster/newmonsters/heaven/nife_claese/nife_claese.mob":
			["newmonsters_heaven_nife_claese_nife_claese", 3, [0, 1]],
		"monster/newmonsters/cartel/spy/spy.mob":
			["newmonsters_cartel_spy_spy", 2, [0]],
		"monster/newmonsters/heaven/letsburn_bentinck/bentinck.mob":
			["newmonsters_heaven_letsburn_bentinck_bentinck", 12, []],
	}
	for mob: String in banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		check(String(definition.get("bank", "")) == banks[mob][0]
			and game.combat_assets.get("monsters", {}).has(banks[mob][0]),
			"Outer Gent source bank is compiled: " + mob)
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
	check(bgm.get("dungeons", {}).get("outergent", {}).get("normal") == "gentgate_outside"
		and bgm.get("dungeons", {}).get("outergent", {}).get("boss") == "gentgate_outside_boss",
		"Outer Gent maps its source normal and boss tracks")
	check(not bgm.get("source_gaps", {}).has("outergent"),
		"Outer Gent has no unresolved MAP music cue")

	var flow := FlowSession.new()
	flow.profile["level"] = 58
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "outergent"})["ok"],
		"flow departs the hidden Outer Gent route")
	route = flow.active_dungeon_route()
	NativePotMonsters.reset_catalog()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live Outer Gent run selects its hell-base block and boss branch")
	NativePotMonsters.prepare_catalog(dungeon, SourceRolls.new([0, 0, 0, 0]))
	check(session._validate_native_maze(probe, live_maze),
		"Outer Gent room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "outergent", "route": route,
		"room_id": "outergent:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source Outer Gent room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 15
			and game.view_snapshot()["hud"]["route"].size() == 15,
			"both public battle views report the complete fifteen-room Outer Gent graph")
		check(game.view.audio.has_dungeon_music("outergent")
			and String(game.view.audio.music.stream.resource_path).ends_with("gentgate_outside.ogg"),
			"Outer Gent starts with the source M_GENTGATE_OUTSIDE track")

		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts,
			"Outer Gent start room spawns its exact source monster lineup")

		var interactive_props := 0
		var all_gaps := {}
		var selected_paths: Array[String] = []
		for path in game.native_maze.required_map_paths():selected_paths.append(path)
		for path in selected_paths:
			var room: Dictionary = probe.room(path)
			var room_props: Array = game.build_props(room)
			interactive_props += room_props.size()
			for path_key: String in game.native_object_gaps:
				if not all_gaps.has(path_key):all_gaps[path_key] = []
				for gap in game.native_object_gaps[path_key]:
					if gap not in all_gaps[path_key]:all_gaps[path_key].append(gap)
		check(interactive_props == 0,
			"Outer Gent does not materialise lamp/APC/fruit-sack objects without native sources")
		check(all_gaps.get("passiveobject/actionobject/breakableobject/smalllamp.obj", [])
			== ["native_breakable_source"]
			and all_gaps.get("passiveobject/actionobject/breakableobject/roadlamp.obj", [])
			== ["native_breakable_source"]
			and all_gaps.get("passiveobject/actionobject/breakableobject/roadlamp_half.obj", [])
			== ["native_breakable_source"],
			"small/road lamp variants remain explicit breakable-source gaps")
		check(all_gaps.get("passiveobject/actionobject/breakableobject/jailapc.obj", [])
			== ["native_breakable_source"],
			"jail APC remains an explicit breakable-source gap")
		var sack_gaps: Array = all_gaps.get(
			"passiveobject/actionobject/breakableobject/fruitsack2.obj", [])
		check("native_breakable_source" in sack_gaps and "native_special_object" in sack_gaps,
			"fruit sacks preserve breakable/special-object gaps with their source trap IDs "
			+ "(actual=%s)" % str(sack_gaps))
		check(all_gaps.get("passiveobject/actionobject/trap/drumtong.obj", [])
			== ["native_object_trigger"],
			"drum tongue objects remain explicit behavior triggers")
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_OUTERGENT] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
