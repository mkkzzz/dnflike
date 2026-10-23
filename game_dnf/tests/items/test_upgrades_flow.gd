extends "res://tests/items/test_services_flow.gd"
const Upgrades=preload("res://items/upgrades.gd")
func visit_upgrade(npc: String, location: String, action: String) -> void:
	game.show_overlay("")
	game.town.set_location(location,game.session.TownWorld.vec(game.town.world.scene(location)["npcs"][npc]))
	game.session.profile.town_location=location
	game.save_profile();game.show_overlay("npc");await ticks(3)
	check(click_text(action),"actual NPC dialogue opens "+action);await ticks(3)
func owned_slot(uid: String) -> Control:
	var node:=slot("upgrade_equipment",uid)
	return node if node!=null else slot("bag",uid)
func confirm() -> void:
	check(click_text("确认操作"),"actual confirmation button is present");await ticks(3)
func run() -> void:
	await ticks(4)
	var fixture=game.Session.new();fixture.profile.gold=1000;fixture.profile.town_location="hendon_main"
	fixture.profile.town_position=fixture.town_world.scene("hendon_main")["npcs"]["kiri"].duplicate()
	var weapon: String=fixture.profile.equipment.weapon
	fixture.profile.services.upgrades.seed=1
	Items.give(fixture.profile,"scrap_iron",12)
	var coat: String=fixture.command("numbers.gear_give",{"id":"training_coat"}).uid
	fixture.command("numbers.gear_equip",{"uid":coat})
	var storage=game.Store.new();storage.path="res://../temp/upgrade_tests/hero.json"
	check(storage.write(fixture) and game.enter_character(storage.path),"independent fixture enters native town through actual save")
	await ticks(3);await visit_upgrade("kiri","hendon_main","强化")
	click_control(owned_slot(weapon));await ticks(2)
	check(game.upgrade_windows.detail.text.contains("强化 +0") and game.upgrade_windows.preview.text.contains("成功率 100%"),"selection shows actual item level and chance")
	check(game.upgrade_windows.preview.text.contains("铁质碎片 ×1（可用12）"),"preview shows configured bill and spendable material stock")
	await frame("upgrades_01_kiri")
	click_text("强化一级");await ticks(3)
	check(is_instance_valid(game.upgrade_windows.confirmation),"reinforcement opens blocking confirmation")
	await frame("upgrades_02_reinforce_confirm")
	var before:=JSON.stringify(game.session.serialize());click_text("取消操作");await ticks(3)
	check(JSON.stringify(game.session.serialize())==before,"cancel consumes no cost or random state")
	click_text("强化一级");await ticks(2)
	var path: String=game.store.path;game.store.path="res://data/upgrades.json/cannot_write.json"
	before=JSON.stringify(game.session.serialize());await confirm()
	check(game.save_failed and JSON.stringify(game.session.serialize())==before and is_instance_valid(game.upgrade_windows.confirmation),"failed write retains live item, gold, materials, RNG and retryable confirmation")
	game.store.path=path;await confirm()
	check(game.session.profile.gear[weapon].reinforce==1 and game.session.profile.gold==980 and game.session.profile.inventory.scrap_iron==11,"GUI enhancement commits one exact bill")
	check(game.session.profile.services.upgrades.attempts==1 and game.notification.begins_with("强化成功"),"GUI success is truthful and persisted only once")
	var loaded=game.Session.new()
	check(game.store.read_into(loaded) and loaded.profile==game.session.profile,"actual disk reload preserves enhancement and next RNG state")
	await frame("upgrades_03_reinforce_success")
	# Declared pre-upgraded fixture exercises an actual failed chance roll through GUI.
	game.session.profile.gear[weapon].reinforce=3;game.session.profile.services.upgrades.seed=seed_for_failure()
	check(game.save_profile(),"probabilistic step fixture saved before UI")
	game.show_overlay("upgrades");await ticks(3)
	click_text("强化一级");await ticks(2);await frame("upgrades_04_chance_confirm");await confirm()
	check(game.session.profile.gear[weapon].reinforce==3 and game.session.profile.gold==880 and game.session.profile.inventory.scrap_iron==7,"actual failed chance roll keeps gear and consumes previewed cost")
	check(game.notification.begins_with("强化失败"),"failed enhancement produces explicit failure result")
	await visit_upgrade("sinda","hendon_auction","附魔")
	click_control(owned_slot(weapon));await ticks(2)
	check(game.upgrade_windows.preview.text.contains("替换原有全部附魔"),"enchantment clearly describes overwrite behavior")
	click_text("应用附魔");await ticks(2);await frame("upgrades_05_enchant_confirm");await confirm()
	check(game.session.profile.gear[weapon].enchants==[Upgrades.config().enchants.strength.modifier] and game.session.profile.inventory.scrap_iron==4 and game.session.profile.gold==800,"GUI applies configured strength enchant and charges once")
	var strength: float=game.session.stats().numbers.strength
	click_text("智力附魔");await ticks(3)
	check(game.upgrade_windows.recipe=="intelligence","actual native button chooses second enchant recipe")
	click_text("应用附魔");await ticks(2);await frame("upgrades_06_replace_confirm");await confirm()
	check(game.session.profile.gear[weapon].enchants.size()==1 and game.session.stats().numbers.strength==strength-3 and game.session.profile.inventory.scrap_iron==1,"GUI replacement removes old strength and consumes only new recipe cost")
	click_text("清除附魔");await ticks(2);await frame("upgrades_07_clear_confirm");await confirm()
	check(game.session.profile.gear[weapon].enchants.is_empty() and game.session.profile.gold==720,"GUI clears enchant for displayed zero cost")
	click_text("应用附魔");await ticks(2);before=JSON.stringify(game.session.serialize());await confirm()
	check(JSON.stringify(game.session.serialize())==before and game.notification.contains("不足"),"material shortage after confirmation consumes nothing")
	click_text("取消操作");await ticks(3)
	await visit_upgrade("kiri","hendon_main","强化")
	click_control(owned_slot(coat));await ticks(2)
	check(game.upgrade_windows.preview.text.contains("物理防御 25 → 28"),"armor enhancement previews actual defensive contribution")
	click_text("强化一级");await ticks(2);await confirm()
	check(game.session.profile.gear[coat].reinforce==1 and game.session.profile.inventory.scrap_iron==0,"GUI also enhances equipped armor with last material")
	await frame("upgrades_08_armor_success")
	check(game.store.read_into(loaded) and loaded.profile==game.session.profile,"completed enhance, enchant replace and clear survive reload")
	# Restart the public combat session and verify persisted equipment reaches the actor.
	game.show_overlay("");game.selected_dungeon="lorien";game.depart();await ticks(5)
	check(game.session.state=="battle" and game.combat.read_view().numbers.physical_attack==31 and game.combat.read_view().numbers.physical_defense==game.session.stats().numbers.physical_defense,"new combat receives saved weapon reinforcement and armor defense")
	if game.session.state=="battle":game.act("flow.retreat")
	game.return_town();await ticks(3)
	print("[LOOP_TEST] COMPLETE checks=%d failures=%d captures=%d" % [checks,failures,captured.size()]);get_tree().quit(1 if failures else 0)
func seed_for_failure() -> int:
	for seed in range(1,1000):
		if (seed*48271)%Upgrades.MODULUS%100>=85:return seed
	return 1
