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

func dialogue() -> void:
	# Original dialogue board is 718x165. Portrait floats above its left edge.
	var node = container(game.modal, Vector2(41, 343), Vector2(718, 165))
	skin.image(node, skin.texture("dialog"), Vector2.ZERO)
	var portrait: TextureRect = skin.image(node, skin.texture("dialog_face"), Vector2(8, -61))
	portrait.name = "linus_dialogue_illustration"
	skin.label(node, "林纳斯", Vector2(215, 18), 16, Color("f0d18a"))
	skin.label(node, "武器是冒险者的伙伴，出发前可别忘了检查。\n森林里的哥布林越来越多，能帮我去调查一下吗？", Vector2(215, 51), 13)
	skin.button(node, "委托任务", Vector2(215, 120), func(): game.show_overlay("quest"))
	skin.button(node, "购买物品", Vector2(325, 120), func(): game.show_overlay("shop"))
	skin.button(node, "结束对话", Vector2(600, 120), func(): game.show_overlay(""))
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
		skin.image(quest_detail, item_texture("forest_sword"), Vector2(105, 228))
		skin.label(quest_detail, "林间太刀", Vector2(139, 233), 12, Color("c6a3ff"))
		if q == "available":skin.button(node, "接受委托", Vector2(450, 377), func():
			if game.act("flow.accept_quest"):quest_tab = 1; game.show_overlay("quest"))
		elif q == "ready":skin.button(node, "领取报酬", Vector2(450, 377), func():
			if game.town.nearest() != "linus":game.notice("请走到林纳斯身旁交付任务")
			elif game.act("flow.claim_quest"):quest_tab = 2; game.show_overlay("quest"))
		else:skin.label(node, "已完成" if q == "done" else "进行中", Vector2(481, 379), 12)
	skin.label(node, "委托记录", Vector2(23, 379), 11, Color("a59c88"))

func item_texture(id: String) -> Texture2D:
	return game.town.loader.texture(game.town.loader.data["ui"]["items"][id])

func hide_tooltip() -> void:
	if is_instance_valid(tip):tip.queue_free()
	tip = null

func item_tip(id: String, rect: Rect2, buying := false) -> void:
	hide_tooltip()
	var data: Dictionary = game.Catalog.ITEMS[id]
	var at := Vector2(rect.position.x - 260, rect.position.y)
	if at.x < 8:at.x = rect.end.x + 8
	at.x = clampf(at.x, 8, 540)
	at.y = clampf(at.y, 8, 306)
	tip = skin.item_board(game.modal, Rect2(at, Vector2(252, 202)))
	tip.name = "native_item_detail"
	tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tip.z_index = 100
	skin.image(tip, item_texture(id), Vector2(15, 14))
	skin.label(tip, data["name"], Vector2(54, 13), 15, Color("c6a3ff") if id == "forest_sword" else Color("eeeeee"))
	skin.label(tip, "已装备" if game.session.profile["equipped"] == id else "消耗品" if data["kind"] != "weapon" else "武器 · 太刀", Vector2(54, 36), 11, Color("a7dd74"))
	skin.label(tip, "等级要求：1\n鬼剑士可以使用" if data["kind"] == "weapon" else "携带数量：%d" % int(game.session.profile["inventory"].get(id, 0)), Vector2(16, 72), 12, Color("cccccc"))
	skin.label(tip, data["description"], Vector2(16, 123), 12, Color("a7dd74"))
	skin.label(tip, "购买价格：%d 金币" % int(data["price"]) if buying else "点击装备" if data["kind"] == "weapon" else "点击使用 · 地下城内有效", Vector2(16, 169), 12, Color("f0d18a"))

func item_slot(parent: Node, id: String, at: Vector2, action: Callable, buying := false) -> Button:
	var hit := Button.new()
	hit.position = at
	hit.size = Vector2(28, 28)
	hit.flat = true
	hit.focus_mode = Control.FOCUS_NONE
	# The original icon already contains its dark cavity texture. Keep it
	# inside the 28px hit area; generic Button hover/pressed plates cover it.
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		hit.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	var icon: TextureRect = skin.image(hit, item_texture(id), Vector2.ZERO)
	icon.name = "item_icon"
	# Custom tooltip replaces the engine's default popup while preserving accessible name.
	hit.set_meta("item_name", game.Catalog.ITEMS[id]["name"])
	hit.set_meta("item_id", id)
	hit.mouse_entered.connect(func(): item_tip(id, hit.get_global_rect(), buying))
	hit.mouse_exited.connect(hide_tooltip)
	hit.pressed.connect(func(): hide_tooltip(); action.call())
	parent.add_child(hit)
	return hit

func inventory(at := Vector2(484, 22), can_close := true) -> void:
	var node = container(game.modal, at, Vector2(303, 476))
	node.name = "native_inventory"
	skin.inventory(node)
	if can_close:skin.close_button(node, Vector2(255, 8), func(): game.show_overlay(""))
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
	item_slot(node, equipped, Vector2(177, 88), func(): pass)
	for i in 5:
		var tab_index := i
		var tab := node.get_node("inventory_tab_" + str(i)) as Button
		tab.pressed.connect(func(): inventory_tab = tab_index; game.show_overlay(game.overlay))
		if i == inventory_tab:tab.modulate = Color("fff3ac")
	var grid: Control = skin.item_grid(node, Vector2(20, 218), 8, 4)
	grid.name = "native_inventory_grid"
	var index := 0
	for id: String in game.Catalog.ITEMS:
		var qty := int(game.session.profile["inventory"].get(id, 0))
		var kind: String = game.Catalog.ITEMS[id]["kind"]
		if qty < 1 or (inventory_tab == 0 and kind != "weapon") or (inventory_tab == 1 and kind == "weapon") or inventory_tab > 1:continue
		var point := Vector2(2 + (index % 8) * 32, 2 + (index / 8) * 32)
		var slot := item_slot(grid, id, point, func():
			if kind == "weapon":
				if game.act("items.equip", {"id": id}):game.show_overlay(game.overlay)
			else:game.use_potion())
		if qty > 1:
			var amount: Label = skin.label(slot, str(qty), Vector2(1, 14), 10)
			amount.size.x = 26
			amount.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		index += 1
	skin.label(node, "0 点", Vector2(75, 378), 11)
	skin.label(node, "0 点", Vector2(217, 378), 11)
	skin.label(node, str(int(game.session.profile["gold"])), Vector2(42, 404), 12)
	skin.label(node, "0 金币", Vector2(204, 404), 11)

func shop() -> void:
	# Native board, original eight/seven-column trade grid, scrollbar and paired inventory.
	var node = board(game.modal, "林纳斯 · 商店", Rect2(181, 22, 291, 410))
	skin.surface(node, Rect2(10, 39, 271, 77), "quest", 15)
	skin.image(node, skin.texture("portrait", 9), Vector2(12, 39))
	skin.label(node, "好好保养武器，\n它才能保护你。", Vector2(96, 54), 12)
	skin.label(node, "商品", Vector2(24, 125), 12, Color("f0d18a"))
	var grid: Control = skin.item_grid(node, Vector2(24, 151), 7, 6)
	grid.name = "native_shop_grid"
	for i in 2:
		var id: String = ["potion", "forest_sword"][i]
		item_slot(grid, id, Vector2(2 + i * 32, 2), func():
			if game.act("items.buy", {"id": id}):game.notice("购入 " + game.Catalog.ITEMS[id]["name"]); game.show_overlay("shop"), true)
	skin.image(node, skin.texture("shop", 13), Vector2(264, 167))
	skin.image(node, skin.texture("shop", 9), Vector2(264, 151))
	skin.image(node, skin.texture("shop", 12), Vector2(264, 329))
	skin.image(node, skin.texture("shop", 8), Vector2(264, 169))
	skin.label(node, "移至物品查看价格，点击购买", Vector2(24, 351), 11, Color("a59c88"))
	skin.button(node, "返回", Vector2(100, 378), func(): game.show_overlay("npc"))
	inventory(Vector2(484, 22), false)

func dungeon() -> void:
	var node = container(game.modal, Vector2.ZERO, Vector2(800, 600))
	skin.image(node, skin.texture("worldmap"), Vector2.ZERO)
	skin.image(node, skin.texture("select", 79), Vector2.ZERO)
	skin.image(node, skin.texture("select", 58), Vector2(104, 0))
	skin.label(node, "格兰之森", Vector2(34, 65), 22, Color("f0d18a"))
	# All cards use actual native dungeon art. Only the implemented route is selectable.
	var locations := [Vector2(300, 230), Vector2(132, 111), Vector2(466, 93), Vector2(562, 292), Vector2(130, 360)]
	for i in locations.size():
		var pic = skin.image(node, skin.texture("dungeon_cards", i), locations[i])
		if i > 0:pic.modulate = Color("999999")
		else:
			skin.surface(node, Rect2(locations[i] - Vector2(5, 4), Vector2(178, 88)), "select", 22, 6)
			skin.label(node, "密林试炼", locations[i] + Vector2(15, 83), 14, Color("ffdf75"))
	skin.surface(node, Rect2(33, 442, 450, 110), "select", 0, 9)
	skin.label(node, "密林试炼  ·  普通级", Vector2(49, 451), 16, Color("f0d18a"))
	skin.label(node, "推荐等级 Lv.1  ·  五个房间\n通关奖励：150 金币、120 经验、恢复药剂 ×1", Vector2(49, 480), 12)
	skin.image(node, skin.texture("select", 11), Vector2(506, 462))
	var enter: TextureButton = skin.sprite_button(node, "select", [164, 165, 166], Vector2(621, 446), game.depart, "进入地下城 Space")
	enter.set_meta("action_label", "进入地下城")
	skin.button(node, "返回城镇", Vector2(631, 528), func(): game.show_overlay(""))
	skin.label(node, "其余地下城尚未开放", Vector2(34, 569), 11)

func result() -> void:
	var r: Dictionary = game.session.result
	var won := bool(r.get("victory", false))
	selected_card = -1
	var node = container(game.modal, Vector2.ZERO, Vector2(800, 600))
	skin.image(node, skin.texture("reward", 33), Vector2.ZERO)
	skin.image(node, skin.texture("reward", 35), Vector2(138, 28))
	skin.label(node, "通关结算" if won else "冒险结束", Vector2(163, 43), 26, Color("f0d18a"))
	skin.label(node, "密林试炼  ·  普通级", Vector2(166, 91), 14)
	var stats: Dictionary = r.get("stats", {})
	skin.label(node, "通关时间    %.1f 秒\n承受伤害    %d\n获得金币    %d\n获得经验    %d" % [float(stats.get("time_ms", 0)) / 1000, int(stats.get("damage_taken", 0)), int(r.get("gold", 0)), int(r.get("xp", 0))], Vector2(166, 125), 14)
	if won:skin.image(node, skin.texture("result", {"S": 3, "A": 6, "B": 7}[r.get("rank", "B")]), Vector2(490, 85))
	else:skin.label(node, "已撤退" if stats.get("reason") == "retreat" else "挑战失败", Vector2(491, 128), 25)
	if won:
		var prompt: Label = skin.label(node, "请选择一张奖励卡牌", Vector2(292, 303), 18, Color("f0d18a"))
		prompt.name = "reward_prompt"
		for i in 4:
			var index := i
			var card: TextureButton = skin.sprite_button(node, "reward", [36, 46, 36], Vector2(72 + i * 167, 345), func(): reveal_card(index, node))
			card.name = "reward_card_" + str(i)
			skin.label(node, str(i + 1), Vector2(140 + i * 167, 445), 12)
	var back: TextureButton = skin.sprite_button(node, "reward", [95, 96, 97], Vector2(588, 475), game.return_town, "确认后返回城镇")
	back.set_meta("action_label", "返回城镇")
	back.name = "result_return"
	back.disabled = won
	if won and r.has("card_choice"):reveal_card(int(r["card_choice"]), node, false)

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
			skin.image(node, item_texture("potion"), Vector2(133 + i * 167, 365))
			skin.label(node, "恢复药剂 ×1", Vector2(112 + i * 167, 412), 12)
	(node.get_node("result_return") as BaseButton).disabled = false
	# Reward was committed once by Session before rendering. Flipping never pays twice.
	if persist:
		game.session.result["card_choice"] = index
		game.save_profile()
		game.notice("奖励已收入背包")
