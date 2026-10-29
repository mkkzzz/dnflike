extends RefCounted
## Layout reconstruction from the supplied client's IMG families and UI tokens.
## Guide screenshots prove HUD/inventory/map style; unspecified anchors are adapted.
var game
var skin
var tip: Control
var inventory_tab := 0
var quest_tab := 0
var selected_card := -1
var quest_detail: Control
var purchase: Control
var purchase_count: SpinBox
var shop_page := 0
var skill_tip_id := ""
var skill_tip_rect: Rect2
var item_icons: Dictionary = {}

func _init(root) -> void:
	game = root
	skin = root.skin

func container(parent: Node, at: Vector2, dimensions := Vector2.ZERO) -> Control:
	var node := Control.new()
	node.position = at
	node.size = dimensions
	node.mouse_filter = Control.MOUSE_FILTER_STOP if dimensions != Vector2.ZERO else Control.MOUSE_FILTER_IGNORE
	parent.add_child(node)
	return node

func board(parent: Node, title: String, rect: Rect2) -> Control:
	var node = skin.panel(parent, rect)
	skin.surface(node, Rect2(8, 7, rect.size.x - 16, 26), "quest", 2)
	skin.label(node, title, Vector2(16, 9), 13, Color("f0d18a"))
	skin.close_button(node, Vector2(rect.size.x - 25, 12), func(): game.show_overlay(""))
	return node

const NPC_NAMES := {"linus": "林纳斯", "danjin": "土罐", "seria": "赛丽亚", "grandis": "歌兰蒂斯",
	"albert": "阿尔伯特", "norton": "诺顿", "pungjin": "风振", "kiri": "凯丽", "kanna": "卡妮娜",
	"gsd": "G.S.D", "sinda": "辛达", "shylock": "夏洛克"}

func dialogue(npc := "linus") -> void:
	# Original dialogue board is 718x165. Portrait floats above its left edge.
	var node = container(game.modal, Vector2(41, 343), Vector2(718, 165))
	skin.image(node, skin.texture("dialog"), Vector2.ZERO)
	var face: Texture2D = game.town.npc_face(npc) if game.town != null else null
	var portrait: TextureRect = skin.image(node, face if face != null else skin.texture("dialog_face"), Vector2(8, -61))
	portrait.name = npc + "_dialogue_illustration"
	if face == null:portrait.size = skin.texture("dialog_face").get_size()
	game.town.play_npc_voice(npc, "talk")
	skin.label(node, NPC_NAMES.get(npc, npc), Vector2(215, 18), 16, Color("f0d18a"))
	skin.label(node, "武器是冒险者的伙伴，出发前可别忘了检查。\n森林里的哥布林越来越多，能帮我去调查一下吗？", Vector2(215, 51), 13)
	skin.button(node, "委托任务", Vector2(215, 120), func(): game.show_overlay("quest"))
	skin.button(node, "购买物品", Vector2(325, 120), func(): game.show_overlay("shop"))
	skin.button(node, "结束对话", Vector2(600, 120), func():
		game.town.play_npc_voice(npc, "farewell")
		game.show_overlay(""))
	skin.close_button(node, Vector2(686, 13), func(): game.show_overlay(""))

func quests() -> void:
	var node = board(game.modal, "任务", Rect2(112, 55, 576, 416))
	for i in 3:
		var tab_index := i
		var tab: Button = skin.button(node, ["可接受", "进行中", "已完成"][i], Vector2(17 + i * 84, 41), func(): quest_tab = tab_index; game.show_overlay("quest"), false)
		tab.size.x = 80
		if i == quest_tab:tab.modulate = Color("ffdb85")
	skin.surface(node, Rect2(16, 73, 236, 288), "quest_list", 5)
	skin.surface(node, Rect2(265, 73, 295, 288), "quest", 16)
	var q: String = game.session.profile["quest"]
	var relevant := (quest_tab == 0 and q == "available") or (quest_tab == 1 and q in ["active", "ready"]) or (quest_tab == 2 and q == "done")
	# Follow the actual quest after accepting/completing; manual tab clicks can show empty lists.
	if relevant:
		skin.surface(node, Rect2(20, 78, 228, 21), "quest", 4, 3)
		skin.label(node, "[主线] 森林的异变", Vector2(29, 80), 12, Color("ffdf70"))
		skin.label(node, "林纳斯  ·  Lv.1", Vector2(30, 107), 11)
		var row := Button.new()
		row.position = Vector2(20, 78)
		row.size = Vector2(228, 52)
		row.flat = true
		row.set_meta("quest_id", "forest_trial")
		row.pressed.connect(func(): quest_detail.show())
		node.add_child(row)
	else:skin.label(node, "暂无该类任务", Vector2(53, 106), 12)
	quest_detail = container(node, Vector2(279, 85))
	if relevant:
		skin.label(quest_detail, "森林的异变", Vector2.ZERO, 17, Color("f0d18a"))
		skin.label(quest_detail, "委托人：林纳斯\n地点：格兰之森", Vector2(0, 34), 12)
		skin.label(quest_detail, "调查格兰之森，击败密林领主，\n然后回到艾尔文防线向林纳斯报告。", Vector2(0, 86), 12)
		skin.label(quest_detail, "任务目标", Vector2(0, 140), 12, Color("f0d18a"))
		skin.label(quest_detail, "击败密林领主  %d / 1" % (1 if q in ["ready", "done"] else 0), Vector2(0, 163), 12, Color("a7dd74"))
		skin.label(quest_detail, "任务奖励", Vector2(0, 201), 12, Color("f0d18a"))
		skin.label(quest_detail, "金币 200", Vector2(0, 233), 12)
		game.make_slot(quest_detail, {"place":"reward", "id":"forest_sword", "count":1}, Vector2(105, 228))
		skin.label(quest_detail, "林间太刀", Vector2(139, 233), 12, Color("c6a3ff"))
		if q == "available":skin.button(node, "接受委托", Vector2(450, 377), func():
			if game.act("flow.accept_quest"):quest_tab = 1; game.show_overlay("quest"))
		elif q == "ready":skin.button(node, "领取报酬", Vector2(450, 377), func():
			if game.town.nearest() != "linus":game.notice("请走到林纳斯身旁交付任务")
			elif game.act("flow.claim_quest"):quest_tab = 2; game.show_overlay("quest"))
		else:skin.label(node, "已完成" if q == "done" else "进行中", Vector2(481, 379), 12)
	skin.label(node, "委托记录", Vector2(23, 379), 11, Color("a59c88"))

func item_texture(id: String) -> Texture2D:
	if id in ["training_coat","training_necklace","scrap_iron"]:
		if item_icons.is_empty():item_icons=JSON.parse_string(FileAccess.get_file_as_string("res://assets_local/items_v2/manifest.json"))
		return load("res://assets_local/items_v2/"+String(item_icons["images"][item_icons["items"][id]]["file"]))
	return game.town.loader.texture(game.town.loader.data["ui"]["items"][id])

func hide_tooltip() -> void:
	if is_instance_valid(tip):tip.queue_free()
	tip = null

func item_tip(id: String, rect: Rect2, buying := false, attached := false, instance_uid := "") -> void:
	hide_tooltip()
	var data: Dictionary = game.Catalog.ITEMS[id]
	var rarity: Dictionary = game.Catalog.RARITIES[int(data["rarity"])]
	var is_weapon: bool = data["kind"] == "weapon"
	var height := 280 if is_weapon else 220
	var at := Vector2(rect.position.x - 288, rect.position.y)
	if at.x < 8:at.x = rect.end.x + 8
	at.x = clampf(at.x, 8, 512)
	at.y = clampf(at.y, 8, 508 - height)
	if attached:at = slot_tip_anchor(rect, Vector2(280, height))
	tip = skin.item_board(game.modal, Rect2(at, Vector2(280, height)))
	tip.name = "native_item_detail"
	tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tip.z_index = 100
	# One more native translucent center layer gives readable body contrast.
	skin.surface(tip, Rect2(6, 6, 268, height - 12), "tooltip", 5, 0)
	skin.label(tip, data["name"], Vector2(16, 12), 16, Color(rarity["color"])).name = "tooltip_title"
	skin.label(tip, rarity["name"] + (" · 装备" if is_weapon else " · 消耗品" if data["kind"]=="consumable" else " · 材料"), Vector2(16, 42), 11, Color(rarity["color"]))
	var icon: TextureRect = skin.image(tip, item_texture(id), Vector2(236, 14))
	skin.rarity_frame(icon, int(data["rarity"]), Color(rarity["color"]))
	skin.image(tip, skin.texture("common", 230), Vector2(39, 69))
	if is_weapon:
		skin.label(tip, "需要等级  %d" % int(data["level"]), Vector2(16, 82), 12, Color("a7dd74") if int(game.session.profile["level"]) >= int(data["level"]) else Color("ff7777"))
		skin.label(tip, "鬼剑士可以使用", Vector2(16, 108), 12, Color("cccccc"))
		skin.label(tip, "重量  %.2f kg" % float(data["weight"]), Vector2(163, 108), 11, Color("a59c88"))
		skin.image(tip, skin.texture("common", 230), Vector2(39, 140))
		skin.label(tip, "装备属性", Vector2(16, 152), 12, Color("d4c399"))
		var definition: Dictionary = game.session.Numbers.config()["equipment"][id]
		var detail := ""
		var properties: Dictionary = definition["stats"]
		var equipped_uid: String = instance_uid if instance_uid!="" else game.session.profile["equipment"].get("weapon","")
		if equipped_uid!="" and game.session.profile["gear"][equipped_uid]["definition"]==id:properties = game.session.Numbers.gear_detail(game.session.profile,equipped_uid)
		for stat: String in properties:
			detail += "%s +%s  " % [game.number_windows.NAMES.get(stat,stat),properties[stat]]
		skin.label(tip, detail, Vector2(16, 178), 12, Color("a7dd74"))
		var uid: String = equipped_uid
		if uid!="" and game.session.profile["gear"][uid]["definition"]==id:
			var instance: Dictionary = game.session.profile["gear"][uid]
			skin.label(tip,"%s · 品质 %d · 强化 +%d%s" % [uid,instance["quality"],instance["reinforce"]," · 已锁定" if instance.get("locked",false) else ""],Vector2(16,201),10)
			skin.label(tip,"耐久 %d / %d%s" % [instance["durability"],instance["durability_max"]," · 属性已失效" if int(instance["durability"])==0 else ""],Vector2(16,218),11,Color("ff7777") if int(instance["durability"])==0 else Color("a7dd74"))
		else:skin.label(tip,"具体品质与强化见 O 键的装备管理",Vector2(16,201),10)
		if (instance_uid!="" and instance_uid in game.session.profile["equipment"].values()) or (instance_uid=="" and game.session.profile["equipped"]==id):skin.label(tip, "已装备", Vector2(211, 151), 11, Color("a7dd74"))
	else:
		skin.label(tip, "使用效果", Vector2(16, 82), 12, Color("d4c399"))
		skin.label(tip, "恢复 %d HP" % int(data["heal"]) if data.has("heal") else data["description"], Vector2(16, 108), 14, Color("a7dd74"))
		skin.label(tip, "地下城内使用" if data.has("heal") else "可用于后续装备养成", Vector2(16, 142), 12, Color("cccccc"))
	skin.image(tip, skin.texture("common", 230), Vector2(39, height - 44))
	var hint := "购买价格  %d 金币" % int(data.get("price", 0)) if buying else "持有数量  %d" % int(game.session.profile["inventory"].get(id, 0))
	skin.label(tip, hint, Vector2(16, height - 30), 11, Color("f0d18a") if buying else Color("a59c88"))

func gauge_tip(gauge: Control) -> void:
	hide_tooltip()
	var at := Vector2(86 if gauge.position.x < 400 else 526, 518)
	tip = skin.item_board(game.ui, Rect2(at, Vector2(188, 34)))
	tip.z_index = 100
	tip.set_meta("gauge", gauge)
	var value: Label = skin.label(tip, "", Vector2(12, 7), 12)
	value.name = "gauge_value"
	update_gauge_tip()

func update_gauge_tip() -> void:
	if is_instance_valid(tip) and tip.has_meta("gauge"):
		var gauge: Control = tip.get_meta("gauge")
		(tip.get_node("gauge_value") as Label).text = String(gauge.get_meta("value_text", ""))

func slot_tip_anchor(rect: Rect2, dimensions: Vector2) -> Vector2:
	return Vector2(clampf(rect.position.x, 4, 796 - dimensions.x), maxf(4, rect.position.y - dimensions.y - 3))

func skill_tip(id: String, rect: Rect2, detailed := false) -> void:
	hide_tooltip()
	skill_tip_id = id
	skill_tip_rect = rect
	var data: Dictionary = game.SkillDescriptions.SKILLS[id]
	var values: Dictionary = game.skill_catalog.get_skill(id,int(game.session.profile["skills"].get(id,1)))
	var height := 260 if detailed else 178
	var at := slot_tip_anchor(rect, Vector2(300, height))
	tip = skin.item_board(game.ui, Rect2(at, Vector2(300, height)))
	tip.z_index = 100
	tip.set_meta("skill", id)
	skin.label(tip, data["name"], Vector2(16, 12), 16, Color("f0d18a"))
	skin.label(tip, "技能等级 %d" % int(game.session.profile["skills"].get(id,1)), Vector2(16, 40), 11, Color("b9b1a0"))
	skin.image(tip, game.slot_texture({"place":"skill", "id":id}), Vector2(254, 14))
	skin.label(tip, data["brief"], Vector2(16, 69), 12)
	skin.label(tip, "魔法消耗  %d     冷却  %.1f 秒" % [values["mp"], values["cooldown"]], Vector2(16, 99), 11, Color("a7dd74"))
	var row := "伤害倍率  "
	for value in values["damage_percent"]:row += "%d%%  " % int(value)
	if not values["damage_percent"].is_empty():skin.label(tip, row, Vector2(16, 122), 11)
	if detailed:
		var detail: String = data["detail"]
		if id == "buff":
			var effect: Dictionary = game.session.Numbers.config()["effects"]["frenzy"]
			detail = "持续 %.1f 秒" % (float(effect["duration_ms"])/1000)
			var index := 0
			for mod: Dictionary in effect["modifiers"]:
				if index%2 == 0:detail += "\n"
				detail += "  %s ×%.2f" % [game.number_windows.NAMES.get(mod["stat"],mod["stat"]),float(mod["value"])+float(mod.get("per_level",0))*(int(game.session.profile["skills"][id])-1)]
				index += 1
		if id == "guard":
			var definition: Dictionary = game.session.Numbers.config()["skills"][id]
			detail += "\n当前正面承伤 %.0f%%" % (maxf(0,float(definition["guard_factor"])-(int(game.session.profile["skills"][id])-1)*float(definition["guard_per_level"]))*100)
		var text: Label = skin.label(tip, detail, Vector2(16, 154), 11)
		text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		text.clip_text = true
		text.set_deferred("size", Vector2(268, 76))
	else:skin.label(tip, "按住 Shift 查看详细说明", Vector2(16, 150), 10, Color("b9b1a0"))

func update_skill_detail(detailed: bool) -> void:
	if is_instance_valid(tip) and tip.has_meta("skill"):skill_tip(skill_tip_id, skill_tip_rect, detailed)

func inventory(at := Vector2(484, 16), can_close := true) -> void:
	game.session.Layout.normalize(game.session.profile, game.Catalog.ITEMS)
	var node = container(game.modal, at, Vector2(303, 488))
	node.name = "native_inventory"
	skin.inventory(node)
	if can_close:skin.close_button(node, Vector2(268, 35), func(): game.show_overlay("")).name = "inventory_close"
	var equipped: String = game.session.profile["equipped"]
	var weight := 0.0
	for id: String in game.Catalog.ITEMS:
		weight += float(game.Catalog.ITEMS[id]["weight"]) * int(game.session.profile["inventory"].get(id, 0))
	(node.get_node("weight_label") as Label).text = "%.2f / 50 kg" % weight
	var fill := node.get_node("weight_fill") as TextureRect
	var region := AtlasTexture.new()
	region.atlas = skin.texture("inventory", 1)
	region.region = Rect2(0, 0, maxf(1, floorf(region.atlas.get_width() * minf(weight / 50.0, 1.0))), region.atlas.get_height())
	fill.texture = region
	fill.size = region.get_size()
	var weapon = game.make_slot(node, {"place":"equipment", "id":equipped}, Vector2(210, 88))
	weapon.name = "equipped_weapon"
	for i in 5:
		var tab_index := i
		var tab := node.get_node("inventory_tab_" + str(i)) as Button
		tab.pressed.connect(func(): inventory_tab = tab_index; game.show_overlay(game.overlay))
		tab.button_pressed = i == inventory_tab
	var grid: Control = skin.item_grid(node, Vector2(20, 176), 8, 6)
	grid.name = "native_inventory_grid"
	var category: String = game.session.Layout.KINDS[inventory_tab]
	var cells: Array = game.session.profile["bag_layout"][category]
	for index in cells.size():
		var uid: String=game.session.profile["item_state"]["bags"][category][index]
		game.make_slot(grid, {"place":"bag", "category":category, "index":index, "id":cells[index],"uid":uid,"count":game.session.Inventory.count(game.session.profile,uid)}, Vector2(2 + (index % 8) * 32, 2 + (index / 8) * 32))
	if game.overlay=="inventory":game.inventory_tools.render()
	for entry in [["resurrection_coins", 0, 99, 408, 40], ["duel_points", 0, 232, 408, 40], ["cash_points", 0, 86, 435, 53], ["gold", 0, 224, 435, 48]]:
		var value: Label = skin.label(node, str(int(game.session.profile.get(entry[0], entry[1]))), Vector2(entry[2], entry[3]), 11)
		value.size.x = entry[4]
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		value.name = "inventory_" + String(entry[0])

func shop() -> void:
	# Native board, original eight/seven-column trade grid, scrollbar and paired inventory.
	var node = board(game.modal, "林纳斯 · 商店", Rect2(181, 22, 291, 410))
	skin.surface(node, Rect2(10, 39, 271, 77), "quest", 15)
	skin.image(node, skin.texture("portrait", 9), Vector2(12, 39))
	skin.label(node, "好好保养武器，\n它才能保护你。", Vector2(96, 54), 12)
	skin.label(node, "商品", Vector2(24, 125), 12, Color("f0d18a"))
	var grid: Control = skin.item_grid(node, Vector2(24, 151), 7, 6)
	grid.name = "native_shop_grid"
	# Two real catalog entries live in a scrollable 12-row catalog; empty cells
	# remain empty instead of inventing products just to populate the scrollbar.
	var viewport := container(node, Vector2(24, 151), Vector2(226, 194))
	viewport.clip_contents = true
	grid.reparent(viewport)
	grid.position = Vector2.ZERO
	for i in 2:game.make_slot(grid, {"place":"shop", "index":i, "id":["potion", "forest_sword"][i]}, Vector2(2 + i * 32, 2))
	var more: Control = skin.item_grid(viewport, Vector2(0, 194), 7, 6)
	var scroll := VScrollBar.new()
	scroll.position = Vector2(263, 151)
	scroll.size = Vector2(14, 194)
	scroll.min_value = 0
	scroll.max_value = 388
	scroll.page = 194
	scroll.step = 16
	scroll.value = shop_page
	for state in ["grabber", "grabber_highlight", "grabber_pressed"]:
		var style := StyleBoxTexture.new()
		style.texture = skin.texture("shop", 8)
		style.texture_margin_top = 3
		style.texture_margin_bottom = 3
		scroll.add_theme_stylebox_override(state, style)
	var track := StyleBoxTexture.new()
	track.texture = skin.texture("shop", 13)
	scroll.add_theme_stylebox_override("scroll", track)
	for pair in [["increment",12],["increment_highlight",12],["increment_pressed",12],["decrement",9],["decrement_highlight",9],["decrement_pressed",9]]:scroll.add_theme_icon_override(pair[0], skin.texture("shop", pair[1]))
	scroll.value_changed.connect(func(value: float): shop_page = int(value); grid.position.y = -value; more.position.y = 194 - value)
	node.add_child(scroll)
	scroll.name = "shop_scroll"
	grid.position.y = -shop_page
	more.position.y = 194 - shop_page
	viewport.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed:
			if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:scroll.value += 32; viewport.accept_event()
			elif event.button_index == MOUSE_BUTTON_WHEEL_UP:scroll.value -= 32; viewport.accept_event())
	skin.button(node, "返回", Vector2(100, 378), func(): game.show_overlay("npc"))
	inventory(Vector2(484, 16), false)

func purchase_dialog(id: String, target: Dictionary = {}) -> void:
	hide_tooltip()
	if is_instance_valid(purchase):purchase.queue_free()
	purchase = container(game.ui, Vector2.ZERO, Vector2(800, 600))
	purchase.name = "purchase_confirm"
	purchase.z_index = 200
	var board = skin.panel(purchase, Rect2(228, 165, 344, 220))
	skin.label(board, "确认购买", Vector2(20, 14), 16, Color("f0d18a"))
	skin.image(board, item_texture(id), Vector2(22, 51))
	skin.label(board, game.Catalog.ITEMS[id]["name"], Vector2(62, 54), 13)
	var price := int(game.Catalog.ITEMS[id]["price"])
	skin.label(board, "单价  %d 金币" % price, Vector2(22, 91), 12)
	skin.label(board, "数量", Vector2(22, 126), 12)
	purchase_count = SpinBox.new()
	purchase_count.position = Vector2(73, 121)
	purchase_count.size = Vector2(94, 28)
	purchase_count.min_value = 1
	purchase_count.max_value = mini(999, maxi(1, int(game.session.profile["gold"]) / price))
	purchase_count.value = 1
	purchase_count.add_theme_font_override("font", skin.font)
	board.add_child(purchase_count)
	purchase_count.get_line_edit().add_theme_font_override("font", skin.font)
	purchase_count.get_line_edit().add_theme_font_size_override("font_size", 12)
	var total: Label = skin.label(board, "", Vector2(185, 126), 12, Color("f0d18a"))
	total.text = "总价  %d 金币" % price
	purchase_count.value_changed.connect(func(value: float): total.text = "总价  %d 金币" % (price * int(value)))
	skin.button(board, "确认购买", Vector2(65, 173), func():
		purchase_count.apply()
		var next_gear:=int(game.session.profile["next_gear"])
		if game.act("items.buy", {"id":id, "count":int(purchase_count.value)}):
			if not target.is_empty():
				var category: String = game.Catalog.ITEMS[id]["kind"]
				var index: int = game.session.profile["bag_layout"][category].find(id)
				var uid: String="gear_%d" % next_gear if game.session.Numbers.config()["equipment"].has(id) else ""
				if uid!="":index=game.session.profile["item_state"]["bags"][category].find(uid)
				if index >= 0:game.act("slots.move", {"source":{"place":"bag", "category":category, "index":index, "id":id,"uid":uid}, "target":target})
			purchase.queue_free()
			purchase = null
			game.refresh_item_views())
	skin.button(board, "取消", Vector2(181, 173), close_purchase)

func close_purchase() -> void:
	if is_instance_valid(purchase):purchase.queue_free()
	purchase = null

## 未解锁原因（等级 / 前置任务），用于出征界面提示。
func dungeon_lock_reason(id: String) -> String:
	var spec: Dictionary = game.session.dungeons.get(id, {})
	var need := int(spec.get("min_level", 1))
	if int(game.session.profile["level"]) < need:return "需要等级 %d" % need
	for required: String in spec.get("requires", []):
		if game.session.quests.status(game.session.profile, required) != "completed":return "需要先完成前置任务"
	return "尚未开放"

func dungeon() -> void:
	var node = container(game.modal, Vector2.ZERO, Vector2(800, 600))
	skin.image(node, skin.texture("worldmap"), Vector2.ZERO)
	skin.image(node, skin.texture("select", 79), Vector2.ZERO)
	skin.image(node, skin.texture("select", 58), Vector2(104, 0))
	var scene_data: Dictionary = game.town.world.scene(game.town.location)
	var regions = scene_data.get("dungeon_region", "lorien")
	if not regions is Array:regions = [regions]
	var region_title := String({"granfloris": "格兰之森", "skytower": "天空之城", "lorien": "洛兰"}.get(String(regions[0]), "地下城"))
	skin.label(node, region_title, Vector2(34, 65), 22, Color("f0d18a"))
	# 卡片按当前城镇的副本区动态列出（每页 5 张）；锁定的置灰并给出原因。
	var choices: Array = game.session.dungeon_choices(regions)
	var pages := maxi(1, int(ceil(float(choices.size()) / 5.0)))
	game.dungeon_page = clampi(game.dungeon_page, 0, pages - 1)
	var start: int = int(game.dungeon_page) * 5
	var locations := [Vector2(300, 230), Vector2(132, 111), Vector2(466, 93), Vector2(562, 292), Vector2(130, 360)]
	for i in locations.size():
		var index: int = start + i
		if index >= choices.size():break
		var id: String = choices[index]
		var spec: Dictionary = game.session.dungeons[id]
		var unlocked: bool = game.session.dungeon_available(id)
		var chosen: bool = id == game.selected_dungeon
		var pic = skin.image(node, skin.texture("dungeon_cards", i), locations[i])
		if chosen:pic.name = "selected_dungeon_card"
		if not unlocked:pic.modulate = Color("666666")
		elif not chosen:pic.modulate = Color("b8b8b8")
		skin.label(node, String(spec.get("name", id)), locations[i] + Vector2(6, 78), 12,
			Color("f0d18a") if unlocked else Color("8a8578"))
		var hit := Button.new()
		hit.flat = true
		hit.position = locations[i]
		hit.size = Vector2(168, 78)
		hit.pressed.connect(func():
			if not game.session.dungeon_available(id):
				game.notice(dungeon_lock_reason(id))
				return
			game.selected_dungeon = id
			game.show_overlay("dungeon"))
		node.add_child(hit)
		if chosen:
			# Card has a 12px crown above its rectangular body. Outline the body,
			# with a native 4px rim; never tile the border across the artwork.
			var selected := NinePatchRect.new()
			selected.texture = skin.texture("select", 22)
			selected.position = locations[i] + Vector2(-3, 9)
			selected.size = Vector2(174, 74)
			selected.patch_margin_left = 4
			selected.patch_margin_right = 4
			selected.patch_margin_top = 4
			selected.patch_margin_bottom = 4
			selected.draw_center = false
			selected.mouse_filter = Control.MOUSE_FILTER_IGNORE
			node.add_child(selected)
	if choices.is_empty():
		skin.label(node, "当前城镇没有可用的地下城", Vector2(300, 400), 12, Color("c86a5a"))
	var difficulty: String = game.session.profile.get("difficulty", "normal")
	var levels := ["normal", "adventure", "king"]
	var current := levels.find(difficulty)
	var bar := container(node, Vector2(325, 314), Vector2(118, 27))
	bar.name = "difficulty_selector"
	skin.image(bar, skin.texture("select", 2), Vector2.ZERO)
	skin.image(bar, skin.texture("select", {"normal":11,"adventure":12,"king":14}[difficulty]), Vector2(36, 4))
	for entry in [[-1, Vector2(0, 4), [3,4,5]], [1, Vector2(98, 4), [7,8,9]]]:
		var next: String = levels[posmod(current + entry[0], 3)]
		var button: TextureButton = skin.sprite_button(bar, "select", entry[2], entry[1], func():
			if game.act("flow.difficulty", {"id":next}):game.show_overlay("dungeon"))
		button.name = "difficulty_previous" if entry[0] == -1 else "difficulty_next"
	var enter: TextureButton = skin.sprite_button(node, "select", [164, 165, 166], Vector2(621, 446), game.depart, "进入地下城 Space")
	enter.set_meta("action_label", "进入地下城")
	skin.button(node, "返回城镇", Vector2(631, 528), func(): game.show_overlay(""))
	skin.label(node, "%d / %d 页 · 共 %d 个地下城" % [game.dungeon_page + 1, pages, choices.size()], Vector2(34, 569), 11)
	if pages > 1:
		var previous: TextureButton = skin.sprite_button(node, "select", [3, 4, 5], Vector2(34, 540), func():
			game.dungeon_page = maxi(0, game.dungeon_page - 1)
			game.show_overlay("dungeon"))
		previous.name = "dungeon_page_previous"
		var following: TextureButton = skin.sprite_button(node, "select", [7, 8, 9], Vector2(232, 540), func():
			game.dungeon_page = mini(pages - 1, game.dungeon_page + 1)
			game.show_overlay("dungeon"))
		following.name = "dungeon_page_next"

func result() -> void:
	var r: Dictionary = game.session.result
	var won := bool(r.get("victory", false))
	selected_card = -1
	var node = container(game.modal, Vector2.ZERO, Vector2(800, 600))
	skin.image(node, skin.texture("reward", 33), Vector2.ZERO)
	skin.image(node, skin.texture("reward", 35), Vector2(138, 28))
	skin.label(node, "通关结算" if won else "冒险结束", Vector2(163, 43), 26, Color("f0d18a"))
	skin.label(node, String(game.session.dungeons.get(game.session.run.get("dungeon","forest_trial"),{}).get("name","冒险"))+"  ·  " + {"normal":"普通级", "adventure":"冒险级", "king":"王者级"}.get(game.session.run.get("difficulty", "normal"), "普通级"), Vector2(166, 91), 14)
	var stats: Dictionary = r.get("stats", {})
	skin.label(node, "通关时间    %.1f 秒\n承受伤害    %d\n获得金币    %d\n获得经验    %d" % [float(stats.get("time_ms", 0)) / 1000, int(stats.get("damage_taken", 0)), int(r.get("gold", 0)), int(r.get("xp", 0))], Vector2(166, 125), 14)
	if won:skin.image(node, skin.texture("result", {"S": 3, "A": 6, "B": 7}[r.get("rank", "B")]), Vector2(490, 85))
	else:skin.label(node, "已撤退" if stats.get("reason") == "retreat" else "挑战失败", Vector2(491, 128), 25)
	if won:
		var prompt: Label = skin.label(node, "点击卡牌或按 1 / 2 / 3 / 4 翻开", Vector2(235, 303), 18, Color("f0d18a"))
		prompt.name = "reward_prompt"
		for i in 4:
			var index := i
			var card: TextureButton = skin.sprite_button(node, "reward", [36, 46, 36], Vector2(72 + i * 167, 345), func(): reveal_card(index, node))
			card.name = "reward_card_" + str(i)
			card.set_meta("card_index", i)
			skin.label(node, str(i + 1), Vector2(140 + i * 167, 445), 12)
	var back: Button = skin.button(node, "返回城镇", Vector2(626, 505), game.return_town)
	back.name = "result_return"
	back.disabled = won
	if won and r.has("card_choice"):reveal_card(int(r["card_choice"]), node, false)

func flip_card(index: int) -> void:
	var card := game.modal.find_child("reward_card_" + str(index), true, false) as TextureButton
	if is_instance_valid(card) and not card.disabled:reveal_card(index, card.get_parent())

func reveal_card(index: int, node: Control, persist := true) -> void:
	if selected_card >= 0:return
	if index < 0 or index > 3:return
	selected_card = index
	(node.get_node("reward_prompt") as Label).text = "奖励已收入背包"
	for i in 4:
		var card := node.get_node("reward_card_" + str(i)) as TextureButton
		card.disabled = true
		card.texture_disabled = skin.texture("reward", 41 if i == index else 45)
		if i == index:
			game.make_slot(node, {"place":"reward", "id":"potion", "count":1}, Vector2(133 + i * 167, 365))
			skin.label(node, "恢复药剂 ×1", Vector2(112 + i * 167, 412), 12)
	(node.get_node("result_return") as BaseButton).disabled = false
	# Reward was committed once by Session before rendering. Flipping never pays twice.
	if persist:
		game.session.result["card_choice"] = index
		game.save_profile()
		game.notice("奖励已收入背包")
