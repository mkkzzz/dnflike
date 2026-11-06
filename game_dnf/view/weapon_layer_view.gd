extends Node2D
## Native weapon ANI, sampled from the parent's absolute action clock only.
const TextureCache = preload("res://view/texture_cache.gd")
var bank: Dictionary={}
var clips: Dictionary={}
var atlas: Texture2D
var frame: Dictionary={}
var facing:=1
var height:=0.0
var tint:=Color.WHITE
var parent_flash: ShaderMaterial
var own_material: ShaderMaterial

func setup(info: Dictionary, flash_material: ShaderMaterial) -> void:
	bank=info["bank"];clips=info["clips"]
	atlas=TextureCache.load_texture(String(bank["texture"]))
	show_behind_parent=int(info["order"])==650
	parent_flash=flash_material
	own_material=flash_material.duplicate()
	material=own_material

func present(pose: String, clock_ms: float, direction: int, z: float, color: Color, body_frame := -1) -> void:
	facing=direction;height=z;tint=color
	var ani: Dictionary=clips.get(pose,clips.get("stay",{}))
	var frames: Array=ani.get("frames",[])
	frame={}
	if frames.is_empty():queue_redraw();return
	var duration:=maxf(1,float(ani.get("duration_ms",1)))
	var local:=fposmod(clock_ms,duration) if pose in ["stay","move","dash"] else minf(clock_ms,maxf(0,duration-0.001))
	var end:=0.0
	for entry: Dictionary in frames:
		end+=float(entry.get("delay_ms",100))
		if local<end:frame=entry;break
	if frame.is_empty():frame=frames[-1]
	# Native equipment wave has a 50ms first frame; the body's 10000ms hold
	# is state-controlled. Bind equipment to body frame, never clamp at 10s.
	if ani.get("sync_body_frame",false) and body_frame>=0 and body_frame<frames.size():frame=frames[body_frame]
	var blend: Dictionary=frame.get("items",{}).get("11",{})
	own_material.set_shader_parameter("source_monochrome",int(blend.get("type",0))==5)
	var rgb: Array=blend.get("color",[255,255,255])
	own_material.set_shader_parameter("mono_rgb",Vector3(float(rgb[0]),float(rgb[1]),float(rgb[2]))/255.0)
	own_material.set_shader_parameter("hit_flash",parent_flash.get_shader_parameter("hit_flash"))
	queue_redraw()

func _draw() -> void:
	if atlas==null or frame.is_empty() or frame.get("img")==null:return
	var item: Dictionary=bank.get("items",{}).get(str(int(frame.get("img_frame",0))),{})
	if item.is_empty():return
	var rotate:=float(frame.get("items",{}).get("8",0))
	draw_set_transform(Vector2(0,-roundf(height)),rotate*facing,Vector2(facing,1))
	var r: Array=item["rect"];var o: Array=item["offset"];var p: Array=frame.get("pos",[0,0])
	draw_texture_rect_region(atlas,Rect2(float(o[0])+float(p[0]),float(o[1])+float(p[1]),float(r[2]),float(r[3])),Rect2(r[0],r[1],r[2],r[3]),tint)
	draw_set_transform(Vector2.ZERO)
