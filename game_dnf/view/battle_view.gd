extends Node2D
## Battle presentation root (L4). Reads the per-tick snapshot and combat events only;
## never writes simulation state. Contract: docs/design/29_新版工程框架_接口契约.md.
## Every drawn element is an original bank: runtime manifest (players, ui, legacy fx),
## assets_local/combat (monsters, passive objects, skill/hit effects, digits, HP bar) and the
## exported original Lorien maps (assets_local/native_maps).
const ActorView = preload("res://view/actor_view.gd")
const FxView = preload("res://view/fx_view.gd")
const NativeParticleView = preload("res://view/native_particle_view.gd")
const ParticleBursts = preload("res://combat/api/particle_bursts.gd")
const TextureCache = preload("res://view/texture_cache.gd")
const AudioRouter = preload("res://view/audio_router.gd")
const MapStage = preload("res://view/map_stage.gd")
const Frame = preload("res://view/world_frame.gd")
const CombatHud = preload("res://ui/combat/combat_hud.gd")
const PropView = preload("res://scripts/native_prop.gd")
const WeaponAppearance = preload("res://content/api/weapon_appearance.gd")
const REVIVE_ASSETS := "res://assets_local/revive_v1/manifest.json"
const STATUS_ASSETS := "res://assets_local/status_v1/manifest.json"
const BLIND_LAYERS := {"BlindBack":"blind_back","BlindFront":"blind_front"}
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
var particle_bursts = ParticleBursts.new()
var _particle_banks: Dictionary = {}
var _particle_emitters: Array[Dictionary] = []
var _object_particle_emitters: Dictionary = {}
var _poison_emitters: Dictionary = {}
var _overdrive_emitter: Dictionary = {}
var revive_effects: Array = []
var numbers: Array = []
var prop_views: Array = []
var enemy_actors: Dictionary = {}
var _companion_banks: Dictionary = {}
var _status_assets: Dictionary = {}
var object_views: Dictionary = {}
var ghosts: Array = []
var aura
var camera_x := 0.0
var _shake_degree := 0
var _shake_remaining_ms := 0.0
var _shake_fresh := false
var _shake_offset := Vector2.ZERO
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
## 拾取使用 CHR [getitem motion]；只有仍处于可拾取地面状态时才覆盖模拟姿势。
## 由 loot/bridge.gd 在拾取成功时调用 request_pickup_pose()。
var pickup_pose_until_ms := 0

## GetItem.ani 为 1 帧 / 200ms；按 60Hz 物理帧保留约 12 帧。
var pickup_pose_frames := 0

func request_pickup_pose(duration_ms := 200.0) -> void:
	pickup_pose_until_ms = Time.get_ticks_msec() + int(duration_ms)
	pickup_pose_frames = int(maxf(1.0,ceili(duration_ms/1000.0*60.0)))

func setup(assets: Dictionary, combat_assets: Dictionary, player_clips: Dictionary, bus, weapon: String, map_loader) -> void:
	_assets = assets
	_combat = combat_assets
	_player_clips = player_clips
	_effects = assets.get("effects",{}).duplicate()
	_effects.merge(combat_assets.get("effects",{}),true)
	if FileAccess.file_exists(STATUS_ASSETS):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(STATUS_ASSETS))
		if parsed is Dictionary and parsed.get("schema") == "dnf_status_assets/1":
			_status_assets = parsed
	for bank: Dictionary in combat_assets.get("effects",{}).values():
		if bank.has("source") and not bank.get("particle_variant",false):
			_particle_banks[String(bank.source).to_lower()] = bank
	_warm_render_assets()
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
	hud.setup(combat_assets.get("digits",{}),combat_assets.get("monster_hp",{}))
	revive_layer=CanvasLayer.new()
	revive_layer.layer=2
	add_child(revive_layer)
	audio = AudioRouter.new()
	add_child(audio)
	audio.setup(assets["audio"],combat_assets.get("audio",{}))
	_load_revive_assets()
	bus.subscribe("combat.cue", _on_cue)
	bus.subscribe("combat.damage", _on_damage)
	bus.subscribe("combat.damage_number", _on_damage)
	bus.subscribe("combat.room_loaded", _on_room_loaded)
	bus.subscribe("combat.entity_spawned", _on_entity_spawned)
	bus.subscribe("combat.entity_removed", _on_entity_removed)
	bus.subscribe("combat.prop_broken", _on_prop_broken)
	bus.subscribe("combat.appearance_changed", func(e: Dictionary):
		if int(e["entity_id"])==0 and String(e["weapon"])!=_weapon:_set_weapon(String(e["weapon"])))

## Decode atlases before the first hit/room transition. This moves the one-time
## cost to battle setup instead of leaving a 20ms stall on the first visual cue.
func _warm_render_assets() -> void:
	var paths := {}
	for effect_info: Dictionary in _effects.values():
		var atlas: Dictionary = effect_info.get("atlas",{})
		if atlas.get("texture","") != "":paths[String(atlas["texture"])] = true
	for bank: Dictionary in _status_assets.get("effects",{}).values():
		paths[String(bank["atlas"]["texture"])] = true
	for bank: Dictionary in _combat.get("objects",{}).values():
		var atlas: Dictionary = bank.get("atlas",{})
		if atlas.get("texture","") != "":paths[String(atlas["texture"])] = true
	for bank: Dictionary in _combat.get("monsters",{}).values():
		var atlas: Dictionary = bank.get("atlas",{})
		if atlas.get("texture","") != "":paths[String(atlas["texture"])] = true
	for bank: Dictionary in _assets.get("players",{}).values():
		if bank.get("texture","") != "":paths[String(bank["texture"])] = true
	var locomotion: Dictionary = _combat.get("player_locomotion",{}).get("battle",{})
	for clips: Dictionary in locomotion.values():
		for override: Dictionary in clips.values():
			if override.get("texture","") != "":paths[String(override["texture"])] = true
	TextureCache.warm(paths.keys())

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
	if index >= 0 and stage != null:stage.hide_prop(index)

func set_debug_collision(enabled: bool) -> void:
	stage.debug_collision = enabled
	stage.queue_redraw()

## frame_ms always elapses (damage numbers); sim_ms is the simulation time actually advanced.
func present(s: Dictionary, frame_ms: float, sim_ms: float) -> void:
	var p: Dictionary = s["player"]
	var companions: Array = s.get("companions",[])
	var actor_by_id := {}
	for actor: Dictionary in s["enemies"]:actor_by_id[actor["id"]] = actor
	for companion: Dictionary in companions:actor_by_id[companion["id"]] = companion
	_player_pos = Vector2(p["pos"])
	_player_z = float(p["z"])
	_advance_native_emitters(sim_ms)
	_advance_poison_emitters([p]+s["enemies"]+companions,sim_ms)
	_advance_overdrive_emitter(p)
	var poison_overlay := _poison_overlay(float(s.get("status_clock_ms",0.0)))
	for fx in effects:
		if is_instance_valid(fx) and not fx.is_queued_for_deletion():
			var source: Dictionary = p if fx.follow == 0 else actor_by_id.get(fx.follow,{})
			if not source.is_empty():
				fx.position = _canvas(Vector2(source["pos"]),float(source["z"]))+fx.follow_offset
				if fx.has_meta("depth_offset"):fx.z_index = int(Vector2(source["pos"]).y)+int(fx.get_meta("depth_offset"))
			if fx.action_clock_at >= 0:
				if int(source.get("action_instance",-1)) != fx.action_instance or source.get("state","") != "action":fx.queue_free()
				else:
					var elapsed: float = float(source.get("fx_clock",source["clock"]))-fx.action_clock_at+fx.action_clock_carry
					fx.seek(0.0 if fx.freeze_first_frame else maxf(0.0,elapsed))
			elif fx.get_meta("particle_birth_pending",false):
				# The cue was created during this simulation tick. Its ANI begins
				# at zero, rather than consuming a tick before its first rendering.
				fx.set_meta("particle_birth_pending",false)
			else:fx.advance(sim_ms)
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
	# 拾取瞬间播放 CHR GetItem.ani；出招、受击或腾空时立即把控制权交回模拟。
	var pose := String(p["ani"])
	var pose_clock := float(p["clock"])
	var pickup_state := String(p.get("state",""))
	if pickup_pose_frames > 0 and pickup_state in ["idle","move","guard"]:
		pose = "getitem"
		pose_clock = 0.0
		pickup_pose_frames -= 1
	elif pickup_pose_frames > 0:
		pickup_pose_frames = 0
	var player_tint := Color(1,1,1,100.0/255.0) if p.get("jar_invincible",false) else Color.WHITE
	player_actor.present(pose,pose_clock,p["facing"],p["z"],1.0 if p["flash"] else 0.0,player_tint,
		float(p.get("body_rotation",0.0)),p.get("cast_layers",[]).is_empty())
	_present_cast_layers(player_actor,p)
	player_actor.present_status_overlay(poison_overlay if int(p.get("poison",0)) > 0 else Color.TRANSPARENT)
	_present_aura(String(p.get("aura","")),p,sim_ms)
	for e: Dictionary in s["enemies"]+companions:
		var actor = enemy_actors.get(e["id"])
		if actor == null:continue
		actor.position = _canvas(Vector2(e["pos"]), 0.0)
		actor.z_index = int(Vector2(e["pos"]).y)
		var alpha := clampf(1.0-(float(e["death_ms"])-400)/400,0,1) if not e["alive"] else 1.0
		actor.present(e["ani"],e["clock"],e["facing"],e["z"],1.0 if e["flash"] else 0.0,Color(1,1,1,alpha))
		var overlay := poison_overlay if int(e.get("poison",0)) > 0 else Color.TRANSPARENT
		var hellbenter_alpha := int(e.get("hellbenter_tint",0))
		if hellbenter_alpha > 0:overlay = Color(1,1,1,alpha*hellbenter_alpha/255.0)
		actor.present_status_overlay(overlay)
		if e.has("blind"):_present_blind(actor,e,sim_ms)
		_present_sleep(actor,float(e.get("sleep_ms",-1)))
		_present_cast_layers(actor,e)
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
	camera_x = stage.camera_for(float(s.get("camera_focus_x",_player_pos.x)))
	_advance_camera_shake(sim_ms)
	world.position = Vector2(-roundf(camera_x),0)+_shake_offset
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
		var age := float(numbers[i]["ms"])
		var expired := age >= float(numbers[i]["end_ms"]) if numbers[i].has("end_ms") else age > 650.0
		if expired:numbers.remove_at(i)
	var hud_state: Dictionary = s["hud"].duplicate()
	hud_state["enemies"] = s["enemies"]
	hud_state["numbers"] = numbers
	hud_state["camera"] = -world.position
	hud_state["width"] = float(Frame.WIDTH)
	hud_state["height"] = float(Frame.HEIGHT)
	hud.present(hud_state)

func _advance_camera_shake(sim_ms: float) -> void:
	if _shake_remaining_ms <= 0.0 or (not _shake_fresh and sim_ms <= 0.0):return
	if not _shake_fresh:_shake_remaining_ms -= sim_ms
	_shake_fresh = false
	# 8E0B4A..8E0BAE at the ordinary 1.0 camera scale. The source
	# consumes both draws before clearing the offset on the deadline.
	var span := 2*_shake_degree+1
	var x := particle_bursts.draw_global()%span-_shake_degree
	var y := particle_bursts.draw_global()%span-_shake_degree
	if _shake_remaining_ms <= 0.0 or is_zero_approx(_shake_remaining_ms):
		_shake_remaining_ms = 0.0
		_shake_offset = Vector2.ZERO
	else:
		_shake_offset = Vector2(x,y)

func _set_weapon(weapon: String) -> void:
	_weapon = weapon
	if _item_appearance_enabled:
		var skin: Dictionary=WeaponAppearance.skin(_weapon_item)
		if _weapon_item=="" or skin.get("family",weapon)==weapon:
			WeaponAppearance.apply(player_actor,_weapon_item,_player_clips)
			return
		# Explicit debug family changes remain a temporary visual override.
		_item_appearance_enabled=false
	setup_weapon_family(player_actor,weapon)

func setup_weapon_family(actor, family: String) -> void:
	if _assets["players"].has(family):
		var overrides: Dictionary = _combat.get("player_locomotion",{}).get("battle",{}).get(family,{}).duplicate()
		var body: Dictionary = WeaponAppearance.data().get("body",{}).get("base",{})
		if not body.is_empty():
			for pose: String in _player_clips:
				if pose.begins_with("hundredswordmoveready"):overrides[pose] = body
		actor.setup(_assets["players"][family],_player_clips,overrides)
	else:
		WeaponAppearance.apply(actor,"",_player_clips)

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

func _present_blind(actor: ActorView, enemy: Dictionary, sim_ms: float) -> void:
	var active := bool(enemy["blind"])
	if not active and not actor.has_node("BlindFront"):return
	var height: Dictionary = _status_assets.get("monster_heights",{}).get(enemy["mob"],{})
	var banks: Dictionary = _status_assets.get("effects",{})
	if height.is_empty() or not banks.has("blind_back") or not banks.has("blind_front"):return
	for layer: String in BLIND_LAYERS:
		var fx := actor.get_node_or_null(layer) as FxView
		var elapsed := 0.0
		if fx == null:
			fx = FxView.new()
			fx.name = layer
			fx.show_behind_parent = layer == "BlindBack"
			var bank: Dictionary = banks[BLIND_LAYERS[layer]]
			fx.setup(bank,1)
			fx.loop = bool(bank["loop"])
			actor.add_child(fx)
		else:
			elapsed = fx.clock_ms + sim_ms
		fx.visible = active
		if active:
			# Both original passes use the cached base ANI top, independent of the current pose.
			fx.position.y = -roundf(float(enemy["z"])) - float(height["pixels"]) - 5.0
			fx.seek(elapsed)
		else:
			# The status owns the ANI pair for the actor's lifetime. Expiry
			# hides it and a later application does not rebuild the animation.
			fx.clock_ms = elapsed

func _present_sleep(actor: ActorView, age: float) -> void:
	var fx := actor.get_node_or_null("NativeSleep") as FxView
	if age < 0:
		if fx != null:fx.hide()
		return
	if fx == null:
		var bank: Dictionary = _effects.get("native_sleep",{})
		if bank.is_empty():return
		fx = FxView.new()
		fx.name = "NativeSleep"
		fx.setup(bank,1)
		fx.loop = bool(bank["loop"])
		actor.add_child(fx)
	# The source uses the current down sprite's right edge and top.
	var bounds := actor.sprite_bounds()
	fx.position = Vector2(int(-actor.facing*bounds.end.x*0.75),-roundf(actor.height)+int(bounds.position.y*0.5))
	fx.seek(age)
	fx.show()

func _present_cast_layers(actor: Node2D, state: Dictionary) -> void:
	var layers: Array = state.get("cast_layers",[])
	var views: Dictionary = actor.get_meta("native_cast_layers",{})
	if layers.is_empty():
		for layer: Node2D in views.values():layer.hide()
		return
	var active := {}
	for info: Dictionary in layers:
		var key: String = info["bank"]
		active[key] = true
		var view = views.get(key)
		if view == null:
			view = FxView.new()
			view.show_behind_parent = bool(info.get("behind",int(info["order"]) < 0))
			view.setup(_effects[key],int(state["facing"]))
			view.loop = bool(info.get("loop",true))
			actor.add_child(view)
			views[key] = view
		view.position.y = -roundf(float(state["z"]))
		view.facing = int(state["facing"])
		view.base_rotation = float(state.get("body_rotation",0.0))
		view.seek(float(state["clock"]))
		view.show()
	for key: String in views:
		if not active.has(key):views[key].hide()
	actor.set_meta("native_cast_layers",views)

func _present_objects(list: Array) -> void:
	var live := {}
	for o: Dictionary in list:
		live[o["id"]] = true
		var v = object_views.get(o["id"])
		if v == null:
			var bank: Dictionary = _effects.get(String(o["effect"]),{}) if o.has("effect") else _combat.get("objects",{}).get(String(o["bank"]),{})
			if bank.is_empty():continue
			v = FxView.new()
			world.add_child(v)
			v.setup(bank,int(o["facing"]))
			var rear_bank: Dictionary = _effects.get(String(o.get("rear_fx","")),{})
			if not rear_bank.is_empty():
				var rear = FxView.new()
				rear.name = "RearAnimation"
				rear.z_index = -1
				v.add_child(rear)
				rear.setup(rear_bank,int(o["facing"]))
			object_views[o["id"]] = v
		v.loop = bool(o.get("loop",false))
		v.hold_last_frame = bool(o.get("hold_last_frame",false))
		v.facing = int(o["facing"])
		v.position = _canvas(Vector2(o["pos"]), float(o["z"]))+Vector2(o.get("screen_offset",Vector2.ZERO))
		v.z_index = int(Vector2(o["pos"]).y)+int(o.get("depth_offset",2))
		v.base_scale = float(o.get("size_rate",1))
		v.base_rotation = float(o.get("rotation",0.0))
		v.frame_rotations = o.get("frame_rotations",{})
		v.uniform_frame_ms = float(o.get("uniform_frame_ms",-1.0))
		v.fade = float(o.get("fade",1))
		v.seek(float(o["clock"]))
		var rear = v.get_node_or_null("RearAnimation")
		if is_instance_valid(rear) and not rear.is_queued_for_deletion():
			rear.base_scale = v.base_scale
			rear.seek(float(o["clock"]))
		if o.has("particle_trail"):advance_object_particle(v,o)
	for id in object_views.keys():
		if not live.has(id):
			if is_instance_valid(object_views[id]):object_views[id].queue_free()
			object_views.erase(id)

func advance_object_particle(view: Node2D, item: Dictionary) -> void:
	var trail: Dictionary = item["particle_trail"]
	var path := String(trail["path"])
	var point: Vector2 = item["pos"]+trail["offset"]
	var origin := Vector3i(int(point.x),int(point.y),int(item["z"]))
	var emitter: RefCounted = view.get_meta("particle_trail") if view.has_meta("particle_trail") else null
	if emitter == null:
		var template: Dictionary = _combat.get("particles",{}).get(path,{})
		if template.is_empty():
			push_error("Missing original particle template: "+path)
			return
		emitter = particle_bursts.create_emitter(template["decoded"],origin,int(item["facing"]) < 0)
		view.set_meta("particle_trail",emitter)
	emitter.origin = origin
	_append_native_particles(path,1.0,particle_bursts.emit_at(emitter,int(item["clock"])))

func _on_room_loaded(event: Dictionary) -> void:
	stage.invalidate_room()
	_shake_remaining_ms = 0.0
	_shake_fresh = false
	_shake_offset = Vector2.ZERO
	for view in prop_views:
		if is_instance_valid(view):view.queue_free()
	prop_views.clear()
	for actor in enemy_actors.values():
		if is_instance_valid(actor):actor.queue_free()
	enemy_actors.clear()
	for fx in effects:
		if is_instance_valid(fx):fx.queue_free()
	effects.clear()
	_particle_emitters.clear()
	_object_particle_emitters.clear()
	_poison_emitters.clear()
	_overdrive_emitter.clear()
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

func companion_bank(source_id: int) -> Dictionary:
	if _companion_banks.is_empty():
		var path := "res://assets_local/companions_v1/manifest.json"
		if not FileAccess.file_exists(path):return {}
		var manifest = JSON.parse_string(FileAccess.get_file_as_string(path))
		if manifest is Dictionary and manifest.get("schema") == "dnf_companion_appearance/1":_companion_banks = manifest.get("actors",{})
	return _companion_banks.get(str(source_id),{})

func has_companion_appearance(source_id: int) -> bool:
	var bank := companion_bank(source_id)
	var texture := String(bank.get("atlas",{}).get("texture",""))
	return bank.get("clips",{}).has("stay") and texture != "" and ResourceLoader.exists(texture)

func _on_entity_spawned(event: Dictionary) -> void:
	var bank: Dictionary = companion_bank(int(event["source_id"])) if event.get("kind","") == "companion" \
		else _combat.get("monsters",{}).get(String(event["appearance"]),{})
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
		"native_particle":_spawn_native_particle(event)
		"screen_flash":_spawn_screen_flash(event)
		"screen_shake":
			_shake_degree = int(event["degree"])
			_shake_remaining_ms = float(event["duration_ms"])
			_shake_fresh = true
		"fx_clear":
			for fx in effects:
				if is_instance_valid(fx) and fx.tag == String(event["tag"]) \
						and (not event.has("keys") or fx.cue_key in event["keys"]):fx.queue_free()
		"fx_continue":
			for fx in effects:
				if is_instance_valid(fx) and fx.tag == String(event["tag"]):
					fx.action_instance = int(event["action_instance"])
					fx.action_clock_carry += float(event["elapsed"])
		"fx_fade_first_frame":
			for fx in effects:
				if is_instance_valid(fx) and fx.tag == String(event["tag"]) and fx.cue_key in event["keys"]:
					fx.fade = float(event["opacity"])
					fx.freeze_first_frame = true
		"ghost":_spawn_ghost(event)

func _spawn_screen_flash(event: Dictionary) -> void:
	var center := Vector2i(_canvas(event["point"],float(event["height"]))+world.position)
	var size: Vector2i = event["trigger_size"]
	# The native rectangle is only an allocation gate. FlashScreen.ani draws at screen (0,0).
	var half_width := size.x>>1
	if (center.x+half_width < 0 or center.x-half_width >= Frame.WIDTH
			or center.y < 0 or center.y-size.y >= Frame.HEIGHT):return
	var bank: Dictionary = _effects["native_flash_screen"].duplicate(true)
	var durations: Array = event["durations"]
	var frames: Array = bank["frames"]
	for index in durations.size():
		frames[index]["delay_ms"] = durations[index]
	bank["duration_ms"] = durations[0]+durations[1]+durations[2]
	var rgb: Vector3i = event.get("rgb",Vector3i(255,255,255))
	var blend := int(event.get("blend",2))
	var peak := int(event["peak_alpha"])
	for index in frames.size():
		var items: Dictionary = frames[index]["items"]
		items["9"] = [rgb.x,rgb.y,rgb.z,peak if index in [1,2] else 0]
		items["11"] = {"type":blend}
	var flash := FxView.new()
	add_child(flash)
	# Native layer 2 draws between the backgrounds and normal scene. Layer 6 draws above the world.
	flash.z_index = 4095
	if event.get("layer",6) == 2:flash.z_index = stage.loader.z_for("closeback",0.0)+1
	flash.cue_key = "native_flash_screen"
	flash.set_meta("particle_birth_pending",true)
	flash.setup(bank,1)
	flash.seek(0.0)
	effects.append(flash)

func _spawn_native_particle(event: Dictionary) -> void:
	var object_emitter := int(event.get("object_emitter",-1))
	if event.get("stop",false):
		_object_particle_emitters.erase(object_emitter)
		return
	var path := String(event["path"])
	var template: Dictionary = _combat.get("particles",{}).get(path,{})
	if template.is_empty():
		push_error("Missing original particle template: "+path)
		return
	var point: Vector2 = event["point"]
	var origin := Vector3i(int(point.x),int(point.y),int(event.get("height",0)))
	var mirrored := bool(event.get("mirrored",false))
	var scale_value := float(event.get("scale",1.0))
	var definition: Dictionary = template.decoded
	if object_emitter >= 0:
		var channels: Dictionary = _object_particle_emitters.get_or_add(object_emitter,{})
		var channel := int(event.get("emitter_channel",0))
		var elapsed := int(event["elapsed_ms"])
		# E50BBB starts the original emitter clock on the first generation update.
		if not channels.has(channel):
			channels[channel] = {"emitter":particle_bursts.create_emitter(definition,origin,mirrored),"started_at":elapsed}
		var entry: Dictionary = channels[channel]
		var emitter: RefCounted = entry["emitter"]
		if emitter.finished:return
		emitter.origin = origin
		_append_native_particles(path,scale_value,particle_bursts.emit_at(emitter,elapsed-int(entry["started_at"])))
		return
	if float(definition.get("creation_frequency",0)) <= 0.0:
		_append_native_particles(path,scale_value,particle_bursts.emit_once(definition,origin,mirrored))
		return
	var emitter: RefCounted = particle_bursts.create_emitter(definition,origin,mirrored)
	var result: Dictionary = particle_bursts.emit_at(emitter,0)
	if _append_native_particles(path,scale_value,result) and not result.finished:
		_particle_emitters.append({"emitter":emitter,"path":path,"scale":scale_value,
			"elapsed_ms":0.0,"birth_pending":true})

func _advance_native_emitters(sim_ms: float) -> void:
	if _particle_emitters.is_empty():return
	var remaining: Array[Dictionary] = []
	for entry in _particle_emitters:
		if entry.birth_pending:
			entry.birth_pending = false
		elif sim_ms > 0.0:
			entry.elapsed_ms += sim_ms
			var result: Dictionary = particle_bursts.emit_at(entry.emitter,int(entry.elapsed_ms))
			if not _append_native_particles(entry.path,entry.scale,result) or result.finished:
				continue
		remaining.append(entry)
	_particle_emitters = remaining

func _advance_poison_emitters(actors: Array, sim_ms: float) -> void:
	var poison: Dictionary = _combat.get("native_status_visuals",{}).get("poison",{})
	if poison.is_empty():return
	var path: String = poison["particle"]
	var live := {}
	for actor: Dictionary in actors:
		var revision := int(actor.get("poison",0))
		if revision == 0:continue
		var id: int = actor["id"]
		var point: Vector2 = actor["pos"]
		var origin := Vector3i(int(point.x),int(point.y),int(actor["z"])+int(poison["z_offset"]))
		var mirrored := int(actor["facing"]) < 0
		var entry: Dictionary = _poison_emitters.get(id,{})
		if int(entry.get("revision",0)) != revision:
			var definition: Dictionary = _combat["particles"][path]["decoded"]
			entry = {"emitter":particle_bursts.create_emitter(definition,origin,mirrored),"revision":revision,"elapsed_ms":0.0}
		else:
			entry["elapsed_ms"] = float(entry["elapsed_ms"])+sim_ms
			entry["emitter"].origin = origin
			entry["emitter"].mirrored = mirrored
		var result: Dictionary = particle_bursts.emit_at(entry["emitter"],int(entry["elapsed_ms"]))
		if _append_native_particles(path,1.0,result) and not result.finished:live[id] = entry
	_poison_emitters = live

func _poison_overlay(clock_ms: float) -> Color:
	if _poison_emitters.is_empty():return Color.TRANSPARENT
	var tint: Dictionary = _combat["native_status_visuals"]["poison"]["tint"]
	var rgb := int(tint["argb"])
	var phase := fposmod(clock_ms,float(tint["period_ms"]))/float(tint["period_ms"])*TAU
	var alpha := int(float(tint["alpha_base_default"])+float(tint["alpha_amplitude"])*sin(phase))
	return Color8((rgb>>16)&255,(rgb>>8)&255,rgb&255,alpha)

func _advance_overdrive_emitter(actor: Dictionary) -> void:
	var age := int(actor.get("overdrive_age_ms",-1.0))
	if age < 0:
		if not _overdrive_emitter.is_empty():
			for fx in effects:
				if is_instance_valid(fx) and fx.tag=="overdrive_status":fx.queue_free()
			_overdrive_emitter.clear()
		return
	var path := String(_combat.get("native_status_visuals",{}).get("overdrive",{}).get("particle",""))
	if path.is_empty():return
	var template: Dictionary = _combat["particles"][path]
	var point: Vector2 = actor["pos"]
	# 97EB5D follows XYZ and places the emitter half a standing body above the owner.
	var origin := Vector3i(int(point.x),int(point.y),int(actor["z"])+int(template["z_offset"]))
	if _overdrive_emitter.is_empty() or age < int(_overdrive_emitter["age"]):
		_overdrive_emitter = {"emitter":particle_bursts.create_emitter(template["decoded"],origin),"start":age}
	_overdrive_emitter["age"] = age
	var emitter: RefCounted = _overdrive_emitter["emitter"]
	emitter.origin = origin
	_append_native_particles(path,1.0,particle_bursts.emit_at(emitter,age-int(_overdrive_emitter["start"])),"overdrive_status")

func _append_native_particles(path: String, scale_value: float, result: Dictionary, tag := "") -> bool:
	if not result.ok:
		push_error(str(result.problems))
		return false
	var pairs: Array = _combat.get("particles",{}).get(path,{}).get("sprite_pairs",[])
	for emission: Dictionary in result.particles:
		var bank: Dictionary = _particle_banks.get(String(emission.entry.path).to_lower(),{})
		var overlay: Dictionary = {}
		if not pairs.is_empty():
			var pair: Array = pairs[particle_bursts.draw_global()%pairs.size()]
			bank = _effects[pair[0]]
			overlay = _effects[pair[1]]
		var particle = NativeParticleView.new()
		world.add_child(particle)
		particle.base_scale = scale_value
		particle.tag = tag
		particle.set_meta("source_ptl",path)
		particle.set_meta("particle_birth_pending",true)
		if not particle.setup_particle(emission,bank,overlay):
			push_error(str(particle.errors))
			particle.queue_free()
			continue
		effects.append(particle)
	return true

func _spawn_fx(event: Dictionary) -> void:
	var key := String(event["key"])
	if not _effects.has(key):return
	var point: Vector2 = event["point"]
	var fx = FxView.new()
	world.add_child(fx)
	fx.follow_offset = Vector2(float(event.get("offset_x",0))*int(event["facing"]),float(event.get("offset_y",0)))
	fx.position = _canvas(point, float(event["height"]))+fx.follow_offset
	var depth_offset := int(event.get("depth_offset",4))
	fx.z_index = int(point.y)+depth_offset
	if depth_offset != 4:fx.set_meta("depth_offset",depth_offset)
	fx.base_scale = float(event.get("scale",1.0))
	fx.base_rotation = float(event.get("angle",0.0))
	fx.tag = String(event.get("tag",""))
	fx.follow = int(event.get("follow",-1))
	fx.max_ms = float(event.get("max_ms",-1.0))
	fx.uniform_frame_ms = float(event.get("uniform_frame_ms",-1.0))
	fx.action_clock_at = float(event.get("action_clock_at",-1.0))
	fx.action_instance = int(event.get("action_instance",-1))
	fx.cue_key = key
	fx.repeat_from_ms = float(event.get("repeat_from_ms",-1.0))
	fx.loop = bool(event.get("loop",false)) and bool(_effects[key].get("loop",false))
	if bool(event.get("fresh",false)):fx.set_meta("particle_birth_pending",true)
	fx.setup(_effects[key],int(event["facing"]))
	fx.advance(0)
	effects.append(fx)

## Translucent copy of the player's pose at the moment an action is cancelled.
func _spawn_ghost(event: Dictionary) -> void:
	var node = ActorView.new()
	world.add_child(node)
	if _item_appearance_enabled:WeaponAppearance.apply(node,_weapon_item,_player_clips)
	else:setup_weapon_family(node,_weapon)
	node.shadow_width = 0
	node.position = _canvas(Vector2(event["pos"]), 0.0)
	node.z_index = int(Vector2(event["pos"]).y)-1
	node.present(String(event["ani"]),float(event["clock"]),int(event["facing"]),float(event["z"]),0.0,GHOST_TINT)
	ghosts.append({"node":node,"ms":0.0})

## Bitmap damage digits (sprite/common/etc/combo.img): monster damage white, damage taken red.
## Positions are canvas coordinates; the HUD subtracts the camera.
func _on_damage(event: Dictionary) -> void:
	if not event.get("show_number",true):return
	var point: Vector3 = event["point"]
	if event.get("id","") == "bloody_rave_thirst":
		numbers.append({"pos":Vector2(point.x,point.y+Frame.MAP_DY-point.z),"value":int(event["amount"]),
			"ms":0.0,"style":"thirst_damage","end_ms":1000.0})
		return
	var style := "damage_crit" if event.get("critical",false) else "damage"
	if String(event.get("victim","monster")) == "player":
		style = "damage_crit" if event.get("id","") == "poison" else "damage_taken"
	numbers.append({"pos":Vector2(point.x,point.y+Frame.MAP_DY)-Vector2(0,65+point.z),"value":int(event["amount"]),"ms":0.0,"style":style})

## map 坐标（角色/敌人/物件/特效）→ 画布坐标。
func _canvas(point: Vector2, height: float) -> Vector2:
	return Vector2(roundf(point.x), roundf(point.y+Frame.MAP_DY-height))
