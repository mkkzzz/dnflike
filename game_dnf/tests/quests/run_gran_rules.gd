extends "res://tests/quests/run_quests.gd"
## Source-specific scope/identity/persistence checks, separate from real fights.
func run() -> void:
	var p:=profile()
	p["level"]=5
	var predecessor: Dictionary=service.new_entry(service.catalog.definitions["hendon.meet_pungjin"])
	predecessor["state"]="completed"
	p["quest_state"]["entries"]["hendon.meet_pungjin"]=predecessor
	p["quest_state"]["transactions"][service.transaction_id("hendon.meet_pungjin")]=true
	check(service.catalog.errors.is_empty(),"source Gran task registry validates")
	check(service.status(p,"gran.tau_rage")=="available" and service.status(p,"gran.cat_trouble")=="locked","105 opens after 104 while 106 stays locked")
	check(not command(p,"quest.accept","gran.tau_rage","sinda")["ok"],"105 cannot be accepted from unrelated NPC")
	check(command(p,"quest.accept","gran.tau_rage","pungjin")["ok"],"105 accepts from original Pungjin")
	event(p,"combat.monster_defeated","wrong_monster",{"monster_id":"monster/tau/tauarmy.mob","dungeon":"mirkwood"})
	event(p,"combat.monster_defeated","wrong_dungeon",{"monster_id":"monster/tau/taubeast.mob","dungeon":"lorien"})
	check(service.status(p,"gran.tau_rage")=="active","ordinary Tau Army and wrong dungeon do not satisfy the original Tau Beast target")
	check(not command(p,"quest.claim","gran.tau_rage","pungjin")["ok"],"105 reward refuses unfinished target")
	event(p,"combat.monster_defeated","tau_1",{"monster_id":"monster/tau/taubeast.mob","dungeon":"mirkwood"})
	event(p,"combat.monster_defeated","tau_1",{"monster_id":"monster/tau/taubeast.mob","dungeon":"mirkwood"})
	check(service.status(p,"gran.tau_rage")=="ready","one correct Tau Beast death marks 105 ready")
	check(not command(p,"quest.claim","gran.tau_rage","shylock")["ok"],"105 cannot be handed to wrong NPC")
	check(command(p,"quest.claim","gran.tau_rage","pungjin")["ok"] and service.status(p,"gran.cat_trouble")=="available","105 hand-in unlocks 106")
	check(command(p,"quest.accept","gran.cat_trouble","pungjin")["ok"],"106 accepts at source giver")
	for i in 5:event(p,"combat.monster_defeated","curse_"+str(i),{"monster_id":"monster/lugaru/kurogaru.mob","dungeon":"mirkwood_deep"})
	check(service.status(p,"gran.cat_trouble")=="active","dark cat boss does not replace the original ordinary cat count")
	for i in 3:event(p,"combat.monster_defeated","cat_"+str(i),{"monster_id":"monster/lugaru/lugaru.mob","dungeon":"mirkwood_deep"})
	var recovered: Dictionary=JSON.parse_string(JSON.stringify(p))
	check(service.valid(recovered),"partial original cat progress survives JSON validation")
	p=recovered
	event(p,"combat.monster_defeated","cat_0",{"monster_id":"monster/lugaru/lugaru.mob","dungeon":"mirkwood_deep"})
	check(service.list(p,["active"])[0]["objectives"][0]["current"]==3,"replayed cat event remains deduplicated after reload")
	for i in range(3,5):event(p,"combat.monster_defeated","cat_"+str(i),{"monster_id":"monster/lugaru/lugaru.mob","dungeon":"mirkwood_deep"})
	check(service.status(p,"gran.cat_trouble")=="ready","five distinct correct cats satisfy 106")
	check(command(p,"quest.claim","gran.cat_trouble","pungjin")["ok"] and command(p,"quest.accept","gran.meet_shylock","pungjin")["ok"],"106 hands in and source 107 accepts without automatic completion")
	event(p,"npc.met","wrong_npc",{"npc":"gsd"})
	check(service.status(p,"gran.meet_shylock")=="active","talking to another backstreet NPC cannot satisfy Shylock meeting")
	event(p,"npc.met","shylock",{"npc":"shylock"})
	check(service.status(p,"gran.meet_shylock")=="ready" and not command(p,"quest.claim","gran.meet_shylock","pungjin")["ok"],"107 is ready only after Shylock and cannot hand back to Pungjin")
	check(command(p,"quest.claim","gran.meet_shylock","shylock")["ok"],"107 hands in at original Shylock")
	var gold: int=p["gold"]
	check(not command(p,"quest.claim","gran.meet_shylock","shylock")["ok"] and int(p["gold"])==gold,"completed new city task cannot replay rewards")
	print("[GRAN_UNIT] COMPLETE checks=%d failures=%d" % [checks,failures])
	quit(1 if failures else 0)
