extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const DetRng = preload("res://core/det_rng.gd")
const Numbers = preload("res://stats/api/numbers.gd")
const NativeZealotSummons = preload("res://combat/resolve/native_zealot_summons.gd")
const ROUTE := {"mode":"native_maze","map_export":"res://assets_local/native_maps/outerwall_v1/map_export.json"}
const FATHER := "monster/zealot/bossfather.mob"
const POPE := "monster/zealot/bosspope.mob"
const DARK := "monster/spirit/darkspirit.mob"
const LIGHT := "monster/spirit/lightspirit.mob"
const CAST := "native_zealot_cast"

class SummonRolls extends DetRng:
	var roll := 20
	var draws := 0

	func range_int(low: int, high: int) -> int:
		if low != 0 or high != 0x7fffffff:return low
		draws += 1
		return roll

var session := CombatSession.new()
var game
var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if ok:return
	failures += 1
	push_error("[NATIVE_ZEALOT_SUMMONS] FAIL " + label)

func run() -> void:
	game = session.mount(root)
	game.set_process(false)
	game.set_physics_process(false)
	if enter_boss(0,1,["right","down","right","right","right","right","left","up","right"],3024):
		check_cast(FATHER,DARK,3,800.0,0.0,true)
	if enter_boss(1,0,["right","up","right","right","right","right","down"],3022):
		check_interrupt_and_orphan()
		check_cast(POPE,LIGHT,4,900.0,40.0,false)
	session.stop()
	await process_frame
	print("[NATIVE_ZEALOT_SUMMONS] COMPLETE checks=%d failures=%d" % [checks,failures])
	quit(0 if failures == 0 else 1)

func enter_boss(start_slot: int, boss_slot: int, steps: Array, map_id: int) -> bool:
	var run_id := ""
	for i in range(1,100):
		var candidate := "run_%d" % i
		var rolls := DetRng.new(hash(candidate))
		var start := rolls.range_int(0,1)
		var boss := rolls.range_int(0,1)
		if start == start_slot and boss == boss_slot:
			run_id = candidate
			break
	var started := not run_id.is_empty() and session.start_room({"run_id":run_id,"dungeon":"outerwall",
		"route":ROUTE,"player":{"numbers":Numbers.shared_config()["base"]},"audio":{"muted":true}})
	check(started,"public combat session enters the source maze for %d" % map_id)
	if not started:return false
	for side: String in steps:
		for enemy: Dictionary in game.monsters:enemy["hp"] = 0.0
		game.step_game(820.0)
		var previous: int = game.room_index
		game.player["pos"] = game.door_point(side)
		game.door_lock_ms = 0.0
		game.step_game(0.0)
		if game.room_index == previous:
			check(false,"source door %s from %s opens en route to %d" % [side,game.native_room["cell"],map_id])
			return false
	var correct: bool = game.native_room["source_map_id"] == map_id and game.route_boss_room()
	check(correct,"source doors reach exact boss MAP%d" % map_id)
	return correct

func check_cast(caster_mob: String, child_mob: String, extra: int, duration: float, height: float, owner_dying: bool) -> void:
	var caster: Dictionary = {}
	for enemy: Dictionary in game.monsters:
		enemy["ai"] = enemy["mob"] == caster_mob
		if enemy["ai"]:caster = enemy
	check(not caster.is_empty() and caster["chief"],"the source MAP spawns the expected caster")
	if caster.is_empty():return
	check(owned(caster).is_empty(),"the source boss MAP has no preplaced spirit")
	game.bus.clear_history()
	game.player["pos"] = Vector2(caster["pos"])+Vector2(40,0)
	game.player["invuln_ms"] = 10000.0
	var rolls := SummonRolls.new(1)
	game.rng = rolls
	game.update_enemy(caster,333.0)
	check(caster["state"] != CAST and rolls.draws == 0,"special selector waits through exactly 333 ms")
	caster["state"] = "idle"
	game.update_enemy(caster,1.0)
	check(caster["state"] != CAST and rolls.draws == 1,"first due poll rejects roll 20")
	caster["state"] = "idle"
	rolls.roll = 19
	game.update_enemy(caster,334.0)
	check(caster["state"] == CAST and rolls.draws == 2 and game.bus.events_of("combat.zealot_cast_started").size() == 1,
		"roll 19 starts the real cast only at the next local poll")
	if caster["state"] != CAST:return
	check(is_equal_approx(float(caster["native_cast_rate"]),1.0),"state13 keeps the ordinary idle ANI rate 1.0")
	game.view.present(game.view_snapshot(),0.0,0.0)
	var actor = game.view.enemy_actors.get(caster["id"])
	var layers: Dictionary = actor.get_meta("native_cast_layers",{}) if actor != null else {}
	check(layers.size() == 3 and layers.values().all(func(layer):return layer.visible)
		and layers.values().filter(func(layer):return layer.show_behind_parent).size() == 1,
		"the real battle view draws one cast layer behind and two in front")
	var clock_end := 800.0/float(caster["native_cast_rate"])
	game.step_game(clock_end-1.0)
	check(caster["state"] == CAST and game.native_zealot_summons.proxies.is_empty(),"no proxy before the rate-adjusted cast end")
	game.step_game(2.0)
	var proxies: Array = game.native_zealot_summons.proxies
	check(caster["state"] == "idle" and caster.get("native_summon_uses",0) == 1 and proxies.size() == 1,
		"the natural state13 exit creates exactly one proxy and spends one use")
	if proxies.size() != 1:return
	caster["ai"] = false
	var proxy: Dictionary = proxies[0]
	var proxy_events: Array = game.bus.events_of("combat.zealot_summon_proxy")
	check(proxy_events.size() == 1 and proxy_events[0]["object_index"] == 48024 and proxy_events[0]["extra"] == extra,
		"the caster uses OBJ48024 with the proper spirit variant")
	check(proxy["pos"] == Vector2(Vector2i(caster["pos"])) and proxy["facing"] == caster["facing"]
		and proxy["level"] == 32 and proxy["clock"] == 0.0,
		"the new proxy keeps caster integer XY, facing and level32 with an uncharged clock")
	game.view.present(game.view_snapshot(),0.0,0.0)
	var art = game.view.object_views.get(proxy["id"])
	check(art != null and art.atlas != null and layers.values().all(func(layer):return not layer.visible),
		"the native proxy is present and the ended caster's three layers are hidden")
	if owner_dying:
		for enemy: Dictionary in game.monsters:enemy["hp"] = 0.0
	game.step_game(duration-1.0)
	check(owned(caster).is_empty() and game.native_zealot_summons.proxies.size() == 1 and not game.room_cleared,
		"OBJ48024 is still a proxy one millisecond before the original ANI ends")
	game.step_game(1.0)
	var children := owned(caster)
	check(children.size() == 1 and game.native_zealot_summons.proxies.is_empty(),
		"proxy end births one owned creature, including a still-registered dying owner")
	if children.size() != 1:return
	var child: Dictionary = children[0]
	check(child["mob"] == child_mob and child["z"] == height and child["pos"] == proxy["pos"]
		and child["facing"] == proxy["facing"] and child["source_level"] == 32 and child["hp"] > 0.0,
		"the real monster has original identity, birth Z and inherited position, facing and level")
	for enemy: Dictionary in game.monsters:
		enemy["ai"] = false
		if enemy != child:enemy["hp"] = 0.0
	game.step_game(16.0)
	check(child["z"] == height,"normal actor updates retain the source base height")
	game.step_game(820.0)
	check(owned(caster).size() == 1 and not game.room_cleared and not game.finished,
		"a live spirit remains a room hostile after its owner is removed")
	child["hp"] = 0.0
	game.step_game(820.0)
	check(game.room_cleared and game.finished and game.bus.events_of("combat.zealot_spirit_spawned").size() == 1,
		"removing the final spirit settles the exact boss room without repeating the spawn")

func owned(caster: Dictionary) -> Array:
	return game.monsters.filter(func(enemy):return enemy.get("summon_owner",-1) == caster["id"])

func check_interrupt_and_orphan() -> void:
	var caster: Dictionary = game.spawn_enemy(Vector2(1200,250),false,game.table.monster_by_mob(POPE))
	caster["ai"] = false
	NativeZealotSummons.start(game,caster)
	game.land_hit(game.player,caster,{"atk":{"damage_reaction":"[down]"},"percent":0.0,
		"lift":20.0,"contact_only":true},Vector3(1200,250,0),1,0.0)
	game.update_enemy(caster,800.0)
	check(caster["state"] != CAST and caster.get("native_summon_uses",0) == 0
		and game.native_zealot_summons.proxies.is_empty(),"a real hit interrupts the cast before any proxy or use is created")
	NativeZealotSummons.start(game,caster)
	caster["stuck_ms"] = 0.0
	game.update_enemy(caster,1000.0)
	check(game.native_zealot_summons.proxies.size() == 1,"fixture queues a LightSpirit proxy before owner removal")
	game.monsters.erase(caster)
	game.native_zealot_summons.step(game,900.0,game._next_entity_id)
	check(owned(caster).is_empty() and game.native_zealot_summons.proxies.is_empty(),
		"proxy end drops the request after the owner's scene removal")
	var rolls := SummonRolls.new(1)
	rolls.roll = 19
	game.rng = rolls
	caster["state"] = "idle"
	caster["native_summon_uses"] = 3
	check(not NativeZealotSummons.choose(game,caster,true) and rolls.draws == 0,"three uses stop selection before a new draw")
