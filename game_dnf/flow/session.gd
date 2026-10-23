extends RefCounted
## Pure flow state. v1 rewards/items are E-ADAPT, never claimed as original balance.
const CATALOG := preload("res://items/catalog.gd")
const Numbers = preload("res://stats/api/numbers.gd")
const Layout = preload("res://items/slot_layout.gd")
const Quests = preload("res://quests/service.gd")
const TownWorld = preload("res://town/world.gd")
const Inventory = preload("res://items/inventory.gd")
const Loot = preload("res://loot/service.gd")
const Services=preload("res://items/services.gd")
var quests = Quests.new()
var town_world = TownWorld.new()
var dungeons: Dictionary = {}
var profile: Dictionary = {}
var state := "town"
var run: Dictionary = {}
var result: Dictionary = {}

func _init() -> void:
	profile = {"schema": 1, "name": "冒险家", "level": 1, "xp": 0, "gold": 300,
		"inventory": {"iron_sword": 1, "potion": 3}, "equipped": "iron_sword",
		"quest": "available", "clears": 0, "next_run": 1, "settled": {}}
	Layout.normalize(profile, CATALOG.ITEMS)
	Numbers.normalize(profile)
	Inventory.initialize(profile)
	Services.initialize(profile)
	quests.initialize(profile)
	profile["town_location"] = "seria_room"
	town_world.normalize(profile)
	dungeons = JSON.parse_string(FileAccess.get_file_as_string("res://data/dungeons.json"))["dungeons"]

func quest_command(kind: String, payload: Dictionary, context: Dictionary) -> Dictionary:
	context = context.duplicate()
	context["in_town"] = state == "town"
	var response: Dictionary=quests.command(profile,kind,payload,context,grant_quest_reward)
	if response.get("ok",false) and payload.get("id")=="legacy.trial":
		profile["quest"]={"active":"active","ready":"ready","completed":"done","available":"available"}.get(quests.status(profile,"legacy.trial"),"available")
	return response

func service_command(kind: String, payload: Dictionary, context: Dictionary) -> Dictionary:
	if state!="town":return reject("请回城后使用服务")
	var npc: String=context.get("npc","")
	var needed: String={"services.sell":"trade","services.buyback":"trade","services.repair":"repair","services.disassemble":"disassemble"}.get(kind,"")
	if needed=="" or not context.get("nearby",false) or needed not in town_world.data["npcs"].get(npc,{}).get("services",[]):return reject("请走到提供该服务的NPC身旁")
	return Services.command(profile,kind,payload)

func mirror_legacy() -> void:
	if profile["quest"] not in ["active","ready","done"]:return
	var entry: Dictionary=quests.new_entry(quests.catalog.definitions["legacy.trial"])
	entry["progress"]["clear"]=1 if profile["quest"] in ["ready","done"] else 0
	if profile["quest"]=="done":
		entry["state"]="completed"
		profile["quest_state"]["transactions"][Quests.transaction_id("legacy.trial")]=true
	profile["quest_state"]["entries"]["legacy.trial"]=entry

func grant_quest_reward(candidate: Dictionary, reward: Dictionary, tx: String) -> Dictionary:
	for item: String in reward["items"]:
		if not CATALOG.ITEMS.has(item):return reject("任务奖励物品尚未接入")
	var outcome: Dictionary = Numbers.Growth.grant(candidate,int(reward["xp"]),tx,Numbers.config()["progression"])
	if not outcome.get("ok",false):return outcome
	candidate["gold"] += int(reward["gold"])
	# Quest consumption is expressed through the old count view. Apply that delta
	# to unlocked backpack instances before awarding anything to the candidate.
	var requested: Dictionary=candidate["inventory"].duplicate(true)
	Inventory.sync(candidate)
	for item: String in requested:
		var used:=int(candidate["inventory"].get(item,0))-int(requested[item])
		if used>0:
			var consumed:=Inventory.consume(candidate,item,used)
			if not consumed["ok"]:return consumed
	for item: String in reward["items"]:
		var given:=Inventory.give(candidate,item,int(reward["items"][item]))
		if not given["ok"]:return given
	Numbers.normalize(candidate)
	Layout.normalize(candidate,CATALOG.ITEMS)
	return {"ok":true}

func dungeon_available(id: String) -> bool:
	if not dungeons.has(id):return false
	if int(profile["level"])<int(dungeons[id].get("min_level",1)):return false
	for required: String in dungeons[id]["requires"]:
		if quests.status(profile,required) != "completed":return false
	return true

func dungeon_choices(region: String) -> Array[String]:
	var choices: Array[String]=[]
	for id: String in dungeons:
		if not dungeons[id].get("legacy",false) and dungeons[id].get("region","lorien")==region:choices.append(id)
	return choices

func snapshot() -> Dictionary:
	return {"profile": profile.duplicate(true), "state": state, "run": run.duplicate(true),
		"result": result.duplicate(true), "stats": stats()}

func stats() -> Dictionary:
	Numbers.normalize(profile)
	var result: Dictionary = Numbers.combat_spec(profile)
	result["hp"] = result["hp_max"]
	result["mp"] = result["mp_max"]
	result["damage_multiplier"] = float(CATALOG.ITEMS.get(profile["equipped"], {"multiplier":0.8})["multiplier"])
	return result

func xp_needed() -> int:
	return Numbers.Growth.need(int(profile["level"]),Numbers.config()["progression"])

func command(kind: String, payload: Dictionary = {}) -> Dictionary:
	Numbers.normalize(profile)
	if kind in ["items.equip","items.unequip","items.split","items.sort","items.lock","items.deposit","items.withdraw","items.recover"]:
		if state!="town" and kind in ["items.equip","items.unequip","items.deposit","items.withdraw","items.recover"]:return reject("请回城后操作")
		return Inventory.command(profile,kind,payload)
	if kind=="numbers.gear_give":
		if not Numbers.config()["equipment"].has(payload.get("id","")):return reject("装备定义不存在")
		if not Numbers.whole(payload.get("quality",50),0,100):return reject("品质范围为 0 至 100")
		var serial:=int(profile["next_gear"])
		var response:=Inventory.give(profile,String(payload.get("id","")),1,int(payload.get("quality",50)))
		if response["ok"]:response["uid"]="gear_%d" % serial
		return response
	if kind in ["numbers.gear_equip","numbers.gear_unequip"]:
		if state!="town":return reject("请回城后调整装备")
		return Inventory.command(profile,"items.equip" if kind=="numbers.gear_equip" else "items.unequip",payload)
	if kind.begins_with("numbers."):
		if state != "town" and kind in ["numbers.gear_equip","numbers.gear_unequip","numbers.reinforce","numbers.enchant"]:return reject("请回城后调整装备")
		var response: Dictionary = Numbers.command(profile,kind,payload)
		Layout.normalize(profile,CATALOG.ITEMS)
		return response
	match kind:
		"flow.accept_quest":
			if state != "town" or profile["quest"] != "available":return reject("现在无法接受这个任务")
			profile["quest"] = "active"
			mirror_legacy()
		"flow.claim_quest":
			if state != "town" or profile["quest"] != "ready":return reject("先击败密林领主，再来找林纳斯")
			profile["quest"] = "done"
			profile["gold"] += 200
			add_item("forest_sword", 1)
			mirror_legacy()
		"items.buy":
			if state != "town":return reject("请回城后购买")
			var id := String(payload.get("id", ""))
			if not CATALOG.ITEMS.has(id) or not CATALOG.ITEMS[id].has("price"):return reject("商品不存在")
			var count = payload.get("count", 1)
			if not count is int or count < 1 or count > 999:return reject("购买数量无效")
			var price: int = int(CATALOG.ITEMS[id]["price"]) * int(count)
			if int(profile["gold"]) < price:return reject("金币不足")
			var given:=Inventory.give(profile,id,count)
			if not given["ok"]:return given
			profile["gold"] -= price
		"items.equip":
			if state != "town":return reject("请回城后更换装备")
			var id := String(payload.get("id", ""))
			if not CATALOG.ITEMS.has(id) or CATALOG.ITEMS[id].get("kind") != "weapon" or int(profile["inventory"].get(id, 0)) < 1:return reject("没有这件装备")
			if int(profile["level"]) < int(CATALOG.ITEMS[id].get("level",1)):return reject("角色等级不足")
			profile["equipped"] = id
			Numbers.normalize(profile)
			Layout.normalize(profile, CATALOG.ITEMS)
		"items.unequip":
			if state != "town":return reject("请回城后更换装备")
			profile["equipped"] = ""
			Numbers.normalize(profile)
			Layout.normalize(profile, CATALOG.ITEMS)
		"slots.move":
			if payload.get("source", {}).get("place") == "equipment" or payload.get("target", {}).get("place") == "equipment":
				if state != "town":return reject("请回城后更换装备")
			var source: Dictionary = payload.get("source",{})
			if payload.get("target",{}).get("place")=="equipment" and int(profile["level"]) < int(CATALOG.ITEMS.get(source.get("id",""),{}).get("level",1)):return reject("角色等级不足")
			if not Layout.move(profile, CATALOG.ITEMS, source, payload.get("target", {})):return reject("这里不能放置该物品或技能")
			Numbers.normalize(profile)
		"flow.difficulty":
			if state != "town" or payload.get("id") not in ["normal", "adventure", "king"]:return reject("难度无效")
			profile["difficulty"] = payload["id"]
		"flow.depart":
			if state != "town":return reject("已有进行中的冒险")
			var dungeon: String = String(payload.get("dungeon", "forest_trial"))
			if not dungeon_available(dungeon):return reject("地下城尚未开放，请先完成前置任务")
			run = {"id": "run_%d" % int(profile["next_run"]), "dungeon": dungeon, "difficulty":profile.get("difficulty", "normal"), "stats": stats()}
			profile["next_run"] += 1
			result = {}
			state = "battle"
		"flow.return":
			if state != "result":return reject("请先完成冒险")
			state = "town"
			run = {}
		"flow.retreat":
			if state != "battle":return reject("当前没有战斗")
			finish_run(false, {"reason": "retreat"})
		_:
			return reject("未知操作：" + kind)
	return {"ok": true}

func consume_potion() -> Dictionary:
	if state != "battle" or int(profile["inventory"].get("potion", 0)) < 1:return reject("没有可用的恢复药剂")
	var consumed:=Inventory.consume(profile,"potion",1)
	if not consumed["ok"]:return consumed
	return {"ok": true, "heal": int(CATALOG.ITEMS["potion"]["heal"])}

func add_item(id: String, count: int) -> void:
	# Guaranteed settlement rewards and legacy migration use recoverable overflow.
	Inventory.give(profile,id,count,50,true)

func combat_event(event: Dictionary) -> Dictionary:
	if state != "battle" or event.get("run_id") != run.get("id"):return reject("忽略过期战斗事件")
	match event.get("type", ""):
		"combat.player_defeated":
			Services.death_penalty(profile)
			return finish_run(false, event.get("stats", {}))
		"combat.monster_defeated":
			var loot_changed:=Loot.generate(run,event)
			var quest_changed := false
			if event.has("event_id"):
				var quest_event := event.duplicate(true)
				quest_event["event_id"] = String(run["id"])+":"+String(event.get("room_id",""))+":"+str(event["event_id"])
				quest_event["dungeon"] = run["dungeon"]
				quest_event["difficulty"] = run["difficulty"]
				var outcome: Dictionary=quests.ingest(profile,quest_event)
				quest_changed=outcome.get("ok",false) and not outcome["changed"].is_empty()
			var amount := int(Numbers.config()["progression"]["kill_xp"])
			if amount>0:
				var reward: Dictionary=Numbers.Growth.grant(profile,amount,"kill:"+String(run["id"])+":"+str(event.get("event_id",event.get("entity_id",-1))),Numbers.config()["progression"])
				reward["quest_changed"]=quest_changed
				reward["loot_changed"]=loot_changed
				return reward
			return {"ok":true,"quest_changed":quest_changed,"loot_changed":loot_changed}
		"combat.room_combat_finished":
			if bool(event.get("final_room", false)):return finish_run(true, event.get("stats", {}))
	return {"ok": true}

func finish_run(won: bool, details: Dictionary) -> Dictionary:
	var id := String(run.get("id", ""))
	if id.is_empty() or profile["settled"].has(id) or state != "battle":return reject("该冒险已结算")
	profile["settled"][id] = true
	result = {"run_id": id, "victory": won, "gold": 0, "xp": 0, "potion": 0, "stats": details.duplicate(true)}
	if won:
		quests.ingest(profile,{"type":"dungeon.cleared","event_id":"clear:"+id,"dungeon":run["dungeon"],"difficulty":run["difficulty"],"victory":true})
		result.merge({"gold": 150, "xp": int(Numbers.config()["progression"]["clear_xp"]), "potion": 1}, true)
		var damage := int(details.get("damage_taken", 0))
		result["rank"] = "S" if damage <= 50 else "A" if damage <= 250 else "B"
		profile["gold"] += 150
		Numbers.Growth.grant(profile,int(Numbers.config()["progression"]["clear_xp"]),"clear:"+id,Numbers.config()["progression"])
		profile["clears"] += 1
		add_item("potion", 1)
		if profile["quest"] == "active" and run["dungeon"]=="forest_trial":profile["quest"] = "ready";mirror_legacy()
	state = "result"
	return {"ok": true}

func serialize() -> Dictionary:
	return {"schema": "dnf_loop_save/4", "profile": profile.duplicate(true), "state": state,
		"run": run.duplicate(true), "result": result.duplicate(true)}

func restore(data: Dictionary) -> bool:
	if data.get("schema") not in ["dnf_loop_save/1","dnf_loop_save/2","dnf_loop_save/3","dnf_loop_save/4"] or not data.get("profile") is Dictionary:return false
	var p: Dictionary = data["profile"].duplicate(true)
	var legacy := not p.has("numbers_revision")
	for k: String in profile:
		if k in ["quest_state", "town_location", "item_state", "town_position", "inn_return", "services"]:continue
		if k in ["bag_layout", "quick_items", "skill_slots", "difficulty", "attack_element"]:continue
		if legacy and k in ["numbers_revision","growtype","sp_bonus","skills","skill_purchases","xp_transactions","gear","next_gear","equipment","stat_modifiers","attack_element"]:continue
		if not p.has(k) or typeof(p[k]) != typeof(profile[k]) and not (p[k] is float and profile[k] is int):return false
	if not p["inventory"] is Dictionary or not p["settled"] is Dictionary:return false
	if p["quest"] not in ["available", "active", "ready", "done"] or (p["equipped"] != "" and not CATALOG.ITEMS.has(p["equipped"])):return false
	if not Layout.valid(p, CATALOG.ITEMS):return false
	for id in p["inventory"]:
		if not CATALOG.ITEMS.has(id) or not (p["inventory"][id] is float or p["inventory"][id] is int) or float(p["inventory"][id]) < 0 or float(p["inventory"][id]) != floorf(float(p["inventory"][id])):return false
	for key in ["level", "gold", "xp", "clears", "next_run"]:
		if float(p[key]) < (1 if key in ["level", "next_run"] else 0) or float(p[key]) != floorf(float(p[key])):return false
	if p["equipped"] != "" and int(p["inventory"].get(p["equipped"], 0)) < 1:return false
	if not data.get("run", {}) is Dictionary or not data.get("result", {}) is Dictionary:return false
	if not Loot.valid(data.get("run",{})):return false
	for id in p["settled"]:
		if not id is String or not p["settled"][id] is bool or not p["settled"][id]:return false
	if data.get("state") == "result":
		var r: Dictionary = data["result"]
		if not r.get("stats") is Dictionary or not r.get("victory") is bool or not r.get("run_id") is String:return false
		if not p["settled"].has(r["run_id"]) or data["run"].get("id") != r["run_id"]:return false
		for key in ["gold", "xp", "potion"]:
			if not (r.get(key) is int or r.get(key) is float) or float(r[key]) < 0:return false
	if legacy:Numbers.normalize(p)
	if not p.has("attack_element"):p["attack_element"] = "none"
	if not Numbers.valid(p):return false
	if not p.has("services"):Services.initialize(p)
	if not Services.valid(p):return false
	if p.has("item_state"):
		if not Inventory.valid(p):return false
	else:Inventory.initialize(p)
	quests.initialize(p,true)
	if not quests.valid(p):return false
	quests.canonicalize(p)
	if not p.has("town_location"):p["town_location"]="elvengard"
	if not town_world.errors.is_empty():return false
	town_world.normalize(p)
	Numbers.canonicalize(p)
	profile = p.duplicate(true)
	Layout.normalize(profile, CATALOG.ITEMS)
	for key in ["schema", "level", "gold", "xp", "clears", "next_run"]:profile[key] = int(profile[key])
	for id in profile["inventory"]:profile["inventory"][id] = int(profile["inventory"][id])
	state = "result" if data.get("state") == "result" else "town"
	run = data.get("run", {}).duplicate(true) if state == "result" else {}
	result = data.get("result", {}).duplicate(true) if state == "result" else {}
	# Interrupted battles return safely to town without reward; run serial is kept.
	return true

static func reject(message: String) -> Dictionary:
	return {"ok": false, "message": message}
