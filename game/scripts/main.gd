extends Node2D
## 主场景：地面 + 玩家 + 简单背景

var player: Player

func _ready() -> void:
	var ground := StaticBody2D.new()
	ground.name = "Ground"
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(1280, 80)
	shape.shape = rect
	shape.position = Vector2(640, 690)
	ground.add_child(shape)
	add_child(ground)

	player = Player.new()
	player.name = "Player"
	player.position = Vector2(400, 650)
	add_child(player)
	queue_redraw()

func _draw() -> void:
	draw_rect(Rect2(0, 0, 1280, 720), Color(0.09, 0.08, 0.13))  # 夜空背景
	draw_rect(Rect2(0, 650, 1280, 70), Color(0.16, 0.14, 0.2))  # 地面
	for i in range(0, 1280, 96):
		draw_line(Vector2(i, 650), Vector2(i, 720), Color(0.12, 0.11, 0.16), 2.0)
