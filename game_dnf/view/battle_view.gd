extends Node2D
## Battle presentation root (L4). Reads the per-tick snapshot and combat events only;
## never writes simulation state. Contract: docs/design/29_新版工程框架_接口契约.md.
## Every drawn element is an original bank: runtime manifest (players, scene, ui, legacy fx)
## or assets_local/combat (monsters, passive objects, skill/hit effects, digits).
const ActorView = preload("res://view/actor_view.gd")
const FxView = preload("res://view/fx_view.gd")
const AudioRouter = preload("res://view/audio_router.gd")
const CombatHud = preload("res://ui/combat/combat_hud.gd")
# Scene drawing stays with the world side (doc 28); the view only feeds it.
const StageView = preload("res://scripts/native_stage.gd")
const PropView = preload("res://scripts/native_prop.gd")

var world: Node2D
var stage
var player_actor
var hud
var audio
var effects: Array = []
var numbers: Array = []
var prop_views: Array = []
var enemy_actors: Dictionary = {}
var object_views: Dictionary = {}
var aura
var _assets: Dictionary
var _combat: Dictionary
var _effects: Dictionary = {}
var _player_clips: Dictionary
var _weapon := ""
var _stage_key := ""

func setup(assets: Dictionary, combat_assets: Dictionary, player_clips: Dictionary, bus, weapon: String) -> void:
	_assets = assets
	_combat = combat_assets
	_player_clips = player_clips
	_effects = assets.get("effects",{}).duplicate()
	_effects.merge(combat_assets.get("effects",{}),true)
	world = Node2D.new()
	add_child(world)
	stage = StageView.new()
	world.add_child(stage)
	stage.setup(assets["scene"])
	player_actor = ActorView.new()
	world.add_child(player_actor)
	_set_weapon(weapon)
	var layer := CanvasLayer.new()
	add_child(layer)
	hud = CombatHud.new()
	layer.add_child(hud)
	hud.setup(assets["ui"],combat_assets.get("digits",{}))
	audio = AudioRouter.new()
	add_child(audio)
	audio.setup(assets["audio"],combat_assets.get("audio",{}))
	bus.subscribe("combat.cue", _on_cue)
	bus.subscribe("combat.damage", _on_damage)
	bus.subscribe("combat.room_loaded", _on_room_loaded)
	bus.subscribe("combat.entity_spawned", _on_entity_spawned)
	bus.subscribe("combat.entity_removed", _on_entity_removed)
	bus.subscribe("combat.appearance_changed", func(e: Dictionary):
		if int(e["entity_id"])==0 and String(e["weapon"])!=_weapon:_set_weapon(String(e["weapon"])))

func set_debug_collision(enabled: bool) -> void:
	stage.debug_collision = enabled
	stage.queue_redraw()

## frame_ms always elapses (damage numbers); sim_ms is the simulation time actually advanced.
func present(s: Dictionary, frame_ms: float, sim_ms: float) -> void:
	for fx in effects:
		if is_instance_valid(fx) and not fx.is_queued_for_deletion():fx.advance(sim_ms)
	effects = effects.filter(func(fx):return is_instance_valid(fx) and not fx.is_queued_for_deletion())
	_present_stage(s["stage"],s["props"])
	var props: Array = s["props"]
	for i in prop_views.size():
		if is_instance_valid(prop_views[i]) and i < props.size():
			prop_views[i].data = props[i]
			prop_views[i].refresh()
	var p: Dictionary = s["player"]
	if String(p["weapon"]) != _weapon:_set_weapon(String(p["weapon"]))
	player_actor.position = Vector2(p["pos"]).round()
	player_actor.z_index = int(Vector2(p["pos"]).y)
	player_actor.present(p["ani"],p["clock"],p["facing"],p["z"],1.0 if p["flash"] else 0.0)
	_present_aura(String(p.get("aura","")),p,sim_ms)
	for e: Dictionary in s["enemies"]:
		var actor = enemy_actors.get(e["id"])
		if actor == null:continue
		actor.position = Vector2(e["pos"]).round()
		actor.z_index = int(Vector2(e["pos"]).y)
		var alpha := clampf(1.0-(float(e["death_ms"])-400)/400,0,1) if not e["alive"] else 1.0
		actor.present(e["ani"],e["clock"],e["facing"],e["z"],1.0 if e["flash"] else 0.0,Color(1,1,1,alpha))
	_present_objects(s.get("objects",[]))
	world.position = Vector2.ZERO
	for i in range(numbers.size()-1,-1,-1):
		numbers[i]["ms"] = float(numbers[i]["ms"])+frame_ms
		if float(numbers[i]["ms"])>650:numbers.remove_at(i)
	var hud_state: Dictionary = s["hud"].duplicate()
	hud_state["enemies"] = s["enemies"]
	hud_state["numbers"] = numbers
	hud.present(hud_state)

func _set_weapon(weapon: String) -> void:
	_weapon = weapon
	player_actor.setup(_assets["players"][weapon],_player_clips)

func _present_stage(info: Dictionary, props: Array) -> void:
	var broken: Array = props.map(func(p: Dictionary) -> bool: return bool(p.get("broken",false)))
	var key := str([info["room_index"],info["cleared"],info["doors"],broken])
	if key == _stage_key:return
	_stage_key = key
	stage.room_index = info["room_index"]
	stage.cleared = info["cleared"]
	stage.doors = info["doors"]
	stage.props = props
	stage.queue_redraw()

## Frenzy-style auras follow the body and loop the original effect while the buff lasts.
func _present_aura(key: String, p: Dictionary, sim_ms: float) -> void:
	if key == "" or not _effects.has(key):
		if aura != null and is_instance_valid(aura):aura.queue_free()
		aura = null
		return
	if aura == null or not is_instance_valid(aura):
		aura = FxView.new()
		world.add_child(aura)
		aura.setup(_effects[key],int(p["facing"]))
		aura.loop = true
	aura.facing = int(p["facing"])
	aura.position = Vector2(p["pos"]).round()-Vector2(0,float(p["z"]))
	aura.z_index = int(Vector2(p["pos"]).y)+1
	aura.advance(sim_ms)

func _present_objects(list: Array) -> void:
	var live := {}
	for o: Dictionary in list:
		live[o["id"]] = true
		var v = object_views.get(o["id"])
		if v == null:
			var bank: Dictionary = _combat.get("objects",{}).get(String(o["bank"]),{})
			if bank.is_empty():continue
			v = FxView.new()
			world.add_child(v)
			v.setup(bank,int(o["facing"]))
			v.loop = true
			object_views[o["id"]] = v
		v.position = Vector2(o["pos"]).round()-Vector2(0,float(o["z"]))
		v.z_index = int(Vector2(o["pos"]).y)+2
		v.seek(float(o["clock"]))
	for id in object_views.keys():
		if not live.has(id):
			if is_instance_valid(object_views[id]):object_views[id].queue_free()
			object_views.erase(id)

func _on_room_loaded(event: Dictionary) -> void:
	for view in prop_views:
		if is_instance_valid(view):view.queue_free()
	prop_views.clear()
	for actor in enemy_actors.values():
		if is_instance_valid(actor):actor.queue_free()
	enemy_actors.clear()
	for fx in effects:
		if is_instance_valid(fx):fx.queue_free()
	effects.clear()
	for v in object_views.values():
		if is_instance_valid(v):v.queue_free()
	object_views.clear()
	for prop: Dictionary in event["props"]:
		var view = PropView.new()
		world.add_child(view)
		view.setup(_assets["scene"],prop)
		prop_views.append(view)

func _on_entity_spawned(event: Dictionary) -> void:
	var bank: Dictionary = _combat.get("monsters",{}).get(String(event["appearance"]),{})
	if bank.is_empty():return
	var actor = ActorView.new()
	world.add_child(actor)
	actor.setup(bank["atlas"],bank["clips"])
	actor.shadow_width = 14
	enemy_actors[event["entity_id"]] = actor

func _on_entity_removed(event: Dictionary) -> void:
	var actor = enemy_actors.get(event["entity_id"])
	if actor != null and is_instance_valid(actor):actor.queue_free()
	enemy_actors.erase(event["entity_id"])

func _on_cue(event: Dictionary) -> void:
	match String(event["kind"]):
		"sound":audio.on_cue(event)
		"fx":_spawn_fx(String(event["key"]),event["point"],int(event["facing"]),float(event["height"]),float(event.get("scale",1.0)))

func _spawn_fx(key: String, point: Vector2, facing: int, height: float, scale := 1.0) -> void:
	if not _effects.has(key):return
	var fx = FxView.new()
	world.add_child(fx)
	fx.position = point-Vector2(0,height)
	fx.z_index = int(point.y)+4
	fx.base_scale = scale
	fx.setup(_effects[key],facing)
	fx.advance(0)
	effects.append(fx)

## Bitmap damage digits (sprite/common/etc/combo.img): monster damage white, damage taken red.
func _on_damage(event: Dictionary) -> void:
	var point: Vector3 = event["point"]
	var style := "damage_taken" if String(event.get("victim","monster")) == "player" else "damage_crit" if event.get("critical",false) else "damage"
	numbers.append({"pos":Vector2(point.x,point.y)-Vector2(0,65+point.z),"value":int(event["amount"]),"ms":0.0,"style":style})
