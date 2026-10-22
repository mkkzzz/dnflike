extends Node2D
## Combat HUD root. Painters in ui/combat/widgets/ are discovered automatically and drawn
## in ascending ORDER on this single canvas item. Adding a widget = adding one file.
## Placeholders still drawn here (system font, program rectangles) are listed in
## docs/tasks/design_tasks/ws1_combat_fidelity_gaps_v1.md and must be replaced, not extended.
const WIDGET_DIR := "res://ui/combat/widgets"

var font: SystemFont
var atlas: Texture2D
var items: Dictionary = {}
var painters: Array = []
var state: Dictionary = {}
## Every draw call of the last frame, for headless equivalence checks.
var trace: Array = []

func setup(ui_assets: Dictionary) -> void:
	font = SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei UI","Microsoft YaHei","Noto Sans CJK SC"])
	font.font_weight = 500
	atlas = load(String(ui_assets["texture"])) as Texture2D
	items = ui_assets["items"]
	painters = discover(WIDGET_DIR)

static func discover(dir_path: String) -> Array:
	var found: Array = []
	for file: String in DirAccess.get_files_at(dir_path):
		var name := file.trim_suffix(".remap")
		if not name.ends_with(".gd"):continue
		found.append(load(dir_path.path_join(name)).new())
	found.sort_custom(func(a, b) -> bool: return a.ORDER < b.ORDER)
	return found

func present(s: Dictionary) -> void:
	state = s
	queue_redraw()

func _draw() -> void:
	trace.clear()
	if state.is_empty() or atlas == null:return
	for painter in painters:
		painter.paint(self,state)

func rect(r: Rect2,c: Color,filled := true) -> void:
	trace.append(["r",str(r),str(c),filled])
	draw_rect(r,c,filled)

func region(dest: Rect2,src: Rect2) -> void:
	trace.append(["g",str(dest),str(src)])
	draw_texture_rect_region(atlas,dest,src)

func text(point: Vector2,value: String,size := 12,color := Color(0.93,0.91,0.79)) -> void:
	trace.append(["t",str(point),value,size,str(color)])
	draw_string(font,point+Vector2(1,1),value,HORIZONTAL_ALIGNMENT_LEFT,-1,size,Color(0.02,0.03,0.03,0.95))
	draw_string(font,point,value,HORIZONTAL_ALIGNMENT_LEFT,-1,size,color)

func piece(key: String,point: Vector2,fill := 1.0) -> void:
	var item: Dictionary = items.get(key,{})
	if item.is_empty():return
	var r: Array = item["rect"]
	var h := float(r[3])*clampf(fill,0,1)
	var missing := float(r[3])-h
	region(Rect2(point+Vector2(0,missing),Vector2(float(r[2]),h)),Rect2(float(r[0]),float(r[1])+missing,float(r[2]),h))

func item_rect(key: String) -> Array:
	return items[key]["rect"]
