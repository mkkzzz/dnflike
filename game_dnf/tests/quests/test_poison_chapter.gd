extends "res://tests/quests/test_gran.gd"
## Completed-opening fixture; source deaths, pickup and hand-in all use actual play.
var keep_quest_drop_on_ground:=false
var quick:=true

func frame(name: String) -> void:
	await super.frame("quick_"+name if quick else name)

func key(code: int, pressed: bool) -> void:
	if keep_quest_drop_on_ground and code==KEY_E and pressed:return
	super.key(code,pressed)

func run() -> void:
	await ticks(4)
	quick="--full-content-route" not in OS.get_cmdline_user_args()
	print("[POISON_CHAPTER] MODE ","gm_quick" if quick else "full_route")
	var state=game.Session.new();state.profile.name="毒香验证";state.profile.level=10
	state.profile.town_location="hendon_auction";state.profile.town_position=[1496.0,245.0]
	for id: String in state.quests.catalog.definitions:
		if id in ["gran.poison_scent","legacy.trial"]:continue
		var entry: Dictionary=state.quests.new_entry(state.quests.catalog.definitions[id]);entry.state="completed"
		state.profile.quest_state.entries[id]=entry;state.profile.quest_state.transactions[state.Quests.transaction_id(id)]=true
	state.Inventory.give(state.profile,"original_27800",1)
	state.Inventory.equip(state.profile,state.profile.item_state.bags.weapon[0])
	state.Inventory.give(state.profile,"original_10580",1)
	state.Inventory.equip(state.profile,state.profile.item_state.bags.weapon.filter(func(uid):return uid!="")[0])
	state.Inventory.give(state.profile,"potion",60)
	var storage=game.Store.new();storage.path="res://../temp/poison_tests/hero.json"
	check(storage.write(state) and game.enter_character(storage.path),"completed-opening source-equipped fixture loads beside GSD")
	await ticks(4);await talk("gsd");await task("gran.poison_scent","接受委托",0)
	await frame("poison_01_source_task")
	check(game.session.quests.status(game.session.profile,"gran.poison_scent")=="active","source collection task accepts at its original NPC")
	game.show_overlay("")
	if quick:
		game.selected_dungeon="sunderland_poison";game.depart()
	else:
		await walk_to(Vector2(388,295));await walk_to(Vector2(388,359));await cross("auction_to_main","hendon_main")
		await forest_entrance()
		var next_page: Control=game.modal.find_child("dungeon_page_next",true,false)
		check(is_instance_valid(next_page),"forest selection exposes its actual next-page control")
		if is_instance_valid(next_page):click_control(next_page)
		await ticks(3)
		check(select_dungeon("sunderland_poison"),"paginated forest selector exposes the gated poison route")
		if game.selected_dungeon!="sunderland_poison":get_tree().quit(1);return
		await ticks(3);await frame("poison_02_route_selection")
		check(click_text("进入地下城"),"actual dungeon button starts the seven-room source route")
	await ticks(6)
	check(game.combat!=null and game.session.state=="battle","ws1 registered monsters preflight and mount the poison map")
	if game.combat==null:get_tree().quit(1);return
	keep_quest_drop_on_ground=true
	if quick:
		check(game.debug_panel.execute("win").ok,"authorized GM win skips dungeon combat and emits source death/settlement events")
		await ticks(12)
	else:await fight_gran("sunderland_poison",7)
	keep_quest_drop_on_ground=false
	if quick:
		var snap: Dictionary=game.combat.read_view()
		var ground_items: Array=game.session.Loot.pending(game.session.run,String(snap.room_id)).filter(func(drop):return drop.item=="original_4169")
		if not ground_items.is_empty():
			var point: Array=ground_items[0].position
			preload("res://debug/test_api.gd").new(game.battle).set_p("pos",Vector2(float(point[0])-40,float(point[1])))
		await ticks(3)
	var view: Dictionary=game.combat.read_view()
	var pending: Array=game.session.Loot.pending(game.session.run,String(view.room_id)).filter(func(drop):return drop.item=="original_4169")
	check(pending.size()==1 and game.session.Inventory.stock(game.session.profile,"original_4169")==0,"actual poison boss leaves one quest bag on ground without auto-completing collection")
	check(game.session.quests.status(game.session.profile,"gran.poison_scent")=="active","victory alone cannot finish the source seeking objective")
	# Result intentionally cannot be closed. Hide only its visual layer for QA;
	# keep the actual result state, paused combat and live ground node untouched.
	game.modal.visible=false;await ticks(3)
	check(is_instance_valid(game.loot_bridge.layer) and game.loot_bridge.layer.get_child_count()==1 and game.windows.field_texture("original_4169")!=null,"actual pending quest bag has a source-textured world presentation")
	var ground: Vector2=game.battle.to_local(game.loot_bridge.layer.get_child(0).global_position)
	var feet: Vector2=game.battle.to_local(game.battle.view.player_actor.global_position)
	check(absf((ground.y-feet.y)-(float(pending[0].position[1])-float(view.pos.y)))<1.1,"world quest drop and actual player feet share the same map projection")
	await frame("poison_03_source_drop")
	game.modal.visible=true;await ticks(3)
	var path: String=game.store.path;var before:=JSON.stringify(game.session.serialize())
	game.store.path="res://data/quests.json/cannot_write.json"
	click_text("收取本房掉落");await ticks(3)
	check(game.save_failed and before==JSON.stringify(game.session.serialize()),"failed actual pickup commit preserves both ground receipt and ownership")
	game.store.path=path
	check(click_text("收取本房掉落"),"real result control collects the source quest item")
	await ticks(3)
	check(game.session.Inventory.stock(game.session.profile,"original_4169")==1 and game.session.quests.status(game.session.profile,"gran.poison_scent")=="ready","pickup advances live collection and saves the claimed receipt")
	game.windows.inventory_tab=4;game.show_overlay("inventory");await ticks(3)
	var icon: Control=null
	for node in game.modal.find_children("*","Button",true,false):
		if node.get_meta("item_id","")=="original_4169" and node.cell.get("place")=="bag":icon=node;break
	check(is_instance_valid(icon) and icon.image_view.texture!=null,"original quest icon renders in the actual quest bag tab")
	await frame("poison_04_quest_bag")
	game.show_overlay("result");await ticks(3);game.windows.flip_card(0);await ticks(2);click_text("返回城镇");await ticks(4)
	if not quick:
		await walk_to(Vector2(880,230));await cross("forest_gate_to_main","hendon_main")
		await walk_to(Vector2(348,240));await walk_to(Vector2(348,172));await cross("main_to_auction","hendon_auction")
		await walk_to(Vector2(1496,245))
	await talk("gsd")
	game.quest_windows.selected="gran.poison_scent";game.quest_windows.tab=1;game.show_overlay("quest");await ticks(3)
	await frame("poison_05_reward")
	before=JSON.stringify(game.session.serialize());game.store.path="res://data/quests.json/cannot_write.json"
	click_text("领取报酬");await ticks(3)
	check(game.save_failed and before==JSON.stringify(game.session.serialize()),"failed NPC hand-in cannot consume quest item or mint reward equipment")
	game.store.path=path;click_text("领取报酬");await ticks(3)
	check(game.session.Inventory.stock(game.session.profile,"original_4169")==0 and game.session.Inventory.stock(game.session.profile,"original_20006")==1,"actual GSD hand-in consumes poison bag and awards one source necklace")
	var loaded=game.Session.new()
	check(game.store.read_into(loaded) and loaded.quests.status(loaded.profile,"gran.poison_scent")=="completed" and loaded.Inventory.stock(loaded.profile,"original_4169")==0 and loaded.Inventory.stock(loaded.profile,"original_20006")==1,"disk reload keeps source quest completion, consumption and reward atomically")
	game.windows.inventory_tab=0;game.show_overlay("inventory");await ticks(3)
	for node in game.modal.find_children("*","Button",true,false):
		if node.get_meta("item_id","")=="original_20006" and node.cell.get("place")=="bag":double_click_control(node);break
	await ticks(3)
	var necklace: String=game.session.profile.equipment.get("necklace","")
	check(necklace!="" and game.session.Numbers.gear_detail(game.session.profile,necklace).magical_defense==640,"real inventory double-click equips the awarded necklace with original magic defense")
	check(game.store.read_into(loaded) and loaded.profile.equipment.get("necklace","")==necklace,"awarded source necklace equipment also persists through disk reload")
	await frame("poison_06_necklace_inventory")
	print("[POISON_CHAPTER] COMPLETE checks=%d failures=%d captures=%d" % [checks,failures,captured.size()]);get_tree().quit(1 if failures else 0)
