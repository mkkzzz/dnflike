extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const MonsterAI = preload("res://combat/ai/monster_ai.gd")
const DUNGEONS := "res://data/dungeons.json"

var session := CombatSession.new()
var game
var checks := 0
var failures := 0
var tested_bosses := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("[WS1_WORLD_BOSS_CONTACTS] FAIL " + label)

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
			check_dungeon_bosses(dungeon_id, route)
	check(tested_bosses == 18, "all 18 visible-dungeon boss spawns were tested")
	session.stop()
	await process_frame
	print("[WS1_WORLD_BOSS_CONTACTS] COMPLETE checks=%d failures=%d bosses=%d" % [
		checks, failures, tested_bosses
	])
	quit(0 if failures == 0 else 1)

func check_dungeon_bosses(dungeon_id: String, route: Dictionary) -> void:
	var final_index := (route.get("rooms", []) as Array).size() - 1
	for boss_index in count_bosses(dungeon_id, route, final_index):
		test_boss(dungeon_id, route, final_index, boss_index)

func count_bosses(dungeon_id: String, route: Dictionary, final_index: int) -> int:
	start_final(dungeon_id, route, final_index)
	var count: int = game.monsters.filter(func(enemy): return bool(enemy.get("chief", false))).size()
	check(count > 0, dungeon_id + " boss room contains a boss")
	return count

func start_final(dungeon_id: String, route: Dictionary, final_index: int) -> void:
	var started := session.start_room({
		"run_id": "ws1-boss-contact-" + dungeon_id,
		"dungeon": dungeon_id,
		"route": route,
		"room_id": "%s:%d" % [dungeon_id, final_index],
		"room_index": final_index,
		"player": {"hp": 5000, "mp": 500, "hp_max": 5000, "mp_max": 500, "weapon": "shortsword", "skill_slots": []},
		"audio": {"muted": true},
	})
	check(started, dungeon_id + " formal final room accepts boss-contact fixture")

func test_boss(dungeon_id: String, route: Dictionary, final_index: int, boss_index: int) -> void:
	start_final(dungeon_id, route, final_index)
	var bosses: Array = game.monsters.filter(func(enemy): return bool(enemy.get("chief", false)))
	if boss_index >= bosses.size():
		return
	var boss: Dictionary = bosses[boss_index]
	tested_bosses += 1
	for enemy: Dictionary in game.monsters:
		if enemy != boss:
			enemy["hp"] = 0.0
			enemy["ai"] = false
	var origin := Vector2(Vector2i(boss["pos"]))
	var distance := choose_attack_distance(boss, origin)
	check(distance >= 0, "%s %s selects a formal AI attack distance" % [
		dungeon_id, String(boss.get("mob", ""))
	])
	if distance < 0:
		return
	game.player["pos"] = origin + Vector2(distance, 0)
	game.player["hp"] = 5000.0
	game.player["state"] = "idle"
	game.player["action"] = ""
	game.player["z"] = 0.0
	game.player["vz"] = 0.0
	game.player["invuln_ms"] = 0.0
	game.player["stuck_ms"] = 0.0
	boss["ai"] = true
	boss["state"] = "idle"
	boss["clock"] = 0.0
	boss["cooldown_ms"] = 0.0
	boss["skill_cd"] = {}
	var before_hp := float(game.player["hp"])
	for frame in 360:
		game.step_game(16.0)
		if float(game.player["hp"]) < before_hp:
			break
	check(float(game.player["hp"]) < before_hp, "%s %s lands a real boss attack" % [
		dungeon_id, String(boss.get("mob", ""))
	])

func choose_attack_distance(boss: Dictionary, origin: Vector2) -> int:
	boss["facing"] = 1
	boss["cooldown_ms"] = 0.0
	boss["skill_cd"] = {}
	var sight := maxi(40, mini(int(boss["def"].get("sight", 300)), 400))
	for distance in range(4, sight + 1, 8):
		var intent: Dictionary = MonsterAI.think(
			boss, boss["def"], origin + Vector2(distance, 0), 0.0
		)
		if bool(intent.get("attack", false)):
			return distance
	return -1
