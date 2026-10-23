extends RefCounted
## Source chapter views. Uses the same native skin and item controls as inventory.
var game
var selected := ""
var tab := 0
var focus_npc := ""
var tracker: Control
var tracker_text: Label
var tracker_signature := ""

func _init(root) -> void:
	game = root

func text(parent: Node, value: String, at: Vector2, size: Vector2, font_size := 12, color := Color("d4c9b1")) -> Label:
	var label: Label = game.skin.label(parent, value, at, font_size, color)
	label.size = size
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label

func dialogue() -> void:
	var npc: String = game.town.nearest()
	if not game.town.is_npc(npc):
		game.notice("请走到人物身旁交谈")
		return
	focus_npc = npc
	game.record_npc_visit(npc)
	var node = game.windows.container(game.modal, Vector2(41,343), Vector2(718,165))
	game.skin.image(node,game.skin.texture("dialog"),Vector2.ZERO)
	var portrait: Texture2D
	if npc=="seria":portrait=game.town.quest_loader.texture(game.town.quest_loader.data["ui"]["seria_portrait"])
	elif npc=="linus":portrait=game.skin.texture("dialog_face")
	elif npc=="shylock":portrait=game.town.gran_loader.texture(game.town.gran_loader.data["ui"]["portraits"][npc])
	else:portrait=game.town.hendon_loader.texture(game.town.hendon_loader.data["ui"]["portraits"][npc])
	game.skin.image(node,portrait,Vector2(8,165-portrait.get_height())).name = npc + "_dialogue_illustration"
	text(node,game.session.quests.npc_name(npc),Vector2(215,18),Vector2(370,25),16,Color("f0d18a"))
	var line: String=game.town.npc_definition(npc)["dialogue"]
	if npc=="linus" and game.session.quests.status(game.session.profile,"hendon.meet_pungjin") in ["available","active"]:line="你已经历练了一番。沿防线左侧去赫顿玛尔吧，经城市区向上走，到主街找风振聊聊。"
	if npc=="seria" and game.session.quests.status(game.session.profile,"elvengard.seria_fate")=="completed":line="看到你平安回来，我就放心了。赫顿玛尔还有许多值得结识的人，祝你旅途顺利。"
	var ready: Array = game.session.quests.list(game.session.profile,["ready"],npc)
	if not ready.is_empty():line = "你回来了，辛苦了。\n打开任务记录，把这次冒险的收获告诉我吧。"
	for q: Dictionary in ready:
		match q["id"]:
			"hendon.meet_pungjin":line="林纳斯让你来的？欢迎来到赫顿玛尔。\n这里有许多能帮助你修行的人，先让我介绍一下。"
			"hendon.swordman_start":line="鬼剑士要走的路，需要你自己选择。\n先去后街拜访辛达，他会告诉你更多。"
			"hendon.meet_sinda":line="风振介绍你来的？我是铁匠辛达。\n坐下聊聊吧，修行和装备都有不少学问。"
			"hendon.job_introduction":line="转职会让你的修行走向不同道路。\n眼下先磨炼基础，之后可向G.S.D了解鬼剑士的修行。"
			"gran.tau_rage":line="牛头巨兽已经被击败了？辛苦了。\n森林深处的猫妖也很不安分，接下来还得请你帮忙。"
			"gran.cat_trouble":line="猫妖的数量总算减少了。\n关于那只呼唤闪电的哥布林，后街小巷的夏洛克也许知道些什么。"
			"gran.meet_shylock":line="风振让你来打听凯诺？森林里的事，我可知道不少。\n先坐下来聊聊，别把我和那些闹事的哥布林混为一谈。"
	text(node,line,Vector2(215,51),Vector2(475,62),13)
	game.skin.button(node,"委托任务",Vector2(215,120),func():
		var active: Array = game.session.quests.list(game.session.profile,["ready","active"],npc)
		tab = 1 if not active.is_empty() else 0
		selected = ""
		game.show_overlay("quest"))
	if npc == "linus":game.skin.button(node,"购买物品",Vector2(325,120),func():game.show_overlay("shop"))
	var services: Array=game.town.npc_definition(npc)["services"]
	if services.any(func(id):return id in ["trade","repair","disassemble"]):game.skin.button(node,"物品服务",Vector2(435,120),func():game.show_overlay("services"))
	if "skills" in services:game.skin.button(node,"学习技能",Vector2(325,120),func():game.number_windows.tab=1;game.show_overlay("numbers"))
	if "equipment" in services:game.skin.button(node,"装备整备",Vector2(325,120),func():game.number_windows.tab=2;game.show_overlay("numbers"))
	if services.any(func(id):return id in ["reinforce","enchant"]):game.skin.button(node,"强化" if "reinforce" in services else "附魔",Vector2(540,120),func():game.show_overlay("upgrades"),false)
	game.skin.button(node,"结束对话",Vector2(600,120),func():game.show_overlay(""))
	game.skin.close_button(node,Vector2(686,13),func():game.show_overlay(""))

func show_window() -> void:
	var node = game.windows.board(game.modal,"任务",Rect2(112,55,576,416))
	for i in 3:
		var index := i
		var button: Button = game.skin.button(node,["可接受","进行中","已完成"][i],Vector2(17+i*84,41),func():tab=index; selected="";game.show_overlay("quest"),false)
		button.size.x = 80
		if i == tab:button.modulate=Color("ffdb85")
	game.skin.surface(node,Rect2(16,73,236,288),"quest_list",5)
	game.skin.surface(node,Rect2(265,73,295,288),"quest",16)
	var states: Array = [["available"],["active","ready"],["completed"]][tab]
	var rows: Array = game.session.quests.list(game.session.profile,states)
	if selected == "" or not rows.any(func(q):return q["id"] == selected):
		selected = ""
		for q: Dictionary in rows:
			if focus_npc == "" or focus_npc in [q["giver"],q["receiver"]]:selected=q["id"];break
		if selected == "" and not rows.is_empty():selected=rows[0]["id"]
	var scroll := ScrollContainer.new()
	scroll.position=Vector2(20,78)
	scroll.size=Vector2(228,278)
	scroll.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED
	node.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation",3)
	scroll.add_child(list)
	var chosen: Dictionary = {}
	for q: Dictionary in rows:
		var id: String = q["id"]
		var button := Button.new()
		button.custom_minimum_size=Vector2(220,43)
		button.flat=true
		button.add_theme_font_override("font",game.skin.font)
		button.add_theme_font_size_override("font_size",12)
		button.text=("[主线] " if q["category"]=="main" else "[支线] ")+q["name"]+("  ✓" if q["status"]=="ready" else "")
		button.alignment=HORIZONTAL_ALIGNMENT_LEFT
		button.set_meta("quest_id",id)
		button.pressed.connect(func():selected=id;game.show_overlay("quest"))
		list.add_child(button)
		if id==selected:
			button.modulate=Color("ffdd85")
			chosen=q
	if chosen.is_empty():text(node,"暂无该类任务",Vector2(48,106),Vector2(180,24));return
	var detail=game.windows.container(node,Vector2(279,85))
	text(detail,chosen["name"],Vector2.ZERO,Vector2(262,28),17,Color("f0d18a"))
	text(detail,"委托：%s    交付：%s\n等级：Lv.%d" % [game.session.quests.npc_name(chosen["giver"]),game.session.quests.npc_name(chosen["receiver"]),chosen["min_level"]],Vector2(0,34),Vector2(263,44))
	text(detail,chosen["description"],Vector2(0,85),Vector2(260,57))
	text(detail,"任务目标",Vector2(0,147),Vector2(260,20),12,Color("f0d18a"))
	var objective_lines := ""
	for o: Dictionary in chosen["objectives"]:objective_lines += objective_line(o)+"\n"
	text(detail,objective_lines,Vector2(0,170),Vector2(260,43),12,Color("a7dd74"))
	text(detail,"任务奖励",Vector2(0,218),Vector2(260,20),12,Color("f0d18a"))
	text(detail,"金币 %d    经验 %d" % [chosen["reward"]["gold"],chosen["reward"]["xp"]],Vector2(0,244),Vector2(260,23))
	var x := 0
	for item: String in chosen["reward"]["items"]:
		game.make_slot(detail,{"place":"reward","id":item,"count":int(chosen["reward"]["items"][item])},Vector2(x,274))
		x += 36
	var id: String=chosen["id"]
	var state: String=chosen["status"]
	if state in ["active","ready"]:
		game.skin.button(node,"取消追踪" if chosen["tracked"] else "追踪任务",Vector2(278,377),func():game.quest_action("quest.track",{"id":id}))
	if state in ["available","ready"]:
		game.skin.button(node,"接受委托" if state=="available" else "领取报酬",Vector2(450,377),func():
			if game.quest_action("quest.accept" if state=="available" else "quest.claim",{"id":id}):tab=1 if state=="available" else 2;game.show_overlay("quest"))
	else:text(node,"已完成" if state=="completed" else "进行中",Vector2(481,379),Vector2(70,20))
	text(node,"%d / %d 进行中" % [game.session.quests.active_count(game.session.profile),game.session.quests.catalog.config["limits"]["active"]],Vector2(23,379),Vector2(200,20),11)

func objective_line(o: Dictionary) -> String:
	var label: String = ""
	match o["type"]:
		"meet_npc":label="拜访"+game.session.quests.npc_name(o["target"])
		"clear_dungeon":label="通关"+String(game.session.quests.catalog.config["dungeons"].get(o["target"],o["target"]))
		"kill_monster":label=String(game.session.quests.catalog.config["dungeons"].get(o.get("dungeon",""),""))+" · "+String(game.session.quests.catalog.config.get("monsters",{}).get(o["target"],"目标怪物"))
		"collect_item":label=String(game.Catalog.ITEMS.get(o["target"],{}).get("name",o["target"]))
	return "%s  %d / %d" % [label,int(o["current"]),int(o["amount"])]

func dungeon() -> void:
	var region: String=game.town.world.scene(game.town.location).get("dungeon_region","lorien")
	var dungeon_ids: Array[String]=game.session.dungeon_choices(region)
	if game.selected_dungeon not in dungeon_ids or not game.session.dungeon_available(game.selected_dungeon):
		game.selected_dungeon=dungeon_ids[0]
		for id: String in dungeon_ids:
			if game.session.dungeon_available(id):game.selected_dungeon=id;break
	if region=="granfloris" and not game.town.ensure_location("hendon_forest_gate"):
		game.notice("格兰之森资源未就绪，请通过正式入口同步")
		return
	var loader=game.town.gran_loader if region=="granfloris" else game.town.quest_loader
	var node=game.windows.container(game.modal,Vector2.ZERO,Vector2(800,600))
	game.skin.image(node,game.skin.texture("worldmap"),Vector2.ZERO)
	game.skin.image(node,game.skin.texture("select",79),Vector2.ZERO)
	game.skin.image(node,game.skin.texture("select",58),Vector2(104,0))
	text(node,"格兰之森" if region=="granfloris" else "洛兰",Vector2(34,65),Vector2(250,40),22,Color("f0d18a"))
	var locations := {dungeon_ids[0]:Vector2(300,230),dungeon_ids[1]:Vector2(132,111)}
	for id: String in locations:
		var at: Vector2=locations[id]
		var image: Texture2D=loader.texture(loader.data["ui"]["dungeons"][id])
		var card: TextureRect=game.skin.image(node,image,at)
		var unlocked: bool=game.session.dungeon_available(id)
		if not unlocked:card.modulate=Color("777777")
		var button:=Button.new()
		button.position=at
		button.size=image.get_size()
		button.flat=true
		var required: Array=game.session.dungeons[id]["requires"]
		var requirement: String=game.session.quests.catalog.definitions[required[0]]["name"] if not required.is_empty() else "前置任务"
		button.tooltip_text=game.session.dungeons[id]["name"]+(" · 完成「"+requirement+"」后开放" if not unlocked else "")
		button.set_meta("dungeon_id",id)
		button.pressed.connect(func():
			if unlocked:game.selected_dungeon=id;game.show_overlay("dungeon")
			else:game.notice("请先完成「"+requirement+"」并达到进入等级"))
		node.add_child(button)
		if id==game.selected_dungeon:
			card.name="selected_dungeon_card"
			var outline:=NinePatchRect.new()
			outline.texture=game.skin.texture("select",22)
			outline.position=at+Vector2(-3,9)
			outline.size=Vector2(174,74)
			outline.patch_margin_left=4
			outline.patch_margin_right=4
			outline.patch_margin_top=4
			outline.patch_margin_bottom=4
			outline.draw_center=false
			outline.mouse_filter=Control.MOUSE_FILTER_IGNORE
			node.add_child(outline)
	var difficulty: String=game.session.profile.get("difficulty","normal")
	var choices := ["normal","adventure","king"]
	var at: Vector2=locations[game.selected_dungeon]+Vector2(25,84)
	var bar=game.windows.container(node,at,Vector2(118,27))
	bar.name="difficulty_selector"
	game.skin.image(bar,game.skin.texture("select",2),Vector2.ZERO)
	game.skin.image(bar,game.skin.texture("select",{"normal":11,"adventure":12,"king":14}[difficulty]),Vector2(36,4))
	for entry in [[-1,Vector2(0,4),[3,4,5]],[1,Vector2(98,4),[7,8,9]]]:
		var next: String=choices[posmod(choices.find(difficulty)+entry[0],3)]
		var button: TextureButton=game.skin.sprite_button(bar,"select",entry[2],entry[1],func():
			if game.act("flow.difficulty",{"id":next}):game.show_overlay("dungeon"))
		button.name="difficulty_previous" if entry[0]==-1 else "difficulty_next"
	var enter: TextureButton=game.skin.sprite_button(node,"select",[164,165,166],Vector2(621,446),game.depart,"进入地下城 Space")
	enter.set_meta("action_label","进入地下城")
	enter.disabled=not game.session.dungeon_available(game.selected_dungeon)
	game.skin.button(node,"返回城镇",Vector2(631,528),func():game.show_overlay(""))
	if game.session.quests.status(game.session.profile,"legacy.trial")=="active":
		game.skin.button(node,"继续旧试炼",Vector2(34,528),func():game.selected_dungeon="forest_trial";game.show_overlay("dungeon"))

func refresh_tracker() -> void:
	if not is_instance_valid(tracker):
		tracker=game.windows.container(game.ui,Vector2(584,43),Vector2(205,148))
		tracker.mouse_filter=Control.MOUSE_FILTER_IGNORE
		tracker_text=text(tracker,"",Vector2.ZERO,Vector2(205,148),11,Color("f0d18a"))
	tracker.visible=game.character_active and game.overlay=="" and not game.debug_is_open() and game.session.state in ["town","battle"]
	tracker.position.y=82 if game.toast_panel.visible else 43
	var lines := ""
	var marks := {}
	for q: Dictionary in game.session.quests.list(game.session.profile,["available","active","ready"]):
		if q["status"]=="ready":marks[q["receiver"]]="?"
		elif q["status"]=="available" and not marks.has(q["giver"]):marks[q["giver"]]="!"
		if q["tracked"]:
			lines += q["name"]+"\n"
			if q["status"]=="ready":lines+="  向"+game.session.quests.npc_name(q["receiver"])+"交付\n"
			else:
				for o: Dictionary in q["objectives"]:lines+="  "+objective_line(o)+"\n"
	tracker_text.text=lines
	game.town.quest_marks=marks
