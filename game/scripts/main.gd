extends Node2D
## 主场景：输入注册、地面、玩家、怪物、战斗表现、调试与验收日志

const GROUND_Y := 650.0

var bm: BattleFX
var player: Player
var monsters: Array = []
var info_label: Label
var font: FontFile

func _ready() -> void:
	GameConfig.load_all()
	_register_actions()
	_load_font()
	_build_world()
	_build_hud()
	print("[M1] scene ready")

func _register_actions() -> void:
	var actions := {
		"move_left": [KEY_LEFT],
		"move_right": [KEY_RIGHT],
		"move_down": [KEY_DOWN],
		"jump": [KEY_C, KEY_SPACE],
		"attack": [KEY_X],
		"generic_skill": [KEY_Z],
		"guard": [KEY_V],
		"skill_a": [KEY_A],
		"skill_s": [KEY_S],
		"skill_d": [KEY_D],
		"skill_f": [KEY_F],
		"debug_job": [KEY_T],
		"debug_reset": [KEY_R],
	}
	for action in actions:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		for key in actions[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = key
			InputMap.action_add_event(action, ev)

func _load_font() -> void:
	font = FontFile.new()
	for path in ["C:/Windows/Fonts/msyh.ttc", "C:/Windows/Fonts/simhei.ttf"]:
		if font.load_dynamic_font(path) == OK:
			print("[M1] font loaded: " + path)
			return
	font = null

func _build_world() -> void:
	var ground := StaticBody2D.new()
	ground.name = "Ground"
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(4000, 100)
	shape.shape = rect
	shape.position = Vector2(2000, GROUND_Y + 50)
	ground.add_child(shape)
	add_child(ground)

	bm = BattleFX.new()
	bm.name = "BattleFX"
	bm.number_font = font
	add_child(bm)
	var cam := Camera2D.new()
	cam.position = Vector2(400, 360)
	cam.zoom = Vector2.ONE
	cam.limit_left = 0
	cam.limit_right = 4000
	cam.limit_top = -200
	cam.limit_bottom = 720
	add_child(cam)
	bm.camera = cam
	camera = cam

	player = Player.new()
	player.name = "Player"
	player.position = Vector2(300, GROUND_Y)
	add_child(player)
	player.setup(GameConfig.player, bm, monsters)

	for x in [620.0, 900.0]:
		_spawn_goblin(x)

func _spawn_goblin(x: float) -> void:
	var m := Monster.new()
	m.name = "Goblin"
	m.position = Vector2(x, GROUND_Y)
	add_child(m)
	m.setup(GameConfig.monsters["goblin"], player, bm)
	monsters.append(m)

func _build_hud() -> void:
	var title := Label.new()
	title.text = "M1 手感原型 · X普攻 C跳 Z上挑 V格挡 ↓+C后跳 · T切换转职 R重置"
	title.position = Vector2(16, 8)
	if font:
		title.add_theme_font_override("font", font)
	add_child(title)
	info_label = Label.new()
	info_label.position = Vector2(16, 36)
	if font:
		info_label.add_theme_font_override("font", font)
	add_child(info_label)

func _physics_process(_delta: float) -> void:
	if bm.freeze > 0:
		bm.freeze -= 1
	_check_debug_keys()

func _check_debug_keys() -> void:
	if Input.is_action_just_pressed("debug_job"):
		player.set_job((player.job + 1) % 3)
	if Input.is_action_just_pressed("debug_reset"):
		_reset_battle()

var camera: Camera2D

func _reset_battle() -> void:
	player.hp = player.cfg["max_hp"]
	for m in monsters:
		if is_instance_valid(m):
			m.queue_free()
	monsters.clear()
	for x in [620.0, 900.0]:
		_spawn_goblin(x)
	print("[M1] battle reset")

func _process(_delta: float) -> void:
	if camera != null and player != null:
		camera.position.x = clampf(player.position.x, 640, 3360)
		camera.position.y = 360
	if info_label == null:
		return
	var job_name: String = ["基础鬼剑士", "狂战士", "剑魂"][player.job]
	var st_name: String = Player.St.keys()[player.state]
	var skills := ""
	if player.job == 1:
		skills = "A血怒 S怒斩"
	elif player.job == 2:
		skills = "A拔刀斩 S连突刺"
	var alive := 0
	for m in monsters:
		if is_instance_valid(m) and not m.dead:
			alive += 1
	info_label.text = "职业: %s | 状态: %s | 连段: %d | HP: %.0f/%.0f | 怪物存活: %d\n技能: %s" % \
		[job_name, st_name, player.combo, player.hp, player.cfg["max_hp"], alive, skills]

func _draw() -> void:
	draw_rect(Rect2(0, 0, 1280, 720), Color(0.09, 0.08, 0.13))
	draw_rect(Rect2(0, GROUND_Y, 1280, 70), Color(0.16, 0.14, 0.2))
	for i in range(0, 1280, 96):
		draw_line(Vector2(i, GROUND_Y), Vector2(i, 720), Color(0.12, 0.11, 0.16), 2.0)
