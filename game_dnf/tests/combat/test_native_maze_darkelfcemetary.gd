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
		push_error("[NATIVE_MAZE_DARKELFCEMETARY] FAIL " + label)

func run() -> void:
	game = session.mount(root)
	game.set_process(false)
	game.set_physics_process(false)
	var routes: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/dungeons.json"))["dungeons"]
	var route: Dictionary = routes["darkelfcemetary"]
	check(route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("region") == "noierfera"
		and int(route.get("min_level", 0)) == 39 and int(route.get("monster_level", 0)) == 42,
		"dark elf cemetery is a hidden level 39 Noierfera native-maze route with source basis level 42")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production dark elf cemetery export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/act4/darkelfcemetary.dgn"
		and dungeon.get("sha256") == "ee3566c5e528abf12e13edcd1721a18aaf4be8677e450222dccc113a472520b0",
		"dark elf cemetery export keeps the pinned DGN source identity")
	check(Array(dungeon.get("placements", [])).size() == 68
		and Dictionary(dungeon.get("rooms", {})).size() == 24
		and Dictionary(probe.data.get("images", {})).size() == 71,
		"dark elf cemetery export contains 68 greed-eligible placements, 24 MAPs and 71 source images")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	var errors: Array = diagnostics.filter(func(row): return row.get("level") == "error")
	var warnings: Array = diagnostics.filter(func(row): return row.get("level") == "warning")
	var infos: Array = diagnostics.filter(func(row): return row.get("level") == "info")
	var aa_warnings := 0
	for row: Dictionary in warnings:
		if row.get("code") == "cell_without_map" and String(row.get("detail", "")).contains(" code AA"):
			aa_warnings += 1
	check(errors.is_empty() and warnings.size() == 2 and aa_warnings == 2 and infos.size() == 24,
		"dark elf cemetery preserves two empty AA cells and 24 raw MAP tag reports")

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
	var boss_hunt_ids: Array[int] = []
	var hell_value = null
	var seal_id = null
	var seal_pos = null
	for span: Dictionary in dungeon.get("raw", []):
		if span.get("tag") == "[maze info]":maze_blocks += 1
		if span.get("tag") == "[quest connection]":quest_connections += 1
		if span.get("tag") == "[hell dungeon]":hell_value = span.get("values", [])
		if span.get("tag") == "[seal door map index]":seal_id = span.get("values", [])
		if span.get("tag") == "[seal door pos]":seal_pos = span.get("values", [])
		if span.get("tag") != "[boss room entrance condition]":continue
		for token in span.get("values", []):
			if token.size() >= 3 and int(token[2]) in [50073, 50074, 50075, 50076]:
				boss_hunt_ids.append(int(token[2]))
	check(cells.size() == 15 and starts.size() == 1 and bosses.size() == 1,
		"dark elf cemetery 5x3 grid exposes one start and one boss candidate")
	check(maze_blocks == 1 and quest_connections == 0 and spec_count == 11,
		"dark elf cemetery consumes its only ordinary layout and 11 fixed MAP rows")
	check(boss_hunt_ids == [50073, 50074, 50075, 50076],
		"boss gate hunt rows preserve four skeleton MOB IDs as an explicit behavior gap")
	check(hell_value != null and seal_id != null and seal_pos != null
		and int(hell_value[0][2]) == 1 and int(seal_id[0][2]) == 60020,
		"hell mode and seal door 60020 remain preserved raw instead of being silently enabled")

	var pools: Dictionary = maze._read_pools(dungeon, cells, starts[0], bosses[0])
	check(pools.size() == 13,
		"start/boss %s/%s reaches all 13 connected cells (pools=%d error=%s)"
		% [starts[0], bosses[0], pools.size(), maze.last_error])
	check(maze.start(probe.data, SourceRolls.new([0, 0, 0, 0]), route.get("source", {})),
		"generic native maze accepts dark elf cemetery ordinary layout")
	check(maze.room_count() == 13 and maze.required_map_paths().size() == 13,
		"dark elf cemetery preflight exposes 13 rooms across 13 source-fixed first-visit MAPs "
		+ "(rooms=%d maps=%d)" % [maze.room_count(), maze.required_map_paths().size()])
	check(NativeBoxLoot.ready(dungeon), "dark elf cemetery item groups and source art resolve")
	check(NativeJarTraps.ready(game.combat_assets), "shared source jar trap assets resolve")

	var source_monsters := {}
	var source_monster_count := 0
	var source_boss_rows := 0
	var source_pot_monster_rows := 0
	var source_pot_mobs := {}
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
				check(monster.get("mob") == "monster/drake/drake.mob",
					"the source boss row is Drake")
		for item: Dictionary in room.get("objects", []):
			source_object_count += 1
			if NativeBoxLoot.draw_count(item) > 0:
				source_box_objects += 1
			for child: Dictionary in NativePotMonsters.rows(item):
				source_pot_monster_rows += 1
				source_pot_mobs[String(child.get("mob", ""))] = true
			var path := String(item.get("obj", "")).to_lower()
			if NativeBreakable.supports(item):
				source_breakables += 1
			elif item.get("source_tag") == "[special passive object]":
				source_specials += 1
			elif path.contains("/trap/"):
				source_triggers += 1
			else:
				source_static += 1
	check(source_monsters.size() == 7 and source_monster_count == 200 and source_boss_rows == 1,
		"dark elf cemetery source has 200 direct placements, 7 MOBs and one Drake boss row")
	check(source_object_count == 536 and source_breakables == 260
		and source_specials == 0 and source_triggers == 0 and source_static == 276
		and source_box_objects == 111,
		"dark elf cemetery source has 536 objects: 260 breakables, 276 static obstacles "
		+ "and 111 item payload rows (objects=%d breakables=%d special=%d triggers=%d static=%d boxes=%d)"
		% [source_object_count, source_breakables, source_specials,
			source_triggers, source_static, source_box_objects])
	check(source_pot_monster_rows == 14 and source_pot_mobs.size() == 2,
		"dark elf cemetery special objects retain 14 source monster payload rows across 2 MOBs")
	for mob: String in source_monsters:
		check(not game.table.monster_by_mob(mob).is_empty(),
			"direct source MOB has runtime content: " + mob)
	for mob: String in source_pot_mobs:
		check(not game.table.monster_by_mob(mob).is_empty(),
			"special-object monster payload has runtime content: " + mob)

	var banks := {
		"monster/skeleton/skeleton.mob": ["skeleton_skeleton", 3],
		"monster/skeleton/stoneskeleton.mob": ["skeleton_stoneskeleton", 4],
		"monster/wraith/wraithspectress.mob": ["wraith_wraithspectress", 4],
		"monster/wraith/wraith.mob": ["wraith_wraith", 3],
		"monster/spirit/souleter.mob": ["spirit_souleter", 4],
		"monster/wraith/wraithlilith.mob": ["wraith_wraithlilith", 6],
		"monster/drake/drake.mob": ["drake_drake", 5],
	}
	for mob: String in banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		check(String(definition.get("bank", "")) == banks[mob][0]
			and game.combat_assets.get("monsters", {}).has(banks[mob][0]),
			"dark elf cemetery source bank is compiled: " + mob)
		check(Array(definition.get("moves", [])).size() == int(banks[mob][1]),
			"source attack slots compile for %s (moves=%d expected=%d)"
			% [mob, Array(definition.get("moves", [])).size(), int(banks[mob][1])])
		for move: Dictionary in Array(definition.get("moves", [])):
			if not move.has("atk_path"):continue
			check(not game.table.atk(String(move["atk_path"])).is_empty()
				and not Array(move.get("timeline", [])).is_empty(),
				"source attack motion and ATK compile together: " + mob)

	var flow := FlowSession.new()
	flow.profile["level"] = 42
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "darkelfcemetary"})["ok"],
		"flow departs the hidden dark elf cemetery route")
	route = flow.active_dungeon_route()
	NativePotMonsters.reset_catalog()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live dark elf cemetery run selects the ordinary layout")
	NativePotMonsters.prepare_catalog(dungeon, SourceRolls.new([0, 0, 0, 0]))
	check(session._validate_native_maze(probe, live_maze),
		"dark elf cemetery room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "darkelfcemetary", "route": route,
		"room_id": "darkelfcemetary:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source dark elf cemetery room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 13
			and game.view_snapshot()["hud"]["route"].size() == 13,
			"both public battle views report the complete dark elf cemetery graph")
		check(game.view.audio.has_dungeon_music("darkelfcemetary")
			and String(game.view.audio.music.stream.resource_path).ends_with("darkelf_amb.ogg"),
			"dark elf cemetery starts with the original DARKELF_AMB track")

		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts,
			"dark elf cemetery start room spawns its exact source monster lineup")

		var interactive_props := 0
		var box_props := 0
		var known_jar_ids := {}
		var unknown_ids: Array[int] = []
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
		unknown_ids.sort()
		check(interactive_props == 260,
			"all 260 source breakables build exactly once across 24 MAPs")
		check(box_props > 0 and box_props <= source_box_objects,
			"dark elf cemetery prepares source item-box draws (prepared=%d source=%d)"
			% [box_props, source_box_objects])
		check(known_jar_ids.is_empty(),
			"no partial jar branch executes when supported 2210 mixes with unknown trap IDs")
		check(unknown_ids == [2010, 2110, 2211, 2300, 2301, 2400, 2500, 2600],
			"unsupported dark elf cemetery trap IDs remain explicit: " + str(unknown_ids))
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_DARKELFCEMETARY] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
