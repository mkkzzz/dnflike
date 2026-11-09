extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
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

func start_room(item: String, family: String, facing := 1, numbers := {}) -> void:
	var spec: Dictionary = numbers.duplicate()
	spec.merge({"weapon_item":item,"weapon":family,"job":"weaponmaster"},true)
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
		var expired_target: Dictionary = api.spawn_dummy(game.player["pos"]+Vector2(30,0))
		step(1)
		check(game.hit_count==1 and expired_target["hp"]==expired_target["max_hp"],
			"Triple Slash weapon boxes expire at 280 ms")

	start_room("original_27601","katana",1,spec)
	game.numeric_player.values["attack_speed"] = 1.25
	press(KEY_S)
	step(0)
	var mp: float = game.player["mp"]
	for index: int in [0,1]:
		press(KEY_S)
		step(167)
		check(game.player["stage"]==index,"Triple Slash cannot continue before body frame 3")
		step(1)
		check(game.player["stage"]==index+1 and game.player["clock"]==0.0 and game.player["mp"]==mp,
			"Triple Slash advances at 210 action ms without another cast cost")
	press(KEY_S)
	step(168)
	check(game.player["stage"]==2,"ordinary Triple Slash has no fourth stage")
	step(296)
	check(game.player["action"]!="triple","Triple Slash recovers at the end of the final body animation")

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
	check_triple_slash()
	session.stop()
	print("[SWORDMAN_CONTACT] COMPLETE checks=",checks," failures=",failures)
	quit(1 if failures else 0)
