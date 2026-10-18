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

## 可破坏物（配置来自 entity_catalog.<id>.destructible，缺省即不可破坏）
## 破坏表现用「把 intact 贴图切格后抛散」实现，因此不需要额外的 debris 美术资源；
## 若有 entities/<id>/debris.png，会作为残骸留在原地（见 _leave_debris）。
var destructible := false
var destroyed := false
var hits_left := 1
var _destruct_cfg: Dictionary = {}
var _fx: Node = null
var _fragments: Array = []
var _destroy_t := 0.0
var _destroy_life := 0.0
var _rng := RandomNumberGenerator.new()


func setup(catalog_entry: Dictionary, asset_root: String, at: Vector2, depth_y: float, with_collision := true) -> void:
	entry = catalog_entry
	collision_enabled = with_collision and bool(entry.get("collision", true))
	actor_depth = depth_y
	position = at + Vector2(0, depth_y)
	_rng.randomize()
	_destruct_cfg = entry.get("destructible", {})
	destructible = not _destruct_cfg.is_empty()
	hits_left = maxi(1, int(_destruct_cfg.get("hits", 1)))
	_build(asset_root)
	set_process(destructible)


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


# ---------------------------------------------------------------- 可破坏物

## 由 main 注入 BattleFX，用于播破坏音效、尘土与震屏（不注入则静默）。
func bind_fx(fx: Node) -> void:
	_fx = fx


## 视觉包围盒（世界坐标）：Sprite2D 以 -anchor 为绘制偏移，左上角即 position - anchor。
func world_hit_rect() -> Rect2:
	if _body == null or _body.texture == null:
		return Rect2()
	var anchor: Array = entry.get("anchor", [0, 0])
	var size := _body.texture.get_size()
	return Rect2(Vector2(position.x - float(anchor[0]), position.y - float(anchor[1])), size)


## 受击：返回 true 表示这一下把它打碎了。
func take_hit(damage: float, from_dir: int) -> bool:
	if not destructible or destroyed:
		return false
	hits_left -= 1
	if hits_left > 0:
		_flash_hit()
		return false
	_shatter(from_dir)
	return true


func _flash_hit() -> void:
	for slice in render_slices:
		if not is_instance_valid(slice):
			continue
		var tween := create_tween()
		tween.tween_property(slice, "modulate", Color(1.7, 1.4, 1.2, 1.0), 0.05)
		tween.tween_property(slice, "modulate", Color.WHITE, 0.14)


## 破坏表现：把 intact 贴图切成 columns×rows 块抛散（不需要额外 debris 美术）。
## 每块独立初速、重力、自转与淡出，全部结束后释放。
func _shatter(from_dir: int) -> void:
	destroyed = true
	collision_enabled = false
	var cfg: Dictionary = _destruct_cfg.get("debris", {})
	var columns := maxi(1, int(cfg.get("columns", 4)))
	var rows := maxi(1, int(cfg.get("rows", 3)))
	var scatter := float(cfg.get("scatter", 120.0))
	var rise := float(cfg.get("rise", 90.0))
	var gravity := float(cfg.get("gravity", 620.0))
	var spin := float(cfg.get("spin", 220.0))
	_destroy_life = maxf(0.12, float(cfg.get("life", 0.55)))
	_destroy_t = 0.0
	var texture: Texture2D = _body.texture if _body != null else null
	var anchor: Array = entry.get("anchor", [0, 0])
	var anchor_v := Vector2(float(anchor[0]), float(anchor[1]))
	if texture != null:
		var size := texture.get_size()
		var cell := Vector2(size.x / float(columns), size.y / float(rows))
		for row in rows:
			for column in columns:
				var fragment := Sprite2D.new()
				fragment.texture = texture
				fragment.centered = false
				fragment.region_enabled = true
				fragment.region_rect = Rect2(Vector2(column * cell.x, row * cell.y), cell)
				fragment.offset = Vector2(column * cell.x, row * cell.y) - anchor_v
				fragment.z_as_relative = false
				fragment.z_index = int(GameConfig.runtime["layering"]["actor_base_z"])
				add_child(fragment)
				var center := Vector2(column * cell.x, row * cell.y) + cell * 0.5 - anchor_v
				var outward := signf(center.x) if absf(center.x) > 0.001 else _rng.randf_range(-1.0, 1.0)
				_fragments.append({
					"node": fragment,
					"velocity": Vector2(
						outward * scatter * _rng.randf_range(0.45, 1.0) + float(from_dir) * scatter * 0.35,
						-rise * _rng.randf_range(0.35, 1.0)),
					"spin": _rng.randf_range(-spin, spin) * 0.06,
					"gravity": gravity,
				})
	for slice in render_slices:
		if is_instance_valid(slice):
			slice.visible = false
	render_slices.clear()
	if _body != null:
		_body.visible = false
	if _shadow != null:
		var fade := create_tween()
		fade.tween_property(_shadow, "modulate:a", 0.0, 0.28)
	_leave_debris()
	_emit_feedback(from_dir)


## 可选残骸：entity_catalog.<id>.debris_file 指向一张 PNG 时留在原地（如 bone 堆）。
## 没配就什么都不留——碎片飞散后该物消失。
func _leave_debris() -> void:
	var file := str(entry.get("debris_file", ""))
	if file.is_empty():
		return
	var root := str(entry.get("debris_root", ""))
	var texture := _load_texture(root + file) if not root.is_empty() else _load_texture(file)
	if texture == null:
		return
	var anchor: Array = entry.get("anchor", [0, 0])
	var sprite := Sprite2D.new()
	sprite.texture = texture
	sprite.centered = false
	sprite.offset = -Vector2(float(anchor[0]), float(anchor[1]))
	sprite.z_as_relative = false
	sprite.z_index = int(GameConfig.runtime["layering"]["actor_base_z"])
	add_child(sprite)


func _emit_feedback(from_dir: int) -> void:
	if _fx == null:
		return
	var sound := str(_destruct_cfg.get("sound", ""))
	if not sound.is_empty():
		_fx.call("play_sound", sound, position.x, 1.0)
	var dust := int(_destruct_cfg.get("dust", 0))
	if dust > 0:
		_fx.call("spawn_dust", Vector2(position.x, position.y - 10.0), dust)
	_fx.call("add_shake", float(_destruct_cfg.get("shake", 1.0)), Vector2(float(from_dir), -0.1))


func _process(delta: float) -> void:
	if _fragments.is_empty():
		set_process(false)
		return
	_destroy_t += delta
	var fade_start := _destroy_life * 0.45
	var alpha := 1.0
	if _destroy_t > fade_start:
		alpha = clampf(1.0 - (_destroy_t - fade_start) / maxf(0.01, _destroy_life - fade_start), 0.0, 1.0)
	for item in _fragments:
		var node: Sprite2D = item["node"]
		if not is_instance_valid(node):
			continue
		var velocity: Vector2 = item["velocity"]
		velocity.y += float(item["gravity"]) * delta
		node.position += velocity * delta
		node.rotation += float(item["spin"]) * delta
		node.modulate.a = alpha
		item["velocity"] = velocity
	if _destroy_t >= _destroy_life:
		for item in _fragments:
			if is_instance_valid(item["node"]):
				item["node"].queue_free()
		_fragments.clear()
		set_process(false)
