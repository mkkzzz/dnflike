extends RefCounted
## Versioned definitions, never player progress. Reject unsupported content at load.
const TYPES := ["meet_npc", "kill_monster", "clear_dungeon", "collect_item", "learn_skill", "disassemble_item"]
var config: Dictionary = {}
var definitions: Dictionary = {}
var errors: Array[String] = []

func _init(data: Dictionary = {}) -> void:
	if data.is_empty():
		var decoded = JSON.parse_string(FileAccess.get_file_as_string("res://data/quests.json"))
		if not decoded is Dictionary:
			errors.append("任务配置无法读取")
			return
		data = decoded
		data["quests"].append_array(preload("res://content/native_catalog.gd").runtime().get("quests",[]))
		data["quests"].append_array(preload("res://content/native_catalog.gd").quest_rules().get("quests",[]))
		data["dungeons"].merge(preload("res://content/native_catalog.gd").quest_rules().get("dungeons",{}),false)
		data["calendar"]=preload("res://content/native_catalog.gd").quest_rules().get("calendar",{})
	config = data.duplicate(true)
	for key in ["npcs", "dungeons", "limits"]:
		if not config.get(key) is Dictionary:
			errors.append("任务注册表无效：" + key)
			return
	if config.get("schema") != "dnf_quests/1" or not config.get("quests") is Array:
		errors.append("任务配置版本不支持")
		return
	for value in config["quests"]:
		if not value is Dictionary or not value.get("id") is String or value["id"].is_empty():
			errors.append("任务标识无效")
			continue
		var id: String = value["id"]
		if definitions.has(id):
			errors.append("任务标识重复：" + id)
			continue
		definitions[id] = value
		validate_definition(value)
	for id: String in definitions:
		var required_ids = definitions[id].get("requires", [])
		if not required_ids is Array:continue
		for required in required_ids:
			if not required is String or not definitions.has(required):errors.append("任务前置不存在：" + id)
		walk_dependencies(id, [])
	var limits = config.get("limits", {})
	var calendar=config.get("calendar",{})
	if not calendar is Dictionary or not whole(calendar.get("utc_offset_minutes",480),-720,840) or not whole(calendar.get("reset_hour",0),0,23):errors.append("每日任务日历无效")
	if not limits is Dictionary or not whole(limits.get("active"), 1, 100) or not whole(limits.get("tracked"), 1, 10):errors.append("任务容量配置无效")

func validate_definition(q: Dictionary) -> void:
	var id: String = q["id"]
	if q.get("lifecycle","once") not in ["once","repeat","daily"]:errors.append("任务周期无效："+id)
	var eligibility=q.get("eligibility",{})
	if not eligibility is Dictionary:errors.append("任务职业资格无效："+id)
	else:
		for field: String in eligibility:
			if field not in ["jobs","grow_types"] or not eligibility[field] is Array or eligibility[field].is_empty():errors.append("任务职业资格无效："+id);continue
			for value in eligibility[field]:
				if not whole(value,-1,30):errors.append("任务职业资格无效："+id)
	for key in ["name", "description", "giver", "receiver", "category"]:
		if not q.get(key) is String or q[key].is_empty():errors.append("任务字段无效：" + id + "/" + key)
	for key in ["enabled", "abandonable"]:
		if not q.get(key) is bool:errors.append("任务开关无效：" + id)
	if not whole(q.get("min_level"), 1, 999) or not q.get("requires") is Array:errors.append("任务前置配置无效：" + id)
	if not config.get("npcs", {}).has(q.get("giver")) or not config.get("npcs", {}).has(q.get("receiver")):errors.append("任务人物不存在：" + id)
	var objectives = q.get("objectives", [])
	if not objectives is Array or objectives.is_empty():
		errors.append("任务缺少目标：" + id)
		return
	var seen := {}
	for o in objectives:
		if not o is Dictionary or not o.get("id") is String or o["id"].is_empty() or seen.has(o["id"]):
			errors.append("任务目标标识无效：" + id)
			continue
		seen[o["id"]] = true
		if o.has("conditions") and (o.get("type")!="clear_dungeon" or not preload("res://quests/clear_conditions.gd").valid(o["conditions"])):errors.append("任务通关条件无效："+id)
		if o.get("type")=="disassemble_item" and not config["npcs"].has(o.get("npc")):errors.append("分解任务人物无效："+id)
		if o.get("type") not in TYPES or not whole(o.get("amount"), 1, 1000000) or not o.get("target") is String or o.get("target", "").is_empty():errors.append("任务目标不支持：" + id)
		if o.has("dungeon") and not config["dungeons"].has(o["dungeon"]) and not (o["dungeon"]=="any" and o.has("allowed_dungeons")):errors.append("任务范围地下城不存在：" + id)
		if o.has("allowed_dungeons"):
			if not o["allowed_dungeons"] is Array or o["allowed_dungeons"].is_empty():errors.append("任务地下城范围无效："+id)
			else:
				for key in o["allowed_dungeons"]:
					if not config["dungeons"].has(key):errors.append("任务地下城范围不存在："+id)
		if o.has("difficulty") and (not o["difficulty"] is Array or o["difficulty"].is_empty()):errors.append("任务难度范围无效：" + id)
		elif o.has("difficulty"):
			for mode in o["difficulty"]:
				if mode not in ["normal","adventure","king"]:errors.append("任务难度不支持："+id)
		if o.get("type")=="learn_skill" and o.get("target")!="any":errors.append("技能学习目标不支持："+id)
		if o.get("type") == "meet_npc" and not config.get("npcs", {}).has(o["target"]):errors.append("目标人物不存在：" + id)
		if o.get("type") == "clear_dungeon" and not config.get("dungeons", {}).has(o["target"]) and not (o["target"]=="any" and o.has("allowed_dungeons")):errors.append("目标地下城不存在：" + id)
	var reward = q.get("reward", {})
	var drops=q.get("drops",[])
	if not drops is Array:errors.append("任务掉落表无效："+id)
	else:
		for rule in drops:
			if not rule is Dictionary:errors.append("任务掉落规则无效："+id);continue
			if not rule.get("monster") is String or rule["monster"].is_empty() or not config["dungeons"].has(rule.get("dungeon","")):errors.append("任务掉落目标无效："+id)
			if not rule.get("item") is String or not preload("res://items/catalog.gd").ITEMS.has(rule.get("item","")):errors.append("任务掉落物品不存在："+id)
			if not whole(rule.get("chance"),1,100) or not whole(rule.get("amount"),1,9999) or not whole(rule.get("limit"),1,9999):errors.append("任务掉落数量无效："+id)
			if not rule.get("difficulty") is Array or rule["difficulty"].is_empty():errors.append("任务掉落难度无效："+id)
			else:
				for mode in rule["difficulty"]:
					if mode not in ["normal","adventure","king"]:errors.append("任务掉落难度不支持："+id)
	if not reward is Dictionary:
		errors.append("任务奖励无效：" + id)
		return
	for key in ["gold", "xp"]:
		if not whole(reward.get(key), 0, 1000000000):errors.append("任务奖励数值无效：" + id)
	var conditional=reward.get("conditional_items",[])
	if not conditional is Array:errors.append("任务职业奖励无效："+id)
	else:
		for row in conditional:
			if not row is Dictionary or not row.get("item") is String or row["item"].is_empty() or not whole(row.get("amount"),1,999999):
				errors.append("任务职业奖励条目无效："+id);continue
			for field: String in ["jobs","grow_types"]:
				if not row.get(field) is Array or row[field].is_empty():errors.append("任务职业条件无效："+id)
				else:
					for value in row[field]:
						if not whole(value,-1,30):errors.append("任务职业条件无效："+id)
	for bag in [q.get("consume"), reward.get("items")]:
		if not bag is Dictionary:errors.append("任务物品表无效：" + id)
		else:
			for item in bag:
				if not item is String or not whole(bag[item], 1, 999999):errors.append("任务物品数量无效：" + id)
	var choices = reward.get("choices")
	if not choices is Array:errors.append("任务选奖无效：" + id)
	else:
		var ids := {}
		for choice in choices:
			if not choice is Dictionary or not choice.get("id") is String or choice["id"].is_empty() or ids.has(choice["id"]) or not choice.get("item") is String or choice["item"].is_empty() or not whole(choice.get("amount"), 1, 999999):errors.append("任务选奖条目无效：" + id)
			else:ids[choice["id"]] = true

func walk_dependencies(id: String, path: Array) -> void:
	if id in path:
		errors.append("任务前置存在循环：" + id)
		return
	path = path.duplicate()
	path.append(id)
	var required_ids = definitions[id].get("requires", [])
	if not required_ids is Array:return
	for required in required_ids:
		if required is String and definitions.has(required):walk_dependencies(required, path)

static func whole(value, low: int, high: int) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) == floorf(float(value)) and value >= low and value <= high
