extends Node
## Presentation/input adapter. The candidate is written before becoming live.
const Loot=preload("res://loot/service.gd")
const LOOT_BEAM := "res://assets_local/loot/beam.png"
## 背包图标是画在"深色格子底"上的 28x28 图；地面掉落只要物品本体。
## 这里从四角洪水填充掉底色（按颜色容差），得到透明背景的物体轮廓，并按 id 缓存。
## 背包格子底是一层深浅不一的暗色纹理（16/32/48 混合），容差要放宽到能覆盖这层纹理，
## 又远小于物品本体的亮色，才不会把物品吃掉。
const ICON_BG_TOLERANCE := 0.38
var game
var layer: Node2D
var signature := ""
var _beam_texture: Texture2D
var _beam_loaded := false
var _drop_textures: Dictionary = {}

## 原版掉落光柱；资源库未烘焙（其它工作区没有 assets_local/loot）时返回 null，自动降级。
func loot_beam_texture() -> Texture2D:
	if not _beam_loaded:
		_beam_loaded = true
		if ResourceLoader.exists(LOOT_BEAM):_beam_texture = load(LOOT_BEAM) as Texture2D
	return _beam_texture

## 地面掉落的物品贴图：去掉背包格子的底色，只留物品本体。
func drop_texture(id: String) -> Texture2D:
	if _drop_textures.has(id):return _drop_textures[id]
	var source: Texture2D = game.skin.texture("inventory_bottom",4) if id == "gold" else game.windows.item_texture(id)
	if source == null:return null
	var keyed := _key_out_slot_background(source)
	_drop_textures[id] = keyed
	return keyed

## 从"最占面积的不透明颜色"（即背包格子底）向内洪水填充成透明。
## 注意不能拿角落像素当底色：图标四角常是 alpha=0 的透明像素，颜色不可靠。
func _key_out_slot_background(source: Texture2D) -> Texture2D:
	var image := source.get_image()
	if image == null:return source
	image = image.duplicate() as Image
	if image.is_compressed():image.decompress()
	image.convert(Image.FORMAT_RGBA8)
	var width := image.get_width()
	var height := image.get_height()
	if width < 4 or height < 4:return source
	var histogram := {}
	for y in height:
		for x in width:
			var color := image.get_pixel(x, y)
			if color.a < 0.5:continue
			var key := ((int(color.r * 15) << 8) | (int(color.g * 15) << 4) | int(color.b * 15))
			histogram[key] = int(histogram.get(key, 0)) + 1
	if histogram.is_empty():return source
	var dominant_key := 0
	var dominant_count := -1
	for key: int in histogram:
		if int(histogram[key]) > dominant_count:
			dominant_count = int(histogram[key])
			dominant_key = key
	var background := Color8(((dominant_key >> 8) & 15) * 17, ((dominant_key >> 4) & 15) * 17, (dominant_key & 15) * 17)
	var seen := {}
	var stack: Array[Vector2i] = []
	for x in width:
		stack.push_back(Vector2i(x, 0))
		stack.push_back(Vector2i(x, height - 1))
	for y in height:
		stack.push_back(Vector2i(0, y))
		stack.push_back(Vector2i(width - 1, y))
	while not stack.is_empty():
		var point: Vector2i = stack.pop_back()
		if point.x < 0 or point.y < 0 or point.x >= width or point.y >= height:continue
		var index := point.y * width + point.x
		if seen.has(index):continue
		seen[index] = true
		var color := image.get_pixel(point.x, point.y)
		if color.a >= 0.5 and absf(color.r - background.r) + absf(color.g - background.g) + absf(color.b - background.b) > ICON_BG_TOLERANCE:continue
		image.set_pixel(point.x, point.y, Color(0, 0, 0, 0))
		stack.push_back(Vector2i(point.x + 1, point.y))
		stack.push_back(Vector2i(point.x - 1, point.y))
		stack.push_back(Vector2i(point.x, point.y + 1))
		stack.push_back(Vector2i(point.x, point.y - 1))
	return ImageTexture.create_from_image(image)

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
			# 原版光柱贴图自带不透明黑底（DNF 用加色混合画光）。必须同样用
			# BLEND_MODE_ADD，否则会盖出一块黑方块，把物品本体整个遮住。
			var additive:=CanvasItemMaterial.new()
			additive.blend_mode=CanvasItemMaterial.BLEND_MODE_ADD
			beam.material=additive
			var beam_scale:=0.2
			var beam_size:=beam_tex.get_size()*beam_scale
			beam.scale=Vector2(beam_scale,beam_scale)
			beam.position=Vector2(-beam_size.x*0.5,-beam_size.y+6)
			beam.modulate=Color(1,1,1,0.9)
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
