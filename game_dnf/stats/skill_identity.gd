extends RefCounted
## Local compatibility migration, not a rule in the original client.
## One source skill has one live rank; keep purchase history and refund duplicates.

static func canonical(id: String, config: Dictionary) -> String:
	return String(config.get("skill_aliases",{}).get(id,{}).get("id",id))

static func valid_record(rank, purchases, initial: int, maximum: int) -> bool:
	if not (rank is int or rank is float) or not is_finite(float(rank)) or float(rank)!=floorf(float(rank)):return false
	if rank<initial or rank>maximum or not purchases is Array or purchases.size()!=int(rank)-initial:return false
	for cost in purchases:
		if not (cost is int or cost is float) or not is_finite(float(cost)) or float(cost)!=floorf(float(cost)) or cost<0 or cost>1000000:return false
	return true

static func valid_history(history, config: Dictionary) -> bool:
	if not history is Array:return false
	for entry in history:
		if not entry is Dictionary or not config["skill_aliases"].has(entry.get("alias","")):return false
		var old: Dictionary = config["skill_aliases"][entry["alias"]]
		var id: String = old["id"]
		if entry.get("target")!=id or entry.get("kept") not in ["legacy","canonical"]:return false
		if not valid_record(entry.get("legacy_rank"),entry.get("legacy_purchases"),old["default"],old["max_level"]):return false
		if not valid_record(entry.get("canonical_rank"),entry.get("canonical_purchases"),int(config["skill_defaults"][id]),int(config["skills"][id]["max_level"])):return false
		var keep_legacy := int(entry["legacy_rank"])>int(entry["canonical_rank"])
		if entry["kept"]!=("legacy" if keep_legacy else "canonical"):return false
		var costs: Array = entry["canonical_purchases"] if keep_legacy else entry["legacy_purchases"]
		var refund := 0
		for cost in costs:refund+=int(cost)
		if entry.get("refunded_sp")!=refund:return false
	return true

static func migrate(profile: Dictionary, config: Dictionary) -> bool:
	if not valid_history(profile.get("skill_alias_history",[]),config):return false
	if not profile.get("skills") is Dictionary or not profile.get("skill_purchases") is Dictionary:return false
	var aliases: Dictionary = config.get("skill_aliases",{})
	var pending: Array = []
	for old: String in aliases:
		if profile["skills"].has(old) or profile["skill_purchases"].has(old):pending.append(old)
	if pending.is_empty():return true
	var ranks: Dictionary = profile["skills"].duplicate(true)
	var ledger: Dictionary = profile["skill_purchases"].duplicate(true)
	var history: Array = profile.get("skill_alias_history",[]).duplicate(true)
	for old: String in pending:
		var contract: Dictionary = aliases[old]
		var id: String = contract["id"]
		var old_rank = ranks.get(old,contract["default"])
		var rank = ranks.get(id,config["skill_defaults"][id])
		var old_costs = ledger.get(old,[])
		var costs = ledger.get(id,[])
		if int(contract["default"])!=int(config["skill_defaults"][id]):return false
		if not valid_record(old_rank,old_costs,contract["default"],contract["max_level"]):return false
		if not valid_record(rank,costs,int(config["skill_defaults"][id]),int(config["skills"][id]["max_level"])):return false
		if old_rank>int(config["skills"][id]["max_level"]):return false
		var keep_legacy: bool = old_rank>rank
		var refund := 0
		for cost in (costs if keep_legacy else old_costs):refund+=int(cost)
		history.append({"alias":old,"target":id,"legacy_rank":int(old_rank),"legacy_purchases":old_costs.duplicate(),
			"canonical_rank":int(rank),"canonical_purchases":costs.duplicate(),"kept":"legacy" if keep_legacy else "canonical","refunded_sp":refund})
		ranks[id] = int(old_rank if keep_legacy else rank)
		ledger[id] = (old_costs if keep_legacy else costs).duplicate()
		ranks.erase(old)
		ledger.erase(old)
	profile["skills"] = ranks
	profile["skill_purchases"] = ledger
	profile["skill_alias_history"] = history
	return true

static func canonicalize_history(profile: Dictionary) -> void:
	for entry: Dictionary in profile.get("skill_alias_history",[]):
		for key: String in ["legacy_rank","canonical_rank","refunded_sp"]:entry[key]=int(entry[key])
		for key: String in ["legacy_purchases","canonical_purchases"]:
			for j in entry[key].size():entry[key][j]=int(entry[key][j])
