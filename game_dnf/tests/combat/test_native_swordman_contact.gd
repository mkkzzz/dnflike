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
	game.step_player(ms,Vector2.ZERO)
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
		press(KEY_X)
		step(400)
		check(game.player["action"]=="attack2" and game.player["hits"].is_empty(),
			"next ATK installation clears the target ledger")
		move_target(ahead,POINT+Vector2(72*facing,0))
		# The ordinary second attack begins above a standing goblin.
		move_target(near,POINT+Vector2(8*facing,0))
		step(100)
		check(game.hit_count==3 and game.bus.events_of("combat.hit")[-1]["target"]==ahead["id"],
			"second attack can hit the same actor again")
		press(KEY_X)
		step(400)
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
	check_hardattack()
	check_hardattack_charge()
	session.stop()
	print("[SWORDMAN_CONTACT] COMPLETE checks=",checks," failures=",failures)
	quit(1 if failures else 0)
