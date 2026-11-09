extends RefCounted
## Source chapter quest, dialogue and tracker views with local content refresh.

const QuestWindowControls = preload("res://ui/flow/quest_window_controls.gd")
const WINDOW_RECT := Rect2(112, 55, 576, 416)
const TAB_NAMES := ["可接受", "进行中", "已完成"]
const TAB_STATES := [["available"], ["active", "ready"], ["completed"]]

var game
var selected := ""
var tab := 0
var focus_npc := ""
var tracker: Control
var tracker_signature := ""
var selected_choices: Dictionary = {}

var window: Control
var window_builds := 0
var window_refreshes := 0
var tab_buttons: Array[Button] = []
var list_scroll: ScrollContainer
var list_content: VBoxContainer
var detail_scroll: ScrollContainer
var detail_content: VBoxContainer
var action_content: Control
var feedback_label: Label
var list_buttons: Dictionary = {}
var choice_buttons: Dictionary = {}
var choice_data: Dictionary = {}
var choice_cancel: Button
var choice_status: Label
var primary_action: Button
var current_quest: Dictionary = {}
var list_signature := ""
var _detail_scroll_by_quest: Dictionary = {}
var _tracker_refresh_bound := false

func _init(root) -> void:
	game = root

func text(parent: Node, value: String, at: Vector2, size: Vector2, font_size := 12, color := Color("d4c9b1")) -> Label:
	var label: Label = game.skin.label(parent, value, at, font_size, color)
	label.size = size
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label

func dialogue() -> void:
	var npc: String = game.town.nearest()
	if not game.town.is_npc(npc):
		game.notice("请走到人物身旁交谈")
		return
	focus_npc = npc
	game.record_npc_visit(npc)
	var node: Control = game.windows.container(game.modal, Vector2(41, 343), Vector2(718, 165))
	node.name = "quest_dialogue"
	game.skin.image(node, game.skin.texture("dialog"), Vector2.ZERO)
	var portrait: Texture2D = game.skin.texture("dialog_face") if npc == "linus" else game.town.dialogue_portrait(npc)
	if portrait != null:
		game.skin.image(node, portrait, Vector2(8, 165 - portrait.get_height())).name = npc + "_dialogue_illustration"
	game.skin.label(node, game.session.quests.npc_name(npc), Vector2(215, 18), 16, Color("f0d18a"))
	var line := _dialogue_line(npc)
	var speech := ScrollContainer.new()
	speech.name = "quest_dialogue_speech_scroll"
	speech.position = Vector2(215, 51)
	speech.size = Vector2(475, 62)
	speech.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	node.add_child(speech)
	var speech_label := Label.new()
	speech_label.name = "quest_dialogue_speech"
	speech_label.text = game.skin.chinese(line)
	speech_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	speech_label.custom_minimum_size.x = 455
	speech_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	speech_label.add_theme_font_override("font", game.skin.font)
	speech_label.add_theme_font_size_override("font_size", 13)
	speech_label.add_theme_color_override("font_color", Color("d4c9b1"))
	speech.add_child(speech_label)
	var actions: Array[Button] = []
	_dialogue_action(node, actions, "委托任务", Vector2(215, 120), func():
		var active: Array = game.session.quests.list(game.session.profile, ["ready", "active"], npc)
		tab = 1 if not active.is_empty() else 0
		selected = ""
		game.show_overlay("quest"))
	if npc == "linus":
		_dialogue_action(node, actions, "购买物品", Vector2(325, 120), func(): game.show_overlay("shop"))
	var services: Array = game.town.npc_definition(npc)["services"]
	if services.any(func(id): return id in ["trade", "repair", "disassemble"]):
		_dialogue_action(node, actions, "物品服务", Vector2(435, 120), func(): game.show_overlay("services"))
	if "skills" in services:
		_dialogue_action(node, actions, "学习技能", Vector2(325, 120), func():
			game.number_windows.tab = 1
			game.show_overlay("numbers"))
	if "equipment" in services:
		_dialogue_action(node, actions, "装备整备", Vector2(325, 120), func():
			game.number_windows.tab = 2
			game.show_overlay("numbers"))
	if services.any(func(id): return id in ["reinforce", "enchant"]):
		_dialogue_action(node, actions, "强化" if "reinforce" in services else "附魔", Vector2(540, 120),
			func(): game.show_overlay("upgrades"), false)
	_dialogue_action(node, actions, "结束对话", Vector2(600, 120), func(): game.show_overlay(""))
	QuestWindowControls.focus_chain(actions)
	for action in actions:
		QuestWindowControls.add_focus_tint(action)
	node.set_meta("action_buttons", actions)
	game.skin.close_button(node, Vector2(686, 13), func(): game.show_overlay(""))

func _dialogue_action(parent: Control, actions: Array[Button], label: String, at: Vector2, action: Callable, wide := true) -> Button:
	var button: Button = game.skin.button(parent, label, at, action, wide)
	button.name = "quest_dialogue_action_%d" % actions.size()
	actions.append(button)
	return button

func _dialogue_line(npc: String) -> String:
	var line: String = game.town.npc_definition(npc)["dialogue"]
	if npc == "linus" and game.session.quests.status(game.session.profile, "hendon.meet_pungjin") in ["available", "active"]:
		line = "你已经历练了一番。沿防线左侧去赫顿玛尔吧，经城市区向上走，到主街找风振聊聊。"
	if npc == "seria" and game.session.quests.status(game.session.profile, "elvengard.seria_fate") == "completed":
		line = "看到你平安回来，我就放心了。赫顿玛尔还有许多值得结识的人，祝你旅途顺利。"
	var ready: Array = game.session.quests.list(game.session.profile, ["ready"], npc)
	if not ready.is_empty():
		line = "你回来了，辛苦了。\n打开任务记录，把这次冒险的收获告诉我吧。"
	for quest: Dictionary in ready:
		match quest["id"]:
			"hendon.meet_pungjin": line = "林纳斯让你来的？欢迎来到赫顿玛尔。\n这里有许多能帮助你修行的人，先让我介绍一下。"
			"hendon.swordman_start": line = "鬼剑士要走的路，需要你自己选择。\n先去后街拜访辛达，他会告诉你更多。"
			"hendon.meet_sinda": line = "风振介绍你来的？我是铁匠辛达。\n坐下聊聊吧，修行和装备都有不少学问。"
			"hendon.job_introduction": line = "转职会让你的修行走向不同道路。\n眼下先磨炼基础，之后可向G.S.D了解鬼剑士的修行。"
			"gran.tau_rage": line = "牛头巨兽已经被击败了？辛苦了。\n森林深处的猫妖也很不安分，接下来还得请你帮忙。"
			"gran.cat_trouble": line = "猫妖的数量总算减少了。\n关于那只呼唤闪电的哥布林，后街小巷的夏洛克也许知道些什么。"
			"gran.meet_shylock": line = "风振让你来打听凯诺？森林里的事，我可知道不少。\n先坐下来聊聊，别把我和那些闹事的哥布林混为一谈。"
	if not ready.is_empty():
		line = String(ready[0].get("dialogue", {}).get("complete", line))
	elif not game.session.quests.list(game.session.profile, ["available"], npc).is_empty():
		var available: Array = game.session.quests.list(game.session.profile, ["available"], npc)
		line = String(available[0].get("dialogue", {}).get("accept", line))
	return line

func show_window() -> void:
	if is_instance_valid(window) and not window.is_queued_for_deletion() \
		and window.is_inside_tree() and window.get_parent() == game.modal:
		_refresh_window()
		return
	_build_window()

func _build_window() -> void:
	window_builds += 1
	window = game.windows.board(game.modal, "任务", WINDOW_RECT)
	window.name = "quest_window"
	tab_buttons.clear()
	list_buttons.clear()
	choice_buttons.clear()
	choice_data.clear()
	list_signature = ""
	for index in TAB_NAMES.size():
		var tab_index := index
		var button: Button = game.skin.button(window, TAB_NAMES[index], Vector2(17 + index * 84, 41),
			func(): _select_tab(tab_index), false, "tab")
		button.name = "quest_tab_%d" % index
		button.size.x = 80
		button.focus_mode = Control.FOCUS_ALL
		tab_buttons.append(button)
	game.skin.surface(window, Rect2(16, 73, 236, 288), "quest_list", 5)
	game.skin.surface(window, Rect2(265, 73, 295, 288), "quest", 16)

	list_scroll = ScrollContainer.new()
	list_scroll.name = "quest_window_list_scroll"
	list_scroll.position = Vector2(20, 78)
	list_scroll.size = Vector2(228, 278)
	list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	window.add_child(list_scroll)
	list_content = VBoxContainer.new()
	list_content.name = "quest_window_list_content"
	list_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_content.add_theme_constant_override("separation", 3)
	list_scroll.add_child(list_content)

	detail_scroll = ScrollContainer.new()
	detail_scroll.name = "quest_window_detail_scroll"
	detail_scroll.position = Vector2(279, 85)
	detail_scroll.size = Vector2(272, 268)
	detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	window.add_child(detail_scroll)
	detail_content = VBoxContainer.new()
	detail_content.name = "quest_window_detail_content"
	detail_content.custom_minimum_size.x = 250
	detail_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_content.add_theme_constant_override("separation", 8)
	detail_scroll.add_child(detail_content)

	action_content = Control.new()
	action_content.name = "quest_window_actions"
	action_content.size = Vector2(576, 40)
	window.add_child(action_content)
	feedback_label = game.skin.label(window, "", Vector2(278, 361), 10, Color("e58d7c"))
	feedback_label.name = "quest_window_feedback"
	feedback_label.size = Vector2(268, 14)
	feedback_label.clip_text = true
	feedback_label.visible = false
	_refresh_window()

func _select_tab(index: int) -> void:
	if index == tab:
		return
	_record_detail_scroll()
	tab = clampi(index, 0, TAB_NAMES.size() - 1)
	selected = ""
	if is_instance_valid(feedback_label):
		feedback_label.text = ""
		feedback_label.visible = false
	_refresh_window()

func select_quest(id: String) -> void:
	if id == selected:
		return
	_record_detail_scroll()
	selected = id
	if is_instance_valid(feedback_label):
		feedback_label.text = ""
		feedback_label.visible = false
	_refresh_window()

func _record_detail_scroll() -> void:
	if selected != "" and is_instance_valid(detail_scroll):
		_detail_scroll_by_quest[selected] = detail_scroll.scroll_vertical

func _refresh_window() -> void:
	if not is_instance_valid(window) or window.is_queued_for_deletion():
		return
	window_refreshes += 1
	var list_value := list_scroll.scroll_vertical if is_instance_valid(list_scroll) else 0
	for index in tab_buttons.size():
		tab_buttons[index].modulate = Color("ffdb85") if index == tab else Color.WHITE
	var rows: Array = game.session.quests.list(game.session.profile, TAB_STATES[tab])
	if selected == "" or not rows.any(func(quest): return quest["id"] == selected):
		selected = ""
		for quest: Dictionary in rows:
			if focus_npc == "" or focus_npc in [quest["giver"], quest["receiver"]]:
				selected = quest["id"]
				break
		if selected == "" and not rows.is_empty():
			selected = rows[0]["id"]
	_sync_list(rows)
	if rows.is_empty():
		current_quest = {}
		QuestWindowControls.clear_children(detail_content)
		var empty := Label.new()
		empty.name = "quest_window_empty"
		empty.text = "暂无该类任务"
		empty.position = Vector2(28, 21)
		empty.size = Vector2(210, 24)
		empty.add_theme_font_override("font", game.skin.font)
		empty.add_theme_font_size_override("font_size", 12)
		empty.add_theme_color_override("font_color", Color("d4c9b1"))
		detail_content.add_child(empty)
		_build_actions({})
		_restore_scrolls(list_value, 0)
		return
	current_quest = {}
	for quest: Dictionary in rows:
		if quest["id"] == selected:
			current_quest = quest
			break
	_build_detail(current_quest)
	_build_actions(current_quest)
	_restore_scrolls(list_value, int(_detail_scroll_by_quest.get(selected, 0)))

func _sync_list(rows: Array) -> void:
	var next_signature := ""
	for quest: Dictionary in rows:
		next_signature += "%s|%s|%s\n" % [quest["id"], quest["status"], quest["name"]]
	if next_signature == list_signature:
		_update_list_selection()
		return
	QuestWindowControls.clear_children(list_content)
	list_buttons.clear()
	for index in rows.size():
		var quest: Dictionary = rows[index]
		var id: String = quest["id"]
		var button := Button.new()
		button.name = "quest_window_row_%d" % index
		button.custom_minimum_size = Vector2(220, 43)
		button.flat = true
		button.focus_mode = Control.FOCUS_ALL
		button.add_theme_font_override("font", game.skin.font)
		button.add_theme_font_size_override("font_size", 12)
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var category: String = {"daily": "[每日] ", "repeat": "[重复] "}.get(
			quest.get("lifecycle", "once"), "[主线] " if quest["category"] == "main" else "[支线] ")
		button.text = category + String(quest["name"]) + ("  ✓" if quest["status"] == "ready" else "")
		button.set_meta("quest_id", id)
		button.pressed.connect(select_quest.bind(id))
		button.focus_entered.connect(select_quest.bind(id))
		list_content.add_child(button)
		list_buttons[id] = button
	list_signature = next_signature
	_update_list_selection()

func _update_list_selection() -> void:
	for id: String in list_buttons:
		var button: Button = list_buttons[id]
		if is_instance_valid(button):
			button.modulate = Color("ffdd85") if id == selected else Color.WHITE

func _build_detail(quest: Dictionary) -> void:
	QuestWindowControls.clear_children(detail_content)
	choice_buttons.clear()
	choice_data.clear()
	choice_cancel = null
	choice_status = null
	primary_action = null
	if quest.is_empty():
		return
	detail_line(detail_content, quest["name"], 17, Color("f0d18a"))
	detail_line(detail_content, "委托：%s  交付：%s\n等级：Lv.%d" % [
		game.session.quests.npc_name(quest["giver"]), game.session.quests.npc_name(quest["receiver"]),
		int(quest["min_level"])])
	detail_line(detail_content, quest["description"])
	if quest.get("lifecycle", "once") != "once":
		var calendar: Dictionary = game.session.quests.catalog.config.get("calendar", {})
		detail_line(detail_content, ("每日任务 · 每日 %02d:00 刷新" % int(calendar.get("reset_hour", 0))
			if quest["lifecycle"] == "daily" else "重复任务 · 完成后可再次接受")
			+ "\n累计完成 %d 次" % int(quest.get("completions", 0)), 12, Color("f0d18a"))
	detail_line(detail_content, "任务目标", 12, Color("f0d18a"))
	for objective: Dictionary in quest["objectives"]:
		detail_line(detail_content, objective_line(objective), 12, Color("a7dd74"))
	detail_line(detail_content, "任务奖励", 12, Color("f0d18a"))
	detail_line(detail_content, "金币 %d    经验 %d" % [int(quest["reward"]["gold"]), int(quest["reward"]["xp"])])
	var rewards := HFlowContainer.new()
	rewards.name = "quest_window_reward_items"
	rewards.custom_minimum_size = Vector2(250, 32)
	rewards.add_theme_constant_override("h_separation", 6)
	rewards.add_theme_constant_override("v_separation", 4)
	detail_content.add_child(rewards)
	for item: String in quest["reward"]["items"]:
		game.make_slot(rewards, {"place": "reward", "id": item,
			"count": int(quest["reward"]["items"][item])}, Vector2.ZERO)
	var choices: Array = quest["reward"].get("choices", [])
	if not choices.is_empty():
		detail_line(detail_content, "请选择一项奖励", 12, Color("f0d18a"))
		var options := VBoxContainer.new()
		options.name = "quest_window_reward_choices"
		options.add_theme_constant_override("separation", 4)
		detail_content.add_child(options)
		for index in choices.size():
			var choice: Dictionary = choices[index]
			var option := Button.new()
			option.name = "quest_window_choice_%d" % index
			option.flat = true
			option.focus_mode = Control.FOCUS_ALL
			option.alignment = HORIZONTAL_ALIGNMENT_LEFT
			option.add_theme_font_override("font", game.skin.font)
			option.add_theme_font_size_override("font_size", 12)
			option.set_meta("choice_id", String(choice["id"]))
			option.pressed.connect(_toggle_choice.bind(String(quest["id"]), String(choice["id"])))
			options.add_child(option)
			choice_buttons[String(choice["id"])] = option
			choice_data[String(choice["id"])] = choice
		choice_status = detail_line(detail_content, "", 11, Color("f0d18a"))
		choice_status.name = "quest_window_choice_status"
		choice_cancel = Button.new()
		choice_cancel.name = "quest_window_choice_cancel"
		choice_cancel.text = "取消选择"
		choice_cancel.flat = true
		choice_cancel.focus_mode = Control.FOCUS_ALL
		choice_cancel.add_theme_font_override("font", game.skin.font)
		choice_cancel.add_theme_font_size_override("font_size", 11)
		choice_cancel.pressed.connect(_clear_choice.bind(String(quest["id"])))
		detail_content.add_child(choice_cancel)
		_update_choice_ui(String(quest["id"]))

func _toggle_choice(quest_id: String, choice_id: String) -> void:
	if selected_choices.get(quest_id, "") == choice_id:
		selected_choices.erase(quest_id)
	else:
		selected_choices[quest_id] = choice_id
	_update_choice_ui(quest_id)

func _clear_choice(quest_id: String) -> void:
	selected_choices.erase(quest_id)
	_update_choice_ui(quest_id)

func _update_choice_ui(quest_id: String) -> void:
	var chosen := String(selected_choices.get(quest_id, ""))
	if chosen != "" and not choice_data.has(chosen):
		selected_choices.erase(quest_id)
		chosen = ""
	for id: String in choice_buttons:
		var option: Button = choice_buttons[id]
		if not is_instance_valid(option):
			continue
		var choice: Dictionary = choice_data[id]
		option.text = ("● " if id == chosen else "○ ") \
			+ String(game.Catalog.ITEMS[choice["item"]]["name"]) + " ×" + str(int(choice["amount"]))
	if is_instance_valid(choice_cancel):
		choice_cancel.visible = chosen != ""
	if is_instance_valid(choice_status):
		choice_status.text = game.skin.chinese("已选择：" + String(game.Catalog.ITEMS[choice_data[chosen]["item"]]["name"])
			if chosen != "" else "尚未选择奖励")
	if is_instance_valid(primary_action) and bool(primary_action.get_meta("requires_choice", false)):
		primary_action.disabled = chosen == ""

func detail_line(parent: VBoxContainer, value: String, size := 12, color := Color("d4c9b1")) -> Label:
	var line := Label.new()
	line.text = game.skin.chinese(value)
	line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_theme_font_override("font", game.skin.font)
	line.add_theme_font_size_override("font_size", size)
	line.add_theme_color_override("font_color", color)
	parent.add_child(line)
	return line

func objective_line(objective: Dictionary) -> String:
	var label := ""
	match objective["type"]:
		"meet_npc": label = "拜访" + game.session.quests.npc_name(objective["target"])
		"clear_dungeon": label = "通关" + ("已接入的任意地下城" if objective["target"] == "any"
			else String(game.session.quests.catalog.config["dungeons"].get(objective["target"], objective["target"])))
		"kill_monster": label = String(game.session.quests.catalog.config["dungeons"].get(objective.get("dungeon", ""), "")) \
			+ " · " + String(game.session.quests.catalog.config.get("monsters", {}).get(objective["target"], "目标怪物"))
		"collect_item": label = String(game.Catalog.ITEMS.get(objective["target"], {}).get("name", objective["target"]))
		"learn_skill": label = "学习任意技能一级"
		"disassemble_item": label = "在" + game.session.quests.npc_name(objective["npc"]) + "处分解一件装备"
		"clear_map":
			label = String(game.session.quests.catalog.config["dungeons"].get(objective.get("dungeon", ""), "目标地图"))
			label += " · 单人通关并确保 G.S.D. 存活" if objective.has("companion_id") else " · 特殊地图目标"
	var rules: Dictionary = objective.get("conditions", {})
	if rules.has("max_elapsed_ms"): label += " · 限时 %g 秒" % (float(rules["max_elapsed_ms"]) / 1000.0)
	if rules.has("max_hits_taken"): label += " · 被击不超过 %d 次" % int(rules["max_hits_taken"])
	if rules.has("max_revives"): label += " · 复活不超过 %d 次" % int(rules["max_revives"])
	if rules.has("min_party_size"): label += " · 至少 %d 人" % int(rules["min_party_size"])
	if objective.has("difficulty"):
		var names: Array = []
		for mode: String in objective["difficulty"]:
			names.append({"normal": "普通级", "adventure": "冒险级", "expert": "勇士级", "king": "王者级"}.get(mode, "未知难度"))
		label += "（" + "、".join(names) + "）"
	return "%s  %d / %d" % [label, int(objective["current"]), int(objective["amount"])]

func _build_actions(quest: Dictionary) -> void:
	QuestWindowControls.clear_children(action_content)
	primary_action = null
	if quest.is_empty():
		game.skin.label(action_content, "0 / %d 进行中" % int(game.session.quests.catalog.config["limits"]["active"]),
			Vector2(23, 379), 11)
		return
	var id: String = quest["id"]
	var state: String = quest["status"]
	if state in ["active", "ready"]:
		var tracking: Button = game.skin.button(action_content, "取消追踪" if quest["tracked"] else "追踪任务",
			Vector2(278, 377), func(): _run_action("quest.track", id, state))
		tracking.name = "quest_window_track"
		tracking.focus_mode = Control.FOCUS_ALL
	if state in ["available", "ready"]:
		var requires_choice: bool = state == "ready" and not quest["reward"].get("choices", []).is_empty()
		primary_action = game.skin.button(action_content, "接受委托" if state == "available" else "领取报酬",
			Vector2(450, 377), func(): _run_action("quest.accept" if state == "available" else "quest.claim", id, state))
		primary_action.name = "quest_window_primary"
		primary_action.focus_mode = Control.FOCUS_ALL
		primary_action.set_meta("requires_choice", requires_choice)
		primary_action.set_meta("quest_id", id)
		primary_action.disabled = requires_choice and String(selected_choices.get(id, "")) == ""
	else:
		var status: Label = game.skin.label(action_content, "已完成" if state == "completed" else "进行中",
			Vector2(481, 379), 12)
		status.name = "quest_window_status"
	game.skin.label(action_content, "%d / %d 进行中" % [
		game.session.quests.active_count(game.session.profile),
		int(game.session.quests.catalog.config["limits"]["active"])], Vector2(23, 379), 11)

func _run_action(kind: String, id: String, state: String) -> void:
	if is_instance_valid(feedback_label):
		feedback_label.visible = false
		feedback_label.text = ""
	var ok: bool = game.quest_action(kind, {"id": id, "choice": String(selected_choices.get(id, ""))})
	if not ok:
		if is_instance_valid(feedback_label):
			feedback_label.text = game.skin.chinese(String(game.notification))
			feedback_label.visible = feedback_label.text != ""
		return
	selected = id
	if kind == "quest.accept":
		tab = 1
	elif kind == "quest.claim":
		tab = 2
	_refresh_window()

func _restore_scrolls(list_value: int, detail_value: int) -> void:
	await game.get_tree().process_frame
	if is_instance_valid(list_scroll):
		list_scroll.scroll_vertical = maxi(0, list_value)
	if is_instance_valid(detail_scroll):
		detail_scroll.scroll_vertical = maxi(0, detail_value)
	await game.get_tree().process_frame
	if is_instance_valid(list_scroll):
		list_scroll.scroll_vertical = maxi(0, list_value)
	if is_instance_valid(detail_scroll):
		detail_scroll.scroll_vertical = maxi(0, detail_value)

func dungeon() -> void:
	# One configured selector for both source chapters and later regions.
	game.windows.dungeon()

## Existing right-side guide layout, independent of the dungeon selector.
const GUIDE_SCALE := 2.0 / 3.0
const GUIDE_SIZE := Vector2(159, 98)
const GUIDE_ORIGIN := Vector2(641, 132)
const GUIDE_TOAST_DROP := 30.0
const GUIDE_TITLE_COLOR := Color("f0d18a")
const GUIDE_BODY_COLOR := Color("c9bda3")
const GUIDE_DONE_COLOR := Color("8fc46a")
const GUIDE_MAX_OBJECTIVES := 3
const GUIDE_TITLE_FONT := 10
const GUIDE_BODY_FONT := 9
const GUIDE_ROW_STEP := 12.0

func refresh_tracker() -> void:
	if not is_instance_valid(tracker):
		_build_tracker()
	var shown: bool = game.character_active and game.overlay == "" and not game.debug_is_open() and game.session.state in ["town", "battle"]
	var tracked: Array = []
	var offers: Array = []
	var marks := {}
	for quest: Dictionary in game.session.quests.list(game.session.profile, ["available", "active", "ready"]):
		if quest["status"] == "ready":
			marks[quest["receiver"]] = "?"
		elif quest["status"] == "available" and not marks.has(quest["giver"]):
			marks[quest["giver"]] = "!"
		if quest["tracked"]:
			tracked.append(quest)
		elif quest["status"] == "available" and offers.is_empty():
			offers.append(quest)
	game.town.quest_marks = marks
	tracker.visible = shown
	if not tracker.visible:
		return
	tracker.position = GUIDE_ORIGIN + (Vector2(0, GUIDE_TOAST_DROP) if game.toast_panel.visible else Vector2.ZERO)
	tracker.modulate.a = 1.0 if game.session.state == "town" else 0.92
	var signature := ""
	for quest: Dictionary in tracked:
		signature += str(quest["id"]) + "|" + str(quest["status"]) + "|" + str(quest["name"])
		for objective: Dictionary in quest["objectives"]:
			signature += "|" + str(objective["id"]) + ":" + str(objective["current"])
		signature += "\n"
	signature += "offer:" + str(offers[0]["id"] if not offers.is_empty() else "")
	if signature == tracker_signature:
		return
	tracker_signature = signature
	_fill_tracker(tracked, offers)

func _build_tracker() -> void:
	tracker = game.windows.container(game.ui, GUIDE_ORIGIN, GUIDE_SIZE)
	tracker.name = "quest_guide"
	tracker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	game.skin.image(tracker, game.skin.texture("quest", 14), Vector2.ZERO, GUIDE_SCALE).name = "quest_guide_board"
	game.skin.image(tracker, game.skin.texture("quest", 0), Vector2(5, 4), GUIDE_SCALE).name = "quest_guide_icon"
	game.skin.image(tracker, game.skin.texture("quest", 1), Vector2(2, 30), GUIDE_SCALE).name = "quest_guide_rule"
	tracker.set_meta("rows", [])
	if not _tracker_refresh_bound:
		_tracker_refresh_bound = true
		game.modal.child_entered_tree.connect(func(_node): call_deferred("refresh_tracker"))
		game.modal.child_exiting_tree.connect(func(_node): call_deferred("refresh_tracker"))

func _fill_tracker(tracked: Array, offers: Array = []) -> void:
	var model: Array[Dictionary] = []
	if tracked.is_empty():
		model.append(_guide_model("任务指引", GUIDE_TITLE_COLOR, 7.0, true))
		var idle_y := 34.0
		model.append(_guide_model("暂未追踪任务", GUIDE_BODY_COLOR, idle_y))
		idle_y += GUIDE_ROW_STEP
		if not offers.is_empty():
			var offer: Dictionary = offers[0]
			model.append(_guide_model("可接：" + String(offer["name"]), GUIDE_TITLE_COLOR, idle_y))
			idle_y += GUIDE_ROW_STEP
			model.append(_guide_model("找 " + game.session.quests.npc_name(offer["giver"]), GUIDE_BODY_COLOR, idle_y))
		_sync_tracker_rows(model)
		return
	var quest: Dictionary = tracked[0]
	model.append(_guide_model(str(quest["name"]), GUIDE_TITLE_COLOR, 7.0, true))
	var y := 34.0
	if quest["status"] == "ready":
		model.append(_guide_model("目标已完成", GUIDE_DONE_COLOR, y))
		y += GUIDE_ROW_STEP
		model.append(_guide_model("回城向 %s 交付" % game.session.quests.npc_name(quest["receiver"]),
			GUIDE_TITLE_COLOR, y))
	else:
		var objectives: Array = quest["objectives"]
		for index in mini(objectives.size(), GUIDE_MAX_OBJECTIVES):
			var objective: Dictionary = objectives[index]
			var done: bool = int(objective["current"]) >= int(objective["amount"])
			model.append(_guide_model(("✓ " if done else "· ") + objective_line(objective),
				GUIDE_DONE_COLOR if done else GUIDE_BODY_COLOR, y))
			y += GUIDE_ROW_STEP
		if objectives.size() > GUIDE_MAX_OBJECTIVES:
			model.append(_guide_model("  另有 %d 项" % (objectives.size() - GUIDE_MAX_OBJECTIVES),
				GUIDE_BODY_COLOR, y))
			y += GUIDE_ROW_STEP
		if tracked.size() > 1:
			model.append(_guide_model("  另 %d 条追踪中" % (tracked.size() - 1), GUIDE_BODY_COLOR, y))
	_sync_tracker_rows(model)

func _guide_model(value: String, color: Color, y: float, title := false) -> Dictionary:
	return {"text": value, "color": color, "y": y, "title": title}

func _sync_tracker_rows(model: Array[Dictionary]) -> void:
	var rows: Array = tracker.get_meta("rows", [])
	while rows.size() > model.size():
		var extra: Control = rows.pop_back()
		if is_instance_valid(extra):
			tracker.remove_child(extra)
			extra.queue_free()
	for index in model.size():
		var row: Label
		if index < rows.size() and is_instance_valid(rows[index]):
			row = rows[index] as Label
		else:
			row = Label.new()
			row.mouse_filter = Control.MOUSE_FILTER_IGNORE
			tracker.add_child(row)
			rows.append(row)
		var entry: Dictionary = model[index]
		row.name = "quest_guide_row_%d" % index
		row.text = game.skin.chinese(String(entry["text"]))
		row.position = Vector2(36 if entry["title"] else 8, float(entry["y"]))
		row.size = Vector2(116 if entry["title"] else 146, 15 if entry["title"] else 13)
		row.clip_text = true
		row.add_theme_font_override("font", game.skin.font)
		row.add_theme_font_size_override("font_size", GUIDE_TITLE_FONT if entry["title"] else GUIDE_BODY_FONT)
		row.add_theme_color_override("font_color", entry["color"])
	tracker.set_meta("rows", rows)
