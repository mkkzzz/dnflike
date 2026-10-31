extends Node
## Integration regression. Touches the game only through debug/test_api.gd.
const TestAPI = preload("res://debug/test_api.gd")
const EventBus = preload("res://core/event_bus.gd")
const Box6 = preload("res://core/box6.gd")
const DetRng = preload("res://core/det_rng.gd")
const ContentDB = preload("res://content/api/content_db.gd")
const CombatSession = preload("res://combat/api/combat_session.gd")

var game
var api
var checks := 0
var failures := 0
var _trace: FileAccess

func before_tick() -> void:pass
func after_tick() -> void:
	if _trace != null:_trace.store_line(JSON.stringify(api.presentation_state()))

func _ready() -> void:
	api = TestAPI.new(game)
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--trace="):_trace = FileAccess.open(arg.substr(8),FileAccess.WRITE)
	call_deferred("run")

func check(value: bool,message: String) -> void:
	checks+=1
	if not value:
		failures+=1
		push_error("[DNF_TEST] FAIL "+message)
	else:print("[DNF_TEST] PASS "+message)

func ticks(count: int) -> void:
	for i in count:await get_tree().physics_frame

func key(code: int,pressed := true) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)

func tap(code: int) -> void:
	key(code,true)
	await ticks(1)
	key(code,false)

func run() -> void:
	await ticks(3)
	check_core()
	check_content()
	await run_combat()
	await run_kernel()
	await run_rooms()
	await run_session()
	if "--capture" in OS.get_cmdline_user_args():
		api.restart()
		api.set_god(true)
		api.spawn_dummy(Vector2(220,250))
		api.set_p("pos",Vector2(155,250))
		api.start_action("attack3")
		api.set_p("clock",150.0)
		await api.capture("combat_native")
		api.load_room(4,"up")
		await ticks(2)
		await api.capture("boss_native")
	print("[DNF_TEST] COMPLETE checks=%d failures=%d"%[checks,failures])
	if _trace != null:_trace.close()
	get_tree().quit(0 if failures==0 else 1)

func check_core() -> void:
	var bus = EventBus.new()
	var seen: Array = []
	bus.subscribe("combat.",func(e: Dictionary):seen.append(e["type"]))
	bus.subscribe("combat.hit",func(e: Dictionary):seen.append("exact"))
	var first: Dictionary = bus.emit("combat.hit",{"target":1})
	var second: Dictionary = bus.emit("map.door_used")
	check(seen==["exact","combat.hit"] and second["event_id"]==first["event_id"]+1,"event bus routes exact and module-prefix subscribers with unique ids")
	var right: AABB = Box6.to_world([10,0,0,20,5,5],Vector3(100,0,0),1)
	var left: AABB = Box6.to_world([10,0,0,20,5,5],Vector3(100,0,0),-1)
	check(right.position.x==110 and left.position.x==70 and left.size.x==20,"Box6 mirrors around the anchor when facing left")
	check(Box6.overlaps(right,AABB(Vector3(125,2,2),Vector3(10,1,1))) and not Box6.overlaps(right,AABB(Vector3(125,6,2),Vector3(10,1,1))),"Box6 overlap requires all three axes")
	var a = DetRng.new(42)
	var b = DetRng.new(42)
	check(a.next_float()==b.next_float() and a.range_int(0,999)==b.range_int(0,999),"deterministic random source repeats with the same seed")
	var orders: Array = game.view.hud.painters.map(func(w): return w.ORDER)
	var sorted := orders.duplicate()
	sorted.sort()
	check(orders.size()==8 and orders==sorted,"combat HUD widgets are discovered from their folder in draw order")
	var source := FileAccess.get_file_as_string("res://scripts/main.gd")
	check(not source.contains("draw_texture") and not source.contains("draw_rect") and not source.contains("player_view.present") and not source.contains("AudioStreamPlayer.new"),"battle simulation no longer draws or owns presentation nodes")

func check_content() -> void:
	check(api.manifest_schema()=="dnf_native_runtime/1","native local resource manifest loaded")
	check(api.room_count()==5,"five-room right-up-right-up route")
	check(api.clip("attack1")["duration_ms"]==600,"ANI milliseconds retained without frame-number guessing")
	check(api.clip("guard")["duration_ms"]==20000,"state-hold frames remain source metadata")
	var db = api.content()
	check(db.layer_of("clips/player/attack1")=="base" and db.layer_of("hitstop/hit_ms")=="adapt","content layers distinguish original base from adaptation values")
	check(db.conflicts.is_empty(),"current adaptation values never shadow original base data")
	var probe = ContentDB.new()
	probe.load_files("res://assets_local/manifest.json","res://data/combat.json","res://tests/content/override_fixture")
	var overridden: bool = probe.value("hitstop/hit_ms")==80 and probe.layer_of("hitstop/hit_ms")=="override"
	probe.set_override_enabled(false)
	check(overridden and probe.value("hitstop/hit_ms")==60 and probe.layer_of("hitstop/hit_ms")=="adapt","override layer wins and switching it off restores the baseline")
	probe.load_files("res://assets_local/manifest.json","res://tests/content/adapt_conflict.json","res://tests/content/none")
	check("clips/player/attack1/duration_ms" in probe.conflicts and probe.value("clips/player/attack1/duration_ms")==600,"adaptation cannot overwrite an original base value and the collision is reported")
	if not db.has_pack():
		print("[DNF_TEST] SKIP compiled content pack absent; run python tools/compile_dnf_content.py (needs sync --full)")
		return
	var info: Dictionary = db.pack_info()
	check(info["records"]>=500 and info["missing_references"]==0,"compiled original content pack loads with every reference resolved")
	check(db.original("character/swordman/attackinfo/attack3.atk","push_aside")==40 and db.original("character/swordman/attackinfo/attack3.atk","lift_up")==300,"original attack info knockback and launch values are queryable")
	var upper: String = db.index("swordman_skills").get("46","")
	check(upper=="skill/swordman/upperslash.skl" and db.original(upper,"dungeon")["cool_time"][0]==2000,"original skill ID table resolves and keeps the dungeon-context cool time")
	var stats: Dictionary = db.original("character/swordman/swordman.chr","stat_groups")["initial_value"]
	check(is_equal_approx(float(stats["jump_power"]),430) and db.original("character/swordman/swordman.chr","attack_infos").size()==3,"original character base stats and three-hit attack info list are queryable")
	var ani: Dictionary = db.original("character/swordman/animation/attack3.ani","timeline")[2]
	check(ani["attack_boxes"].size()==1 and is_equal_approx(float(ani["start_ms"]),100),"original ANI timeline exposes per-frame attack boxes with their start times")
	check_kernel_tables()

## F3~F5: every rule value below is read from original records, not from data/combat.json.
func check_kernel_tables() -> void:
	var t = api.table()
	check(t.problems.is_empty(),"kernel tables resolve every linked original file")
	var a1: Dictionary = api.move("attack1")
	var a3: Dictionary = api.move("attack3")
	check(String(a3["hits"][0]["source"])=="body" and String(a1["hits"][0]["source"]).begins_with("borrow:"),"attack3 uses its own ANI boxes; box-less attack1 borrows an original swordman box timeline")
	check(is_equal_approx(float(a1["hits"][0]["percent"]),85) and is_equal_approx(float(a3["hits"][0]["percent"]),120),"normal attack percent = 100 + original ATK damage bonus")
	var upper: Dictionary = api.move("upper")
	check(upper["mp"]==6 and upper["cool_ms"]==2000 and is_equal_approx(float(upper["hits"][0]["percent"]),120) and is_equal_approx(float(upper["hits"][0]["lift"]),350),"upper slash MP, cooldown, damage percent and launch come from the SKL dungeon level-1 row")
	var triple: Dictionary = api.move("triple")
	check(triple["stages"].size()==3 and triple["cool_ms"]==6000 and String(triple["stages"][2]["ani"])=="tripleslash3","triple slash has three original stages and its SKL cooldown")
	check(api.move("draw")["cool_ms"]==15000 and api.move("draw")["hits"][0]["kind"]=="object","draw slash hits through its original wave passive object")
	check(api.move("rage_slash")["hits"][2]["kind"]=="object" and String(api.move("rage_slash")["hits"][2]["object"]).ends_with("gorecross.obj"),"gore cross ends with its original cross passive object")
	var goblin: Dictionary = t.monsters["goblin"]
	check(is_equal_approx(float(goblin["hp"]),105) and goblin["attack_delay"]==1200 and String(goblin["motions"]["stay"])=="stay" and String(goblin["dir"]).ends_with("animation_goblin2"),"goblin stats and motions come from goblin.mob and the original level table (150 HP x 70%, attack delay, Animation_Goblin2)")
	check(t.monsters["goblin_thrower"].has("throw") and int(t.monsters["goblin_thrower"]["throw"]["frame"])==2 and is_equal_approx(float(t.monsters["goblin_thrower"]["throw"]["speed"]),250),"goblin thrower throws its original stone object on throw frame 2 at the particle speed")
	check(is_equal_approx(float(t.player["jump_power"]),430) and float(t.player["hp_max"])==180,"player jump power and default HP come from the CHR initial values")

func run_combat() -> void:
	api.set_god(true)
	var enemy: Dictionary = api.spawn_dummy(Vector2(190,250))
	api.set_p("pos",Vector2(125,250))
	var old_hits: int = api.hit_count()
	await tap(KEY_X)
	await ticks(5)
	check(api.hit_count()==old_hits,"attack windup does not deal early damage")
	await tap(KEY_X)
	await ticks(38)
	await tap(KEY_X)
	await ticks(95)
	check(api.hit_count()-old_hits>=3,"buffered three-cut combo produces distinct real hits")
	check(float(api.e(enemy,"hp"))<5000,"real monster health is reduced")
	check(api.combo_count()>=1 or api.hit_count()>=3,"combat hit bookkeeping advances")
	var hits: Array = api.bus().events_of("combat.hit")
	var damages: Array = api.bus().events_of("combat.damage")
	check(hits.size()>=3 and damages.size()==hits.size() and hits[-1]["target"]==enemy["id"],"every real hit publishes paired hit and damage events")
	api.restart()
	api.set_god(true)
	enemy = api.spawn_dummy(Vector2(190,172))
	api.set_p("pos",Vector2(125,280))
	await tap(KEY_X)
	await ticks(45)
	check(float(api.e(enemy,"hp"))==5000,"different depth lanes cannot be hit")
	api.restart()
	api.set_god(true)
	enemy = api.spawn_dummy(Vector2(180,250))
	api.set_p("pos",Vector2(125,250))
	await tap(KEY_Z)
	await ticks(16)
	check(float(api.e(enemy,"z"))>0 or float(api.e(enemy,"vz"))>0,"upper slash launches target into physical height")
	check(api.cooldown("upper")>0,"upper cooldown is active")
	var mp := float(api.p("mp"))
	var rejected: int = api.bus().events_of("combat.action_rejected").size()
	check(not api.start_action("upper",true),"cooldown prevents duplicate skill cast")
	check(is_equal_approx(mp,float(api.p("mp"))),"failed cast does not spend MP")
	var reasons: Array = api.bus().events_of("combat.action_rejected")
	check(reasons.size()==rejected+1 and reasons[-1]["reason"]=="cooldown","rejected cast reports its reason instead of being swallowed")
	await ticks(65)
	await tap(KEY_C)
	await ticks(8)
	check(float(api.p("z"))>0,"jump input raises sprite above independent ground root")
	var jump_root: Vector2 = api.p("pos")
	await tap(KEY_X)
	await ticks(6)
	check(String(api.p("action"))=="air_attack","airborne attack selects original jumpattack ANI")
	check(Vector2(api.p("pos")).y==jump_root.y,"jump height is not applied to depth coordinate")
	check(game.view.enemy_actors.size()==1 and game.view.enemy_actors.has(enemy["id"]),"view keeps exactly one actor per live simulation entity")
	await ticks(80)
	check(float(api.p("z"))==0,"jump eventually lands")
	api.set_p("state","idle")
	api.set_p("action","")
	var x := float(Vector2(api.p("pos")).x)
	key(KEY_LEFT)
	await ticks(8)
	key(KEY_LEFT,false)
	check(Vector2(api.p("pos")).x<x and int(api.p("facing"))==-1,"left input moves and faces left")
	await tap(KEY_3)
	check(api.weapon()=="greatsword" and api.view_texture().contains("greatsword"),"three-weapon bank switches to matching original pose set")
	api.start_action("attack1")
	await ticks(4)
	var action_clock := float(api.p("clock"))
	api.set_hitstop(100)
	await ticks(3)
	check(is_equal_approx(action_clock,float(api.p("clock"))),"hitstop freezes the sole action clock")
	await ticks(50)
	api.set_god(false)
	api.set_p("state","guard")
	api.set_p("invuln_ms",0.0)
	api.set_p("facing",1)
	var hp := float(api.p("hp"))
	api.damage_player(50,Vector2(api.p("pos"))+Vector2(30,0))
	check(is_equal_approx(hp-float(api.p("hp")),10),"frontal guard reduces damage by eighty percent")
	api.set_p("invuln_ms",0.0)
	hp = float(api.p("hp"))
	api.damage_player(50,Vector2(api.p("pos"))-Vector2(30,0))
	check(is_equal_approx(hp-float(api.p("hp")),50),"guard does not protect from behind")
	api.restart()
	api.set_god(true)
	api.spawn_dummy(Vector2(330,250))
	await tap(KEY_A)
	await ticks(2)
	check(String(api.p("action"))=="draw","A starts the original draw-slash timeline")
	check(api.effect_count()>0,"draw slash and actor share a spawned source effect timeline")
	await ticks(90)
	api.set_p("mp",api.p("mp")+200.0)
	await tap(KEY_S)
	await ticks(3)
	check(String(api.p("action"))=="triple" and int(api.p("stage"))==0,"S starts the first original triple-slash stage")
	await ticks(60)
	api.set_p("state","idle")
	api.set_p("action","")
	api.set_p("mp",500.0)
	await tap(KEY_F)
	await ticks(2)
	check(float(api.p("buff_ms"))>0 and String(api.p("action"))=="buff","F casts frenzy with its original buff motion")
	await ticks(40)
	await tap(KEY_D)
	await ticks(2)
	check(String(api.p("action"))=="rage_slash","D selects the gore-cross source animation")
	api.restart()
	api.set_god(true)
	api.spawn_dummy(Vector2(550,250))
	api.set_p("mp",500.0)
	api.start_action("triple")
	api.set_p("clock",100.0)
	api.set_p("queued_skill","upper")
	await ticks(5)
	check(api.p("action")=="triple","buffered skill cannot cut off the active slash window")
	await ticks(10)
	check(api.p("action")=="upper","buffered skill starts after the active window")
	api.restart()
	api.set_god(false)
	enemy = api.spawn_dummy(Vector2(165,250))
	api.set_e(enemy,"state","attack")
	api.set_e(enemy,"clock",0.0)
	api.set_e(enemy,"facing",-1)
	api.set_p("invuln_ms",0.0)
	hp = float(api.p("hp"))
	await ticks(10)
	check(float(api.p("hp"))==hp,"original goblin windup has no early contact damage")
	await ticks(8)
	check(float(api.p("hp"))<hp,"original goblin active frame delivers real damage")
	api.restart()
	api.set_god(true)
	api.spawn_dummy(Vector2(550,250))
	var before_backstep := Vector2(api.p("pos"))
	key(KEY_DOWN)
	await tap(KEY_C)
	key(KEY_DOWN,false)
	await ticks(3)
	check(String(api.p("state"))=="backstep" and float(api.p("z"))>0 and Vector2(api.p("pos")).x<before_backstep.x,"down + jump performs a back step: physical hop away from facing")
	check(api.view_pose()=="jump","back step uses the jump rise/fall poses")
	await ticks(40)
	check(String(api.p("state"))=="idle","back step lands back to idle")
	api.start_action("attack1")
	await ticks(4)
	var ghosts_before: int = api.ghost_count()
	key(KEY_DOWN)
	await tap(KEY_C)
	key(KEY_DOWN,false)
	await ticks(1)
	check(String(api.p("state"))=="backstep" and api.ghost_count()>ghosts_before,"back step cancels a normal attack and leaves an afterimage of the cut pose")
	await ticks(40)
	api.set_p("mp",500.0)
	api.start_action("rage_slash")
	await ticks(4)
	key(KEY_DOWN)
	await tap(KEY_C)
	key(KEY_DOWN,false)
	await ticks(1)
	check(String(api.p("action"))=="rage_slash","skills cannot be cancelled by a back step yet")
	await ticks(90)
	api.set_p("state","idle")
	api.clear_direction_taps()
	key(KEY_RIGHT)
	await ticks(3)
	await tap(KEY_X)
	await ticks(2)
	check(String(api.p("action"))=="attack1","holding a direction and pressing X is a normal attack, not a dash attack")
	key(KEY_RIGHT,false)
	await ticks(40)
	api.set_p("state","idle")
	api.set_p("action","")
	api.clear_direction_taps()
	await tap(KEY_RIGHT)
	key(KEY_RIGHT)
	await ticks(3)
	check(api.run_direction()==1 and api.view_pose()=="dash","same-direction double tap selects original running ANI")
	await tap(KEY_X)
	await ticks(2)
	check(String(api.p("action"))=="dash_attack","X out of a run starts the dash attack thrust")
	key(KEY_RIGHT,false)
	await ticks(40)
	check(not api.walkable(Vector2(600,150)) and api.walkable(Vector2(600,200)),"walkability comes from the original map pass grid")
	var blocked: Vector2 = api.move_in_world(Vector2(650,170),Vector2(0,-12))
	var free: Vector2 = api.move_in_world(Vector2(400,170),Vector2(0,-12))
	check(blocked.y==170 and free.y<170,"blocked map cells stop movement; open cells allow it")
	api.restart()
	api.set_god(true)
	api.spawn_dummy(Vector2(180,250))
	await tap(KEY_Z)
	await ticks(8)
	await tap(KEY_C)
	await ticks(25)
	check(float(api.p("z"))>0,"jump buffered through upper hitstop starts aerial chase in recovery")
	api.restart()
	api.set_god(true)
	api.spawn_dummy(Vector2(550,250))
	key(KEY_C)
	key(KEY_X)
	await ticks(2)
	key(KEY_C,false)
	key(KEY_X,false)
	check(api.p("action")=="air_attack","same-tick jump and attack selects airborne source pose")

## F3~F5 kernel behaviour: box judgement, ATK reactions, local hitstop, cues, objects, AI.
func run_kernel() -> void:
	var bus = api.bus()
	# Box judgement: just beyond the farthest attack1 box edge (143 px) nothing lands.
	api.restart()
	api.set_god(true)
	var far: Dictionary = api.spawn_dummy(Vector2(125+175,250))
	api.set_p("pos",Vector2(125,250))
	api.start_action("attack1")
	await ticks(30)
	check(float(api.e(far,"hp"))==5000,"target outside every original attack box is not hit")
	# attack1: [damage] reaction staggers on the ground, pushes away, freezes only the pair.
	api.restart()
	api.set_god(true)
	var target: Dictionary = api.spawn_dummy(Vector2(200,250))
	var bystander: Dictionary = api.spawn_monster(Vector2(560,180))
	api.set_p("pos",Vector2(125,250))
	var damages_before: int = bus.events_of("combat.damage").size()
	var sounds_before: int = bus.events_of("combat.cue").size()
	var x0 := float(Vector2(api.e(target,"pos")).x)
	api.start_action("attack1")
	var hit_tick := -1
	for i in 30:
		await ticks(1)
		if bus.events_of("combat.damage").size()>damages_before:
			hit_tick = i
			break
	check(hit_tick>=0 and String(api.e(target,"state"))=="hurt" and float(api.e(target,"z"))==0,"attack1 [damage] reaction staggers a grounded target without launching it")
	var dmg: Dictionary = bus.events_of("combat.damage")[-1]
	check(int(dmg["amount"])==21 and String(dmg["victim"])=="monster","damage = attack power 25 x (100-15)% from the original ATK")
	check(float(api.p("stuck_ms"))>0 and api.stuck(target)>0 and api.stuck(bystander)==0,"hitstop freezes only attacker and target, not the rest of the room")
	var cues: Array = bus.events_of("combat.cue").slice(sounds_before)
	var keys: Array = cues.map(func(e): return String(e["key"]))
	var wav: Array = api.table().weapon_wav(api.weapon())
	var info: Array = api.table().weapon_hit_info(api.weapon())
	var fx_prefix := "hit_cut_l" if float(info[2])>=100 else "hit_cut_s"
	check(String(wav[2]) in keys and keys.any(func(k): return String(k).begins_with(fx_prefix)),"weapon hit plays its CHR weapon hit sound and sized cut effect ("+api.weapon()+")")
	check(String(wav[0]) in keys,"attack swing plays the CHR weapon swing sound ("+api.weapon()+")")
	check(game.view.numbers.size()>0 and String(game.view.numbers[-1]["style"])=="damage","damage number uses the original white digit set")
	await ticks(20)
	check(float(Vector2(api.e(target,"pos")).x)>x0+3,"ATK push aside slides the target away from the attacker")
	# attack3: [down] + lift up 300 launches, then lands into the original down motion.
	api.set_p("state","idle")
	api.set_p("action","")
	api.set_e(target,"pos",Vector2(200,250))
	api.set_e(target,"state","idle")
	api.start_action("attack3")
	var launched := false
	for i in 40:
		await ticks(1)
		if float(api.e(target,"z"))>20:
			launched = true
			break
	check(launched,"attack3 [down] with lift up launches the target into the air")
	var downed := false
	for i in 90:
		await ticks(1)
		if String(api.e(target,"state"))=="down":
			downed = true
			break
	check(downed and String(api.enemy_ani(target)[0])=="down","launched target lands into its original down motion")
	# Gore cross: two slashes, then the original cross object spawns and hits.
	api.restart()
	api.set_god(true)
	target = api.spawn_dummy(Vector2(205,250))
	api.set_p("pos",Vector2(125,250))
	api.set_p("mp",500.0)
	var hits_before: int = api.hit_count()
	api.start_action("rage_slash")
	var saw_object := false
	for i in 110:
		await ticks(1)
		if api.object_count()>0:saw_object = true
	check(saw_object and api.hit_count()-hits_before>=2,"gore cross lands its slashes and spawns the cross object")
	# Draw slash wave reaches far targets through its passive object.
	api.restart()
	api.set_god(true)
	target = api.spawn_dummy(Vector2(125+190,250))
	api.set_p("pos",Vector2(125,250))
	api.set_p("mp",500.0)
	api.start_action("draw")
	await ticks(60)
	check(float(api.e(target,"hp"))<5000,"draw slash wave object hits a target 190 px away")
	# Triple slash: pressing S again continues to the next original stage.
	api.restart()
	api.set_god(true)
	target = api.spawn_dummy(Vector2(205,250))
	api.set_p("pos",Vector2(125,250))
	api.set_p("mp",500.0)
	hits_before = api.hit_count()
	api.start_action("triple")
	var max_stage := 0
	for i in 12:
		await tap(KEY_S)
		await ticks(9)
		max_stage = maxi(max_stage,int(api.p("stage")))
	check(max_stage==2,"repeated S walks the three triple-slash stages")
	check(api.hit_count()-hits_before>=3,"each triple-slash stage lands its own hit")
	# Monster AI from MOB fields: goblin approaches and its own attack box hits the player.
	api.restart()
	api.set_god(false)
	game.clear_monsters()
	api.set_p("pos",Vector2(200,250))
	api.set_p("hp",150.0)
	api.set_p("invuln_ms",0.0)
	var goblin: Dictionary = api.spawn_monster(Vector2(320,250))
	var start_x := float(Vector2(api.e(goblin,"pos")).x)
	var hp := float(api.p("hp"))
	var hurt := false
	for i in 400:
		await ticks(1)
		if float(api.p("hp"))<hp:
			hurt = true
			break
	check(float(Vector2(api.e(goblin,"pos")).x)<start_x-20,"goblin walks toward the player at its MOB move speed")
	check(hurt and String(bus.events_of("combat.damage")[-1]["victim"])=="player","goblin attack lands through its own attack box onto the player's damage box")
	check(game.view.numbers.size()>0 and String(game.view.numbers[-1]["style"])=="damage_taken","damage taken uses the original red digit set")
	check(api.view_enemy_texture(goblin).contains("mob_goblin"),"goblin is drawn from its own original Animation_Goblin2 body bank")
	# Thrower: keeps distance, throws the original stone object, which hits the player.
	api.restart()
	api.set_god(false)
	game.clear_monsters()
	api.set_p("pos",Vector2(150,250))
	api.set_p("hp",150.0)
	api.set_p("invuln_ms",0.0)
	api.spawn_monster(Vector2(330,250),"goblin_thrower")
	hp = float(api.p("hp"))
	var thrown := false
	hurt = false
	for i in 500:
		await ticks(1)
		if api.object_count()>0:thrown = true
		if float(api.p("hp"))<hp:
			hurt = true
			break
	check(thrown and hurt,"goblin thrower's stone object travels and hits the player")
	api.set_god(true)
	await run_feedback_fixes()

## 2026-10-23 user playtest fixes.
func run_feedback_fixes() -> void:
	# 1. Launched monsters use overturn.ani, whose frame carries [ROTATE] pi: drawn upside down above the ground.
	api.restart()
	var target: Dictionary = api.spawn_dummy(Vector2(200,250))
	api.set_e(target,"state","air")
	api.set_e(target,"z",40.0)
	await ticks(1)
	var actor = game.view.enemy_actors[target["id"]]
	check(actor.pose=="overturn" and is_equal_approx(absf(float(actor.sample()["items"]["8"])),3.140022039413452),"airborne monster pose is overturn with its original pi rotation")
	# 2. Upper slash: own motion (hitback.ani poses 51-59), own effects and swing sound.
	api.restart()
	api.spawn_dummy(Vector2(205,250))
	var cues_before: int = api.bus().events_of("combat.cue").size()
	api.start_action("upper")
	await ticks(1)
	check(api.view_pose()=="hitback" and String(api.move("upper")["ani"])=="hitback","upper slash plays its own original motion, not the 裂波斩 poses")
	await ticks(20)
	var keys: Array = api.bus().events_of("combat.cue").slice(cues_before).map(func(e): return String(e.get("key","")))
	check("upper1" in keys and "upper2" in keys and "UPPER_SLASH_01" in keys and "upper" in keys,"upper slash cues its upperslash effects, swing sound and voice")
	await ticks(40)
	# 3. Jump attack keeps steering in the air.
	api.restart()
	await tap(KEY_C)
	await ticks(4)
	await tap(KEY_X)
	var x0 := float(Vector2(api.p("pos")).x)
	key(KEY_RIGHT)
	await ticks(8)
	key(KEY_RIGHT,false)
	check(String(api.p("action"))=="air_attack" and float(Vector2(api.p("pos")).x)>x0+5,"jump attack can still move in the air")
	await ticks(60)
	# 5. Triple slash slides smoothly per stage and each stage may turn round.
	api.restart()
	api.spawn_dummy(Vector2(900,250))
	api.set_p("pos",Vector2(400,250))
	api.set_p("mp",500.0)
	api.set_p("facing",1)
	api.start_action("triple")
	var xs: Array = []
	for i in 30:
		await ticks(1)
		xs.append(float(Vector2(api.p("pos")).x))
	var steps: Array = []
	for i in range(1,xs.size()):steps.append(xs[i]-xs[i-1])
	check(xs[-1]-400>120 and steps[0]>steps[25] and steps.all(func(s): return s>=0),"first slash slides forward with a smooth decelerating motion")
	key(KEY_LEFT)
	await tap(KEY_S)
	await ticks(6)
	key(KEY_LEFT,false)
	var before_x := float(Vector2(api.p("pos")).x)
	await ticks(10)
	check(int(api.p("stage"))==1 and int(api.p("facing"))==-1 and float(Vector2(api.p("pos")).x)<before_x,"second slash turned left on request and slides that way")
	await ticks(60)
	# 7. Gore cross: crescent object on the caster; slash marks are cleared with the move.
	api.restart()
	api.spawn_dummy(Vector2(205,250))
	api.set_p("mp",500.0)
	api.start_action("rage_slash")
	var tag := String(api.p("fx_tag"))
	await ticks(5)
	check(api.effects_tagged(tag)>0,"gore cross slash marks are tagged with the running move")
	var obj_pos := Vector2.ZERO
	for i in 70:
		await ticks(1)
		if api.object_count()>0 and obj_pos==Vector2.ZERO:obj_pos = Vector2(api.objects()[0]["pos"])
	check(obj_pos.distance_to(Vector2(api.p("pos")))<1,"gore cross crescent object spawns on the caster's own anchor")
	await ticks(30)
	check(String(api.p("action"))=="" and api.effects_tagged(tag)==0,"no gore cross effect remains once the move has ended")
	# 9. Monster HP bar sits at the top of the screen and tracks the last monster hit.
	api.restart()
	target = api.spawn_monster(Vector2(200,250))
	api.set_e(target,"ai",false)
	check(api.monster_bar().is_empty(),"no monster bar before anything is hit")
	api.start_action("attack1")
	await ticks(12)
	var bar: Dictionary = api.monster_bar()
	check(bar.get("id",-1)==target["id"] and bar["rank"]=="normal" and bar["name"]=="哥布林" and bar["level"]>=1 and bar["hp"]<bar["max_hp"],"hit monster shows its name, level and HP in the top bar")
	var drawn: Array = game.view.hud.trace.filter(func(t): return t[0]=="m")
	check(drawn.any(func(t): return t[1]=="f1") and drawn.any(func(t): return String(t[1]).begins_with("face:")) and drawn.any(func(t): return t[1]=="f2"),"top bar draws the original monster_hp.img frame, face and HP line")
	var bar_src := FileAccess.get_file_as_string("res://ui/combat/widgets/monster_bars.gd")
	check(not bar_src.contains("h.rect("),"no program-drawn rectangle bars over monsters")
	api.load_room(4,"up")
	await ticks(2)
	bar = api.monster_bar()
	check(bar.get("rank","")=="boss" and int(bar["lines"])>1,"boss room shows the centred multi-line boss bar")

const SIDE_KEYS := {"left":KEY_LEFT,"right":KEY_RIGHT,"up":KEY_UP,"down":KEY_DOWN}

func walk_through(side: String) -> void:
	api.set_p("pos",api.door_point(side))
	api.unlock_doors()
	key(SIDE_KEYS[side])
	await ticks(3)
	key(SIDE_KEYS[side],false)
	await ticks(1)

func run_rooms() -> void:
	api.restart()
	api.set_god(true)
	check(api.room_placement()=="1_0:s3" and api.room_width()==1120,"first room is the original Lorien start map s3")
	check(api.monster_count()==4 and String(api.monster(0,"mob")).ends_with("goblin.mob"),"monsters spawn from the original map's own monster list")
	api.set_p("pos",Vector2(1000,250))
	await ticks(2)
	check(api.camera_x()>0 and api.camera_x()<=api.room_width()-640,"camera follows the player inside the wider original room")
	var locked_room: int = api.room_index()
	var first_side: String = api.room_next(0)
	await walk_through(first_side)
	check(api.room_index()==locked_room,"uncleared forward door is locked")
	api.set_p("pos",Vector2(540,249))
	var bus = api.bus()
	var defeated_before: int = bus.events_of("combat.monster_defeated").size()
	var finished_before: int = bus.events_of("combat.room_combat_finished").size()
	var monsters_in_room: int = api.monster_count()
	api.kill_all_monsters()
	await ticks(2)
	check(api.room_cleared(),"all monsters dead opens room doors")
	var defeated: Array = bus.events_of("combat.monster_defeated").slice(defeated_before)
	var finished_events: Array = bus.events_of("combat.room_combat_finished").slice(finished_before)
	check(defeated.size()==monsters_in_room and finished_events.size()==1,"each defeat and the room finish are reported exactly once")
	check(finished_events.size()==1 and finished_events[0]["run_id"]=="standalone" and finished_events[0]["room_id"]=="lorien:0","flow events carry run and room identity")
	await walk_through(first_side)
	check(api.room_index()==1 and api.room_placement()=="0_0:s2","cleared door advances to the neighbouring original cell")
	check(Vector2(api.p("pos")).distance_to(api.door_point("right"))<80,"entering spawns next to the paired gate on the far side")
	await walk_through("right")
	check(api.room_index()==1,"uncleared return door is also locked")
	api.kill_all_monsters()
	await ticks(2)
	await walk_through("right")
	check(api.room_index()==0 and api.room_cleared(),"return visit preserves cleared room state")
	check(api.monster_count()==0,"cleared room does not respawn monsters")
	api.load_room(1,"left")
	for next_index in range(2,5):
		api.kill_all_monsters()
		await ticks(2)
		await walk_through(api.room_next(api.room_index()))
		check(api.room_index()==next_index,"original route reaches room "+str(next_index)+" ("+api.room_placement()+")")
		check(float(api.p("invuln_ms"))>0,"paired door grants safe spawn guard for room "+str(next_index))
	check(api.room_placement()=="1_2:b3","last room is the original boss map b3")
	var boss := -1
	for i in api.monster_count():
		if api.monster(i,"chief"):boss = i
	check(boss>=0 and String(api.monster(boss,"mob")).ends_with("goblinthrower.mob"),"boss room spawns the original goblin thrower marked [boss] in the map")
	api.kill_all_monsters()
	await ticks(3)
	check(api.finished() and api.victory(),"boss clear enters victory result")
	check(not api.stage_cleared(),"boss result keeps every exit closed")
	await tap(KEY_R)
	await ticks(3)
	check(not api.finished() and api.room_index()==0 and not api.room_cleared(),"restart resets complete dungeon run")
	api.set_god(false)
	api.set_p("hp",1.0)
	api.set_p("invuln_ms",0.0)
	var defeats_before: int = bus.events_of("combat.player_defeated").size()
	api.damage_player(100,Vector2(api.p("pos"))+Vector2(30,0))
	check(api.finished() and not api.victory(),"player death enters defeat result")
	check(bus.events_of("combat.player_defeated").size()==defeats_before+1,"player defeat is reported once to the flow side")
	var enemy_state := []
	for enemy: Dictionary in game.monsters:enemy_state.append([enemy["id"],enemy["hp"],enemy["max_hp"]])
	var revive_player: Dictionary={"hp_max":game.max_hp,"mp_max":game.max_mp,"weapon":game.weapon}
	if game.numeric_player != null:
		revive_player.merge({"numbers":game.numeric_player.base.duplicate(true),"number_seed":game.numeric_player.seed.duplicate(true),
			"skills":game.skill_levels.duplicate(true),"element":game.numeric_player.element},true)
	var revive_spec: Dictionary={
		"run_id":game.run_id,"room_id":game.room_id,"death_id":game.last_defeat_id,
		"hp_percent":50,"mp_percent":50,"invulnerable_ms":3000,
		"player":revive_player}
	var stale_spec:=revive_spec.duplicate(true);stale_spec["death_id"]=0
	check(not game.can_revive(stale_spec),"stale death identity cannot revive the live battle")
	check(game.revive_player(revive_spec),"correct death identity revives the live battle")
	check(not game.finished and float(game.player["hp"])==game.max_hp*0.5 and float(game.player["mp"])==game.max_mp*0.5 and float(game.player["invuln_ms"])==3000,"revive restores configured HP, MP and protection")
	check(game.view.revive_fx_count==1,"revive plays the original use-coin effect once")
	var after_state := []
	for enemy: Dictionary in game.monsters:after_state.append([enemy["id"],enemy["hp"],enemy["max_hp"]])
	check(enemy_state==after_state,"revive keeps every enemy and its health")
	game.set_input_paused(false)
	game.player["hp"]=1.0;game.player["invuln_ms"]=0.0
	game.damage_player(100,Vector2(game.player["pos"])+Vector2(30,0))
	await ticks(1)
	await tap(KEY_R)
	api.set_god(true)
	await tap(KEY_ESCAPE)
	var elapsed: float = api.elapsed_ms()
	await ticks(6)
	check(api.paused() and api.elapsed_ms()==elapsed,"pause freezes dungeon simulation")
	await tap(KEY_ESCAPE)
	check(not api.paused(),"pause can be resumed")

## External mode: a flow root mounts its own combat scene through the public API.
func run_session() -> void:
	var host := Node.new()
	add_child(host)
	var session = CombatSession.new()
	var received: Array = []
	session.monster_defeated.connect(func(e: Dictionary):received.append(e))
	var finished_rooms: Array = []
	session.room_combat_finished.connect(func(e: Dictionary):finished_rooms.append(e))
	var external = session.mount(host)
	await ticks(2)
	check(external.player.is_empty() and session.read_view().is_empty(),"external mode waits for start_room instead of auto-starting")
	session.start_room({"run_id":"run-7","room_id":"lorien:2","room_index":2,"audio":{"muted":true},
		"player":{"hp":300,"mp":40,"hp_max":525,"mp_max":180,"damage_multiplier":1.2,"weapon":"katana"}})
	await ticks(1)
	var view: Dictionary = session.read_view()
	check(view["room_index"]==2 and view["hp"]==300 and absf(float(view["mp"])-40)<1 and view["weapon"]=="katana","start_room applies the room and the flow-supplied character snapshot")
	check(view["hp_max"]==525 and view["room"]==3 and view["room_count"]==5 and is_equal_approx(float(view["attack_damage"]),30),"flow-supplied max HP and equipment multiplier drive the actual combat")
	check(session.apply_effect({"kind":"heal","amount":150}) and session.read_view()["hp"]==450,"validated flow effect heals through the public entry")
	key(KEY_RIGHT)
	await ticks(1)
	session.pause()
	key(KEY_RIGHT,false)
	check(not external.held.get(KEY_RIGHT,false) and not session.apply_effect({"kind":"heal","amount":10}),"pausing drops held input and refuses effects")
	key(KEY_TAB)
	await ticks(1)
	key(KEY_TAB,false)
	check(external.job=="weaponmaster","flow-owned keys are ignored by a managed combat")
	await ticks(1)
	var paused_elapsed := float(external.elapsed_ms)
	await ticks(4)
	check(session.read_view()["paused"] and float(external.elapsed_ms)==paused_elapsed,"session pause freezes only the managed combat")
	session.resume()
	external.god_mode = true
	var count := 0
	for enemy: Dictionary in external.monsters:
		enemy["hp"] = 0
		enemy["death_ms"] = 800.0
		count += 1
	await ticks(3)
	check(received.size()==count and finished_rooms.size()==1,"session relays defeats and room finish as signals")
	check(finished_rooms.size()==1 and finished_rooms[0]["run_id"]=="run-7" and finished_rooms[0]["room_id"]=="lorien:2","relayed events keep the flow's run and room identity")
	check(finished_rooms.size()==1 and not finished_rooms[0]["final_room"] and finished_rooms[0]["stats"].has("time_ms"),"non-boss room finish is not final and carries settlement stats")
	var ids := {}
	for e: Dictionary in received:ids[e["event_id"]] = true
	check(ids.size()==received.size(),"flow-facing events have unique ids for idempotent rewards")
	session.stop()
	await ticks(2)
	check(not is_instance_valid(external) and session.read_view().is_empty(),"stop unloads the managed combat scene")
	host.queue_free()
