extends SceneTree
const Numbers = preload("res://stats/api/numbers.gd")
const Identity = preload("res://stats/skill_identity.gd")
const Session = preload("res://flow/session.gd")
var checks := 0
var failures := 0

func check(ok: bool, label: String) -> void:
	checks+=1
	if not ok:
		failures+=1
		print("[SKILL_IDENTITY] FAIL ",label)

func costs(rank: int) -> Array:
	var result: Array = []
	for j in rank:result.append([0,20,10][j%3])
	return result

func _initialize() -> void:
	var config := Numbers.shared_config()
	var aliases := {"physical_crit_up":"physicalcriticalhitup","hp_source":"basichpmaxup","short_sword_mastery":"shortswordmastery","blade_mastery":"blademastery","heavy_sword_mastery":"heavyswordmastery"}
	check(config["skill_aliases"].size()==5,"five exact source-path aliases")
	var paths := {}
	for id: String in config["skills"]:
		var path: String = config["skills"][id].get("path","")
		if path.is_empty():continue
		check(not paths.has(path),"one live definition for "+path)
		paths[path]=id
	var source = Session.new()
	source.command("numbers.level",{"level":60})
	var clean: Dictionary = source.serialize()
	for old: String in aliases:
		var id: String = aliases[old]
		check(Identity.canonical(old,config)==id and not config["skills"].has(old),"source identity "+old)
		check(Numbers.record(old)==Numbers.record(id),"old record lookup reaches canonical source")
		for pair in [[3,0],[0,3],[5,2],[2,5],[3,3]]:
			var saved := clean.duplicate(true)
			var p: Dictionary = saved["profile"]
			p["skills"][old]=pair[0]
			p["skills"][id]=pair[1]
			p["skill_purchases"][old]=costs(pair[0])
			var new_costs: Array = []
			new_costs.resize(pair[1])
			new_costs.fill(7)
			p["skill_purchases"][id]=new_costs
			var original := saved.duplicate(true)
			var before_sp := Numbers.Skills.available(p,config)
			var keep_old: bool = pair[0]>pair[1]
			var expected_rank: int = maxi(pair[0],pair[1])
			var retained := costs(pair[0]) if keep_old else new_costs
			var discarded := new_costs if keep_old else costs(pair[0])
			var refund := 0
			for cost in discarded:refund+=int(cost)
			var loaded = Session.new()
			check(loaded.restore(JSON.parse_string(JSON.stringify(saved))),"JSON legacy restore "+old+str(pair))
			check(saved==original,"restore input not mutated")
			check(not loaded.profile["skills"].has(old) and not loaded.profile["skill_purchases"].has(old),"alias no longer a second live skill")
			check(loaded.profile["skills"][id]==expected_rank and loaded.profile["skill_purchases"][id]==retained,"higher rank and its exact ledger survive")
			check(Numbers.Skills.available(loaded.profile,config)==before_sp+refund,"only duplicate spending is released")
			var history: Array = loaded.profile.get("skill_alias_history",[])
			check(history.size()==1 and history[0]["legacy_purchases"]==costs(pair[0]) and history[0]["canonical_purchases"]==new_costs and history[0]["refunded_sp"]==refund,"both old ledgers retained for review")
			var canonical_profile: Dictionary = clean["profile"].duplicate(true)
			canonical_profile["skills"][id]=expected_rank
			canonical_profile["skill_purchases"][id]=retained
			check(Numbers.profile_stats(loaded.profile)["values"]==Numbers.profile_stats(canonical_profile)["values"],"passive applies once using canonical definition")
			var stable: Dictionary = loaded.serialize()
			Numbers.normalize(loaded.profile)
			check(loaded.serialize()==stable,"normalization idempotent")
			check(loaded.restore(stable) and loaded.serialize()==stable,"same session reload does not duplicate history or refund")
			var payload := {"id":old,"delta":-1}
			check(loaded.command("numbers.skill",payload)["ok"] and loaded.profile["skills"][id]==expected_rank-1,"legacy command refunds canonical purchase")
			check(payload["id"]==old and not loaded.profile["skills"].has(old),"command does not rewrite input or recreate alias")
			check(loaded.restore(clean),"migrated session can restore clean save without optional history")
	var invalids := [["rank",1.5],["rank",-1],["rank",31],["costs",[20]],["costs",[20,-1]],["costs",[20,"20"]]]
	for bad in invalids:
		var saved := clean.duplicate(true)
		var p: Dictionary = saved["profile"]
		p["skills"]["blade_mastery"]=bad[1] if bad[0]=="rank" else 2
		p["skill_purchases"]["blade_mastery"]=bad[1] if bad[0]=="costs" else [20,20]
		# A valid earlier pair must not be partially committed before a bad pair.
		p["skills"]["short_sword_mastery"]=1
		p["skill_purchases"]["short_sword_mastery"]=[20]
		var copy_before := p.duplicate(true)
		check(not Identity.migrate(p,config) and p==copy_before,"invalid migration is atomic "+str(bad))
		var target = Session.new()
		var target_before: Dictionary = target.serialize()
		check(not target.restore(saved) and target.serialize()==target_before,"invalid old save cannot replace live state")
	var mastery := clean.duplicate(true)
	mastery["profile"]["skills"]["blade_mastery"]=1
	mastery["profile"]["skill_purchases"]["blade_mastery"]=[20]
	mastery["profile"]["skills"]["weapon_mastery_up"]=1
	mastery["profile"]["skill_purchases"]["weapon_mastery_up"]=[20]
	var fighter = Session.new()
	check(fighter.restore(mastery),"old mastery save loads")
	check(Numbers.Skills.effective_levels(fighter.profile["skills"],config)["blademastery"]==4,"migrated mastery receives native oath column")
	var corrupt: Dictionary = fighter.serialize()
	corrupt["profile"]["skill_alias_history"][0]["refunded_sp"]+=1
	check(not fighter.restore(corrupt),"inconsistent migration history rejected")
	print("[SKILL_IDENTITY] COMPLETE checks=",checks," failures=",failures)
	quit(0 if failures==0 else 1)
