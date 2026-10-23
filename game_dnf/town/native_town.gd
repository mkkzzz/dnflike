extends Node2D
signal interact(target: String)
const Loader = preload("res://scripts/native_map_loader.gd")
const Actor = preload("res://scripts/native_actor.gd")
const TextPatch = preload("res://ui/flow/native_text_patch.gd")
const UIFont = preload("res://ui/flow/ui_font.gd")
const World = preload("res://town/world.gd")
var world=World.new()
var loader=Loader.new()
var quest_loader=Loader.new()
var hendon_loader=Loader.new()
var map_root: Node2D
var map_nodes: Dictionary={}
var map_loaders: Dictionary={}
var street: Node2D
var inn: Node2D
var actor
var labels: Node2D
var font: Font
var ground:=Vector2(540,230)
var camera_x:=200.0
var camera_y:=0.0
var clock_ms:=0.0
var facing:=-1
var enabled:=true
var moving:=false
var running:=false
var animated: Array=[]
var last_tap:={KEY_LEFT:-1000,KEY_RIGHT:-1000}
var run_direction:=0
var player_name:=""
var location:="elvengard"
var inn_return:="enter_inn"
var quest_marks: Dictionary={}
var await_direction_release:=false
var entry_latch:=""

func _ready() -> void:
	loader.load_export("res://assets_local/flow_v1/manifest.json")
	street=loader.build(loader.placements()[0])
	map_root=street
	map_nodes["elvengard"]=street
	map_loaders["elvengard"]=loader
	add_child(street)
	extend_ground(street,loader)
	actor=Actor.new()
	street.add_child(actor)
	var assets: Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://assets_local/combat/manifest.json"))
	var motion: Dictionary=assets["player_locomotion"]["town"]
	actor.setup(motion["bank"],motion["clips"])
	font=UIFont.make()
	localize_signs()
	labels=Node2D.new()
	labels.z_index=4000
	street.add_child(labels)
	labels.draw.connect(_draw_names)
	ensure_location("seria_room")
	set_location("elvengard",ground)

func ensure_location(id: String) -> bool:
	if map_nodes.has(id):return true
	if not world.location_exists(id):return false
	var active_loader=quest_loader if id=="seria_room" else hendon_loader
	if active_loader.data.is_empty() and not active_loader.load_export(world.scene(id)["asset"]):return false
	for placement: Dictionary in active_loader.placements():
		if placement["id"]!=world.scene(id)["placement"]:continue
		var node: Node2D=active_loader.build(placement)
		add_child(node)
		node.hide()
		map_nodes[id]=node
		map_loaders[id]=active_loader
		if id=="seria_room":
			inn=node
			for part in node.get_children():
				if part is Loader.MapSprite and part.get_meta("layer","")=="closeback" and part.frames.size()==1 and part.texture and part.texture.get_width()>=800:
					append_strip(node,part.texture,Vector2(part.offset.x,part.position.y+part.offset.y+part.texture.get_height()),-3000)
					break
		else:extend_ground(node,active_loader)
		return true
	return false

func set_location(id: String, point:=Vector2.ZERO) -> bool:
	if not ensure_location(id):return false
	location=id
	map_root=map_nodes[id]
	if actor.get_parent()!=map_root:actor.reparent(map_root,false)
	if labels.get_parent()!=map_root:labels.reparent(map_root,false)
	for key: String in map_nodes:map_nodes[key].visible=key==id
	ground=world.constrain(id,point if point!=Vector2.ZERO else World.vec(world.scene(id)["spawn"]))
	entry_latch=entry_target()
	running=false
	run_direction=0
	await_direction_release=true
	last_tap={KEY_LEFT:-1000,KEY_RIGHT:-1000}
	clock_ms=0
	animated.clear()
	for node in map_root.get_children():
		if node is Loader.MapSprite and node.frames.size()>1:animated.append(node)
	update_camera()
	return true

func update_camera() -> void:
	camera_x=clampf(ground.x-400,0,maxf(0,float(map_root.get_meta("room")["width"])-800))
	camera_y=clampf(ground.y-300,0,float(world.scene(location).get("camera_y",0)))
	map_root.position=Vector2(-roundf(camera_x),-roundf(camera_y))
	map_loaders[location].apply_camera(map_root,camera_x)
	actor.position=Vector2(roundf(ground.x),roundf(ground.y+120))
	actor.z_index=int(ground.y)

func append_strip(parent: Node, texture: Texture2D, at: Vector2, depth: int) -> void:
	var strip:=AtlasTexture.new()
	strip.atlas=texture
	strip.region=Rect2(0,texture.get_height()-48,texture.get_width(),48)
	var sprite:=Sprite2D.new()
	sprite.centered=false
	sprite.texture=strip
	sprite.position=at
	sprite.z_index=depth
	sprite.set_meta("hud_ground_extension",true)
	parent.add_child(sprite)

func extend_ground(parent: Node2D, source_loader) -> void:
	var last: Dictionary={}
	for tile: Dictionary in parent.get_meta("room")["tiles"]:
		if tile["image"]==null:continue
		var col: int=tile["column"]
		if not last.has(col) or tile["offset"][1]>last[col]["offset"][1]:last[col]=tile
	for tile: Dictionary in last.values():
		var texture: Texture2D=source_loader.texture(tile["image"])
		append_strip(parent,texture,Vector2(float(tile["column"])*224+tile["offset"][0],tile["offset"][1]+texture.get_height()),-3100)

func localize_signs() -> void:
	for node in map_root.get_children():
		if not node is Loader.MapSprite:continue
		for frame: Dictionary in node.frames:
			var info: Dictionary = loader.data["images"].get(frame.get("image"), {})
			if info.get("source_path") != "sprite/map/flags.img":continue
			# Replace the two foreign-looking cloth inscriptions, retaining the
			# original border, anvil emblem, pole and native cloth pixels.
			TextPatch.attach(node, node.texture, Rect2(12, 33, 8, 13), Rect2(node.offset + Vector2(11, 20), Vector2(44, 12)))
			TextPatch.attach(node, node.texture, Rect2(13, 93, 8, 13), Rect2(node.offset + Vector2(13, 109), Vector2(44, 12)))
			for entry in [[Vector2(17, 18), "林纳斯"], [Vector2(19, 107), "铁匠铺"]]:
				var label := Label.new()
				label.text = entry[1]
				label.position = node.offset + entry[0]
				label.add_theme_font_override("font", font)
				label.add_theme_font_size_override("font_size", 10)
				label.add_theme_color_override("font_color", Color("e1d4c6"))
				label.mouse_filter = Control.MOUSE_FILTER_IGNORE
				node.add_child(label)
			break

func _process(delta: float) -> void:
	clock_ms+=delta*1000
	var direction:=Vector2.ZERO
	if await_direction_release and not [KEY_LEFT,KEY_RIGHT,KEY_UP,KEY_DOWN].any(func(key):return Input.is_physical_key_pressed(key)):await_direction_release=false
	if enabled and not await_direction_release:
		direction=Vector2(float(Input.is_physical_key_pressed(KEY_RIGHT))-float(Input.is_physical_key_pressed(KEY_LEFT)),float(Input.is_physical_key_pressed(KEY_DOWN))-float(Input.is_physical_key_pressed(KEY_UP)))
	if direction.length()>1:direction=direction.normalized()
	moving=direction.length_squared()>0
	if direction.x!=0:facing=int(signf(direction.x))
	running=direction.x!=0 and int(signf(direction.x))==run_direction
	ground=constrain_ground(ground+direction*delta*(285 if running else 155))
	update_camera()
	actor.present("dash" if running else "move" if moving else "stay",clock_ms,facing,0,0)
	for node in animated:
		var total:=0.0
		for frame: Dictionary in node.frames:total+=maxf(1,float(frame.get("delay_ms") if frame.get("delay_ms")!=null else 100))
		var local:=fposmod(clock_ms,total)
		for i in node.frames.size():
			local-=maxf(1,float(node.frames[i].get("delay_ms") if node.frames[i].get("delay_ms")!=null else 100))
			if local<0:node.show_frame(i);break
	labels.queue_redraw()
	var entry:=entry_target()
	if entry=="":entry_latch=""
	elif enabled and moving and entry!=entry_latch:
		# Latch before emitting: failed loads or closing map selection must not
		# retry every frame. Leave the edge zone before entering it again.
		entry_latch=entry
		interact.emit(entry)

func is_npc(id: String) -> bool:
	return world.data["npcs"].has(id)

func npc_definition(id: String) -> Dictionary:
	return world.data["npcs"].get(id,{})

func entry_target() -> String:
	return world.entry_at(location,ground,inn_return)

func nearest() -> String:
	var closest:=""
	var distance:=INF
	for id: String in world.scene(location)["npcs"]:
		var d:=ground.distance_to(World.vec(world.scene(location)["npcs"][id]))
		if d<(100.0 if id=="seria" else 95.0) and d<distance:closest=id;distance=d
	if closest!="":return closest
	return entry_target()

func _unhandled_key_input(event: InputEvent) -> void:
	if not enabled or not event is InputEventKey:return
	var key:=int(event.physical_keycode if event.physical_keycode else event.keycode)
	if key in [KEY_LEFT,KEY_RIGHT]:
		if not event.pressed:run_direction=0
		elif not event.echo:
			var now:=Time.get_ticks_msec()
			if now-int(last_tap[key])<260:run_direction=-1 if key==KEY_LEFT else 1
			last_tap[key]=now
	if event.is_pressed() and not event.is_echo() and key==KEY_E:
		var target:=nearest()
		if is_npc(target):interact.emit(target)

func constrain_ground(point: Vector2) -> Vector2:
	return world.constrain(location,point)

func draw_caption(value: String, at: Vector2, size:=13, color:=Color("e9d49a")) -> void:
	at.x-=font.get_string_size(value,HORIZONTAL_ALIGNMENT_LEFT,-1,size).x/2
	labels.draw_string_outline(font,at,value,HORIZONTAL_ALIGNMENT_LEFT,-1,size,3,Color.BLACK)
	labels.draw_string(font,at,value,HORIZONTAL_ALIGNMENT_LEFT,-1,size,color)

func _draw_names() -> void:
	if player_name!="":draw_caption(player_name,actor.position+Vector2(0,-134),12,Color("d4edb0"))
	for npc: String in world.scene(location)["npcs"]:
		var at:=World.vec(world.scene(location)["npcs"][npc])+Vector2(0,120-138)
		draw_caption(npc_definition(npc)["name"],at)
		if quest_marks.get(npc,"")!="":draw_caption(quest_marks[npc],at+Vector2(0,-24),18,Color("ffe074"))
	for label: Array in world.scene(location)["labels"]:draw_caption(label[2],Vector2(label[0],label[1]+120-30),12)
	for portal: Dictionary in world.portals(location,inn_return).values():
		var rect:=World.box(portal["rect"])
		var center:=rect.get_center()
		if center.x<camera_x-30 or center.x>camera_x+830:continue
		center.x=clampf(center.x,camera_x+90,camera_x+710)
		draw_caption(portal["label"],center+Vector2(0,120-35),12)
	var target:=nearest()
	var hint:=""
	if is_npc(target):hint="E 与"+npc_definition(target)["name"]+"交谈"
	elif target=="dungeon":hint="走向出口进入格兰之森"
	elif target!="":hint="走向出口自动进入"
	if hint!="":draw_caption(hint,actor.position+Vector2(0,-110),12,Color("fff2b5"))
