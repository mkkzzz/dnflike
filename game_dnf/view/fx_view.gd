extends Node2D
## Original effect timeline: frames, delays, per-frame colour/scale/rotation/blend items.
var data: Dictionary
var atlas: Texture2D
var clock_ms := 0.0
var facing := 1
var frame: Dictionary = {}
var hitstop_sensitive := true
## Looping banks (auras, passive objects) wrap instead of freeing at the end.
var loop := false
## Whole-effect scale from ATK/CHR hit info (1.0 = native pixels).
var base_scale := 1.0
## Effects tied to a skill can be cut early (e.g. gore-cross marks end when the cross flies).
var tag := ""
var max_ms := -1.0
## Attached effects follow the casting entity every frame instead of staying where spawned.
var follow := -1
var fade := 1.0
var _frame_local := 0.0

func setup(info: Dictionary,direction: int) -> void:
	data = info
	facing = direction
	atlas = load(String(info["atlas"]["texture"])) as Texture2D

func advance(ms: float) -> void:
	seek(clock_ms+ms)

func seek(t: float) -> void:
	clock_ms = t
	if max_ms >= 0 and clock_ms >= max_ms:
		queue_free()
		return
	var duration := float(data["duration_ms"])
	if clock_ms >= duration:
		if not loop or duration <= 0:
			queue_free()
			return
	var local := fposmod(clock_ms,duration) if loop and duration > 0 else clock_ms
	var elapsed := 0.0
	frame = {}
	for f: Dictionary in data["frames"]:
		var delay = f.get("delay_ms",100)
		var span := float(delay if delay != null else 0)
		if local < elapsed+span:
			frame = f
			_frame_local = local-elapsed
			break
		elapsed += span
	if frame.is_empty() and not data["frames"].is_empty():frame = data["frames"][-1]
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
	# [ROTATE] is in radians; [INTERPOLATION] (item 10) eases it toward the next frame.
	var rotate := float(frame.get("items",{}).get("8",0.0))
	if int(frame.get("items",{}).get("10",0)) == 1:
		var i: int = data["frames"].find(frame)
		if i >= 0 and i+1 < data["frames"].size():
			var span := float(frame.get("delay_ms",0) if frame.get("delay_ms") != null else 0)
			var next_rot := float(data["frames"][i+1].get("items",{}).get("8",0.0))
			if span > 0:rotate = lerpf(rotate,next_rot,clampf(_frame_local/span,0,1))
	draw_set_transform(Vector2.ZERO,rotate*facing,Vector2(facing*float(rate[0])*base_scale,float(rate[1])*base_scale))
	var alpha := float(rgba[3])/255*fade
	draw_texture_rect_region(atlas,Rect2(float(o[0]),float(o[1]),float(r[2]),float(r[3])),Rect2(float(r[0]),float(r[1]),float(r[2]),float(r[3])),Color(float(rgba[0])/255,float(rgba[1])/255,float(rgba[2])/255,alpha))
