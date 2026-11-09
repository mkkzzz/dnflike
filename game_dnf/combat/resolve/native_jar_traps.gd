extends RefCounted
## DGN21 special OBJ771 trap rows and their selected child.
const DetRng = preload("res://core/det_rng.gd")
const Timeline = preload("res://combat/action/timeline.gd")
const HitJudge = preload("res://combat/hit/hit_judge.gd")
const ItemRestoration = preload("res://combat/item_restoration.gd")
const IDS := [40002,48003,2200,2210,2410]
const ENABLED := [40002,2200,2210]
const DIFFICULTIES := ["normal","adventure","expert","king"]
## 7FBD1C reads the native animation bounds of the long jar.
const WARNING_HEIGHT := 129.0
var clock_ms := 0.0
var actors: Array[Dictionary] = []

static func rows(item: Dictionary) -> Array:
	var raw: Array = item.get("raw",[])
	if item.get("source_tag") != "[special passive object]" or raw.size() < 11 or raw[0] != 771:return []
	if raw.size() != 5+6*int(raw[4]):return []
	var result: Array = []
	for at in range(5,raw.size(),6):
		if raw[at] != "[trap]" or int(raw[at+1]) not in IDS or raw[at+4] <= 0:return []
		result.append(raw.slice(at+1,at+6))
	return result

## 7DD4DA..523 consumes rows in source order and stops at the first success.
static func select(children: Array, rolls) -> Dictionary:
	for row: Array in children:
		if rolls.range_int(0,0x7fffffff)%int(row[3]) < int(row[2]):
			return {"id":int(row[0]),"custom":int(row[1])}
	return {}

static func prepare(item: Dictionary, seed: int) -> Dictionary:
	return select(rows(item),DetRng.new(seed))

static func warning_index(difficulty: String) -> int:
	return maxi(0,DIFFICULTIES.find(difficulty))

static func delayed(id: int) -> bool:
	return id in [40002,48003]

static func ready(assets: Dictionary) -> bool:
	var spec: Dictionary = assets.get("native_jar_traps",{})
	var warning: Dictionary = spec.get("warning",{})
	if warning.get("duration_ms",[]).size() != 4 or warning.get("rate_percent",[]).size() != 4:return false
	if not has_bank(assets,String(warning.get("bank",""))):return false
	var effect_sources := {}
	for bank: Dictionary in assets.get("effects",{}).values():
		if bank.has("source"):effect_sources[bank["source"]] = bank.get("atlas",{}).get("texture","")
	for id: int in ENABLED:
		var child: Dictionary = spec.get("objects",{}).get(str(id),{})
		if child.get("attack_timeline",[]).is_empty():return false
		var body := String(child.get("motion_bank",""))
		if not body.is_empty() and not has_bank(assets,body):return false
		for bank in child.get("extras",[])+child.get("destroy",[]):
			if not has_bank(assets,String(bank)):return false
		for path in child.get("particles",[]):
			var particle: Dictionary = assets.get("particles",{}).get(path,{})
			var entries: Array = particle.get("decoded",{}).get("object_entries",[])
			if entries.is_empty():return false
			for entry: Dictionary in entries:
				if not ResourceLoader.exists(String(effect_sources.get(entry["path"],"")),"Texture2D"):return false
		for key in ["spawn_sound","hit_sound","consume_sound"]:
			var sound := String(child.get(key,""))
			if sound.is_empty():continue
			var clips: Array = assets.get("audio",{}).get(sound,[])
			if not clips.any(func(clip):return ResourceLoader.exists(String(clip.get("file","")),"AudioStream")):return false
	return true

static func has_bank(assets: Dictionary, key: String) -> bool:
	var bank: Dictionary = assets.get("effects",{}).get(key,{})
	var texture := String(bank.get("atlas",{}).get("texture",""))
	return not texture.is_empty() and ResourceLoader.exists(texture,"Texture2D")

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
	# Fire reads the inherited packet XYZ. The fairy explicitly replaces Z on its first update.
	var height := float(prop["z"]) if delayed(id) else float(definition["floating_height"])
	var actor := {"id":game._next_entity_id,"source_id":id,"custom":selection["custom"],"pos":prop["pos"],
		"z":height,"facing":prop["facing"],"started":clock_ms,"definition":definition,"touched":{}}
	game._next_entity_id += 1
	actors.append(actor)
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
		game.complete_native_prop_break(prop)
	if actors.is_empty():return
	if game.finished:return
	for i in range(actors.size()-1,-1,-1):
		var actor: Dictionary = actors[i]
		var age := clock_ms-float(actor["started"])
		var hazard := delayed(actor["source_id"])
		var definition: Dictionary = actor["definition"]
		if hazard and age >= float(definition["attack_window_ms"]):
			actors.remove_at(i)
			continue
		var frame := Timeline.frame_at(definition["attack_timeline"],age,not hazard)
		var world := HitJudge.world_boxes(frame.get("attack_boxes",[]),HitJudge.anchor(actor["pos"],actor["z"]),actor["facing"])
		if hazard:
			# The source object has team 200. Players and ordinary monsters are both opposing teams.
			for target: Dictionary in game.friendly_targets():
				if float(target.get("invuln_ms",0.0))<=0.0:fire_contact(game,actor,target,world,game.friendly_damage_boxes(target))
			for target: Dictionary in game.monsters:
				if float(target["hp"])>0.0:fire_contact(game,actor,target,world,game.enemy_damage_boxes(target))
		elif float(game.player["hp"])>0.0 and not HitJudge.contact(world,game.player_damage_boxes()).is_empty():
			consume_fairy(game,actor)
			actors.remove_at(i)

func fire_contact(game, actor: Dictionary, target: Dictionary, world: Array, target_boxes: Array) -> void:
	if actor["touched"].has(target["id"]):return
	var contact := HitJudge.contact(world,target_boxes)
	if contact.is_empty():return
	actor["touched"][target["id"]] = true
	var path: String = actor["definition"]["attack"]
	var atk: Dictionary = game.table.atk(path)
	var power := float(actor["custom"])
	game.land_hit(actor,target,{"kind":"object","atk":atk,"atk_path":path,
		"percent":0.0 if game.numeric_player != null else 100.0,"fixed":power,
		"skill_id":"","damage_type":"magical","element":"fire","lift":-1.0},contact["point"],actor["facing"],power)

func consume_fairy(game, actor: Dictionary) -> void:
	var definition: Dictionary = actor["definition"]
	var hp := minf(floorf(game.max_hp/2.0),game.max_hp-float(game.player["hp"]))
	var mp := minf(floorf(game.max_mp/2.0),game.max_mp-float(game.player["mp"]))
	ItemRestoration.apply(game,{"kind":"restore","hp":hp,"mp":mp,"duration_ms":1000.0})
	stop_sound(game,actor)
	game.play_sound(definition["consume_sound"])
	# A58E36 skips the HeartDestroy layer for these two source IDs.
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
