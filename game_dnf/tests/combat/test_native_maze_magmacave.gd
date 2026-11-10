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
		push_error("[NATIVE_MAZE_MAGMACAVE] FAIL " + label)

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
	var route: Dictionary = routes["magmacave"]
	check(route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("region") == "noierfera"
		and int(route.get("min_level", 0)) == 40 and int(route.get("monster_level", 0)) == 43,
		"magma cave is a hidden level 40 Noierfera native-maze route with source basis level 43")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production magma cave export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/act4/magmacave.dgn"
		and dungeon.get("sha256") == "5b47aac76324fb52d63eedb834b5f32bb7cfd1cedba610ce9fccf12873d775e8",
		"magma cave export keeps the pinned DGN source identity")
	check(Array(dungeon.get("placements", [])).size() == 48
		and Dictionary(dungeon.get("rooms", {})).size() == 15
		and Dictionary(probe.data.get("images", {})).size() == 88,
		"magma cave export contains 48 greed-eligible placements, 15 MAPs and 88 source images")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	var errors: Array = diagnostics.filter(func(row): return row.get("level") == "error")
	var warnings: Array = diagnostics.filter(func(row): return row.get("level") == "warning")
	var infos: Array = diagnostics.filter(func(row): return row.get("level") == "info")
	var aa_warnings := 0
	var unrendered := 0
	for row: Dictionary in warnings:
		if row.get("code") == "cell_without_map" and String(row.get("detail", "")).contains(" code AA"):
			aa_warnings += 1
		if row.get("code") == "object_unrendered":
			unrendered += 1
	check(errors.is_empty() and warnings.size() == 11 and aa_warnings == 10
		and unrendered == 1 and infos.size() == 15,
		"magma cave preserves ten empty AA cells, one unrendered bomb and 15 raw MAP reports")

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
	check(cells.size() == 24 and starts.size() == 1 and bosses.size() == 1,
		"magma cave 3x8 grid exposes one start and one boss candidate")
	check(maze_blocks == 2 and quest_connections == 1 and spec_count == 12,
		"magma cave consumes only the first layout and preserves quest 4417 as raw")
	check(hell_value != null and seal_id != null and seal_pos != null
		and int(hell_value[0][2]) == 1 and int(seal_id[0][2]) == 60020,
		"hell mode and seal door 60020 remain preserved raw instead of being silently enabled")

	var pools: Dictionary = maze._read_pools(dungeon, cells, starts[0], bosses[0])
	check(pools.size() == 14,
		"start/boss %s/%s reaches all 14 connected cells (pools=%d error=%s)"
		% [starts[0], bosses[0], pools.size(), maze.last_error])
	check(maze.start(probe.data, SourceRolls.new([0, 0, 0, 0]), route.get("source", {})),
		"generic native maze accepts magma cave ordinary layout")
	check(maze.room_count() == 14 and maze.required_map_paths().size() == 14,
		"magma cave preflight exposes 14 rooms across 14 source-fixed first-visit MAPs "
		+ "(rooms=%d maps=%d)" % [maze.room_count(), maze.required_map_paths().size()])
	check(NativeBoxLoot.ready(dungeon), "magma cave item groups and source art resolve")
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
				check(String(monster.get("mob", "")) in [
					"monster/magma/bossatlas.mob", "monster/magma/bossgoliath.mob",
					"monster/magma/bosstitan.mob",
				], "every source boss row is an Atlas/Goliath/Titan boss variant")
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
	check(source_monsters.size() == 15 and source_monster_count == 113 and source_boss_rows == 3,
		"magma cave source has 113 direct placements, 15 MOBs and three boss rows")
	check(source_object_count == 120 and source_breakables == 68
		and source_specials == 0 and source_triggers == 25 and source_static == 27
		and source_box_objects == 37,
		"magma cave source has 120 objects: 68 breakables, 25 swamp triggers, "
		+ "27 static obstacles and 37 item payload rows "
		+ "(objects=%d breakables=%d special=%d triggers=%d static=%d boxes=%d)"
		% [source_object_count, source_breakables, source_specials,
			source_triggers, source_static, source_box_objects])
	check(source_pot_monster_rows == 8 and source_pot_mobs.size() == 4,
		"magma cave special objects retain 8 source monster payload rows across 4 MOBs")
	for mob: String in source_monsters:
		check(not game.table.monster_by_mob(mob).is_empty(),
			"direct source MOB has runtime content: " + mob)
	for mob: String in source_pot_mobs:
		check(not game.table.monster_by_mob(mob).is_empty(),
			"special-object monster payload has runtime content: " + mob)

	var banks := {
		"monster/magma/magma_ghoul.mob": ["magma_magma_ghoul", 0],
		"monster/spirit/firespirit.mob": ["spirit_firespirit", 2],
		"monster/magma/burninghella.mob": ["magma_burninghella", 2],
		"monster/ghoul/ghoulthrower.mob": ["ghoul_ghoulthrower", 2],
		"monster/magma/oilsellerolrek.mob": ["magma_oilsellerolrek", 2],
		"monster/ghoul/ghoul.mob": ["ghoul_ghoul", 0],
		"monster/spirit/souleter.mob": ["spirit_souleter", 4],
		"monster/ghoul/ghoulnomercy.mob": ["ghoul_ghoulnomercy", 2],
		"monster/ghoul/ghoulthrowerstand.mob": ["ghoul_ghoulthrowerstand", 2],
		"monster/magma/bossatlas.mob": ["magma_bossatlas", 3],
		"monster/magma/bossgoliath.mob": ["magma_bossgoliath", 2],
		"monster/magma/bosstitan.mob": ["magma_bosstitan", 3],
		"monster/magma/goliath.mob": ["magma_goliath", 2],
		"monster/magma/titan.mob": ["magma_titan", 3],
		"monster/magma/atlas.mob": ["magma_atlas", 3],
		"monster/magma/magma_ghoulstand.mob": ["magma_magma_ghoulstand", 0],
		"monster/ghoul/ghoulstand.mob": ["ghoul_ghoulstand", 0],
	}
	for mob: String in banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		check(String(definition.get("bank", "")) == banks[mob][0]
			and game.combat_assets.get("monsters", {}).has(banks[mob][0]),
			"magma cave source bank is compiled: " + mob)
		check(Array(definition.get("moves", [])).size() == int(banks[mob][1]),
			"source attack slots compile for %s (moves=%d expected=%d)"
			% [mob, Array(definition.get("moves", [])).size(), int(banks[mob][1])])
		if int(banks[mob][1]) == 0:
			check(not Array(definition.get("attack_timeline", [])).is_empty()
				and not Dictionary(definition.get("atk", {})).is_empty(),
				"single source attack compiles through the legacy timeline path: " + mob)
		for move: Dictionary in Array(definition.get("moves", [])):
			if not move.has("atk_path"):continue
			check(not game.table.atk(String(move["atk_path"])).is_empty()
				and not Array(move.get("timeline", [])).is_empty(),
				"source attack motion and ATK compile together: " + mob)

	var flow := FlowSession.new()
	flow.profile["level"] = 43
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "magmacave"})["ok"],
		"flow departs the hidden magma cave route")
	route = flow.active_dungeon_route()
	NativePotMonsters.reset_catalog()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})), "live magma cave run selects the ordinary layout")
	NativePotMonsters.prepare_catalog(dungeon, SourceRolls.new([0, 0, 0, 0]))
	check(session._validate_native_maze(probe, live_maze),
		"magma cave room, MOB and object dependencies validate (" + session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "magmacave", "route": route,
		"room_id": "magmacave:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts a source magma cave room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 14
			and game.view_snapshot()["hud"]["route"].size() == 14,
			"both public battle views report the complete magma cave graph")
		check(game.view.audio.has_dungeon_music("magmacave")
			and String(game.view.audio.music.stream.resource_path).ends_with("magma_cave.ogg"),
			"magma cave starts with the original M_MAGMA_CAVE track")

		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		var live_counts := {}
		for enemy in game.monsters:
			live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"], 0))
		check(source_counts == live_counts,
			"magma cave start room spawns its exact source monster lineup")

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
		check(interactive_props == 68,
			"all 68 source breakables build exactly once across 15 MAPs")
		check(box_props > 0 and box_props <= source_box_objects,
			"magma cave prepares source item-box draws (prepared=%d source=%d)"
			% [box_props, source_box_objects])
		check(known_jar_ids.is_empty(),
			"no partial jar branch executes when supported 2210/40002 mixes with unknown IDs")
		check(unknown_ids == [2000, 2001, 2010, 2011, 2012, 2100, 2101, 2110, 2111, 2112,
			2211, 2212, 2310, 2312, 2400, 2411, 2412, 2501, 2510, 2512, 2601, 2610, 2611, 2612],
			"unsupported magma cave trap IDs remain explicit: " + str(unknown_ids))
		check(all_gaps.get("passiveobject/boom/boom1.obj", []) == ["native_object_trigger"],
			"bomb object remains an explicit trigger gap")
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_MAGMACAVE] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
