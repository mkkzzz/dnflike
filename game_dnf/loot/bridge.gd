extends Node
## Presentation/input adapter. The candidate is written before becoming live.
const Loot=preload("res://loot/service.gd")
var game
var layer: Node2D
var signature := ""

func setup(root) -> void:
	game=root

func _process(_delta: float) -> void:
	if game==null:return
	if not is_instance_valid(game.battle) or game.combat==null:
		signature="";return
	var view: Dictionary=game.combat.read_view()
	if view.is_empty():return
	if not is_instance_valid(layer):
		layer=Node2D.new();layer.name="ground_loot";game.battle.add_child(layer);signature=""
	layer.position.x=-float(view.get("camera_x",0))
	var drops:=Loot.pending(game.session.run,String(view["room_id"]))
	var next_signature:=JSON.stringify(drops)
	if next_signature==signature:return
	signature=next_signature
	for child in layer.get_children():child.queue_free()
	var occupied: Array[Rect2]=[]
	for drop: Dictionary in drops:
		var node:=Node2D.new();node.position=Vector2(float(drop["position"][0]),float(drop["position"][1]));node.z_index=int(node.position.y);layer.add_child(node)
		var id: String=drop["item"]
		var texture: Texture2D=game.skin.texture("inventory_bottom",4) if id=="gold" else game.windows.item_texture(id)
		var sprite:=Sprite2D.new();sprite.texture=texture;sprite.position=Vector2(0,-10);node.add_child(sprite)
		var text: String=("金币" if id=="gold" else String(game.Catalog.ITEMS[id]["name"]))+" ×"+str(drop["count"])
		var at:=Vector2(node.position.x-45,node.position.y-43)
		var bounds:=Rect2(at,Vector2(maxi(90,text.length()*11),15))
		while occupied.any(func(rect):return rect.intersects(bounds)):
			bounds.position.y-=16
		occupied.append(bounds)
		var label: Label=game.skin.label(node,text,bounds.position-node.position,10,Color("ffdd85"));label.mouse_filter=Control.MOUSE_FILTER_IGNORE
		label.z_index=1000

func _unhandled_key_input(event: InputEvent) -> void:
	if game==null or not event is InputEventKey or not event.pressed or event.echo or event.keycode!=KEY_E:return
	if game.session.state!="battle" or game.overlay!="" or game.debug_panel.visible:return
	pickup_nearest();get_viewport().set_input_as_handled()

func pickup_nearest() -> bool:
	if game.combat==null:return false
	var view: Dictionary=game.combat.read_view()
	if view.is_empty() or view.get("paused",true):return false
	var nearest: Dictionary={};var distance:=INF
	for drop: Dictionary in Loot.pending(game.session.run,String(view["room_id"])):
		var point:=Vector2(float(drop["position"][0]),float(drop["position"][1]))
		var delta: Vector2=point-Vector2(view["pos"])
		var limits: Array=Loot.config()["pickup_range"]
		if absf(delta.x)>float(limits[0]) or absf(delta.y)>float(limits[1]):continue
		if delta.length_squared()<distance:nearest=drop;distance=delta.length_squared()
	if nearest.is_empty():game.notice("附近没有可拾取物品");return false
	return claim(String(nearest["id"]),view,false)

func claim(id: String, view: Dictionary, cleared: bool) -> bool:
	var candidate=game.Session.new()
	candidate.profile=game.session.profile.duplicate(true);candidate.run=game.session.run.duplicate(true)
	candidate.state=game.session.state;candidate.result=game.session.result.duplicate(true)
	var response:=Loot.claim(candidate.profile,candidate.run,id,String(view["room_id"]),Vector2(view["pos"]),cleared and bool(view["room_cleared"]))
	if not response["ok"]:game.notice(response["message"]);return false
	if not game.store.write(candidate):game.save_failed=true;game.notice("拾取未提交：存档写入失败，请重试");return false
	game.session=candidate;game.save_failed=false
	game.notice("已拾取 %s ×%d" % ["金币" if response["item"]=="gold" else game.Catalog.ITEMS[response["item"]]["name"],response["count"]])
	game.build_hotbars();return true

func collect_room() -> void:
	if game.combat==null:return
	var view: Dictionary=game.combat.read_view()
	if view.is_empty() or not view["room_cleared"]:return
	for drop: Dictionary in Loot.pending(game.session.run,String(view["room_id"])):
		if not claim(String(drop["id"]),view,true):break
	if game.overlay=="result":game.show_overlay("result")
