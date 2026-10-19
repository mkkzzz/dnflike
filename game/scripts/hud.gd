class_name Hud
extends CanvasLayer
## Native 2K generated HUD with live data and no debug readouts.
signal action_requested(action: String)
signal settings_requested
const ASSET_ROOT := "res://assets/ui/hud_v2/"
const SLOT_KEYS := ["Q", "W", "E", "R", "T", "Y", "A", "S", "D", "F", "G", "H"]
const SLOT_CODES := [KEY_Q, KEY_W, KEY_E, KEY_R, KEY_T, KEY_Y, KEY_A, KEY_S, KEY_D, KEY_F, KEY_G, KEY_H]

const DESIGN_W := 2560.0
const DESIGN_H := 1440.0
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
var _textures: Dictionary = {}
var skill_slots: Array = []
var _map_positions: Array = []
var _map_links: Array = []
var _map_cleared: Dictionary = {}
var _keycap: StyleBoxFlat
var _drag_slot := -1
var _dragging := false
var _drag_origin := Vector2.ZERO

func set_attack_speed(speed: float) -> void:
	displayed_attack_speed = speed
	_refresh()


func _init() -> void:
	layer = 15
	name = "HudLayer"


func _ready() -> void:
	_root = Control.new()
	_root.name = "HudRoot"
	# 2K artwork at half logical scale; canvas_items redraws at display resolution.
	_root.scale = Vector2(0.5, 0.5)
	_root.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
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
	for id in ["hp_shell", "mp_shell", "hp_liquid", "mp_liquid", "hp_glass", "mp_glass", "wheel",
			"slot_frame", "fascia_tile", "exp_frame", "target_frame", "target_portrait", "minimap_frame",
			"title_plate", "item_potion_red", "item_potion_blue", "skill_quick_draw", "skill_thrust",
			"skill_blood_rage", "skill_rage_slash"]:
		_textures[id] = load(ASSET_ROOT + id + ".png") as Texture2D
	_keycap = StyleBoxFlat.new()
	_keycap.bg_color = Color("#a28f69")
	_keycap.border_color = Color("#3d3529")
	_keycap.set_border_width_all(2)
	_keycap.set_corner_radius_all(3)
	_load_slots()
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
		_drag_slot = -1
		_load_slots()
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
	_text(Vector2(16, 27), "%d FPS" % roundi(Engine.get_frames_per_second()), 19, Color(0.82, 0.84, 0.82, 0.85), "left", true)
	if _feedback_left > 0.0:
		var color := IVORY
		color.a = minf(1.0, _feedback_left * 3.0)
		_text(Vector2(1280, 1020), _feedback, 28, color, "center")
	var hover := _slot_at(_mouse_position())
	if hover >= 0 and not String(skill_slots[hover]).is_empty():
		var skill: Dictionary = GameConfig.skills.get(skill_slots[hover], {})
		_text(Vector2(1910, 1120), "%s   MP %d" % [str(skill.get("name", "")), int(skill.get("mp", 0))], 24, IVORY, "center")
	if _drag_slot >= 0 and _dragging:
		_tex("skill_" + str(skill_slots[_drag_slot]), _mouse_position() - Vector2(48, 48))


func _draw_bottom_bar() -> void:
	_target = _bottom_layer
	_draw_bottom()


func set_front_occlusion(amount: float) -> void:
	front_occlusion = clampf(amount, 0.0, 1.0)
	if _bottom_layer != null:
		_bottom_layer.modulate.a = lerpf(1.0, float(GameConfig.runtime["hud"]["minimum_opacity"]), front_occlusion)


func _tex(id: String, pos: Vector2, modulate := Color.WHITE) -> void:
	var texture: Texture2D = _textures.get(id)
	if texture != null:
		_target.draw_texture(texture, pos, modulate)


func _draw_bottom() -> void:
	var tile: Texture2D = _textures.get("fascia_tile")
	if tile != null:
		for i in 5:
			if i % 2:
				_target.draw_set_transform(Vector2((i + 1) * 512, 1170), 0, Vector2(-1, 1))
				_target.draw_texture(tile, Vector2.ZERO)
				_target.draw_set_transform(Vector2.ZERO)
			else:
				_target.draw_texture(tile, Vector2(i * 512, 1170))
	_tex("exp_frame", Vector2(260, 1202))
	_text(Vector2(325, 1248), "Lv.%d" % player_level, 27, IVORY, "center")
	# There is no experience system yet: keep the track empty.
	for i in 6:
		var icon: String = ["item_potion_red", "item_potion_blue"][i] if i < 2 else ""
		_draw_slot(Vector2(274 + i * 128, 1302), str(i + 1), icon, 6 + i if i < 2 else -1)
	for i in 12:
		var id := str(skill_slots[i])
		var skills: Array = JOB_SKILLS.get(job, [])
		var index: int = skills.find(id)
		var pos := Vector2(1540 + (i % 6) * 126, 1178 + floori(float(i) / 6.0) * 130)
		_draw_slot(pos, SLOT_KEYS[i], "skill_" + id if not id.is_empty() else "", index, id)
	_tex("wheel", Vector2(1060, 1098))
	_draw_reservoir("hp", Vector2(0, 1056), _ratio(vitals_hp, vitals_hp_max), Rect2(18, 56, 130, 306))
	_draw_reservoir("mp", Vector2(2312, 1056), _ratio(vitals_mp, vitals_mp_max), Rect2(100, 63, 130, 294))
	var buff := float(training_stats.get("buff", 0.0))
	if buff > 0:
		_target.draw_texture_rect(_textures["slot_frame"], Rect2(266, 1124, 64, 64), false)
		_target.draw_texture_rect(_textures["skill_blood_rage"], Rect2(272, 1130, 52, 52), false)
		_text(Vector2(299, 1187), "%.0f" % ceilf(buff), 20, IVORY, "center", true)


func _draw_reservoir(prefix: String, pos: Vector2, ratio: float, well: Rect2) -> void:
	_tex(prefix + "_shell", pos)
	var texture: Texture2D = _textures.get(prefix + "_liquid")
	var cutoff := well.position.y + floorf(well.size.y * (1.0 - ratio))
	if texture != null and ratio > 0:
		var source := Rect2(0, cutoff, 248, 384 - cutoff)
		_target.draw_texture_rect_region(texture, Rect2(pos + source.position, source.size), source)
	_tex(prefix + "_glass", pos)
	_text(pos + Vector2(well.get_center().x, well.end.y - 14), "%d%%" % roundi(ratio * 100), 22, IVORY, "center", true)


func _draw_slot(pos: Vector2, key: String, icon: String, cooldown_index: int, skill_id := "") -> void:
	_tex("slot_frame", pos)
	var icon_mod := Color.WHITE
	if not skill_id.is_empty() and vitals_mp < float(GameConfig.skills.get(skill_id, {}).get("mp", 0)):
		icon_mod = Color(0.38, 0.46, 0.62)
	if not icon.is_empty():
		_tex(icon, pos + Vector2(10, 10), icon_mod)
	var left := maxf(0, float(_cooldowns.get(cooldown_index, 0)))
	var total := maxf(left, float(_cooldown_max.get(cooldown_index, 0)))
	if left > 0 and total > 0 and not icon.is_empty():
		var center := pos + Vector2(58, 58)
		var points := PackedVector2Array([center])
		var end_angle := -PI / 2 + TAU * left / total
		for i in 33:
			var angle := lerpf(-PI / 2, end_angle, float(i) / 32)
			var ray := Vector2(cos(angle), sin(angle))
			points.append(center + ray * (50.0 / maxf(absf(ray.x), absf(ray.y))))
		_target.draw_colored_polygon(points, Color(0, 0, 0, 0.72))
		_text(center + Vector2(0, 10), "%.1f" % left, 27, IVORY, "center", true)
	_target.draw_style_box(_keycap, Rect2(pos + Vector2(39, 96), Vector2(38, 28)))
	_text(pos + Vector2(58, 120), key, 22, IVORY, "center")


func _draw_encounter() -> void:
	_tex("title_plate", Vector2(1940, 0))
	var title := room_title if dungeon_mode else ("训练场" if training_mode else "战斗试炼")
	if has_room:
		title += " · %d/%d" % [room_idx + 1, room_total]
	_text(Vector2(2534, 43), title, 30, IVORY, "right")
	if not dungeon_mode or room_total <= 0:
		return
	_tex("minimap_frame", Vector2(2288, 66))
	_text(Vector2(2438, 115), "地图", 27, IVORY, "center")
	if _map_positions.is_empty():
		return
	var bounds := Rect2(_map_positions[0], Vector2.ZERO)
	for p in _map_positions:
		bounds = bounds.expand(p)
	var step := minf(42.0, minf(160 / maxf(1, bounds.size.x + 1), 148 / maxf(1, bounds.size.y + 1)))
	var origin := Vector2(2436, 226) - (bounds.position + bounds.size * 0.5) * step
	var side := step * 0.78
	for link in _map_links:
		var a := int(link.get("from", -1))
		var b := int(link.get("to", -1))
		if a >= 0 and b >= 0 and a < _map_positions.size() and b < _map_positions.size():
			_target.draw_line(origin + _map_positions[a] * step, origin + _map_positions[b] * step, Color(0.40, 0.39, 0.23), 3)
	for i in _map_positions.size():
		var center: Vector2 = origin + _map_positions[i] * step
		var color := Color(0.22, 0.23, 0.12)
		if _map_cleared.has(i):
			color = Color(0.40, 0.42, 0.22)
		_target.draw_rect(Rect2(center - Vector2.ONE * side / 2, Vector2.ONE * side), color)
		_target.draw_rect(Rect2(center - Vector2.ONE * side / 2, Vector2.ONE * side), GOLD_DIM, false, 1)
		if i == room_idx:
			_target.draw_colored_polygon(PackedVector2Array([center + Vector2(0, -9), center + Vector2(6, 0), center + Vector2(0, 9), center + Vector2(-6, 0)]), Color(0.24, 0.80, 0.95))
		elif i == _map_positions.size() - 1:
			_target.draw_circle(center, 4, Color(0.88, 0.30, 0.12))


func set_map_layout(links: Array, count: int, cleared: Dictionary) -> void:
	_map_cleared = cleared
	if count == _map_positions.size() and links == _map_links:
		return
	_map_links = links.duplicate(true)
	_map_positions = [Vector2.ZERO]
	_map_positions.resize(count)
	# 副本数据用 up/down 表示上下门，早期地图代码只认 top/bottom，
	# 查不到就退化成 RIGHT，导致"钻上门、地图却往右长"。两种写法都接受。
	var side_vectors := {
		"left": Vector2.LEFT, "right": Vector2.RIGHT,
		"up": Vector2.UP, "down": Vector2.DOWN,
		"top": Vector2.UP, "bottom": Vector2.DOWN,
	}
	var known := {0: Vector2.ZERO}
	for pass_index in count:
		for link in links:
			var a := int(link.get("from", -1))
			var b := int(link.get("to", -1))
			var direction: Vector2 = side_vectors.get(str(link.get("from_side", "right")), Vector2.RIGHT)
			if known.has(a) and not known.has(b):
				known[b] = known[a] + direction
			elif known.has(b) and not known.has(a):
				known[a] = known[b] - direction
	for i in count:
		_map_positions[i] = known.get(i, Vector2(i, 0))


func _draw_target() -> void:
	if target == null or not is_instance_valid(target) or bool(target.get("dead")):
		return
	var cfg: Dictionary = target.get("cfg")
	var hp := maxf(0, float(target.get("hp")))
	var maximum := maxf(1, float(cfg.get("hp", 200)))
	var raw_width := 240 + maximum * 0.23
	var width := clampf(raw_width, 672, 1440)
	var layers := maxi(1, ceili(raw_width / 1440))
	var per_layer := maximum / layers
	var remaining_layers := maxi(1, ceili(hp / per_layer))
	var fraction := (hp - (remaining_layers - 1) * per_layer) / per_layer
	var texture: Texture2D = _textures.get("target_frame")
	if texture == null:
		return
	_target.draw_texture_rect_region(texture, Rect2(16, 100, 124, 116), Rect2(0, 0, 124, 116))
	_target.draw_texture_rect_region(texture, Rect2(140, 100, 696, 56), Rect2(124, 0, 696, 56))
	# Repeat the painted health-track middle; never enlarge decorative ends.
	var source := Rect2(124, 56, 696, 60)
	_target.draw_texture_rect_region(texture, Rect2(140, 156, 18, 60), Rect2(source.position, Vector2(18, 60)))
	var x := 158.0
	while x < 140 + width - 18:
		var piece := minf(660, 140 + width - 18 - x)
		_target.draw_texture_rect_region(texture, Rect2(x, 156, piece, 60), Rect2(142, 56, piece, 60))
		x += piece
	_target.draw_texture_rect_region(texture, Rect2(140 + width - 18, 156, 18, 60), Rect2(802, 56, 18, 60))
	_tex("target_portrait", Vector2(30, 118))
	_text(Vector2(155, 143), str(cfg.get("name", "哥布林")), 27, IVORY)
	var bar := Rect2(150, 164, width - 20, 32)
	_fill_bar(bar, fraction, Color(0.80, 0.06, 0.08))
	if layers > 1:
		_text(Vector2(160 + width, 193), "×%d" % remaining_layers, 27, IVORY, "left", true)


func _fill_bar(rect: Rect2, fraction: float, color: Color) -> void:
	var width := rect.size.x * clampf(fraction, 0, 1)
	if width <= 0:
		return
	for y in int(rect.size.y):
		var t := float(y) / maxf(1, rect.size.y - 1)
		var shade := color.lightened((0.5 - t) * 0.5) if t < 0.5 else color.darkened((t - 0.5) * 0.65)
		_target.draw_line(rect.position + Vector2(0, y), rect.position + Vector2(width, y), shade, 1)


func _draw_combo() -> void:
	if combo < 2 or combo_age > 2.5:
		return
	var color := Color(0.10, 0.78, 0.94, clampf((2.5 - combo_age) * 3, 0, 1))
	_text(Vector2(2520, 600), "%d Hit Combo!" % combo, 52, color, "right", true)


func _default_slots() -> Array:
	var slots: Array = []
	slots.resize(12)
	slots.fill("")
	var ids: Array = JOB_SKILLS.get(job, [])
	for i in ids.size():
		slots[6 + i] = ids[i]
	return slots


func _load_slots() -> void:
	skill_slots = _default_slots()
	var saved := ConfigFile.new()
	if saved.load("user://hud_slots.cfg") != OK:
		return
	var candidate = saved.get_value("skills", str(job), [])
	if not candidate is Array or candidate.size() != 12:
		return
	var actual: Array = []
	for id in candidate:
		if str(id).is_empty():
			continue
		if not id in JOB_SKILLS.get(job, []) or id in actual:
			return
		actual.append(id)
	if actual.size() == JOB_SKILLS.get(job, []).size():
		skill_slots = candidate.duplicate()


func move_skill_slot(from: int, to: int, persist := true) -> void:
	if from < 0 or to < 0 or from >= 12 or to >= 12 or str(skill_slots[from]).is_empty():
		return
	var temp = skill_slots[to]
	skill_slots[to] = skill_slots[from]
	skill_slots[from] = temp
	if persist:
		var saved := ConfigFile.new()
		saved.load("user://hud_slots.cfg")
		saved.set_value("skills", str(job), skill_slots)
		saved.save("user://hud_slots.cfg")
	_refresh()


func _mouse_position() -> Vector2:
	return _root.get_local_mouse_position()


func _slot_at(point: Vector2) -> int:
	for i in 12:
		if Rect2(1540 + (i % 6) * 126, 1178 + floori(float(i) / 6.0) * 130, 116, 124).has_point(point):
			return i
	return -1


func _activate_slot(index: int) -> void:
	var ids: Array = JOB_SKILLS.get(job, [])
	var skill_index: int = ids.find(skill_slots[index])
	if skill_index >= 0:
		action_requested.emit("skill_a" if skill_index == 0 else "skill_s")


func handle_hud_input(event: InputEvent) -> bool:
	if not visible:
		return false
	if event is InputEventKey and event.pressed and not event.echo:
		var key: int = event.physical_keycode if event.physical_keycode else event.keycode
		var index := SLOT_CODES.find(key)
		if index >= 0:
			_activate_slot(index)
			return true
	if event is InputEventMouseMotion:
		var point: Vector2 = _root.get_global_transform_with_canvas().affine_inverse() * event.position
		if _drag_slot >= 0 and point.distance_to(_drag_origin) > 12:
			_dragging = true
			return true
	if not event is InputEventMouseButton or event.button_index != MOUSE_BUTTON_LEFT:
		return false
	var point: Vector2 = _root.get_global_transform_with_canvas().affine_inverse() * event.position
	if _bottom_layer.modulate.a < 0.35:
		_drag_slot = -1
		_dragging = false
		return false
	if event.pressed:
		var index := _slot_at(point)
		if index >= 0:
			_drag_slot = index
			_drag_origin = point
			_dragging = false
			return true
		if point.distance_to(Vector2(1430, 1370)) <= 40:
			settings_requested.emit()
			return true
		for i in 2:
			if Rect2(274 + i * 128, 1302, 116, 124).has_point(point):
				action_requested.emit("potion_hp" if i == 0 else "potion_mp")
				return true
	elif _drag_slot >= 0:
		var to := _slot_at(point)
		if _dragging and to >= 0:
			move_skill_slot(_drag_slot, to)
		elif not _dragging:
			_activate_slot(_drag_slot)
		_drag_slot = -1
		_dragging = false
		return true
	return false


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
