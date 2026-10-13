class_name BattleFX
extends Node2D
## 战斗表现管理：命中停帧 / 震屏 / 伤害跳字（数字与中文均需字体，由 Main 注入）

var freeze := 0
var shake := 0.0
var camera: Camera2D
var number_font: Font
var pool: Array[Label] = []
var log_hits := 0

func hitstop(frames: int) -> void:
	freeze = maxi(freeze, frames)

func add_shake(amount: float) -> void:
	shake = maxf(shake, amount)

func spawn_number(world_pos: Vector2, text: String, color: Color, size := 18) -> void:
	var lb := _take_label()
	lb.text = text
	lb.add_theme_font_size_override("font_size", size)
	lb.add_theme_color_override("font_color", color)
	lb.position = world_pos + Vector2(randf_range(-8, 8), -40)
	lb.scale = Vector2(1.6, 1.6)
	lb.modulate.a = 1.0
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(lb, "position:y", lb.position.y - 46.0, 0.55).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(lb, "scale", Vector2(1.0, 1.0), 0.12)
	tw.chain().tween_property(lb, "modulate:a", 0.0, 0.25).set_delay(0.2)
	tw.chain().tween_callback(_recycle.bind(lb))

func _take_label() -> Label:
	for lb in pool:
		if not lb.visible:
			lb.visible = true
			return lb
	var lb := Label.new()
	lb.z_index = 50
	if number_font:
		lb.add_theme_font_override("font", number_font)
	lb.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	lb.add_theme_constant_override("outline_size", 4)
	add_child(lb)
	pool.append(lb)
	return lb

func _recycle(lb: Label) -> void:
	lb.visible = false

func _process(_delta: float) -> void:
	if camera == null:
		return
	if shake > 0.2:
		camera.offset = Vector2(randf_range(-1, 1), randf_range(-0.5, 0.5)) * shake
		shake *= 0.82
	else:
		shake = 0.0
		camera.offset = Vector2.ZERO
