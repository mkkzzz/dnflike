extends Node2D
## 主场景：输入注册、地面、玩家、怪物、战斗表现、调试与验收日志

const VIEW_W := 1280.0
const VIEW_H := 720.0
const WORLD_W := 4000.0
## 物理地面线 = 玩家脚底视觉落点。
## preview 是伪 3D：脚底 = (GROUND0 224 + z) × 2，玩家 z=64 → 576。
## 怪物不共用这条线，而是用纯视觉 depth_y 复现远近层次（见 SPAWNS）。
const GROUND_Y := 576.0
## 出生点 [x, 视觉景深]。景深取自 preview：E1 z=56 → -8，E2 z=80 → +16（相对玩家 z=64）
const SPAWNS := [[620.0, -8.0], [900.0, 16.0]]

var bm: BattleFX
var player: Player
var monsters: Array = []
var info_label: Label
var font: FontFile
var bg_tex: Texture2D
var vignette_tex: Texture2D

func _ready() -> void:
	GameConfig.load_all()
	_register_actions()
	_load_font()
	_load_art()
	_build_world()
	_build_hud()
	_build_vignette()
	print("[M1] scene ready")

## 烘焙贴图由 tools/bake_game_assets.py 产出（美术源为 tools/render_preview.py）
func _load_art() -> void:
	bg_tex = load("res://art/bg_dungeon.png") as Texture2D
	vignette_tex = load("res://art/vignette.png") as Texture2D
	if bg_tex == null or vignette_tex == null:
		push_warning("[ART] 缺烘焙贴图：先跑 python tools/bake_game_assets.py")
	else:
		print("[ART] bg=%dx%d vignette ok" % [bg_tex.get_width(), bg_tex.get_height()])

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
	player.ground_y = GROUND_Y
	add_child(player)
	player.setup(GameConfig.player, bm, monsters)

	for s in SPAWNS:
		_spawn_goblin(s[0], s[1])

func _spawn_goblin(x: float, depth_y: float = NAN) -> void:
	var m := Monster.new()
	m.name = "Goblin"
	m.position = Vector2(x, GROUND_Y)
	var cfg: Dictionary = GameConfig.monsters["goblin"]
	m.depth_y = float(cfg.get("depth_y", 0.0)) if is_nan(depth_y) else depth_y
	m.ground_y = GROUND_Y
	add_child(m)
	m.setup(cfg, player, bm)
	monsters.append(m)

func _build_hud() -> void:
	# HUD 必须挂 CanvasLayer：挂 Node2D 下会随相机一起滚动
	var layer := CanvasLayer.new()
	layer.name = "HudLayer"
	layer.layer = 10
	add_child(layer)
	var title := Label.new()
	title.text = "M1 手感原型 · X普攻 C跳 Z上挑 V格挡 ↓+C后跳 · T切换转职 R重置"
	title.position = Vector2(16, 8)
	if font:
		title.add_theme_font_override("font", font)
	layer.add_child(title)
	info_label = Label.new()
	info_label.position = Vector2(16, 36)
	if font:
		info_label.add_theme_font_override("font", font)
	layer.add_child(info_label)


## 暗角叠加层：固定屏幕空间，压在 HUD 之上
func _build_vignette() -> void:
	if vignette_tex == null:
		return
	var layer := CanvasLayer.new()
	layer.name = "VignetteLayer"
	layer.layer = 20
	var tr := TextureRect.new()
	tr.texture = vignette_tex
	tr.position = Vector2.ZERO
	tr.size = Vector2(VIEW_W, VIEW_H)
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(tr)
	add_child(layer)

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
	for s in SPAWNS:
		_spawn_goblin(s[0], s[1])
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
	if bg_tex == null:
		draw_rect(Rect2(0, 0, WORLD_W, VIEW_H), Color(0.09, 0.08, 0.13))
		return
	# 沿世界横向镜像平铺，减轻重复感（M2 房间制后换成按房间取景）
	var tw := float(bg_tex.get_width())
	var th := float(bg_tex.get_height())
	var n := int(ceil((WORLD_W + VIEW_W) / tw)) + 1
	for i in range(n):
		var x := float(i) * tw
		if i % 2 == 1:
			draw_set_transform(Vector2(x + tw, 0.0), 0.0, Vector2(-1.0, 1.0))
			draw_texture_rect(bg_tex, Rect2(0.0, 0.0, tw, th), false)
		else:
			draw_set_transform(Vector2(x, 0.0), 0.0, Vector2.ONE)
			draw_texture_rect(bg_tex, Rect2(0.0, 0.0, tw, th), false)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
