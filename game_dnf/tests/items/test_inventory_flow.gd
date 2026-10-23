extends "res://tests/quests/test_chapter.gd"
const Items=preload("res://items/inventory.gd")
const Loot=preload("res://loot/service.gd")

func item_cell(place: String, uid: String) -> Control:
	for node in game.modal.find_children("*","Button",true,false):
		if not node.is_queued_for_deletion() and node.get_script()==game.ContentSlot and node.cell.get("place")==place and node.cell.get("uid")==uid:return node
	return null

func run() -> void:
	await ticks(4)
	var path: String="res://../temp/item_tests/runtime.json"
	var initial=game.Session.new()
	initial.add_item("potion",120)
	initial.command("numbers.gear_give",{"id":"forest_sword","quality":100})
	initial.command("numbers.gear_give",{"id":"forest_sword","quality":0})
	initial.command("numbers.gear_give",{"id":"training_coat"})
	initial.command("numbers.gear_give",{"id":"training_necklace"})
	var store=game.Store.new();store.path=path
	check(store.write(initial) and game.enter_character(path),"item character loads real persisted ledger")
	await ticks(4)
	game.show_overlay("inventory");await ticks(3)
	check(game.modal.find_child("storage_grid",true,false)!=null,"inventory exposes 48-cell native storage")
	check(game.modal.find_child("equipment_coat",true,false)!=null,"all numeric equipment slots have actual inventory entrance")
	await frame("items_01_equipment")
	game.windows.inventory_tab=1;game.show_overlay("inventory");await ticks(3)
	var uid: String=game.session.profile.item_state.bags.consumable[1]
	click_control(item_cell("bag",uid));await ticks(2)
	(game.modal.find_child("split_count",true,false) as SpinBox).value=10
	check(click_text("拆分堆叠"),"split is available through actual button")
	await ticks(3)
	check(Items.count(game.session.profile,uid)==14 and game.session.profile.inventory.potion==123,"split GUI preserves stack total")
	click_control(item_cell("bag",uid));await ticks(2);click_text("锁定 / 解锁");await ticks(3)
	check(Items.locked(game.session.profile,uid),"lock GUI writes selected instance")
	click_control(item_cell("bag",uid));await ticks(2);click_text("存入仓库");await ticks(3)
	check(uid not in game.session.profile.item_state.storage,"locked UI transfer rejected")
	click_text("锁定 / 解锁");await ticks(3)
	var before:=JSON.stringify(game.session.serialize())
	game.store.path="res://data/loot.json/cannot_write.json"
	click_text("存入仓库");await ticks(3)
	check(game.save_failed and JSON.stringify(game.session.serialize())==before,"failed item disk commit preserves complete live state")
	game.store.path=path;click_text("存入仓库");await ticks(3)
	check(uid in game.session.profile.item_state.storage and game.session.profile.inventory.potion==109,"deposit GUI moves exact stack")
	click_control(item_cell("storage",uid));await ticks(2);click_text("取回背包");await ticks(3)
	check(uid not in game.session.profile.item_state.storage and game.session.profile.inventory.potion==123,"withdraw GUI restores exact stack")
	click_text("整理背包");await ticks(3)
	check(Items.valid(game.session.profile),"sort GUI preserves ownership")
	await frame("items_02_stack_storage")
	var reloaded=game.Session.new()
	check(game.store.read_into(reloaded) and reloaded.profile==game.session.profile,"inventory operations survive actual disk reload")
	game.show_overlay("");game.selected_dungeon="lorien";game.depart();await ticks(6)
	check(game.session.state=="battle","loot test launches original Lorien")
	var saw_drop:=false
	for i in 5000:
		var snap: Dictionary=game.combat.read_view()
		if not Loot.pending(game.session.run,String(snap.room_id)).is_empty():saw_drop=true;break
		if game.session.state!="battle":break
		var pos: Vector2=snap.pos;var target:=pos;var near:=false
		if not snap.enemies.is_empty():
			var enemy: Dictionary=snap.enemies[0]
			target=enemy.pos;target.x+=-50 if pos.x<=target.x else 50
			near=absf(Vector2(enemy.pos).x-pos.x)<80 and absf(Vector2(enemy.pos).y-pos.y)<12
			if near and int(snap.facing)!=(1 if Vector2(enemy.pos).x>=pos.x else -1):near=false;target.x=pos.x+10*signf(Vector2(enemy.pos).x-pos.x)
		key(KEY_LEFT,target.x-pos.x < -6);key(KEY_RIGHT,target.x-pos.x > 6);key(KEY_UP,target.y-pos.y < -4);key(KEY_DOWN,target.y-pos.y > 4)
		key(KEY_X,near and i%16<2);key(KEY_A,near and i%180<2);key(KEY_S,near and i%220<2)
		await ticks(1)
	release_all();await ticks(3)
	check(saw_drop,"actual monster death generates pending world drops")
	if saw_drop:
		var snap: Dictionary=game.combat.read_view();var drop: Dictionary=Loot.pending(game.session.run,String(snap.room_id))[0]
		var target:=Vector2(float(drop.position[0]),float(drop.position[1]))
		for i in 400:
			snap=game.combat.read_view();var delta: Vector2=target-Vector2(snap.pos)
			if absf(delta.x)<15 and absf(delta.y)<10:break
			key(KEY_LEFT,delta.x < -6);key(KEY_RIGHT,delta.x > 6);key(KEY_UP,delta.y < -4);key(KEY_DOWN,delta.y > 4);await ticks(1)
		release_all();await ticks(3)
		check(is_instance_valid(game.loot_bridge.layer) and game.loot_bridge.layer.get_child_count()>0,"pending drop renders in actual battle presentation")
		await frame("items_03_ground_loot")
		snap=game.combat.read_view();before=JSON.stringify(game.session.serialize())
		game.store.path="res://data/loot.json/cannot_write.json"
		check(not game.loot_bridge.claim(String(drop.id),snap,false) and JSON.stringify(game.session.serialize())==before,"failed pickup disk commit cannot consume ground record or pay reward")
		game.store.path=path
		key(KEY_E,true);await ticks(2);key(KEY_E,false);await ticks(3)
		check(game.session.run.loot.drops[drop.id].claimed,"physical E picks nearby real death drop")
		var saved: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(path))
		check(saved.run.loot.drops[drop.id].claimed,"pickup receipt and awarded inventory persist together")
		check(not game.loot_bridge.claim(String(drop.id),game.combat.read_view(),false),"repeating claimed world pickup is harmless")
	await fight("lorien",5)
	if game.session.state=="result" and game.session.result.get("victory",false):
		var room: String=game.combat.read_view().room_id
		check(not Loot.pending(game.session.run,room).is_empty(),"actual boss leaves unclaimed item records on result screen")
		check(click_text("收取本房掉落"),"result has a real collect-room button")
		await ticks(4)
		check(Loot.pending(game.session.run,room).is_empty(),"result collection saves all eligible boss-room drops once")
		await frame("items_04_result_collected")
	elif game.session.state=="battle":game.act("flow.retreat")
	game.return_town();await ticks(4)
	check(game.session.run.is_empty() and Items.valid(game.session.profile),"leaving adventure discards pending drops while keeping carried inventory valid")
	print("[LOOP_TEST] COMPLETE checks=%d failures=%d captures=%d" % [checks,failures,captured.size()]);get_tree().quit(1 if failures else 0)
