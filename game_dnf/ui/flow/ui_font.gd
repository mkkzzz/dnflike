extends RefCounted
## The original client's UI font is part of the locally distributed asset pack.
const SOURCE_FONT := "res://assets_local/flow_v1/msjh.ttf"

static func make() -> Font:
	if ResourceLoader.exists(SOURCE_FONT):
		var source_font := load(SOURCE_FONT) as Font
		if source_font != null:return source_font
	# Keep the editor usable when the optional flow asset pack is absent.
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "Noto Sans CJK SC", "sans-serif"])
	font.font_weight = 400
	font.oversampling = 2.0
	return font
