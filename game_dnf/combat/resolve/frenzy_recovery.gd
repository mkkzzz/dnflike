extends RefCounted
## Frenzy appendage's bleed scan and the recovery orb sent by native skill 76.
const Numbers = preload("res://stats/api/numbers.gd")
const ActorNumbers = preload("res://stats/api/actor_numbers.gd")
const ItemRestoration = preload("res://combat/item_restoration.gd")
const SCAN_MS := 100.0
const WAIT_MS := 180.0
const RISE_MS := 450.0
const FLIGHT_MS := 400.0
const ARRIVAL_MS := WAIT_MS+RISE_MS+FLIGHT_MS
const RECOVERY_MS := 500.0

var orbs: Array[Dictionary] = []

func clear() -> void:
	orbs.clear()

func step(game, ms: float) -> void:
	var frenzy: Dictionary = game.active_effect("frenzy")
	if not frenzy.is_empty():
		var scan_ms := float(frenzy.get("bleed_scan_ms",0.0))+ms
		frenzy["bleed_scan_ms"] = scan_ms
		if scan_ms >= SCAN_MS:
			var tracked := {}
			for enemy: Dictionary in game.monsters:
				if float(enemy["hp"]) > 0.0 and enemy.has("numeric") and enemy["numeric"].effects.active.has("bleed"):
					tracked[enemy["id"]] = true
			frenzy["bleed_targets"] = tracked
			frenzy["bleed_scan_ms"] = 0.0
	for i in range(orbs.size()-1,-1,-1):
		var orb := orbs[i]
		orb["age_ms"] += ms
		if float(orb["age_ms"]) < ARRIVAL_MS:continue
		orbs.remove_at(i)
		if int(orb["heal"]) > 0:
			# This fixed step may straddle arrival. Advance only this new recovery
			# over the part of the step after the orb reached the player.
			var entry := ItemRestoration.queue(game,float(orb["heal"]),0.0,RECOVERY_MS)
			ItemRestoration.advance(game,entry,float(orb["age_ms"])-ARRIVAL_MS)
		game.play_sound("FLENSE_FLASH")

func record_kill(game, enemy: Dictionary) -> void:
	var frenzy: Dictionary = game.active_effect("frenzy")
	var tracked: Dictionary = frenzy.get("bleed_targets",{})
	if not tracked.erase(enemy["id"]):return
	var row: Array = Numbers.Skills.sample(Numbers.record("buff"),int(frenzy["rank"]))["level_row"]
	if row.size() <= 15:return
	# 0x99784E: the target cap uses two rounded single-precision multiplies.
	var ratio := ActorNumbers.native_scalar(float(row[2])*ActorNumbers.native_scalar(0.0001))
	var target_max_hp := ActorNumbers.native_scalar(float(int(enemy["max_hp"])))
	var cap := int(ActorNumbers.native_scalar(target_max_hp*ratio))
	var point := Vector2(Vector2i(enemy["pos"]))
	var height := int(enemy["z"])
	orbs.append({"id":"frenzy_heal:%d"%enemy["id"],"pos":point,"z":height,
		"age_ms":0.0,"heal":mini(int(row[15]),cap)})
	game.spawn_effect("frenzy_create_ball",point,1,height)
	game.play_sound("FLENSE_SUCK")

func view_objects(game) -> Array:
	var result := []
	if orbs.is_empty():return result
	var player_pos: Vector2 = game.player["pos"]
	var player_z := float(game.player["z"])
	var player_height := 0.0
	for box: AABB in game.player_damage_boxes():
		player_height = maxf(player_height,box.end.z-player_z)
	for orb: Dictionary in orbs:
		var clock := float(orb["age_ms"])
		var age := clock-WAIT_MS
		if age < 0.0:continue
		var point: Vector2 = orb["pos"]
		var z := float(orb["z"])
		var fade := 1.0
		if age < RISE_MS:
			var t := age/RISE_MS
			point.x += int(lerpf(-11.0,-14.0,t))
			z += int(lerpf(62.0,71.0,t))
			fade = int(lerpf(100.0,255.0,t))/255.0
		else:
			var t := (age-RISE_MS)/FLIGHT_MS
			point.x = int(lerpf(point.x-14.0,player_pos.x,1.0-(1.0-t)*(1.0-t)))
			point.y = int(lerpf(point.y,player_pos.y,t))
			z = int(lerpf(z+71.0,player_z+floorf(player_height/2.0),t))
		for effect: String in ["frenzy_ball_layer","frenzy_ball"]:
			result.append({"id":orb["id"]+":"+effect,"effect":effect,"pos":point,"z":z,
				"clock":clock,"loop":true,"fade":fade,"facing":1,"depth_offset":3})
	return result
