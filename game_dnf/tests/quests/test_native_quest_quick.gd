extends "res://tests/town/test_hendon.gd"
## Original NPC/service/clear integration; combat is skipped with GM win.
## Repeat/daily UI fixtures are explicitly synthetic, not admitted original content.
const Native=preload("res://content/native_catalog.gd")

func visit(npc: String) -> void:
	game.show_overlay("")
	for location: String in game.town.world.data.locations:
		var row: Dictionary=game.town.world.scene(location)
		if not row.get("npcs",{}).has(npc):continue
		var at: Array=row.npcs[npc]
		game.town.set_location(location,game.session.TownWorld.vec(at));game.session.profile.town_location=location;game.session.profile.town_position=at.duplicate()
		game.save_profile();break
	await ticks(3);await talk(npc)

func slot(uid: String) -> Control:
	for node in game.modal.find_children("*","Button",true,false):
		if not node.is_queued_for_deletion() and node.get_script()==game.ContentSlot and node.cell.get("place")=="bag" and node.cell.get("uid")==uid:return node
	return null

func inject_cycle_fixtures() -> void:
	for mode: String in ["repeat","daily"]:
		var q: Dictionary=Native.quest_rules().quests[0].duplicate(true)
		q.id="fixture.cycle."+mode;q.name="周期规则测试委托";q.description="验证轮次与写盘的测试委托，非原版内容。";q.erase("source")
		q.lifecycle=mode;q.min_level=1;q.requires=[];q.objectives=[{"id":"talk","type":"meet_npc","target":"gsd","amount":1}]
		q.reward={"gold":3,"xp":1,"items":{},"choices":[]};q.consume={}
		Native.quest_rules().quests.append(q)

func run() -> void:
	await ticks(4);inject_cycle_fixtures()
	var s=game.Session.new();s.profile.name="原任务通用规则快验";s.profile.level=25
	s.profile.town_location="hendon_city";s.profile.town_position=s.town_world.scene("hendon_city").npcs.norton.duplicate()
	var sword: String=s.command("numbers.gear_give",{"id":"forest_sword"}).uid
	var storage=game.Store.new();storage.path="res://../temp/native_quest_tests/hero.json"
	check(storage.write(s) and game.enter_character(storage.path),"declared level-25 fixture loads beside the actual Norton")
	await ticks(3);await talk("norton");await task("original.quest.217","接受委托",0)
	await frame("quest_rules_01_original_disassembly")
	game.show_overlay("npc");await ticks(2);check(click_text("物品服务"),"actual Norton dialogue opens disassembly service");await ticks(2)
	click_control(slot(sword));await ticks(2);click_text("分解所选");await ticks(2)
	var before:=JSON.stringify(game.session.serialize());var path: String=game.store.path
	game.store.path="res://data/quests.json/cannot_write.json";click_text("确认操作");await ticks(3)
	check(game.save_failed and before==JSON.stringify(game.session.serialize()) and game.session.profile.gear.has(sword),"failed disassembly save preserves gear, outputs, transaction and quest progress together")
	game.store.path=path;click_text("确认操作");await ticks(3)
	check(not game.session.profile.gear.has(sword) and game.session.quests.status(game.session.profile,"original.quest.217")=="ready","successful real disassembly advances the original task after the same commit")
	await talk("norton");game.quest_windows.selected="original.quest.217";game.quest_windows.tab=1;game.show_overlay("quest");await ticks(2)
	await frame("quest_rules_02_disassembly_ready")
	before=JSON.stringify(game.session.serialize());game.store.path="res://data/quests.json/cannot_write.json";click_text("领取报酬");await ticks(3)
	check(game.save_failed and before==JSON.stringify(game.session.serialize()),"failed original quest reward write cannot leak gold or completion")
	game.store.path=path;click_text("领取报酬");await ticks(3)
	var loaded=game.Session.new()
	check(game.store.read_into(loaded) and loaded.quests.status(loaded.profile,"original.quest.217")=="completed","original disassembly hand-in survives ordinary disk read")
	await visit("gsd");await task("original.quest.1106","接受委托",0)
	check(game.modal.find_children("*","Label",true,false).any(func(node):return "被击不超过 22 次" in node.text),"task UI shows the actual received-hit constraint")
	await frame("quest_rules_03_hit_limit")
	game.show_overlay("");game.selected_dungeon="palaceofload";game.depart();await ticks(5);game.debug_panel.execute("god on")
	check(game.session.state=="battle","real registered Palace of the Lord route starts")
	# Public combat fact fixtures test same-frame delivery; no AI/dungeon-clear QA.
	for n in 23:game.combat.events().emit("combat.damage",{"victim":"player","amount":1,"point":Vector3.ZERO,"critical":false,"category":"physical"})
	check(game.session.run.quest_facts.hits_taken==23,"public damage facts are observed synchronously before a same-frame final clear")
	check(game.debug_panel.execute("win").ok,"GM skips unrelated dungeon combat");await ticks(12)
	check(game.session.quests.status(game.session.profile,"original.quest.1106")=="active","winning with 23 received-hit facts correctly fails the source limit")
	await return_from_gm()
	game.selected_dungeon="palaceofload";game.depart();await ticks(5);game.debug_panel.execute("god on");game.debug_panel.execute("win");await ticks(12)
	check(game.session.quests.status(game.session.profile,"original.quest.1106")=="ready","a new GM-skipped run resets observations and satisfies the source limit")
	await return_from_gm();await visit("gsd");await task("original.quest.1106","领取报酬",1)
	check(game.store.read_into(loaded) and loaded.quests.status(loaded.profile,"original.quest.1106")=="completed","conditional clear reward and completion reload together")
	for mode: String in ["repeat","daily"]:
		var id: String="fixture.cycle."+mode
		await task(id,"接受委托",0);await talk("gsd");await task(id,"领取报酬",1)
		check(game.session.profile.quest_state.cycles[id].completions==1,"real NPC controls persist a unique completion round: "+mode)
		check(not game.quest_action("quest.claim",{"id":id}),"repeated button action cannot claim a completed round twice: "+mode)
		if mode=="repeat":
			await task(id,"接受委托",0)
			check(game.session.quests.status(game.session.profile,id)=="active" and game.session.profile.quest_state.entries[id].cycle==2,"second repeat round starts without stale objective progress")
			await talk("gsd");await task(id,"领取报酬",1)
		else:check(game.session.quests.status(game.session.profile,id)=="completed","daily fixture remains unavailable until the configured next day")
	game.quest_windows.tab=2;game.quest_windows.selected="fixture.cycle.repeat";game.show_overlay("quest");await ticks(3)
	await frame("quest_rules_04_repeat_history")
	game.show_character_selection();await ticks(2)
	check(game.enter_character(path),"actual character selection reloads the saved cycle ledger");await ticks(3)
	check(game.session.profile.quest_state.cycles["fixture.cycle.repeat"].completions==2 and game.session.quests.status(game.session.profile,"fixture.cycle.daily")=="completed","repeat history and daily claim survive actual character reload")
	print("[QUEST_RULES_QUICK] COMPLETE checks=%d failures=%d captures=%d" % [checks,failures,captured.size()]);get_tree().quit(1 if failures else 0)

func return_from_gm() -> void:
	game.windows.flip_card(0);await ticks(2);check(click_text("返回城镇"),"normal result control returns after GM skip");await ticks(4)
