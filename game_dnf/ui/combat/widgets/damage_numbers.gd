extends RefCounted
## Damage numbers with the original bitmap digits (sprite/common/etc/combo.img): white for
## damage dealt, red for damage taken. Rise/fade timing is still the trial curve (E-ADAPT).
## Number positions are world coordinates; the camera offset is removed here.
const ORDER := 50

func paint(h, s: Dictionary) -> void:
	var camera: Vector2 = s.get("camera",Vector2.ZERO)
	for number: Dictionary in s["numbers"]:
		var pos: Vector2 = Vector2(number["pos"])-camera
		var life := float(number["ms"])/650
		pos.y -= life*28
		h.number(String(number["style"]),int(number["value"]),pos,1-life*life)
