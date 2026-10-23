extends RefCounted
## Use installed Chinese UI fonts; do not redistribute proprietary system files.
static func make() -> Font:
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "Noto Sans CJK SC", "sans-serif"])
	font.font_weight = 400
	font.oversampling = 2.0
	return font
