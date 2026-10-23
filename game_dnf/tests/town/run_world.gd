extends SceneTree
const World=preload("res://town/world.gd")
var checks:=0
var failures:=0
func _initialize() -> void:call_deferred("run")
func check(ok: bool,label: String) -> void:
	checks+=1
	if ok:print("[TOWN_UNIT] PASS "+label)
	else:failures+=1;push_error("[TOWN_UNIT] FAIL "+label)
func run() -> void:
	var world=World.new()
	check(world.errors.is_empty(),"source topology and landing rectangles validate: "+str(world.errors))
	for id: String in world.data["portals"]:
		var p: Dictionary=world.data["portals"][id]
		var profile:={"town_location":p["from"],"level":1,"inn_return":"enter_hendon_inn" if id=="exit_hendon_inn" else "enter_inn"}
		var at: Vector2=world.constrain(p["from"],World.box(p["rect"]).get_center())
		check(World.box(p["rect"]).has_point(at),"source exit reachable from declared ground: "+id)
		var plan: Dictionary=world.plan(profile,id,at,true)
		check(plan.get("ok",false) and plan["location"]==p["to"] and world.walkable(plan["location"],World.vec(plan["point"])),"portal has safe reciprocal destination: "+id)
		check(not world.plan(profile,id,at,false)["ok"],"battle state blocks cross-town travel: "+id)
	check(not world.plan({"town_location":"elvengard","level":3},"city_to_main",Vector2(800,175),true)["ok"],"wrong current town cannot invoke foreign exit")
	check(not world.plan({"town_location":"elvengard","level":3},"elven_to_city",Vector2(500,230),true)["ok"],"remote exit cannot teleport character")
	var p:={"town_location":"removed_scene","town_position":[INF,12],"inn_return":"unknown"}
	world.normalize(p)
	check(p["town_location"]=="elvengard" and world.walkable(p["town_location"],World.vec(p["town_position"])) and p["inn_return"]=="enter_inn","unknown location and nonfinite position recover safely")
	p={"town_location":"hendon_main","town_position":[-900,900]}
	world.normalize(p)
	check(world.walkable("hendon_main",World.vec(p["town_position"])),"invalid saved coordinates project onto native ground union")
	check(world.portal_at("seria_room",Vector2(448,320),"enter_hendon_inn")=="exit_hendon_inn" and world.portal_at("seria_room",Vector2(448,320),"enter_inn")=="exit_inn","shared Seria room preserves entrance-specific return")
	p={"town_location":42,"town_position":false,"inn_return":[]}
	world.normalize(p)
	check(p["town_location"]=="elvengard" and p["inn_return"]=="enter_inn","malformed optional old-save location fields safely normalize")
	var bad: Dictionary=world.data.duplicate(true)
	bad["portals"].erase("city_to_elven")
	check(not World.new(bad).errors.is_empty(),"missing return edge is rejected")
	bad=world.data.duplicate(true)
	bad["portals"]["city_to_main"]["spawn"]=[-500,-500]
	check(not World.new(bad).errors.is_empty(),"unwalkable landing is rejected")
	bad=world.data.duplicate(true)
	bad["locations"]["hendon_main"]["npcs"]["nonexistent"]=[500,230]
	check(not World.new(bad).errors.is_empty(),"unknown NPC cannot enter scene registry")
	print("[TOWN_UNIT] COMPLETE checks=%d failures=%d" % [checks,failures])
	quit(1 if failures else 0)
