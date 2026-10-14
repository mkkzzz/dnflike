extends RefCounted
## V6 序列帧资源库（实机表现层）
##
## 资源本体：`game/assets/seq_v6/`（由美术工作区 `tools/bake_seq_v6.py` 烘焙）。
## 帧数据的唯一来源是 `manifest.json`：每条 `frames` 记录 `start_tick` + 整数 `duration_ticks`，
## 文件可复用，**不能按 PNG 文件序号猜动作帧数**（见 docs/design/13_V6动作资源与实装待办.md §三）。
##
## 本库只做三件事，不含任何美术细节与战斗逻辑：
##   1. 读 manifest → 每个 clip 的逐 tick 图像、画布、锚点、混合、时钟；
##   2. 把逐 tick 时间轴转成 Godot 的 SpriteFrames（每个 tick 一格，保留整数时长）；
##   3. 给出刀光/接触判定需要的护手、刀尖采样线。
##
## 资源缺失或解析失败时返回空表，调用方退回原 V4 表现 —— 不报错崩溃。

const MANIFEST := "res://assets/seq_v6/manifest.json"
const ASSET_ROOT := "res://assets/seq_v6/"

static var _manifest := {}
static var _clips := {}
static var _loaded := false

## 解析 manifest，建立逐 tick 的 clip 表。返回 {clip 名: clip}。
static func load_clips() -> Dictionary:
	if _loaded:
		return _clips
	_loaded = true
	if not FileAccess.file_exists(MANIFEST):
		push_warning("[SEQ6] 缺 %s：先同步 art/seq_v6 与 game/assets/seq_v6" % MANIFEST)
		return _clips
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[SEQ6] %s 解析失败" % MANIFEST)
		return _clips
	_manifest = parsed
	var raw: Dictionary = _manifest.get("clips", {})
	for key in raw:
		var built := _build_clip(String(key), raw[key])
		if not built.is_empty():
			_clips[String(key)] = built
	if not _clips.is_empty():
		var ticks := 0
		for clip in _clips.values():
			ticks += int(clip["length_ticks"])
		print("[SEQ6] manifest v%s loaded: %d clips, %d ticks" % [str(_manifest.get("version", "?")), _clips.size(), ticks])
	return _clips


## manifest 顶层的四招参数（active / contact_tick / hitstop / travel ...）
static func moves() -> Dictionary:
	load_clips()
	return _manifest.get("moves", {})


## manifest 声明：停帧未烘进资源，实机只停一次
static func hitstop_baked() -> bool:
	load_clips()
	return bool(_manifest.get("hitstop_baked", false))


static func has_clip(name: String) -> bool:
	return load_clips().has(name)


static func clip(name: String) -> Dictionary:
	return load_clips().get(name, {})


static func clip_names() -> Array:
	return load_clips().keys()


## 把 clip 名里的 {move} / {fx} 占位替换掉
static func resolve(pattern: String, move: String, fx := "") -> String:
	return pattern.replace("{move}", move).replace("{fx}", fx)


static func _build_clip(name: String, raw: Dictionary) -> Dictionary:
	var size: Array = raw.get("size", [])
	var anchor: Array = raw.get("anchor", [])
	if size.size() != 2 or anchor.size() != 2:
		push_warning("[SEQ6] %s 缺 size/anchor" % name)
		return {}
	var sequences: Array = []
	var bladed: Array = []
	var textures: Array = []
	var roots: Array = []
	var next_tick := 0
	for entry in raw.get("frames", []):
		var start := int(entry.get("start_tick", -1))
		var span := maxi(1, int(entry.get("duration_ticks", 1)))
		if start != next_tick:
			push_warning("[SEQ6] %s 时间轴在 tick %d 处断裂" % [name, next_tick])
			return {}
		var path := ASSET_ROOT + str(entry.get("file", ""))
		if not ResourceLoader.exists(path):
			push_warning("[SEQ6] 缺帧贴图 %s（导入后需跑一次 Godot --import）" % path)
			return {}
		var texture := load(path) as Texture2D
		if texture == null:
			push_warning("[SEQ6] 帧贴图加载失败：%s" % path)
			return {}
		# Records are run-length encoded. Every consumer uses an action/effect tick,
		# so expand duration_ticks here instead of treating a record index as a tick.
		var guard_point := Vector2.ZERO
		var tip_point := Vector2.ZERO
		if entry.has("guard") and entry.has("tip"):
			var guard: Array = entry["guard"]
			var tip: Array = entry["tip"]
			guard_point = Vector2(float(guard[0]), float(guard[1]))
			tip_point = Vector2(float(tip[0]), float(tip[1]))
		for _tick in span:
			textures.append(texture)
			sequences.append(1)
			roots.append(float(entry.get("root_dx", 0.0)))
			bladed.append(guard_point)
			bladed.append(tip_point)
		next_tick += span
	var declared := int(raw.get("duration_ticks", next_tick))
	if next_tick != declared:
		push_warning("[SEQ6] %s 声明 %d tick，实际排到 %d" % [name, declared, next_tick])
	return {
		"name": name,
		"frame_w": int(size[0]),
		"frame_h": int(size[1]),
		"anchor": Vector2(float(anchor[0]), float(anchor[1])),
		"blend": str(raw.get("blend", "normal")),
		"clock": str(raw.get("clock", "effect")),
		"length_ticks": next_tick,
		"unique_images": int(raw.get("unique_images", textures.size())),
		"textures": textures,
		"spans": sequences,
		"blade": bladed,
		"root_dx": roots,
	}


## 逐 tick 时钟 → tick 序号（越界夹到首尾，和 Godot 非循环动画停在末帧一致）
static func tick_index(clip_data: Dictionary, tick: float) -> int:
	var spans: Array = clip_data.get("spans", [])
	if spans.is_empty():
		return 0
	return clampi(int(floor(tick)), 0, spans.size() - 1)


## tick → 该 tick 的帧内已走物理帧数（用于插值/抓帧核对）
static func tick_fraction(tick: float) -> float:
	return clampf(tick - floorf(tick), 0.0, 0.999999)


static func texture_at(clip_data: Dictionary, tick: float) -> Texture2D:
	var textures: Array = clip_data.get("textures", [])
	if textures.is_empty():
		return null
	return textures[tick_index(clip_data, tick)] as Texture2D


## 本 tick 刀身采样线：返回 [护手相对 root, 刀尖相对 root]（右向本地像素，未翻转）
static func blade_local(clip_data: Dictionary, tick: float) -> Array:
	var blade: Array = clip_data.get("blade", [])
	var index := tick_index(clip_data, tick)
	if blade.size() < (index + 1) * 2:
		return [Vector2.ZERO, Vector2.ZERO]
	return [blade[index * 2], blade[index * 2 + 1]]


## 锚点 → 非居中贴图的左上角偏移（朝右）。左向时调用方另按 width - anchor.x 翻转。
static func anchor_offset(clip_data: Dictionary) -> Vector2:
	return -Vector2(clip_data.get("anchor", Vector2.ZERO))


## straight-alpha 图像 + 归属层的混合模式 → CanvasItemMaterial
static func blend_material(blend: String) -> CanvasItemMaterial:
	var material := CanvasItemMaterial.new()
	material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD if blend == "add" else CanvasItemMaterial.BLEND_MODE_MIX
	return material


## manifest → SpriteFrames：**每个 tick 一格**，保留作者写的整数 duration_ticks。
## 不使用 PNG 文件序号，也不把 GIF 里为演示重复的时长当成动作帧数。
static func sprite_frames(clip_data: Dictionary, animation := "default") -> SpriteFrames:
	var frames := SpriteFrames.new()
	if frames.has_animation("default"):
		frames.remove_animation("default")
	frames.add_animation(animation)
	frames.set_animation_loop(animation, false)
	frames.set_animation_speed(animation, 1.0)
	var textures: Array = clip_data.get("textures", [])
	var spans: Array = clip_data.get("spans", [])
	for index in textures.size():
		frames.add_frame(animation, textures[index], float(spans[index]))
	return frames
