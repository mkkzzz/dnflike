extends RefCounted
## Center notice line. Placeholder G13 (program panel, system font).
const ORDER := 70
var chrome := true

func paint(h, s: Dictionary) -> void:
	if float(s["toast_ms"])<=0:return
	var message: String = s["toast"]
	var width: float = h.font.get_string_size(message,HORIZONTAL_ALIGNMENT_LEFT,-1,13).x
	h.rect(Rect2(320-width/2-16,71,width+32,27),Color(0.03,0.07,0.06,0.7))
	h.text(Vector2(320-width/2,90),message,13,Color(1,0.87,0.52))
