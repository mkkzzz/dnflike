extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const FlowSession = preload("res://flow/session.gd")
const DetRng = preload("res://core/det_rng.gd")
const NativeMaze = preload("res://combat/data/native_maze.gd")
const EXPORT := "res://assets_local/native_maps/outerwall_v1/map_export.json"
const ROUTE := {"mode":"native_maze","map_export":EXPORT,"name":"神殿周边"}
const NORMAL_MUSIC := "res://assets_local/audio/bgm/outer_temple.ogg"
const BOSS_MUSIC := "res://assets_local/audio/bgm/behemoth_b01_1.ogg"

var session := CombatSession.new()
var game
var events: Array[Dictionary] = []
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
	check(not game.missing_assets,"production combat tables and new source atlases load")
	if not game.missing_assets:
		check_upper_run()
		check_lower_run()
		check_breakable_run()
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

func seed_for(start_slot: int, boss_slot: int, map_slot: int) -> int:
	for number in range(1,100):
		var draws := DetRng.new(hash("run_%d"%number))
		var entry := draws.range_int(0,1)
		var boss := draws.range_int(0,1)
		var map := draws.range_int(0,1)
		if entry == start_slot and boss == boss_slot and map == map_slot:return number
	return -1

func start_spec(start_slot: int, boss_slot: int, map_slot: int) -> Dictionary:
	flow = FlowSession.new()
	flow.dungeons["outerwall"] = ROUTE.duplicate()
	flow.profile["next_run"] = seed_for(start_slot,boss_slot,map_slot)
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
	var pots: Array = game.props.filter(func(prop):return prop["native_breakable"]["object_index"] == 771)
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
	var export: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(EXPORT))
	var run := ""
	# Select a replay whose unchosen upper entrance uses the original box MAP.
	for i in range(1,100):
		var id := "run_%d"%i
		var maze := NativeMaze.new()
		if not maze.start(export,DetRng.new(hash(id))) or maze.current_room()["cell"] != Vector2i(0,2):continue
		for side: String in ["right","up","up","left"]:
			maze.clear_room(maze.current_room()["cell"],0)
			maze.move(side)
		if maze.current_room()["source_map_id"] == 3019:
			run = id
			break
	flow = null
	var started := not run.is_empty() and session.start_room({"run_id":run,"dungeon":"outerwall","route":ROUTE,"audio":{"muted":true}})
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
	check(game.native_room["source_map_id"] == 3019 and game.props.size() == 2,
		"the box MAP enables its two empty payload rows and excludes nested item rows")
	if game.props.is_empty():return
	var box: Dictionary = game.props[0]
	shape = box["damage_boxes"][0]
	check(box["hp"] == 300 and box["damage_boxes"].size() == 2,"the original collection box has two damage boxes and 300 HP")
	game.bus.clear_history()
	prop_melee(shape.get_center(),atk,300)
	check_prop_burst(box,15)

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
