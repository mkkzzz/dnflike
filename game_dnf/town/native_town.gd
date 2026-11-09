extends Node2D
signal interact(target: String)
const Loader = preload("res://scripts/native_map_loader.gd")
const Frame = preload("res://view/world_frame.gd")
const Actor = preload("res://scripts/native_actor.gd")
const GateLight = preload("res://town/gate_light.gd")
const TextPatch = preload("res://ui/flow/native_text_patch.gd")
const UIFont = preload("res://ui/flow/ui_font.gd")
const World = preload("res://town/world.gd")
var world=World.new()
var loader=Loader.new()
var asset_loaders: Dictionary={}
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
var gate_lights: Array=[]
## 地面逻辑坐标 → 画布坐标的偏移（角色脚部 = ground + MAP_DY），与 loader 同源。
const GROUND_DRAW_OFFSET := Frame.MAP_DY
## 光墙整体压在地面美术之上、任何角色/物件之下：角色 z = ground.y（>=0），光墙固定 -1500，
## 所以人物贴图永远在光墙上方；背景层 -2500/-3000/-4000 仍在光墙之下。
const GATE_LIGHT_DEPTH := -1500
var last_tap:={KEY_LEFT:-1000,KEY_RIGHT:-1000}
var run_direction:=0
var player_name:=""
var location:="elvengard"
var inn_return:="enter_inn"
var quest_marks: Dictionary={}
var await_direction_release:=false
var entry_latch:=""
## 城镇以装备实例ID绑定原武器前后层；类别字段保留给旧入口/临时GM覆盖。
var weapon_shape:="katana"
var weapon_item:=""
var item_appearance_enabled:=false
## NPC 语音与立绘。amb 是“靠近时的一句环境语”，不是持续循环的 BGM；
## talk/farewell 共用一条对白声道，新的台词会替换尚未播完的旧台词。
var npc_voices: Dictionary={}
var ambient_player: AudioStreamPlayer
var speech_player: AudioStreamPlayer
var voice_enabled := false
var ambient_npc := ""
var speech_npc := ""
var speech_kind := ""
var ambient_play_count: Dictionary={}
var speech_play_count: Dictionary={}
const NPC_HEAR_RANGE := 150.0
const NPC_HEAR_EXIT_RANGE := 190.0
const NPC_VOICE_DB := -16.0

func _ready() -> void:
	loader.load_export("res://assets_local/flow_v1/manifest.json")
	street=loader.build(loader.placements()[0])
	map_root=street
	map_nodes["elvengard"]=street
	map_loaders["elvengard"]=loader
	add_child(street)
	actor=Actor.new()
	street.add_child(actor)
	setup_actor()
	font=UIFont.make()
	localize_signs()
	labels=Node2D.new()
	labels.z_index=4000
	street.add_child(labels)
	labels.draw.connect(_draw_names)
	ensure_location("seria_room")
	set_location("elvengard",ground)
	_load_npc_voices()

## 读 NPC 语音表。环境语和对话语各用一个共享播放器，避免全城常驻声源。
func _load_npc_voices() -> void:
	if not FileAccess.file_exists("res://data/npc_voices.json"):return
	var doc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/npc_voices.json"))
	for name: String in doc.get("npcs", {}):
		npc_voices[name] = doc["npcs"][name]
	if npc_voices.is_empty():return
	ambient_player = AudioStreamPlayer.new()
	ambient_player.name = "npc_ambient_voice"
	ambient_player.volume_db = NPC_VOICE_DB
	add_child(ambient_player)
	speech_player = AudioStreamPlayer.new()
	speech_player.name = "npc_speech_voice"
	speech_player.volume_db = NPC_VOICE_DB
	add_child(speech_player)
	speech_player.finished.connect(func(): speech_kind = "")

## 只在玩家进入 NPC 听觉范围时播一句环境语；停留不会重复，离开后才重新触发。
func _update_npc_voices() -> void:
	if ambient_player == null:return
	if not voice_enabled or not enabled or not is_visible_in_tree():
		ambient_player.stop()
		return
	if speech_player != null and speech_player.playing:
		ambient_player.stop()
		return
	var npcs: Dictionary = world.scene(location).get("npcs", {})
	var range := NPC_HEAR_EXIT_RANGE if ambient_npc != "" else NPC_HEAR_RANGE
	var closest := ""
	var distance := INF
	for name: String in npc_voices:
		if not npcs.has(name):continue
		var candidate_distance := ground.distance_to(World.vec(npcs[name]))
		if candidate_distance <= range and candidate_distance < distance:
			closest = name
			distance = candidate_distance
	if closest == "":
		ambient_player.stop()
		ambient_npc = ""
		return
	if closest == ambient_npc:return
	ambient_npc = closest
	_play_npc_ambient(closest)

func _play_npc_ambient(name: String) -> void:
	var entry: Dictionary = npc_voices.get(name, {})
	var list: Array = entry.get("amb", [])
	if list.is_empty():return
	var stream := _load_voice_stream(String(list[randi() % list.size()]))
	if stream == null:return
	ambient_player.stop()
	ambient_player.stream = stream
	ambient_player.play()
	ambient_play_count[name] = int(ambient_play_count.get(name, 0)) + 1

## 对话/告别语音：随机取一条一次性播放。新的对白打断旧对白和环境语。
func play_npc_voice(name: String, kind := "talk") -> bool:
	if speech_player == null:return false
	var entry: Dictionary = npc_voices.get(name, {})
	var list: Array = entry.get(kind, [])
	if list.is_empty():return false
	var stream := _load_voice_stream(String(list[randi() % list.size()]))
	if stream == null:return false
	if ambient_player != null:ambient_player.stop()
	speech_player.stop()
	speech_player.stream = stream
	speech_player.play()
	speech_npc = name
	speech_kind = kind
	speech_play_count[kind] = int(speech_play_count.get(kind, 0)) + 1
	return true

func _load_voice_stream(relative: String) -> AudioStream:
	if relative == "":return null
	var path := "res://assets_local/" + relative
	if not ResourceLoader.exists(path):return null
	var stream := load(path) as AudioStream
	if stream is AudioStreamOggVorbis:(stream as AudioStreamOggVorbis).loop = false
	return stream

func set_voice_enabled(value: bool) -> void:
	voice_enabled = value
	if not value and ambient_player != null:ambient_player.stop()

func stop_npc_voices(reset := false) -> void:
	if ambient_player != null:ambient_player.stop()
	if speech_player != null:speech_player.stop()
	if reset:
		ambient_npc = ""
		speech_npc = ""
		speech_kind = ""

func voice_debug() -> Dictionary:
	var ambient_loop := false
	if ambient_player != null and ambient_player.stream is AudioStreamOggVorbis:
		ambient_loop = (ambient_player.stream as AudioStreamOggVorbis).loop
	return {
		"enabled": voice_enabled,
		"ambient_npc": ambient_npc,
		"ambient_playing": ambient_player != null and ambient_player.playing,
		"ambient_loop": ambient_loop,
		"speech_npc": speech_npc,
		"speech_kind": speech_kind,
		"speech_playing": speech_player != null and speech_player.playing,
		"talk_count": int(speech_play_count.get("talk", 0)),
		"farewell_count": int(speech_play_count.get("farewell", 0)),
	}

## 对话立绘：优先 big face，其次 popup/small（原版 .npc 的三张脸）。
func npc_face(name: String) -> Texture2D:
	var entry: Dictionary = npc_voices.get(name, {})
	for slot in ["big", "popup", "small"]:
		var rel := String((entry.get("faces", {}) as Dictionary).get(slot, ""))
		if rel == "":continue
		var path := "res://assets_local/" + rel
		if ResourceLoader.exists(path):return load(path)
	return null

## 城镇角色的绘制包：优先带武器的合成帧，缺武器时回退到无武器分层帧。
func setup_actor() -> void:
	if actor == null:return
	var runtime: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets_local/manifest.json"))
	var players: Dictionary = runtime.get("players", {})
	var clips: Dictionary = runtime.get("clips", {})
	if item_appearance_enabled:
		var motions: Dictionary={}
		for pose: String in ["stay","move","dash"]:motions[pose]=clips["player/"+pose]
		if preload("res://content/api/weapon_appearance.gd").apply(actor,weapon_item,motions):return
	if players.has(weapon_shape) and clips.has("player/stay") and clips.has("player/move") and clips.has("player/dash"):
		actor.setup(players[weapon_shape], {
			"stay":clips["player/stay"],
			"move":clips["player/move"],
			"dash":clips["player/dash"],
		})
		return
	var assets: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets_local/combat/manifest.json"))
	var motion: Dictionary = assets["player_locomotion"]["town"]
	actor.setup(motion["bank"],motion["clips"])

## 换武器（或重新进城镇）时刷新手上的武器外观。
func set_weapon(shape: String) -> void:
	if shape == "" or (shape == weapon_shape and not item_appearance_enabled):return
	item_appearance_enabled=false
	weapon_shape = shape
	setup_actor()

func set_equipped_weapon(item: String, shape: String) -> bool:
	if not preload("res://content/api/weapon_appearance.gd").can_display(item):return false
	if item_appearance_enabled and weapon_item==item and weapon_shape==shape:return true
	weapon_item=item;weapon_shape=shape;item_appearance_enabled=true
	setup_actor()
	return true

func ensure_location(id: String) -> bool:
	if map_nodes.has(id):return true
	if not world.location_exists(id):return false
	var scene: Dictionary=world.scene(id)
	var asset: String=scene["asset"]
	var active_loader: Loader=asset_loaders.get(asset)
	if active_loader==null:
		active_loader=Loader.new()
		if not active_loader.load_export(asset):return false
		asset_loaders[asset]=active_loader
	for placement: Dictionary in active_loader.placements():
		if placement["id"]!=scene["placement"]:continue
		var node: Node2D=active_loader.build(placement)
		add_child(node)
		node.hide()
		map_nodes[id]=node
		map_loaders[id]=active_loader
		if id=="seria_room":inn=node
		return true
	return false

func dialogue_portrait(npc: String) -> Texture2D:
	var active_loader: Loader=map_loaders.get(location)
	if active_loader!=null:
		var ui: Dictionary=active_loader.data.get("ui",{})
		var key=ui.get("seria_portrait") if npc=="seria" else ui.get("portraits",{}).get(npc)
		var portrait: Texture2D=active_loader.texture(key)
		if portrait!=null:return portrait
	return npc_face(npc)

func set_location(id: String, point:=Vector2.ZERO) -> bool:
	if not ensure_location(id):return false
	stop_npc_voices(true)
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
	rebuild_gate_lights()
	update_camera()
	return true

## 每个可见城镇传送点放一组原版"开门光墙"（上 gateup + 下 gatedown）。
## 只画表现：不建碰撞、不改进出判定；素材缺失时静默跳过（town 仍可运行）。
## 副本入口（dungeon_entry）按用户 2026-10-27 要求不放光墙。
func rebuild_gate_lights() -> void:
	for node in gate_lights:
		if is_instance_valid(node):node.queue_free()
	gate_lights.clear()
	if not GateLight.available():return
	for key: String in world.portals(location,inn_return):
		_add_gate_light(key,key,World.box(world.data["portals"][key]["rect"]),world.data["portals"][key]["rect"])

func _add_gate_light(name: String, target: String, rect: Rect2, raw: Array) -> void:
	var anchor:=Vector2(rect.get_center().x,rect.end.y+GROUND_DRAW_OFFSET)
	var light=GateLight.new()
	if not light.setup(anchor,GATE_LIGHT_DEPTH):
		light.free()
		return
	light.name="gate_light_"+name
	light.set_meta("portal",target)
	light.set_meta("rect",raw)
	map_root.add_child(light)
	gate_lights.append(light)

func gate_light_count() -> int:
	return gate_lights.size()

func update_camera() -> void:
	camera_x=clampf(ground.x-400,0,maxf(0,float(map_root.get_meta("room")["width"])-800))
	camera_y=clampf(ground.y-300,0,float(world.scene(location).get("camera_y",0)))
	map_root.position=Vector2(-roundf(camera_x),-roundf(camera_y))
	map_loaders[location].apply_camera(map_root,camera_x)
	actor.position=Vector2(roundf(ground.x),roundf(ground.y+GROUND_DRAW_OFFSET))
	actor.z_index=int(ground.y)

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
	_update_npc_voices()
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

func _exit_tree() -> void:
	stop_npc_voices(true)

func draw_caption(value: String, at: Vector2, size:=13, color:=Color("e9d49a")) -> void:
	at.x-=font.get_string_size(value,HORIZONTAL_ALIGNMENT_LEFT,-1,size).x/2
	labels.draw_string_outline(font,at,value,HORIZONTAL_ALIGNMENT_LEFT,-1,size,3,Color.BLACK)
	labels.draw_string(font,at,value,HORIZONTAL_ALIGNMENT_LEFT,-1,size,color)

func _draw_names() -> void:
	if player_name!="":draw_caption(player_name,actor.position+Vector2(0,-134),12,Color("d4edb0"))
	for npc: String in world.scene(location)["npcs"]:
		var at:=World.vec(world.scene(location)["npcs"][npc])+Vector2(0,GROUND_DRAW_OFFSET-138)
		draw_caption(npc_definition(npc)["name"],at)
		if quest_marks.get(npc,"")!="":draw_caption(quest_marks[npc],at+Vector2(0,-24),18,Color("ffe074"))
	for label: Array in world.scene(location)["labels"]:
		var half_width:=font.get_string_size(label[2],HORIZONTAL_ALIGNMENT_LEFT,-1,12).x/2
		if label[0]-half_width<camera_x or label[0]+half_width>camera_x+800:continue
		draw_caption(label[2],Vector2(label[0],label[1]+GROUND_DRAW_OFFSET-30),12)
	for portal: Dictionary in world.portals(location,inn_return).values():
		var rect:=World.box(portal["rect"])
		var center:=rect.get_center()
		if center.x<camera_x-30 or center.x>camera_x+830:continue
		center.x=clampf(center.x,camera_x+90,camera_x+710)
		draw_caption(portal["label"],center+Vector2(0,GROUND_DRAW_OFFSET-35),12)
	var target:=nearest()
	var hint:=""
	if is_npc(target):hint="E 与"+npc_definition(target)["name"]+"交谈"
	elif target=="dungeon":hint="走向出口进入格兰之森"
	elif target!="":hint="走向出口自动进入"
	if hint!="":draw_caption(hint,actor.position+Vector2(0,-110),12,Color("fff2b5"))
