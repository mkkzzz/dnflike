extends RefCounted
## Public combat entry for the flow side. Contract: docs/design/29_新版工程框架_接口契约.md.
## F0/F1 wrap the transitional battle scene; the API stays when the World kernel replaces it.
## Usage:
##   var session = CombatSession.new()      # const CombatSession = preload("res://combat/api/combat_session.gd")
##   var node = session.mount(parent)        # external mode: no auto start, no self-restart
##   session.room_combat_finished.connect(...)
##   session.start_room({"run_id":"r1","room_id":"lorien:1","room_index":0,
##       "player":{"hp_max":500,"mp_max":180,"damage_multiplier":1.0,"weapon":"katana"}})

signal monster_defeated(event: Dictionary)
signal room_combat_finished(event: Dictionary)
signal player_defeated(event: Dictionary)
signal companion_defeated(event: Dictionary)
signal prop_loot_released(event: Dictionary)

const SCENE := "res://scenes/main.tscn"
const FLOW_EVENTS := ["combat.monster_defeated", "combat.room_combat_finished", "combat.player_defeated", "combat.companion_defeated", "combat.prop_loot_released"]
const SkillSlots = preload("res://stats/api/skill_slots.gd")
const NativeMaze = preload("res://combat/data/native_maze.gd")
const NativeBreakable = preload("res://combat/resolve/native_breakable.gd")
const NativePotMonsters = preload("res://combat/resolve/native_pot_monsters.gd")
const NativeJarTraps = preload("res://combat/resolve/native_jar_traps.gd")
const NativeZealotSummons = preload("res://combat/resolve/native_zealot_summons.gd")
const DetRng = preload("res://core/det_rng.gd")

var game: Node
var last_start_error := ""

func mount(parent: Node, external := true) -> Node:
	game = (load(SCENE) as PackedScene).instantiate()
	game.external_mode = external
	parent.add_child(game)
	_localize_monster_labels()
	_bind()
	return game

## Display-only labels from the flow's source-text data; registration/AI stay owned by ws1.
func _localize_monster_labels() -> void:
	var path: String="res://data/monster_names_zh.json"
	if not FileAccess.file_exists(path):return
	var doc=JSON.parse_string(FileAccess.get_file_as_string(path))
	if not doc is Dictionary or doc.get("schema")!="dnf_monster_labels/1":return
	for definition: Dictionary in game.table.monsters.values():
		definition["name"]=doc["labels"].get(definition.get("mob",""),definition["name"])

## Headless combat-test harness registers itself so tests observe the same signals.
func attach(existing: Node) -> void:
	game = existing
	_localize_monster_labels()
	_bind()

## The flow owns the inventory and commits the cost synchronously before action entry.
func set_skill_material_spender(spend: Callable) -> void:
	if _alive():game.skill_material_spender = spend

func start_room(spec: Dictionary) -> bool:
	last_start_error = ""
	if not _alive() or game.missing_assets:return false
	var player_spec: Dictionary=spec.get("player",{})
	if not preload("res://content/api/weapon_appearance.gd").valid_spec(player_spec):return false
	var route: Dictionary=spec.get("route",{})
	var maze: NativeMaze
	if route.get("mode","") == "native_maze":
		if not route.has("map_export"):
			last_start_error = "native_maze route has no map export"
			return false
		var probe = game.map_loader.get_script().new()
		if not probe.load_export(String(route["map_export"])):
			last_start_error = "native_maze export failed to load"
			return false
		maze = NativeMaze.new()
		if not maze.start(probe.data,DetRng.new(hash(String(spec.get("run_id","standalone")))),
				route.get("source",{})):
			last_start_error = "native_maze preparation: " + maze.last_error
			return false
		if not game.prepare_native_box_loot(probe.data["dungeon"]):
			last_start_error = "native box loot dependency failed"
			return false
		if not NativeJarTraps.ready(game.combat_assets):
			last_start_error = "native jar trap dependency failed"
			return false
		if not _validate_native_maze(probe,maze) or not game.view.audio.has_dungeon_music(String(spec["dungeon"])):
			if last_start_error.is_empty():last_start_error = "native maze BGM dependency failed"
			return false
		NativePotMonsters.prepare_catalog(probe.data["dungeon"],
			DetRng.new(hash(String(spec.get("run_id","standalone"))+":pot-catalog")))
		_use_map_export(probe)
	elif not route.has("map_export") and game.native_maze != null:
		var probe = game.map_loader.get_script().new()
		if not probe.load_export(String(game.content.rules()["map_export"])):return false
		game.rules = game.rules.duplicate(true)
		game.rules["rooms"] = game.content.rules()["rooms"].duplicate(true)
		_use_map_export(probe)
	elif route.has("map_export"):
		# Validate the complete route before changing the live map/table. Unknown
		# monsters must reject entry rather than silently vanishing from a room.
		var probe=game.map_loader.get_script().new()
		if not probe.load_export(String(route["map_export"])):return false
		var rooms=route.get("rooms",[])
		if not rooms is Array or rooms.is_empty():return false
		var placements: Array[Dictionary]=[]
		var companion_ids: Array[int] = []
		for i in rooms.size():
			var room: Dictionary=rooms[i]
			var found: Dictionary={}
			for placement: Dictionary in probe.placements():
				if placement["id"]==room.get("placement"):found=placement;break
			if found.is_empty():return false
			placements.append(found)
			var map: Dictionary = probe.room(found["map"])
			for monster: Dictionary in map["monsters"]:
				if game.table.monster_by_mob(String(monster["mob"]))=="":return false
			for companion: Dictionary in map.get("companions",[]):
				if not game.can_spawn_companion(companion):return false
				companion_ids.append(int(companion["source_id"]))
			if i<rooms.size()-1 and room.get("next") not in ["left","right","up","down"]:return false
		if route.has("companion_id") and int(route["companion_id"]) not in companion_ids:return false
		if not rooms[-1].get("boss",false):return false
		var opposite := {"left":"right","right":"left","up":"down","down":"up"}
		for i in range(rooms.size()-1):
			var direction: String=rooms[i]["next"]
			var reciprocal := false
			var forward := false
			for gate: Dictionary in placements[i]["gates"]:
				if gate["direction"]==direction and gate["target_cell"]==placements[i+1]["cell"] and gate["anchor"]!=null:forward=true
			for gate: Dictionary in placements[i+1]["gates"]:
				if gate["direction"]==opposite[direction] and gate["target_cell"]==placements[i]["cell"] and gate["anchor"]!=null:reciprocal=true
			if not forward or not reciprocal:return false
		game.rules=game.rules.duplicate(true)
		game.rules["rooms"]=rooms.duplicate(true)
		_use_map_export(probe)
	game.begin_room(spec,maze)
	if player_spec.has("weapon_item"):game.view.set_equipped_weapon(String(player_spec["weapon_item"]))
	return true

func _use_map_export(loader) -> void:
	game.map_loader.data = loader.data
	game.map_loader.base_dir = loader.base_dir
	game.map_loader.textures.clear()
	game.map_loader.errors.clear()

func _validate_native_maze(loader, maze: NativeMaze) -> bool:
	if maze.basis_level <= 0:
		last_start_error = "native maze basis level is missing"
		return false
	var pending: Array[String] = []
	var checked := {}
	var checked_props := {}
	for path: String in maze.required_map_paths():
		var room: Dictionary = loader.room(path)
		for monster: Dictionary in room["monsters"]:
			var mob := String(monster["mob"])
			if mob not in pending:pending.append(mob)
		for companion: Dictionary in room.get("companions",[]):
			if not game.can_spawn_companion(companion):
				last_start_error = "native maze companion dependency missing in " + path
				return false
		for item: Dictionary in room.get("objects",[]):
			if not NativeBreakable.supports(item):continue
			for child: Dictionary in NativePotMonsters.rows(item):
				var mob := String(child["mob"])
				if mob not in pending:pending.append(mob)
			var obj := String(item["obj"])
			var source: Dictionary = game.content.record(obj).get("native_breakable",{})
			if source.is_empty():continue
			if int(source["object_index"]) != int(item["id"]):
				last_start_error = "native breakable object index mismatch for " + obj
				return false
			var sprite: Dictionary = item.get("sprite",{})
			if sprite.get("ani") != source["motion_ani"] or sprite.get("ani_sha256") != source["source_hashes"][source["motion_ani"]]:
				last_start_error = "native breakable sprite mismatch for " + obj
				return false
			if not checked_props.has(obj):
				if not _validate_native_breakable(source):return false
				checked_props[obj] = true
	while not pending.is_empty():
		var mob: String = pending.pop_front()
		if checked.has(mob):continue
		checked[mob] = true
		var kind: String = game.table.monster_by_mob(mob)
		if kind == "":
			last_start_error = "native maze monster runtime missing: " + mob
			return false
		var definition: Dictionary = game.table.monsters[kind]
		var bank: Dictionary = game.combat_assets.get("monsters",{}).get(definition["bank"],{})
		var texture := String(bank.get("atlas",{}).get("texture",""))
		if texture == "" or not ResourceLoader.exists(texture,"Texture2D"):
			last_start_error = "native maze monster atlas missing: " + mob
			return false
		if mob in NativeZealotSummons.CASTERS:
			var summon: Dictionary = definition.get("native_spirit_summon",{})
			if not _validate_zealot_summon(summon,bank):return false
			var spirit: String = summon["mob"]
			if spirit not in pending:pending.append(spirit)
		for child: String in definition.get("native_suicide",{}).get("spawn",{}).get("mobs",[]):
			if child not in pending:pending.append(child)
	for image: Dictionary in loader.data["images"].values():
		if not FileAccess.file_exists(loader.base_dir.path_join(String(image["file"]))):
			last_start_error = "native map image missing: " + String(image["file"])
			return false
	return true

func _validate_zealot_summon(summon: Dictionary, actor_bank: Dictionary) -> bool:
	if summon.is_empty() or not actor_bank.get("clips",{}).has("cast"):return false
	if float(summon["cast_duration_ms"]) <= 0.0 or float(summon["cast_rate"]) <= 0.0:return false
	if not NativeJarTraps.has_bank(game.combat_assets,summon["proxy_bank"]):return false
	var proxy_bank: Dictionary = game.combat_assets["effects"][summon["proxy_bank"]]
	if proxy_bank.get("source") != summon["proxy_ani"] or proxy_bank.get("duration_ms") != summon["proxy_duration_ms"]:return false
	if summon["cast_layers"].size() != 3:return false
	for layer: Dictionary in summon["cast_layers"]:
		if not NativeJarTraps.has_bank(game.combat_assets,layer["bank"]):return false
	return NativeJarTraps.has_sound(game.combat_assets,summon["cast_sound"])

func _validate_native_breakable(source: Dictionary) -> bool:
	var timeline: Array = game.table.timeline(source["motion_ani"])
	if timeline.is_empty() or timeline[0].get("damage_boxes", []).is_empty():
		last_start_error = "native breakable timeline invalid: " + String(source["motion_ani"])
		return false
	var boxes: Array = timeline[0]["damage_boxes"]
	for frame: Dictionary in timeline:
		if frame.get("damage_boxes", []) != boxes:
			last_start_error = "native breakable animated hitbox unsupported: " + String(source["motion_ani"])
			return false
	var particle := String(source["destroy_particle"])
	var template: Dictionary = game.combat_assets.get("particles",{}).get(particle,{})
	var pinned: bool = source.get("source",{}).has("factory")
	if pinned and template.is_empty():
		last_start_error = "native breakable particle template missing: " + particle
		return false
	if not template.is_empty():
		if template.get("sha256") != source["source_hashes"][particle]:
			last_start_error = "native breakable particle mismatch: " + particle
			return false
		var textures := {}
		for bank: Dictionary in game.combat_assets.get("effects",{}).values():
			if bank.has("source"):textures[bank["source"]] = bank.get("atlas",{}).get("texture","")
		for entry: Dictionary in template["decoded"]["object_entries"]:
			if not ResourceLoader.exists(String(textures.get(entry["path"],"")),"Texture2D"):
				last_start_error = "native breakable particle atlas missing: " + String(entry["path"])
				return false
	else:
		var keys: Array = game.breakable_particle_keys(String(source.get("object_path","")))
		if keys.is_empty():
			last_start_error = "native breakable particle banks missing: " + particle
			return false
		for key in keys:
			var texture := String(game.combat_assets.get("effects",{}).get(String(key),{}).get("atlas",{}).get("texture",""))
			if not ResourceLoader.exists(texture,"Texture2D"):
				last_start_error = "native breakable effect atlas missing: " + String(key)
				return false
	var hit_sound := String(source.get("hit_sound",""))
	if hit_sound.is_empty():return true
	for clip: Dictionary in game.combat_assets.get("audio",{}).get(hit_sound,[]):
		if ResourceLoader.exists(String(clip.get("file","")),"AudioStream"):return true
	last_start_error = "native breakable hit sound missing: " + hit_sound
	return false

## The outer flow owns configurable hotkeys; the internal test harness uses this bridge.
func submit_key(code: int, pressed: bool, echo := false) -> void:
	if not _alive():return
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = pressed
	event.echo = echo
	game._input(event)

## The flow owns drag-and-drop slot order; submit by slot rather than translating
## the skill back to its historical canonical key.
func submit_skill(index: int, pressed: bool, echo := false) -> void:
	if index < 0 or index >= SkillSlots.COUNT:return
	submit_key(SkillSlots.KEYS[index], pressed, echo)

func configure_trial(movement_scale: float, difficulty: String) -> void:
	if not _alive():return
	# Per-session copy: increase player locomotion only, leaving MOB tables intact.
	game.rules = game.rules.duplicate(true)
	game.rules["player"]["walk_speed"] *= movement_scale
	game.rules["player"]["run_speed"] *= movement_scale
	if game.numeric_player != null:
		game.configure_monster_numbers(game.numeric_monster_level,difficulty)
		return
	var factor: float = {"normal":1.0, "adventure":1.25, "expert":1.5, "king":1.75}.get(difficulty, 1.0)
	game.table.monsters = game.table.monsters.duplicate(true)
	for monster: Dictionary in game.table.monsters.values():
		monster["hp"] *= factor
		monster["attack"] *= factor
	for enemy: Dictionary in game.monsters:
		enemy["hp"] *= factor
		enemy["max_hp"] *= factor
		enemy["attack"] *= factor

## Pausing also drops held keys and buffered presses so nothing fires on resume.
func pause() -> void:
	if _alive():game.set_input_paused(true)

func resume() -> void:
	if _alive() and not game.finished:game.set_input_paused(false)

func set_paused(value: bool) -> void:
	if value:pause()
	else:resume()

## Effect already validated and paid for by the flow side, e.g. {"kind":"heal","amount":150}.
func can_apply_effect(effect: Dictionary) -> bool:
	if not _alive() or game.player.is_empty() or game.finished or game.paused:return false
	if effect.get("kind")=="restore":return preload("res://combat/item_restoration.gd").can_apply(game,effect)
	var amount=effect.get("amount")
	return effect.get("kind")=="heal" and (amount is int or amount is float) and is_finite(float(amount)) and amount>0 and float(game.player["hp"])>0 and float(game.player["hp"])<game.max_hp

func apply_effect(effect: Dictionary) -> bool:
	return _alive() and game.apply_effect(effect)

func can_revive(spec: Dictionary) -> bool:
	return _alive() and game.can_revive(spec)

func revive(spec: Dictionary) -> bool:
	return _alive() and game.revive_player(spec)

func update_numbers(spec: Dictionary, vitals_policy := "preserve") -> bool:
	if not _alive():return false
	if not preload("res://content/api/weapon_appearance.gd").valid_spec(spec):return false
	if not game.update_numbers(spec,vitals_policy):return false
	if spec.has("weapon_item"):return game.view.set_equipped_weapon(String(spec["weapon_item"]))
	return true

func configure_monsters(level: int, difficulty := "normal") -> bool:
	return _alive() and game.configure_monster_numbers(level,difficulty)

func stop() -> void:
	if _alive():game.queue_free()
	game = null

func is_running() -> bool:
	return _alive() and not game.player.is_empty() and not game.finished

## Read-only copy for flow HUD, autopilot tests and potions. Never hands out internal dictionaries.
func read_view() -> Dictionary:
	if not _alive() or game.player.is_empty():return {}
	var p: Dictionary = game.player
	var enemies: Array = []
	for enemy: Dictionary in game.monsters:
		if float(enemy["hp"]) > 0:enemies.append({"id":enemy["id"],"pos":Vector2(enemy["pos"]),"hp":float(enemy["hp"]),"chief":enemy["chief"]})
	var room_count: int = game.route_room_count()
	var exit_target: Vector2 = game.route_exit_target(enemies.size())
	return {"run_id":game.run_id,"room_id":game.room_id,"room_index":game.room_index,
		"time_ms":game.elapsed_ms,"death_id":game.last_defeat_id,"invulnerable_ms":float(p["invuln_ms"]),
		"revive_fx_count":game.view.revive_fx_count,
		"room":game.route_room_number(),"room_count":room_count,"room_name":game.route_room_name(),
		"hp":float(p["hp"]),"hp_max":game.max_hp,"mp":float(p["mp"]),"mp_max":game.max_mp,
		"pos":Vector2(p["pos"]),"camera_x":roundf(game.view.camera_x),"facing":int(p["facing"]),"job":game.job,"weapon":game.weapon,"weapon_item":String(game.view._weapon_item) if game.view._item_appearance_enabled else "",
		"attack_damage":game.attack_power(),
		"numbers":game.numeric_player.values.duplicate(true) if game.numeric_player != null else {},
		"sources":game.numeric_player.sources.duplicate(true) if game.numeric_player != null else {},
		"effects":game.numeric_player.effects.view() if game.numeric_player != null else [],
		"skills":game.skill_levels.duplicate(true),"last_damage":game.last_damage.duplicate(true),
		"cooldowns":Dictionary(p["cooldowns"]).duplicate(),"buff_ms":float(p["buff_ms"]),
		"enemies":enemies,"companions":game.companion_views(),"alive_monsters":enemies.size(),"exit_target":exit_target,
		"room_cleared":game.room_is_open(enemies.size()),"finished":game.finished,"victory":game.victory,"paused":game.paused}

## Lightweight per-frame view for HUD/loot consumers. It intentionally omits
## full numeric sources, learned skills and effect values; those belong to the
## inspection UI and must not be deep-copied every render tick.
func read_runtime_view() -> Dictionary:
	if not _alive() or game.player.is_empty():return {}
	var p: Dictionary = game.player
	var enemies: Array = []
	for enemy: Dictionary in game.monsters:
		if float(enemy["hp"]) <= 0:continue
		enemies.append({"id":enemy["id"],"pos":Vector2(enemy["pos"]),"hp":float(enemy["hp"]),"chief":enemy["chief"]})
	var room_count: int = game.route_room_count()
	var exit_target: Vector2 = game.route_exit_target(enemies.size())
	var reckless_timer := Vector2i.ZERO
	var reckless: Dictionary = game.active_effect("reckless")
	if not reckless.is_empty() and float(p["hp"]) > 0.0:
		reckless_timer = Vector2i(int(reckless["remaining_ms"]),int(reckless["definition"]["duration_ms"]))
	return {"run_id":game.run_id,"room_id":game.room_id,"room_index":game.room_index,
		"time_ms":game.elapsed_ms,"death_id":game.last_defeat_id,"invulnerable_ms":float(p["invuln_ms"]),
		"revive_fx_count":game.view.revive_fx_count,
		"room":game.route_room_number(),"room_count":room_count,"room_name":game.route_room_name(),
		"hp":float(p["hp"]),"hp_max":game.max_hp,"mp":float(p["mp"]),"mp_max":game.max_mp,
		"pos":Vector2(p["pos"]),"camera_x":roundf(game.view.camera_x),"facing":int(p["facing"]),
		"player_state":String(p["state"]),"player_z":float(p["z"]),"player_vz":float(p["vz"]),
		"job":game.job,"weapon":game.weapon,"weapon_item":String(game.view._weapon_item) if game.view._item_appearance_enabled else "",
		"cooldowns":Dictionary(p["cooldowns"]).duplicate(),"buff_ms":float(p["buff_ms"]),"reckless_timer":reckless_timer,
		"enemies":enemies,"companions":game.companion_views(),"alive_monsters":enemies.size(),"exit_target":exit_target,
		"room_cleared":game.room_is_open(enemies.size()),"finished":game.finished,"victory":game.victory,"paused":game.paused}

func events():
	return game.bus if _alive() else null

func _bind() -> void:
	for type: String in FLOW_EVENTS:
		game.bus.subscribe(type, _relay)

func _relay(event: Dictionary) -> void:
	match String(event["type"]):
		"combat.monster_defeated":monster_defeated.emit(event)
		"combat.prop_loot_released":prop_loot_released.emit(event)
		"combat.room_combat_finished":room_combat_finished.emit(event)
		"combat.player_defeated":player_defeated.emit(event)
		"combat.companion_defeated":companion_defeated.emit(event)

func _alive() -> bool:
	return game != null and is_instance_valid(game) and not game.is_queued_for_deletion()
