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
	_bind()
	return game

## Standalone battle scene registers itself so tests and tools observe the same signals.
func attach(existing: Node) -> void:
	game = existing
	_bind()

func start_room(spec: Dictionary) -> bool:
	if not _alive() or game.missing_assets:return false
	game.begin_room(spec)
	return true

## Pausing also drops held keys and buffered presses so nothing fires on resume.
func pause() -> void:
	if _alive():game.set_input_paused(true)

func resume() -> void:
	if _alive() and not game.finished:game.set_input_paused(false)

func set_paused(value: bool) -> void:
	if value:pause()
	else:resume()

## Effect already validated and paid for by the flow side, e.g. {"kind":"heal","amount":150}.
func apply_effect(effect: Dictionary) -> bool:
	return _alive() and game.apply_effect(effect)

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
		"room":game.room_index+1,"room_count":rooms.size(),"room_name":String(rooms[game.room_index]["name"]),
		"hp":float(p["hp"]),"hp_max":game.max_hp,"mp":float(p["mp"]),"mp_max":game.max_mp,
		"pos":Vector2(p["pos"]),"facing":int(p["facing"]),"job":game.job,"weapon":game.weapon,
		"attack_damage":float(game.rules["moves"]["attack1"]["damage"])*game.damage_scale,
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
