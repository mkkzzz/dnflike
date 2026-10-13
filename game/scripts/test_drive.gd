extends Node
## 自动化战斗测试驱动：headless 下用 --test 参数激活，模拟按键跑完整战斗流程

var active := false
var frame := 0
var seq: Array = []
var main_ref

var init_done := false

func _ready() -> void:
	active = "--test" in OS.get_cmdline_user_args()
	if not active:
		return
	main_ref = get_parent()
	print("[M1] TEST DRIVE ACTIVE")
	_build_seq()

func _init_test_player() -> void:
	# 测试模式下玩家无敌，避免怪物攻击打断指令序列
	var p: Player = main_ref.player
	if p != null:
		p.invincible = 999999

func _build_seq() -> void:
	# (帧, 命令)：走路接近 → 普攻三段 → 重置 → 上挑 → 狂战士技能 → 重置 → 剑魂技能
	seq = [
		[1, "right_on"],
		[95, "right_off"],
		[110, "attack"], [112, "attack_off"],
		[134, "attack"], [136, "attack_off"],
		[160, "attack"], [162, "attack_off"],
		[180, "debug_reset"],
		[200, "teleport", 585.0],
		[220, "generic_skill"], [222, "generic_skill_off"],
		[300, "debug_job"],
		[320, "skill_a"], [322, "skill_a_off"],
		[355, "teleport", 555.0],
		[360, "skill_s"], [362, "skill_s_off"],
		[440, "debug_reset"],
		[470, "teleport", 540.0],
		[490, "debug_job"],
		[510, "skill_a"], [512, "skill_a_off"],
		[520, "teleport", 590.0],
		[530, "skill_s"], [532, "skill_s_off"],
		[700, "done"],
	]

func _physics_process(_delta: float) -> void:
	if not active:
		return
	if not init_done:
		init_done = true
		_init_test_player()
	frame += 1
	if frame % 60 == 0:
		print("[M1] DRIVE tick frame=%d seq=%d" % [frame, seq.size()])
	for item in seq:
		if item[0] == frame:
			_do(item)

func _do(item: Array) -> void:
	var cmd: String = item[1]
	print("[M1] DRIVE cmd=" + cmd)
	match cmd:
		"right_on":
			Input.action_press("move_right")
		"right_off":
			Input.action_release("move_right")
		"attack":
			Input.action_press("attack")
		"attack_off":
			Input.action_release("attack")
		"generic_skill":
			Input.action_press("generic_skill")
		"generic_skill_off":
			Input.action_release("generic_skill")
		"skill_a":
			Input.action_press("skill_a")
		"skill_a_off":
			Input.action_release("skill_a")
		"skill_s":
			Input.action_press("skill_s")
		"skill_s_off":
			Input.action_release("skill_s")
		"debug_job":
			Input.action_press("debug_job")
			Input.action_release("debug_job")
		"debug_reset":
			Input.action_press("debug_reset")
			Input.action_release("debug_reset")
		"teleport":
			var p: Player = main_ref.player
			p.position.x = item[2]
			p.facing = 1
			p.state = Player.St.IDLE
			print("[M1] teleport player to x=%.0f" % item[2])
		"done":
			print("[M1] TEST DRIVE DONE")
