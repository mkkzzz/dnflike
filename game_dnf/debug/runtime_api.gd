extends "res://debug/test_api.gd"
## Only this debug adapter touches transitional combat internals for GM actions.
func heal() -> void:
	set_p("hp", game.max_hp)
	set_p("mp", game.max_mp)

func reset_cooldowns() -> void:game.player["cooldowns"].clear()
func god() -> bool:return game.god_mode
func collision() -> bool:return game.show_collision
func set_collision(enabled: bool) -> void:
	game.show_collision = enabled
	game.view.set_debug_collision(enabled)

func spawn(kind: String, count: int) -> void:
	game.room_cleared = false
	game.room_snapshots.erase(game.room_index)
	for i in count:
		spawn_monster(Vector2(p("pos")) + Vector2(90 + (i % 5) * 35, (i / 5) * 22), "goblin_thrower" if kind == "thrower" else "goblin", kind == "chief")

func lose() -> void:
	set_god(false)
	set_p("invuln_ms", 0.0)
	set_p("state", "idle")
	set_p("z", 0.0)
	damage_player(game.max_hp * 10, Vector2(p("pos")) - Vector2(100, 0))

func has_weapon(id: String) -> bool:return game.assets["players"].has(id)
func set_weapon(id: String) -> void:game.weapon = id
