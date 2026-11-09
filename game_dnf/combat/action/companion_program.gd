extends RefCounted
## Decisions and quick slots from the original AIC/AI/KEY files. The battle
## supplies its current skill eligibility, target state and last hit event.

const PROGRAMS := "res://data/companion_programs.json"
const QUICK_KEYS := "asdfgh"
const DEPTH_RATIO := 0.28999999165534973  # float32(29 * float32(0.01))

static func load_program(source_id: int) -> Dictionary:
	var document = JSON.parse_string(FileAccess.get_file_as_string(PROGRAMS))
	if not document is Dictionary or document.get("schema") != "dnf_companion_programs/1":return {}
	return document.get("companions", {}).get(str(source_id), {})

static func choose(program: Dictionary, entry: String, context: Dictionary) -> Variant:
	var path := String(program.get("ai", {}).get(entry, ""))
	var programs: Dictionary = program.get("programs", {})
	var node: Dictionary = programs.get(path, {}).get("decision", {})
	# The source compiler proves imports acyclic. Bound malformed runtime data as well.
	for _step in 64:
		if node.has("return"):
			var result = node["return"]
			return result if result is String else int(result)
		if node.has("import"):
			path = path.get_base_dir().path_join(String(node["import"]))
			node = programs.get(path, {}).get("decision", {})
		elif node.has("if"):
			node = node["then" if predicate(node["if"],context) else "else"]
		else:break
	return -1

static func predicate(condition: Array, context: Dictionary) -> bool:
	match condition[0]:
		"[check use skill]":return bool(context.get("usable", {}).get(int(condition[1]), false))
		"[check skill on]":return bool(context.get("skill_on", {}).get(int(condition[1]), false))
		"[attack success]":return int(bool(context.get("attack_success", false))) == int(condition[1])
		"[my attack]":return int(context.get("last_attack", -1)) == int(condition[1])
		"[target state]":return int(context.get("target_state", -1)) == int(condition[1])
		"[target distance]":
			return context.has("target_position") and target_distance(context["position"],context["target_position"]) >= float(condition[2])
		"[void]":
			return condition[1] == "is target in attack area()" and context.has("target_position") and _in_attack_area(context,condition)
	return false

static func target_distance(position: Vector2, target: Vector2) -> int:
	# 8DA00C..8DA034 asks the actor's +8 distance with the depth flag clear.
	# 406580 -> 7F10A0 projects Y, truncates it, then truncates the square root.
	var delta := Vector2i(position)-Vector2i(target)
	var depth := int(PackedFloat32Array([float(delta.y)/DEPTH_RATIO])[0])
	return int(sqrt(delta.x*delta.x+depth*depth))

static func _in_attack_area(context: Dictionary, condition: Array) -> bool:
	# 8C9820 reads integer object coordinates, then truncates the bounds.
	# Forward/backward mirror at native facing 0/1; Y is independent of facing.
	var origin := Vector2i(context["position"])
	var target := Vector2i(context["target_position"])
	var right := int(context.get("facing", 1)) > 0
	var behind := float(condition[3] if right else condition[2])
	var ahead := float(condition[2] if right else condition[3])
	return (target.x >= int(origin.x-behind) and target.x <= int(origin.x+ahead)
		and target.y >= int(origin.y-float(condition[4])) and target.y <= int(origin.y+float(condition[5])))

static func stream_skill(program: Dictionary, stream: Variant) -> int:
	if not stream is String:return -1
	var commands: Array = program.get("streams", {}).get(stream, {}).get("commands", [])
	var input_keys := PackedStringArray()
	for command: Array in commands:
		if command[0] != "[input]" or command.size() < 2:continue
		var key := String(command[1])
		if key.begins_with("skill:") and key.substr(6).is_valid_int():return int(key.substr(6))
		if key == "z":return 46
		var slot := QUICK_KEYS.find(key) if key.length() == 1 else -1
		if slot >= 0:
			var slots: Array = program.get("quick_skill", [])
			if slot*2 < slots.size():return int(slots[slot*2])
		if not key.is_empty():input_keys.append(key)
	# APC202 uses the same Guard cast through its directional command.
	if input_keys == PackedStringArray(["down","up","space"]):return 3
	return -1
