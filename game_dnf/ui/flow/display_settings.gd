extends RefCounted
## Outer-loop presentation only. Preserve the original 800x600 layout and
## rasterize fonts at the physical resolution; never change combat coordinates.
const NATIVE := Vector2i(800, 600)
const PRESETS := [Vector2i(800, 600), Vector2i(1200, 900), Vector2i(1600, 1200)]
var window: Window
var test_mode := false
var window_size := Vector2i(1200, 900)
var window_position := Vector2i.ZERO

func setup(target: Window, testing: bool) -> void:
	window = target
	test_mode = testing
	window.content_scale_size = NATIVE
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	# Project-wide integer scaling would round the comfortable 1.5x back to 1x.
	window.content_scale_stretch = Window.CONTENT_SCALE_STRETCH_FRACTIONAL
	window.min_size = Vector2i(640, 480)
	if test_mode:
		# Keep established physical-pixel captures deterministic on any monitor.
		window.size = PRESETS[2]
	else:
		set_window_size(PRESETS[1])

func usable_rect() -> Rect2i:
	return DisplayServer.screen_get_usable_rect(window.current_screen)

func fitted_size(requested: Vector2i, usable: Vector2i) -> Vector2i:
	# Reserve titlebar/taskbar space, preserving the native 4:3 ratio exactly.
	var available := usable - Vector2i(32, 64)
	var units := mini(requested.x / 4, requested.y / 3)
	units = mini(units, mini(available.x / 4, available.y / 3))
	units = maxi(1, units)
	return Vector2i(units * 4, units * 3)

func is_fullscreen() -> bool:
	return window.mode in [Window.MODE_FULLSCREEN, Window.MODE_EXCLUSIVE_FULLSCREEN]

func set_window_size(requested: Vector2i) -> void:
	window.mode = Window.MODE_WINDOWED
	var area := usable_rect()
	window.size = fitted_size(requested, area.size)
	window.position = area.position + (area.size - window.size) / 2
	window_size = window.size
	window_position = window.position

func toggle_fullscreen() -> void:
	if is_fullscreen():
		window.mode = Window.MODE_WINDOWED
		var area := usable_rect()
		window.size = fitted_size(window_size, area.size)
		window.position = window_position.clamp(area.position, area.end - window.size)
	else:
		window_size = window.size
		window_position = window.position
		window.mode = Window.MODE_FULLSCREEN

func cycle_window_size() -> void:
	var available := usable_rect().size
	var choices: Array[Vector2i] = []
	for size: Vector2i in PRESETS:
		var fitted := fitted_size(size, available)
		if not choices.has(fitted):choices.append(fitted)
	var current: Vector2i = window_size if is_fullscreen() else window.size
	var next := 0
	for i in choices.size():
		if choices[i].x > current.x + 4:
			next = i
			break
	set_window_size(choices[next])

func description() -> String:
	if is_fullscreen():return "全屏 · F11 返回窗口"
	return "%d×%d · F3 切换 · F11 全屏" % [window.size.x, window.size.y]
