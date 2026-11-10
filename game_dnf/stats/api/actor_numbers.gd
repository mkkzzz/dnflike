extends RefCounted
## Runtime numeric state; owns temporary effects, never owns persistent profile data.
const Numbers = preload("res://stats/api/numbers.gd")
const STATUS_ROLL_SIZE := 10000
# etc/activestatustable_ex.etc stores probability and power rates as 500 and 100.
const STATUS_LEVEL_PROBABILITY_RATE := 5.0
const STATUS_LEVEL_DURATION_RATE := 1.0
const NATIVE_PERCENT := 0.009999999776482582
var base: Dictionary = {}
var seed: Dictionary = {}
var values: Dictionary = {}
var sources: Dictionary = {}
var effects = Numbers.Effects.new()
var config: Dictionary = Numbers.shared_config()
var element := "none"
var runtime_modifiers: Array = []
var weapon_attack_speed_per_mille := 0
var _modifiers_pending := false

func configure(spec: Dictionary) -> void:
	base = spec.get("numbers",{}).duplicate(true)
	seed = spec.get("number_seed",{}).duplicate(true)
	element = String(spec.get("element","none"))
	weapon_attack_speed_per_mille = 0
	for modifier: Dictionary in seed.get("modifiers",[]):
		if modifier.get("stat","") == "attack_speed" and modifier.has("weapon_attack_speed_per_mille"):
			weapon_attack_speed_per_mille = int(modifier["weapon_attack_speed_per_mille"])
	recalculate()

func native_non_weapon_attack_rate() -> float:
	# 81456B..814597 subtracts the raw EQU bonus from the speed multiplier,
	# then converts the result to an integer rate. The local base is 1000.
	var deduction := native_scalar(native_scalar(float(weapon_attack_speed_per_mille))*native_scalar(0.001))
	var multiplier := native_scalar(native_scalar(float(values["attack_speed"]))-deduction)
	return maxi(1,int(native_scalar(multiplier*1000.0)))/1000.0

func recalculate() -> void:
	_modifiers_pending = false
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

func set_runtime_modifiers(value: Array) -> void:
	runtime_modifiers = value.duplicate(true)
	recalculate()

## Ordinary dungeon freeze, 0x8AC500 -> 0x8146A0 -> 0x8ADBB0 (enum 1).
func source_freeze_duration(chance: float, status_level: int, duration_ms: int, roll: int) -> int:
	if status_level <= 0:return 0
	var level_delta := status_level-int(values.get("level",1))
	if not source_status_lands(chance,level_delta,int(values.get("abnormal_resistance",0)),roll):return 0
	return maxi(0,int(native_scalar(duration_ms*native_level_rate(level_delta,STATUS_LEVEL_DURATION_RATE))))

## Enum 11 uses the target's bleeding resistance and keeps the submitted duration.
func apply_source_bleed(source: Dictionary, roll: int, from_player := false, source_entity_id := -1) -> bool:
	var level := int(source["status_level"])
	var delta := level-int(values.get("level",1))
	var resistance := int(values.get("bleeding_resistance",0))+int(values.get("abnormal_resistance",0))
	if level <= 0 or not source_status_lands(float(source["chance"]),delta,resistance,roll):return false
	if source.has("source_bleed_total"):
		return effects.add_source_bleed(int(source["source_bleed_total"]),int(source["duration_ms"]),level,from_player,source_entity_id)
	var bleed: Dictionary = config["effects"]["bleed"].duplicate(true)
	bleed["duration_ms"] = int(source["duration_ms"])
	bleed["status_level"] = level
	return effects.add("bleed",bleed)

## Enum 6 retains the submitted duration and uses the lightning resistance slot.
func apply_source_shock(source: Dictionary, roll: int) -> bool:
	var level := int(source["status_level"])
	var delta := level-int(values.get("level",1))
	var resistance := int(values.get("lightning_resistance",0))+int(values.get("abnormal_resistance",0))
	if level <= 0 or not source_status_lands(float(source["chance"]),delta,resistance,roll):return false
	return effects.add_source_shock(int(source["source_shock_amount"]),int(source["duration_ms"]),int(source["hit_ms"]))

## Enum 8 shares the original level-duration branch with freeze, but reads
## its own resistance slot and refuses a second application while active.
func apply_source_sleep(source: Dictionary, roll: int) -> bool:
	if effects.active.has("sleep"):return false
	var level := int(source["status_level"])
	var delta := level-int(values.get("level",1))
	var resistance := int(values.get("sleep_resistance",0))+int(values.get("abnormal_resistance",0))
	if level <= 0 or not source_status_lands(float(source["chance"]),delta,resistance,roll):return false
	var duration := int(native_scalar(int(source["duration_ms"])*native_level_rate(delta,STATUS_LEVEL_DURATION_RATE)))
	return duration > 0 and effects.add("sleep",{"name":"睡眠","control":"sleep","status_level":level,"duration_ms":duration})

func sleep_age() -> float:
	var sleep: Dictionary = effects.active.get("sleep",{})
	return -1.0 if sleep.is_empty() else float(sleep["definition"]["duration_ms"])-float(sleep["remaining_ms"])

## Item self-stun has already passed its percent roll. Enum 3 shares the
## native signed level-difference duration branch with freeze and sleep.
func apply_item_stun(status_level: int, duration_ms: int) -> bool:
	var level_delta := status_level-int(values.get("level",1))
	var duration := int(native_scalar(duration_ms*native_level_rate(level_delta,STATUS_LEVEL_DURATION_RATE)))
	return duration>0 and effects.add("stun",{"name":"眩晕","control":"stun","status_level":status_level,"duration_ms":duration})

func apply_khazan_drive(source: Dictionary) -> bool:
	var added := effects.add("khazan_drive",{"name":"卡赞冲波","duration_ms":source["duration_ms"],
		"modifiers":[{"stat":"strength","op":"add","value":source["strength"]},
			{"stat":"intelligence","op":"add","value":source["intelligence"]}]})
	if added:recalculate()
	return added

func apply_bloodlust_strength(rank: int, saw_bleed: bool) -> bool:
	var row: Array = Numbers.Skills.sample(Numbers.record("grabblastblood"),rank)["level_row"]
	if rank <= 0 or row.size() < 6:return false
	# CB6FAD and CB6FD6 select duration, CB6FF6 reads the strength grant.
	var added := effects.add_timed_modifier("bloodlust_strength","嗜魂之手","strength",int(row[3]),int(row[5 if saw_bleed else 2]))
	if added:recalculate()
	return added

func apply_blood_memory_resistance(source: Dictionary) -> void:
	var amount := int(source["amount"])
	if amount == 0:return
	# 928B70 attaches first; 82A2D0 rebuilds the cached resistance on actor update.
	if effects.add_timed_modifier("blood_memory_resistance","鲜血之忆","bleeding_resistance",-amount,int(source["duration_ms"])):
		_modifiers_pending = true

## Blind uses its own resistance index and scales both payloads before storage.
## 8AE001 scales the duration and 8B535C only replaces a strictly weaker entry.
func apply_source_blind(source: Dictionary, roll: int) -> bool:
	var level := int(source["level"])
	var level_delta := level-int(values.get("level",1))
	var resistance := int(values.get("blind_resistance",0))+int(values.get("abnormal_resistance",0))
	if level <= 0 or not source_status_lands(float(source["chance"]),level_delta,resistance,roll):return false
	var rate := native_level_rate(level_delta,STATUS_LEVEL_DURATION_RATE)
	var duration := int(native_scalar(int(source["duration_ms"])*rate))
	if duration <= 0:return false
	var vision := int(native_scalar(int(source["vision_percent"])*rate))
	var stuck := int(native_scalar(int(source["stuck_percent"])*rate))
	var active: Dictionary = effects.active.get("blind",{}).get("definition",{})
	if not active.is_empty() and (vision+stuck)*duration <= (int(active["vision_percent"])+int(active["stuck_percent"]))*int(active["duration_ms"]):return false
	return effects.add("blind",{"name":"失明","duration_ms":duration,"status_level":level,
		"vision_percent":vision,"stuck_percent":stuck})

## 80DB70 skips the role level correction for an environmental source.
func apply_environment_poison(source: Dictionary, roll: int) -> bool:
	var resistance := int(float(values.get("poison_resistance",0))+float(values.get("abnormal_resistance",0)))
	var percent := native_scalar(native_scalar(float((100-resistance)*int(source["chance_percent"])))/100.0)
	if roll >= native_scalar(percent*100.0):return false
	effects.add_source_poison(int(source["total_damage"]),int(source["duration_ms"]))
	return true

static func source_status_lands(chance: float, level_delta: int, resistance: int, roll: int) -> bool:
	var base_percent := native_scalar(chance*100.0)
	var probability_rate := native_level_rate(level_delta,STATUS_LEVEL_PROBABILITY_RATE)
	var adjusted_percent := maxf(0.0,native_scalar(base_percent*probability_rate))
	var resisted_percent := native_scalar(native_scalar(adjusted_percent*(100.0-resistance))/100.0)
	return roll < native_scalar(resisted_percent*100.0)

static func native_level_rate(level_delta: int, rate: float) -> float:
	return native_scalar(1.0+native_scalar(native_scalar(level_delta*rate)*NATIVE_PERCENT))

static func native_scalar(value: float) -> float:
	return PackedFloat32Array([value])[0]

func weapon_wear_units(passive_rank: int) -> int:
	var overdrive: Dictionary = effects.active.get("overdrive",{})
	var rate := int(overdrive.get("definition",{}).get("weapon_wear_percent",100))
	var reduction := 0
	if passive_rank > 0:
		var row: Array = Numbers.Skills.sample(Numbers.record("durabilityup"),passive_rank)["level_row"]
		if not row.is_empty():reduction = int(row[0])
	return scale_weapon_wear(Numbers.WEAR_UNITS_PER_HIT,rate,reduction)

static func scale_weapon_wear(base: int, overdrive_percent: int, reduction: int) -> int:
	# CA1DE0 truncates after Overdrive, then again after Weapon Conservation.
	@warning_ignore("integer_division")
	var increased := base*overdrive_percent/100
	@warning_ignore("integer_division")
	return increased*(100-reduction)/100

func add_effect(id: String, rank := 1, parameters: Dictionary = {}) -> bool:
	if not config["effects"].has(id):return false
	var definition: Dictionary = config["effects"][id].duplicate(true)
	if definition.has("source_skill") and not sample_source_effect(definition,rank):return false
	if id == "thirst":
		var tier := clampi(int(parameters.get("charge_tier",0)),0,10)
		for mod: Dictionary in definition["modifiers"]:
			mod["value"] *= tier
	# Per-hit source values belong to this application, never the shared template.
	for field: String in ["duration_ms","status_level"]:
		if parameters.has(field):definition[field] = parameters[field]
	var abnormal: bool = definition.has("control") or float(definition.get("tick_damage",0))>0 or bool(definition.get("harmful",false))
	definition["duration_ms"] = float(definition.get("duration_ms",0))*(1-clampf(float(values.get("status_resist",0)),0,1) if abnormal else 1.0)
	if float(definition["duration_ms"])<=0 and not definition.has("hp_drain_per_second"):return false
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
	if definition.has("hp_drain_level_row"):
		var drain_column := int(definition["hp_drain_level_row"])
		if not valid_source_column(row,drain_column) or float(row[drain_column])<=0:return false
		# CA4BC1 samples the Frenzy HP drain in tenths per second.
		definition["hp_drain_per_second"] = native_scalar(float(row[drain_column])*native_scalar(0.1))
	else:
		var duration_column := int(definition.get("duration_level_row",-1))
		if not valid_source_column(row,duration_column):return false
		definition["duration_ms"] = float(row[duration_column])
	if definition.has("weapon_wear_level_row"):
		var wear_column := int(definition["weapon_wear_level_row"])
		if not valid_source_column(row,wear_column):return false
		definition["weapon_wear_percent"] = int(row[wear_column])
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

func step(ms: float, sleep_on_ground := true, active_bleed_pose := false) -> Array:
	var events: Array = effects.step(ms,sleep_on_ground,active_bleed_pose)
	for event: Dictionary in events:
		if event["type"] in ["removed","modifier_changed"]:
			_modifiers_pending = true
			break
	if _modifiers_pending:recalculate()
	return events

func effective_element() -> String:
	var result := element
	for effect: Dictionary in effects.active.values():
		if effect["definition"].has("element"):result = effect["definition"]["element"]
	return result
