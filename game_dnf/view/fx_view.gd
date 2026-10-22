extends Node2D
var data: Dictionary
var atlas: Texture2D
var clock_ms := 0.0
var facing := 1
var frame: Dictionary = {}
var hitstop_sensitive := true

func setup(info: Dictionary,direction: int) -> void:
	data = info
	facing = direction
	atlas = load(String(info["atlas"]["texture"])) as Texture2D

func advance(ms: float) -> void:
	clock_ms += ms
	if clock_ms >= float(data["duration_ms"]):
		queue_free()
		return
	var elapsed := 0.0
	frame = {}
	for f: Dictionary in data["frames"]:
		elapsed += float(f.get("delay_ms",100))
		if clock_ms < elapsed:
			frame = f
			break
	var blend: Dictionary = frame.get("items",{}).get("11",{})
	var mode := int(blend.get("type",0))
	var m := CanvasItemMaterial.new()
	m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD if mode in [1,2] else CanvasItemMaterial.BLEND_MODE_MIX
	material = m
	queue_redraw()

func _draw() -> void:
	if atlas == null or not frame.has("sprite"):return
	var item: Dictionary = data["atlas"]["items"][frame["sprite"]]
	var r: Array = item["rect"]
	var o: Array = item["offset"]
	var rgba: Array = frame.get("items",{}).get("9",[255,255,255,255])
	var rate: Array = frame.get("items",{}).get("7",[1.0,1.0])
	var rotate := float(frame.get("items",{}).get("8",0.0))
	draw_set_transform(Vector2.ZERO,deg_to_rad(rotate),Vector2(facing*float(rate[0]),float(rate[1])))
	draw_texture_rect_region(atlas,Rect2(float(o[0]),float(o[1]),float(r[2]),float(r[3])),Rect2(float(r[0]),float(r[1]),float(r[2]),float(r[3])),Color(float(rgba[0])/255,float(rgba[1])/255,float(rgba[2])/255,float(rgba[3])/255))
