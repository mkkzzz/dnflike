class_name GmPanel
extends CanvasLayer
## GM 测试面板：按 P 开关。上方为 N 行 × M 列功能按钮（新增功能 = 往 BUTTONS 加一行），
## 下方为文本输入框 + 执行按钮，按「命令名称 参数1 参数2…」执行。
## 面板只负责 UI 与命令解析，具体命令由 Main 处理并在 log 里回显。

signal command_requested(command: String, args: PackedStringArray)

const COLUMNS := 4
const MAX_LOG_LINES := 3

## 功能按钮清单：label 显示名，cmd 实际执行的命令文本
const BUTTONS := [
	{"label": "选择模式", "cmd": "mode demo"},
	{"label": "进入副本", "cmd": "dungeon 10001"},
	{"label": "重开副本", "cmd": "dungeon restart"},
	{"label": "下一房", "cmd": "room next"},
	{"label": "跳到入口房", "cmd": "room 1"},
	{"label": "跳到 BOSS 房", "cmd": "room 5"},
	{"label": "清空本房", "cmd": "clear"},
	{"label": "刷普通怪", "cmd": "spawn goblin 1"},
	{"label": "刷精英", "cmd": "spawn elite 1"},
	{"label": "刷头目", "cmd": "spawn chief 1"},
	{"label": "无敌开关", "cmd": "god"},
	{"label": "满血满蓝", "cmd": "heal"},
	{"label": "切换职业", "cmd": "job next"},
	{"label": "直接胜利", "cmd": "win"},
	{"label": "直接失败", "cmd": "lose"},
	{"label": "显示设置", "cmd": "settings"},
	{"label": "实体根部几何", "cmd": "geometry"},
	{"label": "新版跑动与三连", "cmd": "art v7"},
	{"label": "回退 c6 动作", "cmd": "art v7c6"},
	{"label": "新第一刀试用", "cmd": "art v7c8"},
	{"label": "旧版基础动作", "cmd": "art v6"},
	{"label": "装备太刀", "cmd": "weapon katana"},
	{"label": "装备巨剑", "cmd": "weapon greatsword"},
	{"label": "装备短剑", "cmd": "weapon shortsword"},
]

var font: Font
var _root: PanelContainer
var _grid: GridContainer
var _input: LineEdit
var _log: Label
var _history: Array[String] = []
var _history_cursor := -1
var _typing := false


func build(ui_font: Font, view: Vector2) -> void:
	font = ui_font
	layer = 40
	process_mode = Node.PROCESS_MODE_ALWAYS

	_root = PanelContainer.new()
	_root.position = Vector2(16, 16)
	_root.custom_minimum_size = Vector2(760, 0)
	_root.add_theme_stylebox_override("panel", _style())
	add_child(_root)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	_root.add_child(column)

	column.add_child(_label("GM 测试面板    P 打开/切换    输入中用 Esc 关闭", 16, Color(1.0, 0.86, 0.55)))

	_grid = GridContainer.new()
	_grid.columns = COLUMNS
	_grid.add_theme_constant_override("h_separation", 8)
	_grid.add_theme_constant_override("v_separation", 8)
	column.add_child(_grid)
	for entry in BUTTONS:
		var button := Button.new()
		button.text = str(entry["label"])
		button.custom_minimum_size = Vector2(178, 34)
		button.add_theme_font_override("font", font)
		button.add_theme_font_size_override("font_size", 14)
		button.add_theme_stylebox_override("normal", _style(Color(0.09, 0.10, 0.13), Color(0.40, 0.34, 0.26), 4, 1))
		button.add_theme_stylebox_override("hover", _style(Color(0.15, 0.16, 0.20), Color(0.85, 0.66, 0.39), 4, 1))
		button.pressed.connect(_on_button.bind(str(entry["cmd"])))
		_grid.add_child(button)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	column.add_child(row)
	_input = LineEdit.new()
	_input.placeholder_text = "输入命令，例如： spawn chief 2   /   room 3   /   help"
	_input.custom_minimum_size = Vector2(600, 36)
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.add_theme_font_override("font", font)
	_input.add_theme_font_size_override("font_size", 15)
	_input.text_submitted.connect(_on_submit_text)
	_input.gui_input.connect(_on_input_gui)
	_input.focus_entered.connect(_on_input_focus.bind(true))
	_input.focus_exited.connect(_on_input_focus.bind(false))
	row.add_child(_input)
	var run := Button.new()
	run.text = "执行"
	run.custom_minimum_size = Vector2(96, 36)
	run.add_theme_font_override("font", font)
	run.add_theme_font_size_override("font_size", 15)
	run.add_theme_stylebox_override("normal", _style(Color(0.27, 0.09, 0.105), Color(0.48, 0.36, 0.25), 6, 1))
	run.add_theme_stylebox_override("hover", _style(Color(0.36, 0.13, 0.15), Color(0.85, 0.66, 0.39), 6, 1))
	run.pressed.connect(_on_execute)
	row.add_child(run)

	_log = _label("就绪。命令格式：命令名称 参数1 参数2…（help 查看全部命令）", 13, Color(0.72, 0.76, 0.80))
	_log.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_log.custom_minimum_size = Vector2(736, 0)
	column.add_child(_log)

	# CanvasLayer must stay visible; open/close only change the panel.
	close()


func is_open() -> bool:
	return _root != null and _root.visible


func _on_input_focus(focused: bool) -> void:
	_typing = focused


## 输入框拿到焦点时，方向键会同时被角色轮询到；Main 据此临时关掉角色操作。
## 只在“打字”期间生效：点按钮、看效果时角色照常可控。
func is_typing() -> bool:
	return is_open() and _typing


func toggle() -> void:
	if is_open():
		close()
	else:
		open()


func open() -> void:
	_root.show()
	set_log("面板已打开。P 关闭；点击输入框可直接输入命令。")


func close() -> void:
	if _input != null:
		_input.release_focus()
	_root.hide()


func set_log(text: String) -> void:
	if _log == null:
		return
	var lines: Array[String] = []
	for line in text.split("\n", false):
		lines.append(line)
	if lines.size() > MAX_LOG_LINES:
		lines = lines.slice(lines.size() - MAX_LOG_LINES)
	_log.text = "\n".join(lines)


func _on_button(command_text: String) -> void:
	_dispatch(command_text)


func _on_execute() -> void:
	var text := _input.text.strip_edges()
	if text.is_empty():
		set_log("命令为空。")
		return
	_input.clear()
	_dispatch(text)


func _on_submit_text(text: String) -> void:
	if text.strip_edges().is_empty():
		return
	_input.clear()
	_dispatch(text.strip_edges())


## 上下键翻阅历史，Esc 让出焦点（面板仍开着）
func _on_input_gui(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	var key_event := event as InputEventKey
	if key_event.keycode == KEY_UP and not _history.is_empty():
		_history_cursor = maxi(0, _history_cursor - 1) if _history_cursor > 0 else _history.size() - 1
		_input.text = _history[_history_cursor]
		_input.caret_column = _input.text.length()
		_input.accept_event()
	elif key_event.keycode == KEY_DOWN and not _history.is_empty():
		_history_cursor = mini(_history.size() - 1, _history_cursor + 1)
		_input.text = _history[_history_cursor]
		_input.caret_column = _input.text.length()
		_input.accept_event()
	elif key_event.keycode == KEY_ESCAPE:
		_input.release_focus()
		_input.accept_event()


func _dispatch(text: String) -> void:
	var tokens := _tokenize(text)
	if tokens.is_empty():
		return
	_history.append(text)
	_history_cursor = _history.size()
	var command := tokens[0]
	var args := PackedStringArray()
	if tokens.size() > 1:
		args = PackedStringArray(tokens.slice(1))
	command_requested.emit(command, args)


## 空白分词，支持双引号包裹带空格的参数
func _tokenize(text: String) -> Array[String]:
	var tokens: Array[String] = []
	var current := ""
	var in_quotes := false
	for index in text.length():
		var ch := text[index]
		if ch == "\"":
			in_quotes = not in_quotes
			continue
		if (ch == " " or ch == "\t") and not in_quotes:
			if not current.is_empty():
				tokens.append(current)
				current = ""
			continue
		current += ch
	if not current.is_empty():
		tokens.append(current)
	return tokens


func _label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	if font != null:
		label.add_theme_font_override("font", font)
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	return label


func _style(background := Color(0.038, 0.043, 0.06, 0.94), border := Color(0.44, 0.35, 0.23), padding := 12, border_width := 1) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(border_width)
	style.set_corner_radius_all(6)
	style.content_margin_left = padding
	style.content_margin_right = padding
	style.content_margin_top = padding
	style.content_margin_bottom = padding
	return style
