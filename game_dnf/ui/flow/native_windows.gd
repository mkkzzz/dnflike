extends RefCounted
## Layout reconstruction from the supplied client's IMG families and UI tokens.
## Guide screenshots prove HUD/inventory/map style; unspecified anchors are adapted.
const SELECTOR_EXPORTS := {
	"lorien": "res://assets_local/flow_v1/dungeon_selector_v1/manifest.json",
	"granfloris": "res://assets_local/flow_v1/dungeon_selector_gran_v1/manifest.json",
	"skytower": "res://assets_local/flow_v1/dungeon_selector_sky_v1/manifest.json",
}
const MapLoader = preload("res://scripts/native_map_loader.gd")
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
var original_icons: Dictionary = {}
var native_item_manifest: Dictionary = {}
var native_item_textures: Dictionary = {}
var _selector_packs: Dictionary = {}

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
	# 林纳斯沿用原版躯干插画；其余 NPC 用 .npc 的脸部立绘。
	var face: Texture2D = null if npc == "linus" else (game.town.npc_face(npc) if game.town != null else null)
	var portrait: TextureRect = skin.image(node, face if face != null else skin.texture("dialog_face"), Vector2(8, -61))
	portrait.name = npc + "_dialogue_illustration"
	if face == null:portrait.size = skin.texture("dialog_face").get_size()
	skin.label(node, NPC_NAMES.get(npc, npc), Vector2(215, 18), 16, Color("f0d18a"))
	var line := String(game.town.npc_definition(npc).get("dialogue", ""))
	if line == "":line = "武器是冒险者的伙伴，出发前可别忘了检查。\n森林里的哥布林越来越多，能帮我去调查一下吗？"
	skin.label(node, line, Vector2(215, 51), 13)
	skin.button(node, "委托任务", Vector2(215, 120), func(): game.show_overlay("quest"))
	skin.button(node, "购买物品", Vector2(325, 120), func(): game.show_overlay("shop"))
	skin.button(node, "结束对话", Vector2(600, 120), func(): game.show_overlay(""))
	skin.close_button(node, Vector2(686, 13), func(): game.show_overlay(""))

func quests() -> void:
	var node = board(game.modal, "任务", Rect2(112, 55, 576, 416))
	for i in 3:
		var tab_index := i
		var tab: Button = skin.button(node, ["可接受", "进行中", "已完成"][i], Vector2(17 + i * 84, 41), func(): quest_tab = tab_index; game.show_overlay("quest"), false, "tab")
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
	if id.begins_with("original_"):
		return original_texture(id,"items")
	if id in ["training_coat","training_necklace","scrap_iron"]:
		if item_icons.is_empty():item_icons=JSON.parse_string(FileAccess.get_file_as_string("res://assets_local/items_v2/manifest.json"))
		return load("res://assets_local/items_v2/"+String(item_icons["images"][item_icons["items"][id]]["file"]))
	return game.town.loader.texture(game.town.loader.data["ui"]["items"][id])

func field_texture(id: String) -> Texture2D:
	if not id.begins_with("original_"):return null
	return original_texture(id,"field_images")

func original_texture(id: String, kind: String) -> Texture2D:
	if native_item_manifest.is_empty():native_item_manifest=JSON.parse_string(FileAccess.get_file_as_string("res://assets_local/items_native_v2/manifest.json"))
	if native_item_manifest.get(kind,{}).has(id):
		var key: String=native_item_manifest[kind][id]
		if not native_item_textures.has(key):
			var info: Dictionary=native_item_manifest["images"][key]
			var texture:=AtlasTexture.new()
			texture.atlas=load("res://assets_local/items_native_v2/"+String(info["file"]))
			var region: Array=info["region"]
			texture.region=Rect2(region[0],region[1],region[2],region[3])
			native_item_textures[key]=texture
		return native_item_textures[key]
	if original_icons.is_empty():
		for pack: String in ["items_original_v1","items_original_v2","items_original_v3","items_original_v4","items_original_v5","items_original_v6","items_original_v7","items_original_v8","items_original_v9","items_original_v10","items_original_v11"]:
			var base: String="res://assets_local/"+pack+"/"
			var data: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(base+"manifest.json"))
			for group: String in ["items","field_images"]:
				for item: String in data[group]:original_icons[group+":"+item]=base+String(data["images"][data[group][item]]["file"])
	return load(original_icons[kind+":"+id]) if original_icons.has(kind+":"+id) else null

func hide_tooltip() -> void:
	if is_instance_valid(tip):tip.queue_free()
	tip = null

func item_tip(id: String, rect: Rect2, buying := false, attached := false, instance_uid := "") -> void:
	hide_tooltip()
	var data: Dictionary = game.Catalog.ITEMS[id]
	var rarity: Dictionary = game.Catalog.RARITIES[int(data["rarity"])]
	var is_weapon: bool = data["kind"] == "weapon"
	var definition: Dictionary=game.session.Numbers.shared_config()["equipment"].get(id,{}) if is_weapon else {}
	var properties: Dictionary=definition.get("stats",{})
	var equipped_uid: String=instance_uid if instance_uid!="" else game.session.profile["equipment"].get("weapon","")
	if is_weapon and equipped_uid!="" and game.session.profile["gear"][equipped_uid]["definition"]==id:properties=game.session.Numbers.gear_detail(game.session.profile,equipped_uid)
	var property_rows:=ceili(properties.size()/2.0)
	var height := maxi(280,255+property_rows*17) if is_weapon else 220
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
		skin.label(tip, "装备部位："+String(game.number_windows.SLOT_NAMES.get(game.session.Numbers.shared_config()["equipment"][id]["slot"],"装备")), Vector2(16, 108), 12, Color("cccccc"))
		skin.label(tip, "重量  %.2f kg" % float(data["weight"]), Vector2(163, 108), 11, Color("a59c88"))
		skin.image(tip, skin.texture("common", 230), Vector2(39, 140))
		skin.label(tip, "装备属性", Vector2(16, 152), 12, Color("d4c399"))
		var stat_index:=0
		for stat: String in properties:
			var percent: bool=stat in ["attack_speed","move_speed","cast_speed","physical_crit","magical_crit","hit","evasion"]
			var value_text: String=("%+.1f%%" % (float(properties[stat])*100)) if percent else ("%+.1f" % float(properties[stat]))
			var label: Label=skin.label(tip,"%s %s" % [game.number_windows.NAMES.get(stat,stat),value_text],Vector2(16+(stat_index%2)*125,178+floori(stat_index/2.0)*17),11,Color("a7dd74"))
			label.set_deferred("size",Vector2(124,17));label.clip_text=true
			stat_index+=1
		var uid: String = equipped_uid
		if uid!="" and game.session.profile["gear"][uid]["definition"]==id:
			var instance: Dictionary = game.session.profile["gear"][uid]
			skin.label(tip,"%s · 品质 %d · 强化 +%d%s" % [uid,instance["quality"],instance["reinforce"]," · 已锁定" if instance.get("locked",false) else ""],Vector2(16,183+property_rows*17),10)
			skin.label(tip,"耐久 %d / %d%s" % [instance["durability"],instance["durability_max"]," · 属性已失效" if int(instance["durability"])==0 else ""],Vector2(16,200+property_rows*17),11,Color("ff7777") if int(instance["durability"])==0 else Color("a7dd74"))
		else:skin.label(tip,"具体品质与强化见 O 键的装备管理",Vector2(16,183+property_rows*17),10)
		if (instance_uid!="" and instance_uid in game.session.profile["equipment"].values()) or (instance_uid=="" and game.session.profile["equipped"]==id):skin.label(tip, "已装备", Vector2(211, 151), 11, Color("a7dd74"))
	else:
		skin.label(tip, "任务物品" if data["kind"]=="quest" else "使用效果", Vector2(16, 82), 12, Color("d4c399"))
		skin.label(tip, "恢复 %d HP" % int(data["heal"]) if data.has("heal") else data["description"], Vector2(16, 108), 14, Color("a7dd74"))
		skin.label(tip, "解锁并放在背包内才可交付" if data["kind"]=="quest" else "地下城内使用" if data["kind"]=="consumable" else "可用于后续装备养成", Vector2(16, 142), 12, Color("cccccc"))
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
	var values: Dictionary = game.skill_catalog.get_profile_skill(id,game.session.profile)
	var rank := int(values["rank"])
	var height := 260 if detailed else 178
	var at := slot_tip_anchor(rect, Vector2(300, height))
	tip = skin.item_board(game.ui, Rect2(at, Vector2(300, height)))
	tip.z_index = 100
	tip.set_meta("skill", id)
	skin.label(tip, data["name"], Vector2(16, 12), 16, Color("f0d18a"))
	skin.label(tip, "技能等级 %d" % rank, Vector2(16, 40), 11, Color("b9b1a0")).name = "skill_effective_rank"
	skin.image(tip, game.slot_texture({"place":"skill", "id":id}), Vector2(254, 14))
	var brief: Label = skin.label(tip, data["brief"], Vector2(16, 69), 12)
	brief.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	brief.clip_text = true
	brief.custom_minimum_size = Vector2.ZERO
	brief.set_deferred("size", Vector2(268, 30))
	skin.label(tip, "魔法消耗  %d     冷却  %.1f 秒" % [values["mp"], values["cooldown"]], Vector2(16, 103), 11, Color("a7dd74"))
	var damage: Array = values["damage_lines"]
	if not damage.is_empty():
		var row := String(damage[0])
		if damage.size() > 1:row += "（其余见技能窗）"
		var damage_label: Label = skin.label(tip, row, Vector2(16, 124), 11)
		damage_label.clip_text = true
		damage_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		damage_label.size.x = 268
	if detailed:
		var detail: String = data["detail"]
		if id == "guard":
			var skills = game.session.Numbers.Skills
			var guard_row: Array = skills.sample(game.session.Numbers.record(id),rank)["level_row"]
			var label := "1级正面承伤" if rank == 0 else "当前正面承伤"
			detail += "\n%s  物理 %d%%  魔法 %d%%" % [label,skills.guard_taken_percent(guard_row,"[physic]"),skills.guard_taken_percent(guard_row,"[magic]")]
		var text: Label = skin.label(tip, detail, Vector2(16, 148), 11)
		text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		text.clip_text = true
		text.custom_minimum_size = Vector2.ZERO
		text.set_deferred("size", Vector2(268, 100))
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
	var capacity:=float(game.session.Numbers.profile_stats(game.session.profile)["values"].get("carry_capacity",50))
	for id: String in game.Catalog.ITEMS:
		weight += float(game.Catalog.ITEMS[id]["weight"]) * int(game.session.profile["inventory"].get(id, 0))
	(node.get_node("weight_label") as Label).text = "%.2f / %.0f kg" % [weight,capacity]
	var fill := node.get_node("weight_fill") as TextureRect
	var region := AtlasTexture.new()
	region.atlas = skin.texture("inventory", 1)
	region.region = Rect2(0, 0, maxf(1, floorf(region.atlas.get_width() * minf(weight / maxf(1,capacity), 1.0))), region.atlas.get_height())
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
	var goods: Array=["potion","forest_sword","original_1106","original_1112","original_1107","original_1113"]
	for i in goods.size():game.make_slot(grid,{"place":"shop","index":i,"id":goods[i]},Vector2(2+i*32,2))
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
				var uid: String="gear_%d" % next_gear if game.session.Numbers.shared_config()["equipment"].has(id) else ""
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

func _dungeon_regions() -> Array:
	var scene: Dictionary = game.town.world.scene(game.town.location)
	var regions = scene.get("dungeon_region", "lorien")
	return regions if regions is Array else [regions]

func _selector_pack(regions: Array, choices: Array) -> MapLoader:
	if regions.size() != 1 or choices.is_empty() or game.selected_dungeon == "forest_trial":
		return null
	var region_id := String(regions[0])
	if not SELECTOR_EXPORTS.has(region_id):return null
	if not _selector_packs.has(region_id):
		var loaded := MapLoader.new()
		if not loaded.load_export(SELECTOR_EXPORTS[region_id]):return null
		_selector_packs[region_id] = loaded
	var pack: MapLoader = _selector_packs[region_id]
	var region: Dictionary = pack.data.get("regions", {}).get(region_id, {})
	for id: String in choices:
		if not region.get("cards", {}).has(id):
			return null
	return pack

func move_dungeon_selection(step: int) -> bool:
	var regions := _dungeon_regions()
	var pack := _selector_pack(regions, game.session.dungeon_choices(regions))
	if pack == null:return false
	var order: Array = pack.data["regions"][String(regions[0])].get("keyboard_order", [])
	var current := order.find(game.selected_dungeon)
	if current < 0:return false
	if step == 0:return true
	for distance in range(1, order.size()):
		var id: String = order[posmod(current + step * distance, order.size())]
		if game.session.dungeon_available(id):
			game.selected_dungeon = id
			game.ui_audio.play("map_hover")
			game.show_overlay("dungeon")
			break
	return true

func _selector_image(parent: Control, pack: MapLoader, key: String, at: Vector2, scale_factor := 1.0) -> TextureRect:
	var offset: Array = pack.data["images"][key]["canvas_offset"]
	return skin.image(parent, pack.texture(key), at + Vector2(offset[0], offset[1]) * scale_factor, scale_factor)

func dungeon() -> void:
	var node = container(game.modal, Vector2.ZERO, Vector2(800, 600))
	var regions := _dungeon_regions()
	var choices: Array = game.session.dungeon_choices(regions)
	if game.selected_dungeon=="forest_trial":choices=["forest_trial"]
	if not choices.is_empty() and game.selected_dungeon not in choices:game.selected_dungeon=choices[0]
	var selector_pack := _selector_pack(regions, choices)
	var has_native_layout := selector_pack != null
	var native_region: Dictionary = selector_pack.data["regions"][String(regions[0])] if has_native_layout else {}
	if has_native_layout:
		_selector_image(node, selector_pack, native_region["background"], Vector2.ZERO).name = "dungeon_region_background"
	else:
		skin.image(node, skin.texture("worldmap"), Vector2.ZERO).name = "dungeon_region_background"
	skin.image(node, skin.texture("select", 79), Vector2.ZERO)
	skin.image(node, skin.texture("select", 58), Vector2(104, 0))
	var region_title := String({"granfloris": "格兰之森", "skytower": "天空之城", "lorien": "洛兰"}.get(String(regions[0]), "地下城"))
	skin.label(node, region_title, Vector2(34, 65), 22, Color("f0d18a"))
	var page_size := choices.size() if has_native_layout else 5
	var pages := maxi(1, ceili(float(choices.size()) / page_size))
	game.dungeon_page = clampi(game.dungeon_page, 0, pages - 1)
	var start: int = int(game.dungeon_page) * page_size
	var visible_choices := choices.slice(start, start + page_size)
	if has_native_layout:
		# The expanded card stays on top of any compact card it overlaps.
		visible_choices.erase(game.selected_dungeon)
		visible_choices.append(game.selected_dungeon)
	var locations := [Vector2(300, 230), Vector2(132, 111), Vector2(466, 93), Vector2(562, 292), Vector2(130, 360)]
	var difficulty_position:=Vector2(325,314)
	for i in visible_choices.size():
		var id: String = visible_choices[i]
		var spec: Dictionary = game.session.dungeons[id]
		var unlocked: bool = game.session.dungeon_available(id)
		var chosen: bool = id == game.selected_dungeon
		var at: Vector2
		var hit_size: Vector2
		var pic: TextureRect
		var card: Dictionary
		var missing_card := false
		if has_native_layout:
			card = native_region["cards"][id]
			missing_card = card.get("missing_card_frame", false)
			var anchor: Array = card["expanded" if chosen else "compact"]
			var connector: Array = card["connector"]
			at = Vector2(anchor[0], anchor[1])
			# Source CWorldMap balloon hit bounds and compact image scaling.
			hit_size = Vector2(168, 63) if chosen else Vector2(118, 53)
			_selector_image(node, selector_pack, card["connector_image"], Vector2(connector[0], connector[1]))
			pic = _selector_image(node, selector_pack, card["card"], at, 1.0 if chosen else 0.7)
		else:
			at = locations[i]
			hit_size = Vector2(168, 78)
			pic = skin.image(node, skin.texture("dungeon_cards", i), at)
			if unlocked and not chosen:pic.modulate = Color("b8b8b8")
			skin.label(node, String(spec.get("name", id)), at + Vector2(6, 78), 12,
				Color("f0d18a") if unlocked else Color("8a8578"))
		pic.name = "dungeon_card_" + id
		if chosen:
			pic.name = "selected_dungeon_card"
			difficulty_position = at + Vector2(25, 78) if missing_card else pic.position + Vector2(25, pic.size.y + 4)
		if not unlocked:pic.modulate = Color("666666")
		var hit := Button.new()
		hit.set_meta("dungeon_id",id)
		hit.set_meta("ui_sound","map_select")
		hit.set_meta("ui_sound_hover","map_hover")
		hit.flat = true
		hit.position = at
		hit.size = hit_size
		if has_native_layout:hit.tooltip_text = String(spec.get("name", id))
		if missing_card:
			# Keep the route discoverable when the source engine displays its transparent error frame.
			var compact: Array = card["compact"]
			var caption: Label = skin.label(hit, hit.tooltip_text, Vector2(compact[0], compact[1]) - at, 12,
				Color("f0d18a") if unlocked else Color("8a8578"))
			caption.name = "missing_dungeon_card_caption"
			caption.clip_text = true
			caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			caption.set_deferred("size", Vector2(118, 53))
		hit.pressed.connect(func():
			if not game.session.dungeon_available(id):
				game.notice(dungeon_lock_reason(id))
				return
			game.selected_dungeon = id
			game.show_overlay("dungeon"))
		node.add_child(hit)
		if chosen and not has_native_layout:
			# Card has a 12px crown above its rectangular body. Outline the body,
			# with a native 4px rim; never tile the border across the artwork.
			var selected := NinePatchRect.new()
			selected.texture = skin.texture("select", 22)
			selected.position = at + Vector2(-3, 9)
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
	var levels := ["normal", "adventure", "expert", "king"]
	var current := levels.find(difficulty)
	var bar := container(node, difficulty_position, Vector2(118, 27))
	bar.name = "difficulty_selector"
	skin.image(bar, skin.texture("select", 2), Vector2.ZERO)
	skin.image(bar, skin.texture("select", {"normal":11,"adventure":12,"expert":13,"king":14}[difficulty]), Vector2(36, 4))
	for entry in [[-1, Vector2(0, 4), [3,4,5]], [1, Vector2(98, 4), [7,8,9]]]:
		var next: String = levels[posmod(current + entry[0], levels.size())]
		var button: TextureButton = skin.sprite_button(bar, "select", entry[2], entry[1], func():
			if game.act("flow.difficulty", {"id":next}):game.show_overlay("dungeon"))
		button.name = "difficulty_previous" if entry[0] == -1 else "difficulty_next"
	var enter: TextureButton = skin.sprite_button(node, "select", [164, 165, 166], Vector2(621, 446), game.depart, "进入地下城 Space")
	enter.set_meta("action_label", "进入地下城")
	var back_position := Vector2(699, 541) if has_native_layout else Vector2(631, 528)
	skin.button(node, "返回城镇", back_position, func(): game.show_overlay("")).name = "dungeon_return_town"
	skin.label(node, "%d / %d 页 · 共 %d 个地下城" % [game.dungeon_page + 1, pages, choices.size()], Vector2(34, 569), 11)
	if pages > 1:
		var previous: TextureButton = skin.sprite_button(node, "select", [3, 4, 5], Vector2(34, 540), func(): game.dungeon_page = maxi(0, game.dungeon_page - 1); game.show_overlay("dungeon"), "", "page")
		previous.name = "dungeon_page_previous"
		var following: TextureButton = skin.sprite_button(node, "select", [7, 8, 9], Vector2(232, 540), func(): game.dungeon_page = mini(pages - 1, game.dungeon_page + 1); game.show_overlay("dungeon"), "", "page")
		following.name = "dungeon_page_next"

func result() -> void:
	var r: Dictionary = game.session.result
	var won := bool(r.get("victory", false))
	selected_card = -1
	var node = container(game.modal, Vector2.ZERO, Vector2(800, 600))
	skin.image(node, skin.texture("reward", 33), Vector2.ZERO)
	skin.image(node, skin.texture("reward", 35), Vector2(138, 28))
	skin.label(node, "通关结算" if won else "冒险结束", Vector2(163, 43), 26, Color("f0d18a"))
	skin.label(node, String(game.session.dungeons.get(game.session.run.get("dungeon","forest_trial"),{}).get("name","冒险"))+"  ·  " + {"normal":"普通级", "adventure":"冒险级", "expert":"勇士级", "king":"王者级"}.get(game.session.run.get("difficulty", "normal"), "普通级"), Vector2(166, 91), 14)
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
