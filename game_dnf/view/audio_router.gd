extends Node
## Plays combat sound cues. Throttle, voice pool and gain budget are unchanged from the
## trial battle scene; cue keys still come from hand-written adaptation (G10/DNF-D015).

var muted := false
var sound_streams: Dictionary = {}
var voice_pool: Array = []
var music: AudioStreamPlayer
var _last: Dictionary = {}
var _cursor := 0

func setup(audio_assets: Dictionary) -> void:
	for i in 8:
		var voice := AudioStreamPlayer.new()
		voice.volume_db = -15
		add_child(voice)
		voice_pool.append(voice)
	for key: String in audio_assets:
		sound_streams[key] = load("res://assets_local/"+String(audio_assets[key]["file"]))
	music = AudioStreamPlayer.new()
	music.volume_db = -28
	add_child(music)

func start_music() -> void:
	if not sound_streams.has("music"):return
	music.stream = sound_streams["music"]
	music.finished.connect(music.play)
	music.play()

func on_cue(event: Dictionary) -> void:
	if String(event.get("kind","")) == "sound":play(String(event["key"]))

func play(key: String) -> void:
	if muted or not sound_streams.has(key):return
	var now := Time.get_ticks_msec()
	if now-int(_last.get(key,-1000))<75:return
	_last[key] = now
	var voice: AudioStreamPlayer = voice_pool[_cursor%voice_pool.size()]
	_cursor += 1
	voice.stream = sound_streams[key]
	# Conservative peak budget, even before source PCM normalization:
	# 8*10^(-21/20)+10^(-28/20)=0.753 < 0.86 (assuming peak <= 1).
	voice.volume_db = -23 if key.begins_with("goblin") else -21
	voice.play()
