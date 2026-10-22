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
func view_texture() -> String:return String(game.player_view.bank["texture"])
func view_pose() -> String:return game.player_view.pose
func run_direction() -> int:return game.run_direction
func clear_direction_taps() -> void:game.last_direction_tap.clear()
func set_hitstop(ms: float) -> void:game.hitstop_ms = ms

# --- combat bookkeeping ---
func hit_count() -> int:return game.hit_count
func combo_count() -> int:return game.combo_count
func effect_count() -> int:return game.effects.size()

# --- monsters ---
## Replaces all monsters with one durable dummy and returns its opaque handle.
func spawn_dummy(point: Vector2) -> Dictionary:
	for enemy: Dictionary in game.monsters:
		enemy["visual"].queue_free()
	game.monsters.clear()
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
func stage_cleared() -> bool:return game.stage.cleared
func load_room(index: int, side: String) -> void:game.load_room(index,side)
func door_point(side: String) -> Vector2:return game.door_point(side)
func unlock_doors() -> void:game.door_lock_ms = 0.0
func prop(index: int, key: String):return game.props[index][key]
func set_prop(index: int, key: String, value) -> void:game.props[index][key] = value
func prop_view_z(index: int) -> int:return game.prop_views[index].z_index
func move_in_world(from: Vector2, delta: Vector2) -> Vector2:return game.move_in_world(from,delta)
