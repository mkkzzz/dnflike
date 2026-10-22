extends Node
var game
var checks := 0
var failures := 0

func before_tick() -> void:pass
func after_tick() -> void:pass

func _ready() -> void:
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

func target(point: Vector2) -> Dictionary:
	for enemy: Dictionary in game.monsters:
		enemy["visual"].queue_free()
	game.monsters.clear()
	var enemy: Dictionary = game.spawn_enemy(point)
	enemy["hp"] = 5000.0
	enemy["max_hp"] = 5000.0
	enemy["state"] = "hurt"
	enemy["hurt_ms"] = 100000.0
	return enemy

func run() -> void:
	await ticks(3)
	game.god_mode = true
	check(game.assets.get("schema","")=="dnf_native_runtime/1","native local resource manifest loaded")
	check(game.rules["rooms"].size()==5,"five-room right-up-right-up route")
	check(game.player_clips["attack1"]["duration_ms"]==600,"ANI milliseconds retained without frame-number guessing")
	check(game.player_clips["guard"]["duration_ms"]==20000,"state-hold frames remain source metadata")
	var enemy := target(Vector2(190,250))
	game.player["pos"] = Vector2(125,250)
	var old_hits: int = game.hit_count
	await tap(KEY_X)
	await ticks(5)
	check(game.hit_count==old_hits,"attack windup does not deal early damage")
	await tap(KEY_X)
	await ticks(38)
	await tap(KEY_X)
	await ticks(95)
	check(game.hit_count-old_hits>=3,"buffered three-cut combo produces distinct real hits")
	check(float(enemy["hp"])<5000,"real monster health is reduced")
	check(game.combo_count>=1 or game.hit_count>=3,"combat hit bookkeeping advances")
	game.restart()
	game.god_mode = true
	enemy = target(Vector2(190,172))
	game.player["pos"] = Vector2(125,280)
	await tap(KEY_X)
	await ticks(45)
	check(float(enemy["hp"])==5000,"different depth lanes cannot be hit")
	game.restart()
	game.god_mode = true
	enemy = target(Vector2(180,250))
	game.player["pos"] = Vector2(125,250)
	await tap(KEY_Z)
	await ticks(16)
	check(float(enemy["z"])>0 or float(enemy["vz"])>0,"upper slash launches target into physical height")
	check(float(game.player["cooldowns"].get("upper",0))>0,"upper cooldown is active")
	var mp := float(game.player["mp"])
	check(not game.start_action("upper",true),"cooldown prevents duplicate skill cast")
	check(is_equal_approx(mp,float(game.player["mp"])),"failed cast does not spend MP")
	await ticks(65)
	await tap(KEY_C)
	await ticks(8)
	check(float(game.player["z"])>0,"jump input raises sprite above independent ground root")
	var jump_root: Vector2 = game.player["pos"]
	await tap(KEY_X)
	await ticks(6)
	check(String(game.player["action"])=="air_attack","airborne attack selects original jumpattack ANI")
	check(Vector2(game.player["pos"]).y==jump_root.y,"jump height is not applied to depth coordinate")
	await ticks(80)
	check(float(game.player["z"])==0,"jump eventually lands")
	game.player["state"] = "idle"
	game.player["action"] = ""
	var x := float(Vector2(game.player["pos"]).x)
	key(KEY_LEFT)
	await ticks(8)
	key(KEY_LEFT,false)
	check(Vector2(game.player["pos"]).x<x and int(game.player["facing"])==-1,"left input moves and faces left")
	await tap(KEY_3)
	check(game.weapon=="greatsword" and String(game.player_view.bank["texture"]).contains("greatsword"),"three-weapon bank switches to matching original pose set")
	game.start_action("attack1")
	await ticks(4)
	var action_clock := float(game.player["clock"])
	game.hitstop_ms = 100
	await ticks(3)
	check(is_equal_approx(action_clock,float(game.player["clock"])),"hitstop freezes the sole action clock")
	await ticks(50)
	game.god_mode = false
	game.player["state"] = "guard"
	game.player["invuln_ms"] = 0.0
	game.player["facing"] = 1
	var hp := float(game.player["hp"])
	game.damage_player(50,Vector2(game.player["pos"])+Vector2(30,0))
	check(is_equal_approx(hp-float(game.player["hp"]),10),"frontal guard reduces damage by eighty percent")
	game.player["invuln_ms"] = 0.0
	hp = float(game.player["hp"])
	game.damage_player(50,Vector2(game.player["pos"])-Vector2(30,0))
	check(is_equal_approx(hp-float(game.player["hp"]),50),"guard does not protect from behind")
	game.restart()
	game.god_mode = true
	game.job = "weaponmaster"
	target(Vector2(300,250))
	await tap(KEY_A)
	await ticks(2)
	check(String(game.player["action"])=="draw","swordmaster A starts original draw-slash timeline")
	check(game.effects.size()>0,"draw slash and actor share a spawned source effect timeline")
	await ticks(90)
	await tap(KEY_S)
	await ticks(3)
	check(String(game.player["action"])=="thrust","swordmaster S starts multi-hit thrust")
	await ticks(55)
	await tap(KEY_TAB)
	await tap(KEY_A)
	await ticks(2)
	check(game.job=="berserker" and float(game.player["buff_ms"])>0,"berserker blood rage applies attack-speed buff")
	await tap(KEY_S)
	await ticks(2)
	check(String(game.player["action"])=="rage_slash","berserker S selects two-cut source animation")
	game.restart()
	game.god_mode = true
	var locked_room: int = game.room_index
	game.player["pos"] = Vector2(603,249)
	game.door_lock_ms = 0
	key(KEY_RIGHT)
	await ticks(3)
	key(KEY_RIGHT,false)
	check(game.room_index==locked_room,"uncleared forward door is locked")
	game.player["pos"] = Vector2(540,249)
	game.props[1]["broken"] = true
	for e: Dictionary in game.monsters:e["hp"]=0;e["death_ms"]=800.0
	await ticks(2)
	check(game.room_cleared,"all monsters dead opens room doors")
	game.player["pos"] = Vector2(603,249)
	key(KEY_RIGHT)
	await ticks(3)
	key(KEY_RIGHT,false)
	check(game.room_index==1,"cleared right door advances to room one")
	check(game.player["pos"].x<120,"paired door uses safe opposite-side spawn")
	game.player["pos"] = Vector2(37,249)
	game.door_lock_ms = 0
	key(KEY_LEFT)
	await ticks(2)
	key(KEY_LEFT,false)
	check(game.room_index==1,"uncleared return door is also locked")
	for e: Dictionary in game.monsters:e["hp"]=0;e["death_ms"]=800.0
	await ticks(2)
	key(KEY_LEFT)
	await ticks(3)
	key(KEY_LEFT,false)
	check(game.room_index==0 and game.room_cleared,"return visit preserves cleared room state")
	check(game.monsters.is_empty(),"cleared room does not respawn monsters")
	check(game.props[1]["broken"],"broken object persists across room return")
	# Traverse all remaining directions through the actual door/input path.
	game.load_room(1,"right")
	for next_index in range(2,5):
		game.player["pos"] = Vector2(300,245)
		for e: Dictionary in game.monsters:e["hp"]=0;e["death_ms"]=800.0
		await ticks(2)
		var side: String = game.rules["rooms"][game.room_index]["next"]
		game.player["pos"] = game.door_point(side)
		game.door_lock_ms = 0.0
		await tap(KEY_UP if side=="up" else KEY_RIGHT)
		await ticks(2)
		check(game.room_index==next_index,"actual four-direction route reaches room "+str(next_index))
		check(float(game.player["invuln_ms"])>0,"paired door grants safe spawn guard for room "+str(next_index))
	game.load_room(4,"up")
	check(game.monsters[0]["chief"],"boss room spawns original alternate goblin appearance")
	for e: Dictionary in game.monsters:e["hp"]=0;e["death_ms"]=800.0
	await ticks(3)
	check(game.finished and game.victory,"boss clear enters victory result")
	check(not game.stage.cleared,"boss result keeps every exit closed")
	await tap(KEY_R)
	await ticks(3)
	check(not game.finished and game.room_index==0 and not game.room_cleared,"restart resets complete dungeon run")
	game.god_mode = false
	game.player["hp"] = 1.0
	game.player["invuln_ms"] = 0.0
	game.damage_player(100,Vector2(game.player["pos"])+Vector2(30,0))
	check(game.finished and not game.victory,"player death enters defeat result")
	await tap(KEY_R)
	game.god_mode = true
	await tap(KEY_ESCAPE)
	var elapsed := float(game.elapsed_ms)
	await ticks(6)
	check(game.paused and game.elapsed_ms==elapsed,"pause freezes dungeon simulation")
	await tap(KEY_ESCAPE)
	check(not game.paused,"pause can be resumed")
	game.restart()
	game.god_mode = true
	target(Vector2(550,250))
	game.start_action("thrust")
	game.player["clock"] = 400.0
	game.player["queued_skill"] = "upper"
	await ticks(5)
	check(game.player["action"]=="thrust","buffered skill cannot cut off final native thrust hit window")
	await ticks(10)
	check(game.player["action"]=="upper","buffered skill starts after final native hit window")
	game.restart()
	game.god_mode = false
	enemy = target(Vector2(165,250))
	enemy["state"] = "attack"
	enemy["clock"] = 0.0
	enemy["facing"] = -1
	game.player["invuln_ms"] = 0.0
	hp = float(game.player["hp"])
	await ticks(10)
	check(float(game.player["hp"])==hp,"original goblin windup has no early contact damage")
	await ticks(8)
	check(float(game.player["hp"])<hp,"original goblin active frame delivers real damage")
	game.restart()
	game.god_mode = true
	target(Vector2(550,250))
	var before_backstep := Vector2(game.player["pos"])
	await tap(KEY_V)
	await ticks(3)
	check(float(game.player["z"])>0 and Vector2(game.player["pos"]).x<before_backstep.x,"backstep combines original retreat pose with physical hop")
	await ticks(40)
	game.player["state"] = "idle"
	game.last_direction_tap.clear()
	await tap(KEY_RIGHT)
	key(KEY_RIGHT)
	await ticks(3)
	check(game.run_direction==1 and game.player_view.pose=="dash","same-direction double tap selects original running ANI")
	key(KEY_RIGHT,false)
	var blocked: Vector2 = game.move_in_world(Vector2(224,205),Vector2(14,0))
	var behind: Vector2 = game.move_in_world(Vector2(224,180),Vector2(14,0))
	var in_front: Vector2 = game.move_in_world(Vector2(224,230),Vector2(14,0))
	check(blocked.x==224,"solid prop root blocks movement through its footprint")
	check(behind.x>224 and in_front.x>224,"same prop permits passage behind and in front")
	check(game.prop_views[2].z_index==int(game.props[2]["pos"].y),"foreground prop sorting is based on ground root")
	game.restart()
	game.god_mode = true
	target(Vector2(180,250))
	await tap(KEY_Z)
	await ticks(8)
	await tap(KEY_C)
	await ticks(25)
	check(float(game.player["z"])>0,"jump buffered through upper hitstop starts aerial chase in recovery")
	game.restart()
	game.god_mode = true
	target(Vector2(550,250))
	key(KEY_C)
	key(KEY_X)
	await ticks(2)
	key(KEY_C,false)
	key(KEY_X,false)
	check(game.player["action"]=="air_attack","same-tick jump and attack selects airborne source pose")
	if "--capture" in OS.get_cmdline_user_args():
		game.restart()
		game.god_mode = true
		target(Vector2(220,250))
		game.player["pos"] = Vector2(155,250)
		game.start_action("attack3")
		game.player["clock"] = 150.0
		game.paused = true
		game.paused = false
		await game.capture_frame("combat_native")
		game.load_room(4,"up")
		await ticks(2)
		await game.capture_frame("boss_native")
	print("[DNF_TEST] COMPLETE checks=%d failures=%d"%[checks,failures])
	get_tree().quit(0 if failures==0 else 1)
