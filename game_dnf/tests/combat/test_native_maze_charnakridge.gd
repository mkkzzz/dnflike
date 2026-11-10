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
		push_error("[NATIVE_MAZE_CHARNAKRIDGE] FAIL " + label)

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
	var route: Dictionary = routes["charnakridge"]
	check(route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("region") == "snowmt"
		and int(route.get("min_level", 0)) == 42 and int(route.get("monster_level", 0)) == 45,
		"charnak ridge is a hidden level 42 Snow Mountain native-maze route with source basis level 45")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production charnak ridge export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/act5/charnakridge.dgn"
		and dungeon.get("sha256") == "172e5364d6e341d5eb23da3fe53ffa2291863930744548990bf541fd80122349",
		"charnak ridge export keeps the pinned DGN source identity")
	check(Array(dungeon.get("placements", [])).size() == 16
		and Dictionary(dungeon.get("rooms", {})).size() == 11
		and Dictionary(probe.data.get("images", {})).size() == 82,
		"charnak ridge export contains 16 greed-eligible placements, 11 MAPs and 82 source images")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	var errors: Array = diagnostics.filter(func(row): return row.get("level") == "error")
	var warnings: Array = diagnostics.filter(func(row): return row.get("level") == "warning")
	var infos: Array = diagnostics.filter(func(row): return row.get("level") == "info")
	var aa_warnings := 0
	var unrendered := 0
	var empty_tiles := 0
	for row: Dictionary in warnings:
		if row.get("code") == "cell_without_map" and String(row.get("detail", "")).contains(" code AA"):
			aa_warnings += 1
		if row.get("code") == "object_unrendered":
			unrendered += 1
	for row: Dictionary in infos:
		if row.get("code") == "empty_tile":
			empty_tiles += 1
	check(errors.is_empty() and warnings.size() == 8 and aa_warnings == 6 and unrendered == 2
		and empty_tiles == 58 and infos.size() == 71,
		"charnak ridge normalizes 58 empty blocked tiles and preserves six AA and two snowfall warnings")

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
	var seal_pos = null
	for span: Dictionary in dungeon.get("raw", []):
		if span.get("tag") == "[maze info]":maze_blocks += 1
		if span.get("tag") == "[quest connection]":quest_connections += 1
		if span.get("tag") == "[hell dungeon]":hell_value = span.get("values", [])
		if span.get("tag") == "[seal door map index]":seal_id = span.get("values", [])
		if span.get("tag") == "[seal door pos]":seal_pos = span.get("values", [])
	check(cells.size() == 16 and starts.size() == 1 and bosses.size() == 1,
		"charnak ridge 4x4 grid exposes one start and one boss candidate")
	check(maze_blocks == 1 and quest_connections == 0 and spec_count == 2,
		"charnak ridge consumes its ordinary layout and two fixed MAP rows")
	check(hell_value != null and seal_id != null and seal_pos != null
		and int(hell_value[0][2]) == 1 and int(seal_id[0][2]) == 60029,
		"hell mode and seal door 60029 remain preserved raw instead of being silently enabled")

	var pools: Dictionary = maze._read_pools(dungeon, cells, starts[0], bosses[0])
	check(pools.size() == 10,
		"start/boss %s/%s reaches all 10 connected cells (pools=%d error=%s)"
		% [starts[0], bosses[0], pools.size(), maze.last_error])
	check(maze.start(probe.data, SourceRolls.new([0, 0, 0, 0]), route.get("source", {})),
		"generic native maze accepts charnak ridge ordinary layout")
	check(maze.room_count() == 10 and maze.required_map_paths().size() == 11,
		"charnak ridge preflight exposes 10 rooms across 11 eligible first-visit MAPs "
		+ "(rooms=%d maps=%d)" % [maze.room_count(), maze.required_map_paths().size()])
	check(not NativeBoxLoot.required(dungeon), "charnak ridge does not invent box item payloads")
	check(NativeJarTraps.ready(game.combat_assets), "shared source jar trap assets resolve")

	var source_monsters := {}
	var source_monster_count := 0
	var source_boss_rows := 0
	var source_object_count := 0
	var source_breakables := 0
	var source_triggers := 0
	var source_specials := 0
	var source_static := 0
	var source_box_objects := 0
	for room: Dictionary in dungeon.get("rooms", {}).values():
		for monster: Dictionary in room.get("monsters", []):
			source_monsters[String(monster.get("mob", ""))] = true
			source_monster_count += 1
			var raw: Array = monster.get("raw", [])
			if not raw.is_empty() and raw[-1] == "[boss]":
				source_boss_rows += 1
				check(String(monster.get("mob", "")) in [
					"monster/icetiger/shavante.mob", "monster/bantu/beastmasterlooger.mob",
				], "every source boss row is Shavante or Beastmaster Looger")
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
	check(source_monsters.size() == 11 and source_monster_count == 90 and source_boss_rows == 2,
		"charnak ridge source has 90 direct placements, 11 MOBs and two boss rows")
	check(source_object_count == 55 and source_breakables == 16
		and source_specials == 1 and source_triggers == 2 and source_static == 36
		and source_box_objects == 0,
		"charnak ridge source has 55 objects: 16 breakables, one unsupported item pocket, two snowfall triggers, "
		+ "36 static/particle objects and no item payload rows "
		+ "(objects=%d breakables=%d special=%d triggers=%d static=%d boxes=%d)"
		% [source_object_count, source_breakables, source_specials,
			source_triggers, source_static, source_box_objects])
	for mob: String in source_monsters:
		check(not game.table.monster_by_mob(mob).is_empty(),
			"direct source MOB has runtime content: " + mob)

	var banks := {
		"monster/bantu/bantufighter.mob": ["bantu_bantufighter", 3],
		"monster/bantu/bantuamazones.mob": ["bantu_bantuamazones", 5],
		"monster/goblin/snowmountain_flagseagab.mob": ["goblin_snowmountain_flagseagab", 0],
		"monster/icetiger/icetiger.mob": ["icetiger_icetiger", 3],
		"monster/bantu/bantuelite.mob": ["bantu_bantuelite", 4],
		"monster/spirit/waterspiritshisuke.mob": ["spirit_waterspiritshisuke", 3],
		"monster/bantu/bash.mob": ["bantu_bash", 5],
		"monster/bantu/emre.mob": ["bantu_emre", 6],
		"monster/bantu/labina.mob": ["bantu_labina", 4],
		"monster/icetiger/shavante.mob": ["icetiger_shavante", 9],
		"monster/bantu/beastmasterlooger.mob": ["bantu_beastmasterlooger", 6],
	}
	for mob: String in banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		check(String(definition.get("bank", "")) == banks[mob][0]
			and game.combat_assets.get("monsters", {}).has(banks[mob][0]),
			"charnak ridge source bank is compiled: " + mob)
		check(Array(definition.get("moves", [])).size() == int(banks[mob][1]),
			"source attack slots compile for %s (moves=%d expected=%d)"
			% [mob, Array(definition.get("moves", [])).size(), int(banks[mob][1])])
		if int(banks[mob][1]) == 0:
			check(not Array(definition.get("attack_timeline", [])).is_empty(),
				"single source attack compiles through the legacy timeline path: " + mob)
			if mob == "monster/goblin/snowmountain_flagseagab.mob":
				check(Dictionary(definition.get("atk", {})).is_empty(),
					"snow flag goblin keeps its empty source attack-info slot")
			else:
				check(not Dictionary(definition.get("atk", {})).is_empty(),
					"single source attack has a non-empty ATK: " + mob)
		for move: Dictionary in Array(definition.get("moves", [])):
			if not move.has("atk_path"):continue
			check(not game.table.atk(String(move["atk_path"])).is_empty()
				and not Array(move.get("timeline", [])).is_empty(),
				"source attack motion and ATK compile together: " + mob)

	var flow := FlowSession.new()
	flow.profile["level"] = 45
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "charnakridge"})["ok"],
		"flow departs the hidden charnak ridge route")
	route = flow.active_dungeon_route()
	check(not game.missing_assets,
		"charnak ridge mounted with all required runtime assets (" + String(game.missing_reason) + ")")
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live charnak ridge run selects the ordinary layout")
	check(session._validate_native_maze(probe, live_maze),
		"charnak ridge room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "charnakridge", "route": route,
		"room_id": "charnakridge:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source charnak ridge room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 10
			and game.view_snapshot()["hud"]["route"].size() == 10,
			"both public battle views report the complete charnak ridge graph")
		check(game.view.audio.has_dungeon_music("charnakridge")
			and String(game.view.audio.music.stream.resource_path).ends_with("charnakridge.ogg"),
			"charnak ridge starts with the original M_CHARNAKRIDGE track")

		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts,
			"charnak ridge start room spawns its exact source monster lineup")

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
		check(interactive_props == 16,
			"all 16 source-complete breakables build exactly once across 11 MAPs")
		check(box_props == 0, "charnak ridge creates no item-box props")
		check(known_jar_ids.is_empty(), "no jar branch executes for unsupported 2211")
		check(unknown_ids.is_empty(),
			"no executable prop leaves an unresolved trap outside the item-pocket gap")
		check(all_gaps.get("passiveobject/mapobject/breakableobject/itempocket.obj", [])
			== ["native_breakable_source", "native_special_object", 2211],
			"item pocket remains an explicit missing-contract and trap gap")
		for path in [
			"passiveobject/mapobject/trap/snowfallmanager1.obj",
			"passiveobject/mapobject/trap/snowfallmanager2.obj",
		]:
			check(all_gaps.get(path, []) == ["native_object_trigger"],
				"snowfall manager remains an explicit trigger gap: " + path)
		for path in [
			"passiveobject/mapobject/particlefactory/blizzard.obj",
			"passiveobject/mapobject/particlefactory/blizzard2.obj",
		]:
			check(all_gaps.get(path, []) == ["native_particle_factory"],
				"blizzard particle factory remains an explicit behavior gap: " + path)
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_CHARNAKRIDGE] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
