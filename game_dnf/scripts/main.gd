extends Node2D
## Transitional battle scene: composition root + the trial room loop. Combat rules come from the
## kernel (combat/api/kernel.gd) and the original content pack; presentation lives in view/ and
## ui/combat/ and only consumes view_snapshot() and combat.* events (doc 29, F1~F5).
## Outside code reaches it only through combat/api/combat_session.gd.
const EventBus = preload("res://core/event_bus.gd")
const DetRng = preload("res://core/det_rng.gd")
const ContentDB = preload("res://content/api/content_db.gd")
const CombatSession = preload("res://combat/api/combat_session.gd")
const Kernel = preload("res://combat/api/kernel.gd")
const BattleView = preload("res://view/battle_view.gd")
const MapLoader = preload("res://scripts/native_map_loader.gd")
const NativeMaze = preload("res://combat/data/native_maze.gd")
const NativeBreakable = preload("res://combat/resolve/native_breakable.gd")
const NativePotMonsters = preload("res://combat/resolve/native_pot_monsters.gd")
const NativeJarTraps = preload("res://combat/resolve/native_jar_traps.gd")
const NativeZealotSummons = preload("res://combat/resolve/native_zealot_summons.gd")
const FrenzyRecovery = preload("res://combat/resolve/frenzy_recovery.gd")
const NativeBoxLoot = preload("res://loot/native_box.gd")
const COMBAT_ASSETS := "res://assets_local/combat/manifest.json"
const PLAYER_ID := 0
const GHOST_FIELD_KINDS := ["khazan_field","bremen_field","saya_field","rasa_field"]
const ENEMY_ATTACK_RATE_REFRESH_MS := 300.0
const OPPOSITE := {"left":"right","right":"left","up":"down","down":"up"}
## Double tap window for running, measured from the release of the first tap.
const RUN_TAP_MS := 240
## Recovery input is kept briefly so a press during hitstun does not disappear.
const RECOVERY_INPUT_BUFFER_MS := 120.0
const Numbers = preload("res://stats/api/numbers.gd")
const ActorNumbers = preload("res://stats/api/actor_numbers.gd")
const CompanionProgram = preload("res://combat/action/companion_program.gd")
var numeric_player
var skill_levels: Dictionary = {}
var skill_material_spender: Callable
var skill_slots: Array = ["", "", "", "", "", "", "", "", "", "", "", ""]
var numeric_monster_level := 1
var numeric_difficulty := "normal"
var last_damage: Dictionary = {}

## Set before entering the tree when a flow root manages this scene (see CombatSession.mount).
var external_mode := false
var bus = EventBus.new()
var content = ContentDB.new()
var table = Kernel.MoveTable.new()
var map_loader = MapLoader.new()
var rng = DetRng.new(1)
var session
var view
var run_id := "standalone"
var room_id := ""
var dungeon_id := "lorien"
var assets: Dictionary = {}
var combat_assets: Dictionary = {}
var rules: Dictionary = {}
var player_clips: Dictionary = {}
var player: Dictionary = {}
var monsters: Array = []
var companions: Array[Dictionary] = []
var _companion_programs: Dictionary = {}
var objects: Array = []
var props: Array = []
var native_jar_traps := NativeJarTraps.new()
var native_zealot_summons := NativeZealotSummons.new()
var frenzy_recovery := FrenzyRecovery.new()
var room_index := 0
var room_cleared := false
var room_snapshots: Dictionary = {}
var native_maze: NativeMaze
var native_room: Dictionary = {}
var native_route_name := ""
var native_bgm_volume_db := -28.0
var room_map: Dictionary = {}
var room_width := 640.0
var _walk_component_ready := false
var _walk_main_cells: Dictionary = {}
var doors: Array = []
var held: Dictionary = {}
var taps: Dictionary = {}
var requests: Array = []
var last_direction_tap: Dictionary = {}
var last_direction_release: Dictionary = {}
var run_direction := 0
var bar_target := -1
var max_hp := 0.0
var max_mp := 0.0
var item_restorations: Array = []
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
var last_defeat_id := 0
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
var _dynamic_refresh_ms := 0.0
var _aura_pulse_ms := 0.0
var test_drive
var _frame := 0
## Isolated testbed bootstrap; set by a harness before add_child(). Empty keeps production paths.
var test_content_pack := ""
var test_adapt_path := ""
var test_combat_assets_path := ""
var test_dungeon_id := ""
var _muted := false:
	set(value):
		_muted = value
		if view != null:view.audio.muted = value

func _ready() -> void:
	var internal_test := "--test" in OS.get_cmdline_user_args() or test_content_pack != "" or test_dungeon_id != ""
	if not external_mode and not internal_test:
		return _fail("Independent battle entry was removed. Run tools/run_dnf_loop.ps1.")
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	if test_content_pack != "":content.pack_path = test_content_pack
	var adapt_path := test_adapt_path if test_adapt_path != "" else "res://data/combat.json"
	if not content.load_files("res://assets_local/manifest.json",adapt_path,"res://data/override"):
		return _fail("Local DNF assets are missing. Run tools/run_dnf_loop.ps1.")
	var combat_assets_path := test_combat_assets_path if test_combat_assets_path != "" else COMBAT_ASSETS
	if not FileAccess.file_exists(combat_assets_path):
		return _fail("Combat assets missing. Run python tools/build_dnf_combat_assets.py (needs sync --full).")
	assets = content.runtime
	rules = content.rules()
	combat_assets = JSON.parse_string(FileAccess.get_file_as_string(combat_assets_path))
	if not table.build(content,rules,combat_assets):
		return _fail("Combat tables incomplete: "+", ".join(table.problems.slice(0,3)))
	if not map_loader.load_export(String(rules["map_export"])):
		return _fail("Lorien map export missing. Run tools/run_dnf_loop.ps1 (needs the full library).")
	player_clips = content.clips("player").duplicate()
	player_clips.merge(combat_assets.get("player_clips",{}),false)
	view = BattleView.new()
	add_child(view)
	view.setup(assets,combat_assets,player_clips,bus,weapon,map_loader)
	if not external_mode:
		session = CombatSession.new()
		session.attach(self)
		if test_dungeon_id != "":dungeon_id = test_dungeon_id
		restart()
	if "--test" in OS.get_cmdline_user_args():
		_muted = true
		if not external_mode:
			test_drive = load("res://scripts/test_drive.gd").new()
			test_drive.game = self
			add_child(test_drive)

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
	begin_room({"run_id":"standalone","dungeon":dungeon_id,"room_index":0,"from":"start"})
	notice("洛兰 · 清除怪物，继续深入")

## Physical attack power before skill percentages (E-ADAPT until equipment/stats exist).
func attack_power() -> float:
	if numeric_player != null:return float(numeric_player.values["physical_panel"])
	return float(rules["player"]["physical_attack"])*damage_scale

func update_numbers(spec: Dictionary, vitals_policy := "preserve") -> bool:
	if player.is_empty() or not spec.get("numbers") is Dictionary or spec["numbers"].is_empty():return false
	if vitals_policy not in ["preserve","refill"]:return false
	if numeric_player == null:numeric_player = ActorNumbers.new()
	numeric_player.configure(spec)
	skill_levels = Numbers.Skills.effective_levels(spec.get("skills",Numbers.shared_config()["skill_defaults"]),Numbers.shared_config())
	var seed: Dictionary = spec.get("number_seed", {})
	if seed.has("growtype"):
		job = String(seed["growtype"])
	if spec.has("weapon") and assets["players"].has(spec["weapon"]) and weapon != spec["weapon"]:
		weapon = spec["weapon"]
	if spec.has("weapon_item"):table.bind_swordman_weapon(String(spec["weapon_item"]),player_clips)
	table.configure_skills(skill_levels, job, weapon)
	configure_skill_slots(spec.get("skill_slots",skill_slots))
	max_hp = float(numeric_player.values["hp_max"])
	max_mp = float(numeric_player.values["mp_max"])
	player["hp"] = max_hp if vitals_policy=="refill" else clampf(float(player["hp"]),0,max_hp)
	player["mp"] = max_mp if vitals_policy=="refill" else clampf(float(player["mp"]),0,max_mp)
	bus.emit("combat.attributes_changed",{"target":PLAYER_ID,"numbers":numeric_player.values.duplicate(true)})
	return true

## The flow commits the revival transaction before calling this bridge. The room,
## enemies, drops, elapsed time and skill cooldowns stay on the live battle.
func can_revive(spec: Dictionary) -> bool:
	if player.is_empty() or not finished or victory or float(player["hp"])>0:return false
	if spec.get("run_id")!=run_id or spec.get("room_id")!=room_id or spec.get("death_id")!=last_defeat_id or last_defeat_id<=0:return false
	for field in ["hp_percent","mp_percent","invulnerable_ms"]:
		if not Numbers.whole(spec.get(field),1 if field=="hp_percent" else 0,30000 if field=="invulnerable_ms" else 100):return false
	var actor=spec.get("player")
	if not actor is Dictionary:return false
	if numeric_player != null:
		if not actor.get("numbers") is Dictionary or not actor.get("number_seed") is Dictionary or not actor.get("skills") is Dictionary:return false
		for field in ["hp_max","mp_max"]:
			var value=actor["numbers"].get(field)
			if not (value is int or value is float) or not is_finite(float(value)) or value<(1 if field=="hp_max" else 0):return false
		var seed: Dictionary=actor["number_seed"];var cfg:=Numbers.shared_config()
		if not Numbers.whole(seed.get("level"),1,int(cfg["progression"]["level_cap"])) or not Numbers.has_growtype(seed.get("growtype","")) or not seed.get("modifiers") is Array:return false
		for modifier in seed["modifiers"]:
			if not Numbers.valid_modifier(modifier,cfg):return false
		for id in actor["skills"]:
			if not cfg["skills"].has(id) or not Numbers.whole(actor["skills"][id],0,int(cfg["skills"][id]["max_level"])):return false
	return true

func revive_player(spec: Dictionary) -> bool:
	if not can_revive(spec):return false
	var point: Vector2=player["pos"];var facing: int=int(player["facing"])
	leave_action()
	var cooldowns: Dictionary=Dictionary(player["cooldowns"]).duplicate(true)
	var had_numeric:=numeric_player!=null
	player=new_player()
	player["pos"]=point;player["facing"]=facing;player["cooldowns"]=cooldowns
	if had_numeric:
		numeric_player=ActorNumbers.new()
		if not update_numbers(spec["player"],"refill"):return false
	player["hp"]=maxf(1,max_hp*int(spec["hp_percent"])/100.0)
	player["mp"]=max_mp*int(spec["mp_percent"])/100.0
	player["invuln_ms"]=float(spec["invulnerable_ms"])
	finished=false;victory=false;paused=true
	held.clear();requests.clear();taps.clear();last_direction_tap.clear();last_direction_release.clear();run_direction=0
	view.play_revive_effect(point,float(player["z"]))
	bus.emit("combat.player_revived",flow_payload({"death_id":last_defeat_id,"invulnerable_ms":int(spec["invulnerable_ms"])}))
	return true

func configure_monster_numbers(level: int, difficulty: String) -> bool:
	if numeric_player == null or level<1 or level>int(Numbers.shared_config()["progression"]["level_cap"]):return false
	if not Numbers.shared_config()["monsters"]["difficulty"].has(difficulty):return false
	numeric_monster_level = level
	numeric_difficulty = difficulty
	for enemy: Dictionary in monsters:configure_enemy_numbers(enemy)
	return true

func configure_enemy_numbers(enemy: Dictionary) -> void:
	var m: Dictionary = enemy["def"]
	var base: Dictionary = rules["monster_base"]
	var monster_base := {"hp":float(m["hp"])*(float(base["boss_hp_scale"]) if enemy["chief"] else 1.0),"attack":float(m["attack"])*(float(base["boss_attack_scale"]) if enemy["chief"] else 1.0),"hit_recovery":float(m["hit_recovery"])}
	var ratio := float(enemy["hp"])/maxf(1,float(enemy["max_hp"]))
	var actor = enemy.get("numeric")
	if actor == null:actor = ActorNumbers.new()
	var stats := Numbers.monster(monster_base,int(enemy.get("source_level",numeric_monster_level)),bool(enemy["chief"]),numeric_difficulty)
	stats["blind_resistance"] = int(m["blind_resistance"])
	stats["sleep_resistance"] = int(m["sleep_resistance"])
	stats["poison_resistance"] = int(m["poison_resistance"])
	stats["bleeding_resistance"] = int(m.get("bleeding_resistance",0))
	if m.has("native_attack_rate"):stats["attack_speed"] = m["native_attack_rate"]
	if m.has("native_spirit_summon"):stats["cast_speed"] = m["native_spirit_summon"]["cast_rate"]
	actor.configure({"numbers":stats})
	enemy["numeric"] = actor
	enemy["max_hp"] = float(actor.values["hp_max"])
	enemy["hp"] = float(enemy["max_hp"])*ratio
	enemy["attack"] = float(actor.values["physical_attack"])

func step_numeric_actor(body: Dictionary, actor, ms: float) -> void:
	if float(body["hp"])<=0:return
	var events: Array = actor.step(ms,body["state"]=="down")
	if int(body["id"])!=PLAYER_ID:
		body["max_hp"] = float(actor.values["hp_max"])
		body["attack"] = float(actor.values["physical_attack"])
	body["hp"] = minf(float(body["hp"]),float(actor.values["hp_max"]))
	for event: Dictionary in events:
		if event["type"]=="removed":
			if body["id"]==PLAYER_ID and event["id"]=="thirst":stop_thirst_loop()
			if event["id"]=="sleep" and body["state"]=="down":
				body["down_ms"] = float(rules["reaction"]["down_hold_ms"])
			bus.emit("combat.status",{"target":body["id"],"id":event["id"],"change":"removed"})
			continue
		if int(body["id"])==PLAYER_ID and god_mode:continue
		if event["type"]=="frenzy_drain":
			# The appendage writes HP directly and removes itself at the HP floor.
			var hp := float(body["hp"])
			var drain := int(event["damage"])
			body["hp"] = maxf(1.0,hp-drain)
			if int(hp)<=drain and actor.remove_effect(event["id"]):
				bus.emit("combat.status",{"target":body["id"],"id":event["id"],"change":"removed"})
			continue
		var point := Vector3(body["pos"].x,body["pos"].y,float(body["z"]))
		if event["type"] == "damage_number":
			bus.emit("combat.damage_number",{"target":body["id"],"amount":event["damage"],"id":event["id"],
				"victim":victim_kind(body),"point":point})
			continue
		var direct: bool = event["type"] == "direct_damage"
		var amount := int(event["damage"])
		if not direct:
			var resolved := Numbers.Damage.resolve({"independent_attack":100,"level":numeric_monster_level},actor.values,{"percent":0,"fixed":event["damage"],"damage_type":event["damage_type"]},[0.0,1.0],Numbers.shared_config()["formula"])
			amount = int(resolved["amount"])
		body["hp"] = maxf(0,float(body["hp"])-amount)
		bus.emit("combat.damage",{"target":body["id"],"amount":amount,"critical":false,"category":event["damage_type"],
			"victim":victim_kind(body),"reaction":"none","point":point,"show_number":not direct})
		if body["id"]==PLAYER_ID:
			damage_taken += amount
			if float(body["hp"])<=0:
				if player.has("draw_cast"):leave_action()
				body["state"] = "dead"
				finished = true
				victory = false
				item_restorations.clear()
				emit_player_defeated()
		elif float(body["hp"])<=0:
			body["state"] = "dead"
			body["death_ms"] = 0.0
			if body.has("companion_id"):report_companion_defeat(body)
			else:report_defeat(body)
		if float(body["hp"])<=0:break

## Spec fields (contract v1): run_id, room_id, room_index (transitional trial route), from (entry side),
## player {hp, mp, hp_max, mp_max, damage_multiplier, job, weapon}, audio {muted, bgm_volume_db}.
## Long-term profile data stays with flow; these are the per-run combat stats it hands over.
## Without flow values, HP/MP start from the original CHR level-1 initial stats.
func begin_room(spec: Dictionary, maze: NativeMaze = null) -> void:
	stop_thirst_loop()
	dungeon_id=String(spec.get("dungeon","lorien"))
	var leaving_maze := native_maze != null and maze == null
	native_maze = maze
	native_room = maze.current_room() if maze != null else {}
	native_route_name = String(spec.get("route",{}).get("name","神殿周边"))
	var snapshot: Dictionary = spec.get("player",{})
	numeric_player = null
	skill_levels = {}
	last_damage = {}
	numeric_monster_level = 1
	numeric_difficulty = "normal"
	if snapshot.get("job","") in ["weaponmaster","berserker"]:job = String(snapshot["job"])
	if assets["players"].has(String(snapshot.get("weapon",""))) and weapon != snapshot["weapon"]:
		weapon = String(snapshot["weapon"])
	table.bind_swordman_weapon(String(snapshot.get("weapon_item","")),player_clips)
	max_hp = float(snapshot.get("hp_max",table.player["hp_max"]))
	max_mp = float(snapshot.get("mp_max",table.player["mp_max"]))
	damage_scale = float(snapshot.get("damage_multiplier",1.0))
	player = new_player()
	if not update_numbers(snapshot,"refill"):table.configure_skills({},job,weapon)
	if String(spec.get("run_id","standalone")) == "standalone":
		configure_skill_slots(["draw","triple","rage_slash","buff","guard",""])
	else:
		configure_skill_slots(snapshot.get("skill_slots",[]))
	if snapshot.has("hp"):player["hp"] = clampf(float(snapshot["hp"]),1,max_hp)
	if snapshot.has("mp"):player["mp"] = clampf(float(snapshot["mp"]),0,max_mp)
	var audio_spec: Dictionary = spec.get("audio",{})
	if audio_spec.has("muted"):_muted = bool(audio_spec["muted"])
	if leaving_maze or (maze != null and _muted):view.audio.music.stop()
	if maze != null:
		native_bgm_volume_db = float(audio_spec.get("bgm_volume_db",-28.0))
	elif audio_spec.has("bgm_volume_db") and not _muted:
		view.audio.start_music(float(audio_spec["bgm_volume_db"]))
	run_id = String(spec.get("run_id","standalone"))
	rng.reseed(hash(run_id))
	room_snapshots.clear()
	companions.clear()
	finished = false
	item_restorations.clear()
	victory = false
	last_defeat_id = 0
	paused = false
	elapsed_ms = 0
	native_jar_traps.reset_clock()
	damage_taken = 0
	hit_count = 0
	combo_count = 0
	requests.clear()
	held.clear()
	taps.clear()
	if maze != null:
		load_room(int(native_room["room_index"]),"start")
	else:
		load_room(clampi(int(spec.get("room_index",0)),0,rules["rooms"].size()-1),String(spec.get("from","start")))
		if spec.has("room_id"):room_id = String(spec["room_id"])

func new_player() -> Dictionary:
	return {"id":PLAYER_ID,"pos":Vector2(125,250),"z":0.0,"vz":0.0,"air_ms":0.0,"hp":max_hp,"mp":max_mp,
		"facing":1,"state":"idle","action":"","stage":0,"clock":0.0,"motion_clock":0.0,
		"guard_hold_ms":0.0,"guard_recoil_ms":0.0,
		"guard_recoil_speed":0.0,"guard_recoil_accel":0.0,
		"guard_dust_emitted":false,
		"stun_ms":0.0,"push_v":0.0,"push_ms":0.0,"hit_motion":"damage1","bounced":false,"down_ms":0.0,"stuck_ms":0.0,
		"invuln_ms":0.0,"flash_ms":0.0,"upper_armor_fx_ms":0.0,"landing_ms":0.0,"buff_ms":0.0,"cooldowns":{},"hits":{},
		"queued_combo":false,"queued_skill":"","queued_jump":false,"queued_backstep":false,"fx_tag":"",
		"hardattack_ghost":"khazan",
		"recovery_code":-1,"recovery_buffer_ms":0.0,"air_attack_used":false,"air_move_speed":0.0}

func emit_player_defeated() -> void:
	stop_thirst_loop()
	frenzy_recovery.clear()
	var event: Dictionary=bus.emit("combat.player_defeated",flow_payload())
	last_defeat_id=int(event.get("event_id",0))

## Keys owned by the flow side when externally managed: pause/menu, character and debug switches.
const FLOW_OWNED_KEYS := [KEY_TAB,KEY_1,KEY_2,KEY_3,KEY_ESCAPE,KEY_F2,KEY_F3]
const SkillSlots = preload("res://stats/api/skill_slots.gd")
const SKILL_SLOT_KEYS := SkillSlots.KEYS

func skill_slot_index(code: int) -> int:
	return SKILL_SLOT_KEYS.find(code)

func skill_request(code: int) -> String:
	var index := skill_slot_index(code)
	if index < 0:return ""
	var id := String(skill_slots[index])
	if code == KEY_G and id == "" and not skill_slots.has("guard"):return "guard"
	return id

func guard_input_held() -> bool:
	return skill_input_held("guard")

func skill_input_held(name: String) -> bool:
	for code: int in SKILL_SLOT_KEYS:
		if held.get(code,false) and skill_request(code) == name:return true
	return false

func configure_skill_slots(slots: Array) -> void:
	skill_slots = []
	skill_slots.resize(SkillSlots.COUNT)
	skill_slots.fill("")
	for index in mini(SkillSlots.COUNT,slots.size()):
		var id := String(slots[index])
		if id != "" and move_def(id).size() > 0 and (skill_levels.is_empty() or int(skill_levels.get(id,0)) > 0):
			skill_slots[index] = id

func _input(event: InputEvent) -> void:
	if not event is InputEventKey:return
	var key_event := event as InputEventKey
	var code := int(key_event.physical_keycode if key_event.physical_keycode != 0 else key_event.keycode)
	if external_mode and code in FLOW_OWNED_KEYS:return
	if key_event.echo:return
	held[code] = key_event.pressed
	if code in [KEY_LEFT,KEY_RIGHT]:
		var direction := -1 if code == KEY_LEFT else 1
		var now := Time.get_ticks_msec()
		if not key_event.pressed:
			last_direction_release[direction] = now
		else:
			# Run = press, release, press again within the window (DNF double tap).
			if last_direction_release.has(direction) and now-int(last_direction_release[direction]) < RUN_TAP_MS:run_direction = direction
			last_direction_release.erase(direction)
			last_direction_tap[direction] = now
	if not key_event.pressed:return
	taps[code] = true
	if missing_assets:return
	match code:
		KEY_F1:help_visible = not help_visible
		KEY_ESCAPE:paused = not paused
		KEY_R:
			if finished and not external_mode:restart()
			elif not paused and not finished:requests.append(code)
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
			table.configure_skills(skill_levels,job,weapon)
		KEY_X,KEY_Z,KEY_C,KEY_SPACE:
			if not paused and not finished:requests.append(code)
		_:
			if code in SKILL_SLOT_KEYS and not paused and not finished:requests.append(code)

func notice(message: String) -> void:
	toast = message
	toast_ms = 2200

func _physics_process(delta: float) -> void:
	_frame += 1
	if missing_assets or player.is_empty():return
	if test_drive != null:test_drive.before_tick()
	var ms := delta*1000
	toast_ms = maxf(0,toast_ms-ms)
	_dynamic_refresh_ms = maxf(0,_dynamic_refresh_ms-ms)
	_aura_pulse_ms = maxf(0,_aura_pulse_ms-ms)
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
# ---------------------------------------------------------------- player

func move_def(name: String) -> Dictionary:
	if name == "triple" and player.get("action","") == "triple" and player.has("triple_cast"):
		return player["triple_cast"]
	if name == "weaponcombo" and player.get("action","") == name and player.has("weapon_combo_cast"):
		return player["weapon_combo_cast"]
	if name == "draw" and player.get("action","") == name and player.has("draw_cast"):
		return player["draw_cast"]
	return table.moves.get(name,{})

func active_effect(id: String) -> Dictionary:
	if numeric_player == null:return {}
	return numeric_player.effects.active.get(id,{})

func effect_form(form: String) -> bool:
	if numeric_player == null:return false
	for effect: Dictionary in numeric_player.effects.active.values():
		if String(effect.get("definition",{}).get("form","")) == form:return true
	return false

func primary_normal_attack() -> String:
	if effect_form("dual_wield"):return "frenzy1"
	if effect_form("ghost_step"):return "ghoststep_attack1"
	if effect_form("kalla"):return "kalla_attack1"
	if effect_form("wave_eye"):return "waveeye_attack1"
	return "attack1"

func skill_damage_multiplier(skill_id: String) -> float:
	if numeric_player == null:return 1.0
	var result := 1.0
	for effect: Dictionary in numeric_player.effects.active.values():
		var definition: Dictionary = effect.get("definition",{})
		var bonuses: Dictionary = definition.get("skill_damage",{})
		if bonuses.has(skill_id):
			result *= 1.0+float(bonuses[skill_id])
	return result

func frenzy_cooldown_reduction_ms(skill_id: String) -> int:
	var frenzy := active_effect("frenzy")
	var columns: Dictionary = frenzy.get("definition",{}).get("skill_cooldown_reduction_rows",{})
	if not columns.has(skill_id):return 0
	# C9D2C0 reads the current effective Frenzy rank when starting the other skill.
	var rank := int(skill_levels.get("buff",0))
	if rank<=0:return 0
	var row: Array = Numbers.Skills.sample(Numbers.record("buff"),rank)["level_row"]
	var column := int(columns[skill_id])
	return int(row[column]) if column<row.size() else 0

func refresh_dynamic_modifiers(force := false) -> void:
	if numeric_player == null:return
	if not force and _dynamic_refresh_ms > 0:return
	_dynamic_refresh_ms = 100.0
	var mods: Array = []
	var hp_ratio := float(player["hp"])/maxf(1.0,float(max_hp))
	var pinch_rank := int(skill_levels.get("pinchpowerup",0))
	if pinch_rank > 0 and hp_ratio < 0.4:
		var sample: Dictionary = Numbers.Skills.sample(Numbers.record("pinchpowerup"),pinch_rank)
		var row: Array = sample.get("level_row",[])
		var strength := (float(row[0])+float(row[1]))/2.0 if row.size()>1 else 0.0
		var evasion := (float(row[2])+float(row[3]))/100.0 if row.size()>3 else 0.0
		var haste := (float(row[4])+float(row[5]))/100.0 if row.size()>5 else 0.0
		var factor := clampf((0.4-hp_ratio)/0.4,0.0,1.0)
		mods.append({"source":"血气唤醒","stat":"strength","op":"add","value":strength*factor})
		mods.append({"source":"血气唤醒","stat":"evasion","op":"add","value":evasion*factor})
		mods.append({"source":"血气唤醒","stat":"attack_speed","op":"mul","value":1.0+haste*factor})
		mods.append({"source":"血气唤醒","stat":"move_speed","op":"mul","value":1.0+haste*factor})
	var bleed_rank := int(skill_levels.get("bleedingmastery",0))
	if bleed_rank > 0:
		var bleeding := 0
		var radius := 800.0
		var record: Dictionary = Numbers.record("bleedingmastery")
		var static_data: Array = record.get("dungeon",record).get("static_data",[])
		if not static_data.is_empty():radius = float(static_data[0])
		for enemy: Dictionary in monsters:
			if float(enemy["hp"])<=0 or not enemy.has("numeric"):continue
			if enemy["numeric"].effects.active.has("bleed") and Vector2(enemy["pos"]).distance_to(Vector2(player["pos"])) <= radius:
				bleeding += 1
		var stacks := mini(bleeding,int(static_data[1]) if static_data.size()>1 else 5)
		if stacks > 0:
			var sample: Dictionary = Numbers.Skills.sample(record,bleed_rank)
			var row: Array = sample.get("level_row",[])
			var strength := float(row[1])*stacks if row.size()>1 else 0.0
			var hit := float(row[2])*stacks/100.0 if row.size()>2 else 0.0
			mods.append({"source":"鲜血之忆","stat":"strength","op":"add","value":strength})
			mods.append({"source":"鲜血之忆","stat":"hit","op":"add","value":hit})
	numeric_player.set_runtime_modifiers(mods)

func pulse_passive_auras() -> void:
	var rank := int(skill_levels.get("darkaura",0))
	if rank > 0:
		var record: Dictionary = Numbers.record("darkaura")
		var sample: Dictionary = Numbers.Skills.sample(record,rank)
		var row: Array = sample.get("level_row",[])
		var radius := float(row[0]) if not row.is_empty() else 550.0
		for enemy: Dictionary in monsters:
			if float(enemy["hp"])<=0:continue
			if Vector2(enemy["pos"]).distance_to(Vector2(player["pos"])) <= radius:
				apply_effect({"kind":"effect","id":"dark_aura","target":enemy["id"],"rank":rank})
	if not active_effect("dotarea").is_empty():
		var dot_rank := int(skill_levels.get("dotarea",1))
		var dot_record: Dictionary = Numbers.record("dotarea")
		var dot_sample: Dictionary = Numbers.Skills.sample(dot_record,dot_rank)
		var dot_row: Array = dot_sample.get("level_row",[])
		var percent := float(dot_row[0]) if not dot_row.is_empty() else 18.0
		for enemy: Dictionary in monsters:
			if float(enemy["hp"])<=0:continue
			if Vector2(enemy["pos"]).distance_to(Vector2(player["pos"])) <= 260.0:
				land_hit(player,enemy,{"atk":{},"atk_path":"","percent":percent,"skill_id":"dotarea","damage_type":"magical","element":"none","lift":-1.0},Vector3(enemy["pos"].x,enemy["pos"].y,float(enemy["z"])),int(player["facing"]),attack_power())
	for aura_entry in [
		["epidemic_aura","epidemicrasa",40.0,"dark",{"id":"slow","chance":0.4}],
	]:
		var effect_id := String(aura_entry[0])
		if active_effect(effect_id).is_empty():continue
		var definition: Dictionary = active_effect(effect_id).get("definition",{})
		var aura: Dictionary = definition.get("aura",{})
		var radius := float(aura.get("radius",260))
		var percent := float(aura.get("damage_percent",aura_entry[2]))
		for enemy: Dictionary in monsters:
			if float(enemy["hp"])<=0:continue
			if Vector2(enemy["pos"]).distance_to(Vector2(player["pos"])) > radius:continue
			var hit_effects: Array = []
			if aura_entry[4] is Dictionary and not (aura_entry[4] as Dictionary).is_empty():
				hit_effects.append((aura_entry[4] as Dictionary).duplicate(true))
			if percent > 0:
				land_hit(player,enemy,{"atk":{},"atk_path":"","percent":percent,"skill_id":String(aura_entry[1]),"damage_type":"magical","element":String(aura_entry[3]),"lift":-1.0,"effects":hit_effects},Vector3(enemy["pos"].x,enemy["pos"].y,float(enemy["z"])),int(player["facing"]),attack_power())

## Current stage of the running action (three-stage skills keep one move with stages).
func action_def() -> Dictionary:
	if player.has("hardattack_release"):return player["hardattack_release"]
	if player.has("weapon_combo_release"):return player["weapon_combo_release"]
	var m := move_def(String(player["action"]))
	if m.has("stages"):return m["stages"][int(player["stage"])]
	return m

func action_duration(action: String) -> float:
	var m := move_def(action)
	if String(player.get("action","")) == action and player.get("native_phase",{}).has("end_ms"):
		return float(player["native_phase"]["end_ms"])
	var stage := action_def() if String(player.get("action","")) == action else m
	# Generic moves retain the ANI duration. Only an evidenced state controller
	# may replace its waiting/recovery phases with a different action lifetime.
	return maxf(float(stage.get("duration",0)),float(m.get("cast_ms",0)))

func action_ani_clock(elapsed: float) -> float:
	var phase: Dictionary = player.get("native_phase",{})
	if phase.has("thirst_loop_ms"):
		return float(phase["body_clock"])
	if phase.has("cast_stage_rate"):return elapsed*float(phase["cast_stage_rate"])
	if phase.has("charge_rate"):
		var release_at := float(phase["wait_ms"])
		return elapsed*float(phase["charge_rate"]) if elapsed < release_at else elapsed-release_at
	return Kernel.NativeWave.ani_clock(phase,elapsed) if not phase.is_empty() else elapsed

func action_event_clock(elapsed: float) -> float:
	var phase: Dictionary = player.get("native_phase",{})
	return elapsed-float(phase["wait_ms"]) if phase.has("charge_rate") else action_ani_clock(elapsed)

func buffering(code: int) -> void:
	if code in [KEY_X,KEY_Z] and player["action"] == "upper":
		var followup := float(move_def("upper").get("upper_followup_at",-1.0))
		if followup >= 0.0:
			if int(player["stage"]) == 0 and float(player["clock"]) >= followup:
				player["queued_upper_followup"] = true
			return
	if code == KEY_X and player["action"] == "draw" and move_def("draw").has("draw_second_slash_at"):
		player["queued_combo"] = true
		return
	if code in [KEY_C,KEY_SPACE] and held.get(KEY_DOWN,false) and backstep_allowed():player["queued_backstep"] = true
	elif code == KEY_X and String(player["action"]) in ["attack1","attack2","attack3","weaponcombo","frenzy1","frenzy2","frenzy3","ghoststep_attack1","ghoststep_attack2","kalla_attack1","kalla_attack2","kalla_attack3","waveeye_attack1","waveeye_attack2","waveeye_attack3"]:player["queued_combo"] = true
	elif code == KEY_Z:player["queued_skill"] = "upper"
	elif skill_slot_index(code) >= 0:
		var id := skill_request(code)
		if id == "backstep" and backstep_allowed():player["queued_backstep"] = true
		elif id != "":player["queued_skill"] = id
	elif code in [KEY_C,KEY_SPACE] and String(player["action"]) == "upper":player["queued_jump"] = true

func buffer_recovery_input(code: int) -> void:
	if not (code in [KEY_X,KEY_Z,KEY_C,KEY_SPACE] or skill_slot_index(code) >= 0):return
	player["recovery_code"] = code
	player["recovery_buffer_ms"] = RECOVERY_INPUT_BUFFER_MS

func consume_recovery_input() -> int:
	var code := int(player.get("recovery_code",-1))
	if code < 0 or float(player.get("recovery_buffer_ms",0.0)) <= 0.0:
		player["recovery_code"] = -1
		player["recovery_buffer_ms"] = 0.0
		return -1
	player["recovery_code"] = -1
	player["recovery_buffer_ms"] = 0.0
	return code

## Back step (Down + jump): from free ground states, or cancelling the moves the adapt layer lists.
func backstep_allowed() -> bool:
	if float(player["z"]) > 0 or float(player["vz"]) > 0:return false
	var state := String(player["state"])
	if state in ["idle","move","guard"]:return true
	if state != "action":return false
	if String(player["action"]) in rules["backstep"]["cancels"]:return true
	var stage := action_def()
	if stage.is_empty() or not stage.has("cancel_at"):return false
	return float(player["clock"]) >= float(stage["cancel_at"])

func start_backstep() -> void:
	var b: Dictionary = rules["backstep"]
	if String(player["state"]) == "action":
		var ani := player_ani()
		bus.emit("combat.cue",{"kind":"ghost","pos":Vector2(player["pos"]),"z":float(player["z"]),
			"facing":int(player["facing"]),"ani":ani[0],"clock":ani[1]})
		bus.emit("combat.action_cancelled",{"entity_id":PLAYER_ID,"action":player["action"],"by":"backstep"})
		leave_action()
	player["state"] = "backstep"
	player["action"] = ""
	player["clock"] = 0.0
	player["air_ms"] = 0.0
	player["vz"] = float(b["lift"])
	player["invuln_ms"] = maxf(float(player["invuln_ms"]),float(b["invuln_ms"]))
	player["queued_backstep"] = false
	player["queued_combo"] = false
	player["queued_skill"] = ""
	player["queued_jump"] = false
	player["recovery_code"] = -1
	player["recovery_buffer_ms"] = 0.0
	play_sound("backstep")

## Action-bound effects (slash marks, auras of a move) vanish when the move ends or is cut.
func end_action_fx() -> void:
	if String(player.get("fx_tag","")) != "":
		bus.emit("combat.cue",{"kind":"fx_clear","tag":player["fx_tag"]})
	player["fx_tag"] = ""

func leave_action() -> void:
	# CC490C starts the cooldown only when leaving state 22, not on another stage.
	if player.has("triple_cast"):
		begin_skill_cooldown("triple",player["triple_cast"])
		player.erase("triple_cast")
	end_hardattack_charge()
	player.erase("hardattack_release")
	player.erase("weapon_combo_cast")
	player.erase("weapon_combo_charge")
	player.erase("weapon_combo_release")
	player.erase("weapon_combo_chain")
	player.erase("action_slide")
	player.erase("frenzy_cast")
	player.erase("overdrive_cast")
	player.erase("draw_cast")
	player.erase("draw_charge")
	player.erase("draw_contact_count")
	end_action_fx()

func end_action() -> void:
	leave_action()
	player["native_phase"] = {}
	player["state"] = "jump" if float(player["z"])>0 else "idle"
	player["action"] = ""

func step_game(ms: float) -> void:
	var dt := ms/1000
	if native_maze != null:native_jar_traps.advance_clock(self,ms)
	preload("res://combat/item_restoration.gd").step(self,ms)
	if numeric_player != null:
		step_numeric_actor(player,numeric_player,ms)
		if finished:return
		player["buff_ms"] = float(numeric_player.effects.active.get("frenzy",{}).get("remaining_ms",0))
		max_hp = float(numeric_player.values["hp_max"])
		max_mp = float(numeric_player.values["mp_max"])
		player["hp"] = minf(max_hp,float(player["hp"])+float(numeric_player.values["hp_regen"])*dt)
		player["mp"] = minf(max_mp,float(player["mp"])+float(numeric_player.values["mp_regen"])*dt)
		refresh_dynamic_modifiers()
		max_hp = float(numeric_player.values["hp_max"])
		max_mp = float(numeric_player.values["mp_max"])
	frenzy_recovery.step(self,ms)
	player["invuln_ms"] = maxf(0,float(player["invuln_ms"])-ms)
	player["flash_ms"] = maxf(0,float(player["flash_ms"])-ms)
	player["upper_armor_fx_ms"] = maxf(0,float(player["upper_armor_fx_ms"])-ms)
	player["recovery_buffer_ms"] = maxf(0,float(player.get("recovery_buffer_ms",0.0))-ms)
	if numeric_player == null:player["buff_ms"] = maxf(0,float(player["buff_ms"])-ms)
	player["landing_ms"] = maxf(0,float(player["landing_ms"])-ms)
	door_lock_ms = maxf(0,door_lock_ms-ms)
	for name: String in player["cooldowns"]:
		player["cooldowns"][name] = maxf(0,float(player["cooldowns"][name])-dt)
	if numeric_player == null:player["mp"] = minf(max_mp,float(player["mp"])+dt*float(rules["player"]["mp_regen_per_s"]))
	combo_ms = maxf(0,combo_ms-ms)
	if combo_ms <= 0:combo_count = 0
	var move := Vector2(float(bool(held.get(KEY_RIGHT,false)))-float(bool(held.get(KEY_LEFT,false))),float(bool(held.get(KEY_DOWN,false)))-float(bool(held.get(KEY_UP,false))))
	if move.x == 0 or signi(int(move.x)) != run_direction:run_direction = 0
	if move.length_squared()>1:move = move.normalized()
	var first_new_object_id := _next_entity_id
	# Local hitstop: only the attacker and its targets freeze; inputs are buffered meanwhile.
	if player["state"] == "hold":
		player["stuck_ms"] = maxf(0,float(player["stuck_ms"])-ms)
		requests.clear()
	elif float(player["stuck_ms"]) > 0:
		player["stuck_ms"] = maxf(0,float(player["stuck_ms"])-ms)
		for code: int in requests:buffering(code)
		requests.clear()
	elif numeric_player != null and numeric_player.effects.controlled():
		requests.clear()
		Kernel.Reaction.step_body(player,ms,float(rules["player"]["gravity"]),rules["reaction"],move_in_world)
	else:
		step_player(ms,move)
	# A creature admitted by another monster participates in clear checks now,
	# and receives its first movement update on the following battle tick.
	for index in monsters.size():update_enemy(monsters[index],ms)
	for companion: Dictionary in companions:update_companion(companion,ms)
	step_objects(ms,first_new_object_id)
	native_zealot_summons.step(self,ms,first_new_object_id)
	if _aura_pulse_ms <= 0:
		_aura_pulse_ms = 1000.0
		pulse_passive_auras()
	step_hazards(ms)
	if native_maze != null:native_jar_traps.step(self)
	for prop: Dictionary in props:
		if prop.get("broken",false):prop["broken_ms"] = float(prop.get("broken_ms",0))+ms
	var all_dead := true
	var living := 0
	for enemy: Dictionary in monsters:
		var alive := float(enemy["hp"])>0
		if alive:living += 1
		else:report_defeat(enemy)
		if enemy_registered(enemy):all_dead = false
	if all_dead and not room_cleared:finish_current_room()
	if room_is_open(living) and not finished and door_lock_ms<=0:
		for door: Dictionary in doors:
			# Walking into the gate passes; standing right on it passes as well.
			# The trigger zone follows the gate's own orientation: side doors are narrow in x,
			# up/down doors are narrow in y. A bare 24 px radius missed the wide arch of an
			# up/down gate, so standing on the visible arch could fail to leave the room.
			var offset := Vector2(player["pos"]) - Vector2(door["pos"])
			var side := String(door.get("side",""))
			var inside := inside_door_trigger(offset,side)
			if inside and (move.length()>0 or offset.length()<14 or taps.get(KEY_ENTER,false)):
				if native_maze != null:
					var next := native_maze.move(side)
					if next.is_empty():continue
					room_snapshots[room_index]["props"] = props.duplicate(true)
					room_snapshots[room_index]["jar_traps"] = native_jar_traps.snapshot()
					native_room = next
					load_room(int(next["room_index"]),side)
				else:
					load_room(int(door["to"]),side)
				break

func enemy_registered(enemy: Dictionary) -> bool:
	return float(enemy["hp"]) > 0.0 or float(enemy["death_ms"]) < 820.0

func finish_current_room() -> void:
	var boss := route_boss_room()
	var details := {"boss":boss,"final_room":boss,"source_map_id":int(room_map.get("map_id",-1)),
		"companions_alive":living_companion_ids()}
	if native_maze != null:
		var cleared := native_maze.clear_room(native_room["cell"],0)
		if cleared.is_empty():return
		native_room["cleared"] = true
		var cell: Vector2i = cleared["cell"]
		details["source_cell"] = [cell.x,cell.y]
		details["source_map_id"] = cleared["source_map_id"]
	elif not _muted:
		view.audio.play_music("forest02" if boss else "forest01",view.audio.music.volume_db)
	room_cleared = true
	room_snapshots[room_index] = {"cleared":true,"props":props.duplicate(true)}
	bus.emit("combat.room_combat_finished",flow_payload(details))
	if boss:
		finished = true
		victory = true
	else:
		notice("房间清空 · 通道已开启")

func step_player(ms: float, move: Vector2) -> void:
	var dt := ms/1000
	player["motion_clock"] = float(player["motion_clock"])+ms
	if player["state"] != "idle" or float(player["landing_ms"]) > 0.0:
		player.erase("thirst_idle_origin_ms")
	if player["state"] == "guard":
		player["guard_hold_ms"] = maxf(0.0,float(player["guard_hold_ms"])-ms)
		var recoil_ms := float(player["guard_recoil_ms"])
		if recoil_ms > 0.0:
			var active_ms := minf(recoil_ms,ms)
			var seconds := active_ms/1000.0
			var speed := float(player["guard_recoil_speed"])
			var next_speed := maxf(0.0,speed+float(player["guard_recoil_accel"])*seconds)
			# 8280E0 applies the opposite horizontal direction and keeps depth still.
			move_along_ground_pixels(-int(player["facing"])*(speed+next_speed)*0.5*seconds)
			player["guard_recoil_speed"] = next_speed
			player["guard_recoil_ms"] = recoil_ms-active_ms
			if next_speed < 40.0 and not bool(player["guard_dust_emitted"]):
				var facing := int(player["facing"])
				var point := Vector2(player["pos"]).round()-Vector2(45*facing,0)
				spawn_effect("guard_dust",point,facing,roundf(float(player["z"])))
				player["guard_dust_emitted"] = true
		# CB8AF2 only checks the held command after the current phase's gate.
		if maxf(float(player["guard_hold_ms"]),float(player["guard_recoil_ms"])) <= 0.0 and not guard_input_held():
			player["state"] = "idle"
			play_sound("SWD_GUARD_END")
	if bool(player["queued_backstep"]):
		player["queued_backstep"] = false
		if backstep_allowed():start_action("backstep",true)
	var state: String = player["state"]
	var grounded := float(player["z"])==0 and float(player["vz"])<=0
	if state in ["hurt","air","down"]:
		for code: int in requests:buffer_recovery_input(code)
		requests.clear()
	elif state in ["idle","move","guard","jump"]:
		var recovery_code := consume_recovery_input()
		if recovery_code >= 0:requests.push_front(recovery_code)
	for code: int in requests:
		if code in [KEY_C,KEY_SPACE]:
			if held.get(KEY_DOWN,false) and backstep_allowed():
				if start_action("backstep",true):state = "backstep"
			elif state == "action":buffering(code)
			elif state in ["idle","move","guard"] and grounded:
				player["vz"] = float(numeric_player.values["jump_power"]) if numeric_player != null else float(table.player["jump_power"])
				player["air_ms"] = 0.0
				player["air_attack_used"] = false
				var takeoff_speed := float(rules["player"]["run_speed"] if run_direction != 0 else rules["player"]["walk_speed"])
				if numeric_player != null:takeoff_speed *= float(numeric_player.values["move_speed"])
				player["air_move_speed"] = takeoff_speed
				player["state"] = "jump"
				play_sound("jump")
		elif code == KEY_X:
			if String(player["state"]) == "action":buffering(code)
			elif float(player["z"])>0 or float(player["vz"])>0:
				if not bool(player.get("air_attack_used",false)):start_action("air_attack")
			# Dash attack only out of an actual run (double-tapped direction, still moving).
			elif state == "move" and run_direction != 0 and signf(move.x) == float(run_direction):start_action("dash_attack")
			else:start_action(primary_normal_attack())
		elif code == KEY_Z:
			if String(player["state"]) == "action":buffering(code)
			else:start_action("upper")
		elif skill_slot_index(code) >= 0:
			var id := skill_request(code)
			if id == "backstep" and backstep_allowed():start_action(id,true)
			elif String(player["state"]) == "action":buffering(code)
			else:
				if id != "":start_action(id)
	requests.clear()
	state = player["state"]
	if state == "action":
		step_action(ms,move)
	elif state in ["hurt","air","down"]:
		var gravity := float(player.get("starfish_fall_gravity",rules["player"]["gravity"]))
		if Kernel.Reaction.step_body(player,ms,gravity,rules["reaction"],move_in_world) == "landed":
			player.erase("starfish_fall_gravity")
			player["landing_ms"] = 0.0
		return
	elif state == "backstep":
		player["clock"] = float(player["clock"])+ms
		player["air_ms"] = float(player["clock"])
		move_player(Vector2(-int(player["facing"])*float(rules["backstep"]["speed"])*dt,0))
		if float(player["clock"])>=float(rules["backstep"]["duration_ms"]) and float(player["z"])==0:player["state"] = "idle"
	elif state != "dead":
		if state == "guard":
			if move.x!=0 and float(player["guard_recoil_ms"]) <= 0.0:player["facing"] = 1 if move.x>0 else -1
		elif move.length_squared()>0:
			if move.x!=0:player["facing"] = 1 if move.x>0 else -1
			var speed := float(rules["player"]["run_speed"] if run_direction!=0 else rules["player"]["walk_speed"])
			if numeric_player != null:speed *= float(numeric_player.values["move_speed"])
			elif float(player["buff_ms"])>0:speed *= float(rules["buff"]["move_speed"])
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
			player["air_attack_used"] = false
			player["air_move_speed"] = 0.0
			if String(player["state"]) == "jump":player["state"] = "idle"
			elif String(player["state"]) == "action" and move_def(String(player["action"])).get("air",false):
				end_action()
	if player["state"] == "idle" and float(player["landing_ms"]) <= 0.0 and not active_effect("thirst").is_empty():
		if not player.has("thirst_idle_origin_ms"):player["thirst_idle_origin_ms"] = player["motion_clock"]
	else:
		player.erase("thirst_idle_origin_ms")

func step_action(ms: float, move: Vector2) -> void:
	if player.has("draw_charge"):
		step_draw_charge(ms)
		return
	if player.has("weapon_combo_charge"):
		step_weapon_combo_charge(ms)
		return
	if player.has("hardattack_charge"):
		step_hardattack_charge(ms)
		return
	if player.has("frenzy_cast"):
		step_frenzy_cast(ms)
		return
	if player.has("overdrive_cast"):
		step_overdrive_cast(ms)
		return
	if player["action"] == "sacrifice" and int(player["stage"]) == 0:
		step_thirst_cast(ms)
		return
	var name: String = player["action"]
	var queued := String(player["queued_skill"])
	if queued != "" and queued != name and normal_attack_cancel_allowed(move_def(queued)):
		player["queued_skill"] = ""
		# This source permission interrupts a normal attack immediately; it does
		# not wait for the generic late combo/cancel window or emit its next hit.
		if start_action(queued,true):return
	var m := move_def(name)
	if m.has("upper_followup_at") and int(player["stage"]) == 0 and player.get("queued_upper_followup",false):
		end_action_fx()
		player["fx_tag"] = "act:%d" % (action_seq+1)
		player["queued_skill"] = ""
		player["queued_jump"] = false
		start_stage(1)
		return
	var stage := action_def()
	var old_clock := float(player["clock"])
	var speed: float = float(rules["buff"]["attack_speed"]) if float(player["buff_ms"])>0 and name != "buff" else 1.0
	if numeric_player != null:
		var speed_kind: String = Numbers.shared_config()["skills"].get(name,{}).get("speed","attack")
		speed = float(numeric_player.values["cast_speed" if speed_kind=="cast" else "attack_speed"])
	var clock := old_clock+ms*speed
	var native_phase: Dictionary = player.get("native_phase",{})
	if not native_phase.is_empty():clock = old_clock+ms
	player["clock"] = clock
	if native_phase.has("velocity"):
		var dx := Kernel.NativeWave.distance(native_phase,clock)-Kernel.NativeWave.distance(native_phase,old_clock)
		if dx != 0:move_player(Vector2(dx*int(player["facing"]),0))
	var native_slide := player.has("action_slide")
	if native_slide or m.has("dash"):
		var motion: Dictionary = player["action_slide"] if native_slide else m["dash"]
		var old_motion_clock := old_clock
		var new_motion_clock := clock
		if native_slide:
			old_motion_clock = float(motion["elapsed_ms"])
			# Original forced movement uses its own clock, independently of the ANI.
			var remaining_ms := maxf(0.0,(action_duration(name)-old_clock)/maxf(speed,0.001))
			new_motion_clock = old_motion_clock+minf(ms,remaining_ms)
			motion["elapsed_ms"] = new_motion_clock
		var v0 := float(motion["speed"])
		var a := float(motion["accel"])
		var stop := float(motion.get("stop_s",v0/-a if a < 0 else float(stage.get("duration",0))/1000.0))
		var t0 := minf(old_motion_clock/1000.0,stop)
		var t1 := minf(new_motion_clock/1000.0,stop)
		var dx := (v0*t1+0.5*a*t1*t1)-(v0*t0+0.5*a*t0*t0)
		if dx != 0:
			dx *= int(player["facing"])
			if native_slide:move_along_ground_pixels(dx)
			else:move_player(Vector2(dx,0))
	if bool(m.get("air",false)) and move.length_squared() > 0:
		# Jump attacks keep the airborne steering of a plain jump; facing stays locked.
		var air_speed := float(player.get("air_move_speed",rules["player"]["walk_speed"]))
		if air_speed <= 0.0:air_speed = float(rules["player"]["walk_speed"])
		move_player(Vector2(move.x*air_speed,move.y*air_speed*float(rules["units"]["depth_speed_ratio"]))*ms/1000.0)
	var old_event_clock := action_event_clock(old_clock)
	var event_clock := action_event_clock(clock)
	action_cues(stage,old_event_clock,event_clock)
	apply_player_hits(stage,old_event_clock,event_clock)
	# CB1BB3 checks the full-charge release's body frame before the next phase.
	if stage.has("hardattack_followup") and clock >= float(stage["timeline"][9]["start_ms"]):
		start_hardattack_followup(stage["hardattack_followup"])
		return
	var duration := action_duration(name)
	if name == "bloodblast" and int(player["stage"]) == 0 and clock >= duration:
		start_stage(1)
		return
	if m.has("draw_second_slash_at") and int(player["stage"]) == 0:
		# CBA163 accepts the skill command or the basic attack key in the last frames.
		var requested: bool = player["queued_skill"] == name or bool(player["queued_combo"]) \
			or skill_input_held(name) or bool(held.get(KEY_X,false))
		if player["queued_skill"] == name:player["queued_skill"] = ""
		player["queued_combo"] = false
		if requested and clock >= float(m["draw_second_slash_at"]) and clock < duration:
			var followup: Dictionary = m["stages"][1]
			var hit: Dictionary = followup["hits"][0]
			hit["percent"] = float(draw_count_adjusted_attack(int(hit["percent"]),m["draw_hit_count_bonus"]))
			end_action_fx()
			player["fx_tag"] = "act:%d" % (action_seq+1)
			start_stage(1,float(followup["entry_clock"]))
			return
	var cancel_at := float(stage.get("cancel_at",duration))
	if not native_phase.is_empty():cancel_at = duration
	var pending := String(player["queued_skill"])
	var input_ready := float(player["stuck_ms"]) <= 0.0
	var ordinary_attack := name in Kernel.MoveTable.NORMAL_ATTACK_CHAIN
	var combo_requested := bool(player["queued_combo"])
	if stage.has("combo_at") or name == "weaponcombo":
		# 85F8A7 waits for hitstop and accepts a held command or a buffered input.
		combo_requested = input_ready and (combo_requested or bool(held.get(KEY_X,false)))
	if combo_requested and clock < duration:
		# CB09D1 runs the common X handler before the Swordman skill input check.
		if name == "weaponcombo" and clock >= float(stage.get("continue_at",INF)):
			var chain: Dictionary = player.get("weapon_combo_chain",{})
			# CD4602 supplies the next ordinary attack ordinal to 85F98B.
			var next_normal := int(chain.get("normal_stage",-1))+1
			player["queued_combo"] = false
			if next_normal < Kernel.MoveTable.NORMAL_ATTACK_CHAIN.size() \
					and start_action(Kernel.MoveTable.NORMAL_ATTACK_CHAIN[next_normal],true):return
		elif pending == "weaponcombo" and ordinary_attack and clock >= float(stage.get("combo_at",INF)):
			player["queued_combo"] = false
			if start_action(String(m["next"]),true):return
	if pending == "weaponcombo" and name != pending:
		# CBEB68 consults the current attack's frame gate, not the end of its hitboxes.
		if ordinary_attack and input_ready and clock >= float(stage.get("combo_at",INF)) and clock < duration:
			player["queued_skill"] = ""
			if start_action(pending,true):return
		elif clock >= duration:
			player["queued_skill"] = ""
			end_action()
			start_action(pending)
			return
	if pending != "" and move_def(pending).has("normal_cancel_job") and not normal_attack_cancel_allowed(move_def(pending)):
		# Keep a valid next cast buffered until recovery ends; lack of early
		# cancel permission must not consume and silently lose the request.
		cancel_at = duration
	if clock >= cancel_at and bool(player["queued_jump"]) and name == "upper":
		leave_action()
		player["state"] = "jump"
		player["action"] = ""
		player["vz"] = float(numeric_player.values["jump_power"]) if numeric_player != null else float(table.player["jump_power"])
		player["air_ms"] = 0.0
		player["queued_jump"] = false
		play_sound("jump")
	elif clock >= float(stage.get("continue_at",cancel_at)) and pending == name and m.has("stages") \
		and not m.has("upper_followup_at") and int(player["stage"]) < m["stages"].size()-1 \
		and (name != "weaponcombo" or (input_ready and clock < duration)):
		player["queued_skill"] = ""
		if name == "weaponcombo":
			# CBEDC4 accepts the next stage only after the regular skill payment.
			var cost := skill_mp_cost(m)
			if float(player["mp"]) < cost:
				reject_action(name,"mp")
				return
			player["mp"] = float(player["mp"])-cost
		start_stage(int(player["stage"])+1)
	elif clock >= cancel_at and String(player["queued_skill"]) not in ["",name,"weaponcombo"]:
		var requested: String = player["queued_skill"]
		player["queued_skill"] = ""
		start_action(requested,true)
	elif clock >= float(stage.get("combo_at",cancel_at)) and combo_requested and String(m.get("next","")) != "":
		player["queued_combo"] = false
		if not start_action(String(m["next"]),true) and clock >= duration:end_action()
	elif clock >= duration:
		end_action()

func flow_payload(extra := {}) -> Dictionary:
	var payload := {"run_id":run_id,"room_id":room_id,"room_index":room_index,
		"stats":{"elapsed_ms":elapsed_ms,"time_ms":elapsed_ms,"hit_count":hit_count,"hits":hit_count,"damage_taken":damage_taken},
		"player":{"hp":float(player["hp"]),"mp":float(player["mp"]),"job":job,"weapon":weapon}}
	payload.merge(extra,true)
	return payload

func cue_item_recovery(effect: Dictionary) -> void:
	var key := "item_heal" if float(effect.get("duration_ms",0))>0 else "item_fastheal"
	bus.emit("combat.cue",{"kind":"fx","key":key,"point":Vector2(player["pos"]),"height":float(player["z"]),
		"facing":int(player["facing"]),"follow":PLAYER_ID})

## Effects already validated and paid for by the flow side (e.g. potions). Returns whether it applied.
func apply_effect(effect: Dictionary) -> bool:
	if effect.get("kind")=="restore":
		var applied: bool = preload("res://combat/item_restoration.gd").apply(self,effect)
		if applied:cue_item_recovery(effect)
		return applied
	if String(effect.get("kind","")) in ["effect","remove_effect"]:
		if numeric_player == null or finished:return false
		var body: Dictionary = player
		var actor = numeric_player
		if int(effect.get("target",PLAYER_ID)) != PLAYER_ID:
			actor = null
			for target: Dictionary in monsters+companions:
				if int(target["id"]) == int(effect["target"]):
					body = target
					actor = target.get("numeric")
					break
		if actor == null or float(body["hp"])<=0:return false
		var id := String(effect.get("id",""))
		var applied: bool = actor.add_effect(id,int(effect.get("rank",1)),effect) if effect["kind"]=="effect" else actor.remove_effect(id)
		if applied:
			if actor.effects.controlled():
				if body == player:leave_action()
				body["action"] = ""
				body["state"] = "idle"
			body["hp"] = minf(float(body["hp"]),float(actor.values["hp_max"]))
			if body != player:
				body["max_hp"] = float(actor.values["hp_max"])
				body["attack"] = float(actor.values["physical_attack"])
			if body == player:
				if id == "thirst" and effect["kind"] == "remove_effect":stop_thirst_loop()
				max_hp = float(actor.values["hp_max"])
				max_mp = float(actor.values["mp_max"])
				player["mp"] = minf(float(player["mp"]),max_mp)
			bus.emit("combat.status",{"target":body["id"],"id":id,"change":"added" if effect["kind"]=="effect" else "removed"})
		return applied
	if player.is_empty() or finished or paused:return false
	match String(effect.get("kind","")):
		"heal":
			if float(player["hp"]) >= max_hp:return false
			player["hp"] = minf(max_hp,float(player["hp"])+float(effect.get("amount",0)))
			cue_item_recovery(effect)
			notice("恢复药剂 · HP +%d"%int(effect.get("amount",0)))
			return true
	return false

func set_input_paused(value: bool) -> void:
	paused = value
	held.clear()
	requests.clear()
	if not player.is_empty():
		# Flow pause clears input ownership, including any unhit guard hold.
		player["guard_hold_ms"] = 0.0
		player["recovery_code"] = -1
		player["recovery_buffer_ms"] = 0.0
		run_direction = 0
		last_direction_release.clear()

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
func normal_attack_cancel_allowed(move: Dictionary) -> bool:
	return move.has("normal_cancel_job") and String(player["state"]) == "action" and job == String(move["normal_cancel_job"]) and String(player["action"]) in ["attack1","attack2","attack3","waveeye_attack1","waveeye_attack2","waveeye_attack3"]

func begin_skill_cooldown(name: String, move: Dictionary) -> void:
	var duration := (float(move["cool_ms"])-frenzy_cooldown_reduction_ms(name))/1000.0
	if duration <= 0.0:return
	var rate := float(numeric_player.values["cooldown_rate"]) if numeric_player != null else 1.0
	player["cooldowns"][name] = duration*rate

func skill_mp_cost(move: Dictionary) -> float:
	return float(move["mp"])*(float(numeric_player.values["mp_cost_rate"]) if numeric_player != null else 1.0)

func start_action(name: String, cancel := false) -> bool:
	var m: Dictionary = table.moves.get(name,{})
	if m.is_empty():return reject_action(name,"unknown")
	if player["state"] == "hold":return reject_action(name,"state")
	if name == "triple" and player.has("triple_cast"):return reject_action(name,"state")
	if name == "weaponcombo" and player["state"] not in ["idle","move","action"]:return reject_action(name,"state")
	if numeric_player != null and (numeric_player.effects.controlled() or skill_levels.has(name) and int(skill_levels[name])<=0):return reject_action(name,"unavailable")
	var required_effect := String(m.get("requires_effect",""))
	if required_effect != "" and (numeric_player == null or not numeric_player.effects.active.has(required_effect)):return reject_action(name,"effect")
	var airborne := float(player["z"])>0 or float(player["vz"])>0
	if airborne != bool(m.get("air",false)):return reject_action(name,"state")
	var guard := name == "guard"
	if guard:
		if not guard_input_held():return reject_action(name,"state")
		if player["state"] == "guard":return true
	var backward_hop := String(m.get("movement","")) == "backstep"
	if backward_hop:
		if not backstep_allowed():return reject_action(name,"state")
	elif not cancel and String(player["state"]) in ["hurt","air","down","dead","backstep","action"]:return reject_action(name,"state")
	if m.has("normal_cancel_job"):
		var state := String(player["state"])
		if state not in ["idle","move","guard","action"]:return reject_action(name,"state")
		if state == "action" and float(player["clock"]) < action_duration(String(player["action"])):
			# Original SKL: only Asura may interrupt a normal attack with this skill.
			if not cancel or not normal_attack_cancel_allowed(m):
				return reject_action(name,"state")
	if float(player["cooldowns"].get(name,0))>0:return reject_action(name,"cooldown")
	var normal_index := Kernel.MoveTable.NORMAL_ATTACK_CHAIN.find(name)
	# Preserve both ordinals across a direct attack transition, then clear on recovery or interruption.
	var combo_chain: Dictionary = player.get("weapon_combo_chain",{}) if cancel else {}
	var opening_stage := int(combo_chain.get("skill_stage",-1))+1 if name == "weaponcombo" else 0
	if name == "weaponcombo" and opening_stage >= m["stages"].size():return reject_action(name,"state")
	if m.has("frenzy_disable_after_ms"):
		var frenzy := active_effect("frenzy")
		if not frenzy.is_empty():
			# CC1166 tests the active appendage clock; C9DC0C removes it on skill use.
			if int(frenzy.get("drain_elapsed_ms",0.0)) < int(m["frenzy_disable_after_ms"]):
				return reject_action(name,"frenzy_minimum_duration")
			return apply_effect({"kind":"remove_effect","id":"frenzy","target":PLAYER_ID})
	var hp_cost := 0.0
	if m.has("hp_cost_row"):
		var sample: Dictionary = table._skill_row(String(m.get("skill","")))
		var row: Array = sample.get("level_row",[])
		var column := int(m["hp_cost_row"])
		if column >= 0 and column < row.size():hp_cost = float(row[column])
	if m.get("native_state","") == "thirst":
		if player["state"] not in ["idle","move"]:return reject_action(name,"state")
		# CBA626..CBA6C3 rejects HP equal to the initial charge cost.
		hp_cost = thirst_hp_cost(int(m["hp_percent"]))
		if int(player["hp"]) <= int(hp_cost):return reject_action(name,"hp")
	elif name == "buff":
		# CC0F72 compares integer HP against the rank cost plus one.
		if int(player["hp"]) <= int(hp_cost)+1:return reject_action(name,"hp")
	elif hp_cost > 0 and float(player["hp"]) <= hp_cost:return reject_action(name,"hp")
	var mp_cost := skill_mp_cost(m)
	var pay_mp_with_hp := name == "rage_slash" and int(skill_levels.get("bloody_vigorous",0)) > 0
	if pay_mp_with_hp:
		if float(player["hp"]) <= mp_cost:return reject_action(name,"hp")
	elif float(player["mp"]) < mp_cost:return reject_action(name,"mp")
	if m.has("material_cost"):
		var cost: Dictionary = m["material_cost"]
		# CBBD13 -> 863552/8635C1 handles the item before requesting state 13.
		if not skill_material_spender.is_valid() or not skill_material_spender.call(int(cost["source_id"]),int(cost["amount"])):
			return reject_action(name,"material")
	if pay_mp_with_hp:
		player["hp"] = float(player["hp"])-mp_cost
	else:
		player["mp"] = float(player["mp"])-mp_cost
	if m.get("native_state","") == "thirst":
		player["hp"] = int(player["hp"])-int(hp_cost)
	elif hp_cost > 0:player["hp"] = float(player["hp"])-hp_cost
	if name != "triple":begin_skill_cooldown(name,m)
	if backward_hop:
		start_backstep()
		return true
	leave_action()
	if normal_index >= 0 or name == "weaponcombo":
		player["weapon_combo_chain"] = combo_chain
		if normal_index >= 0:combo_chain["normal_stage"] = normal_index
	if name == "air_attack":player["air_attack_used"] = true
	player["state"] = "guard" if guard else "action"
	player["action"] = "" if guard else name
	# A live profile refresh can rebuild the table between two stages.
	if name == "triple":player["triple_cast"] = m
	if name == "weaponcombo":player["weapon_combo_cast"] = m
	if m.has("draw_second_slash_at") or m.has("draw_charge"):player["draw_cast"] = m.duplicate(true)
	if m.has("draw_charge"):player["draw_charge"] = {"elapsed_ms":0.0,"fx_clock":0.0}
	player["native_phase"] = {}
	player["queued_combo"] = false
	player["queued_skill"] = ""
	player["queued_jump"] = false
	player["queued_backstep"] = false
	if guard:
		player["clock"] = 0.0
		player["guard_hold_ms"] = float(m["guard_min_hold_ms"])
		player["guard_recoil_ms"] = 0.0
		play_guard_entry()
		action_seq += 1
		bus.emit("combat.action_started",{"entity_id":PLAYER_ID,"action":name,"instance":action_seq})
		return true
	if String(m.get("effect_id","")) != "" and m.get("native_state","") != "thirst":
		player["stage"] = 0
		player["clock"] = 0.0
		player["hits"] = {}
		action_seq += 1
		bus.emit("combat.action_started",{"entity_id":PLAYER_ID,"action":name,"instance":action_seq})
		var cast_fx := String(m["cast_fx"])
		if name == "buff":
			# 858FA6 scales the cast duration with integer thousandths.
			var cast_rate := float(numeric_player.values["cast_speed"]) if numeric_player != null else 1.0
			var speed := maxi(1,int(cast_rate*1000.0))
			var duration := int(float(m["cast_ms"])*1000.0/speed)
			player["frenzy_cast"] = {"elapsed_ms":0.0,"duration_ms":duration,"speed":speed}
			var frames: Array = combat_assets.get("effects",{}).get(cast_fx,{}).get("frames",[])
			# CD750C overwrites each delay with floor(floor(duration * speed / 1000) / frames).
			var delay := int(float(int(duration*speed/1000.0))/maxi(1,frames.size()))
			attach_frenzy_fx(cast_fx,delay)
			play_sound("SM_FLENSE")
			play_sound("FLENSE_GET")
		elif name == "overdrive":
			start_overdrive_cast(m)
		else:
			if cast_fx != "":spawn_effect(cast_fx,player["pos"],int(player["facing"]),float(player["z"]))
			apply_skill_effect(name,String(m["effect_id"]))
		return true
	player["fx_tag"] = "act:%d" % (action_seq+1)
	if m.has("hardattack_charge"):
		var charge: Dictionary = m["hardattack_charge"].duplicate()
		var speed := float(numeric_player.values["attack_speed"]) if numeric_player != null else 1.0
		charge["release_clock"] = float(m["timeline"][1]["start_ms"])
		charge["warmup_ms"] = int(float(charge["release_clock"])/maxf(speed,0.001))
		charge["elapsed_ms"] = 0.0
		player["hardattack_charge"] = charge
	start_stage(opening_stage)
	match name:
		"epidemicrasa":apply_effect({"kind":"effect","id":"epidemic_aura","rank":int(skill_levels.get(name,1))})
	return true

func attach_frenzy_fx(key: String, delay := -1) -> void:
	player["fx_tag"] = "act:%d" % action_seq
	bus.emit("combat.cue",{"kind":"fx","key":key,"point":player["pos"],"height":player["z"],
		"facing":player["facing"],"tag":player["fx_tag"],"follow":PLAYER_ID,
		"action_clock_at":0.0,"action_instance":action_seq,"uniform_frame_ms":delay})

func thirst_hp_cost(percent: int) -> int:
	return int(int(max_hp)*percent/100.0)

func step_thirst_cast(ms: float) -> void:
	var phase: Dictionary = player["native_phase"]
	var move := move_def("sacrifice")
	var elapsed := float(player["clock"])+ms
	player["clock"] = elapsed
	var body_clock := float(phase["body_clock"])+ms*float(phase["cast_stage_rate"])
	var first_frame := float(phase["frame_one_ms"])
	var failed_payment := false
	var held_skill := skill_input_held("sacrifice")
	if body_clock >= first_frame and held_skill:
		# CB2BE5 checks the current tier before resetting the ended body ANI.
		var tier := clampi(int((elapsed+200.0-first_frame)/500.0),0,int(phase["max_tier"]))
		phase["tier"] = tier
		var bit := 1 << tier
		if tier > 0 and (int(phase["paid_mask"]) & bit) == 0:
			phase["paid_mask"] = int(phase["paid_mask"]) | bit
			var hp_cost := thirst_hp_cost(int(move["tier_hp_percent"]))
			failed_payment = int(player["hp"]) <= hp_cost
			if not failed_payment:player["hp"] = int(player["hp"])-hp_cost
	if failed_payment or elapsed >= float(phase["end_ms"]) or (not held_skill and body_clock >= first_frame and elapsed >= 400.0):
		# CABAA4 tests tier + 1 against floor(casting time / 500).
		if int(phase["tier"])+1 > int(float(phase["end_ms"])/500.0) and move.has("full_charge_hit"):
			spawn_object(move["full_charge_hit"],"player",Vector2(Vector2i(player["pos"])),
				float(int(player["z"])),int(player["facing"]),attack_power())
		end_action_fx()
		player["fx_tag"] = "act:%d" % (action_seq+1)
		start_stage(1)
		if apply_effect({"kind":"effect","id":move["effect_id"],"rank":int(skill_levels.get("sacrifice",1)),
				"charge_tier":phase["tier"]}):
			play_sound("SACRI")
			# CABE6E clears slot 26 before starting the new SACRI_LOOP voice.
			stop_thirst_loop()
			player["thirst_loop"] = true
			bus.emit("combat.cue",{"kind":"sound","key":"SACRI_LOOP","loop_id":PLAYER_ID})
		return
	phase["body_clock"] = 0.0 if body_clock >= float(phase["thirst_loop_ms"]) else body_clock

func stop_thirst_loop() -> void:
	if player.erase("thirst_loop"):
		bus.emit("combat.cue",{"kind":"sound","stop":true,"loop_id":PLAYER_ID})

func start_overdrive_cast(move: Dictionary) -> void:
	var authored_ms := float(action_def()["duration"])
	var cast_speed := float(numeric_player.values["cast_speed"]) if numeric_player != null else 1.0
	# State 17 sets the body speed using the authored animation length and the SKL cast time.
	var ratio := ActorNumbers.native_scalar(authored_ms/float(move["cast_ms"]))
	var speed := maxi(1,int(ActorNumbers.native_scalar(int(cast_speed*1000.0)*ratio)))
	var rate := ActorNumbers.native_scalar(speed*100.0*ActorNumbers.native_scalar(0.001))
	var start_fx: Dictionary = combat_assets["effects"]["self_buff_start"]
	player["overdrive_cast"] = {"elapsed_ms":0.0,"rate":rate,
		"end_ms":overdrive_ani_end(authored_ms,rate),
		"loop_ms":overdrive_ani_end(float(start_fx["duration_ms"]),rate)}
	attach_overdrive_cast_fx("self_buff_start",0.0,false)
	play_sound("MOON_CURTAIN_LIGHT")
	play_sound("SM_OVERDRIVE")

func overdrive_ani_end(duration: float, percent: float) -> int:
	# 108E4A0 truncates the scaled animation length; 108E515 requires elapsed > length.
	return int(ActorNumbers.native_scalar(duration*100.0/percent))+1

func attach_overdrive_cast_fx(key: String, clock_at: float, loop: bool) -> void:
	player["fx_tag"] = "act:%d" % action_seq
	# State 17 attaches above the standing body height (100 for the source base skin), plus 30.
	bus.emit("combat.cue",{"kind":"fx","key":key,"point":player["pos"],"height":player["z"],
		"facing":player["facing"],"tag":player["fx_tag"],"follow":PLAYER_ID,"offset_y":-130,
		"action_clock_at":clock_at,"action_instance":action_seq,"loop":loop})

func step_overdrive_cast(ms: float) -> void:
	var cast: Dictionary = player["overdrive_cast"]
	var previous := float(cast["elapsed_ms"])
	var elapsed := previous+ms
	cast["elapsed_ms"] = elapsed
	var rate := float(cast["rate"])/100.0
	player["clock"] = elapsed*rate
	if elapsed >= float(cast["end_ms"]):
		# State 17 calls the skill attachment only on its successful exit to idle.
		var pending := String(player["queued_skill"])
		end_action()
		if apply_effect({"kind":"effect","id":"overdrive","rank":int(skill_levels.get("overdrive",1))}):
			notice(String(move_def("overdrive").get("label","")))
			play_sound("BUFF_OVERDRIVE")
		if pending != "" and pending != "overdrive":start_action(pending)
	elif previous < float(cast["loop_ms"]) and elapsed >= float(cast["loop_ms"]):
		end_action_fx()
		attach_overdrive_cast_fx("self_buff_loop",float(cast["loop_ms"])*rate,true)

func step_frenzy_cast(ms: float) -> void:
	var cast: Dictionary = player["frenzy_cast"]
	var elapsed := float(cast["elapsed_ms"])+ms
	cast["elapsed_ms"] = elapsed
	player["clock"] = elapsed*float(cast["speed"])/1000.0
	if int(elapsed)<int(cast["duration_ms"]):return
	if int(player["stage"])==0:
		# State 13 switches to the shoot motion and attaches Frenzy at CD75E9.
		var move := move_def("buff")
		end_action_fx()
		player["stage"] = 1
		player["clock"] = 0.0
		cast["elapsed_ms"] = 0.0
		cast["duration_ms"] = int(float(move["frenzy_recovery_ms"])*1000.0/float(cast["speed"]))
		attach_frenzy_fx(String(move["release_fx"]))
		apply_skill_effect("buff",String(move["effect_id"]))
		play_sound("FLENSE_CHARGE")
		return
	var pending := String(player["queued_skill"])
	player["queued_skill"] = ""
	if pending!="" and pending!="buff" and start_action(pending,true):return
	end_action()

func start_stage(index: int, opening_clock := 0.0) -> void:
	var name: String = player["action"]
	if name == "weaponcombo":player["weapon_combo_chain"]["skill_stage"] = index
	player["stage"] = index
	player["clock"] = opening_clock
	player["hits"] = {}
	player.erase("queued_upper_followup")
	player.erase("action_slide")
	action_seq += 1
	var m := move_def(name)
	player["native_phase"] = {}
	if m.get("native_state","") in ["normalwave","wave_cast"]:
		var attack_rate := float(numeric_player.values["attack_speed"]) if numeric_player != null else 1.0
		var cast_rate := float(numeric_player.values["cast_speed"]) if numeric_player != null else 1.0
		player["native_phase"] = Kernel.NativeWave.plan(m,attack_rate,cast_rate)
	elif m.get("native_state","") == "ghost_cast":
		var cast_rate := float(numeric_player.values["cast_speed"]) if numeric_player != null else 1.0
		var cast_speed := maxi(1,roundi(cast_rate*1000.0))
		var release_at := int(float(m["cast_ms"])*1000.0/cast_speed)
		# Phase 1 sets mode 0 at 8591E3. The 1000 rate then preserves static[0].
		player["native_phase"] = {"wait_ms":release_at,"charge_rate":cast_speed/1000.0,
			"end_ms":release_at+float(m["native_recovery_ms"])}
	elif m.get("native_state","") == "bloodblast":
		# State 13 selects throw slot 1. Mode 3 uses the non-weapon attack speed.
		# The local numeric model has one attack-speed channel.
		var rate := float(numeric_player.values["attack_speed"]) if numeric_player != null else 1.0
		var speed := maxi(1,roundi(rate*1000.0))
		var base_ms := float(m["cast_ms"] if index == 0 else m["native_recovery_ms"])
		player["native_phase"] = {"cast_stage_rate":speed/1000.0,"end_ms":int(base_ms*1000.0/speed)}
	elif m.get("native_state","") == "thirst":
		var rate := float(numeric_player.values["cast_speed"]) if numeric_player != null else 1.0
		var speed := maxi(1,int(rate*1000.0))
		if index == 0:
			# 858F6D keeps the charge timer unscaled for skill 23.
			var stage := action_def()
			player["native_phase"] = {"cast_stage_rate":speed/1000.0,"end_ms":float(m["cast_ms"]),
				"thirst_loop_ms":float(stage["duration"]),"body_clock":0.0,
				"frame_one_ms":float(stage["timeline"][1]["start_ms"]),
				"max_tier":mini(10,int(float(m["cast_ms"])/500.0)),"tier":0,"paid_mask":0}
		else:
			player["native_phase"] = {"cast_stage_rate":speed/1000.0,
				"end_ms":int(float(m["native_recovery_ms"])*1000.0/speed)}
	if name == "triple":
		var attack_rate := float(numeric_player.values["attack_speed"]) if numeric_player != null else 1.0
		if numeric_player == null and float(player["buff_ms"]) > 0.0:
			attack_rate = float(rules["buff"]["attack_speed"])
		# CC7C56 requests attack speed for Triple Slash movement.
		begin_action_slide(m["dash"],attack_rate)
	# Multi-stage slides can pick their own side. These native follow-ups inherit facing.
	if m.has("stages") and not (name in ["upper","bloodblast","sacrifice","draw"] and index == 1) \
			and not (name == "draw" and opening_clock > 0.0) and not player.has("weapon_combo_release"):
		var turn := int(bool(held.get(KEY_RIGHT,false)))-int(bool(held.get(KEY_LEFT,false)))
		if turn != 0:player["facing"] = turn
	bus.emit("combat.action_started",{"entity_id":PLAYER_ID,"action":name,"stage":index,"instance":action_seq})
	if name == "sacrifice" and index == 0:
		bus.emit("combat.cue",{"kind":"fx","key":m["cast_fx"],"point":player["pos"],"height":player["z"],
			"facing":player["facing"],"tag":player["fx_tag"],"follow":PLAYER_ID,"loop":true})
	if player.has("hardattack_charge"):
		bus.emit("combat.cue",{"kind":"sound","key":"SM_GUE_CHARGE","voice_tag":"hardattack_charge"})
		return
	var stage := action_def()
	if String(stage.get("voice","")) != "":play_sound(String(stage["voice"]))
	if name == "triple":play_sound("R_TSLASH")
	var swing := int(stage.get("swing",m.get("swing",-1)))
	if swing >= 0:
		var wav: Array = table.weapon_wav(weapon)
		if swing < wav.size() and String(wav[swing]) != "":play_sound(String(wav[swing]))
	if index == 1 and m.has("weapon_combo_charge") and not player.has("weapon_combo_release"):
		begin_weapon_combo_charge(m["weapon_combo_charge"])
		return
	var event_clock := action_event_clock(opening_clock)
	action_cues(stage,-1.0,event_clock)
	apply_player_hits(stage,-1.0,event_clock)

func step_draw_charge(ms: float) -> void:
	var config: Dictionary = move_def("draw")["draw_charge"]
	var charge: Dictionary = player["draw_charge"]
	var minimum := int(config["minimum_ms"])
	var maximum := int(config["maximum_ms"])
	var old := float(charge["elapsed_ms"])
	var elapsed := old+ms
	charge["elapsed_ms"] = elapsed
	var rate := float(numeric_player.values["attack_speed"]) if numeric_player != null else 1.0
	charge["fx_clock"] += maxf(0.0,elapsed-maxf(old,minimum))*rate
	if old < minimum and elapsed >= minimum:
		# CB23A1/CB23B0 attach the two charge clips while the body remains frozen.
		var layers: Array = config["effects"]
		for depth in layers.size():
			bus.emit("combat.cue",{"kind":"fx","key":layers[depth],"point":player["pos"],"height":float(player["z"]),
				"facing":player["facing"],"tag":player["fx_tag"],"follow":PLAYER_ID,"depth_offset":depth,
				"action_clock_at":0.0,"action_instance":action_seq})
	# CBA2A8 is strict for a released key. A held key waits for the maximum.
	if int(elapsed) < maximum and (int(elapsed) <= minimum or skill_input_held("draw")):return
	var hit: Dictionary = action_def()["hits"][0]
	var base := float(hit["percent"])
	var ratio := Kernel.NativeMotion.f32(float(config["peak_percent"])*Kernel.NativeMotion.f32(0.01))
	var peak := int(base*ratio-100.0)
	var spent := clampi(int(elapsed)-minimum,0,maximum-minimum)
	# CC842D interpolates the two stored ATK bonuses in single precision.
	hit["percent"] = int(Kernel.NativeMotion.ramp(base-100.0,peak,spent,maximum-minimum))+100
	player.erase("draw_charge")
	player["queued_skill"] = ""
	end_action_fx()
	player["fx_tag"] = "act:%d" % (action_seq+1)
	start_stage(0,float(config["release_clock"]))

func begin_weapon_combo_charge(config: Dictionary) -> void:
	var charge := config.duplicate()
	charge["elapsed_ms"] = 0.0
	player["weapon_combo_charge"] = charge
	var key := "weapon_combo_heavy_charge"
	var frames: Array = combat_assets["effects"][key]["frames"]
	var rate := float(numeric_player.values["attack_speed"]) if numeric_player != null else 1.0
	# CD492A divides the hold duration by the number of FX frames before attaching.
	var delay := int(float(config["duration_ms"])/frames.size())
	bus.emit("combat.cue",{"kind":"fx","key":key,"point":player["pos"],"height":float(player["z"]),
		"facing":player["facing"],"tag":player["fx_tag"],"follow":PLAYER_ID,"fresh":true,
		"offset_x":-52.0,"offset_y":-70.0,"depth_offset":1,"uniform_frame_ms":delay/maxf(rate,0.001)})

func step_weapon_combo_charge(ms: float) -> void:
	var charge: Dictionary = player["weapon_combo_charge"]
	var duration := int(charge["duration_ms"])
	var elapsed := float(charge["elapsed_ms"])+ms
	charge["elapsed_ms"] = elapsed
	if int(elapsed) < duration and skill_input_held("weaponcombo"):return
	# CBEFF7 re-enters state 8, same stage, with elapsed time and no new payment.
	var release := action_def().duplicate(true)
	var spent := mini(int(elapsed),duration)
	for hit: Dictionary in release["hits"]:
		var base := float(hit["percent"])
		var scaled := Kernel.NativeMotion.f32(base*float(charge["peak_percent"]))
		var maximum := int(Kernel.NativeMotion.f32(scaled*Kernel.NativeMotion.f32(0.01)))
		hit["percent"] = int(Kernel.NativeMotion.ramp(base,maximum,spent,duration))
	player.erase("weapon_combo_charge")
	player["weapon_combo_release"] = release
	player["queued_skill"] = ""
	end_action_fx()
	player["fx_tag"] = "act:%d" % (action_seq+1)
	start_stage(1)

func end_hardattack_charge() -> void:
	if player.erase("hardattack_charge"):
		bus.emit("combat.cue",{"kind":"sound","stop":true,"voice_tag":"hardattack_charge"})

func step_hardattack_charge(ms: float) -> void:
	var charge: Dictionary = player["hardattack_charge"]
	var elapsed := float(charge["elapsed_ms"])
	var warmup := int(charge["warmup_ms"])
	var duration := int(charge["duration_ms"])
	# CB9CBD sends max(0, state time - frame 1 start) on release.
	if not skill_input_held("hardattack"):
		var spent := clampi(int(elapsed)-warmup,0,duration)
		var bonus := int(float(charge["bonus_percent"])*spent/duration)
		var release := action_def().duplicate(true)
		if charge.get("full",false):release["hardattack_followup"] = charge["followup"]
		for hit: Dictionary in release["hits"]:
			hit["percent"] = int(float(hit["percent"])*(100+bonus)/100.0)
		# CB1A52 emits the release cue once when the body reaches frame 3.
		release["sounds"].append({"key":"GHOSTSLASH_CRY","at":float(release["timeline"][3]["start_ms"])})
		player["hardattack_release"] = release
		end_hardattack_charge()
		end_action_fx()
		player["fx_tag"] = "act:%d" % (action_seq+1)
		player["queued_skill"] = ""
		start_stage(0,float(charge["release_clock"]))
		return
	var next := elapsed+ms
	charge["elapsed_ms"] = next
	if not charge.get("holding_fx",false) and next >= warmup:
		charge["holding_fx"] = true
		for key: String in ["hardattack_charge1","hardattack_charge2"]:
			bus.emit("combat.cue",{"kind":"fx","key":key,"point":Vector2(player["pos"]),"height":float(player["z"]),
				"facing":int(player["facing"]),"tag":String(player["fx_tag"]),"follow":PLAYER_ID,"loop":true,"fresh":true})
	if not charge.get("full",false) and next >= warmup+duration:
		charge["full"] = true
		end_action_fx()
		for key: String in ["hardattack_full2","hardattack_full1"]:
			bus.emit("combat.cue",{"kind":"fx","key":key,"point":Vector2(player["pos"]),"height":float(player["z"]),
				"facing":int(player["facing"]),"fresh":true})
		play_sound("GHOSTSLASH_CHARGE_END")

func begin_action_slide(config: Dictionary, rate: float) -> void:
	# 827F20 scales velocity and truncates acceleration. 8A7210 uses integer ms.
	var motion_rate := int(rate*1000.0)/1000.0
	var velocity := float(config["speed"])*motion_rate
	var acceleration := int(float(config["accel"])*motion_rate)
	var stop := int(-velocity*1000.0/acceleration)/1000.0 if acceleration < 0 else INF
	player["action_slide"] = {"speed":velocity,"accel":acceleration,"stop_s":stop,"elapsed_ms":0.0}

func start_hardattack_followup(stage: Dictionary) -> void:
	end_action_fx()
	player["hardattack_release"] = stage
	player["fx_tag"] = "act:%d" % (action_seq+1)
	player["queued_skill"] = ""
	start_stage(1)
	var facing := int(player["facing"])
	var direction := int(held.get(KEY_RIGHT,false))-int(held.get(KEY_LEFT,false))
	# CC68D9 zeros the movement when holding the opposite direction.
	# CC6940 uses the fixed movement rate and attack speed for the ANI.
	if direction != -facing:begin_action_slide(stage["slide"],1.0)
	bus.emit("combat.cue",{"kind":"fx","key":"hardattack_dash_dust","point":Vector2(player["pos"]).round(),
		"height":0.0,"facing":facing,"fresh":true})
	var wave: Dictionary = stage["waves"][player["hardattack_ghost"]]
	play_sound(wave["voice"])
	spawn_object(wave["hit"],"player",player["pos"],float(player["z"]),facing,attack_power(),{},wave["definition"])
	# Native packet initialization attaches the modifier to the caster.
	if wave.has("caster_buff") and numeric_player != null and numeric_player.apply_khazan_drive(wave["caster_buff"]):
		bus.emit("combat.status",{"target":PLAYER_ID,"id":"khazan_drive","change":"added"})

func apply_skill_effect(skill_id: String, effect_id: String) -> void:
	if numeric_player != null:
		if apply_effect({"kind":"effect","id":effect_id,"rank":int(skill_levels.get(skill_id,1))}):
			player["buff_ms"] = float(numeric_player.effects.active[effect_id]["remaining_ms"])
			notice(String(move_def(skill_id).get("label","")))
		return
	player["buff_ms"] = float(rules["buff"]["duration_ms"])
	notice(String(move_def(skill_id).get("label",""))+" · 攻击与移动加速")

## Timed effect/sound cues of the move plus the ANI's own frame sound events.
## Move effects are tagged with the running action and capped at the time it has left.
func action_cues(stage: Dictionary, old_t: float, new_t: float) -> void:
	for fx: Dictionary in stage.get("fx",[]):
		var at := float(fx["at"])
		if at > old_t and at <= new_t:
			var left := action_duration(String(player["action"]))-at
			var synchronized := bool(fx.get("action_clock",false))
			bus.emit("combat.cue",{"kind":"fx","key":String(fx["key"]),"point":Vector2(player["pos"]),"height":float(player["z"]),
				"facing":int(player["facing"]),"tag":String(player["fx_tag"]),"follow":PLAYER_ID,"max_ms":-1.0 if synchronized else maxf(left,1.0),
				"action_clock_at":at if synchronized else -1.0,"action_instance":action_seq,"offset_x":float(fx.get("offset_x",0)),
				"offset_y":float(fx.get("offset_y",0)),"scale":float(fx.get("scale",1.0)),
				"depth_offset":int(fx.get("depth_offset",4))})
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
			if at > old_t and at <= new_t:
				if hit.get("skill_id","") == "bloodblast" and numeric_player != null:
					hit = prepare_bloodblast_damage(hit)
				if hit.get("native_controller",{}).get("kind","") == "draw_short_wave":
					# CB2171 passes absolute Z 50 and the caster's integer ground point.
					spawn_object(prepare_draw_short_wave(hit),"player",Vector2(Vector2i(player["pos"])),0.0,facing,attack_power())
				else:
					spawn_object(hit,"player",player["pos"],float(player["z"]),facing,attack_power())
			continue
		# The original actor ledger survives all layers and frames until a new ATK is installed.
		var attached: bool = hit.get("source","") == "attached_weapon"
		var sample_from := new_t if attached else old_t
		for s: int in hit["segments"].size():
			var boxes: Array = Kernel.Timeline.segment_boxes(hit["segments"][s],sample_from,new_t)
			if boxes.is_empty():continue
			var group: int = 0 if attached else s
			var world: Array = Kernel.HitJudge.world_boxes(boxes,anchor,facing)
			for enemy: Dictionary in monsters:
				var id := "%d:%d:%d"%[i,group,int(enemy["id"])]
				if player["hits"].has(id) or float(enemy["hp"])<=0:continue
				var c: Dictionary = Kernel.HitJudge.contact(world,enemy_damage_boxes(enemy))
				if c.is_empty():continue
				player["hits"][id] = true
				land_hit(player,enemy,hit,c["point"],facing,attack_power())
			if native_maze != null:
				apply_native_prop_hits(world,hit,attack_power(),player["hits"],"prop:%d:%d:"%[i,group])
				continue
			for p in props.size():
				var prop: Dictionary = props[p]
				if not prop.get("breakable",false) or prop.get("broken",false):continue
				for b: AABB in world:
					if b.intersects(Kernel.HitJudge.prop_box(prop["collision"])):
						prop["hp"] = int(prop.get("hp", 1)) - 1
						if int(prop["hp"]) > 0:
							spawn_effect("hit_cut_s1", prop["pos"] - Vector2(0, 18), facing)
							if String(prop.get("hit_sound", "")) != "":play_sound(String(prop["hit_sound"]))
						else:
							prop["broken"] = true
							prop["broken_ms"] = 0.0
							spawn_effect("hit_cut_s1", prop["pos"] - Vector2(0, 18), facing)
							# 原版破坏粒子（.obj 的 [destroy particle] → .ptl → ANI）。
							for particle in array_of(prop.get("particles")):
								spawn_effect(String(particle), prop["pos"] - Vector2(0, 16), facing)
							if String(prop.get("break_sound", "")) != "":play_sound(String(prop["break_sound"]))
							bus.emit("combat.prop_broken", {"node": int(prop.get("node", -1))})
						break

func draw_count_adjusted_attack(amount: int, rates: Array) -> int:
	# C9F980 adjusts the attack with the first slash's distinct target count.
	var count := int(player.get("draw_contact_count",0))
	if count == 0:return amount
	return int(float(amount*(1000+int(rates[mini(count,rates.size())-1])))/1000.0)

func prepare_draw_short_wave(template: Dictionary) -> Dictionary:
	var controller: Dictionary = template["native_controller"]
	var amount := draw_count_adjusted_attack(int(controller["base_amount"]),controller["hit_count_bonus"])
	var hit := template.duplicate()
	var atk: Dictionary = template["atk"].duplicate()
	atk["absolute_damage"] = amount
	hit["atk"] = atk
	hit["fixed_amount"] = amount
	return hit

func prepare_bloodblast_damage(template: Dictionary) -> Dictionary:
	# 75EB80 takes dungeon column 1 by owner level. Use the current model's
	# independent-attack addend alongside that base for ordinary dungeons.
	var level := int(numeric_player.values["level"])
	var table_values: Array = move_def("bloodblast")["fixed_attack_base"]
	var equipment_addend := int(numeric_player.values["independent_attack"])-int(Numbers.shared_config()["base"]["independent_attack"])
	var base := int(table_values[level-1])+equipment_addend if level > 0 and level < table_values.size() else 0
	# 90A866..90A897 rounds each SSE operation separately, then truncates.
	var ratio := ActorNumbers.native_scalar(float(template["fixed"])-100.0)
	ratio = ActorNumbers.native_scalar(ratio*ActorNumbers.NATIVE_PERCENT)
	ratio = ActorNumbers.native_scalar(1.0+ratio)
	var product := ActorNumbers.native_scalar(ratio*ActorNumbers.native_scalar(base))
	var amount := int(product)
	var bleeding_amount := amount
	var thirst_active := not active_effect("thirst").is_empty()
	if thirst_active:
		# CD80C1/CD82CB multiply the float before the first integer conversion.
		var rank := int(skill_levels.get("sacrifice",1))
		var row: Array = Numbers.Skills.sample(Numbers.record("sacrifice"),rank)["level_row"]
		var bonus := ActorNumbers.native_scalar(float(row[4])*ActorNumbers.native_scalar(0.001))
		bleeding_amount = int(ActorNumbers.native_scalar(product*ActorNumbers.native_scalar(1.0+bonus)))
	if not active_effect("frenzy").is_empty():
		# CD80D3/CD82D9 apply C9D200 to the integer returned by 90A950.
		var rank := int(skill_levels.get("buff",1))
		var row: Array = Numbers.Skills.sample(Numbers.record("buff"),rank)["level_row"]
		amount = int(float(amount*(100+int(row[11])))/100.0)
		bleeding_amount = int(float(bleeding_amount*(100+int(row[11])))/100.0)
	var hit := template.duplicate()
	var atk: Dictionary = template["atk"].duplicate()
	atk["absolute_damage"] = amount
	hit["atk"] = atk
	hit["fixed_amount"] = amount
	if thirst_active:hit["fixed_amount_bleeding"] = bleeding_amount
	return hit

func native_attack_has_damage(atk: Dictionary) -> bool:
	# 293C11E checks the weapon flag, positive damage or positive absolute damage.
	return int(atk.get("weapon_damage_apply",0)) != 0 or float(atk.get("damage",0)) > 0.0 \
		or float(atk.get("absolute_damage",0)) > 0.0

func apply_native_prop_hits(world: Array, hit: Dictionary, power: float, seen: Dictionary, prefix: String) -> void:
	if not native_attack_has_damage(hit.get("atk",{})):return
	for prop: Dictionary in props:
		if not prop.has("native_breakable") or prop["broken"] or prop.has("jar_warning"):continue
		var key := prefix+str(prop["node"])
		if seen.has(key) or Kernel.HitJudge.contact(world,prop["damage_boxes"]).is_empty():continue
		seen[key] = true
		var source: Dictionary = prop["native_breakable"]
		# A36A20 dispatches the contact sound before the incoming damage callback.
		if not String(source["hit_sound"]).is_empty():play_sound(String(source["hit_sound"]))
		var context := hit.duplicate()
		context["percent"] = float(hit["percent"])*skill_damage_multiplier(String(hit.get("skill_id",player["action"])))
		var resolved: Dictionary
		if numeric_player != null:
			if String(context.get("element","none")) not in ["fire","water","light","dark"]:context["element"] = numeric_player.effective_element()
			# Adapt the project's damage result to the passive object's damage receiver.
			resolved = Numbers.Damage.resolve(numeric_player.values,{},context,[rng.next_float(),rng.next_float()],Numbers.shared_config()["formula"])
		else:
			resolved = {"amount":maxi(0,roundi(power*float(context["percent"])/100.0+float(context.get("fixed",0)))),
				"critical":false,"category":String(context.get("damage_type","physical"))}
		var amount := int(resolved["amount"])
		if amount <= 0:continue
		var pos: Vector2 = prop["pos"]
		var height := float(prop["z"])
		var destroyed := NativeBreakable.apply_damage(prop,amount)
		bus.emit("combat.damage",{"target":prop["id"],"amount":amount,"critical":resolved["critical"],
			"category":resolved["category"],"victim":"prop","reaction":"none","point":Vector3(pos.x,pos.y,height)})
		if not destroyed:continue
		if native_jar_traps.break_pot(self,prop):continue
		var items: Array = prop.get("box_items",[])
		if not items.is_empty():
			bus.emit("combat.prop_loot_released",{"run_id":run_id,"room_id":room_id,
				"node":prop["node"],"position":pos,"items":items.duplicate()})
		for child: Dictionary in prop.get("pot_monsters",[]):
			var entry := child.duplicate()
			entry["launch"] = NativePotMonsters.launch(rng,child["force_ground"],height)
			entry["facing"] = int(prop["facing"])
			spawn_enemy(pos,false,table.monster_by_mob(child["mob"]),entry)
			if not entry["launch"].is_empty() and child["mob"] == NativePotMonsters.MOBS[250]:play_sound("ZGM_SPRING")
		complete_native_prop_break(prop)

func complete_native_prop_break(prop: Dictionary) -> void:
	prop["broken"] = true
	var source: Dictionary = prop["native_breakable"]
	var offset: Array = source["particle_offset"]
	bus.emit("combat.cue",{"kind":"native_particle","path":source["destroy_particle"],
		"point":Vector2(prop["pos"])+Vector2(float(offset[0]),float(offset[1])),"height":float(prop["z"])+float(offset[2])})
	if not String(source["destroy_sound"]).is_empty():play_sound(String(source["destroy_sound"]))
	bus.emit("combat.prop_broken",{"node":prop["node"]})

## One landed hit, attacker -> target. Damage, reaction, local hitstop, events and cues.
func land_hit(attacker: Dictionary, target: Dictionary, hit: Dictionary, point: Vector3, facing: int, power: float) -> void:
	var atk: Dictionary = hit["atk"]
	var starfish_grab := bool(hit.get("starfish_grab",false))
	var by_player := int(attacker.get("id",-1)) == PLAYER_ID
	var by_companion := attacker.has("companion_id")
	var victim := victim_kind(target)
	if victim != "monster" and (by_player or by_companion):return
	if victim == "player" and native_jar_traps.player_protected:return
	var hit_skill_id := String(hit.get("skill_id",player["action"]))
	var percent := float(hit["percent"])*(1.0 if by_companion else skill_damage_multiplier(hit_skill_id))
	var contact_only := bool(hit.get("contact_only",false))
	var amount := 0 if contact_only else Kernel.Reaction.damage(power*(float(rules["buff"]["damage"]) if by_player and float(player["buff_ms"])>0 else 1.0),percent)
	var resolved := {"critical":false,"category":hit.get("damage_type","physical") if contact_only else "physical","missed":false}
	if numeric_player != null and not contact_only:
		var source_stats: Dictionary = numeric_player.values if by_player else attacker.get("numeric").values if attacker.get("numeric") != null else {"physical_attack":power,"magical_attack":power,"level":numeric_monster_level}
		var target_stats: Dictionary = numeric_player.values if int(target["id"])==PLAYER_ID else target["numeric"].values
		if target["state"] == NativeZealotSummons.CAST_STATE:
			target_stats = target_stats.duplicate()
			target_stats["physical_defense"] = float(target_stats["physical_defense"])*NativeZealotSummons.CAST_DEFENSE_FACTOR
			target_stats["magical_defense"] = float(target_stats["magical_defense"])*NativeZealotSummons.CAST_DEFENSE_FACTOR
		var context := hit.duplicate(true)
		context["percent"] = percent
		if context.has("fixed_amount_bleeding") and target["numeric"].effects.active.has("bleed"):
			context["fixed_amount"] = context["fixed_amount_bleeding"]
		if by_player and String(context.get("element","none")) not in ["fire","water","light","dark"]:context["element"] = numeric_player.effective_element()
		context["counter"] = String(target["state"]) in ["attack","action"]
		context["back"] = int(target["facing"])==facing
		resolved = Numbers.Damage.resolve(source_stats,target_stats,context,[rng.next_float(),rng.next_float()],Numbers.shared_config()["formula"])
		last_damage = resolved.duplicate(true)
		amount = int(resolved["amount"])
		if amount <= 0 and (not starfish_grab or bool(resolved["missed"]) or bool(target_stats.get("immune",false))):
			bus.emit("combat.damage",{"target":target["id"],"amount":0,"critical":false,"category":resolved["category"],"missed":resolved["missed"],"victim":victim,"reaction":"none","point":point})
			return
	elif by_companion:
		amount = maxi(1,roundi(amount*float(attacker["numeric"].values["damage_rate"])))
	if by_player and player["action"] == "draw" and int(player["stage"]) == 0 and hit_skill_id == "draw" and hit.get("kind","") == "boxes":
		# CADA24..CADADD records each direct hit target once for the follow-ups.
		player["draw_contact_count"] = int(player.get("draw_contact_count",0))+1
	var target_is_player := victim == "player"
	bus.emit("combat.hit",{"attacker":attacker.get("id",-1),"target":target["id"],"instance":int(attacker.get("action_instance",action_seq)),"point":point,"guarded":false,"atk":String(hit.get("atk_path",""))})
	if starfish_grab:
		start_starfish_capture(attacker)
		return
	var reaction := "none"
	if target_is_player:
		var before_hp := float(player["hp"])
		reaction = hurt_player(amount,attacker,atk,facing,point.z)
		if reaction == "blocked":return
		amount = roundi(before_hp-float(player["hp"]))
		if numeric_player != null and not contact_only:last_damage["trace"]["actual_amount"] = amount
	else:
		var ground_hit_fx: Array = hit.get("native_controller",{}).get("ground_hit_fx",[])
		if not ground_hit_fx.is_empty() and not contact_only and int(target["z"]) == 0:
			# A61738 checks the target height before the local reaction changes it.
			# A6191F/A619EE place both draw-only objects at the original ground point.
			var ground := Vector2(Vector2i(target["pos"]))
			for index in ground_hit_fx.size():
				bus.emit("combat.cue",{"kind":"fx","key":ground_hit_fx[index],
					"point":ground,"height":0.0,"facing":1,"fresh":true,
					"depth_offset":1-int(ground.y) if index==0 else 0})
		target["hp"] = maxf(0,float(target["hp"])-amount)
		# The native hit callback removes sleep only after 200 elapsed ms.
		if not contact_only and target.has("numeric") and int(target["numeric"].sleep_age())>200:
			target["numeric"].remove_effect("sleep")
			if target["state"]=="down":target["down_ms"] = float(rules["reaction"]["down_hold_ms"])
			bus.emit("combat.status",{"target":target["id"],"id":"sleep","change":"removed"})
		var recovery := float(target["numeric"].values["hit_recovery"]) if target.has("numeric") else float(target["def"]["hit_recovery"])
		if target["state"] == NativeZealotSummons.CAST_STATE:recovery += NativeZealotSummons.CAST_RECOVERY_ADD
		reaction = Kernel.Reaction.apply(target,atk,facing,rules["reaction"],recovery,float(hit.get("lift",-1)))
		target["clock"] = 0.0
		target["flash_ms"] = 65.0
		if victim == "monster" and by_player:
			combo_count += 1
			combo_ms = float(rules["combo_window_ms"])
			hit_count += 1
			if by_player:bar_target = int(target["id"])
		if by_companion:
			attacker["attack_success"] = true
			var source_id = attacker["skills"].find_key(hit_skill_id)
			attacker["last_attack"] = -1 if source_id == null else int(source_id)
	var stop := float(rules["hitstop"]["down_ms"] if reaction in ["launch","down","air"] else rules["hitstop"]["hit_ms"])
	# Thrown and spawned objects freeze only their target; the caster keeps moving.
	if String(hit.get("kind","")) != "object" and not hit.has("object"):
		attacker["stuck_ms"] = maxf(float(attacker.get("stuck_ms",0)),stop)
	target["stuck_ms"] = maxf(float(target.get("stuck_ms",0)),stop)
	if hit.has("native_contact"):spawn_attack_contact(attacker,target,hit["native_contact"],facing,power)
	var damage_event := {"target":target["id"],"amount":amount,"critical":resolved["critical"],"category":resolved["category"],
		"victim":victim,"reaction":reaction,"show_number":not contact_only,
		"point":Vector3(Vector2(target["pos"]).x,Vector2(target["pos"]).y,float(target["z"]))}
	if by_player and victim=="monster" and amount>0 and numeric_player!=null:
		var wear_units := int(numeric_player.weapon_wear_units(int(skill_levels.get("durabilityup",0))))
		if wear_units!=Numbers.WEAR_UNITS_PER_HIT:damage_event["weapon_wear_units"] = wear_units
	bus.emit("combat.damage",damage_event)
	hit_cues(atk,point,facing,by_player)
	if numeric_player != null and not target_is_player and float(target["hp"])>0:
		var effect_list: Array = hit.get("effects",[]).duplicate(true)
		if by_player:
			effect_list.append_array(Numbers.shared_config()["skills"].get(hit_skill_id,{}).get("on_hit",[]))
			if hit_skill_id == "hopsmash" and int(skill_levels.get("bloody_vigorous",0)) > 0:
				effect_list.append({"id":"bleed","chance":0.4})
		for effect: Dictionary in effect_list:
			if effect.get("native_frenzy",false) or effect.has("source_bleed_total"):
				if target["numeric"].apply_source_bleed(effect,rng.range_int(0,ActorNumbers.STATUS_ROLL_SIZE-1)):
					bus.emit("combat.status",{"target":target["id"],"id":"bleed","change":"added"})
				continue
			var chance := float(effect.get("chance",1))
			if effect.get("id","") == "bleed" and hit_skill_id in ["rage_slash","hopsmash"] and int(skill_levels.get("bloody_vigorous",0)) > 0:
				chance = minf(1.0,chance+0.4)
			var duration_ms := float(effect.get("duration_ms",0))
			if effect.get("id","") == "sleep":
				if target["numeric"].apply_source_sleep(effect,rng.range_int(0,ActorNumbers.STATUS_ROLL_SIZE-1)):
					play_sound("CONDITION_SLEEP")
					bus.emit("combat.status",{"target":target["id"],"id":"sleep","change":"added"})
				continue
			if effect.get("id","") == "freeze" and effect.has_all(["chance","status_level","duration_ms"]):
				var roll: int = rng.range_int(0,ActorNumbers.STATUS_ROLL_SIZE-1)
				duration_ms = float(target["numeric"].source_freeze_duration(chance,int(effect["status_level"]),int(duration_ms),roll))
				if duration_ms <= 0.0:continue
			elif not rng.chance(chance):continue
			var ranks: Dictionary = attacker["ranks"] if by_companion else skill_levels
			var request := {"kind":"effect","id":effect["id"],"target":target["id"],"rank":int(ranks.get(hit_skill_id,1))}
			if effect.has("duration_ms"):request["duration_ms"] = duration_ms
			if effect.has("status_level"):request["status_level"] = effect["status_level"]
			apply_effect(request)
		if by_player and bool(resolved.get("critical",false)) and int(skill_levels.get("defensedownoncritical",0)) > 0:
			apply_effect({"kind":"effect","id":"defense_down","target":target["id"],"rank":int(skill_levels["defensedownoncritical"])})
	if victim == "companion":
		play_sound("hurt")
		if float(target["hp"]) <= 0:
			target["state"] = "dead"
			target["death_ms"] = 0.0
			report_companion_defeat(target)
	elif victim == "monster":
		# 按怪物种类播受击/死亡音（bake_dnf_monster_sounds.py 生成 mon_<key>_<event>）；
		# 该类怪没有独立音效时退回通用的哥布林音，避免完全无声。
		var mob_key := String(target["def"].get("key", ""))
		play_sound("mon_%s_hit" % mob_key)
		if float(target["hp"])<=0:
			target["state"] = "dead"
			target["death_ms"] = 0.0
			if by_player and not contact_only and native_attack_has_damage(atk):
				frenzy_recovery.record_kill(self,target)
			play_sound("mon_%s_die" % mob_key)
			# 死亡爆散：原版 [die effect] 的编号语义未解（E-OPEN），这里用通用 blow 特效补足死亡反馈。
			bus.emit("combat.cue", {"kind":"fx", "key":"hit_blow_l", "point":Vector2(target["pos"]),
				"height":float(target["z"]), "facing":int(target["facing"]), "scale":1.0})
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

func victim_kind(actor: Dictionary) -> String:
	if int(actor.get("id",-1)) == PLAYER_ID:return "player"
	return "companion" if actor.has("companion_id") else "monster"

func friendly_targets() -> Array:
	var targets: Array = [player] if float(player["hp"]) > 0 else []
	for companion: Dictionary in companions:
		if float(companion["hp"]) > 0:targets.append(companion)
	return targets

func nearest_living(point: Vector2, actors: Array) -> Dictionary:
	var nearest: Dictionary = {}
	var distance := INF
	for actor: Dictionary in actors:
		if float(actor["hp"]) <= 0:continue
		var next := CompanionProgram.target_distance(point,actor["pos"])
		if next >= distance:continue
		distance = next
		nearest = actor
	return nearest

func friendly_damage_boxes(target: Dictionary) -> Array:
	if int(target["id"]) == PLAYER_ID:return player_damage_boxes()
	var ani := companion_ani(target)
	var frame: Dictionary = Kernel.Timeline.frame_at(table.player_timeline(String(ani[0])),float(ani[1]),String(ani[0]) in ["stay","move","dash"])
	return Kernel.HitJudge.world_boxes(frame.get("damage_boxes",[]),Kernel.HitJudge.anchor(target["pos"],float(target["z"])),int(target["facing"]))

func update_enemy(enemy: Dictionary, ms: float) -> void:
	var m: Dictionary = enemy["def"]
	var summon_poll: bool = m.has("native_spirit_summon") and NativeZealotSummons.poll_due(enemy,ms)
	if enemy.has("starfish_capture") and (enemy["state"] != "attack" or float(enemy["hp"]) <= 0.0):
		release_starfish_victim(enemy)
	var native_selection: Dictionary = m.get("native_attack_selection",{})
	if not native_selection.is_empty():
		enemy["native_attack_elapsed_ms"] = float(enemy.get("native_attack_elapsed_ms",0))+ms
	if enemy.has("numeric") and float(enemy["hp"])>0:
		step_numeric_actor(enemy,enemy["numeric"],ms)
		if enemy["numeric"].effects.controlled():
			if enemy.has("starfish_capture"):
				release_starfish_victim(enemy)
				enemy.erase("starfish_bite_phase")
				if enemy["state"] == "attack":
					finish_enemy_attack(enemy,m["moves"][int(enemy["move_index"])])
			var sleeping: bool = enemy["numeric"].effects.active.has("sleep")
			# Enum 8 waits out the incoming hit/air reaction, then holds STATE_DOWN.
			if sleeping and enemy["state"] not in ["air","hurt","down","dead"]:
				enemy["state"] = "down"
				enemy["down_ms"] = 0.0
			Kernel.Reaction.step_body(enemy,ms,float(rules["reaction"]["monster_gravity"]),rules["reaction"],move_in_world,sleeping)
			return
	enemy["flash_ms"] = maxf(0,float(enemy["flash_ms"])-ms)
	if float(enemy["stuck_ms"]) > 0:
		enemy["stuck_ms"] = maxf(0,float(enemy["stuck_ms"])-ms)
		return
	var dt := ms/1000
	enemy["cooldown_ms"] = maxf(0,float(enemy["cooldown_ms"])-ms)
	# 每招独立冷却（原版 [is the skill in cooltime() N] 是按招算的）。
	# 注意：GDScript 里遍历 Dictionary 时不能直接改它（迭代器会失效），先取 keys。
	var skill_cd: Dictionary = enemy.get("skill_cd", {})
	if not skill_cd.is_empty():
		for skill in skill_cd.keys():
			skill_cd[skill] = maxf(0.0, float(skill_cd[skill]) - ms)
	var state: String = enemy["state"]
	var advance := ms
	if state == NativeZealotSummons.CAST_STATE:
		advance *= float(enemy["native_cast_rate"])
	elif state == "attack" and enemy.get("starfish_bite_phase","") != "release":
		var rate := float(enemy["numeric"].values["attack_speed"]) if enemy.has("numeric") else float(m.get("native_attack_rate",1.0))
		advance *= float(enemy.get("rasa_previous_attack_rate",rate))
	if not bool(enemy["chief"]) and enemy.has("numeric") and float(enemy["hp"]) > 0.0:
		# 82A2DB lazily starts a per-actor timer. A due poll changes the rate
		# for subsequent animation time and starts the next interval from now.
		var remaining := float(enemy.get("attack_rate_refresh_ms",ENEMY_ATTACK_RATE_REFRESH_MS+ms))-ms
		if remaining <= 0.0:
			enemy.erase("rasa_previous_attack_rate")
			remaining = ENEMY_ATTACK_RATE_REFRESH_MS
		enemy["attack_rate_refresh_ms"] = remaining
	enemy["clock"] = float(enemy["clock"])+advance
	if float(enemy["hp"])<=0:
		enemy["state"] = "dead"
		enemy["death_ms"] = float(enemy["death_ms"])+ms
	elif state == "native_suicide":
		step_native_suicide(enemy,m["native_suicide"],ms)
	elif state == NativeZealotSummons.CAST_STATE:
		native_zealot_summons.finish_cast(self,enemy)
	elif state == "native_summon_jump":
		step_native_summon_jump(enemy,dt)
		return
	elif state == "attack":
		var bite: Dictionary = m.get("native_starfish_bite",{})
		if not bite.is_empty() and int(enemy.get("move_index",-1)) == int(bite["move_index"]):
			step_starfish_bite(enemy,bite,advance,dt)
			return
		var jump: Dictionary = m.get("native_starfish_jump",{})
		if not jump.is_empty() and int(enemy.get("move_index",-1)) == int(jump["move_index"]):
			step_starfish_jump(enemy,jump,advance,dt)
			return
		enemy_attack(enemy,advance)
	elif state in ["idle","move"] and enemy.get("ai",true):
		var blind: bool = enemy.has("numeric") and enemy["numeric"].effects.active.has("blind")
		var target := player
		if not companions.is_empty():
			var candidates := friendly_targets()
			if m.has("native_target_profile"):
				var eligible := candidates.filter(func(actor):return Kernel.MonsterAI.target_visible(enemy,m,actor["pos"],blind))
				if not eligible.is_empty():candidates = eligible
			target = nearest_living(enemy["pos"],candidates)
		if target.is_empty():return
		var intent: Dictionary = Kernel.MonsterAI.think(enemy,m,target["pos"],float(target["z"]),blind)
		var summon_candidate := summon_poll and NativeZealotSummons.choose(self,enemy,bool(intent["visible"]) and float(target["hp"]) > 0.0)
		if not native_selection.is_empty() and (not blind or bool(intent["visible"])):
			var slot := poll_native_enemy_attack(enemy,native_selection)
			intent["attack"] = slot >= 0
			intent["move_index"] = int(m.get("native_move_indices",{}).get(slot,slot))
			if slot >= 0:intent["face"] = enemy["facing"]
		enemy["facing"] = int(intent["face"])
		if intent["attack"]:
			# D19850 configures ANI mode 2 and reads its current rate on entry.
			enemy.erase("rasa_previous_attack_rate")
			enemy["state"] = "attack"
			enemy["clock"] = 0.0
			enemy["hits"] = {}
			enemy["thrown"] = false
			enemy["move_index"] = int(intent.get("move_index", -1))
			if m.has("native_starfish_jump"):
				enemy.erase("starfish_phase")
				enemy.erase("starfish_bite_phase")
				enemy.erase("native_jump_velocity")
				enemy.erase("native_jump_gravity")
		elif summon_candidate:
			NativeZealotSummons.start(self,enemy)
			return
		elif state == "idle" and m.has("native_suicide") and start_native_suicide(enemy,m["native_suicide"]):
			return
		elif Vector2(intent["move"]).length_squared() > 0:
			var dir: Vector2 = intent["move"]
			enemy["pos"] = move_in_world(enemy["pos"],Vector2(dir.x,dir.y*float(rules["units"]["depth_speed_ratio"]))*float(m["speed"])*dt*(float(enemy["numeric"].values["move_speed"]) if enemy.has("numeric") else 1.0))
			if state != "move":enemy["clock"] = 0.0
			enemy["state"] = "move"
		else:
			enemy["state"] = "idle"
	var gravity := float(rules["reaction"]["monster_gravity"])
	var hover := float(m.get("native_hover_height",0.0))
	if hover > 0.0 and enemy["state"] in ["idle","move","attack"]:
		enemy["z"] = hover
		enemy["vz"] = 0.0
		gravity = 0.0
	Kernel.Reaction.step_body(enemy,ms,gravity,rules["reaction"],move_in_world)

func start_native_suicide(enemy: Dictionary, suicide: Dictionary) -> bool:
	for path: String in suicide["spawn"]["mobs"]:
		if table.monster_by_mob(path) == "":return false
	var chance: Array = suicide["chance"]
	if rng.range_int(0,0x7fffffff)%int(chance[1]) >= int(chance[0]):return false
	enemy["state"] = "native_suicide"
	enemy["clock"] = 0.0
	return true

func step_native_suicide(enemy: Dictionary, suicide: Dictionary, ms: float) -> void:
	var age := float(enemy["clock"])
	var sound_at := float(suicide["sound_at"])
	if age-ms < sound_at and age >= sound_at:play_sound(suicide["sound"])
	if age < float(suicide["end_at"]):return
	enemy["hp"] = 0.0
	enemy["state"] = "dead"
	enemy["death_ms"] = 0.0
	var spec: Dictionary = suicide["spawn"]
	var count := int(spec["count_min"])+rng.range_int(0,0x7fffffff)%int(spec["count_span"])
	var origin := Vector2(Vector2i(enemy["pos"]))
	var height := float(int(enemy["z"])+int(spec["offset_z"]))
	for _index in count:
		# 2689630 sends these independent draws in packet order, Y before X.
		var vx := native_spawn_roll(spec["launch_x"])
		var vy := native_spawn_roll(spec["launch_y"])
		var x_sign := 1 if rng.range_int(0,0x7fffffff)%2 == 0 else -1
		var y_sign := 1 if rng.range_int(0,0x7fffffff)%2 == 0 else -1
		var rise := native_spawn_roll(spec["launch_height"])
		var offset_y := native_spawn_roll(spec["offset_y"])
		var offset_x := native_spawn_roll(spec["offset_x"])
		var path := String(spec["mobs"][rng.range_int(0,0x7fffffff)%spec["mobs"].size()])
		var child := spawn_enemy(origin+Vector2(offset_x,offset_y),false,table.monster_by_mob(path))
		child["facing"] = x_sign
		start_native_flight(child,height,Vector2(vx*x_sign,vy*y_sign),rise,float(spec["ground_gravity"]))
		play_sound(spec["sound"])

func start_native_flight(enemy: Dictionary, height: float, velocity: Vector2, rise: int, gravity: float) -> void:
	enemy["z"] = height
	enemy["vz"] = sqrt(absf(2.0*gravity*rise))
	enemy["state"] = "native_summon_jump"
	enemy["native_jump_velocity"] = velocity
	enemy["native_jump_gravity"] = gravity

func native_spawn_roll(bounds: Array) -> int:
	return int(bounds[0])+rng.range_int(0,0x7fffffff)%(int(bounds[1])-int(bounds[0])+1)

func step_native_summon_jump(enemy: Dictionary, dt: float) -> void:
	if advance_native_flight(enemy,dt):
		enemy["state"] = "idle"
		enemy["clock"] = 0.0

func advance_native_flight(enemy: Dictionary, dt: float) -> bool:
	var velocity: Vector2 = enemy["native_jump_velocity"]
	var gravity := float(enemy["native_jump_gravity"])
	var vz := float(enemy["vz"])
	enemy["pos"] = move_in_world(enemy["pos"],velocity*dt)
	enemy["z"] = maxf(0.0,float(enemy["z"])+(vz+0.5*gravity*dt)*dt)
	enemy["vz"] = vz+gravity*dt
	var landed := float(enemy["z"]) == 0.0 and float(enemy["vz"]) <= 0.0
	if landed:
		enemy["vz"] = 0.0
		enemy.erase("native_jump_velocity")
		enemy.erase("native_jump_gravity")
	return landed

func step_starfish_jump(enemy: Dictionary, jump: Dictionary, animation_ms: float, dt: float) -> void:
	var phase := String(enemy.get("starfish_phase","start"))
	var age := float(enemy["clock"])
	var landed := false
	if enemy.has("native_jump_velocity"):
		landed = advance_native_flight(enemy,dt)
	elif phase == "start" and age >= float(jump["launch_at"]):
		# DB52A5 starts the mover after the native launch frame becomes current.
		var gravity := float(jump["gravity"])
		enemy["native_jump_gravity"] = gravity
		enemy["native_jump_velocity"] = Vector2(float(jump["forward_speed"])*int(enemy["facing"]),0)
		enemy["vz"] = sqrt(absf(2.0*gravity*float(jump["jump_height"])))
	var z := int(enemy["z"])
	var vz := float(enemy["vz"])
	if phase != "end" and (landed or (vz < 0.0 and z < int(jump["end_below_z"]))):
		enemy["starfish_phase"] = "end"
		enemy["clock"] = 0.0
		return
	if phase == "start" and vz > 0.0 and z > int(jump["roll_above_z"]):
		enemy["starfish_phase"] = "rolling"
		enemy["clock"] = 0.0
		play_sound(jump["sound"])
		resolve_enemy_melee(enemy,jump["rolling_segments"],jump["rolling_hit"],-1.0,0.0)
	elif phase == "rolling":
		var cycle := Kernel.Timeline.duration(jump["rolling_timeline"])
		var from := fposmod(maxf(0.0,age-animation_ms),cycle)
		resolve_enemy_melee(enemy,jump["rolling_segments"],jump["rolling_hit"],from,from+animation_ms)
	elif phase == "end" and age >= Kernel.Timeline.duration(jump["end_timeline"]):
		enemy.erase("starfish_phase")
		finish_enemy_attack(enemy,enemy["def"]["moves"][int(jump["move_index"])])

func step_starfish_bite(enemy: Dictionary, bite: Dictionary, animation_ms: float, dt: float) -> void:
	var phase := String(enemy.get("starfish_bite_phase","attempt"))
	var age := float(enemy["clock"])
	var move: Dictionary = enemy["def"]["moves"][int(bite["move_index"])]
	if phase == "attempt":
		if enemy.has("native_jump_velocity"):
			if advance_native_flight(enemy,dt):
				# DB3DB1 seeks beyond the hold frame after the mover lands.
				finish_enemy_attack(enemy,move)
				return
		elif age >= float(bite["launch_at"]):
			launch_starfish_bite(enemy,bite,float(bite["forward_speed"]),float(bite["jump_height"]))
		try_starfish_contact(enemy,move,bite["attempt_hit"],age-animation_ms,age)
	elif phase == "bite":
		if not enemy.has("starfish_capture") or float(player["hp"]) <= 0.0:
			start_starfish_release(enemy,bite)
			return
		if player["state"] != "hold":
			# DB700C queues HOLD after the grab entry.
			hold_starfish_victim()
			return
		anchor_starfish_to_player(enemy,bite)
		if age >= float(bite["bite_duration"]):
			var at: Vector2 = player["pos"]
			land_hit(enemy,player,bite["hit"],Vector3(at.x,at.y,float(player["z"])),int(enemy["facing"]),float(enemy["attack"]))
			play_sound("ZGM_ATTACK")
			play_sound(bite["attach_sound"])
			enemy["starfish_bites_left"] = int(enemy["starfish_bites_left"])-1
			if int(enemy["starfish_bites_left"]) <= 0 or float(player["hp"]) <= 0.0:
				start_starfish_release(enemy,bite)
			else:
				enemy["clock"] = 0.0
	elif enemy.has("native_jump_velocity"):
		if advance_native_flight(enemy,dt):enemy["clock"] = float(bite["release_landed_at"])
	elif age >= float(bite["release_duration"]):
		enemy.erase("starfish_bite_phase")
		finish_enemy_attack(enemy,move)

func launch_starfish_bite(enemy: Dictionary, bite: Dictionary, speed: float, height: float) -> void:
	var gravity := float(bite["gravity"])
	enemy["native_jump_gravity"] = gravity
	enemy["native_jump_velocity"] = Vector2(speed*int(enemy["facing"]),0)
	enemy["vz"] = sqrt(absf(2.0*gravity*height))

func try_starfish_contact(enemy: Dictionary, move: Dictionary, hit: Dictionary, from: float, to: float) -> void:
	if enemy["hits"].has(PLAYER_ID) or player.has("starfish_holder") or float(player["hp"]) <= 0.0:
		return
	if god_mode or target_invulnerable(player):
		return
	if numeric_player != null and (numeric_player.effects.active.has("freeze") or numeric_player.effects.active.has("stone")):
		return
	for segment: Dictionary in move["segments"]:
		var boxes := Kernel.Timeline.segment_boxes(segment,from,to)
		if boxes.is_empty():continue
		var world := Kernel.HitJudge.world_boxes(boxes,Kernel.HitJudge.anchor(enemy["pos"],float(enemy["z"])),int(enemy["facing"]))
		var contact := Kernel.HitJudge.contact(world,player_damage_boxes())
		if contact.is_empty():continue
		enemy["hits"][PLAYER_ID] = true
		land_hit(enemy,player,hit,contact["point"],int(enemy["facing"]),float(enemy["attack"]))
		return

func start_starfish_capture(enemy: Dictionary) -> void:
	var bite: Dictionary = enemy["def"]["native_starfish_bite"]
	enemy["starfish_bite_phase"] = "bite"
	enemy["clock"] = 0.0
	enemy["vz"] = 0.0
	enemy.erase("native_jump_velocity")
	enemy.erase("native_jump_gravity")
	player["facing"] = -int(enemy["facing"])
	# DB661F keeps a grounded target. An airborne contact goes through release.
	if roundi(float(player["z"])) > 0:return
	var limits: Array = bite["level_range"]
	var counts: Array = bite["count_range"]
	var level := int(enemy["numeric"].values["level"]) if enemy.has("numeric") else numeric_monster_level
	var fraction := clampf(inverse_lerp(float(limits[0]),float(limits[1]),float(level)),0.0,1.0)
	enemy["starfish_bites_left"] = int(lerpf(float(counts[0]),float(counts[1]),fraction))
	enemy["starfish_capture"] = Vector3(Vector2(player["pos"]).x,Vector2(player["pos"]).y,float(player["z"]))
	player["starfish_holder"] = enemy["id"]
	anchor_starfish_to_player(enemy,bite)
	play_sound("ZGM_ATTACK")
	play_sound("HOLD")

func hold_starfish_victim() -> void:
	end_action()
	player["state"] = "hold"
	run_direction = 0
	player["queued_combo"] = false
	player["queued_skill"] = ""
	player["queued_jump"] = false
	player["queued_backstep"] = false
	player["recovery_code"] = -1
	player["recovery_buffer_ms"] = 0.0
	player["push_ms"] = 0.0
	player["vz"] = 0.0

func anchor_starfish_to_player(enemy: Dictionary, bite: Dictionary) -> void:
	# DB4D42 uses the victim's rounded position and the original Swordman offsets.
	var at: Vector2 = player["pos"]
	var offset: Array = bite["swordman_anchor"]
	enemy["pos"] = at.round()+Vector2(-int(enemy["facing"])*float(offset[0]),float(offset[1]))
	enemy["z"] = roundf(float(player["z"]))+float(offset[2])
	if player["state"] == "hold":player["pos"] = Vector2(at.x,Vector2(enemy["pos"]).y-1.0)
	player["facing"] = -int(enemy["facing"])

func start_starfish_release(enemy: Dictionary, bite: Dictionary) -> void:
	if enemy.has("starfish_capture"):release_starfish_victim(enemy)
	enemy["starfish_bite_phase"] = "release"
	enemy["clock"] = 0.0
	launch_starfish_bite(enemy,bite,-float(bite["release_speed"]),float(bite["release_height"]))

func release_starfish_victim(enemy: Dictionary) -> void:
	var saved: Vector3 = enemy["starfish_capture"]
	enemy.erase("starfish_capture")
	if player.get("starfish_holder",-1) != enemy["id"]:return
	player.erase("starfish_holder")
	if float(player["hp"]) <= 0.0:return
	player["pos"] = constrain_pos(Vector2(saved.x,saved.y))
	player["z"] = saved.z
	# DB62E8 sends DOWN with push/lift 200/200. 82C95D samples X before Z.
	var weight := float(table.player["weight"])
	var gravity := -float(enemy["def"]["native_starfish_bite"]["gravity"])
	var impulse := float(int(200.0*4000.0/(2100.0+0.0121*(weight-10000.0))))
	var speed := sample_starfish_down(float(int(impulse*0.5)),0.8,1.2)
	var height := sample_starfish_down(float(int(impulse*impulse/(2.0*gravity))),0.9,1.1)
	player["push_v"] = -int(player["facing"])*speed
	player["push_ms"] = float(rules["reaction"]["push_decay_ms"])
	player["vz"] = sqrt(2.0*gravity*height)
	player["starfish_fall_gravity"] = gravity
	player["state"] = "air"
	player["bounced"] = false

func sample_starfish_down(base: float, lower: float, upper: float) -> int:
	var low := int(base*lower)
	var high := int(base*upper)
	var roll := rng.range_int(0,0x7fffffff)%1000
	return int(float(high-low)*float(roll)/999.0+float(low))

func poll_native_enemy_attack(enemy: Dictionary, policy: Dictionary) -> int:
	var width: Array = table.player["width"]
	var targets: Array = []
	for target: Dictionary in friendly_targets():
		if float(target.get("invuln_ms",0)) > 0.0:continue
		targets.append({"position":Vector2i(target["pos"]),"size":Vector2i(width[0],width[1]),
			"down":target["state"] == "down"})
	var result := Kernel.MonsterAI.native_attack_poll(
		{"position":Vector2i(enemy["pos"]),"facing":enemy["facing"],
			"elapsed_ms":int(enemy["native_attack_elapsed_ms"]),"next_attack_ms":enemy.get("native_attack_next_ms",0)},
		policy,targets,func() -> int:return rng.range_int(0,0x7fffffff))
	enemy["native_attack_next_ms"] = result["next_attack_ms"]
	return int(result["slot"])

func enemy_attack(enemy: Dictionary, ms: float) -> void:
	var m: Dictionary = enemy["def"]
	var old_t := float(enemy["clock"])-ms
	var t := float(enemy["clock"])
	# 这一刀用哪一招：BOSS 多招时由 AI 按距离选中（move_index），单招怪退回默认。
	var move: Dictionary = {}
	var moves: Array = m.get("moves", [])
	var pick := int(enemy.get("move_index", -1))
	if pick >= 0 and pick < moves.size():move = moves[pick]
	var move_timeline: Array = move.get("timeline", m.get("attack_timeline", []))
	var move_segments: Array = move.get("segments", m.get("attack_segments", []))
	var move_atk: Dictionary = move.get("atk", m.get("atk", {}))
	var move_atk_path := String(move.get("atk_path", ""))
	var contact: Dictionary = m.get("attack_contacts",{}).get(maxi(pick,0),{})
	var emission: Dictionary = move.get("emission",{})
	if not emission.is_empty():
		if not enemy["thrown"] and t >= float(emission["at"]):
			enemy["thrown"] = true
			spawn_object(emission["hit"],"monster",enemy["pos"],float(enemy["z"]),int(enemy["facing"]),
				float(enemy["attack"]),enemy)
			play_sound(String(emission["sound"]))
	elif m.has("throw"):
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
		var hit := {"atk":move_atk,"atk_path":move_atk_path,
			"percent":100.0+float(move_atk.get("damage_bonus",0)),"lift":-1.0}
		if m.get("native_spirit",false):
			hit["damage_type"] = "magical"
			hit["element"] = "dark" if Kernel.MoveTable.enum_value(move_atk,"element","") == "[dark element]" else "light"
			hit["skill_id"] = ""
		if not contact.is_empty():
			hit["native_contact"] = contact
			hit["atk_path"] = contact["atk_path"]
			hit["skill_id"] = ""
		resolve_enemy_melee(enemy,move_segments,hit,old_t,t)
	if t >= Kernel.Timeline.duration(move_timeline):
		finish_enemy_attack(enemy,move)

func resolve_enemy_melee(enemy: Dictionary, segments: Array, hit: Dictionary, old_t: float, t: float) -> void:
	var targets := friendly_targets()
	for s in segments.size():
		var boxes := Kernel.Timeline.segment_boxes(segments[s],old_t,t)
		if boxes.is_empty():continue
		var world := Kernel.HitJudge.world_boxes(boxes,Kernel.HitJudge.anchor(enemy["pos"],float(enemy["z"])),int(enemy["facing"]))
		for target: Dictionary in targets:
			var key := Vector2i(s,int(target["id"]))
			if enemy["hits"].has(key) or float(target["hp"]) <= 0:continue
			var contact := Kernel.HitJudge.contact(world,friendly_damage_boxes(target))
			if contact.is_empty():continue
			enemy["hits"][key] = true
			land_hit(enemy,target,hit,contact["point"],int(enemy["facing"]),float(enemy["attack"]))

func finish_enemy_attack(enemy: Dictionary, move: Dictionary) -> void:
	enemy["state"] = "idle"
	enemy["clock"] = 0.0
	var delay := float(enemy["def"]["attack_delay"])
	enemy["cooldown_ms"] = delay
	var used := int(enemy.get("move_index", -1))
	if used >= 0:
		var cds: Dictionary = enemy.get("skill_cd", {})
		cds[used] = float(move.get("cool_ms",delay))
		enemy["skill_cd"] = cds

func spawn_attack_contact(attacker: Dictionary, target: Dictionary, contact: Dictionary, facing: int, power: float) -> void:
	# 7EF650 tests a bit mask against the original player, APC and MOB class flags.
	var actor_class := 0x211
	if int(target["id"]) == PLAYER_ID:actor_class = 0x11
	elif target.has("companion_id"):actor_class = 0x111
	var target_class := int(contact["target_class"])
	if (actor_class & target_class) != target_class:return
	if rng.range_int(0,99) >= int(contact["chance_percent"]):return
	# DBBB83 serializes the victim's integer world X and Y, with zero height.
	spawn_object(contact["hit"],"monster",Vector2(Vector2i(target["pos"])),0.0,facing,power,attacker)

## Player takes a monster hit. Returns the reaction kind, or "blocked" if nothing applied.
func target_invulnerable(target: Dictionary) -> bool:
	return float(target.get("invuln_ms",0.0)) > 0.0 or (int(target["id"]) == PLAYER_ID and native_jar_traps.player_protected)

func attack_body_armor() -> bool:
	if player["state"] != "action":return false
	var stage := action_def()
	var upper := String(player["action"]) == "upper" and int(player["stage"]) == 0
	if not upper and stage.get("ani","") != "weaponcomboheavy2":return false
	# CD42F3 installs an override for the first two frames. After CB0E2E
	# clears it, 7F13F0 still reads the current ANI's own body state.
	var frame := Kernel.Timeline.frame_at(stage["timeline"],action_ani_clock(float(player["clock"])))
	return not frame.is_empty() and ((upper and int(frame["frame"]) <= 1) or int(frame["items"].get("13",0)) == 1)

func play_guard_entry() -> void:
	play_sound("SWD_GUARD")
	play_sound("SM_GUARD")

func hurt_player(amount: int, source: Dictionary, atk: Dictionary, facing: int, impact_height := 46.0) -> String:
	if god_mode or target_invulnerable(player) or finished:return "blocked"
	var state := String(player["state"])
	var was_action := state == "action"
	var body_armor := attack_body_armor()
	var front_hit := (Vector2(source["pos"]).x-Vector2(player["pos"]).x)*int(player["facing"])>=0
	var manual_guard := state == "guard" and front_hit
	var guard_rank := int(skill_levels.get("guard",0))
	var auto_rank := int(skill_levels.get("autoguard",0))
	var auto_guard := false
	var grounded := float(player["z"]) == 0.0 and float(player["vz"]) <= 0.0
	if not manual_guard and not body_armor and amount > 0 and guard_rank > 0 and auto_rank > 0 and grounded \
			and state not in ["air","down","dead","hold"] and not active_effect("autoguard").is_empty() \
			and not numeric_player.effects.controlled():
		# CA9346..CA9484 resolves both current ranks and compares the original percentage on a 10000-point roll.
		var row: Array = Numbers.Skills.sample(Numbers.record("autoguard"),auto_rank)["level_row"]
		auto_guard = not row.is_empty() and rng.range_int(0,9999) < int(row[0])*100
	if auto_guard:
		# CA9503..CA9614 transitions to guard recoil and turns toward a rear hit.
		end_action()
		player["state"] = "guard"
		if not front_hit:player["facing"] = -int(player["facing"])
		if state != "guard":play_guard_entry()
		player["queued_combo"] = false
		player["queued_skill"] = ""
		player["queued_jump"] = false
		player["queued_backstep"] = false
	var guarded := manual_guard or auto_guard
	var taken := float(amount)
	if guarded:
		var row: Array = Numbers.Skills.sample(Numbers.record("guard"),maxi(1,guard_rank))["level_row"]
		# Original ATK +30 resets to physical when the source omits attack type.
		var attack_type := Kernel.MoveTable.enum_value(atk,"attack_type","[physic]")
		taken *= float(Numbers.Skills.guard_taken_percent(row,attack_type))/100.0
		if amount > 0 and row.size() > 1:
			# CC6135 clears the initial hold gate on re-entry.
			player["guard_hold_ms"] = 0.0
			var recovery_ms := float(row[1])
			var recoil_speed := float(row[0])
			# CC5EEE uses rank speed, then IDIV truncates the deceleration.
			player["guard_recoil_ms"] = recovery_ms
			player["guard_recoil_speed"] = recoil_speed
			player["guard_recoil_accel"] = int(-recoil_speed*1000.0/recovery_ms) if recovery_ms > 0.0 else 0
			player["guard_dust_emitted"] = false
			# CC5F7E clamps the contact height and interpolates the front offset.
			var spark_height := clampi(int(impact_height),22,71)
			var front_offset := int(23.0-17.0*float(spark_height-22)/49.0)
			var guard_facing := int(player["facing"])
			var spark_point := Vector2(player["pos"]).round()+Vector2(front_offset*guard_facing,0)
			spawn_effect("guard_spark",spark_point,guard_facing,roundf(float(player["z"]))+spark_height)
			play_sound("SWD_GUARDED")
	elif numeric_player == null and float(player["buff_ms"])>0:taken *= float(rules["buff"]["damage_taken"])
	var keiga: Dictionary = active_effect("keiga")
	if taken > 0 and not keiga.is_empty() and int(keiga.get("absorb_remaining",0)) > 0:
		keiga["absorb_remaining"] = int(keiga["absorb_remaining"])-1
		taken = 0.0
		if int(keiga["absorb_remaining"]) <= 0 and numeric_player != null:numeric_player.remove_effect("keiga")
	player["hp"] = maxf(0,float(player["hp"])-taken)
	damage_taken += int(taken)
	player["flash_ms"] = 65.0
	player["invuln_ms"] = float(rules["player"]["hit_invuln_ms"])
	var reaction := "guard" if guarded else "none"
	# 8184DF tests the incoming ATK's ignore-super-armor field before reaction dispatch.
	var armor_blocks_reaction := body_armor and int(atk.get("ignore_super_armor",0)) == 0
	var buff_armor: bool = numeric_player.effects.flag("super_armor") if numeric_player != null else float(player["buff_ms"])>0
	if armor_blocks_reaction and taken > 0.0 and float(player["hp"]) > 0.0 and float(player["upper_armor_fx_ms"]) <= 0.0:
		# 81F427 starts a 600 ms gate. The attached light ANI itself ends after 160 ms.
		player["upper_armor_fx_ms"] = 600.0
		bus.emit("combat.cue",{"kind":"fx","key":"upper_armor_light","point":Vector2(player["pos"]),
			"height":float(player["z"]),"facing":int(player["facing"]),"follow":PLAYER_ID})
		var path := "common/commoneffect/particle/superarmor_damage_particle.ptl"
		var particle: Dictionary = combat_assets.get("particles",{}).get(path,{})
		if not particle.is_empty():
			# E4FFC0 clears the mirror flag. 81F486..81F4C1 adds half the stay height.
			bus.emit("combat.cue",{"kind":"native_particle","path":path,"point":Vector2(player["pos"]),
				"height":float(player["z"])+float(particle["z_offset"])})
	if not guarded and state != "hold" and not armor_blocks_reaction and not buff_armor:
		leave_action()
		player["action"] = ""
		player["native_phase"] = {}
		player["queued_combo"] = false
		player["queued_skill"] = ""
		reaction = Kernel.Reaction.apply(player,atk,facing,rules["reaction"],float(numeric_player.values["hit_recovery"]) if numeric_player != null else float(table.player["hit_recovery"]))
		if reaction == "none":player["state"] = "idle"
	play_sound("hurt")
	var mindflash_rank := int(skill_levels.get("mindflash",0))
	if mindflash_rank > 0:
		apply_effect({"kind":"effect","id":"mindflash","target":PLAYER_ID,"rank":mindflash_rank})
	if was_action and int(skill_levels.get("stuckuponcounter",0)) > 0:
		apply_effect({"kind":"effect","id":"counter_evasion","target":PLAYER_ID,"rank":int(skill_levels["stuckuponcounter"])})
	if float(player["hp"])<=0:
		if player.has("triple_cast") or player.has("hardattack_charge") or player.has("hardattack_release") \
				or player.has("weapon_combo_cast") or player.has("draw_cast"):leave_action()
		player["state"] = "dead"
		finished = true
		victory = false
		play_sound("die")
		item_restorations.clear()
		emit_player_defeated()
	return reaction

## Direct damage entry kept for tests and flow-side hazards: a plain frontal monster hit.
func damage_player(amount: float, source: Vector2) -> void:
	var facing := 1 if Vector2(player["pos"]).x >= source.x else -1
	hurt_player(int(amount),{"pos":source},{},facing)

# ---------------------------------------------------------------- passive objects

func spawn_object(hit: Dictionary, owner: String, pos: Vector2, z: float, facing: int, power: float, source := {}, definition := {}) -> Dictionary:
	var obj: Dictionary = table.object(String(hit["object"])) if definition.is_empty() else definition
	if obj.is_empty():return {}
	var off: Vector3 = hit.get("offset",Vector3.ZERO)
	var entity := {"id":_next_entity_id,"def":obj,"owner":owner,"source":source,"hit":hit,"power":power,
		"pos":Vector2(pos.x+off.x*facing,pos.y+off.y),"z":z+off.z,"facing":facing,"clock":0.0,
		"speed":float(hit.get("speed",0)),"life_ms":float(hit.get("life_ms",-1)),"size_rate":float(hit.get("size_rate",1)),"hits":{}}
	if hit.has("ptl_motion"):
		var origin := Vector3i(int(entity["pos"].x),int(entity["pos"].y),int(entity["z"]))
		entity["ptl_motion"] = Kernel.NativeMotion.new(hit["ptl_motion"],origin,facing < 0)
	var controller: Dictionary = hit.get("native_controller",{})
	var kind := String(controller.get("kind",""))
	if kind == "draw_short_wave":
		# A60D6B..A60E68 holds frame zero until the object has travelled
		# the mastery distance. The original animation then runs normally.
		var timeline: Array = obj["timeline"].duplicate(true)
		var travel_ms := float(controller["distance"])*1000.0/float(entity["speed"])
		var shift := travel_ms-float(timeline[0]["end_ms"])
		timeline[0]["end_ms"] = travel_ms
		for index in range(1,timeline.size()):
			timeline[index]["start_ms"] = float(timeline[index]["start_ms"])+shift
			timeline[index]["end_ms"] = float(timeline[index]["end_ms"])+shift
		entity["timeline"] = timeline
	if kind == "bloodblast" and controller.has("reset_ms"):
		var first := float(obj["segments"][0]["start"])
		entity["next_hit_reset"] = first+float(controller["reset_ms"])
		entity["hit_resets_left"] = int(controller["reset_count"])
	if kind in GHOST_FIELD_KINDS:
		if owner == "player" and kind != "rasa_field":
			player["hardattack_ghost"] = controller.get("ghost_variant",kind.trim_suffix("_field"))
		var exit_ms := float(controller["disappear_ms"])
		if kind in ["khazan_field","bremen_field"]:
			for previous: Dictionary in objects:
				if previous["owner"] == owner and not previous.get("superseded",false) and previous["hit"].get("native_controller",{}).get("kind") == kind:
					# C9E490 -> A665D0 replaces Khazan/Bremen only, keeping the exit clip.
					previous["superseded"] = true
					previous["exit_at_ms"] = minf(float(previous["exit_at_ms"]),float(previous["clock"]))
					previous["life_ms"] = float(previous["exit_at_ms"])+exit_ms
		entity["exit_at_ms"] = float(entity["life_ms"])-exit_ms
		entity["next_pulse_ms"] = float(controller["pulse_ms"]) if kind == "rasa_field" else 0.0
		entity["field_rank"] = int(skill_levels.get(String(hit["skill_id"]),1))
		if controller.has("first_update_sound"):entity["first_update_sound"] = controller["first_update_sound"]
		if kind == "khazan_field" and numeric_player != null:numeric_player.remove_effect("khazan_aura")
	if controller.get("kind","") == "icewave_chain":
		var ordinal := int(hit.get("chain_ordinal",0))
		entity["size_rate"] = _native_float32(float(controller["initial_size"])+_native_float32(ordinal*_native_float32(float(controller["size_step"]))))
		entity["z"] = 0.0
		entity["child_spawned"] = ordinal >= int(controller["count"])-1
		entity["shatter_emitted"] = false
		# A6E554..5BB changes frame 1, keeping the original frame 0 and tail.
		var timeline: Array = obj["timeline"].duplicate(true)
		var shift := float(controller["frame2_at_ms"])-float(timeline[1]["end_ms"])
		timeline[1]["end_ms"] = float(controller["frame2_at_ms"])
		for frame_index in range(2,timeline.size()):
			timeline[frame_index]["start_ms"] = float(timeline[frame_index]["start_ms"])+shift
			timeline[frame_index]["end_ms"] = float(timeline[frame_index]["end_ms"])+shift
		entity["timeline"] = timeline
	_next_entity_id += 1
	objects.append(entity)
	if controller.get("kind","") == "icewave_chain":
		# A6FE41 reads 1A5F820 (Smoke.ptl), sets emitter XYZ, resets it at 0,
		# emits once, then A6FF21 applies ice DD8 to the generated ANI only.
		# This source block does not mirror the shared emitter with the caster.
		bus.emit("combat.cue",{"kind":"native_particle",
			"path":"passiveobject/character/swordman/particle/icewaveparticlesmoke.ptl",
			"point":entity["pos"],"height":entity["z"],"scale":entity["size_rate"]})
	if String(obj["add_fx"]) != "":spawn_effect(String(obj["add_fx"]),entity["pos"],facing,float(entity["z"]))
	return entity

func step_objects(ms: float, first_new_object_id := -1) -> void:
	var khazan_field: Dictionary = {}
	var bremen_field: Dictionary = {}
	var bremen_removed := false
	for i in range(objects.size()-1,-1,-1):
		var o: Dictionary = objects[i]
		var obj: Dictionary = o["def"]
		var hit: Dictionary = o["hit"]
		var controller: Dictionary = hit.get("native_controller",{})
		var kind := String(controller.get("kind",""))
		var object_ms := ms
		if first_new_object_id > 0 and int(o["id"]) >= first_new_object_id and o["owner"] in ["player","companion"] \
				and (kind in GHOST_FIELD_KINDS or hit.get("skill_id","") in ["normalwave","icewave","firewave"]):
			# CB25FB..CB2819 creates a fresh object at release. Evaluate frame zero
			# now without charging the new object for the caster's creation update.
			object_ms = 0.0
		if first_new_object_id > 0 and int(o["id"]) >= first_new_object_id and (o.has("ptl_motion") or hit.get("starts_at_zero",false)):
			object_ms = 0.0
		var old_t := float(o["clock"])
		var t := old_t+object_ms
		o["clock"] = t
		if o.has("ptl_motion"):
			var sample: Dictionary = o["ptl_motion"].advance_to(int(t))
			if not sample.get("ok",false) or not sample["alive"]:
				objects.remove_at(i)
				continue
			var position: Vector3i = sample["position"]
			o["pos"] = Vector2(position.x,position.y)
			o["z"] = float(position.z)
		else:
			o["pos"] = Vector2(o["pos"])+Vector2(float(o["speed"])*int(o["facing"])*object_ms/1000.0,0)
		if kind in GHOST_FIELD_KINDS:
			if o.has("first_update_sound"):
				# A67B64 checks a per-object latch, independent of the pulse clock.
				var first_sound := String(o["first_update_sound"])
				o.erase("first_update_sound")
				play_sound(first_sound)
			if controller.has("crystals"):step_saya_crystal_field(o,controller)
			if kind == "saya_field" and ghost_field_pulse(o):
				# A68045..A68152 runs the area attack before the deletion check.
				pulse_saya_field(o)
			if t >= float(o["life_ms"]):
				objects.remove_at(i)
				if kind == "bremen_field":bremen_removed = true
			elif kind == "rasa_field" and t >= float(o["next_pulse_ms"]):
				# A63B90 calls the repeating selection timer after its deletion gate.
				o["next_pulse_ms"] = float(o["next_pulse_ms"])+float(controller["pulse_ms"])
				pulse_rasa_field(o)
			elif o["owner"] == "player" and not o.get("superseded",false):
				if kind == "khazan_field":khazan_field = o
				elif kind == "bremen_field":bremen_field = o
			continue
		if kind == "rasa_child":
			if not step_rasa_child(o,controller):objects.remove_at(i)
			continue
		if kind == "sayaex_ice":
			if not step_saya_crystal(o,controller):objects.remove_at(i)
			continue
		var active := float(hit.get("active_ms",-1))
		var done := false
		var life := float(o["life_ms"])
		var tl: Array = o.get("timeline",obj["timeline"])
		if kind == "bloodblast":
			if int(o.get("hit_resets_left",0)) > 0 and t >= float(o["next_hit_reset"]):
				o["hits"].clear()
				o["hit_resets_left"] -= 1
				o["next_hit_reset"] += float(controller["reset_ms"])
			var sound_at := float(controller.get("sound_at_ms",INF))
			if old_t < sound_at and t >= sound_at:play_sound("FIRE_PILLAR_UP")
		if controller.get("kind","") == "firewave_chain" and t >= Kernel.Timeline.duration(tl):
			# Native ANI+1EC bit 8: create 20025 at +/-360, then delete 20024.
			# The successor starts at age zero, independently of the actor clock.
			var child_hit: Dictionary = controller["child"].duplicate(true)
			child_hit["skill_id"] = hit.get("skill_id","")
			spawn_object(child_hit,String(o["owner"]),o["pos"],float(o["z"]),int(o["facing"]),float(o["power"]),o["source"])
			objects.remove_at(i)
			continue
		if controller.get("kind","") == "icewave_chain" and not bool(o["child_spawned"]) and t>=float(controller["interval_ms"]):
			o["child_spawned"] = true
			var ordinal := int(hit.get("chain_ordinal",0))
			var child_hit: Dictionary = hit.duplicate(true)
			var paths: Array = controller["objects"]
			child_hit["chain_ordinal"] = ordinal+1
			child_hit["object"] = paths[(ordinal+1)%paths.size()]
			# 2331DB1 MULSS -1.2f; 2431497 CVTTSS2SI; 24314C1 subtracts from 21.
			var gap := int(controller["gap_base"])-int(_native_float32(_native_float32(-float(controller["gap_step"]))*ordinal))
			child_hit["offset"] = Vector3(gap,0,0)
			spawn_object(child_hit,String(o["owner"]),o["pos"],0.0,int(o["facing"]),float(o["power"]),o["source"])
		if controller.get("kind","") == "icewave_chain" and not bool(o["shatter_emitted"]):
			# Native DD6 guard / ANI+144 >= 3, independent of hit or ANI end.
			# Source replay: tools/audit_dnf_ice_shatter.py; 2304DA4 sets DD6 once.
			var ice_frame: Dictionary = Kernel.Timeline.frame_at(tl,t)
			if int(ice_frame.get("frame",-1)) >= 3:
				o["shatter_emitted"] = true
				var ordinal := int(hit.get("chain_ordinal",0))
				# MULSS -1.5, CVTTSS2SI, then subtract from Z+20 in both branches.
				var height := int(o["z"])+20-int(_native_float32(_native_float32(ordinal)*-1.5))
				bus.emit("combat.cue",{"kind":"native_particle",
					"path":"passiveobject/character/swordman/particle/icewaveparticle.ptl",
					"point":o["pos"],"height":height,"scale":o["size_rate"]})
				# Only the shard vector passes through 23CF53E image scaling.
				bus.emit("combat.cue",{"kind":"native_particle",
					"path":"passiveobject/character/swordman/particle/icewaveparticlestar.ptl",
					"point":o["pos"],"height":height,"scale":1.0})
		var loops := life > 0
		if active < 0 or t <= active:
			var f: Dictionary = Kernel.Timeline.frame_at(tl,t,loops)
			var boxes: Array = f.get("attack_boxes",[])
			if not boxes.is_empty():
				var world: Array = Kernel.HitJudge.world_boxes(boxes,Kernel.HitJudge.anchor(o["pos"],float(o["z"])),int(o["facing"]),float(o.get("size_rate",1)))
				var attacker: Dictionary = player if o["owner"] == "player" else o["source"]
				if attacker.is_empty():attacker = {"id":-1,"pos":o["pos"],"stuck_ms":0.0}
				var friendly: bool = o["owner"] in ["player","companion"]
				var targets := monsters if friendly else friendly_targets()
				for target: Dictionary in targets:
					if o["hits"].has(target["id"]) or float(target["hp"])<=0:continue
					var target_boxes := enemy_damage_boxes(target) if friendly else friendly_damage_boxes(target)
					var c: Dictionary = Kernel.HitJudge.contact(world,target_boxes)
					if c.is_empty():continue
					o["hits"][target["id"]] = true
					land_hit(attacker,target,hit,c["point"],int(o["facing"]),float(o["power"]))
					if int(obj["piercing"]) <= 0:
						done = true
						if not friendly:break
				if native_maze != null and o["owner"] == "player":
					apply_native_prop_hits(world,hit,float(o["power"]),o["hits"],"prop:")
		if life > 0 and t >= life:done = true
		elif life <= 0 and t >= Kernel.Timeline.duration(tl) and (active < 0 or t >= active):done = true
		if active >= 0 and t >= active and life <= 0 and Kernel.Timeline.duration(tl) > 2000:done = true
		if done:objects.remove_at(i)
	if khazan_field.is_empty() or ghost_field_pulse(khazan_field):update_khazan_aura(khazan_field)
	if (bremen_field.is_empty() and bremen_removed) or (not bremen_field.is_empty() and ghost_field_pulse(bremen_field)):
		update_bremen_aura(bremen_field)

func ghost_field_pulse(field: Dictionary) -> bool:
	var age := float(field["clock"])
	if age < float(field["next_pulse_ms"]):return false
	# 926990 -> 11246D0 starts immediately, then repeats at the object's interval.
	var interval := float(field["hit"]["native_controller"]["pulse_ms"])
	field["next_pulse_ms"] = age+interval
	return true

func ghost_field_contains(field: Dictionary, position: Vector2) -> bool:
	var controller: Dictionary = field["hit"]["native_controller"]
	return ghost_distance(field["pos"],position,float(controller["depth_scale"])) <= int(controller["radius"])

func ghost_distance(origin: Vector2, position: Vector2, depth_scale: float) -> int:
	# 9269E0 -> 406580 -> 7F10A0 projects integer depth and truncates distance.
	var delta := Vector2i(position)-Vector2i(origin)
	var depth := int(_native_float32(float(delta.y)/_native_float32(depth_scale)))
	return int(sqrt(delta.x*delta.x+depth*depth))

func update_khazan_aura(field: Dictionary = {}) -> void:
	if numeric_player == null:return
	if not field.is_empty() and ghost_field_contains(field,player["pos"]):
		if active_effect("khazan_aura").is_empty():
			var remaining := float(field["life_ms"]) - float(field["clock"])
			numeric_player.add_effect("khazan_aura",int(field["field_rank"]),{"duration_ms":remaining})
		return
	numeric_player.remove_effect("khazan_aura")

func update_bremen_aura(field: Dictionary) -> void:
	for enemy: Dictionary in monsters:
		var actor = enemy.get("numeric")
		if actor == null:continue
		# CNGhost A6656A accepts hostiles; this scene's monster list owns that side.
		if field.is_empty() or float(enemy["hp"]) <= 0 or not ghost_field_contains(field,enemy["pos"]):
			actor.remove_effect("bremen_debuff")
			continue
		var current: Dictionary = actor.effects.active.get("bremen_debuff",{})
		if current.get("field_id",-1) != field["id"]:
			var remaining := float(field["life_ms"]) - float(field["clock"])
			if actor.add_effect("bremen_debuff",int(field["field_rank"]),{"duration_ms":remaining}):
				actor.effects.active["bremen_debuff"]["field_id"] = field["id"]

func pulse_saya_field(field: Dictionary) -> void:
	var attacker: Dictionary = player if field["owner"] == "player" else field["source"]
	if attacker.is_empty():return
	var hit: Dictionary = field["hit"]
	var height_limit := int(hit["native_controller"]["height_limit"])
	for enemy: Dictionary in monsters:
		var height := int(enemy["z"])
		if float(enemy["hp"]) <= 0 or height > height_limit or not ghost_field_contains(field,enemy["pos"]):continue
		var position: Vector2 = enemy["pos"]
		var impact := Vector3(position.x,position.y,int((height+height_limit)/2.0))
		land_hit(attacker,enemy,hit,impact,int(field["facing"]),float(field["power"]))

func step_saya_crystal_field(field: Dictionary, controller: Dictionary) -> void:
	var age := float(field["clock"])
	if age >= float(field["exit_at_ms"]):return
	var ice: Dictionary = controller["crystals"]
	if not field.has("crystal_queue"):
		# A67C81..A67D88 creates the initial batch in ordinal order.
		field["crystal_queue"] = {}
		field["crystal_rng"] = rng.seed_value ^ int(field["id"])
		for ordinal in int(ice["count"]):spawn_saya_crystal(field,controller,ordinal)
		return
	var queue: Dictionary = field["crystal_queue"]
	for ordinal: int in queue.keys():
		if age < float(queue[ordinal]):continue
		spawn_saya_crystal(field,controller,ordinal)
		queue.erase(ordinal)

func _saya_random(seed_value: int) -> Vector2i:
	# E47F50 combines three consecutive unsigned 32-bit LCG states.
	var first := (seed_value*1103515245+12345) & 0xffffffff
	var second := (first*1103515245+12345) & 0xffffffff
	var third := (second*1103515245+12345) & 0xffffffff
	var sample := (((first>>16)&0x7ff)<<20) | (((second>>16)&0x3ff)<<10) | ((third>>16)&0x3ff)
	return Vector2i(third,sample)

func spawn_saya_crystal(field: Dictionary, controller: Dictionary, ordinal: int) -> void:
	var ice: Dictionary = controller["crystals"]
	var radius := int(controller["radius"])
	@warning_ignore("integer_division")
	var band := 2*radius/int(ice["count"])
	var rx := _saya_random(int(field["crystal_rng"]))
	var ry := _saya_random(rx.x)
	field["crystal_rng"] = ry.x
	var center := Vector2i(field["pos"])
	var depth_scale := _native_float32(29.0*_native_float32(0.01))
	@warning_ignore("integer_division")
	var depth_offset := _native_float32((ry.y%radius-radius/2)*depth_scale)
	var point := Vector2(center.x-radius+band*ordinal+rx.y%maxi(1,band),int(_native_float32(center.y+depth_offset)))
	var hit: Dictionary = ice["child"].duplicate()
	hit["skill_id"] = field["hit"]["skill_id"]
	var object := spawn_object(hit,String(field["owner"]),point,float(ice["height"]),int(field["facing"]),float(field["power"]),field["source"])
	object["crystal_parent"] = field
	object["crystal_ordinal"] = ordinal
	object["crystal_born_at"] = field["clock"]
	object["crystal_phase"] = "ready"
	object["crystal_phase_at"] = 0.0
	object["crystal_ready_offset"] = _saya_random(int(object["id"])).y%int(hit["native_controller"]["ready_first_ms"])

func step_saya_crystal(object: Dictionary, controller: Dictionary) -> bool:
	var field: Dictionary = object["crystal_parent"]
	var field_controller: Dictionary = field["hit"]["native_controller"]
	var ice: Dictionary = field_controller["crystals"]
	var age := float(object["clock"])
	var born := float(object["crystal_born_at"])
	var exit_age := float(field["exit_at_ms"])-born
	if age >= exit_age and object["crystal_phase"] != "end":
		# A67F02..A67F3B forces End at the start of the parent's exit.
		end_saya_crystal(object,exit_age)
	var elapsed := age-float(object["crystal_phase_at"])
	match String(object["crystal_phase"]):
		"ready":
			var radius := int(ice["range"])
			for enemy: Dictionary in monsters:
				if float(enemy["hp"]) <= 0.0 or target_invulnerable(enemy):continue
				if absi(int(enemy["z"])-int(object["z"])) > radius:continue
				var distance := ghost_distance(object["pos"],enemy["pos"],float(field_controller["depth_scale"]))
				if distance > radius:continue
				object["crystal_target"] = enemy
				object["crystal_origin"] = Vector3i(int(object["pos"].x),int(object["pos"].y),int(object["z"]))
				object["crystal_flight_ms"] = int(_native_float32(_native_float32(distance/float(ice["speed"]))*1000.0))
				object["crystal_phase"] = "start"
				object["crystal_phase_at"] = age
				break
		"start":
			if elapsed >= float(controller["start_sound_at_ms"]) and not object.has("crystal_start_sound"):
				object["crystal_start_sound"] = true
				play_sound(String(controller["start_sound"]))
			if elapsed >= float(controller["start_ms"]):
				object["crystal_phase"] = "stay"
				object["crystal_phase_at"] = age
		"stay":
			var target: Dictionary = object["crystal_target"]
			if not monsters.has(target):
				end_saya_crystal(object,age)
				return true
			var point := saya_crystal_impact(target)
			var origin: Vector3i = object["crystal_origin"]
			var flight := int(object["crystal_flight_ms"])
			object["pos"] = Vector2(_saya_interpolate(origin.x,int(point.x),int(elapsed),flight),_saya_interpolate(origin.y,int(point.y),int(elapsed),flight))
			object["z"] = _saya_interpolate(origin.z,int(point.z),int(elapsed),flight)
			if elapsed >= float(flight):
				var attacker: Dictionary = player if object["owner"] == "player" else object["source"]
				if not attacker.is_empty() and float(target["hp"]) > 0.0 and not target_invulnerable(target):
					# A67924 uses a direct attack, independent of ANI attack boxes.
					land_hit(attacker,target,object["hit"],point,int(object["facing"]),float(object["power"]))
				end_saya_crystal(object,age)
		"end":
			if elapsed >= float(controller["end_ms"]):
				var due := born+age+float(ice["respawn_ms"])
				# A68259 queues the removed ordinal only when due strictly before exit.
				if due < float(field["exit_at_ms"]):field["crystal_queue"][object["crystal_ordinal"]] = due
				return false
	return true

func end_saya_crystal(object: Dictionary, age: float) -> void:
	object["crystal_phase"] = "end"
	object["crystal_phase_at"] = age
	object.erase("crystal_target")

func saya_crystal_impact(target: Dictionary) -> Vector3:
	var height := float(target["z"])
	var top := height
	for box: AABB in enemy_damage_boxes(target):top = maxf(top,box.end.z)
	# A67848 adds half the target's native height. Use the current hurt extent
	# until the native +0x11C height getter is mapped for the enemy classes.
	return Vector3(int(target["pos"].x),int(target["pos"].y),int(height)+int((top-height)*0.5))

func _saya_interpolate(origin: int, target: int, age: int, duration: int) -> int:
	# 11AEE50 multiplies before dividing, with integer endpoints and SSE rounding.
	if age >= duration:return target
	if age <= 0:return origin
	var scaled := _native_float32(_native_float32(float(target-origin)*age)/float(duration))
	return int(_native_float32(float(origin)+scaled))

func rasa_attachment_count(target_id: int) -> int:
	var count := 0
	for object: Dictionary in objects:
		if int(object.get("rasa_target_id",-1)) == target_id:count += 1
	return count

func pulse_rasa_field(field: Dictionary) -> void:
	var controller: Dictionary = field["hit"]["native_controller"]
	var child: Dictionary = controller["child"]
	var limit := int(child["native_controller"]["attachment_limit"])
	var target: Dictionary = {}
	var highest_hp := 0
	# A63790 selects the first highest-HP hostile within the projected radius,
	# excluding targets already carrying the attachment limit.
	for enemy: Dictionary in monsters:
		var hp := int(enemy["hp"])
		if hp <= highest_hp or not ghost_field_contains(field,enemy["pos"]):continue
		if rasa_attachment_count(int(enemy["id"])) >= limit:continue
		target = enemy
		highest_hp = hp
	if target.is_empty():return
	for ordinal in int(controller["child_count"]):
		# A63B90 makes independent sign draws and uses %64 / %32 magnitudes.
		var side := 1 if rng.range_int(0,1) != 0 else -1
		var depth_side := -1 if rng.range_int(0,1) != 0 else 1
		var point := Vector2(Vector2i(target["pos"]))+Vector2(side*rng.range_int(0,63),depth_side*rng.range_int(0,31))
		var hit := child.duplicate()
		hit["rasa_creator_id"] = field["id"]
		spawn_object(hit,String(field["owner"]),point,float(target["z"]),side,float(field["power"]),field["source"])

func step_rasa_child(object: Dictionary, controller: Dictionary) -> bool:
	var age := float(object["clock"])
	if object.has("rasa_target_id"):
		var target: Dictionary = object["rasa_target"]
		if float(target["hp"]) <= 0 or not monsters.has(target) or age-float(object["rasa_attached_at"]) >= float(controller["attachment_ms"]):
			set_rasa_modifiers(object,target,false)
			return false
		object["pos"] = Vector2(target["pos"])+Vector2(0,int(object["rasa_slot"])+1)
		object["z"] = target["z"]
		if age-float(object["rasa_attached_at"]) < float(controller["grab_ms"]):return true
		if not object.has("rasa_grab_finished"):
			# A64307 enters the stable attachment and leaves this update.
			object["rasa_grab_finished"] = true
			return true
		# A6430E polls the timer started at birth, after the grab clip ends.
		# A due poll advances one interval, even if more elapsed between ticks.
		var interval := float(controller["status_interval_ms"])
		var next_status := float(object.get("rasa_next_status_ms",interval))
		if interval > 0.0 and age >= next_status:
			object["rasa_next_status_ms"] = next_status+interval
			# Native order is poison, blind, bleed. Only blind is connected.
			if rng.range_int(0,2) == 1 and not bool(target["chief"]) and target.has("numeric") \
					and target["numeric"].apply_source_blind(controller["blind"],rng.range_int(0,9999)):
				if target["def"].get("native_target_profile",{}).get("uses_ai_vision",false):
					target["native_blind_applied"] = true
				bus.emit("combat.status",{"target":target["id"],"id":"blind","change":"added"})
		return true
	if age >= float(object["life_ms"]):return false
	var creator_id := int(object["hit"]["rasa_creator_id"])
	if not objects.any(func(other: Dictionary):return int(other["id"]) == creator_id and float(other["clock"]) < float(other["life_ms"])):return false
	var startup_ms := float(controller["startup_ms"])
	if age < startup_ms:return true
	var frame: Dictionary = Kernel.Timeline.frame_at(controller["stay_timeline"],age-startup_ms,true)
	var world: Array = Kernel.HitJudge.world_boxes(frame.get("attack_boxes",[]),
		Kernel.HitJudge.anchor(object["pos"],float(object["z"])),int(object["facing"]))
	# A644F0 attaches only on the actual stay ANI attack contact.
	for target: Dictionary in monsters:
		if float(target["hp"]) <= 0 or Kernel.HitJudge.contact(world,enemy_damage_boxes(target)).is_empty():continue
		var slot := rasa_attachment_count(int(target["id"]))
		if slot >= int(controller["attachment_limit"]):continue
		object["rasa_target_id"] = target["id"]
		object["rasa_target"] = target
		object["rasa_attached_at"] = age
		object["rasa_slot"] = slot
		object["pos"] = Vector2(target["pos"])+Vector2(0,slot+1)
		object["z"] = target["z"]
		set_rasa_modifiers(object,target,true)
		break
	return true

func set_rasa_modifiers(object: Dictionary, target: Dictionary, attached: bool) -> void:
	var actor = target.get("numeric")
	if actor == null or bool(target["chief"]):return
	var id := int(object["id"])
	var mods: Array = actor.runtime_modifiers.filter(func(mod: Dictionary):return int(mod.get("rasa_object_id",-1)) != id)
	if attached:
		var controller: Dictionary = object["hit"]["native_controller"]
		# A648DA / A64964 write negative equipment physical defense and hit
		# recovery. The ordinary monster branch applies the full source value.
		for field: Array in [["physical_defense","defense"],["hit_recovery","recovery"]]:
			mods.append({"source":"瘟疫之罗刹","stat":field[0],"op":"add","value":-float(controller[field[1]]),"rasa_object_id":id})
		# A64883 -> 97B904..97B956 adds the negative source value in thousandths to the attack-rate multiplier.
		mods.append({"source":"瘟疫之罗刹","stat":"attack_speed","op":"percent",
			"value":-float(controller["attack_speed"]),"rasa_object_id":id})
	var previous_rate := float(actor.values["attack_speed"])
	actor.set_runtime_modifiers(mods)
	if target["state"] == "attack" and previous_rate != float(actor.values["attack_speed"]) \
			and not target.has("rasa_previous_attack_rate"):
		target["rasa_previous_attack_rate"] = previous_rate
	bus.emit("combat.status",{"target":target["id"],"id":"rasa_attachment","change":"added" if attached else "removed"})

## Round the original SSE scalar operation before its truncating integer conversion.
func _native_float32(value: float) -> float:
	return PackedFloat32Array([value])[0]

## Render the same frame as collision while keeping the shared source atlas immutable.
func object_view_clock(o: Dictionary) -> float:
	var clock := float(o["clock"])
	if not o.has("timeline"):return clock
	var timeline: Array = o["timeline"]
	var source: Array = o["def"]["timeline"]
	for i in timeline.size():
		var frame: Dictionary = timeline[i]
		if clock < float(frame["end_ms"]):
			var progress := (clock-float(frame["start_ms"]))/maxf(0.001,float(frame["end_ms"])-float(frame["start_ms"]))
			return lerpf(float(source[i]["start_ms"]),float(source[i]["end_ms"]),progress)
	return Kernel.Timeline.duration(source)

func _ghost_field_layers(base: Dictionary, controller: Dictionary, exit_at_ms: float) -> Array:
	var age := float(base["clock"])
	var appear_ms := float(controller["appear_ms"])
	var disappear_ms := float(controller["disappear_ms"])
	# A66680 colors the first two motions to 180/255 with a ramp on entry/exit.
	var opacity := minf(age/appear_ms,clampf(1.0-(age-exit_at_ms)/disappear_ms,0.0,1.0))
	base["fade"] = int(opacity*180.0)/255.0
	base["loop"] = true
	if controller.has("ghost_base_fx"):base["effect"] = controller["ghost_base_fx"]
	var second := base.duplicate()
	second.merge({"id":"%s:ghost"%base["id"],"effect":controller["ghost_fx"]},true)
	var layers: Array = [base,second]
	var area := base.duplicate()
	area.merge({"fade":1.0,"depth_offset":-1,"loop":false,"size_rate":float(controller["area_scale"])},true)
	if age >= exit_at_ms:
		area.merge({"id":"%s:exit"%base["id"],"effect":controller["disappear_fx"],"clock":age-exit_at_ms},true)
		layers.append(area)
	elif age >= appear_ms:
		area.merge({"id":"%s:stay"%base["id"],"effect":controller["stay_fx"],"clock":age-appear_ms,"loop":true},true)
		layers.append(area)
	else:
		for i in controller["appear_fx"].size():
			var entry := area.duplicate()
			entry.merge({"id":"%s:entry:%d"%[base["id"],i],"effect":controller["appear_fx"][i]},true)
			layers.append(entry)
	return layers

func _rasa_child_layers(base: Dictionary, object: Dictionary, controller: Dictionary) -> Array:
	var phase := "startup"
	var age := float(base["clock"])
	base["loop"] = false
	if object.has("rasa_target_id"):
		age -= float(object["rasa_attached_at"])
		phase = "grab"
		if age >= float(controller["grab_ms"]):
			age -= float(controller["grab_ms"])
			phase = "grab_stay"
			base["loop"] = true
	elif age >= float(controller["startup_ms"]):
		age -= float(controller["startup_ms"])
		phase = "stay"
		base["loop"] = true
	base["id"] = "%s:%s" % [object["id"],phase]
	base["clock"] = age
	if phase != "startup":base["effect"] = controller[phase+"_fx"]
	var overlay := base.duplicate()
	overlay["id"] = "%s:overlay" % base["id"]
	overlay["effect"] = controller[phase+"_overlay"]
	return [base,overlay]

# ---------------------------------------------------------------- world
# Rooms are original Lorien maps (data/combat.json "rooms" -> map export placement). Ground
# positions are map coordinates (x pixels, y ground depth); walkability is the map's pass grid.

## 快照里的 props 只暴露视图用得到的少数字段。
## 之前这里是 props.duplicate(true)：每个 prop 都带整份 obj 定义（动画/音效/掉落表），
## 每帧深拷贝一次，物件多的房间（如洛兰 BOSS 房 10 个）会把主循环拖慢一个数量级。
func props_view() -> Array:
	var out: Array = []
	for prop: Dictionary in props:
		out.append({"id": String(prop.get("id", "")), "pos": Vector2(prop.get("pos", Vector2.ZERO)),
			"broken": bool(prop.get("broken", false)), "hazard": bool(prop.get("hazard", false))})
	return out

func array_of(source: Variant) -> Array:
	# GDScript 的 `or` 返回 bool（与 Python 不同），这里显式判类型。
	return source if source is Array else []

## 可破坏物的破坏粒子表（obj 路径 → effect key 列表），由 build_dnf_combat_assets 生成。
var breakable_particles: Dictionary = {}
var breakable_particles_loaded := false

func breakable_particle_keys(path: String) -> Array:
	if not breakable_particles_loaded:
		breakable_particles_loaded = true
		if FileAccess.file_exists("res://data/breakable_particles.json"):
			var doc = JSON.parse_string(FileAccess.get_file_as_string("res://data/breakable_particles.json"))
			if doc is Dictionary:
				breakable_particles = doc.get("objects", {})
	return array_of(breakable_particles.get(path, []))

func build_props(room: Dictionary) -> Array:
	var out: Array = []
	var objects: Array = array_of(room.get("objects"))
	for object_index in objects.size():
		var item: Dictionary = objects[object_index]
		var path := String(item.get("obj", "")).to_lower()
		if native_maze != null:
			# Source routes only enable the exact payloads supported by the adapter.
			if NativeBreakable.supports(item):
				var trap := NativeJarTraps.prepare(item,hash("%s:%s:trap:%d"%[run_id,room_id,object_index]))
				var source: Dictionary = content.record(path)["native_breakable"]
				var timeline: Array = table.timeline(source["motion_ani"])
				var prop := NativeBreakable.create(item,source,timeline[0]["damage_boxes"],object_index)
				if not trap.is_empty():prop["jar_trap"] = trap
				var draws := NativeBoxLoot.draw_count(item)
				if draws > 0:
					prop["box_items"] = NativeBoxLoot.prepare(draws,hash("%s:%s:box:%d"%[run_id,room_id,object_index]))
				var roster := NativePotMonsters.prepared(map_loader.data["dungeon"]["sha256"],room["sha256"],object_index)
				if not roster.is_empty():
					for child: Dictionary in roster:
						child["id"] = _next_entity_id
						_next_entity_id += 1
					prop["pot_monsters"] = roster
				out.append(prop)
			continue
		# 两类场景物件：可破坏物（打碎）与陷阱（trap/* 里有 [attack info] 的会伤害玩家）。
		var breakable := path.contains("breakableobject/")
		var hazard := path.contains("/trap/")
		if not breakable and not hazard:
			continue
		var def: Dictionary = table.object(path)
		if def.is_empty():
			continue
		if hazard and not breakable and array_of(def.get("attack_infos")).is_empty():
			continue
		var anchor: Array = array_of(item.get("anchor"))
		if anchor.size() < 2:
			continue
		var width: Array = array_of(def.get("width"))
		if width.size() < 2:
			width = [40, 20]
		var data: Array = array_of(def.get("int_data"))
		var strings: Array = array_of(def.get("string_data"))
		# Legacy room adapter uses the previously inferred hit count.
		var hits := int(data[1]) if data.size() > 1 else 1
		var pos := Vector2(float(anchor[0]), float(anchor[1]))
		var size := Vector2(float(width[0]), float(width[1]))
		var attack_infos: Array = array_of(def.get("attack_infos"))
		var damage_atk: Dictionary = table.atk(String(attack_infos[0])) if not attack_infos.is_empty() else {}
		out.append({
			"id": "%s#%d" % [path, out.size()],
			"pos": pos, "z": float(anchor[2]) if anchor.size() > 2 else 0.0,
			"collision": Rect2(pos.x - size.x * 0.5, pos.y - size.y, size.x, size.y),
			"breakable": breakable, "broken": false, "broken_ms": 0.0,
			# 陷阱：玩家走进判定范围就按 .atk 结算一次伤害（trap/* 的 [attack info]）。
			"hazard": hazard and not breakable, "damage_atk": damage_atk, "hazard_ms": 0.0,
			"hp": maxi(1, hits), "def": def,
			"break_sound": String(strings[5]) if strings.size() > 5 else "",
			"hit_sound": String(strings[4]) if strings.size() > 4 else "",
			"particles": breakable_particle_keys(path),
			"node": object_index,
		})
	return out

## 陷阱的伤害间隔：原版 .obj 的 [int data] 里有一位像冷却（cryplant 为 2000），
## 语义未完全确定，先统一按 2 秒（E-INFER）。
const HAZARD_INTERVAL_MS := 2000.0

## 玩家站在陷阱判定范围内时按周期受伤。攻击者用 id=-2 的虚拟环境体，
## 伤害走与怪物相同的 land_hit 流程（.atk 的击退/浮空/命中音都会生效）。
func step_hazards(ms: float) -> void:
	if props.is_empty():return
	var body: Array = player_damage_boxes()
	for prop: Dictionary in props:
		if not bool(prop.get("hazard", false)) or bool(prop.get("broken", false)):continue
		prop["hazard_ms"] = maxf(0.0, float(prop.get("hazard_ms", 0.0)) - ms)
		if float(prop["hazard_ms"]) > 0.0:continue
		var box: AABB = Kernel.HitJudge.prop_box(prop["collision"])
		if Kernel.HitJudge.contact([box], body).is_empty():continue
		prop["hazard_ms"] = HAZARD_INTERVAL_MS
		var atk: Dictionary = prop.get("damage_atk", {})
		var env := {"id": -2, "pos": prop["pos"], "z": 0.0, "numeric": null,
			"facing": 1, "state": "idle", "hits": {}}
		land_hit(env, player, {"atk": atk, "percent": 100.0 + float(atk.get("damage_bonus", 0)), "lift": -1.0},
			Vector3(float(prop["pos"].x), float(prop["pos"].y), 0.0), 1, float(player["attack"]))

func room_placement(index: int) -> Dictionary:
	if native_maze != null:return native_room["placement"] if index == room_index else {}
	var id := String(rules["rooms"][index]["placement"])
	for p: Dictionary in map_loader.placements():
		if String(p["id"]) == id:return p
	return {}

func route_room_name() -> String:
	return native_route_name if native_maze != null else String(rules["rooms"][room_index]["name"])

func route_boss_room() -> bool:
	return bool(native_room["boss"]) if native_maze != null else bool(rules["rooms"][room_index].get("boss",false))

func route_room_count() -> int:
	return native_maze.room_count() if native_maze != null else rules["rooms"].size()

func route_room_number() -> int:
	return native_maze.room_number() if native_maze != null else room_index+1

## room_cleared records the once-per-room event. A new source hostile can lock the gate again.
func room_is_open(alive_count: int) -> bool:
	return room_cleared and (native_maze == null or alive_count == 0)

func route_exit_target(alive_count: int) -> Vector2:
	if not room_is_open(alive_count) or finished:return Vector2.ZERO
	if native_maze != null:return Vector2.ZERO if doors.is_empty() else Vector2(doors[0]["pos"])
	return door_point(String(rules["rooms"][room_index]["next"]))

func walkable(p: Vector2) -> bool:
	if room_map.is_empty() or p.x < 0 or p.x >= room_width:return false
	return map_loader.is_walkable(room_map,p.x,p.y)

## Route doors must use the room's main connected floor, not a decorative or isolated pass island.
func main_walk_cells() -> Dictionary:
	if _walk_component_ready:return _walk_main_cells
	_walk_component_ready = true
	_walk_main_cells = {}
	var grid: Array = room_map.get("walk_grid",[])
	if grid.is_empty():return _walk_main_cells
	var remaining := {}
	for row in grid.size():
		var cells: Array = grid[row]
		for col in cells.size():
			if int(cells[col]) == 0:remaining[Vector2i(col,row)] = true
	var best := {}
	while not remaining.is_empty():
		var start: Vector2i = remaining.keys()[0]
		var component := {start:true}
		remaining.erase(start)
		var queue: Array[Vector2i] = [start]
		while not queue.is_empty():
			var cell: Vector2i = queue.pop_back()
			for step: Vector2i in [Vector2i.LEFT,Vector2i.RIGHT,Vector2i.UP,Vector2i.DOWN]:
				var next := cell+step
				if not remaining.has(next):continue
				remaining.erase(next)
				component[next] = true
				queue.append(next)
		if component.size() > best.size():best = component
	_walk_main_cells = best
	return _walk_main_cells

## Vertical gates extend into the room by 72 px. A down gate at screen y=548 would
## otherwise trigger at y=520, below the HUD top at 508, so the player cannot see
## that they entered the doorway.
func door_trigger_rect(side: String) -> Rect2:
	match side:
		"up":return Rect2(-48,-28,96,100)
		"down":return Rect2(-48,-72,96,100)
		_:return Rect2(-28,-48,56,96)

func inside_door_trigger(offset: Vector2, side: String) -> bool:
	return door_trigger_rect(side).has_point(offset)

## Some source MAPs carry pathgate y values below the 30-row pass grid (e.g. 492/703).
## Their raw trigger rectangle is therefore unreachable. Keep valid source anchors, and
## snap only invalid ones to the nearest pass cell on the door's own outer edge.
func gate_trigger_has_floor(point: Vector2, side: String) -> bool:
	var grid: Array = room_map.get("walk_grid",[])
	if grid.is_empty():return false
	var constants: Dictionary = map_loader.constants()
	var cw := float(constants["cell_width"])
	var ch := float(constants["cell_height"])
	var trigger := door_trigger_rect(side)
	var min_col := maxi(0,floori((point.x+trigger.position.x)/cw))
	var max_col := mini((grid[0] as Array).size()-1,floori((point.x+trigger.end.x-0.001)/cw))
	var min_row := maxi(0,floori((point.y+trigger.position.y)/ch))
	var max_row := mini(grid.size()-1,floori((point.y+trigger.end.y-0.001)/ch))
	var main_cells := main_walk_cells()
	for row in range(min_row,max_row+1):
		var cells: Array = grid[row]
		for col in range(min_col,mini(max_col,cells.size()-1)+1):
			if not main_cells.has(Vector2i(col,row)):continue
			var center := Vector2((float(col)+0.5)*cw,(float(row)+0.5)*ch)
			if inside_door_trigger(center-point,side):return true
	return false

func nearest_walkable_gate_point(point: Vector2, side: String) -> Vector2:
	var grid: Array = room_map.get("walk_grid",[])
	if grid.is_empty():return Vector2.INF
	var constants: Dictionary = map_loader.constants()
	var cw := float(constants["cell_width"])
	var ch := float(constants["cell_height"])
	var target := point
	match side:
		"left":target.x = 0.0
		"right":target.x = float((grid[0] as Array).size())*cw
		"up":target.y = 0.0
		"down":target.y = float(grid.size())*ch
	var best := Vector2.INF
	var best_distance := INF
	for cell: Vector2i in main_walk_cells():
		var candidate := Vector2((float(cell.x)+0.5)*cw,(float(cell.y)+0.5)*ch)
		var distance := candidate.distance_squared_to(target)
		if distance < best_distance:
			best_distance = distance
			best = candidate
	return best

func normalized_gate_anchor(placement: Dictionary, side: String) -> Vector2:
	for gate: Dictionary in placement.get("gates",[]):
		if String(gate.get("direction","")) != side:continue
		var anchor = gate.get("anchor")
		if not anchor is Array or anchor.size() < 2:return Vector2.INF
		var source := Vector2(float(anchor[0]),float(anchor[1]))
		if gate_trigger_has_floor(source,side):return source
		var adapted := nearest_walkable_gate_point(source,side)
		if not adapted.is_finite():return Vector2.INF
		gate["anchor"] = [adapted.x,adapted.y,float(anchor[2]) if anchor.size() > 2 else 0.0]
		gate["anchor_adaptation"] = "E-ADAPT: source pathgate outside pass grid; snapped to nearest walkable cell"
		return adapted
	return Vector2.INF

## Nearest walkable ground point (spawn anchors may sit on a blocked cell edge).
func constrain_pos(value: Vector2) -> Vector2:
	if walkable(value):return value
	for r in range(4,200,4):
		for d: Vector2 in [Vector2(0,r),Vector2(0,-r),Vector2(r,0),Vector2(-r,0),Vector2(r,r),Vector2(-r,r),Vector2(r,-r),Vector2(-r,-r)]:
			if walkable(value+d):return value+d
	return value

func move_in_world(from: Vector2,delta: Vector2) -> Vector2:
	var result := from
	if walkable(from+Vector2(delta.x,0)):result = from+Vector2(delta.x,0)
	if walkable(result+Vector2(0,delta.y)):result += Vector2(0,delta.y)
	return result

func move_player(delta: Vector2) -> void:
	player["pos"] = move_in_world(player["pos"],delta)

func move_along_ground_pixels(dx: float) -> void:
	var pos: Vector2 = player["pos"]
	var x := roundi(pos.x)
	var target_x := roundi(pos.x+dx)
	var direction := signi(target_x-x)
	var row := roundi(pos.y)
	# 8A8C20 tests each rounded pixel and 8A8D63 restores the last clear one.
	while x != target_x:
		if not walkable(Vector2(x+direction,row)):
			player["pos"] = Vector2(x,pos.y)
			return
		x += direction
	player["pos"] = Vector2(pos.x+dx,pos.y)

func load_room(index: int, from_side: String) -> void:
	clear_monsters()
	objects.clear()
	native_zealot_summons.proxies.clear()
	native_jar_traps.clear(self)
	update_khazan_aura()
	leave_action()
	room_index = index
	room_id = "%s:%d"%[dungeon_id,index]
	bar_target = -1
	doors.clear()
	var placement := room_placement(index)
	room_map = map_loader.room(String(placement["map"]))
	room_width = float(room_map["width"])
	_walk_component_ready = false
	_walk_main_cells.clear()
	var saved: Dictionary = room_snapshots.get(index,{})
	if native_maze != null:
		for gate: Dictionary in placement["gates"]:
			if gate["target_cell"] == null:continue
			var side := String(gate["direction"])
			doors.append({"side":side,"target_cell":gate["target_cell"],"pos":door_point(side)})
		room_cleared = bool(native_room["cleared"])
		props = saved["props"].duplicate(true) if saved.has("props") else build_props(room_map)
		if not _muted:view.audio.play_dungeon_music(dungeon_id,route_boss_room(),native_bgm_volume_db)
	else:
		if index>0:
			var back := String(OPPOSITE[String(rules["rooms"][index-1]["next"])])
			doors.append({"side":back,"to":index-1,"pos":door_point(back)})
		if index<rules["rooms"].size()-1:
			var next_side: String = rules["rooms"][index]["next"]
			doors.append({"side":next_side,"to":index+1,"pos":door_point(next_side)})
		room_cleared = bool(saved.get("cleared",false))
		props = build_props(room_map)
	# props 由地图静态美术承载（native_map_loader 已画），这里不再交给视图二次渲染；
	# 破坏时用 combat.prop_broken 按 prop_node 下标隐藏对应节点。
	bus.emit("combat.room_loaded",{"room_index":index,"room_id":room_id,"placement":String(placement["id"]),"props":[]})
	if native_maze != null:native_jar_traps.restore_room(self,saved.get("jar_traps",[]))
	# Dungeon entry: centre of the map's own [dungeon start area]; doors spawn beside the paired gate.
	var spawn := Vector2(room_width-160,250)
	var area = room_map.get("start_area")
	if area is Array and area.size() == 4:spawn = Vector2(float(area[0])+float(area[2])/2,float(area[1])+float(area[3])/2)
	var visible_entry = placement.get("spawn_override")
	if visible_entry is Array and visible_entry.size() == 2:spawn = Vector2(float(visible_entry[0]),float(visible_entry[1]))
	if OPPOSITE.has(from_side):
		var side: String = OPPOSITE[from_side]
		spawn = door_point(side)+{"left":Vector2(48,0),"right":Vector2(-48,0),"up":Vector2(0,36),"down":Vector2(0,-36)}[side]
	player["pos"] = constrain_pos(spawn)
	player["z"] = 0.0
	player["vz"] = 0.0
	player.erase("starfish_fall_gravity")
	player.erase("thirst_idle_origin_ms")
	player["state"] = "idle"
	player["action"] = ""
	player["stuck_ms"] = 0.0
	player["push_ms"] = 0.0
	player["invuln_ms"] = 700.0
	door_lock_ms = 700.0
	if not room_cleared:
		for m: Dictionary in room_map["monsters"]:
			var mob := String(m["mob"])
			var kind: String = table.monster_by_mob(mob)
			if kind == "":continue
			var anchor: Array = m["anchor"]
			var source: Dictionary = {}
			if native_maze != null and mob in NativeZealotSummons.CASTERS:
				# The ordinary MAP row uses a level relative to the DGN basis.
				var raw: Array = m["raw"]
				var level := int(raw[2])+(native_maze.basis_level if int(raw[1]) != 0 else 0)
				source["level"] = clampi(level,1,200)
			spawn_enemy(Vector2(float(anchor[0]),float(anchor[1])),String(m["raw"][-1]) == "[boss]",kind,source)
	place_room_companions()
	notice(route_room_name()+(" · 领主出现" if route_boss_room() else ""))

## Gate anchor of the current room on the given side (placement gate, else map pathgate).
func door_point(side: String) -> Vector2:
	if room_map.is_empty():return Vector2.ZERO
	var adapted := normalized_gate_anchor(room_placement(room_index),side)
	if adapted.is_finite():return adapted
	var p = room_map["pathgate_pos"].get(side)
	return Vector2(float(p[0]),float(p[1])) if p != null else Vector2.ZERO

## HP and attack are the adapt bases scaled by the MOB [ability category] percentages.
func spawn_enemy(point: Vector2, chief := false, kind := "goblin", reserved := {}) -> Dictionary:
	var m: Dictionary = table.monsters[kind]
	var base: Dictionary = rules["monster_base"]
	var hp := float(m["hp"])*(float(base["boss_hp_scale"]) if chief else 1.0)
	var spawn := point if reserved.has("summon_owner") else constrain_pos(point)
	var enemy := {"id":int(reserved.get("id",_next_entity_id)),"kind":kind,"def":m,"mob":m["mob"],"pos":spawn,"z":float(reserved.get("z",0.0)),"vz":0.0,
		"facing":int(reserved.get("facing",-1)),"state":"idle","clock":0.0,"hp":hp,"max_hp":hp,"chief":chief,
		"attack":float(m["attack"])*(float(base["boss_attack_scale"]) if chief else 1.0),
		"stun_ms":0.0,"push_v":0.0,"push_ms":0.0,"hit_motion":"damage1","bounced":false,"down_ms":0.0,"stuck_ms":0.0,
		"flash_ms":0.0,"cooldown_ms":500.0,"hits":{},"thrown":false,"death_ms":0.0,"ai":true,
		"skill_cd":{}}
	if reserved.has("level"):
		enemy["source_level"] = int(reserved["level"])
		var launch: Dictionary = reserved.get("launch",{})
		if not launch.is_empty():
			start_native_flight(enemy,launch["z"],launch["velocity"],launch["lift"],NativePotMonsters.GRAVITY)
	if reserved.has("summon_owner"):enemy["summon_owner"] = reserved["summon_owner"]
	if not reserved.has("id"):_next_entity_id += 1
	if numeric_player != null:configure_enemy_numbers(enemy)
	monsters.append(enemy)
	bus.emit("combat.entity_spawned",{"entity_id":enemy["id"],"kind":"monster","appearance":String(m["bank"]),"chief":chief})
	return enemy

func clear_monsters() -> void:
	frenzy_recovery.clear()
	active_effect("frenzy").erase("bleed_targets")
	for enemy: Dictionary in monsters:
		if enemy.has("starfish_capture"):release_starfish_victim(enemy)
		bus.emit("combat.entity_removed",{"entity_id":enemy["id"]})
	monsters.clear()

# ---------------------------------------------------------------- friendly APCs

func can_spawn_companion(entry: Dictionary) -> bool:
	var source_id := int(entry.get("source_id",-1))
	var raw: Array = entry.get("raw",[])
	var anchor: Array = entry.get("anchor",[])
	if raw.size() != 8 or raw[4] != "[character]" or raw[5] != "[normal]" or anchor.size() != 3:return false
	if int(raw[0]) != source_id or raw.slice(1,4) != anchor:return false
	if not _companion_programs.has(source_id):_companion_programs[source_id] = CompanionProgram.load_program(source_id)
	return not _companion_programs[source_id].is_empty() and view.has_companion_appearance(source_id)

func place_room_companions() -> void:
	var placements := {}
	for entry: Dictionary in room_map.get("companions",[]):
		if not can_spawn_companion(entry):continue
		var source_id := int(entry["source_id"])
		placements[source_id] = entry["anchor"]
		if companions.any(func(actor):return int(actor["companion_id"])==source_id):continue
		companions.append(make_companion(source_id,_companion_programs[source_id]))
	for companion: Dictionary in companions:
		if float(companion["hp"])<=0:continue
		var source_id := int(companion["companion_id"])
		var anchor: Array = placements.get(source_id,[])
		# Only the source room gives an APC anchor. Else carry the actor through
		# the gate at the nearest walkable position beside the player.
		companion["pos"] = Vector2(float(anchor[0]),float(anchor[1])) if not anchor.is_empty() else constrain_pos(Vector2(player["pos"])-Vector2(24*int(player["facing"]),0))
		companion["z"] = float(anchor[2]) if not anchor.is_empty() else 0.0
		companion.merge({"state":"idle","action":"","clock":0.0,"vz":0.0,"stuck_ms":0.0,
			"push_ms":0.0,"flash_ms":0.0,"think_ms":0.0,"attack_success":false},true)
		bus.emit("combat.entity_spawned",{"entity_id":companion["id"],"kind":"companion","source_id":source_id})

func make_companion(source_id: int, program: Dictionary) -> Dictionary:
	var config: Dictionary = Numbers.shared_config()
	var numbers: Dictionary = config["base"].duplicate()
	# Until the AIC stat-rate application is decoded, use a separate base actor.
	# The source damage multiplier is explicit and applies to all attack types.
	numbers["hp_max"] = table.player["hp_max"]
	numbers["mp_max"] = table.player["mp_max"]
	numbers["damage_rate"] *= float(program["attack_damage_rate"][0])
	var actor = ActorNumbers.new()
	actor.configure({"numbers":numbers})
	var ranks := {}
	var local_by_source := {}
	for key in ["skill","quick_skill"]:
		var raw: Array = program.get(key,[])
		for i in range(0,raw.size()-1,2):
			var id := int(raw[i])
			var local := String(config["skill_index"].get(str(id),""))
			if local == "" or int(raw[i+1]) <= 0:continue
			ranks[local] = int(raw[i+1])
			local_by_source[id] = local
	var companion := new_player()
	companion.merge({"id":_next_entity_id,"companion_id":source_id,"program":program,"numeric":actor,
		"hp":float(actor.values["hp_max"]),"max_hp":float(actor.values["hp_max"]),"mp":float(actor.values["mp_max"]),
		"attack":float(actor.values["physical_attack"]),"ranks":ranks,"skills":local_by_source,
		"moves":table.companion_moves(ranks,"shortsword"),"death_ms":0.0},true)
	_next_entity_id += 1
	return companion

func living_companion_ids() -> Array[int]:
	var ids: Array[int] = []
	for companion: Dictionary in companions:
		if float(companion["hp"])>0:ids.append(int(companion["companion_id"]))
	ids.sort()
	return ids

func companion_views() -> Array:
	var result: Array = []
	for companion: Dictionary in companions:
		result.append({"id":companion["id"],"source_id":companion["companion_id"],"pos":Vector2(companion["pos"]),
			"hp":float(companion["hp"]),"max_hp":float(companion["max_hp"]),"alive":float(companion["hp"])>0})
	return result

func report_companion_defeat(companion: Dictionary) -> void:
	if companion.get("defeat_reported",false):return
	companion["defeat_reported"] = true
	bus.emit("combat.companion_defeated",flow_payload({"entity_id":companion["id"],
		"source_id":companion["companion_id"],"source_map_id":int(room_map.get("map_id",-1))}))

func update_companion(companion: Dictionary, ms: float) -> void:
	if float(companion["hp"])<=0:
		companion["death_ms"] = float(companion["death_ms"])+ms
		return
	var actor = companion["numeric"]
	step_numeric_actor(companion,actor,ms)
	if float(companion["hp"])<=0:return
	var cd: Dictionary = companion["cooldowns"]
	for skill: String in cd:cd[skill] = maxf(0.0,float(cd[skill])-ms)
	companion["mp"] = minf(float(actor.values["mp_max"]),float(companion["mp"])+ms*float(actor.values["mp_regen"])/1000.0)
	companion["flash_ms"] = maxf(0.0,float(companion["flash_ms"])-ms)
	if float(companion["stuck_ms"])>0:
		companion["stuck_ms"] = maxf(0.0,float(companion["stuck_ms"])-ms)
		return
	var state := String(companion["state"])
	if actor.effects.controlled() or state in ["hurt","air","down"]:
		Kernel.Reaction.step_body(companion,ms,float(rules["player"]["gravity"]),rules["reaction"],move_in_world)
		if state=="down":companion["clock"] = float(companion["down_ms"])
		return
	if state=="action":
		step_companion_action(companion,ms)
		return
	var program: Dictionary = companion["program"]
	var origin: Vector2 = companion["pos"]
	var target := nearest_living(origin,monsters)
	if not target.is_empty() and CompanionProgram.target_distance(origin,target["pos"])>float(program["vision"][0]):target = {}
	var goal := Vector2(player["pos"]) if target.is_empty() else Vector2(target["pos"])
	var offset := goal-origin
	if offset.x != 0.0:companion["facing"] = 1 if offset.x > 0.0 else -1
	companion["think_ms"] = float(companion["think_ms"])-ms
	if float(companion["think_ms"])<=0.0:
		companion["think_ms"] = float(program["think_term"][0])
		if not target.is_empty() and choose_companion_action(companion,target):return
	var keep := float(program["keep_distance_with_target"][0])
	var move := Vector2(signf(offset.x) if absf(offset.x)>keep else 0.0,signf(offset.y) if absf(offset.y)>8.0 else 0.0)
	if not move.is_zero_approx():
		var speed := float(rules["player"]["walk_speed"])*float(actor.values["move_speed"])*ms/1000.0
		companion["pos"] = move_in_world(origin,Vector2(move.x,move.y*float(rules["units"]["depth_speed_ratio"]))*speed)
		companion["state"] = "move"
	else:companion["state"] = "idle"
	companion["clock"] = float(companion["clock"])+ms if state==companion["state"] else 0.0

func choose_companion_action(companion: Dictionary, target: Dictionary) -> bool:
	var program: Dictionary = companion["program"]
	var actor = companion["numeric"]
	var usable := {}
	var active := {}
	for source_id: int in companion["skills"]:
		var id: String = companion["skills"][source_id]
		var move: Dictionary = companion["moves"].get(id,{})
		if move.is_empty():continue
		var effect := String(move.get("effect_id",""))
		if effect != "":active[source_id] = actor.effects.active.has(effect)
		var required := String(move.get("requires_effect",""))
		usable[source_id] = float(companion["cooldowns"].get(id,0))<=0.0 \
			and float(companion["mp"])>=float(move["mp"])*float(actor.values["mp_cost_rate"]) \
			and (required == "" or actor.effects.active.has(required))
	var context := {"position":companion["pos"],"target_position":target["pos"],"facing":companion["facing"],
		"usable":usable,"skill_on":active,"last_attack":int(companion.get("last_attack",-1)),
		"attack_success":bool(companion["attack_success"]),"target_state":4 if target["state"]=="down" else -1}
	companion["attack_success"] = false
	for entry in ["event","action"]:
		var stream = CompanionProgram.choose(program,entry,context)
		# The original combo stream waits for an ordinary three-hit chain.
		if not stream is String or stream == "cancel_wave_combo":continue
		var source_id := CompanionProgram.stream_skill(program,stream)
		if not usable.get(source_id,false):continue
		var id: String = companion["skills"][source_id]
		var move: Dictionary = companion["moves"][id]
		companion["state"] = "action"
		companion["action"] = id
		companion["clock"] = 0.0
		companion["hits"] = {}
		companion["mp"] = float(companion["mp"])-float(move["mp"])*float(actor.values["mp_cost_rate"])
		companion["cooldowns"][id] = float(move["cool_ms"])*float(actor.values["cooldown_rate"])
		companion["native_phase"] = Kernel.NativeWave.plan(move,float(actor.values["attack_speed"]),float(actor.values["cast_speed"])) \
			if move.get("native_state","") in ["normalwave","wave_cast"] else {}
		companion["action_instance"] = int(companion.get("action_instance",0))+1
		bus.emit("combat.action_started",{"entity_id":companion["id"],"action":id,"instance":companion["action_instance"]})
		var effect := String(move.get("effect_id",""))
		if effect != "":actor.add_effect(effect,int(companion["ranks"][id]))
		companion_action_events(companion,move,-1.0,0.0)
		return true
	return false

func step_companion_action(companion: Dictionary, ms: float) -> void:
	var id: String = companion["action"]
	var move: Dictionary = companion["moves"][id]
	var phase: Dictionary = companion["native_phase"]
	var actor = companion["numeric"]
	var old_t := float(companion["clock"])
	var speed_kind := String(Numbers.shared_config()["skills"].get(id,{}).get("speed","attack"))
	var speed := float(actor.values["cast_speed" if speed_kind=="cast" else "attack_speed"])
	var t := old_t+ms*(speed if phase.is_empty() else 1.0)
	companion["clock"] = t
	if not phase.is_empty():
		var dx := Kernel.NativeWave.distance(phase,t)-Kernel.NativeWave.distance(phase,old_t)
		if dx != 0.0:companion["pos"] = move_in_world(companion["pos"],Vector2(dx*int(companion["facing"]),0))
	companion_action_events(companion,move,companion_action_clock(companion,old_t),companion_action_clock(companion,t))
	var duration := float(move["duration"] if phase.is_empty() else phase["end_ms"])
	if t >= duration:
		companion["state"] = "idle"
		companion["action"] = ""
		companion["clock"] = 0.0

func companion_action_clock(companion: Dictionary, time: float) -> float:
	var phase: Dictionary = companion.get("native_phase",{})
	return time if phase.is_empty() else Kernel.NativeWave.ani_clock(phase,time)

func companion_action_events(companion: Dictionary, move: Dictionary, old_t: float, t: float) -> void:
	var point: Vector2 = companion["pos"]
	var z := float(companion["z"])
	var facing := int(companion["facing"])
	for fx: Dictionary in move["fx"]:
		var at := float(fx["at"])
		if at > old_t and at <= t:
			bus.emit("combat.cue",{"kind":"fx","key":fx["key"],"point":point,"height":z,"facing":facing,
				"follow":companion["id"],"offset_x":float(fx.get("offset_x",0)),"action_instance":companion["action_instance"],
				"action_clock_at":at if fx.get("action_clock",false) else -1.0})
	var hits: Array = move["hits"]
	for i in hits.size():
		var hit: Dictionary = hits[i]
		if hit["kind"] == "object":
			if float(hit["at"]) > old_t and float(hit["at"]) <= t:
				spawn_object(hit,"companion",point,z,facing,float(companion["attack"]),companion)
			continue
		for s in hit["segments"].size():
			var boxes: Array = Kernel.Timeline.segment_boxes(hit["segments"][s],old_t,t)
			if boxes.is_empty():continue
			var world: Array = Kernel.HitJudge.world_boxes(boxes,Kernel.HitJudge.anchor(point,z),facing)
			for enemy: Dictionary in monsters:
				var key := "%d:%d:%d"%[i,s,int(enemy["id"])]
				if float(enemy["hp"])<=0.0 or companion["hits"].has(key):continue
				var contact: Dictionary = Kernel.HitJudge.contact(world,enemy_damage_boxes(enemy))
				if contact.is_empty():continue
				companion["hits"][key] = true
				land_hit(companion,enemy,hit,contact["point"],facing,float(companion["attack"]))

func companion_ani(companion: Dictionary) -> Array:
	match String(companion["state"]):
		"action":
			var move: Dictionary = companion["moves"][companion["action"]]
			return [move["ani"],companion_action_clock(companion,float(companion["clock"]))]
		"hurt":return [companion["hit_motion"],0.0]
		"air":return ["overturn",0.0]
		"down","dead":return ["down",Kernel.Reaction.down_clock(companion,rules["reaction"],table.player_timeline("down"))]
		"move":return ["move",float(companion["clock"])]
	return ["stay",float(companion["clock"])]

# ---------------------------------------------------------------- presentation state

func player_ani() -> Array:
	var state: String = player["state"]
	var rp: Dictionary = rules["reaction"]
	if state=="action":
		var m := move_def(String(player["action"]))
		var elapsed := float(player["clock"])
		var phase: Dictionary = player.get("native_phase",{})
		if phase.has("charge_rate") and elapsed < float(phase["wait_ms"]):
			return [String(m["native_charge_ani"]),action_ani_clock(elapsed)]
		return [String(action_def()["ani"]),action_ani_clock(elapsed)]
	if state=="dead":return ["down",float(table.player_timeline("down")[2]["start_ms"]) if table.player_timeline("down").size()>2 else 0.0]
	if state=="hold":return ["damage1",0.0]
	if state=="hurt":return [String(player["hit_motion"]),0.0]
	if state=="air":return ["overturn",0.0]
	if state=="down":return ["down",Kernel.Reaction.down_clock(player,rp,table.player_timeline("down"))]
	if state=="guard":
		var timeline := table.player_timeline("guard")
		# Native guard state 0x13 seeks frame 0 while holding and frame 1 on recoil.
		var recoil_clock := float(timeline[1]["start_ms"]) if timeline.size()>1 and float(player["guard_recoil_ms"])>0.0 else 0.0
		return ["guard",recoil_clock]
	if state=="backstep":return ["jump",minf(float(player["clock"]),600) if float(player["vz"])>=0 else 10680.0]
	if float(player["z"])>0:return ["jump",minf(float(player["air_ms"]),600) if float(player["vz"])>=0 else 10680.0]
	if float(player["landing_ms"])>0:return ["sit",0.0]
	if state=="move":return ["dash" if run_direction!=0 else "move",float(player["motion_clock"])]
	if not active_effect("thirst").is_empty():
		# C9FAB0/C9FAF0 select CHR ETC slot 0x72 for both waiting getters.
		var idle := String(move_def("sacrifice").get("active_idle_ani",""))
		if idle != "":
			var elapsed := float(player["motion_clock"])-float(player.get("thirst_idle_origin_ms",player["motion_clock"]))
			var duration := Kernel.Timeline.duration(table.player_timeline(idle))
			return [idle,fposmod(elapsed,maxf(1.0,duration))]
	return ["stay",float(player["motion_clock"])]

func enemy_ani(enemy: Dictionary) -> Array:
	var m: Dictionary = enemy["def"]
	var rp: Dictionary = rules["reaction"]
	match String(enemy["state"]):
		"move":return ["move",float(enemy["clock"])]
		"native_suicide":return [m["native_suicide"]["pose"],float(enemy["clock"])]
		NativeZealotSummons.CAST_STATE:return ["cast",float(enemy["clock"])]
		"attack":
			var bite_phase := String(enemy.get("starfish_bite_phase",""))
			if bite_phase in ["bite","release"]:
				return [m["native_starfish_bite"][bite_phase+"_pose"],float(enemy["clock"])]
			var phase := String(enemy.get("starfish_phase",""))
			if phase != "":
				var jump: Dictionary = m["native_starfish_jump"]
				var age := float(enemy["clock"])
				if phase == "rolling":age = fposmod(age,Kernel.Timeline.duration(jump["rolling_timeline"]))
				return [jump[phase+"_pose"],age]
			# BOSS 多招：播放这一刀选中的招式 ANI（stem 来自 .mob 的 [attack motion]）。
			var moves: Array = m.get("moves", [])
			var pick := int(enemy.get("move_index", -1))
			if pick >= 0 and pick < moves.size():return [String(moves[pick]["stem"]).to_lower(), float(enemy["clock"])]
			return ["attack",float(enemy["clock"])]
		"hurt":return [String(enemy["hit_motion"]),0.0]
		"air":return ["overturn",0.0]
		"down":return ["down",Kernel.Reaction.down_clock(enemy,rp,table.monster_timeline(m,"down"))]
		"dead":
			if String((m.get("motions", {}) as Dictionary).get("die", "")) != "":
				return ["die", float(enemy["death_ms"])]
			var tl: Array = table.monster_timeline(m,"down")
			if float(enemy["z"])>0:return ["overturn",0.0]
			return ["down",(float(tl[2]["start_ms"]) if tl.size()>2 else 0.0)+minf(float(enemy["death_ms"]),1.0)]
	return ["stay",float(enemy["clock"])]

func skill_bar() -> Array:
	var out: Array = []
	for code: int in SKILL_SLOT_KEYS:
		var name: String = String(skill_slots[SKILL_SLOT_KEYS.find(code)])
		out.append({"name":name,"label":String(move_def(name).get("label","")),"key":OS.get_keycode_string(code),
			"cooldown":float(player["cooldowns"].get(name,0)),"mp":float(move_def(name).get("mp",0))})
	return out

## Top HP bar subject: the monster the player hit last; a living boss otherwise.
func monster_bar() -> Dictionary:
	var pick: Dictionary = {}
	for enemy: Dictionary in monsters:
		if int(enemy["id"]) == bar_target:pick = enemy
	if pick.is_empty() or (float(pick["hp"]) <= 0 and float(pick["death_ms"]) > 800):
		pick = {}
		for enemy: Dictionary in monsters:
			if enemy["chief"] and float(enemy["hp"]) > 0:pick = enemy
	if pick.is_empty():return {}
	var m: Dictionary = pick["def"]
	return {"id":pick["id"],"mob":String(pick["mob"]),"name":String(m["name"]),"level":int(pick["numeric"].values["level"]) if pick.has("numeric") else int(m["level"]),
		"rank":"boss" if pick["chief"] else "normal","hp":float(pick["hp"]),"max_hp":float(pick["max_hp"]),
		"lines":int(rules["boss_hp_lines"]) if pick["chief"] else 1}

## Read-only per-tick state for view/ and ui/combat/ (contract doc 29 section 4). Values only.
func view_snapshot() -> Dictionary:
	var ani := player_ani()
	var enemies: Array = []
	var alive := 0
	for enemy: Dictionary in monsters:
		var e_ani := enemy_ani(enemy)
		var is_alive := float(enemy["hp"])>0
		if is_alive:alive += 1
		var casting: bool = is_alive and enemy["state"] == NativeZealotSummons.CAST_STATE
		enemies.append({"id":enemy["id"],"pos":Vector2(enemy["pos"]),"z":float(enemy["z"]),"facing":int(enemy["facing"]),
			"ani":String(enemy["def"]["motions"].get(e_ani[0],e_ani[0])),"clock":e_ani[1],"flash":float(enemy["flash_ms"])>0,"alive":is_alive,
			"death_ms":float(enemy["death_ms"]),"hp_ratio":float(enemy["hp"])/float(enemy["max_hp"]),"chief":enemy["chief"],
			"mob":enemy["mob"],"blind":is_alive and enemy.has("numeric") and enemy["numeric"].effects.active.has("blind"),
			"sleep_ms":enemy["numeric"].sleep_age() if is_alive and enemy.has("numeric") and enemy["state"]=="down" else -1.0,
			"cast_layers":enemy["def"]["native_spirit_summon"]["cast_layers"] if casting else [],
			"poison":enemy["numeric"].effects.poison_visual() if is_alive and enemy.has("numeric") else 0})
	var friendly: Array = []
	for companion: Dictionary in companions:
		var current := companion_ani(companion)
		friendly.append({"id":companion["id"],"pos":Vector2(companion["pos"]),"z":float(companion["z"]),
			"facing":int(companion["facing"]),"ani":String(current[0]),"clock":float(current[1]),"state":companion["state"],
			"action_instance":int(companion.get("action_instance",-1)),"flash":float(companion["flash_ms"])>0,
			"alive":float(companion["hp"])>0,"death_ms":float(companion["death_ms"]),
			"poison":companion["numeric"].effects.poison_visual() if float(companion["hp"])>0 else 0})
	var objs: Array = []
	for o: Dictionary in objects:
		var controller: Dictionary = o["hit"].get("native_controller",{})
		var bank := String(o["def"]["bank"])
		if bank == "" and controller.get("kind","") != "bloodblast":continue
		var item := {"id":o["id"],"bank":bank,"rear_fx":String(o["hit"].get("rear_fx","")),"pos":Vector2(o["pos"]),"z":float(o["z"]),"facing":int(o["facing"]),"clock":object_view_clock(o),"size_rate":float(o.get("size_rate",1)),"loop":float(o["life_ms"])>0}
		if controller.get("kind","") in GHOST_FIELD_KINDS:
			objs.append_array(_ghost_field_layers(item,controller,float(o["exit_at_ms"])))
		elif controller.get("kind","") == "sayaex_ice":
			var phase := String(o["crystal_phase"])
			item["clock"] = float(o["clock"])-float(o["crystal_phase_at"])
			item["loop"] = phase == "ready"
			if phase == "ready":item["clock"] += float(o["crystal_ready_offset"])
			else:
				item["id"] = "%s:%s"%[o["id"],phase]
				item["effect"] = controller["layers"][phase]
			objs.append(item)
		elif controller.get("kind","") == "rasa_child":
			objs.append_array(_rasa_child_layers(item,o,controller))
		elif controller.get("kind","") in ["bloodblast","thirst_burst"]:
			item["depth_offset"] = -1
			if bank != "":objs.append(item)
			var layers: Array = controller["layers"]
			for index in layers.size():
				var effect_key := String(layers[index])
				if float(item["clock"]) >= float(combat_assets["effects"][effect_key]["duration_ms"]):continue
				var layer := item.duplicate()
				layer["id"] = "%s:layer:%s" % [o["id"],index]
				layer["effect"] = effect_key
				layer["depth_offset"] = 1 if bank != "" else -1
				objs.append(layer)
			# ALS order is internal to the main ANI. Every layer uses the same
			# world depth; source order breaks ties between the attached sprites.
			for attachment: Dictionary in controller.get("ani_layers",[]):
				var age := float(item["clock"])-float(attachment["at_ms"])
				var effect_key := String(attachment["effect"])
				if age < 0.0 or age >= float(combat_assets["effects"][effect_key]["duration_ms"]):continue
				var layer := item.duplicate()
				layer["id"] = "%s:ani:%d" % [o["id"],int(attachment["order"])]
				layer["effect"] = effect_key
				layer["clock"] = age
				layer["depth_offset"] = 0
				objs.append(layer)
		else:
			objs.append(item)
	if native_maze != null:objs.append_array(native_jar_traps.view_objects(self))
	objs.append_array(native_zealot_summons.view_objects())
	objs.append_array(frenzy_recovery.view_objects(self))
	var route: Array = native_maze.route_view() if native_maze != null else []
	if native_maze == null:
		for i in rules["rooms"].size():
			var room: Dictionary = rules["rooms"][i]
			route.append({"cell":room_placement(i).get("cell",[0,0]),"visited":room_snapshots.has(i),"current":i==room_index,"boss":bool(room.get("boss",false))})
	var placement_id := String(native_room["placement"]["id"]) if native_maze != null else String(rules["rooms"][room_index]["placement"])
	var open := room_is_open(alive)
	var stage_info := {"room_index":room_index,"placement":placement_id,
		"cleared":open and not route_boss_room(),"doors":doors.duplicate(true)}
	if native_maze != null:
		stage_info["resolved_placement"] = native_room["placement"]
		stage_info["broken_props"] = props.filter(func(prop):return prop.get("broken",false)).map(func(prop):return int(prop["node"]))
	var buff_active: bool = float(player["buff_ms"])>0 or (numeric_player != null and numeric_player.effects.active.has("frenzy"))
	var overdrive := active_effect("overdrive")
	var overdrive_age_ms := -1.0
	if not overdrive.is_empty() and float(player["hp"]) > 0.0:
		overdrive_age_ms = float(overdrive["definition"]["duration_ms"])-float(overdrive["remaining_ms"])
	var thirst := active_effect("thirst")
	if not thirst.is_empty() and float(player["hp"]) > 0.0:
		# CA06CC draws its own GiveBloodStay ANI as long as the appendage is valid.
		var age := float(thirst["definition"]["duration_ms"])-float(thirst["remaining_ms"])
		objs.append({"id":"player:thirst","effect":move_def("sacrifice")["cast_fx"],
			"pos":Vector2(player["pos"]),"z":float(player["z"]),"facing":int(player["facing"]),
			"clock":age,"loop":true,"depth_offset":1})
	return {"frame":_frame,"paused":paused,"status_clock_ms":native_jar_traps.clock_ms,
		"player":{"id":PLAYER_ID,"pos":Vector2(player["pos"]),"z":float(player["z"]),"state":String(player["state"]),"action":String(player["action"]),
			"facing":int(player["facing"]),"ani":ani[0],"clock":ani[1],"action_instance":action_seq,
			"fx_clock":player.get("draw_charge",{}).get("fx_clock",ani[1]),
			"flash":float(player["flash_ms"])>0,"buff":buff_active,"weapon":weapon,
			"jar_invincible":native_jar_traps.player_protected,
			"poison":numeric_player.effects.poison_visual() if float(player["hp"])>0 and numeric_player != null else 0,
			"overdrive_age_ms":overdrive_age_ms,
			"aura":String(move_def("buff").get("aura_fx","")) if buff_active else ""},
		"enemies":enemies,"companions":friendly,"objects":objs,"props":props_view(),
		"stage":stage_info,
		"hud":{"room_name":route_room_name(),"alive":alive,"room_cleared":open,
			"route":route,"combo":combo_count,"toast":toast,"toast_ms":toast_ms,"skills":skill_bar(),"monster_bar":monster_bar(),
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
