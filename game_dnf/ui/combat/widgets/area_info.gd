extends RefCounted
## Dungeon / room title and remaining monsters. Placeholder G13 (system font).
const ORDER := 10

func paint(h, s: Dictionary) -> void:
	h.text(Vector2(16,23),"格兰之森",16,Color(0.96,0.83,0.47))
	h.text(Vector2(16,40),String(s["room_name"]),11)
	h.text(Vector2(16,56),"通道开启" if s["room_cleared"] else "剩余怪物  "+str(s["alive"]),10,Color(0.66,0.86,0.71))
