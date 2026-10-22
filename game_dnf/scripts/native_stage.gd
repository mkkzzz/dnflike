extends Node2D
var bank: Dictionary
var atlas: Texture2D
var room_index := 0
var props: Array = []
var doors: Array = []
var cleared := false
var debug_collision := false

func setup(info: Dictionary) -> void:
	bank = info
	atlas = load(String(info["texture"])) as Texture2D
	queue_redraw()

func piece(key: String, pos: Vector2, flip := false, alpha := 1.0) -> void:
	var item: Dictionary = bank["items"].get(key,{})
	if item.is_empty():return
	var r: Array = item["rect"]
	if flip:
		draw_set_transform(pos,0,Vector2(-1,1))
		draw_texture_rect_region(atlas,Rect2(0,0,float(r[2]),float(r[3])),Rect2(float(r[0]),float(r[1]),float(r[2]),float(r[3])),Color(1,1,1,alpha))
		draw_set_transform(Vector2.ZERO)
	else:
		draw_texture_rect_region(atlas,Rect2(pos,Vector2(float(r[2]),float(r[3]))),Rect2(float(r[0]),float(r[1]),float(r[2]),float(r[3])),Color(1,1,1,alpha))

func _draw() -> void:
	if atlas == null:return
	# Original floor texture tiles under the original distant/middle forest layers.
	for y in range(1,3):
		for x in range(-1,4):piece("floor2" if (room_index+x)%2 else "floor",Vector2(x*224,120+(y-1)*180))
	piece("far",Vector2(0,-70))
	piece("mid",Vector2(0,-104))
	# Props are separate native sprite nodes sorted by ground depth, not baked
	# into the background; walking behind a trunk correctly hides the actor.
	for door: Dictionary in doors:
		var point: Vector2 = door["pos"]
		var side: String = door["side"]
		# Use original gate graphics in their authored orientation; no 90-degree rotation.
		var key := ("side_open" if cleared else "side_closed") if side in ["left","right"] else ("up_open" if cleared else "up_closed")
		var r: Array = bank["items"][key]["rect"]
		# Closed original gate bars disappear after the room clears. The original
		# authored glow and forest props continue to mark the actual transition.
		if not cleared:piece(key,point-Vector2(float(r[2])/2,float(r[3])-8),side=="left")
		if cleared:
			draw_arc(point-Vector2(0,20),19,0,TAU,32,Color(0.55,0.95,0.9,0.45),1)
	if debug_collision:
		draw_rect(Rect2(26,166,588,140),Color(0.2,1,0.7,0.6),false)
		for p: Dictionary in props:
			if not p.get("broken",false):draw_rect(p["collision"],Color(1,0.3,0.3,0.7),false)
