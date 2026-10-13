class_name CombatAudio
extends Node
## Small deterministic synthesizer: no downloaded assets or external audio dependency.
## Streams are generated once, then shared by a bounded voice pool.

const SAMPLE_RATE := 22050
const MAX_VOICES := 8
const SOUND_SPECS := {
	"swing": [0.13, 360.0, 90.0, 0.85, -17.0, 0],
	"light": [0.14, 190.0, 65.0, 0.67, -12.0, 1],
	"heavy": [0.24, 100.0, 32.0, 0.75, -10.0, 2],
	"launch": [0.20, 160.0, 440.0, 0.38, -13.0, 2],
	"guard": [0.25, 1150.0, 720.0, 0.30, -15.0, 2],
	"hurt": [0.18, 150.0, 50.0, 0.65, -12.0, 2],
	"skill": [0.34, 150.0, 520.0, 0.28, -15.0, 2],
	"death": [0.34, 135.0, 28.0, 0.52, -17.0, 1],
	"wave": [0.53, 220.0, 440.0, 0.0, -17.0, 3],
	"victory": [0.94, 261.63, 523.25, 0.0, -15.0, 3],
	"ui": [0.075, 980.0, 720.0, 0.02, -20.0, 2],
}

var enabled := true
var _streams: Dictionary = {}
var _voices: Array[AudioStreamPlayer] = []
var _started: Array[int] = []
var _priorities: Array[int] = []
var _last_played: Dictionary = {}


func _ready() -> void:
	name = "CombatAudio"
	# Headless fixed-fps runs have no audible output and can outrun the dummy
	# mixer's release queue. Still build every PCM resource for validation.
	if DisplayServer.get_name() == "headless":
		enabled = false
	for kind in SOUND_SPECS:
		_streams[kind] = _synthesize(str(kind), SOUND_SPECS[kind])
	for index in range(MAX_VOICES):
		var voice := AudioStreamPlayer.new()
		voice.name = "Voice%d" % index
		add_child(voice)
		_voices.append(voice)
		_started.append(0)
		_priorities.append(0)


func play_sound(kind: String) -> void:
	if not enabled or not _streams.has(kind) or _voices.is_empty():
		return
	var now := Time.get_ticks_msec()
	# One hit may contact a whole pack. Keep its timbre, rather than stacking noise.
	var minimum_gap := 48 if kind in ["light", "heavy", "launch", "death"] else 25
	if now - int(_last_played.get(kind, -1000)) < minimum_gap:
		return
	var spec: Array = SOUND_SPECS[kind]
	var priority := int(spec[5])
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
	var voice := _voices[selected]
	voice.stop()
	voice.stream = _streams[kind]
	voice.volume_db = float(spec[4])
	voice.pitch_scale = 1.0 if kind in ["wave", "victory", "ui"] else randf_range(0.97, 1.05)
	_started[selected] = now
	_priorities[selected] = priority
	_last_played[kind] = now
	voice.play()


func stop_all() -> void:
	for voice in _voices:
		voice.stop()
		voice.stream = null
	_last_played.clear()


func _exit_tree() -> void:
	# Audio playbacks can outlive the scene by one mixer quantum. Detach streams
	# before the child players leave the tree, then release the generated cache.
	stop_all()
	_streams.clear()
	_voices.clear()
	_started.clear()
	_priorities.clear()


func _synthesize(kind: String, spec: Array) -> AudioStreamWAV:
	var duration := float(spec[0])
	var start_frequency := float(spec[1])
	var end_frequency := float(spec[2])
	var noise_amount := float(spec[3])
	var count := ceili(duration * SAMPLE_RATE)
	var data := PackedByteArray()
	data.resize(count * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = kind.hash()
	var phase := 0.0
	var filtered_noise := 0.0
	for index in range(count):
		var time := float(index) / SAMPLE_RATE
		var progress := time / duration
		var frequency := lerpf(start_frequency, end_frequency, progress)
		phase += TAU * frequency / SAMPLE_RATE
		var noise := rng.randf_range(-1.0, 1.0)
		filtered_noise = lerpf(filtered_noise, noise, 0.42)
		var attack := minf(1.0, time / 0.003)
		var release := minf(1.0, (duration - time) / 0.012)
		var envelope := attack * release * exp(-progress * 5.0)
		var body := sin(phase) * 0.62 + sin(phase * 1.47) * 0.18
		var sample := (body * (1.0 - noise_amount * 0.6) + filtered_noise * noise_amount) * envelope
		match kind:
			"swing":
				var swoosh := sin(PI * progress)
				sample = filtered_noise * swoosh * swoosh * (1.0 - progress) * 0.95
			"guard":
				sample = (sin(phase) * 0.35 + sin(phase * 2.73) * 0.25 +
					sin(phase * 4.11) * 0.12 + noise * exp(-time * 90.0) * 0.35) * envelope
			"heavy", "hurt":
				sample += sin(TAU * 58.0 * time) * exp(-time * 24.0) * 0.32 * attack * release
			"skill", "launch":
				sample = (sin(phase) * 0.42 + sin(phase * 2.0) * 0.16 +
					filtered_noise * noise_amount) * sin(PI * progress) * release * 0.65
			"wave", "victory":
				sample = _cue_sample(kind, time) * release
			"ui":
				sample = sin(phase) * envelope * 0.7
		var value := roundi(clampf(sample, -0.92, 0.92) * 32767.0)
		data[index * 2] = value & 0xff
		data[index * 2 + 1] = (value >> 8) & 0xff
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream


func _cue_sample(kind: String, time: float) -> float:
	var notes: Array = [220.0, 329.63, 440.0] if kind == "wave" else [261.63, 329.63, 392.0, 523.25]
	var step := 0.13 if kind == "wave" else 0.19
	var result := 0.0
	for index in range(notes.size()):
		var local_time := time - float(index) * step
		if local_time < 0.0:
			continue
		var note_envelope := minf(1.0, local_time / 0.005) * exp(-local_time * 12.0)
		var note_phase := TAU * float(notes[index]) * local_time
		result += (sin(note_phase) + sin(note_phase * 2.0) * 0.16) * note_envelope * 0.33
	return result
