extends RefCounted
## Death remains pending until paid revival or explicit abandonment. No clear reward.
const Items=preload("res://items/inventory.gd")
const Numbers=preload("res://stats/api/numbers.gd")
const Consumables=preload("res://items/consumables.gd")
static func initialize(run: Dictionary) -> void:
	if not run.has("recovery"):run["recovery"]={"deaths":0,"revives":0,"seen":{},"transactions":{},"pending":{}}
static func defeat(run: Dictionary, event: Dictionary) -> Dictionary:
	if not event.get("stats",{}) is Dictionary or not event.get("room_id","") is String or not Numbers.whole(event.get("event_id",0),0,1000000000) or not Numbers.whole(event.get("room_index",0),0,10000):return Items.fail("死亡事件无效")
	initialize(run)
	var state: Dictionary=run["recovery"]
	var id:=str(event.get("event_id","legacy"))
	if not state["pending"].is_empty() or state["seen"].has(id):return Items.fail("这次死亡已处理")
	state["seen"][id]=true;state["deaths"]=int(state["deaths"])+1
	state["pending"]={"id":id,"death_id":int(event.get("event_id",0)),"room_id":String(event.get("room_id","")),"room_index":int(event.get("room_index",0)),"stats":Dictionary(event.get("stats",{})).duplicate(true)}
	return {"ok":true}
static func quote(p: Dictionary, run: Dictionary) -> Dictionary:
	var state: Dictionary=run.get("recovery",{})
	if state.get("pending",{}).is_empty():return Items.fail("当前没有待处理的死亡")
	var cfg: Dictionary=Consumables.config()["revival"]
	if int(state["revives"])>=int(cfg["limit"]):return Items.fail("本次冒险的复活次数已用完")
	var result: Dictionary={"ok":true,"run_id":run["id"],"room_id":state["pending"]["room_id"],"death_id":int(state["pending"]["death_id"]),"price":int(cfg["gold"])+int(state["revives"])*int(cfg["gold_increment"]),"used":int(state["revives"]),"limit":int(cfg["limit"]),"hp_percent":int(cfg["hp_percent"]),"mp_percent":int(cfg["mp_percent"]),"invulnerable_ms":int(cfg["invulnerable_ms"]),"player":Numbers.combat_spec(p)}
	result["signature"]=JSON.stringify([result,state["pending"],p["gear"]]).sha256_text()
	return result
static func revive(p: Dictionary, run: Dictionary, payload: Dictionary) -> Dictionary:
	var tx=payload.get("transaction","")
	if not tx is String or tx.is_empty() or tx.length()>160:return Items.fail("复活事务编号无效")
	if run.get("recovery",{}).get("transactions",{}).has(tx):return Items.fail("这次复活已经提交")
	var q:=quote(p,run)
	if not q["ok"]:return q
	if payload.get("signature")!=q["signature"]:return Items.fail("复活条件已变化，请重新确认")
	if int(p["gold"])<int(q["price"]):return Items.fail("金币不足，无法复活")
	p["gold"]-=int(q["price"])
	var state: Dictionary=run["recovery"]
	state["revives"]=int(state["revives"])+1;state["pending"]={};state["transactions"][tx]=true
	return {"ok":true,"quote":q}
static func valid(run: Dictionary) -> bool:
	if not run.has("recovery"):return true
	var state=run["recovery"]
	if not state is Dictionary or not Numbers.whole(state.get("deaths"),0,1000000) or not Numbers.whole(state.get("revives"),0,int(state["deaths"])):return false
	for key in ["seen","transactions","pending"]:
		if not state.get(key) is Dictionary:return false
	for key in ["seen","transactions"]:
		for id in state[key]:
			if not id is String or id.is_empty() or id.length()>160 or not state[key][id] is bool or not state[key][id]:return false
	if state["seen"].size()!=int(state["deaths"]) or state["transactions"].size()!=int(state["revives"]):return false
	var pending: Dictionary=state["pending"]
	if not pending.is_empty():
		if not pending.get("id") is String or not state["seen"].has(pending["id"]) or not pending.get("room_id") is String or not pending.get("stats") is Dictionary or not Numbers.whole(pending.get("death_id"),0,1000000000) or not Numbers.whole(pending.get("room_index"),0,10000):return false
		if int(state["deaths"])!=int(state["revives"])+1:return false
	elif int(state["deaths"])!=int(state["revives"]):return false
	state["deaths"]=int(state["deaths"]);state["revives"]=int(state["revives"])
	return true
