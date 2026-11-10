extends RefCounted
## Native object 20052. Its attack ledger and clock outlive the player's state 46.
const Timeline = preload("res://combat/action/timeline.gd")
const HitJudge = preload("res://combat/hit/hit_judge.gd")
const Motion = preload("res://combat/particles/native_motion.gd")
const DISAPPEAR_PARTICLE := "passiveobject/character/swordman/particle/hellbenterdisappear.ptl"
const LOOP_PARTICLE := "passiveobject/character/swordman/particle/hellbenterloop.ptl"
const EXPLOSION_PARTICLE := "passiveobject/common/particle/noneexplosionparticle%d.ptl"
const EXPLOSION_OFFSETS := [Vector2i(-159,60),Vector2i(-106,136),Vector2i(7,18),Vector2i(120,114),Vector2i(162,43)]

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
	var final: Dictionary = game.native_fixed_hit(config["final_attack_hit"],amounts[1])
	final["native_controller"] = attack["native_controller"]
	object["column"] = {"config":config,"phase":0,"phase_at":0.0,"loop_ms":loop_ms,
		"hit_interval":interval,"next_reset":int(config["impact"])+interval,"resets":hit_count-1,
		"final":final,"erupted":false}
	game.play_sound("B_FIRE_EXPLOSION_READY")
	game.bus.emit("combat.cue",{"kind":"screen_shake","degree":20,"duration_ms":100})
	game.bus.emit("combat.cue",{"kind":"fx","key":config["wave"],"point":object["pos"],
		"height":object["z"],"facing":object["facing"],"offset_y":1,"scale":scale,"depth_offset":2,"fresh":true})
	return object

static func mark_target(target: Dictionary) -> void:
	# A6AAB2 refreshes the duration relative to the appendage's existing clock.
	var mark: Dictionary = target.get_or_add("hellbenter_column_mark",{"age":0.0})
	mark["expires_at"] = int(mark["age"])+600

static func step_target_mark(target: Dictionary, ms: float) -> void:
	if not target.has("hellbenter_column_mark"):return
	var mark: Dictionary = target["hellbenter_column_mark"]
	mark["age"] += ms
	if int(mark["age"]) >= int(mark["expires_at"]):target.erase("hellbenter_column_mark")

static func target_mark_alpha(target: Dictionary) -> int:
	var mark: Dictionary = target.get("hellbenter_column_mark",{})
	if mark.is_empty():return 0
	# 99C018..99C08F ramps from zero, holds at 120 and fades on the last 100 ms.
	var age := int(mark["age"])
	if age <= 100:return int(Motion.ramp(0,120,age,100))
	var remaining := int(mark["expires_at"])-age
	return int(Motion.ramp(120,0,100-remaining,100)) if remaining < 100 else 120

static func final_phase_elapsed(object: Dictionary) -> float:
	var column: Dictionary = object["column"]
	return float(object["clock"])-float(column["phase_at"]) if column["phase"] == 2 else -1.0

static func step(game, object: Dictionary) -> bool:
	var column: Dictionary = object["column"]
	var config: Dictionary = column["config"]
	var clock := float(object["clock"])
	var phase := int(column["phase"])
	var age := clock-float(column["phase_at"])
	var phases: Array = config["phases"]
	if phase == 1:
		# A6B216..A6B26C samples before the state-5 transition, at Y+1 and Z+10.
		emit_loop_particles(game,object,age)
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
		stop_phase_effects(game,object)
		phase = 2
		column["phase_at"] = clock
		age = 0.0
		object["hits"].clear()
		game.play_sound("ASTORM_HIT_FIRE")
		# A6A508..A6A5BB emits once at Y+1, Z+200, then scales the child animations.
		game.bus.emit("combat.cue",{"kind":"native_particle","path":DISAPPEAR_PARTICLE,
			"point":Vector2(object["pos"])+Vector2(0,1),"height":float(object["z"])+200.0,
			"scale":object["size_rate"],"mirrored":int(object["facing"])<0})
		# A6A5D0..A6A616 requests a layer-six white additive flash.
		game.bus.emit("combat.cue",{"kind":"screen_flash","point":object["pos"],"height":object["z"],
			"trigger_size":Vector2i(400,480),"durations":[70,0,70],"peak_alpha":130})
		game.bus.emit("combat.cue",{"kind":"screen_shake","degree":20,"duration_ms":200})
	elif phase == 2:
		emit_final_explosions(game,object,age)
		if age >= float(phases[2]["duration"]):
			stop_phase_effects(game,object)
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

static func stop_phase_effects(game, object: Dictionary) -> void:
	var phase := int(object["column"]["phase"])
	if phase == 1:
		game.bus.emit("combat.cue",{"kind":"sound","stop":true,"loop_id":object["id"]})
	if phase > 0:
		game.bus.emit("combat.cue",{"kind":"native_particle","stop":true,"object_emitter":object["id"]})

static func emit_loop_particles(game, object: Dictionary, age: float) -> void:
	game.bus.emit("combat.cue",{"kind":"native_particle","path":LOOP_PARTICLE,
		"point":Vector2(object["pos"])+Vector2(0,1),"height":float(object["z"])+10.0,
		"scale":object["size_rate"],"object_emitter":object["id"],"elapsed_ms":int(age),
		"mirrored":int(object["facing"])<0})

static func emit_final_explosions(game, object: Dictionary, age: float) -> void:
	var pos := Vector2i(object["pos"])
	var z := int(object["z"])
	var facing := int(object["facing"])
	var scale := float(object["size_rate"])
	var visual_scale := Motion.f32(scale*2.5)
	# A6B505..A6B68E walks five (X,Z) pairs and four independent PTLs per pair.
	for group in EXPLOSION_OFFSETS.size():
		var offset: Vector2i = EXPLOSION_OFFSETS[group]
		var x := int(Motion.f32(pos.x+facing*Motion.f32(offset.x*scale)))
		var height := int(Motion.f32(z+Motion.f32(offset.y*scale)))
		for variant in range(1,5):
			game.bus.emit("combat.cue",{"kind":"native_particle","path":EXPLOSION_PARTICLE%variant,
				"point":Vector2(x,pos.y+1),"height":height,"scale":visual_scale,"mirrored":facing<0,
				"object_emitter":object["id"],"emitter_channel":group*4+variant,"elapsed_ms":int(age)})

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
