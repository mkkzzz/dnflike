class_name GroundSpace
extends RefCounted

var solids: Array = []
var bounds := Rect2()
var skin := 0.01
var slide_iterations := 4
## 实体实例 id -> 它的 footprint 多边形，用于破坏后精确摘除
var _entity_polygons: Dictionary = {}

func configure(area: Rect2, settings: Dictionary) -> void:
	bounds = area
	skin = float(settings["skin"])
	slide_iterations = int(settings["slide_iterations"])
	solids.clear()
	_entity_polygons.clear()

func add_entity(entity: DungeonEntity) -> void:
	if entity.collision_enabled:
		var polygons: Array = []
		for polygon in entity.world_footprints():
			solids.append(polygon)
			polygons.append(polygon)
		_entity_polygons[entity.get_instance_id()] = polygons


## 实体被破坏时摘掉它的挡路多边形；不属于阻挡实体则什么都不做。
func remove_entity(entity: DungeonEntity) -> void:
	var id := entity.get_instance_id()
	if not _entity_polygons.has(id):
		return
	for polygon in _entity_polygons[id]:
		solids.erase(polygon)
	_entity_polygons.erase(id)

func resolve(actor: Node2D, start: Vector2, requested: Vector2) -> Vector2:
	var cfg: Dictionary = actor.get("cfg")
	var half := Vector2(float(cfg["collision_half_width"]), float(cfg["collision_half_depth"]))
	var point := _clamp(start)
	for polygon in solids:
		point = _depenetrate(point, polygon, half)
	var remaining := requested - start
	for iteration in slide_iterations:
		if remaining.length_squared() <= skin * skin:
			break
		var earliest := 1.0
		var normal := Vector2.ZERO
		for polygon in solids:
			var hit := _sweep(point, remaining, polygon, half)
			if not hit.is_empty() and float(hit["time"]) < earliest:
				earliest = float(hit["time"])
				normal = hit["normal"]
		if normal == Vector2.ZERO:
			point += remaining
			break
		point += remaining * maxf(0.0, earliest - skin / maxf(skin, remaining.length()))
		if absf(remaining.y) <= skin or absf(remaining.x) <= skin:
			break
		remaining *= 1.0 - earliest
		remaining -= normal * minf(0.0, remaining.dot(normal))
	return _clamp(point)

func _clamp(point: Vector2) -> Vector2:
	return Vector2(clampf(point.x, bounds.position.x, bounds.end.x), clampf(point.y, bounds.position.y, bounds.end.y))

func _planes(polygon: PackedVector2Array, half: Vector2) -> Array:
	var planes: Array = []
	for index in polygon.size():
		var a := polygon[index]
		var b := polygon[(index + 1) % polygon.size()]
		var normal := Vector2((b - a).y, -(b - a).x).normalized()
		var support := absf(normal.x) * half.x + absf(normal.y) * half.y
		planes.append({"normal": normal, "distance": normal.dot(a) + support})
	for normal in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
		var distance := -INF
		for point in polygon:
			distance = maxf(distance, normal.dot(point))
		planes.append({"normal": normal, "distance": distance + absf(normal.x) * half.x + absf(normal.y) * half.y})
	return planes

func _depenetrate(point: Vector2, polygon: PackedVector2Array, half: Vector2) -> Vector2:
	var nearest := INF
	var normal := Vector2.ZERO
	for plane in _planes(polygon, half):
		var n: Vector2 = plane["normal"]
		var penetration := float(plane["distance"]) - n.dot(point)
		if penetration <= 0.0:
			return point
		if penetration < nearest:
			nearest = penetration
			normal = n
	return point + normal * (nearest + skin)

func _sweep(point: Vector2, motion: Vector2, polygon: PackedVector2Array, half: Vector2) -> Dictionary:
	var enter := 0.0
	var exit := 1.0
	var entry_normal := Vector2.ZERO
	for plane in _planes(polygon, half):
		var normal: Vector2 = plane["normal"]
		var distance := float(plane["distance"]) - normal.dot(point)
		var speed := normal.dot(motion)
		if absf(speed) <= 0.000001:
			if distance < 0.0:
				return {}
			continue
		var time := distance / speed
		if speed < 0.0:
			if time >= enter:
				enter = time
				entry_normal = normal
		else:
			exit = minf(exit, time)
		if enter > exit:
			return {}
	if entry_normal == Vector2.ZERO or enter < 0.0 or enter > 1.0 or exit < 0.0:
		return {}
	return {"time": enter, "normal": entry_normal}
