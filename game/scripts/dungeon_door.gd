class_name DungeonDoor
extends Node2D
## 关卡门：四方位（左/右/上/下）均使用双态贴图；某方向缺图时退回程序化占位。
## 贴图按脚底中心对齐；左门镜像右门图；上门/下门各自独立贴图，不做旋转。
## 触发区使用独立地面坐标，与绘制无关。

const FRAME := Color(0.38, 0.26, 0.16)
const FRAME_DARK := Color(0.20, 0.14, 0.09)
const VINE := Color(0.29, 0.46, 0.23)
const LAMP_OFF := Color(0.40, 0.40, 0.37)
const LAMP_ON := Color(1.0, 0.83, 0.44)
const BAR := Color(0.30, 0.21, 0.13)

const GATE_H := 214.0
const GATE_W := 62.0

var side := "right"
var connection_id := ""
var target_index := -1
var target_side := "left"
var opened := false
var font: Font
var _pulse := 0.0
var _settings: Dictionary = {}
var _gate_height := GATE_H
var _gate_width := GATE_W
var _trigger_width := 92.0
var _trigger_depth := 96.0
var _art := {}
var _art_sprites: Array[Sprite2D] = []

## 贴图缓存按贴图路径复用；某方向缺配置或缺图时退回程序化绘制。
static var _art_cache := {}


func setup(door_side: String, at: Vector2, settings: Dictionary = {}) -> void:
	_settings = (GameConfig.runtime.get("doors", {}) as Dictionary).duplicate(true)
	_settings.merge(settings, true)
	side = door_side
	connection_id = str(_settings.get("connection_id", _settings.get("id", "")))
	target_index = int(_settings.get("target_index", -1))
	target_side = str(_settings.get("target_side", "left"))
	_gate_height = maxf(1.0, float(_settings.get("height", GATE_H)))
	_gate_width = maxf(1.0, float(_settings.get("width", GATE_W)))
	_trigger_width = maxf(1.0, float(_settings.get("trigger_width", 92.0)))
	_trigger_depth = maxf(1.0, float(_settings.get("trigger_depth", 96.0)))
	position = at
	rotation = 0.0
	_art = _resolve_art()
	_build_art()
	queue_redraw()


func _resolve_art() -> Dictionary:
	var art: Dictionary = _settings.get("art", {})
	if art.is_empty():
		return {}
	var entry: Dictionary = art
	var by_side = art.get("by_side", {})
	var has_side: bool = by_side is Dictionary and by_side.has(side)
	if side == "up" or side == "down":
		# 上下门是正面/背面门面，不能拿左右侧视贴图顶替。
		if not has_side:
			return {}
		entry = by_side[side]
	elif has_side:
		entry = by_side[side]
	var closed := str(entry.get("closed", ""))
	var open := str(entry.get("open", ""))
	if closed.is_empty() or open.is_empty():
		return {}
	var key := closed + "|" + open
	if not _art_cache.has(key):
		if not ResourceLoader.exists(closed) or not ResourceLoader.exists(open):
			return {}
		_art_cache[key] = {"closed": load(closed), "open": load(open)}
	var pair: Dictionary = _art_cache[key]
	var texture: Texture2D = pair["closed"]
	if texture == null or texture.get_height() <= 0:
		return {}
	return pair


func _build_art() -> void:
	for sprite in _art_sprites:
		if is_instance_valid(sprite):
			sprite.queue_free()
	_art_sprites.clear()
	if _art.is_empty():
		return
	var texture: Texture2D = _art["closed"]
	var scale_factor := _gate_height / float(texture.get_height())
	var flip := side == "left"
	for state in ["closed", "open"]:
		var sprite := Sprite2D.new()
		sprite.name = "Door" + state.capitalize()
		sprite.texture = _art[state]
		sprite.centered = false
		sprite.offset = Vector2(-float(texture.get_width()) * 0.5, -float(texture.get_height()))
		sprite.scale = Vector2.ONE * scale_factor
		sprite.flip_h = flip
		sprite.visible = false
		add_child(sprite)
		_art_sprites.append(sprite)
	_refresh_art()


func _refresh_art() -> void:
	if _art_sprites.size() < 2:
		return
	_art_sprites[0].visible = not opened
	_art_sprites[1].visible = opened


func set_opened(value: bool) -> void:
	if opened == value:
		return
	opened = value
	_refresh_art()
	queue_redraw()


func uses_texture() -> bool:
	return not _art.is_empty()


## 下门位于画面近端，作为前景压在角色前面；其余方向仍在角色后面。
func z_for_layers(layers: Dictionary) -> int:
	if side == "down":
		return int(layers["effects_z"]) - 1
	return int(layers["door_z"])


## trigger_width 朝房间内侧延伸，trigger_depth 沿门口切向展开；均为世界地面坐标。
func reach_rect() -> Rect2:
	var at := global_position
	var half_depth := _trigger_depth * 0.5
	var edge_pad := 0.001
	match side:
		"left":
			return Rect2(at + Vector2(-edge_pad, -half_depth), Vector2(_trigger_width + edge_pad, _trigger_depth))
		"up":
			return Rect2(at + Vector2(-half_depth, -edge_pad), Vector2(_trigger_depth, _trigger_width + edge_pad))
		"down":
			return Rect2(at + Vector2(-half_depth, -_trigger_width), Vector2(_trigger_depth, _trigger_width + edge_pad))
		_:
			return Rect2(at + Vector2(-_trigger_width, -half_depth), Vector2(_trigger_width + edge_pad, _trigger_depth))


## actor_ground_pos 是脚点的世界地面坐标，包含景深，不包含跳跃高度。
func contains_actor(actor_ground_pos: Vector2) -> bool:
	return reach_rect().has_point(actor_ground_pos)


func spawn_point(clearance: float) -> Vector2:
	var offset := _trigger_width + maxf(1.0, clearance)
	match side:
		"left":
			return global_position + Vector2(offset, 0.0)
		"up":
			return global_position + Vector2(0.0, offset)
		"down":
			return global_position + Vector2(0.0, -offset)
		_:
			return global_position + Vector2(-offset, 0.0)


func _configured_color(key: String, fallback: Color) -> Color:
	var value = _settings.get(key, fallback)
	if value is Color:
		return value
	return Color.from_string(str(value), fallback)


func _process(delta: float) -> void:
	if not opened:
		return
	_pulse = fmod(_pulse + delta, 1.0)
	if _art_sprites.size() < 2:
		queue_redraw()
		return
	# 正式贴图没有灯动画层，用极轻的亮度脉动提示“已开启”，不改变几何。
	var lit := 0.94 + 0.06 * sin(_pulse * TAU)
	_art_sprites[1].modulate = Color(lit, lit, lit, 1.0)


func _draw() -> void:
	if not _art_sprites.is_empty():
		return
	var width := _gate_width
	var height := _gate_height
	var sink := 0.0
	if side == "up" or side == "down":
		# 上下门是朝镜头的门面，宽度远大于侧视门厚；下门背面下半截沉出地面。
		width = _gate_width * 2.4
		if side == "down":
			sink = _gate_height * 0.55
	var half_w := width * 0.5
	var top := -height + sink
	var dir := -1.0 if side == "left" else 1.0
	var frame := _configured_color("frame", FRAME)
	var frame_dark := _configured_color("frame_dark", FRAME_DARK)
	var vine := _configured_color("vine", VINE)
	var lamp_off := _configured_color("lamp_off", LAMP_OFF)
	var lamp_on := _configured_color("lamp_on", LAMP_ON)
	var bar := _configured_color("bar", BAR)

	# 门框：两根立柱 + 上梁
	draw_rect(Rect2(-half_w - 7, top - 12, 14, height + 12), frame)
	draw_rect(Rect2(half_w - 7, top - 12, 14, height + 12), frame)
	draw_rect(Rect2(-half_w - 7, top - 20, width + 14, 14), frame_dark)

	# 藤蔓：门框上的缠绕
	for index in 5:
		var y := top + height * 0.14 + float(index) * height * 0.19
		var wave := sin(float(index) * 1.7) * 5.0
		draw_line(Vector2(-half_w - 10, y), Vector2(half_w + 10, y + wave), vine, 3.0)

	# 未开启：横向木栅
	if not opened:
		for index in 4:
			var y := top + height * 0.22 + float(index) * height * 0.22
			draw_rect(Rect2(-half_w + 2, y, width - 4, 11), bar)
		draw_rect(Rect2(-half_w, top, width, height), Color(0.05, 0.04, 0.03, 0.30))
	else:
		# 开启：门内透光 + 指示箭头
		var glow := 0.22 + 0.16 * sin(_pulse * TAU)
		draw_rect(Rect2(-half_w, top, width, height), Color(1.0, 0.86, 0.52, glow))
		for index in 3:
			var cx := -6.0 + float(index) * 15.0
			var spread := 13.0
			draw_line(Vector2(cx * dir, top + height * 0.48), Vector2((cx + spread) * dir, top + height * 0.56), lamp_on, 4.0)
			draw_line(Vector2((cx + spread) * dir, top + height * 0.56), Vector2(cx * dir, top + height * 0.64), lamp_on, 4.0)

	# 门框灯
	var lamp_pos := Vector2(0, top - 30)
	var lamp_color := lamp_on if opened else lamp_off
	if opened:
		var halo := 26.0 + 6.0 * sin(_pulse * TAU)
		draw_circle(lamp_pos, halo, Color(1.0, 0.82, 0.40, 0.13))
	draw_circle(lamp_pos, 9.0, lamp_color)
	draw_circle(lamp_pos, 4.5, Color(1, 1, 1, 0.75) if opened else Color(0.25, 0.25, 0.22))

	if font != null:
		var text := "门已开启" if opened else "门未开启"
		var color := Color(1.0, 0.88, 0.58) if opened else Color(0.78, 0.74, 0.68)
		draw_string(font, Vector2(-half_w, top - 46), text, HORIZONTAL_ALIGNMENT_CENTER, width, 15, color)
