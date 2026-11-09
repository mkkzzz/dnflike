extends SceneTree
## Original identity/learning columns; growth and job-quest fidelity are separate.
const Numbers = preload("res://stats/api/numbers.gd")
const Session = preload("res://flow/session.gd")
var checks := 0
var failures := 0
func _initialize() -> void:call_deferred("run")
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		print("[JOB_IDENTITY] FAIL ",label)

func check_awakening_learning() -> void:
	var s=Session.new()
	s.command("numbers.level",{"level":60})
	s.command("numbers.growtype",{"growtype":"soulbringer"})
	var learn: Dictionary={"id":"sayaex","delta":1}
	var legacy: Dictionary=s.serialize()
	legacy.profile.erase("awakening_stage")
	check(s.restore(legacy) and s.profile.awakening_stage==0,"legacy save defaults to unawakened")
	check(not s.command("numbers.skill",learn).ok,"unawakened Soulbringer cannot learn an awakening-only skill")
	var awake: Dictionary=s.serialize()
	awake.profile.awakening_stage=1
	check(s.restore(JSON.parse_string(JSON.stringify(awake))) and s.profile.awakening_stage==1,"first awakening stage survives the ordinary save loader")
	check(not s.command("numbers.skill",learn).ok,"the original parent skill still gates awakening-only learning")
	for rank in 3:s.command("numbers.skill",{"id":"bremen","delta":1,"force":true})
	check(s.command("numbers.skill",{"id":"saya","delta":1}).ok,"ordinary skill retains its first-growth learning cap after awakening")
	s.command("numbers.level",{"level":59})
	check(not s.command("numbers.skill",learn).ok,"awakened Soulbringer still needs level 60 for skill 96")
	s.command("numbers.level",{"level":60})
	var cfg:=Numbers.shared_config()
	var before:=Numbers.Skills.available(s.profile,cfg)
	check(s.command("numbers.skill",learn).ok and s.profile.skills.sayaex==1,"stage 1 and growth 2 select the original skill 96 cap")
	check(before-Numbers.Skills.available(s.profile,cfg)==60,"awakening-only skill charges the original 60 SP")
	var restored=Session.new()
	check(restored.restore(JSON.parse_string(JSON.stringify(s.serialize()))) and restored.profile.skills.sayaex==1
		and restored.profile.awakening_stage==1,"learned skill and stage round-trip independently")
	var definition: Dictionary=cfg.skills.sayaex
	for case in [["soulbringer",0,0],["soulbringer",1,30],["soulbringer",2,0],["asura",1,0]]:
		var identity: Dictionary={"growtype":case[0],"awakening_stage":case[1]}
		check(Numbers.Skills.learning_cap(identity,definition,Numbers.record("sayaex"),cfg)==case[2],"stage and growth column: "+str(case))
	for invalid in [-1,3,1.5,"1",null]:
		var damaged: Dictionary=s.serialize()
		damaged.profile.awakening_stage=invalid
		check(not restored.restore(damaged) and restored.profile.awakening_stage==1,"invalid awakening stage is rejected atomically")
	check(restored.command("numbers.growtype",{"growtype":"asura","force":true}).ok and restored.profile.awakening_stage==0,
		"changing branch in the debug entry resets its awakening stage")

func run() -> void:
	var battle = load("res://scenes/main.tscn").instantiate()
	battle.external_mode = true
	battle._muted = true
	root.add_child(battle)
	battle.set_process(false)
	battle.set_physics_process(false)
	battle.restart()
	var jobs := ["weaponmaster","soulbringer","berserker","asura"]
	var skills := ["weapon_mastery_up","ghostpowerup","bloody_vigorous","armormasteryplatewave"]
	for i in jobs.size():
		var job: String = jobs[i]
		var s = Session.new()
		s.command("numbers.level",{"level":17})
		var before: Dictionary = s.serialize().duplicate(true)
		check(not s.command("numbers.growtype",{"growtype":job})["ok"] and s.serialize()==before,job+" below local advancement gate is unchanged")
		s.command("numbers.level",{"level":18})
		check(s.command("numbers.growtype",{"growtype":job})["ok"],job+" ordinary advancement accepted")
		check(s.profile["growtype"]==job and Numbers.valid(s.profile),job+" is valid persistent identity")
		check(int(Numbers.shared_config()["growtype_index"].get(job,-1))==i+1,job+" original source column")
		check(s.command("numbers.skill",{"id":skills[i],"delta":1})["ok"],job+" own exclusive source skill can be learned")
		var rank := int(s.profile["skills"][skills[i]])
		check(rank==1,job+" learned rank persisted")
		for other in jobs.size():
			if other==i:continue
			var sp := Numbers.Skills.available(s.profile,Numbers.shared_config())
			check(not s.command("numbers.skill",{"id":skills[other],"delta":1})["ok"],job+" rejects other job skill "+skills[other])
			check(Numbers.Skills.available(s.profile,Numbers.shared_config())==sp,job+" rejected skill keeps SP")
		before = s.serialize().duplicate(true)
		check(not s.command("numbers.growtype",{"growtype":jobs[(i+1)%4]})["ok"] and s.serialize()==before,job+" second normal advancement rejected")
		var restored = Session.new()
		check(restored.restore(JSON.parse_string(JSON.stringify(before))),job+" JSON save reload accepted")
		check(restored.profile["growtype"]==job and int(restored.profile["skills"][skills[i]])==1,job+" reload preserves identity and learned skill")
		var spec: Dictionary = restored.stats()
		check(battle.update_numbers(spec) and battle.job==job and battle.table.job==job,job+" actual battle uses source branch")
		battle.player["hp"] = 0.0
		battle.finished = true
		battle.victory = false
		battle.last_defeat_id = 1
		var revive := {"run_id":battle.run_id,"room_id":battle.room_id,"death_id":1,"hp_percent":30,"mp_percent":20,"invulnerable_ms":3000,"player":spec}
		var invalid: Dictionary = revive.duplicate(true)
		invalid["player"]["number_seed"]["growtype"] = "unregistered"
		check(not battle.can_revive(invalid),job+" invalid revival identity rejected")
		check(battle.can_revive(revive),job+" valid identity passes revival gate")
		check(battle.revive_player(revive) and battle.player["hp"]>0 and not battle.finished,job+" actual revival restores player")
		check(battle.job==job and battle.numeric_player.seed["growtype"]==job,job+" revival preserves branch")
		check(s.command("numbers.skill",{"id":skills[i],"delta":-1})["ok"] and s.profile["growtype"]==job,job+" refund keeps profession")
	for unknown in ["unregistered","demonicswordman",5,[],null]:
		var s = Session.new()
		var candidate: Dictionary = s.profile.duplicate(true)
		candidate["growtype"] = unknown
		check(not Numbers.valid(candidate),"unregistered or malformed persistent identity rejected")
	check_awakening_learning()
	battle.queue_free()
	await process_frame
	print("[JOB_IDENTITY] COMPLETE checks=%d failures=%d" % [checks,failures])
	quit(1 if failures else 0)
