extends Node2D
## Independent outer loop. ws1's original main scene and files stay untouched.
const Session = preload("res://flow/session.gd")
const Store = preload("res://save/store.gd")
const Town = preload("res://town/native_town.gd")
const NativeSkin = preload("res://ui/flow/native_skin.gd")
const Windows = preload("res://ui/flow/native_windows.gd")
const CombatSession = preload("res://combat/api/combat_session.gd")
const Catalog = preload("res://items/catalog.gd")
const DisplaySettings = preload("res://ui/flow/display_settings.gd")
const DebugPanel = preload("res://ui/flow/debug_panel.gd")
const ContentSlot = preload("res://ui/flow/content_slot.gd")
const SkillCatalog = preload("res://combat/api/skill_catalog.gd")
const SkillDescriptions = preload("res://items/skill_descriptions.gd")
const SKILL_KEYS := [KEY_A, KEY_S, KEY_D, KEY_F, KEY_G, KEY_H]
const SKILL_CODES := {"draw":KEY_A, "triple":KEY_S, "rage_slash":KEY_D, "buff":KEY_F, "guard":KEY_G}
var session = Session.new()
var store = Store.new()
var town
var battle
var combat
var skin
var windows
var ui: Control
var hud: Control
var modal: Control
var overlay := ""
var notification := ""
var notification_seconds := 0.0
var hp_bar: TextureProgressBar
var mp_bar: TextureProgressBar
var status_text: Label
var info_text: Label
var toast_text: Label
var toast_panel: Control
var test_mode := false
var save_failed := false
var skill_views: Dictionary = {}
var display_settings = DisplaySettings.new()
var debug_panel
var world_clip: Control
var skill_catalog
var quick_views: Array = []

func _ready() -> void:
	test_mode = "--loop-test" in OS.get_cmdline_user_args()
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	display_settings.setup(get_window(), test_mode)
	transform = display_settings.content_transform()
	RenderingServer.set_default_clear_color(Color.BLACK)
	get_window().title = "艾尔文防线 · 冒险循环"
	if test_mode:store.path = "res://../temp/loop_tests/ui_profile.json"
	else:
		store.read_into(session)
	town = Town.new()
	town.position.y = 28
	world_clip = Control.new()
	world_clip.size = Vector2(800, 600)
	world_clip.clip_contents = true
	world_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(world_clip)
	world_clip.add_child(town)
	town.interact.connect(func(target: String): show_overlay("npc" if target == "linus" else "dungeon"))
	skin = NativeSkin.new(town.loader)
	windows = Windows.new(self)
	skill_catalog = SkillCatalog.new()
	var layer := CanvasLayer.new()
	layer.transform = display_settings.content_transform()
	add_child(layer)
	ui = Control.new()
	ui.size = Vector2(800, 600)
	ui.clip_contents = true
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(ui)
	build_hud()
	modal = Control.new()
	modal.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(modal)
	toast_panel = skin.panel(ui, Rect2(205, 43, 390, 32))
	toast_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast_text = skin.label(toast_panel, "", Vector2(14, 5), 12)
	toast_panel.hide()
	debug_panel = DebugPanel.new()
	ui.add_child(debug_panel)
	debug_panel.setup(self)
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
	skin.image(hud, skin.texture("hud"), Vector2(0, 508))
	hp_bar = orb(hud, skin.texture("hud", 1), Vector2(15, 525))
	mp_bar = orb(hud, skin.texture("hud", 2), Vector2(733, 525))
	hp_bar.mouse_filter = Control.MOUSE_FILTER_PASS
	mp_bar.mouse_filter = Control.MOUSE_FILTER_PASS
	hp_bar.mouse_entered.connect(func(): windows.gauge_tip(hp_bar))
	mp_bar.mouse_entered.connect(func(): windows.gauge_tip(mp_bar))
	hp_bar.mouse_exited.connect(windows.hide_tooltip)
	mp_bar.mouse_exited.connect(windows.hide_tooltip)
	# Source ui/hud/hud.ui controls are relative to the bottom board.
	skin.sprite_button(hud, "hud", [5, 6, 7], Vector2(273, 560), func(): hud_action("inventory"), "角色装备 I")
	skin.sprite_button(hud, "hud", [8, 9, 10], Vector2(299, 560), func(): hud_action("inventory"), "背包 I")
	skin.sprite_button(hud, "hud", [11, 12, 13], Vector2(325, 560), func(): hud_action("quest"), "任务 Q")
	skin.sprite_button(hud, "hud", [68, 69, 70], Vector2(451, 560), func(): hud_action("menu"), "菜单 Esc")
	for i in 6:
		skin.label(hud, str(i + 1), Vector2(87 + i * 30, 574), 9).z_index = 2
		var hotkey: Label = skin.label(hud, ["A", "S", "D", "F", "G", "H"][i], Vector2(540 + i * 30, 574), 9)
		hotkey.set_meta("skill_hotkey", true)
		hotkey.z_index = 2
	build_hotbars()
	info_text = skin.label(hud, "", Vector2(13, 583), 8, Color("f0d18a"))
	info_text.size.x = 50
	info_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_text = skin.label(ui, "", Vector2(14, 16), 12)
	status_text.hide()
	var experience := TextureProgressBar.new()
	experience.texture_progress = skin.texture("hud", 4)
	experience.position = Vector2(87, 591)
	experience.value = 0
	experience.mouse_filter = Control.MOUSE_FILTER_PASS
	experience.mouse_entered.connect(func(): windows.gauge_tip(experience))
	experience.mouse_exited.connect(windows.hide_tooltip)
	hud.add_child(experience)
	experience.name = "experience"

func orb(parent: Node, tex: Texture2D, at: Vector2) -> TextureProgressBar:
	var bar := TextureProgressBar.new()
	bar.texture_progress = tex
	bar.fill_mode = TextureProgressBar.FILL_BOTTOM_TO_TOP
	bar.position = at
	bar.value = 100
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(bar)
	return bar

func press_combat_key(code: int) -> void:
	if not is_instance_valid(battle) or session.state != "battle" or overlay != "":return
	forward_battle_key(code, true)
	await get_tree().physics_frame
	forward_battle_key(code, false)

func _process(delta: float) -> void:
	var p: Dictionary = session.profile
	var stat: Dictionary = session.stats()
	var hp := float(stat["hp"])
	var mp := float(stat["mp"])
	var hp_max := hp
	var mp_max := mp
	var cooldowns: Dictionary = {}
	if is_instance_valid(battle):
		var snap: Dictionary = combat.read_view()
		hp = float(snap["hp"])
		mp = float(snap["mp"])
		hp_max = float(snap["hp_max"])
		mp_max = float(snap["mp_max"])
		cooldowns = snap.get("cooldowns", {})
		status_text.text = skin.chinese("%s  %d / %d" % [snap["room_name"], snap["room"], snap["room_count"]])
	else:status_text.text = "艾尔文防线  · 方向键移动  E 交谈  · 药剂 ×%d" % int(p["inventory"].get("potion", 0))
	if save_failed:status_text.text = "存档写入失败 · 请检查目录后重试保存"
	hp_bar.value = hp * 100 / hp_max
	mp_bar.value = mp * 100 / mp_max
	hp_bar.set_meta("value_text", "生命值  %d / %d" % [hp, hp_max])
	mp_bar.set_meta("value_text", "魔法值  %d / %d" % [mp, mp_max])
	windows.update_gauge_tip()
	info_text.text = "Lv.%d" % int(p["level"])
	var experience := hud.get_node("experience") as TextureProgressBar
	experience.value = float(p["xp"]) * 100.0 / (int(p["level"]) * 100)
	experience.set_meta("value_text", "经验  %d / %d" % [p["xp"], int(p["level"]) * 100])
	for cell in quick_views:
		if is_instance_valid(cell):cell.refresh_quantity()
	for id: String in skill_views:
		var remaining := float(cooldowns.get(id, 0))
		var view: Button = skill_views[id]["view"]
		var counter: Label = skill_views[id]["counter"]
		view.modulate = Color("777777") if remaining > 0 else Color.WHITE
		counter.text = "%.1f" % remaining if remaining > 0 else ""
	town.enabled = overlay == "" and session.state == "town" and not debug_is_open()
	debug_panel.refresh_status()
	if notification_seconds > 0:
		notification_seconds -= delta
		toast_text.text = skin.chinese(notification)
		toast_panel.visible = notification_seconds > 0 and overlay == ""
	if is_instance_valid(battle) and overlay == "" and not debug_is_open() and combat.read_view()["paused"]:
		show_overlay("menu")

func _input(event: InputEvent) -> void:
	if not event is InputEventKey:return
	var key := int(event.physical_keycode if event.physical_keycode else event.keycode)
	if key == KEY_SHIFT:windows.update_skill_detail(event.pressed)
	if key not in [KEY_P, KEY_ESCAPE, KEY_F3, KEY_F11]:
		if session.state == "battle" and overlay == "" and not debug_is_open():forward_battle_key(key, event.pressed, event.echo)
		return
	if not event.is_pressed() or event.is_echo():return
	if key == KEY_P and not debug_panel.is_typing():
		set_debug_open(not debug_is_open())
		get_viewport().set_input_as_handled()
		return
	if key == KEY_ESCAPE and debug_is_open():
		set_debug_open(false)
		get_viewport().set_input_as_handled()
		return
	if key == KEY_F3:
		notice(display_settings.description())
	elif key == KEY_F11:
		display_settings.toggle_fullscreen()
	else:return
	get_viewport().set_input_as_handled()
	if overlay == "menu":show_overlay("menu")
	notice(display_settings.description())

func _unhandled_key_input(event: InputEvent) -> void:
	if is_instance_valid(windows.purchase):
		if event.is_pressed() and event.keycode == KEY_ESCAPE:windows.close_purchase()
		return
	if debug_is_open():return
	if not event.is_pressed() or event.is_echo():return
	var key := int(event.physical_keycode if event.physical_keycode else event.keycode)
	match key:
		KEY_SPACE:
			if overlay == "dungeon":depart()
		KEY_I:hud_action("inventory")
		KEY_Q:hud_action("quest")
		KEY_D:
			if session.state == "town":hud_action("dungeon")
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6:
			if overlay == "result" and key <= KEY_4:windows.flip_card(key - KEY_1)
			elif session.state != "result":use_quick(key - KEY_1)
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
	windows.close_purchase()
	if session.state == "result" and which == "":which = "result"
	if which == "quest" and overlay != "quest":
		windows.quest_tab = 0 if session.profile["quest"] == "available" else 2 if session.profile["quest"] == "done" else 1
	overlay = which
	windows.hide_tooltip()
	hud.visible = which not in ["dungeon", "result"]
	for child in modal.get_children():
		if child is Control:child.mouse_filter = Control.MOUSE_FILTER_IGNORE
		child.queue_free()
	town.enabled = which == "" and session.state == "town"
	sync_debug_pause()
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
	windows.dialogue()

func quest_panel() -> void:
	windows.quests()

func inventory_panel() -> void:
	windows.inventory()

func shop_panel() -> void:
	windows.shop()

func dungeon_panel() -> void:
	windows.dungeon()

func depart() -> void:
	if not act("flow.depart"):return
	show_overlay("")
	town.hide()
	combat = CombatSession.new()
	battle = combat.mount(world_clip)
	battle.position = Vector2(80, 100)
	combat.room_combat_finished.connect(func(event: Dictionary): call_deferred("on_combat_event", event))
	combat.player_defeated.connect(func(event: Dictionary): call_deferred("on_combat_event", event))
	var stat: Dictionary = session.run["stats"]
	var headless_test := test_mode and DisplayServer.get_name() == "headless"
	combat.start_room({"run_id": String(session.run["id"]), "room_id": "forest_trial:0", "room_index": 0,
		"player": {"hp_max": stat["hp"], "mp_max": stat["mp"], "damage_multiplier": stat["damage_multiplier"], "weapon": stat["weapon"]},
		"audio": {"muted": headless_test, "bgm_volume_db": -32}, "show_hud": false})
	combat.configure_trial(1.35, String(session.run.get("difficulty", "normal")))
	notice("密林试炼 · 清除怪物后前往出口")
	sync_debug_pause()

func on_combat_event(event: Dictionary) -> void:
	var response: Dictionary = session.combat_event(event)
	if response["ok"] and session.state == "result":
		save_profile()
		show_overlay("result")

func result_panel() -> void:
	windows.result()

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
	var panel = title_panel("冒险菜单", Rect2(218, 105, 364, 300))
	skin.button(panel, "继续游戏", Vector2(132, 58), func(): show_overlay(""))
	skin.button(panel, "保存进度", Vector2(132, 96), func(): save_profile())
	if session.state == "battle":skin.button(panel, "撤退回城", Vector2(132, 134), func():
		if act("flow.retreat"):show_overlay("result"))
	skin.label(panel, "画面分辨率：1920×1080（固定）", Vector2(24, 177), 12, Color("f0d18a"))
	var fullscreen: Button = skin.button(panel, "编辑器预览" if Engine.is_embedded_in_editor() else "返回窗口" if display_settings.is_fullscreen() else "切换全屏", Vector2(24, 211), func():
		display_settings.toggle_fullscreen()
		show_overlay("menu"))
	fullscreen.disabled = Engine.is_embedded_in_editor()
	skin.button(panel, "调试面板 P", Vector2(135, 211), func(): set_debug_open(true))
	skin.label(panel, "编辑器工具栏控制预览 · 原版比例居中" if Engine.is_embedded_in_editor() else "F11 切换全屏 · 原版比例居中", Vector2(24, 255), 11)

func debug_is_open() -> bool:
	return is_instance_valid(debug_panel) and debug_panel.visible

func set_debug_open(open: bool) -> void:
	if not open:debug_panel.command_input.release_focus()
	debug_panel.visible = open
	if open:windows.hide_tooltip()
	sync_debug_pause()
	debug_panel.refresh_status()

func sync_debug_pause() -> void:
	var open := debug_is_open()
	if is_instance_valid(town):town.enabled = not open and overlay == "" and session.state == "town"
	if is_instance_valid(battle):
		battle.set_process_input(false)
		combat.set_paused(open or overlay != "" or session.state != "battle")

func build_hotbars() -> void:
	session.Layout.normalize(session.profile, Catalog.ITEMS)
	for view in quick_views:
		if is_instance_valid(view):view.queue_free()
	quick_views.clear()
	for entry in skill_views.values():
		entry["view"].queue_free()
		entry["counter"].queue_free()
	skill_views.clear()
	for i in 6:
		var cell = make_slot(hud, {"place":"quick", "index":i, "id":session.profile["quick_items"][i]}, Vector2(85 + i * 30, 558))
		cell.name = "hud_potion" if i == 0 else "hud_item_" + str(i)
		quick_views.append(cell)
		var id: String = session.profile["skill_slots"][i]
		var skill = make_slot(hud, {"place":"skill", "index":i, "id":id}, Vector2(538 + i * 30, 558))
		var counter: Label = skin.label(hud, "", skill.position + Vector2(6, 5), 12)
		if id != "":skill_views[id] = {"view":skill, "counter":counter}
		else:skill_views["empty_" + str(i)] = {"view":skill, "counter":counter}

func make_slot(parent: Node, data: Dictionary, at: Vector2):
	var cell = ContentSlot.new()
	cell.position = at
	parent.add_child(cell)
	cell.setup(self, data)
	return cell

func slot_texture(cell: Dictionary) -> Texture2D:
	if cell["place"] == "skill":return town.loader.texture(town.loader.data["ui"]["active_skills"][cell["id"]])
	return windows.item_texture(cell["id"])

func slot_hover(cell: Control) -> void:
	if cell.cell.get("id", "") == "":return
	if cell.cell["place"] == "skill":windows.skill_tip(cell.cell["id"], cell.get_global_rect())
	else:windows.item_tip(cell.cell["id"], cell.get_global_rect(), cell.cell["place"] == "shop", cell.cell["place"] == "quick")

func slot_pressed(cell: Control) -> void:
	match cell.cell["place"]:
		"shop":windows.purchase_dialog(cell.cell["id"])
		"quick":use_quick(int(cell.cell["index"]))
		"skill":press_combat_key(SKILL_KEYS[int(cell.cell["index"])])

func slot_double_clicked(cell: Control) -> void:
	var id: String = cell.cell.get("id", "")
	if cell.cell["place"] == "equipment":
		if act("items.unequip"):refresh_item_views()
	elif cell.cell["place"] == "bag" and Catalog.ITEMS.get(id, {}).get("kind") == "weapon":
		if act("items.equip", {"id":id}):refresh_item_views()

func can_drop_slot(source: Dictionary, target: Dictionary) -> bool:
	if source.get("place") == "shop":return target.get("place") in ["bag", "quick", "equipment"] and Catalog.ITEMS.get(source.get("id"), {}).get("kind") == (target.get("category") if target.get("place") == "bag" else "weapon" if target.get("place") == "equipment" else "consumable")
	if session.state != "town" and (source.get("place") == "equipment" or target.get("place") == "equipment"):return false
	return session.Layout.move(session.profile.duplicate(true), Catalog.ITEMS, source, target)

func drop_slot(source: Dictionary, target: Dictionary) -> void:
	if source.get("place") == "shop":windows.purchase_dialog(source["id"], target); return
	if act("slots.move", {"source":source, "target":target}):
		refresh_item_views()
		sync_debug_pause()

func refresh_item_views() -> void:
	windows.hide_tooltip()
	build_hotbars()
	if overlay in ["inventory", "shop"]:show_overlay(overlay)

func use_quick(index: int) -> void:
	var id: String = session.profile["quick_items"][index]
	if id == "potion":use_potion()

func forward_battle_key(code: int, pressed: bool, echo := false) -> void:
	if not is_instance_valid(battle):return
	var index := SKILL_KEYS.find(code)
	if index >= 0:
		var id: String = session.profile["skill_slots"][index]
		if id == "":return
		code = SKILL_CODES[id]
	combat.submit_key(code, pressed, echo)

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
