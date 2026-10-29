extends RefCounted
## Equipment instances; the inventory ledger owns locations, old counts support migration.
static var _upgrade_config: Dictionary={}
static func reinforcement_bonuses() -> Dictionary:
	if _upgrade_config.is_empty():_upgrade_config=JSON.parse_string(FileAccess.get_file_as_string("res://data/upgrades.json"))
	return _upgrade_config["reinforcement"]["bonuses"]

static func create(profile: Dictionary, definition: String, quality := 50, reinforce := 0) -> String:
	var uid := "gear_%d" % int(profile["next_gear"])
	profile["next_gear"] += 1
	var maximum:=int(JSON.parse_string(FileAccess.get_file_as_string("res://data/services.json"))["durability_max"])
	var definition_data: Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://data/numbers.json"))["equipment"].get(definition,{})
	maximum=maxi(1,int(definition_data.get("durability",maximum)))
	profile["gear"][uid] = {"definition":definition,"quality":clampi(quality,0,100),"reinforce":clampi(reinforce,0,30),"enchants":[],"durability_max":maximum,"durability":maximum,"wear_progress":0}
	return uid

static func normalize(profile: Dictionary, definitions: Dictionary, counts: Dictionary) -> void:
	if profile.has("item_state"):return # Instance ownership is managed by the inventory ledger.
	for key: String in definitions:
		if not counts.has(key):continue
		var matches: Array = []
		for uid: String in profile["gear"]:
			if profile["gear"][uid]["definition"] == key:matches.append(uid)
		while matches.size() < int(counts[key]):matches.append(create(profile,key))
		while matches.size() > int(counts[key]):
			var uid: String = matches.pop_back()
			profile["gear"].erase(uid)
			for slot: String in profile["equipment"]:
				if profile["equipment"][slot] == uid:profile["equipment"].erase(slot)
	var old := String(profile.get("equipped",""))
	var current: String = profile["equipment"].get("weapon","")
	if old == "":profile["equipment"].erase("weapon")
	elif current == "" or not profile["gear"].has(current) or profile["gear"][current]["definition"] != old:
		for uid: String in profile["gear"]:
			if profile["gear"][uid]["definition"] == old:
				profile["equipment"]["weapon"] = uid
				break

static func equip(profile: Dictionary, uid: String, config: Dictionary) -> Dictionary:
	if not profile["gear"].has(uid):return {"ok":false,"message":"装备不存在"}
	var definition: Dictionary = config["equipment"][profile["gear"][uid]["definition"]]
	if int(profile["level"]) < int(definition.get("required_level",1)):return {"ok":false,"message":"角色等级不足"}
	if definition.has("growtypes") and profile["growtype"] not in definition["growtypes"]:return {"ok":false,"message":"职业不符合穿戴要求"}
	if not usable(profile,definition):return {"ok":false,"message":"职业不符合穿戴要求"}
	profile["equipment"][definition["slot"]] = uid
	if definition["slot"] == "weapon":profile["equipped"] = profile["gear"][uid]["definition"]
	return {"ok":true}

static func modifiers(profile: Dictionary, config: Dictionary) -> Array:
	var result: Array = []
	var sets := {}
	for slot: String in profile["equipment"]:
		var instance: Dictionary = profile["gear"].get(profile["equipment"][slot],{})
		if instance.is_empty():continue
		if int(instance.get("durability",1))<=0:continue
		var definition: Dictionary = config["equipment"][instance["definition"]]
		# Lowering level does not delete owned gear; ineligible gear ceases to contribute.
		if int(profile["level"]) < int(definition.get("required_level",1)):continue
		if definition.has("growtypes") and profile["growtype"] not in definition["growtypes"]:continue
		if not usable(profile,definition):continue
		var scale := lerpf(float(config["formula"]["quality_min_scale"]),float(config["formula"]["quality_max_scale"]),float(instance["quality"])/100)
		for stat: String in definition.get("stats",{}):
			var value:=float(definition["stats"][stat])*scale
			if definition.get("stat_ranges",{}).has(stat):
				var bounds: Array=definition["stat_ranges"][stat]
				value=lerpf(float(bounds[0]),float(bounds[1]),float(instance["quality"])/100)
			result.append({"source":definition["name"]+" · 编号 "+String(profile["equipment"][slot]).trim_prefix("gear_"),"stat":stat,"op":"add","value":value})
		if slot == "weapon":
			for stat: String in ["physical_attack","magical_attack"]:result.append({"source":"武器强化","stat":stat,"op":"add","value":int(instance["reinforce"])*float(config["formula"]["reinforce_attack_per_level"])})
		else:
			var bonuses: Dictionary=reinforcement_bonuses().get(slot,{})
			for stat: String in bonuses:
				result.append({"source":"装备强化","stat":stat,"op":"add","value":int(instance["reinforce"])*float(bonuses[stat])})
		for mod: Dictionary in instance.get("enchants",[]):
			var entry := mod.duplicate(true)
			entry["source"] = "装备附魔"
			result.append(entry)
		if definition.has("set"):sets[definition["set"]] = int(sets.get(definition["set"],0))+1
	for key: String in config.get("sets",{}):
		for threshold: Dictionary in config["sets"][key]:
			if int(sets.get(key,0)) >= int(threshold["count"]):
				for mod: Dictionary in threshold["modifiers"]:
					var entry := mod.duplicate(true)
					entry["source"] = "套装 · "+key
					result.append(entry)
	return result

static func usable(profile: Dictionary, definition: Dictionary) -> bool:
	var jobs: Array=definition.get("usable_jobs",["[all]"])
	return "[all]" in jobs or ("[swordman]" in jobs and int(profile.get("job_index",0))==0)
