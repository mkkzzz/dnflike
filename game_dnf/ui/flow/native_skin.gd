extends RefCounted
## Native components; native dimensions and source UI control coordinates.
const Language = preload("res://ui/flow/language_guard.gd")
const TextPatch = preload("res://ui/flow/native_text_patch.gd")
var art
var font: Font
var panel_texture: Texture2D
var tooltip_texture: Texture2D

func _init(loader) -> void:
	art = loader
	font = load("res://assets_local/flow_v1/msjh.ttf")
	# Opaque native grain and native border fragments, tiled without scaling.
	# Do not tile the complete description-board gradient: it creates stripes.
	panel_texture = ImageTexture.create_from_image(Image.load_from_file(ProjectSettings.globalize_path("res://assets_local/flow_v1/panel.png")))
	tooltip_texture = ImageTexture.create_from_image(Image.load_from_file(ProjectSettings.globalize_path("res://assets_local/flow_v1/tooltip.png")))

func texture(group: String, frame: int = 0) -> Texture2D:
	return art.texture(art.data["ui"][group][str(frame)])

func chinese(value: String) -> String:
	return Language.display(value)

func inventory(parent: Node) -> void:
	var tex := texture("inventory")
	# Remove 48px of empty body space, preserving equipment, cells and borders
	# at native 1:1. The complete bag now ends above the HUD orb silhouette.
	image_region(parent, tex, Rect2(0, 0, 313, 360), Vector2.ZERO)
	image_region(parent, tex, Rect2(0, 408, 313, 170), Vector2(0, 360))
	# This patched client bakes a close mark into the pet tab. Remove only
	# that mark with adjacent native cream grain; the active close lives below.
	TextPatch.attach(parent, tex, Rect2(201, 11, 8, 12), Rect2(253, 8, 19, 18))
	label(parent, "角色装备", Vector2(20, 34), 11, Color("c3b897"))
	# This patched client supplies Chinese title tabs in the source itself.
	image(parent, texture("inventory", 21), Vector2(19, 198))
	label(parent, "负重", Vector2(25, 357), 11)
	image(parent, texture("inventory", 2), Vector2(58, 363))
	var weight := image(parent, texture("inventory", 1), Vector2(58, 363))
	weight.name = "weight_fill"
	var weight_label := label(parent, "", Vector2(164, 357), 11)
	weight_label.name = "weight_label"
	weight_label.size.x = 109
	weight_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	for y in [382, 409]:
		image(parent, texture("inventory_bottom", 0), Vector2(25, y))
		image(parent, texture("inventory_bottom", 1), Vector2(132, y))
	image(parent, texture("inventory_bottom", 5), Vector2(28, 385))
	image_region(parent, texture("inventory", 13), Rect2(106, 0, 21, 23), Vector2(134, 382))
	image_region(parent, texture("inventory", 13), Rect2(106, 27, 21, 23), Vector2(134, 409))
	label(parent, "复活币", Vector2(50, 384), 11)
	label(parent, "决斗点", Vector2(157, 384), 11)
	label(parent, "点券", Vector2(33, 411), 11)
	label(parent, "金币", Vector2(157, 411), 11)
	for i in 5:
		var tab := button(parent, ["装备", "消耗品", "材料", "副职业", "任务"][i], Vector2(20 + i * 52, 196), func(): pass, false)
		tab.add_theme_font_size_override("font_size", 11)
		tab.size = Vector2(52 if i < 4 else 50, 22)
		tab.toggle_mode = true
		tab.name = "inventory_tab_" + str(i)

func surface(parent: Node, rect: Rect2, group: String, frame: int, margins := 5) -> NinePatchRect:
	var view := NinePatchRect.new()
	view.texture = texture(group, frame)
	view.position = rect.position
	view.size = rect.size
	view.patch_margin_left = margins
	view.patch_margin_right = margins
	view.patch_margin_top = margins
	view.patch_margin_bottom = margins
	view.axis_stretch_horizontal = NinePatchRect.AXIS_STRETCH_MODE_TILE
	view.axis_stretch_vertical = NinePatchRect.AXIS_STRETCH_MODE_TILE
	view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(view)
	return view

func item_board(parent: Node, rect: Rect2) -> NinePatchRect:
	var view := NinePatchRect.new()
	view.texture = tooltip_texture
	view.patch_margin_left = 6
	view.patch_margin_right = 6
	view.patch_margin_top = 6
	view.patch_margin_bottom = 6
	view.axis_stretch_horizontal = NinePatchRect.AXIS_STRETCH_MODE_TILE
	view.axis_stretch_vertical = NinePatchRect.AXIS_STRETCH_MODE_TILE
	view.position = rect.position
	view.size = rect.size
	view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(view)
	return view

func icon_button(parent: Node, tex: Texture2D, at: Vector2, action: Callable) -> Button:
	var hit := Button.new()
	hit.position = at
	hit.size = tex.get_size()
	hit.focus_mode = Control.FOCUS_NONE
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		hit.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	var icon := image(hit, tex, Vector2.ZERO)
	icon.name = "item_icon"
	hit.pressed.connect(action)
	parent.add_child(hit)
	return hit

func rarity_frame(parent: Node, rarity: int, color: Color) -> void:
	var frame := image(parent, texture("base", 119), Vector2.ZERO)
	frame.name = "rarity_frame"
	frame.self_modulate = color
	frame.set_meta("rarity", rarity)

func sprite_button(parent: Node, group: String, frames: Array, at: Vector2, action: Callable, hint := "") -> TextureButton:
	var view := TextureButton.new()
	view.position = at
	view.texture_normal = texture(group, frames[0])
	view.texture_hover = texture(group, frames[1])
	view.texture_pressed = texture(group, frames[2])
	view.tooltip_text = chinese(hint)
	view.focus_mode = Control.FOCUS_NONE
	view.pressed.connect(action)
	parent.add_child(view)
	return view

func close_button(parent: Node, at: Vector2, action: Callable) -> TextureButton:
	return sprite_button(parent, "close", [4, 5, 6], at, action, "关闭 Esc")

func item_grid(parent: Node, at: Vector2, columns: int, rows: int) -> Control:
	# The source grid starts at (16,174), repeats every 32px, and has a
	# final 2px border. Draw continuous row bands so shared edges occur once.
	# (18,178,30,30) cut off the top/left and included the next cell's edge.
	var grid := Control.new()
	grid.position = at
	grid.size = Vector2(columns * 32 + 2, rows * 32 + 2)
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(grid)
	var row := 0
	while row < rows:
		var count := mini(4, rows - row)
		var height := count * 32 + (2 if row + count == rows else 0)
		image_region(grid, texture("inventory_grid"), Rect2(16, 174, columns * 32 + 2, height), Vector2(0, row * 32))
		row += count
	return grid

func image(parent: Node, tex: Texture2D, at: Vector2, shrink := 1.0) -> TextureRect:
	var view := TextureRect.new()
	view.texture = tex
	view.position = at
	view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	view.stretch_mode = TextureRect.STRETCH_SCALE
	view.size = tex.get_size()
	view.scale = Vector2(shrink, shrink)
	view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(view)
	return view

func image_region(parent: Node, tex: Texture2D, region: Rect2, at: Vector2) -> TextureRect:
	var atlas := AtlasTexture.new()
	atlas.atlas = tex
	atlas.region = region
	return image(parent, atlas, at)

func panel(parent: Node, rect: Rect2) -> NinePatchRect:
	var view := NinePatchRect.new()
	view.texture = panel_texture
	view.patch_margin_left = 14
	view.patch_margin_right = 14
	view.patch_margin_top = 11
	view.patch_margin_bottom = 11
	view.axis_stretch_horizontal = NinePatchRect.AXIS_STRETCH_MODE_TILE
	view.axis_stretch_vertical = NinePatchRect.AXIS_STRETCH_MODE_TILE
	view.position = rect.position
	view.size = rect.size
	view.mouse_filter = Control.MOUSE_FILTER_STOP
	parent.add_child(view)
	return view

func label(parent: Node, text: String, at: Vector2, size := 14, color := Color("e8ddb9")) -> Label:
	var view := Label.new()
	view.text = chinese(text)
	view.position = at
	view.add_theme_font_override("font", font)
	view.add_theme_font_size_override("font_size", size)
	view.add_theme_color_override("font_color", color)
	view.add_theme_color_override("font_shadow_color", Color.BLACK)
	view.add_theme_constant_override("shadow_offset_x", 1)
	view.add_theme_constant_override("shadow_offset_y", 1)
	view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(view)
	return view

func button(parent: Node, text: String, at: Vector2, action: Callable, wide := true) -> Button:
	var view := Button.new()
	view.text = chinese(text)
	view.position = at
	view.size = Vector2(97 if wide else 56, 23)
	view.add_theme_font_override("font", font)
	view.add_theme_font_size_override("font_size", 12)
	view.add_theme_color_override("font_color", Color("33240f"))
	view.add_theme_color_override("font_hover_color", Color("241a09"))
	view.add_theme_color_override("font_pressed_color", Color("241a09"))
	for entry in [["normal", 66 if wide else 12], ["hover", 67 if wide else 13], ["pressed", 68 if wide else 14], ["disabled", 69 if wide else 15]]:
		var style := StyleBoxTexture.new()
		style.texture = texture("common", entry[1])
		style.texture_margin_left = 5
		style.texture_margin_right = 5
		style.content_margin_left = 4
		style.content_margin_right = 4
		style.content_margin_top = 2
		style.content_margin_bottom = 2
		view.add_theme_stylebox_override(entry[0], style)
	view.focus_mode = Control.FOCUS_NONE
	view.pressed.connect(action)
	parent.add_child(view)
	return view
