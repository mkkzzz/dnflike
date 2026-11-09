extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const DetRng = preload("res://core/det_rng.gd")
const Minimap = preload("res://ui/combat/widgets/outerwall_minimap.gd")
const ROUTE := {"mode":"native_maze","map_export":"res://assets_local/native_maps/outerwall_v1/map_export.json","name":"神殿周边"}
const CAPTURE_DIR := "res://../temp/outerwall_ui_audit"

var session := CombatSession.new()
var game
var checks := 0
var failures := 0
var graphical := false

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	graphical = DisplayServer.get_name() != "headless"
	game = session.mount(root)
	game.set_process(false)
	game.set_physics_process(false)
	if start_maze(0,1):
		await upper_route()
	if start_maze(1,0):
		check(cell([5,2])["boss"] and not cell([5,0])["boss"],"new run moves the boss to the lower endpoint")
		await draw_room()
		check_parts([["boss",Vector2(770,81)],["player",Vector2(685,83)]],"lower endpoint positions")
		await capture("lower",Vector2i(770,81))
	check(session.start_room({"dungeon":"lorien","audio":{"muted":true}}),"return to a legacy linear route")
	await draw_room()
	check(not cell([0,0]).has("source_map_id"),"legacy route is not marked as native")
	if graphical:check(parts().is_empty(),"the legacy route has no OuterWall overlay")
	session.stop()
	await process_frame
	print("[NATIVE_MAZE_MINIMAP] COMPLETE checks=%d failures=%d"%[checks,failures])
	quit(0 if failures == 0 else 1)

func start_maze(start_slot: int, boss_slot: int) -> bool:
	for i in range(1,100):
		var id := "run_%d"%i
		var rolls := DetRng.new(hash(id))
		var entry := rolls.range_int(0,1)
		var boss := rolls.range_int(0,1)
		if entry == start_slot and boss == boss_slot:
			var started := session.start_room({"run_id":id,"dungeon":"outerwall","route":ROUTE,"audio":{"muted":true}})
			check(started,"public battle entry admits source maze %d/%d"%[start_slot,boss_slot])
			return started
	check(false,"deterministic endpoint seed found")
	return false

func upper_route() -> void:
	var current := cell([0,0])
	check(current["visited"] and current["current"] and current["mask"] == 1
		and current["source_map_id"] in [3001,3002],"HUD sees selected start MAP and source right door")
	check(Minimap.room_frame(current,current,0) == 4,"current start is the bright source variant")
	var unknown := cell([1,0])
	check([Minimap.room_frame(unknown,current,0),Minimap.room_frame(unknown,current,249),
		Minimap.room_frame(unknown,current,250),Minimap.room_frame(unknown,current,499),
		Minimap.room_frame(unknown,current,500)] == [121,121,120,120,121],"linked neighbor switches every 250 ms")
	check(Minimap.room_frame(cell([2,0]),current,0) == -1
		and Minimap.room_frame(cell([5,2]),current,0) == -1,"far cells and the inactive boss candidate are hidden")
	check(Minimap.room_frame(cell([5,0]),current,0) == 120,"far actual boss has the original solo question base")
	await draw_room()
	check_parts([["board",Vector2(671,17)],["room_4",Vector2(679,43)],["player",Vector2(685,47)],
		["room_120",Vector2(769,43)],["boss",Vector2(770,45)]],"original board, start and far boss coordinates")
	if graphical:
		var drawn := parts()
		check(drawn.size() == 6 and (["room_120",Vector2(697,43)] in drawn or ["room_121",Vector2(697,43)] in drawn),
			"one 18 px neighbor and one boss are painted in the actual HUD")
	await capture("upper",Vector2i(770,45))
	if not walk("right"):return
	current = cell([1,0])
	check(current["source_map_id"] in [3004,3012] and Minimap.room_frame(current,current,0) == 92
		and Minimap.room_frame(cell([0,0]),current,0) == 0,"live door crossing lights the new room and dims the prior visit")
	check(Minimap.room_frame(cell([2,0]),current,0) == -1
		and Minimap.room_frame(cell([1,1]),current,0) == 121,"an orthogonal cell also needs the current room's door bit")
	await draw_room()
	check_parts([["room_0",Vector2(679,43)],["room_92",Vector2(697,43)],["player",Vector2(703,47)]],"traversed HUD positions")
	await capture("entered",Vector2i(770,45))
	if not walk("down"):return
	current = cell([1,1])
	var map_id := int(current["source_map_id"])
	check(map_id in [3008,3018] and Minimap.room_frame(current,current,0) == (85 if map_id == 3008 else 86),
		"interior tile variation uses the selected MAP ID and both coordinates")
	for side in ["right","right","right","up","right"]:
		if not walk(side):return
	current = cell([5,0])
	check(current["current"] and current["boss"] and Minimap.room_frame(current,current,0) == 28,
		"inside the real boss room the bright door tile takes priority")
	await draw_room()
	check_parts([["room_28",Vector2(769,43)],["player",Vector2(775,47)]],"boss room uses current marker")
	if graphical:check(parts().all(func(piece):return piece[0] != "boss"),"skull overlay is suppressed inside the boss room")
	await capture("boss",Vector2i(-1,-1))

func walk(side: String) -> bool:
	for enemy: Dictionary in game.monsters:enemy["hp"] = 0.0
	game.step_game(820.0)
	var old: int = game.room_index
	game.player["pos"] = game.door_point(side)
	game.door_lock_ms = 0.0
	game.step_game(0.0)
	var moved: bool = old != game.room_index
	check(moved,"live door crosses "+side)
	return moved

func cell(point: Array) -> Dictionary:
	var route: Array = game.view_snapshot()["hud"]["route"]
	for row: Dictionary in route:
		if row["cell"] == point:return row
	return {}

func draw_room() -> void:
	game.view.present(game.view_snapshot(),0.0,0.0)
	if graphical:await RenderingServer.frame_post_draw

func parts() -> Array:
	var drawn: Array = game.view.hud.trace
	return drawn.filter(func(entry):return entry[0] == "minimap").map(func(entry):return entry.slice(1))

func check_parts(expected: Array, label: String) -> void:
	if not graphical:return
	var drawn := parts()
	check(expected.all(func(piece):return piece in drawn),label)

func capture(label: String, boss_at: Vector2i) -> void:
	if not graphical:return
	var image := root.get_texture().get_image()
	if boss_at.x >= 0:
		var doc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(Minimap.MANIFEST))
		var atlas := (load(doc["texture"]) as Texture2D).get_image()
		var rect: Array = doc["items"]["boss"]["rect"]
		var matching := 0
		var compared := 0
		for y in range(int(rect[3])):
			for x in range(int(rect[2])):
				var pixel := atlas.get_pixel(int(rect[0])+x,int(rect[1])+y)
				if pixel.a8 < 240:continue
				compared += 1
				# The source 4444 frame tops out at alpha 240. Allow only blending with the room underneath.
				var drawn := image.get_pixelv(boss_at+Vector2i(x,y))
				var channel_error := maxi(abs(drawn.r8-pixel.r8),maxi(abs(drawn.g8-pixel.g8),abs(drawn.b8-pixel.b8)))
				if channel_error <= 256-pixel.a8:matching += 1
		check(compared > 0 and matching == compared,"rendered skull uses the original pixels at native scale")
	if "--capture" not in OS.get_cmdline_user_args():return
	var dir := ProjectSettings.globalize_path(CAPTURE_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	check(image.save_png(dir.path_join("minimap_%s.png"%label)) == OK,"saved rendered "+label+" screenshot")

func check(ok: bool, label: String) -> void:
	checks += 1
	if ok:return
	failures += 1
	push_error("[NATIVE_MAZE_MINIMAP] FAIL "+label)
