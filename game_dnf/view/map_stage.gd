extends Node2D
## Room backdrop from the original Lorien maps (tools/export_dnf_map.py -> dnf_native_map/1):
## parallax background layers, tile strip, map animations/objects and path gates, all drawn by
## scripts/native_map_loader.gd. The simulation's ground y is the map y, so the map root sits at
## y = -screen_y_offset (map screen_y = map_y + offset - z).
const Loader = preload("res://scripts/native_map_loader.gd")
const VIEW_WIDTH := 640.0

var loader
var root: Node2D
var room_index := -1
var cleared := false
var debug_collision := false
var walk_grid: Array = []
var room_width := VIEW_WIDTH
var _placement := ""
var _open := false

func setup(map_loader) -> void:
	loader = map_loader

## info: {placement, cleared}
func show_room(info: Dictionary) -> void:
	var placement := String(info.get("placement",""))
	if placement != _placement:
		_placement = placement
		if root != null:root.queue_free()
		root = null
		for p: Dictionary in loader.placements():
			if String(p["id"]) == placement:
				root = loader.build(p)
				root.position.y = -float(loader.constants()["screen_y_offset"])
				add_child(root)
				var room: Dictionary = loader.room(String(p["map"]))
				walk_grid = room["walk_grid"]
				room_width = float(room["width"])
		_open = false
	var open := bool(info.get("cleared",false))
	cleared = open
	room_index = int(info.get("room_index",-1))
	if root != null and open != _open:
		_open = open
		loader.set_gates_open(root,open)
	queue_redraw()

func camera_for(player_x: float) -> float:
	return clampf(player_x-VIEW_WIDTH/2,0.0,maxf(0.0,room_width-VIEW_WIDTH))

func apply_camera(camera_x: float) -> void:
	if root != null:loader.apply_camera(root,camera_x)

func _draw() -> void:
	if not debug_collision or walk_grid.is_empty():return
	var k: Dictionary = loader.constants()
	var cw := float(k["cell_width"])
	var ch := float(k["cell_height"])
	for r in walk_grid.size():
		var row: Array = walk_grid[r]
		for c in row.size():
			if int(row[c]) != 0:draw_rect(Rect2(c*cw,r*ch,cw-1,ch-1),Color(1,0.3,0.3,0.25),false)
