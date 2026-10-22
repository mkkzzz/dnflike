extends Node2D
signal interact(target: String)
const Loader = preload("res://scripts/native_map_loader.gd")
const Actor = preload("res://scripts/native_actor.gd")
var loader = Loader.new()
var map_root: Node2D
var actor
var ground := Vector2(540, 230)
var camera_x := 200.0
var clock_ms := 0.0
var facing := -1
var enabled := true
var moving := false
var labels: Node2D
var font: Font
var animated: Array = []

func _ready() -> void:
	loader.load_export("res://assets_local/flow_v1/manifest.json")
	map_root = loader.build(loader.placements()[0])
	add_child(map_root)
	for node in map_root.get_children():
		if node is Loader.MapSprite and node.frames.size() > 1:animated.append(node)
	var assets: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets_local/manifest.json"))
	var clips: Dictionary = {}
	for key: String in assets["clips"]:
		if key.begins_with("player/"):clips[key.get_slice("/", 1)] = assets["clips"][key]
	actor = Actor.new()
	map_root.add_child(actor)
	actor.setup(assets["players"]["katana"], clips)
	font = load("res://assets_local/flow_v1/msjh.ttf")
	labels = Node2D.new()
	labels.z_index = 4000
	map_root.add_child(labels)
	labels.draw.connect(_draw_names)

func _process(delta: float) -> void:
	clock_ms += delta * 1000
	var direction := Vector2.ZERO
	if enabled:
		direction = Vector2(float(Input.is_physical_key_pressed(KEY_RIGHT)) - float(Input.is_physical_key_pressed(KEY_LEFT)),
			float(Input.is_physical_key_pressed(KEY_DOWN)) - float(Input.is_physical_key_pressed(KEY_UP)))
	if direction.length() > 1:direction = direction.normalized()
	moving = direction.length_squared() > 0
	if direction.x != 0:facing = int(signf(direction.x))
	# Native town rectangles; collision semantics of the source grid remain unverified.
	ground += direction * delta * 115
	ground.x = clampf(ground.x, 24, 1540)
	ground.y = clampf(ground.y, 195, 262)
	camera_x = clampf(ground.x - 320, 0, 928)
	map_root.position.x = -roundf(camera_x)
	loader.apply_camera(map_root, camera_x)
	actor.position = Vector2(roundf(ground.x), roundf(ground.y + 120))
	actor.z_index = int(ground.y)
	actor.present("move" if moving else "stay", clock_ms, facing, 0, 0)
	for node in animated:
		var total := 0.0
		for frame: Dictionary in node.frames:total += maxf(1, float(frame.get("delay_ms", 100)))
		var local := fposmod(clock_ms, total)
		for i in node.frames.size():
			local -= maxf(1, float(node.frames[i].get("delay_ms", 100)))
			if local < 0:
				node.show_frame(i)
				break
	labels.queue_redraw()

func nearest() -> String:
	if ground.distance_to(Vector2(445, 212)) < 95:return "linus"
	if ground.x > 1355:return "dungeon"
	return ""

func _unhandled_key_input(event: InputEvent) -> void:
	if enabled and event.is_pressed() and not event.is_echo() and (event.physical_keycode == KEY_E or event.keycode == KEY_E):
		var target := nearest()
		if target != "":interact.emit(target)

func _draw_names() -> void:
	for entry in [[Vector2(445, 49), "林纳斯"], [Vector2(1335, 48), "土罐"], [Vector2(1460, 95), "格兰之森 →"]]:
		var text: String = entry[1]
		var at: Vector2 = entry[0]
		at.x -= font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x / 2
		at.y += 120
		labels.draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, 3, Color.BLACK)
		labels.draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("e9d49a"))
	var hint := "E 交谈 / 商店" if nearest() == "linus" else "E 进入格兰之森" if nearest() == "dungeon" else ""
	if hint != "":
		var at: Vector2 = actor.position + Vector2(-48, -110)
		labels.draw_string_outline(font, at, hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, 3, Color.BLACK)
		labels.draw_string(font, at, hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("fff2b5"))
