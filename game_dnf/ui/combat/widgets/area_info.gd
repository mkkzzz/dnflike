extends RefCounted
## Dungeon / room title and remaining monsters, under the top monster HP bar.
## Placeholder G13 (system font).
const ORDER := 10
var chrome := true

func paint(h, s: Dictionary) -> void:
	h.text(Vector2(8,58),"洛兰",14,Color(0.96,0.83,0.47))
	h.text(Vector2(8,73),"通道开启" if s["room_cleared"] else "剩余怪物  "+str(s["alive"]),10,Color(0.66,0.86,0.71))
