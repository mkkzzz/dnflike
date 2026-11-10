extends Control
## Native UI pieces, command buttons, bounded log and editable command history.
const Commands = preload("res://debug/loop_commands.gd")
const CATEGORIES := [
	{"id":"role", "name":"角色"},
	{"id":"skill", "name":"技能"},
	{"id":"gear", "name":"装备"},
	{"id":"dungeon", "name":"副本"},
	{"id":"quest", "name":"任务"},
	{"id":"combat", "name":"战斗"},
]
const QUICK_ACTIONS := {
	"role":[
		["等级 1","level 1"],["等级 18","level 18"],["等级 35","level 35"],["等级 50","level 50"],
		["等级 60","level 60"],["SP +1000","sp 1000"],["经验 +1000","xp 1000"],["金币 +1000","gold 1000"],
		["鬼剑士","job swordman"],["剑魂","job weaponmaster"],["鬼泣","job soulbringer"],["狂战士","job berserker"],
		["阿修罗","job asura"],["觉醒 0","awakening 0"],["觉醒 1","awakening 1"],["觉醒 2","awakening 2"],
		["查看状态","status"],["保存","save"],["命令帮助","help"],
	],
	"skill":[
		["本职业主动满级","skill maxjob active"],["本职业全部满级","skill maxjob all"],["已学技能","skill learned"],
		["技能重置","skill reset"],["当前技能表","skill list current"],["SP +1000","sp 1000"],
	],
	"gear":[
		["整套品质100","gear kit 100"],["整套品质50","gear kit 50"],["装备图鉴","gear catalog"],
		["装备列表","gear list"],["最优武器","gear best weapon"],["最优上衣","gear best coat"],
		["全部修复","gear repairall"],["全部耐久0","gear breakall"],["全部强化+10","gear reinforceall 10"],
		["全部强化0","gear reinforceall 0"],["卸下全部","gear unequipall"],
	],
	"dungeon":[
		["副本列表","dungeon list"],["当前副本","dungeon current"],["重开副本","dungeon restart"],
		["领主房","room boss"],["下一房","room next"],["清空本房","clear"],
		["普通","difficulty normal"],["冒险","difficulty adventure"],["专家","difficulty expert"],["王者","difficulty king"],
	],
	"quest":[
		["当前任务","quest current"],["可接任务","quest available"],["进行中","quest active"],
		["可交付","quest ready"],["已完成","quest completed"],["全部准备交付","quest readyall"],
	],
	"combat":[
		["进入副本","dungeon enter"],["返回城镇","town"],["无敌开关","god"],["满血满蓝","heal"],["清除冷却","cooldown"],
		["清空本房","clear"],["下一房","room next"],["领主房","room boss"],["刷哥布林","spawn goblin 1"],
		["刷本房怪","spawn current 3"],["刷投掷手","spawn thrower 1"],["刷领主","spawn chief 1"],["直接通关","win"],["角色战败","lose"],
		["碰撞显示","collision"],["太刀外观","weapon katana"],["短剑外观","weapon shortsword"],["巨剑外观","weapon greatsword"],
	],
}
var game
var commands
var panel: Control
var category_bar: Control
var action_bar: Control
var active_category := "role"
var category_buttons: Dictionary = {}
var command_input: LineEdit
var log_view: RichTextLabel
var status_label: Label
var history: Array[String] = []
var history_index := 0
var messages: Array[String] = []
var draft := ""

func setup(target) -> void:
	game = target
	commands = Commands.new(game)
	name = "gm_debug_panel"
	size = Vector2(800, 600)
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 400
	panel = game.skin.panel(self, Rect2(52, 35, 696, 514))
	game.skin.label(panel, "GM 调试面板", Vector2(20, 15), 19, Color("f0d18a"))
	game.skin.button(panel, "关闭", Vector2(619, 15), func(): game.set_debug_open(false), false)
	game.skin.label(panel, "P 开关 · 输入时 P 为文字 · Esc 关闭 · ↑↓ 命令历史", Vector2(20, 45), 11)
	category_bar = Control.new()
	category_bar.position = Vector2(20,73)
	category_bar.size = Vector2(656,24)
	category_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(category_bar)
	action_bar = Control.new()
	action_bar.position = Vector2(20,102)
	action_bar.size = Vector2(656,174)
	action_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(action_bar)
	status_label = game.skin.label(panel, "", Vector2(20, 250), 11, Color("a7dd74"))
	status_label.size = Vector2(656, 56)
	status_label.clip_text = true
	game.skin.item_board(panel, Rect2(20, 310, 656, 120))
	log_view = RichTextLabel.new()
	log_view.position = Vector2(29, 318)
	log_view.size = Vector2(638, 104)
	log_view.add_theme_font_override("normal_font", game.skin.font)
	log_view.add_theme_font_size_override("normal_font_size", 11)
	log_view.add_theme_color_override("default_color", Color("e8ddb9"))
	log_view.scroll_following = true
	log_view.selection_enabled = true
	panel.add_child(log_view)
	game.skin.item_board(panel, Rect2(20, 445, 548, 29))
	command_input = LineEdit.new()
	command_input.name = "command_input"
	command_input.position = Vector2(27, 447)
	command_input.size = Vector2(534, 25)
	command_input.placeholder_text = "输入命令：spawn goblin 3 或 help"
	command_input.max_length = 256
	# Godot normally leaves editing mode after Enter. A console must accept
	# consecutive submissions without requiring a second Enter or another click.
	command_input.keep_editing_on_text_submit = true
	command_input.focus_entered.connect(command_input.edit)
	command_input.add_theme_font_override("font", game.skin.font)
	command_input.add_theme_font_size_override("font_size", 12)
	command_input.add_theme_color_override("font_color", Color("eeeeee"))
	for state in ["normal", "focus", "read_only"]:command_input.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	command_input.text_submitted.connect(func(_text: String): submit())
	command_input.gui_input.connect(input_history)
	panel.add_child(command_input)
	game.skin.button(panel, "执行命令", Vector2(579, 447), submit)
	game.skin.label(panel, "开面板时暂停战斗；金币、道具与等级修改会保存进度。", Vector2(20, 486), 11, Color("b8ac91"))
	append_log("就绪。点击按钮，或输入 help 查看命令；战斗命令需先进入副本。")
	_refresh_categories()
	_refresh_actions()
	status_label.text = commands.status()
	hide()

func is_typing() -> bool:return visible and command_input.has_focus()

func refresh_status() -> void:
	if visible:
		status_label.text = commands.status()
		_refresh_actions()

func _clear_control(node: Control) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()

func _refresh_categories() -> void:
	_clear_control(category_bar)
	category_buttons.clear()
	for index in CATEGORIES.size():
		var entry: Dictionary = CATEGORIES[index]
		var id := String(entry["id"])
		var button: Button = game.skin.button(category_bar,String(entry["name"]),
			Vector2(index*108,0),func():set_category(id),false,"tab")
		button.name = "gm_category_" + id
		button.size = Vector2(100,23)
		button.set_meta("gm_category",id)
		button.modulate = Color("ffdb85") if id == active_category else Color.WHITE
		category_buttons[id] = button

func set_category(id: String) -> void:
	if id == active_category:return
	active_category=id
	_refresh_categories()
	_refresh_actions()

func _refresh_actions() -> void:
	if not is_instance_valid(action_bar):return
	_clear_control(action_bar)
	var actions: Array = quick_actions(active_category)
	for index in mini(actions.size(),20):
		var entry: Array = actions[index]
		var label := String(entry[0])
		var command := String(entry[1])
		var button: Button = game.skin.button(action_bar,label,
			Vector2((index%4)*164,floori(index/4.0)*30),func():execute(command))
		button.size = Vector2(146,25)
		button.set_meta("gm_command",command)
		button.tooltip_text = command
		var reason := command_disabled_reason(command)
		button.disabled = reason != ""
		if reason != "":button.tooltip_text = reason + "\n" + command

func quick_actions(id: String) -> Array:
	var actions: Array = (QUICK_ACTIONS.get(id,[]) as Array).duplicate(true)
	match id:
		"skill":
			var panel = game.number_windows.skill_panel
			var ids := {}
			for node: Dictionary in panel.tree_nodes(panel.current_branch()):ids[int(node.get("id",-1))]=true
			for skill: Dictionary in panel.skills:
				if not ids.has(int(skill.get("id",-1))) or String(skill.get("local_id","")) == "":continue
				if "[passive]" in String(skill.get("type","")):continue
				actions.append(["满级 "+String(skill.get("name","")),"skill "+String(skill["local_id"])+" max"])
				if actions.size()>=20:break
		"dungeon":
			var ids: Array = game.session.dungeons.keys()
			ids.sort_custom(func(a,b):
				return int(game.session.dungeons[a].get("min_level",1)) < int(game.session.dungeons[b].get("min_level",1)))
			for dungeon_id: String in ids:
				var dungeon: Dictionary = game.session.dungeons[dungeon_id]
				if dungeon.get("legacy",false) or not game.session.dungeon_available(dungeon_id):continue
				actions.append(["进入 "+String(dungeon.get("name",dungeon_id)),"dungeon enter "+dungeon_id])
				if actions.size()>=20:break
		"quest":
			var active: Array = game.session.quests.list(game.session.profile,["active","ready"])
			for quest: Dictionary in active:
				var ready := String(quest.get("status","")) == "ready"
				actions.append([("交付 " if ready else "完成 ")+String(quest.get("name",quest["id"])),
					("quest claim " if ready else "quest ready ")+String(quest["id"])])
				if actions.size()>=20:break
	return actions

func command_disabled_reason(command: String) -> String:
	var words := command.split(" ",false)
	if words.is_empty():return ""
	var cmd := String(words[0])
	var args := words.slice(1)
	if active_category=="combat" and cmd in ["heal","cooldown","god","clear","room","spawn","win","lose"] \
		and game.session.state != "battle":
		return "需要战斗；先进入副本"
	if active_category=="dungeon" and cmd in ["clear","room"] and game.session.state != "battle":
		return "需要战斗；先进入副本"
	if active_category=="gear" and cmd=="gear" and not args.is_empty() \
		and args[0] in ["kit","best","repairall","breakall","reinforceall","unequipall"] and game.session.state != "town":
		return "需要回城"
	if cmd=="quest" and not args.is_empty() and args[0] in ["accept","ready","claim","track","abandon","readyall"] \
		and game.session.state != "town":
		return "需要回城"
	return ""

func reveal_command(command: String) -> bool:
	for entry: Dictionary in CATEGORIES:
		var id := String(entry["id"])
		for action: Array in quick_actions(id):
			if String(action[1]) == command:
				active_category=id
				_refresh_categories()
				_refresh_actions()
				return true
	return false

func submit() -> void:
	var text := command_input.text.strip_edges()
	command_input.clear()
	execute(text)

func execute(text: String) -> Dictionary:
	if not text.is_empty():
		history.append(text)
		if history.size() > 100:history.pop_front()
		history_index = history.size()
		draft = ""
	var response: Dictionary = commands.execute(text)
	append_log("> " + text + "\n" + ("" if response["ok"] else "未执行：") + response["message"])
	refresh_status()
	return response

func append_log(text: String) -> void:
	messages.append(game.skin.chinese(text))
	if messages.size() > 40:messages.pop_front()
	log_view.text = "\n".join(messages)

func input_history(event: InputEvent) -> void:
	if not event is InputEventKey or not event.is_pressed():return
	if event.keycode not in [KEY_UP, KEY_DOWN] or history.is_empty():return
	if history_index == history.size():draft = command_input.text
	history_index = clampi(history_index + (-1 if event.keycode == KEY_UP else 1), 0, history.size())
	command_input.text = draft if history_index == history.size() else history[history_index]
	command_input.caret_column = command_input.text.length()
	command_input.accept_event()
