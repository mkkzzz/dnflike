extends RefCounted
## Bottom bar: HP/MP orbs, class/weapon, skill slots, key hints.
## Placeholders G05/G06 (cropped source bar, system font, text skill slots).
## Laid out from the canvas given by the view (800×600), bottom-anchored.
const ORDER := 60
var chrome := true
const WEAPON_NAMES := {"shortsword":"短剑","katana":"太刀","greatsword":"巨剑"}

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
		var point := Vector2(172+i*52,top+13)
		h.piece("hud_37",point)
		var cd := float(skill["cooldown"])
		if cd>0:h.rect(Rect2(point+Vector2(5,5),Vector2(38,38)),Color(0,0,0,0.62))
		h.text(point+Vector2(3,2),String(skill["key"]),9,Color(0.92,0.82,0.52))
		h.text(point+Vector2(5,27),String(skill["label"]),10)
		if cd>0:h.text(point+Vector2(15,41),"%.1f"%cd,10,Color.WHITE)
	h.text(Vector2(437,top+21),"X 普攻  C 跳跃",10)
	h.text(Vector2(437,top+38),"↓+C 后跳  G 格挡",10)
	h.text(Vector2(437,top+55),"F1 操作说明",9,Color(0.62,0.67,0.62))
