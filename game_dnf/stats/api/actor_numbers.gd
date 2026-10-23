extends RefCounted
## Runtime numeric state; owns temporary effects, never owns persistent profile data.
const Numbers = preload("res://stats/api/numbers.gd")
var base: Dictionary = {}
var seed: Dictionary = {}
var values: Dictionary = {}
var sources: Dictionary = {}
var effects = Numbers.Effects.new()
var config: Dictionary = Numbers.config()
var element := "none"

func configure(spec: Dictionary) -> void:
	base = spec.get("numbers",{}).duplicate(true)
	seed = spec.get("number_seed",{}).duplicate(true)
	element = String(spec.get("element","none"))
	recalculate()

func recalculate() -> void:
	var cfg := config.duplicate(true)
	var mods: Array = effects.modifiers()
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

func add_effect(id: String, rank := 1) -> bool:
	if not config["effects"].has(id):return false
	var definition: Dictionary = config["effects"][id].duplicate(true)
	var abnormal: bool = definition.has("control") or float(definition.get("tick_damage",0))>0 or bool(definition.get("harmful",false))
	definition["duration_ms"] = float(definition.get("duration_ms",0))*(1-clampf(float(values.get("status_resist",0)),0,1) if abnormal else 1.0)
	if float(definition["duration_ms"])<=0:return false
	if not effects.add(id,definition,rank):return false
	recalculate()
	return true

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
