extends RefCounted
## Box-vs-box hit judgement (doc 29, F3). Replaces forward-reach/depth thresholds: an attack
## lands only when an attack box and a damage box of the current frames intersect on all axes.
const Box6 = preload("res://core/box6.gd")

## Sim ground position + height -> Box6 anchor (x, depth, height).
static func anchor(pos: Vector2, z: float) -> Vector3:
	return Vector3(pos.x,pos.y,z)

static func world_boxes(boxes: Array, at: Vector3, facing: int) -> Array:
	var out: Array = []
	for b: Array in boxes:out.append(Box6.to_world(b,at,facing))
	return out

## First intersection between two box lists, or an empty Dictionary.
## Returns {"point": Vector3 centre of the overlap volume}.
static func contact(attack: Array, damage: Array) -> Dictionary:
	for a: AABB in attack:
		for d: AABB in damage:
			if Box6.overlaps(a,d):
				var inter := a.intersection(d)
				return {"point":Box6.center(inter)}
	return {}

## Breakable props have a ground footprint and no authored damage box; treat the footprint as
## a box from the ground up to `height` (E-ADAPT, objects are low grass/bushes).
static func prop_box(rect: Rect2, height := 30.0) -> AABB:
	return AABB(Vector3(rect.position.x,rect.position.y,0),Vector3(rect.size.x,rect.size.y,height))
