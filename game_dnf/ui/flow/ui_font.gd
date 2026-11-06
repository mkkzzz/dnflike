extends RefCounted
## Shared Chinese font for the native 800x600 UI drawn at 2x display density.
## Font oversampling must follow the canvas transform, not the unscaled viewport.
const SOURCE_FONT := "res://assets_local/flow_v1/msjh.ttf"

const DISPLAY_DENSITY := preload("res://ui/flow/display_settings.gd").CONTENT_SCALE
static var _font: Font

static func make() -> Font:
	if _font != null:return _font
	if ResourceLoader.exists(SOURCE_FONT):
		var source_font := load(SOURCE_FONT) as FontFile
		if source_font != null:
			var display_font := source_font.duplicate() as FontFile
			display_font.oversampling = DISPLAY_DENSITY
			_font = display_font
			return _font
	# Keep the editor usable when the optional flow asset pack is absent.
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "Noto Sans CJK SC", "sans-serif"])
	font.font_weight = 400
	font.oversampling = DISPLAY_DENSITY
	_font = font
	return _font
