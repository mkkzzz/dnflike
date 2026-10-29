extends Node
## Presentation/input adapter. The candidate is written before becoming live.
const Loot=preload("res://loot/service.gd")
## 原版地面掉落：本体用 sprite/item/field*.img，光柱用 itemdropeffect/beam.img（16 帧循环）。
## 这些由 tools/bake_loot_sprites.py 从资源库烘到 assets_local/loot/（本机生成物，gitignore）。
## 没有烘焙结果时退回"背包图标去底色"的老方案，保证其它工作区仍能跑。
const LOOT_MANIFEST := "res://assets_local/loot/manifest.json"
const LOOT_DIR := "res://assets_local/loot/"
const ICON_BG_TOLERANCE := 0.38
var game
var layer: Node2D
var signature := ""
var _manifest: Dictionary = {}
var _manifest_loaded := false
var _frame_sets: Dictionary = {}
var _drop_textures: Dictionary = {}
var _pickup_audio: AudioStreamPlayer
var _pickup_streams: Dictionary = {}

func loot_manifest() -> Dictionary:
	if not _manifest_loaded:
		_manifest_loaded = true
		if FileAccess.file_exists(LOOT_MANIFEST):
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(LOOT_MANIFEST))
			if parsed is Dictionary:_manifest = parsed
	return _manifest

## 某个 key（物品 id 或 "beam"）的烘焙信息；没有则返回空字典。
func loot_entry(key: String) -> Dictionary:
	var sprites: Dictionary = loot_manifest().get("sprites", {})
	return sprites.get(key, {})

## 单帧贴图（多帧时取第 0 帧）。
func loot_texture(key: String) -> Texture2D:
	var entry := loot_entry(key)
	if entry.is_empty():return null
	var files: Array = entry.get("frames", [])
	if files.is_empty():return null
	var path := LOOT_DIR + String(files[0])
	if not ResourceLoader.exists(path):return null
	return load(path) as Texture2D

## 动画用的 SpriteFrames（帧数>1 时循环播放）。
func loot_sprite_frames(key: String) -> SpriteFrames:
	if _frame_sets.has(key):return _frame_sets[key]
	var entry := loot_entry(key)
	if entry.is_empty():return null
	var files: Array = entry.get("frames", [])
	if files.is_empty():return null
	var frames := SpriteFrames.new()
	frames.remove_animation("default")
	frames.add_animation("default")
	frames.set_animation_loop("default", true)
	frames.set_animation_speed("default", float(entry.get("fps", 10)))
	for file in files:
		var path := LOOT_DIR + String(file)
		if ResourceLoader.exists(path):frames.add_frame("default", load(path) as Texture2D)
	if frames.get_frame_count("default") == 0:return null
	_frame_sets[key] = frames
	return frames

## 原版光柱的动画；未烘焙时返回 null，自动降级为不画光柱。
func loot_beam_frames() -> SpriteFrames:
	return loot_sprite_frames("beam")

## 兼容旧调用：返回光柱首帧贴图（测试与外部脚本用）。
func loot_beam_texture() -> Texture2D:
	return loot_texture("beam")

## 地面掉落本体：所有物品统一缩放到同一个外框（金币原来 28x34，比药水大太多）。
const DROP_BODY_BOX := 22.0

## 地面掉落本体：优先用原版 field 图；没有烘焙结果时退回背包图标去底色。
func drop_texture(id: String) -> Texture2D:
	if id.begins_with("original_"):return game.windows.field_texture(id)
	if not loot_entry(id).is_empty():
		return loot_texture(id)
	if _drop_textures.has(id):return _drop_textures[id]
	var source: Texture2D = game.skin.texture("inventory_bottom",4) if id == "gold" else game.windows.item_texture(id)
	if source == null:return null
	var keyed := _key_out_slot_background(source)
	_drop_textures[id] = keyed
	return keyed

## 落地效果：原版 field 图用动画精灵；单帧或回退方案用静态精灵。
## 所有本体统一缩放到 DROP_BODY_BOX 的方框内，保证金币和药水看着一样大。
func build_drop_body(id: String) -> Node2D:
	var frames := loot_sprite_frames(id)
	if frames != null:
		var animated := AnimatedSprite2D.new()
		animated.sprite_frames = frames
		animated.animation = "default"
		animated.play()
		animated.scale = _body_scale(frames.get_frame_texture("default", 0))
		return animated
	var sprite := Sprite2D.new()
	sprite.texture = drop_texture(id)
	if sprite.texture != null:sprite.scale = _body_scale(sprite.texture)
	return sprite

func _body_scale(texture: Texture2D) -> Vector2:
	if texture == null:return Vector2.ONE
	var size := texture.get_size()
	var longest := maxf(size.x, size.y)
	if longest <= 0.0:return Vector2.ONE
	var factor := DROP_BODY_BOX / longest
	return Vector2(factor, factor)

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
	var player := AudioStreamPlayer.new()
	player.name="loot_pickup_audio"
	add_child(player)
	_pickup_audio=player
	_load_pickup_sounds()

## 拾取音效（原版 item_pick / coin_pick_01..03）由 bake_loot_sprites.py 复制到
## assets_local/loot/audio/；缺失时不播，不影响拾取。
func _load_pickup_sounds() -> void:
	var sounds: Dictionary = loot_manifest().get("sounds", {})
	for key: String in sounds:
		var list: Array[AudioStream] = []
		for file: String in sounds[key]:
			var path := LOOT_DIR + "audio/" + file
			if ResourceLoader.exists(path):
				var stream := load(path) as AudioStream
				if stream != null:list.append(stream)
		if not list.is_empty():_pickup_streams[key] = list

func play_pickup_sound(id: String) -> void:
	if _pickup_audio == null:return
	var key := "coin_pick" if id == "gold" else "item_pick"
	var list: Array = _pickup_streams.get(key, [])
	if list.is_empty():return
	_pickup_audio.stream = list[randi() % list.size()]
	_pickup_audio.play()

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
		# 原版表现：16 帧循环光柱 + field 系列掉落本体（都没有背包格子底）
		var beam_frames:=loot_beam_frames()
		if beam_frames!=null:
			var beam:=AnimatedSprite2D.new()
			beam.sprite_frames=beam_frames;beam.animation="default";beam.centered=false
			beam.play()
			# 原版光柱贴图自带不透明黑底（DNF 用加色混合画光）。必须同样用
			# BLEND_MODE_ADD，否则会盖出一块黑方块，把物品本体整个遮住。
			var additive:=CanvasItemMaterial.new()
			additive.blend_mode=CanvasItemMaterial.BLEND_MODE_ADD
			beam.material=additive
			var beam_scale:=0.2
			var beam_texture: Texture2D = beam_frames.get_frame_texture("default", 0)
			var beam_size:=beam_texture.get_size()*beam_scale
			beam.scale=Vector2(beam_scale,beam_scale)
			beam.position=Vector2(-beam_size.x*0.5,-beam_size.y+6)
			beam.modulate=Color(1,1,1,0.9)
			node.add_child(beam)
		var body:=build_drop_body(id)
		# 缩放已在 build_drop_body 里按 DROP_BODY_BOX 归一化（金币不再比药水大），此处只定位。
		body.position=Vector2(0,-10)
		node.add_child(body)
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

## 普攻键拾取用：附近有掉落就捡走并返回 true（没有则安静返回 false，让 X 照常出招）。
func try_pickup() -> bool:
	if game==null or game.combat==null:return false
	var view: Dictionary=game.combat.read_view()
	if view.is_empty() or view.get("paused",true):return false
	var nearest := _nearest_drop(view)
	if nearest.is_empty():return false
	return claim(String(nearest["id"]),view,false)

func _nearest_drop(view: Dictionary) -> Dictionary:
	var nearest: Dictionary={};var distance:=INF
	for drop: Dictionary in Loot.pending(game.session.run,String(view["room_id"])):
		var point:=Vector2(float(drop["position"][0]),float(drop["position"][1]))
		var delta: Vector2=point-Vector2(view["pos"])
		var limits: Array=Loot.config()["pickup_range"]
		if absf(delta.x)>float(limits[0]) or absf(delta.y)>float(limits[1]):continue
		if delta.length_squared()<distance:nearest=drop;distance=delta.length_squared()
	return nearest

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
	if not game.store.write(candidate):
		game.save_failed=true;game.notice("拾取未提交：存档写入失败，请重试");return false
	game.session=candidate;game.save_failed=false
	game.notice("已拾取 %s ×%d" % ["金币" if response["item"]=="gold" else game.Catalog.ITEMS[response["item"]]["name"],response["count"]])
	# 拾取表现：下蹲一下 + 原版拾取音效
	var battle_view: Variant = game.battle.get("view") if is_instance_valid(game.battle) else null
	if battle_view != null and battle_view.has_method("request_pickup_pose"):
		battle_view.request_pickup_pose()
	play_pickup_sound(String(response.get("item", "")))
	game.build_hotbars();return true

func collect_room() -> void:
	if game.combat==null:return
	var view: Dictionary=game.combat.read_view()
	if view.is_empty() or not view["room_cleared"]:return
	for drop: Dictionary in Loot.pending(game.session.run,String(view["room_id"])):
		if not claim(String(drop["id"]),view,true):break
	if game.overlay=="result":game.show_overlay("result")
