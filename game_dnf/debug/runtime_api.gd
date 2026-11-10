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

func spawn_current(count: int) -> int:
	var kinds: Array[String] = []
	for row: Dictionary in game.room_map.get("monsters",[]):
		var kind: String=game.table.monster_by_mob(String(row.get("mob","")))
		if kind!="" and kind not in kinds:kinds.append(kind)
	if kinds.is_empty():kinds.append("goblin")
	game.room_cleared=false
	game.room_snapshots.erase(game.room_index)
	for index in count:
		var side := 1 if index % 2 == 0 else -1
		spawn_monster(Vector2(p("pos"))+Vector2(side*(90+(index/2)*34),18+(index%3)*12),
			kinds[index%kinds.size()],false)
	return kinds.size()

func lose() -> void:
	set_god(false)
	set_p("invuln_ms", 0.0)
	set_p("state", "idle")
	set_p("z", 0.0)
	damage_player(game.max_hp * 10, Vector2(p("pos")) - Vector2(100, 0))

func has_weapon(id: String) -> bool:return game.assets["players"].has(id)
func set_weapon(id: String) -> void:game.weapon = id
