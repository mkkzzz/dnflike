extends "res://tests/town/test_hendon.gd"
## Declared completed-Lorien/Hendon fixture, then actual town movement, two
## original dungeon fights, public deaths, GUI hand-ins and persistent reload.

func run() -> void:
	await ticks(4)
	var state=game.Session.new()
	state.profile["name"]="格兰旅人"
	state.profile["level"]=4
	state.profile["town_location"]="hendon_main"
	state.profile["town_position"]=[838.0,240.0]
	for id: String in state.quests.catalog.definitions:
		if id.begins_with("gran.") or id=="legacy.trial":continue
		var entry: Dictionary=state.quests.new_entry(state.quests.catalog.definitions[id])
		entry["state"]="completed"
		state.profile["quest_state"]["entries"][id]=entry
		state.profile["quest_state"]["transactions"][state.Quests.transaction_id(id)]=true
	var storage=game.Store.new()
	storage.path="res://../temp/gran_tests/hero.json"
	check(storage.write(state) and game.enter_character(storage.path),"completed opening fixture loads into Hendon beside Pungjin")
	await ticks(3)
	check(game.session.quests.catalog.errors.is_empty() and game.town.world.errors.is_empty(),"new source tasks and reciprocal town definitions validate")
	check(game.session.quests.status(game.session.profile,"gran.cat_trouble")=="locked" and not game.session.dungeon_available("mirkwood_deep"),"cat task and deeper forest remain gated before 105 hand-in")
	await talk("pungjin")
	await task("gran.tau_rage","接受委托",0)
	check(game.session.quests.status(game.session.profile,"gran.tau_rage")=="active","105 starts at its original giver, not on map entry")
	await frame("gran_01_tau_task")
	await forest_entrance()
	check(game.selected_dungeon=="mirkwood" and game.modal.find_children("*","Button",true,false).any(func(b):return b.get_meta("dungeon_id","")=="mirkwood_deep"),"forest edge opens Granfloris cards including the locked deeper map")
	await frame("gran_02_forest_selection")
	check(click_text("进入地下城"),"native selection launches original Mirkwood")
	await ticks(6)
	await fight_gran("mirkwood",6)
	check(game.session.quests.status(game.session.profile,"gran.tau_rage")=="ready","only a real Tau Beast death completes source 105 hunt")
	await frame("gran_03_tau_result")
	await return_to_pungjin()
	await task("gran.tau_rage","领取报酬",1)
	check(game.session.dungeon_available("mirkwood_deep"),"105 hand-in unlocks original Mirkwood Deep")
	await task("gran.cat_trouble","接受委托",0)
	await forest_entrance()
	check(select_dungeon("mirkwood_deep"),"unlocked native deeper-forest card is selectable")
	await ticks(3)
	check(game.selected_dungeon=="mirkwood_deep","selection keeps the exact source dungeon identity")
	await frame("gran_04_deep_selection")
	check(click_text("进入地下城"),"native selection launches original Mirkwood Deep")
	await ticks(6)
	await fight_gran("mirkwood_deep",6)
	var q: Dictionary=game.session.quests.list(game.session.profile,["ready"]).filter(func(row):return row["id"]=="gran.cat_trouble")[0] if game.session.quests.status(game.session.profile,"gran.cat_trouble")=="ready" else {}
	check(not q.is_empty() and q["objectives"][0]["current"]==5,"five actual Lugaru deaths satisfy the source-specific cat objective without counting other monsters")
	await frame("gran_05_cat_result")
	await return_to_pungjin()
	await task("gran.cat_trouble","领取报酬",1)
	check(int(game.session.profile["level"])>=5,"normal kills and task rewards reach source level-five conversation gate")
	await task("gran.meet_shylock","接受委托",0)
	game.show_overlay("")
	await walk_to(Vector2(348,240))
	await walk_to(Vector2(348,172))
	await cross("main_to_auction","hendon_auction")
	await walk_to(Vector2(285,245))
	await walk_to(Vector2(285,168))
	await cross("auction_to_alley","hendon_alley")
	await frame("gran_06_alley_arrival")
	await walk_to(Vector2(619,225))
	await talk("shylock")
	var portrait=game.modal.find_child("shylock_dialogue_illustration",true,false)
	check(is_instance_valid(portrait) and portrait.texture.get_size()==Vector2(175,203),"Shylock uses his original large dialogue portrait")
	await frame("gran_07_shylock")
	await task("gran.meet_shylock","领取报酬",1)
	check(game.session.quests.status(game.session.profile,"gran.meet_shylock")=="completed","107 hand-in finishes at actual Shylock in the original alley")
	check(not game.quest_action("quest.claim",{"id":"gran.meet_shylock"}),"duplicate conversation reward cannot pay twice")
	game.show_overlay("")
	game.save_profile()
	var path: String=game.store.path
	var saved: Vector2=game.town.ground
	game.show_character_selection()
	await ticks(3)
	check(game.enter_character(path),"new region save reloads through character selection")
	await ticks(3)
	check(game.town.location=="hendon_alley" and game.town.ground.distance_to(saved)<1 and game.session.quests.status(game.session.profile,"gran.meet_shylock")=="completed" and game.session.dungeon_available("mirkwood_deep"),"alley coordinate, source quest completion and map unlock persist together")
	await walk_to(Vector2(507,300))
	await walk_to(Vector2(507,350))
	await cross("alley_to_auction","hendon_auction")
	check(game.town.ground.distance_to(Vector2(285,245))<1,"original alley exit returns beyond the backstreet entry edge")
	OS.delay_msec(100)
	print("[GRAN_CHAPTER] COMPLETE checks=%d failures=%d captures=%d" % [checks,failures,captured.size()])
	get_tree().quit(1 if failures else 0)

func forest_entrance() -> void:
	game.show_overlay("")
	await walk_to(Vector2(12,280))
	await cross("main_to_forest_gate","hendon_forest_gate")
	await frame("gran_forest_approach")
	await walk_to(Vector2(200,230))
	await walk_to(Vector2(12,230))
	check(game.overlay=="dungeon","walking through the original forest approach automatically opens selection")

func select_dungeon(id: String) -> bool:
	for b in game.modal.find_children("*","Button",true,false):
		if b.get_meta("dungeon_id","")==id:click_control(b);return true
	return false

func return_to_pungjin() -> void:
	if game.session.state!="result":return
	game.windows.flip_card(0)
	await ticks(2)
	check(click_text("返回城镇"),"real settlement returns to the forest approach")
	await ticks(4)
	check(game.town.location=="hendon_forest_gate" and game.overlay=="","dungeon return keeps actual departure town without reopening selection")
	await walk_to(Vector2(880,230))
	await cross("forest_gate_to_main","hendon_main")
	await walk_to(Vector2(838,240))
	await talk("pungjin")

func fight_gran(dungeon: String, count: int) -> void:
	check(game.session.state=="battle" and game.session.run.get("dungeon")==dungeon,"correct source route starts: "+dungeon)
	var last_room:=0
	var saw_boss:=false
	for i in 36000:
		if game.session.state!="battle":break
		var snap: Dictionary=game.combat.read_view()
		if int(snap["room"])!=last_room:
			last_room=int(snap["room"])
			print("[GRAN_CHAPTER] ROOM ",dungeon," ",last_room)
			await frame("gran_battle_"+dungeon+"_"+str(last_room))
		var pos: Vector2=snap["pos"]
		if not saw_boss and last_room==count and snap["enemies"].any(func(enemy):return enemy["chief"] and pos.distance_to(enemy["pos"])<220):
			saw_boss=true
			await frame("gran_boss_"+dungeon)
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
		var nearby:=false
		for drop: Dictionary in game.session.Loot.pending(game.session.run,String(snap["room_id"])):
			var at:=Vector2(float(drop["position"][0]),float(drop["position"][1]))
			if absf(at.x-pos.x)<=90 and absf(at.y-pos.y)<=32:nearby=true;break
		key(KEY_E,nearby and i%12<1)
		if float(snap["hp"])<float(snap["hp_max"])-150 and int(game.session.profile["inventory"].get("potion",0))>0:game.use_potion()
		if i%6000==5999:print("[GRAN_CHAPTER] progress ",i," ",snap["pos"]," enemies=",snap["enemies"].size())
		await ticks(1)
	release_all()
	await ticks(4)
	print("[GRAN_CHAPTER] RESULT ",dungeon," ",game.session.result.get("victory")," ",game.session.result.get("stats",{}))
	check(game.session.state=="result" and game.session.result.get("victory",false),"real normal inputs clear original route: "+dungeon)
	check(last_room==count,"original paired gates reach source final room: "+dungeon)
	check(saw_boss,"real original boss is approached in combat: "+dungeon)
