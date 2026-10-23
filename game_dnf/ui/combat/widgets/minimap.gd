extends RefCounted
## Room route map. Placeholder G12 (program cells, rules unverified: DNF-D009).
const ORDER := 20
var chrome := true

func paint(h, s: Dictionary) -> void:
	var base := Vector2(566,42)
	for room: Dictionary in s["route"]:
		var cell: Array = room["cell"]
		var point := base+Vector2(float(cell[0])*18,float(cell[1])*14)
		var color := Color(0.20,0.26,0.25)
		if room["visited"]:color=Color(0.22,0.51,0.36)
		if room["current"]:color=Color(0.92,0.72,0.34)
		if room["boss"] and not room["current"]:color=Color(0.55,0.20,0.18)
		h.rect(Rect2(point,Vector2(13,9)),color)
		h.rect(Rect2(point,Vector2(13,9)),Color(0.75,0.68,0.46),false)
