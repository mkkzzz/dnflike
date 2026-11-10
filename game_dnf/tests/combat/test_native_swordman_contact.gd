extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const SkillCatalog = preload("res://combat/api/skill_catalog.gd")
const TestAPI = preload("res://debug/test_api.gd")
const ProfileSession = preload("res://flow/session.gd")
const Numbers = preload("res://stats/api/numbers.gd")
const Frame = preload("res://view/world_frame.gd")
const POINT := Vector2(400,300)
const ARMOR_PARTICLE := "common/commoneffect/particle/superarmor_damage_particle.ptl"

var session := CombatSession.new()
var game
var api
var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		print("[SWORDMAN_CONTACT] FAIL ",label)

func start_room(item: String, family: String, facing := 1, numbers := {}, job := "weaponmaster") -> void:
	var spec: Dictionary = numbers.duplicate()
	spec.merge({"weapon_item":item,"weapon":family,"job":job},true)
	check(session.start_room({"run_id":"native-swordman-contact","room_id":"lorien:1",
		"player":spec,"audio":{"muted":true}}),
		"public room entry accepts "+item)
	game.player["pos"] = POINT
	game.player["facing"] = facing
	# Frame fixtures isolate action state from the room-entry grace period.
	game.player["invuln_ms"] = 0.0
	game.bus.clear_history()

func press(code: int) -> void:
	session.submit_key(code,true)
	session.submit_key(code,false)

func step(ms: float) -> void:
	var first_new_id: int = game._next_entity_id
	game.step_player(ms,Vector2.ZERO)
	game.step_draw_hits(ms,first_new_id)
	game.view.present(game.view_snapshot(),0.0,0.0)

func move_target(target: Dictionary, point: Vector2, height := 0.0) -> void:
	target["pos"] = point
	target["state"] = "idle"
	target["clock"] = 0.0
	target["z"] = height

func cues(key: String) -> Array:
	return game.bus.events_of("combat.cue").filter(func(event):return event.get("key","")==key)

func check_upper_body_armor() -> void:
	var source := {"pos":POINT+Vector2(40,0)}
	var atk: Dictionary = game.table.atk("character/swordman/attackinfo/attack1.atk")
	for clock: int in [0,149,150,350,849,850]:
		start_room("original_27601","katana")
		press(KEY_Z)
		step(clock)
		var before_hp: float = game.player["hp"]
		var reaction: String = game.hurt_player(7,source,atk,-1)
		check(game.player["hp"]==before_hp-7,"upper takes incoming damage at "+str(clock))
		check((game.player["action"]=="upper" and reaction=="none") if clock<850
			else (game.player["action"]=="" and reaction=="stagger"),
			"the original body state resists the reaction until HitBack ends at "+str(clock))
		check(cues("upper_armor_light").size()==int(clock<850),"only an armored hit lights the actor at "+str(clock))
	var piercing := atk.duplicate()
	piercing["ignore_super_armor"] = 1
	for clock: int in [100,350]:
		start_room("original_27000","shortsword")
		press(KEY_Z)
		step(clock)
		check(game.hurt_player(7,source,piercing,-1)=="stagger" and game.player["action"]=="",
			"native ATK bypass interrupts the override and the frame body armor at "+str(clock))
		check(cues("upper_armor_light").is_empty(),"a piercing hit leaves no upper armor light")
	start_room("original_27000","shortsword")
	press(KEY_Z)
	step(100)
	game.hurt_player(ceilf(game.player["hp"]),source,atk,-1)
	check(game.player["hp"]==0.0 and game.player["state"]=="dead","opening armor does not prevent lethal damage")

	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"weaponmaster"})
	profile.command("numbers.skill_grant",{"id":"guard","level":1})
	profile.command("numbers.skill_grant",{"id":"autoguard","level":20})
	for elapsed: int in [99,100,566,567]:
		start_room("original_27000","shortsword",1,profile.stats())
		check(game.apply_effect({"kind":"effect","id":"autoguard","rank":20}),"source auto guard fixture is active")
		game.numeric_player.values["attack_speed"] = 1.5
		press(KEY_Z)
		step(elapsed)
		var reaction: String = game.hurt_player(7,source,atk,-1)
		check((reaction=="none" and game.player["action"]=="upper") if elapsed<567
			else (reaction=="guard" and game.player["state"]=="guard"),
			"auto guard gate follows the accelerated body frame at "+str(elapsed)+" ms")

func armor_particles() -> Array:
	return game.view.effects.filter(func(fx):return fx.get_meta("source_ptl","")==ARMOR_PARTICLE)

func check_upper_armor_visuals() -> void:
	start_room("original_27601","katana",-1)
	var source := {"pos":POINT+Vector2(40,0)}
	press(KEY_Z)
	step(0)
	game.hurt_player(7,source,{},-1)
	var sparks := armor_particles()
	var bursts: Array = game.bus.events_of("combat.cue").filter(func(event):return event.get("path","")==ARMOR_PARTICLE)
	check(sparks.size()==6,"the original armor PTL emits six particles at high quality")
	check(bursts.size()==1 and bursts[0]["point"]==POINT and float(bursts[0]["height"])==50.0,
		"the original burst origin uses the actor XYZ plus half the source Stay height")
	var source_scales := {
		"superarmor_damage_particle01.ani": [Vector2(0.8,0.7),Vector2(0.55,0.725)],
		"superarmor_damage_particle02.ani": [Vector2(0.6,0.6),Vector2(0.625,0.625)],
		"superarmor_damage_particle03.ani": [Vector2(0.9,0.9),Vector2(0.925,0.575)]}
	for particle in sparks:
		var file := String(particle.data["source"]).get_file()
		check(source_scales.has(file),"armor particle uses one of the three original ANI variants")
		if not source_scales.has(file):continue
		check(particle.frame_scale().is_equal_approx(source_scales[file][0]),"native ANI scale starts at its first endpoint: "+file)
		particle.seek(175.0)
		check(particle.frame_scale().is_equal_approx(source_scales[file][1]),"native ANI interpolates both scale axes halfway through frame 0: "+file)
		particle.seek(0.0)
	if not sparks.is_empty():
		var spark = sparks[0]
		check(spark.facing==1 and spark.follow==-1 and spark.clock_ms==0.0,
			"the original armor particles are free, unmirrored, and start at ANI frame zero")
		var center := Vector2(POINT.x, POINT.y + Frame.MAP_DY - 50)
		var delta: Vector2 = (spark.position-center).abs()
		check(delta.x<=25 and delta.y<=25,"the armor particle birth area centers at half the original Stay height")
		var tint: Vector3 = spark.material.get_shader_parameter("mono_rgb")
		check(tint.is_equal_approx(Vector3(1.0,150.0/255.0,0.0)) and is_equal_approx(spark.fade,1.0),
			"the original orange monochrome blend preserves starting opacity")
		spark.advance(329.0)
		check(not spark.is_queued_for_deletion() and is_equal_approx(spark.fade,1.0-0.57*329.0/330.0),
			"the PTL fades to its original opacity just before the 330 ms deadline")
		spark.advance(1.0)
		check(spark.is_queued_for_deletion(),"the armor particle ends at the original 330 ms motion deadline")
	var lights: Array = game.view.effects.filter(func(fx):return fx.data["source"].ends_with("/superarmordamage.ani"))
	check(lights.size()==1,"the armored hit creates the original light view")
	if not lights.is_empty():
		var light = lights[0]
		check(light.follow==0 and light.facing==-1 and light.frame["items"]["7"][0]<0.71,
			"original light follows the actor and starts on its scaled frame")
		light.seek(40.0)
		check(int(light.frame["frame"])==1 and not light.frame["items"].has("7"),"original light alternates scale at 40 ms")
		light.seek(160.0)
		check(light.is_queued_for_deletion(),"the light ends after the last visible original frame")
	game.step_game(599.0)
	game.view.present(game.view_snapshot(),0.0,0.0)
	game.view.present(game.view_snapshot(),599.0,599.0)
	check(game.hurt_player(7,source,{},-1)=="none" and cues("upper_armor_light").size()==1,
		"an armored hit at 599 ms does not restart the light")
	check(armor_particles().is_empty(),"the occupied light gate also suppresses a second particle burst")
	game.step_game(1.0)
	game.player["invuln_ms"] = 0.0
	check(game.hurt_player(7,source,{},-1)=="none" and cues("upper_armor_light").size()==2,
		"an armored hit can replay the light at 600 ms")
	check(armor_particles().size()==6,"the same 600 ms gate releases the original particle burst")

func check_followup() -> void:
	start_room("original_27000","shortsword")
	for ranks: Dictionary in [
		{"upper":1,"shortswordmastery":3,"weapon_mastery_up":0},
		{"upper":1,"shortswordmastery":2,"weapon_mastery_up":1},
		{"upper":0,"shortswordmastery":3,"weapon_mastery_up":1}]:
		game.table.configure_skills(ranks,"weaponmaster","shortsword")
		check(not game.move_def("upper").has("upper_followup_at"),"source rank gate "+str(ranks))
	start_room("original_27601","katana")
	game.table.configure_skills({"upper":1,"shortswordmastery":3,"weapon_mastery_up":1},"weaponmaster","katana")
	check(not game.move_def("upper").has("upper_followup_at"),"katana cannot enter state 30")

	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"weaponmaster"})
	profile.command("numbers.skill_grant",{"id":"shortswordmastery","level":1})
	profile.command("numbers.skill_grant",{"id":"weapon_mastery_up","level":1})
	var spec := profile.stats()
	for code: int in [KEY_X,KEY_Z]:
		start_room("original_27000","shortsword",1,spec)
		game.numeric_player.values["attack_speed"] = 1.0
		game.numeric_player.values["hit"] = 1.0
		var rank := int(game.skill_levels["shortswordmastery"])
		var row: Array = Numbers.Skills.sample(Numbers.record("shortswordmastery"),rank)["level_row"]
		var move: Dictionary = game.move_def("upper")
		check(rank >= 3 and move.get("upper_followup_at")==200.0,"room uses the effective mastery rank and source frame 3")
		var second: Dictionary = move["stages"][1]
		check(second["hits"][0]["percent"]==float(row[2]) and second["hits"][0]["lift"]==float(row[3]),
			"state 30 uses short sword mastery damage and lift columns")
		check(move["stages"][0]["hits"][0]["lift"]==350.0 and move["stages"][0]["hits"][0]["atk"]["push_aside"]==100.0,
			"state 8 uses Upper Slash lift and horizontal push columns")
		var target: Dictionary = api.spawn_dummy(POINT+Vector2(85,0))
		var before_mp: float = game.player["mp"]
		press(KEY_Z)
		step(199)
		check(game.hit_count==1,"state 8 hits the target before state 30")
		var first_cooldown: float = game.player["cooldowns"]["upper"]
		session.submit_key(code,true)
		step(0)
		check(game.player["stage"]==0 and cues("UPPER_SLASH_02").is_empty(),"input at 199 ms cannot start state 30")
		step(1)
		check(game.player["stage"]==0,"a key held from before frame 3 does not leak into the opened gate")
		session.submit_key(code,false)
		session.submit_key(KEY_LEFT,true)
		press(code)
		step(0)
		session.submit_key(KEY_LEFT,false)
		check(game.player["stage"]==1 and game.player["clock"]==0.0 and game.view.player_actor.pose=="upperslashafter"
			and api.weapon_layers_follow_actor() and game.player["hits"].is_empty() and game.player["facing"]==1,
			"new X or Z edge enters state 30 with a fresh clock, weapon pose and ATK ledger while retaining facing")
		check(cues("UPPER_SLASH_02").size()==1 and cues("SM_UPPERSLASH_ADD").size()==1
			and cues("UPPER_SLASH_02")[0]["event_id"]<cues("SM_UPPERSLASH_ADD")[0]["event_id"]
			and cues("upper_short_followup").size()==1 and cues("upper2").is_empty(),
			"entry sounds and mastery overlay fire in source order, before skill FX 1")
		move_target(target,POINT+Vector2(65,0),110.0)
		step(199)
		check(game.hit_count==1 and cues("upper2").is_empty(),"state 30 has no contact or skill FX before frame 2")
		step(1)
		var hit: Dictionary = game.bus.events_of("combat.hit")[-1]
		check(game.hit_count==2 and hit["target"]==target["id"] and hit["atk"].ends_with("upperslashafter.atk")
			and cues("upper2").size()==1,"frame 2 uses the distinct ATK and hits the same target again")
		step(40)
		var overlays: Array = game.view.effects.filter(func(view):return view.data.get("source","").ends_with("shortweaponupperslashafter.ani"))
		check(overlays.size()==1 and overlays[0].frame.get("img_frame")==4,"mastery artwork keeps its original independent frame timing")
		step(159)
		var late: Dictionary = game.spawn_enemy(POINT+Vector2(115,0))
		move_target(late,POINT+Vector2(115,0),150.0)
		step(1)
		check(game.hit_count==3 and game.bus.events_of("combat.hit")[-1]["target"]==late["id"],
			"copied mastery box still hits on body frame 4 after the B-layer box ends")
		press(code)
		step(100)
		check(game.player["action"]=="" and game.hit_count==3 and cues("UPPER_SLASH_02").size()==1
			and game.player["mp"]==before_mp-move["mp"] and game.player["cooldowns"]["upper"]==first_cooldown,
			"state 30 ends after 500 ms, with no third segment or second cast cost")

	start_room("original_27000","shortsword",1,spec)
	press(KEY_Z)
	step(1000)
	check(game.player["action"]=="" and cues("UPPER_SLASH_02").is_empty(),"qualified cast without another input ends after the first action")
	start_room("original_27000","shortsword",1,spec)
	game.numeric_player.values["attack_speed"] = 1.0
	press(KEY_Z)
	step(200)
	press(KEY_X)
	step(0)
	check(game.player["stage"]==1 and game.hurt_player(7,{"pos":POINT+Vector2(40,0)},{},-1)=="stagger",
		"state 30 no longer uses HitBack armor and can be interrupted")

func check_guard_release() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.skill_grant",{"id":"guard","level":4})
	var spec := profile.stats()
	spec["skill_slots"] = ["","","guard"]

	start_room("original_27601","katana",1,spec)
	session.submit_key(KEY_D,true)
	step(0)
	check(game.player["state"]=="guard" and game.player["guard_hold_ms"]==500.0,
		"manual guard starts with the original 500 ms minimum")
	session.submit_key(KEY_D,false)
	step(499)
	check(game.player["state"]=="guard","releasing early keeps guarding before 500 ms")
	step(1)
	check(game.player["state"]=="idle","released guard exits at 500 ms")

	start_room("original_27601","katana",1,spec)
	session.submit_key(KEY_D,true)
	step(0)
	step(500)
	check(game.player["state"]=="guard","guard remains active after its minimum while the key is down")
	session.submit_key(KEY_D,false)
	step(0)
	check(game.player["state"]=="idle","releasing past the minimum immediately exits guard")

	start_room("original_27601","katana",1,spec)
	session.submit_key(KEY_D,true)
	step(0)
	step(50)
	var reaction: String = game.hurt_player(10,{"pos":POINT+Vector2(40,0)},{},-1)
	check(reaction=="guard" and game.player["guard_recoil_ms"]==140.0 and game.player["guard_hold_ms"]==0.0,
		"a blocked hit replaces the initial hold gate with rank 4 recovery")
	session.submit_key(KEY_D,false)
	step(139)
	check(game.player["state"]=="guard","released guard remains active before recoil ends")
	step(1)
	check(game.player["state"]=="idle","recoil exits at 140 ms without a second 500 ms minimum")

	start_room("original_27601","katana",1,spec)
	session.submit_key(KEY_D,true)
	step(0)
	session.pause()
	session.resume()
	step(0)
	check(game.player["state"]=="idle","flow pause clears the guard hold with its input ownership")

func check_guard_recoil_motion() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.skill_grant",{"id":"autoguard","level":20})
	for sample: Array in [
		[2,1,180.0,-1388,16.8786,22.5144],
		[4,-1,140.0,-2500,18.375,24.5],
	]:
		profile.command("numbers.skill_grant",{"id":"guard","level":sample[0]})
		var spec := profile.stats()
		spec["skill_slots"] = ["","","guard"]
		var facing: int = sample[1]
		var duration: float = sample[2]
		start_room("original_27601","katana",facing,spec)
		game.numeric_player.values["attack_speed"] = 1.5
		session.submit_key(KEY_D,true)
		step(0)
		var reaction: String = game.hurt_player(10,{"pos":POINT+Vector2(40*facing,0)},{},-facing)
		check(reaction=="guard" and game.player["guard_recoil_accel"]==sample[3],
			"guard recoil uses signed integer division for the rank's acceleration")
		game.player["stuck_ms"] = 20.0
		game.step_game(20.0)
		check(game.player["pos"]==POINT and game.player["guard_recoil_ms"]==duration,
			"guard recoil stays on the local combat clock during hitstop")
		step(duration*0.5)
		check(Vector2(game.player["pos"]).is_equal_approx(POINT-Vector2(float(sample[4])*facing,0)),
			"guard decelerates opposite to facing and ignores attack speed")
		step(duration)
		check(game.player["state"]=="guard" and Vector2(game.player["pos"]).is_equal_approx(POINT-Vector2(float(sample[5])*facing,0)),
			"guard returns to its held frame and caps motion at recovery end")
		var stopped: Vector2 = game.player["pos"]
		step(100.0)
		check(game.player["pos"]==stopped,"held guard has no residual recoil")

	start_room("original_27601","katana",1,profile.stats())
	check(game.apply_effect({"kind":"effect","id":"autoguard","rank":20}),"source automatic guard fixture is active")
	var automatic: String = game.hurt_player(10,{"pos":POINT-Vector2(40,0)},{},1)
	step(140.0)
	check(automatic=="guard" and game.player["state"]=="idle" and game.player["facing"]==-1
		and Vector2(game.player["pos"]).is_equal_approx(POINT+Vector2(24.5,0)),
		"automatic guard turns toward a rear hit and recoils away from it")

	var spec := profile.stats()
	spec["skill_slots"] = ["","","guard"]
	start_room("original_27601","katana",1,spec)
	var grid: Dictionary = game.map_loader.constants()
	var cell_width := int(grid["cell_width"])
	var col := floori(POINT.x/cell_width)
	var row := floori(POINT.y/float(grid["cell_height"]))
	var edge := Vector2(col*cell_width,POINT.y)
	game.room_map = game.room_map.duplicate(true)
	game.room_map["walk_grid"][row][col] = 0
	game.room_map["walk_grid"][row][col-1] = 1
	game.player["pos"] = edge+Vector2(8,0)
	session.submit_key(KEY_D,true)
	step(0)
	var blocked: String = game.hurt_player(10,{"pos":edge+Vector2(48,0)},{},-1)
	step(140.0)
	check(blocked=="guard" and game.player["pos"]==edge,
		"guard recoil moves to the last walkable pixel before a blocked cell")

	start_room("original_27601","katana",1,spec)
	game.skill_levels["guard"] = 11
	session.submit_key(KEY_D,true)
	step(0)
	var zero_recoil: String = game.hurt_player(10,{"pos":POINT+Vector2(40,0)},{},-1)
	session.submit_key(KEY_D,false)
	step(16.0)
	check(zero_recoil=="guard" and game.player["state"]=="idle" and game.player["pos"]==POINT,
		"zero recovery from a boosted rank cannot divide by zero or slide")

func check_guard_feedback() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.skill_grant",{"id":"guard","level":4})
	var spec := profile.stats()
	spec["skill_slots"] = ["","","guard"]
	for sample: Array in [[1,10.0,22,23],[-1,46.0,46,14],[1,90.0,71,6]]:
		var facing: int = sample[0]
		start_room("original_27601","katana",facing,spec)
		session.submit_key(KEY_D,true)
		step(0)
		var sounds: Array = game.bus.events_of("combat.cue").filter(func(event):return event["kind"]=="sound")
		check(sounds.size()==2 and sounds[0]["key"]=="SWD_GUARD" and sounds[1]["key"]=="SM_GUARD",
			"entering guard emits the weapon cue and then the original voice")
		var source := {"pos":POINT+Vector2(40*facing,0),"id":999,"stuck_ms":0.0}
		game.land_hit(source,game.player,{"atk":{},"percent":100.0},
			Vector3(POINT.x,POINT.y,float(sample[1])),-facing,100.0)
		var sparks := cues("guard_spark")
		var anchor := POINT+Vector2(int(sample[3])*facing,0)
		check(sparks.size()==1 and sparks[0]["point"]==anchor and sparks[0]["height"]==float(sample[2])
			and sparks[0]["facing"]==facing,"guard spark mirrors and clamps the actual contact height")
		check(cues("SWD_GUARDED").size()==1,"a blocked contact emits the original impact cue")
		var spark = game.view.effects.filter(func(fx):return fx.data["source"].ends_with("/guard/spark.ani"))[0]
		check(spark.atlas!=null and spark.frame["img_frame"]==0 and spark.data["duration_ms"]==250
			and spark.material.blend_mode==CanvasItemMaterial.BLEND_MODE_ADD,"the real spark node uses the native additive atlas")
		step(124)
		check(cues("guard_dust").is_empty(),"no guard dust while recoil speed is exactly 40")
		step(1)
		var dust := cues("guard_dust")
		var dust_anchor := Vector2(game.player["pos"]).round()-Vector2(45*facing,0)
		check(dust.size()==1 and dust[0]["point"]==dust_anchor and dust[0]["height"]==0.0,
			"guard dust appears once behind the fighter below the source speed threshold")
		var dust_view = game.view.effects.filter(func(fx):return fx.data["source"].ends_with("/guard/dust.ani"))[0]
		check(dust_view.atlas!=null and dust_view.frame["img_frame"]==0 and dust_view.data["duration_ms"]==210,
			"the real dust node uses the native seven-frame atlas")
		session.submit_key(KEY_D,false)
		step(15)
		check(cues("guard_dust").size()==1 and cues("SWD_GUARD_END").size()==1,
			"finishing the same recoil adds no second dust and releases guard once")

func check_triple_motion() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.skill_grant",{"id":"triple","level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["","triple"]
	for sample: Array in [[1,1.0,179.8],[-1,0.8,144.0],[1,1.25,213.44]]:
		var facing: int = sample[0]
		start_room("original_27601","katana",facing,spec)
		game.numeric_player.values["attack_speed"] = sample[1]
		press(KEY_S)
		step(0)
		check(game.player["pos"]==POINT,"Triple Slash enters without teleporting")
		step(1000.0)
		check(game.player["state"]=="idle" and Vector2(game.player["pos"]).is_equal_approx(
			POINT+Vector2(float(sample[2])*facing,0)),
			"Triple Slash travel is bounded by both real stop time and the animated state")

	start_room("original_27601","katana",1,spec)
	game.numeric_player.values["attack_speed"] = 1.25
	press(KEY_S)
	step(0)
	var audio = game.view.audio
	var selected := [0,0,0]
	for roll: int in range(100):selected[audio.variant_index("R_TSLASH",roll)] += 1
	check(selected==[34,33,33] and audio.variants["R_TSLASH"].all(func(stream):return stream is AudioStreamOggVorbis),
		"the original weighted weapon group resolves to its three playable streams")
	var first_layers: Array = game.view.effects.filter(func(fx):return fx.data["source"].contains("/tripleslash/"))
	check(first_layers.size()==2 and first_layers.all(func(fx):return fx.frame["img"]==null),
		"the first stage creates both source layers with their blank opening frames")
	step(100)
	check(Vector2(game.player["pos"]).is_equal_approx(POINT+Vector2(68.75,0)),
		"Triple Slash scales acceleration once on its real movement clock")
	check(first_layers.all(func(fx):return fx.clock_ms==125.0 and fx.frame["img_frame"]==0),
		"the attached effects use the accelerated body clock")
	session.submit_key(KEY_LEFT,true)
	press(KEY_S)
	step(68)
	var turn_point: Vector2 = game.player["pos"]
	check(turn_point.is_equal_approx(POINT+Vector2(108.36,0)) and game.player["stage"]==1
		and game.player["facing"]==-1,"Triple Slash completes the current slide before the next segment turns")
	step(100)
	check(Vector2(game.player["pos"]).is_equal_approx(turn_point-Vector2(68.75,0)),
		"the next Triple Slash segment starts a fresh mirrored slide")
	session.submit_key(KEY_LEFT,false)

func check_triple_slash() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.skill_grant",{"id":"triple","level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["","triple"]
	for item: Array in [["original_27000","shortsword",32],["original_27601","katana",35]]:
		start_room(item[0],item[1],1,spec)
		game.numeric_player.values["attack_speed"] = 1.0
		game.numeric_player.values["hit"] = 1.0
		var stages: Array = game.move_def("triple")["stages"]
		var hits := stages.map(func(stage):return stage["hits"][0])
		check(hits.map(func(hit):return hit["percent"])==[158.0,158.0,198.0],
			"ordinary Triple Slash uses original percentage columns 0, 0 and 1")
		check(hits.map(func(hit):return hit["fixed"])==[47.0,47.0,138.0],
			"ordinary Triple Slash uses paired fixed columns 3, 3 and 4")
		check(String(hits[2]["atk_path"]).ends_with("/tripleslash3down.atk")
			and hits[2]["atk"]["lift_up"]==200 and hits[2]["atk"]["push_aside"]==300,
			"the final segment installs the source knockdown ATK")
		for stage: Dictionary in stages:
			var hit: Dictionary = stage["hits"][0]
			var segment: Dictionary = hit["segments"][0]
			check(hit["source"]=="attached_weapon" and segment["start"]==70.0 and segment["end"]==280.0,
				"Triple Slash uses mounted weapon frames 1 to 3")
			check(stage["continue_at"]==210.0 and stage["duration"]==580.0,
				"Triple Slash continuation uses body frame 3 independently of contact")
		check(stages[0]["hits"][0]["segments"][0]["frames"][2]["boxes"][0]==[-39.0,-25.0,27.0,125.0,float(item[2]),45.0],
			"Triple Slash retains the equipped weapon's final attack box and depth")
		press(KEY_S)
		step(0)
		var target: Dictionary = api.spawn_dummy(POINT+Vector2(300,0))
		step(278)
		check(game.player["action"]=="triple" and game.hit_count==0,"S enters Triple Slash with no nearby target")
		move_target(target,game.player["pos"]+Vector2(30,0))
		step(1)
		check(game.hit_count==1,"Triple Slash still hits a new target at 279 ms")
		var independent: float = float(game.numeric_player.values["independent_attack"])+float(game.numeric_player.values["physical_independent_attack"])
		check(is_equal_approx(float(game.last_damage["trace"]["fixed_part"]),47.0*independent/100.0),
			"ordinary contact passes the first native fixed column to physical damage")
		var expired_target: Dictionary = api.spawn_dummy(game.player["pos"]+Vector2(30,0))
		step(1)
		check(game.hit_count==1 and expired_target["hp"]==expired_target["max_hp"],
			"Triple Slash weapon boxes expire at 280 ms")

	start_room("original_27601","katana",1,spec)
	game.numeric_player.values["attack_speed"] = 1.25
	press(KEY_S)
	step(0)
	var mp: float = game.player["mp"]
	check(float(game.player["cooldowns"].get("triple",0.0))==0.0,"Triple Slash has no cooldown while its first stage runs")
	for index: int in [0,1]:
		press(KEY_S)
		step(167)
		check(game.player["stage"]==index,"Triple Slash cannot continue before body frame 3")
		step(1)
		check(game.player["stage"]==index+1 and game.player["clock"]==0.0 and game.player["mp"]==mp,
			"Triple Slash advances at 210 action ms without another cast cost")
		check(float(game.player["cooldowns"].get("triple",0.0))==0.0,"continuing state 22 does not start cooldown")
	press(KEY_S)
	var target: Dictionary = api.spawn_dummy(game.player["pos"]+Vector2(75,0))
	game.numeric_player.values["hit"] = 1.0
	step(56)
	check(target["state"]=="air" and float(target["vz"])>0.0,
		"the final Triple Slash segment knocks down a live enemy")
	step(112)
	check(game.player["stage"]==2,"ordinary Triple Slash has no fourth stage")
	step(296)
	check(game.player["action"]!="triple","Triple Slash recovers at the end of the final body animation")

func check_enhanced_triple_slash() -> void:
	start_room("original_27601","katana")
	for ranks: Dictionary in [
		{"blademastery":5,"weapon_mastery_up":0},
		{"blademastery":4,"weapon_mastery_up":1},
		{"lightswordmastery":7,"weapon_mastery_up":1},
	]:
		game.table.configure_skills(ranks,"weaponmaster","katana")
		check(game.move_def("triple")["stages"].size()==3,"katana checks its own effective mastery and Oath")
	start_room("original_27000","shortsword")
	game.table.configure_skills({"blademastery":7,"weapon_mastery_up":1},"weaponmaster","shortsword")
	check(game.move_def("triple")["stages"].size()==3,"short sword cannot borrow katana's five-stage branch")

	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"weaponmaster"})
	profile.command("numbers.skill_grant",{"id":"triple","level":1})
	profile.command("numbers.skill_grant",{"id":"blademastery","level":1})
	profile.command("numbers.skill_grant",{"id":"weapon_mastery_up","level":2})
	var gear := profile.command("numbers.gear_give",{"id":"original_27601"})
	check(gear["ok"] and profile.command("numbers.gear_equip",{"uid":gear.get("uid","")})["ok"],
		"the profile equips a supported original katana")
	var spec := profile.stats()
	spec["skill_slots"] = ["","triple"]
	start_room("original_27601","katana",1,spec)
	game.numeric_player.values["attack_speed"] = 1.0
	game.numeric_player.values["hit"] = 1.0
	var stages: Array = game.move_def("triple")["stages"]
	check(game.skill_levels["blademastery"]==5 and stages.size()==5,"Oath raises Blade Mastery to the native five-stage threshold")
	if stages.size()!=5:return
	var hits := stages.map(func(stage):return stage["hits"][0])
	check(hits.map(func(hit):return hit["percent"])==[158.0,158.0,158.0,198.0,198.0],
		"enhanced Triple Slash reads the five source percentage columns")
	var fixed := [47.0,47.0,47.0,138.0,158.0]
	check(hits.map(func(hit):return hit["fixed"])==fixed,
		"enhanced Triple Slash changes the third fixed column and uses distinct fourth and fifth columns")
	check(hits[2]["atk_path"].ends_with("/tripleslash3.atk") and hits[4]["lift"]==382.0,
		"the enhanced third stage uses its ordinary ATK and the fifth reads mastery lift")
	check(hits[3]["segments"][0]["frames"][0]["boxes"]==[[-31.0,-20.0,46.0,163.0,35.0,46.0]]
		and hits[4]["segments"][0]["frames"][0]["boxes"]==[[-26.0,-15.0,17.0,106.0,30.0,137.0]],
		"the fourth and fifth stages hit with their native C and B layer boxes")
	var catalog := SkillCatalog.new()
	catalog.get_profile_skill("triple",profile.profile)
	check(catalog.table.moves["triple"]["stages"].size()==5,"profile preview selects the same equipped five-stage move")
	profile.command("numbers.gear_unequip",{"slot":"weapon"})
	catalog.get_profile_skill("triple",profile.profile)
	check(catalog.table.moves["triple"]["stages"].size()==3,"unequipping invalidates the variant preview")

	press(KEY_S)
	step(0)
	var target: Dictionary = api.spawn_dummy(POINT+Vector2(45,0))
	for index: int in range(5):
		if index == 3:
			var refreshed := spec.duplicate(true)
			refreshed["skills"]["weapon_mastery_up"] = 0
			check(session.update_numbers(refreshed) and game.table.moves["triple"]["stages"].size()==3,
				"live refresh reverts future casts without truncating the active stage array")
		var facing: int = game.player["facing"]
		move_target(target,game.player["pos"]+Vector2(45*facing,0))
		step(70)
		check(game.hit_count==index+1 and game.player["stage"]==index,"each source stage hits the real target once")
		var independent: float = float(game.numeric_player.values["independent_attack"])+float(game.numeric_player.values["physical_independent_attack"])
		check(is_equal_approx(float(game.last_damage["trace"]["fixed_part"]),fixed[index]*independent/100.0),
			"enhanced contact consumes the current fixed column at stage "+str(index+1))
		var weapon_cues := cues("R_TSLASH")
		check(weapon_cues.size()==index+1,"each Triple Slash stage emits one original weapon cue")
		var layers: Array = game.view.effects.filter(func(fx):return fx.data["source"].contains("/tripleslash/"))
		var move_source := "/move%d.ani" % (index%2+1)
		var slash_source := "/slash%d.ani" % (index+1)
		check(layers.size()==2 and layers[0].data["source"].ends_with(move_source)
			and layers[1].data["source"].ends_with(slash_source)
			and layers[0].frame["img_frame"]==index%2*4 and layers[1].frame["img_frame"]==0
			and layers.all(func(fx):return fx.follow==0 and fx.z_index>game.view.player_actor.z_index),
			"the current parity and slash layers draw in order in front of the fighter")
		if index >= 3:
			var img := 12 if index==3 else 201
			check(game.view.player_actor.equipment_layers.all(func(layer):return int(layer.frame.get("img_frame",-1))==img),
				"both equipped weapon layers render the source frame in the added stage")
		if index == 4:break
		check(target["state"]=="hurt","an intermediate enhanced stage staggers without launching")
		session.submit_key(KEY_LEFT if facing==1 else KEY_RIGHT,true)
		press(KEY_S)
		step(140)
		session.submit_key(KEY_LEFT if facing==1 else KEY_RIGHT,false)
	check(target["state"]=="air" and target["vz"]==382.0,"the fifth stage launches the target with effective mastery lift")
	press(KEY_S)
	step(140)
	check(game.player["stage"]==4,"the fifth stage cannot continue into a sixth")

func check_hardattack() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.skill_grant",{"id":"hardattack","level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["hardattack"]
	for item: Array in [["original_27000","shortsword",1],["original_27601","katana",-1]]:
		start_room(item[0],item[1],item[2],spec)
		game.numeric_player.values["attack_speed"] = 1.25
		game.numeric_player.values["hit"] = 1.0
		var hit: Dictionary = game.move_def("hardattack")["hits"][0]
		check(hit["source"]=="attached_weapon" and hit["segments"][0]["start"]==150.0
			and hit["segments"][0]["end"]==300.0 and hit["segments"][0]["frames"].size()==4,
			"Ghost Slash uses the equipped weapon's four live body frames")
		check(hit["percent"]==378.0 and hit["fixed"]==85.0 and hit["damage_type"]=="magical" and hit["element"]=="dark",
			"Ghost Slash uses the two original SKL columns and the dark magic ATK")
		var target: Dictionary = api.spawn_dummy(POINT+Vector2(100*int(item[2]),0))
		press(KEY_A)
		step(119)
		var layers: Array = game.view.effects.filter(func(fx):return fx.data["source"].get_file() in ["hardattack1.ani","hardattack2.ani"])
		check(game.hit_count==0 and layers.size()==2 and layers.all(func(fx):return fx.frame.get("img")==null),
			"both Ghost Slash layers attach at entry and share the original blank 150 ms startup")
		check(cues("R_SM_GUE").size()==1 and game.view.audio.variants["R_SM_GUE"].size()==2
			and game.view.audio.variants["R_SM_GUE"].all(func(stream):return stream is AudioStreamOggVorbis),
			"Ghost Slash plays the mounted original voice group")
		step(1)
		check(game.hit_count==1 and target["hp"]<target["max_hp"],"Ghost Slash hits at body frame 3 in both directions")
		check(layers.all(func(fx):return fx.follow==0 and fx.clock_ms==150.0 and fx.frame["img_frame"]==0),
			"both Ghost Slash layers reveal their first image on the contact frame")
		check(game.view.player_actor.equipment_layers.all(func(layer):return int(layer.frame.get("frame",-1))==3),
			"the two visible weapon layers use the original body frame index")
		var expired: Dictionary = api.spawn_dummy(POINT+Vector2(100*int(item[2]),0))
		step(120)
		check(game.hit_count==1 and expired["hp"]==expired["max_hp"],"the frame-7 boundary ends Ghost Slash contact")

func check_hardattack_charge() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"soulbringer"})
	profile.command("numbers.skill_grant",{"id":"hardattackcharge","level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["","","hardattack"]
	for hold: int in [0,49,50,150,249,250,1200]:
		start_room("original_27000","shortsword",1,spec,"soulbringer")
		game.numeric_player.values["attack_speed"] = 1.0
		game.numeric_player.values["hit"] = 1.0
		var target: Dictionary = api.spawn_dummy(POINT+Vector2(100,0))
		session.submit_key(KEY_D,true)
		step(hold)
		check(game.player_ani()==["hardattack",0.0] and game.hit_count==0 and game.objects.is_empty(),
			"holding the bound D key keeps the original pose without hitting at "+str(hold))
		check(cues("SM_GUE_CHARGE").size()==1 and cues("R_SM_GUE").is_empty(),"the charge voice is separate from release")
		check(cues("hardattack_charge1").size()==int(hold>=50) and cues("hardattack_charge2").size()==int(hold>=50),
			"both held effects begin at the original warmup boundary")
		check(cues("GHOSTSLASH_CHARGE_END").size()==int(hold>=250)
			and cues("hardattack_full1").size()==int(hold>=250) and cues("hardattack_full2").size()==int(hold>=250),
			"both full effects and the cue fire once at warmup plus the source threshold")
		session.submit_key(KEY_D,false)
		step(0)
		check(game.bus.events_of("combat.cue").any(func(cue):return cue.get("stop",false) and cue.get("voice_tag","")=="hardattack_charge"),
			"release stops the original charge voice channel")
		var expected: int = {0:378,49:378,50:378,150:408,249:434,250:438,1200:438}[hold]
		var hit: Dictionary = game.action_def()["hits"][0]
		check(game.player_ani()==["hardattack",50.0] and hit["percent"]==expected and hit["fixed"]==85.0,
			"release starts at frame 1 with the native integer bonus at "+str(hold))
		check(cues("R_SM_GUE").size()==1 and game.view.effects.all(func(fx):return not fx.data["source"].contains("hardattackoncharge")),
			"release discards held layers and plays the ordinary slash voice")
		step(99)
		check(game.hit_count==0 and cues("GHOSTSLASH_CRY").is_empty(),"release preserves the original sound and contact gate")
		step(1)
		check(game.hit_count==1 and target["hp"]<target["max_hp"] and cues("GHOSTSLASH_CRY").size()==1,
			"released charge uses original weapon contact and its frame-3 cry")
	start_room("original_27000","shortsword",1,spec,"soulbringer")
	game.numeric_player.values["attack_speed"] = 1.0
	session.submit_key(KEY_D,true)
	step(100)
	game.hurt_player(1,{"pos":POINT+Vector2(40,0)},{},-1)
	session.submit_key(KEY_D,false)
	step(0)
	check(not game.player.has("hardattack_charge") and cues("R_SM_GUE").is_empty(),"interrupting the hold never releases an attack")

func check_hardattack_followup() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"soulbringer"})
	profile.command("numbers.skill_grant",{"id":"hardattackcharge","level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["hardattack"]
	for variant: Array in [[250,1,0,1.0],[250,-1,KEY_LEFT,1.25],[250,1,KEY_LEFT,1.0],[249,1,0,1.0]]:
		var hold: int = variant[0]
		var facing: int = variant[1]
		var direction: int = variant[2]
		var speed: float = variant[3]
		start_room("original_27601","katana",facing,spec,"soulbringer")
		game.numeric_player.values["attack_speed"] = speed
		session.submit_key(KEY_A,true)
		step(hold)
		session.submit_key(KEY_A,false)
		step(0)
		var release_window := 350.0/speed
		step(release_window-1.0)
		check(game.player_ani()[0]=="hardattack" and cues("hardattack_dash_dust").is_empty(),
			"Ghost Slash stays in the release ANI before body frame 9")
		if direction!=0:session.submit_key(direction,true)
		step(1)
		if direction!=0:session.submit_key(direction,false)
		if hold<250:
			check(game.player_ani()[0]=="hardattack" and cues("hardattack_dash_dust").is_empty(),"a partial charge never enters the follow-up")
			check(game.objects.is_empty(),"a partial charge does not create object 20023")
			continue
		check(game.player_ani()==["hardattackchargeafter",0.0] and game.player["stage"]==1,
			"a full charge enters the original follow-up on frame 9")
		check(cues("hardattack_dash_dust").size()==1 and cues("hardattack_dash_down").size()==1 and cues("hardattack_dash_up").size()==1,
			"the follow-up spawns original dust and two body attachments once")
		check(cues("hardattack_dash_dust")[0]["point"]==POINT and cues("hardattack_dash_dust")[0]["height"]==0.0,
			"dust stays at the ground origin of the follow-up")
		check(game.view.player_actor.equipment_layers.all(func(layer):return int(layer.frame.get("img_frame",-1))==10),
			"the follow-up uses both original weapon pose clips")
		check(game.objects.size()==1 and game.objects[0]["pos"]==POINT and game.objects[0]["clock"]==0.0,
			"object 20023 starts at the caster's origin and age zero")
		step(100)
		check(game.hit_count==0,"the follow-up actor pose has no attack boxes")
		game.step_objects(100)
		var dx := 69.0*facing if direction!=KEY_LEFT or facing==-1 else 0.0
		check(Vector2(game.player["pos"]).is_equal_approx(POINT+Vector2(dx,0)),
			"follow-up X motion uses fixed rate, mirrored facing and the back-key veto")
		check(game.objects[0]["pos"]==POINT+Vector2(30*facing,0),
			"wave PTL movement ignores both attack speed and the back-key veto")
		step(650)
		check(game.player["action"]=="" and not game.player.has("action_slide"),"the follow-up returns to idle and clears motion")

func check_hardattack_waves() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"soulbringer"})
	for id: String in ["hardattackcharge","khazan","saya","bremen"]:
		profile.command("numbers.skill_grant",{"id":id,"level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["hardattack","khazan","saya","bremen"]
	for variant: Array in [["khazan",567,[]],["saya",595,[KEY_S,KEY_F,KEY_D]],["bremen",638,[KEY_D,KEY_F]]]:
		var ghost: String = variant[0]
		start_room("original_27601","katana",1,spec,"soulbringer")
		session.set_skill_material_spender(func(id: int, amount: int):return id==3037 and amount==1)
		game.clear_monsters()
		for key: int in variant[2]:
			press(key)
			step(0)
			step(2000)
		check(game.player["hardattack_ghost"]==ghost,"the last released ghost selects "+ghost)
		# Expired fields do not reset the actor's selection.
		game.step_objects(180000)
		check(game.objects.is_empty(),"the selected ghost field is absent before the wave")
		game.numeric_player.values["attack_speed"] = 1.0
		var strength: float = game.numeric_player.values["strength"]
		var intelligence: float = game.numeric_player.values["intelligence"]
		session.submit_key(KEY_A,true)
		step(250)
		session.submit_key(KEY_A,false)
		step(0)
		step(350)
		var wave: Dictionary = game.objects[0]
		var wave_view = game.view.object_views.get(wave["id"])
		check(wave_view!=null and wave_view.data["source"].ends_with(ghost+"-up.ani")
			and wave_view.get_node("RearAnimation").data["source"].ends_with(ghost+"-down.ani"),
			ghost+" wave uses both original ANI banks")
		check(wave["hit"]["percent"]==variant[1] and wave["hit"]["atk_path"].ends_with(ghost+".atk")
			and cues("GHOST_DRIVE_"+ghost.to_upper()).size()==1,
			ghost+" wave installs the original attack record, rank column and voice")
		if ghost == "khazan":
			check(game.active_effect("khazan_drive").get("remaining_ms",0)==13000
				and game.numeric_player.values["strength"]==strength+25
				and game.numeric_player.values["intelligence"]==intelligence+25,
				"Khazan gives the caster both native bonuses before any target contact")
		var target: Dictionary = api.spawn_dummy(POINT+Vector2(45,0))
		var second: Dictionary = game.spawn_enemy(POINT+Vector2(65,0))
		second["hp"] = 5000.0
		if ghost in ["saya","bremen"]:
			target["numeric"].values["level"] = 35
			target["numeric"].values["abnormal_resistance"] = 0
			# After the damage rolls, the first status roll is 403/10000.
			game.rng.reseed(70)
		game.step_objects(0)
		check(target["hp"]<5000.0 and second["hp"]<5000.0 and wave["hits"].size()==2 and game.objects.size()==1,
			"frame zero pierces two targets and records each contact")
		check(cues("GHOST_DRIVE_HIT").size()==2 and game.player["stuck_ms"]==0.0,
			"wave contacts play the original hit cue and keep the caster's clock moving")
		if ghost == "saya":
			var freeze: Dictionary = target["numeric"].effects.active.get("freeze",{})
			check(freeze.get("remaining_ms",0)==1300 and int(freeze.get("definition",{}).get("status_level",0))==35,
				"Saya sends the original rank-one freeze to the hit target")
		game.step_objects(339)
		var late: Dictionary = game.spawn_enemy(POINT+Vector2(210,0))
		late["hp"] = 5000.0
		game.step_objects(1)
		check(late["hp"]==5000.0 and game.objects.size()==1,"the last visible frame has no attack box")
		game.step_objects(84)
		check(game.objects.size()==1 and wave["hits"].size()==2 and wave["pos"]==POINT+Vector2(127,0),
			"the original wave stays through 424 ms and each target is hit once")
		game.step_objects(1)
		check(game.objects.is_empty(),"the wave expires on the original 425 ms boundary")
		if ghost == "khazan":
			game.step_numeric_actor(game.player,game.numeric_player,12999)
			check(not game.active_effect("khazan_drive").is_empty(),"Khazan's caster buff outlives the wave")
			game.step_numeric_actor(game.player,game.numeric_player,1)
			check(game.active_effect("khazan_drive").is_empty() and game.numeric_player.values["strength"]==strength
				and game.numeric_player.values["intelligence"]==intelligence,"Khazan's two bonuses expire together")
		elif ghost == "bremen":
			check_bremen_sleep(target,wave["hit"]["effects"][0])

func check_bremen_sleep(target: Dictionary, source: Dictionary) -> void:
	var actor = target["numeric"]
	check(actor.effects.active.get("sleep",{}).get("remaining_ms",0)==3900 and cues("CONDITION_SLEEP").size()>0,
		"Bremen applies original level-one sleep and plays the native sound on contact")
	check(not actor.apply_source_sleep(source,0),"an active sleep refuses a duplicate")
	game.update_enemy(target,100)
	check(target["state"]=="air" and actor.sleep_age()==0.0,"the sleep clock waits for landing")
	for i in 120:
		if target["state"]=="down":break
		game.update_enemy(target,16)
	check(target["state"]=="down" and actor.sleep_age()==0.0,"landing begins the sleep hold at age zero")
	game.update_enemy(target,200)
	game.view.present(game.view_snapshot(),0.0,0.0)
	var icon = game.view.enemy_actors[target["id"]].get_node_or_null("NativeSleep")
	check(icon!=null and icon.visible and icon.clock_ms==200.0 and icon.data["source"].ends_with("/sleep.ani"),
		"the looped native sleep ANI uses the down-state clock")
	var damage := {"kind":"object","percent":1.0,"atk":{"damage_reaction":[{"value":"[none]"}]}}
	game.land_hit(game.player,target,damage,Vector3(POINT.x,POINT.y,0),1,1.0)
	check(actor.sleep_age()==200.0,"a landed hit at exactly 200 ms preserves sleep")
	game.update_enemy(target,1)
	game.land_hit(game.player,target,damage,Vector3(POINT.x,POINT.y,0),1,1.0)
	game.view.present(game.view_snapshot(),0.0,0.0)
	check(actor.sleep_age()<0.0 and not icon.visible and target["down_ms"]==float(game.rules["reaction"]["down_hold_ms"]),
		"a landed hit after 200 ms wakes, hides the status and starts get-up")
	actor.values["sleep_resistance"] = 100
	check(not actor.apply_source_sleep(source,0),"sleep consults its own full resistance")
	actor.values["sleep_resistance"] = 0
	actor.values["level"] = 35
	check(actor.apply_source_sleep(source,0),"an awake target can sleep again")
	game.update_enemy(target,3899)
	check(actor.sleep_age()==3899.0 and target["state"]=="down","sleep holds the original down pose through the last millisecond")
	game.update_enemy(target,1)
	check(actor.sleep_age()<0.0 and target["down_ms"]>=float(game.rules["reaction"]["down_hold_ms"]),
		"native duration releases the down hold and starts get-up")

func check_triple_cooldown() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.skill_grant",{"id":"triple","level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["","triple"]
	for interrupted: bool in [false,true]:
		start_room("original_27601","katana",1,spec)
		game.numeric_player.values["attack_speed"] = 1.0
		game.numeric_player.values["cooldown_rate"] = 0.75
		press(KEY_S)
		step(0)
		step(100 if interrupted else 579)
		check(game.player["action"]=="triple" and float(game.player["cooldowns"].get("triple",0.0))==0.0,
			"the cooldown stays at zero up to the last active frame or an interruption")
		if interrupted:game.hurt_player(1,{"pos":POINT+Vector2(40,0)},{},-1)
		else:step(1)
		check(game.player["action"]=="" and is_equal_approx(float(game.player["cooldowns"].get("triple",0.0)),4.5),
			"ending state 22 starts the full cooldown with the actor modifier")
		game.step_game(100.0)
		check(is_equal_approx(float(game.player["cooldowns"].get("triple",0.0)),4.4),
			"the cooldown ticks after leaving state 22")
	step(370)
	check(game.player["action"]!="triple" and game.move_def("triple")["stages"].size()==3,
		"the next cast uses the refreshed normal three-stage move")

func check_weapon_combo() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"weaponmaster"})
	profile.command("numbers.skill_grant",{"id":"weaponcombo","level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["weaponcombo"]
	for data: Array in [["original_27000","shortsword","short",[240,300],[100,150,190]],
			["original_27601","katana","blade",[180,240,240],[110,120,140,170]]]:
		start_room(data[0],data[1],1,spec)
		game.numeric_player.values["attack_speed"] = 1.0
		game.numeric_player.values["hit"] = 1.0
		game.numeric_player.values["mp_cost_rate"] = 1.0
		game.player["mp"] = 100.0
		var target: Dictionary = api.spawn_dummy(POINT+Vector2(48,0))
		press(KEY_A)
		step(0)
		var move: Dictionary = game.move_def("weaponcombo")
		check(game.player["action"]=="weaponcombo" and move["stages"].size()==data[4].size(),
			"Weapon Combo selects the original stage count for "+str(data[1]))
		step(119)
		check(game.hit_count==0,"Weapon Combo first equipment hit does not arrive before frame two")
		step(1)
		check(game.hit_count==1 and target["hp"]<5000.0,"Weapon Combo first authored equipment box lands at 120 ms")
		for index in data[4].size():
			var pose := "weaponcombo%s%d"%[data[2],index+1]
			var stage: Dictionary = game.action_def()
			check(game.player_ani()[0]==pose and stage["hits"].size()==1 and stage["hits"][0]["source"]=="attached_weapon"
				and stage["hits"][0]["atk_path"]=="character/swordman/attackinfo/"+pose+".atk"
				and stage["hits"][0]["percent"]==data[4][index],"Weapon Combo uses the equipped ANI and authored ATK for "+pose)
			check(game.player["mp"]==100.0-6.0*(index+1),"Weapon Combo pays the skill cost once per accepted stage")
			if index==data[3].size():break
			var gate: int = data[3][index]
			press(KEY_A)
			step(gate-float(game.player["clock"])-1.0)
			check(game.player["stage"]==index and stage["continue_at"]==float(gate) and game.player["mp"]==100.0-6.0*(index+1),
				"Weapon Combo holds the stage one millisecond before its original chain frame")
			# This fixture advances local action time directly instead of stepping global hitstop.
			game.player["stuck_ms"] = 0.0
			step(1)
			check(game.player["stage"]==index+1,"Weapon Combo advances at its native chain frame")
		check(cues("weapon_combo_%s_finish"%data[2]).size()==1,
			"Weapon Combo attaches the original final-stage effect for "+str(data[1]))
		press(KEY_A)
		step(game.action_duration("weaponcombo")-1.0)
		check(game.player["action"]=="weaponcombo" and game.player["stage"]==data[3].size(),
			"Weapon Combo cannot repeat inside the final stage")
		step(1)
		check(game.player["action"]=="" and game.player["mp"]==100.0-6.0*data[4].size(),
			"Weapon Combo finishes the final recovery without another charge")
	start_room("original_27601","katana",1,spec)
	game.numeric_player.values["attack_speed"] = 1.0
	game.numeric_player.values["mp_cost_rate"] = 0.75
	game.player["mp"] = 8.5
	press(KEY_A)
	step(0)
	press(KEY_A)
	step(180)
	check(game.player["stage"]==0 and game.player["mp"]==4.0 and game.player["queued_skill"]=="",
		"Insufficient MP rejects the buffered stage at the gate without charging or truncating the current swing")
	game.player["mp"] = 4.5
	step(1)
	check(game.player["stage"]==0 and game.player["mp"]==4.5,"A rejected stage does not retry without another press")
	press(KEY_A)
	step(0)
	check(game.player["stage"]==1 and game.player["mp"]==0.0,"A fresh continuation accepts exactly the adjusted MP cost")
	for rank: int in [2,3]:
		profile.command("numbers.skill_grant",{"id":"shortswordmastery","level":rank})
		spec = profile.stats()
		spec["skill_slots"] = ["weaponcombo"]
		start_room("original_27000","shortsword",1,spec)
		game.numeric_player.values["attack_speed"] = 1.0
		game.numeric_player.values["hit"] = 1.0
		var target: Dictionary = api.spawn_dummy(POINT+Vector2(146,0))
		press(KEY_A)
		step(0)
		check(cues("weapon_combo_short_mastery1").size()==int(rank==3),
			"Weapon Combo's short-sword mastery layer requires the original rank three")
		step(179)
		check(target["hp"]==5000.0,"Weapon Combo's extended short-sword box cannot land early")
		step(1)
		check((target["hp"]<5000.0)==(rank==3),"Weapon Combo copies the mastery box at frame three")
	for row: Array in [["club","blunt","shortsword",1],["greatsword","heavy","greatsword",-1]]:
		start_room("",row[2],1,spec)
		if row[0]=="club":
			# No club family art is mounted by the public room yet.
			game.table.configure_skills(game.skill_levels,"weaponmaster","club")
		game.numeric_player.values["attack_speed"] = 1.0
		press(KEY_A)
		step(0)
		var key: String = "weapon_combo_%s_finish"%row[1]
		var stages: Array = game.move_def("weaponcombo")["stages"]
		if row[0]=="club":
			check(stages.size()==4 and stages[1]["ani"]==stages[2]["ani"],
				"Club Weapon Combo retains both original occurrences of the second pose")
		check(stages[-1]["hits"].size()==1 and String(stages[-1]["hits"][0]["source"]).begins_with("derived:"),
			"Weapon Combo keeps the previous final hit reach if no exact weapon is mounted")
		for index in range(stages.size()-1):
			check(cues(key).is_empty(),"Weapon Combo's finishing effect stays off before the final stage")
			press(KEY_A)
			step(stages[index]["continue_at"])
		var finish := cues(key)
		check(finish.size()==1 and finish[0]["depth_offset"]==row[3],
			"Weapon Combo emits its source finish effect at the original depth on the final stage")
	start_room("","shortsword",1,spec)
	game.table.configure_skills(game.skill_levels,"weaponmaster","beamsword")
	game.numeric_player.values["attack_speed"] = 1.0
	for phase in 3:
		game.bus.clear_history()
		press(KEY_A)
		step(0.0 if phase==0 else 180.0)
		var layers: Array = game.bus.events_of("combat.cue").filter(func(event):
			return String(event.get("key","")).begins_with("weapon_combo_light_"))
		var expected: Array = [-3,-2,-1,1,2] if phase<2 else [-3,-2,-1,1,4]
		check(game.player["stage"]==phase and layers.map(func(event):return event["depth_offset"])==expected
			and layers.all(func(event):return event["action_clock_at"]==0.0),
			"Light Sword Weapon Combo attaches each visible layer in its native order on the stage clock")
		var front: String = "weapon_combo_light_finish" if phase==2 else "weapon_combo_light_%d_5"%(phase+1)
		check(cues(front).size()==1 and cues("weapon_combo_light_%d_1"%(phase+1)).size()==1,
			"Light Sword Weapon Combo selects the phase-specific layers and final extra effect")

func check_weapon_combo_normal_cancel() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"weaponmaster"})
	profile.command("numbers.skill_grant",{"id":"weaponcombo","level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["weaponcombo"]
	for sample: Array in [["original_27000","shortsword",1.0,240,300],
			["original_27601","katana",1.25,180,240]]:
		start_room(sample[0],sample[1],1,spec)
		game.clear_monsters()
		var rate: float = sample[2]
		game.numeric_player.values["attack_speed"] = rate
		game.numeric_player.values["mp_cost_rate"] = 1.0
		game.player["mp"] = 100.0
		press(KEY_X)
		step(0)
		press(KEY_A)
		step(250.0/rate-1.0)
		check(game.player["action"]=="attack1" and game.player["mp"]==100.0,
			"Normal attack one does not accept Weapon Combo before native frame five")
		step(1)
		check(game.player["action"]=="weaponcombo" and game.player["stage"]==0 and game.player["mp"]==94.0,
			"Normal attack one cancels to Weapon Combo stage one at native frame five")
		press(KEY_X)
		step(float(sample[3])/rate-1.0)
		check(game.player["action"]=="weaponcombo","Weapon Combo retains its current swing before the weapon-specific gate")
		game.player["stuck_ms"] = 1.0
		step(1)
		check(game.player["action"]=="weaponcombo","Weapon Combo cannot cancel into X during hitstop")
		game.player["stuck_ms"] = 0.0
		step(0)
		check(game.player["action"]=="attack2" and game.player["mp"]==94.0,
			"Weapon Combo resumes the next normal stage once the input gate clears")
		press(KEY_A)
		step(200.0/rate-1.0)
		check(game.player["action"]=="attack2" and game.player["mp"]==94.0,
			"Normal attack two holds until native frame four")
		step(1)
		check(game.player["action"]=="weaponcombo" and game.player["stage"]==1 and game.player["mp"]==88.0,
			"Returning to Weapon Combo advances its own stage and pays exactly once")
		press(KEY_X)
		step(float(sample[4])/rate)
		check(game.player["action"]=="attack3" and game.player["mp"]==88.0,
			"The second return to X chooses normal attack three without charging MP")
		press(KEY_A)
		step(550.0/rate-1.0)
		check(game.player["action"]=="attack3","The final normal attack cannot early cancel into Weapon Combo")
		step(1)
		check(game.player["action"]=="weaponcombo" and game.player["stage"]==0 and game.player["mp"]==82.0,
			"After the final normal recovery, the buffered skill begins a new attack chain")
	start_room("original_27000","shortsword",1,spec)
	game.clear_monsters()
	game.numeric_player.values["attack_speed"] = 1.0
	press(KEY_A)
	step(0)
	session.submit_key(KEY_X,true)
	step(240)
	check(game.player["action"]=="attack1","A Weapon Combo opened from idle cancels to the first normal attack")
	session.submit_key(KEY_X,false)
	press(KEY_A)
	step(250)
	check(game.player["action"]=="weaponcombo" and game.player["stage"]==1,"A second skill request returns to the saved combo ordinal")
	press(KEY_A)
	step(300)
	press(KEY_X)
	step(539)
	check(game.player["action"]=="weaponcombo" and game.player["stage"]==2,"Final Weapon Combo does not early cancel to X")
	step(1)
	press(KEY_X)
	step(0)
	check(game.player["action"]=="attack1","A new normal chain starts at the first attack after Weapon Combo finishes")
	start_room("original_27000","shortsword",1,spec)
	game.clear_monsters()
	game.numeric_player.values["attack_speed"] = 1.0
	press(KEY_Z)
	step(0)
	press(KEY_A)
	step(849)
	check(game.player["action"]=="upper","Weapon Combo cannot use the generic Upper Slash hitbox cancel window")
	step(1)
	check(game.player["action"]=="weaponcombo" and game.player["stage"]==0,
		"After Upper Slash recovery a buffered Weapon Combo starts from the first stage")
	for opener: int in [KEY_X,KEY_A]:
		start_room("original_27000","shortsword",1,spec)
		game.clear_monsters()
		game.numeric_player.values["attack_speed"] = 1.0
		press(opener)
		step(0)
		var balance: float = game.player["mp"]
		press(KEY_A)
		press(KEY_X)
		step(250 if opener==KEY_X else 240)
		check(game.player["action"]==("attack2" if opener==KEY_X else "attack1") and game.player["mp"]==balance,
			"The original common input handles X before the Swordman skill request on the same frame")

func check_heavy_weapon_combo() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"weaponmaster"})
	profile.command("numbers.skill_grant",{"id":"weaponcombo","level":1})
	for sample: Array in [[2,0,210,1.0],[3,0,210,1.0],[3,250,367,1.0],[3,999,839,1.0],
			[3,1000,840,1.25],[3,1030,840,1.0]]:
		profile.command("numbers.skill_grant",{"id":"heavyswordmastery","level":sample[0]})
		var spec := profile.stats()
		spec["skill_slots"] = ["weaponcombo"]
		start_room("","greatsword",1,spec)
		game.numeric_player.values["attack_speed"] = sample[3]
		game.numeric_player.values["mp_cost_rate"] = 1.0
		game.numeric_player.values["hit"] = 1.0
		game.player["mp"] = 12.0
		var target: Dictionary = api.spawn_dummy(POINT+Vector2(65,0))
		press(KEY_A)
		step(0)
		session.submit_key(KEY_A,true)
		step(300.0/float(sample[3])-1.0)
		check(game.player["stage"]==0 and game.player["mp"]==6.0,"Heavy Weapon Combo waits for frame five")
		step(1)
		check(game.player["stage"]==1 and game.player["mp"]==0.0,"Heavy Weapon Combo pays for the second stage at its gate")
		if sample[0] >= 3:
			var charge := cues("weapon_combo_heavy_charge")
			check(charge.size()==1 and charge[0]["offset_x"]==-52.0 and charge[0]["offset_y"]==-70.0
				and is_equal_approx(charge[0]["uniform_frame_ms"],55.0/float(sample[3])),
				"Heavy Weapon Combo retimes and offsets the original charge attachment")
			var held_ms := 240 if sample[1]==250 else mini(sample[1],999)
			step(held_ms)
			check(game.player.has("weapon_combo_charge") and game.player_ani()==["weaponcomboheavy2",0.0]
				and target["hp"]==5000.0 and cues("weapon_combo_heavy_finish").is_empty(),
				"Heavy Weapon Combo holds the opening pose without contact through "+str(held_ms)+" ms")
			if sample[1]>=1000:
				step(sample[1]-999)
				check(not game.player.has("weapon_combo_charge") and game.player["clock"]==0.0,
					"Heavy Weapon Combo enters the release at frame zero on the first tick at or past 1000 ms")
		else:
			check(cues("weapon_combo_heavy_charge").is_empty(),"Heavy Weapon Combo has no charge below mastery rank three")
		session.submit_key(KEY_A,false)
		step(10 if sample[1]==250 else 0)
		check(game.action_def()["hits"][0]["percent"]==sample[2] and game.player["mp"]==0.0
			and cues("weapon_combo_heavy_finish").size()==1,"Heavy Weapon Combo releases with the native damage ramp and no new cost")
		var contact_ms := 180.0/float(sample[3])
		step(contact_ms-1.0)
		check(target["hp"]==5000.0,"Heavy Weapon Combo has no hit before the source contact frame")
		step(1)
		check(target["hp"]<5000.0 and game.hit_count==1,"Heavy Weapon Combo hits when the released body reaches frame three")
		check(game.attack_body_armor(),"Heavy Weapon Combo keeps the source frame-three armor")
		step(60.0/float(sample[3]))
		check(not game.attack_body_armor(),"Heavy Weapon Combo clears body armor on source frame four")
	var spec := profile.stats()
	spec["skill_slots"] = ["weaponcombo"]
	start_room("","greatsword",1,spec)
	game.numeric_player.values["attack_speed"] = 1.0
	press(KEY_A)
	step(0)
	session.submit_key(KEY_A,true)
	step(300)
	var source := {"pos":POINT+Vector2(40,0)}
	var atk: Dictionary = game.table.atk("character/swordman/attackinfo/attack1.atk")
	check(game.hurt_player(7,source,atk,-1)=="none" and game.player.has("weapon_combo_charge"),
		"Heavy Weapon Combo retains its frame-zero armor while charging")
	game.player["invuln_ms"] = 0.0
	atk = atk.duplicate()
	atk["ignore_super_armor"] = 1
	check(game.hurt_player(7,source,atk,-1)=="stagger" and not game.player.has("weapon_combo_charge"),
		"Heavy Weapon Combo drops its charge on armor-piercing interruption")
	session.submit_key(KEY_A,false)
	step(1000)
	check(cues("weapon_combo_heavy_finish").is_empty(),"Interrupted Heavy Weapon Combo never emits the delayed release")

func check_overdrive_attributes() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"weaponmaster"})
	profile.command("numbers.skill_grant",{"id":"durabilityup","level":2})
	for sample: Array in [[1,0.05,30],[2,0.055,36],[4,0.066,50],[20,0.15,252]]:
		profile.command("numbers.skill_grant",{"id":"overdrive","level":sample[0]})
		var spec := profile.stats()
		spec["skill_slots"] = ["overdrive"]
		start_room("original_27601","katana",1,spec)
		game.player["mp"] = 5000.0
		game.numeric_player.values["cast_speed"] = 1.0
		var base_crit: float = game.numeric_player.values["physical_crit"]
		var base_physical: float = game.numeric_player.values["physical_attack"]
		var base_magical: float = game.numeric_player.values["magical_attack"]
		var base_panel: float = game.numeric_player.values["physical_panel"]
		press(KEY_A)
		step(0)
		step(500)
		var effect: Dictionary = game.numeric_player.effects.active.get("overdrive",{})
		check(effect.get("rank")==sample[0] and effect.get("remaining_ms")==120000.0,
			"Overdrive shortcut applies the original duration at rank "+str(sample[0]))
		check(is_equal_approx(game.numeric_player.values["physical_crit"]-base_crit,float(sample[1])),
			"Overdrive adds the correct original critical chance at rank "+str(sample[0]))
		check(is_equal_approx(game.numeric_player.values["physical_attack"]-base_physical,float(sample[2]))
			and game.numeric_player.values["magical_attack"]==base_magical,
			"Overdrive raises physical attack and preserves magical attack at rank "+str(sample[0]))
		check(game.numeric_player.values["physical_panel"]>base_panel,
			"Overdrive updates the derived physical panel with the weapon attack bonus")
		if sample[0]==2:
			var target: Dictionary = api.spawn_dummy(POINT+Vector2(60,0))
			game.numeric_player.values["attack_speed"] = 1.0
			game.numeric_player.values["hit"] = 1.0
			press(KEY_X)
			step(0)
			step(210)
			check(target["hp"]<5000.0 and is_equal_approx(game.last_damage.get("trace",{}).get("attack",0.0),base_physical+36.0),
				"Overdrive's original rank two weapon attack reaches the normal-hit damage resolver")
			var damage: Array = game.bus.events_of("combat.damage")
			check(not damage.is_empty() and damage[-1].get("weapon_wear_units")==2714,
				"Rank two Overdrive and Weapon Conservation both reach the landed-hit wear fact")
		game.step_numeric_actor(game.player,game.numeric_player,119999)
		check(game.numeric_player.effects.active.get("overdrive",{}).get("remaining_ms")==1.0,
			"Overdrive lasts through the last millisecond")
		game.step_numeric_actor(game.player,game.numeric_player,1)
		check(not game.numeric_player.effects.active.has("overdrive")
			and is_equal_approx(game.numeric_player.values["physical_crit"],base_crit)
			and is_equal_approx(game.numeric_player.values["physical_attack"],base_physical)
			and is_equal_approx(game.numeric_player.values["physical_panel"],base_panel),
			"Overdrive expiry restores baseline physical attack, panel and critical chance")
		check(game.numeric_player.weapon_wear_units(2)==920 and game.numeric_player.weapon_wear_units(0)==1000,
			"Overdrive expiry leaves only the learned Weapon Conservation reduction")

func check_overdrive_cast() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"weaponmaster"})
	profile.command("numbers.skill_grant",{"id":"overdrive","level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["overdrive"]
	for sample: Array in [[1.0,334,500],[1.25,267,401]]:
		start_room("original_27601","katana",1,spec)
		game.player["mp"] = 5000.0
		game.numeric_player.values["cast_speed"] = sample[0]
		press(KEY_A)
		step(0)
		check(game.player_ani()[0]=="summon2" and cues("self_buff_start").size()==1
			and cues("MOON_CURTAIN_LIGHT").size()==1 and cues("SM_OVERDRIVE").size()==1,
			"Overdrive opens with the original CHR buff pose, common effect and two cast sounds")
		var start_cues := cues("self_buff_start")
		check(not start_cues.is_empty() and start_cues[0]["follow"]==0 and start_cues[0]["offset_y"]==-130,
			"Overdrive attaches the cast effect above the caster")
		step(sample[1]-1)
		check(cues("self_buff_loop").is_empty() and game.active_effect("overdrive").is_empty(),
			"Overdrive's start effect and cast persist before the original loop handoff")
		step(1)
		check(cues("self_buff_loop").size()==1 and game.active_effect("overdrive").is_empty(),
			"Overdrive hands off to the looping effect at the speed-scaled start ANI boundary")
		step(sample[2]-sample[1]-1)
		check(game.active_effect("overdrive").is_empty() and cues("BUFF_OVERDRIVE").is_empty(),
			"Overdrive applies no stats or finish sound before the scaled buff ANI ends")
		step(1)
		check(not game.active_effect("overdrive").is_empty() and game.player["action"]==""
			and cues("BUFF_OVERDRIVE").size()==1 and game.view_snapshot()["player"]["aura"]=="",
			"Overdrive applies the buff on normal exit and plays its own finish sound")
	start_room("original_27601","katana",1,spec)
	game.player["mp"] = 5000.0
	game.numeric_player.values["cast_speed"] = 1.0
	press(KEY_A)
	step(0)
	step(400)
	game.damage_player(7,POINT+Vector2(60,0))
	step(100)
	check(not game.player.has("overdrive_cast") and game.active_effect("overdrive").is_empty()
		and cues("BUFF_OVERDRIVE").is_empty(),"Incoming damage interrupts Overdrive without attaching the buff")

func overdrive_particles() -> Array:
	return game.view.effects.filter(func(fx):return fx.tag=="overdrive_status")

func check_overdrive_particles() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"weaponmaster"})
	profile.command("numbers.skill_grant",{"id":"overdrive","level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["overdrive"]
	start_room("original_27601","katana",1,spec)
	game.player["mp"] = 5000.0
	game.numeric_player.values["cast_speed"] = 1.0
	press(KEY_A)
	step(0)
	step(499)
	check(overdrive_particles().is_empty(),"Overdrive emits no active-buff particles while casting")
	step(1)
	var particles := overdrive_particles()
	check(particles.size()==1 and particles[0].data["source"]=="common/commoneffect/animation/status_effect/pattack.ani",
		"Overdrive starts with one native physical-attack particle at successful cast exit")
	if particles.is_empty():return
	var first: Node2D = particles[0]
	var emitter: RefCounted = game.view._overdrive_emitter["emitter"]
	check(emitter.origin==Vector3i(400,300,50) and emitter.config["life_time"]==700,
		"Overdrive's source emitter starts at caster XYZ plus half the standing body height")
	game.step_numeric_actor(game.player,game.numeric_player,249)
	game.view.present(game.view_snapshot(),249.0,249.0)
	game.view.present(game.view_snapshot(),200.0,0.0)
	check(overdrive_particles().size()==1,"Overdrive accumulates emission on simulation time and stays at one particle through 249 ms")
	game.player["pos"] = POINT+Vector2(180,20)
	game.player["z"] = 12.0
	game.step_numeric_actor(game.player,game.numeric_player,1)
	game.view.present(game.view_snapshot(),1.0,1.0)
	particles = overdrive_particles()
	check(particles.size()==2 and emitter.origin==Vector3i(580,320,62) and absf(first.position.x-400.0)<40.0
		and absf(particles[1].position.x-580.0)<40.0,
		"Overdrive emits again at 250 ms from the current caster position and leaves existing particles in world space")
	game.step_numeric_actor(game.player,game.numeric_player,119749)
	game.view.present(game.view_snapshot(),0.0,0.0)
	check(not overdrive_particles().is_empty(),"Overdrive retains the particle emitter through the last active millisecond")
	game.step_numeric_actor(game.player,game.numeric_player,1)
	game.view.present(game.view_snapshot(),1.0,1.0)
	check(overdrive_particles().is_empty() and game.view._overdrive_emitter.is_empty(),
		"Overdrive expiry discards the owned emitter and its remaining particles")

func check_frenzy_drain() -> void:
	session.set_skill_material_spender(func(id: int, amount: int):return id==3037 and amount==1)
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"berserker"})
	profile.command("numbers.skill_grant",{"id":"buff","level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["buff"]
	start_room("original_27601","katana",1,spec,"berserker")
	game.player["hp"] = 1000.0
	press(KEY_A)
	step(0)
	step(float(game.player["frenzy_cast"]["duration_ms"]))
	check(game.primary_normal_attack()=="frenzy1" and game.view_snapshot()["player"]["buff"],
		"the Frenzy shortcut activates the dual-wield form and its presentation")
	game.player["hp"] = 100.0
	game.step_numeric_actor(game.player,game.numeric_player,133)
	check(game.player["hp"]==100.0,"rank-one Frenzy keeps fractional drain below one HP")
	game.step_numeric_actor(game.player,game.numeric_player,1)
	check(game.player["hp"]==99.0,"rank-one Frenzy drains one HP at the 134th millisecond")
	game.step_numeric_actor(game.player,game.numeric_player,8000)
	check(game.player["hp"]==39.0 and game.primary_normal_attack()=="frenzy1",
		"Frenzy keeps draining beyond the former eight-second timeout")
	game.player["hp"] = 3.0
	game.step_numeric_actor(game.player,game.numeric_player,400)
	check(game.player["hp"]==1.0 and game.primary_normal_attack()=="attack1" and not game.view_snapshot()["player"]["buff"],
		"Frenzy leaves one HP and clears the dual-wield form and its presentation")
	check(game.bus.events_of("combat.damage").is_empty() and game.bus.events_of("combat.damage_number").is_empty()
		and not game.finished,"Frenzy drain produces no hit, damage number or defeat")

	profile.command("numbers.skill_grant",{"id":"buff","level":2})
	spec = profile.stats()
	spec["skill_slots"] = ["buff"]
	start_room("original_27601","katana",1,spec,"berserker")
	game.player["hp"] = 1000.0
	press(KEY_A)
	step(0)
	step(float(game.player["frenzy_cast"]["duration_ms"]))
	game.player["hp"] = 100.0
	game.step_numeric_actor(game.player,game.numeric_player,1000)
	check(game.player["hp"]==92.0,"rank-two Frenzy samples its own HP drain column")

func check_frenzy_attributes() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"berserker"})
	profile.command("numbers.skill_grant",{"id":"rage_slash","level":1})
	var cooldown_skills := ["grabblastblood","bloodblast","bloodblastex","rage_slash","upper"]
	for sample: Array in [[1,0.002,10,[100,150,150,50,0]],[2,0.004,21,[174,318,318,106,0]]]:
		profile.command("numbers.skill_grant",{"id":"buff","level":sample[0]})
		var spec := profile.stats()
		spec["skill_slots"] = ["buff","rage_slash"]
		start_room("original_27601","katana",1,spec,"berserker")
		game.player["hp"] = 1000.0
		var before: Dictionary = game.numeric_player.values.duplicate()
		var target: Dictionary = api.spawn_dummy(POINT+Vector2(40,0))
		var point := Vector3(POINT.x+40,POINT.y,0)
		var hit := {"atk":{},"percent":100,"skill_id":"attack1"}
		game.rng.reseed(70)
		var roll: float = game.rng.next_float()
		target["numeric"].values["evasion"] = 1.0+float(before["hit"])-roll+0.001
		game.rng.reseed(70)
		game.land_hit(game.player,target,hit,point,1,100)
		check(game.last_damage["missed"],"the chosen roll misses before Frenzy")
		press(KEY_A)
		step(0)
		step(float(game.player["frenzy_cast"]["duration_ms"]))
		var after: Dictionary = game.numeric_player.values
		check(is_equal_approx(float(after["hit"])-float(before["hit"]),float(sample[1]))
			and float(after["hit_recovery"])-float(before["hit_recovery"])==float(sample[2]),
			"Frenzy samples hit and recovery separately at rank "+str(sample[0]))
		check(after["attack_speed"]==before["attack_speed"] and after["move_speed"]==before["move_speed"]
			and after["damage_rate"]==before["damage_rate"] and after["taken_rate"]==before["taken_rate"],
			"Frenzy adds no blanket speed, damage or vulnerability modifiers")
		game.rng.reseed(70)
		game.land_hit(game.player,target,hit,point,1,100)
		check(not game.last_damage["missed"],"Frenzy turns the same roll into a hit")
		var cooldown_rate := float(after["cooldown_rate"])
		for index in cooldown_skills.size():
			var skill: String = cooldown_skills[index]
			var move: Dictionary = game.move_def(skill)
			game.begin_skill_cooldown(skill,move)
			check(is_equal_approx(float(game.player["cooldowns"].get(skill,0.0)),
				(float(move["cool_ms"])-float(sample[3][index]))*cooldown_rate/1000.0),
				"Frenzy adjusts only the sourced cooldown by flat milliseconds for "+skill)
		game.end_action()
		game.player["cooldowns"].erase("rage_slash")
		press(KEY_S)
		step(0)
		check(game.player["action"]=="rage_slash" and is_equal_approx(float(game.player["cooldowns"].get("rage_slash",0.0)),
			(float(game.move_def("rage_slash")["cool_ms"])-float(sample[3][3]))*cooldown_rate/1000.0),
			"the Gore Cross shortcut uses the sourced cooldown through actual cast")
		var reaction: String = game.hurt_player(1,target,{},-1)
		var rules: Dictionary = game.rules["reaction"]
		var stun := float(rules["stun_base_ms"])*float(rules["stun_reference_recovery"])/float(after["hit_recovery"])
		check(reaction=="stagger" and is_equal_approx(float(game.player["stun_ms"]),stun),
			"Frenzy shortens hit stun through recovery without granting blanket armor")
		game.player["hp"] = 2.0
		game.step_numeric_actor(game.player,game.numeric_player,1000)
		check(game.numeric_player.values["hit"]==before["hit"]
			and game.numeric_player.values["hit_recovery"]==before["hit_recovery"],
			"both sourced bonuses are removed with Frenzy")
		check(game.frenzy_cooldown_reduction_ms("rage_slash")==0,
			"Frenzy stops adjusting new cooldowns once the form expires")

func check_frenzy_cast() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"berserker"})
	profile.command("numbers.skill_grant",{"id":"buff","level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["buff"]
	start_room("original_27601","katana",1,spec,"berserker")
	game.numeric_player.values["cast_speed"] = 1.25
	game.player["hp"] = 221.9
	var mp: float = game.player["mp"]
	press(KEY_A)
	step(0)
	check(game.player["action"]=="" and game.player["hp"]==221.9 and game.player["mp"]==mp
		and game.player["cooldowns"].get("buff",0)==0,
		"the Frenzy shortcut rejects integer HP equal to the cast cost plus one without spending")
	game.player["hp"] = 222.0
	press(KEY_A)
	step(0)
	check(game.player["hp"]==2.0 and game.player["action"]=="buff" and game.primary_normal_attack()=="attack1"
		and cues("frenzy_cast").size()==1,"the next integer HP admits the cast and starts its attached effect")
	check(game.view.player_actor.pose=="throw1" and cues("SM_FLENSE").size()==1 and cues("FLENSE_GET").size()==1,
		"Frenzy opens with the original charge motion and both cast audio cues")
	var cast_fx = game.view.effects.filter(func(fx):return fx.data["source"].ends_with("/frenzy/cast.ani"))[0]
	step(66)
	check(int(cast_fx.frame["img_frame"])==0 and cast_fx.uniform_frame_ms==83.0,
		"the cast attachment keeps its first original frame until the rewritten delay")
	step(1)
	check(int(cast_fx.frame["img_frame"])==1,"the cast attachment advances with the actor clock")
	step(332)
	check(game.active_effect("frenzy").is_empty(),"1.25 cast speed keeps Frenzy inactive through 399 ms")
	step(1)
	check(game.primary_normal_attack()=="frenzy1" and game.view_snapshot()["player"]["buff"]
		and game.view.player_actor.pose=="throw2" and game.player["clock"]==0.0,
		"at 400 ms Frenzy enables the form and enters the original shoot motion at frame zero")
	var release_fx = game.view.effects.filter(func(fx):return fx.data["source"].ends_with("/frenzy/blast.ani"))[0]
	check(int(release_fx.frame["img_frame"])==6 and cues("frenzy_blast").size()==1 and cues("FLENSE_CHARGE").size()==1,
		"phase two replaces the cast attachment with the original burst and release cue")
	step(39)
	check(int(release_fx.frame["img_frame"])==6,"the first blast frame lasts until the native 50-ms animation boundary")
	step(1)
	check(int(release_fx.frame["img_frame"])==7,"blast timing follows the phase-two animation clock")
	step(239)
	check(int(release_fx.frame["img_frame"])==12 and game.player["action"]=="buff",
		"the final blast frame is visible through the last millisecond of recovery")
	step(1)
	check(game.view.player_actor.pose=="stay" and game.primary_normal_attack()=="frenzy1"
		and game.view.effects.filter(func(fx):return fx.data["source"].ends_with("/frenzy/blast.ani")).is_empty(),
		"recovery ends at 280 ms and clears the burst while leaving Frenzy active")

	start_room("original_27601","katana",1,spec,"berserker")
	game.numeric_player.values["cast_speed"] = 1.0
	game.player["hp"] = 1000.0
	press(KEY_A)
	step(499)
	check(game.active_effect("frenzy").is_empty(),"base cast speed has not activated at 499 ms")
	step(1)
	check(not game.active_effect("frenzy").is_empty(),"base cast speed activates at exactly 500 ms")

	start_room("original_27601","katana",1,spec,"berserker")
	game.numeric_player.values["cast_speed"] = 1.0
	game.player["hp"] = 1000.0
	press(KEY_A)
	step(499)
	game.hurt_player(1,{"pos":POINT+Vector2(40,0)},{},-1)
	step(500)
	check(game.active_effect("frenzy").is_empty() and not game.player.has("frenzy_cast")
		and game.bus.events_of("combat.cue").any(func(event):return event.get("kind")=="fx_clear"),
		"an interrupted cast clears its effect and never enables the form")

func check_frenzy_normals() -> void:
	session.set_skill_material_spender(func(id: int, amount: int):return id==3037 and amount==1)
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"berserker"})
	profile.command("numbers.skill_grant",{"id":"buff","level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["buff"]
	for item: Array in [["original_27000","shortsword",1],["original_27601","katana",-1]]:
		var facing := int(item[2])
		start_room(item[0],item[1],facing,spec,"berserker")
		game.player["hp"] = 1000.0
		check(not game.start_action("frenzy1"),"dual wield requires the active Frenzy appendage")
		press(KEY_A)
		step(0)
		step(float(game.player["frenzy_cast"]["duration_ms"]))
		step(float(game.player["frenzy_cast"]["duration_ms"]))
		game.numeric_player.values["attack_speed"] = 1.0
		game.numeric_player.values["hit"] = 1.0
		game.player["mp"] = 0.0
		var target: Dictionary = api.spawn_dummy(POINT+Vector2(60*facing,0))
		press(KEY_X)
		step(0)
		for stage in range(1,5):
			var name := "frenzy%d" % stage
			var hit: Dictionary = game.action_def()["hits"][0]
			var segment: Dictionary = hit["segments"][0]
			var last := 300.0 if stage == 1 else 240.0
			check(game.player["action"]==name and game.view.player_actor.pose==name and game.player["mp"]==0.0,
				"X enters "+name+" without charging the Frenzy skill again")
			check(hit["source"]=="attached_weapon" and segment["start"]==120.0 and segment["end"]==last
				and not hit["skill"] and hit["percent"]==[56.0,65.0,75.0,97.0][stage-1],
				"the equipped layer and truncated original ATK scale drive "+name)
			move_target(target,POINT+Vector2(60*facing,0))
			step(119)
			check(game.hit_count==stage-1,"no startup hit in "+name)
			step(1)
			check(game.hit_count==stage,"frame 2 hits in "+name)
			check(game.view.player_actor.equipment_layers.all(func(layer):return int(layer.frame.get("frame",-1))==2),
				"the equipped weapon is drawn at frame 2 in "+name)
			var layers: Array = game.view.effects.filter(func(fx):return fx.data["source"].get_file().begins_with("sword%d-" % stage))
			check(layers.size()==3 and layers.all(func(fx):return fx.facing==facing and fx.clock_ms==120.0)
				and layers.any(func(fx):return fx.z_index<game.view.player_actor.z_index)
				and layers.any(func(fx):return fx.z_index>game.view.player_actor.z_index),
				"native blood sword layers follow both sides of the body in "+name)
			game.player["stuck_ms"] = 0.0
			if stage < 4:
				var gate: float = [300.0,180.0,240.0][stage-1]
				if stage != 2:press(KEY_X)
				step(gate-121.0)
				check(game.player["action"]==name and game.hit_count==stage,"no early continuation or repeat hit in "+name)
				if stage == 2:
					session.submit_key(KEY_X,true)
					step(0)
					game.player["queued_combo"] = false
				step(1)
				if stage == 2:session.submit_key(KEY_X,false)
				check(game.player["action"]=="frenzy%d" % (stage+1),"the next swing starts at the native frame boundary")
				check(layers.all(func(fx):return fx.is_queued_for_deletion()),"transition removes the previous sword layers")
			else:
				press(KEY_X)
				step(479)
				check(game.player["action"]=="frenzy4" and game.hit_count==4,"the final swing recovers without wrapping into the first")
				step(1)
				check(game.player["state"]=="idle","the fourth swing finishes at the original body end")
		press(KEY_X)
		step(0)
		check(game.player["action"]=="frenzy1","a fresh attack after recovery starts a new combo")
		press(KEY_X)
		game.player["hp"] = 3.0
		game.step_numeric_actor(game.player,game.numeric_player,400)
		step(700)
		check(game.player["state"]=="idle" and game.primary_normal_attack()=="attack1",
			"Frenzy expiring at one HP clears the buffered form combo and returns to ordinary attacks")

func check_frenzy_bleed() -> void:
	session.set_skill_material_spender(func(id: int, amount: int):return id==3037 and amount==1)
	var seeds := {}
	for seed_value in 100000:
		game.rng.reseed(seed_value)
		game.rng.next_float()
		game.rng.next_float()
		# The first katana ATK uses the CHR's small cut and blood cue variants.
		game.rng.range_int(1,3)
		game.rng.range_int(1,3)
		var roll: int = game.rng.range_int(0,9999)
		if roll in [599,600] and not seeds.has(roll):seeds[roll] = seed_value
		if seeds.size()==2:break
	check(seeds.size()==2,"fixed seeds reach both sides of the Frenzy bleed roll")
	if seeds.size()!=2:return
	for rank in [1,2]:
		var profile := ProfileSession.new()
		profile.command("numbers.level",{"level":60})
		profile.command("numbers.growtype",{"growtype":"berserker"})
		profile.command("numbers.skill_grant",{"id":"buff","level":rank})
		var spec := profile.stats()
		spec["skill_slots"] = ["buff"]
		start_room("original_27601","katana",1,spec,"berserker")
		game.player["hp"] = 1000.0
		press(KEY_A)
		step(0)
		step(float(game.player["frenzy_cast"]["duration_ms"]))
		step(float(game.player["frenzy_cast"]["duration_ms"]))
		game.numeric_player.values["attack_speed"] = 1.0
		game.numeric_player.values["hit"] = 1.0
		var status_level := 36 if rank==1 else 38
		for scenario: Array in [[599,0,0,true],[600,0,0,rank==2],[599,25,0,false],[600,0,-1,true],[599,0,3,false]]:
			var target: Dictionary = api.spawn_dummy(POINT+Vector2(60,0))
			target["numeric"].values["level"] = status_level+int(scenario[2])
			target["numeric"].values["bleeding_resistance"] = scenario[1]
			game.rng.reseed(seeds[scenario[0]])
			press(KEY_X)
			step(0)
			step(120)
			var bleed: Dictionary = target["numeric"].effects.active.get("bleed",{})
			check((not bleed.is_empty())==scenario[3],"Frenzy bleed roll %d at rank %d with %d resistance and level gap %d" % [scenario[0],rank,scenario[1],scenario[2]])
			if not bleed.is_empty():
				check(bleed["definition"]["status_level"]==status_level and bleed["remaining_ms"]==3000.0,
					"Frenzy keeps the sourced status level and unscaled 3000 ms duration")
				if scenario[0]==599 and scenario[1]==0:
					target["numeric"].step(2999)
					check(target["numeric"].effects.active.has("bleed"),"Frenzy bleed remains through 2999 ms")
					target["numeric"].step(1)
					check(not target["numeric"].effects.active.has("bleed"),"Frenzy bleed expires at 3000 ms")
			game.monsters.erase(target)
			game.player["stuck_ms"] = 0.0
			game.end_action()

func check_frenzy_recovery() -> void:
	session.set_skill_material_spender(func(id: int, amount: int):return id==3037 and amount==1)
	for scenario: Array in [[1,1000,99,true,-1],[1,1000,100,false,-1],
			[1,100,100,true,0],[1,1000,100,true,6],[1,4000,100,true,22],[2,4000,100,true,27]]:
		var profile := ProfileSession.new()
		profile.command("numbers.level",{"level":60})
		profile.command("numbers.growtype",{"growtype":"berserker"})
		profile.command("numbers.skill_grant",{"id":"buff","level":scenario[0]})
		var spec := profile.stats()
		spec["skill_slots"] = ["buff"]
		start_room("original_27601","katana",1,spec,"berserker")
		game.player["hp"] = 1000.0
		press(KEY_A)
		step(0)
		var cast_ms: float = game.player["frenzy_cast"]["duration_ms"]
		step(cast_ms)
		step(cast_ms)
		game.god_mode = true
		game.numeric_player.values["hp_regen"] = 0.0
		game.numeric_player.values["attack_speed"] = 1.0
		game.numeric_player.values["hit"] = 1.0
		var target: Dictionary = api.spawn_dummy(POINT+Vector2(60,0))
		var far_enemy: Dictionary = game.spawn_enemy(POINT+Vector2(180,0))
		far_enemy["ai"] = false
		if scenario[3]:game.apply_effect({"kind":"effect","id":"bleed","target":target["id"]})
		target["numeric"].values["hp_max"] = float(scenario[1])
		target["hp"] = 1.0
		game.step_game(scenario[2])
		var before: float = game.player["hp"]
		press(KEY_X)
		step(0)
		step(120)
		var expected: int = scenario[4]
		check(target["hp"]==0.0 and cues("frenzy_create_ball").size()==int(expected>=0)
			and cues("FLENSE_SUCK").size()==int(expected>=0),"Frenzy kill requires a scan of a living bleeding target: "+str(scenario))
		if expected < 0:continue
		check(game.frenzy_recovery.view_objects(game).is_empty() and game.player["hp"]==before,
			"Frenzy starts with only the creation effect and no HP")
		game.step_game(179.0)
		check(game.frenzy_recovery.view_objects(game).is_empty(),"Frenzy ball stays hidden through 179 ms")
		game.step_game(1.0)
		var layers: Array = game.frenzy_recovery.view_objects(game)
		check(layers.size()==2 and layers[0]["effect"]=="frenzy_ball_layer" and layers[1]["effect"]=="frenzy_ball"
			and layers[1]["clock"]==180.0 and layers[1]["loop"]
			and is_equal_approx(layers[1]["fade"],100.0/255.0),"Both original blood orb layers appear at 180 ms")
		game.step_game(450.0)
		layers = game.frenzy_recovery.view_objects(game)
		check(layers.size()==2 and layers[1]["clock"]==630.0 and layers[1]["fade"]==1.0,
			"Frenzy ball begins flight at 630 ms")
		game.step_game(399.0)
		check(game.player["hp"]==before and cues("FLENSE_FLASH").is_empty(),"Frenzy does not heal before 1030 ms")
		game.step_game(1.0)
		check(game.player["hp"]==before and cues("FLENSE_FLASH").size()==1 and game.frenzy_recovery.view_objects(game).is_empty(),
			"Frenzy starts 500 ms recovery at 1030 ms and removes the ball")
		game.step_game(250.0)
		check(is_equal_approx(game.player["hp"],before+float(expected)/2.0),"Frenzy recovers half of the sourced amount at 1280 ms")
		game.step_game(250.0)
		check(is_equal_approx(game.player["hp"],before+expected) and game.item_restorations.is_empty(),
			"Frenzy rank and enemy max HP cap finish at 1530 ms: "+str(scenario))
	game.god_mode = false

func check_frenzy_toggle() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"berserker"})
	profile.command("numbers.skill_grant",{"id":"buff","level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["buff"]
	start_room("original_27601","katana",1,spec,"berserker")
	game.player["hp"] = 1000.0
	var spent: Array = []
	session.set_skill_material_spender(func(id: int, amount: int):
		spent.append([id,amount])
		return spent.size()==1)
	press(KEY_A)
	step(0)
	step(float(game.player["frenzy_cast"]["duration_ms"]))
	game.end_action()
	# Isolate the appendage gate from the normal cooldown, which began earlier.
	game.player["cooldowns"]["buff"] = 0.0
	game.step_numeric_actor(game.player,game.numeric_player,9999)
	game.player["mp"] = 0.0
	press(KEY_A)
	step(0)
	check(not game.active_effect("frenzy").is_empty() and game.player["action"]==""
		and game.bus.events_of("combat.action_rejected")[-1]["reason"]=="frenzy_minimum_duration",
		"the Frenzy shortcut rejects deactivation at 9999 ms of active time")
	game.step_numeric_actor(game.player,game.numeric_player,1)
	var hp: float = game.player["hp"]
	press(KEY_A)
	step(0)
	check(game.active_effect("frenzy").is_empty() and game.primary_normal_attack()=="attack1"
		and game.player["action"]=="" and not game.view_snapshot()["player"]["buff"],
		"the same shortcut deactivates Frenzy at 10000 ms without a new cast")
	check(game.player["hp"]==hp and game.player["mp"]==0.0 and spent==[[3037,1]],
		"deactivation takes no HP, MP, or additional cube")

func draw_slash_views() -> Array:
	return game.view.effects.filter(func(fx):return String(fx.data.get("source","")).contains("/momentaryslash/momentaryslash_"))

func check_draw_slash_layers(color: String, frame: int) -> void:
	var layers := draw_slash_views()
	var stems := ["none_under","none_upper",color+"_ldodge_under",color+"_ldodge_upper"]
	var depths := [-2,1,-1,2]
	var valid := layers.size()==stems.size()
	for index in layers.size():
		if index >= stems.size():break
		var fx = layers[index]
		var source := String(fx.data["source"])
		valid = valid and source.ends_with("/momentaryslash_"+String(stems[index])+".ani") \
			and int(fx.frame.get("frame",-1))==frame and fx.z_index==game.view.player_actor.z_index+depths[index] \
			and fx.facing==game.player["facing"] and int(fx.frame["items"].get("11",{}).get("type",0))==(0 if index<2 else 2)
	check(valid,"Draw Sword uses the four registered "+color+" layers in order at FX frame "+str(frame))

func check_draw_sword() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"weaponmaster"})
	profile.command("numbers.skill_grant",{"id":"draw","level":2})
	var spec := profile.stats()
	spec["skill_slots"] = ["draw"]
	start_room("original_27601","katana",1,spec)
	var spent: Array = []
	session.set_skill_material_spender(func(id: int, amount: int):
		spent.append([id,amount])
		return spent.size()==2)
	var before_mp := float(game.player["mp"])
	press(KEY_A)
	step(0)
	check(game.player["action"]=="" and game.player["mp"]==before_mp and cues("SM_BAL_READY").is_empty(),
		"Draw Sword rejects a missing cube before MP, cooldown or ready voice")
	game.numeric_player.values["attack_speed"] = 1.0
	for target: Dictionary in game.monsters:move_target(target,POINT+Vector2(600,0))
	var rear: Dictionary = game.monsters[0]
	var front: Dictionary = game.monsters[1]
	move_target(rear,POINT+Vector2(-140,0))
	move_target(front,POINT+Vector2(140,0))
	for target: Dictionary in [rear,front]:target["hp"] = 10000.0
	press(KEY_A)
	step(524)
	var hit: Dictionary = game.move_def("draw")["hits"][0]
	check(game.view.player_actor.pose=="momentaryslash" and hit["source"]=="attached_weapon"
		and hit["percent"]==1192.0 and hit["atk_path"].ends_with("/momentaryslash.atk"),
		"Draw Sword uses CHR slot 8, rank two percent and the attached weapon")
	check(spent==[[3037,1],[3037,1]] and game.player["mp"]<before_mp
		and cues("SM_BAL_READY").size()==1 and cues("SM_BAL_SHOT").is_empty() and game.hit_count==0 and draw_slash_views().is_empty(),
		"the paid cast winds up without damage through frame 1")
	step(1)
	check(game.hit_count==2 and rear["hp"]==10000.0 and front["hp"]==10000.0 and game.objects.is_empty(),
		"body frame 2 registers front and rear contacts before delayed damage")
	check(rear["state"]=="idle" and front["state"]=="idle","the opening slash leaves both grounded poses intact")
	check(cues("SM_BAL_SHOT").size()==1 and cues("R_KATANAA").size()==1
		and cues("R_DRAWING_SWORD_HIT").size()==2 and cues("SWD_BAL_END").is_empty(),
		"outgoing frame triggers the original shot, weapon swing and hit sounds")
	check_draw_slash_layers("blue",0)
	step(34)
	check_draw_slash_layers("blue",0)
	step(1)
	check_draw_slash_layers("blue",1)
	step(139)
	check_draw_slash_layers("blue",4)
	step(1)
	check(draw_slash_views().is_empty(),"all four slash effects end at 175 action milliseconds")
	step(25)
	check(rear["hp"]==10000.0 and front["hp"]==10000.0,"the first draw impact waits through the frame-two deadline")
	step(1)
	check(rear["hp"]<10000.0 and front["hp"]<10000.0,"both registered targets take damage after the frame-two deadline")
	check(rear["state"]=="hurt" and front["state"]=="hurt" and front["stun_ms"]>0.0
		and front["push_ms"]==0.0 and front["vz"]==0.0 and cues("R_DRAWING_SWORD_HIT").size()==2,
		"the temporary object's neutral ATK staggers without copying the slash's push, lift or sound")
	step(48)
	check(game.hit_count==2 and cues("SWD_BAL_END").is_empty(),"one hit per target and no sheath sound before body frame 8")
	step(1)
	check(cues("SWD_BAL_END").size()==1,"body frame 8 plays the authored sheath cue")
	step(279)
	check(game.player["action"]=="draw","the action remains in recovery through 1054 ms")
	step(1)
	check(game.player["action"]=="","the ordinary action recovers at the body ANI end")
	for family: String in ["shortsword","katana","greatsword"]:
		start_room("",family,1,spec)
		var segments: Array = game.move_def("draw")["hits"][0]["segments"]
		var width: float = {"shortsword":475.0,"katana":475.0,"greatsword":525.0}[family]
		check(segments.size()==1 and segments[0]["start"]==525.0 and segments[0]["end"]==675.0
			and segments[0]["frames"][0]["boxes"][0][3]==width,
			"family-only Draw Sword reads its authored four C-layer frames for "+family)
	session.set_skill_material_spender(func(_id: int,_amount: int):return true)
	game.numeric_player.values["attack_speed"] = 1.25
	move_target(game.monsters[0],POINT+Vector2(140,0))
	press(KEY_A)
	step(419)
	check(cues("SM_BAL_SHOT").is_empty() and game.hit_count==0,"faster Draw Sword is still before frame 2 at 419 ms")
	step(1)
	check(cues("SM_BAL_SHOT").size()==1 and game.hit_count>0,
		"weapon hit and shot share the accelerated body clock at 420 ms")
	step(27)
	check_draw_slash_layers("blue",0)
	step(1)
	check_draw_slash_layers("blue",1)

func check_draw_target_deadlines() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"weaponmaster"})
	profile.command("numbers.skill_grant",{"id":"draw","level":2})
	var spec := profile.stats()
	spec["skill_slots"] = ["draw"]
	start_room("original_27601","katana",1,spec)
	session.set_skill_material_spender(func(_id: int,_amount: int):return true)
	game.numeric_player.values["attack_speed"] = 1.0
	game.numeric_player.values["hit"] = 1.0
	game.numeric_player.values["physical_crit"] = 0.0
	game.numeric_player.values["physical_back_crit"] = 1.0
	for enemy: Dictionary in game.monsters:move_target(enemy,POINT+Vector2(1200,0))
	var first: Dictionary = game.monsters[0]
	var late: Dictionary = game.monsters[1]
	for enemy: Dictionary in [first,late]:enemy["hp"] = 5000.0
	move_target(first,POINT+Vector2(100,0))
	press(KEY_A)
	step(525)
	check(game.draw_pending_hits.size()==1 and game.draw_pending_hits[0]["remaining_ms"]==200.0,
		"frame-two contact starts a 200 ms temporary hit without aging on birth")
	move_target(first,POINT-Vector2(1200,0))
	first["facing"] = -1
	move_target(late,POINT+Vector2(100,0))
	late["facing"] = 1
	step(65)
	check(game.draw_pending_hits.size()==2 and game.draw_pending_hits[1]["remaining_ms"]==150.0,
		"frame-four contact sums only frames four through six")
	step(135)
	check(first["hp"]==5000.0 and late["hp"]==5000.0,"the first registered target takes no damage at the exact deadline")
	step(1)
	var trace: Dictionary = game.last_damage.get("trace",{})
	check(first["hp"]<5000.0 and late["hp"]==5000.0
		and is_equal_approx(float(trace.get("percent_part",0.0)),float(trace.get("attack",-1.0))*14.60),
		"the tracked first target still takes damage after moving away and uses the current two-target bonus")
	check(game.last_damage["critical"],
		"the temporary object hits the back of a target that crossed its stored X")
	game.end_action()
	step(14)
	check(late["hp"]==5000.0,"the second target retains its own later deadline after interruption")
	step(1)
	var impacts: Array = game.bus.events_of("combat.damage").filter(func(event):return event.get("source_object",0)==35687)
	check(late["hp"]<5000.0 and game.draw_pending_hits.is_empty() and impacts.size()==2 and game.hit_count==2
		and impacts[0]["point"]==Vector3(500,300,0),
		"both temporary hits resolve once without replaying the two initial contacts")
	check(game.last_damage["critical"],
		"at the same integer X the temporary attack uses its original facing")
	start_room("original_27601","katana",1,spec)
	session.set_skill_material_spender(func(_id: int,_amount: int):return true)
	game.numeric_player.values["attack_speed"] = 1.0416666966666668
	var draw_timeline: Array = game.move_def("draw")["stages"][0]["timeline"]
	check(game.draw_hit_delay(draw_timeline,525.0)==187,
		"temporary hit delay uses the source percent clock and truncates each frame separately")
	game.numeric_player.values["attack_speed"] = 1.0
	game.numeric_player.values["hit"] = 1.0
	# Keep the fixture's fixed inputs through the normal battle update.
	game._dynamic_refresh_ms = 1000.0
	var target: Dictionary = api.spawn_dummy(POINT+Vector2(100,0))
	target["numeric"].values["hp_max"] = 5000.0
	press(KEY_A)
	game.step_game(525)
	check(target["hp"]==5000.0 and game.draw_pending_hits.size()==1
		and game.player["stuck_ms"]==70.0 and target["stuck_ms"]==70.0,
		"the public battle update registers both original katana stops without pre-aging")
	game.step_game(69)
	check(game.player["clock"]==525.0 and game.player["stuck_ms"]==1.0 and target["stuck_ms"]==1.0
		and game.draw_pending_hits[0]["remaining_ms"]==131.0,
		"the impact deadline advances while both actors are still stopped")
	game.step_game(1)
	check(game.player["clock"]==525.0 and game.player["stuck_ms"]==0.0 and target["stuck_ms"]==0.0,
		"the weapon stop lasts exactly 70 ms")
	game.step_game(130)
	check(target["hp"]==5000.0 and game.player["clock"]==655.0,"the impact is still pending at its exact deadline")
	game.step_game(1)
	check(target["hp"]<5000.0 and game.draw_pending_hits.is_empty()
		and game.player["stuck_ms"]==0.0 and target["stuck_ms"]==0.0,
		"the temporary object settles once without starting a new stop")

	for guard: String in ["no_hurtboxes","invulnerable_frame","super_armor"]:
		start_room("original_27601","katana",1,spec)
		session.set_skill_material_spender(func(_id: int,_amount: int):return true)
		game.numeric_player.values["attack_speed"] = 1.0
		game.numeric_player.values["hit"] = 1.0
		for enemy: Dictionary in game.monsters:move_target(enemy,POINT+Vector2(1200,0))
		target = api.spawn_dummy(POINT+Vector2(100,0))
		var before := float(target["hp"])
		press(KEY_A)
		step(525)
		check(game.draw_pending_hits.size()==1,"the initial frame registers before the target changes pose: "+guard)
		game.end_action()
		var frame: Dictionary = game.enemy_frame(target)
		var boxes: Array = frame["damage_boxes"]
		var items: Dictionary = frame.get("items",{})
		frame["items"] = items.duplicate()
		if guard == "no_hurtboxes":frame["damage_boxes"] = []
		else:frame["items"]["13"] = 2 if guard == "invulnerable_frame" else 1
		step(201)
		frame["damage_boxes"] = boxes
		frame["items"] = items
		step(1)
		var count := 1 if guard == "super_armor" else 0
		var hits: Array = game.bus.events_of("combat.damage").filter(func(event):return event.get("source_object",0)==35687)
		check(hits.size()==count and (target["hp"]<before)==(count==1) and game.draw_pending_hits.is_empty(),
			"the delayed attack checks the new frame once and never retries: "+guard)
		check(target["state"]=="idle" and target["stun_ms"]==0.0,
			"the target keeps its current action through the delayed attack: "+guard)

	start_room("original_27601","katana",1,spec)
	session.set_skill_material_spender(func(_id: int,_amount: int):return true)
	game.numeric_player.values["attack_speed"] = 1.0
	game.numeric_player.values["hit"] = 1.0
	target = api.spawn_dummy(POINT+Vector2(100,0))
	target["state"] = "air"
	target["z"] = 20.0
	target["vz"] = 12.0
	press(KEY_A)
	step(525)
	check(game.draw_pending_hits.size()==1 and target["push_ms"]==0.0 and target["vz"]==12.0,
		"first contact does not apply the slash's push and lift to an airborne target")
	step(201)
	check(target["hp"]<5000.0 and target["state"]=="air" and target["push_ms"]==0.0 and target["vz"]==12.0,
		"the delayed hit keeps an airborne target airborne without a new lift")

	start_room("original_27601","katana",1,spec)
	session.set_skill_material_spender(func(_id: int,_amount: int):return true)
	game.numeric_player.values["attack_speed"] = 1.0
	game.numeric_player.values["hit"] = 1.0
	target = api.spawn_dummy(POINT+Vector2(100,0))
	press(KEY_A)
	step(525)
	target["state"] = "hurt"
	target["hit_motion"] = "damage2"
	target["clock"] = 50.0
	target["numeric"].values["hit_recovery"] = 501.0
	target["facing"] = 1
	step(201)
	check(target["hp"]<5000.0 and target["state"]=="hurt" and target["hit_motion"]=="damage1" and target["clock"]==0.0,
		"another stagger alternates the original damage poses and restarts the motion")
	check(target["stun_ms"]==374.0 and target["facing"]==-1,
		"the delayed stagger truncates the original recovery formula and faces the temporary object")
	target["stuck_ms"] = 0.0
	game.update_enemy(target,373)
	check(target["state"]=="hurt" and target["stun_ms"]==1.0,"the target is still staggered one millisecond before recovery")
	game.update_enemy(target,1)
	check(target["state"]=="idle" and target["stun_ms"]==0.0,"the target recovers at the original stagger boundary")

	for recovery: float in [0.0,500.0,2000.0,2500.0]:
		start_room("original_27601","katana",1,spec)
		session.set_skill_material_spender(func(_id: int,_amount: int):return true)
		game.numeric_player.values["attack_speed"] = 1.0
		game.numeric_player.values["hit"] = 1.0
		target = api.spawn_dummy(POINT+Vector2(100,0))
		target["numeric"].values["hit_recovery"] = recovery
		press(KEY_A)
		step(525)
		step(201)
		var duration: float = {0.0:500.0,500.0:375.0,2000.0:0.0,2500.0:0.0}[recovery]
		check(target["hp"]<5000.0 and target["stun_ms"]==duration,
			"the delayed stagger respects the dungeon hit recovery curve at "+str(recovery))

func check_bloody_rave_phases() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"berserker"})
	profile.command("numbers.skill_grant",{"id":"bloodyrave","level":1})
	profile.command("numbers.skill_grant",{"id":"buff","level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["bloodyrave"]
	for scenario: String in ["no_frenzy","one_hp","no_cube","tap","fast_tap","hold","low_hp_hold","interrupt","interrupt_release"]:
		start_room("original_27601","katana",1,spec,"berserker")
		if scenario == "tap":game.view.audio.muted = false
		if scenario != "no_frenzy":game.apply_skill_effect("buff","frenzy")
		var rate := 2.0 if scenario=="fast_tap" else 1.0
		game.numeric_player.values["attack_speed"] = rate
		game.player["hp"] = 1000.0
		if scenario == "one_hp":game.player["hp"] = 1.99
		if scenario == "low_hp_hold":game.player["hp"] = 2.0
		var payments: Array = []
		session.set_skill_material_spender(func(id: int, amount: int):
			payments.append([id,amount])
			return scenario!="no_cube")
		var before_mp: float = game.player["mp"]
		if scenario in ["hold","low_hp_hold"]:session.submit_key(KEY_A,true)
		else:press(KEY_A)
		step(0)
		if scenario in ["no_frenzy","one_hp"]:
			var rejections: Array = game.bus.events_of("combat.action_rejected")
			var reason := "effect" if scenario == "no_frenzy" else "hp"
			check(rejections.size()==1 and rejections[0]["reason"]==reason and payments.is_empty()
				and game.player["action"]=="" and game.player["mp"]==before_mp
				and not game.player["cooldowns"].has("bloodyrave") and cues("SM_BLOOD_RAVE_STORM").is_empty(),
				"the native cast gates reject before payment and cues: "+reason)
			continue
		check(payments==[[3037,1]],"Bloody Rave asks for one original cube through the combat session")
		if scenario == "no_cube":
			check(game.player["action"]=="" and game.player["mp"]==before_mp and not game.player["cooldowns"].has("bloodyrave"),
				"cube rejection leaves Bloody Rave's MP, action and cooldown untouched")
			check(cues("SM_BLOOD_RAVE_STORM").is_empty(),"cube rejection never plays the cast voice")
			continue
		check(cues("SM_BLOOD_RAVE_STORM").size()==1,"the original storm voice plays once at cast entry")
		var hold_start := 790.0/rate
		var move: Dictionary = game.move_def("bloodyrave")
		var first_fx: String = move["stages"][0]["fx"][0]["key"]
		if scenario == "low_hp_hold":
			step(1224)
			check(game.player["stage"]==0 and game.player["hp"]==2.0,
				"two HP permits the cast, and the original drain has not reached one whole HP")
			step(1)
			check(game.player["stage"]==1 and game.player["hp"]==1.0,
				"reaching one HP after startup overrides the held key and minimum hold")
			session.submit_key(KEY_A,false)
			continue
		check(game.view.player_actor.pose=="bloodyraveinhale" and game.player["stage"]==0,"Bloody Rave starts its original inhale pose")
		step(309.0/rate)
		check(cues(first_fx).is_empty() and game.objects.is_empty(),"the first inhale layers wait for the native frame-three gate")
		step(1.0/rate)
		check(cues(first_fx).size()==1 and cues(first_fx)[0]["offset_x"]==55.0 and cues(first_fx)[0]["offset_y"]==-96.0,
			"the original inhale layer is bound to the mirrored hand offset")
		step(399.0/rate)
		check(cues("BLOODYR_BLACKHOLE_LOOP").is_empty(),"the loop waits for zero-based inhale frame eight")
		step(1.0/rate)
		var loop_id: int = game.BLOODY_RAVE_LOOP_ID
		var audio = game.view.audio
		check(cues("BLOODYR_BLACKHOLE_LOOP").size()==1 and audio._loop_voices.has(loop_id)
			and audio._loop_voices[loop_id].stream.loop,"the original inhale loop reaches a looping audio voice at frame eight")
		if scenario == "interrupt":
			game.damage_player(1.0,POINT-Vector2(50,0))
			check(game.player["action"]=="" and not audio._loop_voices.has(loop_id)
				and cues("SM_BLOOD_RAVE_ATK").is_empty(),"interrupting inhale stops its voice without a release cue")
			continue
		step(80.0/rate)
		check(game.player["hp"]==1000.0 and game.player["stage"]==0,"HP drain starts after the scaled frame-nine gate")
		var hold_ms := 3000.0 if scenario=="hold" else 500.0
		step(hold_ms-1.0)
		check(game.player["stage"]==0 and game.objects.is_empty() and game.player["hp"]==1000.0-float(int((hold_ms-1.0)*0.0023)),
			"the SKL hold limit and fractional HP drain use their own milliseconds after %s" % hold_start)
		step(1)
		check(game.player["stage"]==1 and game.view.player_actor.pose=="bloodyraveslash" and game.objects.is_empty(),
			"release enters the original slash pose before its damaging frame")
		check(audio._loop_voices.has(loop_id) and cues("DRAWING_SWORD").is_empty(),
			"the inhale voice persists into the release windup")
		if scenario == "interrupt_release":
			game.damage_player(1.0,POINT-Vector2(50,0))
			check(game.player["action"]=="" and not audio._loop_voices.has(loop_id)
				and cues("SM_BLOOD_RAVE_ATK").is_empty(),"interrupting the windup stops the loop without playing the cut")
			continue
		if scenario == "hold":session.submit_key(KEY_A,false)
		var target: Dictionary = api.spawn_dummy(POINT+Vector2(55,0))
		target["hp"] = 50000.0
		target["z"] = 60.0
		game.numeric_player.values["hit"] = 1.0
		step(460.0/rate-1.0)
		check(game.objects.is_empty() and audio._loop_voices.has(loop_id) and cues("SM_BLOOD_RAVE_ATK").is_empty(),
			"Bloody Rave has no slash object or release cues before release frame three")
		step(1)
		var cues_at_cut: Array = game.bus.events_of("combat.cue").filter(func(event):
			return event.get("key","") in ["DRAWING_SWORD","SM_BLOOD_RAVE_ATK"] \
				or (event.get("stop",false) and event.get("loop_id",-1)==loop_id))
		check(cues_at_cut.size()==3 and cues_at_cut[0].get("key")=="DRAWING_SWORD"
			and cues_at_cut[1].get("key")=="SM_BLOOD_RAVE_ATK" and cues_at_cut[2].get("stop")
			and not audio._loop_voices.has(loop_id),"slash creation orders both sounds before stopping the inhale loop")
		if scenario == "tap":
			for key: String in ["SM_BLOOD_RAVE_STORM","DRAWING_SWORD","SM_BLOOD_RAVE_ATK"]:
				var original: AudioStream = audio.variants[key][0]
				check(original is AudioStreamOggVorbis and audio.voice_pool.any(func(voice):return voice.stream==original and voice.playing),
					key+" reaches an audio player with the original stream")
		check(game.objects.size()==1 and game.objects[0]["hit"]["percent"]==1231.0
			and game.objects[0]["life_ms"]==-1.0 and not String(game.objects[0]["hit"]["rear_fx"]).is_empty(),
			"the release uses its original 1231-percent base, ANI lifetime and rear layer")
		var object_id: int = game.objects[0]["id"]
		game.step_objects(16.0,object_id)
		check(target["hp"]<50000.0 and game.objects[0]["clock"]==0.0,"the original slash attack box is active from its first frame")
	for facing: int in [1,-1]:
		start_room("original_27601","katana",facing,spec,"berserker")
		game.apply_skill_effect("buff","frenzy")
		game.numeric_player.values["attack_speed"] = 1.0
		game.numeric_player.values["hit"] = 1.0
		session.set_skill_material_spender(func(_id: int, _amount: int):return true)
		var front := POINT+Vector2(160*facing,20)
		var target: Dictionary = api.spawn_dummy(front)
		target["def"] = target["def"].duplicate()
		target["def"]["grab_allowed"] = false
		var behind: Dictionary = game.spawn_enemy(POINT+Vector2(-80*facing,0))
		var above: Dictionary = game.spawn_enemy(front)
		above["z"] = 300.0
		var dead: Dictionary = game.spawn_enemy(front)
		press(KEY_A)
		step(0)
		step(789)
		check(game.player["native_phase"]["suction_targets"].is_empty(),"the inhale boxes stay closed before frame nine")
		step(1)
		var targets: Dictionary = game.player["native_phase"]["suction_targets"]
		check(targets.has(target["id"]) and targets.has(dead["id"]) and targets.size()==2,
			"the inhale boxes mirror and reject targets behind or above them")
		dead["hp"] = 0.0
		step(100)
		check(target["pos"]==front-Vector2(14*facing,4) and behind["pos"]==POINT+Vector2(-80*facing,0),
			"pull keeps native two-axis speed even if Bloodlust cannot grab the target")
		step(400)
		var release_point: Vector2 = target["pos"]
		check(game.player["stage"]==1 and game.player["native_phase"]["suction_targets"]==targets,
			"the target remains registered for damage when entering the slash animation")
		step(460)
		check(target["pos"]==release_point,"the native pull ends when entering the slash animation")
		check(game.objects.size()==1 and game.objects[0]["hit"]["percent"]==1529.0 and targets.is_empty(),
			"one live ordinary target raises level-one attack to 1529 percent and releases the pull")
	start_room("original_27601","katana",1,spec,"berserker")
	game.apply_skill_effect("buff","frenzy")
	game.numeric_player.values["attack_speed"] = 1.0
	session.set_skill_material_spender(func(_id: int, _amount: int):return true)
	api.spawn_dummy(POINT+Vector2(72,0))
	for i in 8:game.spawn_enemy(POINT+Vector2(80+i*8,0))
	press(KEY_A)
	step(0)
	step(790)
	check(game.player["native_phase"]["suction_targets"].size()==9,"the score cap does not cap the number of pulled enemies")
	step(500)
	step(460)
	check(game.objects.size()==1 and game.objects[0]["hit"]["percent"]==3621.0,"eight or more normal targets use the original upper damage column")

func check_bloody_rave_cancel() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"berserker"})
	profile.command("numbers.skill_grant",{"id":"bloodyrave","level":1})
	profile.command("numbers.skill_grant",{"id":"buff","level":1})
	profile.command("numbers.skill_grant",{"id":"guard","level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["bloodyrave","guard"]
	for swing in range(1,5):
		start_room("original_27601","katana",1,spec,"berserker")
		game.apply_skill_effect("buff","frenzy")
		game.numeric_player.values["attack_speed"] = 1.0
		var payments: Array = []
		session.set_skill_material_spender(func(id: int, amount: int):
			payments.append([id,amount])
			return true)
		var target: Dictionary = api.spawn_dummy(POINT+Vector2(0,180))
		press(KEY_X)
		step(0)
		for prior in range(swing-1):
			press(KEY_X)
			step([300.0,180.0,240.0][prior])
		move_target(target,Vector2(game.player["pos"])+Vector2(60,0))
		step(119)
		var hits: int = game.hit_count
		check(game.player["action"]=="frenzy%d" % swing and game.player["clock"]==119.0,
			"Frenzy swing %d is one millisecond before its first hit" % swing)
		press(KEY_A)
		step(1)
		check(game.player["action"]=="bloodyrave" and game.player["clock"]==0.0
			and game.hit_count==hits and payments==[[3037,1]],
			"Bloody Rave cancels the native attack state before its next hit")
	start_room("original_27601","katana",1,spec,"berserker")
	game.apply_skill_effect("buff","frenzy")
	session.set_skill_material_spender(func(_id: int, _amount: int):return true)
	press(KEY_Z)
	step(0)
	press(KEY_A)
	step(119)
	check(game.player["action"]=="upper" and not game.player["cooldowns"].has("bloodyrave"),
		"the attack-state permission does not cancel a different active skill")
	start_room("original_27601","katana",1,spec,"berserker")
	game.apply_skill_effect("buff","frenzy")
	session.set_skill_material_spender(func(_id: int, _amount: int):return true)
	session.submit_key(KEY_S,true)
	step(0)
	check(game.player["state"]=="guard","the fixture enters held guard through the shortcut")
	press(KEY_A)
	step(0)
	check(game.player["state"]=="guard" and not game.player["cooldowns"].has("bloodyrave"),
		"guard is outside Bloody Rave's native cast states")
	session.submit_key(KEY_S,false)

func check_bloody_rave_thirst() -> void:
	for sample: Array in [[0,1,750,36],[0,2,750,47],[1,1,500,90],[1,1,501,36],
			[1,1,1199,36],[1,1,1200,3],[0,1,1985,36]]:
		var profile := ProfileSession.new()
		profile.command("numbers.level",{"level":60})
		profile.command("numbers.growtype",{"growtype":"berserker"})
		profile.command("numbers.skill_grant",{"id":"bloodyrave","level":1})
		profile.command("numbers.skill_grant",{"id":"buff","level":1})
		profile.command("numbers.skill_grant",{"id":"sacrifice","level":sample[1]})
		if sample[0] > 0:profile.command("numbers.skill_grant",{"id":"pinchpowerupex","level":sample[0]})
		var spec := profile.stats()
		spec["skill_slots"] = ["bloodyrave"]
		start_room("original_27601","katana",1,spec,"berserker")
		game.apply_skill_effect("buff","frenzy")
		game.apply_skill_effect("sacrifice","thirst")
		game.numeric_player.values["attack_speed"] = 1.0
		game.max_hp = 2000.0
		game.player["hp"] = float(sample[2])
		session.set_skill_material_spender(func(_id: int, _amount: int):return true)
		var front := POINT+Vector2(145,0)
		var first: Dictionary = api.spawn_dummy(front)
		if sample[1] == 2:first["z"] = 12.0
		var limit_case: bool = sample[0] == 0 and sample[1] == 1 and sample[2] == 750
		if limit_case:
			first["hp"] = 5.0
			first["def"] = first["def"].duplicate()
			first["def"]["rave_fixture"] = true
			for index in 7:
				var target: Dictionary = game.spawn_enemy(front)
				target["hp"] = 5000.0
		session.submit_key(KEY_A,true)
		step(0)
		step(500)
		check(game.bus.events_of("combat.damage_number").is_empty(),"the first Thirst timer pulse can occur before any contact")
		step(290)
		if limit_case:move_target(first,POINT-Vector2(80,0))
		step(209)
		check(game.bus.events_of("combat.damage_number").is_empty(),"Thirst waits for the next cast-clock boundary")
		step(1)
		var numbers: Array = game.bus.events_of("combat.damage_number")
		var amount := int(sample[3])
		var count := 6 if limit_case else 1
		check(numbers.size()==count and numbers.all(func(event):return event["amount"]==amount),
			"Thirst uses the sourced amount and caps each pulse at six contacts: %s" % str(sample))
		var anchor := Vector3(int(first["pos"].x),int(first["pos"].y)+1,int(first["z"])+83)
		var first_number: Dictionary = game.view.numbers[0]
		check(numbers[0]["point"]==anchor and first_number["pos"]==Vector2(anchor.x,anchor.y+Frame.MAP_DY-anchor.z),
			"Thirst uses the original 68-pixel goblin height plus 15, including airborne Z and ground depth")
		if sample[1] == 2:
			game.view.present(game.view_snapshot(),999.0,0.0)
			check(game.view.numbers.size()==1 and first_number["ms"]==999.0,"the native float remains until 1000 ms")
			game.view.present(game.view_snapshot(),1.0,0.0)
			check(game.view.numbers.is_empty(),"the native float expires at 1000 ms")
		check(game.player["hp"]==minf(2000.0,float(sample[2]+amount*count))
			and first["hp"]==(0.0 if limit_case else 5000.0-amount) and game.hit_count==0,
			"direct HP transfer grants the nominal heal, caps at max HP and does not create an attack hit")
		if limit_case:
			check(game.monsters[5]["hp"]==4964.0 and game.monsters[6]["hp"]==5000.0,
				"only six registered targets take the first pulse")
			step(1100)
			check(game.bus.events_of("combat.damage_number").size()==12,"a late update does not replay missed pulses")
			game.numeric_player.remove_effect("thirst")
			step(500)
			check(game.bus.events_of("combat.damage_number").size()==12,"removing Thirst stops further HP transfer")
		session.submit_key(KEY_A,false)
		step(500)
		var release_count: int = game.bus.events_of("combat.damage_number").size()
		step(600)
		check(game.bus.events_of("combat.damage_number").size()==release_count,"the release phase cannot pulse again")

func check_hellbenter_first_cast() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"berserker"})
	profile.command("numbers.skill_grant",{"id":"hellbenter","level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["hellbenter"]
	start_room("original_27601","katana",-1,spec,"berserker")
	game.clear_monsters()
	game.player["mp"] = 2000.0
	var requests: Array = []
	var cubes := [4]
	session.set_skill_material_spender(func(id: int, amount: int):
		requests.append([id,amount])
		if id!=3037 or cubes[0]<amount:return false
		cubes[0] -= amount
		return true)
	press(KEY_A)
	step(0.0)
	check(game.player["action"]=="" and game.player["mp"]==2000.0 and cubes[0]==4
		and not game.player["cooldowns"].has("hellbenter"),"Hellbenter rejects insufficient cubes before starting or charging MP")
	cubes[0] = 5
	game.numeric_player.values["attack_speed"] = 1.33
	game.numeric_player.weapon_attack_speed_per_mille = 80
	press(KEY_A)
	step(0.0)
	var hellbenter := func():return game.numeric_player.effects.active.get("hellbenter",{})
	check(game.view.player_actor.pose=="summon1" and hellbenter.call().is_empty()
		and requests==[[3037,5],[3037,5]] and cubes[0]==0 and game.player["mp"]==1100.0,
		"Hellbenter first cast pays once and begins with the original throw-slot-one preparation")
	step(479.0)
	check(hellbenter.call().is_empty() and game.player["stage"]==0,"mode-three preparation lasts through 479 ms")
	step(1.0)
	var effect: Dictionary = hellbenter.call()
	check(game.view.player_actor.pose=="summon2" and game.player["facing"]==-1
		and effect.get("remaining_ms",0)==100100.0 and game.player["native_phase"]["end_ms"]==640,
		"Hellbenter activates on phase one and uses the original recovery and rank duration")
	var layers := func(stem):
		return game.view.object_views.values().filter(func(fx):
			return String(fx.data["source"]).get_file().begins_with(stem))
	var canvas_origin: Vector2 = game.view._canvas(POINT,0.0)
	check(layers.call("cast").size()==2 and layers.call("cast")[0].position==canvas_origin-Vector2(0,70),
		"both original cast effects start at the native draw offset")
	var modifiers: Array = effect.get("definition",{}).get("modifiers",[])
	check(modifiers.size()==2 and is_equal_approx(modifiers[0]["value"],0.003)
		and is_equal_approx(modifiers[1]["value"],0.003),"initial speed gains use the two original rank-one columns")
	var advance := func(ms):
		game.step_numeric_actor(game.player,game.numeric_player,ms)
		step(ms)
	advance.call(99.0)
	check(cues("B_START").is_empty() and layers.call("sword").is_empty(),"the cast does not play its sound before frame one")
	advance.call(1.0)
	check(cues("B_START").size()==1 and game.view.audio.variants["B_START"][0] is AudioStreamOggVorbis,
		"Cast2 plays the original sound once at appendage age 100")
	advance.call(239.0)
	check(layers.call("sword").is_empty() and layers.call("buffmark").is_empty(),"Cast1 gates the sword and mark through 339 ms")
	advance.call(1.0)
	var entry_marks: Array = layers.call("buffmark1")
	check(layers.call("sword").size()==2 and layers.call("blade").size()==1 and entry_marks.size()==1,
		"Cast1 frame four reveals both sword layers, the blood blade and the first mark")
	check(entry_marks.size()==1 and entry_marks[0].position==canvas_origin-Vector2(0,100),
		"the original standing body frame height anchors the Hellbenter mark")
	advance.call(159.0)
	check(layers.call("cast").size()==2 and layers.call("buffmark1").size()==1,"Cast1 and BuffMark1 are still active at age 499")
	advance.call(1.0)
	check(layers.call("cast").is_empty() and layers.call("buffmark1").is_empty()
		and layers.call("buffmark2").size()==1 and layers.call("buffmark3").size()==1,
		"both Cast layers end with Cast1, and the persistent two-part mark replaces BuffMark1")
	advance.call(139.0)
	check(game.player["action"]=="hellbenter","Hellbenter recovery lasts through 639 ms")
	advance.call(1.0)
	check(game.player["action"]=="" and requests.size()==2 and not hellbenter.call().is_empty(),
		"recovery ends without a second charge and the appendage stays active")
	advance.call(60.0)
	var sword = game.view.object_views.get("hellbenter:sword_base")
	check(sword!=null and sword.position==canvas_origin+Vector2(60,-95) and sword.frame["img_frame"]==1,
		"the left-facing sword holds its last frame and reaches the bottom of its 700 ms half-cycle")
	game.player["facing"] = 1
	game.player["pos"] = POINT+Vector2(35,15)
	step(0.0)
	check(sword!=null and sword.position==canvas_origin+Vector2(-25,-80) and sword.facing==1,
		"the floating sword follows its owner and mirrors its horizontal offset")
	advance.call(99350.0)
	check(sword!=null and is_equal_approx(sword.fade,202.0/255.0) and cues("B_START").size()==1,
		"the normal sword enters the original last-band alpha pulse without replaying the cast sound")
	var mp_at_deadline: float = game.player["mp"]
	advance.call(50.0)
	check(game.player.has("hellbenter_finish") and hellbenter.call()["remaining_ms"]==0.0
		and not game.view.object_views.has("hellbenter:sword_base") and layers.call("buffmark").size()==2
		and requests.size()==2 and game.player["mp"]==mp_at_deadline,
		"the deadline starts the finisher automatically, hides the sword and preserves the mark without payment")
	game.end_action()
	check(game.numeric_player.add_effect("hellbenter",6) and hellbenter.call()["remaining_ms"]==130130.0,
		"rank six uses the extended duration from the original level table")
	var near: Dictionary = game.spawn_enemy(game.player["pos"]+Vector2(100,0))
	var far: Dictionary = game.spawn_enemy(game.player["pos"]+Vector2(140,0))
	far["pos"] = Vector2(game.player["pos"])+Vector2(641,0)
	var dry: Dictionary = game.spawn_enemy(game.player["pos"]+Vector2(-90,0))
	for enemy: Dictionary in [near,far,dry]:enemy["ai"] = false
	for enemy: Dictionary in [near,far]:enemy["numeric"].effects.add_source_bleed(0,10000,60)
	var blood = game.hellbenter_blood
	effect = hellbenter.call()
	game.step_game(0.0)
	game.view.present(game.view_snapshot(),0.0,0.0)
	check(blood.marks.size()==2 and not blood.marks.has(dry["id"]) and layers.call("targetmark1").size()==2,
		"Hellbenter immediately marks bleeding hostiles, including those outside the pulse radius")
	game.step_game(499.0)
	check(blood.orbs.is_empty(),"Hellbenter marks wait through 499 ms")
	game.step_game(1.0)
	game.view.present(game.view_snapshot(),0.0,0.0)
	check(blood.orbs.size()==1 and layers.call("ballhead").size()==1 and layers.call("targetmark2").size()==2,
		"the 500 ms pulse creates one original blood orb from the nearby bleeding target")
	if blood.orbs.is_empty():return
	var orb: Dictionary = blood.orbs[0]
	var origin: Vector3i = orb["origin"]
	var bend: Vector2i = orb["bend"]
	game.step_game(150.0)
	game.view.present(game.view_snapshot(),0.0,0.0)
	check(orb["point"].x==bend.x and bend.x-origin.x>=150 and bend.x-origin.x<=249
		and layers.call("balltail").size()>0,"the blood orb swings outward for 150 ms and draws the original tail")
	game.step_game(250.0)
	check(orb["point"].y==bend.y,"the separate depth curve turns at 400 ms")
	near["numeric"].effects.remove("bleed")
	game.step_game(199.0)
	check(effect.get("blood_count",0)==0 and is_equal_approx(effect["definition"]["modifiers"][0]["value"],0.020)
		and not blood.marks.has(near["id"]),"losing bleed removes the mark while the orb continues flying")
	game.step_game(1.0)
	game.view.present(game.view_snapshot(),0.0,0.0)
	check(effect.get("blood_count",0)==1 and blood.orbs.is_empty()
		and is_equal_approx(effect["definition"]["modifiers"][0]["value"],0.022)
		and is_equal_approx(effect["definition"]["modifiers"][1]["value"],0.022),
		"at 600 ms the orb adds exactly one charge and recalculates both speed bonuses")
	check(layers.call("blade").size()==2 and layers.call("absorb").size()==1,
		"the first charge extends the original blade and starts the absorption flash")
	game.step_game(500.0)
	check(blood.orbs.is_empty() and effect.get("blood_count",0)==1,
		"neither the distant target nor the cured target can add another charge")
	# Position the fixture one orb from full to exercise the transition via
	# the live pulse and travel paths, including another orb arriving at cap.
	effect["blood_count"] = 79
	near["numeric"].effects.add_source_bleed(0,10000,60)
	game.step_game(250.0)
	game.step_game(500.0)
	game.step_game(599.0)
	game.view.present(game.view_snapshot(),0.0,0.0)
	check(effect["blood_count"]==79 and cues("W_SPIRITS_FLASH").is_empty()
		and layers.call("completesword").is_empty() and layers.call("blade").size()==5,
		"the ordinary five-layer sword persists until the last charge arrives")
	game.step_game(1.0)
	game.view.present(game.view_snapshot(),0.0,0.0)
	var complete_base = game.view.object_views.get("hellbenter:complete_base")
	var complete_entry = game.view.object_views.get("hellbenter:complete_entry")
	check(effect["blood_count"]==80 and is_equal_approx(effect["definition"]["modifiers"][0]["value"],0.191)
		and is_equal_approx(effect["definition"]["modifiers"][1]["value"],0.191),
		"the final orb reaches the source charge cap and both exact speed endpoints")
	check(layers.call("blade").is_empty() and complete_base!=null and complete_entry!=null
		and complete_base.frame["img_frame"]==2 and complete_entry.frame["img_frame"]==4
		and layers.call("completeflash").size()==2
		and game.view.audio.variants["W_SPIRITS_FLASH"][0] is AudioStreamOggVorbis
		and cues("W_SPIRITS_FLASH").size()==1,"full charge switches both sword layers, starts both flashes and sounds once")
	game.step_game(299.0)
	game.view.present(game.view_snapshot(),0.0,0.0)
	check(layers.call("completeflash").size()==2 and layers.call("completesword3").is_empty(),
		"both full-charge flashes are still drawn at 299 ms")
	game.step_game(100.0)
	game.view.present(game.view_snapshot(),0.0,0.0)
	check(layers.call("completeflash").is_empty() and layers.call("completesword3").is_empty()
		and complete_entry!=null and complete_entry.frame["img_frame"]==7,
		"the flashes are gone at 399 ms and the glow is still on the fourth entry frame")
	game.step_game(1.0)
	game.view.present(game.view_snapshot(),0.0,0.0)
	var complete_glow = game.view.object_views.get("hellbenter:complete_glow")
	check(complete_glow!=null and complete_glow.clock_ms==0.0
		and complete_entry!=null and complete_entry.frame["img_frame"]==8,
		"the independent sword glow starts at zero when the entry animation reaches frame five")
	game.step_game(1200.0)
	game.view.present(game.view_snapshot(),0.0,0.0)
	check(effect["blood_count"]==80 and cues("W_SPIRITS_FLASH").size()==1
		and complete_entry!=null and complete_entry.frame["img_frame"]==8 and is_instance_valid(complete_glow)
		and complete_glow.loop,"the glow keeps looping at the cap without replaying sound or the entry")
	effect["remaining_ms"] = 1.0
	game.player["state"] = "air"
	game.player["z"] = 50.0
	game.step_game(1.0)
	game.step_game(17.0)
	game.view.present(game.view_snapshot(),0.0,0.0)
	check(not game.player.has("hellbenter_finish") and effect["remaining_ms"]==-17.0
		and layers.call("completesword").size()==3 and is_equal_approx(complete_base.fade,150.0/255.0),
		"the timer continues while airborne, keeping the charged sword with minimum alpha")
	game.player["state"] = "idle"
	game.player["z"] = 0.0
	game.player["vz"] = 0.0
	step(0.0)
	game.view.present(game.view_snapshot(),0.0,0.0)
	check(game.player.has("hellbenter_finish") and not hellbenter.call().is_empty()
		and game.player["hellbenter_finish"]["blood_count"]==80 and layers.call("completesword").is_empty(),
		"the first eligible poll starts the fully charged finisher and clears the held sword layers")

func check_hellbenter_manual_finish() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"berserker"})
	profile.command("numbers.skill_grant",{"id":"hellbenter","level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["hellbenter"]
	start_room("original_27601","katana",1,spec,"berserker")
	game.clear_monsters()
	var fees := [0]
	session.set_skill_material_spender(func(id: int, count: int):
		fees[0] += count
		return id==3037 and fees[0]==5)
	game.player["mp"] = 2000.0
	game.numeric_player.values["attack_speed"] = 1.0
	game.numeric_player.weapon_attack_speed_per_mille = 0
	press(KEY_A)
	step(600.0)
	step(800.0)
	var effect: Dictionary = game.active_effect("hellbenter")
	check(not effect.is_empty() and game.player["action"]=="","the first shortcut cast leaves the original sword equipped")
	if effect.is_empty():return
	effect["remaining_ms"] -= 800.0
	effect["blood_count"] = 40
	var cooldown := float(game.player["cooldowns"]["hellbenter"])
	game.player["mp"] = 0.0
	game.numeric_player.values["attack_speed"] = 1.33
	game.numeric_player.weapon_attack_speed_per_mille = 80
	game.numeric_player.values["hit"] = 1.0
	var target: Dictionary = api.spawn_dummy(POINT+Vector2(140,0))
	var outside: Dictionary = game.spawn_enemy(POINT+Vector2(-140,0))
	outside["ai"] = false
	var before := int(game.hit_count)
	game.bus.clear_history()
	press(KEY_A)
	step(0.0)
	check(game.player["mp"]==0.0 and fees[0]==5 and cooldown>0.0 and game.player["cooldowns"]["hellbenter"]==cooldown
		and game.view.player_actor.pose=="hellbenterfinish",
		"the second shortcut use enters state 46 without MP, materials or a fresh cooldown")
	if not game.player.has("hellbenter_finish"):return
	var stage: Dictionary = game.action_def()
	var swing: Dictionary = stage["hits"][0]
	var phase: Dictionary = game.player["native_phase"]
	var base: int = game.native_fixed_attack_base(game.move_def("hellbenter")["fixed_attack_base"])
	var expected := int((int(base*2.05)+int(base*6.19))*0.5)
	check(phase["impact_ms"]==285.0 and swing["fixed_amount"]==expected
		and swing["percent"]==0.0 and swing["source"]=="body",
		"the finisher uses mode three and the integer midpoint of the two fixed attack results")
	var attachments: Array = game.view.effects.filter(func(fx):return fx.data["source"].get_file() in ["finish1.ani","finish2.ani","finish3.ani"])
	check(attachments.size()==3 and cues("CCRASH_MOVING").size()==1 and cues("SM_MUSSANG_START").size()==1
		and not game.view.object_views.has("hellbenter:sword_base"),
		"the finisher hides the carried sword and attaches three original layers with both startup cues")
	step(284.0)
	check(game.hit_count==before and cues("DRAWING_SWORD").is_empty() and game.objects.is_empty(),
		"the mode-three first three frames do not strike or create the column")
	step(1.0)
	check(game.player_ani()[1]==360.0 and game.hit_count==before+1 and target["hp"]<target["max_hp"]
		and outside["hp"]==outside["max_hp"] and game.last_damage["trace"]["fixed_part"]==expected,
		"the swing first connects on frame three using the original body geometry and fixed attack")
	check(attachments.all(func(fx):return fx.clock_ms==360.0) and cues("DRAWING_SWORD").size()==1
		and cues("SM_BLOOD_RAVE_ATK").size()==1 and game.view.player_actor.equipment_layers.size()==2
		and game.view.player_actor.equipment_layers.all(func(layer):
			return int(layer.frame.get("frame",-1))==3 and layer.frame.get("img")==null),
		"the effects and sounds align with the hit frame while both original equipment tracks stay blank")
	check(game.objects.size()==1 and game.objects[0].has("column") and game.objects[0]["pos"]==POINT+Vector2(320,0)
		and is_equal_approx(game.objects[0]["size_rate"],0.87) and game.objects[0]["clock"]==0.0
		and cues("B_FIRE_EXPLOSION_READY").size()==1,
		"the fourth frame creates the column at the original SD offset, age zero and the half-charge scale")
	step(120.0)
	check(game.player_ani()[1]==480.0 and game.hit_count==before+1,"recovery uses base speed and keeps the same hit ledger")
	press(KEY_A)
	step(2559.0)
	check(game.player["action"]=="hellbenter" and not game.active_effect("hellbenter").is_empty(),
		"repeated input cannot restart the finisher and the appendage remains until state exit")
	step(1.0)
	check(game.player["action"]=="hellbenter" and not game.active_effect("hellbenter").is_empty()
		and game.player_ani()[1]==3040.0,"the finished body animation waits on the linked column")
	if game.objects.size()==1 and game.objects[0].has("column"):
		check_hellbenter_column(game.objects[0],target,outside,base)
	check(game.numeric_player.add_effect("hellbenter",1),"a fresh sword can be installed after leaving the finisher")
	press(KEY_A)
	step(100.0)
	game.hurt_player(1,outside,{"ignore_super_armor":1},1)
	step(0.0)
	check(not game.player.has("hellbenter_finish") and game.active_effect("hellbenter").is_empty()
		and game.view.effects.all(func(fx):return fx.data["source"].get_file() not in ["finish1.ani","finish2.ani","finish3.ani"]),
		"being interrupted before the swing consumes the sword and clears the attached finish effects")

func check_hellbenter_column(object: Dictionary, target: Dictionary, outside: Dictionary, base: int) -> void:
	move_target(target,object["pos"])
	target["hp"] = 500000.0
	target["max_hp"] = target["hp"]
	game.numeric_player.values["hit"] = 1.0
	var start := int(game.hit_count)
	var normal_amount := int((int(base*1.55)+int(base*4.63))*0.5)
	var final_amount := int((int(base*7.75)+int(base*23.24))*0.5)
	var column: Dictionary = object["column"]
	var loop_path := "passiveobject/character/swordman/particle/hellbenterloop.ptl"
	var loop_particles := func():return game.view.effects.filter(func(fx):return fx.get_meta("source_ptl","")==loop_path)
	var particle_path := "passiveobject/character/swordman/particle/hellbenterdisappear.ptl"
	var embers := func():return game.view.effects.filter(func(fx):return fx.get_meta("source_ptl","")==particle_path)
	check(column["hit_interval"]==155 and object["hit"]["fixed_amount"]==normal_amount
		and column["final"]["fixed_amount"]==final_amount,
		"object 20052 uses the 155 ms reset and its own normal and final damage endpoints")
	game.step_objects(1679.0)
	game.view.present(game.view_snapshot(),0.0,0.0)
	var layers := func(stem: String):return game.view.object_views.values().filter(func(fx):
		return String(fx.data["source"]).get_file().begins_with(stem))
	check(layers.call("appear").size()==5 and game.hit_count==start and cues("B_FIRE_EXPLOSION").is_empty()
		and loop_particles.call().is_empty(),
		"five original appearance tracks play without attacking through 1679 ms")
	game.step_objects(1.0)
	check(game.hit_count==start+1 and game.last_damage["trace"]["fixed_part"]==normal_amount
		and cues("B_FIRE_EXPLOSION").size()==1,"Appear5 starts the first contact exactly at 1680 ms")
	game.step_objects(100.0)
	game.view.present(game.view_snapshot(),0.0,0.0)
	check(column["phase"]==1 and layers.call("loop").size()==3 and cues("B_FIRE_COLUMN_LOOP").size()==1
		and game.hit_count==start+1 and loop_particles.call().is_empty(),
		"loop entry resets the emitter without sampling or refreshing contact")
	game.step_objects(33.0)
	var first_loop: Array = loop_particles.call()
	check(first_loop.size()==1,"the first loop update emits the reset particle without a second particle before 34 ms")
	if first_loop.size()==1:
		var normal = first_loop[0]
		var overlay = normal.get_child(0)
		check(normal.data["source"].ends_with("loopparticle1.ani") and overlay.data["source"].ends_with("loopparticle2.ani")
			and normal.frame["img_frame"]==overlay.frame["img_frame"] and int(overlay.frame["items"]["11"]["type"])==2
			and is_equal_approx(normal.base_scale,object["size_rate"]) and is_equal_approx(overlay.base_scale,object["size_rate"]),
			"the two original particle layers share one sprite index, position, and column scale")
	game.step_objects(1.0)
	check(loop_particles.call().size()==2,"the 30 Hz column emitter produces its next particle at 34 ms")
	var emissions: Array = game.bus.events_of("combat.cue").filter(func(event):return event.get("path","")==loop_path)
	check(emissions.size()==2 and emissions[-1]["point"]==object["pos"]+Vector2(0,1)
		and emissions[-1]["height"]==10.0 and emissions[-1]["elapsed_ms"]==34,
		"the looping emitter samples the passive object's clock at Y+1 and Z+10")
	game.step_objects(20.0)
	check(game.hit_count==start+1,"the ledger is still closed at 1834 ms")
	game.step_objects(1.0)
	check(game.hit_count==start+2,"the normal ledger first refreshes at 1835 ms")
	for i in 18:game.step_objects(155.0)
	check(game.hit_count==start+20 and outside["hp"]==outside["max_hp"],"the original twenty contacts stay inside the column")
	var fire_cues := cues("ASTORM_HIT_FIRE").size()
	game.step_objects(154.0)
	check(column["phase"]==1 and game.hit_count==start+20 and cues("ASTORM_HIT_FIRE").size()==fire_cues,
		"the final explosion waits for the whole loop duration")
	check(embers.call().is_empty(),"the final embers wait for the last phase")
	game.step_objects(1.0)
	game.view.present(game.view_snapshot(),0.0,0.0)
	var last_loop: Array = loop_particles.call()
	check(column["phase"]==2 and layers.call("disappear").size()==2 and game.hit_count==start+21
		and game.last_damage["trace"]["fixed_part"]==final_amount and cues("ASTORM_HIT_FIRE").size()>fire_cues,
		"the final explosion has independent damage, two original layers and its own sound")
	var bursts: Array = game.bus.events_of("combat.cue").filter(func(event):return event.get("path","")==particle_path)
	var ember_visuals: Array = embers.call()
	check(bursts.size()==1 and bursts[0]["point"]==object["pos"]+Vector2(0,1)
		and bursts[0]["height"]==200.0 and ember_visuals.size()==12
		and ember_visuals.all(func(fx):
			return (is_equal_approx(fx.base_scale,object["size_rate"])
				and String(fx.data["source"]).get_file().begins_with("disappearparticle"))),
		"the final frame emits all twelve original ember animations once from Y+1 and Z+200 at column scale")
	game.step_objects(199.0)
	step(0.0)
	check(not last_loop.is_empty() and loop_particles.call()==last_loop
		and not game.view._object_particle_emitters.has(object["id"]),
		"the terminal update stops the emitter while the spawned loop particles keep their lifetime")
	check(game.player["action"]=="hellbenter" and not game.active_effect("hellbenter").is_empty(),
		"the owner waits through the first 199 ms of the column's final animation")
	game.step_objects(1.0)
	step(0.0)
	check(game.player["action"]=="" and game.active_effect("hellbenter").is_empty()
		and game.objects.has(object) and cues("SM_MUSSANG_START").size()==1,
		"the owner returns to idle at 200 ms, removing the appendage while the column remains")
	game.step_objects(199.0)
	check(game.objects.has(object) and game.hit_count==start+21,"the final contact does not repeat during the tail")
	game.step_objects(1.0)
	check(not game.objects.has(object) and embers.call().size()==12,
		"the source Disappear2 lifetime removes the object at 400 ms, leaving the independent embers")

func check_outrage_break_impact() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"berserker"})
	profile.command("numbers.skill_grant",{"id":"outragebreak","level":1})
	profile.command("numbers.skill_grant",{"id":"buff","level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["outragebreak"]
	for sample: Array in [[false,1000.0,true],[true,400.99,true],[true,401.0,false],[true,401.0,true],[true,1000.0,true]]:
		var rate := 2.0 if sample[1] == 1000.0 and sample[0] else 1.0
		var facing := -1 if rate == 2.0 else 1
		start_room("original_27601","katana",facing,spec,"berserker")
		if sample[0]:game.apply_skill_effect("buff","frenzy")
		game.numeric_player.values["attack_speed"] = rate
		game.numeric_player.values["hit"] = 1.0
		game.numeric_player.values["independent_attack"] = Numbers.shared_config()["base"]["independent_attack"]
		game.player["hp"] = sample[1]
		var before_mp: float = game.player["mp"]
		var payments: Array = []
		session.set_skill_material_spender(func(id: int, amount: int):
			payments.append([id,amount])
			return sample[2])
		var target: Dictionary = api.spawn_dummy(POINT+Vector2(180*facing,0))
		target["hp"] = 50000.0
		press(KEY_A)
		step(0)
		if not sample[0] or sample[1] < 401.0 or not sample[2]:
			check(game.player["action"]=="" and game.player["hp"]==sample[1] and game.player["mp"]==before_mp
				and not game.player["cooldowns"].has("outragebreak"),"Outrage Break rejects without mutating the cast ledger")
			check(payments==([[3037,2]] if not sample[2] else []),"only a legal HP and Frenzy state can request both cubes")
			continue
		check(game.view.player_actor.pose=="outragebreakready" and game.player["hp"]==sample[1]-400.0
			and game.player["mp"]==before_mp and payments==[[3037,2]] and cues("OUTRAGE_READY").size()==1,
			"Outrage Break enters the original ready pose and pays its rank cost once")
		var ready_ms := 279.0 if rate == 2.0 else 560.0
		var landing_ms := 299.0 if rate == 2.0 else 600.0
		var apex_ms := 149.0 if rate == 2.0 else 300.0
		step(ready_ms-1.0)
		check(game.player["stage"]==0 and game.player["pos"]==POINT and game.player["z"]==0.0
			and target["hp"]==50000.0 and game.objects.is_empty(),"the ready frame cannot move or damage")
		step(1)
		check(game.player["stage"]==1 and game.view.player_actor.pose=="outragebreakslash" and game.player["clock"]==0.0,
			"the original ready ANI advances automatically on completion")
		step(apex_ms)
		check(game.player["z"]==150.0 and game.player["pos"]==POINT+Vector2((64 if rate == 2.0 else 65)*facing,0)
			and target["hp"]==50000.0,
			"the leap peaks at the middle of the speed-scaled travel interval")
		if rate == 2.0:
			step(294.0-apex_ms)
			check(game.hit_count==0 and game.objects.is_empty(),"the doubled-speed body frame is still closed at 294 ms")
			step(1.0)
			check(game.hit_count==1 and game.objects.is_empty() and cues("OUTRAGE_SWING").is_empty(),
				"the body hits at 295 ms while the landing effect and floor object still wait")
			step(landing_ms-296.0)
		else:
			step(landing_ms-apex_ms-1.0)
			check(target["hp"]==50000.0,"the normal-speed body and landing gates coincide")
		check(game.objects.is_empty() and game.player["pos"]==POINT+Vector2(129*facing,0),
			"the final pre-impact sample uses the native integer displacement")
		step(1)
		check(game.player["z"]==0.0 and target["hp"]<50000.0 and game.hit_count==1 and not target["numeric"].effects.active.has("bleed"),
			"the original body ATK hits once without a synthetic bleed")
		check(game.objects.size()==1 and game.objects[0]["pos"]==POINT+Vector2(279*facing,0)
			and game.objects[0]["hit"]["fixed_amount"]==5846.0 and game.objects[0]["clock"]==0.0
			and cues("OUTRAGE_SWING").size()==1 and cues("CCRASH_CRASH").size()==1,
			"the floor object and two original sounds start at impact with the rank-one fixed attack")
		step(180.0/rate)
		check(game.hit_count==1 and payments==[[3037,2]],"the contiguous slash frames share one hit and one cast payment")
		if game.objects.size()==1:
			var floor_target: Dictionary = game.spawn_enemy(POINT+Vector2(279*facing,45))
			floor_target["hp"] = 50000.0
			game.step_objects(16.0,int(game.objects[0]["id"]))
			check(floor_target["hp"]<50000.0 and game.objects[0]["clock"]==0.0 and not cues("FLAMES_HIT").is_empty(),
				"the original floor ATK lands independently on its first frame")

func check_outrage_break_speed_refresh() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"berserker"})
	for skill: String in ["outragebreak","buff"]:
		profile.command("numbers.skill_grant",{"id":skill,"level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["outragebreak"]
	for phase: String in ["ready","leap","landed"]:
		start_room("original_27601","katana",1,spec,"berserker")
		game.clear_monsters()
		game.apply_skill_effect("buff","frenzy")
		game.numeric_player.values["attack_speed"] = 2.0 if phase == "landed" else 1.0
		game.numeric_player.values["hit"] = 1.0
		game.player["hp"] = 1000.0
		session.set_skill_material_spender(func(_id: int,_amount: int):return true)
		if phase == "landed":step(21.5)
		press(KEY_A)
		step(0.0)
		if phase == "ready":
			step(298.0)
			game.numeric_player.values["attack_speed"] = 2.0
			step(1.0)
			check(game.player["clock"]==299.0 and game.action_duration("outragebreak")==560.0,
				"changing attack speed does not shorten the ready frame before the actor refresh")
			step(1.0)
			check(game.player["clock"]==149.0 and game.action_duration("outragebreak")==279.0,
				"the ready ANI rescales its elapsed time and its frame length at 300 ms")
			step(129.0)
			check(game.player["stage"]==0 and game.objects.is_empty(),"the shortened ready motion still waits for its last millisecond")
			step(1.0)
			check(game.player["stage"]==1 and game.player["clock"]==0.0,"the shortened ready motion advances once")
		elif phase == "leap":
			step(560.0)
			step(298.0)
			game.numeric_player.values["attack_speed"] = 2.0
			step(1.0)
			check(game.player["clock"]==299.0 and game.player["native_phase"]["outrage_impact_ms"]==600,
				"the airborne phase keeps its old landing threshold until the actor refresh")
			step(1.0)
			check(game.player["clock"]==149.0 and game.player["native_phase"]["outrage_impact_ms"]==299
				and game.player["z"]==150.0 and game.player["pos"]==POINT+Vector2(64,0),
				"the airborne refresh rescales time and samples movement from the same original launch point")
			var target: Dictionary = api.spawn_dummy(POINT+Vector2(180,0))
			target["hp"] = 50000.0
			step(145.0)
			check(game.hit_count==0 and game.objects.is_empty(),"the refreshed frame five still waits at 294 ms")
			step(1.0)
			check(game.hit_count==1 and game.objects.is_empty(),"the refreshed body frame hits four milliseconds before landing")
			step(4.0)
			check(game.hit_count==1 and game.objects.size()==1 and game.player["z"]==0.0
				and cues("OUTRAGE_SWING").size()==1,"the refreshed leap lands once and creates exactly one floor object")
		else:
			step(278.5)
			step(0.5)
			step(298.0)
			step(1.0)
			var landed: Vector2 = game.player["pos"]
			var stone := String(game.move_def("outragebreak")["stone_particle"])
			game.numeric_player.values["attack_speed"] = 1.0
			step(0.5)
			check(game.player["clock"]==598.0 and game.player["native_phase"]["outrage_impact_ms"]==599,
				"single-precision rounding can remap the clock to before the new landing threshold")
			check(game.player["pos"]==landed and game.player["z"]==0.0 and game.objects.size()==1
				and cues("OUTRAGE_SWING").size()==1 and native_particle_cues(stone).size()==1,
				"a post-landing speed change keeps the landing latch and samples the stone emitter once")

func check_outrage_break_eruption() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"berserker"})
	for skill: String in ["outragebreak","buff","sacrifice"]:
		profile.command("numbers.skill_grant",{"id":skill,"level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["outragebreak"]
	start_room("original_27601","katana",-1,spec,"berserker")
	session.set_skill_material_spender(func(id: int,amount: int):return id==3037 and amount==2)
	game.apply_skill_effect("buff","frenzy")
	game.apply_skill_effect("sacrifice","thirst")
	game.numeric_player.values["attack_speed"] = 1.0
	game.numeric_player.values["hit"] = 1.0
	game.numeric_player.values["independent_attack"] = Numbers.shared_config()["base"]["independent_attack"]
	game.player["hp"] = 1000.0
	for enemy: Dictionary in game.monsters:move_target(enemy,POINT+Vector2(900,0))
	press(KEY_A)
	step(0)
	step(560)
	step(600)
	check(game.objects.size()==1,"impact creates the floor only")
	if game.objects.size()!=1:return
	var floor: Dictionary = game.objects[0]
	var point: Vector2 = floor["pos"]
	var controller: Dictionary = floor["hit"]["native_controller"]
	var layers: Array = controller["layers"]
	var light := String(controller["light_particle"])
	var drops := String(controller["drops_particle"])
	var stone := String(game.move_def("outragebreak")["stone_particle"])
	check(game.view.object_views.has("%s:floor:0"%floor["id"])
		and game.view.object_views.has("%s:floor:1"%floor["id"]) and cues(layers[2]).size()==1,
		"the floor renders both synchronized ETC motions and a separate impact clip")
	var stone_layer: Array = game.view.effects.filter(func(fx):return String(fx.cue_key).contains("sword_slash_stone"))
	check(stone_layer.size()==1 and stone_layer[0].follow_offset==Vector2(-121,10) and native_particle_cues(stone).is_empty(),
		"the mirrored slot-six composite renders at impact before the stone emitter is sampled")
	step(1)
	var stone_cues := native_particle_cues(stone)
	check(stone_cues.size()==1 and stone_cues[0]["point"]==point and stone_cues[0]["mirrored"]
		and game.view._particle_emitters.size()==1,
		"first post-impact update starts the actor stone emitter at the original anchor")
	if game.view._particle_emitters.is_empty():return
	game.player["pos"] += Vector2(4,0)
	game.step_player(30,Vector2.ZERO)
	game.view.present(game.view_snapshot(),30.0,30.0)
	var emitter: Dictionary = game.view._particle_emitters[0]
	check(emitter.emitter.origin==Vector3i(int(point.x)+4,int(point.y),0) and emitter.elapsed_ms==30.0,
		"stone sampling follows the caster and advances on the unscaled actor clock")
	step(1349)
	check(game.view._particle_emitters.is_empty() and game.view.effects.any(func(fx):return fx.get_meta("source_ptl","")==stone),
		"recovery stops stone emission while already released particles survive")
	var target: Dictionary = game.spawn_enemy(point+Vector2(0,45))
	game.numeric_player.remove_effect("thirst")
	game.apply_effect({"kind":"effect","id":"bleed","target":target["id"]})
	target["hp"] = 100000.0
	game.step_objects(0)
	check(game.last_damage["trace"]["fixed_part"]==6138.0,
		"the shockwave uses packed Thirst column 5 when the target is bleeding at contact")
	move_target(target,point+Vector2(0,45),110.0)
	game.step_objects(1039)
	check(game.objects.size()==1 and cues("OUTRAGE_CRASH").is_empty() and native_particle_cues(light).is_empty(),
		"the ground-blood clip still holds frame three at 1039 ms")
	game.step_objects(1)
	check(game.objects.size()==2 and cues("OUTRAGE_CRASH").size()==1,
		"ground-blood frame four creates one magma and plays the original eruption sound")
	if game.objects.size()!=2:return
	var magma: Dictionary = game.objects[1]
	var light_cues := native_particle_cues(light)
	check(light_cues.size()==1 and light_cues[0]["point"]==point and light_cues[0]["mirrored"]
		and native_particle_cues(drops).is_empty(),"eruption starts only the original rising sparks")
	var hit: Dictionary = magma["hit"]
	var glow: String = hit["native_controller"]["layers"][4]
	check(magma["pos"]==point and magma["clock"]==0.0 and hit["fixed_amount"]==4094.0
		and hit["fixed_amount_bleeding"]==4299 and hit["native_controller"]["reset_ms"]==126,
		"magma inherits the floor origin and has its own packed amount and attack clock")
	var before: int = game.hit_count
	game.step_objects(0)
	check(game.hit_count==before+1 and game.last_damage["trace"]["fixed_part"]==4299.0,
		"the invisible attack ANI hits the bleeding target at its own frame zero")
	check(cues(glow).size()==1 and cues(glow)[0]["point"]==point+Vector2(22,-12),
		"magma glow starts at the first absolute point even for a left-facing caster")
	game.step_objects(49)
	check(cues(glow).size()==1 and game.hit_count==before+1,"neither timer is due at 49 ms")
	game.step_objects(1)
	check(cues(glow).size()==2 and cues(glow)[1]["point"]==point+Vector2(-117,15)
		and game.hit_count==before+1,"the 50 ms art repeat leaves the hit ledger intact")
	game.step_objects(75)
	check(game.hit_count==before+1,"magma cannot hit a second time at 125 ms")
	target["numeric"].remove_effect("bleed")
	game.step_objects(1)
	check(game.hit_count==before+2 and game.last_damage["trace"]["fixed_part"]==4094.0,
		"126 ms clears the hit ledger and uses the ordinary amount once bleeding ends")
	for index in range(2,6):
		move_target(target,point+Vector2(0,45),110.0)
		game.step_objects(126)
		check(game.hit_count==before+index+1,"magma registers original hit interval "+str(index))
	game.step_objects(129)
	check(game.objects.has(magma) and game.hit_count==before+6,"the last interval has no seventh hit")
	game.step_objects(1)
	check(not game.objects.has(magma) and game.objects.has(floor) and cues("OUTRAGE_CRASH").size()==1,
		"the 760 ms damage object retires separately from its parent")
	game.step_objects(1499)
	check(game.objects.has(floor) and native_particle_cues(drops).is_empty(),
		"the end-of-floor emitter stays dormant at 3299 ms")
	game.step_objects(1)
	var drop_cues := native_particle_cues(drops)
	check(not game.objects.has(floor) and drop_cues.size()==1 and drop_cues[0]["point"]==point,
		"at 3300 ms the visible ground retires and starts the original ember emitter")
	game.view.present(game.view_snapshot(),0.0,0.0)
	game.view.present(game.view_snapshot(),499.0,499.0)
	check(game.view._particle_emitters.is_empty() and game.view.effects.any(func(fx):return fx.get_meta("source_ptl","")==drops),
		"embers use their own 499 ms emission window and live beyond it")

	start_room("original_27601","katana",1,spec,"berserker")
	session.set_skill_material_spender(func(id: int,amount: int):return id==3037 and amount==2)
	game.apply_skill_effect("buff","frenzy")
	game.numeric_player.values["attack_speed"] = 1.3
	game.player["hp"] = 1000.0
	press(KEY_A)
	step(0)
	step(430)
	step(460)
	check(game.objects.is_empty() and native_particle_cues(stone).is_empty(),
		"fractional attack speed cannot start the emitter one millisecond before landing")
	step(1)
	check(game.objects.size()==1 and native_particle_cues(stone).is_empty(),
		"the actual impact update arms the stone emitter without sampling it")
	step(1)
	check(native_particle_cues(stone).size()==1,
		"fractional attack speed still samples stones on the update after impact")

func native_particle_cues(path: String) -> Array:
	return game.bus.events_of("combat.cue").filter(func(event):return event.get("path","")==path)

func check_outrage_break_armor() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"berserker"})
	profile.command("numbers.skill_grant",{"id":"outragebreak","level":2})
	profile.command("numbers.skill_grant",{"id":"buff","level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["outragebreak"]
	var normal_atk: Dictionary = game.table.atk("character/swordman/attackinfo/attack1.atk")
	var piercing_atk := normal_atk.duplicate()
	piercing_atk["ignore_super_armor"] = 1
	for sample: Array in [[0,559.0,1.0,false,false],[1,239.0,1.0,false,false],
			[1,240.0,1.0,false,true],[1,779.0,1.0,false,true],[1,780.0,1.0,false,false],
			[1,189.0,1.25,false,false],[1,190.0,1.25,false,true],[1,241.0,1.0,true,false]]:
		start_room("original_27601","katana",1,spec,"berserker")
		game.apply_skill_effect("buff","frenzy")
		game.numeric_player.values["attack_speed"] = sample[2]
		game.player["hp"] = 1000.0
		var payments: Array = []
		session.set_skill_material_spender(func(id: int,amount: int):
			payments.append([id,amount])
			return true)
		for enemy: Dictionary in game.monsters:move_target(enemy,POINT+Vector2(900,0))
		press(KEY_A)
		step(0)
		if sample[0] == 1:step(447.0 if sample[2] == 1.25 else 560.0)
		step(sample[1])
		var atk: Dictionary = piercing_atk if sample[3] else normal_atk
		var hit_reaction: String = game.hurt_player(7,{"pos":game.player["pos"]+Vector2(50,0)},atk,-1)
		var armored: bool = sample[4]
		check(game.player["hp"]==563.0 and payments==[[3037,2]] and game.player["cooldowns"].has("outragebreak"),
			"rank two keeps its 430 HP and cube payment across incoming damage")
		check((game.player["action"]=="outragebreak" and hit_reaction=="none") if armored else game.player["action"]=="",
			"native leap ANI armor respects frame and attack bypass at "+str(sample))
		check(cues("upper_armor_light").size()==int(armored),
			"only an absorbed reaction emits the native body armor feedback")
		if sample[0] == 0:
			step(700)
			check(game.objects.is_empty() and cues("OUTRAGE_SWING").is_empty(),
				"interrupting the unarmored ready frame keeps payment and prevents impact")

func check_outrage_break_camera() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"berserker"})
	for skill: String in ["outragebreak","buff"]:
		profile.command("numbers.skill_grant",{"id":skill,"level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["outragebreak"]
	start_room("original_27601","katana",1,spec,"berserker")
	session.set_skill_material_spender(func(id: int,amount: int):return id==3037 and amount==2)
	game.apply_skill_effect("buff","frenzy")
	game.numeric_player.values["attack_speed"] = 1.0
	game.player["hp"] = 1000.0
	var previous_clock: Callable = game.view.particle_bursts.clock
	game.view.particle_bursts.clock = func():return 0
	game.view.particle_bursts.random.state = 0
	game.view.particle_bursts.random.draws = 0
	for enemy: Dictionary in game.monsters:move_target(enemy,POINT+Vector2(900,0))
	press(KEY_A)
	step(0)
	step(560)
	step(599)
	var impact_pos: Vector2 = game.player["pos"]
	check(game.view._shake_offset==Vector2.ZERO and game.view.particle_bursts.random.draws==0,
		"the jump leaves camera and cosmetic random untouched until impact")
	step(1)
	var base := Vector2(-roundf(game.view.camera_x),0)
	var snapshot: Dictionary = game.view_snapshot()
	check(game.view.world.position==base+Vector2(-5,5) and game.view.hud.state["camera"]==-game.view.world.position
		and game.player["pos"]==impact_pos,"impact shifts only presentation using the original first two draws")
	game.view.present(snapshot,1000.0,0.0)
	check(game.view.world.position==base+Vector2(-5,5) and game.view.particle_bursts.random.draws==2,
		"camera freeze keeps its current sample during an inactive battle tick")
	for sample: Array in [[16.0,Vector2(-2,-1),4],[283.0,Vector2(1,-1),6],[1.0,Vector2.ZERO,8],[1.0,Vector2.ZERO,8]]:
		game.view.present(snapshot,sample[0],sample[0])
		check(game.view.world.position==base+sample[1] and game.view.particle_bursts.random.draws==sample[2],
			"landing shake follows the original replay through its deadline")
	game.step_objects(1039)
	check(game.view._shake_remaining_ms<=0.0,"camera stays settled before the eruption")
	game.step_objects(1)
	game.view.present(game.view_snapshot(),1.0,1.0)
	check(game.view._shake_remaining_ms==500.0 and game.view._shake_degree==5,
		"the eruption starts a fresh 500 ms shake on its spawn update")
	game.view.present(game.view_snapshot(),499.0,499.0)
	check(game.view._shake_remaining_ms==1.0,"the eruption is still shaking at 499 ms")
	game.view.present(game.view_snapshot(),1.0,1.0)
	check(game.view.world.position==base and game.view.hud.state["camera"]==-base,
		"world and world-space numbers return to their base camera at 500 ms")
	game.view.particle_bursts.clock = previous_clock

func check_bloody_rave_special_targets() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"berserker"})
	profile.command("numbers.skill_grant",{"id":"bloodyrave","level":1})
	profile.command("numbers.skill_grant",{"id":"buff","level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["bloodyrave"]
	var cases := {
		"body_immune":[{}, {}, 1231.0],
		"champion":[{"source_monster_rank":1}, {}, 2426.0],
		"super_champion":[{"source_monster_rank":2}, {}, 2426.0],
		"boss":[{"source_monster_rank":3}, {}, 3023.0],
		"armored_boss":[{"source_monster_rank":3}, {"rave_human_armor":true}, 3023.0],
		"human_armor":[{}, {"rave_human_armor":true}, 3023.0],
		"special_id":[{"source_mob_id":50000,"source_monster_rank":3}, {}, 2724.0],
		"upper_special_id":[{"source_mob_id":60000}, {}, 2724.0],
		"outside_special_ids":[{"source_mob_id":51001}, {}, 1529.0],
		"common_champion_drop":[{"source_mob_id":50000}, {"rave_common_champion_drop":true}, 3023.0]}
	for label: String in cases:
		start_room("original_27601","katana",1,spec,"berserker")
		game.apply_skill_effect("buff","frenzy")
		game.numeric_player.values["attack_speed"] = 1.0
		session.set_skill_material_spender(func(_id: int, _amount: int):return true)
		var target: Dictionary = api.spawn_dummy(POINT+Vector2(145,0))
		var fixture: Array = cases[label]
		target.merge(fixture[0],true)
		target["def"] = target["def"].duplicate()
		target["def"].merge(fixture[1],true)
		var frame_items: Dictionary = game.enemy_frame(target)["items"]
		var previous_body_mode = frame_items.get("13")
		if label == "body_immune":frame_items["13"] = 2
		press(KEY_A)
		step(0)
		step(790)
		var targets: Dictionary = game.player["native_phase"]["suction_targets"]
		check(targets.has(target["id"]) == (label != "body_immune"),"the suction status checks the target body mode: "+label)
		if label == "body_immune":
			check(cues(game.move_def("bloodyrave")["suction_contact_fx"]).size()==1,
				"body mode 2 rejects the suction status after the contact cue")
		step(500)
		if previous_body_mode == null:frame_items.erase("13")
		else:frame_items["13"] = previous_body_mode
		step(460)
		check(game.objects.size()==1 and game.objects[0]["hit"]["percent"]==fixture[2],
			"the slash uses the first matching source score for "+label)

func check_bloody_rave_fade() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"berserker"})
	profile.command("numbers.skill_grant",{"id":"bloodyrave","level":1})
	profile.command("numbers.skill_grant",{"id":"buff","level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["bloodyrave"]
	start_room("original_27601","katana",-1,spec,"berserker")
	game.apply_skill_effect("buff","frenzy")
	game.numeric_player.values["attack_speed"] = 1.0
	session.set_skill_material_spender(func(_id: int, _amount: int):return true)
	var move: Dictionary = game.move_def("bloodyrave")
	var end_key: String = move["suction_end_fx"]
	var inhale: Array = move["stages"][0]["fx"]
	var line_keys := [inhale[4]["key"],inhale[5]["key"]]
	var loop_keys := [inhale[2]["key"],inhale[3]["key"]]
	session.submit_key(KEY_A,true)
	step(0)
	step(710)
	check(not game.view.object_views.has("player:rave_typhoon:2"),"the independent Typhoon starts with zero opacity")
	step(150)
	var vortex: Array = game.view_snapshot()["objects"].filter(func(o):return o.get("effect","")==move["suction_typhoon"]["key"])
	check(vortex.size()==7,"the native Typhoon emits the seven visible offsets for this clock")
	if not vortex.is_empty():
		var first: Dictionary = vortex[0]
		check(first["pos"]==POINT-Vector2(95,0) and first["z"]==96.0 and first["clock"]==280.0
			and is_equal_approx(float(first["fade"]),127.0/255.0)
			and is_equal_approx(float(first["size_rate"]),0.55625),
			"the first Typhoon layer mirrors its offset, uses the stepped source frame and interpolates size")
	step(529)
	var lines: Array = game.view.effects.filter(func(fx):return fx.cue_key in line_keys)
	var loops: Array = game.view.effects.filter(func(fx):return fx.cue_key in loop_keys)
	check(lines.size()==2 and loops.size()==2 and lines.all(func(fx):return int(fx.frame["frame"])==16),
		"the original line clips play through their last frame during the hold")
	if lines.size()!=2 or loops.size()!=2:return
	step(1)
	check(lines.all(func(fx):return int(fx.frame["frame"])==5),"the native line restart resumes at frame five")
	var loop_clock: float = loops[0].clock_ms
	session.submit_key(KEY_A,false)
	step(0)
	check(game.player["stage"]==1 and lines.all(func(fx):return int(fx.frame["frame"])==0 and fx.fade==1.0)
		and loops[0].clock_ms==loop_clock,"release resets only the blood lines and carries the vortex clock")
	step(150)
	check(lines.all(func(fx):return int(fx.frame["frame"])==0 and is_equal_approx(fx.fade,127.0/255.0))
		and loops[0].clock_ms==loop_clock+150.0 and loops[0].fade==1.0,
		"the release fades the first line frames while both vortex layers keep playing at full opacity")
	vortex = game.view_snapshot()["objects"].filter(func(o):return o.get("effect","")==move["suction_typhoon"]["key"])
	check(not vortex.is_empty() and vortex.all(func(o):return float(o["fade"])<=127.0/255.0),
		"the independent Typhoon keeps moving during release while using the same fading alpha")
	step(148)
	check(cues(end_key).is_empty() and is_equal_approx(lines[1].fade,1.0/255.0),"at 298 ms the last alpha byte is still visible")
	step(1)
	var ending: Array = game.view.effects.filter(func(fx):return fx.cue_key==end_key)
	check(ending.size()==1 and game.view.effects.all(func(fx):return not fx.cue_key in line_keys+loop_keys),
		"the zero alpha byte removes only the inhale loops and lines and creates End.ani")
	check(game.view.object_views.keys().all(func(id):return not String(id).begins_with("player:rave_typhoon:")),
		"the independent Typhoon disappears with the end of the fade")
	if ending.is_empty():return
	check(ending[0].facing==-1 and ending[0].follow_offset==Vector2(-55,-96)
		and ending[0].z_index==int(POINT.y)+1,"the end clip mirrors its native offset and uses its attached depth")
	step(239)
	check(int(ending[0].frame["frame"])==2 and not ending[0].is_queued_for_deletion(),"End.ani retains all three authored 80 ms frames")
	step(1)
	check(game.view.effects.all(func(fx):return fx.cue_key!=end_key),"End.ani leaves the view after 240 ms")

func check_bloody_rave_contact_bleed() -> void:
	var seeds := {}
	for seed_value in 100000:
		game.rng.reseed(seed_value)
		var roll: int = game.rng.range_int(0,9999)
		if roll in [2279,2281] and not seeds.has(roll):seeds[roll] = seed_value
		if seeds.size()==2:break
	check(seeds.size()==2,"fixed seeds bracket the Bloody Rave status roll")
	if seeds.size()!=2:return
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"berserker"})
	profile.command("numbers.skill_grant",{"id":"bloodyrave","level":1})
	profile.command("numbers.skill_grant",{"id":"buff","level":1})
	for scenario: String in ["repeat","miss","resist","passive"]:
		if scenario == "passive":profile.command("numbers.skill_grant",{"id":"bleedingmastery","level":1})
		var spec := profile.stats()
		spec["skill_slots"] = ["bloodyrave"]
		var facing := -1 if scenario == "passive" else 1
		start_room("original_27601","katana",facing,spec,"berserker")
		if scenario == "miss":game.view.audio.muted = false
		game.apply_skill_effect("buff","frenzy")
		game.numeric_player.values["attack_speed"] = 1.0
		session.set_skill_material_spender(func(_id: int, _amount: int):return true)
		var target: Dictionary = api.spawn_dummy(POINT+Vector2(145*facing,0))
		target["def"] = target["def"].duplicate()
		if scenario == "repeat":target["def"]["rave_fixture"] = game.table.monsters["soldier_axionexpeller"]["rave_fixture"]
		var level := 47 if scenario == "passive" else 45
		target["numeric"].values["level"] = level
		target["numeric"].values["bleeding_resistance"] = 100 if scenario == "resist" else 0
		target["numeric"].values["abnormal_resistance"] = 0
		press(KEY_A)
		step(0)
		var seed_value: int = seeds[2281 if scenario == "miss" else 2279]
		game.rng.reseed(seed_value)
		var source_move: Dictionary = game.move_def("bloodyrave")
		var contact_key: String = source_move["suction_contact_fx"]
		var sound_key: String = source_move["suction_contact_sound"]
		step(789)
		check(not target["numeric"].effects.active.has("bleed"),"the pre-contact inhale frames never apply bleed")
		check(cues(contact_key).is_empty() and cues(sound_key).is_empty(),"the contact effects wait for the original attack frame")
		var judge = preload("res://combat/hit/hit_judge.gd")
		var boxes: Array = game.action_def()["timeline"][9]["attack_boxes"]
		var hit_world: Array = judge.world_boxes(boxes,Vector3(POINT.x,POINT.y,0),facing)
		var overlap: Vector3 = judge.contact(hit_world,game.enemy_damage_boxes(target))["point"]
		var sample = preload("res://core/det_rng.gd").new(seed_value)
		sample.range_int(0,9999)
		var angle := lerpf(-0.4,0.4,sample.range_int(0,99)/99.0)
		var z := int(overlap.z)+sample.range_int(-50,49)
		var x := int(overlap.x)+sample.range_int(-50,49)
		step(1)
		var emitted: Array = cues(contact_key)
		check(emitted.size()==1 and emitted[0]["facing"]==facing and emitted[0]["point"]==Vector2(x,POINT.y)
			and emitted[0]["height"]==z and is_equal_approx(float(emitted[0]["angle"]),angle) and cues(sound_key).size()==1,
			"contact animation and original hit sound follow the sampled collision point independently of bleed")
		if scenario == "miss":
			var audio = game.view.audio
			var stream: AudioStream = audio.variants[sound_key][0]
			check(stream is AudioStreamOggVorbis and audio.voice_pool.any(func(voice):return voice.stream==stream and voice.playing),
				"the original ATK Ogg reaches the voice pool on a contact that fails the bleed roll")
		if scenario == "repeat":
			var hits: Array = game.view.effects.filter(func(fx):return fx.cue_key==contact_key)
			check(hits.size()==1 and int(hits[0].frame["frame"])==0 and is_equal_approx(hits[0].base_rotation,angle),
				"the spawned contact view displays the first native frame with the sampled angle")
			game.view.present(game.view_snapshot(),0.0,194.0)
			check(hits.size()==1 and int(hits[0].frame["frame"])==4,"the contact view holds its fifth frame through 194 ms")
			game.view.present(game.view_snapshot(),0.0,1.0)
			check(game.view.effects.all(func(fx):return fx.cue_key!=contact_key),"contact visual expires at 195 ms independently of the inhale")
		var entry: Dictionary = target["numeric"].effects.active.get("bleed",{})
		check((not entry.is_empty()) == (scenario in ["repeat","passive"]) and target["hp"]==5000.0,
			"Bloody Rave contact roll and resistance gate without direct damage: "+scenario)
		if entry.is_empty():continue
		var applications: Array = entry["source_bleed"]["applications"]
		check(applications==[{"remaining_ms":5000.0,"amount":55,"status_level":level}],
			"the inhale uses the original bleed duration, damage base and effective status level")
		if scenario != "repeat":continue
		var targets: Dictionary = game.player["native_phase"]["suction_targets"]
		check(targets.has(target["id"]) and not targets[target["id"]]["pull"],
			"a MOB fixture can bleed and remain registered without receiving the movement appendage")
		game.rng.reseed(seeds[2279])
		step(200)
		step(49)
		check(applications.size()==1,"an overlapping target cannot bleed again before the rearm boundary")
		check(cues(contact_key).size()==1,"continuous overlap does not replay the contact animation early")
		step(1)
		check(applications.size()==2 and target["pos"]==POINT+Vector2(145*facing,0),
			"a fixture stays in place and can independently stack bleed on the 250 ms rearm")
		check(cues(contact_key).size()==2,"an eligible repeat contact plays a fresh animation")
		target["numeric"].values["hp_max"] = 5000.0
		game.step_numeric_actor(target,target["numeric"],0.0)
		check(target["hp"]==4890.0,"the two sourced bleed ticks deal 110 HP through the numeric actor")
		step(250)
		var release_count := applications.size()
		game.rng.reseed(seeds[2279])
		step(250)
		check(game.player["stage"]==1 and applications.size()==release_count,
			"the release animation no longer makes inhale contacts")
		step(460)
		check(game.objects.size()==1 and game.objects[0]["hit"]["percent"]==1529.0,
			"an ordinary fixture contributes one score to the final slash")

func check_grab_blast_startup() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"berserker"})
	profile.command("numbers.skill_grant",{"id":"grabblastblood","level":1})
	profile.command("numbers.skill_grant",{"id":"buff","level":2})
	var spec := profile.stats()
	spec["skill_slots"] = ["grabblastblood"]
	var denied := ["whiff","invulnerable","freeze","stone","source_disabled","no_down","body_immune"]
	for outcome: String in denied+["hit","bleed_frenzy","early_bleed","late_bleed","interrupted","interrupted_left","body_armor"]:
		var facing := -1 if outcome in ["body_armor","interrupted_left"] else 1
		start_room("original_27601","katana",facing,spec,"berserker")
		var empowered := outcome == "bleed_frenzy"
		if empowered:game.apply_skill_effect("buff","frenzy")
		var strength: float = game.numeric_player.values["strength"]
		game.numeric_player.values["attack_speed"] = 1.0
		game.numeric_player.values["hit"] = 1.0
		game.numeric_player.values["independent_attack"] = Numbers.shared_config()["base"]["independent_attack"]
		var target: Dictionary = api.spawn_dummy(POINT+Vector2((200 if outcome == "whiff" else 50)*facing,0))
		target["hp"] = 50000.0
		target["numeric"].values["hp_max"] = 50000.0
		if empowered or outcome == "early_bleed":target["numeric"].effects.add_source_bleed(0,3000,38)
		if outcome == "invulnerable":target["invuln_ms"] = 2000.0
		if outcome in ["freeze","stone"]:
			target["numeric"].effects.add(outcome,{"duration_ms":2000.0})
		if outcome in ["source_disabled","no_down"]:
			var record: Dictionary = game.content.record(target["mob"])
			var raw: Array = record["raw"]
			var decoded: Dictionary = record["decoded"]
			var down: Array = decoded["down_motion"]
			if outcome == "source_disabled":raw.append({"tag":"[is grabable]","values":[0]})
			else:decoded.erase("down_motion")
			target["def"] = game.table._build_monster("goblin",{"mob":target["mob"]})
			if outcome == "source_disabled":raw.pop_back()
			else:decoded["down_motion"] = down
		var frame_items: Dictionary = game.enemy_frame(target)["items"]
		var previous_body_mode = frame_items.get("13")
		if outcome == "body_immune":frame_items["13"] = 2
		if outcome == "body_armor":frame_items["13"] = 1
		press(KEY_A)
		step(0)
		check(game.player["clock"]==120.0 and game.view.player_actor.pose=="grab" and game.view.player_actor.sample()["frame"]==3,
			"Bloodlust enters the authored Grab pose at frame three for "+outcome)
		step(159)
		check(game.player["stage"]==0 and game.objects.is_empty(),"Bloodlust cannot capture before frame seven")
		check(cues("BLOODR_GET").is_empty(),"Bloodlust has no capture sound before contact")
		step(1)
		if previous_body_mode == null:frame_items.erase("13")
		else:frame_items["13"] = previous_body_mode
		if outcome in denied:
			check(game.player["stage"]==0 and not game.view.object_views.has("player:grab_hold") and cues("BLOODR_GET").is_empty(),
				"Bloodlust never enters the spray phase or attaches the hand animation for "+outcome)
			step(360)
			check(game.player["action"]=="" and game.objects.is_empty() and game.active_effect("bloodlust_strength").is_empty(),
				"Bloodlust recovers without a spray or strength grant for "+outcome)
			continue
		check(game.player.get("grab_blast_target",-1)==target["id"] and game.view.player_actor.sample()["frame"]==16,
			"Bloodlust captures one target and holds the terminal pose at frame seven contact")
		check(cues("BLOODR_GET").size()==1 and cues("BLOOD_SUCK").is_empty(),"capture plays the original grab sound once")
		var hand = game.view.object_views["player:grab_hold"]
		check(hand.loop and hand.facing==facing and hand.clock_ms==0.0 and not hand.frame.has("sprite")
			and hand.position==game.view._canvas(POINT+Vector2(43*facing,0),90.0)
			and hand.z_index==game.view.player_actor.z_index+1,
			"Bloodlust attaches the original blank first frame at its mirrored hand anchor")
		var held_actor = game.view.enemy_actors[target["id"]]
		check(target["state"]=="hold" and target["pos"]==POINT+Vector2(43*facing,-1)
			and target["z"]==110.0 and target["facing"]==-facing and held_actor.pose=="damage2" and held_actor.sample()["frame"]==0,
			"Bloodlust places the victim at the mirrored native anchor in its second damage motion")
		if outcome == "body_armor":continue
		var clock: float = target["clock"]
		game.player["pos"] = POINT+Vector2(5,4)
		game.update_enemy(target,20.0)
		check(target["clock"]==clock and target["pos"]==POINT+Vector2(5+43*facing,3) and game.enemy_ani(target)==["damage2",20.0],
			"captured monster follows the caster and advances only its held animation")
		game.player["pos"] = POINT
		game.update_enemy(target,0.0)
		if outcome.begins_with("interrupted"):
			game.hurt_player(7,{"pos":POINT+Vector2(40*facing,0)},{},-facing)
			step(750)
			check(not game.player.has("grab_blast_target") and not target.has("grab_blast_pose")
				and target["state"]=="grab_blast_down" and game.objects.is_empty()
				and not game.view.object_views.has("player:grab_hold")
				and cues("BLOOD_SUCK").is_empty() and cues("BLOODR_FIRE").is_empty()
				and target["facing"]==-facing and float(target["native_jump_velocity"].x)*facing>=633.0
				and float(target["native_jump_velocity"].x)*facing<=950.0 and game.active_effect("bloodlust_strength").is_empty(),
				"interruption releases the held target into the native knockdown in either direction")
			continue
		step(99)
		check(target["hp"]==50000.0 and cues("BLOOD_SUCK").is_empty(),"Bloodlust has no direct damage or drain sound through 99 ms after capture")
		step(1)
		check(hand.clock_ms==100.0 and hand.frame.has("sprite") and hand.frame["items"]["11"]["type"]==2,
			"the held hand's additive ANI starts drawing at its original 100 ms boundary")
		var direct: Dictionary = game.last_damage.get("trace",{})
		check(target["hp"]<50000.0 and direct.get("percent_part")==0.0
			and is_equal_approx(float(direct.get("fixed_part",0)),1300.5 if empowered else 1275.0),
			"Bloodlust's directed strike reads level column zero and the native Frenzy multiplier")
		if outcome == "early_bleed":target["numeric"].effects.remove("bleed")
		if outcome == "late_bleed":target["numeric"].effects.add_source_bleed(0,3000,38)
		step(649)
		check(game.objects.is_empty() and game.active_effect("bloodlust_strength").is_empty()
			and game.numeric_player.values["strength"]==strength,"Bloodlust waits through 749 ms before spray and strength")
		check(cues("BLOOD_SUCK").size()==1 and cues("BLOODR_FIRE").is_empty(),"ordinary Bloodlust asks for the drain sound once at the strike")
		check(hand.clock_ms==749.0 and not hand.frame.has("sprite"),"the 650 ms hand ANI loops back through its blank frame")
		if empowered:move_target(target,POINT+Vector2(320,0))
		var bystander: Dictionary = game.spawn_enemy(POINT+Vector2(100,0))
		var distant: Dictionary = game.spawn_enemy(POINT+Vector2(330,0))
		var before_spray: float = target["hp"]
		step(1)
		check(hand.clock_ms==750.0 and hand.frame.has("sprite"),"the hand ANI remains attached through the spray state")
		check(cues("BLOODR_FIRE").size()==1,"spray plays its original release sound once")
		check(not game.player.has("grab_blast_target") and not target.has("grab_blast_pose") and game.objects.size()==1
			and game.objects[0]["pos"]==POINT+Vector2(43,1) and game.objects[0]["z"]==90.0,
			"Bloodlust creates one spray at the original hand offset after 750 ms")
		var spray: Dictionary = game.objects[0]["hit"]
		var large := empowered or outcome == "late_bleed"
		var source := "grabblastbloodbig.obj" if large else "grabblastblood.obj"
		var amount := 3419.0 if empowered else (3352.0 if large else 1821.0)
		check(spray["object"].ends_with(source) and spray["percent"]==0.0 and spray["fixed_amount"]==amount,
			"Bloodlust selects the source spray and truncates each fixed damage component in order")
		var duration := 20000.0 if empowered or outcome=="early_bleed" else 10000.0
		check(game.active_effect("bloodlust_strength").get("remaining_ms",0)==duration
			and game.numeric_player.values["strength"]==strength+46.0,
			"Bloodlust grants row-three strength and uses the earlier bleed observation for duration")
		check(target["hp"]<before_spray and game.objects[0]["hits"].has(target["id"]) and game.objects[0]["hits"].size()==1,
			"Bloodlust directs its first spray hit to the held target even outside the ANI boxes")
		check(target["state"]=="grab_blast_down" and game.enemy_ani(target)==["down",0.0]
			and target["native_jump_gravity"]==-1500.0 and float(target["native_jump_velocity"].x)>=633.0
			and float(target["native_jump_velocity"].x)<=950.0
			and int(round(float(target["vz"])*float(target["vz"])/3000.0)) in [7,8],
			"Bloodlust replaces the held target's spray reaction with the Goblin-weight DOWN launch")
		var hp: float = target["hp"]
		var bystander_hp: float = bystander["hp"]
		var distant_hp: float = distant["hp"]
		game.step_objects(100.0,int(game.objects[0]["id"]))
		check(game.objects[0]["clock"]==0.0 and target["hp"]==hp and bystander["hp"]<bystander_hp and distant["hp"]==distant_hp,
			"the spray's first authored frame hits nearby bystanders and cannot repeat the directed hit")
		if not empowered:
			target["stuck_ms"] = 0.0
			var release_pos: Vector2 = target["pos"]
			game.update_enemy(target,40.0)
			check(float(target["pos"].x)>release_pos.x and float(target["z"])>110.0,"the held victim follows the DOWN launch after release")
			for tick in range(12):game.update_enemy(target,40.0)
			check(target["z"]==0.0 and target["state"]=="down" and not target.has("native_jump_velocity"),
				"the DOWN launch ends on the ground without the shared bounce")
		step(450)
		check(game.player["action"]=="" and not game.view.object_views.has("player:grab_hold"),
			"Bloodlust completes the 1200 ms capture branch and clears its hand ANI")
		if outcome == "hit":
			game.step_numeric_actor(game.player,game.numeric_player,6000.0)
			game.player["cooldowns"].erase("grabblastblood")
			move_target(target,POINT+Vector2(50,0))
			press(KEY_A)
			step(160)
			step(100)
			step(650)
			check(game.active_effect("bloodlust_strength").get("stacks",0)==2
				and game.numeric_player.values["strength"]==strength+92.0,"overlapping Bloodlust casts add two strength grants")
			game.step_numeric_actor(game.player,game.numeric_player,4000.0)
			check(game.active_effect("bloodlust_strength").get("remaining_ms",0)==6000.0
				and game.numeric_player.values["strength"]==strength+46.0,"the first Bloodlust grant expires on its own timer")
			duration = 6000.0
		game.step_numeric_actor(game.player,game.numeric_player,duration-1.0)
		check(game.numeric_player.values["strength"]==strength+46.0,"Bloodlust grants strength through its last millisecond")
		game.step_numeric_actor(game.player,game.numeric_player,1.0)
		check(game.active_effect("bloodlust_strength").is_empty() and game.numeric_player.values["strength"]==strength,
			"Bloodlust restores the caster's strength at expiry")
	var floor_x := 0
	while floor_x<int(POINT.x) and not game.walkable(Vector2(floor_x,POINT.y)):floor_x += 1
	var saved := Vector3i(int(POINT.x),int(POINT.y),5)
	check(game.grab_blast_release_position(Vector3i(floor_x-3,int(POINT.y),110),saved)==Vector3i(floor_x,int(POINT.y),110),
		"the blocked release point searches along its original depth in three-pixel increments")
	check(game.grab_blast_release_position(Vector3i(-250,int(POINT.y),110),saved)==saved,
		"the release returns to the saved XYZ when the native search cannot find a walkable point")

func check_grab_blast_non_weapon_speed() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"berserker"})
	profile.command("numbers.skill_grant",{"id":"grabblastblood","level":1})
	var gear := profile.command("numbers.gear_give",{"id":"original_27601"})
	check(gear["ok"] and profile.command("numbers.gear_equip",{"uid":gear.get("uid","")})["ok"],
		"Bloodlust speed fixture equips the original +80 attack-speed katana")
	var spec := profile.stats()
	spec["skill_slots"] = ["grabblastblood"]
	start_room("original_27601","katana",1,spec,"berserker")
	game.numeric_player.set_runtime_modifiers([{"source":"fixture","stat":"attack_speed","op":"add","value":0.25}])
	check(is_equal_approx(float(game.numeric_player.values["attack_speed"]),1.33)
		and game.numeric_player.native_non_weapon_attack_rate()==1.25,
		"Bloodlust mode 3 removes only the original weapon rate and retains the other bonus")
	var target: Dictionary = api.spawn_dummy(POINT+Vector2(50,0))
	target["hp"] = 50000.0
	press(KEY_A)
	step(127)
	check(game.player["stage"]==0,"+80 weapon speed does not open the capture early")
	step(1)
	check(game.player["stage"]==1,"the remaining +250 non-weapon rate opens the capture at 128 ms")
	var hand = game.view.object_views["player:grab_hold"]
	step(79)
	check(hand.clock_ms==98.75 and not hand.frame.has("sprite"),"the held hand uses the same non-weapon rate")
	step(1)
	check(hand.clock_ms==100.0 and hand.frame.has("sprite") and grab_direct_hits().is_empty(),
		"the hand appears at 80 ms without accelerating the fixed 100 ms damage gate")
	step(20)
	check(grab_direct_hits().size()==1,"the ordinary direct strike remains at 100 ms after capture")
	profile.command("numbers.gear_unequip",{"slot":"weapon"})
	var unarmed := profile.stats()
	unarmed["skill_slots"] = ["grabblastblood"]
	check(game.update_numbers(unarmed) and game.numeric_player.native_non_weapon_attack_rate()==1.25,
		"reconfiguring without a weapon clears the deduction and keeps the other rate")

func check_grab_blast_thirst() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"berserker"})
	profile.command("numbers.skill_grant",{"id":"grabblastblood","level":1})
	for scenario: String in ["four_strikes","expires","interrupted","large"]:
		var large := scenario == "large"
		var rank := 2 if large else 1
		profile.command("numbers.skill_grant",{"id":"sacrifice","level":rank})
		var spec := profile.stats()
		spec["skill_slots"] = ["grabblastblood"]
		start_room("original_27601","katana",1,spec,"berserker")
		game.apply_effect({"kind":"effect","id":"thirst","rank":rank})
		check(not game.active_effect("thirst").is_empty(),"Thirst is active before the shortcut starts Bloodlust")
		var target: Dictionary = api.spawn_dummy(POINT+Vector2(50,0))
		target["hp"] = 50000.0
		game.numeric_player.values["hit"] = 1.0
		press(KEY_A)
		step(160)
		step(99)
		check(grab_direct_hits().is_empty(),"Thirst waits through 99 ms before its first directed strike")
		step(1)
		check(grab_direct_hits().size()==1 and target["state"]=="hold", "Thirst automatically strikes at 100 ms after key release")
		step(599)
		check(grab_direct_hits().size()==1 and game.objects.is_empty(),"Thirst waits the configured 600 ms before repeating")
		check(cues("BLOOD_SUCK").size()==2 and cues("BLOOD_SUCK")[1].get("max_same_key")==3,
			"the original Thirst hold requests a drain voice between strikes with the three-voice cap")
		if scenario == "expires":
			game.active_effect("thirst")["remaining_ms"] = 1.0
			game.step_numeric_actor(game.player,game.numeric_player,1.0)
			step(0)
			check(grab_direct_hits().size()==2 and game.objects.is_empty(),"Thirst expiry takes the ordinary strike path before the next repeat is due")
			step(50)
			check(game.objects.is_empty(),"expiry still respects the 750 ms spray floor")
			step(1)
			check(game.objects.size()==1 and not game.player.has("grab_blast_target") and not target["numeric"].effects.active.has("bleed"),
				"Thirst expiry falls back to an ordinary spray without its bleed payload")
			continue
		step(1)
		check(grab_direct_hits().size()==2,"Thirst dispatches its second strike at 700 ms")
		if scenario == "interrupted":
			game.hurt_player(7,{"pos":POINT+Vector2(40,0)},{},-1)
			step(1400)
			check(grab_direct_hits().size()==2 and game.objects.is_empty() and game.active_effect("bloodlust_strength").is_empty()
				and not game.player.has("grab_blast_target"),"interruption cancels the rest of the repeat timer and releases without a spray")
			continue
		target["numeric"].effects.add_source_bleed(0,3000,38)
		step(50)
		if not large:target["numeric"].effects.remove("bleed")
		check(game.objects.is_empty() and game.active_effect("bloodlust_strength").is_empty(),"750 ms does not cut off active Thirst strikes")
		step(650)
		check(grab_direct_hits().size()==3 and game.player["action"]=="grabblastblood","a delayed third update still keeps the victim held past 1200 ms")
		step(599)
		check(grab_direct_hits().size()==3,"a late update schedules the next interval from the actual strike time")
		step(1)
		check(grab_direct_hits().size()==4 and game.objects.is_empty(),"the fourth direct strike does not spray in the same update")
		step(1)
		check(grab_direct_hits().size()==4 and game.objects.is_empty(),"timer exhaustion advances the original spray-ready substate")
		var bystander: Dictionary = game.spawn_enemy(POINT+Vector2(100,0))
		bystander["hp"] = 50000.0
		check(not bystander["numeric"].effects.active.has("bleed") and target["numeric"].effects.active.has("bleed")==large,
			"the four direct strikes do not carry the spray's new bleed application")
		step(1)
		var spray_name := "/grabblastbloodbig.obj" if large else "/grabblastblood.obj"
		check(game.objects.size()==1 and game.objects[0]["hit"]["object"].ends_with(spray_name)
			and game.active_effect("bloodlust_strength").get("remaining_ms",0)==20000.0
			and not game.player.has("grab_blast_target") and game.player["action"]=="",
			"Thirst remembers bleed during the extended hold but sprays by live bleed and releases after four strikes")
		var expected := {"id":"bleed","chance":1.0,"status_level":40 if large else 37,
			"duration_ms":3000,"source_bleed_total":136 if large else 131}
		check(game.objects[0]["hit"]["effects"]==[expected],"spray records the source Thirst rank and level-60 status damage")
		game.step_objects(16.0,int(game.objects[0]["id"]))
		for victim: Dictionary in [target,bystander]:
			var bleed: Dictionary = victim["numeric"].effects.active.get("bleed",{})
			var applications: Array = bleed.get("source_bleed",{}).get("applications",[])
			check(applications.size()==(2 if large and victim==target else 1)
				and applications.back()=={"remaining_ms":3000.0,"amount":22 if large else 21,"status_level":expected["status_level"]},
				"the source spray applies the same bleed to the held victim and bystander without duplicating the held hit")
	var audio = game.view.audio
	audio.muted = false
	for key: String in ["BLOODR_GET","BLOOD_SUCK","BLOODR_FIRE"]:
		var event: Dictionary = cues(key).front()
		var expected_voices := 3 if key=="BLOOD_SUCK" else 1
		for attempt in expected_voices+2:audio.on_cue(event)
		var stream = audio.variants.get(key,[null])[0]
		var playing: Array = audio.voice_pool.filter(func(voice):return voice.stream==stream and voice.playing)
		check(stream is AudioStreamOggVorbis and playing.size()==expected_voices,key+" reaches the audio player with the expected live voice limit")
	for voice: AudioStreamPlayer in audio.voice_pool:voice.stop()
	audio.muted = true

func grab_direct_hits() -> Array:
	return game.bus.events_of("combat.hit").filter(func(event):return event.get("atk","").ends_with("/grabblastblood.atk"))

func check_hundred_sword_ready() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"weaponmaster"})
	profile.command("numbers.skill_grant",{"id":"hundredsword","level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["hundredsword"]
	start_room("","katana",-1,spec)
	for enemy: Dictionary in game.monsters:move_target(enemy,POINT+Vector2(1200,0))
	game.numeric_player.values["mp_cost_rate"] = 1.0
	game.numeric_player.values["cooldown_rate"] = 1.0
	game.numeric_player.values["attack_speed"] = 1.25
	game.numeric_player.weapon_attack_speed_per_mille = 250
	game.player["mp"] = 1500.0
	var payments: Array = []
	session.set_skill_material_spender(func(id: int, amount: int):
		payments.append([id,amount])
		return payments.size() > 1)
	press(KEY_A)
	step(0.0)
	check(game.player["action"]=="" and game.player["mp"]==1500.0
		and not game.player["cooldowns"].has("hundredsword") and payments==[[3037,5]],
		"Hundred Sword rejects a failed five-cube payment before committing MP or cooldown")
	press(KEY_X)
	step(0.0)
	press(KEY_A)
	step(0.0)
	var layers: Array = game.view.effects.filter(func(fx):return String(fx.data["source"]).ends_with("/hundredsword/ready.ani"))
	check(game.player["action"]=="hundredsword" and game.view.player_actor.pose=="hundredswordready"
		and game.player["mp"]==520.0 and game.player["cooldowns"].get("hundredsword",0)==145.0 and payments==[[3037,5],[3037,5]],
		"the normal-attack entry commits the original rank-one MP, cooldown and five cubes once")
	check(layers.size()==1 and layers[0].follow==game.player["id"] and game.attack_body_armor()
		and game.action_duration("hundredsword")==3000.0,
		"the original ready overlay follows the armored body and excludes weapon speed")
	step(239.0)
	check(cues("SM_BOONGSAN").is_empty() and game.objects.is_empty(),"the ready state has no early voice or generic attack object")
	step(1.0)
	check(cues("SM_BOONGSAN").size()==1,"the first authored ready voice plays at frame three")
	var finish: Dictionary = game.move_def("hundredsword")["stages"][-1]
	check(finish["hits"].size()==1 and finish["hits"][0]["percent"]==2501.0
		and finish["hits"][0]["atk_path"].ends_with("/hundredswordfinish.atk"),
		"the finish uses original ATK 62 and rank column two without an unrelated object")
	game.player["pos"] = POINT+Vector2(17,7)
	game.player["facing"] = 1
	var swords := func(stem: String):
		return game.view_snapshot()["objects"].filter(func(o):
			return str(o["id"]).begins_with("hundred_sword:") and String(o["effect"]).contains(stem))
	var center := POINT-Vector2(150,0)
	step(79.0)
	check(swords.call("light").is_empty() and cues("W_GET_SPIRITS").is_empty(),"no swords or collection cue at 319 ms")
	step(1.0)
	var lights: Array = swords.call("light1")
	check(lights.size()==8 and lights[0]["pos"]==center+Vector2(-30,71) and lights[0]["z"]==150.0
		and cues("W_GET_SPIRITS").size()==1 and game.view.audio.variants["W_GET_SPIRITS"][0] is AudioStreamOggVorbis,
		"frame four spawns eight lights around the original mirrored center and plays the original collection sound")
	check(swords.call("lighttail").is_empty(),"the first gathering frame has no past position to orient a trail")
	var tint = game.view.object_views["hundred_sword:0:light:1"]
	var flash = game.view.object_views["hundred_sword:0:light:2"]
	var flash_angles: Dictionary = flash.frame_rotations
	check(tint.uniform_frame_ms==860.0 and tint.frame_color()==Color.WHITE
		and not flash.frame.has("sprite") and flash_angles.keys()==[1,3,5],
		"the gathering light starts white and samples only the three visible flash frames")
	for frame_index in [1,3,5]:
		step(40.0 if frame_index==1 else 80.0)
		var angle_index := float(flash.frame_rotation())*99.0/6.28
		check(flash.frame["frame"]==frame_index and flash.frame.has("sprite")
			and flash.frame_rotation()==flash_angles[frame_index] and angle_index>=0.0 and angle_index<=99.001
			and absf(angle_index-roundf(angle_index))<0.001,
			"each visible gathering flash uses its own sampled angle at frame %d"%frame_index)
	step(230.0)
	lights = swords.call("light1")
	check(lights.size()==8 and lights[0]["pos"]==center+Vector2(22,-53),
		"halfway to frame eleven the first eight lights rotate by 180 degrees and narrow to radius 187")
	check(is_equal_approx(tint.frame_color().r,(255.0+150.0)/510.0)
		and tint.frame_color().b==1.0 and flash.frame_rotations==flash_angles,
		"the gathering tint is still interpolating halfway through the orbit and keeps the same flash angles")
	var tail: Array = swords.call("lighttail").filter(func(o):return String(o["id"]).begins_with("hundred_sword:0:"))
	check(tail.size()==12 and tail[0]["pos"]==lights[0]["pos"] and tail[0]["fade"]==1.0
		and is_equal_approx(tail[11]["fade"],50.0/255.0),
		"the full-effects trail starts at the gathering light and uses the native opacity endpoints")
	for index in tail.size():
		var layer: Dictionary = tail[index]
		var trail = game.view.object_views.get(layer["id"])
		var variant := mini(4,1+floori(index/3.0))
		check(is_instance_valid(trail) and String(trail.data["source"]).ends_with("/lighttail%d.ani"%variant)
			and trail.z_index==int(lights[0]["pos"].y)+3 and trail.base_rotation==layer["rotation"]
			and trail.fade==layer["fade"],
			"gathering trail layer %d uses its native sprite, angle, fade and sword draw group"%index)
		if index>0:
			var distance: float = layer["pos"].distance_to(tail[index-1]["pos"])
			check(distance>=9.0 and distance<=11.0,"the next layer steps ten pixels into the sword history")
	step(430.0)
	var spread: Array = swords.call("swordspread1")
	check(spread.size()==24 and spread.all(func(o):return o["pos"]==center and o["z"]==150.0)
		and swords.call("lighttail").is_empty()
		and game.view.object_views["hundred_sword:4:swordspread:1"].data["frames"][0]["img"].to_lower().ends_with("/sword05.img"),
		"frame eleven clears the gathering trails and adds the remaining sixteen swords at the center")
	step(1019.0)
	check(swords.call("swordspread1").size()==24 and swords.call("swordland1").is_empty(),
		"the spread formation stays in its airborne preparation pose through frame seventeen")
	check(game.objects.is_empty(),"the field waits until ready frame eighteen")
	var fresh: int = game._next_entity_id
	step(1.0)
	game.step_objects(1.0,fresh)
	check(game.objects.size()==1,"ready frame eighteen creates exactly one field")
	if game.objects.size()!=1:return
	var field: Dictionary = game.objects[0]
	var ground: Array = swords.call("swordland1")
	var air: Array = swords.call("swordair1")
	check(ground.size()==12 and air.size()==12 and ground[0]["z"]==0.0 and air[0]["z"]==156.0
		and ground[0]["pos"]==center+Vector2(-30,71) and air[0]["pos"]==center+Vector2(-93,67),
		"frame eighteen places twelve swords on the ground and twelve in the air at the final orbit points")
	check(field["pos"]==center and field["facing"]==-1 and field["z"]==0.0 and field["clock"]==0.0
		and field["hit"]["percent"]==626.0 and field["hit"]["atk_path"].ends_with("/hundredswordhit.atk"),
		"the new field starts at age zero at the saved cast origin and uses original rank column zero")
	game.numeric_player.values["hit"] = 1.0
	var first: Dictionary = game.monsters[0]
	var late: Dictionary = game.monsters[1]
	var centered: Dictionary = game.spawn_enemy(center+Vector2(0.75,9))
	first["hp"] = 5000.0
	late["hp"] = 5000.0
	centered["hp"] = 5000.0
	move_target(first,center+Vector2(80,0))
	game.step_objects(99.0)
	check(first["hp"]==5000.0 and cues("W_WEAPON_DRIVE").is_empty() and cues("hundred_sword_contact").is_empty(),
		"the field neither hits nor plays a cue at age 99")
	game.step_objects(1.0)
	check(first["hp"]<5000.0 and cues("W_WEAPON_DRIVE").size()==1
		and game.view.audio.variants["W_WEAPON_DRIVE"][0] is AudioStreamOggVorbis,
		"the original three-box contact and its archived cue open at age 100")
	check(first["push_v"]<0.0 and centered["hp"]<5000.0 and centered["push_v"]>0.0,
		"the field pulls from the right and uses reverse cast facing for a victim on the same integer X")
	var hits: Array = game.bus.events_of("combat.hit").filter(func(event):
		return String(event.get("atk","")).ends_with("/hundredswordhit.atk"))
	var flashes := cues("hundred_sword_contact")
	check(hits.size()==2 and flashes.size()==2 and cues("R_SLESSSWDA_HIT").size()==2,
		"each successful contact emits one sword-field slash and the archived hit sound")
	for index in mini(hits.size(),flashes.size()):
		var overlap: Vector3 = hits[index]["point"]
		var target: Dictionary = first if hits[index]["target"]==first["id"] else centered
		check(flashes[index]["point"]==Vector2(int(overlap.x),int(target["pos"].y))
			and flashes[index]["height"]==int(overlap.z) and flashes[index]["facing"]==1
			and is_equal_approx(flashes[index]["angle"],1.57),
			"the sword-field slash uses the overlap X and Z, target ground Y and native angle")
	game.view.present(game.view_snapshot(),0.0,0.0)
	var drawn_flashes: Array = game.view.effects.filter(func(fx):return fx.cue_key=="hundred_sword_contact")
	check(drawn_flashes.size()==2 and drawn_flashes.all(func(fx):
		return (fx.data["source"]=="common/hiteffect/animation/slashlarge2.ani"
			and fx.frame_scale().is_equal_approx(Vector2(1.2,1.2)) and fx.data["duration_ms"]==200.0)),
		"the field contact draws the original 200-ms SlashLarge2 at its authored scale")
	var after_contact: float = first["hp"]
	move_target(first,center+Vector2(80,0))
	move_target(late,center-Vector2(80,0))
	game.step_objects(49.0)
	check(first["hp"]==after_contact and late["hp"]<5000.0 and late["push_v"]>0.0
		and cues("hundred_sword_contact").size()==3,
		"a fresh target is pulled in from the left at 149 while the ledger blocks a duplicate")
	field["hits"].erase(late["id"])
	late["hp"] = 5000.0
	move_target(late,center-Vector2(80,0))
	game.step_objects(1.0)
	game.view.present(game.view_snapshot(),0.0,0.0)
	var visible = game.view.object_views.get(field["id"])
	var overlay = game.view.object_views.get("%s:overlay"%field["id"])
	check(late["hp"]==5000.0 and visible!=null and overlay!=null and visible.hold_last_frame and overlay.hold_last_frame
		and cues("hundred_sword_contact").size()==3,
		"the initial attack closes at 150 while both field layers hold their final frames")
	game.start_stage(game.move_def("hundredsword")["stages"].size()-1)
	var exit_clock: float = game.action_def()["timeline"][2]["start_ms"]
	game.player["clock"] = exit_clock-1.0
	game.step_objects(0.0)
	check(not field.has("exit_at_ms"),"the field survives until the finish reaches frame two")
	game.player["clock"] = exit_clock
	game.step_objects(1.0)
	game.view.present(game.view_snapshot(),0.0,0.0)
	var exit_main = game.view.object_views.get("%s:exit"%field["id"])
	var exit_overlay = game.view.object_views.get("%s:exit_overlay"%field["id"])
	check(exit_main!=null and exit_overlay!=null and exit_main.data["source"].ends_with("disappear1.ani")
		and exit_overlay.data["source"].ends_with("disappear2.ani"),
		"finish frame two switches both field layers to their original exit animations")
	game.step_objects(299.0)
	check(game.objects.size()==1,"both exit layers remain through age 299")
	game.step_objects(1.0)
	check(game.objects.is_empty(),"the field is deleted at the original exit end")
	game.numeric_player.values["attack_speed"] = 1.75
	game.player["pos"] = POINT+Vector2(190.8,22.6)
	game.player["z"] = 78.0
	game.player["vz"] = 150.0
	game.player["facing"] = 1
	game.start_stage(game.move_def("hundredsword")["stages"].size()-1)
	check(game.player["pos"]==POINT and game.player["facing"]==-1 and game.player["z"]==0.0 and game.player["vz"]==0.0,
		"the finish returns from the last sword to the original cast point, grounds the body and restores cast facing")
	move_target(first,POINT-Vector2(90,0))
	move_target(late,POINT+Vector2(100,22))
	first["hp"] = 5000.0
	late["hp"] = 5000.0
	game.bus.clear_history()
	var finish_layers := func():
		return game.view.effects.filter(func(fx):return fx.follow==game.player["id"]).map(
			func(fx):return String(fx.data["source"]).get_file())
	var finish_trails := func():
		return game.view.object_views.keys().filter(func(id):return String(id).begins_with("hundred_sword:finish_tail:"))
	step(559.0)
	check(finish_layers.call().is_empty() and finish_trails.call().is_empty()
		and game.player["facing"]==-1 and game.player["clock"]==559.0,
		"the finish windup restores cast facing and holds its fixed clock without an early flash")
	step(1.0)
	check(first["hp"]<5000.0 and late["hp"]==5000.0,
		"the finish hits in front of the cast origin and misses the target beside the last sword")
	check(finish_layers.call()==["finishslash.ani","finishflash.ani","finishfloor.ani","finishcircle1.ani",
		"finishcircle2.ani","finishcircle3.ani","finishcircle4.ani"] and cues("SM_BLOOD_RAVE_ATK").size()==1,
		"frame two starts the original slash, flash, floor, four staggered circles and body sound")
	var particles: Array = game.bus.events_of("combat.cue").filter(func(event):
		return event.get("path","").ends_with("/hundredswordfinish.ptl"))
	check(particles.size()==1 and particles[0]["point"]==POINT-Vector2(180,0) and particles[0]["height"]==20.0,
		"the original finish particle burst starts once at the integer forward point and absolute height twenty")
	var drawn: Array = game.view.effects.filter(func(fx):
		return String(fx.get_meta("source_ptl","")).ends_with("/hundredswordfinish.ptl"))
	check(not drawn.is_empty() and drawn.all(func(fx):return String(fx.data["source"]).get_file() in [
		"finishparticle1.ani","finishparticle2.ani"]),
		"the finish burst renders instances of the two authored particle animations")
	for sample in 12:
		step(10.0)
	var heads := [Vector2i(-35,378),Vector2i(-31,388),Vector2i(-55,349),Vector2i(-89,338),
		Vector2i(-50,333),Vector2i(-42,267),Vector2i(-66,162)]
	check(finish_trails.call().size()==7*24,"the finish renders seven tracks of twenty-four trail layers")
	var finish_objects: Array = game.view_snapshot()["objects"]
	for track in heads.size():
		var prefix := "hundred_sword:finish_tail:%d:"%track
		var trail := finish_objects.filter(func(layer):return String(layer["id"]).begins_with(prefix))
		check(trail.size()==24 and trail[0]["pos"]==Vector2(heads[track].x,POINT.y)
			and trail[0]["z"]==heads[track].y and trail[0]["facing"]==-1,
			"finish trail %d reaches the original left-facing X and Z"%track)
	for group in 4:
		var layer = game.view.object_views.get("hundred_sword:finish_tail:0:%d:-1"%(group*6))
		check(layer!=null and String(layer.data["source"]).ends_with("finishtail%d.ani"%(group+1))
			and layer.z_index==int(POINT.y)-1,"finish trail group %d uses its original art behind the body"%group)
	var first_finish_layer = game.view.object_views.get("hundred_sword:finish_tail:0:0:-1")
	var last_finish_layer = game.view.object_views.get("hundred_sword:finish_tail:0:23:-1")
	check(first_finish_layer!=null and last_finish_layer!=null and first_finish_layer.fade==1.0
		and is_equal_approx(last_finish_layer.fade,100.0/255.0),
		"the finish trail fades from original alpha 255 to 100")
	step(589.0)
	check(game.player["action"]=="hundredsword","the fixed finish recovery stays active through 1269 ms")
	step(1.0)
	check(game.player["action"]=="" and finish_layers.call().is_empty() and finish_trails.call().is_empty(),
		"the finish ends at 1270 ms and clears attached layers and trails")

func check_hundred_sword_automatic() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"weaponmaster"})
	profile.command("numbers.skill_grant",{"id":"hundredsword","level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["hundredsword"]
	start_room("original_27601","katana",1,spec)
	game.clear_monsters()
	game.player["mp"] = 1500.0
	game.numeric_player.values["attack_speed"] = 1.25
	game.numeric_player.weapon_attack_speed_per_mille = 250
	session.set_skill_material_spender(func(id: int, amount: int):return id==3037 and amount==5)
	press(KEY_A)
	step(2760.0)
	check(game.player["pos"]==POINT and game.player["z"]==0.0 and game.player["stage"]==0,
		"the approach starts at ready frame twenty-two from the saved ground origin")
	step(0.9)
	check(game.player["pos"]==POINT and game.player["z"]==0.0,
		"fractional simulation time stays at the original integer-millisecond approach origin")
	step(119.1)
	check(game.player["pos"]==Vector2(428,266) and game.player["z"]==54.0,
		"the ready approach interpolates XYZ toward the first live sword with a 50-pixel height offset")
	step(120.0)
	var actor = game.view.player_actor
	var travel_cues := func():
		return game.bus.events_of("combat.cue").filter(func(event):
			return String(event.get("key","")) in ["R_SM_HOANYOUNG","R_W_MOVING_ATK"])
	check(travel_cues.call().is_empty(),"the first sword pose starts without a movement voice or swing")
	var swings: Array = game.view.audio.variants.get("R_W_MOVING_ATK",[])
	check(swings.size()==2 and swings.all(func(stream):return stream is AudioStreamOggVorbis),
		"both original sword travel swings load as Ogg streams")
	var layers: Dictionary = actor.get_meta("native_cast_layers",{})
	var first_angle := atan2(-176.0,341.0)
	check(is_equal_approx(actor.body_rotation,first_angle)
		and not actor.equipment_layers.is_empty() and actor.equipment_layers.all(func(layer):return not layer.visible),
		"the first move tilts along the projected sword path and hides the ordinary equipped weapon")
	var first_keys := ["hundred_sword_weaponready5_03","hundred_sword_weaponready5_01",
		"hundred_sword_weaponready5_02","hundred_sword_weaponready5_00"]
	check(layers.keys()==first_keys and layers[first_keys[0]].show_behind_parent
		and layers[first_keys[1]].show_behind_parent and not layers[first_keys[2]].show_behind_parent
		and not layers[first_keys[3]].show_behind_parent,
		"pose five installs both rear and front normal and dodge layers in native order")
	for key: String in first_keys:
		var layer = layers.get(key)
		check(layer!=null and layer.visible and is_equal_approx(layer.base_rotation,first_angle)
			and layer.frame.get("img_frame",-1)==0 and layer.position.y==-157.0,
			"the move weapon layer follows the source frame, height and tilt")
	var slots := [13,6,23,9,2,17,12,0,7,19,20,14,21,16,15,10,3,22,11,8,5,1,4,18]
	var poses := [5,1,2,4,3,5,2,4,2,2,3,2,5,4,1,1,4,3,3,5,3,1,5,1]
	var durations := [713,543,438,367,312,273,245,218,198,183,168,156,146,136,128,122,115,110,105,98,98,98,98,98]
	for ordinal in slots.size():
		var slot: int = slots[ordinal]
		var angle := deg_to_rad(float(7+slot*15))
		var expected := POINT+Vector2(150+int(sin(angle)*250.0),int(cos(angle)*72.5)-1)
		var next_x := POINT.x
		if ordinal+1 < slots.size():next_x += 150+int(sin(deg_to_rad(float(7+slots[ordinal+1]*15)))*250.0)
		var expected_height: bool = game.player["z"]==40.0 if slot%2==0 else game.player["z"]>=150.0 and game.player["z"]<=160.0
		check(game.player.get("hundred_sword_cast",{}).get("ordinal",-1)==ordinal
			and game.view.player_actor.pose=="hundredswordmoveready%d"%poses[ordinal] and game.player["pos"]==expected
			and expected_height and game.player["facing"]==(1 if expected.x<next_x else -1),
			"automatic Hundred Sword stage %d uses the original sword point, body pose and next facing"%ordinal)
		var disappear_id := "hundred_sword:%d:disappear:1"%slot
		var disappear = game.view.object_views.get(disappear_id)
		check(is_instance_valid(disappear),
			"the selected sword enters its original disappearance state at stage %d"%ordinal)
		if is_instance_valid(disappear):
			var angle_index := float(disappear.base_rotation)*99.0/6.28
			check(angle_index >= 0.0 and angle_index <= 99.001 and absf(angle_index-roundf(angle_index)) < 0.001
				and disappear.position == expected+Vector2(0,1+Frame.MAP_DY-float(game.player["z"])),
				"the disappearance uses the original projected anchor and discrete rotation at stage %d"%ordinal)
		check(game.action_duration("hundredsword")==durations[ordinal],
			"stage %d applies its original rate to each body frame"%ordinal)
		var elapsed := 0.0
		if ordinal == 0 and is_instance_valid(disappear):
			var start_angle: float = disappear.base_rotation
			step(299.0)
			check(game.view.object_views.has(disappear_id) and disappear.base_rotation==start_angle
				and disappear.frame.get("frame",-1)==4,
				"the fifth disappearance frame keeps the sword's sampled angle through 299 ms")
			step(1.0)
			check(not game.view.object_views.has(disappear_id),"the disappearance ends at the authored 300 ms boundary")
			elapsed = 300.0
		step(float(durations[ordinal])-1.0-elapsed)
		check(game.player.get("hundred_sword_cast",{}).get("ordinal",-1)==ordinal,
			"stage %d holds through its last millisecond"%ordinal)
		var visible: Array = actor.get_meta("native_cast_layers",{}).values().filter(func(layer):return layer.visible)
		check(visible.size()==(4 if poses[ordinal]==5 else 2)
			and visible.all(func(layer):return layer.frame.get("img_frame",-1)==1),
			"stage %d renders only its current sword layers on the second body frame"%ordinal)
		check(travel_cues.call().size()==ordinal*2,
			"stage %d has no extra travel cue before the next transition"%ordinal)
		step(1.0)
		var sounds: Array = travel_cues.call()
		check(sounds.size()==(ordinal+1)*2 and sounds[-2]["key"]=="R_SM_HOANYOUNG"
			and sounds[-1]["key"]=="R_W_MOVING_ATK",
			"leaving stage %d requests exactly one original voice then one swing"%ordinal)
	check(game.view.player_actor.pose=="hundredswordfinish" and game.player["pos"]==POINT
		and game.player["z"]==0.0 and game.player["facing"]==1,"stage 24 goes directly into the original grounded finish")
	check(actor.body_rotation==0.0 and actor.equipment_layers.all(func(layer):return layer.visible)
		and actor.get_meta("native_cast_layers",{}).values().all(func(layer):return not layer.visible),
		"the finish clears travel tilt and sword layers and restores the equipped weapon")
	# Use the large room coordinate that crosses an integer only after the native f32 stores.
	game.player["pos"] = Vector2(2000,POINT.y)
	step(560.0)
	step(9.0)
	var precision_tip = game.view.object_views.get("hundred_sword:finish_tail:1:0:-1")
	check(precision_tip!=null and precision_tip.position.x==2338.0,
		"the right-facing finish trail rounds X to native f32 before converting to pixels")
	step(701.0)
	check(game.player["action"]=="" and not game.player.has("hundred_sword_cast"),
		"one press completes the full Hundred Sword state sequence and clears the cast")

func check_illusion_finish() -> void:
	var voices: Array = game.view.audio.variants["R_SM_HOANYOUNG"]
	check(game.view.audio.variants["HOANYOUNG_HIT"][0] is AudioStreamOggVorbis
		and game.view.audio.variants["HOANYOUNG_WAVE"][0] is AudioStreamOggVorbis and voices.size()==4
		and voices.all(func(voice):return voice is AudioStreamOggVorbis),
		"the original hit cue and all four repeat voices load as audio streams")
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"weaponmaster"})
	profile.command("numbers.skill_grant",{"id":"illusionslash","level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["illusionslash"]
	start_room("","katana",1,spec)
	session.set_skill_material_spender(func(_id: int,_amount: int):return true)
	game.clear_monsters()
	game.numeric_player.values["attack_speed"] = 1.0
	game.player["mp"] = 1000.0
	step(250.0)
	press(KEY_A)
	step(0.0)
	var opening_slash: Dictionary = game.objects[0]
	game.numeric_player.values["attack_speed"] = 2.0
	step(49.0)
	check(game.player["illusion_cast"]["animation_percent"]==100.0 and game.player["stage"]==0,
		"attack speed waits for the actor timer even if it changes during the opening slash")
	step(1.0)
	check(game.player["illusion_cast"]["animation_ms"]==48.0
		and game.player["illusion_cast"]["timeline"][3]["start_ms"]==72
		and opening_slash["timeline"][2]["start_ms"]==100,
		"the timer rescales body time without changing the object that was already spawned")
	step(23.0)
	check(game.player["stage"]==0,"the shortened opening slash still waits for body frame three")
	step(1.0)
	check(game.player["stage"]==2 and game.objects.size()==2
		and game.objects[1]["timeline"][2]["start_ms"]==48,
		"the next slash object receives the refreshed attack speed at creation")
	for sample: Array in [["katana",6,281,281,10,281,1.06,47],["katana",7,140,140,20,140,1.0,24],
			["beamsword",6,281,281,10,281,1.0,50],["beamsword",7,281,210,20,210,1.0,24],
			["club",0,281,0,10,281,1.0,50]]:
		var family: String = sample[0]
		var frame_ms := float(sample[7])
		spec["skills"]["blademastery"] = sample[1] if family == "katana" else 0
		spec["skills"]["lightswordmastery"] = sample[1] if family == "beamsword" else 0
		start_room("",family,1,spec)
		var spent: Array = []
		session.set_skill_material_spender(func(id: int,amount: int):
			spent.append([id,amount])
			return true)
		game.clear_monsters()
		game.numeric_player.values["attack_speed"] = sample[6]
		game.numeric_player.values["hit"] = 1.0
		game.player["mp"] = 1000.0
		press(KEY_A)
		step(0)
		check(spent==[[3037,2]] and cues("SM_HOANYOUNG_START").size()==1,
			"the entry uses the original two cubes and start voice")
		if family == "katana":
			var melee_target: Dictionary = api.spawn_dummy(POINT+Vector2(95,0))
			var melee: Dictionary = game.objects[0]
			var before := frame_ms*2.0-1.0
			game.step_objects(before)
			check(game.hit_count==0 and melee["pos"]==POINT+Vector2(int(before*0.2),1) and melee["z"]==1.0,
				"the melee object advances on the original particle axis and its first two frames are blank")
			game.step_objects(1.0)
			check(game.hit_count==1 and melee["hits"].has(melee_target["id"]) and cues("R_SQUARESWDC_HIT").size()==1
				and cues("HOANYOUNG_WAVE").size()==1 and game.object_view_clock(melee)==100.0,
				"the melee object uses the actor rate for its first attack frame and presents that same frame")
			game.clear_monsters()
			game.hit_count = 0
		var slash_order := [0,2,1,3,2,0,3,1]
		var melee_percent: int = sample[5]
		for slash: int in int(sample[4]):
			var slot: int = slash_order[slash%slash_order.size()]
			var contact: Dictionary = game.objects.back()
			check(game.player["stage"]==slot and contact["def"]["path"].ends_with("/illusionslashmelee%d.obj"%(slot+1))
				and contact["hit"]["percent"]==melee_percent,"the original order selects the corresponding melee object and damage")
			var remaining := frame_ms*(2.0 if slash == 0 else 3.0)
			step(remaining-1.0)
			check(game.player["stage"]==slot,"the next slash waits for body frame three")
			step(1.0)
		check(game.player["stage"]==4 and cues("R_SM_HOANYOUNG").size()==int(sample[4])-1,
			"the minimum slash count completes automatically with a repeat voice after each transition")
		if family == "katana" and int(sample[1]) == 7:
			game.step_objects(344.0)
			check(not game.objects.is_empty(),"the mastered melee object still has its animation tail at 344 ms")
			game.step_objects(1.0)
			check(game.objects.is_empty(),"the mastered melee object retires at the sum of individually truncated frames")
		game.step_objects(1000.0)
		var finish: Dictionary = game.action_def()
		var direct: Array = finish["hits"].filter(func(hit):return hit["kind"]=="boxes")
		check(finish["ani"]=="illusionslashfinal" and direct.size()==(1 if family == "club" else 2),
			"the finisher selects the original weapon tracks")
		if direct.is_empty():continue
		check(direct[0]["percent"]==sample[2] and direct[0]["atk_path"].ends_with("/illusionslashupper.atk")
			and direct[0]["atk"]["lift_up"]==300,"the uppercut uses the first rank column and original attack record")
		if direct.size()==2:
			check(direct[1]["percent"]==sample[3] and direct[1]["atk_path"].ends_with("/illusionslashsmash.atk")
				and direct[1]["atk"]["lift_up"]==50,"the smash installs its own attack record and mastery scale")
		var near: Dictionary = api.spawn_dummy(POINT+Vector2(55,0))
		var far: Dictionary = game.spawn_enemy(POINT+Vector2(118,0))
		near["hp"] = 50000.0
		far["hp"] = 50000.0
		step(frame_ms*2.0-1.0)
		check(game.hit_count==0 and game.attack_body_armor(),"the armored first two frames do not borrow a visual rectangle")
		step(1)
		check(game.hit_count==1 and game.player["stuck_ms"]==40.0 and far["hp"]==50000.0,
			"frame two hits with the narrow uppercut weapon box and original hitstop")
		game.player["stuck_ms"] = 0.0
		move_target(near,POINT+Vector2(55,0))
		near["invuln_ms"] = 0.0
		step(frame_ms*3.0)
		check(game.hit_count==(2 if family == "club" else 1) and cues("SM_HOANYOUNG_FIN").is_empty(),
			"only the club C layer reaches the target on frame five, before the finishing voice")
		check(game.objects.is_empty(),"the sword wave has not spawned before the smash frame")
		var wave_id: int = game._next_entity_id
		step(frame_ms)
		check(game.hit_count==(2 if family == "club" else 3)
			and cues("skillfx_upper_4c1c9ad1").filter(func(cue):return cue["action_clock_at"]==100.0).size()==1
			and cues("skillfx_smash_c789bbe3").filter(func(cue):return cue["action_clock_at"]==300.0).size()==1
			and cues("SM_HOANYOUNG_FIN").size()==1 and spent==[[3037,2]],
			"frame six switches attack records and attaches the second original effect")
		check(game.objects.size()==1 and game.objects[0]["def"]["path"].ends_with("/illusionslashwave.obj"),
			"frame six dispatches exactly one sword wave")
		check(game.objects[0]["pos"]==POINT+Vector2(65,0) and game.objects[0]["hit"]["percent"]==421.0,
			"the neutral finisher uses the original forward offset and lower damage column")
		game.clear_monsters()
		var wave_target: Dictionary = api.spawn_dummy(POINT+Vector2(70,0))
		game.step_objects(50.0,wave_id)
		check(game.objects.size()==1 and game.objects[0]["clock"]==0.0,
			"the wave begins at animation time zero on its creation update")
		check(game.objects.size()==1 and game.objects[0]["hits"].has(wave_target["id"])
			and cues("HOANYOUNG_HIT").size()==1 and game.table.assets["audio"].has("HOANYOUNG_HIT"),
			"a sword-wave contact plays the hit cue from its original attack record")
		var hit_fx: Array = cues("illusion_wave_hit")
		check(hit_fx.size()==1 and hit_fx[0]["point"].y==wave_target["pos"].y and absf(float(hit_fx[0]["angle"]))<=0.801,
			"the wave creates its own angled impact animation at the target's ground depth")
		if family == "katana" and int(sample[1]) == 6:
			var wave: Dictionary = game.objects[0]
			for count: int in range(1,4):
				move_target(wave_target,Vector2(wave["pos"])+Vector2(70,0))
				wave_target["invuln_ms"] = 0.0
				game.step_objects(124.0)
				check(cues("HOANYOUNG_HIT").size()==count,"the ledger holds until the original interval expires")
				game.step_objects(1.0)
				check(cues("HOANYOUNG_HIT").size()==count+1,"each elapsed interval allows one new contact")
			game.step_objects(124.0)
			check(game.objects.size()==1 and wave["pos"]==POINT+Vector2(314,0)
				and cues("HOANYOUNG_HIT").size()==4,"the neutral wave moves at 500 units per second and has four contacts")
			game.view.present(game.view_snapshot(),0.0,0.0)
			var trails: Array = game.view.effects.filter(func(effect):return effect.has_meta("source_ptl") \
				and String(effect.get_meta("source_ptl")).ends_with("/illusionslash.ptl"))
			check(not trails.is_empty(),"the object view emits the original wave trail")
			game.step_objects(1.0)
			check(game.objects.is_empty(),"the wave expires at its original 500 ms lifetime")
	spec["skills"]["blademastery"] = 7
	start_room("","katana",1,spec)
	session.set_skill_material_spender(func(_id: int,_amount: int):return true)
	game.clear_monsters()
	game.numeric_player.values["attack_speed"] = 1.0
	game.player["mp"] = 1000.0
	press(KEY_A)
	step(0)
	var slash_count := 1
	for update: int in 100:
		if int(game.player["stage"]) == 4:break
		var previous: int = game.player["stage"]
		press(KEY_X if update%2 == 0 else KEY_A)
		step(50.0)
		if int(game.player["stage"]) != previous and int(game.player["stage"]) < 4:slash_count += 1
	check(game.player["stage"]==4 and slash_count==24 and game.player["illusion_cast"]["wave_ratio"]==100,
		"rapid attack and shortcut inputs reach the original katana mastery limit and full wave charge")
	game.step_objects(1000.0)
	step(300.0)
	check(game.objects.size()==1 and game.objects[0]["hit"]["percent"]==506.0
		and game.objects[0]["life_ms"]==800 and game.objects[0]["next_hit_reset"]==160.0
		and game.objects[0]["hit_resets_left"]==4,
		"the fully charged wave uses the upper damage, lifetime and contact limits")
	for sample: Array in [[6,1,KEY_DOWN,500,125,3,"illusion_wave_bottom1",20],
			[7,-1,KEY_UP,600,60,9,"illusion_wave_bottom2",70]]:
		spec["skills"]["shortswordmastery"] = sample[0]
		var facing: int = sample[1]
		start_room("","shortsword",facing,spec)
		session.set_skill_material_spender(func(_id: int,_amount: int):return true)
		game.clear_monsters()
		game.numeric_player.values["attack_speed"] = 1.0
		game.player["mp"] = 1000.0
		press(KEY_A)
		step(100)
		for slash: int in 9:step(150)
		check(game.player["stage"]==4,"the short sword automatically reaches the finisher")
		game.step_objects(1000.0)
		session.submit_key(int(sample[2]),true)
		step(300.0)
		session.submit_key(int(sample[2]),false)
		var wave: Dictionary = game.objects[0]
		var visible: Array = game.view_snapshot()["objects"]
		check(wave["life_ms"]==sample[3] and wave["next_hit_reset"]==sample[4]
			and wave["hit_resets_left"]==sample[5],
			"only rank seven short sword mastery replaces wave lifetime and contact columns")
		check(visible[1]["effect"]==sample[6] and visible[0]["particle_trail"]["offset"]==Vector2(facing*int(sample[7]),-1),
			"the direction selects the original lower layer and moving trail anchor")
		game.step_objects(200.0)
		check(wave["pos"]==POINT+Vector2(facing*151,facing*14),
			"the original angle and 29 percent depth projection turn the wave without mirroring depth")
	for sample: Array in [[6,1,0],[7,1,3220],[8,-1,3427]]:
		spec["skills"]["bluntmastery"] = sample[0]
		var facing: int = sample[1]
		start_room("","club",facing,spec)
		session.set_skill_material_spender(func(_id: int,_amount: int):return true)
		game.clear_monsters()
		game.numeric_player.values["attack_speed"] = 1.0
		game.numeric_player.values["hit"] = 1.0
		game.player["mp"] = 1000.0
		game.player["pos"] = POINT+Vector2(0.75,0.75)
		press(KEY_A)
		step(100)
		for slash: int in 9:step(150)
		game.step_objects(1000.0)
		step(299.0)
		var before_shake: Array = game.bus.events_of("combat.cue").filter(func(cue):return cue["kind"]=="screen_shake")
		check(game.player["stage"]==4 and game.objects.is_empty(),"the club branch also waits until the smash frame")
		check(before_shake.is_empty(),"the club shake does not start one frame early")
		var first_new_id: int = game._next_entity_id
		step(1.0)
		var shakes: Array = game.bus.events_of("combat.cue").filter(func(cue):return cue["kind"]=="screen_shake")
		check(game.objects.size()==1,"the club finisher emits a single object")
		if game.objects.is_empty():continue
		var wave: Dictionary = game.objects[0]
		if int(sample[2])==0:
			check(wave["def"]["path"].ends_with("/illusionslashwave.obj") and shakes.is_empty(),
				"rank six keeps the original default wave without the ground-wave shake")
			continue
		check(shakes.size()==1 and shakes[0]["degree"]==3 and shakes[0]["duration_ms"]==300
			and game.view._shake_remaining_ms==300.0,"the mastered ground wave starts the original room shake at dispatch")
		var controller: Dictionary = wave["hit"]["native_controller"]
		var origin := POINT+Vector2(facing*180,0)
		check(wave["def"]["path"].ends_with("/illusionslashsub.obj") and wave["pos"]==origin
			and wave["hit"]["percent"]==sample[2] and wave["hit"]["atk"]["lift_up"]==250
			and wave["hit"]["atk"]["push_aside"]==100,
			"mastered club dispatches the stationary object at mirrored offset 180 with its own rank and ATK")
		var visible: Array = game.view_snapshot()["objects"]
		check(visible.size()==2 and visible[0]["effect"]==controller["attached"]
			and visible[1]["depth_offset"]==-1,
			"the original earth layer accompanies the bottom-layer object")
		for key: String in controller["detached"]:
			check(cues(key).size()==1 and cues(key)[0]["point"]==origin,
				"the four original draw-only layers start at the same ground point")
		var victim: Dictionary = api.spawn_dummy(origin)
		victim["hp"] = 50000.0
		game.step_objects(16.0,first_new_id)
		var debris: Array = game.bus.events_of("combat.cue").filter(func(event):return event.get("path","")==controller["particle"])
		check(wave["clock"]==0.0 and wave["hits"].has(victim["id"]) and game.hit_count==1
			and cues("R_SQUARESWDC_HIT").size()==1 and victim["state"]=="air" and victim["stuck_ms"]==40.0,
			"the ground object knocks down at frame zero using the original impact cue")
		check(debris.size()==1 and debris[0]["point"]==origin,"the first object update emits one original stone burst")
		game.view.present(game.view_snapshot(),0.0,0.0)
		check(game.view.effects.any(func(effect):return effect.has_meta("source_ptl") \
			and effect.get_meta("source_ptl")==controller["particle"]),
			"the original stone particle sprites load into the battle view")
		game.step_objects(560.0)
		var late: Dictionary = api.spawn_dummy(origin)
		game.step_objects(79.0)
		check(game.objects.size()==1 and wave["pos"]==origin and not wave["hits"].has(late["id"]),
			"the ground wave stays in place, and its final frame has no attack box")
		game.step_objects(1.0)
		check(game.objects.is_empty() and game.hit_count==1,"the ground object retires at 640 ms without reopening its hit ledger")
	for interrupted: bool in [true,false]:
		spec["skills"]["bluntmastery"] = 0
		start_room("","club",1,spec)
		session.set_skill_material_spender(func(_id: int,_amount: int):return true)
		game.clear_monsters()
		game.numeric_player.values["attack_speed"] = 1.0
		game.numeric_player.values["cooldown_rate"] = 0.8
		game.player["mp"] = 1000.0
		press(KEY_A)
		step(0)
		check(is_equal_approx(float(game.player["cooldowns"].get("illusionslash",0)),36.0),
			"the original skill cooldown starts at entry using the current cooldown rate")
		game.step_game(100.0)
		check(game.objects.size()==2,"a repeated slash preserves the previous melee object while state 40 continues")
		if interrupted:
			var strike: Dictionary = game.objects[0]["hit"].duplicate()
			strike.erase("native_controller")
			strike.erase("ptl_motion")
			strike["object"] = "passiveobject/character/swordman/illusionslashwave.obj"
			strike["offset"] = Vector3.ZERO
			strike["skill_id"] = ""
			var enemy: Dictionary = game.spawn_enemy(POINT+Vector2(80,0))
			enemy["numeric"].values["hit"] = 1.0
			var hostile: Dictionary = game.spawn_object(strike,"monster",enemy["pos"],0.0,-1,100.0,enemy)
			game.step_objects(0.0)
			check(game.player["action"]=="" and game.objects==[hostile] and game.hit_count==0,
				"a hostile object can interrupt safely during the object update and cancel all owned melee contacts")
		else:
			for slash: int in 9:step(150.0)
			step(300.0)
			var released_wave: Dictionary = game.objects.back()
			step(640.0)
			var visible: Array = game.view_snapshot()["objects"]
			check(game.player["action"]=="" and visible.size()==2 and visible[0]["id"]==released_wave["id"],
				"normal exit hides old melee objects immediately and leaves the released wave visible")
			game.step_objects(0.0)
			check(game.objects==[released_wave],"the next object update keeps only the independent wave")
		check(is_equal_approx(float(game.player["cooldowns"].get("illusionslash",0)),35.9),
			"neither normal exit nor interruption resets the running cooldown")

func check_rapid_move_slash() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"weaponmaster"})
	profile.command("numbers.skill_grant",{"id":"rapidmoveslash","level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["rapidmoveslash"]
	for rank: int in [3,4]:
		spec["skills"]["weapon_mastery_up"] = 1
		spec["skills"]["shortswordmastery"] = rank
		start_room("original_27000","shortsword",1,spec)
		game.clear_monsters()
		game.numeric_player.values["attack_speed"] = 1.0
		game.numeric_player.values["hit"] = 1.0
		game.numeric_player.values["mp_cost_rate"] = 0.8
		game.numeric_player.values["cooldown_rate"] = 0.75
		game.player["mp"] = 200.0
		var payments: Array = []
		session.set_skill_material_spender(func(id: int,amount: int):
			payments.append([id,amount])
			return true)
		var target: Dictionary = api.spawn_dummy(POINT+Vector2(45,0))
		target["hp"] = 50000.0
		var move: Dictionary = game.move_def("rapidmoveslash")
		var count := 4 if rank == 3 else 5
		check(game.skill_levels["shortswordmastery"]==rank+3 and move["stages"].size()==2*count,
			"the effective short sword rank crosses the native extra slash gate")
		press(KEY_A)
		step(159)
		check(game.player["stage"]==0 and game.player["pos"]==POINT and game.hit_count==0 and payments==[[3037,1]],
			"Rapid Move Slash preparation stays still and deals no damage after the original cube payment")
		check(game.player["mp"]==180.0 and not game.player["cooldowns"].has("rapidmoveslash"),
			"starting state 39 pays the modified rank-one MP and waits to start cooldown")
		check(cues("SM_MENGRYONG_START").size()==1,"Rapid Move Slash preparation plays the start voice")
		step(1)
		var opener: Dictionary = game.action_def()["hits"][0]
		check(game.player["stage"]==1 and game.hit_count==1 and opener["percent"]==265.0
			and opener["atk_path"].ends_with("/rapidmoveslash1.atk"),
			"the ready ANI advances to a first-frame weapon hit without a second press")
		check(game.player["mp"]==180.0,"an automatic transition does not charge MP")
		check(game.player["stuck_ms"]==15.0 and target["stuck_ms"]==15.0 and cues("JAKYEOL_HIT").size()==1
			and cues("MENGRYOUNG_ATK").size()==1 and cues("rapid_move_slash_dust").size()==1,
			"the opening contact and dash use the original pause and audio/dust cues")
		var layers: Array = game.action_def()["fx"]
		check(layers.size()==3 and layers.map(func(layer):return int(layer["depth_offset"]))==[4,5,6]
			and is_equal_approx(layers[1]["scale"],0.85)
			and layers.all(func(layer):return cues(layer["key"]).size()==1),
			"the regular slash mounts the three registered layers with the short sword scale")
		game.player["stuck_ms"] = 0.0
		move_target(target,POINT+Vector2(220,0))
		target["invuln_ms"] = 0.0
		step(100)
		check(is_equal_approx(game.player["pos"].x,POINT.x+175.0),
			"Rapid Move Slash integrates the original 2000 velocity and -5000 deceleration")
		check(game.hit_count==1,"the same target cannot be hit again on the next overlapping weapon frame")
		game.clear_monsters()
		press(KEY_A)
		step(99)
		check(game.player["stage"]==1 and game.player["mp"]==180.0,"an early repeat neither skips frame two nor pays MP")
		for slash in range(1,count):
			step(1 if slash==1 else 200)
			press(KEY_A)
			step(0)
			check(game.player["stage"]==2*slash,"a valid repeat starts the next ready phase")
			if slash == count-1:
				var victim: Dictionary = api.spawn_dummy(Vector2(game.player["pos"])+Vector2(20,0))
				victim["hp"] = 50000.0
			step(160)
			check(game.player["stage"]==2*slash+1,"the next ready phase automatically slashes")
			check(game.player["mp"]==180.0-20.0*slash and payments==[[3037,1]]
				and not game.player["cooldowns"].has("rapidmoveslash"),
				"a successful repeat pays only MP and keeps cooldown off through the automatic slash")
		var finisher: Dictionary = game.action_def()["hits"][0]
		check(finisher["percent"]==529.0 and finisher["atk_path"].ends_with("/rapidmoveslash2.atk")
			and finisher["atk"]["lift_up"]==400 and cues("SM_MENGRYONG_FIN").size()==1,
			"the final ordinal installs the original launch ATK, rank column and final voice")
		check(game.hit_count==2 and game.bus.events_of("combat.damage")[-1]["reaction"]=="launch"
			and is_equal_approx(game.action_def()["fx"][1]["scale"],0.77),
			"the final weapon contact launches and applies the short sword finisher scale")
		game.player["stuck_ms"] = 0.0
		game.clear_monsters()
		press(KEY_A)
		step(200)
		check(game.player["stage"]==2*count-1 and game.player["mp"]==200.0-20.0*count,
			"the final ordinal ignores additional input without spending MP")
		step(300)
		check(game.player["action"]=="" and game.player["cooldowns"]["rapidmoveslash"]==15.0,
			"final recovery starts the full source cooldown with the actor modifier")

func check_rapid_move_slash_shock() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"weaponmaster"})
	profile.command("numbers.skill_grant",{"id":"rapidmoveslash","level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["rapidmoveslash"]
	for sample: Array in [["beamsword",0,9,9],["beamsword",1,6,8],["katana",1,7,9],["beamsword",1,7,9]]:
		var family: String = sample[0]
		spec["skills"]["weapon_mastery_up"] = sample[1]
		spec["skills"]["lightswordmastery"] = sample[2]
		start_room("",family,1,spec)
		var enabled: bool = family == "beamsword" and int(sample[1]) > 0 and int(sample[3]) >= 9
		check(game.weapon==family and game.skill_levels["lightswordmastery"]==sample[3]
			and game.move_def("rapidmoveslash").has("rapid_shock")==enabled,
			"the public room applies the source weapon, Oath and effective rank gate "+str(sample))
		if not enabled:continue
		session.set_skill_material_spender(func(_id: int,_amount: int):return true)
		game.clear_monsters()
		game.numeric_player.values["attack_speed"] = 1.0
		game.numeric_player.values["hit"] = 1.0
		game.player["mp"] = 500.0
		var target: Dictionary = api.spawn_dummy(POINT+Vector2(20,0))
		var resistant: Dictionary = game.spawn_enemy(POINT+Vector2(25,0))
		for victim: Dictionary in [target,resistant]:
			victim["hp"] = 50000.0
			victim["numeric"].values["level"] = 47
			victim["numeric"].values["lightning_resistance"] = -400 if victim == target else 100
			victim["numeric"].values["abnormal_resistance"] = 0
		press(KEY_A)
		step(159)
		check(game.hit_count==0 and game.action_def()["hits"].is_empty(),"the ready pose cannot apply Rapid Move Slash lightning")
		step(1)
		var hit: Dictionary = game.action_def()["hits"][0]
		var shock: Dictionary = hit["effects"][0]
		check(is_equal_approx(shock["chance"],0.294) and shock["status_level"]==47 and shock["source_shock_amount"]==347,
			"effective mastery nine uses the original Rapid Move Slash columns and level 60 base")
		check(target["numeric"].effects.active.get("shock",{}).get("source_shock",[])==[{"remaining_ms":9197.0,"amount":347,"hits_left":19}]
			and not resistant["numeric"].effects.active.has("shock"),
			"first contact installs lightning without consuming it and respects lightning resistance")
		for ordinal: int in range(1,4):
			game.player["stuck_ms"] = 0.0
			step(200)
			press(KEY_A)
			step(0)
			move_target(target,Vector2(game.player["pos"])+Vector2(20,0))
			target["invuln_ms"] = 0.0
			step(160)
		var instances: Array = target["numeric"].effects.active.get("shock",{}).get("source_shock",[])
		var triggers: Array = game.bus.events_of("combat.damage").filter(func(event):return event.get("status","")=="shock")
		check(game.player["stage"]==7 and instances.size()==4 and triggers.size()==3
			and instances[0]["hits_left"]==16 and instances[-1]["hits_left"]==19,
			"each continued slash and the finisher trigger existing lightning and install one fresh entry")
		check(game.table.moves["rapidmoveslash"]["stages"][1]["hits"][0]["effects"].is_empty(),
			"live lightning installation leaves reusable move templates intact")

func check_rapid_move_slash_fee_failure() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"weaponmaster"})
	profile.command("numbers.skill_grant",{"id":"rapidmoveslash","level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["rapidmoveslash"]
	for interrupted: bool in [false,true]:
		start_room("original_27601","katana",1,spec)
		game.clear_monsters()
		game.numeric_player.values["attack_speed"] = 1.0
		game.numeric_player.values["mp_cost_rate"] = 1.0
		game.numeric_player.values["cooldown_rate"] = 1.0
		game.player["mp"] = 24.0
		var payments: Array = []
		session.set_skill_material_spender(func(id: int,amount: int):
			payments.append([id,amount])
			return false)
		press(KEY_A)
		step(0)
		check(game.player["action"]=="" and payments.is_empty() and game.player["mp"]==24.0,
			"an opening MP failure does not attempt material payment")
		game.player["mp"] = 25.0
		press(KEY_A)
		step(0)
		check(game.player["action"]=="" and payments==[[3037,1]] and game.player["mp"]==25.0
			and not game.player["cooldowns"].has("rapidmoveslash"),
			"an opening material failure leaves MP and cooldown unchanged")
		session.set_skill_material_spender(func(id: int,amount: int):
			payments.append([id,amount])
			return true)
		press(KEY_A)
		step(0)
		check(game.player["action"]=="rapidmoveslash" and game.player["mp"]==0.0,
			"MP exactly equal to the opening cost is accepted")
		if interrupted:
			game.hurt_player(1,{"pos":POINT+Vector2(40,0)},{},-1)
		else:
			step(160)
			step(200)
			press(KEY_A)
			step(0)
			var rejected: Array = game.bus.events_of("combat.action_rejected")
			check(game.player["stage"]==1 and game.player["mp"]==0.0 and rejected[-1]["reason"]=="mp"
				and not game.player["cooldowns"].has("rapidmoveslash"),
				"an unaffordable repeat leaves the current slash and does not start cooldown early")
			step(300)
		check(game.player["action"]=="" and game.player["cooldowns"]["rapidmoveslash"]==20.0
			and game.player["mp"]==0.0 and payments==[[3037,1],[3037,1]],
			"interruption or natural exit starts the cooldown without another payment")

func check_rapid_move_slash_depth() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"weaponmaster"})
	profile.command("numbers.skill_grant",{"id":"rapidmoveslash","level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["rapidmoveslash"]
	for sample: Array in [[1,KEY_DOWN,1.0,1],[-1,KEY_UP,1.25,-1],[1,KEY_UP,1.0,0]]:
		start_room("original_27601","katana",sample[0],spec)
		session.set_skill_material_spender(func(_id: int,_amount: int):return true)
		game.clear_monsters()
		var rate: float = sample[2]
		var depth: int = sample[3]
		game.numeric_player.values["attack_speed"] = rate
		game.room_map = game.room_map.duplicate(true)
		for row: Array in game.room_map["walk_grid"]:row.fill(0)
		press(KEY_A)
		step(159.0/rate)
		session.submit_key(sample[1],true)
		check(game.player["pos"]==POINT,"Rapid Move Slash stays still while reading the ready animation")
		if depth == 0:session.submit_key(sample[1],false)
		step(1.0/rate)
		check(game.player["stage"]==1,"the ready boundary samples the depth input")
		session.submit_key(sample[1],false)
		var opposite := KEY_UP if sample[1] == KEY_DOWN else KEY_DOWN
		session.submit_key(opposite,true)
		step(100)
		check(Vector2(game.player["pos"]).is_equal_approx(POINT+Vector2(175*rate*int(sample[0]),25*rate*depth)),
			"Rapid Move Slash keeps its initial depth direction after a key change "+str(sample))
		step(201)
		check(is_equal_approx(float(game.player["pos"].y),POINT.y+45*rate*depth),
			"the original depth axis stops at 300 ms independently of the body and horizontal motion")
		press(KEY_A)
		step(0)
		var next_origin: Vector2 = game.player["pos"]
		step(161.0/rate)
		step(100)
		var next_depth := -1 if opposite == KEY_UP else 1
		check(game.player["stage"]==3 and is_equal_approx(float(game.player["pos"].y),next_origin.y+25*rate*next_depth),
			"the next slash re-reads depth at the end of its own ready phase")
		session.submit_key(opposite,false)

	for blocked_axis: int in 2:
		start_room("original_27601","katana",1,spec)
		session.set_skill_material_spender(func(_id: int,_amount: int):return true)
		game.clear_monsters()
		game.numeric_player.values["attack_speed"] = 1.0
		game.room_map = game.room_map.duplicate(true)
		var grid: Dictionary = game.map_loader.constants()
		var span := int(grid["cell_width"] if blocked_axis == 0 else grid["cell_height"])
		var wall := floori(POINT[blocked_axis]/span)+1
		var walk_grid: Array = game.room_map["walk_grid"]
		for row: Array in walk_grid:
			row.fill(0)
			if blocked_axis == 0:row[wall] = 1
		if blocked_axis == 1:walk_grid[wall].fill(1)
		var start := POINT
		start[blocked_axis] = wall*span-2
		game.player["pos"] = start
		session.submit_key(KEY_DOWN,true)
		press(KEY_A)
		step(160)
		step(100)
		var expected := start+Vector2(175,25)
		expected[blocked_axis] = wall*span-1
		check(game.player["pos"]==expected,"blocking one axis leaves it on the last clear pixel while the other continues")
		session.submit_key(KEY_DOWN,false)

func check_charge_crash_uppercut() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"weaponmaster"})
	profile.command("numbers.skill_grant",{"id":"charge_crash","level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["charge_crash"]
	for rate: float in [1.0,1.25]:
		var facing := 1 if rate == 1.0 else -1
		start_room("original_27000","shortsword",facing,spec)
		game.clear_monsters()
		game.numeric_player.values["attack_speed"] = rate
		press(KEY_A)
		step(0)
		check(game.player["action"]=="charge_crash" and game.player["stage"]==0,
			"one shortcut press starts Charge Crash with the dash")
		var dash_end: float = game.action_duration("charge_crash")/rate
		var voice := cues("SM_CHARGE_CRASH")
		var motion := cues("CCRASH_MOVING")
		check(voice.size()==1 and motion.size()==1 and voice[0]["event_id"]<motion[0]["event_id"],
			"the dash plays its original voice followed by the motion cue once")
		var dash: Array = game.view.effects.filter(func(fx):return fx.cue_key=="charge_dash")
		var dust: Array = game.view.effects.filter(func(fx):return fx.cue_key=="charge_dash_dust")
		check(dash.size()==1 and dust.size()==1 and dash[0].z_index==int(POINT.y)+1
			and dust[0].z_index==int(POINT.y)+2 and dash[0].facing==facing and dust[0].facing==facing,
			"the dash starts the original streak and dust with their separate attachment depths")
		step(80.0/rate)
		check(dash.size()==1 and dust.size()==1 and dash[0].frame["frame"]==1 and dust[0].frame["frame"]==1
			and dash[0].position==game.view.player_actor.position and dust[0].position==game.view.player_actor.position,
			"dash attachments follow the actor and advance at the same action rate")
		var expected_dash := 51.2 if rate == 1.0 else 52.16
		check(Vector2(game.player["pos"]).is_equal_approx(POINT+Vector2(expected_dash*facing,0)),
			"the dash integrates attack-speed-adjusted force on its own clock")
		step(dash_end-80.0/rate-1.0)
		check(game.player["stage"]==0 and cues("SM_CHARGE_CRASH_UP").is_empty(),
			"the uppercut stays silent before the dash ANI finishes")
		check(game.view.effects.all(func(fx):return fx.cue_key not in ["charge_dash","charge_dash_dust"]),
			"the dash streak and dust finish before the dash body ANI")
		var mp: float = game.player["mp"]
		step(1)
		check(game.player["stage"]==1 and game.view.player_actor.pose=="chargecrashupper"
			and cues("SM_CHARGE_CRASH_UP").size()==1 and game.player["mp"]==mp,
			"the uppercut plays automatically with its own voice and no second payment")
		var upper_x: float = game.player["pos"].x
		var expected_end := 153.125 if rate == 1.0 else 171.5
		check(is_equal_approx(upper_x,POINT.x+expected_end*facing),"dash movement is clipped at the phase boundary")
		step(20)
		check(game.player["pos"].x==upper_x and cues("SM_CHARGE_CRASH_UP").size()==1,
			"uppercut does not repeat the dash movement or its entry voice")
		step(30.0/rate-21.0)
		check(cues("charge_upper").is_empty(),"the uppercut has no blade effect in body frame zero")
		step(1)
		var upper: Array = game.view.effects.filter(func(fx):return fx.cue_key=="charge_upper")
		check(upper.size()==1 and upper[0].frame["frame"]==0 and upper[0].clock_ms==0.0
			and upper[0].z_index==int(POINT.y)+1 and upper[0].facing==facing,
			"body frame one attaches the uppercut blade once at its native depth")
		step(60.0/rate)
		check(cues("charge_upper").size()==1 and upper.size()==1 and upper[0].frame["frame"]==1,
			"uppercut blade advances from its own birth frame at the action rate")
		step(240.0/rate)
		check(game.player["action"]=="charge_crash" and game.view.effects.all(func(fx):return fx.cue_key!="charge_upper"),
			"the uppercut blade ends on its own ANI while the body is still recovering")
		for key in ["SM_CHARGE_CRASH","CCRASH_MOVING","SM_CHARGE_CRASH_UP"]:
			var streams: Array = game.view.audio.variants.get(key,[])
			check(streams.size()==1 and streams[0] is AudioStreamOggVorbis,"original Charge Crash stream mounted for "+key)

	for rate: float in [0.5,1.0,1.25]:
		start_room("original_27000","shortsword",1,spec)
		game.numeric_player.values["attack_speed"] = rate
		game.numeric_player.values["hit"] = 1.0
		for enemy: Dictionary in game.monsters:move_target(enemy,POINT+Vector2(600,0))
		var target: Dictionary = game.monsters[0]
		var late_target: Dictionary = game.monsters[1]
		target["hp"] = 100000.0
		late_target["hp"] = 100000.0
		move_target(target,POINT+Vector2(35,0))
		press(KEY_A)
		step(0)
		check(game.hit_count==1,"the dash has an attack box from body frame zero")
		check(game.player["stuck_ms"]==30.0 and target["stuck_ms"]==30.0,"the dash uses its authored 30 ms hitstop on both sides")
		move_target(target,POINT+Vector2(110 if rate == 0.5 else 180,0))
		if rate == 0.5:
			step(301)
			check(game.hit_count==2,"a late dash update opens the elapsed rehit window once")
			step(298)
			check(game.hit_count==2,"the third dash hit cannot arrive before the original 600 ms deadline")
			step(1)
			check(game.hit_count==3,"a late update does not shift subsequent dash rehit deadlines")
			step(99)
		elif rate == 1.0:
			step(299)
			check(game.hit_count==1,"a dash target cannot be hit again before 300 ms")
			step(1)
			check(game.hit_count==2,"the same target is eligible again at 300 ms of dash time")
			step(49)
		else:
			step(279)
			check(game.hit_count==1,"attack speed does not accelerate the dash rehit timer")
		var dash_hits: int = game.hit_count
		move_target(late_target,Vector2(game.player["pos"])+Vector2(40,0))
		step(1)
		check(game.player["stage"]==1 and game.hit_count==dash_hits,
			"the expired dash body cannot contact a new target on the uppercut transition")
		move_target(late_target,POINT+Vector2(600,0))
		move_target(target,Vector2(game.player["pos"])+Vector2(40,0))
		step(60.0/rate-1.0)
		check(game.hit_count==dash_hits,"the uppercut cannot hit in its two opening frames")
		step(1)
		check(game.hit_count==dash_hits+1,"the uppercut can hit the dash target with its own ATK from frame two")
		check(game.player["stuck_ms"]==90.0 and target["stuck_ms"]==90.0,"the short-sword uppercut uses its weapon's 90 ms hitstop")
	start_room("original_27000","shortsword",1,spec)
	var target: Dictionary = api.spawn_dummy(POINT+Vector2(35,0))
	press(KEY_A)
	game.step_game(1.0)
	check(game.hit_count==1 and game.player["stuck_ms"]==30.0 and target["stuck_ms"]==30.0,
		"the integrated contact tick does not use up the target's new hitstop")

func check_charge_crash_body_armor() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"weaponmaster"})
	profile.command("numbers.skill_grant",{"id":"charge_crash","level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["charge_crash"]
	spec["skills"]["heavyswordmastery"] = 7
	var normal_atk: Dictionary = game.table.atk("character/swordman/attackinfo/attack1.atk")
	var piercing_atk := normal_atk.duplicate()
	piercing_atk["ignore_super_armor"] = 1
	for sample: Array in [[0,349.0,false,true],[1,339.0,false,true],
			[2,399.0,false,true],[2,399.0,true,false],[3,0.0,false,false]]:
		start_room("","greatsword",1,spec)
		game.clear_monsters()
		game.numeric_player.values["attack_speed"] = 1.0
		session.submit_key(KEY_A,true)
		step(0)
		if sample[0] >= 1:step(350)
		if sample[0] >= 2:step(340)
		if sample[0] == 3:step(400)
		step(sample[1])
		check(game.player["stage"]==sample[0],"Charge Crash reaches the expected body phase "+str(sample))
		var before_hp: float = game.player["hp"]
		var atk: Dictionary = piercing_atk if sample[2] else normal_atk
		var reaction: String = game.hurt_player(7,{"pos":game.player["pos"]+Vector2(50,0)},atk,-1)
		var armored: bool = sample[3]
		check(game.player["hp"]==before_hp-7,"Charge Crash body armor still takes incoming damage")
		check((reaction=="none" and game.player["action"]=="charge_crash") if armored
			else (reaction=="stagger" and game.player["action"]=="" and not game.player.has("charge_crash_hold")),
			"Charge Crash preserves only the original armored phases "+str(sample))
		check(cues("upper_armor_light").size()==int(armored),"Charge Crash body armor emits the native hit feedback")
		session.submit_key(KEY_A,false)
		if sample[0] == 2 and armored:
			game.player["invuln_ms"] = 0.0
			game.hurt_player(ceilf(game.player["hp"]),{"pos":game.player["pos"]+Vector2(50,0)},normal_atk,-1)
			check(game.player["state"]=="dead" and not game.player.has("charge_crash_hold"),
				"lethal damage clears the frozen Charge Crash hold even through body armor")

func check_charge_crash_mastery() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"weaponmaster"})
	profile.command("numbers.skill_grant",{"id":"charge_crash","level":1})
	for sample: Array in [["greatsword",6,7,true,1.0,false], ["club",7,6,true,1.0,false],
			["greatsword",7,6,false,1.0,false], ["greatsword",7,6,true,1.0,false],
			["greatsword",7,6,true,1.0,true], ["club",6,7,true,1.25,false], ["club",6,7,true,1.25,true]]:
		var family: String = sample[0]
		var heavy := family == "greatsword"
		var full: bool = sample[5]
		var spec := profile.stats()
		spec["skill_slots"] = ["charge_crash"]
		spec["skills"]["heavyswordmastery"] = sample[1]
		spec["skills"]["bluntmastery"] = sample[2]
		start_room("","greatsword" if heavy else "shortsword",1 if heavy else -1,spec)
		# The club logic fixture uses the current neutral body art.
		if not heavy:game.table.configure_skills(game.skill_levels,"weaponmaster","club")
		game.clear_monsters()
		var rate: float = sample[4]
		game.numeric_player.values["attack_speed"] = rate
		session.submit_key(KEY_A,true)
		if not sample[3]:session.submit_key(KEY_A,false)
		step(0)
		var mp: float = game.player["mp"]
		step(350.0/rate)
		step(340.0/rate-1.0)
		check(game.player["stage"]==1 and cues("CCRASH_GET").is_empty(),"mastery preparation waits until uppercut finishes")
		step(1)
		var charge_allowed: bool = sample[3] and int(sample[1 if heavy else 2])==7
		check(game.player.has("charge_crash_hold")==charge_allowed,"Charge Crash checks held input and the equipped family's mastery")
		if not charge_allowed:
			check(game.player["action"]=="" and cues("CCRASH_GET").is_empty(),"ineligible uppercut recovers without a downstroke")
			session.submit_key(KEY_A,false)
			continue
		var charge_fx := "skillfx_charge_623ff08a"
		var charge_layer: Array = game.view.effects.filter(func(fx):return fx.cue_key==charge_fx)
		check(charge_layer.size()==1 and charge_layer[0].follow_offset==Vector2(-55 if heavy else 55,-130)
			and charge_layer[0].uniform_frame_ms==33.0 and cues("CCRASH_GET").size()==1,
			"mastery preparation mounts the original offset and per-frame delay")
		step(33.0/rate)
		check(game.player_ani()==["chargecrashfinish",0.0] and charge_layer.size()==1 and charge_layer[0].frame["frame"]==1,
			"the body stays frozen while the original charge effect advances")
		var limit := 400.0/rate
		var targets: Array[Dictionary] = []
		var target_frame: Dictionary = {}
		var original_boxes: Array = []
		if not full:
			game.numeric_player.values["hit"] = 1.0
			for distance: int in [80,169,-70]:
				var target: Dictionary = game.spawn_enemy(Vector2(game.player["pos"])+Vector2(distance*int(game.player["facing"]),0))
				target["hp"] = 5000.0
				targets.append(target)
			target_frame = game.enemy_frame(targets[0])
			original_boxes = target_frame["damage_boxes"]
			target_frame["damage_boxes"] = [[0,0,0,1,1,1]]
			step((200.0-33.0)/rate)
			check(game.hit_count==0,"the frozen preparation pose has no downstroke hit")
			session.submit_key(KEY_A,false)
			step(0)
		else:
			step(limit-1.0-33.0/rate)
			check(game.player.has("charge_crash_hold") and game.objects.is_empty() and cues("CCRASH_CRASH").is_empty(),
				"the hold has no impact or wave through the tick before full charge")
			step(1)
			session.submit_key(KEY_A,false)
		check(game.player["stage"]==3 and game.player_ani()==["chargecrashfinish",240.0]
			and not game.player.has("charge_crash_hold") and game.player["mp"]==mp,
			"partial release and full charge both start at the original downstroke frame without paying again")
		var hit: Dictionary = game.action_def()["hits"][0]
		var percent: int = (498 if full else 293) if heavy else (118 if full else 88)
		check(hit["percent"]==percent,"downstroke reads the equipped mastery and actual hold time")
		var segments: Array = hit["segments"]
		check(hit["source"]=="attached_weapon" and segments.size()==1 and segments[0]["start"]==240.0
			and segments[0]["end"]==400.0,"the downstroke uses the equipped family's boxes on body frames three and four")
		var down_fx := "skillfx_down_slash_f79b50a7"
		var down_layers: Array = game.view.effects.filter(func(fx):return fx.cue_key==down_fx)
		check(down_layers.size()==1 and down_layers[0].follow_offset==Vector2(135 if heavy else -135,10)
			and game.view.effects.all(func(fx):return fx.cue_key!=charge_fx),"downstroke replaces the charge with the mirrored native effect")
		check(cues("SM_CHARGE_CRASH_DOWN").size()==1 and cues("JAKYEOL_SWING").size()==1 and cues("CCRASH_CRASH").size()==1,
			"the downstroke issues the original voice, swing and impact sounds once")
		var shake: Array = game.bus.events_of("combat.cue").filter(func(event):return event.get("kind","")=="screen_shake")
		check(shake.size()==1 and shake[0]["degree"]==8 and shake[0]["duration_ms"]==500,
			"the downstroke requests the original room shake")
		check(game.objects.size()==int(not heavy and full),"only a fully charged club downstroke spawns the shockwave")
		if not heavy and full and game.objects.size()==1:check_charge_crash_wave(game.objects[0])
		if not full:
			check(targets[0]["hp"]<5000.0 and targets[1]["hp"]==5000.0 and targets[2]["hp"]==5000.0,
				"the first downstroke frame hits in front without inheriting the effect's reach behind the actor")
			var stop := 120.0 if heavy else 100.0
			check(game.player["stuck_ms"]==stop and targets[0]["stuck_ms"]==stop,
				"the direct downstroke uses the equipped family's stop rather than the shockwave's stop")
			var initial_hp: float = targets[0]["hp"]
			step(79.0/rate)
			check(targets[1]["hp"]==5000.0,"the greatsword's longer second box cannot land one frame early")
			step(1.0/rate)
			check((targets[1]["hp"]<5000.0)==heavy and targets[0]["hp"]==initial_hp,
				"only the greatsword widens on the second frame and the current ATK cannot rehit a registered target")
			step(79.0/rate)
			move_target(targets[2],Vector2(game.player["pos"])+Vector2(80*int(game.player["facing"]),0))
			step(1.0/rate)
			check(targets[2]["hp"]==5000.0,"a new contact at the end of the weapon's second frame cannot land")
			target_frame["damage_boxes"] = original_boxes

func check_charge_crash_wave(wave: Dictionary) -> void:
	var origin: Vector2 = Vector2(Vector2i(game.player["pos"]))-Vector2(135,0)
	var id: int = wave["id"]
	check(wave["pos"]==origin and wave["z"]==0.0 and wave["facing"]==-1 and wave["clock"]==0.0,
		"the club wave uses mirrored native spawn offset and starts at age zero")
	check(wave["hit"]["fixed_amount"]==1363.0 and game.view.object_views.has(id),
		"rank seven snapshots its original fixed attack and mounts the front ANI")
	var a: Dictionary = api.spawn_dummy(origin+Vector2(15,0))
	var b: Dictionary = game.spawn_enemy(origin-Vector2(15,0))
	b["hp"] = 5000.0
	b["stuck_ms"] = 45.0
	game.step_objects(16,id)
	check(wave["clock"]==0.0 and wave["hits"].has(a["id"]) and wave["hits"].has(b["id"])
		and a["state"]=="air" and b["state"]=="air" and game.last_damage["trace"]["fixed_part"]==1363.0,
		"invisible frame zero reaches two targets with the independent ATK and upward knockdown")
	check(game.player["stuck_ms"]==0.0 and cues("FLAMES_HIT").size()==2,"wave contact uses its own hit sound without freezing the caster")
	check(a["stuck_ms"]==20.0 and b["stuck_ms"]==45.0,"the original wave requests 20 ms and preserves an existing longer pause")
	game.update_enemy(a,19.0)
	check(a["stuck_ms"]==1.0 and a["clock"]==0.0,"wave target remains paused through 19 ms")
	game.update_enemy(a,1.0)
	check(a["stuck_ms"]==0.0,"the wave target resumes at 20 ms")
	game.step_objects(100)
	game.view.present(game.view_snapshot(),0.0,0.0)
	check(game.view.object_views[id].frame["frame"]==1 and wave["hits"].size()==2 and cues("FLAMES_HIT").size()==2,
		"front ANI changes frame at 100 ms and the object remembers earlier contacts")
	var late: Dictionary = game.spawn_enemy(origin)
	game.step_objects(300)
	check(not wave["hits"].has(late["id"]),"the wave cannot hit once the fourth attack frame has ended")
	game.step_objects(100)
	game.view.present(game.view_snapshot(),0.0,0.0)
	check(game.objects.has(wave) and not game.view.object_views.has(id),"the front layer ends at 500 ms independently of the object")
	game.step_objects(299)
	check(game.objects.has(wave),"the shockwave object survives through 799 ms")
	game.step_objects(1)
	check(not game.objects.has(wave),"the shockwave object retires at the end of its 800 ms main ANI")

func check_draw_second_slash() -> void:
	for family: String in ["katana","beamsword"]:
		var blade := family == "katana"
		var mastery := "blademastery" if blade else "lightswordmastery"
		var item := "original_27601" if blade else ""
		var profile := ProfileSession.new()
		profile.command("numbers.level",{"level":60})
		profile.command("numbers.growtype",{"growtype":"weaponmaster"})
		profile.command("numbers.skill_grant",{"id":"draw","level":2})
		profile.command("numbers.skill_grant",{"id":mastery,"level":7})
		var spec := profile.stats()
		spec["skill_slots"] = ["draw"]
		# The production room has no light-sword appearance bank yet. Exercise its
		# source geometry and action in a room with the neutral body appearance.
		var mount := func():
			start_room(item,family if blade else "shortsword",1,spec)
			if not blade:game.table.configure_skills(game.skill_levels,"weaponmaster",family)
		spec["skills"]["weapon_mastery_up"] = 0
		mount.call()
		check(game.move_def("draw")["stages"].size()==1,"rank seven alone is below the Oath gate for "+family)
		spec["skills"]["weapon_mastery_up"] = 1
		spec["skills"][mastery] = 3 if blade else 4
		mount.call()
		check(game.skill_levels[mastery]==6 and game.move_def("draw")["stages"].size()==1,
			"effective mastery six does not open the second slash for "+family)
		spec["skills"][mastery] += 1
		mount.call()
		var spent: Array = []
		session.set_skill_material_spender(func(id: int, amount: int):
			spent.append([id,amount])
			return true)
		game.numeric_player.values["attack_speed"] = 1.0
		game.numeric_player.values["hit"] = 1.0
		for target: Dictionary in game.monsters:move_target(target,POINT+Vector2(1200,0))
		for index in 2:
			move_target(game.monsters[index],POINT+Vector2(125 if index==0 else -125,0))
			game.monsters[index]["hp"] = 10000.0
			game.monsters[index]["numeric"].values["level"] = 38
			game.monsters[index]["numeric"].values["bleeding_resistance"] = -100
			game.monsters[index]["numeric"].values["lightning_resistance"] = -100
		var move: Dictionary = game.move_def("draw")
		check(game.skill_levels[mastery]==7 and move["stages"].size()==2 and move["draw_second_slash_at"]==775.0,
			"effective mastery seven enables a second slash at body frame eight for "+family)
		if move["stages"].size()!=2:continue
		check(move["stages"][1]["hits"][0]["percent"]==(404.0 if blade else 248.0),
			"the second slash takes its attack percent from the equipped mastery")
		press(KEY_A)
		step(525)
		check_draw_slash_layers("blue",0)
		check(not game.monsters[0]["numeric"].effects.active.has("bleed"),"the opening contact does not apply the second slash's bleeding")
		check(not game.monsters[0]["numeric"].effects.active.has("shock"),"the opening contact does not apply the second slash's lightning")
		step(248)
		press(KEY_A)
		step(1)
		step(1)
		check(game.player["stage"]==0 and game.hit_count==2,"an early tap cannot carry into the second slash window")
		var paid_mp: float = game.player["mp"]
		var paid_cooldown: float = game.player["cooldowns"]["draw"]
		press(KEY_X if blade else KEY_A)
		step(0)
		check(game.player["stage"]==1 and game.player["clock"]==500.0
			and game.view.player_actor.pose=="momentaryslash" and game.view.player_actor.sample()["frame"]==1
			and cues("SM_BAL_READY").size()==2 and draw_slash_views().is_empty(),
			"the second slash restarts the original pose at frame one with its ready cue")
		check(game.action_def()["hits"][0]["percent"]==(494.0 if blade else 303.0) and game.hit_count==2,
			"two first-slash targets apply the native 225 per-mille bonus before the new hit window")
		step(24)
		check(game.hit_count==2 and cues("SM_BAL_SHOT").size()==1,"second slash waits through its opening frame")
		var fresh: Dictionary = game.spawn_enemy(POINT+Vector2(180,0))
		fresh["hp"] = 10000.0
		game.player["stuck_ms"] = 0.0
		step(1)
		var swing := "R_KATANAA" if blade else "R_BEAMSWDA"
		check(game.hit_count==5 and game.view.player_actor.sample()["frame"]==2
			and cues("SM_BAL_SHOT").size()==2 and cues(swing).size()==2 and game.player["mp"]==paid_mp
			and game.player["cooldowns"]["draw"]==paid_cooldown and spent==[[3037,1]],
			"the next frame hits the same targets independently without a second skill payment")
		var pause_ms := 70.0 if blade else 60.0
		check(game.player["stuck_ms"]==pause_ms and fresh["stuck_ms"]==pause_ms,
			"the second slash uses the original weapon stop for "+family)
		check_draw_slash_layers("red" if blade else "white",0)
		if blade:
			var effect: Dictionary = game.action_def()["hits"][0]["effects"][0]
			var active: Dictionary = game.monsters[0]["numeric"].effects.active.get("bleed",{})
			check(is_equal_approx(effect["chance"],0.912) and effect["source_bleed_total"]==2779 and not active.is_empty(),
				"rank seven Katana Mastery installs source bleeding on the second slash at owner level 60")
			if not active.is_empty():
				check(active["source_bleed"]["applications"]==[{"remaining_ms":9000.0,"amount":154,"status_level":38}],
					"second slash bleeding preserves native duration, level and per-tick integer conversion")
		else:
			var effect: Dictionary = game.action_def()["hits"][0]["effects"][0]
			var active: Dictionary = fresh["numeric"].effects.active.get("shock",{})
			check(is_equal_approx(effect["chance"],1.0) and effect["status_level"]==41 and effect["source_shock_amount"]==291,
				"rank seven Light Sword Mastery uses its own chance, level and level-60 lightning base")
			check(active.get("source_shock",[])==[{"remaining_ms":15504.0,"amount":291,"hits_left":32}]
				and game.bus.events_of("combat.damage").all(func(event):return event.get("status","")!="shock"),
				"the applying slash installs lightning without consuming its first hit")
		var after_second: float = fresh["hp"]
		check(game.draw_pending_hits.size()==1 and game.draw_pending_hits[0]["target"]==fresh,
			"only the previously untouched target registers a delayed hit on the second slash")
		press(KEY_X)
		step(530)
		check(game.player["action"]=="" and cues("SWD_BAL_END").size()==2,
			"the second slash sheathes and cannot loop to a third strike")
		check(fresh["hp"]<after_second and game.draw_pending_hits.is_empty(),"the new target also takes the delayed base slash")
		if blade:
			var applications: Array = fresh["numeric"].effects.active.get("bleed",{}).get("source_bleed",{}).get("applications",[])
			check(applications.size()==1,"the new target bleeds once from the immediate second slash")
		else:
			var hits: Array = game.bus.events_of("combat.damage").filter(func(event):return event.get("status","")=="shock")
			var active: Dictionary = fresh["numeric"].effects.active.get("shock",{})
			check(hits.size()==1 and hits[0]["amount"]==291 and active.get("source_shock",[])==[
				{"remaining_ms":15504.0,"amount":291,"hits_left":31}],"the delayed object consumes one lightning hit without reapplying it")

func check_source_shock_limits() -> void:
	var actor := preload("res://stats/api/actor_numbers.gd").new()
	actor.values = {"level":41,"lightning_resistance":20,"abnormal_resistance":0}
	var source := {"status_level":41,"chance":1.0,"duration_ms":15504,"source_shock_amount":291,"hit_ms":500}
	check(not actor.apply_source_shock(source,8000) and actor.apply_source_shock(source,7999),
		"lightning uses its own resistance on the original percent threshold")
	var effects := Numbers.Effects.new()
	effects.add_source_shock(12,500,500)
	effects.add_source_shock(25,1000,500)
	check(effects.step(499).is_empty(),"lightning has no periodic damage event")
	check(effects.trigger_source_shock()=={"amount":25,"display":37,"removed":false},"lightning separates HP subtraction from the sum used for display")
	check(effects.trigger_source_shock()=={"amount":25,"display":37,"removed":false}
		and effects.trigger_source_shock()=={"amount":25,"display":25,"removed":true}
		and effects.trigger_source_shock().is_empty(),"lightning retains the zero-based last hit and then exhausts each application")
	effects.add_source_shock(25,500,500)
	check(effects.step(500)==[{"type":"removed","id":"shock"}] and effects.trigger_source_shock().is_empty(),
		"an untriggered lightning application expires by time")

func check_draw_greatsword_charge() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"weaponmaster"})
	profile.command("numbers.skill_grant",{"id":"draw","level":2})
	for sample: Array in [[2,0,1192,1.0],[3,0,1193,1.0],[3,750,1490,1.25],[3,999,1786,1.0],[3,1000,1788,1.0]]:
		var rank := int(sample[0])
		var release := int(sample[1])
		var rate := float(sample[3])
		profile.command("numbers.skill_grant",{"id":"heavyswordmastery","level":rank})
		var spec := profile.stats()
		spec["skill_slots"] = ["draw"]
		start_room("","greatsword",1,spec)
		var spent: Array = []
		session.set_skill_material_spender(func(id: int, amount: int):
			spent.append([id,amount])
			return true)
		game.numeric_player.values["attack_speed"] = rate
		game.numeric_player.values["hit"] = 1.0
		var target: Dictionary = api.spawn_dummy(POINT+Vector2(125,0))
		if release > 0:session.submit_key(KEY_A,true)
		else:press(KEY_A)
		step(499)
		var paid_mp: float = game.player["mp"]
		var paid_cooldown: float = game.player["cooldowns"]["draw"]
		if rank < 3:
			check(not game.player.has("draw_charge") and game.player["clock"]==499.0 and draw_slash_views().is_empty(),
				"Greatsword Draw Sword keeps its ordinary windup below mastery three")
			step(26)
		else:
			check(game.player_ani()==["momentaryslash",0.0] and game.view.effects.is_empty() and target["hp"]==5000.0,
				"greatsword charge freezes frame zero with no hits or effects through 499 ms")
			step(1)
			var layers: Array = game.view.effects.duplicate()
			check(game.player.has("draw_charge") and layers.size()==2 and game.player_ani()==["momentaryslash",0.0],
				"at 500 ms charge stays active and attaches both registered effects")
			if layers.size()==2:
				check(layers[0].data["source"].ends_with("/charge1.ani") and layers[1].data["source"].ends_with("/charge2.ani")
					and layers[0].z_index==300 and layers[1].z_index==301 and layers[0].frame_scale()==Vector2(0.5,0.5),
					"charge uses both source scales and native layer priorities")
				if release==750:
					step(55)
					check(layers[0].frame["frame"]==0,"1.25 attack speed keeps charge FX on frame zero through 55 ms")
					step(1)
					check(layers[0].frame["frame"]==1 and layers[1].frame["frame"]==1 and game.player["clock"]==0.0,
						"the charge FX advances on its own clock while the body is frozen")
			if release==0:
				step(1)
			else:
				step(mini(release,999)-float(game.player["draw_charge"]["elapsed_ms"]))
				check(game.player.has("draw_charge") and target["hp"]==5000.0,"holding keeps charge active until release or 1000 ms")
				if release==1000:step(1)
				session.submit_key(KEY_A,false)
				step(0)
			check(not game.player.has("draw_charge") and game.view.effects.is_empty() and cues("SM_BAL_READY").size()==2
				and game.view.player_actor.sample()["frame"]==1 and game.player["clock"]==500.0 and target["hp"]==5000.0,
				"greatsword release clears the charge effects and seeks to original frame one")
			step(25.0/rate-1.0)
			check(target["hp"]==5000.0 and draw_slash_views().is_empty(),"released greatsword waits for the outstroke")
			step(1)
		check(game.action_def()["hits"][0]["percent"]==sample[2] and target["hp"]==5000.0
			and game.hit_count==1 and spent==[[3037,1]] and game.player["mp"]==paid_mp
			and game.player["cooldowns"]["draw"]==paid_cooldown,
			"greatsword Draw Sword registers the expected charge percentage and pays once for "+str(sample))
		check_draw_slash_layers("blue",0)
		step(200.0/rate+1)
		var expected := int(float(sample[2])*1.3)
		var trace: Dictionary = game.last_damage["trace"]
		check(target["hp"]<5000.0 and is_equal_approx(trace["percent_part"],float(trace["attack"])*expected/100.0),
			"the delayed greatsword impact applies the live one-target bonus to its charge percentage")
	var spec := profile.stats()
	spec["skill_slots"] = ["draw"]
	start_room("","greatsword",1,spec)
	session.set_skill_material_spender(func(_id: int,_amount: int):return true)
	session.submit_key(KEY_A,true)
	step(600)
	var atk: Dictionary = game.table.atk("character/swordman/attackinfo/attack1.atk")
	check(game.hurt_player(7,{"pos":POINT+Vector2(40,0)},atk,-1)=="stagger","a hit interrupts greatsword charge")
	session.submit_key(KEY_A,false)
	step(500)
	check(not game.player.has("draw_charge") and cues("SM_BAL_SHOT").is_empty() and draw_slash_views().is_empty(),
		"interruption clears charge without emitting a delayed slash")

func check_draw_short_wave() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"weaponmaster"})
	profile.command("numbers.skill_grant",{"id":"draw","level":2})
	for rank in [6,7]:
		profile.command("numbers.skill_grant",{"id":"shortswordmastery","level":rank})
		var spec := profile.stats()
		spec["skill_slots"] = ["draw"]
		start_room("original_27000","shortsword",1,spec)
		session.set_skill_material_spender(func(id: int, amount: int):return id==3037 and amount==1)
		game.numeric_player.values["attack_speed"] = 1.0
		var front: Dictionary = game.monsters[0]
		var rear: Dictionary = game.monsters[1]
		for target: Dictionary in game.monsters:move_target(target,POINT+Vector2(1200,0))
		move_target(front,POINT+Vector2(125,0))
		move_target(rear,POINT+Vector2(-125,0))
		for target: Dictionary in [front,rear]:target["hp"] = 10000.0
		press(KEY_A)
		step(525)
		step(149)
		check(game.hit_count==2 and game.objects.is_empty(),"short sword only uses the direct blade before frame 6")
		step(1)
		if rank == 6:
			check(game.objects.is_empty(),"effective mastery rank six is below the original wave gate")
			continue
		check(game.objects.size()==1,"effective mastery rank seven creates one wave on frame 6")
		if game.objects.size()!=1:return
		var wave: Dictionary = game.objects[0]
		var hit: Dictionary = wave["hit"]
		check(wave["pos"]==POINT and wave["z"]==50.0 and wave["speed"]==500.0
			and hit["native_controller"]["distance"]==400,
			"wave starts at the caster's ground point, native absolute Z, speed and range")
		check(hit["native_controller"]["base_amount"]==1263 and hit["fixed_amount"]==1547
			and hit["atk"]["absolute_damage"]==1547 and hit["percent"]==0.0,
			"rank two draw with rank seven mastery packs 1263 then 1547 for two distinct blade targets")
		game.numeric_player.values["independent_attack"] = 500.0
		game.player["stuck_ms"] = 0.0
		front["stuck_ms"] = 25.0
		game.step_objects(10,int(wave["id"]))
		check(wave["clock"]==0.0 and wave["hits"].has(front["id"]) and not wave["hits"].has(rear["id"])
			and game.last_damage["trace"]["fixed_part"]==1547.0,
			"the wave hits at age zero with its own ledger and already packed fixed amount")
		check(front["state"]=="down" and front["stuck_ms"]==25.0 and game.player["stuck_ms"]==0.0,
			"the wave knocks down without extending the target stop or starting a caster stop")
		check(cues("ASTROM_HIT_LIGHT").size()==1 and not game.view.audio.variants.has("ASTROM_HIT_LIGHT")
			and not game.view.audio.sound_streams.has("ASTROM_HIT_LIGHT"),
			"the wave retains the authored missing sound key without playing a different registered sound")
		game.view.present(game.view_snapshot(),0.0,0.0)
		check(game.view.object_views[wave["id"]].has_node("RearAnimation"),
			"the native StartB clip is attached behind the main wave")
		step(380)
		check(game.player["action"]=="" and game.objects.has(wave),"the wave persists after the caster recovers")
		game.step_objects(799)
		check(wave["pos"]==POINT+Vector2(399.5,0) and game.object_view_clock(wave)<10000.0
			and wave["hits"].size()==1,"the wave remains on flight frame zero through age 799 ms")
		move_target(rear,POINT+Vector2(401,0))
		game.step_objects(1)
		check(game.object_view_clock(wave)==10000.0 and not wave["hits"].has(rear["id"]),
			"at X distance 400 the wave starts its visual tail and loses collision")
		game.step_objects(279)
		check(game.objects.has(wave),"the main ANI retains the final authored frame")
		game.step_objects(1)
		check(game.objects.is_empty(),"both clips retire after the 280 ms main tail")
	var spec := profile.stats()
	spec["skill_slots"] = ["draw"]
	start_room("original_27000","shortsword",-1,spec)
	session.set_skill_material_spender(func(_id: int,_amount: int):return true)
	game.numeric_player.values["attack_speed"] = 1.25
	for target: Dictionary in game.monsters:move_target(target,POINT+Vector2(1200,0))
	press(KEY_A)
	step(539)
	check(game.objects.is_empty(),"1.25 attack speed keeps the independent wave dormant through 539 ms")
	step(1)
	check(game.objects.size()==1 and game.objects[0]["hit"]["fixed_amount"]==1263 and game.objects[0]["facing"]==-1,
		"frame six at 540 ms launches the facing-left base wave after a whiff")

func check_thirst() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"berserker"})
	profile.command("numbers.skill_grant",{"id":"sacrifice","level":2})
	profile.command("numbers.skill_grant",{"id":"bloodblast","level":2})
	var spec := profile.stats()
	spec["skill_slots"] = ["sacrifice","bloodblast"]
	start_room("original_27601","katana",1,spec,"berserker")
	var max_hp := int(game.max_hp)
	var initial := int(max_hp*12/100.0)
	var tier_cost := int(max_hp*5/100.0)
	var mp := float(game.player["mp"])
	game.player["hp"] = initial
	press(KEY_A)
	step(0)
	check(game.player["action"]=="" and game.player["hp"]==initial
		and not game.player["cooldowns"].has("sacrifice"),"Thirst rejects HP equal to the 12 percent entry cost")
	game.player["hp"] = max_hp
	session.submit_key(KEY_A,true)
	step(0)
	var move: Dictionary = game.move_def("sacrifice")
	var release_key: String = move["stages"][1]["fx"][0]["key"]
	check(game.player["hp"]==max_hp-initial and game.player["mp"]==mp
		and game.view.player_actor.pose=="summon1" and cues(move["cast_fx"]).size()==1,
		"Thirst uses Summon1, original charging effect and HP only")
	for index in 6:step(50)
	step(49)
	check(game.player["hp"]==max_hp-initial,"Thirst cannot pay the first tier before 350 ms")
	step(1)
	step(1)
	check(game.player["hp"]==max_hp-initial-tier_cost,"holding the first tier pays once")
	session.submit_key(KEY_A,false)
	step(48)
	check(game.player["stage"]==0 and game.active_effect("thirst").is_empty(),"early release waits until 400 ms")
	step(1)
	var thirst: Dictionary = game.active_effect("thirst")
	var mods: Array = thirst.get("definition",{}).get("modifiers",[])
	check(game.view.player_actor.pose=="summon2" and cues(release_key).size()==1
		and cues("SM_SACRIFICE_CAST").size()==1 and cues("SACRI").size()==1,
		"Thirst releases into Summon2 with its authored effect and sounds")
	check(cues("SACRI_LOOP").size()==1 and game.view.audio._loop_voices.has(0)
		and game.view.audio._loop_voices[0].stream.loop,
		"release starts one true loop on the caster's audio voice")
	check(game.view.object_views.has("player:thirst") and game.view.object_views["player:thirst"].loop,
		"the active buff draws its own looping GiveBloodStay clip during release")
	check(game.objects.is_empty(),"partial release does not create the full-charge object")
	check(thirst.get("remaining_ms")==30000 and mods.map(func(mod):return mod["value"])==[10.0,2.0],
		"rank two at tier one installs the original 30 second strength and attack modifiers")
	step(499)
	check(game.player["action"]=="sacrifice","Thirst holds the recovery state until 500 ms")
	step(1)
	check(game.player["action"]=="" and not game.active_effect("thirst").is_empty(),
		"the cast visual ends while the Thirst appendage remains")
	var actor = game.view.player_actor
	check(actor.pose=="staysacrifice" and actor.sample()["frame"]==0
		and actor.equipment_layers.all(func(layer):return layer.clips.has("staysacrifice")),
		"Thirst selects source ETC 114 with both item-specific weapon tracks on recovery exit")
	step(1549)
	check(actor.sample()["frame"]==15,"the special idle shows its last authored frame at 1549 ms")
	step(1)
	check(actor.sample()["frame"]==0,"the special idle loops to frame zero at 1550 ms")
	game.step_player(10,Vector2.RIGHT)
	game.view.present(game.view_snapshot(),0.0,0.0)
	check(actor.pose=="move" and game.view.object_views.has("player:thirst") and game.view.audio._loop_voices.has(0),
		"moving keeps the persistent effect and sound with the original move pose")
	step(0)
	check(actor.pose=="staysacrifice" and actor.sample()["frame"]==0,"returning to idle resets its body and weapon clock")
	session.set_skill_material_spender(func(_id: int,_amount: int):return true)
	game.numeric_player.values["independent_attack"] = float(Numbers.shared_config()["base"]["independent_attack"])+1.0
	press(KEY_S)
	step(495)
	check(game.objects.size()==3,"Blood Blast releases normally while Thirst is active")
	if game.objects.size()!=3:return
	var ground: Dictionary = game.objects[2]
	check(ground["hit"]["fixed_amount"]==1388 and ground["hit"].get("fixed_amount_bleeding")==1466,
		"rank two Thirst packs a second fixed amount at release before integer truncation")
	game.apply_effect({"kind":"remove_effect","id":"thirst"})
	game.view.present(game.view_snapshot(),0.0,0.0)
	check(not game.view.audio._loop_voices.has(0) and not game.view.object_views.has("player:thirst"),
		"explicit removal releases the loop voice and the active draw layer")
	var target: Dictionary = game.monsters[0]
	for enemy: Dictionary in game.monsters:move_target(enemy,POINT+Vector2(400,0))
	move_target(target,POINT)
	game.apply_effect({"kind":"effect","id":"bleed","target":target["id"]})
	game.step_objects(100)
	check(game.last_damage["trace"]["fixed_part"]==1466.0,
		"a target that starts bleeding after release receives the packed Thirst bonus")
	ground["hits"].clear()
	target["hp"] = 10000.0
	target["numeric"].remove_effect("bleed")
	move_target(target,POINT)
	game.step_objects(0.0)
	check(game.last_damage["trace"]["fixed_part"]==1388.0,"the same payload uses ordinary damage when the target stops bleeding")
	start_room("original_27601","katana",1,spec,"berserker")
	game.player["hp"] = initial+tier_cost
	session.submit_key(KEY_A,true)
	for index in 6:step(50)
	step(49)
	step(1)
	check(game.player["stage"]==1 and game.player["hp"]==tier_cost,
		"an unaffordable tier forces release while preserving the remaining HP")
	session.submit_key(KEY_A,false)
	start_room("original_27601","katana",1,spec,"berserker")
	game.numeric_player.values["cast_speed"] = 1.25
	session.submit_key(KEY_A,true)
	for index in 199:step(10)
	check(game.player["stage"]==0 and game.player["hp"]==max_hp-initial-4*tier_cost,
		"full hold pays four tiers and does not shorten the wall timer at faster cast speed")
	step(10)
	session.submit_key(KEY_A,false)
	check(game.player["stage"]==1 and game.action_duration("sacrifice")==400.0,
		"full hold releases at 2000 ms and applies cast speed only to recovery")
	check_thirst_burst()
	step(400)
	game.step_numeric_actor(game.player,game.numeric_player,29999)
	game.view.present(game.view_snapshot(),0.0,0.0)
	check(game.view.player_actor.pose=="staysacrifice" and game.view.audio._loop_voices.has(0),
		"the idle, aura and loop remain until the original active time expires")
	game.step_numeric_actor(game.player,game.numeric_player,1)
	game.view.present(game.view_snapshot(),0.0,0.0)
	check(game.view.player_actor.pose=="stay" and not game.view.audio._loop_voices.has(0)
		and not game.view.object_views.has("player:thirst"),
		"natural expiry restores ordinary idle and stops both active presentations")

func check_thirst_burst() -> void:
	check(game.objects.size()==1,"full-charge release creates exactly one passive object")
	if game.objects.size()!=1:return
	var burst: Dictionary = game.objects[0]
	var hit: Dictionary = burst["hit"]
	check(burst["def"]["path"].ends_with("/givebloodsub.obj") and burst["pos"]==POINT
		and burst["z"]==1.0 and is_equal_approx(burst["size_rate"],1.65),
		"object 20148 spawns at caster Z+1 with both native scale factors")
	check(hit["effects"]==[{"id":"bleed","chance":1.0,"status_level":40,"duration_ms":7000,"source_bleed_total":1096}],
		"rank two packet uses columns 14 to 16 for bleed and a base 100 percent chance")
	for enemy: Dictionary in game.monsters:move_target(enemy,POINT+Vector2(450,0))
	var first: Dictionary = game.monsters[0]
	var second: Dictionary = game.monsters[1]
	move_target(first,POINT+Vector2(75,0))
	move_target(second,POINT)
	for target: Dictionary in [first,second]:
		target["hp"] = 2000.0
		target["numeric"].values["hp_max"] = 2000.0
		target["numeric"].values["physical_defense"] = 1000000.0
		target["numeric"].values["level"] = 40
		target["numeric"].values["bleeding_resistance"] = 0
		target["numeric"].values["abnormal_resistance"] = 0
	var hp := float(first["hp"])
	game.step_objects(10,int(burst["id"]))
	game.step_objects(99)
	check(burst["clock"]==99.0 and burst["hits"].is_empty(),"creation starts at age zero with a 100 ms blank frame")
	game.step_objects(1)
	check(burst["hits"].has_all([first["id"],second["id"]]) and first["hp"]==hp
		and cues("FIRE_PILLAR_HIT").size()==2,
		"scaled first hit catches both targets with the original impact cue and zero immediate damage")
	var bleed: Dictionary = first["numeric"].effects.active.get("bleed",{})
	check(bleed.has("source_bleed"),"full-charge contact installs the timed original bleed payload")
	if not bleed.has("source_bleed"):return
	game.view.present(game.view_snapshot(),0.0,0.0)
	var views: Dictionary = game.view.object_views
	var layer_id := "%s:layer:0" % burst["id"]
	check(views.has(burst["id"]) and views.has(layer_id)
		and views[burst["id"]].z_index<views[layer_id].z_index
		and is_equal_approx(views[layer_id].base_scale,1.65),
		"front and back clips follow the source layering and share the scale")
	game.step_numeric_actor(first,first["numeric"],0)
	check(first["hp"]==hp-78,"first native tick floors 1096 / floor(7000 / 500)")
	game.step_numeric_actor(first,first["numeric"],499)
	check(first["hp"]==hp-78,"native bleed does not tick again before 500 ms")
	first["state"] = "move"
	game.step_numeric_actor(first,first["numeric"],1)
	check(first["hp"]==hp-156,"an ordinary moving monster takes the same 500 ms bleed tick without a second defense pass")
	game.step_objects(259)
	check(game.objects.has(burst) and cues("FIRE_PILLAR_HIT").size()==2,"object keeps one hit per target through age 359")
	game.step_objects(1)
	game.view.present(game.view_snapshot(),0.0,0.0)
	check(game.objects.is_empty() and not views.has(layer_id) and not views.has(burst["id"]),
		"both layers retire when the 360 ms main ANI ends")
	game.step_numeric_actor(first,first["numeric"],6499)
	check(first["numeric"].effects.active.has("bleed"),"bleed survives the object until its own duration ends")
	game.step_numeric_actor(first,first["numeric"],1)
	check(not first["numeric"].effects.active.has("bleed"),"rank two original bleed expires at 7000 ms")
	var effects = second["numeric"].effects
	effects.step(6000)
	check(second["numeric"].add_effect("bleed"),"generic bleed can apply during the source bleed")
	var mixed: Dictionary = effects.active["bleed"]
	check(mixed["stacks"]==1 and mixed.has("source_bleed"),"generic bleed keeps its own stack count and preserves the source timer")
	effects.step(1000)
	check(effects.active.has("bleed") and not mixed.has("source_bleed"),"the source timer expires independently of generic bleed")

func check_bloodblast() -> void:
	var profile := ProfileSession.new()
	profile.command("numbers.level",{"level":60})
	profile.command("numbers.growtype",{"growtype":"berserker"})
	profile.command("numbers.skill_grant",{"id":"bloodblast","level":2})
	profile.command("numbers.skill_grant",{"id":"buff","level":1})
	var spec := profile.stats()
	spec["skill_slots"] = ["bloodblast"]
	start_room("original_27601","katana",-1,spec,"berserker")
	var spent: Array = []
	session.set_skill_material_spender(func(id: int, amount: int):
		spent.append([id,amount])
		return spent.size()==2)
	var mp: float = game.player["mp"]
	press(KEY_A)
	step(0)
	check(game.player["action"]=="" and game.player["mp"]==mp and game.objects.is_empty(),
		"Blood Blast rejects a missing cube before charging MP or starting the cast")
	game.numeric_player.values["attack_speed"] = 1.25
	game.numeric_player.values["cast_speed"] = 1.0
	press(KEY_A)
	step(395)
	check(game.view.player_actor.pose=="summon1" and game.objects.is_empty() and cues("SM_BLOOD_CAST").is_empty(),
		"rank two Blood Blast charges for 396 ms at 1.25 attack speed, independently of cast speed")
	game.numeric_player.values["independent_attack"] = 126.0
	step(1)
	check(game.view.player_actor.pose=="summon2" and game.player["clock"]==0.0
		and spent==[[3037,1],[3037,1]] and game.player["mp"]<mp and cues("SM_BLOOD_CAST").size()==1,
		"Blood Blast releases from frame zero after one successful payment and plays the original voice")
	check(game.objects.size()==3,"ordinary Blood Blast creates all three passive objects at release")
	if game.objects.size()!=3:return
	var sub: Dictionary = game.objects[0]
	var pillar: Dictionary = game.objects[1]
	var ground: Dictionary = game.objects[2]
	var contact_keys: Array = sub["hit"]["native_controller"]["ground_hit_fx"]
	check(sub["def"]["path"].ends_with("/blastbloodsuborigin.obj") and sub["pos"]==POINT
		and pillar["def"]["path"].ends_with("/blastbloodorigin.obj") and pillar["pos"]==POINT+Vector2(0,50)
		and ground["def"]["path"].ends_with("/blastbloodpresuborigin.obj") and ground["pos"]==POINT,
		"source object creation order and depth offsets")
	check(sub["hit"]["fixed"]==179.0 and pillar["hit"]["fixed"]==179.0 and ground["hit"]["fixed"]==239.0
		and [sub,pillar,ground].all(func(o):return o["hit"]["percent"]==0.0 and o["clock"]==0.0),
		"rank two emits fixed columns 0/0/2 and starts each object at age zero")
	check(sub["hit"]["fixed_amount"]==1084 and pillar["hit"]["fixed_amount"]==1084
		and ground["hit"]["fixed_amount"]==1448 and ground["hit"]["atk"]["absolute_damage"]==1448,
		"release packs the three original truncated amounts using level 60 base 580 and addend 26")
	game.numeric_player.values["independent_attack"] = 500.0
	var target: Dictionary = game.monsters[0]
	for enemy: Dictionary in game.monsters:
		move_target(enemy,POINT+Vector2(400,0))
	move_target(target,POINT)
	game.step_objects(99)
	check(ground["hits"].is_empty(),"the opening blank frame cannot hit")
	game.step_objects(1)
	check(ground["hits"].has(target["id"]) and sub["hits"].is_empty() and pillar["hits"].is_empty(),
		"at 100 ms only the ground burst registers contact with the centered target")
	check(game.last_damage["trace"]["fixed_part"]==1448.0,
		"the damage pipeline uses the released integer even after independent attack changes")
	game.view.present(game.view_snapshot(),0.0,0.0)
	check(game.view.object_views.has(ground["id"]) and game.view.object_views.has("%s:layer:0" % ground["id"]),
		"the original ground burst exposes both its back and front layers")
	move_target(target,POINT+Vector2(400,0))
	game.step_objects(300)
	check(not game.objects.has(ground),"ground contact ends with its 400 ms main animation")
	game.step_objects(559)
	check(cues("FIRE_PILLAR_UP").is_empty(),"the pillar cue stays silent before ETC frame eight")
	game.step_objects(1)
	check(cues("FIRE_PILLAR_UP").size()==1,"the pillar cue plays at object age 960 ms")
	move_target(target,POINT)
	target["hp"] = 10000.0
	target["vz"] = 0.0
	game.step_objects(39)
	check(pillar["hits"].is_empty(),"the main pillar has no contact before 1000 ms")
	game.step_objects(1)
	var lift: float = game.rules["reaction"]["lift_speed_per_unit"]
	check(pillar["hits"].has(target["id"]) and target["state"]=="air"
		and is_equal_approx(float(target["vz"]),450.0*lift) and sub["hit"]["lift"]==450.0,
		"the pillar launches at 1000 ms with the authored static lift, also configured on the spray")
	game.monsters.clear()
	pillar["hits"][99] = true
	sub["hits"][99] = true
	game.step_objects(74)
	check(pillar["hits"].has(99) and sub["hits"].has(99),"both hit ledgers survive before their first timer boundary")
	game.step_objects(1)
	check(pillar["hits"].is_empty() and sub["hits"].has(99),"the pillar resets at 1075 ms, independently of the spray")
	game.step_objects(24)
	game.view.present(game.view_snapshot(),0.0,0.0)
	var ids: Array = [11,12,13,14,15,16,17,18,20,30].map(func(order):return "%s:ani:%s" % [pillar["id"],order])
	var views: Dictionary = game.view.object_views
	check(ids.all(func(id):return views.has(id) and not views[id].frame.has("sprite")),
		"all ten ALS tracks are attached at their original layer positions and remain blank at 1099 ms")
	move_target(target,POINT+Vector2(100.75,-12.25))
	target["vz"] = 0.0
	game.monsters.append(target)
	game.step_objects(1)
	check(pillar["hits"].is_empty(),"the light layer does not widen the pillar's main ANI hitbox")
	game.view.present(game.view_snapshot(),0.0,0.0)
	var ordered := true
	var previous := -1
	for id: String in ids:
		var layer = views.get(id)
		if layer == null or not layer.frame.has("sprite") or layer.z_index!=int(pillar["pos"].y) or layer.get_index()<=previous:
			ordered = false
			break
		previous = layer.get_index()
	check(ordered,"all ten layers reference their 1100 ms sprites in ascending ALS draw order at the pillar depth")
	game.step_objects(19)
	check(not sub["hits"].has(target["id"]),"the centered spray has no contact before 1120 ms")
	check(contact_keys.all(func(key):return cues(key).is_empty()),
		"neither the ground burst nor the main pillar creates the centered spray hit effects")
	game.step_objects(1)
	check(sub["hits"].has(target["id"]) and target["state"]=="air"
		and is_equal_approx(float(target["vz"]),450.0*lift),
		"the centered spray launches at 1120 ms with its own static lift")
	var contact_origin := Vector2(Vector2i(target["pos"]))
	check(contact_keys.all(func(key):return (cues(key).size()==1 and cues(key)[0]["point"]==contact_origin
		and cues(key)[0]["height"]==0.0 and cues(key)[0]["facing"]==1)),
		"the grounded hit creates both draw objects at target XYZ before lift, facing the native default direction")
	game.monsters.clear()
	game.step_objects(60)
	check(sub["hits"].is_empty() and sub["hit_resets_left"]==2 and cues("FIRE_PILLAR_UP").size()==1,
		"the spray first resets at 1180 ms and the pillar cue stays one-shot")
	move_target(target,contact_origin,30.0)
	target["vz"] = 0.0
	game.monsters.append(target)
	game.step_objects(0.0)
	check(sub["hits"].has(target["id"]) and contact_keys.all(func(key):return cues(key).size()==1),
		"the same spray still hits an airborne target, without creating the ground effects")
	game.monsters.clear()
	step(559)
	check(game.player["action"]=="bloodblast","recovery holds at 559 ms")
	step(1)
	check(game.player["action"]=="" and game.objects.size()==2,"560 ms recovery leaves live spray objects independent of the caster")
	game.step_objects(120)
	game.view.present(game.view_snapshot(),0.0,0.0)
	check(not views.has("%s:ani:20" % pillar["id"]) and not views.has("%s:layer:1" % pillar["id"])
		and views.has("%s:ani:30" % pillar["id"]),
		"finished floor layers leave the view while the eruption remains active")
	var contact_views: Array = game.view.effects.filter(func(fx):return (
		String(fx.data["source"]).get_file() in ["blastbloodhit1.ani","blastbloodhit2.ani"]))
	check(contact_views.size()==2,"both native contact clips are bound to render views")
	if contact_views.size()!=2:return
	var first = contact_views[0]
	var second = contact_views[1]
	check(first.z_index==1 and second.z_index==int(contact_origin.y)
		and first.position==second.position and first.facing==1 and second.facing==1,
		"the first effect draws over the floor and the second sorts at the original target depth")
	var anchor: Vector2 = first.position
	move_target(target,POINT+Vector2(200,20),80.0)
	game.view.present(game.view_snapshot(),399.0,399.0)
	check(not first.frame.has("sprite") and not second.frame.has("sprite"),"contact art stays blank through 399 ms")
	game.view.present(game.view_snapshot(),1.0,1.0)
	check(not first.frame.has("sprite") and second.frame.has("sprite"),"Hit2 starts at 400 ms")
	game.view.present(game.view_snapshot(),70.0,70.0)
	check(first.frame.has("sprite") and second.frame.has("sprite") and first.position==anchor and second.position==anchor,
		"Hit1 starts at 470 ms and both effects stay at the grounded contact point")
	start_room("original_27601","katana",1,spec,"berserker")
	session.set_skill_material_spender(func(id: int, amount: int):return id==3037 and amount==1)
	game.apply_skill_effect("buff","frenzy")
	game.numeric_player.values["attack_speed"] = 1.0
	game.numeric_player.values["independent_attack"] = 100.0
	press(KEY_A)
	step(495)
	check(game.objects.size()==3 and game.objects[0]["hit"]["fixed_amount"]==1048
		and game.objects[1]["hit"]["fixed_amount"]==1048 and game.objects[2]["hit"]["fixed_amount"]==1399,
		"active rank one Frenzy applies its one percent after the original truncation on all three objects")

func run() -> void:
	game = session.mount(root)
	game.set_physics_process(false)
	api = TestAPI.new(game)
	for facing: int in [1,-1]:
		start_room("original_27601","katana",facing)
		var ahead: Dictionary = api.spawn_dummy(POINT+Vector2(72*facing,0))
		var near: Dictionary = game.spawn_enemy(POINT+Vector2(8*facing,0))
		near["hp"] = 5000.0
		near["max_hp"] = 5000.0
		press(KEY_X)
		step(149)
		check(game.player["action"]=="attack1" and game.hit_count==0,"X enters Attack1 with no early hit")
		step(1)
		check(game.hit_count==1 and ahead["hp"]<5000.0 and near["hp"]==near["max_hp"],
			"Attack1 at 150 ms hits through the mirrored C layer")
		move_target(ahead,POINT+Vector2(72*facing,0))
		step(50)
		check(game.hit_count==2 and game.bus.events_of("combat.hit")[-1]["target"]==near["id"],
			"B layer first hits the near actor at 200 ms and cannot hit the first actor twice")
		game.player["stuck_ms"] = 0.0
		press(KEY_X)
		step(50)
		check(game.player["action"]=="attack2" and game.player["hits"].is_empty(),
			"next ATK installation clears the target ledger")
		move_target(ahead,POINT+Vector2(72*facing,0))
		# The ordinary second attack begins above a standing goblin.
		move_target(near,POINT+Vector2(8*facing,0))
		step(100)
		check(game.hit_count==3 and game.bus.events_of("combat.hit")[-1]["target"]==ahead["id"],
			"second attack can hit the same actor again")
		game.player["stuck_ms"] = 0.0
		press(KEY_X)
		step(100)
		move_target(ahead,POINT+Vector2(72*facing,0))
		move_target(near,POINT+Vector2(8*facing,0))
		step(100)
		check(game.player["action"]=="attack3" and game.hit_count==5,
			"third X installs Attack3 and both actors are hit once through overlapping layers")

	for family: String in ["shortsword","katana"]:
		var item := "original_27000" if family=="shortsword" else "original_27601"
		start_room(item,family)
		var target: Dictionary = api.spawn_dummy(POINT+Vector2(-76,0))
		press(KEY_X)
		step(1)
		press(KEY_X)
		step(400)
		step(150)
		check(game.player["action"]=="attack2" and game.hit_count==(1 if family=="shortsword" else 0),
			"Attack2 frame 3 uses the equipped family's rear reach")
		var third: Array = game.table.moves["attack3"]["hits"][0]["segments"][0]["frames"]
		check(third[0]["boxes"]==[[-32.0,-13.0,0.0,179.0,26.0,94.0],[-32.0,-10.0,0.0,179.0,20.0,94.0]],
			"Attack3 keeps the body box before the attached box")

		start_room(item,family)
		target = api.spawn_dummy(POINT+Vector2(85,0))
		move_target(target,POINT+Vector2(85,0),110.0)
		var before_mp: float = game.player["mp"]
		press(KEY_Z)
		step(149)
		check(game.player["action"]=="upper" and game.hit_count==0 and cues("UPPER_SLASH_01").size()==1
			and cues("upper").size()==1 and cues("upper1").is_empty()
			and cues("UPPER_SLASH_01")[0]["event_id"]<cues("upper")[0]["event_id"],
			"Z plays the effect sound and voice in entry order before the sweep")
		step(50)
		check(game.hit_count==0 and cues("upper1").is_empty(),"no frame-3 FX or high hit before 200 ms")
		step(1)
		var effects := cues("upper1")
		check(game.hit_count==1 and effects.size()==1 and effects[0]["action_clock_at"]==200.0,
			"Upper frame 3 can hit airborne targets and creates one sweep")
		if not effects.is_empty():
			var fx: Dictionary = effects[0]
			var short_sword := family=="shortsword"
			check(fx["scale"]==(0.8 if short_sword else 0.9) and fx["offset_x"]==(5.0 if short_sword else 0.0)
				and fx["offset_y"]==(-18.0 if short_sword else 0.0),"original upper weapon scale and screen offset")
			var rendered: Array = game.view.effects.filter(func(view):return view.action_clock_at==200.0)
			check(rendered.size()==1 and rendered[0].base_scale==fx["scale"]
				and rendered[0].follow_offset==Vector2(fx["offset_x"],fx["offset_y"]),"live FX view uses original offset and scale")
		var late: Dictionary = game.spawn_enemy(POINT+Vector2(85,0))
		move_target(late,POINT+Vector2(85,0),110.0)
		step(100)
		check(game.hit_count==2 and game.bus.events_of("combat.hit")[-1]["target"]==late["id"],
			"Upper frame 5 retains its high hit at 300 ms")
		var outside: Dictionary = game.spawn_enemy(POINT+Vector2(85,0))
		move_target(outside,POINT+Vector2(85,0),110.0)
		step(50)
		check(game.hit_count==2 and cues("upper1").size()==1 and cues("upper2").is_empty()
			and game.player["mp"]==before_mp-game.table.moves["upper"]["mp"],
			"at 350 ms the last box is gone, with one cast cost and no follow-up FX")

	start_room("original_27000","shortsword")
	game.table.configure_skills({"shortswordmastery":2},"weaponmaster","shortsword")
	var ordinary: Array = game.table.moves["attack1"]["hits"][0]["segments"][0]["frames"]
	game.table.configure_skills({"shortswordmastery":3},"weaponmaster","shortsword")
	var mastery: Array = game.table.moves["attack1"]["hits"][0]["segments"][0]["frames"]
	check(ordinary[0]["boxes"].size()==1 and mastery[0]["boxes"][0]==[0.0,-10.0,30.0,160.0,20.0,84.0]
		and mastery[0]["start"]==150.0,"mastery adds the source frame 3 box on the body clock at rank 3")
	check_upper_body_armor()
	check_upper_armor_visuals()
	check_followup()
	check_guard_release()
	check_guard_recoil_motion()
	check_guard_feedback()
	check_triple_motion()
	check_triple_slash()
	check_enhanced_triple_slash()
	check_triple_cooldown()
	check_overdrive_attributes()
	check_weapon_combo()
	check_weapon_combo_normal_cancel()
	check_heavy_weapon_combo()
	check_overdrive_cast()
	check_overdrive_particles()
	check_frenzy_drain()
	check_frenzy_attributes()
	check_frenzy_cast()
	check_frenzy_normals()
	check_frenzy_bleed()
	check_frenzy_recovery()
	check_frenzy_toggle()
	check_bloodblast()
	check_draw_sword()
	check_draw_target_deadlines()
	check_charge_crash_uppercut()
	check_rapid_move_slash()
	check_illusion_finish()
	check_hundred_sword_ready()
	check_hundred_sword_automatic()
	check_rapid_move_slash_shock()
	check_rapid_move_slash_fee_failure()
	check_rapid_move_slash_depth()
	check_charge_crash_body_armor()
	check_charge_crash_mastery()
	check_draw_second_slash()
	check_bloody_rave_phases()
	check_bloody_rave_fade()
	check_bloody_rave_contact_bleed()
	check_bloody_rave_cancel()
	check_bloody_rave_thirst()
	check_outrage_break_impact()
	check_hellbenter_first_cast()
	check_hellbenter_manual_finish()
	check_outrage_break_speed_refresh()
	check_outrage_break_eruption()
	check_outrage_break_armor()
	check_outrage_break_camera()
	check_bloody_rave_special_targets()
	check_grab_blast_startup()
	check_grab_blast_non_weapon_speed()
	check_grab_blast_thirst()
	check_source_shock_limits()
	check_draw_greatsword_charge()
	check_draw_short_wave()
	check_thirst()
	check_hardattack()
	check_hardattack_charge()
	check_hardattack_followup()
	check_hardattack_waves()
	session.stop()
	print("[SWORDMAN_CONTACT] COMPLETE checks=",checks," failures=",failures)
	quit(1 if failures else 0)
