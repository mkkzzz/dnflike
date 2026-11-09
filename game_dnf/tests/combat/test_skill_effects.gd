extends SceneTree
## Actual action -> effect API integration and the source ghost cast boundaries.
const Numbers = preload("res://stats/api/numbers.gd")
const Actor = preload("res://stats/api/actor_numbers.gd")
const Session = preload("res://flow/session.gd")
const DetRng = preload("res://core/det_rng.gd")
const MonsterAI = preload("res://combat/ai/monster_ai.gd")
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
	game.restart()
	var ordinary: Dictionary = game.spawn_enemy(Vector2(400,250))
	var ordinary_snapshot: Array = game.view_snapshot()["enemies"].filter(func(enemy):return enemy["id"]==ordinary["id"])
	check(not ordinary.has("numeric") and ordinary_snapshot.size()==1 and not ordinary_snapshot[0]["blind"],
		"the standalone nonnumeric monster keeps its regular view snapshot")
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
	check_bremen_freeze(game,session)
	check_rasa(game,session)
	check_rasa_blind(game,session)
	check_native_monster_vision(game,session)
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

func saya_freeze_seed(low: int, high: int) -> int:
	var rolls = DetRng.new()
	for candidate: int in range(10000):
		rolls.reseed(candidate)
		var accuracy: float = rolls.next_float()
		rolls.next_float() # The damage path also samples a critical roll.
		var status_roll: int = rolls.range_int(0,9999)
		if accuracy < 0.8 and status_roll >= low and status_roll <= high:return candidate
	return -1

func check_saya(game, session) -> void:
	var freeze_seed := saya_freeze_seed(0,1469)
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
		inside["numeric"].values["level"] = sample[3]
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

func check_bremen_freeze(game, session) -> void:
	# Equal rank and resistance gives a strict 2500/10000 threshold.
	var actor = Actor.new()
	actor.configure({"numbers":Numbers.shared_config()["base"].merged({"level":40},true)})
	check(actor.source_freeze_duration(0.25,40,1950,2499)==1950 and actor.source_freeze_duration(0.25,40,1950,2500)==0,"native freeze compares the integer roll strictly to the threshold")
	check(actor.source_freeze_duration(0.25,20,1950,0)==0,"twenty levels of disadvantage reduce native freeze chance to zero")
	actor.values["abnormal_resistance"] = 100
	check(actor.source_freeze_duration(0.25,40,1950,0)==0,"100 raw abnormal resistance prevents native freeze")
	# Each seeded roll falls between the two thresholds calculated from the PVF
	# coefficients, the target level and the signed Bremen source row.
	for sample: Array in [[1,45,0,1103,1124,1852],[4,35,25,1379,1488,2047]]:
		var rank := int(sample[0])
		var resistance := int(sample[2])
		var label := "Bremen rank %d with Saya rank 1" % rank
		var seed_value := saya_freeze_seed(int(sample[3]),int(sample[4]))
		check(seed_value>=0,label+" has a deterministic roll between the two thresholds")
		game.restart()
		game.monsters.clear()
		game.numeric_player = Actor.new()
		game.numeric_player.configure(session.stats())
		game.numeric_player.values["cast_speed"] = 1.0
		game.numeric_player.values["hit"] = 1.0
		game.skill_levels = {"bremen":rank,"saya":1}
		game.table.configure_skills(game.skill_levels,"soulbringer","katana")
		game.player["mp"] = game.numeric_player.values["mp_max"]
		var origin := Vector2(400,250)
		game.player["pos"] = origin
		game.player["facing"] = 1
		var enemy: Dictionary = game.spawn_enemy(origin+Vector2(122,0))
		var target = enemy["numeric"]
		target.configure({"numbers":target.base.merged({"level":sample[1],"abnormal_resistance":resistance,"hp_max":10000.0},true)})
		enemy["hp"] = float(target.values["hp_max"])
		game.bus.clear_history()
		check(game.start_action("saya"),label+" casts the source freeze field")
		game.step_action(250,Vector2.ZERO)
		game.step_action(450,Vector2.ZERO)
		game.rng.reseed(seed_value)
		game.step_objects(0.0)
		check(game.hit_count==1 and not target.effects.active.has("freeze"),label+" first pulse hits but its roll fails without Bremen")
		game.player["pos"] = origin-Vector2(100,0)
		check(game.start_action("bremen"),label+" casts the source resistance field")
		game.step_action(200,Vector2.ZERO)
		game.step_objects(250.0)
		check(target.effects.active.has("bremen_debuff") and target.values["abnormal_resistance"]==resistance-(2 if rank==1 else 6),label+" applies the signed source row before the next Saya pulse")
		game.rng.reseed(seed_value)
		game.step_objects(750.0)
		var frozen: Dictionary = target.effects.active.get("freeze",{})
		check(game.hit_count==2 and frozen.get("remaining_ms",0)==sample[5],label+" the same roll freezes for the native level-adjusted integer duration")
		target.remove_effect("freeze")
		enemy["pos"] = origin+Vector2(302,0) # Still in Saya, now outside the Bremen field.
		game.step_objects(250.0)
		check(not target.effects.active.has("bremen_debuff") and target.values["abnormal_resistance"]==resistance,label+" restores the base resistance at the next area check")
		game.rng.reseed(seed_value)
		game.step_objects(750.0)
		check(game.hit_count==3 and not target.effects.active.has("freeze"),label+" the same roll fails again after leaving Bremen")

func check_rasa(game, session) -> void:
	game.restart()
	game.monsters.clear()
	game.numeric_player = Actor.new()
	game.numeric_player.configure(session.stats())
	game.numeric_player.values["cast_speed"] = 1.0
	game.skill_levels = {"epidemicrasa":1}
	game.table.configure_skills(game.skill_levels,"soulbringer","katana")
	game.player["mp"] = game.numeric_player.values["mp_max"]
	var origin := Vector2(400,250)
	var center := origin+Vector2(122,0)
	game.player["pos"] = origin
	game.player["facing"] = 1
	var target: Dictionary = game.spawn_enemy(center+Vector2(233,0))
	var lower: Dictionary = game.spawn_enemy(center-Vector2(70,0))
	var outside: Dictionary = game.spawn_enemy(center-Vector2(234,0))
	target["pos"] = center+Vector2(233,0)
	outside["pos"] = center-Vector2(234,0)
	var actor = target["numeric"]
	actor.configure({"numbers":actor.base.merged({"hp_max":5000,"physical_defense":5000,"hit_recovery":600},true)})
	actor.set_runtime_modifiers([{"source":"fixture","stat":"hit_recovery","op":"add","value":5}])
	check(actor.add_effect("bremen_debuff",1),"Rasa fixture has an independent Bremen effect")
	target["hp"] = 5000.0
	outside["hp"] = 6000.0
	var seed_value := rasa_contact_seed()
	check(seed_value>=0,"Rasa seed gives three child contact fixtures")
	game.bus.clear_history()
	check(game.start_action("epidemicrasa"),"Rasa starts through the learned source move")
	game.step_action(249,Vector2.ZERO)
	check(game.player_ani()[0]=="throw1" and game.objects.is_empty(),"Rasa shares the state 13 charge and creates no pre-release object")
	game.step_action(1,Vector2.ZERO)
	check(game.objects.size()==1 and game.player_ani()[0]=="throw2","Rasa release creates only one creator and enters Throw2")
	if game.objects.size()!=1:return
	var creator: Dictionary = game.objects[0]
	var creator_id := int(creator["id"])
	check(creator["hit"]["object"].ends_with("/epidemicrasacreater.obj") and creator["pos"]==center and creator["life_ms"]==26000.0 and creator["exit_at_ms"]==25680.0,"Rasa uses original creator, offset, level lifespan and exit boundary")
	var voices: Array = game.bus.events_of("combat.cue").filter(func(event: Dictionary):return event.get("key","")=="SM_RASA")
	check(voices.size()==1,"Rasa release emits its own original voice once")
	game.view.present(game.view_snapshot(),0,0)
	check(game.view.object_views.has("%s:entry:0"%creator_id) and game.view.object_views.has("%s:entry:1"%creator_id) and game.view.object_views.has("%s:ghost"%creator_id),"Rasa creator draws both entrance rings and the ghost overlay")
	game.step_objects(999)
	check(game.objects.size()==1 and game.hit_count==0,"Rasa waits until the 1000ms selection threshold without fake direct damage")
	game.rng.reseed(seed_value)
	game.step_objects(1)
	var children: Array = game.objects.slice(1)
	check(children.size()==4,"Rasa pulse creates the four original child objects")
	if children.size()!=4:return
	var first_child_id := int(children[0]["id"])
	for child: Dictionary in children:
		var offset := Vector2(child["pos"])-Vector2(target["pos"])
		check(child["hit"]["object"].ends_with("/epidemicrasa.obj") and child["life_ms"]==13000.0 and absf(offset.x)<=63.0 and absf(offset.y)<=31.0,"each child uses its own original object and spawn rectangle around highest eligible HP")
	game.view.present(game.view_snapshot(),0,0)
	check(game.view.object_views.has("%s:startup"%first_child_id) and game.view.object_views.has("%s:startup:overlay"%first_child_id),"Rasa child uses both original startup layers")
	game.step_objects(40)
	game.view.present(game.view_snapshot(),0,0)
	check(game.view.object_views.has("%s:stay"%creator_id),"Rasa creator changes to stay at 1040ms")
	game.step_objects(1159)
	check(game.rasa_attachment_count(int(target["id"]))==0,"Rasa children do not attach during startup")
	target["ai"] = false
	game.update_enemy(target,17.0)
	target["ai"] = true
	target["cooldown_ms"] = 0.0
	game.player["pos"] = Vector2(target["pos"])-Vector2(35,0)
	game.update_enemy(target,83.0)
	game.player["pos"] = origin
	check(target["state"]=="attack" and target["clock"]==0.0,"Rasa timing fixture starts an ordinary monster attack through its AI")
	game.step_objects(1)
	check(game.rasa_attachment_count(int(target["id"]))==3 and game.rasa_attachment_count(int(lower["id"]))==0,"real stay attack boxes attach up to three to the selected target")
	check(actor.values["physical_defense"]==1973.0 and actor.values["hit_recovery"]==545.0 and actor.effects.active.has("bremen_debuff"),"Rasa deducts source equipment defense and hit recovery alongside other modifiers")
	check(is_equal_approx(float(actor.values["attack_speed"]),0.979),"three rank-one Rasa attachments add three source 7-per-mille attack slow modifiers")
	game.update_enemy(target,180.0)
	check(target["clock"]==180.0,"Rasa attachment waits for the monster's next rate sample")
	game.paused = true
	game._physics_process(0.5)
	target["stuck_ms"] = 100.0
	game.update_enemy(target,100.0)
	check(target["clock"]==180.0 and target["attack_rate_refresh_ms"]==37.0,"game pause and local hitstop preserve the attack-rate deadline")
	game.update_enemy(target,36.0)
	check(target["clock"]==216.0,"the ongoing attack retains its old rate one millisecond before the deadline")
	game.update_enemy(target,6.0)
	check(target["clock"]==222.0 and target["attack_rate_refresh_ms"]==300.0,"a late poll starts a full new interval from its actual update time")
	game.update_enemy(target,1.0)
	check(is_equal_approx(float(target["clock"]),222.979),"the attack slows from the first update at or after its rate deadline")
	var attached: Array = children.filter(func(child: Dictionary):return child.has("rasa_target_id"))
	if attached.is_empty():return
	var attached_id := int(attached[0]["id"])
	game.view.present(game.view_snapshot(),0,0)
	check(game.view.object_views.has("%s:grab"%attached_id) and game.view.object_views.has("%s:grab:overlay"%attached_id),"Rasa actual contact enters the two-layer grab motion")
	target["pos"] = center+Vector2(300,0)
	lower["hp"] = 0.0
	game.step_objects(900)
	game.view.present(game.view_snapshot(),0,0)
	check(game.view.object_views.has("%s:grab_stay"%attached_id) and Vector2(attached[0]["pos"]).x==Vector2(target["pos"]).x,"Rasa attachment follows the enemy outside the field and enters grab-stay")
	game.step_objects(12099)
	check(game.rasa_attachment_count(int(target["id"]))==3,"Rasa attachment survives until its sampled final millisecond")
	game.step_objects(1)
	check(game.rasa_attachment_count(int(target["id"]))==0 and actor.values["physical_defense"]==5000 and actor.values["hit_recovery"]==605 and actor.effects.active.has("bremen_debuff"),"Rasa expiration removes only its own modifiers")
	check(is_equal_approx(float(actor.values["attack_speed"]),1.0),"Rasa expiration restores the unmodified attack clock rate")
	var after_detach := float(target["clock"])
	game.update_enemy(target,298.0)
	check(is_equal_approx(float(target["clock"])-after_detach,298.0*0.979),"the ongoing attack stays slowed before the next sample after detachment")
	var before_refresh := float(target["clock"])
	game.update_enemy(target,1.0)
	var at_refresh := float(target["clock"])
	check(is_equal_approx(at_refresh-before_refresh,0.979),"elapsed animation time before the rescheduled sample keeps the sampled slow")
	game.update_enemy(target,1.0)
	check(is_equal_approx(float(target["clock"])-at_refresh,1.0),"the attack resumes its original rate at the next sample after detachment")
	game.update_enemy(target,20.0)
	game.step_objects(float(creator["exit_at_ms"])-float(creator["clock"]))
	game.view.present(game.view_snapshot(),0,0)
	check(game.view.object_views.has("%s:exit"%creator_id),"Rasa creator uses the original exit ring at 25680ms")
	game.step_objects(320)
	check(game.objects.is_empty(),"Rasa removes the creator at 26000ms")
	game.step_action(450,Vector2.ZERO)
	game.player["cooldowns"].erase("epidemicrasa")
	target["pos"] = center+Vector2(233,0)
	check(game.start_action("epidemicrasa"),"Rasa death fixture starts a new cast")
	game.step_action(250,Vector2.ZERO)
	game.rng.reseed(seed_value)
	game.step_objects(1000)
	game.step_objects(1200)
	check(game.rasa_attachment_count(int(target["id"]))==3,"Rasa death fixture has real attachments")
	target["cooldown_ms"] = 0.0
	game.player["pos"] = Vector2(target["pos"])-Vector2(35,0)
	game.update_enemy(target,1.0)
	game.player["pos"] = origin
	var before_advance := float(target["attack_rate_refresh_ms"])
	game.update_enemy(target,100.0)
	check(target["state"]=="attack" and before_advance>100.0 and is_equal_approx(float(target["clock"]),97.9),"a newly chosen attack reads the attached rate immediately before the next periodic sample")
	target["hp"] = 0.0
	game.step_objects(0.0)
	check(game.rasa_attachment_count(int(target["id"]))==0 and actor.values["physical_defense"]==5000 and actor.values["hit_recovery"]==605 and actor.effects.active.has("bremen_debuff"),"Rasa removes only its own attachments immediately when their target dies")

func rasa_contact_seed() -> int:
	var roll = DetRng.new()
	for seed_value: int in range(20000):
		roll.reseed(seed_value)
		var close := 0
		for i in range(4):
			roll.range_int(0,1)
			roll.range_int(0,1)
			var x: int = roll.range_int(0,63)
			var y: int = roll.range_int(0,31)
			if x <= 12 and y <= 12:close += 1
		if close >= 3:return seed_value
	return -1

func rasa_blind_seed() -> int:
	var draw = DetRng.new()
	for seed_value in range(100):
		draw.reseed(seed_value)
		if draw.range_int(0,2)==1:return seed_value
	return -1

func check_rasa_blind(game, session) -> void:
	game.restart()
	game.monsters.clear()
	game.numeric_player = Actor.new()
	game.numeric_player.configure(session.stats())
	game.numeric_player.values["cast_speed"] = 1.0
	game.skill_levels = {"epidemicrasa":1}
	game.table.configure_skills(game.skill_levels,"soulbringer","katana")
	game.player["mp"] = game.numeric_player.values["mp_max"]
	var origin := Vector2(400,250)
	var point := origin+Vector2(122,0)
	game.player["pos"] = origin
	game.player["facing"] = 1
	var enemy: Dictionary = game.spawn_enemy(point)
	enemy["pos"] = point
	var actor = enemy["numeric"]
	actor.configure({"numbers":actor.base.merged({"level":47},true)})
	check(game.start_action("epidemicrasa"),"Rasa blind fixture casts the actual learned skill")
	game.step_action(250.0,Vector2.ZERO)
	game.rng.reseed(rasa_contact_seed())
	game.step_objects(1000.0)
	game.step_objects(1200.0)
	var attached: Array = game.objects.filter(func(object):return object.has("rasa_target_id"))
	check(attached.size()==3,"Rasa blind fixture has three real child attachments")
	if attached.size()!=3:return
	var late_child: Dictionary = attached[0]
	var controller: Dictionary = late_child["hit"]["native_controller"]
	var row: Dictionary = controller["blind"]
	check(row=={"chance":1.3,"level":47,"duration_ms":6500,"vision_percent":52,"stuck_percent":1}
		and controller["status_interval_ms"]==2600.0,"Rasa rank one compiles original blind columns and the child interval")

	var resister = Actor.new()
	resister.configure({"numbers":actor.base.merged({"blind_resistance":50},true)})
	check(not resister.apply_source_blind(row,6500) and resister.apply_source_blind(row,6499),"original 130 percent chance and 50 blind resistance give the strict 6500 boundary")
	resister.step(100.0)
	check(not resister.apply_source_blind(row,0) and resister.effects.active["blind"]["remaining_ms"]==6400.0,"equal blind strength and duration leave the previous expiry intact")
	var stronger := {"chance":1.3,"level":55,"duration_ms":6500,"vision_percent":56,"stuck_percent":3}
	check(resister.apply_source_blind(stronger,0) and resister.effects.active["blind"]["remaining_ms"]==7020.0
		and resister.effects.active["blind"]["definition"]["vision_percent"]==60,"stronger blind replaces the previous entry after source level scaling")

	game.player["pos"] = point-Vector2(420,0)
	game.update_enemy(enemy,16.0)
	check(enemy["state"]=="move","ordinary Goblin acquires a target at its source 420-unit boundary before blind")
	enemy["pos"] = point
	enemy["state"] = "idle"
	game.player["pos"] = point-Vector2(211,0)
	# Align one already-attached child's grab completion with the deadline.
	late_child["rasa_attached_at"] = 2600.0-float(controller["grab_ms"])
	game.step_objects(1399.0)
	check(not actor.effects.active.has("blind"),"attached children do not draw at age 2599")
	game.rng.reseed(rasa_blind_seed())
	game.bus.clear_history()
	game.step_objects(1.0)
	var blind: Dictionary = actor.effects.active.get("blind",{})
	check(blind.get("remaining_ms",0)==6500.0,"a native blind draw at child age 2600 applies the equal-level status")
	game.view.present(game.view_snapshot(),0,0)
	var enemy_view = game.view.enemy_actors[enemy["id"]]
	var rear = enemy_view.get_node_or_null("BlindBack")
	var front = enemy_view.get_node_or_null("BlindFront")
	check(rear != null and front != null and rear.visible and front.visible
		and rear.atlas != null and front.atlas != null,"real Rasa blind shows both original monster status layers")
	if rear != null and front != null:
		check(rear.show_behind_parent and not front.show_behind_parent
			and rear.position==Vector2(0,-73) and front.position==rear.position,
			"blind uses separate actor passes and original Goblin frame-zero height plus five pixels")
		check(rear.frame["sprite"]=="0" and front.frame["sprite"]=="0"
			and rear.frame_color()==Color.WHITE and front.frame_color()==Color.WHITE,
			"both blind layers start at source frame zero with native sprite alpha")
		game.view.present(game.view_snapshot(),60,60)
		var elevated: Dictionary = game.view_snapshot()
		elevated["enemies"][0]["facing"] = -1
		elevated["enemies"][0]["ani"] = "attack1"
		elevated["enemies"][0]["z"] = 17.0
		game.view.present(elevated,120,0)
		check(rear.frame["sprite"]=="1" and front.frame["sprite"]=="1"
			and rear.position==Vector2(0,-90) and front.position==rear.position
			and rear.facing==1 and front.facing==1,
			"blind follows elevation, uses fixed native orientation and holds its clock during pause")
	var events: Array = game.bus.events_of("combat.status").filter(func(e):return e.get("id","")=="blind")
	check(events.size()==1,"equal child blind draws cannot stack or refresh the status")
	check(not late_child.has("rasa_next_status_ms"),"the grab completion tick does not draw even when the child timer is due")
	game.step_objects(0.0)
	check(late_child.get("rasa_next_status_ms",0)==5200.0,"the next stable update consumes the pending child deadline")
	game.update_enemy(enemy,16.0)
	check(enemy["state"]=="idle" and enemy["pos"]==point,"blind Goblin cannot track beyond the original projected 210-unit boundary")
	game.player["pos"] = point-Vector2(210,0)
	game.update_enemy(enemy,16.0)
	check(enemy["state"]=="move","blind Goblin still tracks at the inclusive reduced sight boundary")
	enemy["pos"] = point
	enemy["state"] = "idle"
	game.player["pos"] = point-Vector2(211,0)
	actor.step(6467.0)
	game.update_enemy(enemy,1.0)
	check(not actor.effects.active.has("blind") and enemy["state"]=="move","status expiry restores the Goblin's ordinary target acquisition")
	if rear != null and front != null:
		game.view.present(game.view_snapshot(),0,0)
		check(not rear.visible and not front.visible,"blind status expiry hides both layers immediately")
	game.step_objects(5200.0)
	check(late_child.get("rasa_next_status_ms",0)==7800.0,"after a long update each child advances the previous deadline only once")
	game.step_objects(0.0)
	check(late_child.get("rasa_next_status_ms",0)==10400.0,"a subsequent update consumes the next overdue interval")
	if rear != null and front != null:
		actor.effects.active.erase("blind")
		check(actor.apply_source_blind(row,0),"blind visual refresh fixture reapplies the source status")
		game.view.present(game.view_snapshot(),300,300)
		check(rear.frame["sprite"]=="0" and front.frame["sprite"]=="0"
			and rear.clock_ms==360.0 and front.clock_ms==360.0,
			"the retained source pair loops every six 60-ms frames")
		check(actor.apply_source_blind(stronger,0),"the source blind accepts a stronger replacement")
		game.view.present(game.view_snapshot(),60,60)
		check(rear.visible and front.visible and rear.frame["sprite"]=="1" and front.frame["sprite"]=="1"
			and rear.clock_ms==420.0 and front.clock_ms==420.0,
			"stronger blind refresh keeps the original presentation clock")
		enemy["hp"] = 0
		game.view.present(game.view_snapshot(),0,0)
		check(not rear.visible and not front.visible,"dead monsters stop rendering the blind pair")


func check_native_monster_vision(game, session) -> void:
	game.restart()
	game.clear_monsters()
	var origin := Vector2(400,250)
	var point := origin+Vector2(122,0)
	var sample := {"pos":Vector2.ZERO,"facing":1}
	var goblin: Dictionary = game.table.monsters["goblin"]
	var thrower: Dictionary = game.table.monsters["goblin_thrower"]
	var haze_key := "newmonsters_haze_chainbiker_chainbiker"
	var haze: Dictionary = game.table.monsters[haze_key]
	check(goblin["native_target_profile"] == thrower["native_target_profile"]
		and not goblin["native_target_profile"]["uses_ai_vision"],
		"Goblin and Thrower consume the original protected sight input")
	check(MonsterAI.target_visible(sample,goblin,Vector2(420,0),false)
		and not MonsterAI.target_visible(sample,goblin,Vector2(421,0),false)
		and MonsterAI.target_visible(sample,goblin,Vector2(0,122),false)
		and not MonsterAI.target_visible(sample,goblin,Vector2(0,123),false),
		"ordinary target eligibility uses the native inclusive projected distance on both axes")
	check(haze["native_target_profile"]=={"uses_ai_vision":true,"sight":200,"vision":1000,"back_vision":1500,"keep_distance":-1},
		"Chainbiker keeps source vision separate from default sight and its preferred movement distance")
	check(MonsterAI.target_visible(sample,haze,Vector2(1400,0),false)
		and not MonsterAI.target_visible(sample,haze,Vector2(1401,0),false),
		"normal CNAI acquisition uses authored vision instead of the legacy sight default")
	var limited := haze.duplicate()
	var profile: Dictionary = haze["native_target_profile"].duplicate()
	limited["native_target_profile"] = profile
	profile["keep_distance"] = 100
	profile["back_vision"] = -1
	check(MonsterAI.target_visible(sample,limited,Vector2(140,0),true)
		and not MonsterAI.target_visible(sample,limited,Vector2(141,0),true)
		and not MonsterAI.target_visible(sample,limited,Vector2(-1,0),true),
		"the original keep-distance override remains subject to the separate front-only sentinel")

	game.numeric_player = Actor.new()
	game.numeric_player.configure(session.stats())
	game.numeric_player.values["cast_speed"] = 1.0
	game.skill_levels = {"epidemicrasa":1}
	game.table.configure_skills(game.skill_levels,"soulbringer","katana")
	game.player["mp"] = game.numeric_player.values["mp_max"]
	game.player["pos"] = origin
	game.player["facing"] = 1
	var enemy: Dictionary = game.spawn_enemy(point,false,haze_key)
	enemy["pos"] = point
	var actor = enemy["numeric"]
	actor.configure({"numbers":actor.base.merged({"level":47},true)})
	check(game.start_action("epidemicrasa"),"Chainbiker fixture enters the real Rasa cast")
	game.step_action(250.0,Vector2.ZERO)
	game.rng.reseed(rasa_contact_seed())
	game.step_objects(1000.0)
	game.step_objects(1200.0)
	game.step_objects(1399.0)
	game.rng.reseed(rasa_blind_seed())
	game.step_objects(1.0)
	check(actor.effects.active.has("blind") and enemy.get("native_blind_applied",false),
		"real Rasa attachment applies blind to CNAI and saves its original expiry destination")
	check(MonsterAI.target_visible(enemy,haze,point+Vector2(70,0),true)
		and not MonsterAI.target_visible(enemy,haze,point+Vector2(71,0),true),
		"the CNAI field receives a second truncating half of the protected sight")
	actor.step(6500.0)
	check(not actor.effects.active.has("blind")
		and MonsterAI.target_visible(enemy,haze,point+Vector2(280,0),false)
		and not MonsterAI.target_visible(enemy,haze,point+Vector2(281,0),false),
		"blind expiry restores protected sight into CNAI vision through the same actor lifetime")
