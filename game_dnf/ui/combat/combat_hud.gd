extends Node2D
## Combat HUD root. Painters in ui/combat/widgets/ are discovered automatically and drawn
## in ascending ORDER on this single canvas item. Adding a widget = adding one file.
## Placeholders still drawn here (system font, program rectangles) are listed in
## docs/tasks/design_tasks/ws1_combat_fidelity_gaps_v1.md and must be replaced, not extended.
const WIDGET_DIR := "res://ui/combat/widgets"

var font: SystemFont
var atlas: Texture2D
var items: Dictionary = {}
var digit_atlas: Texture2D
var digits: Dictionary = {}
var mhp_atlas: Texture2D
var mhp_items: Dictionary = {}
var painters: Array = []
var state: Dictionary = {}
## A flow root that draws its own HUD hides the "chrome" widgets (bottom bar, room info,
## minimap, notices, overlay); combat feedback (numbers, combo, monster HP) stays visible.
var chrome_visible := true
## Every draw call of the last frame, for headless equivalence checks.
var trace: Array = []

func setup(ui_assets: Dictionary, digit_bank := {}, monster_hp_bank := {}) -> void:
	font = SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei UI","Microsoft YaHei","Noto Sans CJK SC"])
	font.font_weight = 500
	atlas = load(String(ui_assets["texture"])) as Texture2D
	items = ui_assets["items"]
	if not digit_bank.is_empty():
		digit_atlas = load(String(digit_bank["texture"])) as Texture2D
		digits = digit_bank["items"]
	if not monster_hp_bank.is_empty():
		mhp_atlas = load(String(monster_hp_bank["texture"])) as Texture2D
		mhp_items = monster_hp_bank["items"]
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

## 画布宽度由视图给出（view/world_frame.gd 的 800×600），控件不再写死 640。
func canvas_width(s: Dictionary) -> float:
	return float(s.get("width",640.0))

func canvas_height(s: Dictionary) -> float:
	return float(s.get("height",360.0))

func _draw() -> void:
	trace.clear()
	if state.is_empty() or atlas == null:return
	for painter in painters:
		if not chrome_visible and painter.get("chrome") == true:continue
		painter.paint(self,state)

## Piece of the original monster HP bar image (sprite/interface/newstyle/windows/monster_hp).
## width < 0 draws the full frame; otherwise the frame is cut to that many pixels from the left.
func mhp(key: String, point: Vector2, width := -1.0) -> void:
	var item: Dictionary = mhp_items.get(key,{})
	if item.is_empty() or mhp_atlas == null:return
	var r: Array = item["rect"]
	var w := float(r[2]) if width < 0 else clampf(width,0,float(r[2]))
	if w <= 0:return
	var o: Array = item["offset"]
	var dest := Rect2(point+Vector2(float(o[0]),float(o[1])),Vector2(w,float(r[3])))
	trace.append(["m",key,str(dest)])
	draw_texture_rect_region(mhp_atlas,dest,Rect2(float(r[0]),float(r[1]),w,float(r[3])))

func mhp_size(key: String) -> Vector2:
	var item: Dictionary = mhp_items.get(key,{})
	return Vector2.ZERO if item.is_empty() else Vector2(float(item["rect"][2]),float(item["rect"][3]))

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

## Original bitmap glyph from sprite/common/etc/combo.img (key e.g. "damage_7", "combo_label_0").
## Returns the glyph width so callers can lay out strings.
func glyph(key: String, point: Vector2, alpha := 1.0) -> float:
	var item: Dictionary = digits.get(key,{})
	if item.is_empty() or digit_atlas == null:return 0.0
	var r: Array = item["rect"]
	var o: Array = item["offset"]
	var dest := Rect2(point+Vector2(float(o[0]),float(o[1])),Vector2(float(r[2]),float(r[3])))
	trace.append(["d",key,str(dest),snappedf(alpha,0.001)])
	draw_texture_rect_region(digit_atlas,dest,Rect2(float(r[0]),float(r[1]),float(r[2]),float(r[3])),Color(1,1,1,alpha))
	return float(r[2])

func glyph_width(key: String) -> float:
	var item: Dictionary = digits.get(key,{})
	return float(item["rect"][2]) if not item.is_empty() else 0.0

## Draws an integer with a digit style; anchor is the centre-left/right/centre per `align`.
func number(style: String, value: int, point: Vector2, alpha := 1.0, align := 0) -> float:
	var text := str(value)
	var width := 0.0
	for c in text:width += glyph_width(style+"_"+c)-2
	var x := point.x-(width*0.5 if align == 0 else width if align > 0 else 0.0)
	for c in text:x += glyph(style+"_"+c,Vector2(x,point.y),alpha)-2
	return width
