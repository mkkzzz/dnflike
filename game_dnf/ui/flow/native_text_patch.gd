extends Node2D
## Presentation-only repair: repeat a known blank native texture crop at 1:1.
## Original IMG/PNG bytes and frames stay unchanged for provenance and rollback.
var source: Texture2D
var crop: Rect2
var extent: Vector2

static func attach(parent: Node, tex: Texture2D, source_rect: Rect2, target_rect: Rect2):
	var patch = load("res://ui/flow/native_text_patch.gd").new()
	patch.source = tex
	patch.crop = source_rect
	patch.extent = target_rect.size
	patch.position = target_rect.position
	parent.add_child(patch)
	return patch

func _draw() -> void:
	for y in range(0, int(extent.y), int(crop.size.y)):
		for x in range(0, int(extent.x), int(crop.size.x)):
			var size := Vector2(minf(crop.size.x, extent.x - x), minf(crop.size.y, extent.y - y))
			draw_texture_rect_region(source, Rect2(Vector2(x, y), size), Rect2(crop.position, size))
