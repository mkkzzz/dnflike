extends RefCounted

func run(main, check: Callable, frames: Callable) -> void:
	var p: Player = main.player
	main.gm_panel.close()
	main._enter_dungeon("10001")
	await frames.call(3)
	main._toggle_pause()
	check.call(main.get_tree().paused and main.resume_state == main.BattleState.ROOM_CLEAR, "dungeon cleared-room pause freezes the game")
	main._toggle_pause()
	check.call(p.control_enabled and not main.get_tree().paused, "cleared-room resume restores control")
	main._toggle_display_settings()
	main._toggle_display_settings()
	check.call(not main._shade.visible and not main._card.visible and not main.get_tree().paused, "closing dungeon settings restores the previous overlay state")
	main.elapsed = 65.0
	main._process(0.0)
	check.call(main.hud.elapsed == main.elapsed, "dungeon HUD receives current run time")
	main._reset_battle()
	check.call(main.dungeon_mode and main.dungeon.room_number() == 1, "dungeon reset keeps dungeon mode")
	main._finish_dungeon(true)
	main.gm_panel.open()
	main.gm_panel._input.grab_focus()
	await frames.call(3)
	main.gm_panel.close()
	await frames.call(3)
	check.call(p.control_enabled and not p.dead, "GM typing after victory restores player movement")
	var enter := InputEventAction.new()
	enter.action = "start_demo"
	enter.pressed = true
	main._unhandled_input(enter)
	check.call(main.dungeon_mode and not main.dungeon_finished, "settlement Enter retries the current dungeon")

	main._on_gm_command("room", PackedStringArray(["2"]))
	await frames.call(2)
	for monster in main.monsters:
		check.call(monster.arena_left == p.arena_left and monster.arena_right == p.arena_right, "dungeon monster arena follows the painted road")
	check.call(main.monsters[2].position.x > 1216.0, "wide-room monster spawn stays beyond the old single-screen limit")
	p.hp = 123.0
	p.mp = 17.0
	p.cds["upper"] = 180
	p.buff_data = {"atk_speed": 1.12}
	p.buff_t = 90.0
	main.monsters[0]._die()
	var killed: int = main.kills
	main._retreat_room()
	check.call(p.hp == 123.0 and p.mp == 17.0 and int(p.cds["upper"]) == 180 and p.buff_t == 90.0, "door travel preserves health mana cooldowns and buffs")
	check.call(main.dungeon.room_number() == 1 and p.position.x > p.arena_right - 160.0 and p.facing == -1, "left return door arrives beside the previous room right door")
	check.call(not main.current_door.contains_actor(Vector2(p.position.x, main.GROUND_Y + p.depth_y)), "return spawn lies outside the destination door trigger")
	main._advance_room()
	check.call(main.alive_count() == 2 and main.kills == killed, "revisiting an uncleared room preserves defeated enemies and kill count")
	main._on_gm_command("room", PackedStringArray(["3"]))
	check.call(float(main.monsters[0].cfg["attack_move"]["damage"]) == 38.0, "elite attack move uses its configured damage")
	main._retreat_room()
	check.call(main.dungeon.room_number() == 2 and p.depth_y < main.room_depth_min + 160.0, "returning from the down door arrives at the previous room up door")

	var config: Dictionary = main.dungeon_config.duplicate(true)
	config["dungeons"]["10001"]["connections"][0]["from_side"] = "up"
	config["dungeons"]["10001"]["connections"][0]["to_side"] = "down"
	var run_state := DungeonRun.new()
	check.call(run_state.load_from(config, "10001"), "vertical paired door configuration is accepted")
	var id := str(run_state.connections()[0]["id"])
	var arrival := run_state.travel(id)
	check.call(run_state.room_index == 1 and str(arrival["side"]) == "down", "up door arrives at the target down door")
	arrival = run_state.travel(id)
	check.call(run_state.room_index == 0 and str(arrival["side"]) == "up", "down return arrives at the original up door")
	var door := DungeonDoor.new()
	main.add_child(door)
	for side in ["left", "right", "up", "down"]:
		door.setup(side, Vector2(500, 500), GameConfig.runtime["doors"])
		var rect := door.reach_rect()
		check.call(door.contains_actor(rect.get_center()) and not door.contains_actor(door.spawn_point(30.0)), "door trigger and safe spawn support " + side)
		check.call(is_zero_approx(door.rotation), "door art is never rotated: " + side)
	door.setup("right", Vector2(500, 500), GameConfig.runtime["doors"])
	check.call(door.uses_texture(), "side door uses the shared closed/open art")
	door.setup("up", Vector2(500, 500), GameConfig.runtime["doors"])
	check.call(door.uses_texture() and is_zero_approx(door.rotation), "up door loads its directional art without rotation")
	check.call(door.z_for_layers(GameConfig.runtime["layering"]) == int(GameConfig.runtime["layering"]["door_z"]), "up door stays behind actors")
	door.setup("down", Vector2(500, 500), GameConfig.runtime["doors"])
	check.call(door.uses_texture() and is_zero_approx(door.rotation), "down door loads its half-height art without rotation")
	check.call(door.z_for_layers(GameConfig.runtime["layering"]) == int(GameConfig.runtime["layering"]["effects_z"]) - 1, "down door renders in the foreground")
	var bare_cfg: Dictionary = GameConfig.runtime["doors"].duplicate(true)
	bare_cfg["art"] = {}
	door.setup("up", Vector2(500, 500), bare_cfg)
	check.call(not door.uses_texture(), "up door falls back to procedural when art is missing")
	var side_only_cfg: Dictionary = GameConfig.runtime["doors"].duplicate(true)
	var side_only_art: Dictionary = (side_only_cfg["art"] as Dictionary).duplicate(true)
	side_only_art.erase("by_side")
	side_only_cfg["art"] = side_only_art
	door.setup("down", Vector2(500, 500), side_only_cfg)
	check.call(not door.uses_texture(), "down door never borrows the side-view art")
	door.queue_free()

	main._enter_dungeon("10001")
	# 小地图必须按门方向排版：10001-A 是 右→上→右→上，
	# 曾被"只认 top/bottom、把 up 退化成 RIGHT"搞成整条横线。
	main._process(0.0)
	var map_pos: Array = main.hud._map_positions
	check.call(map_pos.size() == 5, "minimap has one node per dungeon room")
	if map_pos.size() == 5:
		check.call(map_pos[2] == map_pos[1] + Vector2(0, -1), "minimap stacks the room after an up door directly above")
		check.call(map_pos[3] == map_pos[2] + Vector2(1, 0), "minimap keeps a right door horizontal after an up door")
		check.call(map_pos[4] == map_pos[3] + Vector2(0, -1), "minimap stacks the final boss room above the fourth room")
	# 只显示走过的房间；未清房不提示可去；清房后只闪烁直连房间（含回程）
	check.call(main.hud._map_visited.has(0) and not main.hud._map_visited.has(4), "unvisited rooms stay hidden on the minimap")
	check.call(main.hud._map_available.has(1) and not main.hud._map_available.has(2), "cleared entrance blinks only its directly connected room")
	var map_run := DungeonRun.new()
	map_run.load_from(main.dungeon_config, "10001")
	map_run.room_index = 1
	map_run.mark_room_cleared(1)
	check.call(map_run.available_rooms().has(0) and map_run.available_rooms().has(2), "cleared middle room reaches its back door and the next room")
	map_run.room_index = 2
	check.call(map_run.available_rooms().is_empty(), "an uncleared room offers no travel target")
	var stump: DungeonEntity
	var bush: DungeonEntity
	for entity in main.room_root.get_children():
		if entity is DungeonEntity:
			if entity.entity_id == "stump":
				stump = entity
			if entity.entity_id == "bush":
				bush = entity
	var start := Vector2(stump.position.x - 180.0, stump.actor_depth - 14.0)
	var blocked: Vector2 = main.ground_space.resolve(p, start, start + Vector2(400, 0))
	check.call(blocked.x < stump.position.x - 60.0 and blocked.y == start.y, "continuous root sweep blocks fast horizontal motion without changing depth")
	p.position = Vector2(start.x, main.GROUND_Y)
	p.depth_y = start.y
	p.set_job(2)
	p._try_skill_action("skill_a")
	await frames.call(50)
	check.call(p.position.x < stump.position.x - 60.0 and absf(p.depth_y - start.y) < 0.1, "real quick draw cannot bypass the root by changing depth")
	p.relocate_combat(Vector2(bush.position.x, main.GROUND_Y), bush.front_depth_at(bush.position.x) - 10.0)
	await frames.call(3)
	var nearest: Sprite2D
	var distance := INF
	for slice in bush.render_slices:
		var dx := absf(float(slice.get_meta("ground_x")) - p.position.x)
		if dx < distance:
			distance = dx
			nearest = slice
	check.call(nearest != null and p.z_index < nearest.z_index, "nearby rear feet remain behind the actual calibrated entity image slice")
	p.depth_y = bush.front_depth_at(p.position.x) + 10.0
	await frames.call(3)
	check.call(p.z_index > nearest.z_index, "nearby front feet draw above the actual calibrated entity image slice")
	check.call(main.seq_fx._dim_layer.z_index < p.z_index, "quick-draw background dim stays below rear actors")

	# 可破坏场景物（草丛）：配置驱动 -> 受击一次破碎 -> 从玩家命中列表与地面阻挡里摘除
	check.call(bush.destructible and not bush.destroyed, "bush is configured destructible and starts intact")
	check.call(main.destructibles.has(bush) and p.destructibles.size() == main.destructibles.size(), "destructible props share the player's hit list")
	check.call(bush.world_hit_rect().has_area(), "destructible prop exposes a world hit rect for melee")
	# 关键：必须走**真实 V6 命中路径**（三段普攻/拔刀斩用的是 _seq_hit，不是 _emit_melee）。
	# 第一版只改了 _emit_melee，导致游戏里普攻砍不碎草丛，这条断言就是防它复发。
	# 玩家停在路面默认深度（0），草丛在 -50：这正是实机砍不碎的情形。
	# 可破坏物用专用的宽松容差（destructible.lane，默认 60），不套打怪的 24。
	p.relocate_combat(Vector2(bush.position.x - 90.0, main.GROUND_Y), 0.0)
	p.facing = 1
	p.buffer_action("attack")
	await frames.call(50)
	check.call(bush.destroyed and not bush.collision_enabled, "a real attack input breaks destructible props at default depth")
	var bush_destroyed := bush.destroyed
	check.call(bush.render_slices.is_empty(), "destroyed prop stops rendering its intact slices")
	main._on_prop_destroyed(bush)
	check.call(not main.destructibles.has(bush), "destroyed prop is removed from the shared hit list")

	main._finish_dungeon(true)
	var result: Dictionary = main._last_result.duplicate(true)
	main._finish_dungeon(false)
	check.call(main._last_result == result, "dungeon settlement cannot be replaced by a second finish")
	main._on_retry_dungeon()
	p.invincible = 0
	p.take_hit(p.hp + 1.0, 1, {})
	check.call(main.dungeon_finished and main.battle_state == main.BattleState.DEFEAT, "real dungeon death reaches defeat settlement")
	main._on_retry_dungeon()
	check.call(not p.dead and not main.dungeon_finished and p.hp == p.cfg["max_hp"], "retry after dungeon death resets only the new run")
	main._show_ready()
