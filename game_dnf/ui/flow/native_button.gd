extends Button
## One label follows the same press offset as the native button plate.
var caption: Label
func configure(font: Font, title: String, font_size := 12) -> void:
	text = ""
	set_meta("action_label", title)
	caption = Label.new()
	caption.text = title
	caption.add_theme_font_override("font", font)
	caption.add_theme_font_size_override("font_size", font_size)
	caption.add_theme_color_override("font_color", Color("33240f"))
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(caption)
	resized.connect(place_caption)
	button_down.connect(func(): caption.position = Vector2(1, 1))
	button_up.connect(func(): call_deferred("place_caption"))
	toggled.connect(func(_on: bool): place_caption())
	place_caption()

func place_caption() -> void:
	if not is_instance_valid(caption):return
	caption.position = Vector2(1, 1) if get_draw_mode() in [BaseButton.DRAW_PRESSED, BaseButton.DRAW_HOVER_PRESSED] else Vector2.ZERO
	caption.size = size
	caption.modulate.a = 0.55 if disabled else 1.0

func _process(_delta: float) -> void:
	place_caption()
