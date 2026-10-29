extends Node2D
## The simulation supplies one absolute ANI clock. Presentation never advances it.
var bank: Dictionary
var clips: Dictionary
var atlas: Texture2D
var pose_banks: Dictionary = {}
var pose_atlases: Dictionary = {}
var pose := "stay"
var clock_ms := 0.0
var facing := 1
var height := 0.0
var flash := 0.0
var tint := Color.WHITE
var shadow_width := 18.0
var _flash_material: ShaderMaterial
var equipment_layers: Array=[]

func setup(atlas_bank: Dictionary, animation_clips: Dictionary, overrides: Dictionary = {}) -> void:
	clear_equipment_layers()
	bank = atlas_bank
	clips = animation_clips
	pose_banks = overrides
	pose_atlases.clear()
	for key: String in overrides:pose_atlases[key] = load(String(overrides[key]["texture"])) as Texture2D
	atlas = load(String(bank["texture"])) as Texture2D
	var shader := Shader.new()
	shader.code = "shader_type canvas_item; uniform float hit_flash=0.0; void fragment(){ vec4 c=texture(TEXTURE,UV)*COLOR; c.rgb=mix(c.rgb,vec3(1.0),hit_flash); COLOR=c; }"
	_flash_material = ShaderMaterial.new()
	_flash_material.shader = shader
	material = _flash_material
	queue_redraw()

func clear_equipment_layers() -> void:
	for layer in equipment_layers:
		layer.hide();layer.queue_free()
	equipment_layers.clear()
	if has_meta("weapon_item"):remove_meta("weapon_item")
	if has_meta("weapon_appearance"):remove_meta("weapon_appearance")

func set_equipment_layers(layers: Array) -> void:
	clear_equipment_layers()
	for info: Dictionary in layers:
		var layer=preload("res://view/weapon_layer_view.gd").new()
		add_child(layer);layer.setup(info,_flash_material)
		equipment_layers.append(layer)
		layer.present(pose,clock_ms,facing,height,tint)

func sample() -> Dictionary:
	var ani: Dictionary = clips.get(pose, clips.get("stay", {}))
	var frames: Array = ani.get("frames", [])
	if frames.is_empty():return {}
	var duration := float(ani.get("duration_ms", 1))
	var loop: bool = pose in ["stay", "move", "dash"]
	var t := fposmod(clock_ms, maxf(1.0,duration)) if loop else minf(clock_ms,maxf(0,duration-0.001))
	var elapsed := 0.0
	for frame: Dictionary in frames:
		elapsed += float(frame.get("delay_ms", 100))
		if t < elapsed:return frame
	return frames[-1]

func present(next_pose: String, ms: float, direction: int, z: float, white: float, color := Color.WHITE) -> void:
	pose = next_pose
	clock_ms = ms
	facing = direction
	height = z
	flash = white
	tint = color
	_flash_material.set_shader_parameter("hit_flash", clampf(flash,0,1))
	for layer in equipment_layers:layer.present(next_pose,ms,direction,z,color)
	queue_redraw()

func _draw() -> void:
	if atlas == null:return
	# Shadow stays on the ground while only the sprite moves in height.
	if shadow_width > 0:
		draw_set_transform(Vector2.ZERO,0,Vector2(1,0.28))
		draw_circle(Vector2.ZERO,shadow_width,Color(0.015,0.025,0.02,0.38))
	var frame := sample()
	if frame.is_empty():return
	# ANI [ROTATE] (item 8, radians) turns the frame around the anchor; overturn.ani uses pi
	# to show the damage pose upside down. Mirroring flips the rotation direction.
	var rotate := float(frame.get("items",{}).get("8",0.0))
	draw_set_transform(Vector2(0,-roundf(height)),rotate*facing,Vector2(facing,1))
	var key := str(int(frame.get("img_frame",0)))
	var frame_bank: Dictionary = pose_banks.get(pose, bank)
	var frame_atlas: Texture2D = pose_atlases.get(pose, atlas)
	var item: Dictionary = frame_bank["items"].get(key,{})
	if item.is_empty():return
	var rect: Array = item["rect"]
	var offset: Array = item["offset"]
	var pos: Array = frame.get("pos",[0,0])
	var source := Rect2(float(rect[0]),float(rect[1]),float(rect[2]),float(rect[3]))
	var dest := Rect2(float(offset[0])+float(pos[0]),float(offset[1])+float(pos[1]),source.size.x,source.size.y)
	draw_texture_rect_region(frame_atlas,dest,source,tint)
	draw_set_transform(Vector2.ZERO)
