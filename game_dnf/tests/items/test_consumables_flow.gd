extends "res://tests/items/test_services_flow.gd"
var path: String
var weapon: String
var death_enemies: Array=[]
var death_position:=Vector2.ZERO
var death_loot: Array=[]
func hold_near_enemy() -> void:
	var snap: Dictionary=game.combat.read_view()
	if snap.enemies.is_empty():release_all();return
	var pos: Vector2=snap.pos;var target: Vector2=snap.enemies[0].pos
	target.x+=-40 if pos.x<=target.x else 40
	key(KEY_LEFT,target.x-pos.x < -6);key(KEY_RIGHT,target.x-pos.x > 6);key(KEY_UP,target.y-pos.y < -4);key(KEY_DOWN,target.y-pos.y > 4)
func tap(code: int) -> void:
	key(code,true);await ticks(1);key(code,false);await ticks(2)
func run() -> void:
	await ticks(4)
	var fixture=game.Session.new();fixture.profile.gold=1000
	fixture.profile.stat_modifiers=[{"stat":"hp_max","op":"add","value":-350}]
	fixture.profile.quick_items[1]="potion";Items.give(fixture.profile,"potion",3)
	fixture.profile.town_location="elvengard";fixture.profile.town_position=[1400.0,220.0]
	weapon=fixture.profile.equipment.weapon
	var storage=game.Store.new();storage.path="res://../temp/recovery_tests/hero.json";path=storage.path
	check(storage.write(fixture) and game.enter_character(path),"declared low-health fixture loads from independent save")
	game.selected_dungeon="lorien";game.depart();await ticks(5)
	check(game.session.state=="battle" and game.combat.read_view().hp_max==150,"real original dungeon receives fixture stats through normal departure")
	# No damage/HP/death injection: walk near an enemy and wait for a real attack.
	for i in 3600:
		if game.combat.read_view().hp<150:break
		hold_near_enemy();await ticks(1)
	release_all()
	check(game.combat.read_view().hp>0 and game.combat.read_view().hp<150,"original enemy actually damages the player")
	var before:=JSON.stringify(game.session.serialize());var hp: float=game.combat.read_view().hp
	game.store.path="res://data/recovery.json/cannot_write.json";await tap(KEY_1)
	check(game.save_failed and JSON.stringify(game.session.serialize())==before and game.combat.read_view().hp<=hp,"actual healing hotkey rolls back item and cooldown when disk fails")
	game.store.path=path;hp=game.combat.read_view().hp;await tap(KEY_1)
	check(game.session.profile.inventory.potion==5 and game.combat.read_view().hp>hp,"real first hotkey consumes once and heals live actor")
	check(game.quick_views[0].get_node("item_cooldown").text!="" and game.quick_views[0].get_node("item_cooldown").text==game.quick_views[1].get_node("item_cooldown").text,"both bound shortcuts display the same shared cooldown")
	await frame("recovery_01_shared_cooldown")
	for i in 2400:
		if game.combat.read_view().hp<150:break
		hold_near_enemy();await ticks(1)
	release_all();before=JSON.stringify(game.session.serialize());await tap(KEY_2)
	check(JSON.stringify(game.session.serialize())==before and game.notification.contains("冷却"),"second physical shortcut cannot bypass cooldown while injured")
	game.show_overlay("inventory");await ticks(3)
	var clock: float=game.combat.read_view().time_ms
	var remaining: float=game.Session.Consumables.remaining(game.session.run,"potion",clock)
	await ticks(60);await tap(KEY_1)
	check(game.combat.read_view().time_ms==clock and game.Session.Consumables.remaining(game.session.run,"potion",clock)==remaining,"menu pause freezes simulation clock and healing cooldown")
	check(game.session.profile.inventory.potion==5,"menu hotkey cannot consume hidden healing item")
	await frame("recovery_02_paused_cooldown")
	game.show_overlay("");await ticks(3)
	# Intentionally make the death-record write fail before the real lethal hit.
	game.store.path="res://data/recovery.json/cannot_write.json"
	var durability: int=game.session.profile.gear[weapon].durability
	for i in 7200:
		if not game.recovery_bridge.pending_death.is_empty() or game.session.state=="defeated":break
		hold_near_enemy();await ticks(1)
	release_all();await ticks(3)
	var dead: Dictionary=game.combat.read_view()
	check(dead.finished and dead.hp==0 and not game.recovery_bridge.pending_death.is_empty(),"real lethal attack reaches retryable death-record failure")
	check(game.session.state=="battle" and game.session.profile.gear[weapon].durability==durability,"failed death save does not apply penalty to live profile")
	check(not game.save_profile() and not game.recovery_bridge.pending_death.is_empty() and game.session.profile.gear[weapon].durability==durability,"manual save cannot bypass the pending death transaction")
	await frame("recovery_03_death_save_retry")
	game.store.path=path;check(click_text("重试保存"),"death window offers real retry-save button");await ticks(3)
	check(game.session.state=="defeated" and game.session.profile.gear[weapon].durability==durability-3 and game.session.profile.gold==1000,"retry saves one death penalty and no revival fee")
	check(game.session.result.is_empty() and not game.session.profile.settled.has(game.session.run.id),"pending death does not prematurely settle the adventure")
	death_enemies=game.combat.read_view().enemies.duplicate(true);death_position=game.combat.read_view().pos
	death_loot=game.Session.Loot.pending(game.session.run,String(dead.room_id)).duplicate(true)
	await frame("recovery_04_death_choice")
	await after_death()
func after_death() -> void:
	check(click_text("放弃回城"),"death window has actual abandon-and-return button");await ticks(5)
	check(game.session.state=="town" and not is_instance_valid(game.battle) and game.session.profile.gold==1000 and game.session.profile.inventory.potion==5,"abandon returns to town without clear rewards or extra cost")
	var loaded=game.Session.new()
	check(game.store.read_into(loaded) and loaded.profile==game.session.profile,"consumed item and single death penalty survive disk reload")
	complete()
func complete() -> void:
	print("[LOOP_TEST] COMPLETE checks=%d failures=%d captures=%d" % [checks,failures,captured.size()]);get_tree().quit(1 if failures else 0)
