extends SceneTree
const Session=preload("res://flow/session.gd")
const Items=preload("res://items/inventory.gd")
const Consumables=preload("res://items/consumables.gd")
const Recovery=preload("res://flow/recovery.gd")
var checks:=0
var failures:=0
func check(ok: bool, label: String) -> void:
	checks+=1
	if not ok:failures+=1
	print("[RECOVERY_TEST] %s %s" % ["PASS" if ok else "FAIL",label])
func view(s, clock:=0.0) -> Dictionary:
	return {"run_id":s.run.id,"room_id":"forest_trial:0","hp":100.0,"hp_max":500.0,"paused":false,"finished":false,"time_ms":clock}
func death(s, id: int) -> Dictionary:
	return {"type":"combat.player_defeated","run_id":s.run.id,"room_id":"forest_trial:0","room_index":0,"event_id":id,"stats":{"time_ms":1000.0,"damage_taken":600}}
func revive(s, tx: String) -> Dictionary:
	return s.revive_command({"transaction":tx,"signature":Recovery.quote(s.profile,s.run).get("signature","")})
func _initialize() -> void:
	var s=Session.new();s.command("flow.depart")
	var p: Dictionary=s.profile;var sample:=view(s,125.5)
	var response:=s.use_consumable("potion",sample,"drink_1")
	check(response.ok and p.inventory.potion==2 and response.effect.kind=="heal" and response.effect.amount==150,"valid healing item consumes exactly one and returns configured public effect")
	check(Consumables.remaining(s.run,"potion",125.5)==10000,"fractional simulation clock starts precise cooldown")
	var before:=JSON.stringify(s.serialize())
	check(not s.use_consumable("potion",sample,"drink_1").ok and JSON.stringify(s.serialize())==before,"repeated use transaction cannot consume twice")
	check(not s.use_consumable("potion",sample,"drink_2").ok and JSON.stringify(s.serialize())==before,"second shortcut cannot bypass shared cooldown")
	sample.time_ms=10125.0
	check(not s.use_consumable("potion",sample,"drink_3").ok,"cooldown remains active before exact deadline")
	sample.time_ms=10125.5
	check(s.use_consumable("potion",sample,"drink_4").ok and p.inventory.potion==1,"cooldown expires at exact simulation deadline")
	var f=Session.new();f.command("flow.depart");sample=view(f)
	f.run.consumables.groups.recovery=5000
	check(not f.use_consumable("potion",sample,"group_only").ok and f.profile.inventory.potion==3,"group cooldown blocks an individually ready item")
	f.run.consumables.groups.clear();f.run.consumables.items.potion=5000
	check(not f.use_consumable("potion",sample,"item_only").ok,"individual cooldown also blocks a ready group")
	f.run.consumables.items.clear();sample.hp=500
	before=JSON.stringify(f.serialize())
	check(not f.use_consumable("potion",sample,"full").ok and JSON.stringify(f.serialize())==before,"full health never consumes a healing item")
	sample.hp=0
	check(not f.use_consumable("potion",sample,"dead").ok,"dead actor cannot drink")
	sample.hp=100;sample.paused=true
	check(not f.use_consumable("potion",sample,"paused").ok,"paused menu cannot drink")
	sample.paused=false;sample.finished=true
	check(not f.use_consumable("potion",sample,"finished").ok,"finished adventure cannot drink")
	sample.finished=false;sample.run_id="old"
	check(not f.use_consumable("potion",sample,"old").ok,"stale adventure snapshot cannot consume")
	sample=view(f);sample.time_ms=NAN
	check(not f.use_consumable("potion",sample,"nan").ok,"nonfinite simulation clock rejected")
	sample=view(f);sample.hp="invalid"
	check(not f.use_consumable("potion",sample,"bad_hp").ok,"invalid vitals snapshot rejected without exception")
	sample=view(f);sample.hp=450
	check(f.use_consumable("potion",sample,"partial").amount==50,"reported actual restoration is clipped to missing health")
	var locked=Session.new();locked.command("flow.depart")
	var uid: String=locked.profile.item_state.bags.consumable[0]
	locked.profile.item_state.stacks[uid].locked=true
	before=JSON.stringify(locked.serialize())
	check(not locked.use_consumable("potion",view(locked),"locked").ok and JSON.stringify(locked.serialize())==before,"locked stack cannot be consumed")
	locked.profile.item_state.stacks[uid].locked=false;locked.profile.item_state.bags.consumable[0]="";locked.profile.item_state.storage[0]=uid;Items.sync(locked.profile)
	check(not locked.use_consumable("potion",view(locked),"warehouse").ok,"stored stack cannot be consumed")
	locked.profile.item_state.storage[0]="";locked.profile.item_state.overflow.append(uid);Items.sync(locked.profile)
	check(not locked.use_consumable("potion",view(locked),"overflow").ok,"pending recovery stack cannot be consumed")
	check(not locked.use_consumable("iron_sword",view(locked),"wrong_item").ok,"equipment is never treated as consumable")
	s.command("flow.retreat");s.command("flow.return");s.command("flow.depart")
	check(Consumables.remaining(s.run,"potion",0)==0,"new adventure resets adventure-scoped cooldown")
	var dying=Session.new();dying.profile.gold=1000;dying.profile.resurrection_coins=5;dying.command("flow.depart")
	var weapon: String=dying.profile.equipment.weapon
	var event:=death(dying,10)
	check(dying.combat_event(event).ok and dying.state=="defeated" and dying.result.is_empty() and not dying.profile.settled.has(dying.run.id),"death enters pending choice without settling or granting reward")
	check(dying.profile.gear[weapon].durability==37 and dying.profile.gold==1000 and dying.profile.resurrection_coins==5,"death penalty applied once before revival choice")
	before=JSON.stringify(dying.serialize())
	check(not dying.combat_event(event).ok and JSON.stringify(dying.serialize())==before,"duplicate pending death cannot repeat penalty")
	check(not dying.use_consumable("potion",view(dying),"dead_item").ok,"pending death cannot use consumables")
	var q:=Recovery.quote(dying.profile,dying.run)
	check(q.ok and q.coin_cost==1 and q.coins==5 and q.affordable and q.hp_percent==50 and q.mp_percent==50 and q.invulnerable_ms==3000,"revival quote contains configured coin cost, recovery and invulnerability")
	var request: Dictionary={"transaction":"revive_1","signature":q.signature}
	dying.profile.gear[weapon].quality=99;before=JSON.stringify(dying.serialize())
	check(not dying.revive_command(request).ok and JSON.stringify(dying.serialize())==before,"changed equipment invalidates revival preview")
	request.signature=Recovery.quote(dying.profile,dying.run).signature
	dying.profile.resurrection_coins=0;before=JSON.stringify(dying.serialize())
	check(not dying.revive_command(request).ok and JSON.stringify(dying.serialize())==before,"insufficient revival coins preserve all state")
	dying.profile.resurrection_coins=5
	check(revive(dying,"revive_1").ok and dying.state=="battle" and dying.profile.resurrection_coins==4 and dying.profile.gold==1000 and dying.run.recovery.revives==1,"coin revival returns same adventure to battle and charges once")
	check(dying.profile.gear[weapon].durability==37,"revival never applies death penalty a second time")
	before=JSON.stringify(dying.serialize())
	check(not dying.revive_command(request).ok and JSON.stringify(dying.serialize())==before,"repeated revival cannot charge while alive")
	check(not dying.combat_event(event).ok and JSON.stringify(dying.serialize())==before,"old death event after revival cannot kill profile again")
	dying.combat_event(death(dying,20));q=Recovery.quote(dying.profile,dying.run)
	check(q.ok and q.coins==4 and q.affordable and dying.profile.gear[weapon].durability==34,"new death incurs one new penalty and keeps the coin quote")
	check(revive(dying,"revive_2").ok and dying.profile.resurrection_coins==3,"second revival consumes one more coin")
	dying.combat_event(death(dying,30));check(revive(dying,"revive_3").ok and dying.profile.resurrection_coins==2,"third revival consumes one more coin")
	dying.combat_event(death(dying,40));before=JSON.stringify(dying.serialize())
	check(not revive(dying,"revive_4").ok and JSON.stringify(dying.serialize())==before,"per-adventure revival limit blocks further charge")
	var restored=Session.new();var worn: int=dying.profile.gear[weapon].durability
	check(restored.restore(JSON.parse_string(JSON.stringify(dying.serialize()))) and restored.state=="result" and not restored.result.victory and restored.profile.gear[weapon].durability==worn and restored.profile.gold==1000 and restored.profile.resurrection_coins==2,"reload during pending death ends adventure without new charge or repeated penalty")
	check(dying.command("flow.abandon").ok and dying.state=="result" and dying.result.gold==0 and dying.result.xp==0,"explicit abandonment settles failure without clear rewards")
	before=JSON.stringify(dying.serialize())
	check(not dying.command("flow.abandon").ok and JSON.stringify(dying.serialize())==before,"abandonment cannot settle twice")
	check(dying.command("flow.return").ok and dying.state=="town" and dying.run.is_empty(),"failed adventure can return to town")
	var winner=Session.new();winner.profile.gold=1000;winner.command("flow.depart")
	winner.combat_event(death(winner,1));revive(winner,"win_revive")
	check(winner.combat_event({"type":"combat.room_combat_finished","run_id":winner.run.id,"final_room":true,"stats":{}}).ok and winner.result.victory and winner.profile.gold==1150 and winner.profile.resurrection_coins==2,"revived adventure may still clear and receive one legitimate reward")
	before=JSON.stringify(winner.serialize())
	check(not winner.combat_event({"type":"combat.room_combat_finished","run_id":winner.run.id,"final_room":true}).ok and JSON.stringify(winner.serialize())==before,"repeated clear cannot pay twice after revival")
	var old=Session.new().serialize();old.schema="dnf_loop_save/4"
	check(Session.new().restore(old),"previous v4 service saves remain readable")
	var no_coins=Session.new().serialize();no_coins.profile.erase("resurrection_coins")
	var migrated=Session.new()
	check(migrated.restore(no_coins) and migrated.profile.resurrection_coins==3,"old saves receive starter revival coins")
	var invalid=winner.serialize();invalid.run.consumables.groups.recovery=-1
	check(not Session.new().restore(invalid),"negative saved cooldown rejected")
	invalid=winner.serialize();invalid.profile.resurrection_coins=-1
	check(not Session.new().restore(invalid),"negative saved revival coin balance rejected")
	invalid=winner.serialize();invalid.profile.resurrection_coins=1.5
	check(not Session.new().restore(invalid),"fractional saved revival coin balance rejected")
	invalid=winner.serialize();invalid.run.consumables=[]
	check(not Session.new().restore(invalid),"malformed consumable state rejected")
	invalid=winner.serialize();invalid.run.recovery.revives=100
	check(not Session.new().restore(invalid),"impossible saved revival count rejected")
	invalid=winner.serialize();invalid.run.recovery.seen["1"]=false
	check(not Session.new().restore(invalid),"invalid death receipt rejected")
	invalid=winner.serialize();invalid.run.recovery.pending=[]
	check(not Session.new().restore(invalid),"malformed pending death rejected")
	var empty_id=Session.new();empty_id.command("flow.depart");empty_id.combat_event(death(empty_id,90))
	invalid=empty_id.serialize();invalid.run.id=""
	check(not Session.new().restore(invalid),"pending death requires a nonempty adventure identity")
	check(Items.valid(winner.profile) and Recovery.valid(winner.run) and Consumables.valid(winner.run),"final ownership and lifecycle contracts remain valid")
	print("[RECOVERY_TEST] COMPLETE checks=%d failures=%d" % [checks,failures]);quit(1 if failures else 0)
