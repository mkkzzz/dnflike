class_name DungeonRun
extends RefCounted
## 副本运行状态：布局数据、房间推进、刷怪/实体/门计划。
## 纯数据与逻辑，不创建节点也不接触渲染，便于回归直接断言。

var dungeon: Dictionary = {}
var room_index := 0
var cleared := false


func load_from(config: Dictionary, dungeon_id: String) -> bool:
	var all: Dictionary = config.get("dungeons", {})
	if not all.has(dungeon_id):
		dungeon = {}
		return false
	dungeon = all[dungeon_id]
	room_index = 0
	cleared = false
	return true


func is_loaded() -> bool:
	return not dungeon.is_empty()


func id() -> String:
	return str(dungeon.get("id", ""))


func display_name() -> String:
	return str(dungeon.get("name", ""))


func layout() -> String:
	return str(dungeon.get("layout", ""))


func asset_root() -> String:
	return str(dungeon.get("asset_root", "res://assets/dungeon/10001/"))


func rooms() -> Array:
	return dungeon.get("rooms", [])


func room_count() -> int:
	return rooms().size()


func room() -> Dictionary:
	var list := rooms()
	if room_index < 0 or room_index >= list.size():
		return {}
	return list[room_index]


func room_number() -> int:
	return room_index + 1


func module_id() -> String:
	return str(room().get("module", ""))


func room_name() -> String:
	return str(room().get("name", ""))


func role() -> String:
	return str(room().get("role", "normal"))


func is_boss_room() -> bool:
	return role() == "boss"


func is_last_room() -> bool:
	return room_index >= room_count() - 1


func background_path() -> String:
	var room_data := room()
	if room_data.is_empty():
		return ""
	return asset_root() + str(room_data.get("background", ""))


func ground_line_ratio() -> float:
	return float(room().get("ground_line_ratio", 0.5))


## 画面里“干净路面”的水平范围（比例）。缺省退回满幅，避免配置漏填就不可走。
func road_left_ratio() -> float:
	return float(room().get("road_left_ratio", 0.0))


func road_right_ratio() -> float:
	return float(room().get("road_right_ratio", 1.0))


## 路面下沿（前景草/植被起点）的比例。每张图不同，景深可动范围靠它逐图取值。
func road_front_ratio() -> float:
	return float(room().get("road_front_ratio", 1.0))


## 推进到下一间；已是最后一间则返回 false 且状态不变。
func advance() -> bool:
	if is_last_room():
		return false
	room_index += 1
	cleared = false
	return true


func monster_plan(base_config: Dictionary, presets: Dictionary) -> Array:
	var plan: Array = []
	for spawn in room().get("monsters", []):
		var cfg: Dictionary = base_config.duplicate(true)
		var preset_name := str(spawn.get("preset", ""))
		if presets.has(preset_name):
			for key in (presets[preset_name] as Dictionary):
				cfg[key] = (presets[preset_name] as Dictionary)[key]
		for key in spawn.get("overrides", {}):
			cfg[key] = spawn["overrides"][key]
		plan.append({
			"cfg": cfg,
			"x": float(spawn.get("x", 900)),
			"depth": float(spawn.get("depth", 0)),
			"preset": preset_name,
		})
	return plan


func entity_plan() -> Array:
	var plan: Array = []
	for item in room().get("entities", []):
		plan.append({
			"id": str(item.get("id", "")),
			"x": float(item.get("x", 0)),
			"depth_y": float(item.get("depth_y", 0)),
		})
	return plan


func door_plan() -> Dictionary:
	var door = room().get("door", null)
	if door == null:
		return {}
	return door as Dictionary
