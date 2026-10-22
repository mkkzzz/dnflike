extends RefCounted
## Native textures only. Text and layout are adapted for the standalone loop.
var art
var font: Font
var panel_texture: Texture2D

func _init(loader) -> void:
	art = loader
	font = load("res://assets_local/flow_v1/msjh.ttf")
	panel_texture = ImageTexture.create_from_image(Image.load_from_file(ProjectSettings.globalize_path("res://assets_local/flow_v1/panel.png")))

func texture(group: String, frame: int = 0) -> Texture2D:
	return art.texture(art.data["ui"][group][str(frame)])

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
	view.text = text
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
	view.text = text
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
		view.add_theme_stylebox_override(entry[0], style)
	view.focus_mode = Control.FOCUS_NONE
	view.pressed.connect(action)
	parent.add_child(view)
	return view
