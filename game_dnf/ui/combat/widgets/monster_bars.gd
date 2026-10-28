extends RefCounted
## Top-of-screen monster HP bar from the original monster_hp.img:
##   normal  frame 1 (+ right cap 8), left aligned
##   elite   frame 9 (+ cap 10), left aligned
##   boss    frame 11 (+ cap 12), centred
## HP lines use frames 2..6 (red, orange, green, blue, purple); the depleted part of the
## current line shows the next line's colour. Face = MOB [face image]; frame 0 marks a kill.
## Layout offsets are read from the frame pixels (face box, bar slot); name/level text is the
## placeholder system font (G24). Line count per boss is E-ADAPT.
const ORDER := 40
const LINE_COLORS := ["f2","f3","f4","f5","f6"]
const STYLES := {
	"normal":{"frame":"f1","cap":"f8","cap_at":Vector2(626,15),"face":Vector2(2,2),"bar":Vector2(28,17),"bar_w":597.0,"name":Vector2(31,12)},
	"elite":{"frame":"f9","cap":"f10","cap_at":Vector2(628,16),"face":Vector2(4,4),"bar":Vector2(35,19),"bar_w":591.0,"name":Vector2(38,13)},
	"boss":{"frame":"f11","cap":"f12","cap_at":Vector2(630,0),"face":Vector2(4,4),"bar":Vector2(33,14),"bar_w":595.0,"name":Vector2(36,11)},
}

func paint(h, s: Dictionary) -> void:
	var bar: Dictionary = s.get("monster_bar",{})
	if bar.is_empty():return
	var rank := String(bar["rank"])
	var st: Dictionary = STYLES.get(rank,STYLES["normal"])
	var total: float = h.mhp_size(st["frame"]).x+h.mhp_size(st["cap"]).x
	var origin := Vector2(roundf((h.canvas_width(s)-total)/2),3) if rank == "boss" else Vector2(3,3)
	h.mhp(st["frame"],origin)
	h.mhp(st["cap"],origin+Vector2(st["cap_at"]))
	h.mhp("face:"+String(bar["mob"]),origin+Vector2(st["face"]))
	if float(bar["hp"]) <= 0:h.mhp("f0",origin+Vector2(st["face"]))
	var lines := maxi(1,int(bar["lines"]))
	var per_line := float(bar["max_hp"])/lines
	var hp := maxf(0,float(bar["hp"]))
	var current := clampi(int(ceil(hp/per_line)),0,lines)
	var bar_at: Vector2 = origin+Vector2(st["bar"])
	var width := float(st["bar_w"])
	if current > 1:h.mhp(LINE_COLORS[(current-2)%LINE_COLORS.size()],bar_at,width)
	if current >= 1:
		var fill := (hp-per_line*(current-1))/per_line
		h.mhp(LINE_COLORS[(current-1)%LINE_COLORS.size()],bar_at,roundf(width*clampf(fill,0,1)))
	var label := "Lv%d  %s" % [int(bar["level"]),String(bar["name"])]
	h.text(origin+Vector2(st["name"]),label,10,Color(1,0.93,0.78))
	if lines > 1 and current > 0:
		h.text(origin+Vector2(st["bar"])+Vector2(width-26,-3),"x%d" % current,10,Color(1,0.93,0.78))
