extends SceneTree
const Numbers = preload("res://stats/api/numbers.gd")
const Actor = preload("res://stats/api/actor_numbers.gd")
const Session = preload("res://flow/session.gd")
var checks := 0
var failures := 0

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		print("[NUMBERS_TEST] FAIL "+message)

func _initialize() -> void:
	var cfg := Numbers.config()
	var s = Session.new()
	check(Numbers.valid(s.profile),"new profile is valid")
	check(s.stats()["numbers"]["physical_attack"]==25,"starter weapon contributes actual attack")
	check(s.xp_needed()==100,"initial XP requirement")
	var reward: Dictionary = s.command("numbers.xp",{"amount":1000,"transaction":"unit:reward"})
	check(reward["ok"] and reward["levels"]==4 and s.profile["level"]==5 and s.profile["xp"]==0,"one reward can cross multiple levels")
	check(not s.command("numbers.xp",{"amount":1000,"transaction":"unit:reward"})["ok"] and s.profile["level"]==5,"duplicate XP transaction cannot pay twice")
	check(not s.command("numbers.xp",{"amount":-1,"transaction":"negative"})["ok"],"negative experience rejected")
	check(s.command("numbers.skill",{"id":"draw","delta":1})["ok"],"SP buys a skill level")
	check(s.profile["skills"]["draw"]==2 and Numbers.Skills.available(s.profile,cfg)==40,"learning spends SP once")
	check(not s.command("numbers.level",{"level":1})["ok"],"cannot lower level below spent SP budget")
	check(s.command("numbers.skill",{"id":"draw","delta":-1})["ok"] and Numbers.Skills.available(s.profile,cfg)==80,"refund returns the actual purchase cost")
	check(not s.command("numbers.skill",{"id":"draw","delta":-1})["ok"],"cannot refund gifted skill")
	check(s.command("numbers.skill",{"id":"physical_mastery","delta":1})["ok"] and s.stats()["numbers"]["strength"]==13,"learned passive changes derived attributes")
	var learned: Dictionary = s.serialize()
	var loaded = Session.new()
	check(loaded.restore(JSON.parse_string(JSON.stringify(learned))),"learned profile restores")
	check(loaded.profile["skills"]["physical_mastery"]==1 and loaded.stats()["numbers"]["strength"]==13,"skill and passive survive JSON roundtrip")
	check(loaded.profile==s.profile,"canonical integer types preserve complete profile equality after JSON")
	var reduced_budget: Dictionary = learned.duplicate(true)
	reduced_budget["profile"]["level"] = 1
	check(loaded.restore(JSON.parse_string(JSON.stringify(reduced_budget))) and Numbers.Skills.available(loaded.profile,cfg)<0,"reduced balance budget preserves readable learned skills")
	check(not loaded.command("numbers.skill",{"id":"upper","delta":1})["ok"],"SP deficit prevents new purchases")
	s.command("numbers.skill_reset")
	check(Numbers.Skills.available(s.profile,cfg)==80 and s.profile["skills"]["physical_mastery"]==0,"reset refunds purchases and removes passive")
	var record := Numbers.record("draw")
	check(not record.is_empty(),"compiled original skill is available")
	if not record.is_empty():
		var one := Numbers.Skills.sample(record,1)
		var two := Numbers.Skills.sample(record,2)
		check(one["level_row"][0]==1080 and two["level_row"][0]==1192,"skill sampling selects original rank row")
		check(two["mp"]>one["mp"] and two["cool_ms"]==one["cool_ms"],"per-rank MP and cooldown use same source")
	var requirements := cfg.duplicate(true)
	requirements["progression"]["enforce_skill_requirements"] = true
	check(not Numbers.Skills.change(s.profile,"draw",1,requirements,record)["ok"],"optional character-level gate is enforced")
	var before := float(s.stats()["numbers"]["physical_attack"])
	var gear: Dictionary = s.command("numbers.gear_give",{"id":"iron_sword","quality":100})
	check(gear["ok"] and s.profile["inventory"]["iron_sword"]==2,"same definition creates a separate instance")
	var uid: String = gear["uid"]
	check(s.command("numbers.gear_equip",{"uid":uid})["ok"] and is_equal_approx(float(s.stats()["numbers"]["physical_attack"]),before+0.5),"selected instance quality affects attack")
	s.command("numbers.reinforce",{"uid":uid,"level":10})
	check(is_equal_approx(float(s.stats()["numbers"]["physical_attack"]),before+20.5),"reinforcement changes attack on this instance")
	s.command("numbers.enchant",{"uid":uid,"modifier":{"stat":"strength","op":"add","value":12}})
	check(s.stats()["numbers"]["strength"]==20,"enchant changes equipped attributes")
	check(s.profile["gear"]["gear_1"]["reinforce"]==0,"same-kind equipment instances do not share upgrades")
	var armor: Dictionary = s.command("numbers.gear_give",{"id":"training_coat"})
	s.command("numbers.gear_equip",{"uid":armor["uid"]})
	check(s.stats()["numbers"]["physical_defense"]==29,"armor and vitality contribute defense")
	var neck: Dictionary = s.command("numbers.gear_give",{"id":"training_necklace"})
	s.command("numbers.gear_equip",{"uid":neck["uid"]})
	var set_config := cfg.duplicate(true)
	set_config["equipment"]["training_coat"]["set"]="training"
	set_config["equipment"]["training_necklace"]["set"]="training"
	set_config["sets"]={"training":[{"count":2,"modifiers":[{"stat":"strength","op":"add","value":10}]}]}
	var set_mods: Array = Numbers.Equipment.modifiers(s.profile,set_config)
	var set_stats := Numbers.Attributes.calculate(5,"swordman",set_mods,set_config)
	check(set_stats["values"]["strength"]==30,"two-piece set threshold contributes once alongside enchant")
	check(is_equal_approx(float(Numbers.gear_detail(s.profile,uid)["physical_attack"]),25.5),"equipment description uses actual instance roll and reinforcement")
	check(loaded.restore(JSON.parse_string(JSON.stringify(s.serialize()))),"equipment profile restores")
	check(loaded.profile["equipment"]["weapon"]==uid and loaded.profile["gear"][uid]["reinforce"]==10,"specific equipped instance survives JSON")
	var corrupt: Dictionary = s.serialize()
	corrupt["profile"]["gear"][uid]["quality"]=-1
	check(not loaded.restore(corrupt),"corrupt equipment data rejected before replacing profile")
	corrupt=s.serialize()
	corrupt["profile"]["equipment"]["ring"]=uid
	check(not loaded.restore(corrupt),"wrong equipment slot rejected")
	var legacy: Dictionary = s.serialize()
	legacy["schema"]="dnf_loop_save/1"
	for key in ["numbers_revision","growtype","sp_bonus","skills","skill_purchases","xp_transactions","gear","next_gear","equipment","stat_modifiers"]:legacy["profile"].erase(key)
	check(loaded.restore(JSON.parse_string(JSON.stringify(legacy))),"legacy profile restores")
	check(loaded.profile["gear"].size()==2 and loaded.profile["inventory"]["iron_sword"]==2,"legacy weapon counts migrate without losing duplicates")
	var same: Dictionary = loaded.serialize()
	check(loaded.restore(same) and loaded.profile["gear"].size()==2,"migration does not duplicate equipment on second load")
	var mods: Array = [{"stat":"strength","op":"add","value":10},{"stat":"strength","op":"percent","value":0.1},{"stat":"strength","op":"percent","value":0.2},{"stat":"strength","op":"mul","value":2}]
	check(is_equal_approx(float(Numbers.Attributes.calculate(1,"swordman",mods,cfg)["values"]["strength"]),26),"flat then additive percent then independent multiplication")
	var actor = Actor.new()
	actor.configure(Session.new().stats())
	check(actor.add_effect("strength_potion") and actor.values["strength"]==25,"effect modifies runtime stats")
	actor.add_effect("strength_potion")
	check(actor.values["strength"]==25,"refresh policy does not stack")
	actor.step(30000)
	check(actor.values["strength"]==0 and actor.effects.active.is_empty(),"expiration fully removes modifier")
	actor.add_effect("stun")
	check(actor.effects.controlled(),"control effect exposes action lock")
	actor.remove_effect("stun")
	check(not actor.effects.controlled(),"removal clears action lock")
	actor.configure({"numbers":cfg["base"].merged({"status_resist":1},true)})
	check(not actor.add_effect("stun") and actor.add_effect("strength_potion"),"abnormal resistance blocks control but does not block beneficial buffs")
	actor.remove_effect("strength_potion")
	actor.configure(Session.new().stats())
	for i in 4:actor.add_effect("bleed")
	check(actor.effects.active["bleed"]["stacks"]==3,"effect stack cap")
	var ticks: Array = actor.step(5000)
	var damage := 0.0
	for event: Dictionary in ticks:
		if event["type"]=="tick":damage+=float(event["damage"])
	check(damage==75 and actor.effects.active.is_empty(),"large time step catches all periodic ticks including final boundary")
	var a := {"physical_attack":100,"magical_attack":50,"strength":250,"level":1}
	var f: Dictionary = cfg["formula"]
	check(Numbers.Damage.resolve(a,{}, {"percent":200},[0,1],f)["amount"]==400,"physical percent and main attribute are applied once")
	check(Numbers.Damage.resolve(a,{}, {"damage_type":"magical"},[0,1],f)["amount"]==50,"magic uses magic attack and intelligence")
	check(Numbers.Damage.resolve(a,{"physical_defense":220},{"percent":200},[0,1],f)["amount"]==200,"defense reduces real damage")
	check(Numbers.Damage.resolve(a,{"physical_defense":220},{"percent":200,"ignore_defense":true},[0,1],f)["amount"]==400,"ignore-defense path")
	a["physical_crit"]=1
	check(Numbers.Damage.resolve(a,{}, {"percent":200},[0,0.5],f)["amount"]==600,"critical roll affects damage")
	a["physical_crit"]=0
	a["fire_attack"]=220
	check(Numbers.Damage.resolve(a,{}, {"percent":200,"element":"fire"},[0,1],f)["amount"]==800,"matching element applies strength")
	check(Numbers.Damage.resolve(a,{}, {"percent":200},[0,1],f)["amount"]==400,"elemental strength does not affect neutral attacks")
	check(Numbers.Damage.resolve(a,{"evasion":1},{},[0.5,1],f)["amount"]==0,"miss does not deal minimum damage")
	check(Numbers.Damage.resolve(a,{"immune":true},{},[0,1],f)["amount"]==0,"immunity allows zero damage")
	a["independent_attack"]=200
	check(Numbers.Damage.resolve(a,{}, {"percent":0,"fixed":50},[0,1],f)["amount"]==200,"fixed damage scales with independent attack and main attribute")
	var mob1 := Numbers.monster({"hp":100,"attack":20},1,false,"normal")
	var mob10 := Numbers.monster({"hp":100,"attack":20},10,false,"king")
	check(mob10["hp_max"]>mob1["hp_max"] and mob10["physical_attack"]>mob1["physical_attack"] and mob10["physical_defense"]>0,"monster level and difficulty change actual properties")
	check(s.command("numbers.xp",{"amount":1000000000,"transaction":"cap"})["ok"] and s.profile["level"]==60 and s.profile["xp"]==0 and s.xp_needed()==0,"level cap and overflow handled")
	check(not s.command("numbers.level",{"level":61})["ok"],"configured cap applies to level setter")
	print("[NUMBERS_TEST] COMPLETE checks=%d failures=%d" % [checks,failures])
	quit(1 if failures else 0)
