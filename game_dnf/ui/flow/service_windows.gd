extends RefCounted
const Services=preload("res://items/services.gd")
const Items=preload("res://items/inventory.gd")
var game
var selected := ""
var detail: Label
var quantity: SpinBox
var confirmation: Control
var page := 0
var npc := ""
func _init(root) -> void:game=root

func select(cell: Dictionary) -> void:
	selected=String(cell.get("uid",""))
	if is_instance_valid(quantity):quantity.max_value=maxi(1,Items.count(game.session.profile,selected));quantity.value=1
	refresh_detail()

func refresh_detail() -> void:
	if not is_instance_valid(detail):return
	var p: Dictionary=game.session.profile
	var id:=Items.definition(p,selected)
	detail.text="单击右侧背包物品，选择出售、分解或修理。"
	if id=="":return
	detail.text="%s ×%d%s" % [game.Catalog.ITEMS[id]["name"],Items.count(p,selected)," · 已锁定" if Items.locked(p,selected) else ""]
	if p["gear"].has(selected):
		var gear: Dictionary=p["gear"][selected]
		detail.text+="\n编号 %s · 品质 %d · 强化 +%d\n耐久 %d / %d%s" % [selected.trim_prefix("gear_"),gear["quality"],gear["reinforce"],gear["durability"],gear["durability_max"],"（属性失效）" if int(gear["durability"])==0 else ""]

func open() -> void:
	npc=game.town.nearest()
	var available: Array=game.town.npc_definition(npc).get("services",[])
	if game.session.state!="town" or not game.town.is_npc(npc) or not available.any(func(id):return id in ["trade","repair","disassemble"]):game.notice("请在服务NPC身旁交谈");return
	var node: Control=game.windows.board(game.modal,game.town.npc_definition(npc)["name"]+" · 装备与物品服务",Rect2(8,16,460,488))
	node.name="service_window"
	detail=game.skin.label(node,"",Vector2(18,47),12,Color("f0d18a"));detail.size=Vector2(420,75);detail.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;detail.name="service_selection"
	quantity=SpinBox.new();quantity.position=Vector2(18,128);quantity.size=Vector2(85,28);quantity.min_value=1;quantity.max_value=99;quantity.step=1;quantity.value=1;node.add_child(quantity);quantity.name="service_quantity"
	if "trade" in available:game.skin.button(node,"出售所选",Vector2(122,130),func():prepare("services.sell",{"uid":selected,"count":int(quantity.value)})).name="service_sell"
	if "disassemble" in available:game.skin.button(node,"分解所选",Vector2(232,130),func():prepare("services.disassemble",{"uid":selected,"count":1})).name="service_disassemble"
	if "repair" in available:
		game.skin.button(node,"修理所选",Vector2(122,171),func():prepare("services.repair",{"uid":selected})).name="service_repair"
		game.skin.button(node,"修理穿戴",Vector2(232,171),func():prepare("services.repair",{"all":true})).name="service_repair_all"
	game.skin.label(node,"穿戴中的装备可在下方选择修理",Vector2(18,212),10)
	var index:=0
	for slot: String in game.session.profile["equipment"]:
		var uid: String=game.session.profile["equipment"][slot]
		game.skin.item_grid(node,Vector2(17+index*46,236),1,1)
		game.make_slot(node,{"place":"service_equipment","uid":uid,"id":Items.definition(game.session.profile,uid)},Vector2(19+index*46,238));index+=1
	game.skin.label(node,"回购记录 · 最近 %d 笔，超出后最早记录清除" % int(Services.config()["buyback_limit"]),Vector2(18,280),10,Color("f0d18a"))
	if "trade" in available:
		var rows: Array=game.session.profile["services"]["buyback"]
		page=clampi(page,0,maxi(0,(rows.size()-1)/3))
		for offset in mini(3,rows.size()-page*3):
			var entry: Dictionary=rows[rows.size()-1-page*3-offset]
			var uid: String=entry["uid"];var id:=Items.definition(game.session.profile,uid)
			game.make_slot(node,{"place":"buyback","uid":uid,"id":id,"count":Items.count(game.session.profile,uid)},Vector2(19,307+offset*37))
			game.skin.label(node,"%s ×%d · %d金币" % [game.Catalog.ITEMS[id]["name"],Items.count(game.session.profile,uid),entry["price"]],Vector2(57,313+offset*37),10)
			var sale: String=entry["id"]
			game.skin.button(node,"回购",Vector2(339,310+offset*37),func():prepare("services.buyback",{"sale":sale}),false).name="buyback_"+sale
		game.skin.button(node,"上一页",Vector2(18,426),func():page=maxi(0,page-1);game.show_overlay("services"),false)
		game.skin.button(node,"下一页",Vector2(122,426),func():page+=1;game.show_overlay("services"),false)
	game.skin.label(node,"金币 %d · 分解不可回购；修理不会解除锁定" % int(game.session.profile["gold"]),Vector2(18,462),10)
	game.windows.inventory()
	refresh_detail()

func prepare(kind: String, data: Dictionary) -> void:
	if is_instance_valid(confirmation):return
	if kind=="services.sell":quantity.apply();data["count"]=int(quantity.value)
	var q:=Services.quote(game.session.profile,kind,data)
	if not q["ok"]:game.notice(q["message"]);return
	var payload:=data.duplicate(true)
	payload["transaction"]="service:%d:%d" % [Time.get_ticks_usec(),game.session.profile["services"]["transactions"].size()]
	payload["signature"]=q["signature"]
	var shield:=Control.new();shield.size=Vector2(800,508);shield.mouse_filter=Control.MOUSE_FILTER_STOP;shield.z_index=150;game.modal.add_child(shield);confirmation=shield;shield.name="service_confirmation"
	var panel: Control=game.skin.panel(shield,Rect2(202,137,396,224))
	var titles: Dictionary={"services.sell":"确认出售","services.buyback":"确认回购","services.disassemble":"确认分解","services.repair":"确认修理"}
	game.skin.label(panel,titles[kind],Vector2(18,14),16,Color("f0d18a"))
	var text: String=String(q["name"])+" ×"+str(q["count"])
	if kind=="services.disassemble":
		text+="\n分解后原装备消失，无法回购。\n预计获得："
		for id: String in q["output"]:text+=game.Catalog.ITEMS[id]["name"]+" ×"+str(q["output"][id])+" "
	else:text+="\n%s %d 金币" % ["获得" if kind=="services.sell" else "花费",q["price"]]
	if kind=="services.sell":text+="\n回购保留原品质、强化、附魔与耐久。"
	var label: Label=game.skin.label(panel,text,Vector2(18,51),12);label.size=Vector2(360,110);label.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
	game.skin.button(panel,"确认操作",Vector2(58,176),func():
		if game.act(kind,payload):shield.queue_free();confirmation=null;game.show_overlay("services"))
	game.skin.button(panel,"取消操作",Vector2(230,176),func():shield.queue_free();confirmation=null)
