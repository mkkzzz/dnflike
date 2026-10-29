extends "res://tests/town/test_hendon.gd"
const Appearance=preload("res://content/weapon_appearance.gd")
## Equipment and presentation QA. One room only; no dungeon-completion requirement.
func run() -> void:
	await ticks(4)
	var s=game.Session.new();s.profile.name="逐件武器外观快验";s.profile.level=60
	s.profile.town_location="seria_room";s.profile.town_position=[450.0,200.0]
	for id: String in ["original_27601","original_27800","original_27647","original_27000"]:s.Inventory.give(s.profile,id,1)
	var storage=game.Store.new();storage.path="res://../temp/weapon_appearance_tests/hero.json"
	check(storage.write(s) and game.enter_character(storage.path),"declared appearance fixture loads into the actual town")
	await ticks(3)
	var uids: Dictionary={}
	for uid: String in game.session.profile.gear:uids[game.session.profile.gear[uid].definition]=uid
	check(game.act("items.equip",{"uid":uids.original_27601}),"equip first original katana through the normal candidate/store path")
	await ticks(2)
	check(game.town.actor.get_meta("weapon_item","")=="original_27601" and game.town.actor.equipment_layers.size()==2,"town actor receives exact equipped item and both native weapon layers")
	var first: String=game.town.actor.get_meta("weapon_appearance","")
	await frame("weapon_01_town_rusty_katana")
	var before:=JSON.stringify(game.session.serialize());var store_path: String=game.store.path
	var binding: String=Appearance.data().items.original_27800
	Appearance.data().items.erase("original_27800")
	check(not game.act("items.equip",{"uid":uids.original_27800}) and before==JSON.stringify(game.session.serialize()) and game.town.actor.get_meta("weapon_appearance","")==first,"missing exact item resource rejects the entire equipment change instead of reusing another sword")
	Appearance.data().items["original_27800"]=binding
	game.store.path="res://data/quests.json/cannot_write.json"
	check(not game.act("items.equip",{"uid":uids.original_27800}) and before==JSON.stringify(game.session.serialize()) and game.town.actor.get_meta("weapon_appearance","")==first,"failed equipment write preserves profile and actual scene appearance together")
	game.store.path=store_path
	check(game.act("items.equip",{"uid":uids.original_27800}),"normal same-family swap commits")
	await ticks(2)
	check(game.town.weapon_shape=="katana" and game.town.actor.get_meta("weapon_item","")=="original_27800" and game.town.actor.get_meta("weapon_appearance","")!=first,"two different katana items visibly bind different native skins without changing family")
	await frame("weapon_02_town_sabre")
	check(game.act("items.equip",{"uid":uids.original_27000}),"cross-family short sword equips normally")
	await ticks(2)
	check(game.town.weapon_shape=="shortsword" and game.town.actor.get_meta("weapon_item","")=="original_27000","town family and exact source item update together")
	await frame("weapon_03_town_short_sword")
	check(game.act("items.unequip",{"slot":"weapon"}) and game.town.actor.equipment_layers.is_empty(),"unequipping really removes weapon layers from the scene")
	await frame("weapon_04_town_unarmed")
	check(game.act("items.equip",{"uid":uids.original_27647}),"equip source model three for persistence and battle checks")
	game.town.set_weapon("greatsword")
	game.show_character_selection();await ticks(2)
	check(game.enter_character(store_path),"reload exact saved equipment from disk")
	await ticks(3)
	check(game.town.actor.get_meta("weapon_item","")=="original_27647","reloaded town appearance uses exact original item")
	game.selected_dungeon="lorien";game.depart();await ticks(4)
	var api=preload("res://debug/test_api.gd").new(game.battle)
	check(game.session.state=="battle" and game.combat.read_view().get("weapon_item","")=="original_27647","public start-room snapshot carries exact equipped ID into the battle view")
	check(api.view_weapon_appearance()==Appearance.data().items.original_27647,"battle consumes the same native skin as the town")
	var invalid: Dictionary=game.session.stats();invalid.weapon="shortsword"
	check(not game.combat.update_numbers(invalid) and game.combat.read_view().weapon_item=="original_27647","public bridge rejects a family/item conflict before changing live appearance or numbers")
	game.debug_panel.execute("god on")
	await frame("weapon_05_battle_equipped_idle")
	key(KEY_X,true);await ticks(5);key(KEY_X,false);await ticks(2)
	check(api.view_pose() in ["attack1","attack2","attack3"] and api.weapon_layers_follow_actor(),"real attack input advances both source weapon ANI layers")
	await frame("weapon_06_battle_attack")
	# Finish the normal attack before jumping; this test does not require a new
	# jump-cancel rule merely to verify the equipment's airborne presentation.
	await ticks(36)
	key(KEY_LEFT,true);await ticks(2);key(KEY_LEFT,false)
	key(KEY_C,true);await ticks(3);key(KEY_C,false);await ticks(2)
	check(float(api.p("z"))>0 and api.weapon_layers_follow_actor(),"actual facing and airborne height stay aligned for both weapon layers")
	await frame("weapon_07_battle_jump_left")
	# A presentation event fixture checks ghost copying without asking unrelated
	# simulation cancel/skill/AI behavior to pass before equipment can be delivered.
	api.emit_weapon_ghost_fixture()
	check(api.latest_ghost_weapon_item()=="original_27647","afterimage event copies exact item appearance instead of the generic family weapon")
	check(not game.act("items.equip",{"uid":uids.original_27800}),"existing town-only equipment rule remains enforced")
	print("[WEAPON_QUICK] COMPLETE checks=%d failures=%d captures=%d" % [checks,failures,captured.size()]);get_tree().quit(1 if failures else 0)
