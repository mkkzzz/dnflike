extends "res://scripts/main.gd"
## Temporary port ONLY. Existing battle remains playable while ws1 builds F0 API.
## All knowledge of legacy internals lives here; town/session/UI never read them.
signal flow_event(event: Dictionary)
var managed_run_id := ""
var reported := false

func _ready() -> void:
	super._ready()
	if hud:hud.hide()
	if music:music.volume_db = -32
	if "--loop-test" in OS.get_cmdline_user_args() and DisplayServer.get_name() == "headless":
		_muted = true
		music.stop()
	get_window().title = "艾尔文防线 · 冒险循环"

func start_run(run_data: Dictionary) -> void:
	managed_run_id = String(run_data["id"])
	reported = false
	var stat: Dictionary = run_data["stats"]
	rules = rules.duplicate(true)
	rules["player"]["hp"] = stat["hp"]
	rules["player"]["mp"] = stat["mp"]
	var baseline: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/combat.json"))
	for key: String in rules["moves"]:
		rules["moves"][key]["damage"] = float(baseline["moves"][key]["damage"]) * float(stat["damage_multiplier"])
	weapon = String(stat["weapon"])
	player_view.setup(assets["players"][weapon], player_clips)
	restart()

func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key := int(event.physical_keycode if event.physical_keycode else event.keycode)
		# External flow owns restart, pause, appearance and character selection.
		if key in [KEY_R, KEY_TAB, KEY_1, KEY_2, KEY_3, KEY_ESCAPE, KEY_F2, KEY_F3]:return
	super._input(event)

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if finished and not reported:
		reported = true
		flow_event.emit({"type": "combat.room_combat_finished" if victory else "combat.player_defeated",
			"run_id": managed_run_id, "room_id": str(room_index), "final_room": victory,
			"event_id": managed_run_id + ":finished", "tick": Engine.get_physics_frames(), "time_ms": elapsed_ms,
			"stats": {"time_ms": elapsed_ms, "damage_taken": damage_taken, "hits": hit_count}})

func snapshot() -> Dictionary:
	var enemies: Array = []
	for enemy: Dictionary in monsters:
		if float(enemy["hp"]) > 0:enemies.append({"pos": Vector2(enemy["pos"]), "hp": enemy["hp"]})
	var exit_target := Vector2.ZERO
	if room_cleared and not finished:exit_target = door_point(String(rules["rooms"][room_index]["next"]))
	return {"hp": player.get("hp", 0), "mp": player.get("mp", 0), "pos": Vector2(player.get("pos", Vector2.ZERO)),
		"cooldowns": player.get("cooldowns", {}).duplicate(true),
		"attack_damage": rules["moves"]["attack1"]["damage"],
		"facing": player.get("facing", 1), "enemies": enemies, "exit_target": exit_target, "cleared": room_cleared,
		"max_hp": rules["player"]["hp"], "max_mp": rules["player"]["mp"],
		"room": room_index + 1, "room_count": rules["rooms"].size(),
		"room_name": rules["rooms"][room_index]["name"], "paused": paused}

func apply_heal(amount: int) -> bool:
	if finished or paused or float(player["hp"]) >= float(rules["player"]["hp"]):return false
	player["hp"] = minf(float(rules["player"]["hp"]), float(player["hp"]) + amount)
	notice("恢复药剂 · HP +%d" % amount)
	return true

func set_paused(value: bool) -> void:
	paused = value
	held.clear()
	requests.clear()

func stop_audio() -> void:
	_muted = true
	if music:
		music.stop()
		music.stream = null
	for voice: AudioStreamPlayer in voice_pool:
		voice.stop()
		voice.stream = null
	sound_streams.clear()

func _exit_tree() -> void:
	stop_audio()
