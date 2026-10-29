extends Node
## Observe public combat facts; deferred profile writes never mutate the emitting kernel.
const Services=preload("res://items/services.gd")
var game
var connected_bus
func setup(root) -> void:game=root
func _process(_delta: float) -> void:
	if game==null or game.combat==null:return
	var bus=game.combat.events()
	if bus==null or bus==connected_bus:return
	connected_bus=bus
	var run_id: String=game.session.run.get("id","")
	bus.subscribe("combat.damage",func(event: Dictionary):
		var fact:=event.duplicate(true);fact["run_id"]=run_id
		# Observe before deferred writes: a final kill may settle this same frame.
		game.session.observe_damage(fact)
		call_deferred("apply_wear",fact))

func apply_wear(event: Dictionary) -> void:
	if game.session.state!="battle" or event.get("run_id")!=game.session.run.get("id"):return
	var candidate=game.Session.new()
	candidate.profile=game.session.profile.duplicate(true);candidate.run=game.session.run.duplicate(true)
	candidate.state=game.session.state;candidate.result=game.session.result.duplicate(true)
	var result:=Services.wear(candidate.profile,candidate.run,event)
	if not result["changed"]:return
	if not game.store.write(candidate):game.save_failed=true;game.notice("耐久保存失败，请检查存档目录");return
	game.session=candidate;game.save_failed=false
	if result["broken"]:
		game.sync_number_changes("durability")
		game.notice("装备耐久已耗尽，属性失效，请回城修理")
