extends SceneTree
## Export controls headlessly, or capture pixels on an isolated Windows desktop.
const Loop = preload("res://flow/loop_root.gd")
const NativeSkin = preload("res://ui/flow/native_skin.gd")
const Town = preload("res://town/native_town.gd")
const Windows = preload("res://ui/flow/number_windows.gd")
const NativeWindows = preload("res://ui/flow/native_windows.gd")
const Skills = preload("res://combat/api/skill_catalog.gd")
const Slots = preload("res://stats/api/skill_slots.gd")
var output := ""
var commands: Array = []
var textures: Dictionary = {}
var game

func _initialize() -> void:
	call_deferred("export_panel")

func export_panel() -> void:
	var args := OS.get_cmdline_user_args()
	var capture := "--capture" in args
	if capture:args.remove_at(args.find("--capture"))
	var valid_mode := OS.get_environment("DNF_PRIVATE_DESKTOP") == "1" and DisplayServer.get_name() != "headless" if capture else DisplayServer.get_name() == "headless"
	if args.size() < 2 or not valid_mode:
		push_error("Use --headless --script res://debug/export_skill_panel.gd -- OUTPUT JOB [SCROLL] [SKILL]")
		quit(1)
		return
	output = args[0]
	DirAccess.make_dir_recursive_absolute(output)
	game = Loop.new()
	game.town = Town.new()
	game.town.loader.load_export("res://assets_local/flow_v1/manifest.json")
	game.skin = NativeSkin.new(game.town.loader)
	game.windows = NativeWindows.new(game)
	game.number_windows = Windows.new(game)
	game.skill_catalog = Skills.new()
	game.session.profile["growtype"] = args[1]
	game.session.profile["level"] = 40
	game.session.profile["sp_bonus"] = 600
	game.session.profile["skills"]["upper"] = 5
	var panel = game.number_windows.skill_panel
	panel.tree_scroll = float(args[2]) if args.size() > 2 else 0.0
	panel.selected = args[3] if args.size() > 3 else "upperslash"
	var canvas := Control.new()
	if capture:
		root.size = Vector2i(1600, 1200)
		root.content_scale_size = Vector2i(1600, 1200)
		canvas.scale = Vector2.ONE * 2
	canvas.size = Vector2(800, 600)
	canvas.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	root.add_child(canvas)
	game.ui=canvas
	game.hud=canvas
	game.skin.image(canvas, game.skin.texture("hud"), Vector2(0,508))
	game.build_hotbars()
	for index in Slots.COUNT:
		var label:Label=game.skin.label(canvas,Slots.LABELS[index],Slots.position(index)+Vector2(2,16),9)
		label.z_index=2
	panel.show_window(canvas)
	for index in 5:
		await process_frame
	if capture:
		await RenderingServer.frame_post_draw
		var error := root.get_texture().get_image().save_png(output.path_join("actual.png"))
		if error != OK:
			push_error("Skill capture failed: " + error_string(error))
			quit(1)
			return
		print("[SKILL_CAPTURE] actual framebuffer, isolated desktop: " + output)
	else:
		walk(canvas, Rect2(0, 0, 800, 600))
		var file := FileAccess.open(output.path_join("layout.json"), FileAccess.WRITE)
		file.store_string(JSON.stringify({"size": [800, 600], "commands": commands}, " "))
		print("[SKILL_PREVIEW] commands=%d textures=%d headless=true" % [commands.size(), textures.size()])
	canvas.free()
	game.town.free()
	game.free()
	quit()

func values(vector: Vector2) -> Array:
	return [vector.x, vector.y]

func rectangle(rect: Rect2) -> Array:
	return [rect.position.x, rect.position.y, rect.size.x, rect.size.y]

func rgba(color: Color) -> Array:
	return [color.r, color.g, color.b, color.a]

func texture_file(texture: Texture2D) -> String:
	var id := texture.get_instance_id()
	if not textures.has(id):
		var path := "texture_%03d.png" % textures.size()
		texture.get_image().save_png(output.path_join(path))
		textures[id] = path
	return textures[id]

func style_command(style: StyleBox, rect: Rect2, clip: Rect2, color := Color.WHITE) -> void:
	if style is StyleBoxTexture and style.texture != null:
		commands.append({"kind": "patch", "texture": texture_file(style.texture), "rect": rectangle(rect),
			"clip": rectangle(clip), "color": rgba(color),
			"margins": [style.texture_margin_left, style.texture_margin_top, style.texture_margin_right, style.texture_margin_bottom]})

func walk(node: Node, clip: Rect2, color := Color.WHITE) -> void:
	if node is CanvasItem:
		if not node.visible:
			return
		color *= node.modulate
	var rect := Rect2()
	if node is Control:
		rect = node.get_global_rect()
		if node.clip_contents:
			clip = clip.intersection(rect)
	if node is TextureRect and node.texture != null:
		commands.append({"kind": "image", "texture": texture_file(node.texture), "rect": rectangle(rect),
			"clip": rectangle(clip), "color": rgba(color * node.self_modulate)})
	elif node is TextureButton and node.texture_normal != null:
		commands.append({"kind":"image","texture":texture_file(node.texture_normal),"rect":rectangle(rect),
			"clip":rectangle(clip),"color":rgba(color)})
	elif node is NinePatchRect and node.texture != null:
		commands.append({"kind": "patch", "texture": texture_file(node.texture), "rect": rectangle(rect),
			"clip": rectangle(clip), "color": rgba(color),
			"margins": [node.patch_margin_left, node.patch_margin_top, node.patch_margin_right, node.patch_margin_bottom]})
	elif node is VScrollBar:
		style_command(node.get_theme_stylebox("scroll"), rect, clip)
		var up: Texture2D = node.get_theme_icon("decrement")
		var down: Texture2D = node.get_theme_icon("increment")
		var arrow_height := float(up.get_height())
		for entry in [[up, rect.position], [down, rect.end - Vector2(rect.size.x, down.get_height())]]:
			commands.append({"kind": "image", "texture": texture_file(entry[0]),
				"rect": rectangle(Rect2(entry[1], Vector2(rect.size.x, entry[0].get_height()))), "clip": rectangle(clip), "color": rgba(color)})
		var span := rect.size.y - arrow_height - down.get_height()
		var height := maxf(12, span * node.page / maxf(1, node.max_value - node.min_value))
		var offset: float = (span - height) * node.value / maxf(1, node.max_value - node.page)
		style_command(node.get_theme_stylebox("grabber"), Rect2(rect.position + Vector2(0, arrow_height + offset), Vector2(rect.size.x, height)), clip)
	elif node is Button:
		style_command(node.get_theme_stylebox("disabled" if node.disabled else "normal"), rect, clip)
	elif node is Label or node is RichTextLabel:
		commands.append({"kind": "text", "text": node.text, "rect": rectangle(rect), "clip": rectangle(clip.intersection(rect)),
			"font_size": node.get_theme_font_size("normal_font_size" if node is RichTextLabel else "font_size"),
			"color": rgba(node.get_theme_color("default_color" if node is RichTextLabel else "font_color") * color),
			"align": node.horizontal_alignment if node is Label else 0,
			"vertical": node.vertical_alignment if node is Label else 0,
			"wrap": node is RichTextLabel or node.autowrap_mode != TextServer.AUTOWRAP_OFF,
			"line_height": 14 if node is RichTextLabel else 0})
		if node is RichTextLabel and node.get_v_scroll_bar().visible:
			walk(node.get_v_scroll_bar(), clip.intersection(rect), color)
	elif node is Line2D:
		var points: Array = []
		for point in node.points:
			points.append(values(node.global_transform * point))
		commands.append({"kind": "line", "points": points, "width": node.width, "color": rgba(node.default_color * color), "clip": rectangle(clip)})
	for child in node.get_children():
		walk(child, clip, color)
