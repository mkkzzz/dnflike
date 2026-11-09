extends "res://tests/items/test_services_flow.gd"
var path: String
var weapon: String
var death_enemies: Array=[]
var death_position:=Vector2.ZERO
var death_loot: Array=[]
var death_coins:=0
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
	game.store.path=path;hp=game.combat.read_view().hp
	var cue_count:int=game.combat.events().events_of("combat.cue").size()
	await tap(KEY_1)
	check(game.session.profile.inventory.potion==5 and game.combat.read_view().hp>hp,"real first hotkey consumes once and heals live actor")
	var item_cues:Array=game.combat.events().events_of("combat.cue").slice(cue_count).map(func(event):return String(event.get("key","")))
	check("item_fastheal" in item_cues,"successful potion use publishes the original fast-heal effect cue")
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
	var retry_save: Button=game.modal.find_child("recovery_window_retry_save",true,false)
	check(retry_save!=null and get_tree().root.gui_get_focus_owner()==retry_save,"failed formal death focuses its retry-save action")
	game.store.path=path;check(click_text("重试保存"),"death window offers real retry-save button");await ticks(3)
	check(game.session.state=="defeated" and game.session.profile.gear[weapon].durability==durability-3 and game.session.profile.gold==1000 and game.session.profile.resurrection_coins==3,"retry saves one death penalty without charging a revival coin")
	check(game.session.result.is_empty() and not game.session.profile.settled.has(game.session.run.id),"pending death does not prematurely settle the adventure")
	death_enemies=game.combat.read_view().enemies.duplicate(true);death_position=game.combat.read_view().pos
	death_loot=game.Session.Loot.pending(game.session.run,String(dead.room_id)).duplicate(true)
	await frame("recovery_04_death_choice")
	death_coins=int(game.session.profile.resurrection_coins)
	var revive_button: Button=game.modal.find_child("recovery_window_revive",true,false)
	check(revive_button!=null and get_tree().root.gui_get_focus_owner()==revive_button,"formal death prompt focuses the affordable revive action")
	game.store.path="res://data/recovery.json/cannot_write.json"
	await tap(KEY_X)
	var feedback: Label=game.modal.find_child("recovery_window_feedback",true,false)
	check(game.session.state=="defeated" and int(game.session.profile.resurrection_coins)==death_coins
		and feedback!=null and feedback.visible and feedback.text.contains("存档写入失败"),
		"failed formal revival save keeps the coin and reports the retry reason")
	game.store.path=path
	await frame("recovery_04b_revive_save_retry")
	await tap(KEY_X)
	var revived: Dictionary=game.combat.read_view()
	check(game.session.state=="battle" and game.session.profile.resurrection_coins==death_coins-1 and game.session.profile.gold==1000,"X consumes one revival coin and returns to the same battle")
	check(revived.hp>0 and revived.invulnerable_ms>0 and int(revived.death_id)>0,"revive restores live HP and grants the source protection window")
	check(revived.room_id==dead.room_id and revived.pos==death_position and JSON.stringify(revived.enemies)==JSON.stringify(death_enemies),"revive keeps the room, player position and every enemy")
	check(game.session.run.recovery.revives==1 and int(revived.revive_fx_count)==1,"revive commits once and plays one original coin effect")
	await frame("recovery_05_revived")
	for i in 7200:
		if game.session.state=="defeated":break
		hold_near_enemy();await ticks(1)
	release_all();await ticks(3)
	check(game.session.state=="defeated" and game.session.profile.resurrection_coins==death_coins-1,"second real death keeps the coin balance until the player chooses")
	await after_death()
func after_death() -> void:
	check(click_text("返回城镇"),"death window has actual return-to-town button");await ticks(5)
	check(game.session.state=="town" and not is_instance_valid(game.battle) and game.session.profile.gold==1000 and game.session.profile.inventory.potion==5 and game.session.profile.resurrection_coins==death_coins-1,"return to town keeps the single paid coin and grants no clear reward")
	var loaded=game.Session.new()
	check(game.store.read_into(loaded) and loaded.profile==game.session.profile,"consumed item and single death penalty survive disk reload")
	await check_original_awaken_food()
	complete()

func check_original_awaken_food() -> void:
	const Strawberry := "original_1089"
	const Castor := "original_1090"
	const Rng = preload("res://core/det_rng.gd")
	const Restoration = preload("res://combat/item_restoration.gd")
	var fixture=game.Session.new()
	fixture.profile.level=50
	fixture.profile.town_location="elvengard"
	fixture.profile.town_position=[1400.0,220.0]
	fixture.profile.stat_modifiers=[{"stat":"mp_max","op":"add","value":2000}]
	var supplied: bool=Items.give(fixture.profile,Strawberry,1).ok and Items.give(fixture.profile,Castor,2).ok
	fixture.profile.quick_items[0]=Strawberry
	fixture.profile.quick_items[1]=Castor
	var storage=game.Store.new()
	storage.path="res://../temp/recovery_tests/awaken_food.json"
	game.show_character_selection()
	var entered: bool=supplied and storage.write(fixture) and game.enter_character(storage.path)
	check(entered,"original awakening rewards load with their two item shortcuts")
	if not entered:return
	for id in [Strawberry,Castor]:
		var icon: Texture2D=game.windows.item_texture(id)
		var field: Texture2D=game.windows.field_texture(id)
		check(icon!=null and icon.get_size()==Vector2(28,28) and field!=null,"original inventory and ground graphics are ready for "+id)
	game.selected_dungeon="lorien"
	game.depart()
	await ticks(3)
	check(game.session.state=="battle","original food is used through the normal dungeon flow")
	if game.session.state!="battle":return
	var kernel=game.combat.game
	var numbers=kernel.numeric_player
	check(kernel.apply_effect({"kind":"effect","id":"bleed"}),"fixture applies bleeding through the live status API")
	kernel.player.hp=kernel.max_hp
	game.use_quick(0)
	check(not numbers.effects.active.has("bleed") and Items.stock(game.session.profile,Strawberry)==0,
		"strawberry clears bleeding at full health and commits exactly one unit")
	var healing: Dictionary=kernel.item_restorations.back() if not kernel.item_restorations.is_empty() else {}
	check(healing.get("hp")==1930 and healing.get("duration_ms")==1000,"original HP request queues 1930 over exactly 1000 ms")
	var seed_hit:=0
	var seed_miss:=0
	for seed_value in range(1024):
		var roll:=Rng.new(seed_value).range_int(0,0x7fffffff)%100
		if roll==9:seed_hit=seed_value
		elif roll==10:seed_miss=seed_value
		if seed_hit!=0 and seed_miss!=0:break
	check(seed_hit!=0 and seed_miss!=0,"deterministic rolls bracket the original ten percent boundary")
	kernel.player.mp=1.0
	kernel.rng.reseed(seed_miss)
	game.store.path="res://data/recovery.json/cannot_write.json"
	game.use_quick(1)
	check(game.save_failed and Items.stock(game.session.profile,Castor)==2 and not numbers.effects.active.has("stun"),
		"failed food save spends no item, effect or roll")
	game.store.path=storage.path
	game.use_quick(1)
	check(Items.stock(game.session.profile,Castor)==1 and not numbers.effects.active.has("stun"),
		"roll 10 fails the stun check while MP food uses its own cooldown group")
	var restoration: Dictionary=kernel.item_restorations.back() if not kernel.item_restorations.is_empty() else {}
	check(restoration.get("mp")==1420 and restoration.get("duration_ms")==1000,"original MP request queues 1420 over exactly 1000 ms")
	Restoration.step(kernel,500)
	check(is_equal_approx(float(kernel.player.mp),711.0),"recovery scheduler grants half the original MP after 500 ms")
	Restoration.step(kernel,500)
	check(is_equal_approx(float(kernel.player.mp),1421.0) and kernel.item_restorations.is_empty(),
		"recovery scheduler completes the original MP amount once")
	kernel.player.mp=1.0
	kernel.elapsed_ms+=10000
	kernel.rng.reseed(seed_hit)
	game.use_quick(1)
	var stun: Dictionary=numbers.effects.active.get("stun",{})
	check(Items.stock(game.session.profile,Castor)==0 and stun.get("remaining_ms")==5000.0
		and stun.get("definition",{}).get("status_level")==50,"roll 9 applies level-50 self stun for 5000 ms at equal level")
	await tap(KEY_X)
	check(String(kernel.player.action).is_empty() and numbers.effects.controlled(),"self stun suppresses actual attack input")

func complete() -> void:
	print("[LOOP_TEST] COMPLETE checks=%d failures=%d captures=%d" % [checks,failures,captured.size()]);get_tree().quit(1 if failures else 0)
