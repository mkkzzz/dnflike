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
## 角色绘制层级基准，必须大于 0（背景在 z_index 0），景深在此基础上加减
const Z_ACTOR := 10

var bm: BattleFX
var player: Player
var monsters: Array = []
var info_label: Label
var font: FontFile
var bg_tex: Texture2D
var vignette_tex: Texture2D
var hud: Hud

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
	# 特效要画在角色之上：bm 先于 player/monster 入树，默认会被它们盖住
	bm.z_index = 40
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
	player.z_index = Z_ACTOR
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
	# 按景深决定绘制层级：站得靠前（depth_y 大）的压在玩家前面，靠后的被玩家挡住。
	# 基准 Z_ACTOR 必须 > 0 —— 背景是 main 自己在 z_index 0 画的，
	# 直接用 depth_y 当 z_index 会让靠后的怪（depth_y 为负）跑到背景背后消失。
	# 必须在 add_child 之后设，否则被 monster.gd 的 _ready 覆盖。
	m.z_index = Z_ACTOR + int(round(m.depth_y))
	m.setup(cfg, player, bm)
	monsters.append(m)

func _build_hud() -> void:
	# 正式 HUD：CanvasLayer 由 Hud 内部自建，因此不会随相机滚动
	hud = Hud.new()
	hud.name = "Hud"
	add_child(hud)
	hud.set_font(font)
	hud.set_player_info("幽影剑士", 30, 0)
	# M2 房间系统尚未实现：不设房间时隐藏房间块，避免显示假数据
	hud.clear_room()

	# 调试层：只留操作提示与状态。正式数值已由 HUD 接管，这里不再重复显示。
	var layer := CanvasLayer.new()
	layer.name = "DebugLayer"
	layer.layer = 11
	add_child(layer)
	info_label = Label.new()
	info_label.position = Vector2(16, 76)
	info_label.add_theme_font_size_override("font_size", 13)
	info_label.modulate = Color(1.0, 1.0, 1.0, 0.72)
	if font:
		info_label.add_theme_font_override("font", font)
	layer.add_child(info_label)


## HUD 顶部铭牌的目标：最近的存活怪物
func _pick_target():
	var best = null
	var best_d := INF
	for m in monsters:
		if not is_instance_valid(m) or m.dead:
			continue
		var d: float = absf(m.position.x - player.position.x)
		if d < best_d:
			best_d = d
			best = m
	return best


## 技能格按键 → HUD 格子索引（与 hud_manifest.json 的 slots 顺序一致）
const SLOT_INDEX := {"A": 0, "S": 1, "D": 2, "F": 3, "G": 4, "H": 5, "1": 6, "2": 7}

## player.cds（技能 id → 剩余帧数）+ skills.json 的 slot/cd 字段 → HUD 冷却遮罩
func _hud_cooldowns() -> void:
	var left := {}
	var total := {}
	for sid in player.cds.keys():
		var sk: Dictionary = GameConfig.skills.get(sid, {})
		if sk.is_empty():
			continue
		var idx: int = SLOT_INDEX.get(str(sk.get("slot", "")), -1)
		if idx < 0:
			continue
		var l := float(player.cds[sid]) / 60.0
		if l > 0.0:
			left[idx] = l
			total[idx] = float(sk.get("cd", 0))
	hud.set_cooldowns(left, total)


## 暗角叠加层：固定屏幕空间。
## 层号必须低于 HUD —— preview 的合成顺序是 world(含暗角) → hud → 动态 UI。
func _build_vignette() -> void:
	if vignette_tex == null:
		return
	var layer := CanvasLayer.new()
	layer.name = "VignetteLayer"
	layer.layer = 1
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
	if hud != null and player != null:
		hud.set_vitals(player.hp, player.cfg["max_hp"], player.mp, player.cfg["max_mp"])
		hud.set_combo(player.combo)
		hud.set_job(player.job)
		hud.set_target(_pick_target())
		_hud_cooldowns()
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
	info_label.text = "X普攻 C跳 Z上挑 V格挡 ↓+C后跳 T转职 R重置\n职业: %s | 状态: %s | 连段: %d | HP: %.0f/%.0f | 怪物存活: %d | 技能: %s" % \
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
