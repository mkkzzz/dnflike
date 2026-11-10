extends RefCounted
## Native skill 85 tracks bleeding hostiles separately from the Frenzy kill heal.
const Numbers = preload("res://stats/api/numbers.gd")
const Motion = preload("res://combat/particles/native_motion.gd")
const DetRng = preload("res://core/det_rng.gd")
const TAIL_COUNT := 15
const TAIL_STEP := 10

var marks: Dictionary = {}
var orbs: Array[Dictionary] = []
var next_orb_id := 0

func clear() -> void:
	marks.clear()
	orbs.clear()

func step(game, ms: float) -> void:
	var effect: Dictionary = game.active_effect("hellbenter")
	if effect.is_empty() and marks.is_empty() and orbs.is_empty():return
	if float(game.player["hp"]) <= 0.0:
		clear()
		return
	var move: Dictionary = game.move_def("hellbenter")
	var config: Dictionary = move["blood"]
	var flight := int(config["flight_ms"])
	var arrivals := 0
	var destination := Vector3i(int(game.player["pos"].x),int(game.player["pos"].y),
		int(game.player["z"])+int(float(move["appearance"]["body_height"])*0.5))
	for index in range(orbs.size()-1,-1,-1):
		var orb := orbs[index]
		orb["age"] += ms
		if float(orb["age"]) >= flight:
			orbs.remove_at(index)
			arrivals += 1
			continue
		var point := _orb_point(orb,destination,flight)
		var history: Array = orb["history"]
		var previous: Vector4i = history.back()
		if Motion.trail_projection(point).distance_squared_to(Motion.trail_projection(previous)) >= TAIL_STEP*TAIL_STEP:
			history.append(point)
		orb["point"] = point
	if effect.is_empty():
		marks.clear()
		return
	var age := float(effect["definition"]["duration_ms"])-float(effect["remaining_ms"])
	if arrivals > 0:
		_absorb(game,effect,arrivals,int(config["capacity"]),age,float(move["appearance"]["absorb_end"]))
	var scan := age >= float(effect.get("next_blood_scan",0.0))
	if scan:effect["next_blood_scan"] = age+float(config["scan_ms"])
	for enemy: Dictionary in game.monsters:
		var id := int(enemy["id"])
		if float(enemy["hp"]) <= 0.0 or not enemy.has("numeric") or not enemy["numeric"].effects.active.has("bleed"):
			marks.erase(id)
			continue
		if not marks.has(id):
			if scan:
				marks[id] = {"age":0.0,"next_pulse":float(config["pulse_ms"]),"facing":int(enemy["facing"])}
			continue
		var mark: Dictionary = marks[id]
		mark["age"] += ms
		if float(mark["age"]) < float(mark["next_pulse"]):continue
		mark["next_pulse"] += float(config["pulse_ms"])
		var origin: Vector2 = Vector2(Vector2i(enemy["pos"]))
		if int(origin.distance_to(Vector2(destination.x,destination.y))) <= int(config["range"]):
			_spawn(game,enemy,destination)

func _spawn(game, enemy: Dictionary, destination: Vector3i) -> void:
	# 99C4A0 sends the target position at half body height. Use the same
	# hurt-extent fallback as Saya while the monster display-height getter is unmapped.
	var point: Vector3i = Vector3i(game.enemy_mid_height_point(enemy))
	# Keep cosmetic draws separate from damage and status rolls.
	var rng := DetRng.new(hash([game.rng.seed_value,enemy["id"],next_orb_id]))
	var x_span := rng.range_int(150,249)
	var y_span := int(Motion.ramp(40,80,rng.range_int(0,99),100))
	var bend_x := point.x+x_span if point.x > destination.x else point.x-x_span
	var bend_y := mini(point.y,destination.y)-y_span if rng.range_int(0,1) == 0 else maxi(point.y,destination.y)+y_span
	var head := Vector4i(point.x,point.y,point.z,0)
	orbs.append({"id":"hellbenter:orb:%d"%next_orb_id,
		"origin":point,"bend":Vector2i(bend_x,bend_y),"age":0.0,"point":head,"history":[head]})
	next_orb_id += 1

static func _orb_point(orb: Dictionary, destination: Vector3i, flight: int) -> Vector4i:
	var age := int(orb["age"])
	var origin: Vector3i = orb["origin"]
	var bend: Vector2i = orb["bend"]
	# CAC550 uses separate turning times for x and y. The native parabola
	# decelerates out to the bend, then accelerates toward the current owner position.
	return Vector4i(_orb_axis(origin.x,bend.x,destination.x,age,150,flight),
		_orb_axis(origin.y,bend.y,destination.y,age,400,flight),
		int(Motion.ramp(origin.z,destination.z,age,flight)),age)

static func _orb_axis(start: int, bend: int, destination: int, age: int, turn: int, flight: int) -> int:
	if age == 0:return start
	if age == turn:return bend
	# 11AEFE0 reverses the endpoints and clock for the incoming leg.
	var outgoing := age < turn
	var origin := start if outgoing else destination
	var time := age if outgoing else flight-age
	var term := turn if outgoing else flight-turn
	var initial_speed := Motion.f32(float(absi(bend-origin)*2)/term)
	var acceleration := Motion.f32(-initial_speed/term)
	var offset := time*(initial_speed+acceleration*0.5*time)
	return int(origin+offset*signi(bend-origin))

func _absorb(game, effect: Dictionary, arrivals: int, capacity: int, age: float, flash_duration: float) -> void:
	var previous := int(effect.get("blood_count",0))
	var count := mini(capacity,previous+arrivals)
	if count == previous:return
	effect["blood_count"] = count
	if age-float(effect.get("blood_absorb_at",-INF)) >= flash_duration:effect["blood_absorb_at"] = age
	var row: Array = Numbers.Skills.sample(Numbers.record("hellbenter"),int(effect["rank"]))["level_row"]
	# CA1FD0 writes the interpolated integer per-mille bonus into the two
	# existing modifier records. The cast's saved rank determines the endpoints.
	for modifier: Dictionary in effect["definition"]["modifiers"]:
		var column := 6 if modifier["stat"] == "attack_speed" else 8
		modifier["value"] = int(Motion.ramp(row[column],row[column+1],count,capacity))*0.001
	game.numeric_player.recalculate()

func append_view(game, out: Array) -> void:
	if marks.is_empty() and orbs.is_empty():return
	var appearance: Dictionary = game.move_def("hellbenter")["appearance"]
	for enemy: Dictionary in game.monsters:
		var id := int(enemy["id"])
		if not marks.has(id):continue
		var age := float(marks[id]["age"])
		var mid: Vector3 = game.enemy_mid_height_point(enemy)
		var mark: Array = appearance["target_mark"]
		var height := int(enemy["z"])+2*(int(mid.z)-int(enemy["z"]))
		var layer := {"pos":Vector2(mid.x,mid.y),"z":height,"clock":age,
			"facing":marks[id]["facing"],"depth_offset":1}
		if age < float(appearance["target_mark_end"]):
			out.append(layer.merged({"id":"hellbenter:mark_entry:%d"%id,"effect":mark[0]}))
		else:
			out.append(layer.merged({"id":"hellbenter:mark_base:%d"%id,"effect":mark[1],"hold_last_frame":true}))
			out.append(layer.merged({"id":"hellbenter:mark_glow:%d"%id,"effect":mark[2],"loop":true}))
		layer["z"] = mid.z
		# 99A8E6 scales the two body layers by an integer step above height 100.
		layer["size_rate"] = int(Motion.ramp(1,3,clampi(height-int(enemy["z"])-100,0,200),200))
		for key: String in appearance["target_bleeding"]:
			out.append(layer.merged({"id":"hellbenter:%s:%d"%[key,id],"effect":key,"loop":true}))
	var ball: Array = appearance["ball"]
	for orb: Dictionary in orbs:
		var head: Vector4i = orb["point"]
		var trail := Motion.trail_points(orb["history"],head,TAIL_COUNT,TAIL_STEP)
		for index in range(trail.size()-1,0,-1):
			var point: Vector4i = trail[index]
			var delta := Vector2(Motion.trail_projection(point)-Motion.trail_projection(trail[index-1]))
			var variant := mini(4,int(Motion.ramp(1,5,index-1,TAIL_COUNT)))
			out.append({"id":"%s:%d"%[orb["id"],index],"effect":ball[variant],
				"pos":Vector2(point.x,point.y),"z":point.z,"facing":1,"clock":0.0,
				"depth_offset":head.y-point.y+2,"rotation":delta.angle(),
				"fade":int(Motion.ramp(255,50,index-1,TAIL_COUNT-1))/255.0})
		out.append({"id":orb["id"],"effect":ball[0],"pos":Vector2(head.x,head.y),"z":head.z,
			"facing":1,"clock":head.w,"loop":true,"depth_offset":2})
