extends RefCounted
## CNHundredSword preparation motion. The owner ANI supplies the four phase
## boundaries. Each slot keeps its image variant and ground/air selection.

const Motion = preload("res://combat/particles/native_motion.gd")
const DetRng = preload("res://core/det_rng.gd")
const RADIUS := 250
const HEIGHT := 150

var _center: Vector2
var _facing: int
var _styles: Array
var _art_facing: Array[int] = []
var _disappear_fx: Array[String] = []
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
	_entry_ms = int(timeline[4]["start_ms"])
	_spread_ms = int(timeline[11]["start_ms"])
	_settle_ms = int(timeline[16]["start_ms"])
	_land_ms = int(timeline[18]["start_ms"])

func advance(ms: float, owner_ready_ms: float) -> bool:
	var was_waiting := _age < _entry_ms
	_age = owner_ready_ms if owner_ready_ms >= 0.0 else _age+ms
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
	var rotation := Motion.f32(Motion.f32(6.28)*_art_rng.range_int(0,99)/99.0)
	_spent[slot] = {"point":point,"at_ms":_age,"rotation":rotation}
	return point

func append_view(out: Array) -> void:
	var now := int(_age)
	if now < _entry_ms:return
	var radius := RADIUS
	var angle := 0
	var phase_ms := float(now-_land_ms)
	if now < _spread_ms:
		var elapsed := now-_entry_ms
		var duration := _spread_ms-_entry_ms
		angle = int(Motion.ramp(0.0,360.0,elapsed,duration))
		radius = _orbit_radius(RADIUS,0,elapsed,duration)
		phase_ms = float(elapsed)
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
			_layer(out,slot,id+":light",_effects["light2"],point,height,phase_ms,1,true)
			_layer(out,slot,id+":light",_effects["light3"],point,height,phase_ms,2,false,true)
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
