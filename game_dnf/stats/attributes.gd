extends RefCounted
## Each source is evaluated from scratch; removal never subtracts rounded values.
static func calculate(level: int, growtype: String, modifiers: Array, config: Dictionary) -> Dictionary:
	var values: Dictionary = config["base"].duplicate(true)
	var sources: Dictionary = {}
	for stat: String in values:sources[stat] = [{"source":"角色基础","op":"base","value":values[stat]}]
	for stat: String in config["growth"]:
		var amount := float(config["growth"][stat]) * (level-1)
		values[stat] = float(values.get(stat,0)) + amount
		sources[stat].append({"source":"等级成长","op":"add","value":amount})
	for stat: String in config["growtypes"].get(growtype,{}):
		var amount := float(config["growtypes"][growtype][stat]) * (level-1)
		values[stat] = float(values.get(stat,0)) + amount
		sources[stat].append({"source":"成长类型","op":"add","value":amount})
	# Add flat values, then sum percentage additions, then multiply independent factors.
	for operation: String in ["add","percent","mul"]:
		var percentages := {}
		for mod: Dictionary in modifiers:
			var stat := String(mod.get("stat",""))
			if not values.has(stat) or mod.get("op","add") != operation:continue
			var amount := float(mod["value"])
			sources[stat].append(mod.duplicate(true))
			if operation == "add":values[stat] = float(values[stat])+amount
			elif operation == "mul":values[stat] = float(values[stat])*amount
			else:percentages[stat] = float(percentages.get(stat,0))+amount
		for stat: String in percentages:values[stat] = float(values[stat])*(1+float(percentages[stat]))
	var formula: Dictionary = config["formula"]
	for pair in [["physical_defense","vitality","defense_per_vitality"],["magical_defense","spirit","defense_per_spirit"]]:
		var contribution := float(values[pair[1]])*float(formula.get(pair[2],0))
		values[pair[0]] = float(values[pair[0]])+contribution
		sources[pair[0]].append({"source":pair[1],"op":"add","value":contribution})
	for pair in [["hp_max","vitality","vitality_divisor"],["mp_max","spirit","spirit_divisor"]]:
		var factor := maxf(0,1+float(values[pair[1]])/float(formula[pair[2]]))
		values[pair[0]] = float(values[pair[0]])*factor
		sources[pair[0]].append({"source":pair[1],"op":"mul","value":factor})
	for stat: String in config["limits"]:
		var limits: Array = config["limits"][stat]
		values[stat] = clampf(float(values[stat]),float(limits[0]),float(limits[1]))
	values["level"] = level
	values["physical_panel"] = float(values["physical_attack"])*maxf(0,1+float(values["strength"])/float(formula["main_stat_divisor"]))
	values["magical_panel"] = float(values["magical_attack"])*maxf(0,1+float(values["intelligence"])/float(formula["main_stat_divisor"]))
	return {"values":values,"sources":sources}
