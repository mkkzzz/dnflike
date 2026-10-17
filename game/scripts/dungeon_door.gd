class_name DungeonDoor
extends Node2D
## 关卡门占位：木栅栏 + 藤蔓门框 + 门框灯，未开启 / 开启两态。
## 设计单第五节的门资源尚未产出，这里是程序化占位，不冒充正式美术；
## 四方位接口保留（上/下用旋转复用侧向画法），布局 10001-A 当前只用右侧门。

const FRAME := Color(0.38, 0.26, 0.16)
const FRAME_DARK := Color(0.20, 0.14, 0.09)
const VINE := Color(0.29, 0.46, 0.23)
const LAMP_OFF := Color(0.40, 0.40, 0.37)
const LAMP_ON := Color(1.0, 0.83, 0.44)
const BAR := Color(0.30, 0.21, 0.13)

const GATE_H := 214.0
const GATE_W := 62.0

var side := "right"
var opened := false
var font: Font
var _pulse := 0.0


func setup(door_side: String, at: Vector2) -> void:
	side = door_side
	position = at
	match side:
		"left":
			pass
		"up":
			rotation = -PI * 0.5
		"down":
			rotation = PI * 0.5
		_:
			pass
	queue_redraw()


func set_opened(value: bool) -> void:
	if opened == value:
		return
	opened = value
	queue_redraw()


## 玩家进入该矩形即视为推门（世界坐标）。
## 下沿特意越过地面线：角色脚底正落在 GROUND_Y 上，而 Rect2.has_point 的上界是开区间。
## 纵向要盖住整条景深带，否则玩家走到带子后段就触发不到门。
func reach_rect() -> Rect2:
	var h := GATE_H
	var w := 92.0
	# 纵向一律盖住整条景深带；横向朝“房间内侧”延伸（右侧门往左、左侧门往右）
	# 左侧门的触发区特意收窄：它就在可行走左界附近，太宽会把刚出生的角色立刻吸回去
	if side == "left":
		return Rect2(position + Vector2(-6, -(h + 72.0)), Vector2(52, h + 120.0))
	if side == "up" or side == "down":
		return Rect2(position + Vector2(-w * 0.5, -120.0), Vector2(w + 8, 240.0))
	return Rect2(position + Vector2(-w, -(h + 72.0)), Vector2(w + 8, h + 120.0))


func contains_actor(actor_pos: Vector2) -> bool:
	return reach_rect().has_point(actor_pos)


func _process(delta: float) -> void:
	if opened:
		_pulse = fmod(_pulse + delta, 1.0)
		queue_redraw()


func _draw() -> void:
	var half_w := GATE_W * 0.5
	var dir := -1.0 if side == "left" else 1.0

	# 门框：两根立柱 + 上梁
	draw_rect(Rect2(-half_w - 7, -GATE_H - 12, 14, GATE_H + 12), FRAME)
	draw_rect(Rect2(half_w - 7, -GATE_H - 12, 14, GATE_H + 12), FRAME)
	draw_rect(Rect2(-half_w - 7, -GATE_H - 20, GATE_W + 14, 14), FRAME_DARK)

	# 藤蔓：门框上的缠绕
	for index in 5:
		var y := -GATE_H * 0.86 + float(index) * GATE_H * 0.19
		var wave := sin(float(index) * 1.7) * 5.0
		draw_line(Vector2(-half_w - 10, y), Vector2(half_w + 10, y + wave), VINE, 3.0)

	# 未开启：横向木栅
	if not opened:
		for index in 4:
			var y := -GATE_H * 0.78 + float(index) * GATE_H * 0.22
			draw_rect(Rect2(-half_w + 2, y, GATE_W - 4, 11), BAR)
		draw_rect(Rect2(-half_w, -GATE_H, GATE_W, GATE_H), Color(0.05, 0.04, 0.03, 0.30))
	else:
		# 开启：门内透光 + 指示箭头
		var glow := 0.22 + 0.16 * sin(_pulse * TAU)
		draw_rect(Rect2(-half_w, -GATE_H, GATE_W, GATE_H), Color(1.0, 0.86, 0.52, glow))
		for index in 3:
			var cx := -6.0 + float(index) * 15.0
			var spread := 13.0
			draw_line(Vector2(cx * dir, -GATE_H * 0.52), Vector2((cx + spread) * dir, -GATE_H * 0.44), LAMP_ON, 4.0)
			draw_line(Vector2((cx + spread) * dir, -GATE_H * 0.44), Vector2(cx * dir, -GATE_H * 0.36), LAMP_ON, 4.0)

	# 门框灯
	var lamp_pos := Vector2(0, -GATE_H - 30)
	var lamp_color := LAMP_ON if opened else LAMP_OFF
	if opened:
		var halo := 26.0 + 6.0 * sin(_pulse * TAU)
		draw_circle(lamp_pos, halo, Color(1.0, 0.82, 0.40, 0.13))
	draw_circle(lamp_pos, 9.0, lamp_color)
	draw_circle(lamp_pos, 4.5, Color(1, 1, 1, 0.75) if opened else Color(0.25, 0.25, 0.22))

	if font != null:
		var text := "门已开启" if opened else "门未开启"
		var color := Color(1.0, 0.88, 0.58) if opened else Color(0.78, 0.74, 0.68)
		draw_string(font, Vector2(-42, -GATE_H - 46), text, HORIZONTAL_ALIGNMENT_CENTER, 84, 15, color)
