extends SceneTree

const Program = preload("res://combat/action/companion_program.gd")

var checks := 0
var failures := 0

func check(condition: bool, message: String) -> void:
	checks += 1
	if condition:return
	failures += 1
	print("[COMPANION_PROGRAM] FAIL ",message)

func _initialize() -> void:
	var ordinary := Program.load_program(201)
	var awakened := Program.load_program(202)
	check(not ordinary.is_empty() and not awakened.is_empty(),"load both source APC identities")
	check(Program.load_program(99999).is_empty(),"unknown map APC cannot use a G.S.D. program")
	var origin := Vector2(100,200)
	var context := {"position":origin,"target_position":origin+Vector2(30,15),"facing":1,"usable":{58:true}}
	check(Program.choose(ordinary,"action",context)=="wheel","normal APC uses skill 58 at the inclusive close bound")
	context.usable[58] = false
	check(Program.choose(ordinary,"action",context)=="upper_slash","close unavailable skill follows the source fallback")
	context.target_position = origin+Vector2(250,50)
	context.usable[20] = true
	check(Program.choose(ordinary,"action",context)=="normal_wave","action follows the source wave import")
	context.target_position.x += 1
	check(Program.choose(ordinary,"action",context)==-1,"out of source attack area returns no action")
	context.skill_on = {3:true}
	check(Program.choose(ordinary,"action",context)=="auto_guard","ordinary APC consults its guard attachment")
	context.skill_on = {52:false}
	check(Program.choose(awakened,"action",context)=="psychic_rage","awakened APC first takes its source stance branch")
	context.skill_on[52] = true
	context.usable[88] = true
	check(Program.choose(awakened,"action",context)=="psychic_eye","awakened APC follows the active stance branch")
	context.attack_success = true
	context.last_attack = 20
	context.usable[22] = true
	check(Program.choose(ordinary,"event",context)=="flame_wave","confirmed normal wave hit chains to fire if usable")
	context.attack_success = false
	check(Program.choose(ordinary,"event",context)==-1,"miss cannot trigger the hit chain")
	context.attack_success = true
	context.last_attack = 21
	context.facing = -1
	context.target_position = origin+Vector2(-30,-10)
	context.usable[58] = true
	check(Program.choose(ordinary,"event",context)=="wheel","left-facing ice chain mirrors its asymmetric forward bound")
	context.target_position.x = origin.x+1
	check(Program.choose(ordinary,"event",context)=="flame_wave","behind the mirrored ice chain takes its other source branch")
	check(Program.choose(ordinary,"movement",{"position":origin,"target_position":origin+Vector2(599,0)})==1,"source movement below 600")
	check(Program.choose(ordinary,"movement",{"position":origin,"target_position":origin+Vector2(600,0)})==0,"source movement boundary at 600")
	check(Program.choose(ordinary,"movement",{"position":origin,"target_position":origin+Vector2(0,173)})==1,"source depth projection below 600")
	check(Program.choose(ordinary,"movement",{"position":origin,"target_position":origin+Vector2(0,174)})==0,"source depth projection reaches the movement boundary")
	var skills := {"wheel":58,"psychic_release":32,"normal_wave":20,"ice_wave":21,"flame_wave":22,
		"psychic_rage":52,"upper_slash":46,"cancel_wave_combo":21,"auto_guard":3,"psychic_eye":88}
	for stream: String in skills:
		check(Program.stream_skill(ordinary,stream)==skills[stream],"ordinary KEY stream "+stream)
		check(Program.stream_skill(awakened,stream)==skills[stream],"awakened KEY stream "+stream)
	check(Program.stream_skill(ordinary,"unsupported")==-1,"unmapped stream cannot fall back to a skill")
	print("[COMPANION_PROGRAM] COMPLETE checks=",checks," failures=",failures)
	quit(1 if failures else 0)
