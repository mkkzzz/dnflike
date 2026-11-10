extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const FlowSession = preload("res://flow/session.gd")
const DetRng = preload("res://core/det_rng.gd")
const NativeMaze = preload("res://combat/data/native_maze.gd")
const NativePotMonsters = preload("res://combat/resolve/native_pot_monsters.gd")
const NativeJarTraps = preload("res://combat/resolve/native_jar_traps.gd")
const NativeBoxLoot = preload("res://loot/native_box.gd")
const Loot = preload("res://loot/service.gd")
const Inventory = preload("res://items/inventory.gd")
const EXPORT := "res://assets_local/native_maps/outerwall_v1/map_export.json"
const NORMAL_MUSIC := "res://assets_local/audio/bgm/outer_temple.ogg"
const BOSS_MUSIC := "res://assets_local/audio/bgm/behemoth_b01_1.ogg"

class PotRolls extends DetRng:
	var queue: Array
	func _init(rolls: Array) -> void:queue = rolls.duplicate()
	func randi_range(low: int, high: int) -> int:return range_int(low,high)
	func range_int(low: int, high: int) -> int:
		var roll: int = queue.pop_front()
		assert(roll >= low and roll <= high)
		return roll
	func next_float() -> float:return 0.5

var session := CombatSession.new()
var game
var events: Array[Dictionary] = []
var loot_events: Array[Dictionary] = []
var flow: FlowSession
var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("[NATIVE_MAZE_SESSION] FAIL "+label)

func run() -> void:
	game = session.mount(root)
	game.set_process(false)
	game.set_physics_process(false)
	session.room_combat_finished.connect(record_clear)
	session.prop_loot_released.connect(record_loot)
	check(not game.missing_assets,"production combat tables and new source atlases load")
	if not game.missing_assets:
		prepare_pot_fixture()
		check_upper_run()
		check_lower_run()
		check_breakable_run()
		check_pot_run()
		check_jar_trap_run()
		check_orange_fairy_run()
		check(session.start_room({"run_id":"lorien-reset","dungeon":"lorien","audio":{"muted":true}})
			and game.native_maze == null and game.room_placement(0)["map"].begins_with("map/lorien/")
			and not game.view.audio.music.playing,
			"leaving native mode restores the default linear battle")
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_SESSION] COMPLETE checks=%d failures=%d"%[checks,failures])
	quit(0 if failures == 0 else 1)

func record_clear(event: Dictionary) -> void:
	events.append(event)
	if flow != null:check(bool(flow.combat_event(event)["ok"]),"flow accepts the source room event")

func record_loot(event: Dictionary) -> void:
	loot_events.append(event)
	check(flow != null and flow.combat_event(event).get("loot_changed",false),"flow accepts a live box release")

func seed_for(start_slot: int, boss_slot: int, map_slot: int) -> int:
	for number in range(1,100):
		var draws := DetRng.new(hash("run_%d"%number))
		var entry := draws.range_int(0,1)
		var boss := draws.range_int(0,1)
		var map := draws.range_int(0,1)
		if entry == start_slot and boss == boss_slot and map == map_slot:return number
	return -1

func start_spec(start_slot: int, boss_slot: int, map_slot: int, number := -1) -> Dictionary:
	flow = FlowSession.new()
	flow.profile["level"] = 27
	flow.profile["next_run"] = number if number > 0 else seed_for(start_slot,boss_slot,map_slot)
	check(flow.profile["next_run"] > 0 and flow.command("flow.depart",{"dungeon":"outerwall"})["ok"],
		"flow builds a run using the internal source route contract")
	return {"run_id":flow.run["id"],"dungeon":"outerwall","route":flow.active_dungeon_route(),
		"room_id":"outerwall:0","room_index":0,"player":flow.run["stats"],
		"audio":{"muted":false,"bgm_volume_db":-32.0}}

func current_music() -> String:
	return game.view.audio.music.stream.resource_path if game.view.audio.music.stream != null else ""

func present_room() -> void:
	game.view.present(game.view_snapshot(),0.0,0.0)
	check(game.view.stage.root != null and game.map_loader.errors.is_empty(),"rendered room uses present source art")

func check_preflight(spec: Dictionary) -> void:
	var before := session.read_runtime_view()
	var source: Dictionary = game.table.monsters["native_starfish_rukuku"]
	game.table.monsters.erase("native_starfish_rukuku")
	check(not session.start_room(spec) and session.read_runtime_view() == before,
		"missing a possible summon rejects admission without changing the current battle")
	game.table.monsters["native_starfish_rukuku"] = source
	var atlas: Dictionary = game.combat_assets["monsters"]["native_bosspope"]["atlas"]
	var path: String = atlas["texture"]
	atlas["texture"] = "res://missing_outerwall_monster.png"
	check(not session.start_room(spec) and session.read_runtime_view() == before,
		"missing a later room atlas rejects admission without changing the current battle")
	atlas["texture"] = path
	var particles: Dictionary = game.combat_assets["particles"]
	var particle := "passiveobject/mapobject/breakableobject/particle/longchairdestroy.ptl"
	var template: Dictionary = particles[particle]
	particles.erase(particle)
	check(not session.start_room(spec) and session.read_runtime_view() == before,
		"a missing native prop particle rejects admission without changing the current battle")
	particles[particle] = template
	var sounds: Dictionary = game.combat_assets["audio"]
	var sound := "TINGKERBELL_FLOAT_LOOP"
	var voices: Array = sounds[sound]
	sounds.erase(sound)
	check(not session.start_room(spec) and session.read_runtime_view() == before,
		"a missing fairy loop rejects admission without changing the current battle")
	sounds[sound] = voices

func check_upper_run() -> void:
	var spec := start_spec(0,1,0)
	var started := session.start_room(spec)
	check(started,"public battle session starts the first exact source maze")
	if not started:return
	check(game.native_room["source_map_id"] == 3001 and game.room_id == "outerwall:0"
		and game.player["pos"] == Vector2(297.5,298.0),"upper source entrance keeps the first start MAP and spawn")
	check(session.read_view()["room_count"] == 16 and session.read_runtime_view()["room_name"] == "神殿周边"
		and game.view_snapshot()["hud"]["route"].size() == 16,"both battle views report the complete maze")
	check(current_music() == NORMAL_MUSIC,"the first room starts the original ordinary track")
	check_preflight(spec)
	present_room()
	var gate: Vector2 = game.door_point("right")
	game.player["pos"] = gate
	game.door_lock_ms = 0.0
	game.step_game(0.0)
	check(game.native_room["source_map_id"] == 3001 and events.is_empty(),"the live door cannot bypass enemies")
	game.player["pos"] = Vector2(297.5,298.0)
	clear_all()
	check(events.size() == 1 and events[-1]["source_cell"] == [0,0] and not events[-1]["final_room"]
		and flow.state == "battle","ordinary clear delivers the source coordinate without settlement")
	var malformed := events[-1].duplicate()
	malformed.erase("source_cell")
	check(not flow.combat_event(malformed)["ok"],"the native flow adapter rejects a room event without a source cell")
	if not hop("right"):return
	var selected: int = game.native_room["source_map_id"]
	check(selected in [3004,3012],"a real first crossing from the left filters the MAP pool")
	clear_all()
	if not hop("down"):return
	clear_all()
	var clears := events.size()
	if not hop("up"):return
	game.step_game(100.0)
	check(game.native_room["source_map_id"] == selected and game.room_cleared and game.monsters.is_empty()
		and events.size() == clears,"returning from another side keeps the selected MAP and the prior clear")
	for side in ["down","right","right","right","right","down"]:
		if not hop(side):return
		clear_all()
	check(game.native_room["source_map_id"] == 3021 and not game.route_boss_room()
		and not game.finished and flow.state == "battle","the unused boss coordinate acts as the fixed ordinary MAP")
	for side in ["up","left","up"]:
		if not hop(side):return
		clear_all()
	present_room()
	check(stage_gate("right") == "boss:434","the battle renderer builds the selected boss edge with its right gate")
	if not hop("right"):return
	present_room()
	check(game.native_room["source_map_id"] == 3024 and stage_gate("left") == "boss:432"
		and current_music() == BOSS_MUSIC,"entering the selected boss MAP builds the reciprocal gate and changes music")
	check_final_clear()

func check_lower_run() -> void:
	events.clear()
	var spec := start_spec(1,0,1)
	var started := session.start_room(spec)
	check(started,"the same session accepts a distinct source start and boss")
	if not started:return
	present_room()
	check(game.room_id == "outerwall:12" and game.native_room["source_map_id"] == 3002
		and game.player["pos"] == Vector2(271.5,317.0),"sparse room index and lower start survive the old flow arguments")
	session.submit_key(KEY_UP,true)
	game.step_game(16.0)
	session.submit_key(KEY_UP,false)
	check(float(game.player["pos"].y) < 317.0,"the lower source spawn accepts real upward input immediately")
	check(current_music() == NORMAL_MUSIC,"a new ordinary room switches away from the previous boss track")
	for side in ["right","up","right","right","right","right"]:
		clear_all()
		if not hop(side):return
	clear_all()
	present_room()
	check(stage_gate("down") == "boss:438","the second valid boss selection uses the original down gate")
	if not hop("down"):return
	present_room()
	check(game.native_room["source_map_id"] == 3022 and stage_gate("up") == "boss:436"
		and current_music() == BOSS_MUSIC,"the second boss MAP uses the reciprocal up gate and original track")
	check_live_pot()
	check_final_clear()

func check_live_pot() -> void:
	var pots: Array = game.props.filter(func(prop):
		return prop["native_breakable"]["object_index"] == 771 and game.room_map["objects"][prop["node"]]["source_tag"] == "[passive object]")
	check(pots.size() == 2,"the live boss MAP instantiates both ordinary long pots")
	if pots.size() != 2:return
	var pot: Dictionary = pots[0]
	check(pot["hp"] == 1 and pot["damage_boxes"].size() == 2,"long pot uses its source HP and both ANI volumes")
	var wave: Dictionary = game.move_def("normalwave")["hits"][0].duplicate()
	var obj: Dictionary = game.table.object(wave["object"])
	var hit_box: Array = obj["timeline"][0]["attack_boxes"][0]
	var wave_center := Vector3(hit_box[0]+hit_box[3]*0.5,hit_box[1]+hit_box[4]*0.5,hit_box[2]+hit_box[5]*0.5)
	var body: AABB = pot["damage_boxes"][1]
	var point := body.get_center()-wave_center*float(wave.get("size_rate",1))
	game.bus.clear_history()
	game.spawn_object(wave,"player",Vector2(point.x,point.y),point.z,1,game.attack_power())
	game.step_objects(0.0)
	game.step_objects(0.0)
	for entry: Dictionary in pots:check_prop_burst(entry,10,2)

func check_breakable_run() -> void:
	var rolls := [0,999,1000,2499,2500,2999,3000,3499,3500,6499,6500,10000]
	var expected := [1068,1068,1069,1069,1070,1070,1071,1071,1072,1072,0,0]
	for i in rolls.size():
		check(NativeBoxLoot.pick(rolls[i]) == ("original_%d"%expected[i] if expected[i] else ""),
			"the original cumulative box roll boundary at %d"%rolls[i])
	var export: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(EXPORT))
	var double_boxes: Array = export["dungeon"]["rooms"]["map/outerwall/n3002.map"]["objects"].filter(
		func(item):return NativeBoxLoot.draw_count(item) == 2)
	check(double_boxes.size() == 1,"MAP3006 retains its single source box that draws twice")
	var pair: Array[String] = []
	for seed in range(1,100):
		pair = NativeBoxLoot.prepare(2,seed)
		if pair.size() == 2:
			check(NativeBoxLoot.prepare(1,seed) == pair.slice(0,1),"the second draw preserves the first selection")
			break
	check(pair.size() == 2,"two source draws can independently return two items")
	var run := ""
	# Select a replay whose unchosen upper entrance uses the original box MAP.
	for i in range(1,100):
		var id := "run_%d"%i
		var maze := NativeMaze.new()
		if not maze.start(export,DetRng.new(hash(id))) or maze.current_room()["cell"] != Vector2i(0,2):continue
		for side: String in ["right","up","up","left"]:
			maze.clear_room(maze.current_room()["cell"],0)
			maze.move(side)
		if maze.current_room()["source_map_id"] != 3019:continue
		var map: String = maze.current_room()["placement"]["map"]
		var objects: Array = export["dungeon"]["rooms"][map]["objects"]
		var populated := false
		for node in objects.size():
			var draws := NativeBoxLoot.draw_count(objects[node])
			if draws > 0 and not NativeBoxLoot.prepare(draws,hash("%s:outerwall:0:box:%d"%[id,node])).is_empty():
				populated = true
				break
		if populated:
			run = id
			break
	flow = FlowSession.new()
	flow.profile["level"] = 27
	flow.profile["next_run"] = int(run.get_slice("_",1))
	var started: bool = not run.is_empty() and flow.command("flow.depart",{"dungeon":"outerwall"})["ok"] and flow.run["id"] == run \
		and session.start_room({"run_id":run,"dungeon":"outerwall","route":flow.active_dungeon_route(),"audio":{"muted":true}})
	check(started,"live source route starts with a replayable ordinary box placement")
	if not started:return
	clear_all()
	if not hop("right"):return
	present_room()
	var chairs: Array = game.props.filter(func(prop):return prop["native_breakable"]["object_index"] == 770)
	check(not chairs.is_empty(),"regular MAP object row creates the original chair")
	if chairs.is_empty():return
	var chair: Dictionary = chairs[0]
	var chair_node := int(chair["node"])
	var shape: AABB = chair["damage_boxes"][0]
	var point := shape.get_center()
	check(int(chair["hp"]) == 500 and chair["damage_boxes"].size() == 3 and point.z > 30.0,
		"chair uses the original durability and upper ANI damage volume")
	var atk: Dictionary = game.move_def("attack1")["hits"][0]["atk"]
	check(not atk.is_empty(),"damage fixture uses a real player ATK")
	game.bus.clear_history()
	prop_melee(point+Vector3(0,0,200),atk,500)
	check(int(chair["hp"]) == 500 and game.bus.events_of("combat.damage").is_empty(),"a strike outside the ANI volume misses")
	prop_melee(point,{"damage_bonus":500},500)
	check(int(chair["hp"]) == 500 and game.bus.events_of("combat.cue").is_empty(),"bonus alone cannot enter the source damage or sound paths")
	prop_melee(point,atk,499)
	prop_melee(point,atk,499,false)
	var damage: Array = game.bus.events_of("combat.damage")
	check(int(chair["hp"]) == 1 and not chair["broken"] and damage.size() == 1
		and damage[0]["victim"] == "prop" and damage[0]["amount"] == 499 and game.hit_count == 0,
		"the high ANI contact consumes resolved damage once per attack segment without a monster hit")
	check(prop_visible(chair_node) and game.bus.events_of("combat.prop_broken").is_empty(),"positive remaining HP leaves the source chair visible")
	clear_all()
	if not hop("left"):return
	present_room()
	if not hop("right"):return
	present_room()
	chair = game.props.filter(func(prop):return prop["node"] == chair_node)[0]
	check(int(chair["hp"]) == 1,"partial prop HP survives real room travel")
	game.bus.clear_history()
	prop_melee(point,atk,1)
	check_prop_burst(chair,15)
	check(game.bus.events_of("combat.cue").any(func(event):return event.get("key") == "WOOD_HIT")
		and game.view.audio.variants.has("WOOD_HIT"),"the source contact sound is routed to its original clip")
	if not hop("left"):return
	present_room()
	if not hop("right"):return
	present_room()
	check(not prop_visible(chair_node) and chair_node in game.view_snapshot()["stage"]["broken_props"],
		"reentering the room keeps the original chair sprite hidden")
	for side: String in ["up","up","left"]:
		clear_all()
		if not hop(side):return
	present_room()
	var empty_boxes: Array = game.props.filter(func(prop):return not prop.has("box_items"))
	var loaded_boxes: Array = game.props.filter(func(prop):return not prop.get("box_items",[]).is_empty())
	check(game.native_room["source_map_id"] == 3019 and empty_boxes.size() == 2 and not loaded_boxes.is_empty(),
		"the box MAP loads both empty and populated original rows")
	if empty_boxes.is_empty() or loaded_boxes.is_empty():return
	var box: Dictionary = empty_boxes[0]
	shape = box["damage_boxes"][0]
	check(box["hp"] == 300 and box["damage_boxes"].size() == 2,"the original collection box has two damage boxes and 300 HP")
	game.bus.clear_history()
	prop_melee(shape.get_center(),atk,300)
	check_prop_burst(box,15)
	check(loot_events.is_empty(),"an empty source box releases no items")
	box = loaded_boxes[0]
	var contents: Array = box["box_items"].duplicate()
	shape = box["damage_boxes"][0]
	prop_melee(shape.get_center(),atk,299)
	check(loot_events.is_empty() and Loot.pending(flow.run,game.room_id).is_empty(),"preallocated items stay hidden until final depletion")
	prop_melee(shape.get_center(),atk,1)
	prop_melee(shape.get_center(),atk,300)
	var drops := Loot.pending(flow.run,game.room_id)
	check(loot_events.size() == 1 and drops.size() == contents.size() and drops.map(func(drop):return drop["item"]) == contents,
		"the original items reach the real run ledger exactly once")
	if drops.is_empty() or loot_events.is_empty():return
	check(not flow.combat_event(loot_events[0]).get("loot_changed",false),"duplicate box release cannot duplicate ground loot")
	var drop: Dictionary = drops[0]
	var item: String = drop["item"]
	var before := Inventory.stock(flow.profile,item)
	var position: Vector2 = box["pos"]
	check(not Loot.claim(flow.profile,flow.run,drop["id"],game.room_id,position+Vector2(999,0))["ok"],
		"the original item still requires a nearby claim")
	check(Loot.claim(flow.profile,flow.run,drop["id"],game.room_id,position)["ok"] and Inventory.stock(flow.profile,item) == before+1,
		"claim delivers the exact stackable ID to inventory")
	check(not Loot.claim(flow.profile,flow.run,drop["id"],game.room_id,position)["ok"] and Loot.valid(flow.run),
		"the saved ledger retains the claim receipt")

func prop_melee(point: Vector3, atk: Dictionary, amount: int, fresh := true) -> void:
	game.player["pos"] = Vector2(point.x,point.y)
	game.player["z"] = point.z
	if fresh:game.player["hits"].clear()
	var frame := {"start":0.0,"end":100.0,"boxes":[[-2,-2,-2,4,4,4]]}
	game.apply_player_hits({"hits":[{"kind":"boxes","atk":atk,"percent":0.0,"fixed":amount,
		"segments":[{"frames":[frame]}]}]},0.0,1.0)
	game.player["z"] = 0.0

func prop_visible(index: int) -> bool:
	return game.view.stage.root.get_children().any(func(node):return node.get_meta("prop_node",-1) == index and node.visible)

func check_prop_burst(prop: Dictionary, count: int, burst_count := 1) -> void:
	var path: String = prop["native_breakable"]["destroy_particle"]
	var particles: Array = game.view.effects.filter(func(node):return node.get_meta("source_ptl","") == path)
	check(prop["broken"] and prop["stage"] == 1 and not prop_visible(prop["node"])
		and game.bus.events_of("combat.prop_broken").size() == burst_count,"depletion advances one stage and hides the exact original sprite")
	check(particles.size() == count*burst_count and particles.all(func(node):return node.errors.is_empty()),
		"the battle view instantiates every original PTL fragment")

func check_jar_trap_run() -> void:
	var export: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(EXPORT))
	var map_path := "map/outerwall/n3008.map"
	var node := 10
	var item: Dictionary = export["dungeon"]["rooms"][map_path]["objects"][node]
	var rows := NativeJarTraps.rows(item)
	var fire_rolls := PotRolls.new([0,3])
	var fairy_rolls := PotRolls.new([1,1,2])
	check(NativeJarTraps.select(rows,fire_rolls) == {"id":40002,"custom":320} and fire_rolls.queue == [3]
		and NativeJarTraps.select(rows,fairy_rolls) == {"id":2200,"custom":1} and fairy_rolls.queue.is_empty()
		and NativeJarTraps.select(rows,PotRolls.new([1,1,3])).is_empty(),
		"original jar rows compare strictly and stop rolling at the first match")
	for child in [40002,2200,48003]:
		var number := 0
		for candidate in range(1,500):
			var run_id := "run_%d"%candidate
			var maze := NativeMaze.new()
			if not maze.start(export,DetRng.new(hash(run_id))) or maze.current_room()["cell"] != Vector2i.ZERO:continue
			maze.clear_room(Vector2i.ZERO,0)
			var next := maze.move("right")
			if next.get("placement",{}).get("map","") != map_path:continue
			var room := "outerwall:%d"%next["room_index"]
			if NativeJarTraps.prepare(item,hash("%s:%s:trap:%d"%[run_id,room,node])).get("id") == child:
				number = candidate
				break
		check(number > 0,"a normal run reaches the source jar with child %d"%child)
		if number == 0:return
		events.clear()
		var spec := start_spec(0,0,0,number)
		var started := session.start_room(spec)
		check(started,"trap fixture starts through the public session")
		if not started:return
		clear_all()
		if not hop("right"):return
		clear_all()
		present_room()
		var traps: Array = game.props.filter(func(prop):return prop["node"] == node)
		check(traps.size() == 1 and traps[0].get("jar_trap",{}).get("id") == child,
			"the live MAP builds the prepared source jar")
		if traps.size() != 1:return
		var pot: Dictionary = traps[0]
		var atk: Dictionary = game.move_def("normalwave")["hits"][0]["atk"]
		game.bus.clear_history()
		stop_one_shot_voices()
		prop_melee(pot["damage_boxes"][1].get_center(),atk,1000)
		match child:
			40002:check_fire_jar(pot)
			2200:check_green_fairy(pot)
			48003:check_poison_jar(pot)

func stop_one_shot_voices() -> void:
	var loops: Array = game.view.audio._loop_voices.values()
	for voice: AudioStreamPlayer in game.view.audio.voice_pool:
		if voice in loops:continue
		voice.stop()
		voice.stream = null
		if voice.has_meta("sound_key"):voice.remove_meta("sound_key")
		if voice.has_meta("voice_tag"):voice.remove_meta("voice_tag")

func check_fire_jar(pot: Dictionary) -> void:
	var warning: Dictionary = pot.get("jar_warning",{})
	check(not warning.is_empty() and warning.get("duration") == 1991.0 and not pot["broken"]
		and prop_visible(pot["node"]) and game.bus.events_of("combat.jar_trap_spawned").is_empty(),
		"normal fire trap arms a 1991 ms warning with the original pot still visible")
	if warning.is_empty():return
	var objects: Array = game.native_jar_traps.view_objects(game)
	check(objects.size() == 1 and objects[0]["z"] == float(pot["z"])+129.0
		and objects[0]["effect"] == "native_jar_trapexclamation","warning follows the original jar-height anchor")
	if not hop("left"):return
	game.step_game(1990.0)
	if not hop("right"):return
	present_room()
	var node: int = pot["node"]
	var current: Array = game.props.filter(func(prop):return prop["node"] == node)
	check(current.size() == 1 and current[0].get("jar_warning") == warning and prop_visible(node)
		and game.bus.events_of("combat.jar_trap_spawned").is_empty(),
		"returning one millisecond before the original deadline retains the warning")
	if current.size() != 1:return
	game.player["pos"] = pot["pos"]+Vector2(-200,0)
	game.player["invuln_ms"] = 0.0
	game.rng = PotRolls.new([])
	var hp: float = game.player["hp"]
	game.step_game(1.0)
	var spawned: Array = game.bus.events_of("combat.jar_trap_spawned")
	var paths: Array = game.combat_assets["native_jar_traps"]["objects"]["40002"]["particles"]
	var bursts: Array = game.bus.events_of("combat.cue").filter(func(event):return event.get("path") in paths)
	check(spawned.size() == 1 and spawned[0]["custom"] == 320 and spawned[0]["height"] == float(pot["z"]) and bursts.size() == 4
		and current[0]["broken"] and not current[0].has("jar_warning") and not prop_visible(node)
		and game.player["hp"] == hp,"expiry shatters the original jar once, emits four PTL sources and misses outside its box")
	if not hop("left"):return
	game.step_game(398.0)
	if not hop("right"):return
	game.player["pos"] = pot["pos"]
	game.player["invuln_ms"] = 0.0
	var enemy: Dictionary = game.spawn_enemy(pot["pos"],false,"native_starfish_rukuku")
	enemy["ai"] = false
	var enemy_hp: float = enemy["hp"]
	game.step_game(1.0)
	check(game.player["hp"] < hp and enemy["hp"] < enemy_hp and game.last_damage.get("category") == "magical"
		and game.last_damage.get("element") == "fire" and game.last_damage.get("trace",{}).get("fixed_part") == 320.0
		and game.last_damage.get("trace",{}).get("percent_part") == 0.0,
		"after a revisit at 399 ms the fire box deals the original fixed-base fire magic to both opposing teams")
	var after: float = game.player["hp"]
	game.step_game(1.0)
	check(game.player["hp"] == after and game.native_jar_traps.actors.is_empty()
		and game.bus.events_of("combat.jar_trap_spawned").size() == 1,"the fire hitbox ends at 400 ms")

func check_green_fairy(pot: Dictionary) -> void:
	var actors: Array = game.native_jar_traps.actors
	var initial: Array = game.native_jar_traps.view_objects(game)
	check(pot["broken"] and not pot.has("jar_warning") and actors.size() == 1
		and actors[0]["z"] == 50.0 and initial.map(func(layer):return layer["effect"]) == ["native_jar_hpmpfairy","native_jar_hpmpfairyef"]
		and game.view.audio._loop_voices.has(actors[0]["id"]),
		"green fairy spawns immediately with the source float height, body, light and loop sound")
	if actors.size() != 1:return
	var id: int = actors[0]["id"]
	var voice: AudioStreamPlayer = game.view.audio._loop_voices.get(id)
	game.view.audio.muted = true
	check(voice != null and voice.stream_paused,"the mute setting also pauses an already playing fairy loop")
	game.view.audio.muted = false
	if not hop("left"):return
	check(actors.is_empty() and not game.view.audio._loop_voices.has(id),"leaving the fairy room stops its audible loop")
	game.step_game(150.0)
	if not hop("right"):return
	var frames: Array = game.native_jar_traps.view_objects(game)
	check(actors.size() == 1 and actors[0]["id"] == id and frames[0]["clock"] == 150.0
		and game.view.audio._loop_voices.has(id),"the original fairy retains its age and identity through a real room revisit")
	game.player["pos"] = pot["pos"]+Vector2(-200,0)
	game.player["hp"] = floorf(game.max_hp/4.0)
	game.player["mp"] = game.max_mp-10.0
	game.step_game(100.0)
	check(actors.size() == 1 and game.item_restorations.is_empty(),"standing outside the fairy attack box leaves it available")
	game.player["pos"] = pot["pos"]
	var hp: float = game.player["hp"]
	var mp: float = game.player["mp"]
	var hp_recovery := floorf(game.max_hp/2.0)
	var hp_regen: float = game.numeric_player.values["hp_regen"]
	var mp_regen: float = game.numeric_player.values["mp_regen"]
	game.step_game(0.0)
	var absorbed: Array = game.bus.events_of("combat.cue").filter(func(event):return event.get("key") == "TINGKERBELL_ALL_ABSORB")
	var death: Array = game.bus.events_of("combat.cue").filter(func(event):return event.get("key") in ["native_jar_hpmpfairydestroy","native_jar_heartdestroy"])
	check(actors.is_empty() and game.item_restorations.size() == 1 and not game.view.audio._loop_voices.has(id)
		and absorbed.size() == 1 and game.bus.events_of("combat.jar_fairy_consumed").size() == 1,
		"contact consumes the fairy exactly once, plays the absorb cue and stops the float loop")
	check(death.size() == 1 and death[0]["key"] == "native_jar_hpmpfairydestroy"
		and death[0]["point"] == pot["pos"] and death[0]["height"] == 50.0,
		"the ordinary fairy draws only its original main disappearance at the source anchor")
	var recovery: Dictionary = game.item_restorations[0] if game.item_restorations.size() == 1 else {}
	check(is_equal_approx(float(recovery.get("hp",-1.0)),hp_recovery)
		and is_equal_approx(float(recovery.get("mp",-1.0)),game.max_mp-mp),"source fairy caps each recovery by the current resource gap")
	game.step_game(500.0)
	check(is_equal_approx(game.player["hp"],hp+(hp_recovery+hp_regen)/2.0)
		and is_equal_approx(game.player["mp"],minf(game.max_mp,(mp+game.max_mp+mp_regen)/2.0)),
		"the source fairy recovery and ordinary regeneration advance separately")
	game.step_game(500.0)
	check(is_equal_approx(game.player["hp"],hp+hp_recovery+hp_regen) and game.player["mp"] == game.max_mp
		and game.item_restorations.is_empty(),"fairy restores half max HP and ends at the one-second source deadline")

func check_poison_jar(pot: Dictionary) -> void:
	game.player["pos"] = pot["pos"]+Vector2(-220,0)
	game.step_game(1991.0)
	var actors: Array = game.native_jar_traps.actors
	check(actors.size() == 1 and pot["broken"] and actors[0].get("emission_ms") == 290
		and game.view.audio._loop_voices.has(actors[0]["id"]),
		"poison jars release the source gas loop and use the PTL deadline "
		+ "(actors=%d broken=%s emission_ms=%s loop_voices=%d)"
		% [actors.size(), pot["broken"],
			actors[0].get("emission_ms") if actors.size() == 1 else -1,
			game.view.audio._loop_voices.size()])
	if actors.size() != 1:return
	var gas: Dictionary = actors[0]
	var enemy: Dictionary = game.spawn_enemy(pot["pos"],false,"native_starfish_rukuku")
	enemy["ai"] = false
	enemy["numeric"].base["poison_resistance"] = 25
	enemy["numeric"].recalculate()
	var rng := PotRolls.new([3999,3000])
	game.rng = rng
	game.player["pos"] = pot["pos"]
	game.player["invuln_ms"] = 0.0
	var hp: float = game.player["hp"]
	var damage_before: int = game.damage_taken
	game.bus.clear_history()
	game.step_game(0.0)
	var poison: Dictionary = game.numeric_player.effects.active.get("poison",{})
	var contacts: Array = game.bus.events_of("combat.damage")
	check(game.player["hp"] == hp and game.player["state"] == "hurt" and contacts.size() == 2
		and contacts.all(func(event):return event["amount"] == 0 and not event["show_number"]),
		"gas contact reacts on both teams and deals zero direct HP damage")
	check(poison.get("remaining_ms") == 7000.0 and not enemy["numeric"].effects.active.has("poison") and rng.queue.is_empty(),
		"normal gas uses strict 4000/3000 thresholds and respects specific poison resistance")
	if poison.is_empty():return
	game.view.present(game.view_snapshot(),0.0,0.0)
	var emission: Dictionary = game.view._poison_emitters.get(0,{})
	var silhouette: Sprite2D = game.view.player_actor._status_overlay
	check(not emission.is_empty() and emission["emitter"].origin.z == int(game.player["z"])+70
		and silhouette != null and silhouette.visible and silhouette.region_enabled,
		"the poisoned player draws the original +70 PTL and a separate native silhouette pass")
	game.player["pos"] = pot["pos"]+Vector2(10,0)
	game.player["facing"] = -1
	game.view.present(game.view_snapshot(),1.0,1.0)
	check(not emission.is_empty() and emission["emitter"].origin.x == int(game.player["pos"].x)
		and emission["emitter"].mirrored and silhouette.scale.x == -1.0,
		"the original poison emitter and mask follow movement and facing")
	var sounds: Array = game.bus.events_of("combat.cue").map(func(event):return event.get("key",""))
	check(sounds.has("CONDITION_POSION") and sounds.has("CONDITION_POSION_DROP") and sounds.has("CONDITION_POISON_POP"),
		"first poison application starts the original cue and both group components")
	game.step_game(18.0)
	check(game.damage_taken == damage_before and game.bus.events_of("combat.damage_number").is_empty(),
		"the first 18 milliseconds have zero cumulative poison damage")
	game.step_game(1.0)
	check(game.damage_taken == damage_before+1 and game.bus.events_of("combat.damage_number").is_empty(),
		"the first HP decrement occurs at 19 ms and does not emit a damage number")
	game.step_game(271.0)
	check(actors.size() == 1 and gas.get("emission_finished",false),"the gas records PTL completion at 290 ms")
	game.step_game(1.0)
	check(actors.is_empty() and not game.view.audio._loop_voices.has(gas["id"])
		and game.bus.events_of("combat.hit").size() == 2,"the following update removes the gas and never retries the resisted target")
	game.step_game(209.0)
	var numbers: Array = game.bus.events_of("combat.damage_number")
	check(game.damage_taken == damage_before+27 and numbers.size() == 1 and numbers[0]["amount"] == 27,
		"the first source poison damage number aggregates 27 at 500 ms")
	check(game.view.numbers.any(func(number):return number["style"] == "damage_crit" and number["value"] == 27),
		"local poison damage uses the original 54–63 digit set")
	game.step_game(6500.0)
	check(game.damage_taken == damage_before+386 and not game.numeric_player.effects.active.has("poison"),
		"ordinary dungeon poison applies the full source cumulative damage and ends at 7000 ms")
	game.view.present(game.view_snapshot(),0.0,0.0)
	check(game.view._poison_emitters.is_empty() and not silhouette.visible,"poison expiry removes the emitter and actor overlay")
	var effects = game.numeric_player.effects
	effects.add_source_poison(386,7000)
	effects.step(1000.0)
	effects.add_source_poison(386,7000)
	var overlap: Array = effects.step(500.0)
	check(overlap.size() == 2 and overlap[0]["damage"] == 54 and overlap[1]["damage"] == 54
		and effects.active["poison"]["stacks"] == 2 and effects.active["poison"]["remaining_ms"] == 6500.0,
		"two independent applications preserve older HP age and restart only the shared damage-number window")
	effects.remove("poison")

func check_orange_fairy_run() -> void:
	var export: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(EXPORT))
	var node := 7
	var item: Dictionary = export["dungeon"]["rooms"]["map/outerwall/b3003.map"]["objects"][node]
	var number := 0
	for candidate in range(1,30000):
		var run_id := "run_%d"%candidate
		if NativeJarTraps.prepare(item,hash("%s:outerwall:5:trap:%d"%[run_id,node])).get("id") != 2410:continue
		var rolls := DetRng.new(hash(run_id))
		var entry := rolls.range_int(0,1)
		var boss := rolls.range_int(0,1)
		if entry == 0 and boss == 1:
			number = candidate
			break
	check(number > 0,"an ordinary adventure selects the rare original orange fairy")
	if number == 0:return
	events.clear()
	var started := session.start_room(start_spec(0,1,0,number))
	check(started,"the orange fairy fixture starts a real selected boss route")
	if not started:return
	for side in ["right","down","right","right","right","up","right"]:
		clear_all()
		if not hop(side):return
	present_room()
	var pots: Array = game.props.filter(func(prop):return prop["node"] == node)
	check(game.route_boss_room() and game.native_room["source_map_id"] == 3024 and pots.size() == 1
		and pots[0].get("jar_trap",{}).get("id") == 2410,"the actual boss MAP contains the rare orange jar")
	if pots.size() != 1:return
	for enemy: Dictionary in game.monsters:enemy["ai"] = false
	var pot: Dictionary = pots[0]
	var atk: Dictionary = game.move_def("normalwave")["hits"][0]["atk"]
	prop_melee(pot["damage_boxes"][1].get_center(),atk,1000)
	var visuals: Array = game.native_jar_traps.view_objects(game)
	var actors: Array = game.native_jar_traps.actors
	check(pot["broken"] and visuals.map(func(layer):return layer["effect"]) == ["native_jar_invinsiblefairy","native_jar_invinsiblefairyef"],
		"orange fairy uses the original body and single attached light")
	if actors.size() != 1:return
	var fairy: Dictionary = actors[0]
	game.player["pos"] = pot["pos"]
	game.player["invuln_ms"] = 0.0
	game.bus.clear_history()
	game.step_game(0.0)
	game.view.present(game.view_snapshot(),0.0,0.0)
	var cues: Array = game.bus.events_of("combat.cue")
	check(game.native_jar_traps.player_protected and game.native_jar_traps.actors.is_empty()
		and is_equal_approx(game.view.player_actor.tint.a,100.0/255.0)
		and cues.any(func(event):return event.get("key") == "TINGKERBELL_HP_ABSORB")
		and cues.any(func(event):return event.get("key") == "native_jar_invinsiblefairydestroy"),
		"contact activates the separate source flag, opacity, absorb sound and original disappearance")
	var before: int = game.damage_taken
	var source: Vector2 = pot["pos"]+Vector2(-10,0)
	game.damage_player(30,source)
	check(game.damage_taken == before and game.player["state"] != "hurt","fairy protection rejects an ordinary direct hit")
	game.numeric_player.effects.add_source_poison(7,1000)
	game.step_game(1000.0)
	game.native_jar_traps.consume_fairy(game,fairy)
	game.step_game(13999.0)
	check(game.damage_taken == before+7 and game.native_jar_traps.player_protected,
		"an existing HP-over-time entry continues and protection still holds at 14999 ms")
	game.step_game(1.0)
	game.damage_player(30,source)
	check(game.damage_taken == before+37 and not game.native_jar_traps.player_protected,
		"the 15000 ms expiry restores incoming hits")
	game.native_jar_traps.consume_fairy(game,fairy)
	game.step_game(1000.0)
	check(not game.native_jar_traps.player_protected and game.native_jar_traps.protection_deadlines.size() == 1,
		"an earlier overlapping expiry still clears a subsequently applied fairy flag")

func prepare_pot_fixture() -> void:
	var export: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(EXPORT))
	var dungeon: Dictionary = export["dungeon"]
	var rolls := PotRolls.new([60,80,0,40,21,99,99])
	NativePotMonsters.prepare_catalog(dungeon,rolls)
	check(rolls.queue.is_empty(),"catalog load draws once for every original hidden monster row")
	var unused := PotRolls.new([0])
	NativePotMonsters.prepare_catalog(dungeon,unused)
	check(unused.queue == [0],"later adventures reuse the prepared source catalog")
	var miss := NativePotMonsters.select([[260,30,1,5,-1]],PotRolls.new([21]))
	var match_edge := NativePotMonsters.select([[260,30,1,5,-1]],PotRolls.new([20]))
	check(miss.is_empty() and match_edge.size() == 1,"catalog chance rejects above the threshold and accepts equality")
	check(NativePotMonsters.launch(PotRolls.new([1]),true,17.0).is_empty(),"the original override forces a ground release")

func check_pot_run() -> void:
	var spec := start_spec(0,1,0)
	var started := session.start_room(spec)
	check(started,"the normal session admits the original hidden monster pot route")
	if not started:return
	for side: String in ["right","down","right","right","down"]:
		clear_all()
		if not hop(side):return
	present_room()
	var pots := monster_pots()
	check(game.native_room["source_map_id"] == 3006 and pots.size() == 2,"the route enters the original MAP3006 with two hidden rosters")
	if pots.size() != 2:return
	var first: Dictionary = pots[0]
	var mixed: Dictionary = pots[1]
	var reserved_ids: Array = first["pot_monsters"].map(func(row):return row["id"])
	reserved_ids.append_array(mixed["pot_monsters"].map(func(row):return row["id"]))
	check(reserved_ids.size() == 4 and reserved_ids.all(func(id):return game.monsters.all(func(enemy):return enemy["id"] != id)),
		"four reserved ids are absent from the living actor table before release")
	clear_all()
	present_room()
	check(game.view.stage.cleared and session.read_runtime_view()["room_cleared"],"hidden rosters leave the original door open after clear")
	var clears := events.size()
	if not hop("up"):return
	if not hop("down"):return
	present_room()
	pots = monster_pots()
	first = pots[0]
	mixed = pots[1]
	check(first["pot_monsters"][0]["id"] == reserved_ids[0] and events.size() == clears,
		"visiting again keeps the same hidden id and does not repeat clear")
	var atk: Dictionary = game.move_def("attack1")["hits"][0]["atk"]
	var real_rng = game.rng
	game.rng = PotRolls.new([1,0,0,1,0,0])
	var box: AABB = first["damage_boxes"][0]
	game.bus.clear_history()
	prop_melee(box.get_center(),atk,1000)
	check(game.rng.queue.is_empty(),"airborne release consumes the six original draws in order")
	check(game.bus.events_of("combat.cue").filter(func(event):return event.get("key") == "ZGM_SPRING").size() == 1,
		"the shared source airborne receiver plays its jump cue once")
	game.rng = real_rng
	check(game.monsters.size() == 1,"striking the first pot creates its one selected actor")
	if game.monsters.size() != 1:return
	var enemy: Dictionary = game.monsters[0]
	check(enemy["id"] == reserved_ids[0] and enemy["mob"] == NativePotMonsters.MOBS[250]
		and enemy["pos"] == game.constrain_pos(first["pos"]) and enemy["facing"] == 1 and enemy["z"] == 10.0
		and enemy["native_jump_velocity"] == Vector2(-50,25) and enemy["numeric"].values["level"] == 30,
		"airborne Starfish uses original reserved id, position, facing, signed velocity and level")
	check(session.configure_monsters(28,"adventure") and enemy["numeric"].values["level"] == 30,
		"room scaling keeps the hidden MOB source level")
	present_room()
	check(game.room_cleared and not game.view.stage.cleared and not session.read_view()["room_cleared"]
		and not session.read_runtime_view()["room_cleared"] and session.read_runtime_view()["exit_target"] == Vector2.ZERO,
		"actual birth closes the source gate and removes the exit while keeping the clear receipt")
	game.player["pos"] = game.door_point("up")
	game.door_lock_ms = 0.0
	game.step_game(100.0)
	check(game.native_room["source_map_id"] == 3006 and float(enemy["z"]) > 10.0 and game.enemy_ani(enemy)[0] == "stay",
		"the airborne actor updates in battle and physically blocks crossing the reopened door")
	for tick in range(64):
		game.update_enemy(enemy,16.0)
		if enemy["state"] != "native_summon_jump":break
	check(enemy["state"] == "idle" and enemy["z"] == 0.0 and game.enemy_ani(enemy) == ["stay",0.0],
		"the physical landing returns to a restarted waiting clip in the same tick")
	game.player["pos"] = Vector2(741,314)
	clear_all()
	present_room()
	check(game.view.stage.cleared and events.size() == clears,"defeating the new actor reopens the door without a second clear event")
	box = mixed["damage_boxes"][0]
	game.rng = PotRolls.new([0,0,1,99,49,1,1,59])
	game.bus.clear_history()
	prop_melee(box.get_center(),atk,1000)
	check(game.rng.queue.is_empty(),"each grounded child uses one draw before the airborne Raxy draws")
	check(not game.bus.events_of("combat.cue").any(func(event):return event.get("key") == "ZGM_SPRING"),
		"grounded Starfish and airborne Raxy skip the Starfish jump cue")
	game.rng = real_rng
	var children: Array = game.monsters.filter(func(actor):return actor["hp"] > 0)
	check(children.map(func(actor):return actor["id"]) == reserved_ids.slice(1)
		and children.map(func(actor):return actor["mob"]) == [NativePotMonsters.MOBS[250],NativePotMonsters.MOBS[250],NativePotMonsters.MOBS[260]]
		and children.slice(0,2).all(func(actor):return actor["z"] == 0.0 and actor["facing"] == 1 and actor["state"] == "idle")
		and children[2]["z"] == 10.0 and children[2]["facing"] == 1 and children[2]["native_jump_velocity"] == Vector2(-149,-74),
		"one pot releases the ordered original mix of two grounded Starfish and one airborne Raxy")
	prop_melee(box.get_center(),atk,1000)
	check(game.monsters.size() == 4,"a repeated strike cannot release another roster")
	clear_all()
	if not hop("up"):return
	if not hop("down"):return
	present_room()
	check(game.monsters.is_empty() and game.view.stage.cleared and monster_pots().all(func(prop):return prop["broken"]),
		"returning after both releases preserves destruction with no respawn or relock")

func monster_pots() -> Array:
	return game.props.filter(func(prop):return prop.has("pot_monsters"))

func hop(side: String) -> bool:
	var previous: int = game.room_index
	game.player["pos"] = game.door_point(side)
	game.door_lock_ms = 0.0
	game.step_game(0.0)
	var moved: bool = game.room_index != previous
	check(moved,"walking onto the source door crosses "+side)
	return moved

func clear_all() -> void:
	for enemy: Dictionary in game.monsters:enemy["hp"] = 0.0
	game.step_game(820.0)

func stage_gate(side: String) -> String:
	if game.view.stage.root == null:return ""
	var placement: Dictionary = game.view.stage.root.get_meta("placement",{})
	for gate: Dictionary in placement.get("gates",[]):
		if gate["direction"] == side:return "%s:%s"%[gate["kind"],gate["object"]]
	return ""

func check_final_clear() -> void:
	var live := {}
	for enemy: Dictionary in game.monsters:
		if live.is_empty() and not enemy["chief"]:
			live = enemy
			enemy["ai"] = false
		else:
			enemy["hp"] = 0.0
	game.step_game(820.0)
	check(not live.is_empty() and not game.finished and flow.state == "battle",
		"a non-boss hostile in the selected boss room prevents settlement")
	clear_all()
	var clears := events.size()
	check(game.finished and game.victory and flow.state == "result" and flow.result["victory"]
		and events[-1]["final_room"],"clearing the selected boss room settles through the flow once")
	game.step_game(820.0)
	check(events.size() == clears and not flow.combat_event(events[-1])["ok"],
		"the completed maze and flow both reject repeated settlement")
