class_name DungeonEntity
extends Node2D
## 非生物实体占位实装：影子 + 本体，按台账的脚底锚点对齐，可选 ground footprint 碰撞。
## 美术来自 lowres_release_v1 的实体导出（台账写明 entities preserved，未单独重新批准）。

var entity_id := ""
var entry: Dictionary = {}
var footprint: Rect2 = Rect2()

var _body: Sprite2D
var _shadow: Sprite2D
var _body_node: StaticBody2D


func setup(catalog_entry: Dictionary, asset_root: String, at: Vector2, depth_y: float, with_collision := true) -> void:
	entry = catalog_entry
	position = at + Vector2(0, depth_y)
	_build(asset_root, with_collision)


func _build(asset_root: String, with_collision: bool) -> void:
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

	if with_collision:
		var rect: Array = entry.get("footprint", [])
		if rect.size() == 4:
			footprint = Rect2(float(rect[0]), float(rect[1]), float(rect[2]), float(rect[3]))
			_body_node = StaticBody2D.new()
			var shape := CollisionShape2D.new()
			var box := RectangleShape2D.new()
			box.size = footprint.size
			shape.shape = box
			shape.position = footprint.position + footprint.size * 0.5
			_body_node.add_child(shape)
			add_child(_body_node)


func _load_texture(path: String) -> Texture2D:
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D


## 前台遮挡用的深度：depth_y > 0 的实体画在角色前面
func apply_actor_order(depth_y: float) -> void:
	z_index = 1 if depth_y > 0.0 else -1
