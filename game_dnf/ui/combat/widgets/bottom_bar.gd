extends RefCounted
## Bottom bar: HP/MP orbs, class/weapon, skill slots, key hints.
## G05/G06 remaining gaps are the cropped source bar and procedural cooldown/gain text.
## Laid out from the canvas given by the view (800×600), bottom-anchored.
const ORDER := 60
var chrome := true
const WEAPON_NAMES := {"shortsword":"短剑","katana":"太刀","greatsword":"巨剑"}
var icon_paths: Dictionary = {}
var icon_textures: Dictionary = {}

func skill_icon(id: String) -> Texture2D:
	if id == "":return null
	if icon_paths.is_empty():
		var catalog:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://data/skill_catalog.json"))
		for skill:Dictionary in catalog["skills"]:
			if String(skill["local_id"])!="":icon_paths[String(skill["local_id"])]=String(skill["icon"])
	if not icon_textures.has(id):
		var image:=Image.load_from_file(ProjectSettings.globalize_path("res://assets_local/skill_panel/"+String(icon_paths.get(id,""))))
		icon_textures[id]=ImageTexture.create_from_image(image) if image!=null else null
	return icon_textures[id]

func paint(h, s: Dictionary) -> void:
	var p: Dictionary = s["player"]
	var width: float = h.canvas_width(s)
	var top: float = h.canvas_height(s)-69.0
	# The source HUD's middle section is cropped, not rescaled to a fractional size.
	h.rect(Rect2(0,top,width,69),Color(0.035,0.035,0.04,0.94))
	var r: Array = h.item_rect("hud_0")
	h.region(Rect2(0,top,width,69),Rect2(float(r[0]),float(r[1]),minf(float(r[2]),width),69))
	h.piece("hud_1",Vector2(10,top+7),float(p["hp"])/float(p["hp_max"]))
	h.piece("hud_2",Vector2(width-66,top+7),float(p["mp"])/float(p["mp_max"]))
	h.text(Vector2(20,top+38),str(int(p["hp"])),11,Color(1,0.9,0.82))
	h.text(Vector2(width-56,top+38),str(int(p["mp"])),11,Color(0.80,0.93,1))
	var berserker: bool = p["job"]=="berserker"
	h.text(Vector2(78,top+20),"狂战士" if berserker else "剑魂",12,Color(0.96,0.78,0.39))
	h.text(Vector2(78,top+37),WEAPON_NAMES[p["weapon"]],10)
	if float(p["buff_ms"])>0:h.text(Vector2(78,top+54),"%s %.1f"%[String(p.get("buff_label","")),float(p["buff_ms"])/1000],10,Color(1,0.48,0.38))
	var skills: Array = s.get("skills",[])
	for i in skills.size():
		var skill: Dictionary = skills[i]
		var point := Vector2(172+(i%6)*40,top+34 if i<6 else top+2)
		h.region(Rect2(point,Vector2(30,32)),Rect2(float(r[0])+534,float(r[1])+46,30,32))
		var icon:=skill_icon(String(skill["name"]))
		if icon!=null:
			h.draw_texture(icon,point+Vector2(1,1))
			h.trace.append(["skill_icon",String(skill["name"]),str(point)])
		var cd := float(skill["cooldown"])
		if cd>0:h.rect(Rect2(point+Vector2(3,3),Vector2(22,22)),Color(0,0,0,0.62))
		h.text(point+Vector2(3,27),String(skill["key"]),9,Color(0.92,0.82,0.52))
		if cd>0:h.text(point+Vector2(5,14),"%.1f"%cd,9,Color.WHITE)
	h.text(Vector2(437,top+21),"X 普攻  C 跳跃",10)
	h.text(Vector2(437,top+38),"↓+C 后跳  G 格挡",10)
	h.text(Vector2(437,top+55),"F1 操作说明",9,Color(0.62,0.67,0.62))
