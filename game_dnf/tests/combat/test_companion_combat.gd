extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const Numbers = preload("res://stats/api/numbers.gd")
var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("[COMPANION_COMBAT] FAIL "+label)

func run() -> void:
	var dungeons: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/dungeons.json"))["dungeons"]
	for row: Array in [["draconiantower","original.quest.4307",201,Vector2(250,245),1619,0.6],
		["hallofdoll","original.quest.4308",202,Vector2(186,238),1820,0.2]]:
		await check_route(dungeons,row)
	print("[COMPANION_COMBAT] COMPLETE checks=%d failures=%d"%[checks,failures])
	quit(0 if failures==0 else 1)

func check_route(dungeons: Dictionary, row: Array) -> void:
	var dungeon := String(row[0])
	var source_id := int(row[2])
	var route: Dictionary = dungeons[dungeon].duplicate(true)
	route.merge(route["quest_routes"][row[1]],true)
	var session = CombatSession.new()
	var game = session.mount(root)
	game.set_physics_process(false)
	game._muted = true
	var spec := {"run_id":"companion-%d"%source_id,"dungeon":dungeon,"route":route,"room_index":0,
		"player":{"numbers":Numbers.shared_config()["base"],"skills":{"normalwave":1}}}
	var finished: Array = []
	var fallen: Array = []
	var kills: Array = []
	var actions: Array = []
	session.room_combat_finished.connect(func(event):finished.append(event))
	session.companion_defeated.connect(func(event):fallen.append(event))
	session.monster_defeated.connect(func(event):kills.append(event))
	session.events().subscribe("combat.action_started",func(event):actions.append(event))
	check(session.start_room(spec),"the actual quest route validates and starts for APC %d"%source_id)
	check(game.companions.size()==1,"source MAP instantiates one companion")
	if game.companions.size()!=1:
		session.stop()
		await process_frame
		return
	var ally: Dictionary = game.companions[0]
	var actor = game.view.enemy_actors.get(ally["id"])
	var identity := int(ally["id"])
	check(ally["companion_id"]==source_id and ally["pos"]==row[3] and ally["z"]==0.0,"the spawned friendly uses MAP source identity and XYZ")
	check(actor!=null and actor.atlas!=null and actor.bank["texture"].ends_with("/gsd.png"),"the source G.S.D. atlas renders the actor")
	check(float(ally["hp"])>0.0 and is_equal_approx(float(ally["numeric"].values["damage_rate"]),float(row[5])),"independent HP and native AIC attack multiplier")
	var runtime: Dictionary = session.read_runtime_view()
	check(runtime["companions"][0]["source_id"]==source_id and runtime["alive_monsters"]==game.monsters.size(),"read view separates friendlies from the room enemy count")

	# A real monster's source melee frames can hit the companion without counting
	# it as a player hit, and monster AI can select the nearby friend.
	game.clear_monsters()
	var goblin: Dictionary = game.spawn_enemy(Vector2(370,250))
	ally["pos"] = Vector2(goblin["pos"])+Vector2(40,0)
	game.player["pos"] = Vector2(goblin["pos"])-Vector2(250,0)
	goblin["cooldown_ms"] = 0.0
	game.update_enemy(goblin,1.0)
	check(goblin["state"]=="attack" and goblin["facing"]==1,"monster targets a nearby living companion")
	var hp := float(ally["hp"])
	game.rng.reseed(1)
	game.update_enemy(goblin,800.0)
	check(float(ally["hp"])<hp and float(ally["hp"])>0.0 and game.hit_count==0,"hostile melee damage reaches companion HP without inflating player statistics")
	var carried_hp := float(ally["hp"])

	# Player and ally projectiles share the original object collision path and
	# never attack the friendly side.
	game.clear_monsters()
	ally["pos"] = Vector2(470,250)
	ally["state"] = "idle"
	game.player["pos"] = Vector2(400,250)
	game.player["facing"] = 1
	game.player["mp"] = 500.0
	check(game.start_action("normalwave"),"player wave starts beside the companion")
	game.step_action(150.0,Vector2.ZERO)
	game.step_objects(0.0)
	check(float(ally["hp"])==carried_hp,"the player's real wave object skips the friendly companion")
	game.objects.clear()
	var foe: Dictionary = game.spawn_enemy(Vector2(600,250))
	foe["pos"] = Vector2(600,250)
	foe["ai"] = false
	var foe_hp := float(foe["hp"])
	ally["pos"] = Vector2(420,250)
	ally["stuck_ms"] = 0.0
	ally["think_ms"] = 0.0
	ally["mp"] = 500.0
	game.rng.reseed(1)
	for _i in 200:
		game.update_companion(ally,16.0)
		game.step_objects(16.0)
		if float(foe["hp"])<foe_hp:break
	check(actions.any(func(event):return int(event["entity_id"])==identity),"the original companion decision program starts a real action")
	check(float(foe["hp"])<foe_hp and float(ally["hp"])==carried_hp,"a source-selected companion move damages only the enemy")

	var final_index: int = route["rooms"].size()-1
	game.load_room(final_index,"start")
	check(game.companions.size()==1 and int(game.companions[0]["id"])==identity and float(ally["hp"])==carried_hp,"room transition keeps the same live APC and HP")
	game.clear_monsters()
	game.step_game(1.0)
	check(finished.size()==1 and finished[0]["source_map_id"]==row[4] and finished[0]["companions_alive"]==[source_id],"final room emits the real MAP and surviving APC")

	# Replay the real route and let a hostile blow kill the companion. Returning
	# to its source room must not instantiate it again or award a monster defeat.
	finished.clear()
	kills.clear()
	check(session.start_room(spec),"a new attempt resets the previous run's companion state")
	ally = game.companions[0]
	goblin = game.spawn_enemy(Vector2(380,250))
	ally["hp"] = 1.0
	game.rng.reseed(1)
	game.land_hit(goblin,ally,{"atk":{},"percent":100},Vector3(380,250,0),1,100.0)
	check(fallen.size()==1 and fallen[0]["source_id"]==source_id and kills.is_empty(),"lethal hostile damage emits exactly one companion defeat and no monster loot event")
	game.load_room(0,"start")
	check(game.companions.size()==1 and float(ally["hp"])==0.0,"re-entering the source MAP cannot respawn the dead APC")
	game.load_room(final_index,"start")
	game.clear_monsters()
	game.step_game(1.0)
	check(finished.size()==1 and finished[0]["source_map_id"]==row[4] and finished[0]["companions_alive"].is_empty() and fallen.size()==1,"defeated APC cannot enter the final survival event")
	session.stop()
	await process_frame
