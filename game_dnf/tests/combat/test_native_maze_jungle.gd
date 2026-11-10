extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const FlowSession = preload("res://flow/session.gd")
const NativeMaze = preload("res://combat/data/native_maze.gd")
const NativeBoxLoot = preload("res://loot/native_box.gd")
const NativeJarTraps = preload("res://combat/resolve/native_jar_traps.gd")
const NativePotMonsters = preload("res://combat/resolve/native_pot_monsters.gd")
const DetRng = preload("res://core/det_rng.gd")
const EXPORT := "res://assets_local/native_maps/jungle_v1/map_export.json"

var session := CombatSession.new()
var game
var checks := 0
var failures := 0
var loot_events: Array[Dictionary] = []

class SourceRolls extends RefCounted:
	var values: Array[int]
	var index := 0
	func _init(sequence: Array[int]) -> void:values = sequence
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
		push_error("[NATIVE_MAZE_JUNGLE] FAIL " + label)

func run() -> void:
	game = session.mount(root)
	game.set_process(false)
	game.set_physics_process(false)
	session.prop_loot_released.connect(func(event: Dictionary):loot_events.append(event.duplicate(true)))
	var route: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/dungeons.json"))["dungeons"]["jungle"]
	var probe = game.map_loader.get_script().new()
	check(probe.load_export(String(route["map_export"])), "production jungle export loads")
	var maze := NativeMaze.new()
	var dungeon: Dictionary = probe.data["dungeon"]
	var size: Vector2i = maze._point(dungeon.get("size"))
	var cells: Dictionary = maze._read_cells(dungeon.get("cells"),size)
	var starts: Array = maze._read_endpoint_cells(dungeon.get("start_map_raw"),cells,"start_candidate")
	var bosses: Array = maze._read_endpoint_cells(dungeon.get("boss_map_raw"),cells,"boss_candidate")
	var specs: Dictionary = maze._read_specifications(dungeon.get("raw"),cells)
	check(cells.size() == 16 and starts.size() == 2 and bosses.size() == 2,
		"jungle source grid and both endpoint choices parse")
	check(not specs.is_empty(), "jungle source map specifications parse")
	var pools: Dictionary = maze._read_pools(dungeon,cells,starts[0],bosses[0]) if not starts.is_empty() and not bosses.is_empty() else {}
	check(pools.size() == 16, "every connected jungle cell has an eligible first-visit map pool "
		+ "(pools=%d error=%s)" % [pools.size(),maze.last_error])
	check(maze.start(probe.data,DetRng.new(1),route.get("source",{})), "generic native maze accepts jungle source")
	check(maze.room_count() == 16 and maze.required_map_paths().size() == 19,
		"jungle preflight exposes 16 connected rooms across 19 active-boss MAPs "
		+ "(rooms=%d maps=%d)" % [maze.room_count(),maze.required_map_paths().size()])
	for start_slot in 2:
		for boss_slot in 2:
			var endpoint_maze := NativeMaze.new()
			check(endpoint_maze.start(probe.data,SourceRolls.new([start_slot,boss_slot,0]),route.get("source",{})),
				"jungle start/boss choice %d/%d builds its run" % [start_slot,boss_slot])
			check(endpoint_maze.current_room().get("cell") == starts[start_slot]
				and endpoint_maze.room_count() == 16,
				"jungle endpoint %d/%d preserves the source start cell and all 16 rooms" % [start_slot,boss_slot])
	check(NativeBoxLoot.ready(probe.data["dungeon"]), "jungle box groups and item art resolve")
	check(NativeJarTraps.ready(game.combat_assets), "shared source jar trap assets resolve")
	var fixture := find_live_fixture(probe.data,route)
	check(not fixture.is_empty(), "a deterministic jungle run reaches source box and monster payloads")
	if fixture.is_empty():
		quit(1)
		return
	var flow := FlowSession.new()
	flow.profile["level"] = 28
	flow.profile["next_run"] = int(fixture["run_number"])
	check(flow.command("flow.depart",{"dungeon":"jungle"})["ok"], "flow departs the hidden jungle route")
	route = flow.active_dungeon_route()
	NativePotMonsters.reset_catalog()
	var live_maze := NativeMaze.new()
	check(live_maze.start(probe.data,DetRng.new(hash(String(flow.run["id"]))),route.get("source",{})),
		"live jungle run repeats the selected source maze")
	NativePotMonsters.prepare_catalog(probe.data["dungeon"],DetRng.new(hash(String(flow.run["id"])+":pot-catalog")))
	check(session._validate_native_maze(probe,live_maze),
		"jungle room, monster and object dependencies validate ("+session.last_start_error+")")
	var started := session.start_room({
		"run_id":flow.run["id"],"dungeon":"jungle","route":route,
		"room_id":"jungle:0","room_index":0,"player":flow.run["stats"],
		"audio":{"muted":false,"bgm_volume_db":-32.0},
	})
	check(started and game.native_maze != null and game.native_room.get("source_map_id",0) > 0,
		"public battle session starts a source jungle room (error=%s)" % session.last_start_error)
	if started:
		check(game.native_maze.room_count() == 16 and game.view_snapshot()["hud"]["route"].size() == 16,
			"both public battle views report the complete jungle graph")
		check(game.view.audio.has_dungeon_music("jungle") and String(game.view.audio.music.stream.resource_path).ends_with("dendroid.ogg"),
			"jungle start room uses the original M_DENDROID track")
		var source_counts := {}
		for enemy in game.room_map.get("monsters",[]):source_counts[enemy["mob"]] = 1 + int(source_counts.get(enemy["mob"],0))
		var live_counts := {}
		for enemy in game.monsters:live_counts[enemy["mob"]] = 1 + int(live_counts.get(enemy["mob"],0))
		check(source_counts == live_counts, "jungle room spawns its exact source monster lineup")
		for side in fixture["path"]:
			clear_room()
			game.player["pos"] = game.door_point(String(side))
			game.door_lock_ms = 0.0
			game.step_game(0.0)
		check(game.native_room.get("cell",Vector2i(-1,-1)) == Vector2i(int(fixture["target_cell"][0]),int(fixture["target_cell"][1])),
			"jungle source traversal reaches the selected payload MAP")
		var box_prop := find_prop(int(fixture["box_node"]))
		check(not box_prop.is_empty() and box_prop.get("box_items",[]).size() == int(fixture["box_draws"]),
			"source box releases its deterministic item draws")
		var pot_prop := find_prop(int(fixture["pot_node"]))
		check(not pot_prop.is_empty() and pot_prop.get("pot_monsters",[]).map(func(row):return row["mob"]) == fixture["roster"],
			"source monster pot prepares the original Dendroid roster")
		var atk: Dictionary = game.move_def("attack1")["hits"][0]["atk"]
		var box_items: Array = box_prop.get("box_items",[]).duplicate()
		prop_melee(box_prop["damage_boxes"][0].get_center(),atk,
			int(box_prop["hp"])*int(box_prop["native_breakable"]["stages"]))
		check(loot_events.size() == 1 and loot_events[0]["node"] == int(fixture["box_node"])
			and loot_events[0]["items"] == box_items,
			"breaking the live box emits its prepared original items once")
		var before_monsters: int = game.monsters.size()
		prop_melee(pot_prop["damage_boxes"][0].get_center(),atk,
			int(pot_prop["hp"])*int(pot_prop["native_breakable"]["stages"]))
		var spawned: Array = game.monsters.slice(before_monsters)
		check(spawned.size() == fixture["roster"].size()
			and spawned.map(func(row):return row["mob"]) == fixture["roster"]
			and spawned.all(func(row):return int(row["numeric"].values["level"]) == 31),
			"breaking the live monster pot releases the ordered source Dendroid roster "
			+ "(spawned=%s expected=%s levels=%s)" % [
				spawned.map(func(row):return row["mob"]),fixture["roster"],
				spawned.map(func(row):return int(row["numeric"].values["level"]))])
		var unresolved := {}
		for prop in game.props:
			for source_id in prop.get("unresolved_trap_ids",[]):unresolved[int(source_id)] = true
		check(not unresolved.is_empty() and not game.native_object_gaps.is_empty(),
			"unsupported source traps are recorded instead of silently executing")
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_JUNGLE] COMPLETE checks=%d failures=%d" % [checks,failures])
	quit(0 if failures == 0 else 1)

func find_live_fixture(export: Dictionary, route: Dictionary) -> Dictionary:
	var path := ["right","up","left","up","right","up","left"]
	var target_runs := 0
	var top_starts := 0
	var bottom_starts := 0
	var path_failures := 0
	var failure_detail := ""
	var box_runs := 0
	var monster_row_runs := 0
	var selected_runs := 0
	for number in range(1,500):
		var flow := FlowSession.new()
		flow.profile["level"] = 28
		flow.profile["next_run"] = number
		if not flow.command("flow.depart",{"dungeon":"jungle"})["ok"]:continue
		var maze := NativeMaze.new()
		if not maze.start(export,DetRng.new(hash(String(flow.run["id"]))),route.get("source",{})):continue
		if maze.current_room().get("cell") == Vector2i(0,3):top_starts += 1
		else:bottom_starts += 1
		if maze.current_room().get("cell") != Vector2i(0,3):continue
		for side in path:
			maze.clear_room(maze.current_room()["cell"],0)
			if maze.move(side).is_empty():
				path_failures += 1
				if failure_detail.is_empty():
					failure_detail = "cell=%s side=%s error=%s" % [maze.current_room().get("cell"),side,maze.last_error]
				break
		var current := maze.current_room()
		if current.get("cell") != Vector2i(0,0):continue
		var map_path := String(current.get("placement",{}).get("map",""))
		var room: Dictionary = export["dungeon"]["rooms"].get(map_path,{})
		target_runs += 1
		var run_id := String(flow.run["id"])
		NativePotMonsters.reset_catalog()
		NativePotMonsters.prepare_catalog(export["dungeon"],DetRng.new(hash(run_id+":pot-catalog")))
		var box_node := -1
		var box_draws := 0
		var pot_node := -1
		var roster_mobs: Array = []
		for node in (room.get("objects",[]) as Array).size():
			var item: Dictionary = room["objects"][node]
			var raw: Array = item.get("raw",[])
			var draws := 0
			if item.get("source_tag") == "[special passive object]" and raw.size() >= 11 and int(raw[0]) in [300,800]:
				var count := int(raw[4])
				if raw.size() == 5+6*count:
					for at in range(5,raw.size(),6):
						if raw[at] != "[item]":continue
						if int(raw[at+1]) != 0:continue
						draws = int(raw[at+2])
						if draws < 0 and at+3 < raw.size():draws = int(raw[at+3])
				if draws > 0 and box_node < 0:
					box_node = node
					box_draws = draws
			var roster: Array = NativePotMonsters.prepared(String(export["dungeon"]["sha256"]),String(room.get("sha256","")),node)
			if not NativePotMonsters.rows(item).is_empty():monster_row_runs += 1
			if not roster.is_empty() and pot_node < 0:
				pot_node = node
				roster_mobs = roster.map(func(row):return row["mob"])
		if box_node >= 0:box_runs += 1
		if not roster_mobs.is_empty():selected_runs += 1
		if box_node >= 0 and pot_node >= 0:
			return {"run_number":number,"map":map_path,"path":path,"target_cell":[0,0],
				"box_node":box_node,"box_draws":box_draws,"pot_node":pot_node,"roster":roster_mobs}
	print("[NATIVE_MAZE_JUNGLE] FIXTURE_SCAN top=%d bottom=%d path_fail=%d target=%d box=%d monster_rows=%d selected=%d detail=%s" % [
		top_starts,bottom_starts,path_failures,target_runs,box_runs,monster_row_runs,selected_runs,failure_detail])
	return {}

func find_prop(node: int) -> Dictionary:
	for prop: Dictionary in game.props:
		if int(prop["node"]) == node:return prop
	return {}

func clear_room() -> void:
	for enemy: Dictionary in game.monsters:
		enemy["hp"] = 0.0
	game.step_game(820.0)

func prop_melee(point: Vector3, atk: Dictionary, amount: int) -> void:
	game.player["pos"] = Vector2(point.x,point.y)
	game.player["z"] = point.z
	game.player["hits"].clear()
	var frame := {"start":0.0,"end":100.0,"boxes":[[-2,-2,-2,4,4,4]]}
	game.apply_player_hits({"hits":[{"kind":"boxes","atk":atk,"percent":0.0,"fixed":amount,
		"segments":[{"frames":[frame]}]}]},0.0,1.0)
	game.player["z"] = 0.0
