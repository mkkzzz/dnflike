class_name BattleFX
extends Node2D
## 战斗表现管理：命中停帧 / 震屏 / 伤害跳字（数字与中文均需字体，由 Main 注入）

var freeze := 0
var shake := 0.0
var camera: Camera2D
var number_font: Font
var pool: Array[Label] = []
var log_hits := 0

func hitstop(frames: int) -> void:
	freeze = maxi(freeze, frames)

func add_shake(amount: float) -> void:
	shake = maxf(shake, amount)

func spawn_number(world_pos: Vector2, text: String, color: Color, size := 18) -> void:
	var lb := _take_label()
	lb.text = text
	lb.add_theme_font_size_override("font_size", size)
	lb.add_theme_color_override("font_color", color)
	lb.position = world_pos + Vector2(randf_range(-8, 8), -40)
	lb.scale = Vector2(1.6, 1.6)
	lb.modulate.a = 1.0
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(lb, "position:y", lb.position.y - 46.0, 0.55).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(lb, "scale", Vector2(1.0, 1.0), 0.12)
	tw.chain().tween_property(lb, "modulate:a", 0.0, 0.25).set_delay(0.2)
	tw.chain().tween_callback(_recycle.bind(lb))

func _take_label() -> Label:
	for lb in pool:
		if not lb.visible:
			lb.visible = true
			return lb
	var lb := Label.new()
	lb.z_index = 50
	if number_font:
		lb.add_theme_font_override("font", number_font)
	lb.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	lb.add_theme_constant_override("outline_size", 4)
	add_child(lb)
	pool.append(lb)
	return lb

func _recycle(lb: Label) -> void:
	lb.visible = false

func _process(_delta: float) -> void:
	_update_fx(_delta)
	if camera == null:
		return
	if shake > 0.2:
		camera.offset = Vector2(randf_range(-1, 1), randf_range(-0.5, 0.5)) * shake
		shake *= 0.82
	else:
		shake = 0.0
		camera.offset = Vector2.ZERO


# ============================================================ 刀光 / 冲击波 / 发光
# preview(render_preview.py) 里 draw_trails() / crescent_poly() / add_glow() / 粒子 的实机对应实现。
# 攻击特效只在 BattleFX 里画，player.gd / monster.gd 不要重复画一遍。
# 调用方：在攻击判定帧 spawn_*，其余生命周期由本文件负责。

## 拖尾存活秒数 —— 对齐 preview 的 4.5 帧 @60fps 量级。
## 太长会糊成实心扇面，太短则刀光读不出来。
const TRAIL_LIFE := 0.10
const TRAIL_MAX := 14

var _trails: Array = []    # {p0, p1, t}
var _slashes: Array = []   # {pos, facing, r, arc, th, col, t, life}
var _glows: Array = []     # {pos, r, col, t, life}
var _parts: Array = []     # {pos, vel, col, t, life, grav}

## 剑刃轨迹采样点（base = 护手, tip = 剑尖），每帧调用一次形成刀光带
func spawn_trail(base: Vector2, tip: Vector2) -> void:
	_trails.append({"p0": base, "p1": tip, "t": 0.0})
	if _trails.size() > TRAIL_MAX:
		_trails.pop_front()

## 弯月刀光：大范围斩击/十字斩/地裂波
func spawn_slash(pos: Vector2, facing: int, radius := 96.0, arc_deg := 150.0,
		thickness := 30.0, col := Color(0.45, 0.72, 1.0)) -> void:
	_slashes.append({"pos": pos, "facing": facing, "r": radius, "arc": deg_to_rad(arc_deg),
		"th": thickness, "col": col, "t": 0.0, "life": 0.18})

## 加色发光团：左臂暗红火焰 / 技能蓄力 / 火把
func spawn_glow(pos: Vector2, radius := 40.0, col := Color(1.0, 0.3, 0.28), life := 0.25) -> void:
	_glows.append({"pos": pos, "r": radius, "col": col, "t": 0.0, "life": life})

## 命中火花（朝 dir 方向溅射）
func spawn_sparks(pos: Vector2, dir: int = 1, count := 7) -> void:
	for i in count:
		var a := randf_range(-1.1, 1.1)
		var sp := randf_range(140.0, 340.0)
		_parts.append({"pos": pos, "vel": Vector2(cos(a) * sp * float(dir), sin(a) * sp - 70.0),
			"col": Color(1.0, 0.93, 0.62), "t": 0.0, "life": randf_range(0.16, 0.32), "grav": 900.0})

## 落地/起跳尘土
func spawn_dust(pos: Vector2, count := 5) -> void:
	for i in count:
		_parts.append({"pos": pos + Vector2(randf_range(-11.0, 11.0), 0.0),
			"vel": Vector2(randf_range(-70.0, 70.0), randf_range(-95.0, -30.0)),
			"col": Color(0.72, 0.68, 0.62), "t": 0.0, "life": randf_range(0.24, 0.44), "grav": 120.0})

## 命中表现一站式入口：停帧 + 震屏 + 跳字 + 火花 + 重击刀光。
## 调用方只需传命中信息，避免各脚本各画一套导致表现不一致。
func on_hit(world_pos: Vector2, dir: int, damage: float, hit: Dictionary) -> void:
	hitstop(int(hit.get("hitstop", 4)))
	add_shake(float(hit.get("shake", 2)))
	spawn_number(world_pos + Vector2(0, -100), str(roundi(damage)),
		Color(1.0, 0.9, 0.3), 20)
	spawn_sparks(world_pos, dir, 8)
	var kind := String(hit.get("kind", ""))
	if kind == "knock" or kind == "launch":
		spawn_slash(world_pos, dir, 124.0, 155.0, 36.0, Color(0.50, 0.75, 1.0))

## 挥砍轨迹采样：攻击判定附近每帧调用，生成刀光带。
## Godot 侧没有骨骼，按「肩 → 剑尖」近似剑刃位置；swing01 为这一刀 0→1 的进度。
func on_swing(pos: Vector2, facing: int, swing01: float, reach := 78.0) -> void:
	var shoulder := pos + Vector2(0.0, -92.0)
	var a := lerpf(-2.3, 0.7, clampf(swing01, 0.0, 1.0))
	var dx := cos(a) * float(facing)
	var dy := sin(a)
	spawn_trail(shoulder + Vector2(dx * 0.35 * reach, dy * 0.35 * reach),
		shoulder + Vector2(dx * reach, dy * reach))

func clear_fx() -> void:
	_trails.clear()
	_slashes.clear()
	_glows.clear()
	_parts.clear()
	queue_redraw()

func _update_fx(delta: float) -> void:
	# 注意：Node2D 的 _draw 结果会被缓存并每帧重绘，
	# 所以「本帧还有东西」和「本帧刚清空」都必须 queue_redraw，否则残影会留在屏幕上。
	var had := not (_trails.is_empty() and _slashes.is_empty() and _glows.is_empty() and _parts.is_empty())
	for arr in [_trails, _slashes, _glows, _parts]:
		var i: int = arr.size() - 1
		while i >= 0:
			var e: Dictionary = arr[i]
			e["t"] = e["t"] + delta
			var life: float = e.get("life", TRAIL_LIFE)
			if e["t"] >= life:
				arr.remove_at(i)
			i -= 1
	for e in _parts:
		e["vel"] = (e["vel"] as Vector2) + Vector2(0.0, e["grav"] * delta)
		e["pos"] = (e["pos"] as Vector2) + (e["vel"] as Vector2) * delta
		e["vel"] = (e["vel"] as Vector2) * 0.94
	if had:
		queue_redraw()

func _draw() -> void:
	# --- 刀光带：三层（宽淡外层 → 中层 → 白芯），与 preview 的 draw_trails 一致
	var n := _trails.size()
	for i in range(1, n):
		var a: Dictionary = _trails[i - 1]
		var b: Dictionary = _trails[i]
		var k := clampf(1.0 - maxf(a["t"], b["t"]) / TRAIL_LIFE, 0.0, 1.0)
		if k <= 0.0:
			continue
		var ab: Vector2 = a["p0"]
		var at: Vector2 = a["p1"]
		var bb: Vector2 = b["p0"]
		var bt: Vector2 = b["p1"]
		_quad(ab, at, bt, bb, Color(0.27, 0.47, 1.0, 0.62 * k))          # 外层
		_quad(ab.lerp(at, 0.25), at.lerp(ab, 0.25), bt.lerp(bb, 0.25), bb.lerp(ab, 0.25),
			Color(0.67, 0.80, 1.0, 0.80 * k))                            # 中层
		_quad(ab.lerp(at, 0.45), at.lerp(ab, 0.45), bt.lerp(bb, 0.45), bb.lerp(ab, 0.45),
			Color(1.0, 1.0, 1.0, 0.95 * k))                              # 白芯

	# --- 弯月刀光
	for s in _slashes:
		var u: float = clampf(s["t"] / s["life"], 0.0, 1.0)
		var k2 := 1.0 - u
		var col: Color = s["col"]
		col.a = 0.85 * k2
		var r: float = s["r"] * (0.72 + 0.28 * u)
		_crescent(s["pos"], float(s["facing"]), r, s["arc"], s["th"] * (1.0 - 0.35 * u), col)

	# --- 发光团：同心圆近似加色辉光
	for g in _glows:
		var u2: float = clampf(g["t"] / g["life"], 0.0, 1.0)
		var gc: Color = g["col"]
		var rr: float = g["r"] * (0.85 + 0.5 * u2)
		for ring in range(4, 0, -1):
			var f := float(ring) / 4.0
			var c := gc
			c.a = 0.16 * (1.0 - u2) * (1.0 - f + 0.35)
			draw_circle(g["pos"], rr * f, c)

	# --- 粒子
	for p in _parts:
		var u3: float = clampf(p["t"] / p["life"], 0.0, 1.0)
		var pc: Color = p["col"]
		pc.a = 1.0 - u3
		draw_circle(p["pos"], maxf(1.0, 3.0 * (1.0 - u3 * 0.6)), pc)

func _quad(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, col: Color) -> void:
	draw_colored_polygon(PackedVector2Array([p0, p1, p2, p3]), col)

## 弯月形：外弧与内弧之间填充，朝 facing 方向开口
func _crescent(center: Vector2, facing: float, radius: float, arc: float,
		thickness: float, col: Color) -> void:
	var steps := 14
	var outer := PackedVector2Array()
	var inner := PackedVector2Array()
	var base := -arc * 0.5
	for i in range(steps + 1):
		var t := base + arc * float(i) / float(steps)
		var dir := Vector2(cos(t) * facing, sin(t))
		outer.append(center + dir * radius)
		inner.append(center + dir * maxf(2.0, radius - thickness))
	inner.reverse()
	outer.append_array(inner)
	draw_colored_polygon(outer, col)
