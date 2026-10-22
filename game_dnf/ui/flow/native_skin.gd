extends RefCounted
## Native components; native dimensions and source UI control coordinates.
const Language = preload("res://ui/flow/language_guard.gd")
const TextPatch = preload("res://ui/flow/native_text_patch.gd")
var art
var font: Font
var panel_texture: Texture2D

func _init(loader) -> void:
	art = loader
	font = load("res://assets_local/flow_v1/msjh.ttf")
	# Opaque native grain and native border fragments, tiled without scaling.
	# Do not tile the complete description-board gradient: it creates stripes.
	panel_texture = ImageTexture.create_from_image(Image.load_from_file(ProjectSettings.globalize_path("res://assets_local/flow_v1/panel.png")))

func texture(group: String, frame: int = 0) -> Texture2D:
	return art.texture(art.data["ui"][group][str(frame)])

func chinese(value: String) -> String:
	return Language.display(value)

func inventory(parent: Node) -> void:
	var tex := texture("inventory")
	image(parent, tex, Vector2.ZERO)
	# This patched client supplies Chinese title tabs in the source itself.
	image(parent, texture("inventory", 21), Vector2(19, 198))
	image(parent, texture("inventory", 13), Vector2(19, 421))
	label(parent, "负重", Vector2(20, 400), 11)
	image(parent, texture("inventory", 2), Vector2(49, 405))
	image(parent, texture("inventory", 1), Vector2(49, 405))
	label(parent, "1.2 / 50 kg", Vector2(151, 399), 10)
	for i in 5:
		var tab := button(parent, ["装备", "消耗品", "材料", "副职业", "任务"][i], Vector2(20 + i * 48, 196), func(): pass, false)
		tab.size = Vector2(48, 20)
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

func close_button(parent: Node, at: Vector2, action: Callable) -> void:
	sprite_button(parent, "close", [4, 5, 6], at, action, "关闭 Esc")

func item_cell(parent: Node, at: Vector2) -> void:
	# An actual native bag cell, with its one-pixel grid. No generic raised button.
	var atlas := AtlasTexture.new()
	atlas.atlas = texture("inventory_grid")
	atlas.region = Rect2(18, 178, 30, 30)
	image(parent, atlas, at)

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
		view.add_theme_stylebox_override(entry[0], style)
	view.focus_mode = Control.FOCUS_NONE
	view.pressed.connect(action)
	parent.add_child(view)
	return view
