extends RefCounted
## Adventure-scoped cooldowns use public simulation time, never wall-clock time.
const Items=preload("res://items/inventory.gd")
const Numbers=preload("res://stats/api/numbers.gd")
static var _config: Dictionary={}
static func config() -> Dictionary:
	if _config.is_empty():
		_config=JSON.parse_string(FileAccess.get_file_as_string("res://data/recovery.json"))
		_config["consumables"].merge(preload("res://content/api/native_catalog.gd").runtime().get("consumables",{}),false)
	return _config
static func initialize(run: Dictionary) -> void:
	if not run.has("consumables"):run["consumables"]={"items":{},"groups":{},"transactions":{}}
static func finite(value, minimum: float, maximum: float) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and value>=minimum and value<=maximum
static func remaining(run: Dictionary, id: String, time_ms: float) -> float:
	if not run.has("consumables") or not config()["consumables"].has(id):return 0
	var rule: Dictionary=config()["consumables"][id];var state: Dictionary=run["consumables"]
	return maxf(0,maxf(float(state["items"].get(id,0)),float(state["groups"].get(rule["group"],0)))-time_ms)
static func use(p: Dictionary, run: Dictionary, id: String, view: Dictionary, tx: String) -> Dictionary:
	var rules: Dictionary=config()["consumables"]
	if not rules.has(id):return Items.fail("该物品不能直接使用")
	if tx.is_empty() or tx.length()>160:return Items.fail("使用事务编号无效")
	if not finite(view.get("time_ms"),0,1000000000000):return Items.fail("战斗时钟无效")
	if not finite(view.get("hp"),0,1000000000) or not finite(view.get("hp_max"),1,1000000000) or view["hp"]>view["hp_max"]:return Items.fail("生命值快照无效")
	if view.get("run_id")!=run.get("id") or view.get("paused",true) or view.get("finished",true) or float(view.get("hp",0))<=0:return Items.fail("请在存活且未暂停的战斗中使用物品")
	var rule: Dictionary=rules[id]
	if int(p["level"])<int(rule["level"]):return Items.fail("角色等级不足，无法使用")
	var effect: Dictionary=rule["effect"].duplicate(true)
	# Resolve percentages from the current validated maxima before emitting the
	# existing public restore request; the combat kernel receives absolute values.
	for resource: String in ["hp","mp"]:
		var percent:=float(effect.get(resource+"_percent",0))
		if percent<=0:continue
		if not finite(view.get(resource+"_max"),1,1000000000):return Items.fail("恢复上限快照无效")
		effect[resource]=float(effect.get(resource,0))+float(view[resource+"_max"])*percent/100.0
	var hp_amount:=float(effect.get("amount",0)) if effect.get("kind")=="heal" else float(effect.get("hp",0))
	var mp_amount:=float(effect.get("mp",0))
	if mp_amount>0 and (not finite(view.get("mp"),0,1000000000) or not finite(view.get("mp_max"),1,1000000000) or view["mp"]>view["mp_max"]):return Items.fail("魔法值快照无效")
	var restored_hp:=minf(hp_amount,float(view["hp_max"])-float(view["hp"]))
	var restored_mp:=minf(mp_amount,float(view.get("mp_max",0))-float(view.get("mp",0)))
	if restored_hp<=0 and restored_mp<=0:return Items.fail("对应的生命值或魔法值已满")
	var time_ms:=float(view["time_ms"])
	var state: Dictionary=run.get("consumables",{"items":{},"groups":{},"transactions":{}})
	if state["transactions"].has(tx):return Items.fail("这次使用已经提交")
	var wait:=remaining(run,id,time_ms)
	if wait>0:return Items.fail("恢复物品冷却中 · 剩余 %.1f 秒" % (wait/1000))
	if Items.stock(p,id)<1:return Items.fail("没有可用物品；锁定、仓库与待领取区不能使用")
	var consumed:=Items.consume(p,id,1)
	if not consumed["ok"]:return consumed
	initialize(run);state=run["consumables"]
	state["items"][id]=time_ms+int(rule["cooldown_ms"])
	state["groups"][rule["group"]]=time_ms+int(rule["group_cooldown_ms"])
	state["transactions"][tx]=true
	return {"ok":true,"effect":effect.duplicate(true),"amount":restored_hp+restored_mp,"hp_amount":restored_hp,"mp_amount":restored_mp}
static func valid(run: Dictionary) -> bool:
	if not run.has("consumables"):return true
	var state=run["consumables"]
	if not state is Dictionary:return false
	for field in ["items","groups","transactions"]:
		if not state.get(field) is Dictionary:return false
		for key in state[field]:
			if not key is String or key.is_empty() or key.length()>160:return false
			var value=state[field][key]
			if field=="transactions":
				if not value is bool or not value:return false
			elif not (value is float or value is int) or not is_finite(float(value)) or value<0 or value>1000000000000:return false
	return true
