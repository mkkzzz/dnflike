extends "res://tests/flow/test_loop.gd"
## New-town test starts from a declared completed-Lorien fixture, then uses
## physical movement/E, real NPC GUI and disk saves for every new task/exit.

func run() -> void:
	await ticks(4)
	var state=game.Session.new()
	state.profile["name"]="赫顿旅人"
	state.profile["level"]=3
	state.profile["xp"]=200
	state.profile["town_location"]="elvengard"
	state.profile["town_position"]=[445.0,222.0]
	for id in ["elvengard.meet_linus","lorien.first_clear","lorien.goblin_noise","elvengard.seria_fate"]:
		var entry: Dictionary=state.quests.new_entry(state.quests.catalog.definitions[id])
		entry["state"]="completed"
		state.profile["quest_state"]["entries"][id]=entry
		state.profile["quest_state"]["transactions"][state.Quests.transaction_id(id)]=true
	var storage=game.Store.new()
	storage.path="res://../temp/hendon_tests/hero.json"
	check(storage.write(state) and game.enter_character(storage.path),"completed first chapter fixture loads into original Elvengard")
	await ticks(3)
	check(game.town.world.errors.is_empty(),"all towns, native ground unions and reciprocal connections validate")
	await talk("linus")
	await task("hendon.meet_pungjin","接受委托",0)
	check(game.session.quests.status(game.session.profile,"hendon.meet_pungjin")=="active","original 104 accepts at Linus")
	game.show_overlay("")
	await walk_to(Vector2(32,260))
	var before: String=JSON.stringify(game.session.serialize())
	var asset: String=game.town.world.scene("hendon_city")["asset"]
	game.town.world.data["locations"]["hendon_city"]["asset"]="res://assets_local/missing_hendon.json"
	check(not await game.transition_town("elven_to_city") and game.town.location=="elvengard" and JSON.stringify(game.session.serialize())==before,"missing target art keeps source scene and save unchanged")
	game.town.world.data["locations"]["hendon_city"]["asset"]=asset
	game.town.hendon_loader.errors.clear()
	var original_path: String=game.store.path
	game.store.path="res://data/towns.json/not_a_directory.json"
	check(not await game.transition_town("elven_to_city") and game.town.location=="elvengard" and JSON.stringify(game.session.serialize())==before,"disk failure cannot commit partial cross-town state")
	game.store.path=original_path
	await cross("elven_to_city","hendon_city")
	check(game.town.ground.distance_to(Vector2(3670,265))<1,"Elvengard left road lands beyond Hendon city right exit")
	await frame("hendon_01_city_arrival")
	await walk_to(Vector2(1975,265))
	await frame("hendon_02_city_street")
	await walk_to(Vector2(800,250))
	await walk_to(Vector2(800,175))
	await cross("city_to_main","hendon_main")
	check(game.town.ground.distance_to(Vector2(1066,400))<1 and game.town.camera_y>0,"city connects to main lower road with native extended floor and vertical camera")
	await frame("hendon_03_main_lower")
	await walk_to(Vector2(838,240))
	await talk("pungjin")
	var portrait=game.modal.find_child("pungjin_dialogue_illustration",true,false)
	check(is_instance_valid(portrait) and portrait.texture.get_size()==Vector2(194,219),"Pungjin uses the original large NPC portrait")
	await frame("hendon_04_pungjin")
	await task("hendon.meet_pungjin","领取报酬",1)
	check(game.session.quests.status(game.session.profile,"hendon.meet_pungjin")=="completed","104 hands in at the correct distant NPC")
	await task("hendon.swordman_start","接受委托",0)
	game.show_overlay("")
	await talk("pungjin")
	await task("hendon.swordman_start","领取报酬",1)
	check(int(game.session.profile["level"])>=4,"source level four gate is reached through configured quest XP")
	await task("hendon.meet_sinda","接受委托",0)
	game.show_overlay("")
	await walk_to(Vector2(348,240))
	await walk_to(Vector2(348,172))
	await cross("main_to_auction","hendon_auction")
	await frame("hendon_05_backstreet")
	await walk_to(Vector2(1198,245))
	await talk("sinda")
	await frame("hendon_06_sinda")
	await task("hendon.meet_sinda","领取报酬",1)
	await task("hendon.job_introduction","接受委托",0)
	game.show_overlay("")
	await talk("sinda")
	await task("hendon.job_introduction","领取报酬",1)
	check(game.session.quests.status(game.session.profile,"hendon.job_introduction")=="completed","four original Hendon source tasks complete through NPC GUI")
	check(not game.quest_action("quest.claim",{"id":"hendon.job_introduction"}),"repeat city task hand-in cannot replay rewards")
	game.show_overlay("")
	await walk_to(Vector2(1496,245))
	await talk("gsd")
	await frame("hendon_07_gsd")
	check(click_text("学习技能"),"G.S.D opens the existing shared skill service")
	await ticks(3)
	check(game.overlay=="numbers" and game.number_windows.tab==1,"mentor service uses the real skill page")
	await frame("hendon_08_gsd_skills")
	game.show_overlay("")
	await walk_to(Vector2(810,245))
	await walk_to(Vector2(810,188))
	await cross("enter_hendon_inn","seria_room")
	check(game.session.profile["inn_return"]=="enter_hendon_inn","Seria records which town entrance was used")
	await frame("hendon_09_seria_return_route")
	game.save_profile()
	var loaded=game.Session.new()
	check(game.store.read_into(loaded) and loaded.profile["inn_return"]=="enter_hendon_inn" and loaded.profile["town_location"]=="seria_room","inn return context survives JSON disk load")
	await walk_to(Vector2(448,320))
	await cross("exit_hendon_inn","hendon_auction")
	check(game.town.ground.distance_to(Vector2(810,245))<1,"Hendon Seria exit returns to Hendon rather than Elvengard")
	# Reload through the real character screen; preserve position and task state.
	await walk_to(Vector2(1300,270))
	game.save_profile()
	var saved: Vector2=game.town.ground
	var tasks: Dictionary=game.session.profile["quest_state"].duplicate(true)
	game.show_character_selection()
	await ticks(3)
	check(game.enter_character(original_path),"city character reloads through normal selection")
	await ticks(3)
	check(game.town.location=="hendon_auction" and game.town.ground.distance_to(saved)<1 and game.session.profile["quest_state"]==tasks,"load retains exact street, safe coordinate and quest ledger")
	await frame("hendon_10_reload")
	# Depart/retreat from this city to verify the return is the actual origin.
	game.depart()
	await ticks(6)
	check(game.session.state=="battle","existing dungeon can start with Hendon return context")
	game.act("flow.retreat")
	game.return_town()
	await ticks(4)
	check(game.town.location=="hendon_auction" and game.town.ground.distance_to(saved)<1,"dungeon retreat restores original town entry rather than fixed Linus spawn")
	await walk_to(Vector2(388,295))
	await walk_to(Vector2(388,359))
	await cross("auction_to_main","hendon_main")
	await walk_to(Vector2(1066,400))
	await walk_to(Vector2(1066,465))
	await cross("main_to_city","hendon_city")
	await walk_to(Vector2(3780,265))
	await cross("city_to_elven","elvengard")
	check(game.town.ground.distance_to(Vector2(100,260))<1,"complete city route returns through original Elvengard left entrance")
	await frame("hendon_11_elven_return")
	var final_state=game.Session.new()
	check(game.store.read_into(final_state) and final_state.profile==game.session.profile,"round trip persists all rewards and current world state")
	OS.delay_msec(100)
	print("[HENDON_TEST] COMPLETE checks=%d failures=%d captures=%d" % [checks,failures,captured.size()])
	get_tree().quit(1 if failures else 0)

func walk_to(point: Vector2) -> void:
	game.show_overlay("")
	for i in 2600:
		var d: Vector2=point-game.town.ground
		if absf(d.x)<4 and absf(d.y)<4:break
		key(KEY_LEFT,d.x < -3)
		key(KEY_RIGHT,d.x > 3)
		key(KEY_UP,d.y < -3)
		key(KEY_DOWN,d.y > 3)
		await ticks(1)
	release_all()
	await ticks(2)
	check(game.town.ground.distance_to(point)<7,"physical town movement reaches "+str(point))

func cross(portal: String, destination: String) -> void:
	check(game.town.nearest()==portal,"source exit is reachable and recognized: "+portal)
	key(KEY_E,true)
	await ticks(1)
	key(KEY_E,false)
	check(game.transitioning,"scene transition owns input during fade: "+portal)
	if portal=="elven_to_city":key(KEY_RIGHT,true)
	await ticks(22)
	check(not game.transitioning and game.town.location==destination and game.session.profile["town_location"]==destination,"physical E loads and commits target scene: "+destination)
	if portal=="elven_to_city":
		check(game.town.ground.distance_to(Vector2(3670,265))<1,"held movement cannot carry character away during or after transition")
		key(KEY_RIGHT,false)
		await ticks(2)

func talk(npc: String) -> void:
	game.show_overlay("")
	check(game.town.nearest()==npc,"correct original NPC anchor reachable: "+npc)
	key(KEY_E,true)
	await ticks(2)
	key(KEY_E,false)
	await ticks(2)
	check(game.overlay=="npc","physical E opens NPC dialogue: "+npc)

func task(id: String, caption: String, tab: int) -> void:
	game.quest_windows.selected=id
	game.quest_windows.tab=tab
	game.show_overlay("quest")
	await ticks(3)
	check(click_text(caption),"native quest action "+caption+": "+id)
	await ticks(3)
