extends Control

const ICON_RECT := Rect2(2, 2, 19, 19)
const SOURCE_SIZE := Vector2(28, 28)
var _frame_texture: Texture2D
var _skill_texture: Texture2D
var _shade_texture: Texture2D
var _alpha := 255
var _shade_height := 0

func setup(frame_texture: Texture2D, skill_texture: Texture2D, shade_texture: Texture2D) -> void:
	_frame_texture = frame_texture
	_skill_texture = skill_texture
	_shade_texture = shade_texture
	position = Vector2(92, 528)
	size = Vector2(23, 23)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	hide()

func present(timer: Vector2i) -> void:
	if timer.x <= 0 or timer.y <= 0 or _frame_texture == null or _skill_texture == null or _shade_texture == null:
		hide()
		return
	var alpha := warning_alpha(timer.x)
	# 4C8D61 truncates the remaining fraction before subtracting it from 19.
	var shade_height := 19 - clampi(int(19.0 * timer.x / timer.y), 0, 19)
	if not visible or _alpha != alpha or _shade_height != shade_height:
		_alpha = alpha
		_shade_height = shade_height
		show()
		queue_redraw()

static func warning_alpha(remaining_ms: int) -> int:
	# 4C8C92..4C8D13 blinks in the last 10 s and fades in the last second.
	if remaining_ms <= 1000:
		return int(255.0 * remaining_ms / 1000.0)
	@warning_ignore("integer_division")
	var phase := remaining_ms / (200 if remaining_ms <= 5000 else 500)
	return 128 if remaining_ms < 10000 and phase % 2 == 1 else 255

func _draw() -> void:
	var tint := Color(1, 1, 1, _alpha / 255.0)
	draw_texture(_frame_texture, Vector2.ZERO, tint)
	draw_texture_rect(_skill_texture, ICON_RECT, false, tint)
	if _shade_height > 0:
		var clip_height := SOURCE_SIZE.y * _shade_height / ICON_RECT.size.y
		draw_texture_rect_region(_shade_texture, Rect2(ICON_RECT.position, Vector2(ICON_RECT.size.x, _shade_height)),
			Rect2(Vector2.ZERO, Vector2(SOURCE_SIZE.x, clip_height)), Color(1, 1, 1, 128.0 / 255.0), false)
