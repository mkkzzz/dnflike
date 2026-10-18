class_name Hud
extends CanvasLayer
## Screen-space combat HUD. Only implemented actions appear in the hotbar.

const DESIGN_W := 1280.0
const DESIGN_H := 720.0
const INK := Color(0.035, 0.028, 0.034, 0.90)
const GOLD := Color(0.69, 0.54, 0.33)
const GOLD_DIM := Color(0.32, 0.25, 0.17)
const IVORY := Color(0.90, 0.85, 0.76)
const MUTED := Color(0.58, 0.55, 0.52)
const RED := Color(0.65, 0.15, 0.21)
const BLUE := Color(0.25, 0.45, 0.60)
const JOB_NAMES := ["鬼剑士", "狂战士", "剑魂"]
const JOB_SKILLS := {1: ["blood_rage", "rage_slash"], 2: ["quick_draw", "thrust"]}

var font: Font
var number_font: Font
var target = null
var combo := 0
var combo_age := 0.0
var combo_flash := 0.0
var job := 0
var player_name := "幽影剑士"
var player_level := 30
var vitals_hp := 0.0
var vitals_hp_max := 0.0
var vitals_mp := 0.0
var vitals_mp_max := 0.0
var room_idx := 0
var room_total := 0
var room_difficulty := ""
var has_room := false
var dungeon_mode := false
var room_title := ""
var wave := 0
var wave_total := 0
var enemies_remaining := 0
var elapsed := 0.0
var training_mode := false
var training_stats: Dictionary = {}

var _root: Control
## 当前绘制目标：默认 _root；画底部栏时切到 _bottom_layer，好让底栏整体让位
var _target: CanvasItem
## 底部栏独立节点（y≈616 以下的整条面板 + 技能槽）：角色走到路面前沿时整体淡出
var _bottom_layer: Control
var front_occlusion := 0.0
var _portrait: Texture2D
var _cooldowns: Dictionary = {}
var _cooldown_max: Dictionary = {}
var _feedback := ""
var _feedback_left := 0.0
var _hp_chip := 0.0
var _target_chip := 0.0
var _target_id := 0
var _vitals_initialized := false
var displayed_attack_speed := 1.0

func set_attack_speed(speed: float) -> void:
	displayed_attack_speed = speed
	_refresh()


func _init() -> void:
	layer = 15
	name = "HudLayer"


func _ready() -> void:
	_root = Control.new()
	_root.name = "HudRoot"
	_root.size = Vector2(DESIGN_W, DESIGN_H)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.draw.connect(_draw_hud)
	add_child(_root)
	_target = _root
	# 底部栏画在自己的子节点里，这样可以让它整体淡出而不影响其它 HUD 元素
	_bottom_layer = Control.new()
	_bottom_layer.name = "HudBottom"
	_bottom_layer.size = Vector2(DESIGN_W, DESIGN_H)
	_bottom_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bottom_layer.draw.connect(_draw_bottom_bar)
	_root.add_child(_bottom_layer)
	if font == null:
		font = ThemeDB.fallback_font
	if ResourceLoader.exists("res://assets/demo/portrait.png"):
		_portrait = load("res://assets/demo/portrait.png") as Texture2D
	_refresh()


func set_font(value: Font) -> void:
	if value != null:
		font = value
	_refresh()


func set_number_font(value: Font) -> void:
	number_font = value
	_refresh()


func set_player_info(name_text: String, level: int = -1, job_id: int = -1) -> void:
	if not name_text.is_empty():
		player_name = name_text
	if level >= 0:
		player_level = level
	if job_id >= 0:
		set_job(job_id)
	_refresh()


func set_job(job_id: int) -> void:
	var next_job := clampi(job_id, 0, JOB_NAMES.size() - 1)
	if next_job != job:
		job = next_job
	_refresh()


func set_vitals(hp: float, hp_max: float, mp: float, mp_max: float) -> void:
	vitals_hp = maxf(0.0, hp)
	vitals_hp_max = maxf(0.0, hp_max)
	vitals_mp = maxf(0.0, mp)
	vitals_mp_max = maxf(0.0, mp_max)
	if not _vitals_initialized or vitals_hp > _hp_chip:
		_hp_chip = vitals_hp
		_vitals_initialized = true
	_refresh()


func set_combo(value: int) -> void:
	if value != combo:
		combo_flash = 1.0
		combo_age = 0.0
	combo = value
	_refresh()


func set_target(monster) -> void:
	target = monster
	_refresh()


func set_cooldowns(slot_to_left: Dictionary, slot_to_total: Dictionary = {}) -> void:
	# Existing indices stay intact: A=0, S=1, 1=6, 2=7, Z=8, backjump=9.
	_cooldowns = slot_to_left.duplicate()
	_cooldown_max = slot_to_total.duplicate()
	_refresh()


func set_room(idx: int, total: int, difficulty: String = "") -> void:
	room_idx = idx
	room_total = total
	room_difficulty = difficulty
	has_room = total > 0
	_refresh()


func clear_room() -> void:
	has_room = false
	_refresh()


## 副本模式专用：标题换成副本名，副标题给出房间进度与角色，第三行给清房目标。
## 用独立入口而不是复用 set_room，避免影响旧的“第 X · Y 波”显示。
func set_dungeon_room(title: String, idx: int, total: int, role_label: String, remaining: int) -> void:
	dungeon_mode = true
	room_title = title
	room_idx = idx
	room_total = total
	room_difficulty = role_label
	has_room = total > 0
	enemies_remaining = maxi(0, remaining)
	_refresh()


func set_elapsed(seconds: float) -> void:
	elapsed = maxf(0.0, seconds)
	_refresh()


func clear_dungeon_room() -> void:
	dungeon_mode = false
	room_title = ""
	_refresh()


func set_encounter(current_wave: int, total: int, remaining: int, time_elapsed: float) -> void:
	wave = current_wave
	wave_total = total
	enemies_remaining = maxi(0, remaining)
	elapsed = maxf(0.0, time_elapsed)
	_refresh()


func set_feedback(text: String) -> void:
	_feedback = text
	_feedback_left = 1.7 if not text.is_empty() else 0.0
	_refresh()

func set_training(enabled: bool, stats: Dictionary) -> void:
	training_mode = enabled
	training_stats = stats
	_refresh()


func set_data(data: Dictionary) -> void:
	if data.has("target"):
		set_target(data["target"])
	if data.has("hp") or data.has("mp"):
		set_vitals(float(data.get("hp", vitals_hp)), float(data.get("hp_max", vitals_hp_max)),
			float(data.get("mp", vitals_mp)), float(data.get("mp_max", vitals_mp_max)))
	if data.has("combo"):
		set_combo(int(data["combo"]))
	if data.has("name") or data.has("level") or data.has("job"):
		set_player_info(str(data.get("name", player_name)), int(data.get("level", -1)),
			int(data.get("job", -1)))
	if data.has("room_total"):
		set_room(int(data.get("room_idx", 0)), int(data["room_total"]),
			str(data.get("room_difficulty", "")))
	if data.has("cooldowns"):
		set_cooldowns(data["cooldowns"], data.get("cooldown_max", {}))
	if data.has("wave"):
		set_encounter(int(data["wave"]), int(data.get("wave_total", wave_total)),
			int(data.get("remaining", enemies_remaining)), float(data.get("elapsed", elapsed)))
	if data.has("feedback"):
		set_feedback(str(data["feedback"]))


func refresh() -> void:
	_refresh()


func _refresh() -> void:
	if _root != null:
		_root.queue_redraw()
		if _bottom_layer != null:
			_bottom_layer.queue_redraw()


func _process(delta: float) -> void:
	combo_flash = maxf(0.0, combo_flash - delta * 6.0)
	combo_age += delta
	_feedback_left = maxf(0.0, _feedback_left - delta)
	_hp_chip = move_toward(_hp_chip, vitals_hp, vitals_hp_max * delta * 0.6)
	if target != null and is_instance_valid(target) and not bool(target.get("dead")):
		var target_hp := maxf(0.0, float(target.get("hp")))
		var instance_id: int = target.get_instance_id()
		var cfg: Dictionary = target.get("cfg")
		var hp_max := maxf(1.0, float(cfg.get("hp", 200.0)))
		if instance_id != _target_id or target_hp > _target_chip:
			_target_id = instance_id
			_target_chip = target_hp
		_target_chip = move_toward(_target_chip, target_hp, hp_max * delta * 0.75)
	_refresh()


func _draw_hud() -> void:
	_target = _root
	_draw_encounter()
	_draw_target()
	_draw_combo()
	if training_mode:
		_draw_training()
	if _feedback_left > 0.0:
		var color := IVORY
		color.a = minf(1.0, _feedback_left * 3.0)
		_text(Vector2(640, 599), _feedback, 17, color, "center")


## 底部栏在自己的节点里绘制（y≈616 以下），便于整体让位给走到前景的角色
func _draw_bottom_bar() -> void:
	_target = _bottom_layer
	_draw_bottom()


## 角色越靠近该图路面前沿，底栏越淡（0 = 完整显示，1 = 几乎全透明）。
## 注意：这是显示层让位，景深可动范围本身仍严格按该图路面取值。
func set_front_occlusion(amount: float) -> void:
	front_occlusion = clampf(amount, 0.0, 1.0)
	if _bottom_layer != null:
		_bottom_layer.modulate.a = lerpf(1.0, float(GameConfig.runtime["hud"]["minimum_opacity"]), front_occlusion)


func _draw_encounter() -> void:
	_target.draw_line(Vector2(26, 27), Vector2(26, 83), GOLD, 2.0)
	_text(Vector2(40, 43), "回廊训练场" if training_mode else ("幽暗回廊" if not (dungeon_mode and has_room) else room_title), 24, IVORY)
	var subtitle := "战斗试炼"
	if training_mode:
		subtitle = "连段练习  /  " + ("无限补给" if training_stats.get("free", true) else "实战消耗")
	elif dungeon_mode and has_room:
		subtitle = "第 %d · %d 间" % [room_idx + 1, room_total]
		if not room_difficulty.is_empty():
			subtitle += "  ·  " + room_difficulty
	elif wave_total > 0:
		subtitle += "  /  第 %d · %d 波" % [maxi(1, wave), wave_total]
	elif has_room:
		subtitle += "  /  第 %d · %d 间" % [room_idx + 1, room_total]
		if not room_difficulty.is_empty():
			subtitle += "  " + room_difficulty
	_text(Vector2(40, 65), subtitle, 13, GOLD)
	if training_mode:
		_text(Vector2(40, 87), "Tab 重置  ·  F2 补给模式", 13, MUTED)
	elif dungeon_mode and has_room:
		var room_objective := "清除本房间敌人  ·  剩余 %d" % enemies_remaining
		if enemies_remaining == 0:
			room_objective = "房间已清空  ·  门已开启"
		_text(Vector2(40, 87), room_objective, 14, MUTED)
	elif wave_total > 0:
		var objective := "清除本波敌人  ·  剩余 %d" % enemies_remaining
		if enemies_remaining == 0:
			objective = "本波已肃清"
		_text(Vector2(40, 87), objective, 14, MUTED)
	var seconds := floori(elapsed)
	_text(Vector2(1246, 37), "%02d:%02d" % [int(seconds / 60.0), seconds % 60], 19, IVORY, "right", true)
	_text(Vector2(1246, 60), "ESC  暂停", 12, MUTED, "right")

func _draw_training() -> void:
	_target.draw_rect(Rect2(26, 111, 222, 153), Color(0.025, 0.027, 0.04, 0.78))
	_target.draw_line(Vector2(26, 111), Vector2(248, 111), GOLD_DIM, 1)
	_text(Vector2(40, 135), "DPS  /  最近 5 秒", 12, MUTED)
	_text(Vector2(40, 169), "%.1f" % float(training_stats.get("dps", 0)), 30, IVORY, "left", true)
	_text(Vector2(40, 196), "本段伤害   %.0f" % float(training_stats.get("chain_damage", 0)), 14, GOLD)
	_text(Vector2(40, 219), "累计伤害   %.0f" % float(training_stats.get("damage", 0)), 13, MUTED)
	_text(Vector2(40, 246), "命中 %d     最长连击 %d" % [int(training_stats.get("hits", 0)), int(training_stats.get("best", 0))], 13, IVORY)
	var buff := float(training_stats.get("buff", 0))
	if buff > 0:
		_text(Vector2(40, 291), "血怒  %.1fs" % buff, 15, Color(0.96, 0.34, 0.37))


func _draw_target() -> void:
	if target == null or not is_instance_valid(target) or bool(target.get("dead")):
		return
	var cfg: Dictionary = target.get("cfg")
	var hp := maxf(0.0, float(target.get("hp")))
	var hp_max := maxf(1.0, float(cfg.get("hp", 200.0)))
	var bar := Rect2(467, 50, 386, 9)
	_text(Vector2(660, 37), str(cfg.get("name", "哥布林")), 16, IVORY, "center")
	_target.draw_rect(Rect2(463, 46, 394, 17), INK)
	_target.draw_line(Vector2(463, 46), Vector2(857, 46), GOLD_DIM, 1.0)
	_bar(bar, hp / hp_max, RED, _target_chip / hp_max)
	_text(Vector2(660, 78), "%d / %d" % [ceili(hp), ceili(hp_max)], 12, MUTED, "center", true)


func _draw_bottom() -> void:
	# The translucent strip begins below the playable ground line (576px).
	for row in range(104):
		var alpha := 0.30 + 0.65 * float(row) / 103.0
		_target.draw_line(Vector2(0, 616 + row), Vector2(DESIGN_W, 616 + row),
			Color(INK.r, INK.g, INK.b, alpha), 1.0)
	_target.draw_line(Vector2(24, 616), Vector2(1256, 616), GOLD_DIM, 1.0)
	_draw_portrait()
	_text(Vector2(100, 641), player_name, 17, IVORY)
	_text(Vector2(331, 641), "%s  Lv.%d" % [JOB_NAMES[job], player_level], 12, GOLD, "right")
	_bar(Rect2(100, 651, 231, 10), _ratio(vitals_hp, vitals_hp_max), RED,
		_ratio(_hp_chip, vitals_hp_max))
	_bar(Rect2(100, 673, 231, 7), _ratio(vitals_mp, vitals_mp_max), BLUE)
	_text(Vector2(216, 660), "%d / %d" % [ceili(vitals_hp), ceili(vitals_hp_max)], 11,
		IVORY, "center", true)
	_text(Vector2(216, 680), "%d / %d" % [ceili(vitals_mp), ceili(vitals_mp_max)], 10,
		IVORY, "center", true)
	_text(Vector2(100, 695), "攻速 %.0f%%" % (displayed_attack_speed * 100), 11, MUTED)
	var backjump_left := float(_cooldowns.get(9, 0.0))
	_text(Vector2(331, 695), "后跳 %.1fs" % backjump_left if backjump_left > 0 else "后跳就绪", 11, GOLD if backjump_left <= 0 else MUTED, "right")
	var attack_name := "三连斩"
	if str(training_stats.get("action", "")) == "air_attack":
		attack_name = "空中斩"
	elif str(training_stats.get("action", "")) == "dash_attack":
		attack_name = "奔跑冲斩"
	_draw_action(0, "X", attack_name, -1, "basic", true)
	_draw_action(1, "Z", "上挑", 8, "upper", true)
	var skill_names: Array = ["转职解锁", "转职解锁"]
	if JOB_SKILLS.has(job):
		var ids: Array = JOB_SKILLS[job]
		for index in range(2):
			var skill: Dictionary = GameConfig.skills.get(ids[index], {})
			skill_names[index] = str(skill.get("name", ids[index]))
	_draw_action(2, "A", skill_names[0], 0, "A", job > 0)
	_draw_action(3, "S", skill_names[1], 1, "S", job > 0)
	_draw_action(4, "V", "格挡", -1, "guard", true)
	_draw_action(5, "1", "生命药水", 6, "hp", true)
	_draw_action(6, "2", "魔力药水", 7, "mp", true)
	_text(Vector2(25, 715), "← → 移动  ·  双击奔跑  ·  ↑ ↓ 景深", 11, MUTED)
	_text(Vector2(639, 715), "C / 空格 跳跃  ·  ↓ + C 后跳", 11, MUTED, "center")
	_text(Vector2(1255, 715), "T 切换职业  ·  R 重玩  ·  F3 显示设置", 11, MUTED, "right")


func _draw_portrait() -> void:
	var rect := Rect2(25, 631, 60, 55)
	_target.draw_rect(rect.grow(2.0), INK)
	if _portrait != null:
		var source_size := _portrait.get_size()
		var side := minf(source_size.x, source_size.y)
		var source := Rect2(Vector2((source_size.x - side) * 0.5, 0), Vector2(side, side))
		_target.draw_texture_rect_region(_portrait, rect, source)
	_target.draw_rect(rect.grow(2.0), GOLD_DIM, false, 1.0)
	_target.draw_line(Vector2(25, 630), Vector2(85, 630), GOLD, 1.0)


func _draw_action(index: int, key: String, title: String, cooldown_index: int,
		icon: String, enabled: bool) -> void:
	var rect := Rect2(383 + index * 124, 629, 113, 58)
	var accent := RED if job == 1 and key in ["A", "S"] else GOLD
	if key == "2":
		accent = BLUE
	elif key == "1":
		accent = RED
	if not enabled:
		accent = MUTED * Color(0.6, 0.6, 0.6, 1.0)
	_target.draw_rect(rect, INK)
	_target.draw_rect(rect, GOLD_DIM if enabled else Color(0.17, 0.16, 0.16), false, 1.0)
	_target.draw_line(rect.position, rect.position + Vector2(rect.size.x, 0), accent, 1.0)
	var left := maxf(0.0, float(_cooldowns.get(cooldown_index, 0.0)))
	var total := maxf(left, float(_cooldown_max.get(cooldown_index, 0.0)))
	var icon_pos := rect.position + Vector2(8, 8)
	_draw_symbol(icon_pos + Vector2(16, 15), icon, accent)
	_text(rect.position + Vector2(96, 22), key, 18, IVORY if enabled else MUTED, "right", true)
	_text(rect.position + Vector2(56, 49), title, 12, IVORY if enabled else MUTED, "center")
	if left > 0.0:
		_target.draw_rect(Rect2(rect.position + Vector2(1, 1), Vector2(111, 56)), Color(0, 0, 0, 0.57))
		_text(rect.position + Vector2(29, 34), "%.1f" % left, 18, IVORY, "center", true)
		_text(rect.position + Vector2(96, 22), key, 18, IVORY, "right", true)
		if total > 0.0:
			_target.draw_line(rect.position + Vector2(1, 57),
				rect.position + Vector2(1 + 111 * (1.0 - left / total), 57), GOLD, 2.0)


func _draw_symbol(center: Vector2, kind: String, color: Color) -> void:
	if kind in ["hp", "mp"]:
		_target.draw_rect(Rect2(center + Vector2(-3, -13), Vector2(6, 6)), GOLD_DIM)
		var flask := PackedVector2Array([center + Vector2(-4, -7), center + Vector2(4, -7),
			center + Vector2(9, 1), center + Vector2(9, 11), center + Vector2(-9, 11),
			center + Vector2(-9, 1)])
		_target.draw_colored_polygon(flask, Color(color.r, color.g, color.b, 0.55))
		var outline := flask.duplicate()
		outline.append(flask[0])
		_target.draw_polyline(outline, color.lightened(0.2), 1.5, true)
		_target.draw_line(center + Vector2(-6, 3), center + Vector2(6, 3), IVORY, 1.0)
	elif kind == "guard":
		var points := PackedVector2Array([center + Vector2(-10, -12), center + Vector2(10, -12),
			center + Vector2(8, 6), center + Vector2(0, 13), center + Vector2(-8, 6),
			center + Vector2(-10, -12)])
		_target.draw_polyline(points, color, 1.5, true)
		_target.draw_line(center + Vector2(0, -9), center + Vector2(0, 8), color, 1.0, true)
	elif kind == "A" and job == 1:
		_target.draw_arc(center, 12, 0, TAU, 24, color, 1.5, true)
		_target.draw_arc(center, 7, 0, TAU, 18, color.lightened(0.15), 1.0, true)
		_target.draw_line(center + Vector2(0, -15), center + Vector2(0, 15), IVORY, 1.5)
	else:
		_target.draw_line(center + Vector2(-10, 11), center + Vector2(10, -11), color, 3.0, true)
		_target.draw_line(center + Vector2(-11, 2), center + Vector2(-2, 10), IVORY, 2.0, true)
		if kind == "upper":
			_target.draw_arc(center + Vector2(-4, 3), 14, -1.6, 0.3, 14, color, 1.0, true)
		elif kind == "S" and job == 2:
			for offset in [-7, 0, 7]:
				_target.draw_line(center + Vector2(-15, offset), center + Vector2(13, offset), color, 1.0)
		elif kind in ["A", "S"]:
			_target.draw_arc(center + Vector2(-5, 0), 16, -1.5, 1.1, 16, color, 1.5, true)


func _draw_combo() -> void:
	if combo < 2 or combo_age > 2.5:
		return
	var alpha := clampf((2.5 - combo_age) * 3.0, 0.0, 1.0)
	var color := GOLD
	color.a = alpha
	_text(Vector2(1219, 268), str(combo), 43 + roundi(combo_flash * 5), color, "right", true)
	color = IVORY
	color.a = alpha * 0.8
	_text(Vector2(1219, 290), "连击", 14, color, "right")


func _bar(rect: Rect2, fraction: float, color: Color, chip: float = 0.0) -> void:
	_target.draw_rect(rect, Color(0.08, 0.065, 0.07))
	if chip > fraction:
		_target.draw_rect(Rect2(rect.position, Vector2(rect.size.x * clampf(chip, 0.0, 1.0), rect.size.y)),
			Color(0.65, 0.51, 0.37, 0.55))
	var width := rect.size.x * clampf(fraction, 0.0, 1.0)
	if width > 0.0:
		_target.draw_rect(Rect2(rect.position, Vector2(width, rect.size.y)), color)
		_target.draw_line(rect.position + Vector2(0, 1), rect.position + Vector2(width, 1),
			color.lightened(0.22), 1.0)


func _ratio(value: float, maximum: float) -> float:
	return clampf(value / maximum, 0.0, 1.0) if maximum > 0.0 else 0.0


func _text(pos: Vector2, text: String, size: int, color: Color, align: String = "left",
		numeric: bool = false) -> void:
	var selected_font := number_font if numeric and number_font != null else font
	if selected_font == null:
		selected_font = ThemeDB.fallback_font
	var width := selected_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var baseline := pos
	if align == "center":
		baseline.x -= width * 0.5
	elif align == "right":
		baseline.x -= width
	_target.draw_string_outline(selected_font, baseline, text, HORIZONTAL_ALIGNMENT_LEFT, -1,
		size, 3, Color(0.02, 0.015, 0.02, color.a * 0.75))
	_target.draw_string(selected_font, baseline, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)
