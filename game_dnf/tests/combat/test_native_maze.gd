extends SceneTree

const Maze = preload("res://combat/data/native_maze.gd")
const Loader = preload("res://scripts/native_map_loader.gd")
const DetRng = preload("res://core/det_rng.gd")
const OPPOSITE := {"left":"right","right":"left","up":"down","down":"up"}

var checks := 0
var failures := 0

class SourceRolls extends RefCounted:
	var values: Array[int]
	var calls: Array[Vector2i] = []

	func _init(sequence: Array[int]) -> void:
		values = sequence

	func range_int(low: int, high: int) -> int:
		var index := calls.size()
		calls.append(Vector2i(low,high))
		return values[index] if index < values.size() else low

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("[NATIVE_MAZE] FAIL "+label)

func run() -> void:
	var args := OS.get_cmdline_user_args()
	var loader := Loader.new()
	if args.size() != 1 or not loader.load_export(args[0]):
		push_error("[NATIVE_MAZE] Pass the fresh OuterWall map_export.json after --")
		quit(2)
		return
	var export: Dictionary = loader.data
	check_endpoints(export)
	check_revisit(export)
	check_branches(export)
	check_lower_boss(export)
	check_rejects_incomplete(export)
	print("[NATIVE_MAZE] COMPLETE checks=%d failures=%d"%[checks,failures])
	quit(0 if failures == 0 else 1)

func check_endpoints(export: Dictionary) -> void:
	var starts := [Vector2i(0,0),Vector2i(0,2)]
	var bosses := [Vector2i(5,2),Vector2i(5,0)]
	for start_slot in range(2):
		for boss_slot in range(2):
			var rolls := SourceRolls.new([start_slot,boss_slot,start_slot])
			var maze := Maze.new()
			check(maze.start(export,rolls),"all four independent source start and boss pairs load")
			if maze.current_room().is_empty():continue
			check(rolls.calls == [Vector2i(0,1),Vector2i(0,1),Vector2i(0,1)],"start, boss and start MAP each consume their own slot")
			check(maze.current_room()["cell"] == starts[start_slot],"source start coordinate preserved")
			check(maze.current_room()["source_map_id"] == 3001+start_slot,"both source start MAPs are selectable")
			var chosen := "map/outerwall/b3001.map" if bosses[boss_slot].y == 2 else "map/outerwall/b3003.map"
			var other := "map/outerwall/b3003.map" if bosses[boss_slot].y == 2 else "map/outerwall/b3001.map"
			check(chosen in maze.required_map_paths() and other not in maze.required_map_paths(),"preflight sees only the active boss pool")
			check(not maze.start(export,rolls) and rolls.calls.size() == 3,"a live run cannot be reset in place")
	var first := Maze.new()
	var second := Maze.new()
	check(first.start(export,DetRng.new(1701)) and second.start(export,DetRng.new(1701)),"project deterministic RNG is a valid source")
	check(first.current_room() == second.current_room(),"same local seed repeats the source selections")

func check_revisit(export: Dictionary) -> void:
	var rolls := SourceRolls.new([0,1,0,0,0])
	var maze := Maze.new()
	if not maze.start(export,rolls):
		check(false,"top start loads")
		return
	var entry: Vector2i = maze.current_room()["cell"]
	check(maze.move("right").is_empty(),"living enemies keep the room exit closed")
	check(maze.clear_room(entry,1).is_empty(),"a surviving hostile prevents room clear")
	check(maze.clear_room(Vector2i(5,0),0).is_empty(),"a stale final-cell event cannot settle the run")
	check(not maze.clear_room(entry,0).get("final_room",true),"clearing the start is not dungeon victory")
	check(maze.clear_room(entry,0).is_empty(),"each cell emits a clear exactly once")
	check(maze.move("up").is_empty() and rolls.calls.size() == 3,"an unlinked side consumes no roll")
	var upper := maze.move("right")
	check(upper.get("source_map_id") == 3004 and upper.get("ingress") == "left","first entry from the left excludes MAP3013")
	if upper.is_empty():return
	maze.clear_room(upper["cell"],0)
	var center := maze.move("down")
	if center.is_empty():
		check(false,"reciprocal lower gate is traversable")
		return
	maze.clear_room(center["cell"],0)
	var returning := maze.move("up")
	check(returning.get("source_map_id") == 3004 and returning.get("ingress") == "down", "reentry uses cached MAP3004 despite its first-entry mask")
	check(returning.get("visited_before",false) and returning.get("cleared",false) and rolls.calls.size() == 5,"reentry retains room clear without a new draw")
	var view := maze.current_room()
	view["placement"]["gates"].clear()
	check(not maze.current_room()["placement"]["gates"].is_empty(),"rendering callers cannot mutate the cached gates")
	var bottom := Maze.new()
	check(bottom.start(export,SourceRolls.new([1,0,0])),"bottom start loads")
	for side in ["right","up","up"]:
		var current := bottom.current_room()
		if current.is_empty():return
		bottom.clear_room(current["cell"],0)
		check(not bottom.move(side).is_empty(),"bottom approach crosses source gate "+side)
	check(bottom.current_room().get("source_map_id") == 3013,"first entry from below selects the only source ingress match")

func check_branches(export: Dictionary) -> void:
	var maze := Maze.new()
	if not maze.start(export,SourceRolls.new([0,1,0])):
		check(false,"branch traversal initializes")
		return
	var reached := {}
	visit_nonfinal(maze,reached)
	check(reached.size() == 15,"every non-boss cell is traversable before the final room")
	check(reached.get(Vector2i(5,2)) == 3021,"inactive boss coordinate uses the ordinary specified MAP")
	check(reached.get(Vector2i(4,0)) == 3015,"down entrance keeps the correct MAP next to the actual boss")
	for side in ["right","down","right","right","right","up"]:
		check(not maze.move(side).is_empty(),"cached route to final room crosses "+side)
	var adjoining := maze.current_room()
	check(gate_style(adjoining,"right") == "boss:434","the selected boss gate uses original right boss slot")
	var boss := maze.move("right")
	check(boss.get("source_map_id") == 3024 and boss.get("boss",false),"active boss cell chooses its source boss MAP")
	check(gate_style(boss,"left") == "boss:432","the reverse side also uses the original boss gate")
	if boss.is_empty():return
	check(maze.clear_room(boss["cell"],1).is_empty(),"one hostile prevents final victory")
	var clear := maze.clear_room(boss["cell"],0)
	check(clear.get("final_room",false) and clear.get("source_map_id") == 3024,"only clear of the active boss cell settles the run")
	check(maze.clear_room(boss["cell"],0).is_empty() and maze.move("left").is_empty(),"final clear is delivered once and ends movement")

func check_lower_boss(export: Dictionary) -> void:
	var maze := Maze.new()
	if not maze.start(export,SourceRolls.new([1,0,0])):
		check(false,"lower boss route initializes")
		return
	for side in ["right","up","right","right","right","right"]:
		maze.clear_room(maze.current_room()["cell"],0)
		if maze.move(side).is_empty():
			check(false,"lower boss route reaches the adjoining cell")
			return
	var adjoining := maze.current_room()
	check(gate_style(adjoining,"down") == "boss:438","lower boss activates the original down boss slot")
	maze.clear_room(adjoining["cell"],0)
	var boss := maze.move("down")
	check(boss.get("source_map_id") == 3022 and gate_style(boss,"up") == "boss:436","lower boss uses MAP3022 and the reciprocal up boss slot")
	check(maze.clear_room(Vector2i(5,2),0).get("final_room",false),"the lower boss cell can also settle the run")

func visit_nonfinal(maze: RefCounted, seen: Dictionary) -> void:
	var room: Dictionary = maze.current_room()
	var here: Vector2i = room["cell"]
	seen[here] = room["source_map_id"]
	check(not maze.clear_room(here,0).get("final_room",true),"ordinary room clear stays local")
	for gate: Dictionary in room["placement"]["gates"]:
		var raw = gate.get("target_cell")
		if raw == null or gate["kind"] == "boss":continue
		var target := Vector2i(int(raw[0]),int(raw[1]))
		if seen.has(target):continue
		var side: String = gate["direction"]
		var next: Dictionary = maze.move(side)
		check(next.get("cell") == target and not next.get("visited_before",true),"source branch resolves on first visit")
		if next.is_empty():continue
		visit_nonfinal(maze,seen)
		var back: Dictionary = maze.move(OPPOSITE[side])
		check(back.get("cell") == here and back.get("cleared",false),"reciprocal return preserves cleared room")

func gate_style(room: Dictionary, side: String) -> String:
	for gate: Dictionary in room.get("placement",{}).get("gates",[]):
		if gate["direction"] == side:return gate["kind"]+":"+gate["object"]
	return ""

func check_rejects_incomplete(export: Dictionary) -> void:
	var incomplete := export.duplicate(true)
	var room: Dictionary = incomplete["dungeon"]["rooms"]["map/outerwall/n3011.map"]
	room["greed_pairs"] = [[13,4]]
	var maze := Maze.new()
	check(not maze.start(incomplete,SourceRolls.new([0,1])),"unavailable branch ingress rejects the whole run")
	check(maze.current_room().is_empty() and maze.required_map_paths().is_empty(),"rejected preparation publishes no partial rooms")
	var missing_gate := export.duplicate(true)
	missing_gate["dungeon"]["gate_objects"].erase("434")
	check(not Maze.new().start(missing_gate,SourceRolls.new([0,1])),"unavailable active boss gate rejects preflight")
	var bad_roll := Maze.new()
	check(not bad_roll.start(export,SourceRolls.new([2,0])),"invalid replay roll cannot load a different endpoint")
