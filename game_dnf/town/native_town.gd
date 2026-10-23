extends Node2D
signal interact(target: String)
const Loader = preload("res://scripts/native_map_loader.gd")
const Actor = preload("res://scripts/native_actor.gd")
const TextPatch = preload("res://ui/flow/native_text_patch.gd")
const UIFont = preload("res://ui/flow/ui_font.gd")
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
var running := false
var last_tap := {KEY_LEFT:-1000, KEY_RIGHT:-1000}
var run_direction := 0
var player_name := ""
var location := "elvengard"
var street: Node2D
var inn: Node2D
var quest_loader = Loader.new()
var quest_marks: Dictionary = {}

func _ready() -> void:
	loader.load_export("res://assets_local/flow_v1/manifest.json")
	map_root = loader.build(loader.placements()[0])
	street = map_root
	add_child(map_root)
	extend_ground_under_hud()
	for node in map_root.get_children():
		if node is Loader.MapSprite and node.frames.size() > 1:animated.append(node)
	actor = Actor.new()
	map_root.add_child(actor)
	var combat_assets: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets_local/combat/manifest.json"))
	var town_motion: Dictionary = combat_assets["player_locomotion"]["town"]
	actor.setup(town_motion["bank"], town_motion["clips"])
	font = UIFont.make()
	localize_signs()
	labels = Node2D.new()
	labels.z_index = 4000
	map_root.add_child(labels)
	labels.draw.connect(_draw_names)
	if quest_loader.load_export("res://assets_local/flow_v1/early_quests/manifest.json"):
		inn = quest_loader.build(quest_loader.placements()[0])
		add_child(inn)
		# Extend only the last 48 native floor pixels behind the transparent HUD.
		# The room uses a full background ANI and intentional dummy tiles.
		for node in inn.get_children():
			if node is Loader.MapSprite and node.get_meta("layer", "")=="closeback" and node.frames.size()==1 and node.texture and node.texture.get_width()>=800:
				var strip:=AtlasTexture.new()
				strip.atlas=node.texture
				strip.region=Rect2(0,node.texture.get_height()-48,node.texture.get_width(),48)
				var floor:=Sprite2D.new()
				floor.texture=strip
				floor.centered=false
				floor.position=Vector2(node.offset.x,node.position.y+node.offset.y+node.texture.get_height())
				floor.z_index=-3000
				inn.add_child(floor)
				break
		inn.hide()

func set_location(id: String, point := Vector2.ZERO) -> bool:
	if id not in ["elvengard", "seria_room"] or (id == "seria_room" and not is_instance_valid(inn)):return false
	location = id
	map_root = inn if id == "seria_room" else street
	actor.reparent(map_root, false)
	labels.reparent(map_root, false)
	street.visible = id == "elvengard"
	if is_instance_valid(inn):inn.visible = id == "seria_room"
	ground = point if point != Vector2.ZERO else Vector2(390, 200) if id == "seria_room" else Vector2(775, 205)
	running = false
	run_direction = 0
	animated.clear()
	for node in map_root.get_children():
		if node is Loader.MapSprite and node.frames.size() > 1:animated.append(node)
	return true

func extend_ground_under_hud() -> void:
	# The original 480-high field must continue behind the transparent HUD.
	# Repeat only the last native ground strip; all source pixels stay 1:1.
	var room: Dictionary = map_root.get_meta("room")
	for tile: Dictionary in room["tiles"]:
		if tile["image"] == null:continue
		var source: Texture2D = loader.texture(tile["image"])
		var strip := AtlasTexture.new()
		strip.atlas = source
		strip.region = Rect2(0, source.get_height() - 48, source.get_width(), 48)
		var sprite := Sprite2D.new()
		sprite.centered = false
		sprite.texture = strip
		sprite.position = Vector2(float(tile["column"]) * 224 + tile["offset"][0], tile["offset"][1] + source.get_height())
		sprite.z_index = -3100
		sprite.set_meta("hud_ground_extension", true)
		map_root.add_child(sprite)

func localize_signs() -> void:
	for node in map_root.get_children():
		if not node is Loader.MapSprite:continue
		for frame: Dictionary in node.frames:
			var info: Dictionary = loader.data["images"].get(frame.get("image"), {})
			if info.get("source_path") != "sprite/map/flags.img":continue
			# Replace the two foreign-looking cloth inscriptions, retaining the
			# original border, anvil emblem, pole and native cloth pixels.
			TextPatch.attach(node, node.texture, Rect2(12, 33, 8, 13), Rect2(node.offset + Vector2(11, 20), Vector2(44, 12)))
			TextPatch.attach(node, node.texture, Rect2(13, 93, 8, 13), Rect2(node.offset + Vector2(13, 109), Vector2(44, 12)))
			for entry in [[Vector2(17, 18), "林纳斯"], [Vector2(19, 107), "铁匠铺"]]:
				var label := Label.new()
				label.text = entry[1]
				label.position = node.offset + entry[0]
				label.add_theme_font_override("font", font)
				label.add_theme_font_size_override("font_size", 10)
				label.add_theme_color_override("font_color", Color("e1d4c6"))
				label.mouse_filter = Control.MOUSE_FILTER_IGNORE
				node.add_child(label)
			break

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
	running = direction.x != 0 and int(signf(direction.x)) == run_direction
	ground = constrain_ground(ground + direction * delta * (285 if running else 155))
	camera_x = clampf(ground.x - 400, 0, 96 if location == "seria_room" else 768)
	map_root.position.x = -roundf(camera_x)
	loader.apply_camera(map_root, camera_x)
	actor.position = Vector2(roundf(ground.x), roundf(ground.y + 120))
	actor.z_index = int(ground.y)
	actor.present("dash" if running else "move" if moving else "stay", clock_ms, facing, 0, 0)
	for node in animated:
		var total := 0.0
		for frame: Dictionary in node.frames:total += maxf(1, float(frame.get("delay_ms") if frame.get("delay_ms") != null else 100))
		var local := fposmod(clock_ms, total)
		for i in node.frames.size():
			local -= maxf(1, float(node.frames[i].get("delay_ms") if node.frames[i].get("delay_ms") != null else 100))
			if local < 0:
				node.show_frame(i)
				break
	labels.queue_redraw()

func nearest() -> String:
	if location == "seria_room":
		if ground.distance_to(Vector2(477, 160)) < 100:return "seria"
		if ground.y > 295:return "exit_inn"
		return ""
	if ground.distance_to(Vector2(445, 212)) < 95:return "linus"
	if ground.distance_to(Vector2(775, 185)) < 85:return "enter_inn"
	if ground.x > 1355:return "dungeon"
	return ""

func _unhandled_key_input(event: InputEvent) -> void:
	if enabled and event is InputEventKey:
		var key := int(event.physical_keycode if event.physical_keycode else event.keycode)
		if key in [KEY_LEFT, KEY_RIGHT]:
			if not event.pressed:run_direction = 0
			elif not event.echo:
				var now := Time.get_ticks_msec()
				if now - int(last_tap[key]) < 260:run_direction = -1 if key == KEY_LEFT else 1
				last_tap[key] = now
	if enabled and event.is_pressed() and not event.is_echo() and (event.physical_keycode == KEY_E or event.keycode == KEY_E):
		var target := nearest()
		if target != "":interact.emit(target)

func constrain_ground(point: Vector2) -> Vector2:
	if location == "seria_room":return Vector2(clampf(point.x, 330, 619), clampf(point.y, 178, 348))
	# Grass/stone foreground is walkable too. The tree/shop silhouettes stay
	# behind the upper ground contour; the lowest foot position clears the HUD.
	return Vector2(clampf(point.x, 24, 1540), clampf(point.y, 175, 352))

func _draw_names() -> void:
	if player_name != "":
		var at: Vector2 = actor.position + Vector2(-font.get_string_size(player_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x / 2, -134)
		labels.draw_string_outline(font, at, player_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, 3, Color.BLACK)
		labels.draw_string(font, at, player_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("d4edb0"))
	var entries := [[Vector2(477, 22), "赛丽亚"], [Vector2(448, 340), "艾尔文防线 ↓"]] if location == "seria_room" else [[Vector2(445, 49), "林纳斯"], [Vector2(775, 38), "赛丽亚房间"], [Vector2(1335, 48), "土罐"], [Vector2(1460, 95), "格兰之森 →"]]
	for entry in entries:
		var text: String = entry[1]
		var at: Vector2 = entry[0]
		at.x -= font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x / 2
		at.y += 120
		labels.draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, 3, Color.BLACK)
		labels.draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("e9d49a"))
	var npc_id := "seria" if location == "seria_room" else "linus"
	if quest_marks.get(npc_id, "") != "":
		var at := Vector2(477, 120) if npc_id == "seria" else Vector2(445, 147)
		labels.draw_string_outline(font, at, quest_marks[npc_id], HORIZONTAL_ALIGNMENT_CENTER, 28, 18, 3, Color.BLACK)
		labels.draw_string(font, at, quest_marks[npc_id], HORIZONTAL_ALIGNMENT_CENTER, 28, 18, Color("ffe074"))
	var hint: String = {"linus":"E 交谈 / 商店", "seria":"E 与赛丽亚交谈", "dungeon":"E 进入格兰之森", "enter_inn":"E 进入赛丽亚房间", "exit_inn":"E 返回艾尔文防线"}.get(nearest(), "")
	if hint != "":
		var at: Vector2 = actor.position + Vector2(-48, -110)
		labels.draw_string_outline(font, at, hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, 3, Color.BLACK)
		labels.draw_string(font, at, hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("fff2b5"))
