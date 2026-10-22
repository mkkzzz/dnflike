extends RefCounted
## Combo counter. Placeholder G02 (system font "N HIT").
const ORDER := 30

func paint(h, s: Dictionary) -> void:
	if int(s["combo"])>1:
		h.text(Vector2(20,106),str(s["combo"])+" HIT",20,Color(1,0.79,0.3))
