extends RefCounted
## Adventure-scoped cooldowns use public simulation time, never wall-clock time.
const Items=preload("res://items/inventory.gd")
const Numbers=preload("res://stats/api/numbers.gd")
static var _config: Dictionary={}
static func config() -> Dictionary:
	if _config.is_empty():_config=JSON.parse_string(FileAccess.get_file_as_string("res://data/recovery.json"))
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
	if float(view.get("hp",0))>=float(view.get("hp_max",0)):return Items.fail("生命值已满")
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
	return {"ok":true,"effect":rule["effect"].duplicate(true),"amount":minf(float(rule["effect"]["amount"]),float(view["hp_max"])-float(view["hp"]))}
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
