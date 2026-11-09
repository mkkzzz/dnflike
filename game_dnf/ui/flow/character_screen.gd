extends Control
## Original select/create IMG families, native 800x600 composition.
const Actor = preload("res://scripts/native_actor.gd")
var game
var selected_path := ""
var creating := false
var name_input: LineEdit
var message_label: Label
var actors: Array = []
var clock_ms := 0.0
var enter_button: TextureButton
var slot_buttons: Array[Button] = []
var slot_paths: Array[String] = []
var slot_selection_frames: Array[TextureRect] = []
var slot_icons: Array[TextureRect] = []
var slot_name_labels: Array[Label] = []
var chosen_label: Label

func setup(owner_game) -> void:
	game = owner_game
	name = "character_screen"
	size = Vector2(800, 600)
	mouse_filter = Control.MOUSE_FILTER_STOP
	show_roster()

func clear_screen() -> void:
	actors.clear()
	slot_buttons.clear()
	slot_paths.clear()
	slot_selection_frames.clear()
	slot_icons.clear()
	slot_name_labels.clear()
	chosen_label = null
	name_input = null
	for child in get_children():
		if child is Control:child.mouse_filter = Control.MOUSE_FILTER_IGNORE
		remove_child(child)
		child.queue_free()

func center_text(text: String, at: Vector2, width: float, font_size := 12, color := Color("ead49c")) -> Label:
	var label: Label = game.skin.label(self, text, at, font_size, color)
	label.size.x = width
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return label

func show_roster(message := "") -> void:
	var leaving_create := creating and message == ""
	creating = false
	if leaving_create:game.ui_audio.play("window_close")
	clear_screen()
	game.characters.refresh()
	var records: Array = game.characters.entries
	if not records.any(func(entry): return entry["path"] == selected_path):selected_path = "" if records.is_empty() else records[0]["path"]
	game.skin.image(self, game.skin.texture("characters"), Vector2.ZERO)
	game.skin.image(self, game.skin.texture("characters", 1), Vector2(329, 33))
	center_text("艾尔文防线", Vector2(300, 84), 200, 14)
	for i in game.characters.LIMIT:
		var at := Vector2(38 + i * 122, 180)
		var occupied: bool = i < records.size()
		var active: bool = occupied and records[i]["path"] == selected_path
		if not occupied:game.skin.image(self, game.skin.texture("characters", 17), at)
		var selection_frame: TextureRect = game.skin.image(self, game.skin.texture("characters", 3), at) if occupied else null
		if selection_frame != null:
			selection_frame.visible = active
			selection_frame.name = "character_selected_%d" % i
		var hit := Button.new()
		hit.set_meta("ui_sound", "character_select")
		hit.position = at
		hit.size = Vector2(119, 207)
		hit.focus_mode = Control.FOCUS_NONE
		for state in ["normal", "hover", "pressed", "focus"]:hit.add_theme_stylebox_override(state, StyleBoxEmpty.new())
		hit.set_meta("character_index", i)
		add_child(hit)
		slot_buttons.append(hit)
		if occupied:
			var record: Dictionary = records[i]
			slot_paths.append(record["path"])
			slot_selection_frames.append(selection_frame)
			hit.tooltip_text = game.skin.chinese(String(record["name"]))
			var name_label := center_text(record["name"], at + Vector2(0, 17), 119, 12, Color("fff0b8") if active else Color("b9ad94"))
			slot_name_labels.append(name_label)
			center_text("Lv.%d  鬼剑士" % record["level"], at + Vector2(0, 40), 119, 10)
			var icon: TextureRect = game.skin.image(self, game.skin.texture("characters", 11 if active else 12), at + Vector2(0, 155))
			slot_icons.append(icon)
			add_actor(at + Vector2(59, 179))
			hit.pressed.connect(func(): select_path(record["path"]))
			hit.gui_input.connect(func(event):
				if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed and event.double_click:
					selected_path = record["path"]
					enter_selected())
		else:
			slot_paths.append("")
			slot_selection_frames.append(null)
			slot_icons.append(null)
			slot_name_labels.append(null)
			center_text("创建角色", at + Vector2(0, 97), 119, 12, Color("8a806c"))
			hit.pressed.connect(show_create)
	game.skin.image(self, game.skin.texture("characters", 6), Vector2(298, 454))
	var chosen: Dictionary = {}
	for record in records:
		if record["path"] == selected_path:chosen = record
	chosen_label = center_text(chosen.get("name", "尚未创建角色"), Vector2(298, 462), 204, 14)
	var create_button: Button = game.skin.button(self, "创建角色", Vector2(46, 537), show_create)
	create_button.disabled = records.size() >= game.characters.LIMIT
	enter_button = game.skin.sprite_button(self, "characters", [7, 8, 9], Vector2(646, 516), enter_selected, "进入游戏 Enter")
	enter_button.set_meta("ui_sound", "character_select")
	enter_button.texture_disabled = game.skin.texture("characters", 10)
	enter_button.disabled = selected_path.is_empty()
	center_text("进入游戏", Vector2(646, 490), 106, 12)
	message_label = center_text(message if message != "" else game.characters.error, Vector2(160, 530), 470, 12, Color("efc584"))
	if records.is_empty() and message_label.text == "":message_label.text = "创建一位鬼剑士，开始你的冒险"

func select_path(path: String) -> void:
	selected_path = path
	for i in slot_paths.size():
		var active := slot_paths[i] == path
		if is_instance_valid(slot_selection_frames[i]):
			slot_selection_frames[i].visible = active
		if is_instance_valid(slot_icons[i]):
			slot_icons[i].texture = game.skin.texture("characters", 11 if active else 12)
		if is_instance_valid(slot_name_labels[i]):
			slot_name_labels[i].add_theme_color_override("font_color", Color("fff0b8") if active else Color("b9ad94"))
	if is_instance_valid(chosen_label):
		for entry: Dictionary in game.characters.entries:
			if entry["path"] == path:
				chosen_label.text = entry["name"]
				break
	if is_instance_valid(enter_button):
		enter_button.disabled = selected_path.is_empty()

func show_create() -> void:
	if game.characters.entries.size() >= game.characters.LIMIT:
		if is_instance_valid(message_label):
			message_label.text = "角色位置已满"
		game.ui_audio.play("error")
		return
	creating = true
	game.ui_audio.play("window_open")
	clear_screen()
	game.skin.image(self, game.skin.texture("character_create"), Vector2.ZERO)
	game.skin.image(self, game.skin.texture("character_create", 38), Vector2.ZERO)
	center_text("创建角色", Vector2(430, 76), 320, 26, Color("f0d18a"))
	game.skin.panel(self, Rect2(430, 163, 320, 306))
	game.skin.image(self, game.skin.texture("character_create", 6), Vector2(454, 184))
	game.skin.label(self, "鬼剑士", Vector2(547, 189), 22, Color("f0d18a"))
	game.skin.label(self, "以鬼手驾驭力量的剑士", Vector2(547, 226), 11)
	game.skin.label(self, "角色名字", Vector2(454, 284), 14)
	game.skin.item_board(self, Rect2(453, 312, 274, 36))
	name_input = LineEdit.new()
	name_input.name = "character_name"
	name_input.position = Vector2(464, 318)
	name_input.size = Vector2(252, 25)
	name_input.max_length = 12
	name_input.placeholder_text = "输入角色名"
	name_input.add_theme_font_override("font", game.skin.font)
	name_input.add_theme_font_size_override("font_size", 14)
	for state in ["normal", "focus"]:name_input.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	add_child(name_input)
	game.skin.label(self, "2—12 个中文、字母或数字", Vector2(455, 357), 11, Color("b5a784"))
	message_label = center_text("", Vector2(443, 386), 294, 12, Color("ef9b83"))
	game.skin.button(self, "创建角色", Vector2(469, 428), create_character)
	game.skin.button(self, "返回", Vector2(613, 428), show_roster)
	name_input.text_submitted.connect(func(_text):
		get_viewport().set_input_as_handled()
		call_deferred("create_character"))
	name_input.text_changed.connect(func(_text): message_label.text = "")
	name_input.grab_focus()

func create_character() -> void:
	if not creating or not is_instance_valid(name_input):return
	var response: Dictionary = game.characters.create(name_input.text)
	if not response["ok"]:
		message_label.text = response["message"]
		game.ui_audio.play("error")
		return
	selected_path = response["path"]
	game.ui_audio.play("character_create")
	show_roster("角色创建成功")

func enter_selected() -> void:
	if selected_path == "":return
	if not game.enter_character(selected_path):message_label.text = "角色读取失败，原存档已保留"

func add_actor(at: Vector2) -> void:
	var actor = Actor.new()
	add_child(actor)
	actor.position = at
	actor.setup(game.town.actor.bank, game.town.actor.clips)
	actors.append(actor)

func _process(delta: float) -> void:
	clock_ms += delta * 1000
	for actor in actors:actor.present("stay", clock_ms, 1, 0, 0)

func handle_key(key: int) -> void:
	if creating:
		if key == KEY_ESCAPE:show_roster()
		elif key in [KEY_ENTER, KEY_KP_ENTER]:create_character()
		return
	if key in [KEY_ENTER, KEY_KP_ENTER]:enter_selected()
	elif key == KEY_LEFT or key == KEY_RIGHT:
		var records: Array = game.characters.entries
		if records.is_empty():return
		var index := 0
		for i in records.size():
			if records[i]["path"] == selected_path:index = i
		select_path(records[posmod(index + (-1 if key == KEY_LEFT else 1), records.size())]["path"])
