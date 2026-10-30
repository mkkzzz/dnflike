extends "res://tests/town/test_hendon.gd"
const Native=preload("res://content/api/native_catalog.gd")
## Town/UI/item quick test only. No dungeon traversal or monster behavior test.
func run() -> void:
	await ticks(4)
	var s=game.Session.new();s.profile.name="原库批量迁移快验";s.profile.level=60
	s.profile.town_location="seria_room";s.profile.town_position=[450.0,200.0]
	var storage=game.Store.new();storage.path="res://../temp/native_bulk_tests/hero.json"
	check(storage.write(s) and game.enter_character(storage.path),"native migration fixture loads into actual town")
	await ticks(4)
	check(game.debug_panel.execute("native").ok,"GM complete source database summary is accessible")
	check(game.debug_panel.execute("native quests 101").ok and game.debug_panel.execute("native find quests 林纳斯").ok,"GM original-ID lookup and Chinese full-corpus search work")
	var weapon:="";var material:="";var food:=""
	for id: String in Native.runtime().equipment:
		var gear: Dictionary=Native.runtime().equipment[id]
		if gear.slot=="weapon" and int(gear.required_level)<=60 and game.session.Numbers.Equipment.usable(s.profile,gear):weapon=id;break
	for id: String in Native.runtime().items:
		var item: Dictionary=Native.runtime().items[id]
		if item.kind=="material" and material=="":material=id
		if item.kind=="consumable" and food=="":food=id
	check(weapon!="" and material!="" and food!="","bulk registry contains actual weapon, material and food candidates")
	for id: String in [weapon,material,food]:check(game.debug_panel.execute("give %s 2" % id).ok,"existing GM gives bulk original ID: "+id)
	game.windows.inventory_tab=0;game.show_overlay("inventory");await ticks(3)
	var cell=null
	for node in game.modal.find_children("*","Button",true,false):
		if node.get_meta("item_id","")!="" and node.get_meta("item_id","")==weapon and node.cell.get("place")=="bag":cell=node;break
	check(cell!=null and cell.image_view.texture!=null,"bulk source weapon native atlas renders in actual equipment bag")
	if cell!=null:
		var uid: String=cell.cell.uid
		var before:=JSON.stringify(game.session.serialize());var path: String=game.store.path
		game.store.path="res://data/quests.json/cannot_write.json"
		check(not game.act("items.equip",{"uid":uid}) and game.save_failed and before==JSON.stringify(game.session.serialize()),"failed bulk equipment save rolls back ownership and equipped state")
		game.store.path=path
		check(game.act("items.equip",{"uid":uid}) and game.session.profile.equipped==weapon,"bulk weapon uses real candidate equip/store path")
		game.refresh_item_views();await ticks(3)
		game.windows.item_tip(weapon,Rect2(500,100,28,28),false,false,uid)
		await frame("native_01_original_equipment")
	game.windows.inventory_tab=2;game.show_overlay("inventory");await ticks(3)
	check(game.windows.item_texture(material)!=null and game.windows.field_texture(material)!=null,"material icon and ground frame share delivered native atlas")
	await frame("native_02_original_materials")
	game.windows.inventory_tab=1;game.show_overlay("inventory");await ticks(3)
	check(game.windows.item_texture(food)!=null,"bulk recovery icon renders in actual consumables bag")
	await frame("native_03_original_foods")
	var restored=game.Session.new()
	check(game.store.read_into(restored) and restored.profile.equipped==weapon and restored.Inventory.stock(restored.profile,material)==2,"bulk original equipment and material ownership restore from the real save")
	print("[NATIVE_QUICK] COMPLETE checks=%d failures=%d captures=%d" % [checks,failures,captured.size()]);get_tree().quit(1 if failures else 0)
