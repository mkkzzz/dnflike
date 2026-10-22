extends RefCounted
## Standalone result / pause / help overlay. Placeholder G14. Settlement belongs to the
## flow side when the scene is externally managed.
const ORDER := 80

func paint(h, s: Dictionary) -> void:
	var o: Dictionary = s["overlay"]
	if o["finished"] and not o["external"]:
		h.rect(Rect2(0,0,640,291),Color(0.02,0.04,0.04,0.67))
		h.text(Vector2(237,135),"地下城通关" if o["victory"] else "挑战失败",26,Color(1,0.81,0.39))
		var rank := "S" if o["damage_taken"]<100 and o["elapsed_ms"]<100000 else "A" if o["damage_taken"]<250 else "B"
		if o["victory"]:h.text(Vector2(222,169),"评价 "+rank+"   用时 %.1f 秒"%(float(o["elapsed_ms"])/1000),14)
		h.text(Vector2(256,204),"R 重新挑战",14,Color(0.8,0.92,0.84))
	elif o["paused"] or o["help"]:
		h.rect(Rect2(100,60,440,205),Color(0.025,0.04,0.035,0.95))
		h.text(Vector2(125,88),"已暂停" if o["paused"] else "操作说明",19,Color(1,0.83,0.45))
		var lines := ["方向键移动 · 同向双击奔跑", "X 普攻三连 / 空中斩 / 跑动攻击", "C 或空格跳跃 · V 后跳 · 按住 G 格挡", "Z 上挑 · A 拔刀斩 · S 三段斩(连按)", "D 十字斩 · F 暴走 · 1 / 2 / 3 切换武器", "清怪后走入通道切房 · 领主房清完结算", "Esc 暂停 · M 静音 · F3 切换窗口尺寸"]
		for i in lines.size():h.text(Vector2(125,112+i*19),lines[i],12)
