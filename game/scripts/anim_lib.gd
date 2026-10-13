extends RefCounted
## 帧条贴图仓库（实机表现层）
##
## 数据来自 `res://art/anim.json` —— 由 `tools/bake_game_assets.py` 从 `tools/render_preview.py`
## 烘焙（单一美术源原则：本文件与 player.gd / monster.gd 都不含任何美术细节）。
##
## 帧条约定：水平排列、所有帧共用同一画布尺寸与锚点、一律朝右（facing = +1）。
## 清单缺失 / 贴图缺失 / 解析失败时返回空表，调用方退回占位绘制 —— 绝不报错崩溃。

const MANIFEST := "res://art/anim.json"

static var _cache := {}


## 读取一组动作：{动作名: {tex, frames, frame_w, frame_h, durations, loop, ax, ay}}
static func load_group(group: String) -> Dictionary:
	if _cache.has(group):
		return _cache[group]
	var out := {}
	if not FileAccess.file_exists(MANIFEST):
		push_warning("[ANIM] 缺 %s：先跑 python tools/bake_game_assets.py" % MANIFEST)
		return out
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	if typeof(data) != TYPE_DICTIONARY:
		push_warning("[ANIM] %s 解析失败（JSON 坏了？重跑烘焙脚本）" % MANIFEST)
		return out
	var groups: Dictionary = (data as Dictionary).get("groups", {})
	if not groups.has(group):
		push_warning("[ANIM] %s 里没有分组 %s" % [MANIFEST, group])
		return out
	var entries: Dictionary = groups[group]
	for key in entries:
		var e: Dictionary = entries[key]
		var path := "res://" + str(e.get("file", ""))
		if not ResourceLoader.exists(path):            # 先探再 load，缺图时只留一条警告，不刷引擎报错
			push_warning("[ANIM] 缺帧条贴图 %s（烘焙后需要跑一次 Godot --import）" % path)
			continue
		var tex := load(path) as Texture2D
		if tex == null:
			push_warning("[ANIM] 帧条贴图加载失败：%s" % path)
			continue
		var frames: int = maxi(1, int(e.get("frames", 1)))
		var durs: Array = []
		for d in e.get("durations", []):
			durs.append(maxi(1, int(d)))
		if durs.size() != frames:                      # 清单没写时长就按 fps 折算成物理帧
			var tick: int = maxi(1, int(round(60.0 / maxf(1.0, float(e.get("fps", 30))))))
			durs = []
			for _i in range(frames):
				durs.append(tick)
		out[String(key)] = {
			"name": String(key),
			"tex": tex,
			"frames": frames,
			"frame_w": float(e.get("frame_w", 1.0)),
			"frame_h": float(e.get("frame_h", 1.0)),
			"durations": durs,
			"loop": bool(e.get("loop", false)),
			"ax": float(e.get("ax", 0.0)),
			"ay": float(e.get("ay", 0.0)),
		}
	if not out.is_empty():
		_cache[group] = out
	return out


## 本帧该显示哪一格（region 的源矩形）
static func src_rect(clip: Dictionary, frame: int) -> Rect2:
	var f: int = clampi(frame, 0, int(clip.get("frames", 1)) - 1)
	return Rect2(float(f) * float(clip["frame_w"]), 0.0, float(clip["frame_w"]), float(clip["frame_h"]))


## 推进动画时钟（每物理帧调用一次）：返回 [帧号, 帧内已走物理帧数]。
## 循环动作绕回第 0 帧；非循环动作停在最后一帧。
static func advance(clip: Dictionary, frame: int, tick: int) -> Array:
	if clip.is_empty():
		return [0, 0]
	var frames: int = int(clip["frames"])
	var durs: Array = clip["durations"]
	var f: int = clampi(frame, 0, frames - 1)
	var t: int = tick + 1
	var guard := 0
	while t >= int(durs[f]) and guard < 16:
		guard += 1
		t -= int(durs[f])
		if f + 1 < frames:
			f += 1
		elif bool(clip["loop"]):
			f = 0
		else:
			f = frames - 1
			t = 0
			break
	return [f, t]


## 按优先级挑第一个存在的动作名；都不存在时退回 fallback（可能也不存在 → 返回空串）
static func pick(clips: Dictionary, names: Array, fallback := "") -> String:
	for n in names:
		if clips.has(n):
			return String(n)
	return fallback if clips.has(fallback) else ""
