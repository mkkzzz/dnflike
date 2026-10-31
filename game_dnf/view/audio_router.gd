extends Node
## Plays combat sound cues. Keys are original sound keys (ATK [hit wav], CHR [weapon wav], ANI
## frame events) resolved by tools/build_dnf_combat_assets.py; R_ keys pick a random variant.
## Throttle, voice pool and gain budget are unchanged from the trial battle scene.

var muted := false
var sound_streams: Dictionary = {}
var variants: Dictionary = {}
var voice_pool: Array = []
var music: AudioStreamPlayer
var music_bank: Dictionary = {}
var _last: Dictionary = {}
var _cursor := 0

func setup(audio_assets: Dictionary, combat_audio := {}) -> void:
	for i in 8:
		var voice := AudioStreamPlayer.new()
		voice.volume_db = -15
		add_child(voice)
		voice_pool.append(voice)
	for key: String in audio_assets:
		sound_streams[key] = load("res://assets_local/"+String(audio_assets[key]["file"]))
	for key: String in combat_audio:
		var list: Array = []
		for entry: Dictionary in combat_audio[key]:list.append(load(String(entry["file"])))
		variants[key] = list
	music = AudioStreamPlayer.new()
	music.volume_db = -28
	add_child(music)

## Optional one-shot outside the compiled combat bank, still backed by an original file.
func register(key: String, path: String) -> void:
	if not ResourceLoader.exists(path):return
	var stream = load(path)
	if stream is AudioStream:sound_streams[key] = stream

func start_music(volume_db := -28.0) -> void:
	if music.playing:return
	play_music("forest01", volume_db)

## 按 data/bgm.json 的键播放原版曲目（曲目已随仓库分发，循环由流自身负责）。
func play_music(key: String, volume_db := -28.0) -> void:
	_load_music_bank()
	if not music_bank.has(key):return
	if music.stream == music_bank[key] and music.playing:return
	music.volume_db = volume_db
	music.stream = music_bank[key]
	music.play()

func _load_music_bank() -> void:
	if not music_bank.is_empty() or not FileAccess.file_exists("res://data/bgm.json"):return
	var doc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/bgm.json"))
	for key: String in doc.get("tracks", {}):
		var path := "res://assets_local/" + String(doc["tracks"][key]["file"])
		if not ResourceLoader.exists(path):continue
		var stream = load(path)
		if stream is AudioStreamOggVorbis:stream.loop = true
		music_bank[key] = stream

## Release streams before the node leaves so no Ogg playback outlives the scene.
func _exit_tree() -> void:
	music.stop()
	music.stream = null
	for voice: AudioStreamPlayer in voice_pool:
		voice.stop()
		voice.stream = null
	sound_streams.clear()
	variants.clear()

func on_cue(event: Dictionary) -> void:
	if String(event.get("kind","")) == "sound":play(String(event["key"]))

func play(key: String) -> void:
	if muted:return
	var stream: AudioStream = null
	if variants.has(key) and not variants[key].is_empty():stream = variants[key][randi()%variants[key].size()]
	elif sound_streams.has(key):stream = sound_streams[key]
	if stream == null:return
	var now := Time.get_ticks_msec()
	if now-int(_last.get(key,-1000))<75:return
	_last[key] = now
	var voice: AudioStreamPlayer = voice_pool[_cursor%voice_pool.size()]
	_cursor += 1
	voice.stream = stream
	# Conservative peak budget, even before source PCM normalization:
	# 8*10^(-21/20)+10^(-28/20)=0.753 < 0.86 (assuming peak <= 1).
	voice.volume_db = -23 if key.begins_with("goblin") else -21
	voice.play()
