class_name SeqFX
extends Node2D
## V6 序列帧表现层（docs/design/13_V6动作资源与实装待办.md §三）
##
## 只负责把 `game/assets/seq_v6/` 的 clip 按 manifest 契约摆到世界里，不含伤害逻辑：
##   - 动作时钟层：slash_back / slash_front 消费 phase_t；用实际 root 减去烘焙前冲，
##     保持原画对位并补偿舞台边界。停帧时与 actor 一起冻结。
##   - 特效时钟层：hit_light / hit_matter / ground / iai_flash 挂在自己的时钟上，
##     命中停帧期间继续播放（与预览一致，DNF 同款处理）。
##   - 拔刀一闪后短暂压暗世界（预览为 30%）；受击 light 是加法层，matter 是普通层，不合并。
##
## 资源缺失时全部静默降级，玩家仍按原 V4 表现出招。

const SeqLib := preload("res://scripts/seq_lib.gd")

const MAX_HIT_NODES := 12
const MAX_GROUND_NODES := 4
const MAX_FLASH_NODES := 4

var actor: Player
var fx: BattleFX
var config: Dictionary = {}
var moves: Dictionary = {}
var clips: Dictionary = {}

var action_move := ""
var action_tick := -1.0
var action_facing := 1
# 特效与 manifest 一样使用 60 Hz tick，不受攻速或命中停帧影响。
var effect_clock := 0.0
var slash_origin := Vector2.ZERO
var dim_left := 0
var dim_strength := 0.0
var contacts: Array = []
var ground_events: Array = []
var iai_events: Array = []
var freeze_samples: Array = []
var dims: Array = []
var last_kind := ""
var last_flash: Sprite2D = null
var frame_count := 0
var window := Vector2i.ZERO

var _body_clip: Dictionary = {}
var _slash_response := false
var _active_fx := "light"
var _slash_back: Sprite2D
var _slash_front: Sprite2D
var _dim: ColorRect
var _dim_layer: Node2D
var _hits: Array = []
var _grounds: Array = []
var _flashes: Array = []


func setup(player: Player, battle_fx: BattleFX, data: Dictionary) -> void:
	actor = player
	fx = battle_fx
	config = data
	# 作者帧表只认 manifest；接线 JSON 只保留 clip 路径和 iai 表现参数。
	moves = SeqLib.moves()
	clips = SeqLib.load_clips()
	_configure_root()
	actor.action_started.connect(_on_action_started)
	_refresh_action()


## 收招/复位：默认连接触记录一起清空（重开一局时用）。
## `keep_records` 为 true 时只收画面，保留接触/地裂/一闪记录供验收核对。
func reset(keep_records := false) -> void:
	clear_action()
	effect_clock = 0.0
	slash_origin = Vector2.ZERO
	dim_left = 0
	dim_strength = 0.0
	last_kind = ""
	last_flash = null
	# 保留验收记录也不能保留仍在驱动画面的压暗事件。
	for dim in dims:
		dim["age"] = float(dim["hold"]) + float(dim["fade"])
	if not keep_records:
		contacts.clear()
		ground_events.clear()
		iai_events.clear()
		freeze_samples.clear()
		dims.clear()
	for pool in [_hits, _grounds, _flashes]:
		for node in pool:
			node.visible = false
			if node.has_meta("seq"):
				node.remove_meta("seq")
	if _dim != null:
		_dim.color = Color(0, 0, 0, 0)
	if is_instance_valid(_dim_layer):
		_dim_layer.visible = false


## 收招/打断仅收刀光；已经落在世界中的接触特效应自然播完。
func clear_action() -> void:
	action_move = ""
	action_tick = -1.0
	action_facing = 1
	_slash_response = false
	_body_clip = {}
	frame_count = 0
	window = Vector2i.ZERO
	for node in [_slash_back, _slash_front]:
		if is_instance_valid(node):
			node.visible = false


## 当前是否正在用 V6 一体帧出招（WeaponRig 必须据此停用旧武器层）
func active() -> bool:
	return _slash_response and action_move != ""


## 本招在 manifest 里的命中窗口 [start, end)
func current_window() -> Dictionary:
	return {"start": window.x, "end": window.y}


## 本招在 manifest 里的参数（hitstop / fx / ground / travel ...）
func move_params() -> Dictionary:
	return moves.get(action_move, {})


func current_tick() -> float:
	return maxf(0.0, action_tick)


## 本招本 tick 的护手/刀尖（世界坐标，已按朝向翻转）——供判定与验收日志
func blade_world(tick := -1.0) -> Array:
	if _body_clip.is_empty():
		return [Vector2.ZERO, Vector2.ZERO]
	var at := action_tick if tick < 0.0 else tick
	if is_instance_valid(actor):
		return actor.seq_blade_world(at)
	var local: Array = SeqLib.blade_local(_body_clip, at)
	var facing := float(action_facing)
	var root := actor.visual_position() if is_instance_valid(actor) else Vector2.ZERO
	var guard: Vector2 = local[0]
	var tip: Vector2 = local[1]
	return [root + Vector2(guard.x * facing, guard.y), root + Vector2(tip.x * facing, tip.y)]


func _configure_root() -> void:
	z_index = 0
	_slash_back = _make_sprite("SlashBack", false)
	_slash_front = _make_sprite("SlashFront", true)
	# 与战斗节点共享世界 canvas，才能只压背景，不压人物、刀光或 HUD。
	_dim_layer = Node2D.new()
	_dim_layer.name = "IaiDim"
	_dim_layer.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_dim_layer.z_as_relative = false
	_dim_layer.z_index = int(GameConfig.runtime.get("layering", {}).get("dim_z", -950))
	add_child(_dim_layer)
	_dim = ColorRect.new()
	_dim.name = "Dim"
	_dim.color = Color(0, 0, 0, 0)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dim_layer.add_child(_dim)
	var view := Vector2(1280, 720)
	if is_instance_valid(actor) and actor.get_viewport() != null:
		view = actor.get_viewport().get_visible_rect().size
	_dim.size = view
	_dim_layer.visible = false


func _make_sprite(node_name: String, top: bool) -> Sprite2D:
	var sprite := Sprite2D.new()
	sprite.name = node_name
	sprite.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	sprite.centered = false
	sprite.visible = false
	sprite.z_as_relative = false
	sprite.z_index = 105 if top else 95
	add_child(sprite)
	return sprite


func _make_pool(count: int, prefix: String, z: int) -> Array:
	var pool: Array = []
	for index in count:
		var sprite := Sprite2D.new()
		sprite.name = "%s%02d" % [prefix, index]
		sprite.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		sprite.centered = false
		sprite.visible = false
		sprite.z_as_relative = false
		sprite.z_index = z
		add_child(sprite)
		pool.append(sprite)
	return pool


func _take(pool: Array, capacity: int, prefix: String, z: int) -> Sprite2D:
	for sprite in pool:
		if not sprite.visible:
			return sprite
	if pool.size() < capacity:
		var created := _make_pool(1, prefix, z)
		pool.append(created[0])
		return created[0]
	# 池满时回收最早的一格，绝不无限增长。
	var recycle: Sprite2D = pool.pop_front()
	pool.append(recycle)
	return recycle


func _on_action_started(identifier: String) -> void:
	if not moves.has(identifier) or not clips.has("actor/%s" % identifier):
		clear_action()
		return
	action_move = identifier
	action_tick = -1.0
	action_facing = actor.facing
	_slash_response = true
	slash_origin = actor.visual_position()
	var params: Dictionary = moves[identifier]
	_active_fx = str(params.get("fx", "light"))
	var span: Array = params.get("active", [0, 0])
	window = Vector2i(int(span[0]), int(span[1]))
	_body_clip = clips["actor/%s" % identifier]
	frame_count = int(_body_clip["length_ticks"])
	_attach_slash()
	_refresh_action()


func _attach_slash() -> void:
	if action_move == "":
		return
	var table: Dictionary = config.get("clips", {})
	_attach(_slash_back, SeqLib.resolve(str(table.get("slash_back", "")), action_move, _active_fx))
	_attach(_slash_front, SeqLib.resolve(str(table.get("slash_front", "")), action_move, _active_fx))


func _attach(node: Sprite2D, clip_name: String) -> void:
	if not clips.has(clip_name):
		node.visible = false
		return
	var clip: Dictionary = clips[clip_name]
	node.texture = clip["textures"][0]
	node.material = SeqLib.blend_material(str(clip.get("blend", "normal")))
	node.visible = true


func _refresh_action() -> void:
	if not is_instance_valid(actor):
		return
	var move := actor.move_name
	if move != action_move or not moves.has(move):
		clear_action()
		return
	var tick := actor.phase_t
	if tick < action_tick:
		# 同一招重新起手（连段回到第 0 tick）
		action_tick = -1.0
		action_facing = actor.facing
		slash_origin = actor.visual_position()
		_attach_slash()
	action_tick = tick
	# 刀光已经烘入 root_dx；减去它得到本帧真实的出招坐标。
	# 正常前冲时等于 slash_origin；撞到舞台边界时与被截停的角色一起校正。
	var reference: Array = _body_clip.get("root_dx", [])
	var root_dx := float(reference[SeqLib.tick_index(_body_clip, tick)]) if not reference.is_empty() else 0.0
	var origin := actor.visual_position() - Vector2(root_dx * float(action_facing), 0.0)
	if _slash_back.visible:
		_slash_back.global_position = origin
		_slash_back.z_index = actor.z_index - 1
		_seq_apply(_slash_back, clips["slash_back/%s" % action_move], tick, true, action_facing)
	if _slash_front.visible:
		_slash_front.global_position = origin
		_slash_front.z_index = actor.z_index + 1
		_seq_apply(_slash_front, clips["slash_front/%s" % action_move], tick, true, action_facing)


func refresh_depth_layers() -> void:
	if not is_instance_valid(actor):
		return
	if is_instance_valid(_slash_back):
		_slash_back.z_index = actor.z_index - 1
	if is_instance_valid(_slash_front):
		_slash_front.z_index = actor.z_index + 1


func _seq_apply(node: Sprite2D, clip: Dictionary, tick: float, mirror: bool, facing_value := 0) -> void:
	if clip.is_empty():
		return
	var texture := SeqLib.texture_at(clip, tick)
	if texture == null:
		return
	node.texture = texture
	# offset=-anchor 只对非居中 Sprite 成立；居中再减 anchor 会多偏半张画布。
	node.centered = false
	var anchor: Vector2 = clip["anchor"]
	var width := float(clip["frame_w"])
	var offset := -anchor
	var facing := facing_value if facing_value != 0 else (actor.facing if is_instance_valid(actor) else 1)
	if mirror and facing < 0:
		# 左向：整套图像水平翻转，锚点按 width - anchor.x 重新对齐（不是只对剑作负缩放）
		node.flip_h = true
		offset = Vector2(-(width - anchor.x), -anchor.y)
	else:
		node.flip_h = false
	node.offset = offset


func _physics_process(delta: float) -> void:
	if not is_instance_valid(actor):
		return
	_refresh_action()
	# phase_t 已由 Player 在停帧时冻结；特效时钟必须继续。
	_advance_effects(delta)
	_tick_dim(delta * float(config.get("fps", 60)))


func _advance_effects(delta: float) -> void:
	var step := delta * float(config.get("fps", 60))
	effect_clock += step
	for pool in [_hits, _grounds, _flashes]:
		for node in pool:
			if not node.visible:
				continue
			var entry: Dictionary = node.get_meta("seq")
			# Player 先生成、SeqFX 后更新：出生物理帧保持第 0 张，不跳首帧。
			if int(entry.get("spawn_frame", -1)) == Engine.get_physics_frames():
				continue
			entry["tick"] = float(entry["tick"]) + step
			var clip: Dictionary = entry["clip"]
			if int(entry["tick"]) >= int(clip["length_ticks"]):
				node.visible = false
				node.remove_meta("seq")
				continue
			_seq_apply(node, clip, float(entry["tick"]), true, int(entry["facing"]))


func _tick_dim(step := 1.0) -> void:
	# 预览：命中后压暗 30%，保持 7 tick，再在 8 tick 内恢复；停帧期间特效时钟照走。
	dim_left = 0
	var alpha := 0.0
	for dim in dims:
		var duration := float(dim["hold"]) + float(dim["fade"])
		var age := float(dim.get("age", duration))
		if int(dim.get("spawn_frame", -1)) != Engine.get_physics_frames():
			age = minf(duration, age + step)
			dim["age"] = age
		if age < duration:
			dim_left = maxi(dim_left, int(ceil(duration - age)))
			var gain := clampf(1.0 - maxf(0.0, age - float(dim["hold"])) / maxf(1.0, float(dim["fade"])), 0.0, 1.0)
			alpha = maxf(alpha, float(dim["strength"]) * gain)
	if not is_instance_valid(_dim):
		return
	if alpha <= 0.0:
		_dim.color = Color(0, 0, 0, 0)
		if is_instance_valid(_dim_layer):
			_dim_layer.visible = false
		return
	_dim_layer.visible = true
	# 屏幕覆盖跟随相机，但画面排序仍使用 world canvas。
	_dim_layer.global_transform = get_viewport().get_canvas_transform().affine_inverse()
	_dim.size = get_viewport().get_visible_rect().size
	_dim.color = Color(0, 0, 0, alpha)


## 命中：按 manifest 的 fx 档位（light / heavy / iai）播受击 light + matter。
## `point` 必须是战斗碰撞给出的真实接触点，不能拿目标中心或脚底替代。
func spawn_hit(point: Vector2, kind: String) -> void:
	# 伤害在 Player 的本帧推进中触发，不能沿用上一帧 SeqFX 的 tick。
	_refresh_action()
	var light_name := SeqLib.resolve(str(config.get("clips", {}).get("hit_light", "hit_light/{fx}")), action_move, kind)
	var matter_name := SeqLib.resolve(str(config.get("clips", {}).get("hit_matter", "hit_matter/{fx}")), action_move, kind)
	last_kind = kind
	last_flash = null
	var spawned := 0
	for name in [matter_name, light_name]:
		if not clips.has(name):
			continue
		var node := _take(_hits, MAX_HIT_NODES, "Hit", 300)
		if node == null:
			continue
		_play(node, name, point, 300)
		spawned += 1
	if spawned == 2:
		contacts.append({"move": action_move, "tick": action_tick, "point": point, "kind": kind})
	# 拔刀一闪：长线挂接触点，画布已留足，靠舞台边缘自然裁切。
	if kind == "iai" and clips.has(SeqLib.resolve(str(config.get("clips", {}).get("iai_flash", "iai/flash")), action_move, kind)):
		var flash := _take(_flashes, MAX_FLASH_NODES, "Flash", 320)
		if flash != null:
			_play(flash, SeqLib.resolve(str(config.get("clips", {}).get("iai_flash", "iai/flash")), action_move, kind), point, 320)
			last_flash = flash
			iai_events.append({"move": action_move, "tick": action_tick, "point": point})
			_start_dim()


func _start_dim() -> void:
	var iai: Dictionary = config.get("iai", {})
	dim_strength = float(iai.get("dim", 0.30))
	dims.append({"move": action_move, "at": effect_clock, "age": 0.0,
		"spawn_frame": Engine.get_physics_frames(), "strength": dim_strength,
		"hold": float(iai.get("dim_hold", 7)), "fade": float(iai.get("dim_fade", 8))})
	if dims.size() > 8:
		dims.pop_front()
	_tick_dim(0.0)


## 地裂：只在可见刀尖真正落到地面线时触发，锚点 = 落地坐标（不是角色脚下）。
func spawn_ground(point: Vector2) -> bool:
	_refresh_action()
	var spawned := 0
	var ground_z := actor.z_index - 3 if is_instance_valid(actor) else 90
	for key in ["ground_matter", "ground_light"]:
		var name := str(config.get("clips", {}).get(key, ""))
		if not clips.has(name):
			continue
		var node := _take(_grounds, MAX_GROUND_NODES, "Ground", ground_z)
		if node == null:
			continue
		_play(node, name, point, ground_z)
		spawned += 1
	if spawned > 0:
		ground_events.append({"move": action_move, "tick": action_tick, "point": point})
		return true
	return false


func _play(node: Sprite2D, clip_name: String, origin: Vector2, z: int) -> void:
	var clip: Dictionary = clips[clip_name]
	node.visible = true
	node.z_index = z
	node.global_position = origin
	node.material = SeqLib.blend_material(str(clip.get("blend", "normal")))
	var facing := action_facing if active() else (actor.facing if is_instance_valid(actor) else 1)
	node.set_meta("seq", {"clip": clip, "tick": 0.0, "origin": origin,
		"facing": facing, "spawn_frame": Engine.get_physics_frames()})
	_seq_apply(node, clip, 0.0, true, facing)


## 命中停帧的第一帧现场：动作时钟、actor 贴图与刀身采样线必须是同一 tick。
## 录制在物理帧内发生，验收不必靠测试脚本掐时机；记录跨收招保留。
func note_freeze(tick: float, frame: int, blade: Vector2, point: Vector2, hitstop: int) -> void:
	var flash_at := Vector2.INF
	if is_instance_valid(last_flash):
		flash_at = last_flash.global_position
	freeze_samples.append({"move": action_move, "tick": tick, "frame": frame, "blade": blade,
		"point": point, "hitstop": hitstop, "flash": flash_at, "dim_alpha": _dim.color.a if is_instance_valid(_dim) else 0.0})
	if freeze_samples.size() > 16:
		freeze_samples.pop_front()


## 验收/回归用的现场快照
func debug_state() -> Dictionary:
	return {
		"active": active(),
		"move": action_move,
		"tick": action_tick,
		"facing": action_facing,
		"effect_clock": effect_clock,
		"slash_back_visible": is_instance_valid(_slash_back) and _slash_back.visible,
		"slash_front_visible": is_instance_valid(_slash_front) and _slash_front.visible,
		"slash_back_position": _slash_back.position if is_instance_valid(_slash_back) else Vector2.ZERO,
		"hit_nodes": _visible_count(_hits),
		"ground_nodes": _visible_count(_grounds),
		"flash_nodes": _visible_count(_flashes),
		"dim_left": dim_left,
		"contacts": contacts.size(),
		"ground_events": ground_events.size(),
		"iai_events": iai_events.size(),
		"freeze_samples": freeze_samples.size(),
		"last_kind": last_kind,
		"last_flash": last_flash,
		"dim_alpha": _dim.color.a if is_instance_valid(_dim) else 0.0,
	}


func _visible_count(pool: Array) -> int:
	var total := 0
	for node in pool:
		total += 1 if node.visible else 0
	return total
