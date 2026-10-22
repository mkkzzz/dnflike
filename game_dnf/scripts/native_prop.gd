extends Node2D
var bank: Dictionary
var atlas: Texture2D
var data: Dictionary

func setup(info: Dictionary,prop: Dictionary) -> void:
	bank = info
	data = prop
	atlas = load(String(info["texture"])) as Texture2D
	position = Vector2(data["pos"]).round()
	z_index = int(position.y)

func refresh() -> void:
	visible = not bool(data.get("broken",false)) or (data["sprite"]=="grass" and float(data.get("broken_ms",0))<420)
	queue_redraw()

func _draw() -> void:
	if atlas == null:return
	var key: String = data["sprite"]
	var base: Dictionary = bank["items"][key]
	var r0: Array = base["rect"]
	if data.get("broken",false) and key=="grass":key="grass_"+str(mini(7,1+int(float(data.get("broken_ms",0))/60)))
	var item: Dictionary = bank["items"][key]
	var r: Array = item["rect"]
	var o: Array = item["offset"]
	var b: Array = base["offset"]
	var shift := Vector2(float(o[0])-float(b[0]),float(o[1])-float(b[1]))
	draw_texture_rect_region(atlas,Rect2(Vector2(-float(r0[2])/2,-float(r0[3]))+shift,Vector2(float(r[2]),float(r[3]))),Rect2(float(r[0]),float(r[1]),float(r[2]),float(r[3])))
