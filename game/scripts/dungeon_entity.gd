class_name DungeonEntity
extends Node2D
## 根部占地与遮挡前缘均以贴图脚底锚点为原点。

var geometry: Dictionary = {}
var footprints: Array[PackedVector2Array] = []
var occlusion_front := PackedVector2Array()
var debug_geometry := false
var render_slices: Array[Sprite2D] = []

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
			_shadow.z_as_relative = false
			_shadow.z_index = int(GameConfig.runtime["layering"]["ground_shadow_z"])
			add_child(_shadow)

	var body_tex := _load_texture(asset_root + str(entry.get("file", "")))
	if body_tex != null:
		_body = Sprite2D.new()
		_body.texture = body_tex
		_body.centered = false
		_body.offset = -anchor_v
		add_child(_body)

	geometry = GameConfig.entity_geometry.get(entity_id, {})
	if geometry.is_empty():
		push_error("[DUNGEON] missing entity geometry: " + entity_id)
		collision_enabled = false
		return
	footprints.clear()
	for points in geometry.get("footprints", []):
		var polygon := PackedVector2Array()
		for point in points:
			polygon.append(Vector2(float(point[0]), float(point[1])))
		if polygon.size() < 3:
			push_error("[DUNGEON] invalid footprint: " + entity_id)
			collision_enabled = false
			return
		for index in polygon.size():
			var a := polygon[(index + 1) % polygon.size()] - polygon[index]
			var b := polygon[(index + 2) % polygon.size()] - polygon[(index + 1) % polygon.size()]
			if a.cross(b) < 0.0:
				push_error("[DUNGEON] footprint must be clockwise convex: " + entity_id)
				collision_enabled = false
				return
		footprints.append(polygon)
	for point in geometry.get("occlusion_front", []):
		occlusion_front.append(Vector2(float(point[0]), float(point[1])))
	if collision_enabled:
		var minimum := Vector2.INF
		var maximum := -Vector2.INF
		for polygon in footprints:
			for point in polygon:
				minimum = minimum.min(point)
				maximum = maximum.max(point)
		collision_rect = Rect2(minimum, maximum - minimum)
	_build_render_slices(body_tex, anchor_v)


func _build_render_slices(texture: Texture2D, anchor: Vector2) -> void:
	if texture == null:
		return
	_body.visible = false
	var width := int(GameConfig.runtime["layering"]["entity_slice_width"])
	for x in range(0, texture.get_width(), width):
		var slice := Sprite2D.new()
		slice.texture = texture
		slice.centered = false
		slice.region_enabled = true
		var size := mini(width, texture.get_width() - x)
		slice.region_rect = Rect2(x, 0, size, texture.get_height())
		slice.offset = Vector2(float(x), 0.0) - anchor
		slice.z_as_relative = false
		slice.set_meta("ground_x", position.x + float(x) + float(size) * 0.5 - anchor.x)
		add_child(slice)
		render_slices.append(slice)


func world_footprints() -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	for polygon in footprints:
		var world := PackedVector2Array()
		for point in polygon:
			world.append(point + Vector2(position.x, actor_depth))
		result.append(world)
	return result


func front_depth_at(world_x: float) -> float:
	var x := world_x - position.x
	if occlusion_front.is_empty():
		return actor_depth
	for index in range(occlusion_front.size() - 1):
		var a := occlusion_front[index]
		var b := occlusion_front[index + 1]
		if x >= a.x and x <= b.x:
			return actor_depth + lerpf(a.y, b.y, inverse_lerp(a.x, b.x, x))
	return actor_depth + (occlusion_front[0].y if x < occlusion_front[0].x else occlusion_front[-1].y)


func world_solid_rect() -> Rect2:
	return Rect2(Vector2(position.x, actor_depth) + collision_rect.position, collision_rect.size)


func _draw() -> void:
	if not debug_geometry:
		return
	for polygon in footprints:
		var closed := polygon.duplicate()
		closed.append(polygon[0])
		draw_polyline(closed, Color(1.0, 0.25, 0.1) if collision_enabled else Color(0.3, 0.8, 1.0), 2.0)
	if occlusion_front.size() > 1:
		draw_polyline(occlusion_front, Color(1.0, 0.9, 0.1), 3.0)


func _load_texture(path: String) -> Texture2D:
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D
