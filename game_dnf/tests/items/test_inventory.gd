extends SceneTree
const Session=preload("res://flow/session.gd")
const Items=preload("res://items/inventory.gd")
const Loot=preload("res://loot/service.gd")
var checks:=0
var failures:=0
func check(value: bool, message: String) -> void:
	checks+=1
	if not value:failures+=1;print("[ITEM_TEST] FAIL "+message)
func _initialize() -> void:
	var s=Session.new();var p: Dictionary=s.profile
	check(Items.valid(p),"starter ledger has one owner for every instance")
	check(Items.give(p,"potion",200)["ok"],"large reward splits into finite stacks")
	var bag: Array=p.item_state.bags.consumable
	check(Items.count(p,bag[0])==99 and Items.count(p,bag[1])==99 and Items.count(p,bag[2])==5 and p.inventory.potion==203,"99 stack boundary and aggregate compatibility")
	var uid: String=bag[2]
	check(Items.command(p,"items.split",{"uid":uid,"count":2})["ok"] and Items.count(p,uid)==3,"split preserves original identity and amount")
	check(Items.valid(p),"split preserves ownership invariant")
	check(Items.command(p,"items.lock",{"uid":uid})["ok"] and Items.stock(p,"potion")==200,"locked stack excluded from spendable stock")
	var before:=JSON.stringify(p)
	check(not Items.command(p,"items.split",{"uid":uid,"count":1})["ok"] and JSON.stringify(p)==before,"locked split rejected atomically")
	check(not Items.command(p,"items.deposit",{"uid":uid})["ok"],"locked storage transfer rejected")
	check(Items.command(p,"items.sort",{})["ok"] and p.item_state.bags.consumable[2]==uid and Items.count(p,uid)==3,"sort preserves locked cell")
	Items.command(p,"items.lock",{"uid":uid})
	check(Items.command(p,"items.deposit",{"uid":uid})["ok"] and p.inventory.potion==200 and Items.count(p,uid)==3,"storage transfers identity without duplicating count")
	check(Items.command(p,"items.withdraw",{"uid":uid})["ok"] and p.inventory.potion==203,"withdraw restores carried aggregate")
	check(Items.consume(p,"potion",100)["ok"] and p.inventory.potion==103 and Items.valid(p),"multi-stack consumption conserves amount")
	check(not Items.consume(p,"potion",104)["ok"] and p.inventory.potion==103,"insufficient consumption leaves all stacks")
	var first: String=p.equipment.weapon
	var result:=s.command("numbers.gear_give",{"id":"iron_sword","quality":100})
	var second: String=result.get("uid","")
	check(result["ok"] and second!=first and p.gear[second].quality==100,"same definition gets distinct rolled instance")
	check(s.command("numbers.gear_equip",{"uid":second})["ok"] and p.equipment.weapon==second and first in p.item_state.bags.weapon,"equip swaps exact identity")
	check(Items.command(p,"items.deposit",{"uid":first})["ok"] and p.inventory.iron_sword==1,"stored weapon is not counted as carried")
	s.stats()
	check(p.gear.has(first) and Items.valid(p),"numeric normalization cannot delete stored equipment")
	check(not s.command("numbers.gear_equip",{"uid":first})["ok"],"cannot equip from storage")
	var restored=Session.new()
	check(restored.restore(JSON.parse_string(JSON.stringify(s.serialize()))) and restored.profile==p,"canonical JSON roundtrip preserves every owner and roll")
	var corrupt:=s.serialize();corrupt.profile.item_state.bags.weapon[0]=first
	check(not restored.restore(corrupt),"duplicate storage and backpack ownership rejected")
	corrupt=s.serialize();corrupt.profile.item_state.stacks[uid].count=100
	check(not restored.restore(corrupt),"oversized stack rejected")
	corrupt=s.serialize();corrupt.profile.item_state.next_stack=1
	check(not restored.restore(corrupt),"reused stack serial rejected")
	var full=Session.new();full.profile.gold=100000
	check(Items.give(full.profile,"forest_sword",48)["ok"],"48 independent equipment fit")
	before=JSON.stringify(full.profile)
	check(not full.command("items.buy",{"id":"forest_sword"})["ok"] and JSON.stringify(full.profile)==before,"full backpack purchase does not spend gold or create orphan")
	check(not full.command("items.unequip")["ok"] and full.profile.equipment.weapon!="","full bag unequip leaves weapon worn")
	check(Items.give(full.profile,"forest_sword",1,80,true)["ok"] and full.profile.item_state.overflow.size()==1,"guaranteed rewards go to recoverable overflow")
	check(Items.command(full.profile,"items.recover",{})["ok"] and full.profile.item_state.overflow.size()==1,"recovery preserves full-bag remainder")
	var stored: String=full.profile.item_state.bags.weapon[0]
	Items.command(full.profile,"items.deposit",{"uid":stored});Items.command(full.profile,"items.recover",{})
	check(full.profile.item_state.overflow.is_empty() and Items.valid(full.profile),"recovery fills freed cell once")
	var legacy=Session.new().serialize();legacy.profile.erase("item_state");legacy.profile.inventory.potion=5000;legacy.profile.inventory.iron_sword=55
	legacy.profile.gear={};legacy.profile.equipment={};legacy.profile.next_gear=1
	legacy.profile.erase("numbers_revision")
	var old=Session.new()
	check(old.restore(JSON.parse_string(JSON.stringify(legacy))),"legacy overflowing save migrates")
	check(old.profile.item_state.overflow.size()==9 and old.profile.gear.size()==55 and Items.valid(old.profile),"migration recovers every old weapon and potion stack")
	var run: Dictionary={"id":"run_test","dungeon":"lorien"}
	var event: Dictionary={"run_id":"run_test","room_id":"boss_room","entity_id":7,"position":Vector2(300,200),"boss":true}
	check(Loot.generate(run,event) and Loot.pending(run,"boss_room").size()==3,"boss event generates actual ground records")
	before=JSON.stringify(run)
	check(not Loot.generate(run,event) and JSON.stringify(run)==before,"duplicate death never rerolls")
	var replay: Dictionary={"id":"run_test","dungeon":"lorien"};Loot.generate(replay,event)
	check(run==replay,"same event has stable item amounts and qualities")
	var drops:=Loot.pending(run,"boss_room");var gold: String=drops[0].id
	check(not Loot.claim(p,run,gold,"other",Vector2(300,200))["ok"],"cross-room pickup rejected")
	check(not Loot.claim(p,run,gold,"boss_room",Vector2.ZERO)["ok"],"distant pickup rejected")
	var wallet:=int(p.gold)
	check(Loot.claim(p,run,gold,"boss_room",Vector2(300,200))["ok"] and p.gold>wallet,"nearby gold enters wallet")
	wallet=int(p.gold)
	check(not Loot.claim(p,run,gold,"boss_room",Vector2(300,200))["ok"] and p.gold==wallet,"duplicate pickup cannot pay twice")
	var weapon: String=drops[2].id
	before=JSON.stringify(full.profile)
	check(not Loot.claim(full.profile,run,weapon,"boss_room",Vector2(300,200))["ok"] and JSON.stringify(full.profile)==before and not run.loot.drops[weapon].claimed,"full bag retains unclaimed ground item")
	check(Loot.pending(run,"other").is_empty() and Loot.pending(run,"boss_room").size()==2,"room revisit retains only unclaimed drops")
	var stale:=event.duplicate();stale.run_id="expired"
	check(not Loot.generate(run,stale),"stale run event rejected")
	var crowded=Session.new()
	Items.give(crowded.profile,"potion",Items.STACK_LIMIT*48-4)
	before=JSON.stringify(crowded.profile)
	check(not Items.give(crowded.profile,"potion",10)["ok"] and JSON.stringify(crowded.profile)==before,"partial stack fill rolls back when remaining reward needs an unavailable cell")
	check(not s.command("numbers.gear_give",{"id":"potion"})["ok"],"equipment command cannot mint fake gear serial for a consumable")
	check(Loot.claim(p,run,drops[1].id,"boss_room",Vector2.ZERO,true)["ok"],"cleared-room collection explicitly bypasses distance")
	var invalid_run:=run.duplicate(true);invalid_run.loot.drops[weapon].claimed="yes"
	check(not Loot.valid(invalid_run) and Loot.valid(JSON.parse_string(JSON.stringify(run))),"drop receipt validation rejects malformed save and accepts JSON")
	print("[ITEM_TEST] COMPLETE checks=%d failures=%d" % [checks,failures]);quit(1 if failures else 0)
