extends RefCounted
## Integer 2x output for the native 800x600 canvas.
const OUTPUT := Vector2i(1600, 1200)
const NATIVE := Vector2i(800, 600)
const CONTENT_SCALE := 2.0
const CONTENT_OFFSET := Vector2.ZERO
var window: Window
var window_position := Vector2i.ZERO
var windowed_size := OUTPUT
var last_restore_recentered := false
var fullscreen := false

func setup(target: Window, testing: bool, screen_override := Rect2i()) -> void:
	window = target
	fullscreen = window.mode in [Window.MODE_FULLSCREEN, Window.MODE_EXCLUSIVE_FULLSCREEN]
	window.content_scale_size = OUTPUT
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	window.content_scale_stretch = Window.CONTENT_SCALE_STRETCH_FRACTIONAL
	# Embedded Game View owns native size/position/flags. Its startup dimensions
	# come from project.godot's window overrides, not these standalone controls.
	if not owns_window(Engine.is_embedded_in_editor()):return
	window.unresizable = true
	var area := usable_area(screen_override)
	_apply_windowed_size(area)
	# Capture launches deliberately live offscreen. Re-centering them steals
	# focus from the editor, which correctly pauses the managed battle.
	if not testing and OS.get_environment("MCP_BACKGROUND") != "1":
		window.position = centered_position(area,windowed_size)
	window_position = window.position

func content_transform() -> Transform2D:
	return Transform2D(0.0, Vector2.ONE * CONTENT_SCALE, 0.0, CONTENT_OFFSET)

func is_fullscreen() -> bool:
	return fullscreen or window.mode in [Window.MODE_FULLSCREEN, Window.MODE_EXCLUSIVE_FULLSCREEN]

func toggle_fullscreen(screen_override := Rect2i()) -> void:
	if not owns_window(Engine.is_embedded_in_editor()):return
	if is_fullscreen():
		window.mode = Window.MODE_WINDOWED
		fullscreen = false
		var area := usable_area(screen_override)
		_apply_windowed_size(area)
		var restored := restored_position(window_position,area,windowed_size)
		last_restore_recentered = restored != window_position
		window.position = restored
		window_position = restored
	else:
		window_position = window.position
		last_restore_recentered = false
		window.mode = Window.MODE_FULLSCREEN
		fullscreen = true

func description() -> String:
	var size := "%d×%d" % [OUTPUT.x, OUTPUT.y]
	if not owns_window(Engine.is_embedded_in_editor()):return "固定 %s · 编辑器预览" % size
	return "固定 %s · F11 %s" % [size, "返回窗口" if is_fullscreen() else "全屏"]

static func owns_window(embedded: bool) -> bool:
	return not embedded

func usable_area(screen_override := Rect2i()) -> Rect2i:
	if screen_override.size.x > 0 and screen_override.size.y > 0:
		return screen_override
	var fallback := Rect2i(Vector2i.ZERO,OUTPUT)
	if DisplayServer.get_name() == "headless":
		return fallback
	var screen := window.current_screen if window != null else 0
	if screen < 0 or screen >= DisplayServer.get_screen_count():
		screen = DisplayServer.get_primary_screen()
	var area := DisplayServer.screen_get_usable_rect(screen)
	if area.size.x <= 0 or area.size.y <= 0:
		return fallback
	return area

func _apply_windowed_size(area: Rect2i) -> void:
	windowed_size = fit_window_size(area.size,OUTPUT)
	window.min_size = windowed_size
	window.max_size = windowed_size
	window.size = windowed_size

static func fit_window_size(area_size: Vector2i, output := OUTPUT) -> Vector2i:
	if area_size.x >= output.x and area_size.y >= output.y:
		return output
	if area_size.x <= 0 or area_size.y <= 0:
		return output
	var scale := minf(float(area_size.x) / float(output.x),float(area_size.y) / float(output.y))
	return Vector2i(maxi(1,floori(output.x * scale)),maxi(1,floori(output.y * scale)))

static func centered_position(area: Rect2i, size: Vector2i) -> Vector2i:
	return area.position + Vector2i(floori((area.size.x - size.x) / 2.0),floori((area.size.y - size.y) / 2.0))

static func restored_position(saved: Vector2i, area: Rect2i, size: Vector2i) -> Vector2i:
	var candidate := Rect2i(saved,size)
	if area.encloses(candidate):
		return saved
	var intersection := candidate.intersection(area)
	if intersection.size.x >= 64 and intersection.size.y >= 64:
		return Vector2i(
			clampi(saved.x,area.position.x,area.end.x - size.x),
			clampi(saved.y,area.position.y,area.end.y - size.y))
	return centered_position(area,size)

static func letterbox_rect(frame_size: Vector2i, output := OUTPUT) -> Rect2i:
	if frame_size.x <= 0 or frame_size.y <= 0:
		return Rect2i()
	var scale := minf(float(frame_size.x) / float(output.x),float(frame_size.y) / float(output.y))
	var size := Vector2i(maxi(1,floori(output.x * scale)),maxi(1,floori(output.y * scale)))
	return Rect2i(Vector2i((frame_size.x - size.x) / 2,(frame_size.y - size.y) / 2),size)

static func window_to_native(point: Vector2i, frame_size: Vector2i) -> Vector2i:
	var content := letterbox_rect(frame_size)
	if not content.has_point(point):
		return Vector2i(-1,-1)
	return Vector2i(
		floori(float(point.x - content.position.x) * NATIVE.x / content.size.x),
		floori(float(point.y - content.position.y) * NATIVE.y / content.size.y))

static func native_to_window(point: Vector2, frame_size: Vector2i) -> Vector2i:
	var content := letterbox_rect(frame_size)
	return Vector2i(
		content.position.x + floori(point.x * content.size.x / NATIVE.x),
		content.position.y + floori(point.y * content.size.y / NATIVE.y))
