extends RefCounted
## Authoritative ownership ledger. Legacy counts/layout are derived views only.
const Catalog = preload("res://items/catalog.gd")
const Numbers = preload("res://stats/api/numbers.gd")
const KINDS := ["weapon", "consumable", "material", "profession", "quest"]
const CAPACITY := 48
const STACK_LIMIT := 99

static func definition(p: Dictionary, uid: String) -> String:
	if p["gear"].has(uid):return p["gear"][uid]["definition"]
	return String(p["item_state"]["stacks"].get(uid,{}).get("id",""))

static func count(p: Dictionary, uid: String) -> int:
	return 1 if p["gear"].has(uid) else int(p["item_state"]["stacks"].get(uid,{}).get("count",0))

static func locked(p: Dictionary, uid: String) -> bool:
	return bool(p["gear"].get(uid,p["item_state"]["stacks"].get(uid,{})).get("locked",false))

static func cells() -> Array:
	var result: Array = [];result.resize(CAPACITY);result.fill("");return result

static func initialize(p: Dictionary) -> void:
	if p.has("item_state"):return
	Numbers.normalize(p)
	var old: Dictionary = p["inventory"].duplicate(true)
	p["item_state"] = {"revision":1,"next_stack":1,"stacks":{},"bags":{},"storage":cells(),"overflow":[]}
	for kind: String in KINDS:p["item_state"]["bags"][kind] = cells()
	for uid: String in p["gear"]:
		if uid not in p["equipment"].values():place(p,uid,true)
	for id: String in old:
		if not Numbers.config()["equipment"].has(id):
			var remaining := int(old[id])
			while remaining > 0:
				var amount := mini(remaining,STACK_LIMIT)
				place(p,new_stack(p,id,amount),true);remaining -= amount
	# Preserve the first old cell for each definition, then fit additional instances.
	for kind: String in KINDS:
		var pending: Array = p["item_state"]["bags"][kind].filter(func(uid):return uid != "")
		var arranged := cells()
		var legacy: Array = p.get("bag_layout",{}).get(kind,[])
		for index in mini(legacy.size(),CAPACITY):
			for uid: String in pending:
				if definition(p,uid) == legacy[index]:arranged[index]=uid;pending.erase(uid);break
		for uid: String in pending:arranged[arranged.find("")]=uid
		p["item_state"]["bags"][kind]=arranged
	sync(p)

static func new_stack(p: Dictionary, id: String, amount: int) -> String:
	var ledger: Dictionary = p["item_state"]
	var uid := "stack_%d" % int(ledger["next_stack"])
	ledger["next_stack"] = int(ledger["next_stack"])+1
	ledger["stacks"][uid] = {"id":id,"count":amount,"locked":false}
	return uid

static func place(p: Dictionary, uid: String, recovery := false) -> bool:
	var kind: String = Catalog.ITEMS[definition(p,uid)]["kind"]
	var bag: Array = p["item_state"]["bags"][kind]
	var index := bag.find("")
	if index >= 0:bag[index]=uid;return true
	if recovery:p["item_state"]["overflow"].append(uid);return true
	return false

static func sync(p: Dictionary) -> void:
	var totals := {};var layout := {}
	for id: String in Catalog.ITEMS:totals[id]=0
	for kind: String in KINDS:
		layout[kind]=[]
		for uid: String in p["item_state"]["bags"][kind]:
			var id := definition(p,uid) if uid != "" else ""
			layout[kind].append(id)
			if id != "":totals[id]=int(totals.get(id,0))+count(p,uid)
	for uid: String in p["equipment"].values():
		var id := definition(p,uid);totals[id]=int(totals.get(id,0))+1
	p["inventory"]=totals;p["bag_layout"]=layout
	p["equipped"] = definition(p,p["equipment"].get("weapon",""))

static func stock(p: Dictionary, id: String) -> int:
	if not Catalog.ITEMS.has(id):return 0
	var total := 0
	for uid: String in p["item_state"]["bags"][Catalog.ITEMS[id]["kind"]]:
		if uid != "" and definition(p,uid)==id and not locked(p,uid):total += count(p,uid)
	return total

static func give(p: Dictionary, id: String, amount: int, quality := 50, recovery := false) -> Dictionary:
	if not Catalog.ITEMS.has(id) or amount < 1 or amount > 100000:return fail("物品或数量无效")
	var candidate := p.duplicate(true)
	if Numbers.config()["equipment"].has(id):
		for i in amount:
			var uid := Numbers.Equipment.create(candidate,id,quality)
			if not place(candidate,uid,recovery):return fail("装备背包已满")
	else:
		var remaining := amount
		for uid: String in candidate["item_state"]["bags"][Catalog.ITEMS[id]["kind"]]:
			if uid == "" or definition(candidate,uid)!=id or locked(candidate,uid):continue
			var added := mini(remaining,STACK_LIMIT-count(candidate,uid))
			candidate["item_state"]["stacks"][uid]["count"] += added;remaining -= added
			if remaining == 0:break
		while remaining > 0:
			var added := mini(remaining,STACK_LIMIT)
			if not place(candidate,new_stack(candidate,id,added),recovery):return fail("物品背包已满")
			remaining -= added
	sync(candidate);p.assign(candidate);return {"ok":true}

static func consume(p: Dictionary, id: String, amount: int) -> Dictionary:
	if not Catalog.ITEMS.has(id) or amount < 1 or stock(p,id)<amount:return fail("可用物品不足（已锁定或已存仓的物品不能消耗）")
	var bag: Array = p["item_state"]["bags"][Catalog.ITEMS[id]["kind"]]
	for index in bag.size():
		var uid: String = bag[index]
		if uid=="" or definition(p,uid)!=id or locked(p,uid):continue
		var used := mini(amount,count(p,uid));amount-=used
		if used==count(p,uid):
			bag[index]="";p["gear"].erase(uid);p["item_state"]["stacks"].erase(uid)
		else:p["item_state"]["stacks"][uid]["count"]-=used
		if amount==0:break
	sync(p);return {"ok":true}

static func locate(p: Dictionary, uid: String) -> Array:
	for kind: String in KINDS:
		var bag: Array = p["item_state"]["bags"][kind]
		if uid in bag:return [bag,bag.find(uid)]
	for key in ["storage","overflow"]:
		var bag: Array = p["item_state"][key]
		if uid in bag:return [bag,bag.find(uid)]
	return []

static func equip(p: Dictionary, uid: String) -> Dictionary:
	var location := locate(p,uid)
	if not p["gear"].has(uid) or location.is_empty() or uid not in p["item_state"]["bags"]["weapon"]:return fail("请从装备背包选择装备")
	var slot: String = Numbers.config()["equipment"][definition(p,uid)]["slot"]
	var old: String = p["equipment"].get(slot,"")
	var response: Dictionary = Numbers.Equipment.equip(p,uid,Numbers.config())
	if not response["ok"]:return response
	location[0][location[1]]=old
	sync(p);return {"ok":true}

static func unequip(p: Dictionary, slot: String, index := -1) -> Dictionary:
	var uid: String = p["equipment"].get(slot,"")
	if uid=="":return fail("该部位没有装备")
	var bag: Array = p["item_state"]["bags"]["weapon"]
	if index<0:index=bag.find("")
	if index not in range(CAPACITY) or bag[index]!="":return fail("装备背包已满")
	bag[index]=uid;p["equipment"].erase(slot);sync(p);return {"ok":true}

static func command(p: Dictionary, kind: String, data: Dictionary) -> Dictionary:
	var candidate := p.duplicate(true)
	var response := operate(candidate,kind,data)
	if response.get("ok",false):sync(candidate);p.assign(candidate)
	return response

static func move(p: Dictionary, source: Dictionary, target: Dictionary) -> bool:
	var candidate:=p.duplicate(true)
	if not move_inside(candidate,source,target):return false
	sync(candidate);p.assign(candidate);return true

static func move_inside(p: Dictionary, source: Dictionary, target: Dictionary) -> bool:
	var from: String=source.get("place","");var to: String=target.get("place","")
	var index:=int(target.get("index",-1));var old:=int(source.get("index",-1))
	var id: String=source.get("id","")
	if from=="skill" and to=="skill" and old in range(6) and index in range(6) and p["skill_slots"][old]==id:
		p["skill_slots"][old]=p["skill_slots"][index];p["skill_slots"][index]=id;return true
	if not Catalog.ITEMS.has(id):return false
	var uid: String=source.get("uid","")
	if from=="bag":
		var bag: Array=p["item_state"]["bags"].get(source.get("category",""),[])
		if old not in range(bag.size()) or bag[old]=="" or definition(p,bag[old])!=id:return false
		if uid!="" and uid!=bag[old]:return false
		uid=bag[old]
	elif from=="equipment":
		uid=p["equipment"].get(source.get("slot","weapon"),"")
		if uid=="" or definition(p,uid)!=id:return false
	elif from=="quick":
		if old not in range(6) or p["quick_items"][old]!=id:return false
	else:return false
	if to=="quick" and index in range(6) and Catalog.ITEMS[id]["kind"]=="consumable":
		if from=="quick":p["quick_items"][old]=p["quick_items"][index]
		p["quick_items"][index]=id;return true
	if to=="equipment" and from=="bag":
		if not p["gear"].has(uid) or Numbers.config()["equipment"][id]["slot"]!=target.get("slot","weapon"):return false
		return equip(p,uid)["ok"]
	var category: String=target.get("category","")
	if to!="bag" or category!=Catalog.ITEMS[id]["kind"] or index not in range(CAPACITY):return false
	var bag: Array=p["item_state"]["bags"][category]
	if from=="equipment":
		var other: String=bag[index]
		if other=="":return unequip(p,String(source.get("slot","weapon")),index)["ok"]
		if Numbers.config()["equipment"][definition(p,other)]["slot"]!=source.get("slot","weapon"):return false
		return equip(p,other)["ok"]
	if from=="quick":
		for entry in bag:
			if entry!="" and definition(p,entry)==id:uid=entry;old=bag.find(entry);break
		if uid=="":return false
		p["quick_items"][int(source["index"]) ]=""
	if old==index:return true
	var other: String=bag[index]
	if other!="" and not p["gear"].has(uid) and definition(p,other)==id and not locked(p,uid) and not locked(p,other):
		var amount:=mini(STACK_LIMIT-count(p,other),count(p,uid))
		p["item_state"]["stacks"][other]["count"]+=amount;p["item_state"]["stacks"][uid]["count"]-=amount
		if count(p,uid)==0:p["item_state"]["stacks"].erase(uid);bag[old]=""
	else:bag[old]=other;bag[index]=uid
	return true

static func operate(p: Dictionary, kind: String, data: Dictionary) -> Dictionary:
	var uid := String(data.get("uid",""))
	match kind:
		"items.equip":
			if uid=="":
				for entry: String in p["item_state"]["bags"]["weapon"]:
					if entry!="" and definition(p,entry)==data.get("id"):uid=entry;break
			return equip(p,uid)
		"items.unequip":return unequip(p,String(data.get("slot","weapon")))
		"items.sort":
			for category: String in KINDS:
				var bag: Array=p["item_state"]["bags"][category]
				# Merge unlocked stacks without changing locked cells or their identity.
				for i in bag.size():
					if bag[i]=="" or locked(p,bag[i]) or p["gear"].has(bag[i]):continue
					for j in range(i+1,bag.size()):
						if bag[j]=="" or locked(p,bag[j]) or definition(p,bag[i])!=definition(p,bag[j]):continue
						var moved:=mini(STACK_LIMIT-count(p,bag[i]),count(p,bag[j]))
						p["item_state"]["stacks"][bag[i]]["count"]+=moved
						p["item_state"]["stacks"][bag[j]]["count"]-=moved
						if count(p,bag[j])==0:p["item_state"]["stacks"].erase(bag[j]);bag[j]=""
				var ordered: Array=bag.filter(func(entry):return entry!="" and not locked(p,entry))
				ordered.sort_custom(func(a,b):return (definition(p,a)+a).naturalnocasecmp_to(definition(p,b)+b)<0)
				for i in bag.size():
					if bag[i]!="" and locked(p,bag[i]):continue
					bag[i]="" if ordered.is_empty() else ordered.pop_front()
		"items.recover":
			for entry: String in p["item_state"]["overflow"].duplicate():
				if entry=="":continue
				if place(p,entry):p["item_state"]["overflow"].erase(entry)
		"items.lock", "items.split", "items.deposit", "items.withdraw":
			var location:=locate(p,uid)
			if location.is_empty() or uid=="":return fail("请先选择物品")
			if kind=="items.lock":
				var instance: Dictionary = p["gear"].get(uid,p["item_state"]["stacks"].get(uid,{}))
				instance["locked"]=not locked(p,uid)
			elif locked(p,uid):return fail("请先解锁物品")
			elif kind=="items.split":
				var amount = data.get("count",0)
				if not amount is int or amount<1 or amount>=count(p,uid) or p["gear"].has(uid):return fail("拆分数量无效")
				if uid not in p["item_state"]["bags"][Catalog.ITEMS[definition(p,uid)]["kind"]]:return fail("请先取回背包")
				if not place(p,new_stack(p,definition(p,uid),amount)):return fail("背包没有空格")
				p["item_state"]["stacks"][uid]["count"]-=amount
			elif kind=="items.deposit":
				if uid not in p["item_state"]["bags"][Catalog.ITEMS[definition(p,uid)]["kind"]]:return fail("请选择背包物品")
				var empty: int=p["item_state"]["storage"].find("")
				if empty<0:return fail("仓库已满")
				location[0][location[1]]="";p["item_state"]["storage"][empty]=uid
			else:
				if uid not in p["item_state"]["storage"]:return fail("请选择仓库物品")
				if not place(p,uid):return fail("背包已满")
				location[0][location[1]]=""
		_:return fail("未知物品操作")
	return {"ok":true}

static func valid(p: Dictionary) -> bool:
	var state = p.get("item_state")
	if not state is Dictionary or state.get("revision")!=1 or not state.get("bags") is Dictionary or state["bags"].size()!=KINDS.size() or not state.get("stacks") is Dictionary:return false
	if not Numbers.whole(state.get("next_stack"),1,1000000000):return false
	for value in state["stacks"].values():
		if not value is Dictionary or not Catalog.ITEMS.has(value.get("id","")):return false
	var all: Array=[];var max_serial:=0
	for kind: String in KINDS:
		var bag = state["bags"].get(kind)
		if not bag is Array or bag.size()!=CAPACITY:return false
		for uid in bag:
			if not uid is String:return false
			if uid!="" and (not Catalog.ITEMS.has(definition(p,uid)) or Catalog.ITEMS[definition(p,uid)]["kind"]!=kind):return false
		all.append_array(bag)
	for key in ["storage","overflow"]:
		if not state.get(key) is Array or (key=="storage" and state[key].size()!=CAPACITY):return false
		all.append_array(state[key])
	all.append_array(p["equipment"].values())
	for entry: Dictionary in p.get("services",{}).get("buyback",[]):all.append(entry["uid"])
	var seen: Dictionary={}
	for uid in all:
		if not uid is String:return false
		if uid=="":continue
		if seen.has(uid) or not Catalog.ITEMS.has(definition(p,uid)):return false
		seen[uid]=true
	for uid in state["stacks"]:
		if not uid is String or not uid.begins_with("stack_") or not uid.trim_prefix("stack_").is_valid_int() or int(uid.trim_prefix("stack_"))<1:return false
		max_serial=maxi(max_serial,int(uid.trim_prefix("stack_")))
		var stack=state["stacks"][uid]
		if not stack is Dictionary or not Catalog.ITEMS.has(stack.get("id","")) or Numbers.config()["equipment"].has(stack["id"]) or not Numbers.whole(stack.get("count"),1,STACK_LIMIT) or not stack.get("locked") is bool or not seen.has(uid):return false
		stack["count"]=int(stack["count"])
	for uid in p["gear"]:
		if not seen.has(uid) or not p["gear"][uid].get("locked",false) is bool:return false
	if int(state["next_stack"])<=max_serial or seen.size()!=p["gear"].size()+state["stacks"].size():return false
	var view:=p.duplicate(true);sync(view)
	for id: String in view["inventory"]:
		if not p["inventory"].has(id) and int(view["inventory"][id])==0:p["inventory"][id]=0
		if not Numbers.whole(p["inventory"].get(id),0,1000000000) or int(p["inventory"][id])!=int(view["inventory"][id]):return false
		p["inventory"][id]=int(p["inventory"][id])
	if view["inventory"].size()!=p["inventory"].size():return false
	state["next_stack"]=int(state["next_stack"]);state["revision"]=1
	return view["bag_layout"]==p["bag_layout"] and view["equipped"]==p["equipped"]

static func fail(message: String) -> Dictionary:
	return {"ok":false,"message":message}
