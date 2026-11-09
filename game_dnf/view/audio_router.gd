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
var music_paths: Dictionary = {}
var dungeon_music: Dictionary = {}
var _last: Dictionary = {}
var _cursor := 0
const SAME_KEY_THROTTLE_MS := 50

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

func play_dungeon_music(dungeon: String, boss: bool, volume_db: float) -> void:
	_ensure_music_manifest()
	var tracks: Dictionary = dungeon_music.get(dungeon,{})
	play_music(String(tracks.get("boss" if boss else "normal","")),volume_db)

func has_dungeon_music(dungeon: String) -> bool:
	_ensure_music_manifest()
	var tracks: Dictionary = dungeon_music.get(dungeon,{})
	return music_paths.has(tracks.get("normal","")) and music_paths.has(tracks.get("boss",""))

## 按 data/bgm.json 的键播放原版曲目（曲目已随仓库分发，循环由流自身负责）。
func play_music(key: String, volume_db := -28.0) -> void:
	_ensure_music_manifest()
	var stream := _music_stream(key)
	if stream == null:return
	if music.stream == stream and music.playing:return
	music.volume_db = volume_db
	music.stream = stream
	music.play()

func _ensure_music_manifest() -> void:
	if not music_paths.is_empty() or not FileAccess.file_exists("res://data/bgm.json"):return
	var doc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/bgm.json"))
	dungeon_music = doc.get("dungeons",{})
	for key: String in doc.get("tracks", {}):
		var path := "res://assets_local/" + String(doc["tracks"][key]["file"])
		if not ResourceLoader.exists(path):continue
		music_paths[key] = path

func _music_stream(key: String) -> AudioStream:
	if music_bank.has(key):return music_bank[key]
	if not music_paths.has(key):return null
	var stream := load(String(music_paths[key])) as AudioStream
	if stream is AudioStreamOggVorbis:(stream as AudioStreamOggVorbis).loop = true
	music_bank[key] = stream
	return stream

## Release streams before the node leaves so no Ogg playback outlives the scene.
func _exit_tree() -> void:
	music.stop()
	music.stream = null
	for voice: AudioStreamPlayer in voice_pool:
		voice.stop()
		voice.stream = null
	sound_streams.clear()
	variants.clear()
	music_bank.clear()
	music_paths.clear()

func on_cue(event: Dictionary) -> void:
	if String(event.get("kind","")) == "sound":play(String(event["key"]))

func play(key: String) -> void:
	if muted:return
	var stream: AudioStream = null
	if variants.has(key) and not variants[key].is_empty():stream = variants[key][randi()%variants[key].size()]
	elif sound_streams.has(key):stream = sound_streams[key]
	if stream == null:return
	var now := Time.get_ticks_msec()
	if now-int(_last.get(key,-1000))<SAME_KEY_THROTTLE_MS:return
	_last[key] = now
	var voice: AudioStreamPlayer = null
	for i in voice_pool.size():
		var candidate := voice_pool[(_cursor+i)%voice_pool.size()] as AudioStreamPlayer
		if not candidate.playing:
			voice = candidate
			_cursor = (_cursor+i+1)%voice_pool.size()
			break
	if voice == null:
		# Never cut a longer line just because the voice pool is momentarily busy.
		return
	voice.stream = stream
	# Conservative peak budget, even before source PCM normalization:
	# 8*10^(-21/20)+10^(-28/20)=0.753 < 0.86 (assuming peak <= 1).
	voice.volume_db = -23 if key.begins_with("goblin") else -21
	voice.play()
