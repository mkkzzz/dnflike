extends RefCounted
## Combo counter: original cyan combo digits + "连击数!" label from sprite/common/etc/combo.img.
## Screen position is still the trial layout (E-ADAPT).
const ORDER := 30

func paint(h, s: Dictionary) -> void:
	if int(s["combo"])>1:
		var right := 120.0
		h.number("combo",int(s["combo"]),Vector2(right,98),1.0,1)
		h.glyph("combo_label_0",Vector2(right+4,104))
