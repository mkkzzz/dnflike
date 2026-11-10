extends RefCounted
## CNHundredSword preparation motion. The owner ANI supplies the four phase
## boundaries. Each slot keeps its image variant and ground/air selection.

const Motion = preload("res://combat/particles/native_motion.gd")
const DetRng = preload("res://core/det_rng.gd")
const RADIUS := 250
const HEIGHT := 150
const TRAIL_LAYERS := 12
const TRAIL_STEP := 10

var _center: Vector2
var _facing: int
var _styles: Array
var _art_facing: Array[int] = []
var _disappear_fx: Array[String] = []
var _light_rotations: Dictionary = {}
var _trail_history: Dictionary = {}
var _spent: Dictionary = {}
var _disappear_ms: float
var _effects: Dictionary
var _entry_ms: int
var _spread_ms: int
var _settle_ms: int
var _land_ms: int
var _age := 0.0
var _art_rng: DetRng

func _init(origin: Vector2, facing: int, timeline: Array, config: Dictionary, cosmetic_seed: int) -> void:
	_center = origin+Vector2(int(config["distance"])*facing,0)
	_facing = facing
	_styles = config["styles"]
	_effects = config["effects"]
	_disappear_ms = float(config["disappear_ms"])
	# The source draws an independent mirror bit for each sword. Keep these
	# cosmetic draws off the combat hit and critical RNG.
	_art_rng = DetRng.new(cosmetic_seed)
	for slot in _styles.size():
		_art_facing.append(2*_art_rng.range_int(0,1)-1)
		_disappear_fx.append(_effects["sworddisappear%d"%_art_rng.range_int(1,2)])
	# A6CD63..A6CE62 assigns a separate angle to each visible Light3 frame.
	for slot in range(0,_styles.size(),3):
		_light_rotations[slot] = {1:_random_rotation(),3:_random_rotation(),5:_random_rotation()}
		_trail_history[slot] = []
	_entry_ms = int(timeline[4]["start_ms"])
	_spread_ms = int(timeline[11]["start_ms"])
	_settle_ms = int(timeline[16]["start_ms"])
	_land_ms = int(timeline[18]["start_ms"])

func advance(ms: float, owner_ready_ms: float) -> bool:
	var was_waiting := _age < _entry_ms
	_age = owner_ready_ms if owner_ready_ms >= 0.0 else _age+ms
	if _age >= _entry_ms and _age < _spread_ms:
		_record_trail(int(_age))
	elif not _trail_history.is_empty() and _age >= _spread_ms:
		_trail_history.clear()
	return was_waiting and _age >= _entry_ms

func waypoint(slot: int) -> Vector3i:
	if _spent.has(slot):return _spent[slot]["point"]
	var point := _blade_point(slot,0,RADIUS)
	var z := 40 if slot%2 == 0 else _air_height(slot,int(_age))
	return Vector3i(int(point.x),int(point.y),z)

func consume(slot: int) -> Vector3i:
	var point := waypoint(slot)
	# CD22CD selects CNHundredSword state 4 before CD2305 reads its point.
	# A6D256..A6D2E4 assigns one sampled rotation to every frame of ETC 12.
	_spent[slot] = {"point":point,"at_ms":_age,"rotation":_random_rotation()}
	return point

func append_view(out: Array) -> void:
	var now := int(_age)
	if now < _entry_ms:return
	var radius := RADIUS
	var angle := 0
	var phase_ms := float(now-_land_ms)
	if now < _spread_ms:
		var orbit := _gather_orbit(now)
		angle = orbit.x
		radius = orbit.y
		phase_ms = float(now-_entry_ms)
	elif now < _land_ms:
		var elapsed := mini(now,_settle_ms)-_spread_ms
		var duration := _settle_ms-_spread_ms
		angle = int(Motion.ramp(360.0,720.0,elapsed,duration))
		radius = _orbit_radius(0,RADIUS,elapsed,duration)
		phase_ms = float(now-_spread_ms)
	for slot in _styles.size():
		if now < _spread_ms and slot%3 != 0:continue
		var id := "hundred_sword:%d"%slot
		if _spent.has(slot):
			var age := _age-float(_spent[slot]["at_ms"])
			if age < _disappear_ms:
				var point: Vector3i = _spent[slot]["point"]
				# A6D202 keeps the object's height and offsets the ground attachment in screen Y.
				var ground := slot%2 == 0
				var view := _layer(out,slot,id+":disappear",_disappear_fx[slot],Vector2(point.x,point.y),
					0.0 if ground else float(point.z),age,1,false)
				view["screen_offset"] = Vector2(0,-40) if ground else Vector2.ZERO
				view["rotation"] = _spent[slot]["rotation"]
			continue
		var ground := slot%2 == 0
		var point := _blade_point(slot,angle,radius)
		var height := float(HEIGHT)
		if now >= _land_ms:
			height = 0.0 if ground else _air_height(slot,now)
		if now < _spread_ms:
			_layer(out,slot,id+":light",_effects["light1"],point,height,phase_ms,0,true)
			# A6CE6F..A6CEB6 sets Light2's first delay to the owner's frame 4–11 interval.
			var tint := _layer(out,slot,id+":light",_effects["light2"],point,height,phase_ms,1,true)
			tint["uniform_frame_ms"] = _spread_ms-_entry_ms
			var flash := _layer(out,slot,id+":light",_effects["light3"],point,height,phase_ms,2,false,true)
			flash["frame_rotations"] = _light_rotations[slot]
			_append_trail(out,slot,id,point,now)
		else:
			var stem := "swordspread" if now < _land_ms else "swordland" if ground else "swordair"
			for layer in [1,2]:
				var bank := "hundred_sword_%s%d_%02d"%[stem,layer,int(_styles[slot])]
				_layer(out,slot,id+":"+stem,bank,point,height,phase_ms,layer,true,stem=="swordair")
			if now >= _land_ms and ground:
				if phase_ms < 380.0:_layer(out,slot,id+":land",_effects["swordlandglow1"],point,0.0,phase_ms,0,false)
				if phase_ms < 310.0:_layer(out,slot,id+":land",_effects["swordlandglow2"],point,0.0,phase_ms,-1,false)
			elif now >= _land_ms:
				_layer(out,slot,id+":air",_effects["swordairglow"],point,height,phase_ms,-1,false,true)

func _gather_orbit(now: int) -> Vector2i:
	var elapsed := now-_entry_ms
	var duration := _spread_ms-_entry_ms
	return Vector2i(int(Motion.ramp(0.0,360.0,elapsed,duration)),_orbit_radius(RADIUS,0,elapsed,duration))

func _record_trail(now: int) -> void:
	var orbit := _gather_orbit(now)
	for slot: int in _trail_history:
		var point := Vector2i(_blade_point(slot,orbit.x,orbit.y))
		var history: Array = _trail_history[slot]
		# E2DACF records a new projected point after at least ten pixels of movement.
		# All points in this state have the same height, so Y-Z differences equal Y differences.
		if history.is_empty() or point.distance_squared_to(Vector2i(history.back().x,history.back().y)) >= TRAIL_STEP*TRAIL_STEP:
			history.append(Vector3i(point.x,point.y,now))

func _append_trail(out: Array, slot: int, id: String, head: Vector2, now: int) -> void:
	var history: Array = _trail_history[slot]
	var points: Array[Vector3i] = [Vector3i(int(head.x),int(head.y),now)]
	var sample_index := history.size()-1
	# E2DC2C..E2E485 walks backwards from each layer, interpolating ten
	# pixels toward the first older sample far enough away.
	for layer in TRAIL_LAYERS:
		var previous: Vector3i = points.back()
		while sample_index >= 0:
			var sample: Vector3i = history[sample_index]
			var delta := Vector2(sample.x-previous.x,sample.y-previous.y)
			var distance := int(delta.length())
			if sample.z < previous.z and distance >= TRAIL_STEP:
				# 11F0FF0/11F1060 index the original tenth-degree sine and cosine tables.
				var angle := mini(posmod(int(Motion.f32(delta.angle())*572.957914),3600),3559)
				var radians := Motion.f32(angle*0.0017453288892284036)
				var offset := Vector2.from_angle(radians)*TRAIL_STEP
				var stamp := int(Motion.ramp(previous.z,sample.z,TRAIL_STEP,distance))
				points.append(Vector3i(previous.x+roundi(offset.x),previous.y+roundi(offset.y),stamp))
				break
			sample_index -= 1
		if sample_index < 0:break
	if points.size() < 2:return
	var rotation := 0.0
	for layer in mini(points.size(),TRAIL_LAYERS):
		var point := Vector2(points[layer].x,points[layer].y)
		if layer+1 < points.size():
			var next := Vector2(points[layer+1].x,points[layer+1].y)
			rotation = Motion.f32(Motion.f32((point-next).angle())+Motion.f32(3.14))
		var variant := mini(4,int(Motion.ramp(1,5,layer,TRAIL_LAYERS)))
		var view := _layer(out,slot,id+":tail:%d"%layer,_effects["lighttail%d"%variant],point,HEIGHT,0.0,3,true)
		view["depth_offset"] = int(head.y-point.y)+3
		view["rotation"] = rotation*_art_facing[slot]
		view["fade"] = int(Motion.ramp(255,50,layer,TRAIL_LAYERS-1))/255.0

func _blade_point(slot: int, angle: int, radius: int) -> Vector2:
	var radians := deg_to_rad(float((7+slot*15+angle)%360))
	var x := int(Motion.f32(sin(radians))*radius)*_facing
	var y := -int(Motion.f32(cos(radians))*radius*29*Motion.f32(-0.01))
	return _center+Vector2(x,y)

func _air_height(slot: int, now: int) -> int:
	var born := _entry_ms if slot%3 == 0 else _spread_ms
	var wave := (now-born)%3000
	if wave > 1500:wave = 3000-wave
	return HEIGHT+int(Motion.ramp(0.0,10.0,wave,1500))

func _random_rotation() -> float:
	return Motion.f32(Motion.f32(6.28)*_art_rng.range_int(0,99)/99.0)

func _layer(out: Array, slot: int, id: String, bank: String, pos: Vector2, z: float, clock: float, depth: int,
		hold: bool, loop := false) -> Dictionary:
	var view := {"id":"%s:%d"%[id,depth],"effect":bank,"pos":pos,"z":z,"facing":_art_facing[slot],
		"clock":clock,"depth_offset":depth,"hold_last_frame":hold,"loop":loop}
	out.append(view)
	return view

static func _orbit_radius(from: int, to: int, elapsed: int, duration: int) -> int:
	# A6DF19/A6DF90 call the integer wrapper of 11AEFE0, with reverse easing.
	if elapsed <= 0:return from
	if elapsed >= duration:return to
	var time := float(duration-elapsed)
	var slope := Motion.f32(float(2*absi(to-from))/duration)
	var curve := Motion.f32(slope/duration)
	var offset := (slope-0.5*curve*time)*time
	return int(to+offset if from > to else to-offset)
