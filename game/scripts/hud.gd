class_name Hud
extends CanvasLayer
## 实机 HUD：与 tools/render_preview.py 的成品级 HUD 对齐。
##
## 分工（单一美术源原则）
## --------------------
## - **静态层**（底板 / 技能格+图标 / 头像 / HP·MP 球底 / 铭牌框 / 小地图）由
##   `tools/bake_hud.py` import `render_preview` 的 `make_icon()` 等函数烘焙成
##   `game/art/hud/*.png`，坐标清单在 `game/art/hud/hud_manifest.json`。
## - **动态层**（分段血条填充 / 名字等级 / 数值 / COMBO / 冷却遮罩 / 球体液面 /
##   按键字母）在本文件按 manifest 给的坐标叠加，不重复描述任何静态美术细节。
##
## 本节点 extends CanvasLayer ⇒ **天生固定在屏幕空间，不随相机滚动**。
## 内部那个 Control 只负责 `_draw`；所有公开接口都在 Hud 上，main.gd 只跟 Hud 打交道。
##
## 坐标约定：preview 的 HUD 直接画在 1280x720（W*S, H*S）画布上，manifest 里的坐标
## **就是实机像素坐标**，不需要再乘 SCALE。实机 viewport 也是 1280x720 ⇒ 1:1 对齐。
##
## main.gd 接线（3 行）：
##     var hud := Hud.new()
##     add_child(hud)
##     hud.set_font(font)          # 中文必须，否则方块
## 之后每帧喂数据即可（不喂就保持上次的值，任何一项缺失都不会报错）。

const DESIGN_W := 1280.0
const DESIGN_H := 720.0
const MANIFEST_PATH := "res://art/hud/hud_manifest.json"
const HUD_DIR := "res://art/hud/"
const DEFAULT_LAYER := 15

# 小地图：点亮"当前房间"用（M2 接入后生效）。缺省值仅在 manifest 缺字段时兜底。
const ROOM_MAP_CELL := 26
const ROOM_MAP_ORIGIN := Vector2(1100, 22)
const ROOM_MAP_ROOMS := [Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1),
	Vector2i(2, 0), Vector2i(3, 0), Vector2i(3, 1)]

# ---------------------------------------------------------------- 布局（来自 manifest）
var manifest: Dictionary = {}
var manifest_ok := false
var panel := {}
var exp_bar := {}
var slot_frames := {}
var slots: Array = []
var orbs := {}
var portrait := {}
var nameplate := {}
var room_map := {}
var hp_layers := {}
var texts: Array = []
var job_names := {}
var static_draw: Array = []          # [{key, pos}] 静态贴图绘制顺序（按 preview build_hud 顺序）
var orb_pos := {}                    # {"hp": Vector2, "mp": Vector2} 球体底盘贴图原点
var orb_glass_pos := {}              # 玻璃高光贴图原点（叠在液面之上）

# ---------------------------------------------------------------- 运行期状态
var target = null                    # 顶部铭牌目标（Monster 或 null）
var combo := 0
var combo_age := 0.0
var combo_flash := 0.0
var job := 0
var player_name := "幽影剑士"
var player_level := 30
var vitals_hp := 0.0
var vitals_hp_max := 0.0
var vitals_mp := 0.0
var vitals_mp_max := 0.0
var room_idx := 0
var room_total := 0
var room_difficulty := ""
var has_room := false
var room_cell := ROOM_MAP_CELL
var room_origin := ROOM_MAP_ORIGIN
var room_cells: Array = []

var font: Font = null
var number_font: Font = null

var _root: Control = null
var _tex := {}
var _slot_tex: Array = []
var _slot_cd: Array = []
var _slot_cd_max: Array = []
var _fallback_warned := false


func _init() -> void:
	layer = DEFAULT_LAYER
	name = "HudLayer"


func _ready() -> void:
	_root = Control.new()
	_root.name = "HudRoot"
	_root.position = Vector2.ZERO
	_root.size = Vector2(DESIGN_W, DESIGN_H)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.draw.connect(_on_root_draw)
	_root.process_mode = Node.PROCESS_MODE_ALWAYS   # HUD 动画不被 hitstop 暂停
	add_child(_root)

	_load_manifest()
	if font == null:
		_load_font()
	_refresh_slot_icons()
	_refresh()


# ---------------------------------------------------------------- manifest / 贴图
func _load_manifest() -> void:
	if not FileAccess.file_exists(MANIFEST_PATH):
		push_warning("[HUD] 缺 %s：先跑 python tools/bake_hud.py（HUD 退化为简易底栏）" % MANIFEST_PATH)
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
	if typeof(data) != TYPE_DICTIONARY:
		push_warning("[HUD] manifest 解析失败：%s" % MANIFEST_PATH)
		return
	manifest = data
	manifest_ok = true

	panel = manifest.get("panel", {})
	exp_bar = manifest.get("exp_bar", {})
	slot_frames = manifest.get("slot_frames", {})
	orbs = manifest.get("orbs", {})
	portrait = manifest.get("portrait", {})
	nameplate = manifest.get("nameplate", {})
	room_map = manifest.get("room_map", {})
	hp_layers = manifest.get("hp_layers", {})
	texts = manifest.get("texts", [])
	job_names = manifest.get("job_names", {})
	# 小地图配置（manifest 优先，缺字段用常量兜底）
	room_cell = int(room_map.get("cell", ROOM_MAP_CELL))
	room_origin = _v2(room_map.get("origin", ROOM_MAP_ORIGIN))
	room_cells.clear()
	for c in room_map.get("rooms", []):
		if c is Array and c.size() >= 2:
			room_cells.append(Vector2i(int(c[0]), int(c[1])))
	if room_cells.is_empty():
		room_cells = ROOM_MAP_ROOMS.duplicate()

	slots = []
	for s in manifest.get("slots", []):
		slots.append(s)
		_slot_cd.append(0.0)
		_slot_cd_max.append(0.0)

	# 静态贴图缓存 + 绘制顺序（与 preview build_hud 的层序一致，先底后上）
	_tex.clear()
	static_draw.clear()
	orb_pos.clear()
	orb_glass_pos.clear()
	for key in ["panel", "exp_bar", "slot_frames", "portrait", "nameplate", "room_map"]:
		var spec: Dictionary = manifest.get(key, {})
		if spec.has("path"):
			_tex[key] = _try_load(str(spec["path"]))
	for kind in orbs.keys():
		var o: Dictionary = orbs[kind]
		_tex["orb_" + str(kind)] = _try_load(str(o.get("base", "")))
		orb_pos[str(kind)] = _v2(o.get("base_pos", [0, 0]))
		_tex["orb_glass_" + str(kind)] = _try_load(str(o.get("glass", "")))
		orb_glass_pos[str(kind)] = _v2(o.get("glass_pos", o.get("base_pos", [0, 0])))

	# 顺序：底板 → 经验条 → 小地图 → 技能格底 → 球体底盘 → 头像 → 铭牌框
	# （球体的**玻璃高光**不在这里，它必须叠在液面之上，见 _on_root_draw）
	for key in ["panel", "exp_bar"]:
		_push_static(key)
	_push_static("room_map")
	_push_static("slot_frames")
	_push_static("orb_hp")
	_push_static("orb_mp")
	_push_static("portrait")
	_push_static("nameplate")


func _push_static(key: String) -> void:
	if _tex.get(key, null) == null:
		return
	var pos := Vector2.ZERO
	if key.begins_with("orb_"):
		pos = orb_pos.get(key.substr(4), Vector2.ZERO)
	else:
		var spec: Dictionary = manifest.get(key, {})
		pos = _v2(spec.get("pos", [0, 0]))
	static_draw.append({"key": key, "pos": pos})


func _try_load(rel: String) -> Texture2D:
	if rel.is_empty():
		return null
	var p := HUD_DIR + rel
	if not ResourceLoader.exists(p):
		return null
	var res := load(p)
	if res is Texture2D:
		return res
	push_warning("[HUD] %s 不是 Texture2D" % p)
	return null


func _load_font() -> void:
	var cands: Array = []
	if manifest.has("fonts"):
		var f: Dictionary = manifest["fonts"]
		for k in ["cn", "num"]:
			for p in f.get(k, []):
				if not cands.has(p):
					cands.append(p)
	for p in ["C:/Windows/Fonts/msyhbd.ttc", "C:/Windows/Fonts/msyh.ttc",
			"C:/Windows/Fonts/simhei.ttf"]:
		if not cands.has(p):
			cands.append(p)
	for p in cands:
		var ff := FontFile.new()
		if ff.load_dynamic_font(p) == OK:
			font = ff
			return
	font = ThemeDB.fallback_font
	push_warning("[HUD] 找不到中文字体，中文会变方块；请调用 hud.set_font(main.font)")


# ---------------------------------------------------------------- 公开接口
func set_font(f: Font) -> void:
	## main.gd 必须调用：把 msyh.ttc 的 FontFile 传进来，否则中文变方块。
	if f == null:
		return
	font = f
	_refresh()


func set_number_font(f: Font) -> void:
	## 可选：数字用 Impact 风格字体（对齐 preview 的 F_NUM）。不设就沿用 set_font 的字体。
	number_font = f
	_refresh()


func set_target(monster) -> void:
	## 顶部中央铭牌显示的目标怪物；传 null 隐藏。任何有 hp/cfg/dead 的对象都能接。
	target = monster
	_refresh()


func set_vitals(hp: float, hp_max: float, mp: float, mp_max: float) -> void:
	## HP/MP 球与球心数值。max 为 0 时按空球兜底，不会除零。
	vitals_hp = hp
	vitals_hp_max = hp_max
	vitals_mp = mp
	vitals_mp_max = mp_max
	_refresh()


func set_combo(c: int) -> void:
	## 连击数。c >= 2 显示（对齐 preview 的 G.combo 显示条件），数值变化时弹一下。
	if c != combo:
		combo_flash = 1.0
	combo = c
	if c > 0:
		combo_age = 0.0
	_refresh()


func set_player_info(name_text: String, level: int = -1, job_id: int = -1) -> void:
	## 角色名 / 等级（左下角头像旁）。level < 0 表示不改。job_id >= 0 时同时切职业图标。
	if not name_text.is_empty():
		player_name = name_text
	if level >= 0:
		player_level = level
	if job_id >= 0:
		set_job(job_id)


func set_job(job_id: int) -> void:
	## 切换职业时刷新 A/S 两格的技能图标（数据来自 data/skills.json 的 slot 字段）。
	if job_id == job and not _slot_tex.is_empty():
		return
	job = job_id
	_refresh_slot_icons()
	_refresh()


func set_room(idx: int, total: int, difficulty: String = "") -> void:
	## 左上角「第 N / M 间 · 难度：X」+ 小地图点亮当前房间。
	## TODO(M2)：M2 房间系统落地后由 main.gd 调用；**不调用时这一行自动隐藏**，
	##           只保留烘焙好的房间名静态文字（"幽暗回廊"），不会报错。
	room_idx = idx
	room_total = total
	room_difficulty = difficulty
	has_room = total > 0
	_refresh()


func clear_room() -> void:
	has_room = false
	_refresh()


func set_cooldowns(slot_to_left: Dictionary, slot_to_total: Dictionary = {}) -> void:
	## 冷却遮罩。key = 技能格下标（0=A 1=S 2=D 3=F 4=G 5=H 6=1 7=2），value = 剩余秒数；
	## slot_to_total 给出该格总冷却秒数（缺省则只画遮罩不画秒数）。
	## 数据源：player.cds / GameConfig.skills[sid].cd（player.cds 是**帧**，除 60 得秒）。
	## TODO(技能表)：M1 只有 A/S 两格有真实冷却数据，其余格子留空占位。
	for i in slots.size():
		_slot_cd[i] = 0.0
		_slot_cd_max[i] = 0.0
	for k in slot_to_left.keys():
		var i := int(k)
		if i < 0 or i >= slots.size():
			continue
		var left := maxf(0.0, float(slot_to_left[k]))
		_slot_cd[i] = left
		_slot_cd_max[i] = maxf(left, float(slot_to_total.get(k, 0.0)))
	_refresh()


func set_data(d: Dictionary) -> void:
	## 便捷入口：一次喂齐所有动态数据（main.gd 用这个最省事）。
	## 支持的 key：target / hp / hp_max / mp / mp_max / combo / job / name / level /
	##             room_idx / room_total / room_difficulty / cooldowns / cooldown_max
	if d.has("target"):
		set_target(d["target"])
	if d.has("hp") or d.has("mp"):
		set_vitals(float(d.get("hp", vitals_hp)), float(d.get("hp_max", vitals_hp_max)),
				float(d.get("mp", vitals_mp)), float(d.get("mp_max", vitals_mp_max)))
	if d.has("combo"):
		set_combo(int(d["combo"]))
	if d.has("name") or d.has("level") or d.has("job"):
		set_player_info(str(d.get("name", player_name)), int(d.get("level", -1)),
				int(d.get("job", -1)))
	if d.has("room_total"):
		set_room(int(d.get("room_idx", 0)), int(d.get("room_total", 0)),
				str(d.get("room_difficulty", "")))
	if d.has("cooldowns"):
		set_cooldowns(d["cooldowns"], d.get("cooldown_max", {}))
	_refresh()


func refresh() -> void:
	## 强制重绘
	_refresh()


# ---------------------------------------------------------------- 内部
func _refresh() -> void:
	if _root != null:
		_root.queue_redraw()


func _process(delta: float) -> void:
	if combo_flash > 0.0:
		combo_flash = maxf(0.0, combo_flash - delta * 8.0)
		_refresh()
	if combo > 0:
		combo_age += delta
		if combo_age > 2.5:
			# 连击 2.5s 无新增后淡出（对齐 preview 的 60 帧窗口）
			combo = 0
			_refresh()


func _v2(a) -> Vector2:
	if a is Vector2:
		return a
	if a is Array and a.size() >= 2:
		return Vector2(float(a[0]), float(a[1]))
	return Vector2.ZERO


func _col(a, dflt: Color) -> Color:
	if a is Array and a.size() >= 3:
		return Color(float(a[0]) / 255.0, float(a[1]) / 255.0, float(a[2]) / 255.0,
				float(a[3]) / 255.0 if a.size() >= 4 else 1.0)
	return dflt


func _mix(a, b, t: float) -> Color:
	## 颜色插值。a/b 既可以是 manifest 里的 [r,g,b(,a)] 数组，也可以是已解析的 Color
	## —— 两处调用都在用（血条传数组、球体液面传 Color），必须都认。
	var ca: Color = a if a is Color else _col(a, Color.WHITE)
	var cb: Color = b if b is Color else _col(b, Color.WHITE)
	return Color(ca.r + (cb.r - ca.r) * t, ca.g + (cb.g - ca.g) * t,
			ca.b + (cb.b - ca.b) * t, ca.a + (cb.a - ca.a) * t)


func _f() -> Font:
	return font if font != null else ThemeDB.fallback_font


func _fn() -> Font:
	return number_font if number_font != null else _f()


func _txt(ci: CanvasItem, pos: Vector2, s: String, size_px: float, anchor: String,
		col: Color, stroke: float, stroke_col: Color, fnt: Font = null) -> void:
	if s.is_empty():
		return
	var fo: Font = fnt if fnt != null else _f()
	var sz := int(round(size_px))
	var w := fo.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, sz).x
	var p := pos
	var asc := fo.get_ascent(sz)
	match anchor:
		"center", "mm", "mc":
			p.x -= w * 0.5
		"right", "rm", "re":
			p.x -= w
		"bl", "lb":
			p.y += asc
		"lm", "ml":
			p.y += (asc - fo.get_descent(sz)) * 0.5
	if stroke > 0.0:
		ci.draw_string_outline(fo, p, s, HORIZONTAL_ALIGNMENT_LEFT, -1, sz,
				int(round(stroke)), stroke_col)
	ci.draw_string(fo, p, s, HORIZONTAL_ALIGNMENT_LEFT, -1, sz, col)


# ---------------------------------------------------------------- 绘制入口
func _on_root_draw() -> void:
	var ci := _root
	if ci == null:
		return
	if not manifest_ok:
		_draw_fallback(ci)
		return

	# 1) 静态层（底板 / 经验条 / 小地图 / 技能格底+图标 / 球底 / 头像 / 铭牌框）
	for it in static_draw:
		var tex: Texture2D = _tex.get(it["key"], null)
		if tex != null:
			ci.draw_texture(tex, it["pos"])
	# 技能图标叠在格框上
	for i in slots.size():
		var t: Texture2D = _slot_tex[i] if i < _slot_tex.size() else null
		if t == null:
			continue
		var s: Dictionary = slots[i]
		ci.draw_texture(t, _v2(s.get("icon_pos", s.get("frame_origin", [0, 0]))))

	# 2) 动态层：球体液面 → 玻璃高光（与 preview draw_orb 的内部顺序一致：
	#    preview 是「球底描边 → 液面 alpha_composite」，实机把描边底盘放在 static_draw 里
	#    先画好，这里补液面，再叠只含高光的透明玻璃层。）
	_draw_orb_liquid(ci, "hp")
	_draw_orb_liquid(ci, "mp")
	for kind in ["hp", "mp"]:
		var g: Texture2D = _tex.get("orb_glass_" + kind, null)
		if g != null:
			ci.draw_texture(g, orb_glass_pos.get(kind, Vector2.ZERO))

	_draw_room(ci)
	_draw_static_texts(ci)
	_draw_target_plate(ci)
	_draw_slot_overlays(ci)
	_draw_orb_values(ci)
	_draw_combo(ci)


# ---------------------------------------------------------------- 静态文字（房间名 / 角色名）
func _draw_static_texts(ci: CanvasItem) -> void:
	for t in texts:
		var d: Dictionary = t
		var id := str(d.get("id", ""))
		var text := str(d.get("text", ""))
		var size_px := float(d.get("size", 16))
		var col := _col(d.get("color"), Color.WHITE)
		var stroke := float(d.get("stroke", 2))
		var scol := _col(d.get("stroke_color"), Color.BLACK)
		if id == "hero_name":
			# 名字/等级用动态数据拼（烘焙时写死的 "Lv.30" 不直接用）
			text = "%s  Lv.%d" % [player_name, player_level]
		_txt(ci, _v2(d.get("pos", [0, 0])), text, size_px, str(d.get("anchor", "tl")),
				col, stroke, scol)


# ---------------------------------------------------------------- 左上角房间信息
func _draw_room(ci: CanvasItem) -> void:
	if has_room:
		# 小地图点亮当前房间（越界自动夹取）。
		# room_origin 是小地图格坐标原点(1100,22)，贴图原点在 (1103,25)，只差 cell_pad=3。
		var cell: Vector2i = room_cells[clampi(room_idx, 0, room_cells.size() - 1)]
		var c := room_origin + Vector2(cell.x, cell.y) * float(room_cell) + Vector2(3, 3)
		ci.draw_rect(Rect2(c, Vector2(room_cell - 6, room_cell - 6)),
				Color(1.0, 0.85, 0.35, 0.9), false, 2.0)
		var s := "第 %d / %d 间" % [room_idx + 1, room_total]
		if not room_difficulty.is_empty():
			s += " · 难度：" + room_difficulty
		_txt(ci, Vector2(26, 52), s, 15.0, "tl", Color(0.784, 0.745, 0.667), 2.0,
				Color(0.078, 0.039, 0.0))
	# TODO(M2)：has_room == false（M2 房间系统未接入）时不画这一行，只留房间名


# ---------------------------------------------------------------- 顶部中央：目标怪物铭牌
func _draw_target_plate(ci: CanvasItem) -> void:
	if target == null or not is_instance_valid(target):
		return
	if bool(target.get("dead")):
		return
	if nameplate.is_empty():
		return
	var cfg: Dictionary = target.get("cfg")
	if cfg == null:
		cfg = {}
	var mname := str(cfg.get("name", "怪物"))
	# M1 的 monsters.json 暂无 level / palette 字段：走 cfg 可选字段，缺省回落 preview 的值
	var mlevel := int(cfg.get("level", 28))
	var pal: Dictionary = cfg.get("palette", {})
	var iskin := _col(pal.get("skin", [120, 150, 90]), Color(0.47, 0.59, 0.35))
	var ieye := _col(pal.get("eye", [255, 230, 120]), Color(1.0, 0.9, 0.47))

	# 铭牌左侧小头像（preview: (x0-38, y+0)-(x0-16, y+22) 的皮肤色圆 + 眼睛条）
	var ic := _v2(nameplate.get("icon_center", [373, 46]))
	ci.draw_circle(ic, 11.0, iskin)
	ci.draw_rect(Rect2(ic.x - 3.0, ic.y - 3.0, 8.0, 3.0), ieye)

	# 名字 + 等级
	_txt(ci, _v2(nameplate.get("name_pos", [400, 32])), "%s  Lv.%d" % [mname, mlevel],
			float(nameplate.get("name_size", 16)), str(nameplate.get("name_anchor", "bl")),
			_col(nameplate.get("name_color"), Color(1.0, 0.9, 0.78)),
			float(nameplate.get("name_stroke", 2)),
			_col(nameplate.get("name_stroke_color"), Color.BLACK))

	# 分段血条：照抄 render_preview.draw_dynamic_ui 的分段算法（LAYER_HP / LAYER_COLS）
	var inner: Array = nameplate.get("bar_inner", [400, 36, 880, 52])
	var ip := _v2(inner)
	var iw := float(inner[2]) - ip.x
	var hp := maxf(0.0, float(target.get("hp")))
	var layer_hp := maxf(1.0, float(hp_layers.get("layer_hp", 15000)))
	var colors: Array = hp_layers.get("colors", [[200, 40, 40]])
	if colors.is_empty():
		colors = [[200, 40, 40]]
	var layers := maxi(1, int(ceil(hp / layer_hp)))
	var cur := hp - float(layers - 1) * layer_hp
	var ci_idx := (layers - 1) % colors.size()
	var frac := clampf(cur / layer_hp, 0.0, 1.0)
	if layers > 1:
		# 下层残留色（preview: LAYER_COLS[(ci-1) % len]）
		ci.draw_rect(Rect2(ip, Vector2(iw, 16.0)),
				_col(colors[(ci_idx - 1 + colors.size()) % colors.size()], Color(0.78, 0.16, 0.16)))
	ci.draw_rect(Rect2(ip, Vector2(iw * frac, 16.0)), _col(colors[ci_idx], Color(0.78, 0.16, 0.16)))
	# 顶部高光（preview: mixc(col, white, 0.4) 的 2px 线）
	ci.draw_line(ip + Vector2(0, 2), ip + Vector2(iw * frac, 2),
			_mix(colors[ci_idx], [255, 255, 255], 0.4), 2.0)
	# 层数 xN
	if layers > 1:
		_txt(ci, _v2(nameplate.get("layer_pos", [890, 44])), "x%d" % layers,
				float(nameplate.get("layer_size", 22)), str(nameplate.get("layer_anchor", "lm")),
				_col(nameplate.get("layer_color"), Color(1.0, 0.94, 0.78)),
				float(nameplate.get("layer_stroke", 2)),
				_col(nameplate.get("layer_stroke_color"), Color.BLACK), _fn())


# ---------------------------------------------------------------- 技能格：按键字母 + 冷却遮罩
func _draw_slot_overlays(ci: CanvasItem) -> void:
	for i in slots.size():
		var s: Dictionary = slots[i]
		var left: float = _slot_cd[i]
		var total: float = _slot_cd_max[i]
		if left > 0.0 and total > 0.0:
			var c := _v2(s.get("cd_center", [0, 0]))
			var r := float(s.get("cd_radius", 31))
			var frac := clampf(left / total, 0.0, 1.0)
			ci.draw_colored_polygon(
					_arc_points(c, r - 8.0, -PI * 0.5, -PI * 0.5 + TAU * (1.0 - frac), 30),
					Color(0, 0, 0, 0.63))
			_txt(ci, _v2(s.get("cd_text_pos", [0, 0])), "%.1f" % left,
					float(s.get("cd_text_size", 16)), "center", Color.WHITE, 2.0, Color.BLACK,
					_fn())
		# 按键字母（preview 用 F_NUM(14)）
		_txt(ci, _v2(s.get("key_pos", [0, 0])), str(s.get("key", "")),
				float(s.get("key_size", 14)), "tl", Color(1.0, 0.94, 0.784), 2.0,
				Color.BLACK, _fn())


func _arc_points(c: Vector2, r: float, a0: float, a1: float, steps: int) -> PackedVector2Array:
	## 扇形三角带（冷却遮罩）：圆心 + 圆弧采样点
	var pts := PackedVector2Array()
	pts.append(c)
	var n := maxi(3, steps)
	for k in range(n + 1):
		var a := a0 + (a1 - a0) * float(k) / float(n)
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	return pts


# ---------------------------------------------------------------- HP / MP 球
func _draw_orb_liquid(ci: CanvasItem, kind: String) -> void:
	var o: Dictionary = orbs.get(kind, {})
	if o.is_empty():
		return
	var c := _v2(o.get("center", [0, 0]))
	var r := float(o.get("radius", 50))
	var cur := vitals_hp if kind == "hp" else vitals_mp
	var mx := vitals_hp_max if kind == "hp" else vitals_mp_max
	var frac := clampf(cur / mx, 0.0, 1.0) if mx > 0.0 else 0.0
	if frac <= 0.002:
		return
	var col := _col(o.get("liquid_color"), Color(0.9, 0.24, 0.24))
	var cold := _col(o.get("liquid_color_dark"), Color(0.47, 0.04, 0.08))
	var top := c.y - r + 2.0 * r * (1.0 - frac)
	# 液面高光（preview: ld.line(..., width=2) 混白）
	ci.draw_line(Vector2(c.x - r, top), Vector2(c.x + r, top), _mix(col, Color.WHITE, 0.5), 2.0)
	# 逐行填充并裁剪到圆内（对齐 draw_orb 的逐行渐变 + 圆形 mask）
	var y := maxf(top + 1.0, c.y - r + 1.0)
	while y <= c.y + r:
		var dy := y - c.y
		var hw := sqrt(maxf(0.0, r * r - dy * dy)) - 0.5
		if hw > 0.0:
			ci.draw_line(Vector2(c.x - hw, y), Vector2(c.x + hw, y),
					_mix(col, cold, (y - top) / (2.0 * r)), 1.0)
		y += 1.0


func _draw_orb_values(ci: CanvasItem) -> void:
	for kind in ["hp", "mp"]:
		var o: Dictionary = orbs.get(kind, {})
		if o.is_empty():
			continue
		var cur := vitals_hp if kind == "hp" else vitals_mp
		_txt(ci, _v2(o.get("value_pos", [0, 0])), "%d" % int(round(cur)),
				float(o.get("value_size", 18)), str(o.get("value_anchor", "center")),
				_col(o.get("value_color"), Color.WHITE), float(o.get("value_stroke", 2)),
				_col(o.get("value_stroke_color"), Color.BLACK), _fn())


# ---------------------------------------------------------------- COMBO
func _draw_combo(ci: CanvasItem) -> void:
	if combo < 2:
		return
	var pop := 1.0 + 0.45 * combo_flash      # 数值变化时弹一下（对齐 preview 的 pop 手感）
	_txt(ci, Vector2(1150, 250), str(combo), 70.0 * pop, "right",
			Color(1.0, 0.84, 0.35), 5.0, Color(0.35, 0.12, 0.0), _fn())
	_txt(ci, Vector2(1162, 262), "COMBO", 26.0, "lm", Color(1.0, 0.96, 0.86), 3.0,
			Color(0.24, 0.08, 0.0), _fn())


# ---------------------------------------------------------------- 图标切换 / 降级
func _refresh_slot_icons() -> void:
	_slot_tex.clear()
	if not manifest_ok:
		return
	for i in slots.size():
		var s: Dictionary = slots[i]
		var variants: Dictionary = s.get("icon_by_job", {})
		var rel := str(variants.get(str(job), variants.get("0", "")))
		var key := "slot:%d:%s" % [i, rel]
		if not _tex.has(key):
			_tex[key] = _try_load(rel)
		_slot_tex.append(_tex[key])


func _draw_fallback(ci: CanvasItem) -> void:
	## manifest / 贴图缺失时的降级：一条半透明底栏 + 一行提示。不报错、不崩溃。
	if not _fallback_warned:
		_fallback_warned = true
		print("[HUD] 降级模式：未加载到烘焙 HUD（先跑 python tools/bake_hud.py）")
	ci.draw_rect(Rect2(0, 640, DESIGN_W, 80), Color(0.06, 0.055, 0.086, 0.85))
	ci.draw_line(Vector2(0, 640), Vector2(DESIGN_W, 640), Color(0.706, 0.557, 0.259), 2.0)
	_txt(ci, Vector2(16, 652), "HUD 贴图缺失：python tools/bake_hud.py", 16.0, "tl",
			Color(1.0, 0.85, 0.5), 2.0, Color.BLACK)
	if combo >= 2:
		_txt(ci, Vector2(1150, 250), str(combo), 70.0, "right", Color(1.0, 0.84, 0.35), 5.0,
				Color(0.35, 0.12, 0.0), _fn())
