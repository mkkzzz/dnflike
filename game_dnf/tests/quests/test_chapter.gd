extends "res://tests/flow/test_loop.gd"
## End-to-end chapter test. Reads combat snapshots and sends physical keys;
## no fake kills, HP edits or fabricated victories in the actual chapter run.

func run() -> void:
	await ticks(4)
	var path := "res://../temp/quest_tests/chapter.json"
	var store=game.Store.new()
	store.path=path
	var initial=game.Session.new()
	initial.profile["name"]="洛兰冒险家"
	check(store.write(initial),"chapter character starts from a real independent save")
	check(game.enter_character(path),"character selection loads the chapter save")
	await ticks(4)
	check(game.town.location=="seria_room" and game.town.nearest()=="seria","new character starts beside source Seria")
	game.show_overlay("npc")
	await ticks(3)
	var portrait=game.modal.find_child("seria_dialogue_illustration",true,false)
	check(is_instance_valid(portrait) and portrait.texture.get_size()==Vector2(199,247),"Seria uses original large portrait at native size")
	await frame("quest_01_seria")
	check(click_text("委托任务"),"Seria dialogue opens native quest list")
	await ticks(3)
	check(click_text("接受委托"),"quest 101 accepts through real button")
	await ticks(3)
	check(game.session.quests.status(game.session.profile,"elvengard.meet_linus")=="active","original first task is active")
	await frame("quest_02_accepted")
	game.show_overlay("")
	game.town.ground=Vector2(448,330)
	game.interact_town(game.town.nearest())
	await ticks(22)
	check(game.town.location=="elvengard" and game.session.profile["town_location"]=="elvengard","inn exit connects to original Elvengard street")
	game.town.ground=Vector2(445,222)
	game.show_overlay("npc")
	await ticks(3)
	check(game.session.quests.status(game.session.profile,"elvengard.meet_linus")=="ready","real Linus conversation satisfies 101")
	click_text("委托任务")
	await ticks(3)
	# Force an actual storage failure after reward calculation; live state must
	# remain byte-identical, then the same GUI action must succeed on retry.
	var old_path: String=game.store.path
	var before: String=JSON.stringify(game.session.serialize())
	game.store.path="res://data/quests.json/cannot_write.json"
	click_text("领取报酬")
	await ticks(3)
	check(game.save_failed and JSON.stringify(game.session.serialize())==before,"failed disk commit rolls back all task rewards and completion")
	game.store.path=old_path
	click_text("领取报酬")
	await ticks(3)
	check(game.session.profile["gold"]==400 and game.session.profile["xp"]==40,"101 grants gold and XP through shared progression")
	check(not game.quest_action("quest.claim",{"id":"elvengard.meet_linus"}),"repeat hand-in never replays reward")
	click_text("可接受")
	await ticks(3)
	click_text("接受委托")
	await ticks(3)
	check(game.session.quests.status(game.session.profile,"lorien.first_clear")=="active","source 102 unlocks after 101 and accepts at Linus")
	game.show_overlay("dungeon")
	await ticks(3)
	check(not game.session.dungeon_available("lorien_inside"),"Lorien Inside remains gated before first clear hand-in")
	await frame("quest_03_lorien_select")
	check(click_text("进入地下城"),"native map selection launches original Lorien")
	await ticks(6)
	await fight("lorien",5)
	check(game.session.quests.status(game.session.profile,"lorien.first_clear")=="ready","only actual original dungeon victory completes 102 objective")
	await frame("quest_04_lorien_result")
	await back_to_linus()
	game.show_overlay("quest")
	await ticks(3)
	click_text("领取报酬")
	await ticks(3)
	check(game.session.dungeon_available("lorien_inside"),"claiming 102 unlocks original Lorien Inside")
	click_text("可接受")
	await ticks(3)
	click_text("接受委托")
	await ticks(3)
	check(game.session.quests.status(game.session.profile,"lorien.goblin_noise")=="active","source 103 uses shared level gate and source predecessor")
	game.selected_dungeon="lorien_inside"
	game.show_overlay("dungeon")
	await ticks(3)
	await frame("quest_05_inside_select")
	click_text("进入地下城")
	await ticks(6)
	await fight("lorien_inside",4)
	var rows: Array=game.session.quests.list(game.session.profile,["ready"])
	check(rows.any(func(q):return q["id"]=="lorien.goblin_noise" and q["objectives"][0]["current"]==10),"ten original goblins counted through real public death signals")
	await frame("quest_06_inside_result")
	await back_to_linus()
	game.show_overlay("quest")
	await ticks(3)
	click_text("领取报酬")
	await ticks(3)
	click_text("可接受")
	await ticks(3)
	click_text("接受委托")
	await ticks(3)
	check(game.session.quests.status(game.session.profile,"elvengard.seria_fate")=="active","4301 returns the chapter to Seria")
	game.show_overlay("")
	game.town.ground=Vector2(775,205)
	game.interact_town(game.town.nearest())
	await ticks(22)
	game.show_overlay("npc")
	await ticks(3)
	click_text("委托任务")
	await ticks(3)
	await frame("quest_07_seria_handoff")
	click_text("领取报酬")
	await ticks(3)
	check(game.session.quests.list(game.session.profile,["completed"]).size()==4,"all four original source nodes completed through chapter UI")
	var loaded=game.Session.new()
	check(game.store.read_into(loaded) and loaded.profile==game.session.profile,"chapter goals, unlocks, rewards and location survive disk reload")
	game.show_overlay("")
	await frame("quest_08_return")
	await edge_cases()
	OS.delay_msec(100)
	print("[QUEST_CHAPTER] COMPLETE checks=%d failures=%d captures=%d" % [checks,failures,captured.size()])
	get_tree().quit(1 if failures else 0)

func back_to_linus() -> void:
	if game.session.state!="result":return
	if game.session.result.get("victory",false):game.windows.flip_card(0)
	await ticks(2)
	click_text("返回城镇")
	await ticks(4)
	game.town.ground=Vector2(445,222)
	game.show_overlay("npc")
	await ticks(2)

func fight(dungeon: String, room_count: int) -> void:
	check(game.session.state=="battle" and game.session.run.get("dungeon")==dungeon,"correct original dungeon identity starts: "+dungeon)
	var last_room := 0
	var saw_tau := false
	var saved_kill := false
	for i in 24000:
		if game.session.state!="battle":break
		var snap: Dictionary=game.combat.read_view()
		last_room=maxi(last_room,int(snap["room"]))
		if dungeon=="lorien_inside":
			if not saved_kill:
				var goals: Array=game.session.quests.list(game.session.profile,["active","ready"])
				for q: Dictionary in goals:
					if q["id"]=="lorien.goblin_noise" and q["objectives"][0]["current"]>0:
						var reloaded=game.Session.new()
						check(game.store.read_into(reloaded) and reloaded.quests.list(reloaded.profile,["active","ready"])[0]["objectives"][0]["current"]==q["objectives"][0]["current"],"real kill is saved before victory even when kill XP is zero")
						saved_kill=true
			if not saw_tau and snap["room"]==4:
				saw_tau=game.combat.events().events_of("combat.entity_spawned").any(func(e):return e.get("appearance")=="tau_army")
				if saw_tau:await frame("quest_inside_boss")
		var pos: Vector2=snap["pos"]
		var target: Vector2=snap["exit_target"] if snap["enemies"].is_empty() else pos
		var near:=false
		if not snap["enemies"].is_empty():
			var best:=INF
			for enemy: Dictionary in snap["enemies"]:
				var distance: float=pos.distance_to(enemy["pos"])
				if distance<best:best=distance;target=enemy["pos"]
			var enemy_pos:=target
			target.x+=-52 if pos.x<=enemy_pos.x else 52
			near=absf(enemy_pos.x-pos.x)<80 and absf(enemy_pos.y-pos.y)<14
			if near:
				target.x=pos.x
				var face:=1 if enemy_pos.x>=pos.x else -1
				if int(snap["facing"])!=face:target.x+=face*10;near=false
		var direction:=target-pos
		key(KEY_LEFT,direction.x < -7)
		key(KEY_RIGHT,direction.x > 7)
		key(KEY_UP,direction.y < -5)
		key(KEY_DOWN,direction.y > 5)
		key(KEY_X,near and i%16<2)
		key(KEY_Z,near and i%150<2)
		key(KEY_A,near and i%330<2)
		key(KEY_S,near and i%220<2)
		if float(snap["hp"])<float(snap["hp_max"])-150 and int(game.session.profile["inventory"].get("potion",0))>0:game.use_potion()
		if i==700:await frame("quest_combat_"+dungeon)
		await ticks(1)
	release_all()
	await ticks(4)
	check(game.session.state=="result" and game.session.result.get("victory",false),"real input clears route: "+dungeon)
	check(last_room==room_count,"actual reciprocal gates reach expected final room: "+dungeon)
	if dungeon=="lorien_inside":check(saw_tau,"original inside boss room is reached")

func edge_cases() -> void:
	var legacy=game.Session.new()
	var data: Dictionary=legacy.serialize()
	data["profile"].erase("quest_state")
	data["profile"].erase("town_location")
	data["profile"]["quest"]="done"
	check(legacy.restore(data) and legacy.quests.status(legacy.profile,"legacy.trial")=="completed" and legacy.quests.status(legacy.profile,"lorien.first_clear")=="locked","old quest migrates separately without fabricating source story completion")
	var other=game.Session.new()
	check(other.quests.list(other.profile,["completed"]).is_empty(),"new character has an independent quest ledger")
