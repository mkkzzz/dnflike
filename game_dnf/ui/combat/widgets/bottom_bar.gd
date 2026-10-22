extends RefCounted
## Bottom bar: HP/MP orbs, class/weapon, skill slots, key hints.
## Placeholders G05/G06 (cropped source bar, system font, text skill slots).
const ORDER := 60
const WEAPON_NAMES := {"shortsword":"短剑","katana":"太刀","greatsword":"巨剑"}

func paint(h, s: Dictionary) -> void:
	var p: Dictionary = s["player"]
	# The source HUD's middle section is cropped, not rescaled to a fractional size.
	h.rect(Rect2(0,291,640,69),Color(0.035,0.035,0.04,0.94))
	var r: Array = h.item_rect("hud_0")
	h.region(Rect2(0,291,640,69),Rect2(float(r[0])+80,float(r[1]),640,69))
	h.piece("hud_1",Vector2(10,298),float(p["hp"])/float(p["hp_max"]))
	h.piece("hud_2",Vector2(574,298),float(p["mp"])/float(p["mp_max"]))
	h.text(Vector2(20,329),str(int(p["hp"])),11,Color(1,0.9,0.82))
	h.text(Vector2(584,329),str(int(p["mp"])),11,Color(0.80,0.93,1))
	var berserker: bool = p["job"]=="berserker"
	h.text(Vector2(78,311),"狂战士" if berserker else "剑魂",12,Color(0.96,0.78,0.39))
	h.text(Vector2(78,328),WEAPON_NAMES[p["weapon"]],10)
	if float(p["buff_ms"])>0:h.text(Vector2(78,345),"血怒 %.1f"%(float(p["buff_ms"])/1000),10,Color(1,0.48,0.38))
	var skills: Array = ["upper","buff","rage_slash"] if berserker else ["upper","draw","thrust"]
	var names: Array = ["上挑","血怒","怒斩"] if berserker else ["上挑","拔刀斩","连突刺"]
	for i in 3:
		var point := Vector2(226+i*54,304)
		h.piece("hud_37",point)
		var cd := float(p["cooldowns"].get(skills[i],0))
		if cd>0:h.rect(Rect2(point+Vector2(5,5),Vector2(38,38)),Color(0,0,0,0.62))
		h.text(point+Vector2(3,2),["Z","A","S"][i],9,Color(0.92,0.82,0.52))
		h.text(point+Vector2(7,27),String(names[i]),10)
		if cd>0:h.text(point+Vector2(15,41),"%.1f"%cd,10,Color.WHITE)
	h.text(Vector2(437,312),"X 普攻  C 跳跃",10)
	h.text(Vector2(437,329),"V 后跳  G 格挡",10)
	h.text(Vector2(437,346),"F1 操作说明",9,Color(0.62,0.67,0.62))
