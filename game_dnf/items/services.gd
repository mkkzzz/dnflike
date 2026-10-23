extends RefCounted
## Pure service quotes/transactions. The flow commits a candidate before applying it.
const Inventory=preload("res://items/inventory.gd")
const Numbers=preload("res://stats/api/numbers.gd")
static func config() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string("res://data/services.json"))

static func initialize(p: Dictionary) -> void:
	if not p.has("services"):p["services"]={"revision":1,"next_sale":1,"buyback":[],"transactions":{}}
	for gear: Dictionary in p["gear"].values():
		if not gear.has("durability_max"):gear["durability_max"]=int(config()["durability_max"])
		if not gear.has("durability"):gear["durability"]=int(gear["durability_max"])
		if not gear.has("wear_progress"):gear["wear_progress"]=0

static func carried(p: Dictionary, uid: String) -> bool:
	for bag: Array in p["item_state"]["bags"].values():
		if uid!="" and uid in bag:return true
	return false

static func delete_entity(p: Dictionary, uid: String) -> void:
	p["gear"].erase(uid);p["item_state"]["stacks"].erase(uid)

static func repair_targets(p: Dictionary, uid: String, all_equipped: bool) -> Array:
	if all_equipped:return p["equipment"].values().duplicate()
	return [uid] if p["gear"].has(uid) and (carried(p,uid) or uid in p["equipment"].values()) else []

static func quote(p: Dictionary, kind: String, data: Dictionary) -> Dictionary:
	var cfg:=config();var uid:=String(data.get("uid",""))
	var result: Dictionary={"ok":true,"kind":kind,"uid":uid,"count":1,"price":0,"output":{},"targets":[]}
	match kind:
		"services.sell", "services.disassemble":
			if not carried(p,uid):return Inventory.fail("请选择背包物品；穿戴、仓库和待领取区的物品不能处理")
			if Inventory.locked(p,uid):return Inventory.fail("请先解锁物品")
			var id:=Inventory.definition(p,uid)
			if not cfg["items"].has(id):return Inventory.fail("该物品尚未配置服务规则")
			var amount=data.get("count",1)
			if not amount is int or amount<1 or amount>Inventory.count(p,uid):return Inventory.fail("处理数量无效")
			result["count"]=amount
			result["name"]=Inventory.Catalog.ITEMS[id]["name"]
			if kind=="services.sell":result["price"]=int(cfg["items"][id]["sell"])*amount
			else:
				if not p["gear"].has(uid) or not cfg["items"][id].has("disassemble"):return Inventory.fail("只能分解支持的装备")
				result["output"]=cfg["items"][id]["disassemble"].duplicate(true)
				for output: String in result["output"]:result["output"][output]=int(result["output"][output])
		"services.buyback":
			var entry: Dictionary={}
			for record: Dictionary in p["services"]["buyback"]:
				if record["id"]==data.get("sale"):entry=record;break
			if entry.is_empty():return Inventory.fail("该笔出售已回购或不在回购列表")
			uid=entry["uid"];result["uid"]=uid;result["sale"]=entry["id"]
			result["price"]=int(entry["price"]);result["count"]=Inventory.count(p,uid)
			result["name"]=Inventory.Catalog.ITEMS[Inventory.definition(p,uid)]["name"]
		"services.repair":
			var targets:=repair_targets(p,uid,bool(data.get("all",false)))
			for entry: String in targets:
				var gear: Dictionary=p["gear"][entry]
				var missing:=int(gear["durability_max"])-int(gear["durability"])
				if missing<=0:continue
				var rule: Dictionary=cfg["items"].get(gear["definition"],{})
				if not rule.has("repair_point"):return Inventory.fail("该装备尚未配置修理费用")
				result["price"]+=missing*int(rule["repair_point"])
				result["targets"].append(entry)
			if result["targets"].is_empty():return Inventory.fail("没有需要修理的装备")
			result["name"]="全部穿戴装备" if data.get("all",false) else Inventory.Catalog.ITEMS[Inventory.definition(p,uid)]["name"]
		_:return Inventory.fail("服务不存在")
	# A confirmation is tied to the exact entity and current durability/stack count.
	var fingerprint: Array=[result]
	for entry: String in result["targets"]:
		fingerprint.append(p["gear"][entry])
	if uid!="":fingerprint.append(p["gear"].get(uid,p["item_state"]["stacks"].get(uid,{})))
	result["signature"]=JSON.stringify(fingerprint).sha256_text()
	return result

static func command(p: Dictionary, kind: String, data: Dictionary) -> Dictionary:
	var tx=data.get("transaction","")
	if not tx is String or tx.is_empty() or tx.length()>160:return Inventory.fail("服务事务编号无效")
	if p["services"]["transactions"].has(tx):return Inventory.fail("这次操作已经提交，请勿重复确认")
	var q:=quote(p,kind,data)
	if not q["ok"]:return q
	if data.get("signature")!=q["signature"]:return Inventory.fail("物品或价格已变化，请重新确认")
	var candidate:=p.duplicate(true)
	var result:=apply_quote(candidate,q)
	if not result["ok"]:return result
	candidate["services"]["transactions"][tx]=true
	Inventory.sync(candidate);p.assign(candidate)
	return {"ok":true,"quote":q}

static func apply_quote(p: Dictionary, q: Dictionary) -> Dictionary:
	var uid: String=q["uid"];var state: Dictionary=p["services"]
	match q["kind"]:
		"services.sell":
			var sold:=uid
			var location:=Inventory.locate(p,uid)
			if int(q["count"])<Inventory.count(p,uid):
				sold=Inventory.new_stack(p,Inventory.definition(p,uid),int(q["count"]))
				p["item_state"]["stacks"][uid]["count"]-=int(q["count"])
			else:location[0][location[1]]=""
			state["buyback"].append({"id":"sale_%d" % int(state["next_sale"]),"uid":sold,"price":int(q["price"])})
			state["next_sale"]=int(state["next_sale"])+1
			while state["buyback"].size()>int(config()["buyback_limit"]):delete_entity(p,state["buyback"].pop_front()["uid"])
			p["gold"]+=int(q["price"])
		"services.buyback":
			if int(p["gold"])<int(q["price"]):return Inventory.fail("金币不足")
			if not Inventory.place(p,uid):return Inventory.fail("背包没有空格，请先整理或腾出位置")
			for i in state["buyback"].size():
				if state["buyback"][i]["id"]==q["sale"]:state["buyback"].remove_at(i);break
			p["gold"]-=int(q["price"])
		"services.disassemble":
			var location:=Inventory.locate(p,uid);location[0][location[1]]="";delete_entity(p,uid)
			for id: String in q["output"]:
				var result:=Inventory.give(p,id,int(q["output"][id]))
				if not result["ok"]:return result
		"services.repair":
			if int(p["gold"])<int(q["price"]):return Inventory.fail("金币不足")
			for entry: String in q["targets"]:p["gear"][entry]["durability"]=int(p["gear"][entry]["durability_max"])
			p["gold"]-=int(q["price"])
	return {"ok":true}

static func wear(p: Dictionary, run: Dictionary, event: Dictionary) -> Dictionary:
	if event.get("run_id")!=run.get("id") or event.get("type")!="combat.damage" or not event.has("event_id") or float(event.get("amount",0))<=0:return {"changed":false,"broken":false}
	var key:=str(event["event_id"])
	if not run.has("wear_seen"):run["wear_seen"]={}
	if run["wear_seen"].has(key):return {"changed":false,"broken":false}
	run["wear_seen"][key]=true
	var broken:=false;var changed:=false
	for slot: String in p["equipment"]:
		if (slot=="weapon")!=(event.get("victim")=="monster"):continue
		var gear: Dictionary=p["gear"][p["equipment"][slot]]
		if int(gear["durability"])<=0:continue
		gear["wear_progress"]=int(gear["wear_progress"])+1;changed=true
		var threshold:=int(config()["wear"]["weapon_hits" if slot=="weapon" else "armor_hits"])
		if int(gear["wear_progress"])>=threshold:
			gear["wear_progress"]=0;gear["durability"]=maxi(0,int(gear["durability"])-1)
			broken=broken or int(gear["durability"])==0
	return {"changed":changed,"broken":broken}

static func death_penalty(p: Dictionary) -> void:
	for uid: String in p["equipment"].values():p["gear"][uid]["durability"]=maxi(0,int(p["gear"][uid]["durability"])-int(config()["wear"]["death_loss"]))

static func valid(p: Dictionary) -> bool:
	var state=p.get("services")
	if not state is Dictionary or state.get("revision")!=1 or not state.get("buyback") is Array or state["buyback"].size()>1000 or not state.get("transactions") is Dictionary or not Numbers.whole(state.get("next_sale"),1,1000000000):return false
	var seen: Dictionary={};var max_sale:=0
	var ledger=p.get("item_state")
	if not state["buyback"].is_empty() and (not ledger is Dictionary or not ledger.get("stacks") is Dictionary):return false
	for gear: Dictionary in p["gear"].values():
		if not Numbers.whole(gear.get("durability_max"),1,100000) or not Numbers.whole(gear.get("durability"),0,int(gear["durability_max"])) or not Numbers.whole(gear.get("wear_progress"),0,1000000):return false
	for entry in state["buyback"]:
		if not entry is Dictionary or not entry.get("id") is String or not entry["id"].begins_with("sale_") or not entry["id"].trim_prefix("sale_").is_valid_int() or int(entry["id"].trim_prefix("sale_"))<1 or seen.has(entry["id"]):return false
		if not entry.get("uid") is String or not Numbers.whole(entry.get("price"),0,1000000000):return false
		if not p["gear"].has(entry["uid"]):
			var stack=ledger["stacks"].get(entry["uid"])
			if not stack is Dictionary or not Inventory.Catalog.ITEMS.has(stack.get("id","")):return false
		seen[entry["id"]]=true;max_sale=maxi(max_sale,int(entry["id"].trim_prefix("sale_")));entry["price"]=int(entry["price"])
	for tx in state["transactions"]:
		if not tx is String or tx.is_empty() or tx.length()>160 or not state["transactions"][tx] is bool or not state["transactions"][tx]:return false
	state["next_sale"]=int(state["next_sale"]);state["revision"]=1
	return int(state["next_sale"])>max_sale
