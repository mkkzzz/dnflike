extends RefCounted
## Stable rolls are persisted with the run. A claim updates ownership and receipt together.
const Inventory=preload("res://items/inventory.gd")
static func config() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string("res://data/loot.json"))

static func generate(run: Dictionary, event: Dictionary, quest_drops: Array=[]) -> bool:
	var cfg:=config()
	var ordinary: bool=run.get("dungeon") in cfg["enabled_dungeons"]
	if (not ordinary and quest_drops.is_empty()) or event.get("run_id")!=run.get("id"):return false
	if not event.has("entity_id") or not event.get("room_id") is String or event["room_id"]=="" or not event.get("position") is Vector2:return false
	var position: Vector2=event["position"]
	if not position.is_finite():return false
	var key:=String(event["room_id"])+":"+str(event["entity_id"])
	if not run.has("loot"):run["loot"]={"seen":{},"drops":{}}
	if run["loot"]["seen"].has(key):return false
	run["loot"]["seen"][key]=true
	var rng:=RandomNumberGenerator.new()
	rng.seed=(String(run["id"])+":"+key).hash()
	var table: Array=cfg["boss" if event.get("boss",false) else "normal"].duplicate(true) if ordinary else []
	table.append_array(quest_drops)
	var index:=0
	for entry: Dictionary in table:
		var roll:=rng.randi_range(1,100)
		var count:=rng.randi_range(int(entry["min"]),int(entry["max"]))
		var quality:=rng.randi_range(0,100)
		if roll>int(entry["chance"]):continue
		var id:=String(run["id"])+":"+key+":"+str(index)
		run["loot"]["drops"][id]={"id":id,"item":entry["id"],"count":count,"quality":quality,"room":event["room_id"],"position":[position.x+index*28-28,position.y],"claimed":false}
		if entry.has("quest"):run["loot"]["drops"][id]["quest"]=entry["quest"]
		index+=1
	return true

static func pending(run: Dictionary, room: String) -> Array:
	var result: Array=[]
	for drop: Dictionary in run.get("loot",{}).get("drops",{}).values():
		if drop["room"]==room and not drop["claimed"]:result.append(drop.duplicate(true))
	return result

static func claim(p: Dictionary, run: Dictionary, id: String, room: String, pos: Vector2, cleared := false) -> Dictionary:
	var drops: Dictionary=run.get("loot",{}).get("drops",{})
	if not drops.has(id) or drops[id]["claimed"]:return Inventory.fail("掉落已拾取或不存在")
	var drop: Dictionary=drops[id]
	if drop["room"]!=room or not pos.is_finite():return Inventory.fail("掉落不在当前房间")
	var target:=Vector2(float(drop["position"][0]),float(drop["position"][1]))
	var limits: Array=config()["pickup_range"]
	if not cleared and (absf(target.x-pos.x)>float(limits[0]) or absf(target.y-pos.y)>float(limits[1])):return Inventory.fail("请靠近掉落后按 E 拾取")
	var candidate:=p.duplicate(true)
	if drop["item"]=="gold":candidate["gold"]+=int(drop["count"])
	else:
		var given:=Inventory.give(candidate,String(drop["item"]),int(drop["count"]),int(drop["quality"]))
		if not given["ok"]:return given
	p.assign(candidate);drop["claimed"]=true
	return {"ok":true,"item":drop["item"],"count":drop["count"]}

static func valid(run: Dictionary) -> bool:
	if not run.has("loot"):return true
	var ledger=run["loot"]
	if not run.get("id") is String or not ledger is Dictionary or not ledger.get("seen") is Dictionary or not ledger.get("drops") is Dictionary:return false
	for key in ledger["seen"]:
		if not key is String or ledger["seen"][key]!=true:return false
	for key in ledger["drops"]:
		var drop=ledger["drops"][key]
		if not key is String or not key.begins_with(run["id"]+":") or not drop is Dictionary or drop.get("id")!=key:return false
		if drop.get("item")!="gold" and not Inventory.Catalog.ITEMS.has(drop.get("item","")):return false
		if not Inventory.Numbers.whole(drop.get("count"),1,100000) or not Inventory.Numbers.whole(drop.get("quality"),0,100):return false
		if not drop.get("claimed") is bool or not drop.get("room") is String or drop["room"]=="" or not drop.get("position") is Array or drop["position"].size()!=2:return false
		for value in drop["position"]:
			if not (value is int or value is float) or not is_finite(float(value)):return false
	return true
