extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const DUNGEONS := "res://data/dungeons.json"

var session := CombatSession.new()
var game
var checks := 0
var failures := 0
var audited_rooms := 0
var blocker_total := 0
var do_not_pass_total := 0
var float_pass_total := 0
var breakable_total := 0
var trap_total := 0
var obstacle_total := 0
var blocker_paths := {}
var tested_paths := {}

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("[WS1_WORLD_COLLISIONS] FAIL " + label)

func run() -> void:
	var dungeons: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string(DUNGEONS)
	)["dungeons"]
	game = session.mount(root)
	game.set_process(false)
	game.set_physics_process(false)
	check(not game.missing_assets, "production combat content and assets load")
	if not game.missing_assets:
		var ids: Array = dungeons.keys()
		ids.sort()
		for dungeon_id: String in ids:
			var route: Dictionary = dungeons[dungeon_id]
			if bool(route.get("legacy", false)) or bool(route.get("hidden", false)):
				continue
			audit_dungeon(dungeon_id, route)
		test_breakable_blocker_restore(dungeons)
		test_player_motion_contract(dungeons)
	check(audited_rooms == 107, "all 107 rooms in the 17 visible dungeons were audited")
	check(blocker_total == 1218, "all 1218 source ground footprints are counted")
	check(do_not_pass_total == 1189, "all source do-not-pass footprints are counted")
	check(float_pass_total == 29, "all source float-only footprints are counted")
	check(breakable_total == 553, "all blocking breakable footprints are counted")
	check(trap_total == 289, "all blocking trap footprints are counted")
	check(obstacle_total == 376, "all blocking obstacle footprints are counted")
	check(blocker_paths.size() == 63, "all 63 blocking source object paths are covered")
	check(tested_paths.size() == blocker_paths.size(), "every blocking source path is exercised")
	session.stop()
	await process_frame
	print("[WS1_WORLD_COLLISIONS] COMPLETE checks=%d failures=%d rooms=%d blockers=%d breakable=%d trap=%d obstacle=%d" % [
		checks, failures, audited_rooms, blocker_total, breakable_total, trap_total, obstacle_total
	])
	quit(0 if failures == 0 else 1)

func audit_dungeon(dungeon_id: String, route: Dictionary) -> void:
	var spec := {
		"run_id": "ws1-world-collisions-" + dungeon_id,
		"dungeon": dungeon_id,
		"route": route,
		"room_id": dungeon_id + ":0",
		"room_index": 0,
		"player": {"hp": 500, "mp": 200, "weapon": "shortsword", "skill_slots": []},
		"audio": {"muted": true},
	}
	check(session.start_room(spec), "formal route accepts " + dungeon_id)
	if game.room_index != 0 or game.missing_assets:
		return
	for index in (route.get("rooms", []) as Array).size():
		if index > 0:
			game.load_room(index, "start")
		check_room(dungeon_id, index)

func check_room(dungeon_id: String, index: int) -> void:
	audited_rooms += 1
	var expected := {}
	var source_objects: Array = game.room_map.get("objects", [])
	for object_index in source_objects.size():
		var item: Dictionary = source_objects[object_index]
		if not is_source_blocker(item):
			continue
		expected[object_index] = item
		var anchor: Array = item["anchor"]
		var width: Array = item["width"]
		var pos := Vector2(float(anchor[0]), float(anchor[1]))
		var size := Vector2(float(width[0]), float(width[1]))
		var rect := Rect2(pos.x-size.x*0.5, pos.y-size.y, size.x, size.y)
		var center := rect.get_center()
		var pass_type := String(item["pass_type"])
		var path := String(item["obj"]).to_lower()
		blocker_total += 1
		blocker_paths[path] = true
		if pass_type == "[do not pass]":
			do_not_pass_total += 1
		else:
			float_pass_total += 1
		if path.contains("breakableobject/"):
			breakable_total += 1
		elif path.contains("/trap/"):
			trap_total += 1
		elif path.contains("/obstacle/"):
			obstacle_total += 1
	var actual := {}
	for blocker: Dictionary in game.room_blockers:
		actual[int(blocker["node"])] = blocker
	var label := "%s room %d" % [dungeon_id, index+1]
	check(actual.size() == expected.size(), label + " builds exactly its source blockers")
	for node: int in expected:
		check(actual.has(node), label + " builds blocker node " + str(node))
		if not actual.has(node):
			continue
		var item: Dictionary = expected[node]
		var blocker: Dictionary = actual[node]
		var anchor: Array = item["anchor"]
		var width: Array = item["width"]
		var pos := Vector2(float(anchor[0]), float(anchor[1]))
		var size := Vector2(float(width[0]), float(width[1]))
		check(blocker["collision"] == Rect2(pos.x-size.x*0.5, pos.y-size.y, size.x, size.y),
			label + " preserves blocker footprint at node " + str(node))
		check(String(blocker["source_path"]) == String(item["obj"]).to_lower(),
			label + " preserves blocker source path at node " + str(node))
		var center: Vector2 = (blocker["collision"] as Rect2).get_center()
		check(game.blocker_blocks_at(blocker, center, 0.0),
			label + " blocks source footprint at node " + str(node))
		check(game.blocker_blocks_at(blocker, center, 1.0) == (String(blocker["pass_type"]) == "[do not pass]"),
			label + " keeps source height policy at node " + str(node))
		var path := String(blocker["source_path"])
		if tested_paths.has(path):
			continue
		test_path(node, path)

func test_path(node: int, path: String) -> void:
	tested_paths[path] = true
	var blocker: Dictionary = {}
	for candidate: Dictionary in game.room_blockers:
		if int(candidate["node"]) == node:
			blocker = candidate
			break
	if blocker.is_empty():
		return
	var center: Vector2 = (blocker["collision"] as Rect2).get_center()
	var prop: Dictionary = {}
	for candidate: Dictionary in game.props:
		if int(candidate["node"]) == node:
			prop = candidate
			break
	if prop.is_empty() or not bool(prop.get("breakable", false)):
		check(game.blocker_blocks_at(blocker, center, 0.0), path + " remains a static ground blocker")
		return
	var overlapping: Array = game.room_blockers.filter(func(item):
		return bool(item["active"]) and (item["collision"] as Rect2).has_point(center))
	if overlapping.size() != 1:
		return
	var amount := int(prop["hp"]) * int(prop["stages"])
	var destroyed: bool = game.apply_legacy_prop_damage(prop, amount)
	if bool(prop["destroy_on_final_stage"]):
		check(destroyed, path + " can be destroyed")
		check(not game.blocker_blocks_at(blocker, center, 0.0), path + " stops blocking after destruction")
	else:
		check(not destroyed and game.blocker_blocks_at(blocker, center, 0.0),
			path + " preserves its source non-destroy final stage")

func test_breakable_blocker_restore(dungeons: Dictionary) -> void:
	var dungeon_id := "lorien_inside"
	var route: Dictionary = dungeons[dungeon_id]
	var spec := {
		"run_id": "ws1-world-collisions-snapshot",
		"dungeon": dungeon_id,
		"route": route,
		"room_id": dungeon_id + ":0",
		"room_index": 0,
		"player": {"hp": 500, "mp": 200, "weapon": "shortsword", "skill_slots": []},
		"audio": {"muted": true},
	}
	check(session.start_room(spec), "blocker snapshot fixture starts its formal route")
	game.load_room(1, "start")
	var blocker: Dictionary = {}
	for candidate: Dictionary in game.room_blockers:
		if String(candidate["source_path"]).contains("breakableobject/"):
			blocker = candidate
			break
	check(not blocker.is_empty(), "blocker snapshot fixture finds a source breakable")
	if blocker.is_empty():
		return
	var node := int(blocker["node"])
	var center: Vector2 = (blocker["collision"] as Rect2).get_center()
	var prop: Dictionary = {}
	for candidate: Dictionary in game.props:
		if int(candidate["node"]) == node:
			prop = candidate
			break
	check(not prop.is_empty(), "blocker snapshot fixture finds its runtime prop")
	if prop.is_empty():
		return
	game.apply_legacy_prop_damage(prop, int(prop["hp"]) * int(prop["stages"]))
	game.load_room(game.room_index, "start")
	var restored: Dictionary = {}
	for candidate: Dictionary in game.room_blockers:
		if int(candidate["node"]) == node:
			restored = candidate
			break
	check(not restored.is_empty() and not bool(restored["active"]),
		"reloading a room restores the destroyed blocker as inactive")
	check(not restored.is_empty() and not game.blocker_blocks_at(restored, center, 0.0),
		"restored destroyed blocker no longer blocks movement")

func test_player_motion_contract(dungeons: Dictionary) -> void:
	var dungeon_id := "lorien"
	var route: Dictionary = dungeons[dungeon_id]
	var spec := {
		"run_id": "ws1-world-collisions-motion",
		"dungeon": dungeon_id,
		"route": route,
		"room_id": dungeon_id + ":0",
		"room_index": 0,
		"player": {"hp": 500, "mp": 200, "weapon": "shortsword", "skill_slots": []},
		"audio": {"muted": true},
	}
	check(session.start_room(spec), "player collision fixture starts its formal route")
	var blocker: Dictionary = {}
	var start := Vector2.ZERO
	for candidate: Dictionary in game.room_blockers:
		if String(candidate["pass_type"]) != "[do not pass]":
			continue
		var rect: Rect2 = candidate["collision"]
		var center := rect.get_center()
		var from := Vector2(rect.position.x-2.0, center.y)
		if rect.size.x >= 8.0 and game.walkable(center) and game.ground_passable(from, 0.0):
			blocker = candidate
			start = from
			break
	check(not blocker.is_empty(), "player collision fixture finds a walkable source blocker")
	if blocker.is_empty():
		return
	var rect: Rect2 = blocker["collision"]
	game.player["pos"] = start
	game.player["z"] = 0.0
	game.move_along_ground_pixels(rect.size.x+8.0)
	check(Vector2(game.player["pos"]).x < rect.end.x,
		"pixel movement stops at the source blocker footprint")

func is_source_blocker(item: Dictionary) -> bool:
	var pass_type := str(item.get("pass_type", ""))
	if pass_type not in ["[do not pass]", "[pass only float type]"]:
		return false
	var anchor: Array = item.get("anchor", [])
	if anchor.size() < 2:
		return false
	if anchor.size() > 2 and float(anchor[2]) >= 100.0:
		return false
	var width: Array = item.get("width", [])
	return width.size() >= 2 and float(width[0]) > 0.0 and float(width[1]) > 0.0
