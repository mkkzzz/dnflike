extends Node2D
## Independent outer loop. ws1's original main scene and files stay untouched.
const Session = preload("res://flow/session.gd")
const Store = preload("res://save/store.gd")
const Town = preload("res://town/native_town.gd")
const NativeSkin = preload("res://ui/flow/native_skin.gd")
const Windows = preload("res://ui/flow/native_windows.gd")
const CombatSession = preload("res://combat/api/combat_session.gd")
const Catalog = preload("res://items/catalog.gd")
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

func _ready() -> void:
	test_mode = "--loop-test" in OS.get_cmdline_user_args()
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	get_window().content_scale_size = Vector2i(800, 600)
	# Rasterize dynamic fonts at the physical window resolution. Native textures
	# still use nearest filtering and integer scaling, without invented pixels.
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	get_window().content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	var usable := DisplayServer.screen_get_usable_rect().size
	get_window().size = Vector2i(1600, 1200) if test_mode or (usable.x >= 1600 and usable.y >= 1240) else Vector2i(800, 600)
	get_window().title = "艾尔文防线 · 冒险循环"
	if test_mode:store.path = "res://../temp/loop_tests/ui_profile.json"
	else:
		store.read_into(session)
	town = Town.new()
	town.position.y = 28
	add_child(town)
	town.interact.connect(func(target: String): show_overlay("npc" if target == "linus" else "dungeon"))
	skin = NativeSkin.new(town.loader)
	windows = Windows.new(self)
	var layer := CanvasLayer.new()
	add_child(layer)
	ui = Control.new()
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
	hp_bar = orb(hud, skin.texture("hud", 1), Vector2(13, 521))
	mp_bar = orb(hud, skin.texture("hud", 2), Vector2(731, 521))
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
	# The baked HUD uses 30px pitch; its 28px cavities begin 2px inside.
	# The previous y555/x537 positions painted over the original top/left rim.
	var potion_hit: Button = skin.icon_button(hud, town.loader.texture(town.loader.data["ui"]["items"]["potion"]), Vector2(85, 558), use_potion)
	potion_hit.name = "hud_potion"
	skin.rarity_frame(potion_hit, int(Catalog.ITEMS["potion"]["rarity"]), Color(Catalog.RARITIES[int(Catalog.ITEMS["potion"]["rarity"])]["color"]))
	potion_hit.tooltip_text = "恢复药剂 1"
	for entry in [[0, "draw", KEY_A, "拔刀斩 A"], [1, "triple", KEY_S, "三段斩 S"], [2, "rage_slash", KEY_D, "十字斩 D"], [3, "buff", KEY_F, "暴走 F"], [4, "guard", KEY_G, "格挡 G"]]:
		var code: int = entry[2]
		var tex: Texture2D = town.loader.texture(town.loader.data["ui"]["active_skills"][entry[1]])
		var view: Button = skin.icon_button(hud, tex, Vector2(538 + int(entry[0]) * 30, 558), func(): press_combat_key(code))
		view.tooltip_text = entry[3]
		var counter: Label = skin.label(hud, "", view.position + Vector2(6, 5), 12)
		skill_views[entry[1]] = {"view": view, "counter": counter}
	skin.label(hud, "Lv.", Vector2(14, 583), 10, Color("f0d18a"))
	info_text = skin.label(hud, "", Vector2(36, 583), 10, Color("f0d18a"))
	status_text = skin.label(ui, "", Vector2(14, 16), 12)
	status_text.hide()
	var experience := TextureProgressBar.new()
	experience.texture_progress = skin.texture("hud", 4)
	experience.position = Vector2(86, 590)
	experience.value = 0
	experience.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.pressed = true
	Input.parse_input_event(event)
	await get_tree().physics_frame
	event = event.duplicate()
	event.pressed = false
	Input.parse_input_event(event)

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
	info_text.text = str(p["level"])
	(hud.get_node("experience") as TextureProgressBar).value = float(p["xp"]) * 100.0 / 100.0
	for id: String in skill_views:
		var remaining := float(cooldowns.get(id, 0))
		var view: Button = skill_views[id]["view"]
		var counter: Label = skill_views[id]["counter"]
		view.modulate = Color("777777") if remaining > 0 else Color.WHITE
		counter.text = "%.1f" % remaining if remaining > 0 else ""
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
		KEY_SPACE:
			if overlay == "dungeon":depart()
		KEY_I:hud_action("inventory")
		KEY_Q:hud_action("quest")
		KEY_D:
			if session.state == "town":hud_action("dungeon")
		KEY_1:use_potion()
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
	if which == "quest" and overlay != "quest":
		windows.quest_tab = 0 if session.profile["quest"] == "available" else 2 if session.profile["quest"] == "done" else 1
	overlay = which
	windows.hide_tooltip()
	hud.visible = which not in ["dungeon", "result"]
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
	battle = combat.mount(self)
	battle.position = Vector2(80, 100)
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
	var panel = title_panel("冒险菜单", Rect2(246, 120, 308, 280))
	skin.button(panel, "继续游戏", Vector2(103, 63), func(): show_overlay(""))
	skin.button(panel, "保存进度", Vector2(103, 105), func(): save_profile())
	if session.state == "battle":skin.button(panel, "撤退回城", Vector2(103, 147), func():
		if act("flow.retreat"):show_overlay("result"))
	skin.button(panel, "原始大小", Vector2(48, 195), func(): get_window().size = Vector2i(800, 600))
	skin.button(panel, "两倍大小", Vector2(160, 195), func(): get_window().size = Vector2i(1600, 1200))
	skin.label(panel, "中断的战斗重进后安全回城", Vector2(48, 245), 12)

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
