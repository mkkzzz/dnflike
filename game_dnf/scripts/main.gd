extends Node2D
## Transitional battle scene: simulation + composition. Presentation lives in view/ and
## ui/combat/ and only consumes snapshot() and combat events (doc 29, F1).
const TestDrive = preload("res://scripts/test_drive.gd")
const EventBus = preload("res://core/event_bus.gd")
const ContentDB = preload("res://content/api/content_db.gd")
const CombatSession = preload("res://combat/api/combat_session.gd")
const BattleView = preload("res://view/battle_view.gd")

## Set before entering the tree when a flow root manages this scene (see CombatSession.mount).
var external_mode := false
var bus = EventBus.new()
var content = ContentDB.new()
var session
var view
var run_id := "standalone"
var room_id := ""
var assets: Dictionary = {}
var rules: Dictionary = {}
var player_clips: Dictionary = {}
var monster_clips: Dictionary = {}
# Aliases into the view kept for the flow-side transition bridge (flow/legacy_combat_port.gd).
var player_view
var hud
var music: AudioStreamPlayer
var voice_pool: Array = []
var sound_streams: Dictionary = {}
var player: Dictionary = {}
var monsters: Array = []
var props: Array = []
var room_index := 0
var room_cleared := false
var room_snapshots: Dictionary = {}
var doors: Array = []
var held: Dictionary = {}
var taps: Dictionary = {}
var requests: Array = []
var last_direction_tap: Dictionary = {}
var run_direction := 0
var hitstop_ms := 0.0
var action_seq := 0
var _next_entity_id := 1
var toast := ""
var toast_ms := 0.0
var elapsed_ms := 0.0
var damage_taken := 0
var hit_count := 0
var combo_count := 0
var combo_ms := 0.0
var paused := false
var finished := false
var victory := false
var help_visible := false
var show_collision := false
var god_mode := false
var job := "weaponmaster"
var weapon := "shortsword":
	set(value):
		weapon = value
		bus.emit("combat.appearance_changed",{"entity_id":0,"weapon":value})
var missing_assets := false
var door_lock_ms := 0.0
var test_drive
var _capture := false
var _frame := 0
var _muted := false:
	set(value):
		_muted = value
		if view != null:view.audio.muted = value

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	if not content.load_files("res://assets_local/manifest.json","res://data/combat.json","res://data/override"):
		missing_assets = true
		queue_redraw()
		return
	assets = content.runtime
	rules = content.rules()
	player_clips = content.clips("player")
	monster_clips = content.clips("goblin")
	view = BattleView.new()
	add_child(view)
	view.setup(assets,player_clips,monster_clips,bus,weapon)
	player_view = view.player_actor
	hud = view.hud
	music = view.audio.music
	voice_pool = view.audio.voice_pool
	sound_streams = view.audio.sound_streams
	# Managed mode leaves dungeon BGM to the flow side; tests never start it.
	if not external_mode and not "--test" in OS.get_cmdline_user_args():view.audio.start_music()
	if not external_mode:
		session = CombatSession.new()
		session.attach(self)
		restart()
	_capture = "--capture" in OS.get_cmdline_user_args()
	if "--test" in OS.get_cmdline_user_args():
		_muted = true
		if not external_mode:
			test_drive = TestDrive.new()
			test_drive.game = self
			add_child(test_drive)
	if not external_mode:get_window().title = "格兰之森 · 新版战斗验证"
	if "--review" in OS.get_cmdline_user_args():paused = true

func _notification(what: int) -> void:
	if what==NOTIFICATION_WM_WINDOW_FOCUS_OUT and not player.is_empty() and not "--test" in OS.get_cmdline_user_args():
		held.clear()
		requests.clear()
		if not finished:paused = true

func restart() -> void:
	begin_room({"run_id":"standalone","room_index":0,"from":"start"})
	notice("格兰之森 · 清除怪物，继续深入")

## Spec fields (contract v1): run_id, room_id, room_index (transitional trial route),
## from (entry side), player {hp, mp, job, weapon}. Long-term profile data stays with flow.
func begin_room(spec: Dictionary) -> void:
	player = {"pos":Vector2(125,250),"z":0.0,"vz":0.0,"air_ms":0.0,
		"hp":float(rules["player"]["hp"]),"mp":float(rules["player"]["mp"]),
		"facing":1,"state":"idle","action":"","clock":0.0,"motion_clock":0.0,
		"hurt_ms":0.0,"invuln_ms":0.0,"flash_ms":0.0,"landing_ms":0.0,
		"buff_ms":0.0,"cooldowns":{},"hits":{},"queued_combo":false,"queued_skill":"","queued_jump":false}
	var snapshot: Dictionary = spec.get("player",{})
	if snapshot.has("hp"):player["hp"] = clampf(float(snapshot["hp"]),1,float(rules["player"]["hp"]))
	if snapshot.has("mp"):player["mp"] = clampf(float(snapshot["mp"]),0,float(rules["player"]["mp"]))
	if snapshot.get("job","") in ["weaponmaster","berserker"]:job = String(snapshot["job"])
	if assets["players"].has(String(snapshot.get("weapon",""))):weapon = String(snapshot["weapon"])
	run_id = String(spec.get("run_id","standalone"))
	room_snapshots.clear()
	finished = false
	victory = false
	paused = false
	elapsed_ms = 0
	damage_taken = 0
	hit_count = 0
	combo_count = 0
	requests.clear()
	held.clear()
	taps.clear()
	hitstop_ms = 0
	load_room(clampi(int(spec.get("room_index",0)),0,rules["rooms"].size()-1),String(spec.get("from","start")))
	if spec.has("room_id"):room_id = String(spec["room_id"])

func _input(event: InputEvent) -> void:
	if not event is InputEventKey:return
	var key_event := event as InputEventKey
	var code := int(key_event.physical_keycode if key_event.physical_keycode != 0 else key_event.keycode)
	held[code] = key_event.pressed
	if not key_event.pressed or key_event.echo:return
	taps[code] = true
	if missing_assets:return
	match code:
		KEY_F1:help_visible = not help_visible
		KEY_ESCAPE:paused = not paused
		KEY_R:
			if finished and not external_mode:restart()
		KEY_F2:
			show_collision = not show_collision
			view.set_debug_collision(show_collision)
		KEY_F3:
			get_window().size = Vector2i(1920,1080) if get_window().size.x < 1920 else Vector2i(1280,720)
		KEY_M:
			_muted = not _muted
			music.volume_db = -80 if _muted else -28
		KEY_TAB:
			if player.get("state","") != "action":
				job = "berserker" if job == "weaponmaster" else "weaponmaster"
				notice("职业切换："+("狂战士" if job == "berserker" else "剑魂"))
		KEY_1,KEY_2,KEY_3:
			weapon = ["shortsword","katana","greatsword"][code-KEY_1]
		KEY_LEFT,KEY_RIGHT:
			var direction := -1 if code == KEY_LEFT else 1
			var now := Time.get_ticks_msec()
			if now-int(last_direction_tap.get(direction,-1000)) < 240:run_direction = direction
			last_direction_tap[direction] = now
		KEY_X,KEY_Z,KEY_A,KEY_S,KEY_C,KEY_SPACE,KEY_V:
			if not paused and not finished:requests.append(code)

func notice(message: String) -> void:
	toast = message
	toast_ms = 2200

func _physics_process(delta: float) -> void:
	_frame += 1
	if missing_assets or player.is_empty():return
	if test_drive != null:test_drive.before_tick()
	var ms := delta*1000
	toast_ms = maxf(0,toast_ms-ms)
	bus.tick = _frame
	bus.time_ms = elapsed_ms
	var sim_ms := 0.0
	if not paused and not finished:
		elapsed_ms += ms
		if hitstop_ms > 0:
			hitstop_ms = maxf(0,hitstop_ms-ms)
			consume_buffer()
		else:
			step_game(ms)
			sim_ms = ms
	view.present(view_snapshot(),ms,sim_ms)
	taps.clear()
	if test_drive != null:test_drive.after_tick()
	if _capture and _frame in [25,130,260,400]:
		capture_frame("frame_%04d"%_frame)

func consume_buffer() -> void:
	var retained: Array = []
	for code: int in requests:
		if code == KEY_X and String(player["action"]).begins_with("attack"):
			player["queued_combo"] = true
		elif code in [KEY_Z,KEY_A,KEY_S]:player["queued_skill"] = skill_for_key(code)
		elif code in [KEY_C,KEY_SPACE,KEY_V]:retained.append(code)
	requests = retained

func skill_for_key(code: int) -> String:
	if code == KEY_Z:return "upper"
	if code == KEY_A:return "draw" if job == "weaponmaster" else "buff"
	return "thrust" if job == "weaponmaster" else "rage_slash"

func step_game(ms: float) -> void:
	var dt := ms/1000
	player["invuln_ms"] = maxf(0,float(player["invuln_ms"])-ms)
	player["flash_ms"] = maxf(0,float(player["flash_ms"])-ms)
	player["buff_ms"] = maxf(0,float(player["buff_ms"])-ms)
	player["landing_ms"] = maxf(0,float(player["landing_ms"])-ms)
	door_lock_ms = maxf(0,door_lock_ms-ms)
	for name: String in player["cooldowns"]:
		player["cooldowns"][name] = maxf(0,float(player["cooldowns"][name])-dt)
	player["mp"] = minf(float(rules["player"]["mp"]),float(player["mp"])+dt*2.2)
	combo_ms = maxf(0,combo_ms-ms)
	if combo_ms <= 0:combo_count = 0
	player["motion_clock"] = float(player["motion_clock"])+ms
	var move := Vector2(float(bool(held.get(KEY_RIGHT,false)))-float(bool(held.get(KEY_LEFT,false))),float(bool(held.get(KEY_DOWN,false)))-float(bool(held.get(KEY_UP,false))))
	if move.x == 0 or signi(int(move.x)) != run_direction:run_direction = 0
	if move.length_squared()>1:move = move.normalized()
	var state: String = player["state"]
	for code: int in requests:
		if code in [KEY_C,KEY_SPACE]:
			if player["state"]=="action" and player["action"]=="upper":
				player["queued_jump"] = true
			elif state in ["idle","move","guard"] and float(player["z"])==0:
				player["vz"] = float(rules["player"]["jump_velocity"])
				player["air_ms"] = 0.0
				player["state"] = "jump"
				play_sound("jump")
		elif code == KEY_V:
			if state in ["idle","move","guard"] and float(player["z"])==0:
				player["state"] = "backstep"
				player["clock"] = 0.0
				player["vz"] = 220.0
				player["invuln_ms"] = 110.0
		elif code == KEY_X:
			if String(player["state"]) == "action":
				if String(player["action"]).begins_with("attack"):player["queued_combo"] = true
			else:start_action("air_attack" if float(player["z"])>0 or float(player["vz"])>0 else "dash_attack" if run_direction!=0 else "attack1")
		elif code in [KEY_Z,KEY_A,KEY_S]:
			var requested := skill_for_key(code)
			if String(player["state"]) == "action":player["queued_skill"] = requested
			else:start_action(requested)
	requests.clear()
	state = player["state"]
	if state == "action":
		var action: String = player["action"]
		var rule: Dictionary = rules["moves"][action]
		var old_clock := float(player["clock"])
		var speed := 1.25 if float(player["buff_ms"])>0 and (action.begins_with("attack") or action=="thrust") else 1.0
		player["clock"] = old_clock+ms*speed
		if action=="draw" and old_clock<550 and float(player["clock"])>=550:play_sound("draw")
		var duration := action_duration(action)
		var advance := float(rule.get("step",0))*ms*speed/maxf(1,duration)
		move_player(Vector2(advance*int(player["facing"]),0))
		apply_player_hits(old_clock,float(player["clock"]))
		var cancel_at := duration*0.66
		for active_window: Array in rule["windows"]:cancel_at=maxf(cancel_at,float(active_window[1]))
		if float(player["clock"])>=cancel_at and bool(player["queued_jump"]) and action=="upper":
			player["state"] = "jump"
			player["action"] = ""
			player["vz"] = float(rules["player"]["jump_velocity"])
			player["air_ms"] = 0.0
			player["queued_jump"] = false
			play_sound("jump")
		elif float(player["clock"])>=cancel_at and player["queued_skill"]!="":
			var requested: String = player["queued_skill"]
			player["queued_skill"] = ""
			start_action(requested,true)
		elif float(player["clock"])>=duration:
			if bool(player["queued_combo"]) and action in ["attack1","attack2"]:
				start_action("attack2" if action=="attack1" else "attack3",true)
			else:
				player["state"] = "jump" if float(player["z"])>0 else "idle"
				player["action"] = ""
	elif state == "hurt":
		player["hurt_ms"] = maxf(0,float(player["hurt_ms"])-ms)
		if float(player["hurt_ms"])<=0:player["state"] = "idle"
	elif state == "backstep":
		player["clock"] = float(player["clock"])+ms
		move_player(Vector2(-int(player["facing"])*150*dt,0))
		if float(player["clock"])>=470:player["state"] = "idle"
	else:
		if held.get(KEY_G,false) and float(player["z"])==0 and float(player["vz"])<=0:
			player["state"] = "guard"
			if move.x!=0:player["facing"] = 1 if move.x>0 else -1
		elif move.length_squared()>0:
			if move.x!=0:player["facing"] = 1 if move.x>0 else -1
			var speed := float(rules["player"]["run_speed"] if run_direction!=0 else rules["player"]["walk_speed"])
			if float(player["buff_ms"])>0:speed *= 1.2
			move_player(Vector2(move.x*speed,move.y*speed*0.58)*dt)
			player["state"] = "jump" if float(player["z"])>0 else "move"
		else:
			player["state"] = "jump" if float(player["z"])>0 else "idle"
	if float(player["z"])>0 or float(player["vz"])>0:
		player["air_ms"] = float(player["air_ms"])+ms
		player["z"] = maxf(0,float(player["z"])+float(player["vz"])*dt)
		player["vz"] = float(player["vz"])-float(rules["player"]["gravity"])*dt
		if float(player["z"])==0 and float(player["vz"])<0:
			player["vz"] = 0.0
			player["landing_ms"] = 100.0
			if String(player["state"]) in ["jump","backstep"]:player["state"] = "idle"
	for enemy: Dictionary in monsters:update_enemy(enemy,ms)
	for prop: Dictionary in props:
		if prop.get("broken",false):prop["broken_ms"] = float(prop.get("broken_ms",0))+ms
	var all_dead := true
	for enemy: Dictionary in monsters:
		if float(enemy["hp"])<=0:report_defeat(enemy)
		if float(enemy["hp"])>0 or float(enemy["death_ms"])<820:all_dead = false
	if all_dead and not room_cleared:
		room_cleared = true
		room_snapshots[room_index] = {"cleared":true,"props":props.duplicate(true)}
		var boss := bool(rules["rooms"][room_index].get("boss",false))
		bus.emit("combat.room_combat_finished",flow_payload({"boss":boss}))
		if boss:
			finished = true
			victory = true
		else:notice("房间清空 · 通道已开启")
	if room_cleared and not finished and door_lock_ms<=0:
		for door: Dictionary in doors:
			if Vector2(player["pos"]).distance_to(door["pos"])<24 and (move.length()>0 or taps.get(KEY_E,false)):
				load_room(int(door["to"]),String(door["side"]))
				break

func action_duration(action: String) -> float:
	return float(player_clips[String(rules["moves"][action]["ani"])]["duration_ms"])

func flow_payload(extra := {}) -> Dictionary:
	var payload := {"run_id":run_id,"room_id":room_id,"room_index":room_index,
		"stats":{"elapsed_ms":elapsed_ms,"hit_count":hit_count,"damage_taken":damage_taken},
		"player":{"hp":float(player["hp"]),"mp":float(player["mp"]),"job":job,"weapon":weapon}}
	payload.merge(extra,true)
	return payload

func report_defeat(enemy: Dictionary) -> void:
	if enemy.get("defeat_reported",false):return
	enemy["defeat_reported"] = true
	# Trial appearance keys, not verified original monster IDs (DNF-D013).
	bus.emit("combat.monster_defeated",{"run_id":run_id,"room_id":room_id,"room_index":room_index,
		"entity_id":enemy["id"],"monster_id":"trial/goblin_chief" if enemy["chief"] else "trial/goblin",
		"position":Vector2(enemy["pos"])})

func reject_action(name: String, reason: String) -> bool:
	bus.emit("combat.action_rejected",{"entity_id":0,"action":name,"reason":reason})
	return false

func start_action(name: String, cancel := false) -> bool:
	if name=="buff":
		if float(player["cooldowns"].get("buff",0))>0:return reject_action(name,"cooldown")
		if float(player["mp"])<15:return reject_action(name,"mp")
		player["buff_ms"] = 8000.0
		player["cooldowns"]["buff"] = 10.0
		player["mp"] = float(player["mp"])-15
		notice("血怒 · 攻击与移动加速")
		bus.emit("combat.action_started",{"entity_id":0,"action":name,"instance":0})
		return true
	if not rules["moves"].has(name):return reject_action(name,"unknown")
	if (float(player["z"])>0 or float(player["vz"])>0) and name!="air_attack":return reject_action(name,"state")
	if not cancel and String(player["state"]) in ["hurt","dead","backstep","action"]:return reject_action(name,"state")
	var move: Dictionary = rules["moves"][name]
	if float(player["cooldowns"].get(name,0))>0:return reject_action(name,"cooldown")
	if float(player["mp"])<float(move.get("mp",0)):return reject_action(name,"mp")
	player["mp"] = float(player["mp"])-float(move.get("mp",0))
	player["cooldowns"][name] = float(move.get("cooldown",0))
	player["state"] = "action"
	player["action"] = name
	player["clock"] = 0.0
	player["hits"] = {}
	player["queued_combo"] = false
	player["queued_skill"] = ""
	player["queued_jump"] = false
	action_seq += 1
	bus.emit("combat.action_started",{"entity_id":0,"action":name,"instance":action_seq})
	if move.has("fx"):spawn_effect(String(move["fx"]),player["pos"],int(player["facing"]),float(player["z"]))
	play_sound("swing3" if name=="attack3" else "swing2" if name=="attack2" else "upper" if name=="upper" else "draw_ready" if name=="draw" else "thrust" if name=="thrust" else "swing1")
	return true

func apply_player_hits(old_ms: float,new_ms: float) -> void:
	var action: String = player["action"]
	var rule: Dictionary = rules["moves"][action]
	var windows: Array = rule["windows"]
	for i in windows.size():
		var window: Array = windows[i]
		if new_ms < float(window[0]) or old_ms >= float(window[1]):continue
		for enemy: Dictionary in monsters:
			var id := str(enemy["id"])+":"+str(i)
			if player["hits"].has(id) or float(enemy["hp"])<=0:continue
			var offset: Vector2 = Vector2(enemy["pos"])-Vector2(player["pos"])
			var forward := offset.x*int(player["facing"])
			if forward < -14 or forward>float(rule["reach"]) or absf(offset.y)>float(rule["depth"]):continue
			if absf(float(enemy["z"])-float(player["z"]))>105:continue
			player["hits"][id] = true
			hit_enemy(enemy,rule,i)
		for p: Dictionary in props:
			if not p.get("breakable",false) or p.get("broken",false):continue
			var offset: Vector2 = Vector2(p["pos"])-Vector2(player["pos"])
			if offset.x*int(player["facing"])>=-10 and offset.x*int(player["facing"])<=float(rule["reach"]) and absf(offset.y)<25:
				p["broken"] = true
				p["broken_ms"] = 0.0
				spawn_effect("hit",p["pos"]-Vector2(0,18),int(player["facing"]))

func hit_enemy(enemy: Dictionary,rule: Dictionary,group := 0) -> void:
	var damage := float(rule["damage"])*(1.2 if float(player["buff_ms"])>0 else 1.0)
	bus.emit("combat.hit",{"attacker":0,"target":enemy["id"],"instance":action_seq,"group":group,
		"point":Vector3(Vector2(enemy["pos"]).x,Vector2(enemy["pos"]).y,float(enemy["z"])),"guarded":false})
	enemy["hp"] = maxf(0,float(enemy["hp"])-damage)
	enemy["state"] = "hurt"
	enemy["clock"] = 0.0
	enemy["hurt_ms"] = 260.0
	enemy["flash_ms"] = 65.0
	enemy["pos"] = constrain_pos(Vector2(enemy["pos"])+Vector2(int(player["facing"])*float(rule.get("push",12)),0))
	if rule.has("launch"):
		enemy["vz"] = float(rule["launch"])
		enemy["z"] = maxf(1,float(enemy["z"]))
		enemy["bounced"] = false
	if rule.get("bleed",false):enemy["bleed_ms"] = 2400.0
	hitstop_ms = maxf(hitstop_ms,float(rule["hitstop_ms"]))
	combo_count += 1
	combo_ms = 1500
	hit_count += 1
	# point = target ground position and height after the reaction is applied.
	bus.emit("combat.damage",{"target":enemy["id"],"amount":damage,"critical":false,"category":"physical",
		"point":Vector3(Vector2(enemy["pos"]).x,Vector2(enemy["pos"]).y,float(enemy["z"]))})
	spawn_effect("heavy" if damage>=40 else "hit",Vector2(enemy["pos"]),int(player["facing"]),35+float(enemy["z"]))
	play_sound("goblin_hurt")
	if float(enemy["hp"])<=0:
		enemy["state"] = "dead"
		enemy["death_ms"] = 0.0
		play_sound("goblin_die")
		report_defeat(enemy)

## Presentation cue; the view decides whether and how to show it.
func spawn_effect(name: String, point: Vector2, direction: int, z := 0.0) -> void:
	bus.emit("combat.cue",{"kind":"fx","key":name,"point":point,"height":z,"facing":direction})

func update_enemy(enemy: Dictionary,ms: float) -> void:
	var dt := ms/1000
	enemy["flash_ms"] = maxf(0,float(enemy["flash_ms"])-ms)
	enemy["cooldown"] = maxf(0,float(enemy["cooldown"])-dt)
	enemy["clock"] = float(enemy["clock"])+ms
	if float(enemy["hp"])<=0:
		enemy["state"] = "dead"
		enemy["death_ms"] = float(enemy["death_ms"])+ms
	else:
		if float(enemy["bleed_ms"])>0:
			enemy["bleed_ms"] = maxf(0,float(enemy["bleed_ms"])-ms)
			enemy["hp"] = maxf(0,float(enemy["hp"])-dt*7)
		var state: String = enemy["state"]
		if state == "hurt" or float(enemy["z"])>0:
			enemy["hurt_ms"] = maxf(0,float(enemy["hurt_ms"])-ms)
			if float(enemy["hurt_ms"])<=0 and float(enemy["z"])==0:enemy["state"] = "idle"
		elif state == "down":
			enemy["hurt_ms"] = maxf(0,float(enemy["hurt_ms"])-ms)
			if float(enemy["hurt_ms"])<=0:enemy["state"] = "idle"
		elif state == "attack":
			if not enemy["attack_done"] and float(enemy["clock"])>=240:
				enemy["attack_done"] = true
				var offset: Vector2 = Vector2(player["pos"])-Vector2(enemy["pos"])
				if offset.x*int(enemy["facing"])>=-12 and offset.x*int(enemy["facing"])<62 and absf(offset.y)<18 and float(player["z"])<40:
					damage_player(float(rules["goblin"]["chief_damage"] if enemy["chief"] else rules["goblin"]["damage"]),enemy["pos"])
			if float(enemy["clock"])>=520:
				enemy["state"] = "idle"
				enemy["cooldown"] = float(rules["goblin"]["attack_cooldown"])
		else:
			var offset: Vector2 = Vector2(player["pos"])-Vector2(enemy["pos"])
			enemy["facing"] = 1 if offset.x>=0 else -1
			if absf(offset.x)<42 and absf(offset.y)<13 and float(enemy["cooldown"])<=0:
				enemy["state"] = "attack"
				enemy["clock"] = 0.0
				enemy["attack_done"] = false
			else:
				var direction := offset.normalized()
				var speed := float(rules["goblin"]["speed"])*(0.9 if enemy["chief"] else 1.0)
				enemy["pos"] = move_in_world(enemy["pos"],Vector2(direction.x,direction.y*0.65)*speed*dt)
				enemy["state"] = "move"
	if float(enemy["z"])>0 or float(enemy["vz"])>0:
		enemy["z"] = maxf(0,float(enemy["z"])+float(enemy["vz"])*dt)
		enemy["vz"] = float(enemy["vz"])-900*dt
		if float(enemy["z"])==0 and float(enemy["vz"])<0:
			if not enemy["bounced"] and float(enemy["vz"]) < -240:
				enemy["vz"] = 140.0
				enemy["z"] = 1.0
				enemy["bounced"] = true
			else:
				enemy["vz"] = 0.0
				if float(enemy["hp"])>0:
					enemy["state"] = "down"
					enemy["hurt_ms"] = 400.0
					enemy["clock"] = 0.0

func damage_player(amount: float, source: Vector2) -> void:
	if god_mode or float(player["invuln_ms"])>0 or finished:return
	var guarded: bool = String(player["state"])=="guard" and (source.x-Vector2(player["pos"]).x)*int(player["facing"])>=0
	if guarded:amount *= 0.2
	elif float(player["buff_ms"])>0:amount *= 1.3
	player["hp"] = maxf(0,float(player["hp"])-amount)
	damage_taken += int(amount)
	player["flash_ms"] = 65.0
	player["invuln_ms"] = 400.0
	if not guarded and float(player["buff_ms"])<=0:
		player["state"] = "hurt"
		player["hurt_ms"] = 250.0
		player["queued_combo"] = false
		player["queued_skill"] = ""
	move_player(Vector2(signf(Vector2(player["pos"]).x-source.x)*(5 if guarded else 15),0))
	hitstop_ms = maxf(hitstop_ms,45)
	play_sound("hurt")
	if float(player["hp"])<=0:
		player["state"] = "dead"
		finished = true
		victory = false
		bus.emit("combat.player_defeated",flow_payload())

func constrain_pos(value: Vector2) -> Vector2:
	return Vector2(clampf(value.x,26,614),clampf(value.y,166,302))

func move_in_world(from: Vector2,delta: Vector2) -> Vector2:
	var result := constrain_pos(from+Vector2(delta.x,0))
	for p: Dictionary in props:
		if p.get("broken",false):continue
		var rect: Rect2 = p["collision"]
		if rect.has_point(result):result.x = from.x
	var next := constrain_pos(result+Vector2(0,delta.y))
	for p: Dictionary in props:
		if not p.get("broken",false) and Rect2(p["collision"]).has_point(next):next.y = result.y
	return next

func move_player(delta: Vector2) -> void:
	player["pos"] = move_in_world(player["pos"],delta)

func load_room(index: int, from_side: String) -> void:
	monsters.clear()
	room_index = index
	room_id = "trial:%d"%index
	doors.clear()
	var entry: Dictionary = rules["rooms"][index]
	var previous_side := ""
	if index>0:
		previous_side = "left" if String(rules["rooms"][index-1]["next"])=="right" else "down"
		doors.append({"side":previous_side,"to":index-1,"pos":door_point(previous_side)})
	if index<rules["rooms"].size()-1:
		var next_side: String = entry["next"]
		doors.append({"side":next_side,"to":index+1,"pos":door_point(next_side)})
	room_cleared = bool(room_snapshots.get(index,{}).get("cleared",false))
	props = [{"sprite":"rock","pos":Vector2(240,205),"collision":Rect2(230,199,20,12),"broken":false},
		{"sprite":"grass","pos":Vector2(385,278),"collision":Rect2(375,274,20,8),"breakable":true,"broken":false},
		{"sprite":"tree","pos":Vector2(13,270),"collision":Rect2(5,264,16,10),"broken":false},
		{"sprite":"tree","pos":Vector2(641,285),"collision":Rect2(633,279,16,10),"broken":false}]
	if room_snapshots.has(index):props = room_snapshots[index]["props"].duplicate(true)
	bus.emit("combat.room_loaded",{"room_index":index,"room_id":room_id,"props":props.duplicate(true)})
	player["pos"] = Vector2(70,250) if from_side=="right" else Vector2(480,285) if from_side=="up" else Vector2(570,250) if from_side=="left" else Vector2(480,190) if from_side=="down" else Vector2(125,250)
	player["z"] = 0.0
	player["vz"] = 0.0
	player["state"] = "idle"
	player["action"] = ""
	player["invuln_ms"] = 700.0
	door_lock_ms = 700.0
	if not room_cleared:
		for i in int(entry["enemies"]):spawn_enemy(Vector2(350+i*65,222+(i%2)*38),bool(entry.get("boss",false)) and i==0)
	notice(String(entry["name"])+(" · 领主出现" if entry.get("boss",false) else ""))

func door_point(side: String) -> Vector2:
	return {"right":Vector2(603,249),"left":Vector2(37,249),"up":Vector2(480,174),"down":Vector2(480,295)}.get(side,Vector2.ZERO)

func spawn_enemy(point: Vector2, chief := false) -> Dictionary:
	var hp := float(rules["goblin"]["chief_hp"] if chief else rules["goblin"]["hp"])
	var enemy := {"id":_next_entity_id,"pos":constrain_pos(point),"z":0.0,"vz":0.0,"state":"idle","clock":0.0,"hp":hp,"max_hp":hp,"chief":chief,
		"hurt_ms":0.0,"flash_ms":0.0,"cooldown":0.5,"attack_done":false,"bounced":false,"death_ms":0.0,"bleed_ms":0.0}
	monsters.append(enemy)
	_next_entity_id += 1
	bus.emit("combat.entity_spawned",{"entity_id":enemy["id"],"kind":"monster","appearance":"goblin_chief" if chief else "goblin"})
	return enemy

func clear_monsters() -> void:
	for enemy: Dictionary in monsters:
		bus.emit("combat.entity_removed",{"entity_id":enemy["id"]})
	monsters.clear()

func player_ani() -> Array:
	var state: String = player["state"]
	if state=="action":return [String(rules["moves"][player["action"]]["ani"]),float(player["clock"])]
	if state=="dead":return ["down",20200.0]
	if state=="hurt":return ["damage1",0.0]
	if state=="guard":return ["guard",0.0]
	if state=="backstep":return ["hitback",float(player["clock"])]
	if float(player["z"])>0:return ["jump",minf(float(player["air_ms"]),600) if float(player["vz"])>=0 else 10680.0]
	if float(player["landing_ms"])>0:return ["sit",0.0]
	if state=="move":return ["dash" if run_direction!=0 else "move",float(player["motion_clock"])]
	return ["stay",float(player["motion_clock"])]

func enemy_ani(enemy: Dictionary) -> Array:
	match String(enemy["state"]):
		"move":return ["move",float(enemy["clock"])]
		"attack":return ["attack1",float(enemy["clock"])]
		"hurt":return ["overturn" if float(enemy["z"])>0 else "damage1",0.0]
		"down":return ["down",20160.0]
		"dead":return ["down",160+minf(float(enemy["death_ms"]),500)]
	return ["stay",float(enemy["clock"])]

## Read-only per-tick state for view/ and ui/combat/ (contract doc 29 section 4). Values only.
func view_snapshot() -> Dictionary:
	var ani := player_ani()
	var enemies: Array = []
	var alive := 0
	for enemy: Dictionary in monsters:
		var e_ani := enemy_ani(enemy)
		var is_alive := float(enemy["hp"])>0
		if is_alive:alive += 1
		enemies.append({"id":enemy["id"],"pos":Vector2(enemy["pos"]),"z":float(enemy["z"]),"facing":int(enemy.get("facing",-1)),
			"ani":e_ani[0],"clock":e_ani[1],"flash":float(enemy["flash_ms"])>0,"alive":is_alive,
			"death_ms":float(enemy["death_ms"]),"hp_ratio":float(enemy["hp"])/float(enemy["max_hp"]),"chief":enemy["chief"]})
	var route: Array = []
	for i in rules["rooms"].size():
		var room: Dictionary = rules["rooms"][i]
		route.append({"cell":room["cell"],"visited":room_snapshots.has(i),"current":i==room_index,"boss":bool(room.get("boss",false))})
	var boss_room := bool(rules["rooms"][room_index].get("boss",false))
	return {"frame":_frame,"paused":paused,
		"player":{"pos":Vector2(player["pos"]),"z":float(player["z"]),"facing":int(player["facing"]),"ani":ani[0],"clock":ani[1],
			"flash":float(player["flash_ms"])>0,"buff":float(player["buff_ms"])>0,"weapon":weapon},
		"enemies":enemies,"props":props.duplicate(true),
		"stage":{"room_index":room_index,"cleared":room_cleared and not boss_room,"doors":doors.duplicate(true)},
		"hud":{"room_name":String(rules["rooms"][room_index]["name"]),"alive":alive,"room_cleared":room_cleared,
			"route":route,"combo":combo_count,"toast":toast,"toast_ms":toast_ms,
			"player":{"hp":float(player["hp"]),"mp":float(player["mp"]),"hp_max":float(rules["player"]["hp"]),"mp_max":float(rules["player"]["mp"]),
				"job":job,"weapon":weapon,"buff_ms":float(player["buff_ms"]),"cooldowns":Dictionary(player["cooldowns"]).duplicate()},
			"overlay":{"finished":finished,"external":external_mode,"victory":victory,"damage_taken":damage_taken,
				"elapsed_ms":elapsed_ms,"paused":paused,"help":help_visible}}}

## Presentation cue; the view's audio router plays it.
func play_sound(key: String) -> void:
	bus.emit("combat.cue",{"kind":"sound","key":key})

func capture_frame(name: String) -> void:
	await RenderingServer.frame_post_draw
	var folder := ProjectSettings.globalize_path("res://../temp/dnf_native_capture")
	DirAccess.make_dir_recursive_absolute(folder)
	get_viewport().get_texture().get_image().save_png(folder+"/"+name+".png")

func _draw() -> void:
	if missing_assets:
		draw_string(ThemeDB.fallback_font,Vector2(35,90),"Local DNF assets are missing.",HORIZONTAL_ALIGNMENT_LEFT,-1,22,Color.WHITE)
		draw_string(ThemeDB.fallback_font,Vector2(35,130),"Run tools/build_dnf_assets.py --library <local library>",HORIZONTAL_ALIGNMENT_LEFT,-1,15,Color.WHITE)
