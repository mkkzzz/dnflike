extends RefCounted
## Pure upgrade rules. RNG advances only in the candidate that is saved by flow.
const Items=preload("res://items/inventory.gd")
const Numbers=preload("res://stats/api/numbers.gd")
const KINDS=["services.reinforce","services.enchant","services.enchant_clear"]
const MODULUS=2147483647

static func config() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string("res://data/upgrades.json"))

static func initialize(p: Dictionary) -> void:
	if not p["services"].has("upgrades"):
		p["services"]["upgrades"]={"seed":randi_range(1,MODULUS-1),"attempts":0}

static func valid(state: Dictionary) -> bool:
	if not state.has("upgrades"):return true # Additive migration from existing /4 saves.
	var data=state["upgrades"]
	if not data is Dictionary or not Numbers.whole(data.get("seed"),1,MODULUS-1) or not Numbers.whole(data.get("attempts"),0,1000000000):return false
	data["seed"]=int(data["seed"]);data["attempts"]=int(data["attempts"])
	return true

static func owned(p: Dictionary, uid: String) -> bool:
	if uid in p["equipment"].values():return true
	for bag: Array in p["item_state"]["bags"].values():
		if uid!="" and uid in bag:return true
	return false

static func quote(p: Dictionary, kind: String, data: Dictionary) -> Dictionary:
	var uid:=String(data.get("uid",""))
	if not p["gear"].has(uid) or not owned(p,uid):return Items.fail("请选择背包或穿戴中的装备")
	if Items.locked(p,uid):return Items.fail("请先解锁装备")
	var gear: Dictionary=p["gear"][uid]
	if int(gear["durability"])<=0:return Items.fail("装备已损坏，请先修理")
	var slot: String=Numbers.config()["equipment"][gear["definition"]]["slot"]
	var cfg:=config()
	var result: Dictionary={"ok":true,"kind":kind,"uid":uid,"name":Items.Catalog.ITEMS[gear["definition"]]["name"],"count":1,"price":0,"output":{},"targets":[],"materials":{},"before":Numbers.gear_detail(p,uid)}
	var preview:=p.duplicate(true)
	match kind:
		"services.reinforce":
			var level:=int(gear["reinforce"])
			if int(p["services"]["upgrades"]["attempts"])>=1000000000:return Items.fail("强化次数达到当前存档上限")
			if slot!="weapon" and not cfg["reinforcement"]["bonuses"].has(slot):return Items.fail("该部位尚未配置强化属性")
			if level>=cfg["reinforcement"]["steps"].size():return Items.fail("已达到当前强化上限")
			var step: Dictionary=cfg["reinforcement"]["steps"][level]
			result.merge({"price":int(step["gold"]),"materials":step["materials"].duplicate(true),"chance":int(step["chance"]),"from":level,"to":level+1,"failure_level":int(step["failure_level"]),"rng":p["services"]["upgrades"].duplicate(true)},true)
			preview["gear"][uid]["reinforce"]=level+1
		"services.enchant":
			if not data.get("recipe","") is String:return Items.fail("请选择有效附魔方案")
			var recipe: String=data.get("recipe","")
			if not cfg["enchants"].has(recipe):return Items.fail("请选择有效附魔方案")
			var entry: Dictionary=cfg["enchants"][recipe]
			if slot not in entry["slots"]:return Items.fail("该附魔不支持此装备部位")
			if gear["enchants"]==[entry["modifier"]]:return Items.fail("装备已有相同附魔，无需重复消耗")
			result.merge({"recipe":recipe,"recipe_name":entry["name"],"price":int(entry["gold"]),"materials":entry["materials"].duplicate(true),"enchants":[entry["modifier"].duplicate(true)]},true)
			preview["gear"][uid]["enchants"]=result["enchants"].duplicate(true)
		"services.enchant_clear":
			if gear["enchants"].is_empty():return Items.fail("装备没有附魔")
			result["enchants"]=[];preview["gear"][uid]["enchants"]=[]
		_:return Items.fail("养成服务不存在")
	result["after"]=Numbers.gear_detail(preview,uid)
	return result

static func apply_quote(p: Dictionary, q: Dictionary) -> Dictionary:
	if int(p["gold"])<int(q["price"]):return Items.fail("金币不足")
	# Preflight the complete bill before consuming any material.
	for id: String in q["materials"]:
		if Items.stock(p,id)<int(q["materials"][id]):return Items.fail("可用%s不足；锁定、仓库与待领取区材料不参与消耗" % Items.Catalog.ITEMS[id]["name"])
	for id: String in q["materials"]:
		var response:=Items.consume(p,id,int(q["materials"][id]))
		if not response["ok"]:return response
	p["gold"]-=int(q["price"])
	var gear: Dictionary=p["gear"][q["uid"]]
	var message: String
	if q["kind"]=="services.reinforce":
		var rng: Dictionary=p["services"]["upgrades"]
		rng["seed"]=(int(rng["seed"])*48271)%MODULUS
		rng["attempts"]=int(rng["attempts"])+1
		var success:=int(rng["seed"])%100<int(q["chance"])
		gear["reinforce"]=int(q["to"] if success else q["failure_level"])
		message="强化成功 · %s +%d" % [q["name"],gear["reinforce"]] if success else "强化失败 · 保留装备，当前 +%d；费用与材料已消耗" % int(gear["reinforce"])
	else:
		gear["enchants"]=q["enchants"].duplicate(true)
		message="附魔已清除" if q["kind"]=="services.enchant_clear" else "附魔完成 · "+String(q["recipe_name"])
	return {"ok":true,"message":message}
