extends RefCounted
const Inventory=preload("res://items/inventory.gd")
var game
var selected := ""
var selected_place := ""
var detail: Label
var amount: SpinBox

func _init(root) -> void:game=root

func select(cell: Dictionary) -> void:
	selected=String(cell.get("uid",""));selected_place=String(cell.get("place",""));refresh_detail()

func refresh_detail() -> void:
	if not is_instance_valid(detail):return
	var p: Dictionary=game.session.profile
	var id:=Inventory.definition(p,selected)
	if is_instance_valid(amount):amount.max_value=maxi(1,Inventory.count(p,selected)-1) if id!="" else 1
	detail.text="单击格子选择物品；双击装备穿戴"
	if id!="":detail.text="%s  ×%d%s\n%s%s" % [game.Catalog.ITEMS[id]["name"],Inventory.count(p,selected)," · 编号 "+selected.trim_prefix("gear_") if p["gear"].has(selected) else "", "已锁定 · " if Inventory.locked(p,selected) else "", "仓库" if selected in p["item_state"]["storage"] else "背包"]

func perform(kind: String, extra: Dictionary={}) -> void:
	var payload: Dictionary={"uid":selected};payload.merge(extra,true)
	if game.act(kind,payload):game.refresh_item_views()

func render() -> void:
	var p: Dictionary=game.session.profile
	var node: Control=game.windows.board(game.modal,"物品管理 · 个人仓库",Rect2(8,16,460,488))
	node.name="inventory_management"
	var slots: Array=game.session.Numbers.config()["equipment_slots"]
	for i in slots.size():
		var slot: String=slots[i];var uid: String=p["equipment"].get(slot,"")
		game.skin.item_grid(node,Vector2(15+i*47,44),1,1)
		var cell=game.make_slot(node,{"place":"equipment","slot":slot,"uid":uid,"id":Inventory.definition(p,uid)},Vector2(17+i*47,46))
		cell.name="equipment_"+slot
		game.skin.label(node,["武器","上衣","下装","头肩","腰带","鞋","手镯","项链","戒指"][i],Vector2(16+i*47,77),9)
	detail=game.skin.label(node,"",Vector2(17,100),11,Color("f0d18a"));detail.name="selected_item_detail"
	game.skin.label(node,"仓库 48 格 · 回城后存取 · 不计入随身持有",Vector2(17,143),11)
	var grid: Control=game.skin.item_grid(node,Vector2(16,167),8,6);grid.name="storage_grid"
	var storage: Array=p["item_state"]["storage"]
	for i in storage.size():
		var uid: String=storage[i]
		game.make_slot(grid,{"place":"storage","uid":uid,"id":Inventory.definition(p,uid),"index":i,"count":Inventory.count(p,uid)},Vector2(2+i%8*32,2+(i/8)*32))
	for entry in [["整理背包","items.sort",Vector2(292,168)],["锁定 / 解锁","items.lock",Vector2(292,208)],["存入仓库","items.deposit",Vector2(292,248)],["取回背包","items.withdraw",Vector2(292,288)]]:
		var kind: String=entry[1]
		var button: Button=game.skin.button(node,entry[0],entry[2],func():perform(kind));button.name=kind.replace(".","_")
	game.skin.label(node,"拆分数量",Vector2(17,383),11)
	amount=SpinBox.new();amount.position=Vector2(90,378);amount.size=Vector2(90,28);amount.min_value=1;amount.max_value=1;amount.step=1;amount.value=1;node.add_child(amount);amount.name="split_count"
	game.skin.button(node,"拆分堆叠",Vector2(197,381),func():amount.apply();perform("items.split",{"count":int(amount.value)})).name="items_split"
	var overflow: Array=p["item_state"]["overflow"]
	game.skin.label(node,"待领取 %d 件（旧存档溢出及保底奖励）" % overflow.size(),Vector2(17,425),11,Color("f0d18a"))
	game.skin.button(node,"领取待领物品",Vector2(292,423),func():perform("items.recover")).name="items_recover"
	game.skin.label(node,"堆叠上限按物品配置；锁定物品不合并、不消耗",Vector2(17,460),10)
	refresh_detail()
