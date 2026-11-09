extends SceneTree

const CATAPULT := "monster/vehicle/catapult.mob"
const CANNON_ATK := "passiveobject/monster/vehicle/attackinfo/cannonball.atk"
var checks := 0
var failures := 0
var game

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("[NATIVE_CANNON] FAIL " + label)

func run() -> void:
	# Compile a scratch pack with --extra-mob monster/vehicle/catapult.mob.
	var args := OS.get_cmdline_user_args()
	if args.size() != 1 or not FileAccess.file_exists(args[0]):
		push_error("[NATIVE_CANNON] Expected one compiled content pack path after --")
		quit(1)
		return
	game = load("res://scenes/main.tscn").instantiate()
	game.external_mode = true
	game.test_content_pack = args[0]
	root.add_child(game)
	game.set_process(false)
	game.set_physics_process(false)
	game._muted = true
	check(not game.missing_assets,"formal battle loads the source fixture")
	var hit_audio: Array = game.view.audio.variants.get("R_BOMB_HIT",[])
	check(hit_audio.size() == 2 and hit_audio.all(func(stream):return stream is AudioStreamOggVorbis),
		"both original bomb contact sound variants load")
	var cannon: Dictionary = game.table._build_monster("catapult",{"mob":CATAPULT})
	check(game.table.problems.is_empty() and cannon.get("moves",[]).size() == 2,"original Fire slots compile")
	if cannon.get("moves",[]).size() == 2:
		for facing in [1,-1]:
			for slot in [0,1]:
				check_shot(cannon,facing,slot)
		check_contact(cannon)
		check_selection(cannon)
	print("[NATIVE_CANNON] COMPLETE checks=%d failures=%d" % [checks,failures])
	quit(0 if failures == 0 else 1)

func shot_actor(cannon: Dictionary, facing: int, slot: int, clock: float) -> Dictionary:
	return {"id":19,"def":cannon,"clock":clock,"move_index":slot,"state":"attack",
		"pos":Vector2(350,300),"z":0.0,"facing":facing,"attack":48.0,"thrown":false}

func check_shot(cannon: Dictionary, facing: int, slot: int) -> void:
	game.restart()
	game.player["pos"] = Vector2(950,400)
	game.bus.clear_history()
	var move: Dictionary = cannon["moves"][slot]
	var label := "slot %d facing %d" % [slot,facing]
	check(move.get("emission",{}).get("at") == 730.0,label+" original Fire frame 11")
	var enemy := shot_actor(cannon,facing,slot,729.0)
	game.enemy_attack(enemy,1.0)
	check(game.objects.is_empty(),label+" no shot before frame")
	enemy["clock"] = 730.0
	var verify_playback := facing == 1 and slot == 0
	if verify_playback:game._muted = false
	game.enemy_attack(enemy,1.0)
	if verify_playback:
		var voices: Array = game.view.audio.voice_pool
		check(voices.any(func(voice):return voice.playing and voice.stream.resource_path.ends_with("/drgcan_shoot.ogg")),
			"launch cue plays the original source stream")
		game._muted = true
	check(game.objects.size() == 1,label+" one fresh shell at frame 11")
	if game.objects.is_empty():return
	var shot: Dictionary = game.objects[0]
	var start := Vector2(350+70*facing,300)
	check(shot["pos"] == start and shot["z"] == 50.0,label+" source muzzle offset")
	game.step_objects(16.0,int(shot["id"]))
	check(shot["clock"] == 0.0 and shot["pos"] == start,label+" new shell starts at age zero")
	enemy["clock"] = 731.0
	game.enemy_attack(enemy,1.0)
	var sounds: Array = game.bus.events_of("combat.cue").filter(func(e):return e.get("key") == "DRGCANNON_SHOOT")
	check(game.objects.size() == 1 and sounds.size() == 1,label+" single sound and launch")
	game.view.present(game.view_snapshot(),0.0,0.0)
	var shot_view = game.view.object_views.get(shot["id"])
	check(shot_view != null and shot_view.atlas != null and int(shot_view.frame.get("frame",-1)) == 0,
		label+" draws the first original projectile frame")
	game.step_objects(70.0)
	game.view.present(game.view_snapshot(),0.0,0.0)
	check(shot_view != null and int(shot_view.frame.get("frame",-1)) == 1,label+" draws the second frame at 70 ms")
	game.step_objects(430.0)
	check(shot["pos"] == start+Vector2(200*facing,0),label+" original horizontal travel")
	check(shot["z"] == (13.0 if slot == 0 else 50.0),label+" each slot uses its own gravity")
	var last_age := 583.0 if slot == 0 else 999.0
	game.step_objects(last_age-500.0)
	check(game.objects.size() == 1,label+" survives prior sample")
	game.step_objects(1.0)
	check(game.objects.is_empty(),label+" vanishes on the ground or at source lifetime")

func check_contact(cannon: Dictionary) -> void:
	for height in [200.0,0.0]:
		game.restart()
		game.bus.clear_history()
		game.player["pos"] = Vector2(620,300)
		game.player["z"] = height
		game.player["invuln_ms"] = 0.0
		var hp := float(game.player["hp"])
		game.enemy_attack(shot_actor(cannon,1,0,730.0),1.0)
		game.step_objects(500.0)
		var hits: Array = game.bus.events_of("combat.hit")
		if height == 0.0:
			check(float(game.player["hp"]) < hp and hits.size() == 1 and hits[0]["atk"] == CANNON_ATK,
				"grounded player takes a hit from the original projectile ATK")
			game.step_objects(1.0)
			check(game.bus.events_of("combat.hit").size() == 1,"one shell does not hit a player twice")
		else:
			check(float(game.player["hp"]) == hp and hits.is_empty(),"same XY outside the vertical attack box misses")

func check_selection(cannon: Dictionary) -> void:
	check(cannon.has("native_attack_selection"),"source selection policy reaches the live monster")
	if not cannon.has("native_attack_selection"):return
	game.table.monsters["catapult"] = cannon
	var outcomes := {}
	for seed in range(24):
		game.restart()
		game.player["pos"] = Vector2(500,300)
		game.player["invuln_ms"] = 0.0
		var enemy: Dictionary = game.spawn_enemy(Vector2(350,300),false,"catapult")
		enemy["pos"] = Vector2(350,300)
		enemy["facing"] = 1
		game.rng.reseed(seed)
		game.update_enemy(enemy,2999.0)
		check(enemy["state"] == "idle" and int(enemy.get("native_attack_next_ms",0)) == 0,"no early attempt for seed %d"%seed)
		game.update_enemy(enemy,1.0)
		var deadline := int(enemy.get("native_attack_next_ms",0))
		check(deadline >= 4080 and deadline <= 4319,"source delay jitter for seed %d"%seed)
		var slot := int(enemy.get("move_index",-1))
		outcomes[slot] = true
		if slot >= 0:
			check(enemy["state"] == "attack" and enemy["clock"] == 0.0,"native selection enters the chosen Fire state")
	check(outcomes.has(-1) and outcomes.has(0) and outcomes.has(1),"live target can pass either slot or neither")
