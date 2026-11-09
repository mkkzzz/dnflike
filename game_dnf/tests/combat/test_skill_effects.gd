extends SceneTree
## Actual action -> effect API integration and the source ghost cast boundaries.
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
	check_ghost_casts(game,session)
	check_khazan(game,session)
	game.queue_free()
	await process_frame
	print("[SKILL_EFFECTS] COMPLETE checks=",checks," failures=",failures)
	quit(0 if failures==0 else 1)

func check_ghost_casts(game, session) -> void:
	for sample: Array in [["khazan",150,250],["bremen",200,300]]:
		var name := String(sample[0])
		for rates: Array in [[1000,1000],[1001,1001],[1600,1600],[1600,1250]]:
			game.restart()
			game.numeric_player = Actor.new()
			game.numeric_player.configure(session.stats())
			game.numeric_player.values["cast_speed"] = float(rates[0])/1000.0
			game.skill_levels = {name:1}
			game.table.configure_skills(game.skill_levels,"swordman","katana")
			game.player["mp"] = game.numeric_player.values["mp_max"]
			var release_ms := int(float(sample[1])*1000.0/float(rates[0]))
			var recovery_ms := int(sample[2])
			var label := "%s %d/%d" % [name,rates[0],rates[1]]
			check(game.start_action(name),label+" starts the source cast")
			check(game.player_ani()==["throw1",0.0] and game.objects.is_empty(),label+" starts in Throw1 with no field")
			game.step_action(release_ms-1,Vector2.ZERO)
			var before: Array = game.player_ani()
			check(before[0]=="throw1" and is_equal_approx(float(before[1]),float(release_ms-1)*float(rates[0])/1000.0) and game.objects.is_empty(),label+" uses the cast-rate Throw1 clock until one ms before release")
			game.view.present(game.view_snapshot(),0,0)
			check(game.view.player_actor.pose=="throw1" and not game.view.player_actor.sample().is_empty() and not game.player_damage_boxes().is_empty(),label+" the view and damage boxes consume Throw1")
			game.numeric_player.values["cast_speed"] = float(rates[1])/1000.0
			game.step_action(1,Vector2.ZERO)
			check(game.player_ani()==["throw2",0.0] and game.objects.size()==1,label+" switches to Throw2 and creates exactly one field at release")
			game.view.present(game.view_snapshot(),0,0)
			check(game.view.player_actor.pose=="throw2" and not game.view.player_actor.sample().is_empty() and not game.player_damage_boxes().is_empty(),label+" the view and damage boxes consume Throw2")
			game.step_action(recovery_ms-1,Vector2.ZERO)
			check(game.player_ani()==["throw2",float(recovery_ms-1)] and game.objects.size()==1,label+" keeps the native base-rate release pose and fixed recovery")
			game.step_action(1,Vector2.ZERO)
			check(game.player["state"]=="idle" and game.objects.size()==1,label+" recovers at the exact boundary without generating another field")
			check(not game.start_action(name),label+" still enforces cooldown after recovery")
		game.restart()
		game.numeric_player = Actor.new()
		game.numeric_player.configure(session.stats())
		game.player["mp"] = game.numeric_player.values["mp_max"]
		game.player["invuln_ms"] = 0.0
		check(game.start_action(name),name+" starts the interrupt fixture")
		game.step_action(1,Vector2.ZERO)
		game.damage_player(10,Vector2(game.player["pos"])+Vector2(20,0))
		game.step_player(600,Vector2.ZERO)
		check(game.player["action"]=="" and game.player["native_phase"].is_empty() and game.objects.is_empty(),name+" a hit during charge prevents the field")

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
	var field_id: int = field["id"]
	check(field["pos"]==origin+Vector2(122,0) and field["life_ms"]==120000,"field uses original mirrored X argument and dungeon duration")
	game.step_objects(1)
	check(game.numeric_player.values["strength"]==strength+31 and game.numeric_player.values["intelligence"]==intelligence+31,"rank one field grants both source columns")
	var view = game.view
	view.present(game.view_snapshot(),0,0)
	var ghost = view.object_views.get("%s:ghost"%field_id)
	var first_ring = view.object_views.get("%s:entry:0"%field_id)
	var second_ring = view.object_views.get("%s:entry:1"%field_id)
	check(ghost!=null and ghost.atlas!=null and String(ghost.data["source"]).ends_with("/khazan2.ani"),"second source ghost draws from its own image bank")
	check(first_ring!=null and first_ring.atlas!=null and not first_ring.frame.has("sprite"),"first source ring preserves its opening blank frames")
	check(second_ring!=null and second_ring.atlas!=null and int(second_ring.frame.get("img_frame",-1))==0,"second source ring shows its first visible frame at placement")
	game.pulse_passive_auras()
	check(float(target["hp"])==hp,"placement and aura do not damage the enemy")
	game.step_objects(1039)
	view.present(game.view_snapshot(),0,0)
	var stay = view.object_views.get("%s:stay"%field_id)
	check(stay!=null and stay.loop and stay.clock_ms==0 and int(stay.frame.get("img_frame",-1))==13,"appearance switches to the original looping stay frames")
	check(stay!=null and is_equal_approx(stay.base_scale,250.0/233.0),"the source static radius scales the area sprites by 250/233")
	check(not view.object_views.has("%s:entry:0"%field_id) and not view.object_views.has("%s:entry:1"%field_id),"stay detaches both appearance layers")
	check(ghost!=null and is_equal_approx(ghost.fade,180.0/255.0),"the ghost layers reach original maximum opacity")
	game.player["pos"] = origin+Vector2(500,0)
	game.step_objects(99)
	check(not game.active_effect("khazan_aura").is_empty(),"leaving the field waits for the next original 100ms membership scan")
	game.step_objects(1)
	check(game.active_effect("khazan_aura").is_empty() and game.numeric_player.values["strength"]==strength,"the membership scan removes the bonus outside the placed field")
	game.player["pos"] = origin
	game.step_objects(100)
	check(game.active_effect("khazan_aura").get("remaining_ms")==118760,"re-entry grants only the field's remaining life")
	for sample: Array in [[Vector2(0,72),true],[Vector2(0,73),false],[Vector2(250,-6),true],[Vector2(250,-7),false]]:
		game.player["pos"] = Vector2(field["pos"])+Vector2(sample[0])
		game.step_objects(100)
		check((not game.active_effect("khazan_aura").is_empty())==bool(sample[1]),"source projected and truncated aura range at "+str(sample[0]))
	game.player["pos"] = origin
	game.skill_levels["khazan"] = 4
	game.table.configure_skills(game.skill_levels,"swordman","katana")
	game.player["cooldowns"].erase("khazan")
	game.player["facing"] = -1
	check(game.start_action("khazan"),"recast starts after cooldown")
	game.step_action(2000,Vector2.ZERO)
	check(game.objects.size()==2 and game.objects[1]["id"]!=field_id and game.objects[1]["pos"]==origin-Vector2(122,0),"recast mirrors the new field and leaves the old exit visual")
	if game.objects.size()!=2:return
	var new_id: int = game.objects[1]["id"]
	game.step_objects(1)
	check(game.numeric_player.values["strength"]==strength+58 and game.numeric_player.values["intelligence"]==intelligence+58,"replacement uses rank four without stacking")
	view.present(game.view_snapshot(),0,0)
	var exit_ring = view.object_views.get("%s:exit"%field_id)
	check(exit_ring!=null and not exit_ring.loop and int(exit_ring.frame.get("img_frame",-1))==17,"recast switches the old field to its original exit ANI")
	game.step_objects(159)
	view.present(game.view_snapshot(),0,0)
	check(ghost!=null and is_equal_approx(ghost.fade,90.0/255.0),"replaced ghost fades over the exit interval")
	game.step_objects(160)
	check(game.objects.size()==1 and game.objects[0]["id"]!=field_id,"old field disappears when its exit ANI ends")
	game.step_objects(119359)
	check(not game.active_effect("khazan_aura").is_empty(),"field still grants its bonus one millisecond before native exit")
	game.step_objects(1)
	view.present(game.view_snapshot(),0,0)
	check(view.object_views.has("%s:exit"%new_id) and game.numeric_player.values["strength"]==strength+58,"native exit starts 320ms before total lifetime and the aura is still active")
	game.step_objects(320)
	check(game.objects.is_empty() and game.active_effect("khazan_aura").is_empty() and game.numeric_player.values["strength"]==strength,"expired field and modifier are deleted at the total source lifetime")
