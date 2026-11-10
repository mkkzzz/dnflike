extends RefCounted
## Native object 20052. Its attack ledger and clock outlive the player's state 46.
const Timeline = preload("res://combat/action/timeline.gd")
const HitJudge = preload("res://combat/hit/hit_judge.gd")
const Motion = preload("res://combat/particles/native_motion.gd")
const DISAPPEAR_PARTICLE := "passiveobject/character/swordman/particle/hellbenterdisappear.ptl"

static func spawn(game, move: Dictionary, charges: int) -> Dictionary:
	var config: Dictionary = move["column"]
	var skill: Dictionary = game.table._skill_row(move["skill"])
	var row: Array = skill["level_row"]
	var static_data: Array = skill["static"]
	var capacity := int(move["blood"]["capacity"])
	var base: int = game.native_fixed_attack_base(move["fixed_attack_base"])
	var amounts: Array[int] = []
	for start: int in [2,4]:
		var weak := int(game.native_fixed_attack_product(row[start],base))
		var strong := int(game.native_fixed_attack_product(row[start+1],base))
		amounts.append(game._native_interpolate(weak,strong,charges,capacity))
	var percent: int = game._native_interpolate(config["scale"][0],config["scale"][1],charges,capacity)
	var scale := Motion.f32(percent*Motion.f32(0.01))
	# CB86B9 passes the signed SD offset, zero depth and height offsets, and
	# the normal attack amount separately from the final-attack packet.
	var attack: Dictionary = game.native_fixed_hit(config["attack_hit"],amounts[0])
	attack.merge({"object":config["object"],"offset":Vector3(config["offset"],0,0),
		"size_rate":scale,"starts_at_zero":true,"native_controller":{"kind":"hellbenter_column"}},true)
	var position := Vector2(Vector2i(game.player["pos"]))
	var object: Dictionary = game.spawn_object(attack,"player",position,float(int(game.player["z"])),
		int(game.player["facing"]),game.attack_power(),{},{"timeline":[],"bank":"","add_fx":""})
	var appear: Dictionary = config["phases"][0]
	var loop_ms := int(static_data[15])
	var hit_count := int(static_data[16])
	# A69E08 reads the only attack frame's delay from Appear5.
	@warning_ignore("integer_division")
	var interval := (loop_ms+int(appear["duration"])-int(config["impact"]))/hit_count
	object["column"] = {"config":config,"phase":0,"phase_at":0.0,"loop_ms":loop_ms,
		"hit_interval":interval,"next_reset":int(config["impact"])+interval,"resets":hit_count-1,
		"final":game.native_fixed_hit(config["final_attack_hit"],amounts[1]),"erupted":false}
	game.play_sound("B_FIRE_EXPLOSION_READY")
	game.bus.emit("combat.cue",{"kind":"screen_shake","degree":20,"duration_ms":100})
	game.bus.emit("combat.cue",{"kind":"fx","key":config["wave"],"point":object["pos"],
		"height":object["z"],"facing":object["facing"],"offset_y":1,"scale":scale,"depth_offset":2,"fresh":true})
	return object

static func owner_can_exit(object: Dictionary) -> bool:
	var column: Dictionary = object["column"]
	return column["phase"] == 2 and float(object["clock"])-float(column["phase_at"]) >= 200.0

static func step(game, object: Dictionary) -> bool:
	var column: Dictionary = object["column"]
	var config: Dictionary = column["config"]
	var clock := float(object["clock"])
	var phase := int(column["phase"])
	var age := clock-float(column["phase_at"])
	var phases: Array = config["phases"]
	if phase == 0:
		if age >= float(config["impact"]) and not column["erupted"]:
			column["erupted"] = true
			game.play_sound("B_FIRE_EXPLOSION")
			game.bus.emit("combat.cue",{"kind":"screen_shake","degree":20,"duration_ms":100})
		if age >= float(phases[0]["duration"]):
			phase = 1
			column["phase_at"] = clock
			age = 0.0
			game.bus.emit("combat.cue",{"kind":"screen_shake","degree":2,"duration_ms":column["loop_ms"]})
			game.bus.emit("combat.cue",{"kind":"sound","key":"B_FIRE_COLUMN_LOOP","loop_id":object["id"]})
	elif phase == 1 and age >= float(column["loop_ms"]):
		stop_loop(game,object)
		phase = 2
		column["phase_at"] = clock
		age = 0.0
		object["hits"].clear()
		game.play_sound("ASTORM_HIT_FIRE")
		game.bus.emit("combat.cue",{"kind":"screen_shake","degree":20,"duration_ms":200})
		# A6A508..A6A5BB emits once at Y+1, Z+200, then scales the child animations.
		game.bus.emit("combat.cue",{"kind":"native_particle","path":DISAPPEAR_PARTICLE,
			"point":Vector2(object["pos"])+Vector2(0,1),"height":float(object["z"])+200.0,
			"scale":object["size_rate"]})
	elif phase == 2 and age >= float(phases[2]["duration"]):
		return false
	column["phase"] = phase
	if phase < 2 and int(column["resets"]) > 0 and clock >= float(column["next_reset"]):
		# A6B708 clears the object's contact list once per timer update.
		object["hits"].clear()
		column["next_reset"] += int(column["hit_interval"])
		column["resets"] -= 1
	var frame := Timeline.frame_at(phases[phase]["timeline"],age,phase==1)
	var boxes: Array = frame.get("attack_boxes",[])
	if boxes.is_empty():return true
	var hit: Dictionary = column["final"] if phase == 2 else object["hit"]
	var facing := int(object["facing"])
	var anchor := HitJudge.anchor(object["pos"],object["z"])
	var world := HitJudge.world_boxes(boxes,anchor,facing,float(object["size_rate"]))
	for enemy: Dictionary in game.monsters:
		var id := int(enemy["id"])
		if object["hits"].has(id) or float(enemy["hp"]) <= 0.0:continue
		var contact := HitJudge.contact(world,game.enemy_damage_boxes(enemy))
		if contact.is_empty():continue
		object["hits"][id] = true
		game.land_hit(game.player,enemy,hit,contact["point"],facing,float(object["power"]))
	if game.native_maze != null:
		game.apply_native_prop_hits(world,hit,float(object["power"]),object["hits"],"prop:")
	return true

static func stop_loop(game, object: Dictionary) -> void:
	if int(object["column"]["phase"]) == 1:
		game.bus.emit("combat.cue",{"kind":"sound","stop":true,"loop_id":object["id"]})

static func append_view(out: Array, object: Dictionary) -> void:
	var column: Dictionary = object["column"]
	var phase := int(column["phase"])
	var age := float(object["clock"])-float(column["phase_at"])
	var layers: Array = column["config"]["phases"][phase]["layers"]
	for layer: Dictionary in layers:
		if phase != 1 and age >= float(layer["duration"]):continue
		out.append({"id":"%d:%s"%[object["id"],layer["effect"]],"effect":layer["effect"],
			"pos":object["pos"],"z":object["z"],"facing":object["facing"],"clock":age,
			"size_rate":object["size_rate"],"depth_offset":layer["depth"],"loop":phase==1})
