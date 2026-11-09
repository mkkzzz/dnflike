extends RefCounted
## Damage numbers with the original bitmap digits (sprite/common/etc/combo.img): white for
## damage dealt, red for damage taken. Rise/fade timing is still the trial curve (E-ADAPT).
## Number positions are world coordinates; the camera offset is removed here.
const ORDER := 50

func paint(h, s: Dictionary) -> void:
	var camera: Vector2 = s.get("camera",Vector2.ZERO)
	for number: Dictionary in s["numbers"]:
		var pos: Vector2 = Vector2(number["pos"])-camera
		if number["style"] == "thirst_damage":
			# 7EF1E4..7EF4A1 holds for 600 ms and interpolates the final two spans.
			var age := float(number["ms"])
			var rise := lerpf(0.0,39.0,clampf((age-600.0)/200.0,0.0,1.0))
			rise += lerpf(0.0,30.0,clampf((age-800.0)/200.0,0.0,1.0))
			var alpha := lerpf(255.0,128.0,clampf((age-600.0)/200.0,0.0,1.0))
			alpha -= lerpf(0.0,128.0,clampf((age-800.0)/200.0,0.0,1.0))
			h.thirst_damage_number(int(number["value"]),pos-Vector2(0,rise),alpha/255.0)
			continue
		var life := float(number["ms"])/650
		pos.y -= life*28
		h.number(String(number["style"]),int(number["value"]),pos,1-life*life)
