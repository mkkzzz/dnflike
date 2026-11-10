extends Control

const ICON_RECT := Rect2(2, 2, 19, 19)
const SOURCE_SIZE := Vector2(28, 28)
const HOVER_RECT := Rect2(0, 0, 21, 21)
const TIP_ORIGIN := Vector2(0, -40)
const TIP_FONT_SIZE := 12
const TIP_NAME := "暴走"
var _frame_texture: Texture2D
var _skill_texture: Texture2D
var _shade_texture: Texture2D
var _tip_tiles: Array[Texture2D]
var _tip_font: Font
var _tip_rank := 0
var _tip_rank_text := ""
var _tip_columns := 0
var _pointer := Vector2.INF
var _alpha := 255
var _shade_height := 0

func setup(frame_texture: Texture2D, skill_texture: Texture2D, shade_texture: Texture2D,
		tip_tiles: Array[Texture2D], tip_font: Font) -> void:
	_frame_texture = frame_texture
	_skill_texture = skill_texture
	_shade_texture = shade_texture
	_tip_tiles = tip_tiles
	_tip_font = tip_font
	position = Vector2(92, 528)
	size = Vector2(23, 23)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	hide()

func _input(event: InputEvent) -> void:
	if event is InputEventMouse:
		_pointer = event.position

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_MOUSE_EXIT:
		_pointer = Vector2.INF

func present(timer: Vector2i, rank: int) -> void:
	if timer.x <= 0 or timer.y <= 0 or _frame_texture == null or _skill_texture == null or _shade_texture == null:
		_tip_rank = 0
		hide()
		return
	# 4BF500 polls the original 21×21 slot. Its 23px artwork extends past that hit area.
	var tip_rank := 0
	if _pointer.is_finite() and HOVER_RECT.has_point(make_canvas_position_local(_pointer)):
		tip_rank = rank
	if tip_rank != _tip_rank:
		_tip_rank = tip_rank
		if tip_rank > 0:
			_tip_rank_text = "技能Lv%d" % tip_rank
			var title_width := _tip_font.get_string_size(TIP_NAME, HORIZONTAL_ALIGNMENT_LEFT, -1, TIP_FONT_SIZE).x
			var rank_width := _tip_font.get_string_size(_tip_rank_text, HORIZONTAL_ALIGNMENT_LEFT, -1, TIP_FONT_SIZE).x
			_tip_columns = ceili(maxf(title_width, rank_width) / 12.0)
		queue_redraw()
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
	if _frame_texture == null or _skill_texture == null or _shade_texture == null:return
	var tint := Color(1, 1, 1, _alpha / 255.0)
	draw_texture(_frame_texture, Vector2.ZERO, tint)
	draw_texture_rect(_skill_texture, ICON_RECT, false, tint)
	if _shade_height > 0:
		var clip_height := SOURCE_SIZE.y * _shade_height / ICON_RECT.size.y
		draw_texture_rect_region(_shade_texture, Rect2(ICON_RECT.position, Vector2(ICON_RECT.size.x, _shade_height)),
			Rect2(Vector2.ZERO, Vector2(SOURCE_SIZE.x, clip_height)), Color(1, 1, 1, 128.0 / 255.0), false)
	if _tip_rank > 0:_draw_tip()

func _draw_tip() -> void:
	# EED15E uses Popup.img 134..142. The middle row repeats for each 13px line.
	if not _tip_tiles.has(null):
		var row_y := 0
		for row in [0, 1, 1, 2]:
			var frame: int = row * 3
			draw_texture(_tip_tiles[frame], TIP_ORIGIN + Vector2(0, row_y))
			for column in _tip_columns:
				draw_texture(_tip_tiles[frame + 1], TIP_ORIGIN + Vector2(6 + 12 * column, row_y))
			draw_texture(_tip_tiles[frame + 2], TIP_ORIGIN + Vector2(6 + 12 * _tip_columns, row_y))
			row_y += _tip_tiles[frame].get_height()
	var text_at := TIP_ORIGIN + Vector2(7, 7 + _tip_font.get_ascent(TIP_FONT_SIZE))
	draw_string(_tip_font, text_at, TIP_NAME, HORIZONTAL_ALIGNMENT_LEFT, -1, TIP_FONT_SIZE)
	draw_string(_tip_font, text_at + Vector2(0, 13), _tip_rank_text, HORIZONTAL_ALIGNMENT_LEFT, -1, TIP_FONT_SIZE)
