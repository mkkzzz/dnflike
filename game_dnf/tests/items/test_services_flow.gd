extends "res://tests/quests/test_chapter.gd"
const Services=preload("res://items/services.gd")
const Items=preload("res://items/inventory.gd")
func slot(place: String, uid: String) -> Control:
	for node in game.modal.find_children("*","Button",true,false):
		if not node.is_queued_for_deletion() and node.get_script()==game.ContentSlot and node.cell.get("place")==place and node.cell.get("uid")==uid:return node
	return null
func visit(npc: String, location: String) -> void:
	game.show_overlay("")
	game.town.set_location(location,game.session.TownWorld.vec(game.town.world.scene(location)["npcs"][npc]))
	game.session.profile.town_location=location
	game.save_profile();game.show_overlay("npc");await ticks(3)
	check(click_text("物品服务"),"real NPC dialogue opens services: "+npc);await ticks(3)
func run() -> void:
	await ticks(4)
	var fixture=game.Session.new();fixture.profile.gold=1000;fixture.profile.town_location="elvengard";fixture.profile.town_position=[445.0,222.0]
	var weapon: String=fixture.profile.equipment.weapon
	fixture.profile.gear[weapon].durability=1;fixture.profile.gear[weapon].wear_progress=19
	var sword: String=fixture.command("numbers.gear_give",{"id":"forest_sword","quality":87}).uid
	fixture.profile.gear[sword].reinforce=4;fixture.profile.gear[sword].durability=7
	var original: Dictionary=fixture.profile.gear[sword].duplicate(true)
	var coat: String=fixture.command("numbers.gear_give",{"id":"training_coat"}).uid
	fixture.command("numbers.gear_equip",{"uid":coat});fixture.profile.gear[coat].durability=0
	var storage=game.Store.new();storage.path="res://../temp/service_tests/hero.json"
	check(storage.write(fixture) and game.enter_character(storage.path),"independent service fixture loads with worn and broken equipment")
	await ticks(3);await visit("linus","elvengard")
	click_control(slot("bag",sword));await ticks(2);click_text("出售所选");await ticks(2)
	check(is_instance_valid(game.service_windows.confirmation),"sale opens actual confirmation preview")
	await frame("services_01_sell_confirm")
	var before:=JSON.stringify(game.session.serialize());click_text("取消操作");await ticks(3)
	check(JSON.stringify(game.session.serialize())==before,"cancel sale preserves exact character state")
	click_text("出售所选");await ticks(2)
	var path: String=game.store.path;game.store.path="res://data/services.json/cannot_write.json"
	before=JSON.stringify(game.session.serialize());click_text("确认操作");await ticks(3)
	check(game.save_failed and JSON.stringify(game.session.serialize())==before,"failed service disk write rolls back coins, owner and receipt")
	game.store.path=path;click_text("确认操作");await ticks(3)
	check(game.session.profile.gold==1060 and game.session.profile.services.buyback[0].uid==sword,"confirmed sale moves exact equipment into real buyback list")
	await frame("services_02_buyback")
	check(click_text("回购"),"buyback has actual button");await ticks(2);click_text("确认操作");await ticks(3)
	check(game.session.profile.gold==1000 and game.session.profile.gear[sword]==original and sword in game.session.profile.item_state.bags.weapon,"GUI buyback preserves quality, reinforcement and durability")
	click_control(slot("service_equipment",coat));await ticks(2);click_text("修理所选");await ticks(2)
	await frame("services_03_repair_confirm")
	click_text("确认操作");await ticks(3)
	check(game.session.profile.gear[coat].durability==40 and game.session.profile.gold==960 and game.session.stats().numbers.physical_defense>4,"repair GUI restores actual armor stats and deducts quoted cost")
	game.show_overlay("");game.selected_dungeon="lorien";game.depart();await ticks(5)
	check(game.session.state=="battle","wear test starts real original dungeon")
	var damaged:=false
	for i in 2200:
		var snap: Dictionary=game.combat.read_view()
		if int(game.session.profile.gear[weapon].durability)==0:damaged=true;break
		if game.session.state!="battle" or snap.enemies.is_empty():break
		var pos: Vector2=snap.pos;var enemy: Dictionary=snap.enemies[0];var target: Vector2=enemy.pos
		target.x+=-50 if pos.x<=target.x else 50
		var near:=absf(Vector2(enemy.pos).x-pos.x)<80 and absf(Vector2(enemy.pos).y-pos.y)<12
		if near and int(snap.facing)!=(1 if Vector2(enemy.pos).x>=pos.x else -1):near=false;target.x=pos.x+10*signf(Vector2(enemy.pos).x-pos.x)
		key(KEY_LEFT,target.x-pos.x < -6);key(KEY_RIGHT,target.x-pos.x > 6);key(KEY_UP,target.y-pos.y < -4);key(KEY_DOWN,target.y-pos.y > 4);key(KEY_X,near and i%16<2)
		await ticks(1)
	release_all();await ticks(3)
	check(damaged and game.session.stats().numbers.physical_attack==20,"real landed attack exhausts last durability and disables weapon stats")
	check(float(game.combat.read_view().numbers.physical_attack)==20,"broken gear propagates into live combat numeric actor")
	var saved: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(path))
	check(int(saved.profile.gear[weapon].durability)==0,"real combat wear persists before settlement")
	await frame("services_04_real_wear")
	if game.session.state=="battle":game.act("flow.retreat")
	game.return_town();await ticks(3);await visit("linus","elvengard")
	click_text("修理穿戴");await ticks(2);click_text("确认操作");await ticks(3)
	check(game.session.profile.gear[weapon].durability==40 and game.session.stats().numbers.physical_attack==25,"return-to-town repair restores broken weapon")
	var norton_location: String=""
	for location: String in game.town.world.data["locations"]:
		if game.town.world.scene(location).get("npcs",{}).has("norton"):norton_location=location;break
	await visit("norton",norton_location)
	click_control(slot("bag",sword));await ticks(2);click_text("分解所选");await ticks(2)
	check(is_instance_valid(game.service_windows.confirmation),"Norton disassembly previews exact output")
	await frame("services_05_disassemble_confirm")
	click_text("确认操作");await ticks(3)
	check(not game.session.profile.gear.has(sword) and game.session.profile.inventory.scrap_iron==5,"confirmed disassembly replaces original instance with real material")
	game.windows.inventory_tab=2;game.show_overlay("services");await ticks(3)
	var material: String=game.session.profile.item_state.bags.material[0]
	check(material!="" and slot("bag",material)!=null and slot("bag",material).has_node("item_icon") and slot("bag",material).get_node("item_icon").texture.get_size()==Vector2(28,28),"material uses original native 28x28 icon in real backpack")
	await frame("services_06_material")
	var loaded=game.Session.new()
	check(game.store.read_into(loaded) and loaded.profile==game.session.profile,"trade, repair and material ownership survive actual disk reload")
	print("[LOOP_TEST] COMPLETE checks=%d failures=%d captures=%d" % [checks,failures,captured.size()]);get_tree().quit(1 if failures else 0)
