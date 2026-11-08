extends SceneTree
## Actual action -> effect API integration. Native cast onset/animation is not certified.
const Numbers = preload("res://stats/api/numbers.gd")
const Actor = preload("res://stats/api/actor_numbers.gd")
const Session = preload("res://flow/session.gd")
var checks := 0
var failures := 0

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		print("[SKILL_EFFECTS] FAIL ",label)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var game = load("res://scenes/main.tscn").instantiate()
	game.external_mode = true
	game._muted = true
	root.add_child(game)
	game.set_process(false)
	game.set_physics_process(false)
	check(not game.missing_assets,"internal combat scene loads existing skill resources")
	var session = Session.new()
	session.command("numbers.level",{"level":60})
	for rank in [1,10]:
		game.restart()
		game.numeric_player = Actor.new()
		game.numeric_player.configure(session.stats())
		game.skill_levels = {"magicalattackup":rank}
		game.table.configure_skills(game.skill_levels,"swordman","katana")
		game.max_hp = float(game.numeric_player.values["hp_max"])
		game.max_mp = float(game.numeric_player.values["mp_max"])
		game.player["hp"] = game.max_hp
		game.player["mp"] = game.max_mp
		var before: Dictionary = game.numeric_player.values.duplicate(true)
		var move: Dictionary = game.move_def("magicalattackup")
		check(move["effect_id"]=="magical_memory" and move["cast_ms"]==500 and move["cool_ms"]==40000,"compiled move keeps source effect, cast and cooldown inputs")
		check(game.start_action("magicalattackup"),"learned ancient memory starts through the actual action path")
		check(game.numeric_player.effects.active["magical_memory"]["rank"]==rank,"actual action passes learned rank into effect application")
		check(game.numeric_player.values["intelligence"]-before["intelligence"]==rank*15,"actual cast receives source-ranked intelligence")
		check(game.numeric_player.values["magical_attack"]==before["magical_attack"],"actual cast has no fabricated weapon-attack percentage")
		check(game.player["buff_ms"]==20000 and game.numeric_player.effects.active["magical_memory"]["remaining_ms"]==20000,"effect presentation receives sampled duration")
		check(is_equal_approx(game.player["mp"],game.max_mp-float(move["mp"])*float(before["mp_cost_rate"])),"existing sampled MP is paid once; interpolation is not native-certified here")
		game.player["state"] = "idle"
		check(not game.start_action("magicalattackup"),"cooldown still rejects a repeat cast")
		game.numeric_player.step(20000)
		check(game.numeric_player.values==before and not game.numeric_player.effects.active.has("magical_memory"),"real combat numeric actor returns to base after source duration")
	check_khazan(game,session)
	game.queue_free()
	await process_frame
	print("[SKILL_EFFECTS] COMPLETE checks=",checks," failures=",failures)
	quit(0 if failures==0 else 1)

func check_khazan(game, session) -> void:
	game.restart()
	game.numeric_player = Actor.new()
	game.numeric_player.configure(session.stats())
	game.skill_levels = {"khazan":1}
	game.table.configure_skills(game.skill_levels,"swordman","katana")
	game.player["mp"] = game.numeric_player.values["mp_max"]
	var origin := Vector2(400,250)
	game.player["pos"] = origin
	game.player["facing"] = 1
	var target: Dictionary = game.spawn_enemy(origin+Vector2(100,0))
	var hp := float(target["hp"])
	var strength := float(game.numeric_player.values["strength"])
	var intelligence := float(game.numeric_player.values["intelligence"])
	check(game.start_action("khazan"), "Khazan starts through actual skill action")
	check(game.objects.is_empty() and game.active_effect("khazan_aura").is_empty(), "pre-placement cast grants no aura")
	game.step_action(2000,Vector2.ZERO)
	check(game.objects.size()==1,"cast places a single field object")
	if game.objects.size()!=1:return
	var field: Dictionary = game.objects[0]
	check(field["pos"]==origin+Vector2(122,0) and field["life_ms"]==120000,"field uses original mirrored X argument and dungeon duration")
	game.step_objects(1)
	check(game.numeric_player.values["strength"]==strength+31 and game.numeric_player.values["intelligence"]==intelligence+31,"rank one field grants both source columns")
	game.pulse_passive_auras()
	check(float(target["hp"])==hp,"placement and aura do not damage the enemy")
	game.player["pos"] = origin+Vector2(500,0)
	game.step_objects(1000)
	check(game.active_effect("khazan_aura").is_empty() and game.numeric_player.values["strength"]==strength,"leaving the placed field removes its bonus")
	game.player["pos"] = origin
	game.step_objects(1)
	check(game.active_effect("khazan_aura").get("remaining_ms")==118998,"re-entry grants only the field's remaining life")
	game.skill_levels["khazan"] = 4
	game.table.configure_skills(game.skill_levels,"swordman","katana")
	game.player["cooldowns"].erase("khazan")
	game.player["facing"] = -1
	check(game.start_action("khazan"),"recast starts after cooldown")
	game.step_action(2000,Vector2.ZERO)
	check(game.objects.size()==1 and game.objects[0]["id"]!=field["id"] and game.objects[0]["pos"]==origin-Vector2(122,0),"recast replaces old field and mirrors placement")
	game.step_objects(1)
	check(game.numeric_player.values["strength"]==strength+58 and game.numeric_player.values["intelligence"]==intelligence+58,"replacement uses rank four without stacking")
	game.step_objects(119999)
	check(game.objects.is_empty() and game.active_effect("khazan_aura").is_empty() and game.numeric_player.values["strength"]==strength,"field and modifier end at source lifetime")
