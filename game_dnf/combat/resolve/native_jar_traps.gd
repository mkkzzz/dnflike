extends RefCounted
## DGN21 special OBJ771 trap rows and their selected child.
const DetRng = preload("res://core/det_rng.gd")
const Timeline = preload("res://combat/action/timeline.gd")
const HitJudge = preload("res://combat/hit/hit_judge.gd")
const ItemRestoration = preload("res://combat/item_restoration.gd")
const NativeEmitter = preload("res://combat/particles/native_emitter.gd")
const IDS := [40002,48003,2200,2210,2410]
const DIFFICULTIES := ["normal","adventure","expert","king"]
## 7FBD1C reads the native animation bounds of the long jar.
const WARNING_HEIGHT := 129.0
const INVINCIBILITY_MS := 15000.0
var clock_ms := 0.0
var actors: Array[Dictionary] = []
var player_protected := false
var protection_deadlines: Array[float] = []

func reset_clock() -> void:
	clock_ms = 0.0
	player_protected = false
	protection_deadlines.clear()

func advance_clock(game, ms: float) -> void:
	clock_ms += ms
	while not protection_deadlines.is_empty() and clock_ms >= protection_deadlines[0]:
		protection_deadlines.pop_front()
		if player_protected:
			player_protected = false
			game.bus.emit("combat.status",{"target":game.player["id"],"id":"jar_invincibility","change":"removed"})

static func rows(item: Dictionary) -> Array:
	var raw: Array = item.get("raw",[])
	if item.get("source_tag") != "[special passive object]" or raw.size() < 11 or raw[0] != 771:return []
	if raw.size() != 5+6*int(raw[4]):return []
	var result: Array = []
	for at in range(5,raw.size(),6):
		if raw[at] != "[trap]" or int(raw[at+1]) not in IDS or raw[at+4] <= 0:return []
		result.append(raw.slice(at+1,at+6))
	return result

## Ordinary dungeon props can mix [trap] with [item]/[monster] rows. Select
## only when every trap branch is one of the five verified source IDs.
static func candidate_rows(item: Dictionary) -> Array:
	var raw: Array = item.get("raw",[])
	if item.get("source_tag") != "[special passive object]" or raw.size() < 5:return []
	if raw.size() != 5+6*int(raw[4]):return []
	var result: Array = []
	for at in range(5,raw.size(),6):
		if raw[at] != "[trap]":continue
		if int(raw[at+1]) not in IDS or int(raw[at+4]) <= 0:return []
		result.append(raw.slice(at+1,at+6))
	return result

static func unresolved_ids(item: Dictionary) -> Array[int]:
	var raw: Array = item.get("raw",[])
	if item.get("source_tag") != "[special passive object]" or raw.size() < 11:return []
	var count := int(raw[4])
	if raw.size() != 5+6*count:return []
	var result: Array[int] = []
	for at in range(5,raw.size(),6):
		if raw[at] != "[trap]":continue
		var source_id := int(raw[at+1])
		if source_id not in IDS and source_id not in result:result.append(source_id)
	return result

## 7DD4DA..523 consumes rows in source order and stops at the first success.
static func select(children: Array, rolls) -> Dictionary:
	for row: Array in children:
		if rolls.range_int(0,0x7fffffff)%int(row[3]) < int(row[2]):
			return {"id":int(row[0]),"custom":int(row[1])}
	return {}

static func prepare(item: Dictionary, seed: int) -> Dictionary:
	return select(rows(item),DetRng.new(seed))

static func prepare_candidate(item: Dictionary, seed: int) -> Dictionary:
	return select(candidate_rows(item),DetRng.new(seed))

static func warning_index(difficulty: String) -> int:
	return maxi(0,DIFFICULTIES.find(difficulty))

static func delayed(id: int) -> bool:
	return id in [40002,48003]

static func ready(assets: Dictionary) -> bool:
	var spec: Dictionary = assets.get("native_jar_traps",{})
	var warning: Dictionary = spec.get("warning",{})
	if warning.get("duration_ms",[]).size() != 4 or warning.get("rate_percent",[]).size() != 4:return false
	if not has_bank(assets,String(warning.get("bank",""))):return false
	var poison_visual: Dictionary = assets.get("native_status_visuals",{}).get("poison",{})
	if not poison_visual.has_all(["particle","tint","z_offset","apply_sound","loop_items"]):return false
	if not has_sound(assets,String(poison_visual["apply_sound"])):return false
	for item: Dictionary in poison_visual["loop_items"]:
		if not has_sound(assets,String(item["sound"])):return false
	var effect_sources := {}
	for bank: Dictionary in assets.get("effects",{}).values():
		if bank.has("source"):effect_sources[bank["source"]] = bank.get("atlas",{}).get("texture","")
	for id: int in IDS:
		var child: Dictionary = spec.get("objects",{}).get(str(id),{})
		if child.get("attack_timeline",[]).is_empty():return false
		if id == 48003 and not child.get("poison",{}).has_all(["custom","chance_percent","duration_ms","total_damage","basis_level"]):return false
		var body := String(child.get("motion_bank",""))
		if not body.is_empty() and not has_bank(assets,body):return false
		for bank in child.get("extras",[])+child.get("destroy",[]):
			if not has_bank(assets,String(bank)):return false
		var paths: Array = child.get("particles",[]).duplicate()
		if id == 48003:paths.append(poison_visual["particle"])
		for path in paths:
			var particle: Dictionary = assets.get("particles",{}).get(path,{})
			var entries: Array = particle.get("decoded",{}).get("object_entries",[])
			if entries.is_empty():return false
			for entry: Dictionary in entries:
				if not ResourceLoader.exists(String(effect_sources.get(entry["path"],"")),"Texture2D"):return false
		for key in ["spawn_sound","hit_sound","consume_sound"]:
			var sound := String(child.get(key,""))
			if not sound.is_empty() and not has_sound(assets,sound):return false
	return true

static func has_bank(assets: Dictionary, key: String) -> bool:
	var bank: Dictionary = assets.get("effects",{}).get(key,{})
	var texture := String(bank.get("atlas",{}).get("texture",""))
	return not texture.is_empty() and ResourceLoader.exists(texture,"Texture2D")

static func has_sound(assets: Dictionary, key: String) -> bool:
	var clips: Array = assets.get("audio",{}).get(key,[])
	return clips.any(func(clip):return ResourceLoader.exists(String(clip.get("file","")),"AudioStream"))

## Delayed hazards keep the source pot visible until the warning expires.
func break_pot(game, prop: Dictionary) -> bool:
	var selection: Dictionary = prop.get("jar_trap",{})
	if selection.is_empty():return false
	if not delayed(selection["id"]):
		spawn(game,prop)
		return false
	var warning: Dictionary = game.combat_assets["native_jar_traps"]["warning"]
	var index := warning_index(game.numeric_difficulty)
	prop["jar_warning"] = {"start":clock_ms,"duration":float(warning["duration_ms"][index]),
		"rate":float(warning["rate_percent"][index])/100.0}
	prop["broken"] = false
	return true

func spawn(game, prop: Dictionary) -> void:
	var selection: Dictionary = prop["jar_trap"]
	var id: int = selection["id"]
	var definition: Dictionary = game.combat_assets["native_jar_traps"]["objects"][str(id)]
	# Traps read the inherited packet XYZ. The fairy explicitly replaces Z on its first update.
	var height := float(prop["z"]) if delayed(id) else float(definition["floating_height"])
	var actor := {"id":game._next_entity_id,"source_id":id,"custom":selection["custom"],"pos":prop["pos"],
		"z":height,"facing":prop["facing"],"started":clock_ms,"definition":definition,"touched":{}}
	game._next_entity_id += 1
	actors.append(actor)
	if id == 48003:
		var decoded: Dictionary = game.combat_assets["particles"][definition["particles"][0]]["decoded"]
		var emitter := NativeEmitter.new(decoded,func():return 0)
		actor["emission_ms"] = emitter.end_time(float(decoded["creation_frequency"]))
	for path: String in definition["particles"]:
		game.bus.emit("combat.cue",{"kind":"native_particle","path":path,"point":actor["pos"],
			"height":actor["z"],"mirrored":int(actor["facing"])<0})
	start_sound(game,actor)
	game.bus.emit("combat.jar_trap_spawned",{"object_index":id,"custom":actor["custom"],"position":actor["pos"],"height":actor["z"]})

func step(game) -> void:
	for prop: Dictionary in game.props:
		var warning: Dictionary = prop.get("jar_warning",{})
		if warning.is_empty() or clock_ms-float(warning["start"]) < float(warning["duration"]):continue
		prop.erase("jar_warning")
		spawn(game,prop)
		game.complete_prop_break(prop)
	if actors.is_empty():return
	if game.finished:return
	for i in range(actors.size()-1,-1,-1):
		var actor: Dictionary = actors[i]
		var age := clock_ms-float(actor["started"])
		var hazard := delayed(actor["source_id"])
		var definition: Dictionary = actor["definition"]
		if hazard and (age >= float(definition["attack_window_ms"]) or actor.get("emission_finished",false)):
			stop_sound(game,actor)
			actors.remove_at(i)
			continue
		if actor.has("emission_ms") and age >= float(actor["emission_ms"]):
			# B23996 observes the emitter's finished flag on the next actor update.
			actor["emission_finished"] = true
		var frame := Timeline.frame_at(definition["attack_timeline"],age,not hazard)
		var world := HitJudge.world_boxes(frame.get("attack_boxes",[]),HitJudge.anchor(actor["pos"],actor["z"]),actor["facing"])
		if hazard:
			# The source object has team 200. Players and ordinary monsters are both opposing teams.
			for target: Dictionary in game.friendly_targets():
				if not game.target_invulnerable(target):hazard_contact(game,actor,target,world,game.friendly_damage_boxes(target))
			for target: Dictionary in game.monsters:
				if float(target["hp"])>0.0 and not game.target_invulnerable(target):
					hazard_contact(game,actor,target,world,game.enemy_damage_boxes(target))
		elif float(game.player["hp"])>0.0 and not HitJudge.contact(world,game.player_damage_boxes()).is_empty():
			consume_fairy(game,actor)
			actors.remove_at(i)

func hazard_contact(game, actor: Dictionary, target: Dictionary, world: Array, target_boxes: Array) -> void:
	if actor["touched"].has(target["id"]):return
	var is_player: bool = target["id"] == game.player["id"]
	if is_player and game.god_mode:return
	var contact := HitJudge.contact(world,target_boxes)
	if contact.is_empty():return
	actor["touched"][target["id"]] = true
	var path: String = actor["definition"]["attack"]
	var atk: Dictionary = game.table.atk(path)
	if actor["source_id"] == 48003:
		game.land_hit(actor,target,{"kind":"object","atk":atk,"atk_path":path,"percent":0.0,
			"skill_id":"","contact_only":true,"damage_type":"magical","element":"dark","lift":-1.0},contact["point"],actor["facing"],0.0)
		var numbers = game.numeric_player if is_player else target.get("numeric")
		if numbers == null:return
		var first: bool = not numbers.effects.active.has("poison")
		if numbers.apply_environment_poison(actor["definition"]["poison"],game.rng.range_int(0,0x7fffffff)%10000):
			game.bus.emit("combat.status",{"target":target["id"],"id":"poison","change":"added"})
			var visual_info: Dictionary = game.combat_assets["native_status_visuals"]["poison"]
			game.play_sound(visual_info["apply_sound"])
			if first:
				for item: Dictionary in visual_info["loop_items"]:
					game.play_sound(item["sound"])
		return
	var power := float(actor["custom"])
	game.land_hit(actor,target,{"kind":"object","atk":atk,"atk_path":path,
		"percent":0.0 if game.numeric_player != null else 100.0,"fixed":power,
		"skill_id":"","damage_type":"magical","element":"fire","lift":-1.0},contact["point"],actor["facing"],power)

func consume_fairy(game, actor: Dictionary) -> void:
	var definition: Dictionary = actor["definition"]
	if actor["source_id"] == 2410:
		# A55C00 queues event variant 0x14 for 15000 ms on the recipient.
		player_protected = true
		protection_deadlines.append(clock_ms+INVINCIBILITY_MS)
		game.bus.emit("combat.status",{"target":game.player["id"],"id":"jar_invincibility","change":"added"})
	else:
		var hp := minf(floorf(game.max_hp/2.0),game.max_hp-float(game.player["hp"]))
		var mp := minf(floorf(game.max_mp/2.0),game.max_mp-float(game.player["mp"]))
		ItemRestoration.apply(game,{"kind":"restore","hp":hp,"mp":mp,"duration_ms":1000.0})
	stop_sound(game,actor)
	game.play_sound(definition["consume_sound"])
	# A58E36 skips the HeartDestroy layer for these source IDs.
	game.spawn_effect(definition["destroy"][0],actor["pos"],actor["facing"],actor["z"])
	game.bus.emit("combat.jar_fairy_consumed",{"object_index":actor["source_id"],"position":actor["pos"]})

func clear(game) -> void:
	for actor: Dictionary in actors:stop_sound(game,actor)
	actors.clear()

func snapshot() -> Array:
	return actors.duplicate()

func restore_room(game, saved: Array) -> void:
	actors.assign(saved)
	for actor: Dictionary in actors:start_sound(game,actor)

func start_sound(game, actor: Dictionary) -> void:
	var sound := String(actor["definition"]["spawn_sound"])
	if not sound.is_empty():
		game.bus.emit("combat.cue",{"kind":"sound","key":sound,"loop_id":actor["id"]})

func stop_sound(game, actor: Dictionary) -> void:
	if not String(actor["definition"]["spawn_sound"]).is_empty():
		game.bus.emit("combat.cue",{"kind":"sound","loop_id":actor["id"],"stop":true})

func view_objects(game) -> Array:
	var out: Array = []
	for prop: Dictionary in game.props:
		var progress: Dictionary = prop.get("jar_warning",{})
		if progress.is_empty():continue
		var warning: Dictionary = game.combat_assets["native_jar_traps"]["warning"]
		var view := visual(prop,"jar-warning:%d"%prop["node"],warning["bank"],(clock_ms-float(progress["start"]))*float(progress["rate"]),false)
		view["z"] += WARNING_HEIGHT
		out.append(view)
	for actor: Dictionary in actors:
		var definition: Dictionary = actor["definition"]
		if String(definition["motion_bank"]).is_empty():continue
		var age := clock_ms-float(actor["started"])
		out.append(visual(actor,"jar:%d"%actor["id"],definition["motion_bank"],age,true))
		# The original constructor attaches ETC slot 0 after the body, at the same anchor.
		out.append(visual(actor,"jar-light:%d"%actor["id"],definition["extras"][0],age,true))
	return out

static func visual(actor: Dictionary, id: String, bank: String, age: float, loop: bool) -> Dictionary:
	return {"id":id,"effect":bank,"pos":actor["pos"],"z":actor["z"],"facing":actor["facing"],"clock":age,"loop":loop}
