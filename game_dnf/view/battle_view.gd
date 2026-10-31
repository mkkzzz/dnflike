extends Node2D
## Battle presentation root (L4). Reads the per-tick snapshot and combat events only;
## never writes simulation state. Contract: docs/design/29_新版工程框架_接口契约.md.
## Every drawn element is an original bank: runtime manifest (players, ui, legacy fx),
## assets_local/combat (monsters, passive objects, skill/hit effects, digits, HP bar) and the
## exported original Lorien maps (assets_local/native_maps).
const ActorView = preload("res://view/actor_view.gd")
const FxView = preload("res://view/fx_view.gd")
const AudioRouter = preload("res://view/audio_router.gd")
const MapStage = preload("res://view/map_stage.gd")
const Frame = preload("res://view/world_frame.gd")
const CombatHud = preload("res://ui/combat/combat_hud.gd")
const PropView = preload("res://scripts/native_prop.gd")
const WeaponAppearance = preload("res://content/api/weapon_appearance.gd")
const REVIVE_ASSETS := "res://assets_local/revive_v1/manifest.json"
## Afterimage of a cancelled pose (E-ADAPT: engine-drawn in the original, no data file).
const GHOST_MS := 320.0
const GHOST_TINT := Color(0.62,0.78,1.0,0.6)

var world: Node2D
var stage
var player_actor
var hud
## CanvasLayer hosting the combat HUD. A CanvasLayer ignores its parent's transform, so a
## flow root that scales its own canvas (the loop) must scale this layer explicitly, or the
## HUD draws at half size while the world is scaled.
var hud_layer
var revive_layer
var audio
var effects: Array = []
var revive_effects: Array = []
var numbers: Array = []
var prop_views: Array = []
var enemy_actors: Dictionary = {}
var object_views: Dictionary = {}
var ghosts: Array = []
var aura
var camera_x := 0.0
var _assets: Dictionary
var _combat: Dictionary
var _effects: Dictionary = {}
var _player_clips: Dictionary
var _weapon := ""
var _weapon_item := ""
var _item_appearance_enabled := false
var _player_pos := Vector2.ZERO
var _player_z := 0.0
var revive_assets: Dictionary = {}
var revive_fx_count := 0
## 拾取下蹲：这段时间内把玩家姿势临时换成 sit（原版下蹲帧），到点自动回到模拟姿势。
## 由 loot/bridge.gd 在拾取成功时调用 request_pickup_pose()。
var pickup_pose_until_ms := 0

## 剩余帧数：用帧计数而不是墙上时钟，截图/掉帧时不会整段跳过（原版 sit 约 0.8s ≈ 48 帧）。
var pickup_pose_frames := 0

func request_pickup_pose(duration_ms := 900.0) -> void:
	pickup_pose_until_ms = Time.get_ticks_msec() + int(duration_ms)
	pickup_pose_frames = int(maxf(8.0, duration_ms / 16.0))

func setup(assets: Dictionary, combat_assets: Dictionary, player_clips: Dictionary, bus, weapon: String, map_loader) -> void:
	_assets = assets
	_combat = combat_assets
	_player_clips = player_clips
	_effects = assets.get("effects",{}).duplicate()
	_effects.merge(combat_assets.get("effects",{}),true)
	world = Node2D.new()
	add_child(world)
	stage = MapStage.new()
	world.add_child(stage)
	stage.setup(map_loader)
	player_actor = ActorView.new()
	world.add_child(player_actor)
	_set_weapon(weapon)
	var layer := CanvasLayer.new()
	add_child(layer)
	hud_layer = layer
	hud = CombatHud.new()
	layer.add_child(hud)
	hud.setup(assets["ui"],combat_assets.get("digits",{}),combat_assets.get("monster_hp",{}))
	revive_layer=CanvasLayer.new()
	revive_layer.layer=2
	add_child(revive_layer)
	audio = AudioRouter.new()
	add_child(audio)
	audio.setup(assets["audio"],combat_assets.get("audio",{}))
	_load_revive_assets()
	bus.subscribe("combat.cue", _on_cue)
	bus.subscribe("combat.damage", _on_damage)
	bus.subscribe("combat.room_loaded", _on_room_loaded)
	bus.subscribe("combat.entity_spawned", _on_entity_spawned)
	bus.subscribe("combat.entity_removed", _on_entity_removed)
	bus.subscribe("combat.prop_broken", _on_prop_broken)
	bus.subscribe("combat.appearance_changed", func(e: Dictionary):
		if int(e["entity_id"])==0 and String(e["weapon"])!=_weapon:_set_weapon(String(e["weapon"])))

func _load_revive_assets() -> void:
	if not FileAccess.file_exists(REVIVE_ASSETS):return
	var parsed=JSON.parse_string(FileAccess.get_file_as_string(REVIVE_ASSETS))
	if not parsed is Dictionary or parsed.get("schema")!="dnf_revive_assets/1":return
	revive_assets=parsed
	var audio_info: Dictionary=revive_assets.get("audio",{}).get("coin_in",{})
	if not audio_info.is_empty():
		audio.register("revive_coin","res://assets_local/revive_v1/"+String(audio_info.get("file","")))

## Original use-coin animation plus the particle sprite around the revived player.
func play_revive_effect(pos: Vector2, z: float) -> void:
	if revive_assets.is_empty() or not revive_assets.get("effects",{}).has("coin"):return
	# Screen-space layer keeps the native coin above the 508..600 HUD band.
	var center_offset := Vector2(0,-52)
	var coin := FxView.new()
	revive_layer.add_child(coin)
	coin.setup(revive_assets["effects"]["coin"],1)
	revive_effects.append({"node":coin,"offset":center_offset})
	var points := [Vector2(-25,-8),Vector2(24,-10),Vector2(-17,-27),Vector2(18,-23),Vector2(0,-35),Vector2(0,-4)]
	for i in points.size():
		var spark := FxView.new()
		revive_layer.add_child(spark)
		spark.setup(revive_assets["effects"]["spark"],1)
		spark.seek(float(i)*70.0)
		revive_effects.append({"node":spark,"offset":center_offset+points[i]})
	audio.play("revive_coin")
	revive_fx_count+=1

## 可破坏物被打碎：地图里对应节点按 loader 打好的 prop_node 下标隐藏。
func _on_prop_broken(event: Dictionary) -> void:
	var index := int(event.get("node", -1))
	if index < 0 or stage == null or stage.root == null:return
	for node in stage.root.get_children():
		if int(node.get_meta("prop_node", -1)) == index:
			node.visible = false
			return

func set_debug_collision(enabled: bool) -> void:
	stage.debug_collision = enabled
	stage.queue_redraw()

## frame_ms always elapses (damage numbers); sim_ms is the simulation time actually advanced.
func present(s: Dictionary, frame_ms: float, sim_ms: float) -> void:
	var p: Dictionary = s["player"]
	_player_pos = Vector2(p["pos"])
	_player_z = float(p["z"])
	for fx in effects:
		if is_instance_valid(fx) and not fx.is_queued_for_deletion():
			if fx.follow == 0:fx.position = _canvas(_player_pos, _player_z)
			fx.advance(sim_ms)
	effects = effects.filter(func(fx):return is_instance_valid(fx) and not fx.is_queued_for_deletion())
	stage.show_room(s["stage"])
	var props: Array = s["props"]
	for i in prop_views.size():
		if is_instance_valid(prop_views[i]) and i < props.size():
			prop_views[i].data = props[i]
			prop_views[i].refresh()
	if String(p["weapon"]) != _weapon:_set_weapon(String(p["weapon"]))
	player_actor.position = _canvas(_player_pos, 0.0)
	player_actor.z_index = int(_player_pos.y)
	# 拾取瞬间播放下蹲（原版 sit 帧），其余时间完全按模拟给的动作。
	var pose := String(p["ani"])
	var pose_clock := float(p["clock"])
	if pickup_pose_frames > 0:
		pose = "sit"
		pose_clock = 30.0
		pickup_pose_frames -= 1
	player_actor.present(pose,pose_clock,p["facing"],p["z"],1.0 if p["flash"] else 0.0)
	_present_aura(String(p.get("aura","")),p,sim_ms)
	for e: Dictionary in s["enemies"]:
		var actor = enemy_actors.get(e["id"])
		if actor == null:continue
		actor.position = _canvas(Vector2(e["pos"]), 0.0)
		actor.z_index = int(Vector2(e["pos"]).y)
		var alpha := clampf(1.0-(float(e["death_ms"])-400)/400,0,1) if not e["alive"] else 1.0
		actor.present(e["ani"],e["clock"],e["facing"],e["z"],1.0 if e["flash"] else 0.0,Color(1,1,1,alpha))
	_present_objects(s.get("objects",[]))
	for i in range(ghosts.size()-1,-1,-1):
		var g: Dictionary = ghosts[i]
		g["ms"] = float(g["ms"])+frame_ms
		var node = g["node"]
		if float(g["ms"]) >= GHOST_MS or not is_instance_valid(node):
			if is_instance_valid(node):node.queue_free()
			ghosts.remove_at(i)
			continue
		var c := GHOST_TINT
		c.a *= 1.0-float(g["ms"])/GHOST_MS
		node.tint = c
		node.queue_redraw()
	camera_x = stage.camera_for(_player_pos.x)
	world.position = Vector2(-roundf(camera_x),0)
	stage.apply_camera(roundf(camera_x))
	var revive_anchor := _canvas(_player_pos,_player_z) + world.position
	var revive_ms := minf(sim_ms,50.0)
	for entry: Dictionary in revive_effects:
		var node=entry["node"]
		if is_instance_valid(node):
			node.position=revive_anchor+Vector2(entry["offset"])
			node.advance(revive_ms)
	revive_effects=revive_effects.filter(func(entry: Dictionary):return is_instance_valid(entry["node"]) and not entry["node"].is_queued_for_deletion())
	for i in range(numbers.size()-1,-1,-1):
		numbers[i]["ms"] = float(numbers[i]["ms"])+frame_ms
		if float(numbers[i]["ms"])>650:numbers.remove_at(i)
	var hud_state: Dictionary = s["hud"].duplicate()
	hud_state["enemies"] = s["enemies"]
	hud_state["numbers"] = numbers
	hud_state["camera"] = Vector2(roundf(camera_x),0)
	hud_state["width"] = float(Frame.WIDTH)
	hud_state["height"] = float(Frame.HEIGHT)
	hud.present(hud_state)

func _set_weapon(weapon: String) -> void:
	_weapon = weapon
	if _item_appearance_enabled:
		var skin: Dictionary=WeaponAppearance.skin(_weapon_item)
		if _weapon_item=="" or skin.get("family",weapon)==weapon:
			WeaponAppearance.apply(player_actor,_weapon_item,_player_clips)
			return
		# Explicit debug family changes remain a temporary visual override.
		_item_appearance_enabled=false
	player_actor.setup(_assets["players"][weapon],_player_clips, _combat.get("player_locomotion", {}).get("battle", {}).get(weapon, {}))

func set_equipped_weapon(item: String) -> bool:
	if not WeaponAppearance.can_display(item):return false
	if _item_appearance_enabled and _weapon_item==item and player_actor.get_meta("weapon_item",null)==item:return true
	_weapon_item=item;_item_appearance_enabled=true
	return WeaponAppearance.apply(player_actor,item,_player_clips)

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
	aura.position = _canvas(Vector2(p["pos"]), float(p["z"]))
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
		v.position = _canvas(Vector2(o["pos"]), float(o["z"]))
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
	for g: Dictionary in ghosts:
		if is_instance_valid(g["node"]):g["node"].queue_free()
	ghosts.clear()
	numbers.clear()
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
		"fx":_spawn_fx(event)
		"fx_clear":
			for fx in effects:
				if is_instance_valid(fx) and fx.tag == String(event["tag"]):fx.queue_free()
		"ghost":_spawn_ghost(event)

func _spawn_fx(event: Dictionary) -> void:
	var key := String(event["key"])
	if not _effects.has(key):return
	var point: Vector2 = event["point"]
	var fx = FxView.new()
	world.add_child(fx)
	fx.position = _canvas(point, float(event["height"]))
	fx.z_index = int(point.y)+4
	fx.base_scale = float(event.get("scale",1.0))
	fx.tag = String(event.get("tag",""))
	fx.follow = int(event.get("follow",-1))
	fx.max_ms = float(event.get("max_ms",-1.0))
	fx.setup(_effects[key],int(event["facing"]))
	fx.advance(0)
	effects.append(fx)

## Translucent copy of the player's pose at the moment an action is cancelled.
func _spawn_ghost(event: Dictionary) -> void:
	var node = ActorView.new()
	world.add_child(node)
	node.setup(_assets["players"][_weapon],_player_clips,_combat.get("player_locomotion",{}).get("battle",{}).get(_weapon,{}))
	if _item_appearance_enabled:WeaponAppearance.apply(node,_weapon_item,_player_clips)
	node.shadow_width = 0
	node.position = _canvas(Vector2(event["pos"]), 0.0)
	node.z_index = int(Vector2(event["pos"]).y)-1
	node.present(String(event["ani"]),float(event["clock"]),int(event["facing"]),float(event["z"]),0.0,GHOST_TINT)
	ghosts.append({"node":node,"ms":0.0})

## Bitmap damage digits (sprite/common/etc/combo.img): monster damage white, damage taken red.
## Positions are canvas coordinates; the HUD subtracts the camera.
func _on_damage(event: Dictionary) -> void:
	var point: Vector3 = event["point"]
	var style := "damage_taken" if String(event.get("victim","monster")) == "player" else "damage_crit" if event.get("critical",false) else "damage"
	numbers.append({"pos":Vector2(point.x,point.y+Frame.MAP_DY)-Vector2(0,65+point.z),"value":int(event["amount"]),"ms":0.0,"style":style})

## map 坐标（角色/敌人/物件/特效）→ 画布坐标。
func _canvas(point: Vector2, height: float) -> Vector2:
	return Vector2(roundf(point.x), roundf(point.y+Frame.MAP_DY-height))
