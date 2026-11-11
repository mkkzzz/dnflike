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
		push_error("[NATIVE_MAZE_TRAINING2] FAIL " + label)

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
	var route: Dictionary = routes["training2"]
	check(route.get("mode") == "native_maze" and bool(route.get("hidden", false))
		and route.get("name") == "月光修炼场" and route.get("region") == "noierfera"
		and int(route.get("min_level", 0)) == 48
		and int(route.get("monster_level", 0)) == 50,
		"Moonlight Training Ground is a hidden level 48/50 native route")

	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])),
		"production Moonlight Training Ground export loads")
	var dungeon: Dictionary = probe.data["dungeon"]
	check(dungeon.get("path") == "dungeon/quest/training2.dgn"
		and dungeon.get("sha256") == "92da771e3991f446d27948ca2747f300f9f4290159258fb869f0ec6af2088484"
		and int(dungeon.get("index", -1)) == 511,
		"Moonlight Training Ground keeps DGN index 511 and pinned source identity")
	check(Array(dungeon.get("placements", [])).size() == 2
		and Dictionary(dungeon.get("rooms", {})).size() == 2
		and Dictionary(probe.data.get("images", {})).size() == 40,
		"Moonlight Training Ground retains two rooms and 40 source images")
	check(int(dungeon.get("maze_block_index", -1)) == 0
		and dungeon.get("maze_block_selection") == "ordinary"
		and Array(dungeon.get("maze_blocks", [])).size() == 1,
		"Moonlight Training Ground selects its ordinary block")

	var diagnostics: Array = probe.data.get("diagnostics", [])
	check(diagnostics.filter(func(row): return row.get("level") == "error").is_empty(),
		"Moonlight Training Ground has no source image or ANI errors")
	check(diagnostics.filter(func(row): return row.get("code") == "object_unrendered").size() == 7,
		"Moonlight Training Ground preserves seven unrendered furniture objects")
	check(diagnostics.filter(func(row): return row.get("code") == "unhandled_tags").size() == 2,
		"Moonlight Training Ground preserves two MAP tag reports")

	var maze := NativeMaze.new()
	var size: Vector2i = maze._point(dungeon.get("size"))
	var cells: Dictionary = maze._read_cells(dungeon.get("cells"), size)
	var starts: Array = maze._read_endpoint_cells(dungeon.get("start_map_raw"), cells, "start_candidate")
	var bosses: Array = maze._read_endpoint_cells(dungeon.get("boss_map_raw"), cells, "boss_candidate")
	var specs: Dictionary = maze._read_specifications(dungeon.get("raw"), cells, 0)
	check(size == Vector2i(2, 1) and cells.size() == 2
		and starts == [Vector2i(1, 0)] and bosses == [Vector2i(0, 0)],
		"Moonlight Training Ground exposes its single start and boss cells")
	check(specs.get("normal", {}).get(Vector2i(1, 0)) == [15129]
		and specs.get("boss", {}).get(Vector2i(0, 0)) == [15270],
		"Moonlight Training Ground binds source MAPs 15129 and 15270")
	check(raw_values(dungeon.get("raw", []), "[limit party count]") == [1]
		and raw_values(dungeon.get("raw", []), "[designate dungeon difficulty]") == [0],
		"source single-player and fixed-difficulty fields are preserved")
	check(raw_values(dungeon.get("raw", []), "[champion]") == [6, 12, 18, 24, 26],
		"source champion thresholds remain raw")
	check(raw_values(dungeon.get("raw", []), "[pathgate object]")
		== [5540, 5541, 5542, 5543, 5544, 5545, 5546, 5547, 5548, 5549],
		"source pathgate object list remains intact")

	var start_path := "map/training2/15129training.map"
	var boss_path := "map/training2/15270training.map"
	var start_room: Dictionary = dungeon["rooms"][start_path]
	var boss_room: Dictionary = dungeon["rooms"][boss_path]
	check(room_role(start_room) == "[normal]" and room_role(boss_room) == "[boss]",
		"source MAP roles remain normal and boss")
	check(start_room.get("monsters", []).size() == 4 and boss_room.get("monsters", []).size() == 1,
		"source rooms retain four training targets and one Albert boss")
	check(String(boss_room["monsters"][0].get("mob", ""))
		== "monster/newmonsters/albert/albert.mob"
		and int(boss_room["monsters"][0].get("npc_id", -1)) == 1009
		and Array(boss_room["monsters"][0].get("raw", [])).size() == 12
		and boss_room["monsters"][0]["raw"][-1] == "[boss]",
		"Albert boss row preserves embedded NPC1009 and classification")
	var npc_spans: Array = boss_room.get("raw", []).filter(func(span): return span.get("tag") == "[NPC]")
	check(npc_spans.size() == 1,
		"boss MAP retains its independent NPC1000 row")

	var all_monsters := {}
	var all_monster_count := 0
	var all_boss_rows := 0
	var all_objects := []
	var all_breakable_rows := 0
	for room: Dictionary in dungeon.get("rooms", {}).values():
		for monster: Dictionary in room.get("monsters", []):
			all_monsters[String(monster.get("mob", ""))] = true
			all_monster_count += 1
			var raw: Array = monster.get("raw", [])
			if not raw.is_empty() and raw[-1] == "[boss]":
				all_boss_rows += 1
		for item: Dictionary in room.get("objects", []):
			all_objects.append(item)
			if NativeBreakable.supports(item):
				all_breakable_rows += 1
	check(all_monsters.size() == 3 and all_monster_count == 5 and all_boss_rows == 1,
		"Moonlight Training Ground retains five monsters across three MOBs")
	check(all_objects.size() == 10 and all_breakable_rows == 7,
		"Moonlight Training Ground retains ten objects and seven breakable-shaped furniture rows")
	var object_paths := {
		"passiveobject/actionobject/breakableobject/aganzo_chair.obj": 4,
		"passiveobject/actionobject/breakableobject/aganzo_namutong.obj": 3,
		"passiveobject/actionobject/obstacle/pubtable.obj": 3,
	}
	for path: String in object_paths:
		var count := 0
		for item: Dictionary in all_objects:
			if String(item.get("obj", "")).to_lower() == path:
				count += 1
		check(count == int(object_paths[path]),
			"source furniture count matches for " + path)
	for path: String in [
		"passiveobject/actionobject/breakableobject/aganzo_chair.obj",
		"passiveobject/actionobject/breakableobject/aganzo_namutong.obj",
	]:
		check(Dictionary(game.content.record(path).get("native_breakable", {})).is_empty(),
			"furniture remains an explicit missing source, not a guessed breakable: " + path)
	check(not NativeBoxLoot.required(dungeon),
		"Moonlight Training Ground has no DGN item drop group")

	var banks := {
		"monster/newmonsters/cartel/westcoast/rod_aradman/rod_aradman.mob":
			["newmonsters_cartel_westcoast_rod_aradman_rod_aradman", 2, [0, 1]],
		"monster/newmonsters/cartel/westcoast/special_rod_aradman/special_rod_aradman.mob":
			["newmonsters_cartel_westcoast_special_rod_aradman_special_rod_aradman", 2, [0, 1]],
		"monster/newmonsters/albert/albert.mob":
			["newmonsters_albert_albert", 7, [0, 1, 2, 3, 4, 5]],
	}
	for mob: String in banks:
		var kind: String = game.table.monster_by_mob(mob)
		var definition: Dictionary = game.table.monsters.get(kind, {})
		check(String(definition.get("bank", "")) == banks[mob][0]
			and game.combat_assets.get("monsters", {}).has(banks[mob][0]),
			"Moonlight Training Ground source bank is compiled: " + mob)
		var moves: Array = Array(definition.get("moves", []))
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
	check(_rule_skills(game.table.monsters[
		game.table.monster_by_mob("monster/newmonsters/cartel/westcoast/rod_aradman/rod_aradman.mob")
	]) == [1, 0]
		and _rule_skills(game.table.monsters[
		game.table.monster_by_mob(
			"monster/newmonsters/cartel/westcoast/special_rod_aradman/special_rod_aradman.mob")
		]) == [0, 1]
		and _rule_skills(game.table.monsters[
		game.table.monster_by_mob("monster/newmonsters/albert/albert.mob")
		]) == [0, 3],
		"source AI priorities remain indexed by the compiled move slots")
	check(NativeJarTraps.ready(game.combat_assets),
		"shared verified jar trap assets resolve")

	var bgm: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/bgm.json"))
	check(bgm.get("dungeons", {}).get("training2", {}).get("normal") == "aganzo"
		and bgm.get("dungeons", {}).get("training2", {}).get("boss") == "aganzo"
		and not bgm.get("source_gaps", {}).has("training2"),
		"Moonlight Training Ground uses its two source M_AGANZO room cues")

	var sample := NativeMaze.new()
	check(sample.start(probe.data, SourceRolls.new([0, 0, 0, 0]), route.get("source", {})),
		"generic native maze starts Moonlight Training Ground")
	check(sample.room_count() == 2
		and int(sample.current_room().get("source_map_id", 0)) == 15129,
		"Moonlight Training Ground starts in MAP15129 with one remaining boss room")
	var start_clear := sample.clear_room(Vector2i(1, 0), 0)
	var moved: Dictionary = sample.move("left")
	check(not start_clear.is_empty() and int(moved.get("source_map_id", 0)) == 15270,
		"clearing the training room enters MAP15270")
	var boss_clear := sample.clear_room(Vector2i(0, 0), 0)
	check(bool(boss_clear.get("boss", false)) and bool(boss_clear.get("final_room", false)),
		"Albert's room is the two-room route's final room")

	var flow := FlowSession.new()
	flow.profile["level"] = 60
	flow.profile["next_run"] = 1
	check(flow.command("flow.depart", {"dungeon": "training2"})["ok"],
		"flow departs the hidden Moonlight Training Ground route")
	route = flow.active_dungeon_route()
	NativePotMonsters.reset_catalog()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data, DetRng.new(hash(String(flow.run["id"]))),
		route.get("source", {})),
		"live Moonlight Training Ground run selects its source route")
	NativePotMonsters.prepare_catalog(dungeon, SourceRolls.new([0, 0, 0, 0]))
	check(session._validate_native_maze(probe, live_maze),
		"Moonlight Training Ground room, MOB and object dependencies validate ("
		+ session.last_start_error + ")")
	var started := session.start_room({
		"run_id": flow.run["id"], "dungeon": "training2", "route": route,
		"room_id": "training2:0", "room_index": 0, "player": flow.run["stats"],
		"audio": {"muted": false, "bgm_volume_db": -32.0},
	})
	check(started and game.native_maze != null,
		"public battle session starts Moonlight Training Ground (error=%s)"
		% session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 2
			and game.view_snapshot()["hud"]["route"].size() == 2,
			"both public battle views report the two-room graph")
		check(game.view.audio.has_dungeon_music("training2")
			and String(game.view.audio.music.stream.resource_path).ends_with("aganzo.ogg"),
			"Moonlight Training Ground starts with its source music")
		var source_counts := {}
		for enemy in game.room_map.get("monsters", []):
			source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"], 0))
		check(int(source_counts.get(
			"monster/newmonsters/cartel/westcoast/rod_aradman/rod_aradman.mob", 0)) == 2
			and int(source_counts.get(
				"monster/newmonsters/cartel/westcoast/special_rod_aradman/special_rod_aradman.mob",
				0)) == 2,
			"start room spawns two normal and two special training targets")
		var start_props: Array = game.build_props(start_room)
		var start_gaps: Dictionary = game.native_object_gaps.duplicate(true)
		var boss_props: Array = game.build_props(boss_room)
		var boss_gaps: Dictionary = game.native_object_gaps.duplicate(true)
		check(start_props.is_empty() and boss_props.is_empty(),
			"unrendered Aganzo furniture is not materialised as guessed props")
		check(start_gaps.get(
			"passiveobject/actionobject/breakableobject/aganzo_chair.obj", [])
			== ["native_breakable_source"]
			and boss_gaps.get(
				"passiveobject/actionobject/breakableobject/aganzo_namutong.obj", [])
			== ["native_breakable_source"],
			"Aganzo furniture retains explicit breakable-source gaps")
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_TRAINING2] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _rule_skills(definition: Dictionary) -> Array[int]:
	var result: Array[int] = []
	for rule: Dictionary in Array(definition.get("rules", [])):
		result.append(int(rule.get("skill", -1)))
	return result
