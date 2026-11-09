extends RefCounted
const Inventory=preload("res://items/inventory.gd")
const WindowControls=preload("res://ui/flow/inventory_window_controls.gd")

const WINDOW_RECT := Rect2(8,16,460,488)

var game
var selected := ""
var selected_place := ""
var detail: Label
var amount: SpinBox
var window: Control
var content: Control
var feedback: Label
var busy := false
var rebuilding_shared := false
var window_builds := 0
var content_refreshes := 0

func _init(root) -> void:
	game = root

func render() -> void:
	if rebuilding_shared and is_instance_valid(window) \
		and not window.is_queued_for_deletion():
		_render_content()
		return
	if is_instance_valid(window) and not window.is_queued_for_deletion() \
		and window.get_parent() == game.modal:
		_render_content()
		return
	_build_window()

func _build_window() -> void:
	window_builds += 1
	window = game.windows.board(game.modal,"物品管理 · 个人仓库",WINDOW_RECT)
	window.name = "inventory_management"
	content = Control.new()
	content.name = "inventory_management_content"
	content.size = WINDOW_RECT.size
	content.mouse_filter = Control.MOUSE_FILTER_PASS
	window.add_child(content)
	feedback = game.skin.label(window,"",Vector2(17,445),10,Color("e58d7c"))
	feedback.name = "inventory_management_feedback"
	feedback.size = Vector2(420,14)
	feedback.clip_text = true
	feedback.visible = false
	_render_content()

func _render_content() -> void:
	if not is_instance_valid(content):
		return
	content_refreshes += 1
	for child in content.get_children():
		content.remove_child(child)
		child.queue_free()
	var profile: Dictionary = game.session.profile
	var slots: Array = game.session.Numbers.shared_config()["equipment_slots"]
	for index in slots.size():
		var slot: String = slots[index]
		var uid: String = profile["equipment"].get(slot,"")
		game.skin.item_grid(content,Vector2(15+index*47,44),1,1)
		var cell = game.make_slot(content,{"place":"equipment","slot":slot,"uid":uid,
			"id":Inventory.definition(profile,uid)},Vector2(17+index*47,46))
		cell.name = "equipment_"+slot
		game.skin.label(content,["武器","上衣","下装","头肩","腰带","鞋","手镯","项链","戒指"][index],
			Vector2(16+index*47,77),9)
	detail = game.skin.label(content,"",Vector2(17,100),11,Color("f0d18a"))
	detail.size = Vector2(420,38)
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.name = "selected_item_detail"
	game.skin.label(content,"仓库 48 格 · 回城后存取 · 不计入随身持有",Vector2(17,143),11)
	var grid: Control = game.skin.item_grid(content,Vector2(16,167),8,6)
	grid.name = "storage_grid"
	var storage: Array = profile["item_state"]["storage"]
	for index in storage.size():
		var uid: String = storage[index]
		game.make_slot(grid,{"place":"storage","uid":uid,"id":Inventory.definition(profile,uid),
			"index":index,"count":Inventory.count(profile,uid)},Vector2(2+index%8*32,2+(index/8)*32))
	_action_button("整理背包","items_sort",Vector2(292,168),func(): perform("items.sort","items_sort"))
	_action_button("锁定 / 解锁","items_lock",Vector2(292,208),func(): perform("items.lock","items_lock"))
	_action_button("存入仓库","items_deposit",Vector2(292,248),func(): perform("items.deposit","items_deposit"))
	_action_button("取回背包","items_withdraw",Vector2(292,288),func(): perform("items.withdraw","items_withdraw"))
	game.skin.label(content,"拆分数量",Vector2(17,383),11)
	amount = SpinBox.new()
	amount.position = Vector2(90,378)
	amount.size = Vector2(90,28)
	amount.min_value = 1
	amount.max_value = 1
	amount.step = 1
	amount.value = 1
	amount.name = "split_count"
	amount.add_theme_font_override("font",game.skin.font)
	amount.get_line_edit().add_theme_font_override("font",game.skin.font)
	amount.get_line_edit().add_theme_font_size_override("font_size",12)
	content.add_child(amount)
	var split := _action_button("拆分堆叠","items_split",Vector2(197,381),func():
		amount.apply()
		perform("items.split","items_split",{"count":int(amount.value)}))
	split.set_meta("requires_bag",true)
	var overflow: Array = profile["item_state"]["overflow"]
	game.skin.label(content,"待领取 %d 件（旧存档溢出及保底奖励）" % overflow.size(),
		Vector2(17,425),11,Color("f0d18a"))
	_action_button("领取待领物品","items_recover",Vector2(292,423),
		func(): perform("items.recover","items_recover"))
	game.skin.label(content,"堆叠上限按物品配置；锁定物品不合并、不消耗",Vector2(17,465),10)
	refresh_detail()

func _action_button(label: String, node_name: String, at: Vector2, action: Callable) -> Button:
	var button: Button = game.skin.button(content,label,at,action)
	button.name = node_name
	button.focus_mode = Control.FOCUS_ALL
	return button

func select(cell: Dictionary) -> void:
	selected = String(cell.get("uid",""))
	selected_place = String(cell.get("place",""))
	WindowControls.clear_feedback(feedback)
	refresh_detail()

func refresh_detail() -> void:
	if not is_instance_valid(detail):
		return
	var profile: Dictionary = game.session.profile
	var id := Inventory.definition(profile,selected)
	if is_instance_valid(amount):
		var count := Inventory.count(profile,selected)
		amount.max_value = maxi(1,count-1) if id!="" else 1
		amount.value = mini(amount.value,amount.max_value)
		amount.editable = id!="" and selected_place=="bag" and not profile["gear"].has(selected) and count>1
	detail.text = "单击格子选择物品；双击装备穿戴"
	if id != "":
		var place := "仓库" if selected in profile["item_state"]["storage"] else "背包"
		if selected_place=="equipment":
			place = "穿戴"
		detail.text = "%s  ×%d%s\n%s%s" % [
			game.Catalog.ITEMS[id]["name"],
			Inventory.count(profile,selected),
			" · 编号 "+selected.trim_prefix("gear_") if profile["gear"].has(selected) else "",
			"已锁定 · " if Inventory.locked(profile,selected) else "",
			place,
		]
	_update_actions(id)

func _update_actions(id: String) -> void:
	var profile: Dictionary = game.session.profile
	for entry in [["items_lock",id!="" and selected_place!="equipment"],
		["items_split",id!="" and selected_place=="bag" and not profile["gear"].has(selected) \
			and Inventory.count(profile,selected)>1],
		["items_deposit",id!="" and selected_place=="bag"],
		["items_withdraw",id!="" and selected_place=="storage"]]:
		var button := content.find_child(String(entry[0]),true,false) as Button
		if is_instance_valid(button):
			button.disabled = not bool(entry[1])

func perform(kind: String, focus_name := "", extra: Dictionary = {}) -> void:
	if busy:
		return
	if kind in ["items.lock","items.split","items.deposit","items.withdraw"] and selected=="":
		_fail("请先选择物品")
		return
	busy = true
	var payload := {"uid":selected}
	payload.merge(extra,true)
	var overflow_before: int = game.session.profile["item_state"]["overflow"].size()
	var ok: bool = game.act(kind,payload)
	busy = false
	if not ok:
		_fail(String(game.notification))
		return
	if selected != "":
		if selected in game.session.profile["item_state"]["storage"]:
			selected_place = "storage"
		elif selected in game.session.profile["equipment"].values():
			selected_place = "equipment"
		elif Inventory.locate(game.session.profile,selected).size() > 0:
			selected_place = "bag"
		else:
			selected = ""
			selected_place = ""
	var message := ""
	match kind:
		"items.lock": message = "物品已解锁" if not Inventory.locked(game.session.profile,selected) else "物品已锁定"
		"items.split": message = "堆叠已拆分"
		"items.deposit": message = "物品已存入仓库"
		"items.withdraw": message = "物品已取回背包"
		"items.sort": message = "背包已整理"
		"items.recover":
			var remaining: int = game.session.profile["item_state"]["overflow"].size()
			var recovered: int = overflow_before-remaining
			message = "已领取 %d 件物品" % recovered if remaining==0 else "背包空间不足，仍有 %d 件待领取" % remaining
	_rebuild_shared()
	WindowControls.set_feedback(feedback,message)
	if focus_name!="":
		call_deferred("_restore_focus",focus_name)

func _rebuild_shared() -> void:
	var old: Node = game.modal.get_node_or_null("native_inventory")
	if is_instance_valid(old):
		game.modal.remove_child(old)
		old.queue_free()
	rebuilding_shared = true
	game.windows.inventory()
	rebuilding_shared = false

func _restore_focus(node_name: String) -> void:
	var button := content.find_child(node_name,true,false) as Button
	if is_instance_valid(button) and not button.disabled:
		button.grab_focus()

func _fail(message: String) -> void:
	game.notice(message)
	game.ui_audio.play("error")
	WindowControls.set_feedback(feedback,message)
