extends RefCounted
## Runtime numeric state; owns temporary effects, never owns persistent profile data.
const Numbers = preload("res://stats/api/numbers.gd")
var base: Dictionary = {}
var seed: Dictionary = {}
var values: Dictionary = {}
var sources: Dictionary = {}
var effects = Numbers.Effects.new()
var config: Dictionary = Numbers.shared_config()
var element := "none"
var runtime_modifiers: Array = []

func configure(spec: Dictionary) -> void:
	base = spec.get("numbers",{}).duplicate(true)
	seed = spec.get("number_seed",{}).duplicate(true)
	element = String(spec.get("element","none"))
	recalculate()

func recalculate() -> void:
	var cfg := config.duplicate()
	var mods: Array = effects.modifiers()+runtime_modifiers.duplicate(true)
	var level := int(base.get("level",1))
	var growtype := "swordman"
	if not seed.is_empty():
		level = int(seed["level"])
		growtype = String(seed["growtype"])
		mods = seed["modifiers"].duplicate(true)+mods
	else:
		cfg["base"] = base.duplicate(true)
		cfg["growth"] = {}
		cfg["growtypes"] = {}
	var result := Numbers.Attributes.calculate(level,growtype,mods,cfg)
	values = result["values"]
	sources = result["sources"]
	for effect: Dictionary in effects.active.values():
		var bonus := float(effect.get("definition",{}).get("weapon_attack",0))
		if bonus != 0:
			values["physical_attack"] = float(values["physical_attack"])+bonus
			values["magical_attack"] = float(values["magical_attack"])+bonus
			sources["physical_attack"].append({"source":effect["definition"].get("name","武器增益"),"op":"add","value":bonus})
			sources["magical_attack"].append({"source":effect["definition"].get("name","武器增益"),"op":"add","value":bonus})

func set_runtime_modifiers(value: Array) -> void:
	runtime_modifiers = value.duplicate(true)
	recalculate()

func add_effect(id: String, rank := 1, parameters: Dictionary = {}) -> bool:
	if not config["effects"].has(id):return false
	var definition: Dictionary = config["effects"][id].duplicate(true)
	if definition.has("source_skill") and not sample_source_effect(definition,rank):return false
	# Per-hit source values belong to this application, never the shared template.
	# status_level is retained for the still-unresolved native resistance formula.
	for field: String in ["duration_ms","status_level"]:
		if parameters.has(field):definition[field] = parameters[field]
	var abnormal: bool = definition.has("control") or float(definition.get("tick_damage",0))>0 or bool(definition.get("harmful",false))
	definition["duration_ms"] = float(definition.get("duration_ms",0))*(1-clampf(float(values.get("status_resist",0)),0,1) if abnormal else 1.0)
	if float(definition["duration_ms"])<=0:return false
	if not effects.add(id,definition,rank):return false
	recalculate()
	return true

## Resolve verified SKL column bindings once per application, into its private copy.
## Missing source/columns reject the application; never fall back to invented values.
func sample_source_effect(definition: Dictionary, rank: int) -> bool:
	var source := Numbers.record(String(definition["source_skill"]))
	if source.is_empty() or rank <= 0 or rank > int(source.get("max_level",0)):return false
	var context: Dictionary = source.get("dungeon",{})
	var info: Array = context.get("level_info",source.get("level_info",[]))
	if info.is_empty():return false
	var columns := int(info[0])
	if columns <= 0 or (info.size()-1)%columns != 0 or rank*columns >= info.size():return false
	var row: Array = Numbers.Skills.sample(source,rank)["level_row"]
	var duration_column := int(definition.get("duration_level_row",-1))
	if not valid_source_column(row,duration_column):return false
	definition["duration_ms"] = float(row[duration_column])
	for mod: Dictionary in definition.get("modifiers",[]):
		var column := int(mod.get("level_row",-1))
		if not valid_source_column(row,column):return false
		mod["value"] = float(row[column])*float(mod.get("scale",1.0))
		mod.erase("level_row")
		mod.erase("per_level")
	return true

func valid_source_column(row: Array, column: int) -> bool:
	return column >= 0 and column < row.size() and (row[column] is int or row[column] is float) and is_finite(float(row[column]))

func remove_effect(id: String) -> bool:
	var removed: bool = effects.remove(id)
	if removed:recalculate()
	return removed

func step(ms: float) -> Array:
	var events: Array = effects.step(ms)
	for event: Dictionary in events:
		if event["type"] == "removed":
			recalculate()
			break
	return events

func effective_element() -> String:
	var result := element
	for effect: Dictionary in effects.active.values():
		if effect["definition"].has("element"):result = effect["definition"]["element"]
	return result
