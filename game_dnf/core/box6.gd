extends RefCounted
## Original ANI six-value boxes: [x, y, z, width, depth, height], relative to the
## entity anchor while facing right. Axis semantics are E-INFER until the F3 overlay
## experiment; this file is the only place that mirrors or converts them.

static func to_world(box: Array, anchor: Vector3, facing: int) -> AABB:
	var x := float(box[0])
	var w := float(box[3])
	if facing < 0:
		x = -(x + w)
	return AABB(anchor + Vector3(x, float(box[1]), float(box[2])), Vector3(w, float(box[4]), float(box[5])))

static func overlaps(a: AABB, b: AABB) -> bool:
	return a.position.x < b.end.x and b.position.x < a.end.x \
		and a.position.y < b.end.y and b.position.y < a.end.y \
		and a.position.z < b.end.z and b.position.z < a.end.z

static func center(box: AABB) -> Vector3:
	return box.position + box.size * 0.5
