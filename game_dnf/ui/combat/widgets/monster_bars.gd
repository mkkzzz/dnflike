extends RefCounted
## Monster head bars and boss bar. Placeholders G03/G04 (program rectangles).
const ORDER := 40

func paint(h, s: Dictionary) -> void:
	for enemy: Dictionary in s["enemies"]:
		if not enemy["alive"]:continue
		var ep: Vector2 = Vector2(enemy["pos"])-Vector2(20,70+float(enemy["z"]))
		var hp := float(enemy["hp_ratio"])
		h.rect(Rect2(ep,Vector2(40,3)),Color(0.06,0.03,0.02,0.8))
		h.rect(Rect2(ep,Vector2(40*hp,3)),Color(0.85,0.24,0.15))
		if enemy["chief"]:
			h.text(Vector2(206,26),"密林领主",12,Color(1,0.68,0.30))
			h.rect(Rect2(204,31,230,5),Color(0.12,0.05,0.03))
			h.rect(Rect2(204,31,230*hp,5),Color(0.68,0.16,0.10))
