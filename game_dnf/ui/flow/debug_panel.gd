extends Control
## Native UI pieces, command buttons, bounded log and editable command history.
const Commands = preload("res://debug/loop_commands.gd")
const BUTTONS := [
	["进入副本", "dungeon enter"], ["重开副本", "dungeon restart"], ["下一房", "room next"], ["领主房", "room boss"],
	["清空本房", "clear"], ["刷哥布林", "spawn goblin 1"], ["刷投掷手", "spawn thrower 1"], ["刷领主", "spawn chief 1"],
	["无敌开关", "god"], ["满血满蓝", "heal"], ["清除冷却", "cooldown"], ["碰撞显示", "collision"],
	["药剂 +10", "give potion 10"], ["获得稀有太刀", "give forest_sword 1"], ["金币 +1000", "gold 1000"], ["等级设为60", "level 60"],
	["太刀外观", "weapon katana"], ["短剑外观", "weapon shortsword"], ["巨剑外观", "weapon greatsword"], ["返回城镇", "town"],
	["直接通关", "win"], ["角色战败", "lose"], ["查看状态", "status"], ["命令帮助", "help"],
]
var game
var commands
var panel: Control
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
	status_label = game.skin.label(panel, "", Vector2(20, 67), 11, Color("a7dd74"))
	for i in BUTTONS.size():
		var text: String = BUTTONS[i][1]
		var button: Button = game.skin.button(panel, BUTTONS[i][0], Vector2(20 + (i % 4) * 164, 111 + (i / 4) * 30), func(): execute(text))
		button.size = Vector2(146, 25)
		button.set_meta("gm_command", text)
	game.skin.item_board(panel, Rect2(20, 301, 656, 132))
	log_view = RichTextLabel.new()
	log_view.position = Vector2(29, 308)
	log_view.size = Vector2(638, 117)
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
	hide()

func is_typing() -> bool:return visible and command_input.has_focus()

func refresh_status() -> void:
	if visible:status_label.text = commands.status()

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
