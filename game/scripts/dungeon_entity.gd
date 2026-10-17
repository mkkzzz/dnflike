class_name DungeonEntity
extends Node2D
## 非生物实体占位实装：影子 + 本体，按台账的脚底锚点对齐。
## 碰撞框由台账的 collision_rect 给出（实测“实心核心”，可逐类覆盖），
## 但**不再使用物理碰撞体**：本引擎的碰撞只有一个平面（演员的 depth_y 只改绘制偏移，
## 碰撞体固定在 GROUND_Y），用开关静态体既会抖动又能被绕过。
## 改为由 Main 用 world_solid_rect() 做代码级阻挡（见 Main._resolve_solids）。
## 美术来自 lowres_release_v1 的实体导出（台账写明 entities preserved，未单独重新批准）。

var entity_id := ""
var entry: Dictionary = {}
## 碰撞框（相对脚底锚点，紧贴物体的实心核心；仅 collision_enabled 时有效）
var collision_rect := Rect2()
var collision_enabled := false
## 脚底所在的景深（相对 GROUND_Y）：阻挡与前后遮挡都以它为准
var actor_depth := 0.0

var _body: Sprite2D
var _shadow: Sprite2D


func setup(catalog_entry: Dictionary, asset_root: String, at: Vector2, depth_y: float, with_collision := true) -> void:
	entry = catalog_entry
	collision_enabled = with_collision and bool(entry.get("collision", true))
	actor_depth = depth_y
	position = at + Vector2(0, depth_y)
	_build(asset_root)


func _build(asset_root: String) -> void:
	var anchor: Array = entry.get("anchor", [0, 0])
	var anchor_v := Vector2(float(anchor[0]), float(anchor[1]))

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
			add_child(_shadow)

	var body_tex := _load_texture(asset_root + str(entry.get("file", "")))
	if body_tex != null:
		_body = Sprite2D.new()
		_body.texture = body_tex
		_body.centered = false
		_body.offset = -anchor_v
		add_child(_body)

	if collision_enabled:
		collision_rect = _resolve_rect(body_tex)


## 优先用台账里显式登记的 collision_rect；没有才退回贴图自身的可见矩形。
func _resolve_rect(body_tex: Texture2D) -> Rect2:
	var declared: Array = entry.get("collision_rect", [])
	if declared.size() == 4:
		return Rect2(float(declared[0]), float(declared[1]), float(declared[2]), float(declared[3]))
	var size := Vector2.ZERO
	if body_tex != null:
		size = body_tex.get_size()
	elif entry.has("size"):
		var s: Array = entry["size"]
		size = Vector2(float(s[0]), float(s[1]))
	var anchor: Array = entry.get("anchor", [0, 0])
	return Rect2(-float(anchor[0]), -float(anchor[1]), size.x, size.y)


## 世界坐标的阻挡矩形
func world_solid_rect() -> Rect2:
	return Rect2(position + collision_rect.position, collision_rect.size)


func _load_texture(path: String) -> Texture2D:
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D
