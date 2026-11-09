extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const Numbers = preload("res://stats/api/numbers.gd")
const MOB := "monster/zealot/bosspope.mob"
const MELEE_ATK := "monster/zealot/attackinfo/poattack.atk"
const BOLT := "passiveobject/monster/zealot/popethunderbolt.obj"
const BOLT_ATK := "passiveobject/monster/zealot/attackinfo/popethunderbolt.atk"
var checks := 0
var failures := 0
var game
var session := CombatSession.new()

class ContactRolls:
	var roll: int
	var contact_draws := 0

	func _init(value: int) -> void:
		roll = value

	func next_float() -> float:
		return 0.0

	func range_int(low: int, high: int) -> int:
		if low == 0 and high == 99:
			contact_draws += 1
			return roll
		return low

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("[NATIVE_POPE] FAIL " + label)

func run() -> void:
	game = session.mount(root)
	game.set_process(false)
	game.set_physics_process(false)
	game._muted = true
	check(not game.missing_assets,"formal battle loads the original content pack")
	var definition: Dictionary = game.table._build_monster("source_pope",{"mob":MOB})
	check(game.table.problems.is_empty() and definition.get("attack_contacts",{}).has(0),
		"the original slot 0 contact compiles with an available sprite bank")
	if definition.get("attack_contacts",{}).has(0):
		game.table.monsters["source_pope"] = definition
		check_attack(49)
		check_attack(50)
		check_companion_contact()
	print("[NATIVE_POPE] COMPLETE checks=%d failures=%d" % [checks,failures])
	quit(0 if failures == 0 else 1)

func check_attack(roll: int) -> void:
	var previous_rng = game.rng
	session.start_room({"run_id":"standalone","dungeon":"lorien","room_index":0,"from":"start",
		"player":{"numbers":Numbers.shared_config()["base"]}})
	var rolls := ContactRolls.new(roll)
	game.rng = rolls
	var pope: Dictionary = game.spawn_enemy(Vector2(350,300),true,"source_pope")
	pope["pos"] = Vector2(350,300)
	pope["facing"] = 1
	pope["state"] = "attack"
	var target_position := Vector2(390.75,300.75)
	game.player["pos"] = target_position
	game.player["invuln_ms"] = 0.0
	game.bus.clear_history()
	pope["clock"] = 279.0
	game.enemy_attack(pope,1.0)
	check(game.objects.is_empty() and rolls.contact_draws == 0,"no callback before the first attack box")
	pope["clock"] = 280.0
	game.player["pos"] = Vector2(620,300)
	game.enemy_attack(pope,1.0)
	check(game.objects.is_empty() and rolls.contact_draws == 0,"no callback when an active swing misses")
	game.player["pos"] = target_position
	game.enemy_attack(pope,1.0)
	var contacts: Array = game.bus.events_of("combat.hit")
	check(contacts.size() == 1 and contacts[0]["atk"] == MELEE_ATK,"original melee still resolves with its own ATK")
	check(rolls.contact_draws == 1 and game.objects.size() == int(roll < 50),"roll %d observes the strict 50 threshold" % roll)
	pope["clock"] = 340.0
	game.enemy_attack(pope,60.0)
	check(rolls.contact_draws == 1 and game.objects.size() == int(roll < 50),"the same attack box run does not repeat the contact callback")
	if not game.objects.is_empty():
		check_bolt(game.objects[0])
	game.rng = previous_rng

func check_companion_contact() -> void:
	var dungeons: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/dungeons.json"))["dungeons"]
	var route: Dictionary = dungeons["draconiantower"].duplicate(true)
	route.merge(route["quest_routes"]["original.quest.4307"],true)
	check(session.start_room({"run_id":"pope-companion","dungeon":"draconiantower","route":route,"room_index":0,
		"from":"start","player":{"numbers":Numbers.shared_config()["base"]}}),"the real quest route starts through the combat API")
	check(game.companions.size() == 1,"the real quest MAP creates a friendly APC")
	if game.companions.size() != 1:return
	var companion: Dictionary = game.companions[0]
	var previous_rng = game.rng
	var rolls := ContactRolls.new(49)
	game.rng = rolls
	game.player["pos"] = Vector2(620,300)
	companion["pos"] = Vector2(390.75,300.75)
	var pope: Dictionary = game.spawn_enemy(Vector2(350,300),true,"source_pope")
	pope["pos"] = Vector2(350,300)
	pope["facing"] = 1
	pope["state"] = "attack"
	pope["clock"] = 280.0
	game.bus.clear_history()
	game.enemy_attack(pope,1.0)
	var contacts: Array = game.bus.events_of("combat.hit")
	check(contacts.size() == 1 and contacts[0]["target"] == companion["id"],"the original melee contacts the friendly APC only")
	check(rolls.contact_draws == 1 and game.objects.size() == 1 and game.objects[0]["pos"] == Vector2(390,300),
		"APC class 0x111 passes the 0x11 mask and receives the bolt at its own position")
	game.rng = previous_rng

func check_bolt(bolt: Dictionary) -> void:
	check(bolt["hit"]["object"] == BOLT and bolt["pos"] == Vector2(390,300) and bolt["z"] == 0.0,
		"the original object starts on the target's integer XY at ground height")
	game.player["invuln_ms"] = 0.0
	game.step_objects(16.0,int(bolt["id"]))
	check(bolt["clock"] == 0.0,"spawn update does not charge the new bolt for the caster tick")
	game.view.present(game.view_snapshot(),0.0,0.0)
	var art = game.view.object_views.get(bolt["id"])
	check(art != null and art.atlas != null and int(art.frame.get("frame",-1)) == 0,
		"the source ANI's first frame is visible")
	check(game.last_damage.get("category") == "magical" and game.last_damage.get("element") == "light"
		and game.bus.events_of("combat.hit").any(func(event):return event["atk"] == BOLT_ATK),
		"the bolt's original attack box resolves light magic using the original ATK")
	game.step_objects(539.0)
	check(game.objects.size() == 1,"the original visual survives before its 540 ms end")
	game.step_objects(1.0)
	check(game.objects.is_empty(),"the original ANI end removes the bolt")
