extends Node
## Presentation/input adapter. The candidate is written before becoming live.
const Loot=preload("res://loot/service.gd")
const LOOT_BEAM := "res://assets_local/loot/beam.png"
## 背包图标是 28x28 且外圈带底框；地面掉落要的是"没有背景"的物品本体，
## 所以按这个像素数裁掉四边外框。
const ICON_BORDER := 3
var game
var layer: Node2D
var signature := ""
var _beam_texture: Texture2D
var _beam_loaded := false

## 原版掉落光柱；资源库未烘焙（其它工作区没有 assets_local/loot）时返回 null，自动降级。
func loot_beam_texture() -> Texture2D:
	if not _beam_loaded:
		_beam_loaded = true
		if ResourceLoader.exists(LOOT_BEAM):_beam_texture = load(LOOT_BEAM) as Texture2D
	return _beam_texture

## 地面掉落的物品贴图：金币用原生金币帧，其余用图标裁掉外框后的本体。
func drop_texture(id: String) -> Texture2D:
	if id == "gold":return game.skin.texture("inventory_bottom",4)
	var source: Texture2D = game.windows.item_texture(id)
	if source == null:return null
	var size := source.get_size()
	if size.x <= ICON_BORDER * 2 or size.y <= ICON_BORDER * 2:return source
	var atlas := AtlasTexture.new()
	atlas.atlas = source
	atlas.region = Rect2(ICON_BORDER, ICON_BORDER, size.x - ICON_BORDER * 2, size.y - ICON_BORDER * 2)
	return atlas

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
		# 地面掉落用原版表现：物品本体不带背包图标外框，下面加原版掉落光柱
		# （itemdropeffect/beam.img，由 tools/bake_loot_sprites.py 从资源库烘到 assets_local/loot/）。
		var beam_tex:=loot_beam_texture()
		if beam_tex!=null:
			var beam:=Sprite2D.new();beam.texture=beam_tex;beam.centered=false
			var beam_scale:=0.2
			var beam_size:=beam_tex.get_size()*beam_scale
			beam.scale=Vector2(beam_scale,beam_scale)
			beam.position=Vector2(-beam_size.x*0.5,-beam_size.y+6)
			beam.modulate=Color(1,1,1,0.85)
			node.add_child(beam)
		var texture: Texture2D=drop_texture(id)
		var sprite:=Sprite2D.new();sprite.texture=texture;sprite.position=Vector2(0,-10);sprite.scale=Vector2(0.85,0.85);node.add_child(sprite)
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
