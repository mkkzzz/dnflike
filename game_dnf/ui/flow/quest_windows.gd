extends RefCounted
## Source chapter views. Uses the same native skin and item controls as inventory.
var game
var selected := ""
var tab := 0
var focus_npc := ""
var tracker: Control
var tracker_signature := ""
var selected_choices: Dictionary = {}

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
	if not ready.is_empty():line=String(ready[0].get("dialogue",{}).get("complete",line))
	elif not game.session.quests.list(game.session.profile,["available"],npc).is_empty():
		var available: Array=game.session.quests.list(game.session.profile,["available"],npc)
		line=String(available[0].get("dialogue",{}).get("accept",line))
	var speech:=ScrollContainer.new()
	speech.position=Vector2(215,51);speech.size=Vector2(475,62)
	speech.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED
	node.add_child(speech)
	var speech_label:=Label.new()
	speech_label.text=line;speech_label.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
	speech_label.custom_minimum_size.x=455;speech_label.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	speech_label.add_theme_font_override("font",game.skin.font);speech_label.add_theme_font_size_override("font_size",13)
	speech.add_child(speech_label)
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
		var category: String={"daily":"[每日] ","repeat":"[重复] "}.get(q.get("lifecycle","once"),"[主线] " if q["category"]=="main" else "[支线] ")
		button.text=category+q["name"]+("  ✓" if q["status"]=="ready" else "")
		button.alignment=HORIZONTAL_ALIGNMENT_LEFT
		button.set_meta("quest_id",id)
		button.pressed.connect(func():selected=id;game.show_overlay("quest"))
		list.add_child(button)
		if id==selected:
			button.modulate=Color("ffdd85")
			chosen=q
	if chosen.is_empty():text(node,"暂无该类任务",Vector2(48,106),Vector2(180,24));return
	var detail_scroll:=ScrollContainer.new()
	detail_scroll.name="quest_detail_scroll"
	detail_scroll.position=Vector2(279,85);detail_scroll.size=Vector2(272,276)
	detail_scroll.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED
	node.add_child(detail_scroll)
	var detail:=VBoxContainer.new()
	detail.custom_minimum_size.x=250;detail.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	detail.add_theme_constant_override("separation",8);detail_scroll.add_child(detail)
	detail_line(detail,chosen["name"],17,Color("f0d18a"))
	detail_line(detail,"委托：%s  交付：%s\n等级：Lv.%d" % [game.session.quests.npc_name(chosen["giver"]),game.session.quests.npc_name(chosen["receiver"]),chosen["min_level"]])
	detail_line(detail,chosen["description"])
	if chosen.get("lifecycle","once")!="once":
		var calendar: Dictionary=game.session.quests.catalog.config.get("calendar",{})
		detail_line(detail,("每日任务 · 每日 %02d:00 刷新" % int(calendar.get("reset_hour",0)) if chosen["lifecycle"]=="daily" else "重复任务 · 完成后可再次接受")+"\n累计完成 %d 次" % int(chosen.get("completions",0)),12,Color("f0d18a"))
	detail_line(detail,"任务目标",12,Color("f0d18a"))
	for o: Dictionary in chosen["objectives"]:detail_line(detail,objective_line(o),12,Color("a7dd74"))
	detail_line(detail,"任务奖励",12,Color("f0d18a"))
	detail_line(detail,"金币 %d    经验 %d" % [chosen["reward"]["gold"],chosen["reward"]["xp"]])
	var rewards:=Control.new();rewards.custom_minimum_size=Vector2(250,32);detail.add_child(rewards)
	var x:=0
	for item: String in chosen["reward"]["items"]:
		game.make_slot(rewards,{"place":"reward","id":item,"count":int(chosen["reward"]["items"][item])},Vector2(x,0));x+=36
	if not chosen["reward"]["choices"].is_empty():detail_line(detail,"请选择一项奖励",12,Color("f0d18a"))
	for choice: Dictionary in chosen["reward"]["choices"]:
		var option:=Button.new()
		var option_id: String=choice["id"];var quest_id: String=chosen["id"]
		option.text=("● " if selected_choices.get(quest_id,"")==option_id else "○ ")+game.Catalog.ITEMS[choice["item"]]["name"]+" ×"+str(choice["amount"])
		option.add_theme_font_override("font",game.skin.font);option.add_theme_font_size_override("font_size",12)
		option.pressed.connect(func():selected_choices[quest_id]=option_id;game.show_overlay("quest"))
		detail.add_child(option)
	var id: String=chosen["id"]
	var state: String=chosen["status"]
	if state in ["active","ready"]:
		game.skin.button(node,"取消追踪" if chosen["tracked"] else "追踪任务",Vector2(278,377),func():game.quest_action("quest.track",{"id":id}))
	if state in ["available","ready"]:
		game.skin.button(node,"接受委托" if state=="available" else "领取报酬",Vector2(450,377),func():
			if game.quest_action("quest.accept" if state=="available" else "quest.claim",{"id":id,"choice":selected_choices.get(id,"")}):tab=1 if state=="available" else 2;game.show_overlay("quest"))
	else:text(node,"已完成" if state=="completed" else "进行中",Vector2(481,379),Vector2(70,20))
	text(node,"%d / %d 进行中" % [game.session.quests.active_count(game.session.profile),game.session.quests.catalog.config["limits"]["active"]],Vector2(23,379),Vector2(200,20),11)

func detail_line(parent: VBoxContainer, value: String, size:=12, color:=Color("d4c9b1")) -> void:
	var line:=Label.new()
	line.text=value;line.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
	line.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	line.add_theme_font_override("font",game.skin.font);line.add_theme_font_size_override("font_size",size)
	line.add_theme_color_override("font_color",color);parent.add_child(line)

func objective_line(o: Dictionary) -> String:
	var label: String = ""
	match o["type"]:
		"meet_npc":label="拜访"+game.session.quests.npc_name(o["target"])
		"clear_dungeon":label="通关"+("已接入的任意地下城" if o["target"]=="any" else String(game.session.quests.catalog.config["dungeons"].get(o["target"],o["target"])))
		"kill_monster":label=String(game.session.quests.catalog.config["dungeons"].get(o.get("dungeon",""),""))+" · "+String(game.session.quests.catalog.config.get("monsters",{}).get(o["target"],"目标怪物"))
		"collect_item":label=String(game.Catalog.ITEMS.get(o["target"],{}).get("name",o["target"]))
		"learn_skill":label="学习任意技能一级"
		"disassemble_item":label="在"+game.session.quests.npc_name(o["npc"])+"处分解一件装备"
		"clear_map":label=String(game.session.quests.catalog.config["dungeons"].get(o.get("dungeon",""),"目标地图"))+" · 特殊地图目标"
	var rules: Dictionary=o.get("conditions",{})
	if rules.has("max_elapsed_ms"):label+=" · 限时 %g 秒" % (float(rules["max_elapsed_ms"])/1000.0)
	if rules.has("max_hits_taken"):label+=" · 被击不超过 %d 次" % int(rules["max_hits_taken"])
	if rules.has("max_revives"):label+=" · 复活不超过 %d 次" % int(rules["max_revives"])
	if rules.has("min_party_size"):label+=" · 至少 %d 人" % int(rules["min_party_size"])
	if o.has("difficulty"):
		var names: Array=[]
		for mode: String in o["difficulty"]:names.append({"normal":"普通级","adventure":"冒险级","expert":"勇士级","king":"王者级"}.get(mode,"未知难度"))
		label+="（"+"、".join(names)+"）"
	return "%s  %d / %d" % [label,int(o["current"]),int(o["amount"])]

func dungeon() -> void:
	# One configured selector for both source chapters and later regions.
	game.windows.dungeon()

## Existing right-side guide layout, independent of the dungeon selector.
const GUIDE_SCALE := 2.0 / 3.0
const GUIDE_SIZE := Vector2(159,98)
const GUIDE_ORIGIN := Vector2(641,132)
const GUIDE_TOAST_DROP := 30.0
const GUIDE_TITLE_COLOR := Color("f0d18a")
const GUIDE_BODY_COLOR := Color("c9bda3")
const GUIDE_DONE_COLOR := Color("8fc46a")
const GUIDE_MAX_OBJECTIVES := 3
const GUIDE_TITLE_FONT := 10
const GUIDE_BODY_FONT := 9
const GUIDE_ROW_STEP := 12.0

func refresh_tracker() -> void:
	if not is_instance_valid(tracker):
		_build_tracker()
	var shown: bool = game.character_active and game.overlay=="" and not game.debug_is_open() and game.session.state in ["town","battle"]
	var tracked: Array = []
	var offers: Array = []
	var marks := {}
	for q: Dictionary in game.session.quests.list(game.session.profile,["available","active","ready"]):
		if q["status"]=="ready":marks[q["receiver"]]="?"
		elif q["status"]=="available" and not marks.has(q["giver"]):marks[q["giver"]]="!"
		if q["tracked"]:tracked.append(q)
		elif q["status"]=="available" and offers.is_empty():offers.append(q)
	game.town.quest_marks=marks
	# 常驻：没有追踪任务也显示面板（改用占位与可接提示），方便随时知道下一步做什么。
	tracker.visible=shown
	if not tracker.visible:return
	tracker.position=GUIDE_ORIGIN + (Vector2(0,GUIDE_TOAST_DROP) if game.toast_panel.visible else Vector2.ZERO)
	tracker.modulate.a=1.0 if game.session.state=="town" else 0.92
	var signature := ""
	for q: Dictionary in tracked:
		signature += str(q["id"])+"|"+str(q["status"])
		for o: Dictionary in q["objectives"]:signature+="|"+str(o["id"])+":"+str(o["current"])
		signature += "\n"
	signature += "offer:"+str(offers[0]["id"] if not offers.is_empty() else "")
	if signature == tracker_signature:return
	tracker_signature = signature
	_fill_tracker(tracked, offers)

func _build_tracker() -> void:
	tracker=game.windows.container(game.ui,GUIDE_ORIGIN,GUIDE_SIZE)
	tracker.name="quest_guide"
	tracker.mouse_filter=Control.MOUSE_FILTER_IGNORE
	game.skin.image(tracker,game.skin.texture("quest",14),Vector2.ZERO,GUIDE_SCALE).name="quest_guide_board"
	game.skin.image(tracker,game.skin.texture("quest",0),Vector2(5,4),GUIDE_SCALE).name="quest_guide_icon"
	game.skin.image(tracker,game.skin.texture("quest",1),Vector2(2,30),GUIDE_SCALE).name="quest_guide_rule"
	tracker.set_meta("rows",[])

func _fill_tracker(tracked: Array, offers: Array = []) -> void:
	for row in tracker.get_meta("rows",[]):
		if is_instance_valid(row):row.queue_free()
	var rows: Array = []
	if tracked.is_empty():
		rows.append(_guide_title("任务指引"))
		var idle_y := 34.0
		idle_y=_guide_row(rows,"暂未追踪任务",GUIDE_BODY_COLOR,idle_y)
		if not offers.is_empty():
			var offer: Dictionary = offers[0]
			idle_y=_guide_row(rows,"可接："+String(offer["name"]),GUIDE_TITLE_COLOR,idle_y)
			idle_y=_guide_row(rows,"找 "+game.session.quests.npc_name(offer["giver"]),GUIDE_BODY_COLOR,idle_y)
		tracker.set_meta("rows",rows)
		return
	var q: Dictionary = tracked[0]
	rows.append(_guide_title(str(q["name"])))
	var y := 34.0
	if q["status"]=="ready":
		y=_guide_row(rows,"目标已完成",GUIDE_DONE_COLOR,y)
		y=_guide_row(rows,"回城向 %s 交付"%game.session.quests.npc_name(q["receiver"]),GUIDE_TITLE_COLOR,y)
	else:
		var objectives: Array = q["objectives"]
		for index in mini(objectives.size(),GUIDE_MAX_OBJECTIVES):
			var o: Dictionary = objectives[index]
			var done: bool = int(o["current"]) >= int(o["amount"])
			var mark := "✓" if done else "·"
			y=_guide_row(rows,mark+" "+objective_line(o),GUIDE_DONE_COLOR if done else GUIDE_BODY_COLOR,y)
		if objectives.size() > GUIDE_MAX_OBJECTIVES:
			y=_guide_row(rows,"  另有 %d 项"%(objectives.size()-GUIDE_MAX_OBJECTIVES),GUIDE_BODY_COLOR,y)
		if tracked.size() > 1:
			y=_guide_row(rows,"  另 %d 条追踪中"%(tracked.size()-1),GUIDE_BODY_COLOR,y)
	tracker.set_meta("rows",rows)

func _guide_title(value: String) -> Label:
	var title := Label.new()
	title.text=game.skin.chinese(value)
	title.position=Vector2(36,7)
	title.size=Vector2(116,15)
	title.clip_text=true
	title.add_theme_font_override("font",game.skin.font)
	title.add_theme_font_size_override("font_size",GUIDE_TITLE_FONT)
	title.add_theme_color_override("font_color",GUIDE_TITLE_COLOR)
	title.mouse_filter=Control.MOUSE_FILTER_IGNORE
	tracker.add_child(title)
	return title

func _guide_row(rows: Array, value: String, color: Color, y: float) -> float:
	var label := Label.new()
	label.text=game.skin.chinese(value)
	label.position=Vector2(8,y)
	label.size=Vector2(146,13)
	label.clip_text=true
	label.add_theme_font_override("font",game.skin.font)
	label.add_theme_font_size_override("font_size",GUIDE_BODY_FONT)
	label.add_theme_color_override("font_color",color)
	label.mouse_filter=Control.MOUSE_FILTER_IGNORE
	tracker.add_child(label)
	rows.append(label)
	return y+GUIDE_ROW_STEP
