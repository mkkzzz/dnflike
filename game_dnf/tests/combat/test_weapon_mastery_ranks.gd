extends SceneTree
## Source skill-27 effective ranks through profile numbers and combat refresh.
const Numbers = preload("res://stats/api/numbers.gd")
const Session = preload("res://flow/session.gd")
var checks := 0
var failures := 0

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		print("[MASTERY_RANKS] FAIL ",label)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var game = load("res://scenes/main.tscn").instantiate()
	game.external_mode = true
	game._muted = true
	root.add_child(game)
	game.set_process(false)
	game.set_physics_process(false)
	game.restart()
	var targets := ["shortswordmastery","blademastery","heavyswordmastery","bluntmastery","lightswordmastery"]
	for pair in [[0,1],[1,0],[1,1],[10,1],[30,1],[50,1],[1,49],[1,50]]:
		var passive := int(pair[0])
		var base := int(pair[1])
		var session = Session.new()
		session.command("numbers.level",{"level":60})
		check(session.command("numbers.skill_grant",{"id":"weapon_mastery_up","level":passive})["ok"],"prepare source passive rank")
		for id: String in targets:
			check(session.command("numbers.skill_grant",{"id":id,"level":base})["ok"],"prepare target rank "+id)
		var saved: Dictionary = session.serialize().duplicate(true)
		var spec: Dictionary = session.stats()
		check(game.update_numbers(spec),"real combat refresh")
		for j in targets.size():
			var id: String = targets[j]
			var expected := base+passive+(1 if j==4 else 2) if passive>0 and base>0 and base<50 else base
			check(int(game.skill_levels.get(id,0))==expected,"source target effective rank "+id+" "+str(pair))
			check(int(game.table.skill_levels.get(id,0))==expected,"move table effective rank "+id)
			check(spec["skills"][id]==base,"combat spec keeps purchased rank "+id)
		var blade_rank := base+passive+2 if passive>0 and base>0 and base<50 else base
		var raw: Dictionary = Numbers.record("blademastery")
		var table: Array = raw.get("dungeon",{}).get("level_info",raw.get("level_info",[]))
		var expected_mod := float(table[1+(blade_rank-1)*int(table[0])])*0.001 if blade_rank>0 else 0.0
		var blade_mod := 0.0
		for mod: Dictionary in spec["number_seed"]["modifiers"]:
			if mod.get("source")==Numbers.shared_config()["skills"]["blademastery"]["name"] and mod.get("stat")=="physical_attack":blade_mod+=float(mod["value"])
		check(is_equal_approx(blade_mod,expected_mod),"numeric passive samples effective source row "+str(pair))
		check(is_equal_approx(game.numeric_player.values["physical_attack"],spec["numbers"]["physical_attack"]),"combat numeric actor consumes recalculated passive values")
		var once: Dictionary = game.skill_levels.duplicate(true)
		check(game.update_numbers(spec) and game.skill_levels==once,"repeat refresh does not accumulate")
		check(session.serialize()==saved,"effective levels never modify saved purchases")
		var restored = Session.new()
		check(restored.restore(JSON.parse_string(JSON.stringify(saved))),"source ranks restore")
		check(restored.stats()["numbers"]==spec["numbers"],"reload preserves effective passive calculation")
	var learn = Session.new()
	learn.command("numbers.level",{"level":60})
	learn.command("numbers.growtype",{"growtype":"weaponmaster"})
	check(learn.command("numbers.skill",{"id":"blademastery","delta":1})["ok"],"original one-rank mastery is purchasable")
	check(learn.command("numbers.skill",{"id":"weapon_mastery_up","delta":1})["ok"],"oath is purchased normally")
	var sp_before := Numbers.Skills.available(learn.profile,Numbers.shared_config())
	check(not learn.command("numbers.skill",{"id":"blademastery","delta":1})["ok"],"oath does not invent extra purchasable ranks")
	check(Numbers.Skills.available(learn.profile,Numbers.shared_config())==sp_before,"rejected purchase spends no SP")
	check(learn.command("numbers.skill",{"id":"weapon_mastery_up","delta":-1})["ok"] and Numbers.Skills.effective_levels(learn.profile["skills"],Numbers.shared_config())["blademastery"]==1,"refund removes effective bonus only")
	game.queue_free()
	await process_frame
	print("[MASTERY_RANKS] COMPLETE checks=",checks," failures=",failures)
	quit(0 if failures==0 else 1)
