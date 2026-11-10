extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const MonsterAI = preload("res://combat/ai/monster_ai.gd")
const MapLoader = preload("res://scripts/native_map_loader.gd")
const DUNGEONS := "res://data/dungeons.json"
const EXPECTED_SPECIES := {
	"monster/draconian/lakius.mob": 1,
	"monster/draconian/mirkius.mob": 2,
	"monster/draconian/minius.mob": 2,
	"monster/flydragon/harseseri.mob": 7,
	"monster/flydragon/looseseri.mob": 11,
}

var session := CombatSession.new()
var game
var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("[WS1_DRACONIAN_TOWER] FAIL " + label)

func run() -> void:
	var dungeon_doc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DUNGEONS))
	var route: Dictionary = dungeon_doc["dungeons"]["draconiantower"].duplicate(true)
	check_source_room(route)
	game = session.mount(root)
	game.set_process(false)
	game.set_physics_process(false)
	check(not game.missing_assets, "production Draconian Tower content and combat assets load")
	if not game.missing_assets:
		var started: bool = session.start_room({
			"run_id": "ws1-draconiantower",
			"dungeon": "draconiantower",
			"route": route,
			"room_id": "draconiantower:5",
			"room_index": 5,
			"player": {"hp": 500, "mp": 200, "weapon": "shortsword", "skill_slots": []},
			"audio": {"muted": true},
		})
		check(started, "formal combat accepts the complete six-room Draconian Tower route")
		if started:
			check_live_room()
			check_moves()
	session.stop()
	await process_frame
	print("[WS1_DRACONIAN_TOWER] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)

func check_source_room(route: Dictionary) -> void:
	var rooms: Array = route.get("rooms", [])
	check(rooms.size() == 6 and bool(rooms[-1].get("boss", false)),
		"source route keeps six rooms and a boss terminal")
	var loader = MapLoader.new()
	check(loader.load_export(String(route["map_export"])), "source Draconian Tower MAP export loads")
	var placement: Dictionary = {}
	for candidate: Dictionary in loader.placements():
		if String(candidate.get("id", "")) == "2_4:(3,2)b1823":
			placement = candidate
			break
	check(String(placement.get("map", "")) == "map/draconiantower/(3,2)b1823.map",
		"boss placement resolves the source b1823 MAP")
	if placement.is_empty():
		return
	var room: Dictionary = loader.room(String(placement["map"]))
	var counts := {}
	var boss := 0
	for monster: Dictionary in room.get("monsters", []):
		var mob := String(monster.get("mob", ""))
		counts[mob] = int(counts.get(mob, 0)) + 1
		var raw: Array = monster.get("raw", [])
		if raw.size() > 9 and String(raw[9]) == "[boss]":
			boss += 1
	check(room.get("monsters", []).size() == 23, "source b1823 keeps all 23 monster placements")
	check(counts == EXPECTED_SPECIES, "source b1823 preserves the exact five-species lineup")
	check(boss == 1, "source b1823 marks exactly one Lakius boss")

func check_live_room() -> void:
	var counts := {}
	var bosses := 0
	for enemy: Dictionary in game.monsters:
		var mob := String(enemy.get("mob", ""))
		counts[mob] = int(counts.get(mob, 0)) + 1
		if bool(enemy.get("chief", false)):
			bosses += 1
	check(game.room_index == 5 and game.room_width > 0, "formal session loads the sixth room")
	check(game.monsters.size() == 23 and counts == EXPECTED_SPECIES,
		"formal session spawns the exact source monster lineup")
	check(bosses == 1 and String(game.monsters.filter(func(enemy): return bool(enemy.get("chief", false)))[0].get("mob", ""))
		== "monster/draconian/lakius.mob", "formal session identifies Lakius as the sole boss")

func check_moves() -> void:
	var mirkius: Dictionary = game.table.monsters.get("draconian_mirkius", {})
	var minius: Dictionary = game.table.monsters.get("draconian_minius", {})
	var lakius: Dictionary = game.table.monsters.get("draconian_lakius", {})
	var harse: Dictionary = game.table.monsters.get("flydragon_harseseri", {})
	var loose: Dictionary = game.table.monsters.get("flydragon_looseseri", {})
	var mirkius_source: Array = game.content.original(
		"monster/draconian/mirkius.mob", "attack_motions", []
	)
	check(mirkius_source.size() == 3 and String(mirkius_source[1]) == "",
		"Mirkius source preserves three attack slots including the blank motion")
	check(mirkius.get("moves", []).size() == 3,
		"Mirkius source blank slot reuses its prior motion without losing attackheart")
	var mirkius_slots: Array = mirkius.get("moves", []).map(func(move): return int(move.get("source_slot", -1)))
	check(mirkius_slots == [0, 1, 2], "Mirkius runtime keeps the original three slot indices")
	check(minius.get("moves", []).size() == 3, "Minius preserves its three attack slots")
	check(lakius.get("moves", []).size() == 5, "Lakius preserves all five source attacks")
	check(harse.has("atk") and loose.has("atk"), "Harseseri and Looseseri retain their bite attack info")
	for definition in [mirkius, minius, lakius]:
		for move: Dictionary in definition.get("moves", []):
			check(not move.get("ani", "") == "" and not move.get("atk", {}).is_empty(),
				"every multi-attack slot keeps both ANI and ATK: " + String(definition.get("mob", "")))
	var minius_choice: Dictionary = MonsterAI.think(
		{"pos": Vector2(700, 266), "facing": 1, "cooldown_ms": 0.0, "skill_cd": {}},
		minius, Vector2(790, 266), 0.0
	)
	check(bool(minius_choice.get("attack", false)) and int(minius_choice.get("move_index", -1)) == 0,
		"Minius selects its source attack inside the native reach band")
	var lakius_close: Dictionary = MonsterAI.think(
		{"pos": Vector2(1399, 332), "facing": 1, "cooldown_ms": 0.0, "skill_cd": {}},
		lakius, Vector2(1480, 332), 0.0
	)
	var lakius_long: Dictionary = MonsterAI.think(
		{"pos": Vector2(1399, 332), "facing": 1, "cooldown_ms": 0.0, "skill_cd": {}},
		lakius, Vector2(1569, 332), 0.0
	)
	check(bool(lakius_close.get("attack", false)) and int(lakius_close.get("move_index", -1)) == 0,
		"Lakius selects its close source attack at close range")
	check(bool(lakius_long.get("attack", false)) and int(lakius_long.get("move_index", -1)) == 2,
		"Lakius selects the long source attack outside close reach")
