extends RefCounted
## Public combat entry for the flow side (ws2). Contract: docs/design/29_新版工程框架_接口契约.md.
## F0 wraps the transitional battle scene; the API stays when the World kernel replaces it.
## Usage:
##   var session = CombatSession.new()      # const CombatSession = preload("res://combat/api/combat_session.gd")
##   session.mount(parent)                   # external mode: no auto start, no self-restart
##   session.monster_defeated.connect(...)
##   session.start_room({"run_id":"r1","room_id":"lorien:1","room_index":0,"player":{"hp":500,"mp":180}})

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

func pause() -> void:
	if _alive():game.paused = true

func resume() -> void:
	if _alive() and not game.finished:game.paused = false

func stop() -> void:
	if _alive():game.queue_free()
	game = null

func is_running() -> bool:
	return _alive() and not game.player.is_empty() and not game.finished

## Read-only view for HUD/flow. Never hand out internal dictionaries.
func read_view() -> Dictionary:
	if not _alive() or game.player.is_empty():return {}
	var p: Dictionary = game.player
	var alive := 0
	for enemy: Dictionary in game.monsters:
		if float(enemy["hp"]) > 0:alive += 1
	return {"run_id":game.run_id,"room_id":game.room_id,"room_index":game.room_index,
		"hp":float(p["hp"]),"hp_max":float(game.rules["player"]["hp"]),
		"mp":float(p["mp"]),"mp_max":float(game.rules["player"]["mp"]),
		"job":game.job,"weapon":game.weapon,"cooldowns":Dictionary(p["cooldowns"]).duplicate(),
		"buff_ms":float(p["buff_ms"]),"alive_monsters":alive,"room_cleared":game.room_cleared,
		"finished":game.finished,"victory":game.victory,"paused":game.paused}

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
