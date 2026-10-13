class_name GameConfig
extends RefCounted
## 静态配置表加载：moves/skills/monsters/player 全部数据驱动

static var moves: Dictionary = {}
static var skills: Dictionary = {}
static var monsters: Dictionary = {}
static var player: Dictionary = {}

static func load_all() -> void:
	moves = _load_json("res://data/moves.json")
	skills = _load_json("res://data/skills.json")
	monsters = _load_json("res://data/monsters.json")
	player = _load_json("res://data/player.json")
	print("[M1] config loaded: moves=%d skills=%d monsters=%d" % [moves.size(), skills.size(), monsters.size()])

static func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[M1] cannot load config: " + path)
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}
