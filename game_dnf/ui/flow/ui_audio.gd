extends Node
## Shared one-shot router for native UI sounds. It binds controls added under the
## managed UI root and keeps event-specific calls out of individual windows.

const MANIFEST := "res://data/ui_sounds.json"
const POOL_SIZE := 6
const DEFAULT_DB := -16.0
const VOLUME_DB := {
	"hover": -22.0,
	"click": -18.0,
	"tab": -18.0,
	"text_input": -21.0,
	"window_open": -17.0,
	"window_close": -17.0,
}
const THROTTLE_MS := {
	"hover": 70,
	"click": 35,
	"tab": 45,
	"text_input": 40,
}

var streams: Dictionary = {}
var pool: Array[AudioStreamPlayer] = []
var play_counts: Dictionary = {}
var muted := false
var _host: Node
var _cursor := 0
var _last: Dictionary = {}

func setup(host: Node) -> void:
	_host = host
	_load_manifest()
	for i in POOL_SIZE:
		var player := AudioStreamPlayer.new()
		player.name = "ui_audio_%d" % i
		player.volume_db = DEFAULT_DB
		add_child(player)
		pool.append(player)
	if not host.get_tree().node_added.is_connected(_on_node_added):
		host.get_tree().node_added.connect(_on_node_added)
	_bind_tree(host)

func _load_manifest() -> void:
	if not FileAccess.file_exists(MANIFEST):return
	var doc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	for key: String in doc.get("sounds", {}):
		var path := "res://assets_local/" + String(doc["sounds"][key].get("file", ""))
		if not ResourceLoader.exists(path):continue
		var stream := load(path) as AudioStream
		if stream != null:streams[key] = stream

func _bind_tree(root: Node) -> void:
	_bind_control(root)
	for child in root.get_children():
		_bind_tree(child)

func _on_node_added(node: Node) -> void:
	if _host == null or (node != _host and not _host.is_ancestor_of(node)):return
	_bind_control(node)

func _bind_control(node: Node) -> void:
	if node is BaseButton:
		var button := node as BaseButton
		if button.get_meta("_ui_audio_bound", false):return
		button.set_meta("_ui_audio_bound", true)
		button.button_down.connect(_on_button_down.bind(button))
		button.mouse_entered.connect(_on_mouse_entered.bind(button))
	elif node is LineEdit:
		var line := node as LineEdit
		if line.get_meta("_ui_audio_bound", false):return
		line.set_meta("_ui_audio_bound", true)
		line.text_changed.connect(func(_text: String): play("text_input"))

func assign(button: BaseButton, key: String, hover_key := "") -> void:
	button.set_meta("ui_sound", key)
	if hover_key != "":button.set_meta("ui_sound_hover", hover_key)

func _on_button_down(button: BaseButton) -> void:
	if button.disabled:return
	play(String(button.get_meta("ui_sound", "click")))

func _on_mouse_entered(button: BaseButton) -> void:
	if button.disabled:return
	var key := String(button.get_meta("ui_sound_hover", "hover"))
	if key != "none":play(key)

## Play a semantic UI cue. Missing streams are ignored so a partial asset install
## never blocks navigation.
func play(key: String) -> void:
	if muted or not streams.has(key):return
	var now := Time.get_ticks_msec()
	var gap := int(THROTTLE_MS.get(key, 0))
	if gap > 0 and now - int(_last.get(key, -10000)) < gap:return
	_last[key] = now
	var player: AudioStreamPlayer = null
	for i in pool.size():
		var candidate := pool[(_cursor + i) % pool.size()]
		if not candidate.playing:
			player = candidate
			_cursor = (_cursor + i + 1) % pool.size()
			break
	if player == null:
		# UI cues are short; recycle the next channel instead of losing a click.
		player = pool[_cursor]
		_cursor = (_cursor + 1) % pool.size()
		player.stop()
	player.stream = streams[key]
	player.volume_db = float(VOLUME_DB.get(key, DEFAULT_DB))
	player.play()
	play_counts[key] = int(play_counts.get(key, 0)) + 1

func play_count(key: String) -> int:
	return int(play_counts.get(key, 0))

func stream_count() -> int:
	return streams.size()

func stop_all() -> void:
	for player in pool:player.stop()

func _exit_tree() -> void:
	stop_all()
	streams.clear()
