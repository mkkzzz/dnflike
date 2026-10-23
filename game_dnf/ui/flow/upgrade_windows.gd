extends RefCounted
const Services=preload("res://items/services.gd")
const Upgrades=preload("res://items/upgrades.gd")
const Items=preload("res://items/inventory.gd")
const Names=preload("res://ui/flow/number_windows.gd")
var game
var selected:=""
var recipe:="strength"
var npc:=""
var detail: Label
var preview: Label
var recipe_buttons: Array=[]
var confirmation: Control
func _init(root) -> void:game=root

func select(cell: Dictionary) -> void:
	game.windows.hide_tooltip();selected=String(cell.get("uid",""));refresh()

func label(parent: Node, text: String, at: Vector2, size: Vector2, font_size:=12) -> Label:
	var node: Label=game.skin.label(parent,text,at,font_size,Color("f0d18a"))
	node.size=size;node.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
	return node

func open() -> void:
	recipe_buttons=[]
	npc=game.town.nearest()
	var available: Array=game.town.npc_definition(npc).get("services",[])
	if game.session.state!="town" or not game.town.is_npc(npc) or not available.any(func(id):return id in ["reinforce","enchant"]):game.notice("请到提供强化或附魔的NPC身旁");return
	var node: Control=game.windows.board(game.modal,game.town.npc_definition(npc)["name"]+" · 装备养成",Rect2(8,16,460,488));node.name="upgrade_window"
	detail=label(node,"",Vector2(18,47),Vector2(420,73));detail.name="upgrade_selection"
	label(node,"单击右侧背包装备，或选择下方穿戴装备",Vector2(18,121),Vector2(420,18),10)
	var index:=0
	for slot: String in game.session.profile["equipment"]:
		var uid: String=game.session.profile["equipment"][slot]
		game.skin.item_grid(node,Vector2(17+index*46,144),1,1)
		game.make_slot(node,{"place":"upgrade_equipment","uid":uid,"id":Items.definition(game.session.profile,uid)},Vector2(19+index*46,146));index+=1
	if "reinforce" in available:
		game.skin.button(node,"强化一级",Vector2(18,190),func():prepare("services.reinforce",{})).name="upgrade_reinforce"
		label(node,"上限 +%d · 每次单独确认" % Upgrades.config()["reinforcement"]["steps"].size(),Vector2(128,194),Vector2(290,22),11)
	if "enchant" in available:
		var recipes: Dictionary=Upgrades.config()["enchants"]
		var choices:=ScrollContainer.new();choices.position=Vector2(18,188);choices.size=Vector2(420,37);choices.vertical_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED;node.add_child(choices)
		var content:=Control.new();content.custom_minimum_size=Vector2(maxi(420,recipes.size()*140),25);choices.add_child(content)
		for id: String in recipes:
			var button: Button=game.skin.button(content,recipes[id]["name"],Vector2(recipe_buttons.size()*140,2),func():recipe=id;refresh())
			button.set_meta("recipe",id);recipe_buttons.append(button)
		game.skin.button(node,"应用附魔",Vector2(18,234),func():prepare("services.enchant",{"recipe":recipe})).name="upgrade_enchant"
		game.skin.button(node,"清除附魔",Vector2(128,234),func():prepare("services.enchant_clear",{})).name="upgrade_enchant_clear"
		label(node,"新附魔会替换旧附魔；清除免费",Vector2(18,272),Vector2(420,22),10)
	preview=label(node,"",Vector2(18,310),Vector2(420,135),11);preview.name="upgrade_preview"
	label(node,"金币 %d · 仅消耗背包中未锁定的材料" % int(game.session.profile["gold"]),Vector2(18,462),Vector2(420,18),10)
	game.windows.inventory();refresh()

func changes(q: Dictionary) -> String:
	var keys: Array=q["before"].keys()
	for stat: String in q["after"]:
		if stat not in keys:keys.append(stat)
	keys.sort()
	var result:=""
	for stat: String in keys:
		var old:=float(q["before"].get(stat,0));var next:=float(q["after"].get(stat,0))
		if not is_equal_approx(old,next):result+="\n%s %s → %s" % [Names.NAMES.get(stat,stat),number(old),number(next)]
	return result

func number(value: float) -> String:
	return str(int(value)) if is_equal_approx(value,floorf(value)) else String.num(value,2)

func bill(q: Dictionary) -> String:
	var result:="%d 金币" % int(q["price"])
	for id: String in q["materials"]:result+=" · %s ×%d（可用%d）" % [game.Catalog.ITEMS[id]["name"],q["materials"][id],Items.stock(game.session.profile,id)]
	return result

func description(q: Dictionary) -> String:
	var result: String=q["name"]+" · 编号 "+String(q["uid"]).trim_prefix("gear_")
	match q["kind"]:
		"services.reinforce":
			result+="\n强化 +%d → +%d · 成功率 %d%%\n失败后 +%d，装备保留，费用与材料消耗。" % [q["from"],q["to"],q["chance"],q["failure_level"]]
		"services.enchant":result+="\n"+String(q["recipe_name"])+" · 成功率 100%\n替换原有全部附魔，不返还旧材料。"
		"services.enchant_clear":result+="\n清除全部附魔，不返还旧材料。"
	result+="\n花费："+bill(q)
	result+="\n成功后装备属性：" if q["kind"]=="services.reinforce" else "\n装备属性变化："
	result+=changes(q)
	return result

func refresh() -> void:
	if not is_instance_valid(detail) or not is_instance_valid(preview):return
	for button in recipe_buttons:
		if is_instance_valid(button):button.modulate=Color("ffdb85") if button.get_meta("recipe")==recipe else Color.WHITE
	var p: Dictionary=game.session.profile
	detail.text="请选择需要养成的装备。"
	preview.text="先选择装备，再核对本次费用与属性变化。"
	if not p["gear"].has(selected):return
	var gear: Dictionary=p["gear"][selected]
	detail.text="%s · 编号%s · 品质%d\n强化 +%d · 耐久 %d/%d%s" % [game.Catalog.ITEMS[gear["definition"]]["name"],selected.trim_prefix("gear_"),gear["quality"],gear["reinforce"],gear["durability"],gear["durability_max"]," · 已锁定" if Items.locked(p,selected) else ""]
	for mod: Dictionary in gear["enchants"]:detail.text+="\n附魔：%s %s" % [Names.NAMES.get(mod["stat"],mod["stat"]),str(mod["value"])]
	var reinforce: bool="reinforce" in game.town.npc_definition(npc)["services"]
	var q:=Services.quote(p,"services.reinforce" if reinforce else "services.enchant",{"uid":selected,"recipe":recipe})
	preview.text=description(q) if q["ok"] else q["message"]

func prepare(kind: String, data: Dictionary) -> void:
	if is_instance_valid(confirmation):return
	data=data.duplicate(true);data["uid"]=selected
	var q:=Services.quote(game.session.profile,kind,data)
	if not q["ok"]:game.notice(q["message"]);return
	data["signature"]=q["signature"];data["transaction"]="upgrade:%d:%d" % [Time.get_ticks_usec(),game.session.profile["services"]["transactions"].size()]
	var shield:=Control.new();shield.size=Vector2(800,508);shield.mouse_filter=Control.MOUSE_FILTER_STOP;shield.z_index=150;game.modal.add_child(shield);confirmation=shield;shield.name="upgrade_confirmation"
	var panel: Control=game.skin.panel(shield,Rect2(184,103,432,300))
	label(panel,"确认装备养成",Vector2(18,14),Vector2(395,26),16)
	label(panel,description(q),Vector2(18,52),Vector2(395,191),12)
	game.skin.button(panel,"确认操作",Vector2(68,257),func():
		if game.act(kind,data):shield.queue_free();confirmation=null;game.show_overlay("upgrades"))
	game.skin.button(panel,"取消操作",Vector2(240,257),func():shield.queue_free();confirmation=null)
