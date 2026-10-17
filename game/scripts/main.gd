extends Node2D
## 默认入口：副本 10001（入口房 → 清怪开门 → BOSS 房 → 结算）；
## 旧的职业选择三波遭遇战保留为可测模式（GM 面板 "选择模式" 或 _show_ready）。
## ROOM_CLEAR 追加在末尾，避免改动既有枚举值。
enum BattleState { READY, FIGHT, WAVE_BREAK, VICTORY, DEFEAT, PAUSED, ROOM_CLEAR }
const VIEW_W := 1280.0
const VIEW_H := 720.0
const GROUND_Y := 576.0
const JOB_NAMES := ["鬼剑士", "狂战士", "剑魂"]
const JOB_DESCRIPTIONS := ["三段剑击与上挑，掌握距离和浮空追击。", "血怒强化攻速，怒斩以霸体压制敌人。", "蓄力拔刀与三连突刺，快速衔接连击。"]
const SLOT_INDEX := {"A": 0, "S": 1, "1": 6, "2": 7}
const FPS_PRESETS := [30, 60, 90, 120, 144, 165, 240, 0]
const DISPLAY_CONFIG := "user://display.cfg"

var bm: BattleFX
var player: Player
var weapon_rig: WeaponRig
var seq_fx: SeqFX
var seq_config: Dictionary = {}
var monsters: Array = []
var camera: Camera2D
var hud: Hud
var font: Font
var bg_tex: Texture2D
var demo_config: Dictionary = {}
var battle_state := BattleState.READY
var resume_state := BattleState.FIGHT
var selected_job := 2
var wave_index := 0
var transition_left := 0.0
var elapsed := 0.0
var kills := 0
var hit_count := 0
var damage_taken := 0.0
var best_chain := 0
var last_hit_time := -10.0
var hit_chain := 0
var _clock := 0.0
var _last_hp := 0.0
var _overlay: CanvasLayer
var _shade: ColorRect
var _card: PanelContainer
var _content: VBoxContainer
var _job_buttons: Array[Button] = []
var _description: Label
var _wave_notice: Label
var _hint: Label
var training_mode := false
var training_free_skills := true
var training_damage := 0.0
var training_chain_damage := 0.0
var damage_samples: Array = []
var fps_limit := 60
var vsync_enabled := true
var _automated_run := false
var _settings_card: PanelContainer
var _fps_choice: OptionButton
var _vsync_choice: CheckButton
var _fps_readout: Label
var _settings_resume_fight := false
var _pause_jump_held := false

# --- 副本 10001（布局 10001-A）---
const DUNGEON_CONFIG := "res://data/dungeons.json"
const DOOR_INSET := 30.0
var dungeon_config: Dictionary = {}
var dungeon: DungeonRun
var dungeon_mode := false
var dungeon_finished := false
var room_cleared := false
var room_root: Node2D
var room_bg_tex: Texture2D
var room_bg_sprite: Sprite2D
var room_bg_rect := Rect2()
var room_world_width := VIEW_W
var room_road_left := 0.0
var room_road_right := VIEW_W
var room_depth_min := -40.0
var room_depth_max := 24.0
const ROAD_INSET := 44.0
## 路面地平线的目标屏幕高度（画面比例）
const ROAD_LINE_RATIO := 0.45
## 景深带相对路面的上下留边：上边留一点避免贴住地平线，下边留出底部 HUD 的高度
const DEPTH_TOP_INSET := 16.0
const DEPTH_BOTTOM_INSET := 100.0
## 实体只在“玩家与它同一条景深”时才挡人（本引擎碰撞只有一个平面，见 DungeonEntity 注释）
const LANE_GATE_TOLERANCE := 36.0
var current_door: DungeonDoor
var gm_panel: GmPanel
var _settlement: PanelContainer
var _settlement_title: Label
var _settlement_stats: Label
var _toast: Label
var _toast_left := 0.0
var _ground_shape: CollisionShape2D
var _last_result: Dictionary = {}
var _control_suppressed_by_gm := false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	GameConfig.load_all()
	demo_config = GameConfig._load_json("res://data/demo.json")
	_automated_run = "--test" in OS.get_cmdline_user_args() or "--capture" in OS.get_cmdline_user_args() or "--showcase" in OS.get_cmdline_user_args()
	_load_display_settings()
	_register_actions()
	var system_font := SystemFont.new()
	system_font.font_names = PackedStringArray(["Microsoft YaHei", "Noto Sans CJK SC", "sans-serif"])
	font = system_font
	if ResourceLoader.exists("res://assets/demo/bg_dungeon.png"):
		bg_tex = load("res://assets/demo/bg_dungeon.png")
	dungeon_config = GameConfig._load_json(DUNGEON_CONFIG)
	_build_world()
	_build_hud()
	_build_overlay()
	_build_gm_panel()
	_enter_dungeon("10001")
	print("[DEMO] scene ready")

func _register_actions() -> void:
	var actions := {
		"move_left": [KEY_LEFT], "move_right": [KEY_RIGHT], "move_up": [KEY_UP], "move_down": [KEY_DOWN],
		"jump": [KEY_C, KEY_SPACE], "attack": [KEY_X], "generic_skill": [KEY_Z], "guard": [KEY_V],
		"skill_a": [KEY_A], "skill_s": [KEY_S], "skill_d": [KEY_D], "skill_f": [KEY_F],
		"debug_job": [KEY_T], "debug_reset": [KEY_R], "potion_hp": [KEY_1], "potion_mp": [KEY_2],
		"pause_demo": [KEY_ESCAPE], "start_demo": [KEY_ENTER], "toggle_help": [KEY_F1],
		"reset_training": [KEY_TAB], "toggle_training_supply": [KEY_F2],
		"display_settings": [KEY_F3],
		"gm_panel": [KEY_P],
	}
	if InputMap.has_action("dash"):
		InputMap.erase_action("dash")
	for action in actions:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		for key in actions[action]:
			var event := InputEventKey.new()
			event.physical_keycode = key
			InputMap.action_add_event(action, event)

func _build_world() -> void:
	var ground := StaticBody2D.new()
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(VIEW_W + 256, 100)
	shape.shape = rect
	shape.position = Vector2(VIEW_W / 2, GROUND_Y + 50)
	ground.add_child(shape)
	add_child(ground)
	_ground_shape = shape
	# 房间背景必须是独立节点并压在很低的 z_index：Main 自己的 _draw 会盖住
	# z_index 为负的子节点，实体/门都用负 z 表示“站在角色后面”。
	room_bg_sprite = Sprite2D.new()
	room_bg_sprite.name = "RoomBackground"
	room_bg_sprite.centered = false
	room_bg_sprite.z_index = -1000
	room_bg_sprite.visible = false
	add_child(room_bg_sprite)
	bm = BattleFX.new()
	bm.name = "BattleFX"
	bm.process_mode = Node.PROCESS_MODE_PAUSABLE
	bm.number_font = font
	bm.z_index = 200
	add_child(bm)
	camera = Camera2D.new()
	camera.process_callback = Camera2D.CAMERA2D_PROCESS_PHYSICS
	camera.position = Vector2(VIEW_W / 2, VIEW_H / 2)
	add_child(camera)
	bm.camera = camera
	player = Player.new()
	player.name = "Player"
	player.process_mode = Node.PROCESS_MODE_PAUSABLE
	player.position = Vector2(240, GROUND_Y)
	player.ground_y = GROUND_Y
	add_child(player)
	player.setup(GameConfig.player, bm, monsters)
	weapon_rig = WeaponRig.new()
	weapon_rig.name = "WeaponRig"
	weapon_rig.process_mode = Node.PROCESS_MODE_PAUSABLE
	player.add_child(weapon_rig)
	weapon_rig.setup(player, bm)
	player.weapon_attachment = weapon_rig
	# V6 序列帧表现层：三段普攻与拔刀斩的刀光/受击/地裂/一闪
	seq_config = GameConfig._load_json("res://data/seq_v6.json")
	seq_fx = SeqFX.new()
	seq_fx.name = "SeqFX"
	seq_fx.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(seq_fx)
	seq_fx.setup(player, bm, seq_config)
	player.seq_fx = seq_fx
	player.seq_hitstop.connect(_on_seq_hitstop)
	player.died.connect(_on_player_died)
	player.hp_changed.connect(_on_hp_changed)
	player.landed_hit.connect(_on_landed_hit)
	player.set_job(selected_job)
	player.control_enabled = false

func _build_hud() -> void:
	hud = Hud.new()
	add_child(hud)
	hud.set_font(font)
	player.action_feedback.connect(hud.set_feedback)
	hud.set_player_info("幽影剑士", 30, selected_job)
	hud.clear_room()
	hud.visible = false

func _build_overlay() -> void:
	_overlay = CanvasLayer.new()
	_overlay.layer = 30
	add_child(_overlay)
	_shade = ColorRect.new()
	_shade.color = Color(0.015, 0.019, 0.028, 0.72)
	_shade.size = Vector2(VIEW_W, VIEW_H)
	_overlay.add_child(_shade)
	_card = PanelContainer.new()
	_card.position = Vector2(310, 116)
	_card.size = Vector2(660, 510)
	_card.add_theme_stylebox_override("panel", _style(Color(0.038, 0.043, 0.06, 0.97), Color(0.42, 0.33, 0.22), 28))
	_overlay.add_child(_card)
	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", 15)
	_card.add_child(_content)
	_wave_notice = _label("", 30, Color(1.0, 0.88, 0.65))
	_wave_notice.position = Vector2(340, 200)
	_wave_notice.size = Vector2(600, 100)
	_wave_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_wave_notice.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wave_notice.add_theme_constant_override("outline_size", 8)
	_wave_notice.add_theme_color_override("font_outline_color", Color(0.01, 0.01, 0.015, 0.9))
	_overlay.add_child(_wave_notice)
	_hint = _label("", 14, Color(0.8, 0.81, 0.84))
	_hint.position = Vector2(260, 104)
	_hint.size = Vector2(760, 62)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.visible = false
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(_hint)
	_build_toast()
	_build_settlement()
	_build_display_settings()

func _load_display_settings() -> void:
	if not _automated_run:
		var saved := ConfigFile.new()
		if saved.load(DISPLAY_CONFIG) == OK:
			var requested := int(saved.get_value("display", "fps_limit", 60))
			fps_limit = requested if requested in FPS_PRESETS else 60
			vsync_enabled = bool(saved.get_value("display", "vsync", true))
	_apply_display_settings(false)

func _apply_display_settings(persist := true) -> void:
	# Automated captures use --fixed-fps and never alter the player's saved choice.
	if not _automated_run:
		Engine.max_fps = fps_limit
		if DisplayServer.get_name() != "headless":
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if vsync_enabled else DisplayServer.VSYNC_DISABLED)
	if persist and not _automated_run:
		var saved := ConfigFile.new()
		saved.set_value("display", "fps_limit", fps_limit)
		saved.set_value("display", "vsync", vsync_enabled)
		if saved.save(DISPLAY_CONFIG) != OK:
			hud.set_feedback("本次显示设置已生效，保存失败。")

func _set_fps_choice(index: int) -> void:
	if index < 0 or index >= FPS_PRESETS.size():
		return
	fps_limit = int(FPS_PRESETS[index])
	_apply_display_settings()

func _set_vsync_choice(enabled: bool) -> void:
	vsync_enabled = enabled
	_apply_display_settings()

func _build_display_settings() -> void:
	var settings_button := _button("显示设置 · F3", _toggle_display_settings)
	settings_button.position = Vector2(1084, 92)
	settings_button.size = Vector2(171, 34)
	settings_button.custom_minimum_size = Vector2(171, 34)
	settings_button.add_theme_font_size_override("font_size", 14)
	_overlay.add_child(settings_button)
	_fps_readout = _label("", 12, Color(0.7, 0.73, 0.77))
	_fps_readout.position = Vector2(1084, 70)
	_fps_readout.size = Vector2(171, 20)
	_fps_readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_fps_readout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(_fps_readout)
	_settings_card = PanelContainer.new()
	_settings_card.position = Vector2(380, 150)
	_settings_card.size = Vector2(520, 420)
	_settings_card.add_theme_stylebox_override("panel", _style(Color(0.038, 0.043, 0.06, 0.99), Color(0.42, 0.33, 0.22), 28))
	_overlay.add_child(_settings_card)
	var settings_content := VBoxContainer.new()
	settings_content.add_theme_constant_override("separation", 18)
	_settings_card.add_child(settings_content)
	settings_content.add_child(_label("显示设置", 32))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)
	row.add_child(_label("帧率上限", 18))
	_fps_choice = OptionButton.new()
	_fps_choice.custom_minimum_size = Vector2(255, 42)
	_fps_choice.add_theme_font_override("font", font)
	_fps_choice.add_theme_font_size_override("font_size", 18)
	for preset in FPS_PRESETS:
		_fps_choice.add_item("不限" if preset == 0 else "%d FPS" % preset)
	_fps_choice.select(FPS_PRESETS.find(fps_limit))
	_fps_choice.item_selected.connect(_set_fps_choice)
	row.add_child(_fps_choice)
	settings_content.add_child(row)
	_vsync_choice = CheckButton.new()
	_vsync_choice.text = "垂直同步"
	_vsync_choice.add_theme_font_override("font", font)
	_vsync_choice.add_theme_font_size_override("font_size", 18)
	_vsync_choice.button_pressed = vsync_enabled
	_vsync_choice.toggled.connect(_set_vsync_choice)
	settings_content.add_child(_vsync_choice)
	settings_content.add_child(_label("垂直同步可减少画面撕裂，也可能受显示器刷新率限制。\n若希望超过显示器刷新率，请关闭垂直同步。", 14, Color(0.65, 0.69, 0.74)))
	settings_content.add_child(_label("帧率上限只影响画面流畅度。\n攻速属性、技能冷却和跳跃节奏保持不变。", 15))
	settings_content.add_child(_button("完成    Esc / F3", _toggle_display_settings, true))
	_settings_card.hide()

func _toggle_display_settings() -> void:
	if _settings_card.visible:
		_settings_card.hide()
		if _settings_resume_fight:
			_toggle_pause()
		else:
			_card.show()
		_settings_resume_fight = false
		return
	_settings_resume_fight = battle_state in [BattleState.FIGHT, BattleState.WAVE_BREAK]
	if _settings_resume_fight:
		_toggle_pause()
	_shade.show()
	_card.hide()
	_settings_card.show()
	_fps_choice.select(FPS_PRESETS.find(fps_limit))
	_vsync_choice.set_pressed_no_signal(vsync_enabled)
	_fps_choice.grab_focus()

func _style(background: Color, border: Color, padding := 10) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(5)
	style.content_margin_left = padding
	style.content_margin_right = padding
	style.content_margin_top = padding
	style.content_margin_bottom = padding
	return style

func _label(text: String, size: int, color := Color(0.89, 0.87, 0.82)) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_override("font", font)
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	return label

func _button(text: String, callback: Callable, primary := false) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0, 46)
	button.add_theme_font_override("font", font)
	button.add_theme_font_size_override("font_size", 18)
	var tint := Color(0.27, 0.09, 0.105) if primary else Color(0.08, 0.085, 0.105)
	button.add_theme_stylebox_override("normal", _style(tint, Color(0.48, 0.36, 0.25)))
	button.add_theme_stylebox_override("hover", _style(tint.lightened(0.16), Color(0.85, 0.66, 0.39)))
	button.add_theme_stylebox_override("pressed", _style(tint.lightened(0.08), Color(0.95, 0.72, 0.44)))
	button.add_theme_stylebox_override("focus", _style(Color(0, 0, 0, 0), Color(0.95, 0.72, 0.44)))
	button.pressed.connect(callback)
	return button

func _clear_card() -> void:
	for child in _content.get_children():
		_content.remove_child(child)
		child.queue_free()
	_job_buttons.clear()
	_shade.show()
	_card.show()
	_wave_notice.hide()
	_hint.hide()

func _show_ready() -> void:
	get_tree().paused = false
	if dungeon_mode:
		dungeon_mode = false
		dungeon_finished = false
		room_bg_tex = null
		if room_bg_sprite != null:
			room_bg_sprite.visible = false
		room_world_width = VIEW_W
		_clear_room_nodes()
		_clear_monsters()
		bm.clear_fx()
		seq_fx.reset()
		if _ground_shape != null:
			(_ground_shape.shape as RectangleShape2D).size.x = VIEW_W + 256
			_ground_shape.position.x = VIEW_W * 0.5
		player.set_arena(64.0, 1216.0)
		player.clear_lane_limits()
		_update_camera()
	_clear_settlement()
	hud.clear_dungeon_room()
	battle_state = BattleState.READY
	_set_actor_control(false)
	hud.visible = false
	_clear_card()
	_content.add_child(_label("SHADOW HALL  /  COMBAT DEMO", 13, Color(0.67, 0.55, 0.37)))
	_content.add_child(_label("幽暗回廊", 42))
	_content.add_child(_label("选择战斗风格，练习连段或突破三波围攻。", 17, Color(0.66, 0.69, 0.73)))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_content.add_child(row)
	for index in 3:
		var button := _button(JOB_NAMES[index], _select_job.bind(index))
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(button)
		_job_buttons.append(button)
	_description = _label("", 16)
	_content.add_child(_description)
	_select_job(selected_job)
	_content.add_child(_label("方向键移动 · 双击方向奔跑 · 跑动 X 冲斩 · 空中 X 空斩\nC 长短跳 · Z 上挑 · V 格挡 · ↓+C 后跳 · A/S 技能", 15, Color(0.6, 0.63, 0.68)))
	_content.add_child(_button("连段训练    无限补给 / 实时 DPS", _start_training.bind(-1), true))
	_content.add_child(_button("进入回廊    ↵", _start_demo.bind(-1), true))

func _select_job(index: int) -> void:
	selected_job = clampi(index, 0, 2)
	player.set_job(selected_job)
	if _description:
		_description.text = JOB_DESCRIPTIONS[selected_job]
	for i in _job_buttons.size():
		_job_buttons[i].modulate = Color.WHITE if i == selected_job else Color(0.6, 0.64, 0.7)

func _start_demo(job_id := -1) -> void:
	get_tree().paused = false
	_pause_jump_held = false
	training_mode = false
	damage_samples.clear()
	training_damage = 0.0
	training_chain_damage = 0.0
	if job_id >= 0:
		selected_job = clampi(job_id, 0, 2)
	# 退出副本模式，恢复旧的单屏三波场景
	dungeon_mode = false
	dungeon_finished = false
	room_bg_tex = null
	if room_bg_sprite != null:
		room_bg_sprite.visible = false
	room_world_width = VIEW_W
	_clear_room_nodes()
	_clear_settlement()
	hud.clear_room()
	hud.clear_dungeon_room()
	player.set_arena(64.0, 1216.0)
	player.clear_lane_limits()
	if _ground_shape != null:
		(_ground_shape.shape as RectangleShape2D).size.x = VIEW_W + 256
		_ground_shape.position.x = VIEW_W * 0.5
	_update_camera()
	_clear_monsters()
	bm.clear_fx()
	seq_fx.reset()
	player.reset_combat(Vector2(float(demo_config.get("player_x", 220)), GROUND_Y))
	player.set_job(selected_job)
	wave_index = 0
	weapon_rig.reset_pose()
	elapsed = 0.0
	kills = 0
	hit_count = 0
	damage_taken = 0.0
	best_chain = 0
	hit_chain = 0
	last_hit_time = -10.0
	_last_hp = player.hp
	_shade.hide()
	_card.hide()
	_hint.hide()
	hud.visible = true
	hud.set_combo(0)
	hud.set_feedback("")
	hud.set_player_info("幽影剑士", 30, selected_job)
	_spawn_wave()
	print("[DEMO] started job=%d" % selected_job)

func _start_training(job_id := -1) -> void:
	_start_demo(job_id)
	training_mode = true
	training_free_skills = true
	_clear_monsters()
	seq_fx.reset()
	player.reset_combat(Vector2(430, GROUND_Y))
	player.set_job(selected_job)
	weapon_rig.reset_pose()
	for index in 2:
		var target := Monster.new()
		target.name = "TrainingTarget"
		target.process_mode = Node.PROCESS_MODE_PAUSABLE
		target.position = Vector2(680 + index * 350, GROUND_Y)
		target.depth_y = 0 if index == 0 else -18
		target.ground_y = GROUND_Y
		add_child(target)
		var cfg: Dictionary = GameConfig.monsters["goblin"].duplicate(true)
		cfg["name"] = "训练替身" if index == 0 else "范围训练替身"
		cfg["hp"] = 4000
		cfg["max_hit_chain"] = 999
		target.setup(cfg, player, bm)
		target.damaged.connect(_on_damage_dealt)
		target.training_mode = true
		target.training_origin = target.position
		target.training_depth = target.depth_y
		monsters.append(target)
	battle_state = BattleState.FIGHT
	_set_actor_control(true)
	_wave_notice.text = "连段训练\nTab 重置  ·  F2 切换补给\n上挑与后跳始终保留冷却"
	_wave_notice.show()
	transition_left = 2.2
	print("[DEMO] training started")

func _clear_monsters() -> void:
	for monster in monsters:
		if is_instance_valid(monster):
			monster.control_enabled = false
			monster.queue_free()
	monsters.clear()

func _spawn_wave() -> void:
	_clear_monsters()
	var wave: Dictionary = demo_config["waves"][wave_index]
	for spawn in wave["spawns"]:
		var cfg: Dictionary = GameConfig.monsters["goblin"].duplicate(true)
		for key in spawn.get("overrides", {}):
			cfg[key] = spawn["overrides"][key]
		var monster := Monster.new()
		monster.name = "Goblin"
		monster.process_mode = Node.PROCESS_MODE_PAUSABLE
		monster.position = Vector2(float(spawn["x"]), GROUND_Y)
		monster.ground_y = GROUND_Y
		monster.depth_y = float(spawn.get("depth", 0))
		add_child(monster)
		monster.setup(cfg, player, bm)
		monster.died.connect(_on_monster_died)
		monster.damaged.connect(_on_damage_dealt)
		monsters.append(monster)
	battle_state = BattleState.FIGHT
	_set_actor_control(true)
	_wave_notice.text = "第 %d / %d 波\n%s" % [wave_index + 1, demo_config["waves"].size(), wave["name"]]
	_wave_notice.show()
	transition_left = 1.8
	bm.play_sound("wave")
	print("[DEMO] wave=%d enemies=%d" % [wave_index + 1, monsters.size()])

func _on_seq_hitstop(tick: float, frame: int, blade: Vector2, point: Vector2, hitstop: int) -> void:
	if is_instance_valid(seq_fx):
		seq_fx.note_freeze(tick, frame, blade, point, hitstop)


func _set_actor_control(enabled: bool) -> void:
	player.control_enabled = enabled and not player.dead
	for monster in monsters:
		if is_instance_valid(monster):
			monster.control_enabled = enabled and not monster.dead

func alive_count() -> int:
	var count := 0
	for monster in monsters:
		if is_instance_valid(monster) and not monster.dead:
			count += 1
	return count

func _on_monster_died(_monster) -> void:
	kills += 1

func _on_landed_hit(_monster, _damage: float) -> void:
	hit_count += 1
	hit_chain = hit_chain + 1 if elapsed - last_hit_time < 2.2 else 1
	last_hit_time = elapsed
	best_chain = maxi(best_chain, hit_chain)
	hud.set_combo(hit_chain)

func _on_damage_dealt(_monster, amount: float, direct: bool) -> void:
	if direct and elapsed - last_hit_time >= 2.2:
		training_chain_damage = 0.0
	training_damage += amount
	training_chain_damage += amount
	damage_samples.append({"time": elapsed, "damage": amount})

func _on_player_died() -> void:
	if dungeon_mode:
		_finish_dungeon(false)
	else:
		_finish(false)

func _on_hp_changed(health: float, _max_health: float) -> void:
	if battle_state in [BattleState.FIGHT, BattleState.WAVE_BREAK]:
		damage_taken += maxf(0.0, _last_hp - health)
	_last_hp = health

func _finish(victory: bool) -> void:
	battle_state = BattleState.VICTORY if victory else BattleState.DEFEAT
	_set_actor_control(false)
	damage_taken += maxf(0.0, _last_hp - player.hp)
	_last_hp = player.hp
	bm.clear_fx()
	seq_fx.reset()
	bm.play_sound("victory" if victory else "death")
	_clear_card()
	_content.add_child(_label("ENCOUNTER COMPLETE" if victory else "ENCOUNTER FAILED", 13, Color(0.67, 0.55, 0.37)))
	_content.add_child(_label("回廊已肃清" if victory else "挑战失败", 38))
	var rank := "S" if damage_taken < 100 and elapsed < 100 else ("A" if damage_taken < 250 else "B")
	_content.add_child(_label("战斗评价  %s" % rank if victory else "观察挥棒前摇，以格挡或后跳争取反击机会。", 22))
	_content.add_child(_label("用时 %s    击败 %d    最长连击 %d\n有效命中 %d    承受伤害 %.0f" % [_time_text(elapsed), kills, best_chain, hit_count, damage_taken], 18))
	_content.add_child(_button("再次挑战    R / ↵", _reset_battle, true))
	_content.add_child(_button("选择战斗风格", _show_ready))
	print("[DEMO] result=%s kills=%d hits=%d" % ["victory" if victory else "defeat", kills, hit_count])

func _toggle_pause() -> void:
	if battle_state == BattleState.PAUSED:
		battle_state = resume_state
		get_tree().paused = false
		_shade.hide()
		_card.hide()
		if _pause_jump_held and not Input.is_action_pressed("jump") and player.velocity.y < 0:
			player._jump_cut_pending = true
		_pause_jump_held = false
		_set_actor_control(battle_state in [BattleState.FIGHT, BattleState.WAVE_BREAK])
		return
	if battle_state not in [BattleState.FIGHT, BattleState.WAVE_BREAK]:
		return
	resume_state = battle_state
	_pause_jump_held = Input.is_action_pressed("jump")
	battle_state = BattleState.PAUSED
	_set_actor_control(false)
	get_tree().paused = true
	_clear_card()
	_content.add_child(_label("战斗已暂停", 34))
	_content.add_child(_label("Esc 继续 · R 重新挑战 · F1 操作说明", 17))
	_content.add_child(_button("继续战斗    Esc", _toggle_pause, true))
	_content.add_child(_button("重置训练" if training_mode else "重新挑战", _reset_battle))
	_content.add_child(_button("选择战斗风格", _show_ready))

func _reset_battle() -> void:
	if training_mode:
		_start_training(selected_job)
	else:
		_start_demo(selected_job)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("display_settings") or (_settings_card.visible and event.is_action_pressed("pause_demo")):
		_toggle_display_settings()
		get_viewport().set_input_as_handled()
		return
	if _settings_card.visible:
		return
	if gm_panel != null and event.is_action_pressed("gm_panel"):
		gm_panel.toggle()
		get_viewport().set_input_as_handled()
		return
	if gm_panel != null and gm_panel.is_open():
		return
	if event.is_action_pressed("pause_demo"):
		_toggle_pause()
	elif event.is_action_pressed("debug_reset"):
		_reset_battle()
	elif event.is_action_pressed("reset_training") and training_mode:
		_reset_battle()
	elif event.is_action_pressed("toggle_training_supply") and training_mode:
		training_free_skills = not training_free_skills
		hud.set_feedback("职业技能无限补给" if training_free_skills else "实战蓝耗与冷却")
	elif event.is_action_pressed("start_demo"):
		if battle_state in [BattleState.READY, BattleState.VICTORY, BattleState.DEFEAT]:
			_start_demo()
	elif event.is_action_pressed("debug_job") and battle_state == BattleState.FIGHT:
		selected_job = (player.job + 1) % 3
		player.set_job(selected_job)
	elif event.is_action_pressed("toggle_help"):
		_hint.position.y = 20 if battle_state == BattleState.PAUSED else 104
		_hint.text = "←→ 移动，双击奔跑 / ↑↓ 景深 / X 三连、冲斩或空斩\nC 按住高跳、松开短跳 / Z 上挑后 C 追击 / V 正面格挡，起手精准格挡\n↓+C 后跳 / A S 技能 / 1 2 药水 / Tab 重置、F2 补给、F3 帧率设置"
		_hint.visible = not _hint.visible

func _physics_process(delta: float) -> void:
	if battle_state == BattleState.PAUSED:
		return
	# GM 输入框拿到焦点时，方向键会同时带动角色，这里临时收回操作权
	if gm_panel != null and gm_panel.is_typing():
		player.control_enabled = false
		_control_suppressed_by_gm = true
	elif _control_suppressed_by_gm:
		_control_suppressed_by_gm = false
		_set_actor_control(battle_state in [BattleState.FIGHT, BattleState.WAVE_BREAK, BattleState.ROOM_CLEAR] and not player.dead)
	if bm.freeze > 0:
		bm.freeze -= 1
	if battle_state == BattleState.ROOM_CLEAR:
		elapsed += delta
		damage_taken += maxf(0.0, _last_hp - player.hp)
		_last_hp = player.hp
		_clamp_player_to_room()
		_tick_room_notice(delta)
		if not dungeon_finished and current_door != null and current_door.contains_actor(player.position):
			_advance_room()
	elif battle_state == BattleState.FIGHT:
		elapsed += delta
		damage_taken += maxf(0.0, _last_hp - player.hp)
		_last_hp = player.hp
		if dungeon_mode:
			if alive_count() == 0:
				_on_room_cleared()
			_clamp_player_to_room()
			_tick_room_notice(delta)
		elif training_mode:
			if training_free_skills:
				player.mp = float(player.cfg.get("max_mp", 300))
				for identifier in player.cds:
					if GameConfig.skills.has(identifier):
						player.cds[identifier] = 0
			if transition_left > 0:
				transition_left -= delta
				if transition_left <= 0:
					_wave_notice.hide()
		elif alive_count() == 0:
			if wave_index + 1 == demo_config["waves"].size():
				_finish(true)
			else:
				battle_state = BattleState.WAVE_BREAK
				transition_left = float(demo_config.get("wave_delay", 2.0))
				_set_actor_control(true)
				_wave_notice.text = "第 %d 波已清理\n下一波即将进入" % [wave_index + 1]
				_wave_notice.show()
		elif transition_left > 0.0:
			transition_left -= delta
			if transition_left <= 0.0:
				_wave_notice.hide()
	elif battle_state == BattleState.WAVE_BREAK:
		elapsed += delta
		transition_left -= delta
		if transition_left <= 0.0:
			wave_index += 1
			_spawn_wave()

# ============================ 副本 10001 ============================

func _build_gm_panel() -> void:
	gm_panel = GmPanel.new()
	gm_panel.name = "GmPanel"
	add_child(gm_panel)
	gm_panel.build(font, Vector2(VIEW_W, VIEW_H))
	gm_panel.command_requested.connect(_on_gm_command)


func _build_toast() -> void:
	_toast = _label("", 18, Color(1.0, 0.92, 0.72))
	_toast.position = Vector2(0, 636)
	_toast.size = Vector2(VIEW_W, 40)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.add_theme_constant_override("outline_size", 7)
	_toast.add_theme_color_override("font_outline_color", Color(0.02, 0.02, 0.03, 0.92))
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast.hide()
	_overlay.add_child(_toast)


func _build_settlement() -> void:
	_settlement = PanelContainer.new()
	_settlement.position = Vector2(VIEW_W - 404, 168)
	_settlement.custom_minimum_size = Vector2(384, 0)
	_settlement.add_theme_stylebox_override("panel", _style(Color(0.038, 0.043, 0.06, 0.96), Color(0.44, 0.35, 0.23), 18))
	_overlay.add_child(_settlement)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	_settlement.add_child(column)
	_settlement_title = _label("", 26)
	column.add_child(_settlement_title)
	_settlement_stats = _label("", 15, Color(0.78, 0.81, 0.85))
	_settlement_stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_settlement_stats)
	column.add_child(_button("再打一次", _on_retry_dungeon, true))
	column.add_child(_button("离开地下城", _on_leave_dungeon))
	_settlement.hide()


func _show_settlement(victory: bool) -> void:
	if _settlement == null:
		return
	_settlement_title.text = "副本完成" if victory else "挑战失败"
	_settlement_title.add_theme_color_override("font_color",
		Color(1.0, 0.88, 0.55) if victory else Color(0.95, 0.62, 0.58))
	var rank := "S" if damage_taken < 100 and elapsed < 100 else ("A" if damage_taken < 250 else "B")
	var tail := "" if victory else "\n点“再打一次”可重新挑战"
	_settlement_stats.text = "%s · %s\n用时 %s    击败 %d\n最长连击 %d    有效命中 %d\n承受伤害 %.0f\n战斗评价 %s%s" % [
		dungeon.display_name(), dungeon.layout(), _time_text(elapsed), kills,
		best_chain, hit_count, damage_taken, rank if victory else "—", tail]
	_settlement.show()


func _clear_settlement() -> void:
	if _settlement != null:
		_settlement.hide()


func _toast_show(text: String) -> void:
	if _toast == null:
		return
	_toast.text = text
	_toast_left = 2.6
	_toast.show()


func _enter_dungeon(dungeon_id := "10001") -> void:
	get_tree().paused = false
	_pause_jump_held = false
	dungeon = DungeonRun.new()
	if not dungeon.load_from(dungeon_config, dungeon_id):
		hud.set_feedback("副本 %s 没有配置" % dungeon_id)
		_show_ready()
		return
	dungeon_mode = true
	dungeon_finished = false
	training_mode = false
	_clear_settlement()
	_reset_run_stats()
	_load_room()
	print("[DEMO] dungeon=%s layout=%s rooms=%d" % [dungeon.id(), dungeon.layout(), dungeon.room_count()])


func _reset_run_stats() -> void:
	elapsed = 0.0
	kills = 0
	hit_count = 0
	damage_taken = 0.0
	best_chain = 0
	hit_chain = 0
	last_hit_time = -10.0
	damage_samples.clear()
	training_damage = 0.0
	training_chain_damage = 0.0
	hud.set_combo(0)


func _load_room() -> void:
	_clear_monsters()
	_clear_room_nodes()
	bm.clear_fx()
	seq_fx.reset()
	weapon_rig.reset_pose()
	room_cleared = false
	dungeon_finished = false
	_clear_settlement()
	room_bg_tex = null
	var bg_path := dungeon.background_path()
	if ResourceLoader.exists(bg_path):
		room_bg_tex = load(bg_path) as Texture2D
	room_bg_rect = _compute_room_rect(room_bg_tex, dungeon.ground_line_ratio())
	room_world_width = maxf(VIEW_W, room_bg_rect.size.x)
	# 可行走范围贴合画面里的路面（实测比例），而不是整幅图减去固定边距
	room_road_left = room_bg_rect.position.x + dungeon.road_left_ratio() * room_bg_rect.size.x
	room_road_right = room_bg_rect.position.x + dungeon.road_right_ratio() * room_bg_rect.size.x
	if room_road_right - room_road_left < 240.0:
		room_road_left = 0.0
		room_road_right = room_world_width
	# 景深（上下）可动范围＝画面里路面的纵向范围，而不是 player.json 的固定值
	var road_top_y := room_bg_rect.position.y + dungeon.ground_line_ratio() * room_bg_rect.size.y
	var road_bottom_y := minf(VIEW_H, room_bg_rect.position.y + room_bg_rect.size.y)
	room_depth_min = road_top_y + DEPTH_TOP_INSET - GROUND_Y
	room_depth_max = road_bottom_y - DEPTH_BOTTOM_INSET - GROUND_Y
	if room_depth_max - room_depth_min < 64.0:
		room_depth_min = -40.0
		room_depth_max = 24.0
	if room_bg_sprite != null:
		room_bg_sprite.texture = room_bg_tex
		room_bg_sprite.visible = room_bg_tex != null
		if room_bg_tex != null:
			room_bg_sprite.position = room_bg_rect.position
			room_bg_sprite.scale = Vector2.ONE * (room_bg_rect.size.x / float(room_bg_tex.get_size().x))
	if _ground_shape != null:
		(_ground_shape.shape as RectangleShape2D).size.x = room_world_width + 256.0
		_ground_shape.position.x = room_world_width * 0.5
	player.reset_combat(Vector2(200, GROUND_Y))
	player.set_arena(room_road_left + ROAD_INSET, room_road_right - ROAD_INSET)
	player.set_lane_limits(room_depth_min, room_depth_max)
	player.position.x = clampf(player.position.x, player.arena_left, player.arena_right)
	player.set_job(selected_job)
	player.invincible = 0
	player.control_enabled = true
	_last_hp = player.hp
	var props := Node2D.new()
	props.name = "RoomProps"
	add_child(props)
	room_root = props
	var catalog: Dictionary = dungeon_config.get("entity_catalog", {})
	for item in dungeon.entity_plan():
		var entry: Dictionary = catalog.get(item["id"], {})
		if entry.is_empty():
			continue
		var entity := DungeonEntity.new()
		entity.entity_id = item["id"]
		props.add_child(entity)
		entity.setup(entry, dungeon.asset_root(), Vector2(item["x"], GROUND_Y), item["depth_y"])
		entity.enable_lane_gate(player, LANE_GATE_TOLERANCE)
		entity.apply_actor_order(item["depth_y"])
	var plan := dungeon.monster_plan(GameConfig.monsters["goblin"], dungeon_config.get("monster_presets", {}))
	for spawn in plan:
		_spawn_room_monster(spawn)
	var door_plan := dungeon.door_plan()
	if not door_plan.is_empty():
		var door := DungeonDoor.new()
		door.font = font
		props.add_child(door)
		# 门放在路面右端之内，否则玩家走不到（可行动范围已贴合路面）
		door.setup(str(door_plan.get("side", "right")), Vector2(room_road_right - DOOR_INSET, GROUND_Y))
		current_door = door
	hud.visible = true
	hud.set_dungeon_room(dungeon.display_name(), dungeon.room_index, dungeon.room_count(), _role_label(), alive_count())
	hud.set_feedback("")
	print("[DEMO] room=%d module=%s props=%d monsters=%d door=%s" % [dungeon.room_number(),
		dungeon.module_id(), props.get_child_count(), monsters.size(), str(not door_plan.is_empty())])
	_shade.hide()
	_card.hide()
	_hint.hide()
	_update_camera()
	if plan.is_empty():
		_on_room_cleared(true)
	else:
		battle_state = BattleState.FIGHT
		_set_actor_control(true)
	_show_room_notice()


func _show_room_notice() -> void:
	_wave_notice.text = "第 %d / %d 房 · %s\n%s" % [dungeon.room_number(), dungeon.room_count(),
		dungeon.room_name(), dungeon.module_id()]
	_wave_notice.show()
	transition_left = 1.8


## 等比放大到覆盖 1280×720，再把“路面地平线”尽量放到画面 45% 高。
## 横版四房因比例关系本来就被夹到 0；这条主要修正竖幅 R04——原先把地平线
## 对齐到 GROUND_Y，会让它的路面只剩屏幕最下面一条，景深几乎没得走。
func _compute_room_rect(tex: Texture2D, ratio: float) -> Rect2:
	if tex == null:
		return Rect2(0, 0, VIEW_W, VIEW_H)
	var size := tex.get_size()
	var factor := maxf(VIEW_W / size.x, VIEW_H / size.y)
	var draw_size := size * factor
	var target_line := VIEW_H * ROAD_LINE_RATIO
	var offset_y := clampf(target_line - ratio * draw_size.y, VIEW_H - draw_size.y, 0.0)
	return Rect2(0.0, offset_y, draw_size.x, draw_size.y)


func _clear_room_nodes() -> void:
	if current_door != null and is_instance_valid(current_door):
		current_door.queue_free()
	current_door = null
	if room_root != null and is_instance_valid(room_root):
		room_root.queue_free()
	room_root = null


func _spawn_room_monster(spawn: Dictionary) -> Monster:
	var monster := Monster.new()
	monster.name = "DungeonMonster"
	monster.process_mode = Node.PROCESS_MODE_PAUSABLE
	monster.position = Vector2(float(spawn["x"]), GROUND_Y)
	monster.ground_y = GROUND_Y
	monster.depth_y = float(spawn.get("depth", 0.0))
	add_child(monster)
	monster.setup(spawn["cfg"], player, bm)
	monster.died.connect(_on_monster_died)
	monster.damaged.connect(_on_damage_dealt)
	monsters.append(monster)
	return monster


func _on_room_cleared(silent := false) -> void:
	if room_cleared:
		return
	room_cleared = true
	battle_state = BattleState.ROOM_CLEAR
	_set_actor_control(true)
	if current_door != null:
		current_door.set_opened(true)
	if dungeon.is_boss_room():
		_finish_dungeon(true)
		return
	if not silent:
		hud.set_feedback("房间已清空 · 门已开启")
		_wave_notice.text = "房间已清空\n走向右侧的门继续前进"
		_wave_notice.show()
		transition_left = 1.8
		bm.play_sound("ui")


func _tick_room_notice(delta: float) -> void:
	if transition_left > 0.0:
		transition_left -= delta
		if transition_left <= 0.0:
			_wave_notice.hide()


func _clamp_player_to_room() -> void:
	player.position.x = clampf(player.position.x, player.arena_left, player.arena_right)


func _advance_room() -> void:
	if not dungeon.advance():
		return
	_load_room()
	print("[DEMO] room=%d module=%s" % [dungeon.room_number(), dungeon.module_id()])


func _role_label() -> String:
	match dungeon.role():
		"entrance":
			return "入口"
		"elite":
			return "精英"
		"boss":
			return "BOSS"
		_:
			return "小怪"


func _finish_dungeon(victory: bool) -> void:
	if dungeon_finished:
		return
	dungeon_finished = true
	battle_state = BattleState.VICTORY if victory else BattleState.DEFEAT
	damage_taken += maxf(0.0, _last_hp - player.hp)
	_last_hp = player.hp
	bm.clear_fx()
	seq_fx.reset()
	bm.play_sound("victory" if victory else "death")
	_last_result = {"victory": victory, "kills": kills, "hits": hit_count,
		"best_chain": best_chain, "damage_taken": damage_taken, "elapsed": elapsed}
	_show_settlement(victory)
	# 结算后角色仍可自由移动：只有死亡本身会锁住操作
	player.control_enabled = not player.dead
	for monster in monsters:
		if is_instance_valid(monster):
			monster.control_enabled = false
	print("[DEMO] dungeon_result=%s kills=%d hits=%d" % ["victory" if victory else "defeat", kills, hit_count])


func _on_retry_dungeon() -> void:
	var target := "10001"
	if dungeon != null and dungeon.is_loaded():
		target = dungeon.id()
	_enter_dungeon(target)


func _on_leave_dungeon() -> void:
	_toast_show("离开地下城功能尚未开放")
	gm_log("离开地下城：功能尚未实现（本按钮只给提示）")


func _update_camera() -> void:
	if camera == null or player == null:
		return
	var half := VIEW_W * 0.5
	var target_x := half
	if room_world_width > VIEW_W:
		target_x = clampf(player.position.x, half, room_world_width - half)
	camera.position = Vector2(target_x, VIEW_H * 0.5)


# ---------------------------- GM 命令 ----------------------------

func gm_log(text: String) -> void:
	if gm_panel != null:
		gm_panel.set_log(text)


func _on_gm_command(command: String, args: PackedStringArray) -> void:
	var verb := command.to_lower()
	match verb:
		"help":
			gm_log("命令：help | mode <demo|dungeon> | dungeon [id|restart] | room <n|next|prev>\nclear | spawn <goblin|elite|chief> [n] | god | heal | job <0-2|next>\nwin | lose | settings | fps <n>")
		"mode":
			_gm_mode(args)
		"dungeon":
			_gm_dungeon(args)
		"room":
			_gm_room(args)
		"clear", "kill":
			_gm_clear()
		"spawn":
			_gm_spawn(args)
		"god":
			player.invincible = 0 if player.invincible > 0 else 99999999
			gm_log("无敌：%s" % ("开" if player.invincible > 0 else "关"))
		"heal":
			player.hp = float(player.cfg.get("max_hp", player.hp))
			player.mp = float(player.cfg.get("max_mp", player.mp))
			gm_log("已回满 HP / MP")
		"job":
			_gm_job(args)
		"win":
			if dungeon_mode:
				_finish_dungeon(true)
				gm_log("已直接结算为胜利")
			else:
				gm_log("当前不是副本模式（先执行 dungeon 10001）")
		"lose":
			if dungeon_mode:
				_finish_dungeon(false)
			else:
				_finish(false)
			gm_log("已直接结算为失败")
		"settings":
			_toggle_display_settings()
			gm_log("已打开显示设置（等同 F3）")
		"fps":
			_gm_fps(args)
		_:
			gm_log("未知命令：%s（输入 help 查看全部命令）" % command)


func _gm_mode(args: PackedStringArray) -> void:
	var target := ""
	if args.size() > 0:
		target = args[0].to_lower()
	if target == "demo":
		_show_ready()
		gm_log("已切到旧的“选择战斗风格 / 三波遭遇战”模式")
	elif target == "dungeon":
		_enter_dungeon("10001")
		gm_log("已切到副本模式 · 10001")
	else:
		gm_log("用法：mode <demo|dungeon>")


func _gm_dungeon(args: PackedStringArray) -> void:
	var target := "10001"
	if args.size() > 0:
		target = args[0]
	if target == "restart":
		if dungeon != null and dungeon.is_loaded():
			target = dungeon.id()
		else:
			target = "10001"
	_enter_dungeon(target)
	if dungeon != null and dungeon.is_loaded() and dungeon.id() == target:
		gm_log("进入副本 %s · 布局 %s · 第 %d/%d 房" % [dungeon.id(), dungeon.layout(),
			dungeon.room_number(), dungeon.room_count()])


func _gm_room(args: PackedStringArray) -> void:
	if not dungeon_mode or dungeon == null or not dungeon.is_loaded():
		gm_log("当前不是副本模式，无法切房")
		return
	var token := "next"
	if args.size() > 0:
		token = args[0].to_lower()
	var target_index := dungeon.room_index
	if token == "next":
		target_index += 1
	elif token == "prev":
		target_index -= 1
	elif token.is_valid_int():
		target_index = int(token) - 1
	else:
		gm_log("用法：room <序号|next|prev>")
		return
	if target_index < 0 or target_index >= dungeon.room_count():
		gm_log("房间序号超出范围（1 ~ %d）" % dungeon.room_count())
		return
	dungeon.room_index = target_index
	dungeon_finished = false
	_clear_settlement()
	_load_room()
	gm_log("已切到第 %d 房 %s（%s）" % [dungeon.room_number(), dungeon.room_name(), dungeon.module_id()])


func _gm_clear() -> void:
	var cleared_count := 0
	for monster in monsters.duplicate():
		if is_instance_valid(monster) and not monster.dead and not monster.training_mode:
			monster._die()
			cleared_count += 1
	if cleared_count == 0:
		gm_log("本房没有存活怪物")
	else:
		gm_log("已清空本房 %d 只怪物" % cleared_count)


func _gm_spawn(args: PackedStringArray) -> void:
	var preset := "goblin"
	if args.size() > 0:
		preset = args[0].to_lower()
	var count := 1
	if args.size() > 1 and args[1].is_valid_int():
		count = clampi(int(args[1]), 1, 8)
	var presets: Dictionary = dungeon_config.get("monster_presets", {})
	if not presets.has(preset):
		gm_log("未知怪物预设：%s（可用 goblin / elite / chief）" % preset)
		return
	if not dungeon_mode:
		_enter_dungeon("10001")
	for index in count:
		var cfg: Dictionary = GameConfig.monsters["goblin"].duplicate(true)
		var overrides: Dictionary = presets[preset]
		for key in overrides:
			cfg[key] = overrides[key]
		var spawn_x := clampf(player.position.x + 220.0 + float(index) * 130.0, 120.0,
			maxf(160.0, room_world_width - 90.0))
		_spawn_room_monster({"cfg": cfg, "x": spawn_x, "depth": 0.0, "preset": preset})
	room_cleared = false
	dungeon_finished = false
	_clear_settlement()
	if current_door != null:
		current_door.set_opened(false)
	if battle_state != BattleState.FIGHT:
		battle_state = BattleState.FIGHT
	_set_actor_control(true)
	gm_log("已生成 %d 只 %s" % [count, preset])


func _gm_job(args: PackedStringArray) -> void:
	var token := "next"
	if args.size() > 0:
		token = args[0].to_lower()
	if token == "next":
		selected_job = (player.job + 1) % 3
	elif token.is_valid_int():
		selected_job = clampi(int(token), 0, 2)
	else:
		gm_log("用法：job <0-2|next>")
		return
	player.set_job(selected_job)
	hud.set_player_info("幽影剑士", 30, selected_job)
	gm_log("职业已切换为 %s" % JOB_NAMES[selected_job])


func _gm_fps(args: PackedStringArray) -> void:
	if args.size() == 0 or not args[0].is_valid_int():
		gm_log("用法：fps <0|30|60|90|120|144|165|240>（0 为不限）")
		return
	var requested := int(args[0])
	if not FPS_PRESETS.has(requested):
		gm_log("不支持的帧率：%d" % requested)
		return
	fps_limit = requested
	_apply_display_settings()
	gm_log("帧率上限已设为 %s" % ("不限" if fps_limit == 0 else str(fps_limit)))


func _pick_target():
	var best = null
	var best_distance := INF
	for monster in monsters:
		if not is_instance_valid(monster) or monster.dead:
			continue
		var distance: float = absf(monster.position.x - player.position.x)
		if distance < best_distance:
			best_distance = distance
			best = monster
	return best

func _hud_cooldowns() -> void:
	var left := {}
	var total := {}
	for sid in Player.JOB_SKILLS.get(player.job, []):
		var skill: Dictionary = GameConfig.skills.get(sid, {})
		var index: int = SLOT_INDEX.get(str(skill.get("slot", "")), -1)
		if index >= 0:
			left[index] = float(player.cds.get(sid, 0)) / 60.0
			total[index] = float(skill.get("cd", 0))
	for index in [6, 7]:
		left[index] = float(player.potion_cd) / 60.0
		total[index] = float(player.cfg.get("potion_cd", 5))
	for move_id in ["upper", "back_dash"]:
		var index := 8 if move_id == "upper" else 9
		left[index] = float(player.cds.get(move_id, 0)) / 60.0
		total[index] = float(GameConfig.moves[move_id].get("cd", 0))
	hud.set_cooldowns(left, total)

func _process(delta: float) -> void:
	if _fps_readout:
		_fps_readout.text = "%d FPS  ·  %s" % [roundi(Engine.get_frames_per_second()), "不限" if fps_limit == 0 else "上限 %d" % fps_limit]
	if battle_state != BattleState.PAUSED:
		_clock += delta
		queue_redraw()
	if _toast_left > 0.0:
		_toast_left -= delta
		if _toast_left <= 0.0 and _toast != null:
			_toast.hide()
	if dungeon_mode:
		_update_camera()
	if hud and player:
		bm.set_listener_position(player.visual_position().x)
		hud.set_vitals(player.hp, player.cfg["max_hp"], player.mp, player.cfg["max_mp"])
		hud.set_job(player.job)
		hud.set_attack_speed(float(player.cfg.get("attack_speed", 1.0)) * (float(player.buff_data.get("atk_speed", 1.0)) if player.buff_t > 0 else 1.0))
		hud.set_target(_pick_target())
		if dungeon_mode and dungeon != null and dungeon.is_loaded():
			hud.set_dungeon_room(dungeon.display_name(), dungeon.room_index, dungeon.room_count(), _role_label(), alive_count())
		else:
			hud.set_encounter(wave_index + 1, demo_config["waves"].size(), alive_count(), elapsed)
		while not damage_samples.is_empty() and elapsed - float(damage_samples[0]["time"]) > 5.0:
			damage_samples.pop_front()
		var rolling_damage := 0.0
		for sample in damage_samples:
			rolling_damage += float(sample["damage"])
		hud.set_training(training_mode, {"damage": training_damage, "chain_damage": training_chain_damage,
			"hits": hit_count, "best": best_chain, "dps": rolling_damage / minf(5.0, maxf(1, elapsed)),
			"free": training_free_skills, "action": player.move_name, "buff": player.buff_t})
		_hud_cooldowns()
		if elapsed - last_hit_time > 2.2:
			hit_chain = 0
			hud.set_combo(0)

func _time_text(seconds: float) -> String:
	return "%02d:%02d" % [int(seconds / 60.0), int(seconds) % 60]

func _draw() -> void:
	# 副本模式的房间背景由 room_bg_sprite 负责（见 _build_world 的 z_index 说明），
	# 这里直接返回，避免 Main 自己的绘制盖住负 z 的实体。
	if dungeon_mode:
		return
	if bg_tex:
		draw_texture_rect(bg_tex, Rect2(0, 0, VIEW_W, VIEW_H), false)
	else:
		draw_rect(Rect2(0, 0, VIEW_W, VIEW_H), Color(0.07, 0.07, 0.105))
	for point in [Vector2(125, 303), Vector2(1120, 291)]:
		var flicker := 0.78 + 0.09 * sin(_clock * 5.3 + point.x)
		for radius in [70.0, 45.0, 24.0]:
			draw_circle(point, radius, Color(1.0, 0.37, 0.08, 0.018 * flicker))
	for index in 14:
		var x := fposmod(index * 103.7 + _clock * (3.0 + index % 3), VIEW_W)
		var y := 290 + fposmod(index * 53.9 - _clock * 6, 280)
		draw_circle(Vector2(x, y), 1.2, Color(0.9, 0.67, 0.42, 0.17))
