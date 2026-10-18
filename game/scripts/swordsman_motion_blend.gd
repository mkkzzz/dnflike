extends RefCounted
## Source rasters are warped to the same anatomical surface before blending.
## All clocks advance once per physics tick, including on-demand hit-line reads.
const Library := preload("res://scripts/swordsman_v7_lib.gd")
const MAX_SOURCES := 8
var body: MeshInstance2D
var fingers: MeshInstance2D
var back_weapon: Sprite2D
var front_weapon: Sprite2D
var _transparent: ImageTexture
var _key := ""
var _last_clock := 0.0
var _last_physics := -1
var _elapsed := 99.0
var _duration := 8.0
var _outgoing: Array = []
var _last_sources: Array = []
var _last_signature := ""
var geometry: Dictionary = {}
var blades: Dictionary = {}
var _angle_origins: Dictionary = {}

func setup(parent: Node2D) -> void:
	var image := Image.create(1,1,false,Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	_transparent = ImageTexture.create_from_image(image)
	back_weapon = Sprite2D.new()
	back_weapon.centered = false
	back_weapon.z_index = 0
	parent.add_child(back_weapon)
	body = MeshInstance2D.new()
	body.z_index = 1
	parent.add_child(body)
	front_weapon = Sprite2D.new()
	front_weapon.centered = false
	front_weapon.z_index = 2
	parent.add_child(front_weapon)
	fingers = MeshInstance2D.new()
	fingers.z_index = 3
	parent.add_child(fingers)
	for node in [body,fingers]:
		var material := ShaderMaterial.new()
		material.shader = preload("res://shaders/swordsman_motion.gdshader")
		node.material = material
	hide_all()

func hide_all() -> void:
	for node in [body,fingers,back_weapon,front_weapon]:
		if is_instance_valid(node): node.visible = false

func reset() -> void:
	_key = ""
	_last_physics = -1
	_elapsed = 99.0
	_outgoing.clear()
	_last_sources.clear()
	_last_signature = ""
	_angle_origins.clear()
	hide_all()

func sync_context(key: String, clock: float, loop: bool, frozen: bool) -> void:
	var changed := key != _key or (not loop and clock < _last_clock - 0.1)
	var physics_tick := int(Engine.get_physics_frames())
	if changed:
		_outgoing = _last_sources.duplicate()
		_angle_origins.clear()
		for profile in blades:
			var axis: Vector2 = blades[profile]["basis_u"]
			_angle_origins[profile] = axis.angle()
		_elapsed = 0.0 if not _outgoing.is_empty() else 99.0
		# A chained cut already begins in the preceding contact/follow-through
		# family. Keep that short handover inside windup, rather than mixing an
		# old recovery pose across the next cut's entire low preparation.
		_duration = 3.0 if key in ["attack1","attack2","attack3","hit_light","hit_heavy","air_hit","jump_land"] else 8.0
		if key in ["hit_light","hit_heavy"]:
			_duration = 1.0
		_key = key
	elif physics_tick != _last_physics and not frozen:
		_elapsed += 1.0
	_last_physics = physics_tick
	_last_clock = clock

func _sources(targets: Array) -> Array:
	var t := smoothstep(0.0,1.0,clampf(_elapsed / _duration,0.0,1.0))
	var sources: Array = []
	if t < 1.0:
		for source in _outgoing:
			var weight := float(source["weight"]) * (1.0-t)
			if weight > 0.00001: sources.append({"frame":source["frame"],"weight":weight})
	for source in targets:
		var weight := float(source["weight"]) * t
		if weight > 0.00001: sources.append({"frame":source["frame"],"weight":weight})
	if sources.is_empty(): sources = targets.duplicate()
	sources.sort_custom(func(a,b): return a["weight"] > b["weight"])
	if sources.size() > MAX_SOURCES: sources.resize(MAX_SOURCES)
	var total := 0.0
	for source in sources: total += float(source["weight"])
	for source in sources: source["weight"] = float(source["weight"]) / maxf(total,0.000001)
	return sources

static func _point(value: Array) -> Vector2:
	return Vector2(float(value[0]),float(value[1]))

static func controls(g: Dictionary, limbs := false) -> PackedVector2Array:
	var result := PackedVector2Array()
	var center := _point(g["head_center"])
	var angle := float(g["head_angle"])
	var down := Vector2(sin(angle),cos(angle))
	var right := Vector2(down.y,-down.x)
	var h := float(g["head_size"])
	for corner in [Vector2(-0.48,-0.5),Vector2(0.48,-0.5),Vector2(-0.48,0.5),Vector2(0.48,0.5)]:
		result.append((center+down*h*corner.y+right*h*corner.x)/512.0)
	result.append(_point(g["grip"])/512.0)
	result.append(_point(g["root"])/512.0)
	if g.has("secondary_grip"):result.append(_point(g["secondary_grip"])/512.0)
	if limbs:
		for i in g["joints"].size():
			if i not in [4,5]:result.append(_point(g["joints"][i])/512.0)
	for corner in [Vector2.ZERO,Vector2(1024,0),Vector2(0,1080),Vector2(1024,1080)]:result.append(corner/512.0)
	return result

func _geometry(sources: Array) -> Dictionary:
	var first: Dictionary = sources[0]["frame"]["motion_geometry"]
	var g := {"head_center":[0.0,0.0],"head_size":0.0,"head_angle":float(first["head_angle"]),"grip":[0.0,0.0],"root":[0.0,0.0],"secondary_grip":[0.0,0.0],"joints":[]}
	for _joint in first["joints"]:g["joints"].append([0.0,0.0])
	for source in sources:
		var m: Dictionary = source["frame"]["motion_geometry"]
		var w := float(source["weight"])
		for key in ["head_center","grip","root","secondary_grip"]:
			for axis in 2:g[key][axis] += float(m[key][axis])*w
		g["head_size"] += float(m["head_size"])*w
		g["head_angle"] += wrapf(float(m["head_angle"])-float(first["head_angle"]),-PI,PI)*w
		for j in g["joints"].size():
			for axis in 2:g["joints"][j][axis] += float(m["joints"][j][axis])*w
	return g

func _blades(sources: Array, g: Dictionary) -> Dictionary:
	var result := {}
	for profile in Library.data()["profiles"]:
		var u := Vector2.ZERO
		var v := Vector2.ZERO
		var front_weight := 0.0
		var angle := 0.0
		var projection := 0.0
		var origin_angle := float(_angle_origins.get(profile,_point(sources[0]["frame"]["profiles"][profile]["basis_u"]).angle()))
		for source in sources:
			var p: Dictionary = source["frame"]["profiles"][profile]
			var w := float(source["weight"])
			u += _point(p["basis_u"])*w
			v += _point(p["basis_v"])*w
			var axis := _point(p["basis_u"])
			var unwrapped := origin_angle+wrapf(axis.angle()-origin_angle,-PI,PI)
			if _elapsed < _duration and _key in ["idle","walk","run","walk_stop","run_stop","guard_end"] and cos(origin_angle)<0 and axis.x>0:
				while unwrapped < origin_angle:unwrapped += TAU
			angle += unwrapped*w
			projection += axis.length()*w
			if not p["front"].is_empty():front_weight += w
		if _elapsed < _duration:u = Vector2.from_angle(angle)*projection
		if u.length() < 0.035:u = Vector2(u.x,-0.035)
		var normal := Vector2(-u.y,u.x).normalized()
		if absf(v.dot(normal)) < 0.025:v += normal * (0.025 if v.dot(normal) >= 0 else -0.025)
		var spec: Dictionary = Library.data()["weapon_sources"][profile]
		var marks: Dictionary = spec["marks"]
		var source_axis := (_point(marks["tip"])-_point(marks["guard"])).normalized()
		var scale := float(spec["physical_blade_length"])/_point(marks["tip"]).distance_to(_point(marks["guard"]))
		var a := scale*(u.x*source_axis.x-v.x*source_axis.y)
		var b := scale*(u.x*source_axis.y+v.x*source_axis.x)
		var c := scale*(u.y*source_axis.x-v.y*source_axis.y)
		var d := scale*(u.y*source_axis.y+v.y*source_axis.x)
		var grip := _point(g["grip"])
		var matrix := Transform2D(Vector2(a,c),Vector2(b,d),grip)
		var raw_grip := _point(marks["grip"])
		result[profile] = {"guard":matrix*(_point(marks["guard"])-raw_grip),"tip":matrix*(_point(marks["tip"])-raw_grip),"grip":grip,"matrix":matrix,"raw_grip":raw_grip,"raw_weapon":spec["file"],"front":front_weight >= 0.5,"basis_u":u,"basis_v":v}
	return result

func sample(targets: Array) -> Dictionary:
	var sources := _sources(targets)
	var g := _geometry(sources)
	return {"sources":sources,"geometry":g,"blades":_blades(sources,g)}

func present(targets: Array, profile: String) -> Dictionary:
	var value := sample(targets)
	geometry = value["geometry"]
	blades = value["blades"]
	_last_sources = value["sources"]
	var signature := JSON.stringify(_last_sources)
	if signature != _last_signature:
		_last_signature = signature
		_update_surface(_last_sources,geometry)
	var p: Dictionary = blades[profile]
	var node: Sprite2D = front_weapon if p["front"] else back_weapon
	front_weapon.visible = p["front"]
	back_weapon.visible = not p["front"]
	node.texture = Library.texture({"file":p["raw_weapon"]})
	node.offset = -p["raw_grip"]
	node.transform = p["matrix"]
	node.position -= Library.anchor()
	return value

func _update_surface(sources: Array, g: Dictionary) -> void:
	# Only state bridges need limb alignment. Within a baked walk cycle the
	# correspondence model owns crossing-leg occlusion; do not re-rig it.
	var bridge := _elapsed < _duration and not _outgoing.is_empty()
	var destination := controls(g,bridge)
	var originals: Array = []
	for source in sources:originals.append(controls(source["frame"]["motion_geometry"],bridge))
	var points := PackedVector2Array()
	for point in destination:points.append(point*512.0)
	var vertices := PackedVector3Array()
	for point in points:vertices.append(Vector3(point.x-Library.anchor().x,point.y-Library.anchor().y,0))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var uv := PackedVector2Array()
	for i in points.size():uv.append(Vector2(i,0))
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = Geometry2D.triangulate_delaunay(points)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	var wa := Vector4.ZERO
	var wb := Vector4.ZERO
	for i in sources.size():
		if i < 4:wa[i] = float(sources[i]["weight"])
		else:wb[i-4] = float(sources[i]["weight"])
	for pair in [[body,"body"],[fingers,"fingers"]]:
		var node: MeshInstance2D = pair[0]
		node.visible = true
		node.mesh = mesh
		var material := node.material as ShaderMaterial
		material.set_shader_parameter("weights_a",wa)
		material.set_shader_parameter("weights_b",wb)
		for i in MAX_SOURCES:
			var ref: Dictionary = sources[i]["frame"][pair[1]] if i < sources.size() else {}
			var texture := Library.texture(ref)
			material.set_shader_parameter("source_%d" % i,texture if texture != null else _transparent)
			var r: Array = ref.get("rect",[0,0,1,1])
			material.set_shader_parameter("rect_%d" % i,Vector4(r[0],r[1],r[2],r[3]))
			var original := PackedVector2Array()
			if i < originals.size():original = originals[i].duplicate()
			original.resize(32)
			material.set_shader_parameter("points_%d" % i,original)
