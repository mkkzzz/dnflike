extends RefCounted
## Pure numerical pipeline. Rolls are supplied by the caller's deterministic run RNG.
static func resolve(attacker: Dictionary, defender: Dictionary, hit: Dictionary, rolls: Array, formula: Dictionary) -> Dictionary:
	var kind := String(hit.get("damage_type","physical"))
	var magic := kind == "magical"
	var main := float(attacker.get("intelligence" if magic else "strength",0))
	var attack := float(attacker.get("magical_attack" if magic else "physical_attack",0))
	var defense := maxf(0,float(defender.get("magical_defense" if magic else "physical_defense",0)))
	var chance := clampf(float(formula["hit_base"])+float(attacker.get("hit",0))-float(defender.get("evasion",0)),float(formula["hit_min"]),float(formula["hit_max"]))
	var critical := float(rolls[1]) < clampf(float(attacker.get("magical_crit" if magic else "physical_crit",0))+float(hit.get("critical_chance",0)),0,1)
	var main_factor := maxf(0,1+main/float(formula["main_stat_divisor"]))
	var percent := attack*float(hit.get("percent",100))/100
	var fixed := float(hit.get("fixed",0))*float(attacker.get("independent_attack",100))/100
	var defense_k := float(formula["defense_base"])+maxi(1,int(attacker.get("level",1)))*float(formula["defense_per_attacker_level"])
	var defense_factor := 1.0 if hit.get("ignore_defense",false) else defense_k/(defense_k+defense)
	var element_factor := 1.0
	var element := String(hit.get("element","none"))
	if element in ["fire","water","light","dark"]:element_factor = maxf(float(formula["element_min"]),1+(float(attacker.get(element+"_attack",0))-float(defender.get(element+"_resist",0)))/float(formula["element_divisor"]))
	var crit_factor := float(formula["critical_multiplier"]) if critical else 1.0
	var skill_factor := float(attacker.get("skill_rate",1)) if hit.get("skill",false) else 1.0
	var situation := (float(formula["counter_multiplier"]) if hit.get("counter",false) else 1.0)*(float(formula["back_multiplier"]) if hit.get("back",false) else 1.0)
	var raw := ((percent+fixed)*main_factor*defense_factor+float(hit.get("true_damage",0)))*element_factor*crit_factor*skill_factor*float(attacker.get("damage_rate",1))*float(defender.get("taken_rate",1))*situation
	var missed := float(rolls[0]) >= chance
	var amount := 0 if missed or defender.get("immune",false) or raw <= 0 else maxi(int(formula["minimum_damage"]),roundi(raw))
	return {"amount":amount,"critical":critical and not missed,"missed":missed,"category":kind,"element":element,"trace":{"attack":attack,"percent_part":percent,"fixed_part":fixed,"main_factor":main_factor,"defense_factor":defense_factor,"element_factor":element_factor,"critical_factor":crit_factor,"skill_factor":skill_factor,"situation_factor":situation,"hit_chance":chance,"raw":raw,"amount":amount}}
