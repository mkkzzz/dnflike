extends RefCounted
## Public, UI-independent API. Formula constants are adaptation, not original claims.
const Growth = preload("res://stats/progression.gd")
const Attributes = preload("res://stats/attributes.gd")
const Equipment = preload("res://stats/equipment.gd")
const Skills = preload("res://stats/skill_book.gd")
const Effects = preload("res://stats/effects.gd")
const Damage = preload("res://stats/damage.gd")
const ContentDB = preload("res://content/api/content_db.gd")
static var _config: Dictionary = {}
static var _content_db

static func config() -> Dictionary:
	if _config.is_empty():_config = JSON.parse_string(FileAccess.get_file_as_string("res://data/numbers.json"))
	return _config.duplicate(true)

static func record(id: String) -> Dictionary:
	var cfg := config()
	var path: String = cfg["skills"].get(id,{}).get("path","")
	if path == "":return {}
	if _content_db == null:_content_db = ContentDB.new()
	return Dictionary(_content_db.record(path).get("decoded",{})).duplicate(true)

static func normalize(profile: Dictionary) -> void:
	var cfg := config()
	if not profile.has("numbers_revision"):
		profile.merge({"numbers_revision":1,"growtype":"swordman","sp_bonus":0,"skills":cfg["skill_defaults"].duplicate(true),"skill_purchases":{},"xp_transactions":{},"gear":{},"next_gear":1,"equipment":{},"stat_modifiers":[],"attack_element":"none"},false)
	if not profile.has("attack_element"):profile["attack_element"] = "none"
	Equipment.normalize(profile,cfg["equipment"],profile["inventory"])
	canonicalize(profile)

static func canonicalize(profile: Dictionary) -> void:
	for key in ["numbers_revision","sp_bonus","next_gear"]:profile[key] = int(profile[key])
	for id: String in profile["skills"]:profile["skills"][id] = int(profile["skills"][id])
	for purchases: Array in profile["skill_purchases"].values():
		for index in purchases.size():purchases[index] = int(purchases[index])
	for instance: Dictionary in profile["gear"].values():
		for key in ["durability","durability_max","wear_progress"]:
			if instance.has(key):instance[key]=int(instance[key])
		instance["quality"] = int(instance["quality"])
		instance["reinforce"] = int(instance["reinforce"])
		for mod: Dictionary in instance["enchants"]:mod["value"] = float(mod["value"])
	for mod: Dictionary in profile["stat_modifiers"]:mod["value"] = float(mod["value"])

static func profile_stats(profile: Dictionary, extra: Array = []) -> Dictionary:
	var cfg := config()
	var mods: Array = Equipment.modifiers(profile,cfg)
	mods.append_array(profile.get("stat_modifiers",[]))
	for id: String in profile["skills"]:
		for mod: Dictionary in cfg["skills"].get(id,{}).get("passive",[]):
			var entry := mod.duplicate(true)
			entry["value"] = float(mod["value"])*int(profile["skills"][id])
			entry["source"] = cfg["skills"][id]["name"]
			mods.append(entry)
	mods.append_array(extra)
	var result := Attributes.calculate(int(profile["level"]),String(profile["growtype"]),mods,cfg)
	result["modifiers"] = mods
	return result

static func gear_detail(profile: Dictionary, uid: String) -> Dictionary:
	var cfg := config()
	if not profile["gear"].has(uid):return {}
	var instance: Dictionary = profile["gear"][uid]
	var definition: Dictionary = cfg["equipment"][instance["definition"]]
	var view := profile.duplicate(true)
	view["equipment"] = {definition["slot"]:uid}
	var values := {}
	for mod: Dictionary in Equipment.modifiers(view,cfg):
		if mod.get("op","add")=="add":values[mod["stat"]] = float(values.get(mod["stat"],0))+float(mod["value"])
	return values

static func combat_spec(profile: Dictionary) -> Dictionary:
	var result := profile_stats(profile)
	var weapon := "katana"
	var uid: String = profile["equipment"].get("weapon","")
	if uid != "":weapon = String(config()["equipment"][profile["gear"][uid]["definition"]].get("weapon",weapon))
	var element: String = profile.get("attack_element","none")
	if uid!="":element = config()["equipment"][profile["gear"][uid]["definition"]].get("element",element)
	return {"numbers":result["values"],"number_sources":result["sources"],"number_seed":{"level":profile["level"],"growtype":profile["growtype"],"modifiers":result["modifiers"]},"skills":profile["skills"].duplicate(true),"weapon":weapon,"element":element,"hp_max":result["values"]["hp_max"],"mp_max":result["values"]["mp_max"]}

static func monster(base: Dictionary, level: int, chief: bool, difficulty: String, cfg: Dictionary = {}) -> Dictionary:
	if cfg.is_empty():cfg = config()
	var rules: Dictionary = cfg["monsters"]
	var factor := float(rules["difficulty"].get(difficulty,1))
	var stats: Dictionary = cfg["base"].duplicate(true)
	stats.merge({"level":level,"hp_max":float(base["hp"])*(1+(level-1)*float(rules["hp_per_level"]))*factor,"physical_attack":float(base["attack"])*(1+(level-1)*float(rules["attack_per_level"]))*factor,"magical_attack":float(base["attack"])*(1+(level-1)*float(rules["attack_per_level"]))*factor,"physical_defense":(level-1)*float(rules["defense_per_level"]),"magical_defense":(level-1)*float(rules["defense_per_level"]),"strength":0,"intelligence":0,"vitality":0,"spirit":0},true)
	stats["rank"] = "boss" if chief else "normal"
	stats["hit_recovery"] = float(base.get("hit_recovery",stats["hit_recovery"]))
	return stats

static func command(profile: Dictionary, kind: String, payload: Dictionary) -> Dictionary:
	var cfg := config()
	match kind:
		"numbers.xp":
			if not whole(payload.get("amount"),0,1000000000):return fail("经验数量无效")
			return Growth.grant(profile,int(payload["amount"]),String(payload.get("transaction","")),cfg["progression"])
		"numbers.level":
			if not whole(payload.get("level"),1,int(cfg["progression"]["level_cap"])):return fail("等级超出范围")
			var level := int(payload["level"])
			if Growth.sp_total({"level":level,"sp_bonus":profile["sp_bonus"]},cfg["progression"]) < Skills.spent(profile):return fail("请先退还技能点，再降低等级")
			profile["level"] = level
			profile["xp"] = 0
		"numbers.skill":
			return Skills.change(profile,String(payload.get("id","")),int(payload.get("delta",0)),cfg,record(String(payload.get("id",""))))
		"numbers.skill_reset":
			profile["skills"] = cfg["skill_defaults"].duplicate(true)
			profile["skill_purchases"] = {}
		"numbers.element":
			if payload.get("element") not in ["none","fire","water","light","dark"]:return fail("属性攻击无效")
			profile["attack_element"] = payload["element"]
		"numbers.growtype":
			if not cfg["growtypes"].has(payload.get("growtype","")):return fail("成长类型不存在")
			profile["growtype"] = payload["growtype"]
		"numbers.sp":
			if not whole(payload.get("amount"),0,1000000):return fail("SP 数量无效")
			if int(profile["sp_bonus"])+int(payload["amount"])>1000000:return fail("SP 已达调试上限")
			profile["sp_bonus"] += int(payload["amount"])
		"numbers.skill_grant":
			var id := String(payload.get("id",""))
			if not cfg["skills"].has(id):return fail("技能不存在")
			if not whole(payload.get("level"),int(cfg["skill_defaults"][id]),int(cfg["skills"][id]["max_level"])):return fail("技能等级超出范围")
			profile["skills"][id] = int(payload["level"])
			var entries: Array = []
			entries.resize(int(payload["level"])-int(cfg["skill_defaults"][id]))
			entries.fill(0)
			profile["skill_purchases"][id] = entries
		"numbers.gear_give":
			var id := String(payload.get("id",""))
			if not cfg["equipment"].has(id):return fail("装备定义不存在")
			if not whole(payload.get("quality",50),0,100):return fail("品质范围为 0 至 100")
			var uid := Equipment.create(profile,id,int(payload.get("quality",50)))
			if profile["inventory"].has(id) or id in ["iron_sword","forest_sword"]:profile["inventory"][id] = int(profile["inventory"].get(id,0))+1
			return {"ok":true,"uid":uid}
		"numbers.gear_equip":return Equipment.equip(profile,String(payload.get("uid","")),cfg)
		"numbers.gear_unequip":
			var slot := String(payload.get("slot",""))
			if slot not in cfg["equipment_slots"]:return fail("装备部位无效")
			profile["equipment"].erase(slot)
			if slot == "weapon":profile["equipped"] = ""
		"numbers.reinforce", "numbers.enchant":
			var uid := String(payload.get("uid",""))
			if not profile["gear"].has(uid):return fail("装备不存在")
			if kind == "numbers.reinforce":
				if not whole(payload.get("level"),0,30):return fail("强化范围为 0 至 30")
				profile["gear"][uid]["reinforce"] = int(payload["level"])
			else:
				var mod: Dictionary = payload.get("modifier",{})
				if not valid_modifier(mod,cfg):return fail("附魔属性无效")
				profile["gear"][uid]["enchants"] = [mod.duplicate(true)]
		"numbers.modifier":
			var mod: Dictionary = payload.get("modifier",{})
			if not valid_modifier(mod,cfg):return fail("属性修正无效")
			var remaining: Array = []
			for entry: Dictionary in profile["stat_modifiers"]:
				if entry["stat"] != mod["stat"]:remaining.append(entry)
			remaining.append(mod.duplicate(true))
			profile["stat_modifiers"] = remaining
		"numbers.modifier_clear":profile["stat_modifiers"] = []
		_:return fail("未知数值操作")
	return {"ok":true}

static func whole(value, minimum: int, maximum: int) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value)==floorf(float(value)) and float(value)>=minimum and float(value)<=maximum

static func valid_modifier(mod, cfg: Dictionary) -> bool:
	return mod is Dictionary and cfg["base"].has(mod.get("stat","")) and mod.get("op","add") in ["add","percent","mul"] and (mod.get("value") is int or mod.get("value") is float) and is_finite(float(mod["value"])) and absf(float(mod["value"])) <= 1000000 and (mod.get("op","add") != "mul" or float(mod["value"])>=0)

static func valid(profile: Dictionary) -> bool:
	var cfg := config()
	if not whole(profile.get("numbers_revision"),1,1) or not cfg["growtypes"].has(profile.get("growtype","")):return false
	if profile.get("attack_element","none") not in ["none","fire","water","light","dark"]:return false
	if not whole(profile.get("level"),1,int(cfg["progression"]["level_cap"])) or not whole(profile.get("xp"),0,1000000000) or not whole(profile.get("sp_bonus"),0,1000000) or not whole(profile.get("next_gear"),1,1000000000):return false
	for key in ["skills","skill_purchases","xp_transactions","gear","equipment"]:
		if not profile.get(key) is Dictionary:return false
	if not profile.get("stat_modifiers") is Array:return false
	for mod in profile["stat_modifiers"]:
		if not valid_modifier(mod,cfg):return false
	for id in cfg["skills"]:
		if not whole(profile["skills"].get(id),0,int(cfg["skills"][id]["max_level"])):return false
		var purchases = profile["skill_purchases"].get(id,[])
		if not purchases is Array or int(profile["skills"][id]) != int(cfg["skill_defaults"][id])+purchases.size():return false
		for cost in purchases:
			if not whole(cost,0,1000000):return false
	for id in profile["skills"]:
		if not cfg["skills"].has(id):return false
	for id in profile["skill_purchases"]:
		if not cfg["skills"].has(id):return false
	# A later balance revision may reduce the SP budget. Keep learned skills readable;
	# a negative available budget blocks further purchases until refunded/reset.
	for id in profile["xp_transactions"]:
		if not id is String or not profile["xp_transactions"][id] is bool:return false
	var max_serial := 0
	var counts := {}
	for uid in profile["gear"]:
		if not uid is String or not uid.begins_with("gear_") or not uid.trim_prefix("gear_").is_valid_int():return false
		max_serial = maxi(max_serial,int(uid.trim_prefix("gear_")))
		var gear = profile["gear"][uid]
		if not gear is Dictionary or not cfg["equipment"].has(gear.get("definition","")):return false
		if not whole(gear.get("quality"),0,100) or not whole(gear.get("reinforce"),0,30) or not gear.get("enchants") is Array:return false
		if gear.has("durability_max") and (not whole(gear["durability_max"],1,100000) or not whole(gear.get("durability"),0,int(gear["durability_max"])) or not whole(gear.get("wear_progress"),0,1000000)):return false
		for mod in gear["enchants"]:
			if not valid_modifier(mod,cfg):return false
		counts[gear["definition"]] = int(counts.get(gear["definition"],0))+1
	if int(profile["next_gear"]) <= max_serial:return false
	for id in ["iron_sword","forest_sword"]:
		if not profile.has("item_state") and int(counts.get(id,0)) != int(profile["inventory"].get(id,0)):return false
	for slot in profile["equipment"]:
		if slot not in cfg["equipment_slots"]:return false
		var uid = profile["equipment"][slot]
		if not uid is String or not profile["gear"].has(uid):return false
		if cfg["equipment"][profile["gear"][uid]["definition"]]["slot"] != slot:return false
	var weapon_uid: String = profile["equipment"].get("weapon","")
	if ("" if weapon_uid=="" else String(profile["gear"][weapon_uid]["definition"])) != profile["equipped"]:return false
	return true

static func fail(message: String) -> Dictionary:
	return {"ok":false,"message":message}
