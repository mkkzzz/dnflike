extends RefCounted
## Damage numbers. Placeholder G01 (system font, linear 650 ms rise).
const ORDER := 50

func paint(h, s: Dictionary) -> void:
	for number: Dictionary in s["numbers"]:
		var pos: Vector2 = number["pos"]
		var life := float(number["ms"])/650
		pos.y -= life*28
		h.text(pos,String(number["text"]),20 if number["heavy"] else 15,Color(1,0.79 if number["heavy"] else 0.95,0.32 if number["heavy"] else 0.75,1-life))
