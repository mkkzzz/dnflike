extends Node
## Isolated newmonsters/haze logic testbed. It uses the hidden Arden route data but does
## not add a town entrance, campaign integration, or content-quality acceptance.

const BattleScene = preload("res://scenes/main.tscn")
const TestAPI = preload("res://debug/test_api.gd")
const TEST_CONTENT := "res://assets_local/act8_testbed/content.json"
const TEST_ADAPT := "res://assets_local/act8_testbed/adapt.json"
const TEST_ASSETS := "res://assets_local/act8_testbed/combat_manifest.json"

var game
var api
var checks := 0
var failures := 0
var arden_kinds := {}

func _ready() -> void:
	game = BattleScene.instantiate()
	game.test_content_pack = TEST_CONTENT
	game.test_adapt_path = TEST_ADAPT
	game.test_combat_assets_path = TEST_ASSETS
	game.test_dungeon_id = "arden"
	add_child(game)
	await ticks(5)
	if game.missing_assets:
		check(false,"act8 testbed bootstraps isolated content: "+game.missing_reason)
		finish()
		return
	game._muted = true
	game.view.audio.music.stop()
	api = TestAPI.new(game)
	await run()
	finish()

func finish() -> void:
	print("[ACT8_TEST] COMPLETE checks=%d failures=%d"%[checks,failures])
	get_tree().quit(0 if failures==0 else 1)

func check(value: bool,message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("[ACT8_TEST] FAIL "+message)
	else:
		print("[ACT8_TEST] PASS "+message)

func ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame

func tap(code: int) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = true
	Input.parse_input_event(event)
	await ticks(1)
	var release := InputEventKey.new()
	release.keycode = code
	release.physical_keycode = code
	release.pressed = false
	Input.parse_input_event(release)

func run() -> void:
	await check_route_and_content()
	check_action_sets()
	await check_runtime_logic()

func check_route_and_content() -> void:
	check(game.dungeon_id=="arden","isolated test bootstrap selects the hidden Arden route")
	check(game.rules["rooms"].size()==10,"Arden route exposes all ten source rooms")
	check(game.table.problems.is_empty(),"act8 content and combat tables resolve without missing records")
	var room_total := 0
	for room_index in game.rules["rooms"].size():
		game.room_snapshots.clear()
		game.load_room(room_index,"start")
		await ticks(1)
		var expected: Array = game.room_map.get("monsters",[])
		room_total += expected.size()
		check(game.monsters.size()==expected.size(),"room %d spawns every source monster (%d)"%[room_index,expected.size()])
		for enemy: Dictionary in game.monsters:
			var kind := String(enemy["kind"])
			arden_kinds[kind] = true
			check(game.table.monsters.has(kind),"room %d maps %s into the combat table"%[room_index,kind])
	check(room_total==80,"all 80 source spawns enter the act8 testbed")
	check(arden_kinds.size()==9,"Arden covers nine unique newmonsters/haze kinds")
	var atlas_note: Dictionary = game.combat_assets.get("act8_testbed",{})
	var missing_atlas: Array = atlas_note.get("missing_atlas_kinds",[])
	check(atlas_note.get("atlas_status","")=="logic_only_missing_source_image" and missing_atlas.size()==9,
		"missing haze IMG pixels are explicit; the testbed uses no substitute monster art")
	game.restart()
	await ticks(2)

func check_action_sets() -> void:
	for kind: String in arden_kinds:
		var m: Dictionary = game.table.monsters[kind]
		var motions: Dictionary = m.get("motions",{})
		var paths: Dictionary = m.get("ani_paths",{})
		check(String(motions.get("stay",""))!="" and paths.has("stay"),kind+" has a resolved stay action")
		check(String(motions.get("move",""))!="" and paths.has("move"),kind+" has a resolved move action")
		check(not m.get("attack_timeline",[]).is_empty(),kind+" has a non-empty original attack timeline")
		check(not m.get("moves",[]).is_empty(),kind+" exposes indexed [attack action] moves")
		var moves: Array = m.get("moves",[])
		for index in moves.size():
			var move: Dictionary = moves[index]
			check(String(move.get("act","")).ends_with(".act") and String(move.get("ani","")).ends_with(".ani"),
				"%s move %d binds .act to its [BASE ANI]"%[kind,index])
		for rule: Dictionary in m.get("rules",[]):
			var skill := int(rule.get("skill",-1))
			check(skill>=0 and skill<moves.size(),"%s AI skill %d resolves to an attack action"%[kind,skill])
	var death_squad: Dictionary = game.table.monsters["newmonsters_haze_death_squad_death_squad"]
	check(death_squad.get("moves",[]).size()==2,"death_squad keeps both source attack actions")
	check(String(death_squad["moves"][1].get("ani","")).ends_with("attack2.ani"),
		"death_squad AI index 1 binds the second attack ANI")
	var biker2: Dictionary = game.table.monsters["newmonsters_haze_chainbiker2_chainbiker2"]
	check(biker2.get("moves",[]).size()==6 and String(biker2["moves"][2].get("ani","")).ends_with("dash_go.ani"),
		"chainbiker2 keeps all six indexed actions including dash_go")

func check_runtime_logic() -> void:
	var axe := "newmonsters_haze_axeoutlaw_axeoutlaw"
	api.restart()
	api.set_god(true)
	game.clear_monsters()
	var anchor: Array = game.room_map["monsters"][0]["anchor"]
	var enemy: Dictionary = api.spawn_monster(Vector2(float(anchor[0]),float(anchor[1])),axe)
	enemy["ai"] = false
	enemy["hp"] = 5000.0
	enemy["max_hp"] = 5000.0
	game.player["pos"] = game.constrain_pos(Vector2(enemy["pos"])-Vector2(72,0))
	var hp_before := float(enemy["hp"])
	var saw_hurt := false
	api.start_action("attack1")
	for i in 40:
		await ticks(1)
		if String(enemy["state"])=="hurt":saw_hurt = true
	check(float(enemy["hp"])<hp_before,"player attack reaches an act8 monster")
	check(saw_hurt,"act8 monster enters a real hurt state")

	api.restart()
	api.set_god(false)
	game.clear_monsters()
	enemy = api.spawn_monster(Vector2(float(anchor[0]),float(anchor[1])),axe)
	game.player["pos"] = game.constrain_pos(Vector2(enemy["pos"])-Vector2(90,0))
	game.player["hp"] = 1000.0
	game.player["invuln_ms"] = 0.0
	enemy["cooldown_ms"] = 0.0
	var player_hp := float(game.player["hp"])
	var saw_attack := false
	for i in 150:
		await ticks(1)
		if String(enemy["state"])=="attack" and int(enemy.get("move_index",-1))==0:
			saw_attack = true
		if float(game.player["hp"])<player_hp:
			break
	check(saw_attack and int(enemy.get("move_index",-1))==0,"axeoutlaw AI selects skill 0 and plays its attack")
	check(float(game.player["hp"])<player_hp,"act8 attack reaches the player through its own attack box")

	api.restart()
	api.set_god(true)
	game.clear_monsters()
	var biker: Dictionary = api.spawn_monster(Vector2(float(anchor[0]),float(anchor[1])),"newmonsters_haze_chainbiker2_chainbiker2")
	biker["ai"] = false
	biker["hp"] = 0.0
	biker["death_ms"] = 0.0
	await ticks(2)
	check(String(biker["state"])=="dead" and String(api.enemy_ani(biker)[0])=="die",
		"chainbiker2 enters the original last-action death animation")
	check(String(biker["def"]["motions"].get("die",""))!="" and biker["def"]["ani_paths"].has("die"),
		"chainbiker2 death resolves to the original die ANI")
