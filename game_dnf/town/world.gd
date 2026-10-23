extends RefCounted
## Safe-town topology and ground queries. No scene tree, input, saves or quest mutation.
var data: Dictionary = {}
var errors: Array[String] = []

func _init(config: Dictionary = {}) -> void:
	if config.is_empty():
		var parsed=JSON.parse_string(FileAccess.get_file_as_string("res://data/towns.json"))
		if not parsed is Dictionary:errors.append("城镇配置无法读取");return
		config=parsed
	data=config.duplicate(true)
	if data.get("schema")!="dnf_towns/1":errors.append("城镇配置版本无效");return
	for key in ["locations","portals","npcs"]:
		if not data.get(key) is Dictionary:errors.append("城镇注册表无效："+key);return
	for id in ["elvengard","seria_room"]:
		if not data["locations"].has(id):errors.append("城镇缺少安全场景："+id)
	for id in data["npcs"]:
		var npc=data["npcs"][id]
		if not npc is Dictionary or not npc.get("name") is String or not npc.get("dialogue") is String or not npc.get("services") is Array:errors.append("NPC服务配置无效："+str(id))
	for id in data["locations"]:
		var loc=data["locations"][id]
		if not loc is Dictionary:errors.append("城镇记录无效："+str(id));continue
		for key in ["name","asset","placement"]:
			if not loc.get(key) is String or loc[key].is_empty():errors.append("城镇字段无效："+str(id)+"/"+key)
		if not loc.get("walk") is Array or loc["walk"].is_empty():errors.append("城镇缺少走区："+str(id));continue
		for rect in loc["walk"]:
			if not rectangle(rect):errors.append("城镇走区无效："+str(id))
		if not vector(loc.get("spawn")):errors.append("城镇落点无效："+str(id))
		if loc.has("dungeon_entry") and not rectangle(loc["dungeon_entry"]):errors.append("副本入口范围无效："+str(id))
		if not loc.get("npcs") is Dictionary:errors.append("城镇NPC表无效："+str(id))
		else:
			for npc in loc["npcs"]:
				if not data["npcs"].has(npc) or not vector(loc["npcs"][npc]):errors.append("城镇NPC不存在："+str(npc))
	for id in data["portals"]:
		var p=data["portals"][id]
		if not p is Dictionary:errors.append("城镇连接无效："+str(id));continue
		if not data["locations"].has(p.get("from")) or not data["locations"].has(p.get("to")):errors.append("城镇连接目标缺失："+str(id));continue
		if not rectangle(p.get("rect")) or not vector(p.get("spawn")):errors.append("城镇连接范围无效："+str(id));continue
		var back=data["portals"].get(p.get("reciprocal"),{})
		if not back is Dictionary or back.get("from")!=p["to"] or back.get("to")!=p["from"] or back.get("reciprocal")!=id:errors.append("城镇连接缺少回程："+str(id))
		if not walkable(p["to"],vec(p["spawn"])):errors.append("城镇落点不在地面："+str(id))

func location_exists(id: String) -> bool:
	return data.get("locations",{}).has(id)

func scene(id: String) -> Dictionary:
	return data.get("locations",{}).get(id,{})

func walkable(id: String, point: Vector2) -> bool:
	var walks=scene(id).get("walk",[])
	if not walks is Array:return false
	for r in walks:
		if rectangle(r) and box(r).has_point(point):return true
	return false

func constrain(id: String, point: Vector2) -> Vector2:
	if walkable(id,point):return point
	var result:=point
	var distance:=INF
	for r in scene(id).get("walk",[]):
		if not rectangle(r):continue
		var rect:=box(r)
		var candidate:=Vector2(clampf(point.x,rect.position.x,rect.end.x-0.01),clampf(point.y,rect.position.y,rect.end.y-0.01))
		var d:=candidate.distance_squared_to(point)
		if d<distance:result=candidate;distance=d
	return result

func portals(id: String, inn_return := "enter_inn") -> Dictionary:
	var result: Dictionary={}
	for key: String in data["portals"]:
		var p: Dictionary=data["portals"][key]
		if p["from"]!=id:continue
		if id=="seria_room":
			var entrance: Dictionary=data["portals"].get(inn_return,data["portals"]["enter_inn"])
			if key!=entrance["reciprocal"]:continue
		result[key]=p
	return result

func portal_at(id: String, point: Vector2, inn_return := "enter_inn") -> String:
	var visible:=portals(id,inn_return)
	for key: String in visible:
		if box(visible[key]["rect"]).has_point(point):return key
	return ""

func entry_at(id: String, point: Vector2, inn_return := "enter_inn") -> String:
	var portal:=portal_at(id,point,inn_return)
	if portal!="":return portal
	var rect=scene(id).get("dungeon_entry")
	return "dungeon" if rectangle(rect) and box(rect).has_point(point) else ""

func plan(profile: Dictionary, portal: String, point: Vector2, in_town: bool) -> Dictionary:
	if not errors.is_empty():return fail("城镇配置无效")
	if not in_town:return fail("当前无法切换城镇")
	if not profile.get("town_location") is String:return fail("当前城镇状态无效")
	var location: String=profile["town_location"]
	var active:=portals(location,String(profile.get("inn_return","enter_inn")))
	if not active.has(portal) or not box(active[portal]["rect"]).has_point(point):return fail("请走到对应路口再按E")
	var p: Dictionary=active[portal]
	if int(profile.get("level",1))<int(p.get("min_level",1)):return fail("尚未达到进入等级")
	return {"ok":true,"location":p["to"],"point":p["spawn"].duplicate(),
		"inn_return":portal if p["to"]=="seria_room" else profile.get("inn_return","enter_inn"),"label":scene(p["to"])["name"]}

func normalize(profile: Dictionary) -> void:
	var raw_location=profile.get("town_location","elvengard")
	var location: String=raw_location if raw_location is String else "elvengard"
	if not location_exists(location):location="elvengard"
	profile["town_location"]=location
	var point=profile.get("town_position",scene(location)["spawn"])
	if not vector(point):point=scene(location)["spawn"]
	var safe:=constrain(location,vec(point))
	profile["town_position"]=[safe.x,safe.y]
	var entrance=profile.get("inn_return","enter_inn")
	if not entrance is String or not data["portals"].has(entrance) or data["portals"][entrance]["to"]!="seria_room":entrance="enter_inn"
	profile["inn_return"]=entrance

static func vec(point: Array) -> Vector2:
	return Vector2(float(point[0]),float(point[1]))

static func box(rect: Array) -> Rect2:
	return Rect2(float(rect[0]),float(rect[1]),float(rect[2]),float(rect[3]))

static func vector(value) -> bool:
	if not value is Array or value.size()!=2:return false
	for n in value:
		if not (n is int or n is float) or not is_finite(float(n)):return false
	return true

static func rectangle(value) -> bool:
	if not value is Array or value.size()!=4:return false
	for n in value:
		if not (n is int or n is float) or not is_finite(float(n)):return false
	return value[2]>0 and value[3]>0

static func fail(message: String) -> Dictionary:
	return {"ok":false,"message":message}
