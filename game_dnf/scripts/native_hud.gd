extends Node2D
var game
var font: SystemFont
var atlas: Texture2D

func _ready() -> void:
	font = SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei UI","Microsoft YaHei","Noto Sans CJK SC"])
	font.font_weight = 500
	atlas = load(String(game.assets["ui"]["texture"])) as Texture2D

func text(point: Vector2,value: String,size := 12,color := Color(0.93,0.91,0.79)) -> void:
	draw_string(font,point+Vector2(1,1),value,HORIZONTAL_ALIGNMENT_LEFT,-1,size,Color(0.02,0.03,0.03,0.95))
	draw_string(font,point,value,HORIZONTAL_ALIGNMENT_LEFT,-1,size,color)

func piece(key: String,point: Vector2,fill := 1.0) -> void:
	var item: Dictionary = game.assets["ui"]["items"].get(key,{})
	if item.is_empty():return
	var r: Array = item["rect"]
	var h := float(r[3])*clampf(fill,0,1)
	var missing := float(r[3])-h
	draw_texture_rect_region(atlas,Rect2(point+Vector2(0,missing),Vector2(float(r[2]),h)),Rect2(float(r[0]),float(r[1])+missing,float(r[2]),h))

func _draw() -> void:
	if game == null or game.player.is_empty() or atlas == null:return
	var p: Dictionary = game.player
	var room: Dictionary = game.rules["rooms"][game.room_index]
	text(Vector2(16,23),"格兰之森",16,Color(0.96,0.83,0.47))
	text(Vector2(16,40),String(room["name"]),11)
	var alive := 0
	for enemy: Dictionary in game.monsters:
		if float(enemy["hp"])>0:alive+=1
	text(Vector2(16,56),"通道开启" if game.room_cleared else "剩余怪物  "+str(alive),10,Color(0.66,0.86,0.71))
	var base := Vector2(566,42)
	for i in game.rules["rooms"].size():
		var cell: Array = game.rules["rooms"][i]["cell"]
		var point := base+Vector2(float(cell[0])*18,float(cell[1])*14)
		var color := Color(0.20,0.26,0.25)
		if game.room_snapshots.has(i):color=Color(0.22,0.51,0.36)
		if i==game.room_index:color=Color(0.92,0.72,0.34)
		if game.rules["rooms"][i].get("boss",false) and i!=game.room_index:color=Color(0.55,0.20,0.18)
		draw_rect(Rect2(point,Vector2(13,9)),color)
		draw_rect(Rect2(point,Vector2(13,9)),Color(0.75,0.68,0.46),false)
	if game.combo_count>1:
		text(Vector2(20,106),str(game.combo_count)+" HIT",20,Color(1,0.79,0.3))
	for enemy: Dictionary in game.monsters:
		if float(enemy["hp"])<=0:continue
		var ep: Vector2 = Vector2(enemy["pos"])-Vector2(20,70+float(enemy["z"]))
		var hp := float(enemy["hp"])/float(enemy["max_hp"])
		draw_rect(Rect2(ep,Vector2(40,3)),Color(0.06,0.03,0.02,0.8))
		draw_rect(Rect2(ep,Vector2(40*hp,3)),Color(0.85,0.24,0.15))
		if enemy["chief"]:
			text(Vector2(206,26),"密林领主",12,Color(1,0.68,0.30))
			draw_rect(Rect2(204,31,230,5),Color(0.12,0.05,0.03))
			draw_rect(Rect2(204,31,230*hp,5),Color(0.68,0.16,0.10))
	for number: Dictionary in game.numbers:
		var pos: Vector2 = number["pos"]
		var life := float(number["ms"])/650
		pos.y -= life*28
		text(pos,String(number["text"]),20 if number["heavy"] else 15,Color(1,0.79 if number["heavy"] else 0.95,0.32 if number["heavy"] else 0.75,1-life))
	# The source HUD's middle section is cropped, not rescaled to a fractional size.
	draw_rect(Rect2(0,291,640,69),Color(0.035,0.035,0.04,0.94))
	var r: Array = game.assets["ui"]["items"]["hud_0"]["rect"]
	draw_texture_rect_region(atlas,Rect2(0,291,640,69),Rect2(float(r[0])+80,float(r[1]),640,69))
	piece("hud_1",Vector2(10,298),float(p["hp"])/float(game.rules["player"]["hp"]))
	piece("hud_2",Vector2(574,298),float(p["mp"])/float(game.rules["player"]["mp"]))
	text(Vector2(20,329),str(int(p["hp"])),11,Color(1,0.9,0.82))
	text(Vector2(584,329),str(int(p["mp"])),11,Color(0.80,0.93,1))
	text(Vector2(78,311),"狂战士" if game.job=="berserker" else "剑魂",12,Color(0.96,0.78,0.39))
	var weapon_name: String = {"shortsword":"短剑","katana":"太刀","greatsword":"巨剑"}[game.weapon]
	text(Vector2(78,328),weapon_name,10)
	if float(p["buff_ms"])>0:text(Vector2(78,345),"血怒 %.1f"%(float(p["buff_ms"])/1000),10,Color(1,0.48,0.38))
	var skills: Array = ["upper","buff","rage_slash"] if game.job=="berserker" else ["upper","draw","thrust"]
	var names: Array = ["上挑","血怒","怒斩"] if game.job=="berserker" else ["上挑","拔刀斩","连突刺"]
	for i in 3:
		var point := Vector2(226+i*54,304)
		piece("hud_37",point)
		var cd := float(p["cooldowns"].get(skills[i],0))
		if cd>0:draw_rect(Rect2(point+Vector2(5,5),Vector2(38,38)),Color(0,0,0,0.62))
		text(point+Vector2(3,2),["Z","A","S"][i],9,Color(0.92,0.82,0.52))
		text(point+Vector2(7,27),String(names[i]),10)
		if cd>0:text(point+Vector2(15,41),"%.1f"%cd,10,Color.WHITE)
	text(Vector2(437,312),"X 普攻  C 跳跃",10)
	text(Vector2(437,329),"V 后跳  G 格挡",10)
	text(Vector2(437,346),"F1 操作说明",9,Color(0.62,0.67,0.62))
	if game.toast_ms>0:
		var message: String = game.toast
		var width := font.get_string_size(message,HORIZONTAL_ALIGNMENT_LEFT,-1,13).x
		draw_rect(Rect2(320-width/2-16,71,width+32,27),Color(0.03,0.07,0.06,0.7))
		text(Vector2(320-width/2,90),message,13,Color(1,0.87,0.52))
	if game.finished:
		draw_rect(Rect2(0,0,640,291),Color(0.02,0.04,0.04,0.67))
		text(Vector2(237,135),"地下城通关" if game.victory else "挑战失败",26,Color(1,0.81,0.39))
		var rank := "S" if game.damage_taken<100 and game.elapsed_ms<100000 else "A" if game.damage_taken<250 else "B"
		if game.victory:text(Vector2(222,169),"评价 "+rank+"   用时 %.1f 秒"%(game.elapsed_ms/1000),14)
		text(Vector2(256,204),"R 重新挑战",14,Color(0.8,0.92,0.84))
	elif game.paused or game.help_visible:
		draw_rect(Rect2(100,60,440,205),Color(0.025,0.04,0.035,0.95))
		text(Vector2(125,88),"已暂停" if game.paused else "操作说明",19,Color(1,0.83,0.45))
		var lines := ["方向键移动 · 同向双击奔跑", "X 普攻三连 / 空中斩 / 跑动攻击", "C 或空格跳跃 · V 后跳 · 按住 G 格挡", "Z 上挑 · A / S 职业技能", "Tab 切换职业 · 1 / 2 / 3 切换武器", "清怪后走入通道切房 · 领主房清完结算", "Esc 暂停 · M 静音 · F3 切换窗口尺寸"]
		for i in lines.size():text(Vector2(125,112+i*19),lines[i],12)
