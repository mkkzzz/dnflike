extends RefCounted
## Integer 2x output for the native 800x600 canvas.
const OUTPUT := Vector2i(1600, 1200)
const NATIVE := Vector2i(800, 600)
const CONTENT_SCALE := 2.0
const CONTENT_OFFSET := Vector2.ZERO
var window: Window
var window_position := Vector2i.ZERO

func setup(target: Window, testing: bool) -> void:
	window = target
	window.content_scale_size = OUTPUT
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	window.content_scale_stretch = Window.CONTENT_SCALE_STRETCH_FRACTIONAL
	# Embedded Game View owns native size/position/flags. Its startup dimensions
	# come from project.godot's window overrides, not these standalone controls.
	if Engine.is_embedded_in_editor():return
	window.unresizable = true
	window.min_size = OUTPUT
	window.max_size = OUTPUT
	window.size = OUTPUT
	var area := DisplayServer.screen_get_usable_rect(window.current_screen)
	# Capture launches deliberately live offscreen. Re-centering them steals
	# focus from the editor, which correctly pauses the managed battle.
	if not testing and OS.get_environment("MCP_BACKGROUND") != "1":window.position = area.position + Vector2i(maxi(0, (area.size.x - OUTPUT.x) / 2), maxi(0, (area.size.y - OUTPUT.y) / 2))
	window_position = window.position

func content_transform() -> Transform2D:
	return Transform2D(0.0, Vector2.ONE * CONTENT_SCALE, 0.0, CONTENT_OFFSET)

func is_fullscreen() -> bool:
	return window.mode in [Window.MODE_FULLSCREEN, Window.MODE_EXCLUSIVE_FULLSCREEN]

func toggle_fullscreen() -> void:
	if Engine.is_embedded_in_editor():return
	if is_fullscreen():
		window.mode = Window.MODE_WINDOWED
		window.size = OUTPUT
		window.position = window_position
	else:
		window_position = window.position
		window.mode = Window.MODE_FULLSCREEN

func description() -> String:
	var size := "%d×%d" % [OUTPUT.x, OUTPUT.y]
	if Engine.is_embedded_in_editor():return "固定 %s · 编辑器预览" % size
	return "固定 %s · F11 %s" % [size, "返回窗口" if is_fullscreen() else "全屏"]
