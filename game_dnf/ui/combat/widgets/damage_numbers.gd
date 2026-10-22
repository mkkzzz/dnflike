extends RefCounted
## Damage numbers with the original bitmap digits (sprite/common/etc/combo.img): white for
## damage dealt, red for damage taken. Rise/fade timing is still the trial curve (E-ADAPT).
const ORDER := 50

func paint(h, s: Dictionary) -> void:
	for number: Dictionary in s["numbers"]:
		var pos: Vector2 = number["pos"]
		var life := float(number["ms"])/650
		pos.y -= life*28
		h.number(String(number["style"]),int(number["value"]),pos,1-life*life)
