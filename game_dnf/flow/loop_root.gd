extends Node2D
## Outer flow owns profile transactions; combat owns simulation state.
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
const Characters = preload("res://save/characters.gd")
const CharacterScreen = preload("res://ui/flow/character_screen.gd")
const NumberWindows = preload("res://ui/flow/number_windows.gd")
const QuestWindows = preload("res://ui/flow/quest_windows.gd")
const InventoryTools = preload("res://ui/flow/inventory_tools.gd")
const LootBridge = preload("res://loot/bridge.gd")
const ServiceWindows=preload("res://ui/flow/service_windows.gd")
const UpgradeWindows=preload("res://ui/flow/upgrade_windows.gd")
const RecoveryBridge=preload("res://flow/recovery_bridge.gd")
const RecoveryWindows=preload("res://ui/flow/recovery_windows.gd")
const DurabilityBridge=preload("res://items/durability_bridge.gd")
var service_windows
var upgrade_windows
var recovery_bridge
var recovery_windows
var inventory_tools
var loot_bridge
var quest_windows
var selected_dungeon := "lorien"
var dungeon_page := 0
var transitioning := false
var number_windows
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
## 城镇 BGM：场景 → 原版曲目（data/bgm.json），战斗时让位给战斗侧音乐。
var town_bgm: AudioStreamPlayer
var town_amb: AudioStreamPlayer
var bgm_tracks: Dictionary = {}
var bgm_scenes: Dictionary = {}
var bgm_screens: Dictionary = {}
var bgm_ambience: Dictionary = {}
var _bgm_scene := ""
var _bgm_ambience := ""
var skill_catalog
var quick_views: Array = []
var characters = Characters.new()
var character_screen
var character_active := false
var active_character_path := ""

func _ready() -> void:
	test_mode = "--loop-test" in OS.get_cmdline_user_args()
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	display_settings.setup(get_window(), test_mode)
	transform = display_settings.content_transform()
	RenderingServer.set_default_clear_color(Color.BLACK)
	get_window().title = "艾尔文防线 · 冒险循环"
	if test_mode:
		store.path = "res://../temp/loop_tests/ui_profile.json"
		characters.directory = "res://../temp/loop_tests/characters"
		characters.legacy_path = "res://../temp/loop_tests/character_legacy.json"
	town = Town.new()
	# 城镇与副本共用画布基准：地图美术的纵向偏移由 loader 统一加，节点自身不再位移。
	world_clip = Control.new()
	world_clip.size = Vector2(800, 600)
	world_clip.clip_contents = true
	world_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(world_clip)
	world_clip.add_child(town)
	town.interact.connect(interact_town)
	skin = NativeSkin.new(town.loader)
	windows = Windows.new(self)
	number_windows = NumberWindows.new(self)
	quest_windows = QuestWindows.new(self)
	inventory_tools = InventoryTools.new(self)
	service_windows=ServiceWindows.new(self)
	upgrade_windows=UpgradeWindows.new(self)
	recovery_bridge=RecoveryBridge.new(self);recovery_windows=RecoveryWindows.new(self)
	var durability_bridge=DurabilityBridge.new();durability_bridge.setup(self);add_child(durability_bridge)
	loot_bridge = LootBridge.new();loot_bridge.setup(self);add_child(loot_bridge)
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
	_setup_bgm()
	show_character_selection()
	if test_mode:
		var runner_path: String="res://tests/town/test_hendon.gd" if "--towns-only" in OS.get_cmdline_user_args() else "res://tests/quests/test_chapter.gd" if "--quests-only" in OS.get_cmdline_user_args() else "res://tests/flow/test_loop.gd"
		if "--items-only" in OS.get_cmdline_user_args():runner_path="res://tests/items/test_inventory_flow.gd"
		if "--services-only" in OS.get_cmdline_user_args():runner_path="res://tests/items/test_services_flow.gd"
		if "--upgrades-only" in OS.get_cmdline_user_args():runner_path="res://tests/items/test_upgrades_flow.gd"
		if "--recovery-only" in OS.get_cmdline_user_args():runner_path="res://tests/items/test_consumables_flow.gd"
		if "--consumables-only" in OS.get_cmdline_user_args():runner_path="res://tests/items/test_consumables_flow.gd"
		if "--gran-only" in OS.get_cmdline_user_args():runner_path="res://tests/quests/test_gran.gd"
		if "--kaino-only" in OS.get_cmdline_user_args():runner_path="res://tests/quests/test_kaino_chapter.gd"
		if "--poison-only" in OS.get_cmdline_user_args():runner_path="res://tests/quests/test_poison_chapter.gd"
		if "--teaching-only" in OS.get_cmdline_user_args():runner_path="res://tests/quests/test_teaching_quick.gd"
		if "--native-only" in OS.get_cmdline_user_args():runner_path="res://tests/items/test_native_quick.gd"
		if "--weapon-appearance-only" in OS.get_cmdline_user_args():runner_path="res://tests/items/test_weapon_appearance_quick.gd"
		if "--quest-guide-only" in OS.get_cmdline_user_args():runner_path="res://tests/flow/test_quest_guide_town.gd"
		var runner = load(runner_path).new()
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
	skin.sprite_button(hud, "hud", [5, 6, 7], Vector2(273, 560), func(): hud_action("numbers"), "角色属性 O")
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
	var item_clock:=0.0
	if is_instance_valid(battle):
		var snap: Dictionary = combat.read_view()
		hp = float(snap["hp"])
		mp = float(snap["mp"])
		hp_max = float(snap["hp_max"])
		mp_max = float(snap["mp_max"])
		cooldowns = snap.get("cooldowns", {})
		item_clock=float(snap.get("time_ms",0))
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
	experience.value = float(p["xp"]) * 100.0 / session.xp_needed() if session.xp_needed()>0 else 100
	experience.set_meta("value_text", "经验  %d / %d" % [p["xp"], session.xp_needed()] if session.xp_needed()>0 else "已达等级上限")
	for cell in quick_views:
		if is_instance_valid(cell):
			cell.refresh_quantity()
			var remaining: float=Session.Consumables.remaining(session.run,cell.cell.get("id",""),item_clock)/1000
			var item_counter: Label=cell.get_node("item_cooldown")
			item_counter.text=str(ceili(remaining)) if remaining>0 else ""
			if remaining>0 and is_instance_valid(cell.image_view):cell.image_view.modulate=Color("777777")
	for id: String in skill_views:
		var remaining := float(cooldowns.get(id, 0))
		var view: Button = skill_views[id]["view"]
		var counter: Label = skill_views[id]["counter"]
		view.modulate = Color("777777") if remaining > 0 else Color.WHITE
		counter.text = "%.1f" % remaining if remaining > 0 else ""
	town.enabled = not transitioning and overlay == "" and session.state == "town" and not debug_is_open()
	update_bgm()
	debug_panel.refresh_status()
	quest_windows.refresh_tracker()
	if notification_seconds > 0:
		notification_seconds -= delta
		toast_text.text = skin.chinese(notification)
		toast_panel.position.y = 4 if overlay=="numbers" else 43
		toast_panel.visible = notification_seconds > 0 and overlay in ["","numbers","death"]
	if is_instance_valid(battle) and overlay == "" and not debug_is_open() and combat.read_view()["paused"]:
		show_overlay("menu")

func _input(event: InputEvent) -> void:
	if transitioning:get_viewport().set_input_as_handled();return
	if not event is InputEventKey:return
	var key := int(event.physical_keycode if event.physical_keycode else event.keycode)
	if not character_active and key != KEY_F11:return
	if key == KEY_SHIFT:windows.update_skill_detail(event.pressed)
	if key not in [KEY_P, KEY_ESCAPE, KEY_F3, KEY_F11]:
		if session.state == "battle" and overlay == "" and not debug_is_open():
			# 普攻键（X）兼职拾取：附近有地面掉落时先捡，没掉落才照常出招。
			if key == KEY_X and event.pressed and not event.echo and loot_bridge != null and loot_bridge.try_pickup():
				get_viewport().set_input_as_handled()
				return
			forward_battle_key(key, event.pressed, event.echo)
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
	if transitioning:get_viewport().set_input_as_handled();return
	if not character_active:
		if event.is_pressed() and not event.is_echo() and is_instance_valid(character_screen):
			character_screen.handle_key(int(event.physical_keycode if event.physical_keycode else event.keycode))
			get_viewport().set_input_as_handled()
		return
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
		KEY_O:hud_action("numbers")
		KEY_K:
			number_windows.tab = 1
			show_overlay("numbers")
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
	if not character_active:return false
	if recovery_bridge!=null and not recovery_bridge.pending_death.is_empty():
		var committed: bool=recovery_bridge.commit_death()
		if overlay=="death":show_overlay("death")
		return committed
	remember_town_position()
	var ok: bool = store.write(session)
	save_failed = not ok
	notice("进度已保存" if ok else "保存失败，请检查存档目录")
	return ok

func act(kind: String, payload: Dictionary = {}) -> bool:
	if transitioning:return false
	if session.state=="town":remember_town_position()
	if kind.begins_with("quest."):return quest_action(kind,payload)
	if kind.begins_with("services."):return service_action(kind,payload)
	if kind in ["flow.depart","flow.return","flow.retreat","flow.abandon"]:return lifecycle_action(kind,payload)
	if kind.begins_with("items.") or kind.begins_with("numbers.gear") or kind in ["slots.move","numbers.skill"]:return item_action(kind,payload)
	var before_level := int(session.profile["level"])
	var response: Dictionary = session.command(kind, payload)
	if not response["ok"]:
		notice(response["message"])
		return false
	if kind.begins_with("numbers."):
		sync_number_changes(kind)
	save_profile()
	if int(session.profile["level"])>before_level:notice("等级提升 · Lv.%d" % int(session.profile["level"]))
	return true

func lifecycle_action(kind: String, payload: Dictionary) -> bool:
	if not character_active:return false
	var candidate=recovery_bridge.candidate()
	var response: Dictionary=candidate.command(kind,payload)
	if not response["ok"]:notice(response["message"]);return false
	if not store.write(candidate):save_failed=true;notice("冒险变更未提交：存档写入失败，请重试");return false
	session=candidate;save_failed=false;return true

func item_action(kind: String, payload: Dictionary) -> bool:
	if not character_active:return false
	var candidate=Session.new()
	candidate.profile=session.profile.duplicate(true);candidate.run=session.run.duplicate(true)
	candidate.state=session.state;candidate.result=session.result.duplicate(true)
	var response: Dictionary=candidate.command(kind,payload)
	if not response.get("ok",false):notice(response.get("message","物品操作失败"));return false
	if not preload("res://content/weapon_appearance.gd").can_display(equipped_weapon_item(candidate.profile)):
		notice("武器外观资源未就绪，换装未提交");return false
	if not store.write(candidate):save_failed=true;notice(("技能加点" if kind=="numbers.skill" else "物品变更")+"未提交：存档写入失败，请重试");return false
	session=candidate;save_failed=false;sync_number_changes(kind)
	if kind=="numbers.skill":notice("技能加点已保存")
	return true

func service_action(kind: String, payload: Dictionary) -> bool:
	if not character_active or transitioning:return false
	var candidate=Session.new()
	candidate.profile=session.profile.duplicate(true);candidate.run=session.run.duplicate(true)
	candidate.state=session.state;candidate.result=session.result.duplicate(true)
	var npc: String=town.nearest()
	var response: Dictionary=candidate.service_command(kind,payload,{"npc":npc,"nearby":town.is_npc(npc)})
	if not response["ok"]:notice(response["message"]);return false
	if not store.write(candidate):save_failed=true;notice("服务未提交：存档写入失败，请重试");return false
	session=candidate;save_failed=false;sync_number_changes(kind);notice(response.get("message","操作完成，进度已保存"));return true

func quest_action(kind: String, payload: Dictionary = {}) -> bool:
	if not character_active or transitioning:return false
	# Write the complete candidate first. A failed disk write cannot leak XP,
	# consumed materials or completion into the live character.
	var candidate = Session.new()
	candidate.profile=session.profile.duplicate(true)
	candidate.state=session.state
	candidate.run=session.run.duplicate(true)
	candidate.result=session.result.duplicate(true)
	var npc: String=town.nearest() if session.state=="town" else ""
	var response: Dictionary=candidate.quest_command(kind,payload,{"npc":npc,"nearby":town.is_npc(npc)})
	if not response.get("ok",false):notice(response.get("message","任务操作失败"));return false
	if not store.write(candidate):
		save_failed=true
		notice("任务未提交：存档写入失败，请重试")
		return false
	session=candidate
	save_failed=false
	sync_number_changes("numbers.xp" if kind=="quest.claim" else kind)
	if kind=="quest.claim":notice("任务已完成，奖励已保存")
	if overlay=="quest":show_overlay("quest")
	return true

func record_npc_visit(npc: String) -> void:
	if session.state!="town" or town.nearest()!=npc:return
	var outcome: Dictionary=session.quests.ingest(session.profile,{"type":"npc.met","event_id":"visit:"+str(Time.get_ticks_usec()),"npc":npc})
	if outcome.get("ok",false) and not outcome["changed"].is_empty():save_profile()

func interact_town(target: String) -> void:
	if not character_active or transitioning or session.state!="town":return
	if target!=town.nearest() and target!=town.entry_target():return
	if town.is_npc(target):show_overlay("npc")
	elif target=="dungeon":
		var choices: Array[String]=session.dungeon_choices(town.world.scene(town.location).get("dungeon_region","lorien"))
		if not choices.is_empty():
			if selected_dungeon not in choices:selected_dungeon=choices[0]
			for id: String in choices:
				if session.dungeon_available(id):selected_dungeon=id;break
		show_overlay("dungeon")
	else:transition_town(target)

func remember_town_position() -> void:
	if session.state=="town" and town.location==session.profile.get("town_location"):
		session.profile["town_position"]=[town.ground.x,town.ground.y]
		session.profile["inn_return"]=town.inn_return

func transition_town(portal: String) -> bool:
	if transitioning or not character_active:return false
	var plan: Dictionary=town.world.plan(session.profile,portal,town.ground,session.state=="town")
	if not plan["ok"]:notice(plan["message"]);return false
	if not town.ensure_location(plan["location"]):notice("目标场景资源未就绪，请通过正式入口同步");return false
	var candidate=Session.new()
	candidate.profile=session.profile.duplicate(true)
	candidate.state=session.state
	candidate.run=session.run.duplicate(true)
	candidate.result=session.result.duplicate(true)
	candidate.profile["town_location"]=plan["location"]
	candidate.profile["town_position"]=plan["point"]
	candidate.profile["inn_return"]=plan["inn_return"]
	candidate.town_world.normalize(candidate.profile)
	if not store.write(candidate):save_failed=true;notice("切换未提交：存档写入失败，请重试");return false
	transitioning=true
	town.enabled=false
	windows.hide_tooltip()
	var cover:=ColorRect.new()
	cover.size=Vector2(800,600)
	cover.color=Color(0,0,0,0)
	cover.z_index=200
	cover.mouse_filter=Control.MOUSE_FILTER_STOP
	ui.add_child(cover)
	var tween=create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	tween.tween_property(cover,"color:a",1.0,0.12)
	await tween.finished
	session=candidate
	town.inn_return=plan["inn_return"]
	town.set_location(plan["location"],session.TownWorld.vec(candidate.profile["town_position"]))
	quest_windows.focus_npc=""
	show_overlay("")
	var reveal=create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	reveal.tween_property(cover,"color:a",0.0,0.16)
	await reveal.finished
	cover.queue_free()
	transitioning=false
	save_failed=false
	sync_debug_pause()
	notice(String(plan["label"]))
	return true

func sync_number_changes(kind := "numbers.update") -> void:
	if is_instance_valid(battle) and session.state=="battle":
		combat.update_numbers(session.stats(),String(session.Numbers.config()["progression"]["level_up_vitals"]) if kind in ["numbers.xp","numbers.level"] else "preserve")
	if is_instance_valid(town) and session.state=="town":town.set_equipped_weapon(equipped_weapon_item(),equipped_weapon_shape())
	build_hotbars()

func show_overlay(which: String) -> void:
	if not character_active:return
	if session.state=="defeated" or not recovery_bridge.pending_death.is_empty() or not recovery_bridge.pending_effect.is_empty():which="death"
	windows.close_purchase()
	if session.state == "result" and which == "":which = "result"
	if which=="quest" and overlay not in ["quest","npc"]:
		quest_windows.focus_npc=""
		quest_windows.tab=1 if session.quests.active_count(session.profile)>0 else 0
	overlay = which
	windows.hide_tooltip()
	hud.visible = which not in ["dungeon", "result"]
	for child in modal.get_children():
		if child is Control:child.mouse_filter = Control.MOUSE_FILTER_IGNORE
		child.queue_free()
	town.enabled = not transitioning and which == "" and session.state == "town"
	sync_debug_pause()
	match which:
		"npc":npc_panel()
		"quest":quest_panel()
		"legacy_quest":windows.quests()
		"inventory":inventory_panel()
		"shop":shop_panel()
		"services":service_windows.open()
		"upgrades":upgrade_windows.open()
		"death":recovery_windows.open()
		"dungeon":dungeon_panel()
		"result":result_panel()
		"menu":menu_panel()
		"numbers":number_windows.show_window()

func title_panel(title: String, rect := Rect2(103, 93, 434, 250)) -> Control:
	var panel = skin.panel(modal, rect)
	skin.label(panel, title, Vector2(22, 15), 18, Color("f0d18a"))
	if session.state != "result":skin.button(panel, "关闭", Vector2(rect.size.x - 78, 15), func(): show_overlay(""), false)
	return panel

func npc_panel() -> void:
	if selected_dungeon=="forest_trial" and town.nearest()!="":windows.dialogue(town.nearest())
	else:quest_windows.dialogue()

func quest_panel() -> void:
	if selected_dungeon=="forest_trial":windows.quests()
	else:quest_windows.show_window()

func inventory_panel() -> void:
	windows.inventory()

func shop_panel() -> void:
	windows.shop()

func dungeon_panel() -> void:
	if selected_dungeon=="forest_trial":
		windows.dungeon()
		skin.button(modal,"洛兰主线",Vector2(34,528),func():selected_dungeon="lorien";show_overlay("dungeon"))
	else:quest_windows.dungeon()

func depart() -> void:
	if not act("flow.depart",{"dungeon":selected_dungeon}):return
	recovery_bridge.reset()
	show_overlay("")
	town.hide()
	combat = CombatSession.new()
	battle = combat.mount(world_clip)
	# 战斗视图与城镇同用 800×600 画布基准（view/world_frame.gd），1:1 像素，
	# 不缩放、不位移；地图与角色的纵向定位由 loader/view 统一承担。
	# CanvasLayer 不继承父变换：战斗 HUD 单独套同一份内容变换。
	# mount() 返回的是战斗场景根（main.gd），渲染视图在它的 view 属性上。
	if battle.get("view") != null:
		battle.view.hud_layer.transform = display_settings.content_transform()
	combat.room_combat_finished.connect(func(event: Dictionary): call_deferred("on_combat_event", event))
	combat.player_defeated.connect(func(event: Dictionary): call_deferred("on_combat_event", event))
	combat.monster_defeated.connect(func(event: Dictionary): call_deferred("on_combat_event", event))
	var stat: Dictionary = session.run["stats"]
	var headless_test := test_mode and DisplayServer.get_name() == "headless"
	var started: bool = combat.start_room({"run_id": String(session.run["id"]), "dungeon":selected_dungeon, "route":session.dungeons[selected_dungeon], "room_id": selected_dungeon+":0", "room_index": 0,
		"player": stat,
		"audio": {"muted": headless_test, "bgm_volume_db": -32}, "show_hud": false})
	if not started:
		combat.stop()
		battle = null
		combat = null
		session.command("flow.retreat")
		session.command("flow.return")
		town.show()
		notice("战斗资源尚未准备完成，请通过正式启动脚本重试")
		return
	combat.configure_trial(1.35, String(session.run.get("difficulty", "normal")))
	if session.dungeons[selected_dungeon].has("monster_level"):
		combat.configure_monsters(int(session.dungeons[selected_dungeon]["monster_level"]),String(session.run.get("difficulty","normal")))
	notice(String(session.dungeons[selected_dungeon]["name"])+" · 清除怪物后前往出口")
	sync_debug_pause()

func on_combat_event(event: Dictionary) -> void:
	if event.get("type")=="combat.player_defeated":recovery_bridge.receive(event);return
	var before_level := int(session.profile["level"])
	var response: Dictionary = session.combat_event(event)
	if response["ok"] and event.get("type")=="combat.monster_defeated" and (int(response.get("amount",0))>0 or response.get("quest_changed",false) or response.get("loot_changed",false)):
		if int(session.profile["level"])>before_level:sync_number_changes("numbers.xp")
		save_profile()
	if response["ok"] and session.state == "result":
		save_profile()
		show_overlay("result")
	if int(session.profile["level"])>before_level:notice("等级提升 · Lv.%d" % int(session.profile["level"]))

func result_panel() -> void:
	windows.result()
	if combat!=null:
		var view: Dictionary=combat.read_view()
		if not view.is_empty() and view["room_cleared"]:
			skin.button(modal,"收取本房掉落",Vector2(320,460),loot_bridge.collect_room).name="collect_room_loot"

func return_town() -> void:
	if not act("flow.return"):return
	if is_instance_valid(battle):
		combat.stop()
		battle = null
		combat = null
	town.show()
	show_overlay("")
	town.set_location(session.profile["town_location"],session.TownWorld.vec(session.profile["town_position"]))
	notice("回到"+String(town.world.scene(town.location)["name"])+" · " + ("保存失败，请重试" if save_failed else "进度已保存"))

func menu_panel() -> void:
	var panel = title_panel("冒险菜单", Rect2(218, 105, 364, 300))
	skin.button(panel, "继续游戏", Vector2(132, 58), func(): show_overlay(""))
	skin.button(panel, "保存进度", Vector2(132, 96), func(): save_profile())
	if session.state == "town":skin.button(panel, "返回选人", Vector2(132, 134), func():
		if save_profile():show_character_selection())
	if session.state == "battle":skin.button(panel, "撤退回城", Vector2(132, 134), func():
		if act("flow.retreat"):show_overlay("result"))
	skin.label(panel, "画面分辨率：%d×%d（固定）" % [display_settings.OUTPUT.x, display_settings.OUTPUT.y], Vector2(24, 177), 12, Color("f0d18a"))
	var fullscreen: Button = skin.button(panel, "编辑器预览" if Engine.is_embedded_in_editor() else "返回窗口" if display_settings.is_fullscreen() else "切换全屏", Vector2(24, 211), func():
		display_settings.toggle_fullscreen()
		show_overlay("menu"))
	fullscreen.disabled = Engine.is_embedded_in_editor()
	skin.button(panel, "调试面板 P", Vector2(135, 211), func(): set_debug_open(true))
	skin.label(panel, "编辑器工具栏控制预览 · 原版比例居中" if Engine.is_embedded_in_editor() else "F11 切换全屏 · 原版比例居中", Vector2(24, 255), 11)

func show_character_selection() -> void:
	if recovery_bridge!=null:recovery_bridge.reset()
	character_active = false
	set_debug_open(false)
	windows.close_purchase()
	windows.hide_tooltip()
	overlay = "characters"
	hud.hide()
	world_clip.hide()
	toast_panel.hide()
	for child in modal.get_children():
		if child is Control:child.mouse_filter = Control.MOUSE_FILTER_IGNORE
		child.queue_free()
	character_screen = CharacterScreen.new()
	character_screen.selected_path = active_character_path
	modal.add_child(character_screen)
	character_screen.setup(self)
	sync_debug_pause()

func enter_character(path: String) -> bool:
	# Read into a new state first, so a failed load cannot modify active progress.
	if character_active:return false
	var candidate = Store.new()
	candidate.path = path
	var next_session = Session.new()
	if not candidate.read_into(next_session):return false
	if not preload("res://content/weapon_appearance.gd").can_display(equipped_weapon_item(next_session.profile)):return false
	store = candidate
	active_character_path = path
	session = next_session
	selected_dungeon="lorien"
	character_active = true
	save_failed = false
	character_screen = null
	build_hotbars()
	world_clip.show()
	town.show()
	town.inn_return=session.profile.get("inn_return","enter_inn")
	town.set_equipped_weapon(equipped_weapon_item(),equipped_weapon_shape())
	if not town.set_location(String(session.profile.get("town_location","elvengard")),session.TownWorld.vec(session.profile["town_position"])):
		town.set_location("elvengard",Vector2(100,260))
		session.profile["town_location"]="elvengard"
		remember_town_position()
		notice("场景资源缺失，已返回艾尔文安全点")
	town.player_name = skin.chinese(String(session.profile["name"]))
	town.running = false
	town.run_direction = 0
	show_overlay("result" if session.state == "result" else "")
	notice("已从备份恢复存档 · "+String(town.world.scene(town.location)["name"]) if store.recovered else String(town.world.scene(town.location)["name"])+" · 欢迎 "+String(session.profile["name"]))
	return true

func debug_is_open() -> bool:
	return is_instance_valid(debug_panel) and debug_panel.visible

func set_debug_open(open: bool) -> void:
	if not open:debug_panel.command_input.release_focus()
	debug_panel.visible = open
	if open:windows.hide_tooltip()
	sync_debug_pause()
	debug_panel.refresh_status()

## 选人/城镇 BGM 与环境音初始化：原版 Music/*.ogg、sounds/amb/*.ogg 原字节，
## 映射见 data/bgm.json（tools/bake_dnf_bgm.py 生成，新场景在该表补一行即可）。
func _setup_bgm() -> void:
	town_bgm = AudioStreamPlayer.new()
	town_bgm.volume_db = -32.0
	add_child(town_bgm)
	town_amb = AudioStreamPlayer.new()
	town_amb.volume_db = -26.0
	add_child(town_amb)
	if not FileAccess.file_exists("res://data/bgm.json"):return
	var doc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/bgm.json"))
	bgm_scenes = doc.get("scenes", {})
	bgm_screens = doc.get("screens", {})
	bgm_ambience = doc.get("ambience", {})
	for key: String in doc.get("tracks", {}):
		var path := "res://assets_local/" + String(doc["tracks"][key]["file"])
		if not ResourceLoader.exists(path):continue
		var stream = load(path)
		if stream is AudioStreamOggVorbis:stream.loop = true
		bgm_tracks[key] = stream

## 三态切换：选人界面用界面曲，城镇用城市场景曲，战斗交给战斗侧（含 BOSS 曲）。
func update_bgm() -> void:
	if town_bgm == null or test_mode:return
	var scene := ""
	if not character_active:
		scene = "select"
	elif session.state != "battle" and is_instance_valid(town):
		scene = String(town.location)
	if scene != _bgm_scene:
		_bgm_scene = scene
		var key := ""
		if scene == "select":
			key = String(bgm_screens.get("select", ""))
		elif scene != "":
			key = String(bgm_scenes.get(scene, ""))
		if key != "" and bgm_tracks.has(key):
			town_bgm.stream = bgm_tracks[key]
			town_bgm.play()
		else:
			town_bgm.stop()
	var amb := ""
	if scene != "" and scene != "select":
		amb = "town" if bgm_scenes.has(scene) else "forest"
	if amb != _bgm_ambience:
		_bgm_ambience = amb
		var list: Array = bgm_ambience.get(amb, []) if amb != "" else []
		var pick := String(list[0]) if list.size() > 0 else ""
		if pick != "" and bgm_tracks.has(pick):
			town_amb.stream = bgm_tracks[pick]
			town_amb.play()
		else:
			town_amb.stop()

func sync_debug_pause() -> void:
	var open := debug_is_open()
	if is_instance_valid(town):town.enabled = not transitioning and not open and overlay == "" and session.state == "town"
	if is_instance_valid(battle):
		battle.set_process_input(false)
		combat.set_paused(open or overlay != "" or session.state != "battle")

func build_hotbars() -> void:
	session.Layout.normalize(session.profile, Catalog.ITEMS)
	for view in quick_views:
		if is_instance_valid(view):
			hud.remove_child(view)
			view.queue_free()
	quick_views.clear()
	for entry in skill_views.values():
		hud.remove_child(entry["view"])
		hud.remove_child(entry["counter"])
		entry["view"].queue_free()
		entry["counter"].queue_free()
	skill_views.clear()
	for i in 6:
		var cell = make_slot(hud, {"place":"quick", "index":i, "id":session.profile["quick_items"][i]}, Vector2(85 + i * 30, 558))
		var item_counter: Label=skin.label(cell,"",Vector2(2,3),10,Color.WHITE);item_counter.name="item_cooldown";item_counter.z_index=3
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
	else:windows.item_tip(cell.cell["id"], cell.get_global_rect(), cell.cell["place"] == "shop", cell.cell["place"] == "quick",cell.cell.get("uid",""))

func slot_pressed(cell: Control) -> void:
	if overlay=="services" and cell.cell["place"] in ["bag","service_equipment"]:service_windows.select(cell.cell)
	elif overlay=="upgrades" and cell.cell["place"] in ["bag","upgrade_equipment"]:upgrade_windows.select(cell.cell)
	elif cell.cell["place"] in ["bag","storage"]:inventory_tools.select(cell.cell)
	match cell.cell["place"]:
		"shop":windows.purchase_dialog(cell.cell["id"])
		"quick":use_quick(int(cell.cell["index"]))
		"skill":press_combat_key(SKILL_KEYS[int(cell.cell["index"])])

func slot_double_clicked(cell: Control) -> void:
	var id: String = cell.cell.get("id", "")
	if cell.cell["place"] == "equipment":
		if act("items.unequip",{"slot":cell.cell.get("slot","weapon")}):refresh_item_views()
	elif cell.cell["place"] == "bag" and Catalog.ITEMS.get(id, {}).get("kind") == "weapon":
		if act("items.equip", {"id":id,"uid":cell.cell.get("uid","")}):refresh_item_views()

func can_drop_slot(source: Dictionary, target: Dictionary) -> bool:
	if source.get("place") == "skill_catalog":return target.get("place") == "skill"
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
	# 换装后同步城镇手上的逐件武器外观（同一物品时是空操作）。
	if is_instance_valid(town):town.set_equipped_weapon(equipped_weapon_item(),equipped_weapon_shape())
	if overlay in ["inventory", "shop", "services", "upgrades"]:show_overlay(overlay)

## 当前装备武器的外观类型（numbers.json 的 equipment.<id>.weapon），缺省太刀。
func equipped_weapon_shape() -> String:
	if session == null:return "katana"
	var id := String(session.profile.get("equipped", ""))
	var entry: Dictionary = session.Numbers.config().get("equipment", {}).get(id, {})
	return String(entry.get("weapon", "katana"))

func equipped_weapon_item(profile: Dictionary = {}) -> String:
	if profile.is_empty():
		if session==null:return ""
		profile=session.profile
	var uid: String=profile["equipment"].get("weapon","")
	return String(profile["gear"][uid]["definition"]) if uid!="" else ""

func use_quick(index: int) -> void:
	var id: String = session.profile["quick_items"][index]
	if id!="":recovery_bridge.use_item(id)

func forward_battle_key(code: int, pressed: bool, echo := false) -> void:
	if not is_instance_valid(battle):return
	var index := SKILL_KEYS.find(code)
	if index >= 0:
		var id: String = session.profile["skill_slots"][index]
		if id == "":return
		code = SKILL_CODES[id]
	combat.submit_key(code, pressed, echo)

func use_potion() -> void:
	recovery_bridge.use_item("potion")
