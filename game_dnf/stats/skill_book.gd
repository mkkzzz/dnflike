extends RefCounted
const Growth = preload("res://stats/progression.gd")

static func spent(profile: Dictionary) -> int:
	var result := 0
	for purchases: Array in profile["skill_purchases"].values():
		for cost in purchases:result += int(cost)
	return result

static func available(profile: Dictionary, config: Dictionary) -> int:
	return Growth.sp_total(profile,config["progression"])-spent(profile)

static func change(profile: Dictionary, id: String, delta: int, config: Dictionary, record: Dictionary = {}) -> Dictionary:
	if not config["skills"].has(id) or delta not in [-1,1]:return {"ok":false,"message":"技能或操作无效"}
	var definition: Dictionary = config["skills"][id]
	var rank := int(profile["skills"].get(id,0))
	var purchases: Array = profile["skill_purchases"].get(id,[])
	if delta < 0:
		if purchases.is_empty():return {"ok":false,"message":"初始赠送技能不可退点"}
		purchases.pop_back()
	else:
		if rank >= int(definition["max_level"]):return {"ok":false,"message":"技能已达上限"}
		if config["progression"]["enforce_skill_requirements"]:
			var caps: Array = record.get("growtype_max_level",[])
			var grow_index := int(config.get("growtype_index",{}).get(profile["growtype"],0))
			if not caps.is_empty() and (grow_index>=caps.size() or rank>=int(caps[grow_index])):return {"ok":false,"message":"该职业无法继续学习此技能"}
			var required := int(record.get("required_level",1))+rank*int(record.get("required_level_range",1))
			if int(profile["level"]) < required:return {"ok":false,"message":"角色等级不足"}
			if definition.has("growtypes") and profile["growtype"] not in definition["growtypes"]:return {"ok":false,"message":"职业不符合学习要求"}
			for parent: String in definition.get("requires",{}):
				if int(profile["skills"].get(parent,0)) < int(definition["requires"][parent]):return {"ok":false,"message":"前置技能不足"}
			var raw_pre: Array = record.get("pre_required_skill",[])
			for index in range(0,raw_pre.size()-1,2):
				var parent: String = config.get("skill_index",{}).get(str(int(raw_pre[index])),"")
				if parent=="" or int(profile["skills"].get(parent,0))<int(raw_pre[index+1]):return {"ok":false,"message":"前置技能不足或尚未接入"}
		var cost := int(definition.get("cost",0))
		if available(profile,config) < cost:return {"ok":false,"message":"SP 不足"}
		purchases.append(cost)
	profile["skill_purchases"][id] = purchases
	profile["skills"][id] = rank+delta
	return {"ok":true}

static func sample(record: Dictionary, rank: int) -> Dictionary:
	var context: Dictionary = record.get("dungeon",{})
	var info: Array = context.get("level_info",record.get("level_info",[]))
	var columns := int(info[0]) if not info.is_empty() else 0
	var rows := (info.size()-1)/columns if columns > 0 else 0
	var index := clampi(rank-1,0,maxi(0,rows-1))
	var result := {"level_row":info.slice(1+index*columns,1+(index+1)*columns) if columns > 0 else [],"static":context.get("static_data",record.get("static_data",[])),"rank":rank}
	# Endpoint interpolation is E-INFER; configurable per-skill overrides can replace it.
	for pair in [["consume_mp","mp"],["cool_time","cool_ms"],["casting_time","cast_ms"]]:
		var values: Array = context.get(pair[0],record.get(pair[0],[]))
		result[pair[1]] = 0.0 if values.is_empty() else float(values[0]) if values.size()==1 else lerpf(float(values[0]),float(values[-1]),float(index)/maxf(1,rows-1))
	return result
