extends Node2D
## Transitional battle scene: composition root + the trial room loop. Combat rules come from the
## kernel (combat/api/kernel.gd) and the original content pack; presentation lives in view/ and
## ui/combat/ and only consumes view_snapshot() and combat.* events (doc 29, F1~F5).
## Outside code reaches it only through combat/api/combat_session.gd.
const TestDrive = preload("res://scripts/test_drive.gd")
const EventBus = preload("res://core/event_bus.gd")
const DetRng = preload("res://core/det_rng.gd")
const ContentDB = preload("res://content/api/content_db.gd")
const CombatSession = preload("res://combat/api/combat_session.gd")
const Kernel = preload("res://combat/api/kernel.gd")
const BattleView = preload("res://view/battle_view.gd")
const COMBAT_ASSETS := "res://assets_local/combat/manifest.json"
const PLAYER_ID := 0

## Set before entering the tree when a flow root manages this scene (see CombatSession.mount).
var external_mode := false
var bus = EventBus.new()
var content = ContentDB.new()
var table = Kernel.MoveTable.new()
var rng = DetRng.new(1)
var session
var view
var run_id := "standalone"
var room_id := ""
var assets: Dictionary = {}
var combat_assets: Dictionary = {}
var rules: Dictionary = {}
var player_clips: Dictionary = {}
var player: Dictionary = {}
var monsters: Array = []
var objects: Array = []
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
var max_hp := 0.0
var max_mp := 0.0
var damage_scale := 1.0
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
		bus.emit("combat.appearance_changed",{"entity_id":PLAYER_ID,"weapon":value})
var missing_assets := false
var missing_reason := ""
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
		return _fail("Local DNF assets are missing. Run tools/run_dnf.ps1 (asset store sync).")
	if not FileAccess.file_exists(COMBAT_ASSETS):
		return _fail("Combat assets missing. Run python tools/build_dnf_combat_assets.py (needs sync --full).")
	assets = content.runtime
	rules = content.rules()
	combat_assets = JSON.parse_string(FileAccess.get_file_as_string(COMBAT_ASSETS))
	if not table.build(content,rules,combat_assets):
		return _fail("Combat tables incomplete: "+", ".join(table.problems.slice(0,3)))
	player_clips = content.clips("player").duplicate()
	player_clips.merge(combat_assets.get("player_clips",{}),false)
	view = BattleView.new()
	add_child(view)
	view.setup(assets,combat_assets,player_clips,bus,weapon)
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

func _fail(reason: String) -> void:
	missing_assets = true
	missing_reason = reason
	push_warning(reason)
	queue_redraw()

func _notification(what: int) -> void:
	if what==NOTIFICATION_WM_WINDOW_FOCUS_OUT and not player.is_empty() and not "--test" in OS.get_cmdline_user_args():
		held.clear()
		requests.clear()
		if not finished:paused = true

func restart() -> void:
	begin_room({"run_id":"standalone","room_index":0,"from":"start"})
	notice("格兰之森 · 清除怪物，继续深入")

## Physical attack power before skill percentages (E-ADAPT until equipment/stats exist).
func attack_power() -> float:
	return float(rules["player"]["physical_attack"])*damage_scale

## Spec fields (contract v1): run_id, room_id, room_index (transitional trial route), from (entry side),
## player {hp, mp, hp_max, mp_max, damage_multiplier, job, weapon}, audio {muted, bgm_volume_db}, show_hud.
## Long-term profile data stays with flow; these are the per-run combat stats it hands over.
## Without flow values, HP/MP start from the original CHR level-1 initial stats.
func begin_room(spec: Dictionary) -> void:
	var snapshot: Dictionary = spec.get("player",{})
	max_hp = float(snapshot.get("hp_max",table.player["hp_max"]))
	max_mp = float(snapshot.get("mp_max",table.player["mp_max"]))
	damage_scale = float(snapshot.get("damage_multiplier",1.0))
	player = new_player()
	if snapshot.has("hp"):player["hp"] = clampf(float(snapshot["hp"]),1,max_hp)
	if snapshot.has("mp"):player["mp"] = clampf(float(snapshot["mp"]),0,max_mp)
	if snapshot.get("job","") in ["weaponmaster","berserker"]:job = String(snapshot["job"])
	if assets["players"].has(String(snapshot.get("weapon",""))):weapon = String(snapshot["weapon"])
	var audio_spec: Dictionary = spec.get("audio",{})
	if audio_spec.has("muted"):_muted = bool(audio_spec["muted"])
	if audio_spec.has("bgm_volume_db") and not _muted:view.audio.start_music(float(audio_spec["bgm_volume_db"]))
	view.hud.visible = bool(spec.get("show_hud",true))
	run_id = String(spec.get("run_id","standalone"))
	rng.reseed(hash(run_id))
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
	load_room(clampi(int(spec.get("room_index",0)),0,rules["rooms"].size()-1),String(spec.get("from","start")))
	if spec.has("room_id"):room_id = String(spec["room_id"])

func new_player() -> Dictionary:
	return {"id":PLAYER_ID,"pos":Vector2(125,250),"z":0.0,"vz":0.0,"air_ms":0.0,"hp":max_hp,"mp":max_mp,
		"facing":1,"state":"idle","action":"","stage":0,"clock":0.0,"motion_clock":0.0,
		"stun_ms":0.0,"push_v":0.0,"push_ms":0.0,"hit_motion":"damage1","bounced":false,"down_ms":0.0,"stuck_ms":0.0,
		"invuln_ms":0.0,"flash_ms":0.0,"landing_ms":0.0,"buff_ms":0.0,"cooldowns":{},"hits":{},
		"queued_combo":false,"queued_skill":"","queued_jump":false}

## Keys owned by the flow side when externally managed: restart, pause/menu, character and debug switches.
const FLOW_OWNED_KEYS := [KEY_R,KEY_TAB,KEY_1,KEY_2,KEY_3,KEY_ESCAPE,KEY_F2,KEY_F3]
const SKILL_KEYS := {KEY_Z:"upper",KEY_A:"draw",KEY_S:"triple",KEY_D:"rage_slash",KEY_F:"buff"}

func _input(event: InputEvent) -> void:
	if not event is InputEventKey:return
	var key_event := event as InputEventKey
	var code := int(key_event.physical_keycode if key_event.physical_keycode != 0 else key_event.keycode)
	if external_mode and code in FLOW_OWNED_KEYS:return
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
			view.audio.music.volume_db = -80 if _muted else -28
		KEY_1,KEY_2,KEY_3:
			weapon = ["shortsword","katana","greatsword"][code-KEY_1]
		KEY_LEFT,KEY_RIGHT:
			var direction := -1 if code == KEY_LEFT else 1
			var now := Time.get_ticks_msec()
			if now-int(last_direction_tap.get(direction,-1000)) < 240:run_direction = direction
			last_direction_tap[direction] = now
		KEY_X,KEY_Z,KEY_A,KEY_S,KEY_D,KEY_F,KEY_C,KEY_SPACE,KEY_V:
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
		step_game(ms)
		sim_ms = ms
	view.present(view_snapshot(),ms,sim_ms)
	taps.clear()
	if test_drive != null:test_drive.after_tick()
	if _capture and _frame in [25,130,260,400]:
		capture_frame("frame_%04d"%_frame)

# ---------------------------------------------------------------- player

func move_def(name: String) -> Dictionary:
	return table.moves.get(name,{})

## Current stage of the running action (three-stage skills keep one move with stages).
func action_def() -> Dictionary:
	var m := move_def(String(player["action"]))
	if m.has("stages"):return m["stages"][int(player["stage"])]
	return m

func action_duration(action: String) -> float:
	var m := move_def(action)
	if action == "buff":return maxf(float(m["cast_ms"]),1.0)
	return float(m.get("duration",0))

func buffering(code: int) -> void:
	if code == KEY_X and String(player["action"]).begins_with("attack"):player["queued_combo"] = true
	elif SKILL_KEYS.has(code):player["queued_skill"] = SKILL_KEYS[code]
	elif code in [KEY_C,KEY_SPACE] and String(player["action"]) == "upper":player["queued_jump"] = true

func step_game(ms: float) -> void:
	var dt := ms/1000
	player["invuln_ms"] = maxf(0,float(player["invuln_ms"])-ms)
	player["flash_ms"] = maxf(0,float(player["flash_ms"])-ms)
	player["buff_ms"] = maxf(0,float(player["buff_ms"])-ms)
	player["landing_ms"] = maxf(0,float(player["landing_ms"])-ms)
	door_lock_ms = maxf(0,door_lock_ms-ms)
	for name: String in player["cooldowns"]:
		player["cooldowns"][name] = maxf(0,float(player["cooldowns"][name])-dt)
	player["mp"] = minf(max_mp,float(player["mp"])+dt*float(rules["player"]["mp_regen_per_s"]))
	combo_ms = maxf(0,combo_ms-ms)
	if combo_ms <= 0:combo_count = 0
	var move := Vector2(float(bool(held.get(KEY_RIGHT,false)))-float(bool(held.get(KEY_LEFT,false))),float(bool(held.get(KEY_DOWN,false)))-float(bool(held.get(KEY_UP,false))))
	if move.x == 0 or signi(int(move.x)) != run_direction:run_direction = 0
	if move.length_squared()>1:move = move.normalized()
	# Local hitstop: only the attacker and its targets freeze; inputs are buffered meanwhile.
	if float(player["stuck_ms"]) > 0:
		player["stuck_ms"] = maxf(0,float(player["stuck_ms"])-ms)
		for code: int in requests:buffering(code)
		requests.clear()
	else:
		step_player(ms,move)
	for enemy: Dictionary in monsters:update_enemy(enemy,ms)
	step_objects(ms)
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
		bus.emit("combat.room_combat_finished",flow_payload({"boss":boss,"final_room":boss}))
		if boss:
			finished = true
			victory = true
		else:notice("房间清空 · 通道已开启")
	if room_cleared and not finished and door_lock_ms<=0:
		for door: Dictionary in doors:
			if Vector2(player["pos"]).distance_to(door["pos"])<24 and (move.length()>0 or taps.get(KEY_E,false)):
				load_room(int(door["to"]),String(door["side"]))
				break

func step_player(ms: float, move: Vector2) -> void:
	var dt := ms/1000
	player["motion_clock"] = float(player["motion_clock"])+ms
	var state: String = player["state"]
	var grounded := float(player["z"])==0 and float(player["vz"])<=0
	for code: int in requests:
		if code in [KEY_C,KEY_SPACE]:
			if state == "action":buffering(code)
			elif state in ["idle","move","guard"] and grounded:
				player["vz"] = float(table.player["jump_power"])
				player["air_ms"] = 0.0
				player["state"] = "jump"
				play_sound("jump")
		elif code == KEY_V:
			if state in ["idle","move","guard"] and grounded:
				player["state"] = "backstep"
				player["clock"] = 0.0
				player["vz"] = 220.0
				player["invuln_ms"] = 110.0
				play_sound("backstep")
		elif code == KEY_X:
			if String(player["state"]) == "action":buffering(code)
			else:start_action("air_attack" if float(player["z"])>0 or float(player["vz"])>0 else "dash_attack" if run_direction!=0 else "attack1")
		elif SKILL_KEYS.has(code):
			if String(player["state"]) == "action":buffering(code)
			else:start_action(SKILL_KEYS[code])
	requests.clear()
	state = player["state"]
	if state == "action":
		step_action(ms)
	elif state in ["hurt","air","down"]:
		if Kernel.Reaction.step_body(player,ms,float(rules["player"]["gravity"]),rules["reaction"],move_in_world) == "landed":
			player["landing_ms"] = 0.0
		return
	elif state == "backstep":
		player["clock"] = float(player["clock"])+ms
		move_player(Vector2(-int(player["facing"])*150*dt,0))
		if float(player["clock"])>=470:player["state"] = "idle"
	elif state != "dead":
		if held.get(KEY_G,false) and float(player["z"])==0 and float(player["vz"])<=0:
			player["state"] = "guard"
			if move.x!=0:player["facing"] = 1 if move.x>0 else -1
		elif move.length_squared()>0:
			if move.x!=0:player["facing"] = 1 if move.x>0 else -1
			var speed := float(rules["player"]["run_speed"] if run_direction!=0 else rules["player"]["walk_speed"])
			if float(player["buff_ms"])>0:speed *= float(rules["buff"]["move_speed"])
			move_player(Vector2(move.x*speed,move.y*speed*float(rules["units"]["depth_speed_ratio"]))*dt)
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
			elif String(player["state"]) == "action" and move_def(String(player["action"])).get("air",false):
				player["state"] = "idle"
				player["action"] = ""

func step_action(ms: float) -> void:
	var name: String = player["action"]
	var m := move_def(name)
	var stage := action_def()
	var old_clock := float(player["clock"])
	var speed: float = float(rules["buff"]["attack_speed"]) if float(player["buff_ms"])>0 and name != "buff" else 1.0
	var clock := old_clock+ms*speed
	player["clock"] = clock
	if m.has("dash") and clock <= float(m["dash"]["until"]):
		move_player(Vector2(float(m["dash"]["speed"])*int(player["facing"])*ms/1000.0,0))
	action_cues(stage,old_clock,clock)
	apply_player_hits(stage,old_clock,clock)
	var duration := action_duration(name)
	var cancel_at := float(stage.get("cancel_at",duration))
	if clock >= cancel_at and bool(player["queued_jump"]) and name == "upper":
		player["state"] = "jump"
		player["action"] = ""
		player["vz"] = float(table.player["jump_power"])
		player["air_ms"] = 0.0
		player["queued_jump"] = false
		play_sound("jump")
	elif clock >= cancel_at and String(player["queued_skill"]) == name and m.has("stages") and int(player["stage"]) < m["stages"].size()-1:
		player["queued_skill"] = ""
		start_stage(int(player["stage"])+1)
	elif clock >= cancel_at and String(player["queued_skill"]) != "" and String(player["queued_skill"]) != name:
		var requested: String = player["queued_skill"]
		player["queued_skill"] = ""
		start_action(requested,true)
	elif clock >= cancel_at and bool(player["queued_combo"]) and String(m.get("next","")) != "":
		start_action(String(m["next"]),true)
	elif clock >= duration:
		player["state"] = "jump" if float(player["z"])>0 else "idle"
		player["action"] = ""

func flow_payload(extra := {}) -> Dictionary:
	var payload := {"run_id":run_id,"room_id":room_id,"room_index":room_index,
		"stats":{"elapsed_ms":elapsed_ms,"time_ms":elapsed_ms,"hit_count":hit_count,"hits":hit_count,"damage_taken":damage_taken},
		"player":{"hp":float(player["hp"]),"mp":float(player["mp"]),"job":job,"weapon":weapon}}
	payload.merge(extra,true)
	return payload

## Effects already validated and paid for by the flow side (e.g. potions). Returns whether it applied.
func apply_effect(effect: Dictionary) -> bool:
	if player.is_empty() or finished or paused:return false
	match String(effect.get("kind","")):
		"heal":
			if float(player["hp"]) >= max_hp:return false
			player["hp"] = minf(max_hp,float(player["hp"])+float(effect.get("amount",0)))
			notice("恢复药剂 · HP +%d"%int(effect.get("amount",0)))
			return true
	return false

func set_input_paused(value: bool) -> void:
	paused = value
	held.clear()
	requests.clear()

func report_defeat(enemy: Dictionary) -> void:
	if enemy.get("defeat_reported",false):return
	enemy["defeat_reported"] = true
	bus.emit("combat.monster_defeated",{"run_id":run_id,"room_id":room_id,"room_index":room_index,
		"entity_id":enemy["id"],"monster_id":String(enemy["mob"]),"boss":bool(enemy["chief"]),
		"position":Vector2(enemy["pos"])})

func reject_action(name: String, reason: String) -> bool:
	bus.emit("combat.action_rejected",{"entity_id":PLAYER_ID,"action":name,"reason":reason})
	return false

## Starts a move. MP and cooldown come from the original SKL [dungeon] section (level 1).
func start_action(name: String, cancel := false) -> bool:
	var m := move_def(name)
	if m.is_empty():return reject_action(name,"unknown")
	var airborne := float(player["z"])>0 or float(player["vz"])>0
	if airborne != bool(m.get("air",false)):return reject_action(name,"state")
	if not cancel and String(player["state"]) in ["hurt","air","down","dead","backstep","action"]:return reject_action(name,"state")
	if float(player["cooldowns"].get(name,0))>0:return reject_action(name,"cooldown")
	if float(player["mp"])<float(m["mp"]):return reject_action(name,"mp")
	player["mp"] = float(player["mp"])-float(m["mp"])
	if float(m["cool_ms"]) > 0:player["cooldowns"][name] = float(m["cool_ms"])/1000.0
	player["state"] = "action"
	player["action"] = name
	player["queued_combo"] = false
	player["queued_skill"] = ""
	player["queued_jump"] = false
	if name == "buff":
		player["stage"] = 0
		player["clock"] = 0.0
		player["hits"] = {}
		action_seq += 1
		bus.emit("combat.action_started",{"entity_id":PLAYER_ID,"action":name,"instance":action_seq})
		if String(m["cast_fx"]) != "":spawn_effect(String(m["cast_fx"]),player["pos"],int(player["facing"]),float(player["z"]))
		apply_buff()
		return true
	start_stage(0)
	return true

func start_stage(index: int) -> void:
	var name: String = player["action"]
	player["stage"] = index
	player["clock"] = 0.0
	player["hits"] = {}
	action_seq += 1
	bus.emit("combat.action_started",{"entity_id":PLAYER_ID,"action":name,"stage":index,"instance":action_seq})
	var m := move_def(name)
	var stage := action_def()
	if String(stage.get("voice","")) != "":play_sound(String(stage["voice"]))
	var swing := int(m.get("swing",-1))
	if swing >= 0:
		var wav: Array = table.weapon_wav(weapon)
		if swing < wav.size() and String(wav[swing]) != "":play_sound(String(wav[swing]))
	action_cues(stage,-1.0,0.0)
	apply_player_hits(stage,-1.0,0.0)

func apply_buff() -> void:
	player["buff_ms"] = float(rules["buff"]["duration_ms"])
	notice(String(move_def("buff").get("label",""))+" · 攻击与移动加速")

## Timed effect/sound cues of the move plus the ANI's own frame sound events.
func action_cues(stage: Dictionary, old_t: float, new_t: float) -> void:
	for fx: Dictionary in stage.get("fx",[]):
		var at := float(fx["at"])
		if at > old_t and at <= new_t:spawn_effect(String(fx["key"]),player["pos"],int(player["facing"]),float(player["z"]))
	for s: Dictionary in stage.get("sounds",[]):
		var at := float(s["at"])
		if at > old_t and at <= new_t:play_sound(String(s["key"]))
	var rec: Dictionary = content.record(Kernel.MoveTable.CHR_ANI+String(stage.get("ani",""))+".ani")
	if rec.is_empty():return
	var events: Array = rec["decoded"].get("sound_events",[])
	if events.is_empty():return
	for f: Dictionary in Kernel.Timeline.crossed_frames(stage["timeline"],old_t,new_t):
		for e: Dictionary in events:
			if int(e["frame"]) == int(f["frame"]):play_sound(String(e["sound"]))

func apply_player_hits(stage: Dictionary, old_t: float, new_t: float) -> void:
	var anchor := Kernel.HitJudge.anchor(player["pos"],float(player["z"]))
	var facing := int(player["facing"])
	for i in stage["hits"].size():
		var hit: Dictionary = stage["hits"][i]
		if hit["kind"] == "object":
			var at := float(hit["at"])
			if at > old_t and at <= new_t:spawn_object(hit,"player",player["pos"],float(player["z"]),facing,attack_power())
			continue
		for s in hit["segments"].size():
			var boxes: Array = Kernel.Timeline.segment_boxes(hit["segments"][s],maxf(old_t,0.0) if old_t >= 0 else -1.0,new_t)
			if boxes.is_empty():continue
			var world: Array = Kernel.HitJudge.world_boxes(boxes,anchor,facing)
			for enemy: Dictionary in monsters:
				var id := "%d:%d:%d"%[i,s,int(enemy["id"])]
				if player["hits"].has(id) or float(enemy["hp"])<=0:continue
				var c: Dictionary = Kernel.HitJudge.contact(world,enemy_damage_boxes(enemy))
				if c.is_empty():continue
				player["hits"][id] = true
				land_hit(player,enemy,hit,c["point"],facing,attack_power())
			for p in props.size():
				var prop: Dictionary = props[p]
				if not prop.get("breakable",false) or prop.get("broken",false):continue
				for b: AABB in world:
					if b.intersects(Kernel.HitJudge.prop_box(prop["collision"])):
						prop["broken"] = true
						prop["broken_ms"] = 0.0
						spawn_effect("hit_cut_s1",prop["pos"]-Vector2(0,18),facing)
						break

## One landed hit, attacker -> target. Damage, reaction, local hitstop, events and cues.
func land_hit(attacker: Dictionary, target: Dictionary, hit: Dictionary, point: Vector3, facing: int, power: float) -> void:
	var atk: Dictionary = hit["atk"]
	var by_player := int(attacker.get("id",-1)) == PLAYER_ID
	var percent := float(hit["percent"])
	var amount := Kernel.Reaction.damage(power*(float(rules["buff"]["damage"]) if by_player and float(player["buff_ms"])>0 else 1.0),percent)
	var target_is_player := int(target.get("id",-1)) == PLAYER_ID
	bus.emit("combat.hit",{"attacker":attacker.get("id",-1),"target":target["id"],"instance":action_seq,"point":point,"guarded":false,"atk":String(hit.get("atk_path",""))})
	var reaction := "none"
	if target_is_player:
		reaction = hurt_player(amount,attacker,atk,facing)
		if reaction == "blocked":return
	else:
		target["hp"] = maxf(0,float(target["hp"])-amount)
		reaction = Kernel.Reaction.apply(target,atk,facing,rules["reaction"],float(target["def"]["hit_recovery"]),float(hit.get("lift",-1)))
		target["clock"] = 0.0
		target["flash_ms"] = 65.0
		combo_count += 1
		combo_ms = float(rules["combo_window_ms"])
		hit_count += 1
	var stop := float(rules["hitstop"]["down_ms"] if reaction in ["launch","down","air"] else rules["hitstop"]["hit_ms"])
	# Thrown and spawned objects freeze only their target; the caster keeps moving.
	if String(hit.get("kind","")) != "object" and not hit.has("object"):
		attacker["stuck_ms"] = maxf(float(attacker.get("stuck_ms",0)),stop)
	target["stuck_ms"] = maxf(float(target.get("stuck_ms",0)),stop)
	bus.emit("combat.damage",{"target":target["id"],"amount":amount,"critical":false,"category":"physical",
		"victim":"player" if target_is_player else "monster","reaction":reaction,
		"point":Vector3(Vector2(target["pos"]).x,Vector2(target["pos"]).y,float(target["z"]))})
	hit_cues(atk,point,facing,by_player)
	if not target_is_player:
		play_sound("goblin_hurt")
		if float(target["hp"])<=0:
			target["state"] = "dead"
			target["death_ms"] = 0.0
			play_sound("goblin_die")
			report_defeat(target)

## Hit effect and hit sound from ATK [hit info]/[hit wav]; weapon rows of the CHR when the
## ATK leaves them to the weapon (normal attacks).
func hit_cues(atk: Dictionary, point: Vector3, facing: int, by_player: bool) -> void:
	var kind := Kernel.MoveTable.enum_value(atk,"hit_info","")
	var blood := ""
	var size := 100.0
	var scale := 1.0
	var info: Array = atk.get("hit_info",[]) if atk.get("hit_info") is Array else []
	if info.size() > 1:
		blood = String(info[1]["value"])
		var args: Array = info[1]["args"]
		if args.size() > 0:size = float(args[0])
		if args.size() > 1:scale = float(args[1])
	elif by_player:
		var row: Array = table.weapon_hit_info(weapon)
		kind = String(row[0])
		blood = String(row[1])
		size = float(row[2])
		scale = float(row[3])
	var large := size >= 100
	var fx := ""
	match kind:
		"[blow]":fx = "hit_blow_l" if large else "hit_blow_s"
		"":fx = "hit_blow_s"
		_:fx = ("hit_cut_l%d" if large else "hit_cut_s%d")%rng.range_int(1,3)
	var ground := Vector2(point.x,point.y)
	bus.emit("combat.cue",{"kind":"fx","key":fx,"point":ground,"height":point.z,"facing":facing,"scale":scale})
	if blood == "[blood]":
		var bfx := "hit_blood_l" if large else "hit_blood_s%d"%rng.range_int(1,3)
		bus.emit("combat.cue",{"kind":"fx","key":bfx,"point":ground,"height":point.z,"facing":facing,"scale":scale})
	var wav := String(atk.get("hit_wav",""))
	if wav == "" and by_player:
		var w: Array = table.weapon_wav(weapon)
		if w.size() > 2:wav = String(w[2])
	if wav != "":play_sound(wav)

## Presentation cue; the view decides whether and how to show it.
func spawn_effect(name: String, point: Vector2, direction: int, z := 0.0) -> void:
	bus.emit("combat.cue",{"kind":"fx","key":name,"point":point,"height":z,"facing":direction})

# ---------------------------------------------------------------- monsters

func enemy_damage_boxes(enemy: Dictionary) -> Array:
	var ani := enemy_ani(enemy)
	var tl: Array = table.monster_timeline(enemy["def"],String(ani[0]))
	var f: Dictionary = Kernel.Timeline.frame_at(tl,float(ani[1]),String(ani[0]) in ["stay","move"])
	return Kernel.HitJudge.world_boxes(f.get("damage_boxes",[]),Kernel.HitJudge.anchor(enemy["pos"],float(enemy["z"])),int(enemy["facing"]))

func player_damage_boxes() -> Array:
	var ani := player_ani()
	var tl: Array = table.player_timeline(String(ani[0]))
	var f: Dictionary = Kernel.Timeline.frame_at(tl,float(ani[1]),String(ani[0]) in ["stay","move","dash"])
	return Kernel.HitJudge.world_boxes(f.get("damage_boxes",[]),Kernel.HitJudge.anchor(player["pos"],float(player["z"])),int(player["facing"]))

func update_enemy(enemy: Dictionary, ms: float) -> void:
	enemy["flash_ms"] = maxf(0,float(enemy["flash_ms"])-ms)
	if float(enemy["stuck_ms"]) > 0:
		enemy["stuck_ms"] = maxf(0,float(enemy["stuck_ms"])-ms)
		return
	var dt := ms/1000
	var m: Dictionary = enemy["def"]
	enemy["cooldown_ms"] = maxf(0,float(enemy["cooldown_ms"])-ms)
	enemy["clock"] = float(enemy["clock"])+ms
	var state: String = enemy["state"]
	if float(enemy["hp"])<=0:
		enemy["state"] = "dead"
		enemy["death_ms"] = float(enemy["death_ms"])+ms
	elif state == "attack":
		enemy_attack(enemy,ms)
	elif state in ["idle","move"] and enemy.get("ai",true):
		var intent: Dictionary = Kernel.MonsterAI.think(enemy,m,player["pos"],float(player["z"]))
		enemy["facing"] = int(intent["face"])
		if intent["attack"]:
			enemy["state"] = "attack"
			enemy["clock"] = 0.0
			enemy["hits"] = {}
			enemy["thrown"] = false
		elif Vector2(intent["move"]).length_squared() > 0:
			var dir: Vector2 = intent["move"]
			enemy["pos"] = move_in_world(enemy["pos"],Vector2(dir.x,dir.y*float(rules["units"]["depth_speed_ratio"]))*float(m["speed"])*dt)
			if state != "move":enemy["clock"] = 0.0
			enemy["state"] = "move"
		else:
			enemy["state"] = "idle"
	Kernel.Reaction.step_body(enemy,ms,float(rules["reaction"]["monster_gravity"]),rules["reaction"],move_in_world)

func enemy_attack(enemy: Dictionary, ms: float) -> void:
	var m: Dictionary = enemy["def"]
	var old_t := float(enemy["clock"])-ms
	var t := float(enemy["clock"])
	if m.has("throw"):
		var throw: Dictionary = m["throw"]
		var tl: Array = m["attack_timeline"]
		var f := int(throw["frame"])
		if not enemy["thrown"] and f < tl.size() and t >= float(tl[f]["start_ms"]):
			enemy["thrown"] = true
			var start: Vector3 = throw["start"]
			var facing := int(enemy["facing"])
			var hit := {"atk":throw["object"]["atk"],"atk_path":throw["object"]["atk_path"],"object":throw["object"]["path"],
				"percent":100.0+float(throw["object"]["atk"].get("damage_bonus",0)),"lift":-1.0,"active_ms":-1.0,
				"offset":Vector3(start.x,start.y,start.z),"speed":float(throw["speed"]),"life_ms":float(throw["life_ms"])}
			spawn_object(hit,"monster",enemy["pos"],float(enemy["z"]),facing,float(enemy["attack"]),enemy)
			if String(throw["sound"]) != "":play_sound(String(throw["sound"]))
	else:
		for s in m["attack_segments"].size():
			if enemy["hits"].has(s):continue
			var boxes: Array = Kernel.Timeline.segment_boxes(m["attack_segments"][s],old_t,t)
			if boxes.is_empty():continue
			var world: Array = Kernel.HitJudge.world_boxes(boxes,Kernel.HitJudge.anchor(enemy["pos"],float(enemy["z"])),int(enemy["facing"]))
			var c: Dictionary = Kernel.HitJudge.contact(world,player_damage_boxes())
			if c.is_empty():continue
			enemy["hits"][s] = true
			land_hit(enemy,player,{"atk":m["atk"],"percent":100.0+float(m["atk"].get("damage_bonus",0)),"lift":-1.0},c["point"],int(enemy["facing"]),float(enemy["attack"]))
	if t >= Kernel.Timeline.duration(m["attack_timeline"]):
		enemy["state"] = "idle"
		enemy["clock"] = 0.0
		enemy["cooldown_ms"] = float(m["attack_delay"])

## Player takes a monster hit. Returns the reaction kind, or "blocked" if nothing applied.
func hurt_player(amount: int, source: Dictionary, atk: Dictionary, facing: int) -> String:
	if god_mode or float(player["invuln_ms"])>0 or finished:return "blocked"
	var guarded: bool = String(player["state"])=="guard" and (Vector2(source["pos"]).x-Vector2(player["pos"]).x)*int(player["facing"])>=0
	var taken := float(amount)
	if guarded:taken *= float(rules["player"]["guard_factor"])
	elif float(player["buff_ms"])>0:taken *= float(rules["buff"]["damage_taken"])
	player["hp"] = maxf(0,float(player["hp"])-taken)
	damage_taken += int(taken)
	player["flash_ms"] = 65.0
	player["invuln_ms"] = float(rules["player"]["hit_invuln_ms"])
	var reaction := "guard" if guarded else "none"
	if not guarded and float(player["buff_ms"])<=0:
		player["action"] = ""
		player["queued_combo"] = false
		player["queued_skill"] = ""
		reaction = Kernel.Reaction.apply(player,atk,facing,rules["reaction"],float(table.player["hit_recovery"]))
		if reaction == "none":player["state"] = "idle"
	play_sound("hurt")
	if float(player["hp"])<=0:
		player["state"] = "dead"
		finished = true
		victory = false
		play_sound("die")
		bus.emit("combat.player_defeated",flow_payload())
	return reaction

## Direct damage entry kept for tests and flow-side hazards: a plain frontal monster hit.
func damage_player(amount: float, source: Vector2) -> void:
	var facing := 1 if Vector2(player["pos"]).x >= source.x else -1
	hurt_player(int(amount),{"pos":source},{},facing)

# ---------------------------------------------------------------- passive objects

func spawn_object(hit: Dictionary, owner: String, pos: Vector2, z: float, facing: int, power: float, source := {}) -> void:
	var obj: Dictionary = table.object(String(hit["object"]))
	if obj.is_empty():return
	var off: Vector3 = hit.get("offset",Vector3.ZERO)
	var entity := {"id":_next_entity_id,"def":obj,"owner":owner,"source":source,"hit":hit,"power":power,
		"pos":constrain_pos(Vector2(pos.x+off.x*facing,pos.y+off.y)),"z":z+off.z,"facing":facing,"clock":0.0,
		"speed":float(hit.get("speed",0)),"life_ms":float(hit.get("life_ms",-1)),"hits":{}}
	_next_entity_id += 1
	objects.append(entity)
	if String(obj["add_fx"]) != "":spawn_effect(String(obj["add_fx"]),entity["pos"],facing,float(entity["z"]))

func step_objects(ms: float) -> void:
	for i in range(objects.size()-1,-1,-1):
		var o: Dictionary = objects[i]
		var obj: Dictionary = o["def"]
		var old_t := float(o["clock"])
		var t := old_t+ms
		o["clock"] = t
		o["pos"] = Vector2(o["pos"])+Vector2(float(o["speed"])*int(o["facing"])*ms/1000.0,0)
		var hit: Dictionary = o["hit"]
		var active := float(hit.get("active_ms",-1))
		var done := false
		var life := float(o["life_ms"])
		var tl: Array = obj["timeline"]
		var loops := life > 0
		if active < 0 or t <= active:
			var f: Dictionary = Kernel.Timeline.frame_at(tl,t,loops)
			var boxes: Array = f.get("attack_boxes",[])
			if not boxes.is_empty():
				var world: Array = Kernel.HitJudge.world_boxes(boxes,Kernel.HitJudge.anchor(o["pos"],float(o["z"])),int(o["facing"]))
				var attacker: Dictionary = player if o["owner"] == "player" else o["source"]
				if o["owner"] == "player":
					for enemy: Dictionary in monsters:
						if o["hits"].has(enemy["id"]) or float(enemy["hp"])<=0:continue
						var c: Dictionary = Kernel.HitJudge.contact(world,enemy_damage_boxes(enemy))
						if c.is_empty():continue
						o["hits"][enemy["id"]] = true
						land_hit(attacker,enemy,hit,c["point"],int(o["facing"]),float(o["power"]))
						if int(obj["piercing"]) <= 0:done = true
				elif not o["hits"].has(PLAYER_ID):
					var c: Dictionary = Kernel.HitJudge.contact(world,player_damage_boxes())
					if not c.is_empty():
						o["hits"][PLAYER_ID] = true
						land_hit({"id":-1,"pos":o["pos"],"stuck_ms":0.0},player,hit,c["point"],int(o["facing"]),float(o["power"]))
						if int(obj["piercing"]) <= 0:done = true
		if life > 0 and t >= life:done = true
		elif life <= 0 and t >= Kernel.Timeline.duration(tl) and (active < 0 or t >= active):done = true
		if active >= 0 and t >= active and life <= 0 and Kernel.Timeline.duration(tl) > 2000:done = true
		if done:objects.remove_at(i)

# ---------------------------------------------------------------- world

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
	clear_monsters()
	objects.clear()
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
	player["stuck_ms"] = 0.0
	player["push_ms"] = 0.0
	player["invuln_ms"] = 700.0
	door_lock_ms = 700.0
	if not room_cleared:
		var boss := bool(entry.get("boss",false))
		for i in int(entry["enemies"]):
			var kind := String(entry.get("boss_monster","goblin")) if boss and i==0 else "goblin"
			spawn_enemy(Vector2(350+i*65,222+(i%2)*38),boss and i==0,kind)
	notice(String(entry["name"])+(" · 领主出现" if entry.get("boss",false) else ""))

func door_point(side: String) -> Vector2:
	return {"right":Vector2(603,249),"left":Vector2(37,249),"up":Vector2(480,174),"down":Vector2(480,295)}.get(side,Vector2.ZERO)

## HP and attack are the adapt bases scaled by the MOB [ability category] percentages.
func spawn_enemy(point: Vector2, chief := false, kind := "goblin") -> Dictionary:
	var m: Dictionary = table.monsters[kind]
	var base: Dictionary = rules["monster_base"]
	var hp := float(m["hp"])*(float(base["boss_hp_scale"]) if chief else 1.0)
	var enemy := {"id":_next_entity_id,"kind":kind,"def":m,"mob":m["mob"],"pos":constrain_pos(point),"z":0.0,"vz":0.0,
		"facing":-1,"state":"idle","clock":0.0,"hp":hp,"max_hp":hp,"chief":chief,
		"attack":float(m["attack"])*(float(base["boss_attack_scale"]) if chief else 1.0),
		"stun_ms":0.0,"push_v":0.0,"push_ms":0.0,"hit_motion":"damage1","bounced":false,"down_ms":0.0,"stuck_ms":0.0,
		"flash_ms":0.0,"cooldown_ms":500.0,"hits":{},"thrown":false,"death_ms":0.0,"ai":true}
	monsters.append(enemy)
	_next_entity_id += 1
	bus.emit("combat.entity_spawned",{"entity_id":enemy["id"],"kind":"monster","appearance":String(m["bank"]),"chief":chief})
	return enemy

func clear_monsters() -> void:
	for enemy: Dictionary in monsters:
		bus.emit("combat.entity_removed",{"entity_id":enemy["id"]})
	monsters.clear()

# ---------------------------------------------------------------- presentation state

func player_ani() -> Array:
	var state: String = player["state"]
	var rp: Dictionary = rules["reaction"]
	if state=="action":
		if String(player["action"]) == "buff":return [String(move_def("buff")["ani"]),float(player["clock"])]
		return [String(action_def()["ani"]),float(player["clock"])]
	if state=="dead":return ["down",float(table.player_timeline("down")[2]["start_ms"]) if table.player_timeline("down").size()>2 else 0.0]
	if state=="hurt":return [String(player["hit_motion"]),0.0]
	if state=="air":return ["overturn",0.0]
	if state=="down":return ["down",Kernel.Reaction.down_clock(player,rp,table.player_timeline("down"))]
	if state=="guard":return ["guard",0.0]
	if state=="backstep":return ["hitback",float(player["clock"])]
	if float(player["z"])>0:return ["jump",minf(float(player["air_ms"]),600) if float(player["vz"])>=0 else 10680.0]
	if float(player["landing_ms"])>0:return ["sit",0.0]
	if state=="move":return ["dash" if run_direction!=0 else "move",float(player["motion_clock"])]
	return ["stay",float(player["motion_clock"])]

func enemy_ani(enemy: Dictionary) -> Array:
	var m: Dictionary = enemy["def"]
	var rp: Dictionary = rules["reaction"]
	match String(enemy["state"]):
		"move":return ["move",float(enemy["clock"])]
		"attack":return ["attack",float(enemy["clock"])]
		"hurt":return [String(enemy["hit_motion"]),0.0]
		"air":return ["overturn",0.0]
		"down":return ["down",Kernel.Reaction.down_clock(enemy,rp,table.monster_timeline(m,"down"))]
		"dead":
			var tl: Array = table.monster_timeline(m,"down")
			if float(enemy["z"])>0:return ["overturn",0.0]
			return ["down",(float(tl[2]["start_ms"]) if tl.size()>2 else 0.0)+minf(float(enemy["death_ms"]),1.0)]
	return ["stay",float(enemy["clock"])]

func skill_bar() -> Array:
	var out: Array = []
	for code: int in SKILL_KEYS:
		var name: String = SKILL_KEYS[code]
		out.append({"name":name,"label":String(move_def(name).get("label","")),"key":OS.get_keycode_string(code),
			"cooldown":float(player["cooldowns"].get(name,0)),"mp":float(move_def(name).get("mp",0))})
	return out

## Read-only per-tick state for view/ and ui/combat/ (contract doc 29 section 4). Values only.
func view_snapshot() -> Dictionary:
	var ani := player_ani()
	var enemies: Array = []
	var alive := 0
	for enemy: Dictionary in monsters:
		var e_ani := enemy_ani(enemy)
		var is_alive := float(enemy["hp"])>0
		if is_alive:alive += 1
		enemies.append({"id":enemy["id"],"pos":Vector2(enemy["pos"]),"z":float(enemy["z"]),"facing":int(enemy["facing"]),
			"ani":String(enemy["def"]["motions"].get(e_ani[0],e_ani[0])),"clock":e_ani[1],"flash":float(enemy["flash_ms"])>0,"alive":is_alive,
			"death_ms":float(enemy["death_ms"]),"hp_ratio":float(enemy["hp"])/float(enemy["max_hp"]),"chief":enemy["chief"]})
	var objs: Array = []
	for o: Dictionary in objects:
		if String(o["def"]["bank"]) == "":continue
		objs.append({"id":o["id"],"bank":String(o["def"]["bank"]),"pos":Vector2(o["pos"]),"z":float(o["z"]),"facing":int(o["facing"]),"clock":float(o["clock"])})
	var route: Array = []
	for i in rules["rooms"].size():
		var room: Dictionary = rules["rooms"][i]
		route.append({"cell":room["cell"],"visited":room_snapshots.has(i),"current":i==room_index,"boss":bool(room.get("boss",false))})
	var boss_room := bool(rules["rooms"][room_index].get("boss",false))
	return {"frame":_frame,"paused":paused,
		"player":{"pos":Vector2(player["pos"]),"z":float(player["z"]),"facing":int(player["facing"]),"ani":ani[0],"clock":ani[1],
			"flash":float(player["flash_ms"])>0,"buff":float(player["buff_ms"])>0,"weapon":weapon,
			"aura":String(move_def("buff").get("aura_fx","")) if float(player["buff_ms"])>0 else ""},
		"enemies":enemies,"objects":objs,"props":props.duplicate(true),
		"stage":{"room_index":room_index,"cleared":room_cleared and not boss_room,"doors":doors.duplicate(true)},
		"hud":{"room_name":String(rules["rooms"][room_index]["name"]),"alive":alive,"room_cleared":room_cleared,
			"route":route,"combo":combo_count,"toast":toast,"toast_ms":toast_ms,"skills":skill_bar(),
			"player":{"hp":float(player["hp"]),"mp":float(player["mp"]),"hp_max":max_hp,"mp_max":max_mp,
				"job":job,"weapon":weapon,"buff_ms":float(player["buff_ms"]),"buff_label":String(move_def("buff").get("label","")),
				"cooldowns":Dictionary(player["cooldowns"]).duplicate()},
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
		draw_string(ThemeDB.fallback_font,Vector2(35,90),"Combat cannot start.",HORIZONTAL_ALIGNMENT_LEFT,-1,22,Color.WHITE)
		draw_string(ThemeDB.fallback_font,Vector2(35,130),missing_reason,HORIZONTAL_ALIGNMENT_LEFT,-1,13,Color.WHITE)
