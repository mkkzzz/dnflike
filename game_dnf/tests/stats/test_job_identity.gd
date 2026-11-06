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
	battle.queue_free()
	await process_frame
	print("[JOB_IDENTITY] COMPLETE checks=%d failures=%d" % [checks,failures])
	quit(1 if failures else 0)
