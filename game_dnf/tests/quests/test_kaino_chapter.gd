extends "res://tests/quests/test_gran.gd"
## Declared completed-opening fixture; all new kills, room gates and hand-ins use real play.
func run() -> void:
	await ticks(4)
	var state=game.Session.new()
	state.profile.name="凯诺任务验证";state.profile.level=10
	state.profile.town_location="hendon_alley";state.profile.town_position=[619.0,225.0]
	for id: String in state.quests.catalog.definitions:
		if id in ["gran.kaino_legend","gran.goblin_mutation","gran.meet_gsd","legacy.trial"]:continue
		var entry: Dictionary=state.quests.new_entry(state.quests.catalog.definitions[id]);entry.state="completed"
		state.profile.quest_state.entries[id]=entry
		state.profile.quest_state.transactions[state.Quests.transaction_id(id)]=true
	state.Inventory.give(state.profile,"original_27601",1)
	var sword: String=state.profile.item_state.bags.weapon[0]
	state.Inventory.equip(state.profile,sword)
	state.Inventory.give(state.profile,"potion",40)
	state.Inventory.give(state.profile,"original_1106",1001)
	state.Inventory.give(state.profile,"original_1112",5)
	state.profile.quick_items[1]="original_1112"
	var storage=game.Store.new();storage.path="res://../temp/kaino_tests/hero.json"
	check(storage.write(state) and game.enter_character(storage.path),"declared source-equipped completed-opening fixture loads beside Shylock")
	await ticks(4)
	game.windows.inventory_tab=1;game.show_overlay("inventory");await ticks(3)
	for cell in game.modal.find_children("*","Button",true,false):
		if cell.get_script()==game.ContentSlot and cell.cell.get("id")=="original_1106" and int(cell.cell.get("count",0))==1000:
			click_control(cell);break
	await ticks(2)
	var split: SpinBox=game.modal.find_child("split_count",true,false)
	check(split.max_value==999,"source thousand-stack exposes full split range in actual inventory")
	split.get_line_edit().text="500"
	check(click_text("拆分堆叠"),"typed split amount is committed through actual button")
	await ticks(3)
	check(game.session.Inventory.stock(game.session.profile,"original_1106")==1001 and game.session.Inventory.valid(game.session.profile),"splitting source medicine preserves all units and ownership")
	var half_stacks:=0
	for uid: String in game.session.profile.item_state.bags.consumable:
		if game.session.Inventory.definition(game.session.profile,uid)=="original_1106" and game.session.Inventory.count(game.session.profile,uid)==500:half_stacks+=1
	check(half_stacks==2,"source stack actually splits at the typed amount above legacy limit")
	game.show_overlay("")
	await talk("shylock")
	await task("gran.kaino_legend","接受委托",0)
	await frame("original_01_kaino_task")
	check(is_instance_valid(game.modal.find_child("quest_detail_scroll",true,false)),"long original Simplified Chinese task text uses scrollable details")
	await to_forest()
	check(select_dungeon("sunderland"),"real dungeon card selects source Sunderland route")
	await ticks(3)
	check(click_text("进入地下城"),"real selection enters the source Kaino route")
	await ticks(6)
	check(game.combat!=null and game.session.state=="battle","all source monsters preflight and mount successfully")
	if game.combat==null:get_tree().quit(1);return
	# Spend MP through an actual skill, then test a paid MP request and disk rollback.
	key(KEY_Z,true);await ticks(1);key(KEY_Z,false);await ticks(8)
	var stock: int=game.session.Inventory.stock(game.session.profile,"original_1112")
	var before: String=JSON.stringify(game.session.serialize())
	var path: String=game.store.path
	game.store.path="res://data/recovery.json/cannot_write.json"
	key(KEY_2,true);await ticks(1);key(KEY_2,false);await ticks(2)
	check(game.save_failed and JSON.stringify(game.session.serialize())==before,"physical MP shortcut preserves inventory and cooldown after failed disk commit")
	game.store.path=path
	key(KEY_2,true);await ticks(1);key(KEY_2,false);await ticks(3)
	check(game.session.Inventory.stock(game.session.profile,"original_1112")==stock-1,"physical MP shortcut consumes one source medicine")
	game.show_overlay("inventory");await ticks(3)
	var clock: float=game.combat.read_view().time_ms
	var mana: float=game.combat.read_view().mp
	await ticks(40)
	check(game.combat.read_view().time_ms==clock and game.combat.read_view().mp==mana,"inventory pause freezes actual timed MP recovery")
	await frame("original_02_items_and_pause")
	game.show_overlay("");await ticks(65)
	check(game.combat.read_view().mp>mana,"source MP restoration reaches the live player after simulation resumes")
	await fight_gran("sunderland",6)
	check(game.session.quests.status(game.session.profile,"gran.kaino_legend")=="ready","actual Kaino death completes 108 through the public event")
	await frame("original_03_kaino_victory")
	await return_to_shylock()
	game.quest_windows.selected="gran.kaino_legend";game.quest_windows.tab=1;game.show_overlay("quest");await ticks(3)
	await frame("original_04_source_rewards")
	before=JSON.stringify(game.session.serialize());game.store.path="res://data/quests.json/cannot_write.json"
	click_text("领取报酬");await ticks(3)
	check(game.save_failed and JSON.stringify(game.session.serialize())==before,"actual source-equipment reward rolls back atomically on failed storage")
	game.store.path=path;click_text("领取报酬");await ticks(3)
	check(game.session.Inventory.stock(game.session.profile,"original_27800")==1 and game.session.Inventory.stock(game.session.profile,"original_24116")==1,"GUI hand-in delivers eligible saber and lightning ring")
	check(game.store.read_into(game.Session.new()),"new conditional equipment reward is readable from disk")
	await task("gran.goblin_mutation","接受委托",0)
	check(game.session.quests.status(game.session.profile,"gran.goblin_mutation")=="active","4302 starts with no inherited Kaino progress")
	await to_forest();select_dungeon("sunderland");await ticks(3);click_text("进入地下城");await ticks(6)
	await fight_gran("sunderland",6)
	check(game.session.quests.status(game.session.profile,"gran.goblin_mutation")=="ready","second actual Kaino kill independently completes 4302")
	await return_to_shylock();await task("gran.goblin_mutation","领取报酬",1)
	check(game.session.quests.status(game.session.profile,"gran.meet_gsd")=="available","handing in 4302 unlocks the original next NPC task")
	game.show_overlay("inventory");await ticks(3);await frame("original_05_rewards_inventory")
	var loaded=game.Session.new()
	check(game.store.read_into(loaded) and loaded.quests.status(loaded.profile,"gran.goblin_mutation")=="completed" and loaded.Inventory.stock(loaded.profile,"original_27800")==1,"disk reload preserves actual double clear and one-time source rewards")
	print("[KAINO_CHAPTER] COMPLETE checks=%d failures=%d captures=%d" % [checks,failures,captured.size()])
	get_tree().quit(1 if failures else 0)

func to_forest() -> void:
	game.show_overlay("")
	await walk_to(Vector2(507,300));await walk_to(Vector2(507,350));await cross("alley_to_auction","hendon_auction")
	await walk_to(Vector2(388,295));await walk_to(Vector2(388,359));await cross("auction_to_main","hendon_main")
	await forest_entrance()

func return_to_shylock() -> void:
	if game.session.state!="result":return
	game.windows.flip_card(0);await ticks(2);click_text("返回城镇");await ticks(4)
	await walk_to(Vector2(880,230));await cross("forest_gate_to_main","hendon_main")
	await walk_to(Vector2(348,240));await walk_to(Vector2(348,172));await cross("main_to_auction","hendon_auction")
	await walk_to(Vector2(285,245));await walk_to(Vector2(285,168));await cross("auction_to_alley","hendon_alley")
	await walk_to(Vector2(619,225));await talk("shylock")
