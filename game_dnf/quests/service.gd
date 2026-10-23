extends RefCounted
## Pure quest state and transactions. No scene, input, damage, save or numeric formula.
const Catalog = preload("res://quests/catalog.gd")
var catalog

func _init(definitions = null) -> void:
	catalog = definitions if definitions != null else Catalog.new()

func initialize(profile: Dictionary, migrate_legacy := false) -> void:
	if profile.has("quest_state"):return
	profile["quest_state"] = {"revision":1, "entries":{}, "transactions":{}, "tracked":[]}
	if migrate_legacy and profile.get("quest") in ["active", "ready", "done"]:
		var entry := new_entry(catalog.definitions["legacy.trial"])
		entry["progress"]["clear"] = 1 if profile["quest"] in ["ready", "done"] else 0
		if profile["quest"] == "done":
			entry["state"] = "completed"
			profile["quest_state"]["transactions"][transaction_id("legacy.trial")] = true
		profile["quest_state"]["entries"]["legacy.trial"] = entry

func new_entry(q: Dictionary) -> Dictionary:
	var progress := {}
	var seen := {}
	for o: Dictionary in q["objectives"]:
		progress[o["id"]] = 0
		seen[o["id"]] = {}
	return {"state":"active", "progress":progress, "seen":seen}

func canonicalize(profile: Dictionary) -> void:
	profile["quest_state"]["revision"]=1
	for entry: Dictionary in profile["quest_state"]["entries"].values():
		for key in entry["progress"]:entry["progress"][key]=int(entry["progress"][key])

func valid(profile: Dictionary) -> bool:
	if not catalog.errors.is_empty():return false
	var state = profile.get("quest_state")
	if not state is Dictionary or state.get("revision") != 1:return false
	for field in ["entries", "transactions"]:
		if not state.get(field) is Dictionary:return false
	if not state.get("tracked") is Array or state["tracked"].size() > int(catalog.config["limits"]["tracked"]):return false
	var seen := {}
	for id in state["tracked"]:
		if not id is String or seen.has(id) or not state["entries"].has(id):return false
		if not state["entries"][id] is Dictionary or state["entries"][id].get("state") != "active":return false
		seen[id] = true
	for key in state["transactions"]:
		if not key is String or not state["transactions"][key] is bool or not state["transactions"][key]:return false
	for id in state["entries"]:
		var entry = state["entries"][id]
		if not id is String or not entry is Dictionary or entry.get("state") not in ["active", "completed"]:return false
		if not entry.get("progress") is Dictionary or not entry.get("seen") is Dictionary:return false
		for key in entry["progress"]:
			if not key is String or not Catalog.whole(entry["progress"][key], 0, 1000000000):return false
		for key in entry["seen"]:
			if not key is String or not entry["seen"][key] is Dictionary or entry["seen"][key].size() > 1000000:return false
			for event_id in entry["seen"][key]:
				if not event_id is String or entry["seen"][key][event_id] != true:return false
		if entry["state"] == "completed" and not state["transactions"].has(transaction_id(id)):return false
		if entry["state"] == "active" and state["transactions"].has(transaction_id(id)):return false
		if catalog.definitions.has(id):
			for objective: Dictionary in catalog.definitions[id]["objectives"]:
				if not entry["progress"].has(objective["id"]) or not entry["seen"].has(objective["id"]):return false
				if int(entry["progress"][objective["id"]]) > int(objective["amount"]):return false
	return true

func status(profile: Dictionary, id: String) -> String:
	if not catalog.errors.is_empty() or not catalog.definitions.has(id):return "unavailable"
	var q: Dictionary = catalog.definitions[id]
	var entry: Dictionary = profile.get("quest_state", {}).get("entries", {}).get(id, {})
	if entry.get("state") == "completed":return "completed"
	if not q["enabled"]:return "locked"
	if not entry.is_empty():return "ready" if objectives_done(profile, q, entry) else "active"
	if int(profile.get("level", 1)) < int(q["min_level"]):return "locked"
	for required: String in q["requires"]:
		if status(profile, required) != "completed":return "locked"
	return "available"

func objective_count(profile: Dictionary, o: Dictionary, entry: Dictionary) -> int:
	if o["type"] == "collect_item":return mini(int(o["amount"]), stock(profile, o["target"]))
	return mini(int(o["amount"]), int(entry.get("progress", {}).get(o["id"], 0)))

func objectives_done(profile: Dictionary, q: Dictionary, entry: Dictionary) -> bool:
	for o: Dictionary in q["objectives"]:
		if objective_count(profile, o, entry) < int(o["amount"]):return false
	for item: String in q["consume"]:
		if stock(profile, item) < int(q["consume"][item]):return false
	return true

func list(profile: Dictionary, statuses: Array = [], npc := "") -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for id: String in catalog.definitions:
		var q: Dictionary = catalog.definitions[id]
		if q.get("legacy", false) and not profile.get("quest_state", {}).get("entries", {}).has(id):continue
		var state := status(profile, id)
		if not statuses.is_empty() and state not in statuses:continue
		if npc != "" and npc not in [q["giver"], q["receiver"]]:continue
		var view := q.duplicate(true)
		view["status"] = state
		view["tracked"] = id in profile.get("quest_state", {}).get("tracked", [])
		var entry: Dictionary = profile.get("quest_state", {}).get("entries", {}).get(id, {})
		for o: Dictionary in view["objectives"]:o["current"] = objective_count(profile, o, entry)
		result.append(view)
	return result

func command(profile: Dictionary, kind: String, payload: Dictionary, context: Dictionary, grant := Callable()) -> Dictionary:
	if not catalog.errors.is_empty():return fail("任务配置无效：" + catalog.errors[0])
	if not valid(profile):return fail("任务存档无效")
	var id = payload.get("id", "")
	if not id is String or not catalog.definitions.has(id):return fail("任务不存在")
	var q: Dictionary = catalog.definitions[id]
	var state := status(profile, id)
	var candidate := profile.duplicate(true)
	var ledger: Dictionary = candidate["quest_state"]
	if kind != "quest.track" and not context.get("in_town", false):return fail("请回城后处理任务")
	match kind:
		"quest.accept":
			if state != "available":return fail("任务尚不可接受")
			if not context.get("nearby", false) or context.get("npc") != q["giver"]:return fail("请到" + npc_name(q["giver"]) + "身旁接受任务")
			if active_count(profile) >= int(catalog.config["limits"]["active"]):return fail("进行中的任务已满")
			ledger["entries"][id] = new_entry(q)
			if ledger["tracked"].size() < int(catalog.config["limits"]["tracked"]):ledger["tracked"].append(id)
		"quest.track":
			if state not in ["active", "ready"]:return fail("只能追踪进行中的任务")
			if id in ledger["tracked"]:ledger["tracked"].erase(id)
			elif ledger["tracked"].size() >= int(catalog.config["limits"]["tracked"]):return fail("追踪任务已满，请先取消一项")
			else:ledger["tracked"].append(id)
		"quest.abandon":
			if not q["abandonable"] or state not in ["active", "ready"]:return fail("该任务不能放弃")
			ledger["entries"].erase(id)
			ledger["tracked"].erase(id)
		"quest.claim":
			if state != "ready":return fail("任务尚未完成或已交付")
			if not context.get("nearby", false) or context.get("npc") != q["receiver"]:return fail("请到" + npc_name(q["receiver"]) + "身旁交付任务")
			var tx := transaction_id(id)
			if ledger["transactions"].has(tx):return fail("任务奖励已经领取")
			var reward: Dictionary = q["reward"].duplicate(true)
			if not reward["choices"].is_empty():
				var chosen: Dictionary = {}
				for choice: Dictionary in reward["choices"]:
					if choice["id"] == payload.get("choice"):chosen = choice
				if chosen.is_empty():return fail("请选择一项任务奖励")
				reward["items"][chosen["item"]] = int(reward["items"].get(chosen["item"], 0)) + int(chosen["amount"])
			if not grant.is_valid():return fail("任务奖励服务未接入")
			for item: String in q["consume"]:candidate["inventory"][item] -= int(q["consume"][item])
			var outcome = grant.call(candidate, reward, tx)
			if not outcome is Dictionary or not outcome.get("ok", false):return fail(outcome.get("message", "任务奖励提交失败") if outcome is Dictionary else "任务奖励提交失败")
			ledger["entries"][id]["state"] = "completed"
			ledger["transactions"][tx] = true
			ledger["tracked"].erase(id)
		_:return fail("不支持的任务操作")
	if not valid(candidate):return fail("任务变更校验失败")
	profile.assign(candidate)
	return {"ok":true, "id":id, "kind":kind, "status":status(profile, id)}

func ingest(profile: Dictionary, event: Dictionary) -> Dictionary:
	if not valid(profile):return fail("任务存档无效")
	if event.get("type") not in ["npc.met", "combat.monster_defeated", "dungeon.cleared"] or not event.get("event_id") is String or event["event_id"].is_empty():return fail("任务事件无效")
	var changed: Array[String] = []
	for id: String in profile["quest_state"]["entries"]:
		if not catalog.definitions.has(id):continue
		var q: Dictionary = catalog.definitions[id]
		var entry: Dictionary = profile["quest_state"]["entries"][id]
		if entry["state"] != "active" or not q["enabled"]:continue
		for o: Dictionary in q["objectives"]:
			if o["type"] == "collect_item" or objective_count(profile, o, entry) >= int(o["amount"]):continue
			var matches: bool = (o["type"] == "meet_npc" and event["type"] == "npc.met" and event.get("npc") == o["target"]) or (o["type"] == "kill_monster" and event["type"] == "combat.monster_defeated" and event.get("monster_id") == o["target"]) or (o["type"] == "clear_dungeon" and event["type"] == "dungeon.cleared" and event.get("dungeon") == o["target"] and event.get("victory", false))
			if not matches or (o.has("dungeon") and event.get("dungeon") != o["dungeon"]) or (o.has("difficulty") and event.get("difficulty") not in o["difficulty"]):continue
			var seen: Dictionary = entry["seen"].get(o["id"], {})
			if seen.has(event["event_id"]):continue
			seen[event["event_id"]] = true
			entry["seen"][o["id"]] = seen
			entry["progress"][o["id"]] = int(entry["progress"].get(o["id"], 0)) + 1
			if id not in changed:changed.append(id)
	return {"ok":true, "changed":changed}

func active_count(profile: Dictionary) -> int:
	return list(profile, ["active", "ready"]).size()

func npc_name(id: String) -> String:
	return String(catalog.config["npcs"].get(id, id))

static func transaction_id(id: String) -> String:
	return "quest:" + id + ":once"

static func stock(profile: Dictionary, item: String) -> int:
	return maxi(0, int(profile.get("inventory", {}).get(item, 0)) - (1 if profile.get("equipped") == item else 0))

static func fail(message: String) -> Dictionary:
	return {"ok":false, "message":message}
