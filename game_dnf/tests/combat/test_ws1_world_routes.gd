extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const DUNGEONS := "res://data/dungeons.json"

var session := CombatSession.new()
var game
var checks := 0
var failures := 0
var completed_rooms := 0
var final_rooms := 0
var room_events: Array = []

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("[WS1_WORLD_ROUTES] FAIL " + label)

func run() -> void:
	var dungeons: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string(DUNGEONS)
	)["dungeons"]
	game = session.mount(root)
	game.set_process(false)
	game.set_physics_process(false)
	session.room_combat_finished.connect(func(event: Dictionary): room_events.append(event.duplicate(true)))
	check(not game.missing_assets, "production combat content and assets load")
	if not game.missing_assets:
		var ids: Array = dungeons.keys()
		ids.sort()
		for dungeon_id: String in ids:
			var route: Dictionary = dungeons[dungeon_id]
			if bool(route.get("legacy", false)) or bool(route.get("hidden", false)):
				continue
			audit_route(dungeon_id, route)
	check(completed_rooms == 107, "all 107 rooms complete their formal clear event")
	check(final_rooms == 17, "all 17 visible dungeons finish exactly once at the boss")
	session.stop()
	await process_frame
	print("[WS1_WORLD_ROUTES] COMPLETE checks=%d failures=%d rooms=%d finals=%d" % [
		checks, failures, completed_rooms, final_rooms
	])
	quit(0 if failures == 0 else 1)

func audit_route(dungeon_id: String, route: Dictionary) -> void:
	room_events.clear()
	var spec := {
		"run_id": "ws1-world-routes-" + dungeon_id,
		"dungeon": dungeon_id,
		"route": route,
		"room_id": dungeon_id + ":0",
		"room_index": 0,
		"player": {"hp": 5000, "mp": 500, "weapon": "shortsword", "skill_slots": []},
		"audio": {"muted": true},
	}
	var started := session.start_room(spec)
	check(started, "formal route starts " + dungeon_id)
	if not started:
		return
	var rooms: Array = route["rooms"]
	for index in rooms.size():
		var label := "%s room %d" % [dungeon_id, index+1]
		check(game.room_index == index, label + " is the active room")
		check(String(game.room_id) == "%s:%d" % [dungeon_id, index], label + " keeps the run room id")
		check(int(game.room_map.get("map_id", -1)) == source_map_id(route, index),
			label + " keeps its source MAP id")
		var before_events := room_events.size()
		clear_room()
		check(game.room_cleared, label + " emits a room clear")
		completed_rooms += 1
		var event: Dictionary = room_events[-1] if not room_events.is_empty() else {}
		check(room_events.size() == before_events+1, label + " emits exactly one clear event")
		check(int(event.get("room_index", -1)) == index, label + " clear event carries the room index")
		check(event.get("final_room", false) == bool(rooms[index].get("boss", false)),
			label + " matches its final-room flag")
		if index < rooms.size()-1:
			check(not game.finished and not game.victory, label + " does not settle before the boss")
			var side := String(rooms[index]["next"])
			game.player["pos"] = game.door_point(side)
			game.door_lock_ms = 0.0
			game.step_game(0.0)
			check(game.room_index == index+1, label + " crosses " + side + " into the next room")
		else:
			check(game.finished and game.victory, label + " settles the completed dungeon")
			final_rooms += 1

func clear_room() -> void:
	for enemy: Dictionary in game.monsters:
		enemy["hp"] = 0.0
	game.step_game(820.0)

func source_map_id(route: Dictionary, index: int) -> int:
	var rooms: Dictionary = game.map_loader.data.get("dungeon", {}).get("rooms", {})
	var placement_id := String(route["rooms"][index]["placement"])
	for placement: Dictionary in game.map_loader.placements():
		if String(placement["id"]) == placement_id:
			return int(rooms.get(String(placement["map"]), {}).get("map_id", -1))
	return -1
