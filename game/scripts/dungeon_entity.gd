class_name DungeonEntity
extends Node2D
## 非生物实体占位实装：影子 + 本体，按台账的脚底锚点对齐。
## 碰撞按“物体本身”精准匹配，并由台账逐类开关（不是所有实体都挡人）。
## 美术来自 lowres_release_v1 的实体导出（台账写明 entities preserved，未单独重新批准）。

var entity_id := ""
var entry: Dictionary = {}
## 精准碰撞框（相对脚底锚点）。仅当 collision_enabled 为 true 时有效。
var collision_rect := Rect2()
var collision_enabled := false

var _body: Sprite2D
var _shadow: Sprite2D
var _collision_body: StaticBody2D
## 景深门控：本引擎的碰撞只有一个平面（玩家 depth_y 只改绘制偏移，碰撞体固定在 GROUND_Y），
## 所以实体必须自己判断“玩家是否和我站在同一条景深上”，否则要么永远挡不到人、
## 要么把整条路堵死。默认 0 表示不限（非副本场景）。
var actor_depth := 0.0
var lane_tolerance := 0.0
var player_ref: Node2D = null


## 由 Main 在摆好之后调用：传入玩家引用与景深容差，开启“同层才挡人”。
func enable_lane_gate(player_node: Node2D, tolerance: float) -> void:
	player_ref = player_node
	lane_tolerance = maxf(0.0, tolerance)
	refresh_lane_gate()


func refresh_lane_gate() -> void:
	if _collision_body == null:
		return
	var active := true
	if player_ref != null and lane_tolerance > 0.0:
		active = absf(float(player_ref.get("depth_y")) - actor_depth) <= lane_tolerance
	_collision_body.collision_layer = 1 if active else 0


func _physics_process(_delta: float) -> void:
	if lane_tolerance > 0.0 and player_ref != null:
		refresh_lane_gate()


func setup(catalog_entry: Dictionary, asset_root: String, at: Vector2, depth_y: float, with_collision := true) -> void:
	entry = catalog_entry
	# 逐类区分：台账里 collision=false 的（软植被/细杆/拾取物）只做装饰，不挡人
	collision_enabled = with_collision and bool(entry.get("collision", true))
	actor_depth = depth_y
	position = at + Vector2(0, depth_y)
	_build(asset_root)


func _build(asset_root: String) -> void:
	var anchor: Array = entry.get("anchor", [0, 0])
	var anchor_v := Vector2(float(anchor[0]), float(anchor[1]))

	# 影子画在本体之前，稍暗一点，避免踩空感
	var shadow: Dictionary = entry.get("shadow", {})
	if not shadow.is_empty():
		var shadow_tex := _load_texture(asset_root + str(shadow.get("file", "")))
		if shadow_tex != null:
			var sh_anchor: Array = shadow.get("anchor", anchor)
			_shadow = Sprite2D.new()
			_shadow.texture = shadow_tex
			_shadow.centered = false
			_shadow.offset = Vector2(-float(sh_anchor[0]), -float(sh_anchor[1]))
			_shadow.modulate = Color(1, 1, 1, 0.85)
			_shadow.z_index = -1
			add_child(_shadow)

	var body_tex := _load_texture(asset_root + str(entry.get("file", "")))
	if body_tex != null:
		_body = Sprite2D.new()
		_body.texture = body_tex
		_body.centered = false
		_body.offset = -anchor_v
		add_child(_body)

	if collision_enabled:
		var rect := _collision_rect()
		if rect.size.x > 1.0 and rect.size.y > 1.0:
			collision_rect = rect
			_collision_body = StaticBody2D.new()
			var shape := CollisionShape2D.new()
			var box := RectangleShape2D.new()
			box.size = rect.size
			shape.shape = box
			shape.position = rect.position + rect.size * 0.5
			_collision_body.add_child(shape)
			add_child(_collision_body)


## 精准碰撞框：直接用精灵自身的可见矩形。
## 这批实体 PNG 已紧贴裁切（alpha 包围盒就是整张图），所以“物体的范围”＝贴图范围；
## 台账里那张 footprint 只是“建议的地面投影”，仅够摆放参考，不拿来做碰撞。
## 需要特例时用台账的 collision_rect 显式覆盖。
func _collision_rect() -> Rect2:
	var override: Array = entry.get("collision_rect", [])
	if override.size() == 4:
		return Rect2(float(override[0]), float(override[1]), float(override[2]), float(override[3]))
	var size := Vector2.ZERO
	if _body != null and _body.texture != null:
		size = _body.texture.get_size()
	elif entry.has("size"):
		var declared: Array = entry["size"]
		size = Vector2(float(declared[0]), float(declared[1]))
	var anchor: Array = entry.get("anchor", [0, 0])
	return Rect2(-float(anchor[0]), -float(anchor[1]), size.x, size.y)


func _load_texture(path: String) -> Texture2D:
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D


## 前台遮挡用的深度：depth_y > 0 的实体画在角色前面
func apply_actor_order(depth_y: float) -> void:
	z_index = 1 if depth_y > 0.0 else -1
