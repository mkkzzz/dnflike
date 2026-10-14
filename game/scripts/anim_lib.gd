extends RefCounted
## 帧条贴图仓库（实机表现层）
##
## 数据来自 `res://art/anim.json`。帧条有两个来源（见 docs/design/11_实机表现层管线.md）：
##   - **正式**：AI 帧图 → `tools/make_anim.py` → `tools/bake_ai_frames.py`（定稿画风）
##   - **占位**：`tools/bake_game_assets.py` 从 `tools/render_preview.py` 烘焙的程序化几何图形
## 两种产物格式相同，本文件与 player.gd / monster.gd 都不含任何美术细节。
##
## 帧条约定：水平排列、所有帧共用同一画布尺寸与锚点、一律朝右（facing = +1）。
## 清单缺失 / 贴图缺失 / 解析失败时返回空表，调用方退回占位绘制 —— 绝不报错崩溃。

const MANIFEST := "res://assets/demo/anim.json"
const BODY_MANIFEST := "res://assets/actors_v3/manifest.json"
const POLISH_MANIFEST := "res://assets/actors_v4/manifest.json"

static var _cache := {}


## 读取一组动作：{动作名: {tex, frames, frame_w, frame_h, durations, loop, ax, ay}}
static func load_group(group: String) -> Dictionary:
	if _cache.has(group):
		return _cache[group]
	var out := {}
	var manifest_path := BODY_MANIFEST if group == "player" and FileAccess.file_exists(BODY_MANIFEST) else MANIFEST
	if group == "player" and FileAccess.file_exists(POLISH_MANIFEST):
		manifest_path = POLISH_MANIFEST
	if not FileAccess.file_exists(manifest_path):
		push_warning("[ANIM] 缺 %s：先跑 python tools/bake_ai_frames.py（正式）或 tools/bake_game_assets.py（占位）" % MANIFEST)
		return out
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
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
			"weapon_separated": bool(e.get("weapon_separated", false)),
			"sockets": e.get("sockets", []),
			"phase_frames": e.get("phase_frames", {}),
			"segments": e.get("segments", []),
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


## 动作动画跟随战斗帧表；攻速与取消不会让贴图停留在错误的动作阶段。
static func frame_at_progress(clip: Dictionary, progress: float) -> int:
	var durations: Array = clip.get("durations", [1])
	var duration := 0.0
	for span in durations:
		duration += float(span)
	var clock := clampf(progress, 0.0, 0.999999) * duration
	for index in durations.size():
		if clock < float(durations[index]):
			return index
		clock -= float(durations[index])
	return maxi(0, int(clip.get("frames", 1)) - 1)


## Demo 清单按动作准备/出手/收势排列，贴图必须与真正活动判定同步。
static func frame_for_move(clip: Dictionary, clock: float, data: Dictionary) -> int:
	var frames := int(clip.get("frames", 1))
	var authored: Dictionary = clip.get("phase_frames", {})
	if not authored.is_empty():
		var startup := float(data.get("charge", data.get("windup", 0)))
		if data.has("hits"):
			var hits: Array = data["hits"]
			var segments: Array = clip.get("segments", [])
			var previous_end := 0.0
			for index in hits.size():
				var hit: Dictionary = hits[index]
				var start := float(hit.get("delay", 0))
				var active_end := start + float(hit.get("active", 3))
				var phase_map: Dictionary = segments[mini(index, segments.size() - 1)] if not segments.is_empty() else authored
				if clock <= start:
					return _phase_frame(phase_map.get("windup", [0]), (clock - previous_end) / maxf(1, start - previous_end), frames)
				if clock <= active_end:
					return _phase_frame(phase_map.get("active", [1]), (clock - start) / maxf(1, active_end - start), frames)
				previous_end = active_end
			return _phase_frame(authored.get("recovery", [frames - 1]), (clock - previous_end) / maxf(1, float(data.get("recovery", 1))), frames)
		if clock <= startup:
			return _phase_frame(authored.get("windup", [0]), clock / maxf(1, startup), frames)
		if clock <= startup + float(data.get("active", 0)):
			return _phase_frame(authored.get("active", [1]), (clock - startup) / maxf(1, float(data.get("active", 1))), frames)
		return _phase_frame(authored.get("recovery", [frames - 1]), (clock - startup - float(data.get("active", 0))) / maxf(1, float(data.get("recovery", 1))), frames)
	if not data.has("hits") and float(data.get("active", 0)) == 0.0:
		return frame_at_progress(clip, clock / maxf(1.0, move_duration(data)))
	if data.has("hits"):
		var hits: Array = data["hits"]
		for index in hits.size():
			var hit: Dictionary = hits[index]
			var start := float(hit.get("delay", 0))
			if clock <= start:
				return mini(index * 2, frames - 1)
			if clock <= start + float(hit.get("active", 3)):
				return mini(index * 2 + 1, frames - 1)
		return frames - 1
	var startup := float(data.get("charge", data.get("windup", 0)))
	# 哥布林五帧动作有两个前摇关键姿态；玩家的3/4帧有一个前摇。
	var active_frame := 2 if String(clip.get("name", "")) == "attack" and frames >= 5 else 1
	if clock <= startup:
		return 1 if active_frame == 2 and clock > startup * 0.5 else 0
	if clock <= startup + float(data.get("active", 0)):
		return mini(active_frame, frames - 1)
	var recovery_start := mini(active_frame + 1, frames - 1)
	var spans: Array = clip.get("durations", [1])
	var recovery_spans := 0.0
	for index in range(recovery_start, frames):
		recovery_spans += float(spans[index])
	var recovery_clock := clampf((clock - startup - float(data.get("active", 0))) / maxf(1.0, float(data.get("recovery", 0))), 0.0, 0.999999) * recovery_spans
	for index in range(recovery_start, frames):
		if recovery_clock < float(spans[index]):
			return index
		recovery_clock -= float(spans[index])
	return frames - 1

static func _phase_frame(indices: Array, progress: float, frames: int) -> int:
	if indices.is_empty():
		return 0
	return clampi(int(indices[mini(indices.size() - 1, int(clampf(progress, 0, 0.99999) * indices.size()))]), 0, frames - 1)


static func move_duration(data: Dictionary) -> float:
	if data.has("hits"):
		var last: Dictionary = data["hits"][-1]
		return float(last.get("delay", 0)) + float(last.get("active", 3)) + float(data.get("recovery", 0))
	return float(data.get("charge", data.get("windup", 0))) + float(data.get("active", 0)) + float(data.get("recovery", 0))


## 按优先级挑第一个存在的动作名；都不存在时退回 fallback（可能也不存在 → 返回空串）
static func pick(clips: Dictionary, names: Array, fallback := "") -> String:
	for n in names:
		if clips.has(n):
			return String(n)
	return fallback if clips.has(fallback) else ""
