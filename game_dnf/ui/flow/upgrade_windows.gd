extends RefCounted
const Services=preload("res://items/services.gd")
const Upgrades=preload("res://items/upgrades.gd")
const Items=preload("res://items/inventory.gd")
const Names=preload("res://ui/flow/number_windows.gd")
const WindowControls=preload("res://ui/flow/service_window_controls.gd")

const WINDOW_RECT := Rect2(8,16,460,488)

var game
var selected := ""
var recipe := "strength"
var npc := ""
var detail: Label
var preview: Label
var recipe_buttons: Array[Button] = []
var confirmation: Control
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
		or not available.any(func(id): return id in ["reinforce","enchant"]):
		game.notice("请到提供强化或附魔的NPC身旁")
		return
	if is_instance_valid(window) and not window.is_queued_for_deletion() \
		and window.get_parent() == game.modal:
		_render_content()
		_rebuild_inventory()
		return
	_build_window()

func _build_window() -> void:
	window_builds += 1
	window = game.windows.board(game.modal,game.town.npc_definition(npc)["name"]+" · 装备养成",WINDOW_RECT)
	window.name = "upgrade_window"
	content = Control.new()
	content.name = "upgrade_window_content"
	content.size = WINDOW_RECT.size
	content.mouse_filter = Control.MOUSE_FILTER_PASS
	window.add_child(content)
	feedback = game.skin.label(window,"",Vector2(18,447),10,Color("e58d7c"))
	feedback.name = "upgrade_window_feedback"
	feedback.size = Vector2(420,14)
	feedback.clip_text = true
	feedback.visible = false
	_render_content()
	_rebuild_inventory()

func _render_content() -> void:
	if not is_instance_valid(content):
		return
	content_refreshes += 1
	recipe_buttons.clear()
	WindowControls.clear_feedback(feedback)
	for child in content.get_children():
		content.remove_child(child)
		child.queue_free()
	var available: Array = game.town.npc_definition(npc).get("services", [])
	detail = label(content,"",Vector2(18,47),Vector2(420,73))
	detail.name = "upgrade_selection"
	label(content,"单击右侧背包装备，或选择下方穿戴装备",Vector2(18,121),Vector2(420,18),10)
	var index := 0
	for slot: String in game.session.profile["equipment"]:
		var uid: String = game.session.profile["equipment"][slot]
		game.skin.item_grid(content,Vector2(17+index*46,144),1,1)
		game.make_slot(content,{"place":"upgrade_equipment","uid":uid,
			"id":Items.definition(game.session.profile,uid)},Vector2(19+index*46,146))
		index += 1
	if "reinforce" in available:
		game.skin.button(content,"强化一级",Vector2(18,190),
			func(): prepare("services.reinforce",{})).name = "upgrade_reinforce"
		label(content,"上限 +%d · 每次单独确认" % Upgrades.config()["reinforcement"]["steps"].size(),
			Vector2(128,194),Vector2(290,22),11)
	if "enchant" in available:
		var recipes: Dictionary = Upgrades.config()["enchants"]
		var choices := ScrollContainer.new()
		choices.position = Vector2(18,188)
		choices.size = Vector2(420,37)
		choices.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		choices.name = "upgrade_recipe_scroll"
		content.add_child(choices)
		var recipe_content := Control.new()
		recipe_content.name = "upgrade_recipe_content"
		recipe_content.custom_minimum_size = Vector2(maxi(420,recipes.size()*140),25)
		choices.add_child(recipe_content)
		for id: String in recipes:
			var button: Button = game.skin.button(recipe_content,recipes[id]["name"],
				Vector2(recipe_buttons.size()*140,2),func():
					recipe = id
					WindowControls.clear_feedback(feedback)
					refresh())
			button.name = "upgrade_recipe_"+id
			button.set_meta("recipe",id)
			recipe_buttons.append(button)
		game.skin.button(content,"应用附魔",Vector2(18,234),
			func(): prepare("services.enchant",{"recipe":recipe})).name = "upgrade_enchant"
		game.skin.button(content,"清除附魔",Vector2(128,234),
			func(): prepare("services.enchant_clear",{})).name = "upgrade_enchant_clear"
		label(content,"新附魔会替换旧附魔；清除免费",Vector2(18,272),Vector2(420,22),10)
	preview = label(content,"",Vector2(18,310),Vector2(420,135),11)
	preview.name = "upgrade_preview"
	label(content,"金币 %d · 仅消耗背包中未锁定的材料" % int(game.session.profile["gold"]),
		Vector2(18,466),Vector2(420,18),10)
	refresh()

func _rebuild_inventory() -> void:
	WindowControls.replace_named_child(game.modal,"native_inventory")
	game.windows.inventory()

func select(cell: Dictionary) -> void:
	game.windows.hide_tooltip()
	selected = String(cell.get("uid",""))
	WindowControls.clear_feedback(feedback)
	refresh()

func label(parent: Node, text: String, at: Vector2, size: Vector2, font_size := 12) -> Label:
	var node: Label = game.skin.label(parent,text,at,font_size,Color("f0d18a"))
	node.size = size
	node.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return node

func changes(quote: Dictionary) -> String:
	var keys: Array = quote["before"].keys()
	for stat: String in quote["after"]:
		if stat not in keys:
			keys.append(stat)
	keys.sort()
	var result := ""
	for stat: String in keys:
		var old := float(quote["before"].get(stat,0))
		var next := float(quote["after"].get(stat,0))
		if not is_equal_approx(old,next):
			result += "\n%s %s → %s" % [Names.NAMES.get(stat,stat),number(old),number(next)]
	return result

func number(value: float) -> String:
	return str(int(value)) if is_equal_approx(value,floorf(value)) else String.num(value,2)

func bill(quote: Dictionary) -> String:
	var result := "%d 金币" % int(quote["price"])
	for id: String in quote["materials"]:
		result += " · %s ×%d（可用%d）" % [game.Catalog.ITEMS[id]["name"],
			quote["materials"][id],Items.stock(game.session.profile,id)]
	return result

func description(quote: Dictionary) -> String:
	var result: String = quote["name"]+" · 编号 "+String(quote["uid"]).trim_prefix("gear_")
	match quote["kind"]:
		"services.reinforce":
			result += "\n强化 +%d → +%d · 成功率 %d%%\n失败后 +%d，装备保留，费用与材料消耗。" % [
				quote["from"],quote["to"],quote["chance"],quote["failure_level"]]
		"services.enchant":
			result += "\n"+String(quote["recipe_name"])+" · 成功率 100%\n替换原有全部附魔，不返还旧材料。"
		"services.enchant_clear":
			result += "\n清除全部附魔，不返还旧材料。"
	result += "\n花费："+bill(quote)
	result += "\n成功后装备属性：" if quote["kind"]=="services.reinforce" else "\n装备属性变化："
	result += changes(quote)
	return result

func refresh() -> void:
	if not is_instance_valid(detail) or not is_instance_valid(preview):
		return
	for button in recipe_buttons:
		if is_instance_valid(button):
			button.modulate = Color("ffdb85") if button.get_meta("recipe") == recipe else Color.WHITE
	var profile: Dictionary = game.session.profile
	detail.text = "请选择需要养成的装备。"
	preview.text = "先选择装备，再核对本次费用与属性变化。"
	if not profile["gear"].has(selected):
		return
	var gear: Dictionary = profile["gear"][selected]
	detail.text = "%s · 编号%s · 品质%d\n强化 +%d · 耐久 %d/%d%s" % [
		game.Catalog.ITEMS[gear["definition"]]["name"],selected.trim_prefix("gear_"),gear["quality"],
		gear["reinforce"],gear["durability"],gear["durability_max"],
		" · 已锁定" if Items.locked(profile,selected) else ""]
	for modifier: Dictionary in gear["enchants"]:
		detail.text += "\n附魔：%s %s" % [Names.NAMES.get(modifier["stat"],modifier["stat"]),str(modifier["value"])]
	var reinforce: bool = "reinforce" in game.town.npc_definition(npc)["services"]
	var quote := Services.quote(profile,"services.reinforce" if reinforce else "services.enchant",
		{"uid":selected,"recipe":recipe})
	preview.text = description(quote) if quote["ok"] else text_of(quote["message"])

func prepare(kind: String, data: Dictionary) -> void:
	if is_instance_valid(confirmation) or busy:
		return
	if selected == "":
		_fail_feedback("请先选择需要养成的装备")
		return
	data = data.duplicate(true)
	data["uid"] = selected
	var quote := Services.quote(game.session.profile,kind,data)
	if not quote["ok"]:
		_fail_feedback(text_of(quote["message"]))
		return
	data["signature"] = quote["signature"]
	data["transaction"] = WindowControls.transaction_id("upgrade",
		int(game.session.profile["services"]["transactions"].size()))
	var shield := Control.new()
	shield.size = Vector2(800,508)
	shield.mouse_filter = Control.MOUSE_FILTER_STOP
	shield.z_index = 150
	game.modal.add_child(shield)
	confirmation = shield
	shield.name = "upgrade_confirmation"
	var panel: Control = game.skin.panel(shield,Rect2(184,103,432,300))
	label(panel,"确认装备养成",Vector2(18,14),Vector2(395,26),16)
	label(panel,description(quote),Vector2(18,52),Vector2(395,191),12)
	var confirm_feedback := label(panel,"",Vector2(18,232),Vector2(395,14),10)
	confirm_feedback.name = "upgrade_confirm_feedback"
	confirm_feedback.add_theme_color_override("font_color",Color("e58d7c"))
	confirm_feedback.clip_text = true
	confirm_feedback.visible = false
	var confirm: Button = game.skin.button(panel,"确认操作",Vector2(68,257),
		func(): _commit(kind,data,shield))
	confirm.name = "upgrade_confirm"
	var cancel: Button = game.skin.button(panel,"取消操作",Vector2(240,257),
		func(): _close_confirmation(shield))
	cancel.name = "upgrade_cancel"

func _commit(kind: String, data: Dictionary, shield: Control) -> void:
	if busy:
		return
	var button := shield.find_child("upgrade_confirm",true,false) as Button
	if not is_instance_valid(button) or button.disabled:
		return
	var current := Services.quote(game.session.profile,kind,data)
	if not current["ok"] or current.get("signature","") != data.get("signature",""):
		var message := "物品、价格或随机状态已变化，请重新确认"
		game.notice(message)
		game.ui_audio.play("error")
		_close_confirmation(shield)
		_render_content()
		WindowControls.set_feedback(feedback,message)
		return
	busy = true
	if is_instance_valid(button):
		button.disabled = true
	var ok: bool = game.act(kind,data)
	if not ok:
		var message := text_of(game.notification)
		WindowControls.set_feedback(feedback,message)
		var inline := shield.find_child("upgrade_confirm_feedback",true,false) as Label
		WindowControls.set_feedback(inline,message)
		busy = false
		if is_instance_valid(button):
			button.disabled = false
		if not message.contains("存档写入失败"):
			_close_confirmation(shield)
			_render_content()
			WindowControls.set_feedback(feedback,message)
		return
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
