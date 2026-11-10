extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const MonsterAI = preload("res://combat/ai/monster_ai.gd")
const DUNGEONS := "res://data/dungeons.json"

var session := CombatSession.new()
var game
var checks := 0
var failures := 0
var audited_rooms := 0
var checked_attack_mobs := {}

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("[WS1_WORLD_ROOMS] FAIL " + label)

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
			if bool(route.get("legacy", false)):
				continue
			if String(route.get("mode", "")) == "native_maze":
				continue
			if bool(route.get("hidden", false)):
				print("[WS1_WORLD_ROOMS] SKIP hidden dungeon ", dungeon_id)
				continue
			audit_dungeon(dungeon_id, route)
	check(audited_rooms == 107, "all 107 rooms in the 17 visible dungeons were audited")
	session.stop()
	await process_frame
	print("[WS1_WORLD_ROOMS] COMPLETE checks=%d failures=%d rooms=%d" % [
		checks, failures, audited_rooms
	])
	quit(0 if failures == 0 else 1)

func audit_dungeon(dungeon_id: String, route: Dictionary) -> void:
	var spec := {
		"run_id": "ws1-world-rooms-" + dungeon_id,
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
	var source_counts := {}
	var source_bosses := 0
	for monster: Dictionary in game.room_map.get("monsters", []):
		var mob := String(monster.get("mob", ""))
		source_counts[mob] = int(source_counts.get(mob, 0)) + 1
		var raw: Array = monster.get("raw", [])
		if raw.size() > 9 and String(raw[9]) == "[boss]":
			source_bosses += 1
	var live_counts := {}
	var live_bosses := 0
	for enemy: Dictionary in game.monsters:
		var mob := String(enemy.get("mob", ""))
		live_counts[mob] = int(live_counts.get(mob, 0)) + 1
		if bool(enemy.get("chief", false)):
			live_bosses += 1
		check_attack_contract(String(enemy.get("mob", "")), enemy.get("def", {}))
	var label := "%s room %d" % [dungeon_id, index + 1]
	check(game.room_index == index, label + " loads the requested index")
	check(live_counts == source_counts, label + " spawns its exact source monster lineup")
	check(live_bosses == source_bosses, label + " preserves source boss markers")
	check(game.route_boss_room() == bool((game.rules["rooms"][index] as Dictionary).get("boss", false)),
		label + " boss state matches the route definition")

func check_attack_contract(mob: String, definition: Dictionary) -> void:
	if checked_attack_mobs.has(mob):
		return
	checked_attack_mobs[mob] = true
	var can_attack := definition.has("throw")
	for move: Dictionary in definition.get("moves", []):
		can_attack = can_attack or not (move.get("segments", []) as Array).is_empty()
		can_attack = can_attack or not (move.get("emission", {}) as Dictionary).is_empty()
	can_attack = can_attack or not (definition.get("attack_segments", []) as Array).is_empty()
	can_attack = can_attack or not (definition.get("native_suicide", {}) as Dictionary).is_empty()
	check(can_attack, mob + " exposes at least one reachable attack or projectile")
	if not can_attack:
		return
	var selected := false
	var origin := Vector2(700, 250)
	var sight := maxi(40, int(definition.get("sight", 300)))
	for distance in range(4, mini(sight, 400) + 1, 8):
		var intent: Dictionary = MonsterAI.think(
			{"pos": origin, "facing": 1, "cooldown_ms": 0.0, "skill_cd": {}},
			definition, origin + Vector2(distance, 0), 0.0
		)
		if bool(intent.get("attack", false)):
			selected = true
			break
	check(selected, mob + " can select an attack at a source-visible distance")
