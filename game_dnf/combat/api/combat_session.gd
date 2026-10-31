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

const SCENE := "res://scenes/main.tscn"
const FLOW_EVENTS := ["combat.monster_defeated", "combat.room_combat_finished", "combat.player_defeated"]

var game: Node

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

## Standalone battle scene registers itself so tests and tools observe the same signals.
func attach(existing: Node) -> void:
	game = existing
	_localize_monster_labels()
	_bind()

func start_room(spec: Dictionary) -> bool:
	if not _alive() or game.missing_assets:return false
	var player_spec: Dictionary=spec.get("player",{})
	if not preload("res://content/api/weapon_appearance.gd").valid_spec(player_spec):return false
	var route: Dictionary=spec.get("route",{})
	if route.has("map_export"):
		# Validate the complete route before changing the live map/table. Unknown
		# monsters must reject entry rather than silently vanishing from a room.
		var probe=game.map_loader.get_script().new()
		if not probe.load_export(String(route["map_export"])):return false
		var rooms=route.get("rooms",[])
		if not rooms is Array or rooms.is_empty():return false
		var placements: Array[Dictionary]=[]
		for i in rooms.size():
			var room: Dictionary=rooms[i]
			var found: Dictionary={}
			for placement: Dictionary in probe.placements():
				if placement["id"]==room.get("placement"):found=placement;break
			if found.is_empty():return false
			placements.append(found)
			for monster: Dictionary in probe.room(found["map"])["monsters"]:
				if game.table.monster_by_mob(String(monster["mob"]))=="":return false
			if i<rooms.size()-1 and room.get("next") not in ["left","right","up","down"]:return false
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
		game.map_loader.data=probe.data
		game.map_loader.base_dir=probe.base_dir
		game.map_loader.textures.clear()
	game.begin_room(spec)
	if player_spec.has("weapon_item"):game.view.set_equipped_weapon(String(player_spec["weapon_item"]))
	return true

## The outer UI owns configurable hotkeys; standalone battle keeps its own input.
func submit_key(code: int, pressed: bool, echo := false) -> void:
	if not _alive():return
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = pressed
	event.echo = echo
	game._input(event)

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
	var rooms: Array = game.rules["rooms"]
	var exit_target := Vector2.ZERO
	if game.room_cleared and not game.finished:exit_target = game.door_point(String(rooms[game.room_index]["next"]))
	return {"run_id":game.run_id,"room_id":game.room_id,"room_index":game.room_index,
		"time_ms":game.elapsed_ms,"death_id":game.last_defeat_id,"invulnerable_ms":float(p["invuln_ms"]),
		"revive_fx_count":game.view.revive_fx_count,
		"room":game.room_index+1,"room_count":rooms.size(),"room_name":String(rooms[game.room_index]["name"]),
		"hp":float(p["hp"]),"hp_max":game.max_hp,"mp":float(p["mp"]),"mp_max":game.max_mp,
		"pos":Vector2(p["pos"]),"camera_x":roundf(game.view.camera_x),"facing":int(p["facing"]),"job":game.job,"weapon":game.weapon,"weapon_item":String(game.view._weapon_item) if game.view._item_appearance_enabled else "",
		"attack_damage":game.attack_power(),
		"numbers":game.numeric_player.values.duplicate(true) if game.numeric_player != null else {},
		"sources":game.numeric_player.sources.duplicate(true) if game.numeric_player != null else {},
		"effects":game.numeric_player.effects.view() if game.numeric_player != null else [],
		"skills":game.skill_levels.duplicate(true),"last_damage":game.last_damage.duplicate(true),
		"cooldowns":Dictionary(p["cooldowns"]).duplicate(),"buff_ms":float(p["buff_ms"]),
		"enemies":enemies,"alive_monsters":enemies.size(),"exit_target":exit_target,
		"room_cleared":game.room_cleared,"finished":game.finished,"victory":game.victory,"paused":game.paused}

func events():
	return game.bus if _alive() else null

func _bind() -> void:
	for type: String in FLOW_EVENTS:
		game.bus.subscribe(type, _relay)

func _relay(event: Dictionary) -> void:
	match String(event["type"]):
		"combat.monster_defeated":monster_defeated.emit(event)
		"combat.room_combat_finished":room_combat_finished.emit(event)
		"combat.player_defeated":player_defeated.emit(event)

func _alive() -> bool:
	return game != null and is_instance_valid(game) and not game.is_queued_for_deletion()
