extends Node2D
## Standalone T2 verification scene for exported original maps. Not used by main.tscn.
## Keys: PageUp/PageDown or Tab switch placement, Left/Right pan, O toggle gates, F2 walk grid.
## User args: --test runs checks; --capture saves full-room frames to temp/dnf_map_capture/.

const Loader = preload("res://scripts/native_map_loader.gd")
const EXPORT_PATH := "res://assets_local/native_maps/lorien/map_export.json"
const VIEW := Vector2i(640, 480)

var loader
var world: Node2D
var current: Node2D
var index := 0
var camera_x := 0.0
var gates_open := false
var show_grid := false
var label: Label
var checks := 0
var failures := 0

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	get_window().content_scale_size = VIEW
	world = Node2D.new()
	add_child(world)
	var hud := CanvasLayer.new()
	add_child(hud)
	label = Label.new()
	label.position = Vector2(6, 4)
	label.add_theme_font_size_override("font_size", 10)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 3)
	hud.add_child(label)
	loader = Loader.new()
	if not loader.load_export(EXPORT_PATH):
		label.text = "缺少导出数据：先运行 python tools/export_dnf_map.py\n" + "\n".join(loader.errors)
		if _arg("--test"):
			push_error("[MAP_TEST] FAIL export missing")
			get_tree().quit(1)
		return
	show_placement(0)
	if _arg("--test"):call_deferred("run_tests")
	elif _arg("--capture"):call_deferred("capture_all")

func _arg(name: String) -> bool:
	return name in OS.get_cmdline_user_args()

func show_placement(n: int) -> void:
	var list: Array = loader.placements()
	index = posmod(n, list.size())
	if current:current.queue_free()
	current = loader.build(list[index])
	world.add_child(current)
	gates_open = false
	set_camera(0.0)
	queue_redraw()

func room_width() -> float:
	return float(current.get_meta("room")["width"])

func set_camera(x: float) -> void:
	camera_x = clampf(x, 0.0, maxf(0.0, room_width() - VIEW.x))
	world.position.x = -camera_x
	loader.apply_camera(current, camera_x)
	_update_label()
	queue_redraw()

func _update_label() -> void:
	var p: Dictionary = current.get_meta("placement")
	var r: Dictionary = current.get_meta("room")
	label.text = "[试验装配，非原版验收] %d/%d  格%s  %s  宽%d  镜头x=%d  门:%s\nPgUp/PgDn 换房  ←/→ 平移  O 开关门  F2 走区" % [
		index + 1, loader.placements().size(), str(p["cell"]), r["path"], int(r["width"]), int(camera_x), "开" if gates_open else "关"]

func _process(delta: float) -> void:
	if current == null:return
	var dir := Input.get_axis("ui_left", "ui_right")
	if dir != 0.0:set_camera(camera_x + dir * 360.0 * delta)

func _unhandled_input(event: InputEvent) -> void:
	if current == null or not (event is InputEventKey and event.pressed and not event.echo):return
	match event.keycode:
		KEY_PAGEDOWN, KEY_TAB:show_placement(index + 1)
		KEY_PAGEUP:show_placement(index - 1)
		KEY_O:
			gates_open = not gates_open
			loader.set_gates_open(current, gates_open)
			_update_label()
		KEY_F2:
			show_grid = not show_grid
			queue_redraw()

func _draw() -> void:
	if not show_grid or current == null:return
	var k: Dictionary = loader.constants()
	var grid: Array = current.get_meta("room")["walk_grid"]
	var cw := float(k["cell_width"])
	var ch := float(k["cell_height"])
	for r in grid.size():
		for c in (grid[r] as Array).size():
			if grid[r][c] == 0:
				draw_rect(Rect2(c * cw - camera_x, r * ch + float(k["screen_y_offset"]), cw - 1, ch - 1), Color(0.2, 1, 0.5, 0.35), false)

func check(value: bool, message: String) -> void:
	checks += 1
	if value:print("[MAP_TEST] PASS " + message)
	else:
		failures += 1
		push_error("[MAP_TEST] FAIL " + message)

func run_tests() -> void:
	var list: Array = loader.placements()
	check(list.size() >= 6, "export lists placements for every dungeon cell (%d)" % list.size())
	check(loader.data["source"]["asset_version"] == JSON.parse_string(FileAccess.get_file_as_string("res://asset_store.json"))["version"], "export matches locked asset version")
	var cells := {}
	for i in list.size():
		show_placement(i)
		var p: Dictionary = list[i]
		var r: Dictionary = current.get_meta("room")
		cells[str(p["cell"])] = true
		check(int(current.get_meta("placed_sprites")) > 0, "%s places native sprites" % p["id"])
		check((r["walk_grid"] as Array).size() == 30 and (r["walk_grid"][0] as Array).size() == (r["tiles"] as Array).size() * 14, "%s walk grid matches tile columns" % p["id"])
		var ok := 0
		for m: Dictionary in r["monsters"]:
			ok += int(loader.is_walkable(r, float(m["anchor"][0]), float(m["anchor"][1])))
		check(r["monsters"].is_empty() or ok * 10 >= (r["monsters"] as Array).size() * 8, "%s monster anchors mostly on walkable cells (%d/%d)" % [p["id"], ok, (r["monsters"] as Array).size()])
		var gate_nodes: Array = current.get_meta("gate_nodes")
		check(gate_nodes.size() > 0, "%s builds gate parts" % p["id"])
		var closed_visible := gate_nodes.filter(func(n): return n.visible and n.get_meta("gate_state") == "closed").size()
		loader.set_gates_open(current, true)
		var open_visible := gate_nodes.filter(func(n): return n.visible and n.get_meta("gate_state") == "open").size()
		var closed_after := gate_nodes.filter(func(n): return n.visible and n.get_meta("gate_state") == "closed").size()
		var has_door: bool = p["gates"].any(func(g): return g["kind"] != "wall")
		check(not has_door or (closed_visible > 0 and open_visible > 0 and closed_after == 0), "%s gate open/close swaps door parts" % p["id"])
		set_camera(99999.0)
		check(is_equal_approx(camera_x, maxf(0.0, room_width() - VIEW.x)), "%s camera clamps to room width" % p["id"])
		var far: Array = (current.get_meta("parallax") as Array).filter(func(n): return n.name == "bg_distantback")
		check(far.is_empty() or far[0].position.x > 0.0, "%s distant layer scrolls slower than world" % p["id"])
	check(cells.size() == int(loader.data["dungeon"]["size"][0]) * int(loader.data["dungeon"]["size"][1]), "every greed cell has at least one map candidate")
	check(loader.errors.is_empty(), "loader reported no errors " + str(loader.errors))
	print("[MAP_TEST] COMPLETE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(0 if failures == 0 else 1)

func capture_all() -> void:
	var folder := ProjectSettings.globalize_path("res://../temp/dnf_map_capture")
	DirAccess.make_dir_recursive_absolute(folder)
	var list: Array = loader.placements()
	for i in list.size():
		show_placement(i)
		label.visible = false
		var shots := [0.0, room_width() - VIEW.x]
		for s in shots.size():
			for open in [false, true]:
				gates_open = open
				loader.set_gates_open(current, open)
				set_camera(shots[s])
				for t in 50:await get_tree().process_frame
				var name := "%02d_%s_cam%d_%s.png" % [i, String(list[i]["id"]).replace(":", "_"), s, "open" if open else "closed"]
				get_viewport().get_texture().get_image().save_png(folder + "/" + name)
	print("[MAP_CAPTURE] saved to " + folder)
	get_tree().quit()
