extends RefCounted
## One container per combatant. Simulation milliseconds only; no timers or global state.
var active: Dictionary = {}
var poison_revision := 0

func add(id: String, definition: Dictionary, rank := 1) -> bool:
	if definition.is_empty():return false
	var old: Dictionary = active.get(id,{})
	var stacks := 1
	if definition.get("stacking","refresh") == "stack":stacks = mini(int(old.get("stacks",0))+1,int(definition.get("max_stacks",1)))
	var entry := {"id":id,"definition":definition.duplicate(true),"remaining_ms":float(definition.get("duration_ms",0)),"tick_ms":float(old.get("tick_ms",0)),"stacks":stacks,"rank":rank}
	if definition.has("absorb_hits"):entry["absorb_remaining"] = int(definition["absorb_hits"])
	if old.has("source_bleed"):entry["source_bleed"] = old["source_bleed"]
	active[id] = entry
	return true

func remove(id: String) -> bool:
	return active.erase(id)

func add_bloodlust_strength(amount: int, duration_ms: int) -> bool:
	if duration_ms <= 0:return false
	if not active.has("bloodlust_strength"):
		add("bloodlust_strength",{"name":"嗜魂之手"})
		active["bloodlust_strength"]["strength_grants"] = []
	var effect: Dictionary = active["bloodlust_strength"]
	var grants: Array = effect["strength_grants"]
	grants.append({"amount":amount,"remaining_ms":float(duration_ms)})
	effect["remaining_ms"] = maxf(float(effect["remaining_ms"]),duration_ms)
	effect["stacks"] = grants.size()
	return true

func add_source_bleed(total: int, duration_ms: int, status_level: int, from_player := false) -> bool:
	if duration_ms <= 0:return false
	if not active.has("bleed"):add("bleed",{"name":"出血"})
	var bleed: Dictionary = active["bleed"]
	if float(bleed["remaining_ms"]) <= 0.0:bleed["stacks"] = 0
	if not bleed.has("source_bleed"):bleed["source_bleed"] = {"applications":[]}
	var source: Dictionary = bleed["source_bleed"]
	# 8B568E resets the shared tick gate. Each timed application keeps its age.
	source["next_tick_ms"] = 0.0
	@warning_ignore("integer_division")
	var ticks := maxi(1,duration_ms/500)
	var amount := int(PackedFloat32Array([float(total)/ticks])[0])
	var application := {"remaining_ms":float(duration_ms),"amount":amount,"status_level":status_level}
	if from_player:application["from_player"] = true
	source["applications"].append(application)
	return true

func add_source_shock(amount: int, duration_ms: int, hit_ms: int) -> bool:
	if duration_ms <= 0 or hit_ms <= 0:return false
	if not active.get("shock",{}).has("source_shock"):
		add("shock",{"name":"感电"})
		active["shock"]["source_shock"] = []
	var shock: Dictionary = active["shock"]
	# 8AF2D5 sets the limit. 8B3626 and 8B3874 admit counter values 0 through the limit.
	@warning_ignore("integer_division")
	var hits_left := duration_ms/hit_ms+1
	shock["source_shock"].append({"remaining_ms":float(duration_ms),"amount":amount,"hits_left":hits_left})
	shock["remaining_ms"] = maxf(float(shock["remaining_ms"]),duration_ms)
	return true

func trigger_source_shock() -> Dictionary:
	var shock: Dictionary = active.get("shock",{})
	if not shock.has("source_shock"):return {}
	var entries: Array = shock["source_shock"]
	var amount := 0
	var display := 0
	for entry: Dictionary in entries:
		amount = int(entry["amount"])
		display += amount
		entry["hits_left"] -= 1
	var remaining := 0.0
	for index in range(entries.size()-1,-1,-1):
		if int(entries[index]["hits_left"]) == 0:
			entries.remove_at(index)
			continue
		remaining = maxf(remaining,float(entries[index]["remaining_ms"]))
	shock["remaining_ms"] = remaining
	if entries.is_empty():active.erase("shock")
	# 8B3928 subtracts the last eligible amount. 8B3987 sends their sum to the display.
	return {"amount":amount,"display":display,"removed":entries.is_empty()}

## 8B5160 appends each poison application with an independent timer and HP ledger.
func add_source_poison(amount: int, duration_ms: int) -> void:
	if not active.has("poison"):
		add("poison",{"name":"中毒","duration_ms":duration_ms})
		active["poison"]["applications"] = []
	var poison: Dictionary = active["poison"]
	var applications: Array = poison["applications"]
	poison_revision += 1
	poison["visual_revision"] = poison_revision
	# 8B5897 resets the shared display counters, while older HP ledgers are untouched.
	poison["display_amount"] = 0
	poison["next_display_ms"] = (float(applications[0]["elapsed_ms"]) if not applications.is_empty() else 0.0)+500.0
	applications.append({"amount":amount,"duration_ms":duration_ms,"elapsed_ms":0.0,"applied":0})
	poison["remaining_ms"] = maxf(float(poison["remaining_ms"]),duration_ms)
	poison["stacks"] = poison["applications"].size()

func poison_visual() -> int:
	return int(active.get("poison",{}).get("visual_revision",0))

func modifiers() -> Array:
	var result: Array = []
	for effect: Dictionary in active.values():
		if effect.has("strength_grants"):
			for grant: Dictionary in effect["strength_grants"]:
				result.append({"stat":"strength","op":"add","value":grant["amount"],"source":effect["definition"]["name"]})
		for mod: Dictionary in effect["definition"].get("modifiers",[]):
			var entry := mod.duplicate(true)
			entry["source"] = effect["definition"].get("name",effect["id"])
			var count := int(effect["stacks"])
			var value := float(mod["value"])+float(mod.get("per_level",0))*(int(effect["rank"])-1)
			entry["value"] = pow(value,count) if mod.get("op","add")=="mul" else value*count
			result.append(entry)
	return result

func flag(key: String) -> bool:
	for effect: Dictionary in active.values():
		if effect["definition"].get(key,false):return true
	return false

func controlled() -> bool:
	return flag("control")

func step(ms: float, sleep_on_ground := true) -> Array:
	var events: Array = []
	for id: String in active.keys():
		if id == "sleep" and not sleep_on_ground:continue
		var effect: Dictionary = active[id]
		if effect.has("strength_grants"):
			step_bloodlust_strength(effect,ms,events)
			continue
		if effect.has("source_bleed"):step_source_bleed(effect,ms,events)
		if effect.has("source_shock"):
			var entries: Array = effect["source_shock"]
			var remaining := 0.0
			for index in range(entries.size()-1,-1,-1):
				entries[index]["remaining_ms"] -= ms
				var duration := float(entries[index]["remaining_ms"])
				if duration <= 0.0:entries.remove_at(index)
				remaining = maxf(remaining,duration)
			effect["remaining_ms"] = remaining
			if entries.is_empty():
				active.erase(id)
				events.append({"type":"removed","id":id})
			continue
		if effect.has("applications"):
			step_source_poison(effect,ms,events)
			continue
		var definition: Dictionary = effect["definition"]
		if definition.has("hp_drain_per_second"):
			step_frenzy_drain(effect,ms,events)
			continue
		if definition.get("action_managed_expiry",false):
			effect["remaining_ms"] = float(effect["remaining_ms"])-ms
			continue
		var duration := maxf(0,minf(ms,float(effect["remaining_ms"])))
		effect["remaining_ms"] = maxf(0,float(effect["remaining_ms"])-ms)
		var interval := float(definition.get("interval_ms",0))
		if interval > 0:
			effect["tick_ms"] = float(effect["tick_ms"])+duration
			while float(effect["tick_ms"]) >= interval:
				effect["tick_ms"] -= interval
				events.append({"type":"tick","id":id,"damage":float(definition.get("tick_damage",0))*int(effect["stacks"]),"damage_type":definition.get("damage_type","physical")})
		if float(effect["remaining_ms"]) <= 0:
			if effect.has("source_bleed"):
				effect["tick_ms"] = 0.0
				effect["stacks"] = 0
			else:
				active.erase(id)
				events.append({"type":"removed","id":id})
	return events

func step_bloodlust_strength(effect: Dictionary, ms: float, events: Array) -> void:
	var grants: Array = effect["strength_grants"]
	var old_count := grants.size()
	var remaining := 0.0
	for index in range(old_count-1,-1,-1):
		grants[index]["remaining_ms"] -= ms
		var duration := float(grants[index]["remaining_ms"])
		if duration <= 0.0:grants.remove_at(index)
		else:remaining = maxf(remaining,duration)
	effect["remaining_ms"] = remaining
	effect["stacks"] = grants.size()
	if grants.is_empty():
		active.erase("bloodlust_strength")
		events.append({"type":"removed","id":"bloodlust_strength"})
	elif grants.size() < old_count:
		events.append({"type":"modifier_changed","id":"bloodlust_strength"})

func step_source_bleed(effect: Dictionary, ms: float, events: Array) -> void:
	var source: Dictionary = effect["source_bleed"]
	var applications: Array = source["applications"]
	source["next_tick_ms"] = float(source["next_tick_ms"])-ms
	# 8B2747 permits the initial update at zero. 8B30C0 schedules from the
	# current age, then 8B4F4F removes expired applications after processing.
	if float(source["next_tick_ms"]) <= 0.0:
		source["next_tick_ms"] = 500.0
		var amount := 0
		var player_amount := 0
		for application: Dictionary in applications:
			var tick := int(application["amount"])
			amount += tick
			if application.get("from_player",false):player_amount += tick
		if amount > 0:
			events.append({"type":"direct_damage","id":"bleed","damage":amount,"damage_type":"physical",
				"native_number":true,"player_bleed":player_amount>0})
	for index in range(applications.size()-1,-1,-1):
		applications[index]["remaining_ms"] -= ms
		if float(applications[index]["remaining_ms"]) <= 0.0:applications.remove_at(index)
	if applications.is_empty():effect.erase("source_bleed")

func step_frenzy_drain(effect: Dictionary, ms: float, events: Array) -> void:
	var previous := float(effect.get("drain_elapsed_ms",0.0))
	var elapsed := previous+ms
	effect["drain_elapsed_ms"] = elapsed
	# 9975C0 uses integer milliseconds and retains the fractional HP between callbacks.
	var rate := float(effect["definition"]["hp_drain_per_second"])
	var weighted_ms := PackedFloat32Array([(int(elapsed)-int(previous))*rate])[0]
	var drain := PackedFloat32Array([weighted_ms*0.0010000000474974513])[0]
	var total := PackedFloat32Array([drain+float(effect.get("drain_fraction",0.0))])[0]
	var amount := int(total)
	effect["drain_fraction"] = total-amount
	if amount>0:events.append({"type":"frenzy_drain","id":effect["id"],"damage":amount})

func step_source_poison(effect: Dictionary, ms: float, events: Array) -> void:
	var remaining: Array = []
	var damage := 0
	var remaining_ms := 0.0
	var applications: Array = effect["applications"]
	var display_clock := float(applications[0]["elapsed_ms"])+ms
	for entry: Dictionary in applications:
		var duration: int = entry["duration_ms"]
		var elapsed := minf(duration,float(entry["elapsed_ms"])+ms)
		# E4BEC0 truncates the cumulative HP loss at the elapsed integer millisecond.
		@warning_ignore("integer_division")
		var cumulative: int = int(entry["amount"])*int(elapsed)/duration
		damage += cumulative-int(entry["applied"])
		if elapsed < duration:
			entry["elapsed_ms"] = elapsed
			entry["applied"] = cumulative
			remaining_ms = maxf(remaining_ms,duration-elapsed)
			remaining.append(entry)
	if damage > 0:
		effect["display_amount"] = int(effect["display_amount"])+damage
		events.append({"type":"direct_damage","id":"poison","damage":damage,"damage_type":"poison"})
	if display_clock >= float(effect["next_display_ms"]):
		var amount: int = effect["display_amount"]
		if amount > 0:events.append({"type":"damage_number","id":"poison","damage":amount})
		effect["display_amount"] = 0
		effect["next_display_ms"] = display_clock+500.0
	effect["applications"] = remaining
	effect["remaining_ms"] = remaining_ms
	effect["stacks"] = remaining.size()
	if remaining.is_empty():
		active.erase("poison")
		events.append({"type":"removed","id":"poison"})

func view() -> Array:
	return active.values().duplicate(true)
