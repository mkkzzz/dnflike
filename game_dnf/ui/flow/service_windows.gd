extends RefCounted
const Services=preload("res://items/services.gd")
const Items=preload("res://items/inventory.gd")
const WindowControls=preload("res://ui/flow/service_window_controls.gd")

const WINDOW_RECT := Rect2(8,16,460,488)

var game
var selected := ""
var detail: Label
var quantity: SpinBox
var confirmation: Control
var page := 0
var npc := ""
var window: Control
var content: Control
var feedback: Label
var busy := false
var window_builds := 0
var content_refreshes := 0

func _init(root) -> void:
	game = root

func open() -> void:
	npc = game.town.nearest()
	var available: Array = game.town.npc_definition(npc).get("services", [])
	if game.session.state != "town" or not game.town.is_npc(npc) \
		or not available.any(func(id): return id in ["trade","repair","disassemble"]):
		game.notice("请在服务NPC身旁交谈")
		return
	if is_instance_valid(window) and not window.is_queued_for_deletion() \
		and window.get_parent() == game.modal:
		_render_content()
		_rebuild_inventory()
		return
	_build_window()

func _build_window() -> void:
	window_builds += 1
	window = game.windows.board(game.modal, game.town.npc_definition(npc)["name"]+" · 装备与物品服务", WINDOW_RECT)
	window.name = "service_window"
	content = Control.new()
	content.name = "service_window_content"
	content.size = WINDOW_RECT.size
	content.mouse_filter = Control.MOUSE_FILTER_PASS
	window.add_child(content)
	feedback = game.skin.label(window, "", Vector2(18,445), 10, Color("e58d7c"))
	feedback.name = "service_window_feedback"
	feedback.size = Vector2(420,14)
	feedback.clip_text = true
	feedback.visible = false
	_render_content()
	_rebuild_inventory()

func _render_content() -> void:
	if not is_instance_valid(content):
		return
	content_refreshes += 1
	WindowControls.clear_feedback(feedback)
	for child in content.get_children():
		content.remove_child(child)
		child.queue_free()
	var available: Array = game.town.npc_definition(npc).get("services", [])
	detail = game.skin.label(content, "", Vector2(18,47), 12, Color("f0d18a"))
	detail.size = Vector2(420,72)
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.name = "service_selection"
	quantity = SpinBox.new()
	quantity.position = Vector2(18,128)
	quantity.size = Vector2(85,28)
	quantity.min_value = 1
	quantity.max_value = 99
	quantity.step = 1
	quantity.value = 1
	quantity.name = "service_quantity"
	quantity.add_theme_font_override("font", game.skin.font)
	quantity.get_line_edit().add_theme_font_override("font", game.skin.font)
	quantity.get_line_edit().add_theme_font_size_override("font_size", 12)
	quantity.value_changed.connect(func(_value: float): refresh_detail())
	content.add_child(quantity)
	if "trade" in available:
		game.skin.button(content, "出售所选", Vector2(122,130),
			func(): prepare("services.sell", {"uid":selected, "count":int(quantity.value)})).name = "service_sell"
	if "disassemble" in available:
		game.skin.button(content, "分解所选", Vector2(232,130),
			func(): prepare("services.disassemble", {"uid":selected, "count":1})).name = "service_disassemble"
	if "repair" in available:
		game.skin.button(content, "修理所选", Vector2(122,171),
			func(): prepare("services.repair", {"uid":selected})).name = "service_repair"
		game.skin.button(content, "修理穿戴", Vector2(232,171),
			func(): prepare("services.repair", {"all":true})).name = "service_repair_all"
	game.skin.label(content, "穿戴中的装备可在下方选择修理", Vector2(18,212), 10)
	var index := 0
	for slot: String in game.session.profile["equipment"]:
		var uid: String = game.session.profile["equipment"][slot]
		game.skin.item_grid(content, Vector2(17+index*46,236), 1, 1)
		game.make_slot(content, {"place":"service_equipment", "uid":uid,
			"id":Items.definition(game.session.profile,uid)}, Vector2(19+index*46,238))
		index += 1
	game.skin.label(content, "回购记录 · 最近 %d 笔，超出后最早记录清除" % int(Services.config()["buyback_limit"]),
		Vector2(18,280), 10, Color("f0d18a"))
	if "trade" in available:
		var rows: Array = game.session.profile["services"]["buyback"]
		page = clampi(page, 0, maxi(0, (rows.size()-1)/3))
		for offset in mini(3, rows.size()-page*3):
			var entry: Dictionary = rows[rows.size()-1-page*3-offset]
			var uid: String = entry["uid"]
			var id := Items.definition(game.session.profile,uid)
			game.make_slot(content, {"place":"buyback", "uid":uid, "id":id,
				"count":Items.count(game.session.profile,uid)}, Vector2(19,307+offset*37))
			game.skin.label(content, "%s ×%d · %d金币" % [
				game.Catalog.ITEMS[id]["name"], Items.count(game.session.profile,uid), entry["price"]],
				Vector2(57,313+offset*37), 10)
			var sale: String = entry["id"]
			game.skin.button(content, "回购", Vector2(339,310+offset*37),
				func(): prepare("services.buyback", {"sale":sale}), false).name = "buyback_"+sale
		var previous: Button = game.skin.button(content, "上一页", Vector2(18,426),
			func(): _change_page(-1), false, "page")
		previous.name = "service_page_previous"
		var following: Button = game.skin.button(content, "下一页", Vector2(122,426),
			func(): _change_page(1), false, "page")
		following.name = "service_page_next"
	game.skin.label(content, "金币 %d · 分解不可回购；修理不会解除锁定" % int(game.session.profile["gold"]),
		Vector2(18,462), 10)
	refresh_detail()

func _change_page(step: int) -> void:
	var rows: Array = game.session.profile["services"]["buyback"]
	var last := maxi(0, (rows.size()-1)/3)
	page = clampi(page+step, 0, last)
	_render_content()

func _rebuild_inventory() -> void:
	WindowControls.replace_named_child(game.modal, "native_inventory")
	game.windows.inventory()

func select(cell: Dictionary) -> void:
	WindowControls.clear_feedback(feedback)
	selected = String(cell.get("uid",""))
	if is_instance_valid(quantity):
		var count := maxi(1, Items.count(game.session.profile,selected))
		quantity.max_value = count
		quantity.value = mini(quantity.value,count)
		quantity.editable = Items.definition(game.session.profile,selected) != "" and Items.count(game.session.profile,selected) > 1
	refresh_detail()

func refresh_detail() -> void:
	if not is_instance_valid(detail):
		return
	var profile: Dictionary = game.session.profile
	var id := Items.definition(profile,selected)
	detail.text = "单击右侧背包物品，选择出售、分解或修理。"
	if id == "":
		return
	detail.text = "%s ×%d%s" % [game.Catalog.ITEMS[id]["name"], Items.count(profile,selected),
		" · 已锁定" if Items.locked(profile,selected) else ""]
	if profile["gear"].has(selected):
		var gear: Dictionary = profile["gear"][selected]
		detail.text += "\n编号 %s · 品质 %d · 强化 +%d\n耐久 %d / %d%s" % [
			selected.trim_prefix("gear_"), gear["quality"], gear["reinforce"],
			gear["durability"], gear["durability_max"], "（属性失效）" if int(gear["durability"]) == 0 else ""]
	if Services.carried(profile,selected) and is_instance_valid(quantity):
		var sell := Services.quote(profile,"services.sell",{"uid":selected,"count":int(quantity.value)})
		if sell["ok"]:
			detail.text += "\n本次出售报价 %d 金币" % int(sell["price"])

func prepare(kind: String, data: Dictionary) -> void:
	if is_instance_valid(confirmation) or busy:
		return
	if selected == "" and kind in ["services.sell","services.disassemble","services.repair"] \
		and not bool(data.get("all",false)):
		_fail_feedback("请先选择背包物品")
		return
	if kind=="services.sell" and is_instance_valid(quantity):
		quantity.apply()
		data["count"] = int(quantity.value)
	var quote := Services.quote(game.session.profile,kind,data)
	if not quote["ok"]:
		_fail_feedback(text_of(quote["message"]))
		return
	var payload := data.duplicate(true)
	payload["transaction"] = WindowControls.transaction_id("service",
		int(game.session.profile["services"]["transactions"].size()))
	payload["signature"] = quote["signature"]
	var shield := Control.new()
	shield.size = Vector2(800,508)
	shield.mouse_filter = Control.MOUSE_FILTER_STOP
	shield.z_index = 150
	game.modal.add_child(shield)
	confirmation = shield
	shield.name = "service_confirmation"
	var panel: Control = game.skin.panel(shield,Rect2(202,137,396,224))
	var titles: Dictionary = {
		"services.sell":"确认出售",
		"services.buyback":"确认回购",
		"services.disassemble":"确认分解",
		"services.repair":"确认修理",
	}
	game.skin.label(panel,titles[kind],Vector2(18,14),16,Color("f0d18a"))
	var text: String = String(quote["name"])+" ×"+str(quote["count"])
	if kind=="services.disassemble":
		text += "\n分解后原装备消失，无法回购。\n预计获得："
		for id: String in quote["output"]:
			text += game.Catalog.ITEMS[id]["name"]+" ×"+str(quote["output"][id])+" "
	else:
		text += "\n%s %d 金币" % ["获得" if kind=="services.sell" else "花费",quote["price"]]
	if kind=="services.sell":
		text += "\n回购保留原品质、强化、附魔与耐久。"
	var description: Label = game.skin.label(panel,text,Vector2(18,51),12)
	description.size = Vector2(360,110)
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var confirm_feedback: Label = game.skin.label(panel,"",Vector2(18,151),10,Color("e58d7c"))
	confirm_feedback.name = "service_confirm_feedback"
	confirm_feedback.size = Vector2(360,14)
	confirm_feedback.clip_text = true
	confirm_feedback.visible = false
	var confirm: Button = game.skin.button(panel,"确认操作",Vector2(58,176),
		func(): _commit(kind,payload,shield))
	confirm.name = "service_confirm"
	var cancel: Button = game.skin.button(panel,"取消操作",Vector2(230,176),
		func(): _close_confirmation(shield))
	cancel.name = "service_cancel"

func _commit(kind: String, payload: Dictionary, shield: Control) -> void:
	if busy:
		return
	var button := shield.find_child("service_confirm",true,false) as Button
	if not is_instance_valid(button) or button.disabled:
		return
	var current := Services.quote(game.session.profile,kind,payload)
	if not current["ok"] or current.get("signature","") != payload.get("signature",""):
		var message := "物品或价格已变化，请重新确认"
		game.notice(message)
		game.ui_audio.play("error")
		_close_confirmation(shield)
		_render_content()
		WindowControls.set_feedback(feedback,message)
		return
	busy = true
	if is_instance_valid(button):
		button.disabled = true
	var ok: bool = game.act(kind,payload)
	if not ok:
		var message := text_of(game.notification)
		WindowControls.set_feedback(feedback,message)
		var inline := shield.find_child("service_confirm_feedback",true,false) as Label
		WindowControls.set_feedback(inline,message)
		busy = false
		if is_instance_valid(button):
			button.disabled = false
		if not message.contains("存档写入失败"):
			_close_confirmation(shield)
			_render_content()
			WindowControls.set_feedback(feedback,message)
		return
	if kind in ["services.sell","services.disassemble"] and selected == String(payload.get("uid","")):
		selected = ""
	busy = false
	_close_confirmation(shield)
	_render_content()
	_rebuild_inventory()

func _close_confirmation(shield: Control) -> void:
	if is_instance_valid(shield):
		shield.queue_free()
	if confirmation == shield:
		confirmation = null
	busy = false

func _fail_feedback(message: String) -> void:
	game.notice(message)
	game.ui_audio.play("error")
	WindowControls.set_feedback(feedback,message)

func text_of(value) -> String:
	return game.skin.chinese(String(value))
