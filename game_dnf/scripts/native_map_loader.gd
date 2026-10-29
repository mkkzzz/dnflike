extends RefCounted
## Builds Godot nodes from tools/export_dnf_map.py output (dnf_native_map/1).
## 纵向一律输出"画布坐标"：地砖/背景（美术坐标）+ART_DY，锚点（map 坐标）+MAP_DY，
## 基准见 view/world_frame.gd。调用方不再对地图根节点加偏移。
## Trial loader: coordinate/layer/scroll rules are E-INFER, recorded in the export's
## "coordinates" block; it does not touch main.gd or the combat simulation.

const Frame = preload("res://view/world_frame.gd")
const SCHEMA := "dnf_native_map/1"
const LAYER_BASE := {"distantback": -4000, "middleback": -3500, "bottom": -3000, "closeback": -2500, "normal": 0, "close": 3000}

class MapSprite extends Sprite2D:
	var frames: Array = []
	var textures: Array = []
	var offsets: Array = []
	var index := 0
	var elapsed := 0.0
	var playing := false

	func setup(sprite: Dictionary, loader) -> bool:
		frames = sprite.get("frames", [])
		centered = false
		for f: Dictionary in frames:
			textures.append(loader.texture(f.get("image")))
		if textures.all(func(t): return t == null):
			return false
		show_frame(0)
		return true

	func show_frame(n: int) -> void:
		index = clampi(n, 0, frames.size() - 1)
		var f: Dictionary = frames[index]
		texture = textures[index]
		var o: Array = f.get("offset", [0, 0])
		flip_h = bool(f.get("flip_x", false))
		var w := float(texture.get_width()) if texture else 0.0
		offset = Vector2(-float(o[0]) - w if flip_h else float(o[0]), float(o[1]))
		var c = f.get("color")
		modulate = Color8(int(c[0]), int(c[1]), int(c[2]), int(c[3])) if c is Array and c.size() == 4 else Color.WHITE
		if bool(f.get("additive", false)):
			var m := CanvasItemMaterial.new()
			m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
			material = m

	func play_once() -> void:
		elapsed = 0.0
		show_frame(0)
		playing = frames.size() > 1

	func _process(delta: float) -> void:
		if not playing:return
		elapsed += delta * 1000.0
		var f: Dictionary = frames[index]
		var span := float(f.get("delay_ms", 0) if f.get("delay_ms") != null else 0)
		var nxt := index + 1
		if nxt >= frames.size():
			playing = false
			return
		var items: Dictionary = f.get("items", {})
		if int(items.get("10", 0)) == 1 and span > 0.0:
			var a: Color = _frame_color(f)
			var b: Color = _frame_color(frames[nxt])
			modulate = a.lerp(b, clampf(elapsed / span, 0.0, 1.0))
		if elapsed >= span:
			elapsed -= span
			show_frame(nxt)
			if nxt == frames.size() - 1:playing = false

	func _frame_color(f: Dictionary) -> Color:
		var c = f.get("color")
		return Color8(int(c[0]), int(c[1]), int(c[2]), int(c[3])) if c is Array and c.size() == 4 else Color.WHITE

var data: Dictionary = {}
var base_dir := ""
var textures: Dictionary = {}
var errors: Array = []

func load_export(path: String) -> bool:
	if not FileAccess.file_exists(path):
		errors.append("export missing: " + path)
		return false
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary or parsed.get("schema") != SCHEMA:
		errors.append("unsupported export schema")
		return false
	data = parsed
	base_dir = path.get_base_dir()
	return true

func texture(key) -> Texture2D:
	if key == null:return null
	if textures.has(key):return textures[key]
	var info: Dictionary = data["images"].get(key, {})
	var tex: Texture2D = null
	if not info.is_empty():
		var image := Image.load_from_file(ProjectSettings.globalize_path(base_dir + "/" + String(info["file"])))
		if image:tex = ImageTexture.create_from_image(image)
	if tex == null:errors.append("texture failed: " + str(key))
	textures[key] = tex
	return tex

func constants() -> Dictionary:
	return data["constants"]

func placements() -> Array:
	return data["dungeon"]["placements"]

func room(map_path: String) -> Dictionary:
	return data["dungeon"]["rooms"][map_path]

func ground_to_screen(anchor: Array) -> Vector2:
	return Vector2(float(anchor[0]), float(anchor[1]) + float(constants()["screen_y_offset"]) + Frame.ART_DY - float(anchor[2]))

func is_walkable(room_data: Dictionary, x: float, y: float) -> bool:
	var k := constants()
	var col := int(floor(x / float(k["cell_width"])))
	var row := int(floor(y / float(k["cell_height"])))
	var grid: Array = room_data["walk_grid"]
	if row < 0 or row >= grid.size() or col < 0 or col >= (grid[row] as Array).size():return false
	return grid[row][col] == 0

func z_for(layer: String, ground_y: float) -> int:
	var base: int = LAYER_BASE.get(layer, 0)
	return base + int(ground_y) if layer == "normal" else base

## Returns a Node2D with metadata: room, placement, parallax layer nodes, gate parts.
func build(placement: Dictionary) -> Node2D:
	var room_data := room(String(placement["map"]))
	var root := Node2D.new()
	root.name = String(placement["id"]).replace(":", "_")
	root.set_meta("room", room_data)
	root.set_meta("placement", placement)
	var parallax: Array = []
	var k := constants()
	for bg: Dictionary in room_data["background"]:
		var layer := Node2D.new()
		layer.name = "bg_" + String(bg["layer"])
		layer.z_index = z_for(String(bg["layer"]), 0)
		var pct = room_data["scroll_percent"].get(bg["layer"])
		layer.set_meta("scroll", float(pct if pct != null else 100) / 100.0)
		var width := 640.0
		var copies := int(ceil((float(room_data["width"]) * float(layer.get_meta("scroll")) + 640.0) / width)) + 1
		for i in copies:
			var s := MapSprite.new()
			if s.setup(bg["sprite"], self):
				s.position = Vector2(i * width, Frame.ART_DY)
				layer.add_child(s)
			else:s.free()
		root.add_child(layer)
		parallax.append(layer)
	root.set_meta("parallax", parallax)
	for tile: Dictionary in room_data["tiles"]:
		if tile["image"] == null:continue
		var s := Sprite2D.new()
		s.centered = false
		s.texture = texture(tile["image"])
		s.position = Vector2(float(tile["column"]) * float(k["tile_width"]), Frame.ART_DY) + Vector2(tile["offset"][0], tile["offset"][1])
		s.z_index = z_for("bottom", 0) - 100
		root.add_child(s)
	var placed := 0
	# 只画真正的场景美术：animations / objects。
	# 地图数据里的 monsters[] 是怪物刷新锚点，不是背景装饰——以前把它也画出来，
	# 结果同一只哥布林既有"画上去的一份（打不到）"又有战斗系统生成的一份（能打），
	# 房间里就出现打不动的哥布林贴图。怪物一律由战斗系统生成。
	for item: Dictionary in room_data["animations"]:
		if item.get("sprite") == null:continue
		var layer := String(item.get("layer", "normal"))
		placed += int(_place(root, item["sprite"], item["anchor"], layer) != null)
	# objects 额外记下标：战斗侧打碎可破坏物时按 prop_node 隐藏对应节点。
	for object_index in room_data["objects"].size():
		var item: Dictionary = room_data["objects"][object_index]
		if item.get("sprite") == null:continue
		var layer := String(item.get("layer", "normal"))
		var node := _place(root, item["sprite"], item["anchor"], layer)
		if node != null:
			node.set_meta("prop_node", object_index)
			placed += 1
	var gates: Array = []
	for gate: Dictionary in placement["gates"]:
		var obj: Dictionary = data["dungeon"]["gate_objects"].get(String(gate["object"]), {})
		if obj.is_empty() or gate["anchor"] == null:
			errors.append("gate unresolved: %s %s" % [placement["id"], gate["direction"]])
			continue
		for part: Dictionary in obj["parts"]:
			var node := _place(root, part["sprite"], gate["anchor"], String(part["layer"]))
			if node == null:continue
			node.set_meta("gate_state", part["state"])
			node.set_meta("gate_role", part["role"])
			node.set_meta("gate_direction", gate["direction"])
			gates.append(node)
	root.set_meta("gate_nodes", gates)
	root.set_meta("placed_sprites", placed)
	set_gates_open(root, false)
	return root

func _place(root: Node2D, sprite: Dictionary, anchor: Array, layer: String) -> MapSprite:
	var s := MapSprite.new()
	if not s.setup(sprite, self):
		s.free()
		return null
	s.position = ground_to_screen(anchor)
	# 地图里的 normal 层道具（门、物件）与角色同用 y 排序。同 y 时因为地图节点
	# 比角色节点后挂到树上，会盖住角色（人站在门里被门框挡住）；统一减 1，
	# 让角色在相同 y 上永远压在地图物件前面。
	var z := z_for(layer, float(anchor[1]))
	if layer == "normal":z -= 1
	s.z_index = z
	s.set_meta("layer", layer)
	root.add_child(s)
	return s

func set_gates_open(root: Node2D, open: bool) -> void:
	for node: MapSprite in root.get_meta("gate_nodes", []):
		var state := String(node.get_meta("gate_state"))
		node.visible = state == "always" or (state == "closed" and not open) or (state == "open" and open)
		if open and state == "open":node.play_once()

## World is shifted by -camera_x; background layers counter-shift by their scroll factor.
func apply_camera(root: Node2D, camera_x: float) -> void:
	for layer: Node2D in root.get_meta("parallax", []):
		layer.position.x = camera_x * (1.0 - float(layer.get_meta("scroll")))
