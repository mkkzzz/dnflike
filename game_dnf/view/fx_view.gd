extends Node2D
## Original effect timeline: frames, delays, per-frame colour/scale/rotation/blend items.
const TextureCache = preload("res://view/texture_cache.gd")
static var _materials: Dictionary = {}
static var _mono_shader: Shader

var data: Dictionary
var atlas: Texture2D
var clock_ms := 0.0
var facing := 1
var frame: Dictionary = {}
var hitstop_sensitive := true
## Looping banks (auras, passive objects) wrap instead of freeing at the end.
var loop := false
## Native particle objects disable ANI-end deletion; motion owns their lifetime.
var hold_last_frame := false
## Whole-effect scale from ATK/CHR hit info (1.0 = native pixels).
var base_scale := 1.0
## Effects tied to a skill can be cut early (e.g. gore-cross marks end when the cross flies).
var tag := ""
var max_ms := -1.0
## Some native state entries overwrite every ANI frame delay on their attachment.
var uniform_frame_ms := -1.0
## Optional original actor-clock attachment; seek from snapshots, never wall time.
var action_clock_at := -1.0
var action_instance := -1
## Attached effects follow the casting entity every frame instead of staying where spawned.
var follow := -1
## Native attachment offset, already mirrored when the action creates it.
var follow_offset := Vector2.ZERO
var fade := 1.0
var _next_items: Dictionary = {}
var _frame_mix := 0.0
var _blend_key: Variant

func setup(info: Dictionary,direction: int) -> void:
	data = info
	facing = direction
	atlas = TextureCache.load_texture(String(info["atlas"]["texture"]))
	_blend_key = null

func advance(ms: float) -> void:
	seek(clock_ms+ms)

func seek(t: float) -> void:
	clock_ms = t
	if max_ms >= 0 and clock_ms >= max_ms:
		queue_free()
		return
	var frames: Array = data["frames"]
	var duration := uniform_frame_ms*frames.size() if uniform_frame_ms>=0.0 else float(data["duration_ms"])
	if clock_ms >= duration:
		if (not loop or duration <= 0) and not hold_last_frame:
			queue_free()
			return
	var local := fposmod(clock_ms,duration) if loop and duration > 0 else clock_ms
	var elapsed := 0.0
	_next_items = {}
	_frame_mix = 0.0
	frame = {}
	for index: int in range(frames.size()):
		var f: Dictionary = frames[index]
		var delay = f.get("delay_ms",100)
		var span := uniform_frame_ms if uniform_frame_ms>=0.0 else float(delay if delay != null else 0)
		if local < elapsed+span:
			frame = f
			if span > 0:
				var next := index+1
				if next == frames.size() and bool(data.get("loop",false)):
					next = 0
				if next < frames.size():
					_next_items = frames[next].get("items",{})
					_frame_mix = clampf((local-elapsed)/span,0.0,1.0)
			break
		elapsed += span
	if frame.is_empty() and not frames.is_empty():frame = frames[-1]
	var blend: Dictionary = frame.get("items",{}).get("11",{})
	var mode := int(blend.get("type",0))
	var key: Variant = mode
	if mode == 5:
		var rgb: Array = blend["color"]
		key = Vector3i(int(rgb[0]),int(rgb[1]),int(rgb[2]))
	if key != _blend_key:
		_blend_key = key
		if not _materials.has(key):
			if mode == 5:
				if _mono_shader == null:
					_mono_shader = Shader.new()
					_mono_shader.code = """shader_type canvas_item;
uniform vec3 mono_rgb;
varying vec3 tint_rgb;
void vertex() { tint_rgb = COLOR.rgb; }
void fragment() { COLOR.rgb = mono_rgb * tint_rgb; }
"""
				var monochrome := ShaderMaterial.new()
				monochrome.shader = _mono_shader
				monochrome.set_shader_parameter("mono_rgb",Vector3(key)/255.0)
				_materials[key] = monochrome
			else:
				var material_for_mode := CanvasItemMaterial.new()
				material_for_mode.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD if mode in [1,2] else CanvasItemMaterial.BLEND_MODE_MIX
				_materials[key] = material_for_mode
		material = _materials[key]
	queue_redraw()

func _interpolation_weight() -> float:
	return _frame_mix if int(frame.get("items",{}).get("10",0)) == 1 else 0.0

## ANI item 9 supplies RGBA endpoints; item 10 enables interpolation. Keep
## PTL fade separate so particle opacity is not applied twice. The renderer
## uses float channels; original packed-byte quantization remains unverified.
func frame_color() -> Color:
	var rgba: Array = frame.get("items",{}).get("9",[255,255,255,255])
	var color := Color(float(rgba[0])/255,float(rgba[1])/255,float(rgba[2])/255,float(rgba[3])/255)
	var weight := _interpolation_weight()
	if weight > 0.0:
		var next_rgba: Array = _next_items.get("9",[255,255,255,255])
		var target := Color(float(next_rgba[0])/255,float(next_rgba[1])/255,float(next_rgba[2])/255,float(next_rgba[3])/255)
		color = color.lerp(target,weight)
	color.a *= fade
	return color

func frame_scale() -> Vector2:
	var rate: Array = frame.get("items",{}).get("7",[1.0,1.0])
	var value := Vector2(float(rate[0]),float(rate[1]))
	var weight := _interpolation_weight()
	if weight > 0.0:
		var target: Array = _next_items.get("7",[1.0,1.0])
		value = value.lerp(Vector2(float(target[0]),float(target[1])),weight)
	return value

func _draw() -> void:
	if atlas == null or not frame.has("sprite"):return
	var item: Dictionary = data["atlas"]["items"][frame["sprite"]]
	var r: Array = item["rect"]
	var o: Array = item["offset"]
	var rate := frame_scale()*base_scale
	# [ROTATE] is in radians; [INTERPOLATION] (item 10) eases it toward the next frame.
	var rotate := float(frame.get("items",{}).get("8",0.0))
	var weight := _interpolation_weight()
	if weight > 0.0:
		rotate = lerpf(rotate,float(_next_items.get("8",0.0)),weight)
	draw_set_transform(Vector2.ZERO,rotate*facing,Vector2(facing*rate.x,rate.y))
	draw_texture_rect_region(atlas,Rect2(float(o[0]),float(o[1]),float(r[2]),float(r[3])),Rect2(float(r[0]),float(r[1]),float(r[2]),float(r[3])),frame_color())
