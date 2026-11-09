extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const Numbers = preload("res://stats/api/numbers.gd")
const MOB_PATHS := {
	"native_raxy":"monster/zealot/raxy-a.mob",
	"native_starfish":"monster/starfish/starfish.mob",
	"native_starfish_rukuku":"monster/starfish/starfishrukuku.mob",
}
var session := CombatSession.new()
var game
var checks := 0
var failures := 0

class SourceRolls:
	var rolls: Array[int]
	var index := 0

	func _init(source: Array[int]) -> void:
		rolls = source

	func range_int(low: int, high: int) -> int:
		if low == 0 and high == 0x7fffffff and index < rolls.size():
			var result := rolls[index]
			index += 1
			return result
		return low

	func next_float() -> float:
		return 0.0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("[NATIVE_RAXY] FAIL "+label)

func run() -> void:
	game = session.mount(root)
	game.set_process(false)
	game.set_physics_process(false)
	game._muted = true
	check(not game.missing_assets,"the formal battle loads the compiled source pack")
	if not game.missing_assets:
		for key: String in MOB_PATHS:
			game.table.monsters[key] = game.table._build_monster(key,{"mob":MOB_PATHS[key],"bank":key})
		var ready: bool = game.table.problems.is_empty() and game.table.monsters["native_raxy"].has("native_suicide")
		check(ready,"the original Raxy and both summoned monster records resolve")
		if ready:
			check_suicide()
			check_two_summons()
			check_ordinary_death()
			check_jump("native_starfish",[0,9999,9999,0,0],1)
			check_jump("native_starfish_rukuku",[0,0,0],0)
	print("[NATIVE_RAXY] COMPLETE checks=%d failures=%d"%[checks,failures])
	quit(0 if failures == 0 else 1)

func start_room() -> Dictionary:
	check(session.start_room({"run_id":"native-raxy","dungeon":"lorien","room_index":0,
		"from":"start","player":{"numbers":Numbers.shared_config()["base"]}}),"a real room starts through the battle API")
	game.clear_monsters()
	game.player["pos"] = Vector2(760,300)
	var enemy: Dictionary = game.spawn_enemy(Vector2(300,300),false,"native_raxy")
	game.bus.clear_history()
	return enemy

func sound_count(key: String) -> int:
	return game.bus.events_of("combat.cue").filter(func(event):return event.get("kind") == "sound" and event.get("key") == key).size()

func check_suicide() -> void:
	var enemy := start_room()
	var rng_before = game.rng
	var draws := SourceRolls.new([5,4,1, 0,0,0,0,0,0,0,0, 199,99,1,1,59,19,39,1, 42,14,0,1,21,11,18,0])
	game.rng = draws
	game.step_game(1.0)
	check(enemy["state"] == "idle" and draws.index == 1,"native draw 5 does not start suicide")
	game.step_game(1.0)
	check(enemy["state"] == "native_suicide" and enemy["clock"] == 0.0,"native draw 4 starts the original suicide ANI at frame zero")
	game.step_game(899.0)
	check(sound_count("KNIFE_STICK") == 0 and game.monsters.size() == 1,"no knife cue or summons before frame 2")
	game.step_game(1.0)
	check(sound_count("KNIFE_STICK") == 1 and game.enemy_ani(enemy)[0] == "suicide","frame 2 emits the original cue from the suicide pose")
	game.step_game(719.0)
	check(float(enemy["hp"]) > 0.0 and game.monsters.size() == 1,"no death or summons before the original ANI end")
	game.step_game(1.0)
	check(enemy["state"] == "dead" and game.monsters.size() == 4 and draws.index == draws.rolls.size(),"the end transition consumes one count and eight draws per child")
	check(sound_count("ZGM_SPRING") == 3 and game.bus.events_of("combat.hit").is_empty(),"each summon plays the original launch cue, with no suicide hit")
	if game.monsters.size() == 4:
		check_child(game.monsters[1],"native_starfish",Vector2(280,290),Vector2(100,50),40)
		check_child(game.monsters[2],"native_starfish_rukuku",Vector2(319,309),Vector2(-299,-149),99)
		check_child(game.monsters[3],"native_starfish",Vector2(298,301),Vector2(142,-64),61)
		game.step_game(900.0)
		check(not game.room_cleared,"live summoned enemies keep the actual room gate closed")
		check(game.monsters[1]["state"] == "idle" and game.monsters[1]["z"] == 0.0,"launch ends on the ground without a player knockdown")
		for child: Dictionary in game.monsters.slice(1):child["hp"] = 0.0
		game.step_game(820.0)
		check(game.room_cleared and game.bus.events_of("combat.room_combat_finished").size() == 1,"the normal room opens after all summoned enemies are defeated")
	game.rng = rng_before

func check_child(child: Dictionary, kind: String, point: Vector2, speed: Vector2, rise: int) -> void:
	check(child["kind"] == kind and child["pos"] == point and child["z"] == 20.0
		and child["state"] == "native_summon_jump" and child["clock"] == 0.0,"the chosen original monster arrives at the packet XYZ with no elapsed launch time")
	check(child["native_jump_velocity"] == speed and is_equal_approx(child["vz"],sqrt(3000.0*rise)),"the packet magnitude, signs and mode-2 apex produce the launch velocities")

func check_ordinary_death() -> void:
	var enemy := start_room()
	enemy["hp"] = 0.0
	game.step_game(820.0)
	check(game.monsters.size() == 1 and sound_count("ZGM_SPRING") == 0 and game.room_cleared,"an ordinary defeat opens the room without spawning StarFish")

func check_two_summons() -> void:
	var enemy := start_room()
	var rng_before = game.rng
	var draws := SourceRolls.new([0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0])
	game.rng = draws
	game.step_game(1.0)
	game.step_game(1620.0)
	check(enemy["state"] == "dead" and game.monsters.size() == 3 and draws.index == draws.rolls.size(),"the even count draw spawns two children")
	game.step_game(900.0)
	check(game.monsters.size() == 3 and sound_count("KNIFE_STICK") == 1 and sound_count("ZGM_SPRING") == 2,"large updates preserve the one-shot cue and summon lifecycle")
	game.rng = rng_before

func check_jump(kind: String, source_draws: Array[int], runtime_index: int) -> void:
	start_room()
	game.clear_monsters()
	game.player["pos"] = Vector2(430,300)
	game.player["invuln_ms"] = 0.0
	var enemy: Dictionary = game.spawn_enemy(Vector2(350,300),false,kind)
	var jump: Dictionary = enemy["def"]["native_starfish_jump"]
	var rng_before = game.rng
	var draws := SourceRolls.new(source_draws)
	game.rng = draws
	enemy["facing"] = 1
	game.update_enemy(enemy,2999.0)
	check(enemy["state"] != "attack" and draws.index == 0,"original attack polling waits 3000 ms")
	enemy["pos"] = Vector2(350,300)
	game.update_enemy(enemy,1.0)
	var selected: bool = enemy["state"] == "attack" and enemy["move_index"] == runtime_index \
		and enemy["def"]["moves"][runtime_index]["source_slot"] == 1 and draws.index == source_draws.size()
	check(selected,"original poll selects slot one without renumbering a sparse attack table (%s, %s, %s)"
		%[enemy["state"],enemy.get("move_index",-1),draws.index])
	if not selected:
		game.rng = rng_before
		return
	game.player["pos"] = Vector2(760,300)
	game.bus.clear_history()
	game.update_enemy(enemy,49.0)
	check(enemy["z"] == 0.0 and enemy["vz"] == 0.0 and game.enemy_ani(enemy)[0] == "jumpattackstart",
		"the original startup frame has neither vertical motion nor a hit")
	game.update_enemy(enemy,1.0)
	check(enemy["z"] == 0.0 and enemy.get("native_jump_velocity") == Vector2(80,0)
		and is_equal_approx(enemy["vz"],sqrt(450000.0)),"native frame one launches toward the original 150-pixel apex")
	for _tick in 40:
		game.update_enemy(enemy,16.0)
		if enemy.get("starfish_phase","") == "rolling":break
	check(enemy.get("starfish_phase","") == "rolling" and int(enemy["z"]) > 130 and float(enemy["vz"]) > 0.0
		and sound_count("ZGM_ATK") == 1,"the original rolling ANI and sound start once above 130 on ascent")
	game.view.present(game.view_snapshot(),0.0,0.0)
	var actor = game.view.enemy_actors.get(enemy["id"])
	check(actor != null and actor.atlas != null and actor.pose == "jumpattackrolling"
		and actor.bank["texture"].ends_with("mob_"+kind+".png"),"each original monster uses its own rolling sprite bank")
	check(game.bus.events_of("combat.hit").is_empty(),"startup and distant rolling cause no hits")
	game.player["pos"] = enemy["pos"]
	game.player["z"] = enemy["z"]
	game.player["invuln_ms"] = 0.0
	game.update_enemy(enemy,1.0)
	var hits: Array = game.bus.events_of("combat.hit")
	check(hits.size() == 1 and hits[0]["atk"] == jump["rolling_atk"],"a live rolling collision consumes the independent original ATK")
	game.player["pos"] = Vector2(760,300)
	game.player["z"] = 0.0
	var looped := false
	for _tick in 90:
		game.update_enemy(enemy,16.0)
		if enemy.get("starfish_phase","") == "rolling" and enemy["clock"] >= 140.0:
			looped = looped or game.enemy_ani(enemy)[1] < 140.0
		if enemy.get("starfish_phase","") == "end":break
	check(looped and game.bus.events_of("combat.hit").size() == 1,
		"rolling loops its own 140 ms visual without duplicating the resolved contact")
	check(enemy.get("starfish_phase","") == "end" and int(enemy["z"]) < 15
		and game.enemy_ani(enemy)[0] == "jumpattackend" and enemy["clock"] == 0.0,"the original landing pose starts below 15 on descent")
	game.update_enemy(enemy,279.0)
	check(enemy["state"] == "attack" and enemy["z"] == 0.0,"the last landing frame is held to its own ANI end")
	game.update_enemy(enemy,1.0)
	check(enemy["state"] == "idle" and not enemy.has("native_jump_velocity") and sound_count("ZGM_ATK") == 1,
		"landing finishes after 280 ms and clears the native flight")
	game.rng = rng_before
