class_name CombatAudio
extends Node2D
## Offline layered foley: no DSP or large PCM allocations during startup/playback.
## Each sound has three independently baked performances and small live pitch variation.
## A bounded spatial voice pool preserves impacts and reserves headroom for overlap.

const SAMPLE_RATE := 48000
const MAX_VOICES := 10
const VARIANTS := 3
const ASSET_PATH := "res://assets/audio_v3/%s_%d.wav"
# Base dB, steal priority, retrigger interval in milliseconds.
const SOUND_SPECS := {
	"swing_light": [-8.5, 1, 50], "swing_back": [-8.0, 1, 50],
	"swing_heavy": [-6.0, 2, 60], "swing_air": [-8.0, 1, 50],
	"swing_upper": [-7.0, 2, 50], "dash": [-13.0, 0, 75],
	"dash_strike": [-6.5, 2, 70], "light": [-6.0, 2, 40],
	"heavy": [-4.5, 3, 55], "launch": [-5.5, 3, 45],
	"metal_hit": [-8.0, 3, 45], "guard": [-9.0, 3, 50],
	"hurt": [-8.0, 2, 65], "step": [-16.5, 0, 100],
	"run_step": [-14.5, 0, 85], "run_stop": [-15.0, 0, 100],
	"jump": [-13.0, 0, 100], "land": [-11.0, 1, 100],
	"charge": [-12.5, 1, 100], "draw_strike": [-6.0, 3, 75],
	"rage": [-11.5, 2, 120], "rage_strike": [-6.5, 2, 60],
	"thrust": [-9.0, 2, 45], "death": [-10.5, 2, 70],
	# 怪物受击的生物叫声（哥布林）。与撞击拟音 light/heavy 分层并存，不是替换。
	# 节流 320ms：叫声长达 0.34~0.43s，更短的节流会让连击糊成一片。
	"goblin_hurt": [-12.0, 2, 320],
	# 可破坏场景物（草丛等）被打碎：环境音，比打击音轻一档。
	# 声音长 0.48~0.60s，节流取 140ms 避免连击时碎响叠成一团。
	"foliage_break": [-9.0, 1, 140],
	"wave": [-13.0, 4, 500], "victory": [-11.5, 4, 1000],
	"ui": [-18.0, 1, 50],
}
const ALIASES := {
	"swing": "swing_light", "skill": "charge", "monster_death": "death",
	"monster_hurt": "goblin_hurt", "bush_break": "foliage_break",
	"footstep": "step", "run": "run_step", "stop": "run_stop", "turn": "run_stop",
	"attack1": "swing_light", "attack2": "swing_back", "attack3": "swing_heavy",
	"air_attack": "swing_air", "dash_attack": "dash_strike", "upper": "swing_upper",
	"quick_draw": "draw_strike", "rage_slash": "rage_strike", "blood_rage": "rage",
}

var enabled := true
var _streams: Dictionary = {}
var _voices: Array[AudioStreamPlayer2D] = []
var _started: Array[int] = []
var _priorities: Array[int] = []
var _base_db: Array[float] = []
var _last_played: Dictionary = {}
var _last_variant: Dictionary = {}
var _listener: AudioListener2D
var _headroom := 1.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	name = "CombatAudio"
	_rng.randomize()
	enabled = DisplayServer.get_name() != "headless"
	for kind in SOUND_SPECS:
		var takes: Array[AudioStreamWAV] = []
		for variant in range(1, VARIANTS + 1):
			var path := ASSET_PATH % [kind, variant]
			var stream := load(path) as AudioStreamWAV
			if stream != null:
				takes.append(stream)
			else:
				push_error("Missing baked combat foley: %s" % path)
		_streams[kind] = takes
	_listener = AudioListener2D.new()
	_listener.position = Vector2(640, 576)
	add_child(_listener)
	_listener.make_current()
	for index in range(MAX_VOICES):
		var voice := AudioStreamPlayer2D.new()
		voice.name = "FoleyVoice%d" % index
		voice.max_distance = 1200.0
		voice.attenuation = 0.65
		voice.panning_strength = 0.55
		add_child(voice)
		_voices.append(voice)
		_started.append(0)
		_priorities.append(0)
		_base_db.append(-40.0)


func set_listener_position(world_x: float) -> void:
	if _listener != null:
		_listener.global_position.x = world_x


func play_sound(requested_kind: String, world_x: float = NAN, intensity: float = 1.0) -> void:
	var kind := str(ALIASES.get(requested_kind, requested_kind))
	if not enabled or not _streams.has(kind) or _voices.is_empty():
		return
	var takes: Array = _streams[kind]
	if takes.is_empty():
		return
	var now := Time.get_ticks_msec()
	var spec: Array = SOUND_SPECS[kind]
	if now - int(_last_played.get(kind, -10000)) < int(spec[2]):
		return
	var priority := int(spec[1])
	var selected := -1
	var oldest := now + 1
	for index in range(_voices.size()):
		if not _voices[index].playing:
			selected = index
			break
		if _priorities[index] <= priority and _started[index] < oldest:
			oldest = _started[index]
			selected = index
	if selected < 0:
		return
	var previous := int(_last_variant.get(kind, -1))
	var variant := _rng.randi_range(0, takes.size() - 1)
	if takes.size() > 1 and variant == previous:
		variant = (variant + 1) % takes.size()
	_last_variant[kind] = variant
	var voice := _voices[selected]
	voice.stop()
	voice.stream = takes[variant]
	voice.global_position = _listener.global_position if is_nan(world_x) else Vector2(world_x, _listener.global_position.y)
	voice.pitch_scale = 1.0 if kind in ["wave", "victory", "ui"] else _rng.randf_range(0.976, 1.027)
	_base_db[selected] = float(spec[0]) + linear_to_db(clampf(intensity, 0.20, 1.3)) + _rng.randf_range(-0.7, 0.4)
	_started[selected] = now
	_priorities[selected] = priority
	_last_played[kind] = now
	voice.volume_db = _base_db[selected] + linear_to_db(_headroom)
	voice.play()
	# Immediate downward adjustment, so a burst cannot clip before the next frame.
	_headroom = minf(_headroom, _required_headroom())
	_apply_headroom()


func _required_headroom() -> float:
	var worst_peak := 0.0
	for index in range(_voices.size()):
		if _voices[index].playing:
			# Assets peak below .76; .84 also covers interpolation/pitch overshoot.
			worst_peak += 0.84 * db_to_linear(_base_db[index])
	return minf(1.0, 0.86 / maxf(worst_peak, 0.001))


func _apply_headroom() -> void:
	var trim := linear_to_db(maxf(_headroom, 0.001))
	for index in range(_voices.size()):
		if _voices[index].playing:
			_voices[index].volume_db = _base_db[index] + trim


func _process(delta: float) -> void:
	if not enabled:
		return
	var required := _required_headroom()
	_headroom = required if required < _headroom else lerpf(_headroom, required, 1.0 - exp(-6.0 * delta))
	_apply_headroom()


func stop_all() -> void:
	for voice in _voices:
		voice.stop()
		voice.stream = null
	_last_played.clear()
	_last_variant.clear()
	_headroom = 1.0
	for index in range(_started.size()):
		_started[index] = 0
		_priorities[index] = 0
		_base_db[index] = -40.0


func _exit_tree() -> void:
	stop_all()
	_streams.clear()
	_voices.clear()
	_started.clear()
	_priorities.clear()
	_base_db.clear()
