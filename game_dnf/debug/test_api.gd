extends RefCounted
## The only place tests may touch combat internals. When the kernel is replaced (F1~F3),
## this facade is remapped and the test scripts stay unchanged.

var game

func _init(target) -> void:
	game = target

# --- content / resources ---
func manifest_schema() -> String:return String(game.assets.get("schema",""))
func content():return game.content
func clip(name: String) -> Dictionary:return game.player_clips.get(name,{})
func room_count() -> int:return game.rules["rooms"].size()
func room_next(index: int) -> String:return String(game.rules["rooms"][index]["next"])

# --- session / lifecycle ---
func session():return game.session
func bus():return game.bus
func restart() -> void:game.restart()
func set_god(enabled: bool) -> void:game.god_mode = enabled
func finished() -> bool:return game.finished
func victory() -> bool:return game.victory
func paused() -> bool:return game.paused
func set_paused(value: bool) -> void:game.paused = value
func elapsed_ms() -> float:return float(game.elapsed_ms)
func capture(name: String) -> void:await game.capture_frame(name)

# --- player ---
func p(key: String):return game.player[key]
func set_p(key: String, value) -> void:game.player[key] = value
func cooldown(name: String) -> float:return float(game.player["cooldowns"].get(name,0))
func start_action(name: String, cancel := false) -> bool:return game.start_action(name,cancel)
func damage_player(amount: float, source: Vector2) -> void:game.damage_player(amount,source)
func job() -> String:return game.job
func set_job(value: String) -> void:game.job = value
func weapon() -> String:return game.weapon
func view_texture() -> String:return String(game.view.player_actor.bank["texture"])
func view_pose() -> String:return game.view.player_actor.pose
func run_direction() -> int:return game.run_direction
func clear_direction_taps() -> void:game.last_direction_tap.clear()
func set_hitstop(ms: float) -> void:game.hitstop_ms = ms

# --- combat bookkeeping ---
func hit_count() -> int:return game.hit_count
func combo_count() -> int:return game.combo_count
func effect_count() -> int:return game.view.effects.size()

# --- monsters ---
## Replaces all monsters with one durable dummy and returns its opaque handle.
func spawn_dummy(point: Vector2) -> Dictionary:
	game.clear_monsters()
	var enemy: Dictionary = game.spawn_enemy(point)
	enemy["hp"] = 5000.0
	enemy["max_hp"] = 5000.0
	enemy["state"] = "hurt"
	enemy["hurt_ms"] = 100000.0
	return enemy
func e(handle: Dictionary, key: String):return handle[key]
func set_e(handle: Dictionary, key: String, value) -> void:handle[key] = value
func monster_count() -> int:return game.monsters.size()
func monster(index: int, key: String):return game.monsters[index][key]
func kill_all_monsters() -> void:
	for enemy: Dictionary in game.monsters:
		enemy["hp"] = 0
		enemy["death_ms"] = 800.0

# --- rooms / world ---
func room_index() -> int:return game.room_index
func room_cleared() -> bool:return game.room_cleared
func stage_cleared() -> bool:return game.view.stage.cleared
func load_room(index: int, side: String) -> void:game.load_room(index,side)
func door_point(side: String) -> Vector2:return game.door_point(side)
func unlock_doors() -> void:game.door_lock_ms = 0.0
func prop(index: int, key: String):return game.props[index][key]
func set_prop(index: int, key: String, value) -> void:game.props[index][key] = value
func prop_view_z(index: int) -> int:return game.view.prop_views[index].z_index
func move_in_world(from: Vector2, delta: Vector2) -> Vector2:return game.move_in_world(from,delta)

# --- presentation trace (headless equivalence checks; no window needed) ---
const ActorScript = preload("res://view/actor_view.gd")
const EffectScript = preload("res://view/fx_view.gd")
const PropScript = preload("res://scripts/native_prop.gd")

func presentation_state() -> Dictionary:
	var nodes: Array = []
	for child in game.view.world.get_children():
		if child.is_queued_for_deletion() or child == game.view.stage:continue
		var s = child.get_script()
		var base := [str(child.position),child.z_index,child.visible]
		if s == ActorScript:
			nodes.append(["actor",base,child.pose,snappedf(child.clock_ms,0.001),child.facing,snappedf(child.height,0.001),child.flash,str(child.tint),child.shadow_width,String(child.bank.get("texture",""))])
		elif s == EffectScript:
			nodes.append(["fx",base,snappedf(child.clock_ms,0.001),String(child.frame.get("sprite","")),child.facing])
		elif s == PropScript:
			nodes.append(["prop",base,String(child.data.get("sprite",""))])
		else:
			nodes.append(["other",base,str(s)])
	var numbers: Array = []
	for n: Dictionary in _numbers():
		numbers.append([str(n["pos"]),n["text"],snappedf(float(n["ms"]),0.001),n["heavy"]])
	return {"world":str(game.view.world.position),"nodes":nodes,"numbers":numbers,"hud":_hud_values(),
		"hud_draw":_hud_trace(),"stage":[game.view.stage.room_index,game.view.stage.cleared,game.view.stage.debug_collision,str(game.view.stage.doors)]}

func _hud_trace() -> Array:
	return game.view.hud.trace.duplicate()

func _numbers() -> Array:
	return game.view.numbers

func _hud_values() -> Dictionary:
	if game.player.is_empty():return {}
	var p: Dictionary = game.player
	var bars: Array = []
	var alive := 0
	for enemy: Dictionary in game.monsters:
		if float(enemy["hp"])<=0:continue
		alive += 1
		bars.append([str(enemy["pos"]),snappedf(float(enemy["z"]),0.001),snappedf(float(enemy["hp"])/float(enemy["max_hp"]),0.0001),enemy["chief"]])
	var skills: Array = ["upper","buff","rage_slash"] if game.job=="berserker" else ["upper","draw","thrust"]
	var cds: Array = []
	for name: String in skills:
		var cd := float(p["cooldowns"].get(name,0))
		cds.append("%.1f"%cd if cd>0 else "")
	var route: Array = []
	for i in game.rules["rooms"].size():
		route.append([game.room_snapshots.has(i),i==game.room_index,bool(game.rules["rooms"][i].get("boss",false))])
	return {"combo":game.combo_count,"toast":game.toast if game.toast_ms>0 else "","bars":bars,
		"hp":int(p["hp"]),"mp":int(p["mp"]),"hp_fill":snappedf(float(p["hp"])/float(game.rules["player"]["hp"]),0.0001),
		"mp_fill":snappedf(float(p["mp"])/float(game.rules["player"]["mp"]),0.0001),"job":game.job,"weapon":game.weapon,
		"buff":"%.1f"%(float(p["buff_ms"])/1000) if float(p["buff_ms"])>0 else "","cds":cds,
		"room":[String(game.rules["rooms"][game.room_index]["name"]),alive,game.room_cleared],"route":route,
		"overlay":[game.finished and not game.external_mode,game.victory,game.damage_taken,"%.1f"%(game.elapsed_ms/1000),game.paused,game.help_visible]}
