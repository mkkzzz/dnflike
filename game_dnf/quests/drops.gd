extends RefCounted
## Eligibility only. Loot owns deterministic rolls and persisted death receipts.

static func entries(profile: Dictionary, run: Dictionary, event: Dictionary, definitions: Dictionary) -> Array:
	var result: Array=[]
	if event.get("run_id")!=run.get("id"):return result
	for id: String in definitions:
		var quest: Dictionary=definitions[id]
		if not quest.get("enabled",false) or profile.get("quest_state",{}).get("entries",{}).get(id,{}).get("state")!="active":continue
		for rule: Dictionary in quest.get("drops",[]):
			if rule["monster"]!=event.get("monster_id") or rule["dungeon"]!=run.get("dungeon") or run.get("difficulty") not in rule["difficulty"]:continue
			var owned:=0
			# Storage and locked stacks still count toward a unique quest-item cap.
			for stack: Dictionary in profile.get("item_state",{}).get("stacks",{}).values():
				if stack["id"]==rule["item"]:owned+=int(stack["count"])
			for drop: Dictionary in run.get("loot",{}).get("drops",{}).values():
				if not drop["claimed"] and drop["item"]==rule["item"]:owned+=int(drop["count"])
			var count:=mini(int(rule["amount"]),int(rule["limit"])-owned)
			if count>0:result.append({"id":rule["item"],"min":count,"max":count,"chance":rule["chance"],"quest":id})
	return result
