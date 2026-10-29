extends "res://tests/town/test_hendon.gd"
## Task/item transaction QA; dungeon progression is skipped with existing GM commands.
func run() -> void:
	await ticks(4)
	var s=game.Session.new();s.profile.name="技能教学快验";s.profile.level=10
	s.profile.town_location="seria_room";s.profile.town_position=[450.0,200.0]
	for id: String in s.quests.catalog.definitions:
		if id in ["tutorial.skill_intro","tutorial.learn_skill","gran.stronger_enemy","legacy.trial"]:continue
		var entry: Dictionary=s.quests.new_entry(s.quests.catalog.definitions[id]);entry.state="completed"
		s.profile.quest_state.entries[id]=entry;s.profile.quest_state.transactions[s.Quests.transaction_id(id)]=true
	var storage=game.Store.new();storage.path="res://../temp/teaching_tests/hero.json"
	check(storage.write(s) and game.enter_character(storage.path),"declared opening-complete fixture loads beside Seria")
	await ticks(4);await talk("seria");await task("tutorial.skill_intro","接受委托",0)
	await talk("seria");await task("tutorial.skill_intro","领取报酬",1)
	check(game.session.Inventory.stock(game.session.profile,"original_1062")==1 and game.session.Inventory.stock(game.session.profile,"original_1065")==1,"NPC intro delivers the two original recovery foods")
	await task("tutorial.learn_skill","接受委托",0)
	await frame("teaching_01_learning_task")
	game.number_windows.tab=1;game.show_overlay("numbers");await ticks(3)
	check(not game.number_windows.skill_panel.free_mode,"normal skill panel keeps requirement bypass disabled")
	check(game.modal.find_children("*","Label",true,false).any(func(label):return label.text=="每级 SP  20"),"skill panel displays the source purchase cost instead of a boolean fallback")
	var before:=JSON.stringify(game.session.serialize());var path: String=game.store.path
	game.store.path="res://data/quests.json/cannot_write.json"
	check(click_text("加点"),"actual learning control is reachable")
	await ticks(3)
	check(game.save_failed and before==JSON.stringify(game.session.serialize()),"failed skill save preserves SP, skill rank and learning task together")
	game.store.path=path;click_text("加点");await ticks(3)
	check(int(game.session.profile.skills.upper)==2 and game.session.quests.status(game.session.profile,"tutorial.learn_skill")=="ready","successful UI purchase advances the actual learning objective")
	await frame("teaching_02_skill_panel")
	await talk("seria");await task("tutorial.learn_skill","领取报酬",1)
	var loaded=game.Session.new()
	check(game.store.read_into(loaded) and loaded.quests.status(loaded.profile,"tutorial.learn_skill")=="completed" and int(loaded.profile.skills.upper)==2,"skill level and original teaching completion reload atomically")
	game.windows.inventory_tab=1;game.show_overlay("inventory");await ticks(3)
	var icons:=0
	for node in game.modal.find_children("*","Button",true,false):
		if node.get_meta("item_id","") in ["original_1062","original_1065"] and node.cell.get("place")=="bag" and node.image_view.texture!=null:icons+=1
	check(icons==2,"both new original food icons render in the consumables bag")
	await frame("teaching_03_food_items")
	game.show_overlay("")
	game.town.set_location("hendon_auction",Vector2(1496,245))
	game.session.profile.town_location="hendon_auction";game.session.profile.town_position=[1496.0,245.0]
	await ticks(3);await talk("gsd");await task("gran.stronger_enemy","接受委托",0)
	check(game.session.quests.catalog.definitions["gran.stronger_enemy"].objectives[0].difficulty==["adventure"],"source challenge records its exact requested difficulty")
	game.show_overlay("");game.act("flow.difficulty",{"id":"normal"})
	game.selected_dungeon="sunderland_poison";game.depart();await ticks(5)
	check(game.debug_panel.execute("win").ok,"GM command skips unrelated normal dungeon combat")
	await ticks(12)
	check(game.session.quests.status(game.session.profile,"gran.stronger_enemy")=="active","normal-mode GM settlement does not satisfy the adventure task")
	await return_from_gm()
	game.act("flow.difficulty",{"id":"adventure"});game.selected_dungeon="sunderland_poison";game.depart();await ticks(5)
	check(game.debug_panel.execute("win").ok,"GM command skips unrelated adventure combat")
	await ticks(12)
	check(game.session.quests.status(game.session.profile,"gran.stronger_enemy")=="ready","adventure-mode settlement reaches the task through the normal public event")
	await return_from_gm();await talk("gsd");await task("gran.stronger_enemy","领取报酬",1)
	await frame("teaching_04_challenge_reward")
	check(game.store.read_into(loaded) and loaded.quests.status(loaded.profile,"gran.stronger_enemy")=="completed","challenge reward and completion persist after GM-skipped traversal")
	print("[TEACHING_QUICK] COMPLETE checks=%d failures=%d captures=%d" % [checks,failures,captured.size()]);get_tree().quit(1 if failures else 0)

func return_from_gm() -> void:
	game.windows.flip_card(0);await ticks(2)
	check(click_text("返回城镇"),"normal result control returns from GM-skipped dungeon")
	await ticks(4)
