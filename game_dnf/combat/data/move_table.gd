extends RefCounted
## Runtime combat tables (doc 29, F3~F5). Joins three sources and keeps their roles apart:
##   content pack (ContentDB.record/original) — original ANI/ATK/SKL/CHR/MOB/OBJ/PTL values;
##   data/combat.json (adapt layer)          — which original file each trial move links to,
##                                             unit scales and missing base tables;
##   assets_local/combat/manifest.json        — baked banks for presentation and borrowed ANIs.
const Timeline = preload("res://combat/action/timeline.gd")

const CHR_ANI := "character/swordman/animation/"

var db
var rules: Dictionary
var assets: Dictionary
var moves: Dictionary = {}
var monsters: Dictionary = {}
var objects: Dictionary = {}
var player: Dictionary = {}
var problems: Array = []
var _timelines: Dictionary = {}

func build(content_db, adapt_rules: Dictionary, combat_assets: Dictionary) -> bool:
	db = content_db
	rules = adapt_rules
	assets = combat_assets
	if not db.has_pack():
		problems.append("compiled content pack missing (python tools/compile_dnf_content.py)")
		return false
	_build_player()
	for name: String in rules["moves"]:moves[name] = _build_move(name,rules["moves"][name])
	for key: String in rules["monsters"]:monsters[key] = _build_monster(key,rules["monsters"][key])
	return problems.is_empty()

## Timeline of any original ANI by archive path (pack first, then borrowed raw ANIs).
func timeline(path: String) -> Array:
	path = path.to_lower()
	if _timelines.has(path):return _timelines[path]
	var tl: Array = []
	var rec: Dictionary = db.record(path)
	if not rec.is_empty():tl = rec["decoded"]["timeline"]
	elif assets.get("borrowed",{}).has(path):tl = Timeline.from_ani(assets["borrowed"][path])
	else:problems.append("ANI not found: "+path)
	_timelines[path] = tl
	return tl

func player_timeline(ani: String) -> Array:
	return timeline(CHR_ANI+ani+".ani")

func atk(path: String) -> Dictionary:
	if path == "":return {}
	var rec: Dictionary = db.record(path)
	if rec.is_empty():
		problems.append("ATK not found: "+path)
		return {}
	return rec["decoded"]

## First enum value of an ATK field, e.g. enum(atk,"damage_reaction") -> "[down]".
static func enum_value(decoded: Dictionary, key: String, fallback := "") -> String:
	var v = decoded.get(key)
	if v is Array and not v.is_empty() and v[0] is Dictionary:return String(v[0]["value"])
	return fallback

static func enum_args(decoded: Dictionary, key: String, index: int) -> Array:
	var v = decoded.get(key)
	if v is Array and v.size() > index and v[index] is Dictionary:return v[index]["args"]
	return []

func move_px(units: float) -> float:
	return units*float(rules["player"]["walk_speed"])/float(rules["units"]["move_speed_reference"])

func _build_player() -> void:
	var chr: Dictionary = db.record(String(rules["player"]["chr"])).get("decoded",{})
	var base: Dictionary = chr.get("stat_groups",{}).get("initial_value",{})
	player = {"hp_max":float(base.get("hp_max",0)),"mp_max":float(base.get("mp_max",0)),
		"jump_power":float(base.get("jump_power",0)),"hit_recovery":float(base.get("hit_recovery",500)),
		"move_speed":float(base.get("move_speed",850)),"weapon_wav":chr.get("weapon_wav",[]),
		"weapon_hit_info":chr.get("weapon_hit_info",[]),
		"motions":{"damage1":"damage1","damage2":"damage2","down":"down","overturn":"overturn"}}
	if player["hp_max"] <= 0:problems.append("CHR initial HP missing")

## Weapon row of CHR [weapon hit info]: [kind, blood, size, scale, x, y] per weapon subtype.
func weapon_hit_info(weapon: String) -> Array:
	var index := int(rules["player"]["weapon_index"].get(weapon,0))
	var flat: Array = player["weapon_hit_info"]
	if flat.size() < (index+1)*6:return ["[cut]","[blood]",100,1.0]
	return flat.slice(index*6,index*6+6)

## Weapon row of CHR [weapon wav]: [swing A, swing B, hit A, hit B].
func weapon_wav(weapon: String) -> Array:
	var index := int(rules["player"]["weapon_index"].get(weapon,0))
	var rows: Array = player["weapon_wav"]
	return rows[index] if index < rows.size() else []

func _skill_row(path: String) -> Dictionary:
	var rec: Dictionary = db.record(path)
	if rec.is_empty():
		problems.append("SKL not found: "+path)
		return {}
	var d: Dictionary = rec["decoded"]
	var dungeon: Dictionary = d.get("dungeon",{})
	var pick = func(key: String):return dungeon.get(key,d.get(key,[]))
	var info: Array = pick.call("level_info")
	var cols := int(info[0]) if not info.is_empty() else 0
	var mp: Array = pick.call("consume_mp")
	var cool: Array = pick.call("cool_time")
	var cast: Array = pick.call("casting_time")
	var static_data: Array = pick.call("static_data")
	# Level 1 = first column group and the first value of each [min, max] pair (E-INFER).
	return {"mp":float(mp[0]) if not mp.is_empty() else 0.0,"cool_ms":float(cool[0]) if not cool.is_empty() else 0.0,
		"cast_ms":float(cast[0]) if not cast.is_empty() else 0.0,"level_row":info.slice(1,1+cols) if cols > 0 else [],
		"static":static_data}

func _build_move(name: String, spec: Dictionary) -> Dictionary:
	var skill: Dictionary = _skill_row(String(spec["skill"])) if spec.has("skill") else {}
	var move := {"name":name,"label":String(spec.get("name","")),"mp":float(skill.get("mp",0)),
		"cool_ms":float(skill.get("cool_ms",0)),"cast_ms":float(skill.get("cast_ms",0)),"skill":String(spec.get("skill","")),
		"air":bool(spec.get("air",false)),"next":String(spec.get("next","")),"swing":int(spec.get("swing",-1)),
		"cast_fx":String(spec.get("cast_fx","")),"aura_fx":String(spec.get("aura_fx",""))}
	if spec.has("stages"):
		move["stages"] = []
		for stage: Dictionary in spec["stages"]:move["stages"].append(_build_stage(stage,skill))
		var dash: Dictionary = spec.get("dash",{})
		var stat: Array = skill.get("static",[])
		var units := float(stat[int(dash.get("speed_static",0))]) if stat.size() > int(dash.get("speed_static",0)) else 0.0
		move["dash"] = {"speed":move_px(units),"until":float(dash.get("until",0))}
		move.merge(move["stages"][0],false)
	else:
		move.merge(_build_stage(spec,skill),false)
	return move

func _build_stage(spec: Dictionary, skill: Dictionary) -> Dictionary:
	var ani := String(spec.get("ani",""))
	var body := player_timeline(ani) if ani != "" else []
	var default_atk := String(spec.get("atk",""))
	var hits: Array = []
	var row: Array = skill.get("level_row",[])
	for h: Dictionary in spec.get("hits",[]):
		var atk_path := String(h.get("atk",default_atk))
		var decoded := atk(atk_path)
		var percent := 100.0+float(decoded.get("damage_bonus",0))
		if h.has("percent_col") and row.size() > int(h["percent_col"]):percent = float(row[int(h["percent_col"])])
		var lift := -1.0
		if h.has("lift_col") and row.size() > int(h["lift_col"]):lift = float(row[int(h["lift_col"])])
		var hit := {"atk":decoded,"atk_path":atk_path,"percent":percent,"lift":lift,"skill":skill.size() > 0}
		if h.get("body",false):
			hit["kind"] = "boxes"
			hit["source"] = "body"
			hit["segments"] = Timeline.attack_segments(body)
		elif h.has("borrow"):
			hit["kind"] = "boxes"
			hit["source"] = "borrow:"+String(h["borrow"])
			hit["segments"] = Timeline.attack_segments(timeline(String(h["borrow"])))
		elif h.has("derived"):
			var box = assets.get("derived_boxes",{}).get(String(h["derived"]))
			if box == null:
				problems.append("derived box missing: "+String(h["derived"]))
				continue
			var w: Array = h["window"]
			hit["kind"] = "boxes"
			hit["source"] = "derived:"+String(h["derived"])
			hit["segments"] = [{"start":float(w[0]),"end":float(w[1]),"frames":[{"start":float(w[0]),"end":float(w[1]),"boxes":[box]}]}]
		elif h.has("object"):
			var obj := object(String(h["object"]))
			if obj.is_empty():continue
			hit["kind"] = "object"
			hit["object"] = String(h["object"])
			hit["at"] = float(h.get("at",0))
			hit["active_ms"] = float(h.get("active_ms",-1))
			var off: Array = h.get("offset",[0,0,0])
			hit["offset"] = Vector3(float(off[0]),float(off[1]),float(off[2]))
			if atk_path == "":
				hit["atk"] = obj["atk"]
				hit["atk_path"] = obj["atk_path"]
				if not h.has("percent_col"):hit["percent"] = 100.0+float(obj["atk"].get("damage_bonus",0))
		if hit.get("kind","") == "boxes" and hit["segments"].is_empty():
			problems.append("no attack boxes for "+ani+" ("+String(hit["source"])+")")
		hits.append(hit)
	var last := 0.0
	for hit: Dictionary in hits:
		if hit["kind"] == "boxes":last = maxf(last,Timeline.last_active_ms(hit["segments"]))
		else:last = maxf(last,float(hit["at"])+maxf(0,float(hit["active_ms"])))
	# Moves without hits (buffs) cannot be cancelled before their motion ends.
	if hits.is_empty():last = Timeline.duration(body)
	return {"ani":ani,"timeline":body,"duration":Timeline.duration(body),"hits":hits,"cancel_at":last,
		"fx":spec.get("fx",[]),"voice":String(spec.get("voice","")),"sounds":spec.get("sounds",[])}

## Passive object: motion timeline, attack info, particle motion and the render bank key.
func object(path: String) -> Dictionary:
	path = path.to_lower()
	if objects.has(path):return objects[path]
	var rec: Dictionary = db.record(path)
	if rec.is_empty():
		problems.append("OBJ not found: "+path)
		return {}
	var d: Dictionary = rec["decoded"]
	var motion := String(d.get("basic_motion",[""])[0])
	var atk_path := String(d.get("attack_infos",[""])[0])
	var bank := ""
	for key: String in assets.get("objects",{}):
		if String(assets["objects"][key]["source"]) == motion:bank = key
	var add_fx := ""
	var add: Array = d.get("add_object_effect",[])
	if not add.is_empty():
		var add_path := path.get_base_dir().path_join(String(add[0])).to_lower()
		for key: String in assets.get("effects",{}):
			if String(assets["effects"][key]["source"]) == add_path:add_fx = key
	var obj := {"path":path,"motion":motion,"timeline":timeline(motion),"atk":atk(atk_path),"atk_path":atk_path,
		"bank":bank,"add_fx":add_fx,"piercing":int(d.get("piercing_power",0)),"floating":float(d.get("floating_height",0))}
	obj["segments"] = Timeline.attack_segments(obj["timeline"])
	objects[path] = obj
	return obj

func _ability(mob: Dictionary, stat: String) -> float:
	var list: Array = mob.get("ability_category",[])
	for i in range(0,list.size()-2,3):
		if String(list[i]) == stat:return float(list[i+2])
	return 100.0

func _stem(paths) -> String:
	if not paths is Array or paths.is_empty() or String(paths[0]) == "":return ""
	return String(paths[0]).get_file().get_basename()

func _build_monster(key: String, spec: Dictionary) -> Dictionary:
	var path := String(spec["mob"])
	var mob: Dictionary = db.record(path).get("decoded",{})
	if mob.is_empty():
		problems.append("MOB not found: "+path)
		return {}
	var base: Dictionary = rules["monster_base"]
	var motion_dir := String(mob.get("waiting_motion",[""])[0]).get_base_dir()
	var m := {"key":key,"mob":path,"bank":String(spec.get("bank",key)),"dir":motion_dir,
		"hp":float(base["hp"])*_ability(mob,"[HP MAX]")/100.0,
		"attack":float(base["attack"])*_ability(mob,"[EQUIPMENT_PHYSICAL_ATTACK]")/100.0,
		"speed":move_px(float(mob.get("move_speed",[300])[0])),"sight":float(mob.get("sight",300)),
		"attack_delay":float(mob.get("attack_delay",1200)),"hit_recovery":float(mob.get("hit_recovery",[500])[0]),
		"keep_distance":float(spec.get("keep_distance",0)),
		"motions":{"stay":_stem(mob.get("waiting_motion")),"move":_stem(mob.get("move_motion")),
			"damage1":_stem(mob.get("damage_motion_1")),"damage2":_stem(mob.get("damage_motion_2")),
			"down":_stem(mob.get("down_motion")),"overturn":_stem(mob.get("overturn_motion")),
			"sit":_stem(mob.get("sit_motion")),"attack":_stem(mob.get("attack_motions"))}}
	m["attack_timeline"] = timeline(motion_dir.path_join(m["motions"]["attack"]+".ani"))
	m["attack_segments"] = Timeline.attack_segments(m["attack_timeline"])
	m["atk"] = atk(String(mob.get("attack_infos",[""])[0]))
	var throw: Dictionary = mob.get("throw_attack",{}) if mob.get("throw_attack") is Dictionary else {}
	if not throw.is_empty():
		var objects_index: Dictionary = db.index("passive_objects")
		var obj := object(String(objects_index.get(str(int(throw.get("passive_object_index",-1))),"")))
		var ptl_path := path.get_base_dir().path_join(String(throw.get("passive_object_filename",""))).to_lower()
		var ptl: Dictionary = db.record(ptl_path).get("decoded",{})
		var speed: Array = ptl.get("move_variable_1",[0])
		m["throw"] = {"object":obj,"frame":int(throw.get("throw_frame",0)),"sound":String(throw.get("throw_sound","")),
			"start":Vector3(float(throw.get("passive_object_start_x_cood",0)),float(throw.get("passive_object_start_y_cood",0)),
				float(throw.get("passive_object_start_z_cood",0))),
			"speed":float(speed[0]),"life_ms":float(ptl.get("life_time",1000))}
		if obj.is_empty() or ptl.is_empty():problems.append("throw object/particle missing for "+path)
		m["atk"] = obj.get("atk",{})
	return m

func monster_timeline(m: Dictionary, motion: String) -> Array:
	var stem := String(m["motions"].get(motion,motion))
	return timeline(String(m["dir"]).path_join(stem+".ani"))
