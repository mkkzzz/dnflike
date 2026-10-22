extends Node2D
## Independent outer loop. ws1's original main scene and files stay untouched.
const Session = preload("res://flow/session.gd")
const Store = preload("res://save/store.gd")
const Town = preload("res://town/native_town.gd")
const NativeSkin = preload("res://ui/flow/native_skin.gd")
const CombatSession = preload("res://combat/api/combat_session.gd")
const Catalog = preload("res://items/catalog.gd")
var session = Session.new()
var store = Store.new()
var town
var battle
var combat
var skin
var ui: Control
var hud: Control
var modal: Control
var overlay := ""
var notification := ""
var notification_seconds := 0.0
var hp_bar: TextureProgressBar
var mp_bar: TextureProgressBar
var hp_text: Label
var mp_text: Label
var status_text: Label
var info_text: Label
var toast_text: Label
var toast_panel: Control
var test_mode := false
var save_failed := false

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	get_window().content_scale_size = Vector2i(640, 480)
	get_window().size = Vector2i(1280, 960)
	get_window().title = "艾尔文防线 · 冒险循环"
	test_mode = "--loop-test" in OS.get_cmdline_user_args()
	if test_mode:store.path = "res://../temp/loop_tests/ui_profile.json"
	else:
		store.read_into(session)
	town = Town.new()
	add_child(town)
	town.interact.connect(func(target: String): show_overlay("npc" if target == "linus" else "dungeon"))
	skin = NativeSkin.new(town.loader)
	var layer := CanvasLayer.new()
	add_child(layer)
	ui = Control.new()
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(ui)
	build_hud()
	modal = Control.new()
	modal.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(modal)
	toast_panel = skin.panel(ui, Rect2(125, 43, 390, 32))
	toast_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast_text = skin.label(toast_panel, "", Vector2(14, 5), 12)
	toast_panel.hide()
	if session.state == "result":show_overlay("result")
	else:notice("已从备份恢复存档 · 艾尔文防线" if store.recovered else "艾尔文防线 · 方向键移动，靠近林纳斯按 E")
	if test_mode:
		var runner = load("res://tests/flow/test_loop.gd").new()
		runner.game = self
		add_child(runner)

func build_hud() -> void:
	hud = Control.new()
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(hud)
	skin.image(hud, skin.texture("hud"), Vector2(0, 392))
	hp_bar = orb(hud, skin.texture("hud", 1), Vector2(12, 404))
	mp_bar = orb(hud, skin.texture("hud", 2), Vector2(572, 404))
	hp_text = skin.label(hud, "", Vector2(12, 426), 10)
	mp_text = skin.label(hud, "", Vector2(572, 426), 10)
	info_text = skin.label(hud, "", Vector2(91, 394), 12)
	status_text = skin.label(hud, "", Vector2(91, 415), 11)
	for entry in [["背包 I", "inventory"], ["任务 Q", "quest"], ["出征 D", "dungeon"], ["药剂 H", "potion"], ["保存", "save"], ["菜单", "menu"]]:
		var index := ["inventory", "quest", "dungeon", "potion", "save", "menu"].find(entry[1])
		var action := String(entry[1])
		skin.button(hud, entry[0], Vector2(87 + index * 77, 448), func(): hud_action(action), false)

func orb(parent: Node, tex: Texture2D, at: Vector2) -> TextureProgressBar:
	var bar := TextureProgressBar.new()
	bar.texture_progress = tex
	bar.fill_mode = TextureProgressBar.FILL_BOTTOM_TO_TOP
	bar.position = at
	bar.value = 100
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(bar)
	return bar

func _process(delta: float) -> void:
	var p: Dictionary = session.profile
	var stat: Dictionary = session.stats()
	var hp := float(stat["hp"])
	var mp := float(stat["mp"])
	var hp_max := hp
	var mp_max := mp
	if is_instance_valid(battle):
		var snap: Dictionary = combat.read_view()
		hp = float(snap["hp"])
		mp = float(snap["mp"])
		hp_max = float(snap["hp_max"])
		mp_max = float(snap["mp_max"])
		status_text.text = skin.chinese("%s  %d / %d  · X 普攻  Z/A/S 技能  C 跳跃" % [snap["room_name"], snap["room"], snap["room_count"]])
	else:status_text.text = "艾尔文防线  · 方向键移动  E 交谈  · 药剂 ×%d" % int(p["inventory"].get("potion", 0))
	if save_failed:status_text.text = "存档写入失败 · 请检查目录后重试保存"
	hp_bar.value = hp * 100 / hp_max
	mp_bar.value = mp * 100 / mp_max
	hp_text.text = "%d/%d" % [hp, hp_max]
	mp_text.text = "%d/%d" % [mp, mp_max]
	info_text.text = skin.chinese("等级 %d  %s    金币 %d    %s" % [p["level"], p["name"], p["gold"], Catalog.ITEMS[p["equipped"]]["name"]])
	town.enabled = overlay == "" and session.state == "town"
	if notification_seconds > 0:
		notification_seconds -= delta
		toast_text.text = skin.chinese(notification)
		toast_panel.visible = notification_seconds > 0 and overlay == ""
	if is_instance_valid(battle) and overlay == "" and combat.read_view()["paused"]:
		show_overlay("menu")

func _unhandled_key_input(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo():return
	var key := int(event.physical_keycode if event.physical_keycode else event.keycode)
	match key:
		KEY_I:hud_action("inventory")
		KEY_Q:hud_action("quest")
		KEY_D:
			if session.state == "town":hud_action("dungeon")
		KEY_H:use_potion()
		KEY_F5:save_profile()
		KEY_ESCAPE:
			if overlay == "" or session.state == "result":show_overlay("menu" if session.state != "result" else "result")
			else:show_overlay("")

func hud_action(action: String) -> void:
	match action:
		"potion":use_potion()
		"save":save_profile()
		"dungeon":
			if session.state == "town":show_overlay("dungeon")
			else:notice("请先完成当前冒险")
		_:show_overlay(action if overlay != action else "")

func notice(message: String) -> void:
	notification = message
	notification_seconds = 4

func save_profile() -> bool:
	var ok: bool = store.write(session)
	save_failed = not ok
	notice("进度已保存" if ok else "保存失败，请检查存档目录")
	return ok

func act(kind: String, payload: Dictionary = {}) -> bool:
	var response: Dictionary = session.command(kind, payload)
	if not response["ok"]:
		notice(response["message"])
		return false
	save_profile()
	return true

func show_overlay(which: String) -> void:
	if session.state == "result" and which == "":which = "result"
	overlay = which
	for child in modal.get_children():
		if child is Control:child.mouse_filter = Control.MOUSE_FILTER_IGNORE
		child.queue_free()
	town.enabled = which == "" and session.state == "town"
	if is_instance_valid(battle):combat.set_paused(which != "" or session.state != "battle")
	match which:
		"npc":npc_panel()
		"quest":quest_panel()
		"inventory":inventory_panel()
		"shop":shop_panel()
		"dungeon":dungeon_panel()
		"result":result_panel()
		"menu":menu_panel()

func title_panel(title: String, rect := Rect2(103, 93, 434, 250)) -> Control:
	var panel = skin.panel(modal, rect)
	skin.label(panel, title, Vector2(22, 15), 18, Color("f0d18a"))
	if session.state != "result":skin.button(panel, "关闭", Vector2(rect.size.x - 78, 15), func(): show_overlay(""), false)
	return panel

func npc_panel() -> void:
	var panel = title_panel("林纳斯 · 艾尔文防线")
	skin.image(panel, skin.texture("portrait", 8), Vector2(22, 55), 0.75)
	skin.label(panel, "森林里的哥布林越来越多了。\n出发前，先检查武器和药剂。", Vector2(153, 68), 14)
	skin.button(panel, "委托任务", Vector2(153, 159), func(): show_overlay("quest"))
	skin.button(panel, "购买物品", Vector2(269, 159), func(): show_overlay("shop"))
	skin.label(panel, "接取委托 → 击败密林领主 → 回来领取报酬", Vector2(22, 211), 12)

func quest_panel() -> void:
	var panel = title_panel("委托 · 森林的异变")
	var q: String = session.profile["quest"]
	var text: String = {"available": "林纳斯希望你调查格兰之森。\n击败密林领主，然后回城向他报告。", "active": "目标：击败密林领主  0 / 1\n通关后回到艾尔文防线交付。", "ready": "目标：击败密林领主  1 / 1\n调查完成，林纳斯正在等你。", "done": "委托已完成。\n林间太刀已收入背包，可以回城装备。"}[q]
	skin.label(panel, text, Vector2(26, 62), 14)
	skin.label(panel, "报酬：金币 200 · 林间太刀（伤害 ×1.20）", Vector2(26, 137), 13, Color("f0d18a"))
	if q == "available":skin.button(panel, "接受委托", Vector2(26, 190), func():
		if act("flow.accept_quest"):show_overlay("quest"))
	if q == "ready":skin.button(panel, "领取报酬", Vector2(26, 190), func():
		if town.nearest() != "linus":notice("请走到林纳斯身旁交付任务")
			# The UI may inspect position; the pure session does not know scene nodes.
		elif act("flow.claim_quest"):show_overlay("quest"))

func inventory_panel() -> void:
	var panel := Control.new()
	panel.position = Vector2(330, 0)
	modal.add_child(panel)
	skin.inventory(panel)
	skin.button(panel, "关闭", Vector2(226, 382), func(): show_overlay(""), false)
	var equipped: String = session.profile["equipped"]
	skin.image(panel, town.loader.texture(town.loader.data["ui"]["items"][equipped]), Vector2(211, 82))
	var index := 0
	for id: String in Catalog.ITEMS:
		var qty := int(session.profile["inventory"].get(id, 0))
		if qty < 1:continue
		var at := Vector2(18 + index * 32, 178)
		skin.image(panel, town.loader.texture(town.loader.data["ui"]["items"][id]), at)
		skin.label(panel, str(qty), at + Vector2(17, 15), 10)
		var hit := Button.new()
		hit.position = at
		hit.size = Vector2(30, 30)
		hit.flat = true
		hit.tooltip_text = skin.chinese(Catalog.ITEMS[id]["name"] + "\n" + Catalog.ITEMS[id]["description"] + "\n点击装备 / 使用")
		hit.pressed.connect(func():
			if Catalog.ITEMS[id]["kind"] == "weapon":
				if act("items.equip", {"id": id}):show_overlay("inventory")
			else:use_potion())
		panel.add_child(hit)
		index += 1
	skin.label(panel, str(int(session.profile["gold"])), Vector2(38, 312), 12)
	skin.label(panel, Catalog.ITEMS[equipped]["name"] + "  " + Catalog.ITEMS[equipped]["description"], Vector2(17, 342), 11)
	skin.label(panel, "点击格子装备；恢复药剂战斗中按 H", Vector2(18, 367), 11)

func shop_panel() -> void:
	var panel := Control.new()
	panel.position = Vector2(173, 10)
	modal.add_child(panel)
	skin.image(panel, skin.texture("shop"), Vector2.ZERO)
	skin.image(panel, skin.texture("portrait", 9), Vector2(32, 34), 0.65)
	skin.label(panel, "林纳斯的商店\n点击商品购买", Vector2(108, 38), 15)
	var ids := ["potion", "forest_sword"]
	for i in ids.size():
		var id: String = ids[i]
		var at := Vector2(24 + i * 32, 135)
		skin.image(panel, town.loader.texture(town.loader.data["ui"]["items"][id]), at)
		var hit := Button.new()
		hit.position = at
		hit.size = Vector2(30, 30)
		hit.flat = true
		hit.tooltip_text = skin.chinese("%s · %d 金币\n%s" % [Catalog.ITEMS[id]["name"], Catalog.ITEMS[id]["price"], Catalog.ITEMS[id]["description"]])
		hit.pressed.connect(func():
			if act("items.buy", {"id": id}):notice("购入 " + Catalog.ITEMS[id]["name"]); show_overlay("shop"))
		panel.add_child(hit)
	skin.label(panel, "恢复药剂 40 金币 · 林间太刀 240 金币", Vector2(24, 298), 11)
	skin.label(panel, "持有金币：%d" % int(session.profile["gold"]), Vector2(24, 316), 12)
	skin.button(panel, "返回", Vector2(96, 335), func(): show_overlay("npc"))

func dungeon_panel() -> void:
	var panel = title_panel("格兰之森 · 地下城选择", Rect2(50, 38, 540, 337))
	skin.image(panel, skin.texture("lorien"), Vector2(23, 58), 0.33)
	skin.label(panel, "密林试炼", Vector2(316, 60), 21, Color("f0d18a"))
	skin.label(panel, "普通难度", Vector2(318, 96), 14, Color("a7dd74"))
	skin.label(panel, "五个房间 · 哥布林领主\n\n清除怪物，沿开放的门深入。\n通关奖励：150 金币 / 120 经验\n恢复药剂 ×1", Vector2(316, 125), 12)
	skin.label(panel, "X 普攻  Z 上挑  A 拔刀  S 连刺\nC 跳跃  V 后跳  G 格挡  H 药剂", Vector2(23, 268), 12)
	skin.button(panel, "进入地下城", Vector2(316, 270), depart)

func depart() -> void:
	if not act("flow.depart"):return
	show_overlay("")
	town.hide()
	combat = CombatSession.new()
	battle = combat.mount(self)
	battle.position.y = 20
	combat.room_combat_finished.connect(func(event: Dictionary): call_deferred("on_combat_event", event))
	combat.player_defeated.connect(func(event: Dictionary): call_deferred("on_combat_event", event))
	var stat: Dictionary = session.run["stats"]
	var headless_test := test_mode and DisplayServer.get_name() == "headless"
	combat.start_room({"run_id": String(session.run["id"]), "room_id": "forest_trial:0", "room_index": 0,
		"player": {"hp_max": stat["hp"], "mp_max": stat["mp"], "damage_multiplier": stat["damage_multiplier"], "weapon": stat["weapon"]},
		"audio": {"muted": headless_test, "bgm_volume_db": -32}, "show_hud": false})
	notice("密林试炼 · 清除怪物后前往出口")

func on_combat_event(event: Dictionary) -> void:
	var response: Dictionary = session.combat_event(event)
	if response["ok"] and session.state == "result":
		save_profile()
		show_overlay("result")

func result_panel() -> void:
	var r: Dictionary = session.result
	var panel = title_panel("冒险结束", Rect2(102, 45, 436, 326))
	var won := bool(r.get("victory", false))
	skin.label(panel, "通关结算" if won else "冒险结算", Vector2(27, 58), 24, Color("f0d18a"))
	if won:skin.image(panel, skin.texture("result", {"S": 3, "A": 6, "B": 7}[r.get("rank", "B")]), Vector2(264, 69), 0.8)
	skin.label(panel, "地下城通关" if won else "已撤退" if r.get("stats", {}).get("reason") == "retreat" else "冒险失败", Vector2(29, 116), 20, Color("f0d18a"))
	var details: Dictionary = r.get("stats", {})
	skin.label(panel, "金币 +%d\n经验 +%d\n恢复药剂 ×%d" % [r.get("gold", 0), r.get("xp", 0), r.get("potion", 0)], Vector2(29, 157), 15)
	skin.label(panel, "用时 %.1f 秒  · 受伤 %d" % [float(details.get("time_ms", 0)) / 1000, int(details.get("damage_taken", 0))], Vector2(29, 238), 12)
	skin.button(panel, "返回城镇", Vector2(29, 278), return_town)
	if session.profile["quest"] == "ready":skin.label(panel, "委托完成，回城找林纳斯领奖", Vector2(147, 280), 12)

func return_town() -> void:
	if not act("flow.return"):return
	if is_instance_valid(battle):
		combat.stop()
		battle = null
		combat = null
	town.show()
	show_overlay("")
	notice("回到艾尔文防线 · " + ("保存失败，请重试" if save_failed else "进度已保存"))

func menu_panel() -> void:
	var panel = title_panel("冒险菜单", Rect2(166, 100, 308, 245))
	skin.button(panel, "继续游戏", Vector2(103, 63), func(): show_overlay(""))
	skin.button(panel, "保存进度", Vector2(103, 105), func(): save_profile())
	if session.state == "battle":skin.button(panel, "撤退回城", Vector2(103, 147), func():
		if act("flow.retreat"):show_overlay("result"))
	skin.label(panel, "中断的战斗重进后安全回城", Vector2(48, 204), 12)

func use_potion() -> void:
	if not is_instance_valid(battle) or session.state != "battle":notice("进入地下城后可使用恢复药剂"); return
	var snap: Dictionary = combat.read_view()
	if float(snap["hp"]) >= float(snap["hp_max"]):notice("生命值已满"); return
	if bool(snap["paused"]):notice("请关闭菜单后使用药剂"); return
	if int(session.profile["inventory"].get("potion", 0)) < 1:notice("恢复药剂不足"); return
	if combat.apply_effect({"kind": "heal", "amount": int(Catalog.ITEMS["potion"]["heal"])}):
		session.consume_potion()
		save_profile()
		notice("使用恢复药剂 · HP +150")
