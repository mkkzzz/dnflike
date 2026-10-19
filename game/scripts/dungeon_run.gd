class_name DungeonRun
extends RefCounted
## 副本运行状态：布局数据、房间推进、刷怪/实体/门计划。
## 纯数据与逻辑，不创建节点也不接触渲染，便于回归直接断言。

var dungeon: Dictionary = {}
var room_index := 0
var cleared := false
## 已清空的房间（按 0 基房间序号）：回退时保持已清状态，不重新刷怪
var cleared_rooms: Dictionary = {}
## 已进入过的房间：小地图只显示这些（加上当前房间的直连邻居）
var visited_rooms: Dictionary = {}
var room_states: Dictionary = {}
var _connections: Array = []


func load_from(config: Dictionary, dungeon_id: String) -> bool:
	dungeon = {}
	room_index = 0
	cleared = false
	cleared_rooms.clear()
	room_states.clear()
	visited_rooms.clear()
	_connections.clear()
	var all = config.get("dungeons", {})
	if not all is Dictionary or not all.has(dungeon_id):
		return false
	var candidate = all[dungeon_id]
	if not candidate is Dictionary or not candidate.get("rooms", []) is Array:
		push_error("[DUNGEON] invalid dungeon rooms: " + dungeon_id)
		return false
	dungeon = candidate.duplicate(true)
	if not _load_connections():
		dungeon = {}
		_connections.clear()
		return false
	return true


func _load_connections() -> bool:
	if not dungeon.has("connections"):
		for index in range(room_count() - 1):
			_connections.append({
				"id": "adjacent_%d_%d" % [index, index + 1],
				"from": index, "from_side": "right",
				"to": index + 1, "to_side": "left",
			})
		return true
	var configured = dungeon["connections"]
	if not configured is Array:
		push_error("[DUNGEON] connections must be an array: " + id())
		return false
	var ids: Dictionary = {}
	var occupied_sides: Dictionary = {}
	var opposite := {"right": "left", "left": "right", "up": "down", "down": "up"}
	for value in configured:
		if not value is Dictionary:
			push_error("[DUNGEON] connection must be a dictionary: " + id())
			return false
		var connection: Dictionary = value
		var connection_id = connection.get("id", null)
		if not connection_id is String or connection_id.is_empty() or ids.has(connection_id):
			push_error("[DUNGEON] invalid or duplicate connection id: " + str(connection_id))
			return false
		var from_value = connection.get("from", null)
		var to_value = connection.get("to", null)
		if not _valid_room_index(from_value) or not _valid_room_index(to_value):
			push_error("[DUNGEON] invalid connection room index: " + connection_id)
			return false
		var from_index := int(from_value)
		var to_index := int(to_value)
		if from_index == to_index:
			push_error("[DUNGEON] connection cannot join a room to itself: " + connection_id)
			return false
		var from_side = connection.get("from_side", null)
		var to_side = connection.get("to_side", null)
		if not from_side is String or not to_side is String or not opposite.has(from_side):
			push_error("[DUNGEON] invalid connection side: " + connection_id)
			return false
		if to_side != opposite[from_side]:
			push_error("[DUNGEON] connection sides must be opposite: " + connection_id)
			return false
		var from_key := "%d:%s" % [from_index, from_side]
		var to_key := "%d:%s" % [to_index, to_side]
		if occupied_sides.has(from_key) or occupied_sides.has(to_key):
			push_error("[DUNGEON] duplicate room side in connection: " + connection_id)
			return false
		ids[connection_id] = true
		occupied_sides[from_key] = true
		occupied_sides[to_key] = true
		_connections.append({
			"id": connection_id,
			"from": from_index, "from_side": from_side,
			"to": to_index, "to_side": to_side,
		})
	return true


func _valid_room_index(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	var number := float(value)
	return is_finite(number) and number >= 0.0 and number < room_count() and number == floor(number)


func connections() -> Array:
	return _connections.duplicate(true)


func room_connections() -> Array:
	var result: Array = []
	for connection in _connections:
		var target_index: int
		var side: String
		var target_side: String
		if int(connection["from"]) == room_index:
			target_index = int(connection["to"])
			side = str(connection["from_side"])
			target_side = str(connection["to_side"])
		elif int(connection["to"]) == room_index:
			target_index = int(connection["from"])
			side = str(connection["to_side"])
			target_side = str(connection["from_side"])
		else:
			continue
		result.append({
			"id": str(connection["id"]), "side": side,
			"target_index": target_index, "target_side": target_side,
			"forward": target_index > room_index,
		})
	return result


func travel(connection_id: String) -> Dictionary:
	for connection in room_connections():
		if str(connection["id"]) != connection_id:
			continue
		room_index = int(connection["target_index"])
		cleared = is_room_cleared(room_index)
		mark_visited(room_index)
		return {
			"room_index": room_index, "side": str(connection["target_side"]),
			"source_side": str(connection["side"]),
			"target_side": str(connection["target_side"]), "id": connection_id,
		}
	push_error("[DUNGEON] connection does not belong to current room: " + connection_id)
	return {}


## 进入某房间时登记；小地图据此只显示走过的地方。
func mark_visited(index: int) -> void:
	if index >= 0 and index < room_count():
		visited_rooms[index] = true


func is_room_visited(index: int) -> bool:
	return bool(visited_rooms.get(index, false))


## 当前房间清空后才开门：此时与它直连的房间（含回程门）才是"可去"的。
## 未清房返回空数组——门是锁的，地图不该提示能走。
func available_rooms() -> Array:
	var out: Array = []
	if not is_room_cleared(room_index):
		return out
	for connection in room_connections():
		out.append(int(connection["target_index"]))
	return out


func save_room_state(index: int, state: Dictionary) -> void:
	room_states[index] = state.duplicate(true)


func room_state(index: int) -> Dictionary:
	var state: Dictionary = room_states.get(index, {})
	return state.duplicate(true)


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
	cleared = is_room_cleared(room_index)
	return true


## 退回上一间（门是双向的）；已是第一间则返回 false。
func retreat() -> bool:
	if room_index <= 0:
		return false
	room_index -= 1
	cleared = is_room_cleared(room_index)
	return true


func mark_room_cleared(index: int) -> void:
	cleared_rooms[index] = true


func is_room_cleared(index: int) -> bool:
	return bool(cleared_rooms.get(index, false))


func has_previous_room() -> bool:
	return room_index > 0


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
			"id": str(spawn.get("id", plan.size())),
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
	for connection in room_connections():
		if not bool(connection["forward"]):
			continue
		var legacy = room().get("door", {})
		var plan: Dictionary = legacy.duplicate(true) if legacy is Dictionary else {}
		plan.merge(connection, true)
		return plan
	return {}
