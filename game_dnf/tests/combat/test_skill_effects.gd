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
	game.view.audio.muted = true
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
	check_ghost_cast_sounds(game,session)
	check_khazan(game,session)
	check_saya(game,session)
	game.queue_free()
	await process_frame
	print("[SKILL_EFFECTS] COMPLETE checks=",checks," failures=",failures)
	quit(0 if failures==0 else 1)

func check_ghost_casts(game, session) -> void:
	for sample: Array in [["khazan",150,250],["bremen",200,300],["saya",250,450]]:
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

func check_ghost_cast_sounds(game, session) -> void:
	var audio = game.view.audio
	var was_muted: bool = audio.muted
	audio.muted = false
	for sample: Array in [["khazan",150,"SM_GHOST_KAZHAN","GHOST_KAJAN"],
			["bremen",200,"SM_GHOST_BREMEN","GHOST_BREMEN"],["saya",250,"SM_GHOST_SAYA","GHOST_SAYA"]]:
		var skill := String(sample[0])
		var cast_key := String(sample[2])
		var field_key := String(sample[3])
		game.restart()
		for voice in audio.voice_pool:voice.stop()
		game.numeric_player = Actor.new()
		game.numeric_player.configure(session.stats())
		game.numeric_player.values["cast_speed"] = 1.0
		game.skill_levels = {skill:1}
		game.table.configure_skills(game.skill_levels,"swordman","katana")
		game.player["mp"] = game.numeric_player.values["mp_max"]
		game.bus.clear_history()
		var cues := func() -> Array:
			return game.bus.events_of("combat.cue").filter(func(e):return e.get("kind")=="sound" and e["key"] in [cast_key,field_key]).map(func(e):return e["key"])
		check(game.start_action(skill),skill+" starts for the sound fixture")
		game.step_action(float(sample[1])-1.0,Vector2.ZERO)
		check(cues.call().is_empty() and game.objects.is_empty(),skill+" charge remains silent")
		game.step_action(1.0,Vector2.ZERO)
		check(cues.call()==[cast_key] and game.objects.size()==1,skill+" actor sound plays at release before the field updates")
		game.step_objects(0.0)
		check(cues.call()==[cast_key,field_key],skill+" first field update emits its own sound even at age zero")
		for key: String in [cast_key,field_key]:
			var stream = audio.variants.get(key,[null])[0]
			check(stream is AudioStreamOggVorbis and audio.voice_pool.any(func(voice):return voice.stream==stream and voice.playing),key+" original stream reaches the audio player")
		game.step_objects(0.0)
		game.step_objects(1000.0)
		game.step_objects(40000.0)
		check(cues.call()==[cast_key,field_key],skill+" zero-time updates, pulses and expiry do not repeat either sound")
	audio.muted = was_muted

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

func check_saya(game, session) -> void:
	var rolls := RandomNumberGenerator.new()
	var freeze_seed := -1
	for candidate: int in range(128):
		rolls.seed = candidate
		var accuracy := rolls.randf()
		rolls.randf() # The damage path also samples a critical roll.
		if accuracy < 0.8 and rolls.randf() < 0.147:
			freeze_seed = candidate
			break
	check(freeze_seed >= 0,"deterministic Saya hit and freeze fixture")
	for sample: Array in [[1,251,0.147,40,1950],[4,329,0.153,48,2258]]:
		var rank := int(sample[0])
		var label := "Saya rank %d" % rank
		game.restart()
		game.monsters.clear()
		game.numeric_player = Actor.new()
		game.numeric_player.configure(session.stats())
		game.numeric_player.values["cast_speed"] = 1.0
		game.numeric_player.values["hit"] = 1.0
		game.skill_levels = {"saya":rank}
		game.table.configure_skills(game.skill_levels,"swordman","katana")
		game.player["mp"] = game.numeric_player.values["mp_max"]
		var origin := Vector2(400,250)
		var center := origin+Vector2(122,0)
		game.player["pos"] = origin
		game.player["facing"] = 1
		var inside: Dictionary = game.spawn_enemy(center+Vector2(250,0))
		var outside: Dictionary = game.spawn_enemy(center-Vector2(251,0))
		var too_high: Dictionary = game.spawn_enemy(center)
		inside["hp"] = 100000.0
		inside["numeric"].values["status_resist"] = 0.0
		too_high["z"] = 71.0
		var outside_hp := float(outside["hp"])
		var high_hp := float(too_high["hp"])
		var move: Dictionary = game.move_def("saya")
		var hit: Dictionary = move["stages"][0]["hits"][0]
		var freeze: Dictionary = hit["effects"][0]
		check(move["stages"][0]["hits"].size()==1 and move["stages"][0]["fx"].is_empty(),label+" has no unrelated cast contact box or effect")
		check(hit["percent"]==sample[1] and is_equal_approx(float(freeze["chance"]),float(sample[2])) and freeze["status_level"]==sample[3] and freeze["duration_ms"]==sample[4],label+" compiles original damage and freeze columns")
		game.bus.clear_history()
		game.rng.reseed(freeze_seed)
		check(game.start_action("saya"),label+" starts through the actual action path")
		game.step_action(249,Vector2.ZERO)
		game.pulse_passive_auras()
		check(game.objects.is_empty() and game.bus.events_of("combat.damage").is_empty() and game.active_effect("saya_aura").is_empty(),label+" has neither pre-release damage nor a caster aura")
		game.step_action(1,Vector2.ZERO)
		check(game.objects.size()==1,label+" creates exactly one field at release")
		if game.objects.size()!=1:continue
		var field: Dictionary = game.objects[0]
		var field_id := int(field["id"])
		check(field["pos"]==center and field["life_ms"]==13000 and field["exit_at_ms"]==12680,label+" matches the native field offset and lifetime")
		game.step_objects(17,field_id)
		var hits: Array = game.bus.events_of("combat.hit")
		check(field["clock"]==0.0 and hits.size()==1 and hits[0]["target"]==inside["id"] and hits[0]["point"]==Vector3(inside["pos"].x,inside["pos"].y,35.0),label+" first pulse uses field age zero and the native impact height")
		check(outside["hp"]==outside_hp and too_high["hp"]==high_hp and inside["hp"]<100000,label+" strikes only hostiles inside radius 250 and at height <=70")
		var resolved: Dictionary = game.last_damage
		check(resolved.get("category")=="magical" and resolved.get("element")=="water" and is_equal_approx(float(resolved.get("trace",{}).get("percent_part",0)),float(game.numeric_player.values["magical_attack"])*float(sample[1])/100.0),label+" applies the sampled percentage as water magic")
		var applied: Dictionary = inside["numeric"].effects.active.get("freeze",{})
		check(applied.get("remaining_ms")==sample[4] and applied.get("definition",{}).get("status_level")==sample[3],label+" the live freeze receives source level and duration")
		var hp_after_first := float(inside["hp"])
		game.view.present(game.view_snapshot(),0,0)
		check(game.view.object_views.has("%s:ghost"%field_id) and game.view.object_views.has("%s:entry:0"%field_id) and game.view.object_views.has("%s:entry:1"%field_id),label+" draws both ghost and entrance layers")
		game.player["pos"] = origin-Vector2(500,0)
		game.step_objects(999)
		check(inside["hp"]==hp_after_first,label+" waits the full 1000ms between pulses")
		inside["z"] = 70.0
		game.rng.reseed(freeze_seed)
		game.step_objects(1)
		check(inside["hp"]<hp_after_first and outside["hp"]==outside_hp and too_high["hp"]==high_hp,label+" next pulse stays on the placed field and accepts the inclusive height limit")
		game.step_objects(40)
		game.view.present(game.view_snapshot(),0,0)
		check(game.view.object_views.has("%s:stay"%field_id) and not game.view.object_views.has("%s:entry:0"%field_id),label+" switches to the original stay clip at 1040ms")
		inside["pos"] = center+Vector2(400,0)
		if rank==4:
			game.step_action(450,Vector2.ZERO)
			game.player["cooldowns"].erase("saya")
			game.player["facing"] = -1
			check(game.start_action("saya"),label+" starts a recast with cleared cooldown")
			game.step_action(250,Vector2.ZERO)
			check(game.objects.size()==2 and not field.get("superseded",false) and game.objects[1]["pos"]==Vector2(game.player["pos"])-Vector2(122,0),label+" mirrors placement and keeps the previous native field")
		game.step_objects(11640)
		game.view.present(game.view_snapshot(),0,0)
		check(game.view.object_views.has("%s:exit"%field_id),label+" enters the original exit clip at 12680ms")
		game.step_objects(320)
		check(game.objects.all(func(object):return int(object["id"])!=field_id),label+" deletes the original field at 13000ms")
