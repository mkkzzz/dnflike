extends Node2D
## 城镇传送点的原版"开门光墙"：上（gateup）与下（gatedown）两层。
##
## 来源（E-FILE）：sprite/common/commoneffect/gate/gateup.img、gatedown.img，
## 由通用门动画 passiveobject/mapobject/pathgate/common/animation/gateall_00.ani（上）
## 与 gateall_02.ani（下）引用：29 帧、每帧 60ms、加色混合。
## 帧由 tools/bake_town_gate_light.py 从共享库烘焙到 assets_local/town_gate/（不入库）。
##
## 只负责表现：不参与走区判定、不改世界坐标；一处传送点 = 一个本节点，两个 Sprite2D。

const MANIFEST := "res://assets_local/town_gate/manifest.json"
const SCHEMA := "dnflike_town_gate_light/1"
const DIR := "res://assets_local/town_gate/"

var up: Sprite2D
var down: Sprite2D
var frames_up: Array = []
var frames_down: Array = []
var delay_ms := 60
var index := 0
var elapsed := 0.0
var playing := false
## 同一城镇里多处传送点共用同一批帧纹理，避免每个光墙各载 29 张。
static var texture_cache: Dictionary = {}

static func available() -> bool:
	return FileAccess.file_exists(MANIFEST)

## anchor = 屏幕层的地面锚点（地图坐标，已含城镇的 +120 视觉偏移）；depth 决定与角色的前后关系。
func setup(anchor: Vector2, depth: int = 0, manifest: Dictionary = {}) -> bool:
	if manifest.is_empty():
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
		if not parsed is Dictionary or parsed.get("schema") != SCHEMA:
			return false
		manifest = parsed
	var clips: Dictionary = manifest.get("clips", {})
	frames_up = _load_frames(clips.get("up", {}))
	frames_down = _load_frames(clips.get("down", {}))
	if frames_up.is_empty() and frames_down.is_empty():
		return false
	var timing: Array = clips.get("up", {}).get("frames", [])
	if timing.is_empty():
		timing = clips.get("down", {}).get("frames", [])
	delay_ms = int((timing[0] if timing else {}).get("delay_ms", 60))
	position = anchor
	z_index = depth
	up = _make_sprite(frames_up)
	down = _make_sprite(frames_down)
	# 地面光斑贴着门槛，常被门框底边挡住；单独抬到地图美术之上、HUD 之下，保证"下有光"。
	if down:
		down.z_index = 2400
	show_frame(0)
	playing = true
	elapsed = 0.0
	return true

func _load_frames(clip: Dictionary) -> Array:
	var frames: Array = clip.get("frames", [])
	if frames.is_empty():
		return []
	var key := DIR + String(frames[0].get("file", ""))
	if not texture_cache.has(key):
		var out: Array = []
		for frame: Dictionary in frames:
			var path := ProjectSettings.globalize_path(DIR + String(frame.get("file", "")))
			var image := Image.load_from_file(path)
			if image == null:
				continue
			out.append(ImageTexture.create_from_image(image))
		texture_cache[key] = out
	return texture_cache[key]

func _make_sprite(frames: Array) -> Sprite2D:
	if frames.is_empty():
		return null
	var sprite := Sprite2D.new()
	sprite.centered = false
	sprite.texture = frames[0]
	sprite.position = Vector2(-float(frames[0].get_width()) * 0.5, -float(frames[0].get_height()))
	var material := CanvasItemMaterial.new()
	material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	sprite.material = material
	sprite.z_index = -1
	add_child(sprite)
	return sprite

func show_frame(n: int) -> void:
	index = clampi(n, 0, maxi(frames_up.size(), frames_down.size()) - 1)
	if up and not frames_up.is_empty():
		up.texture = frames_up[mini(index, frames_up.size() - 1)]
	if down and not frames_down.is_empty():
		down.texture = frames_down[mini(index, frames_down.size() - 1)]

func frame_count() -> int:
	return maxi(frames_up.size(), frames_down.size())

func _process(delta: float) -> void:
	if not playing:
		return
	elapsed += delta * 1000.0
	if elapsed < float(delay_ms):
		return
	elapsed -= float(delay_ms)
	if index + 1 >= frame_count():
		playing = false
		return
	show_frame(index + 1)
