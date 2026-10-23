extends SceneTree
const Session=preload("res://flow/session.gd")
const Services=preload("res://items/services.gd")
const Items=preload("res://items/inventory.gd")
var checks:=0
var failures:=0
var sequence:=0
func check(ok: bool, label: String) -> void:
	checks+=1
	if not ok:failures+=1;print("[SERVICE_TEST] FAIL "+label)
func payload(p: Dictionary, kind: String, data: Dictionary) -> Dictionary:
	sequence+=1
	var copy:=data.duplicate(true)
	copy["transaction"]="test:%d" % sequence
	copy["signature"]=Services.quote(p,kind,copy).get("signature","")
	return copy
func _initialize() -> void:
	var s=Session.new();var p: Dictionary=s.profile
	check(Services.valid(p) and Items.valid(p),"new profile has valid service and ownership ledgers")
	var gear: String=s.command("numbers.gear_give",{"id":"forest_sword","quality":91}).uid
	p.gear[gear].reinforce=7;p.gear[gear].enchants=[{"stat":"strength","op":"add","value":3.0}];p.gear[gear].durability=11
	var original: Dictionary=p.gear[gear].duplicate(true)
	var sell:=payload(p,"services.sell",{"uid":gear})
	check(s.service_command("services.sell",sell,{"npc":"linus","nearby":true}).ok,"sell at actual configured vendor")
	check(p.gold==360 and p.services.buyback[0].uid==gear and p.gear[gear]==original and p.inventory.forest_sword==0,"sale transfers exact instance out of carried counts")
	var before:=JSON.stringify(p)
	check(not Services.command(p,"services.sell",sell).ok and JSON.stringify(p)==before,"repeated transaction cannot sell again")
	var loaded=Session.new()
	check(loaded.restore(JSON.parse_string(JSON.stringify(s.serialize()))) and loaded.profile==p,"buyback ownership and roll survive JSON roundtrip")
	var buy:=payload(p,"services.buyback",{"sale":"sale_1"})
	check(Services.command(p,"services.buyback",buy).ok,"buyback transaction succeeds")
	check(gear in p.item_state.bags.weapon and p.services.buyback.is_empty() and p.gear[gear]==original and p.gold==300,"buyback restores same identity and exact sale price")
	Items.command(p,"items.lock",{"uid":gear})
	check(not Services.quote(p,"services.sell",{"uid":gear}).ok and not Services.quote(p,"services.disassemble",{"uid":gear}).ok,"locked gear cannot sell or disassemble")
	Items.command(p,"items.lock",{"uid":gear});s.command("items.equip",{"uid":gear})
	check(not Services.quote(p,"services.sell",{"uid":gear}).ok,"equipped gear cannot sell")
	var quote:=Services.quote(p,"services.repair",{"uid":gear})
	check(quote.price==87 and quote.targets==[gear],"repair quote charges missing durability only")
	var repair:=payload(p,"services.repair",{"uid":gear})
	p.gold=86;before=JSON.stringify(p)
	check(not Services.command(p,"services.repair",repair).ok and JSON.stringify(p)==before,"insufficient repair gold changes nothing")
	p.gold=1000
	check(Services.command(p,"services.repair",repair).ok and p.gear[gear].durability==40 and p.gold==913,"repair restores full durability at quoted cost")
	check(not Services.quote(p,"services.repair",{"uid":gear}).ok,"fully repaired gear cannot charge twice")
	p.gear[gear].durability=0
	check(s.stats().numbers.physical_attack==20,"zero durability disables equipment stats including reinforcement and enchant")
	check(Services.command(p,"services.repair",payload(p,"services.repair",{"all":true})).ok and s.stats().numbers.physical_attack>20,"repair reactivates actual numeric equipment")
	s.command("items.unequip")
	var decompose:=payload(p,"services.disassemble",{"uid":gear})
	check(Services.command(p,"services.disassemble",decompose).ok and not p.gear.has(gear) and p.inventory.scrap_iron==5 and Items.valid(p),"disassembly consumes one exact gear and creates configured material stacks")
	check(not Services.command(p,"services.disassemble",decompose).ok and p.inventory.scrap_iron==5,"duplicate disassembly cannot produce more materials")
	var potion: String=p.item_state.bags.consumable[0]
	check(Services.command(p,"services.sell",payload(p,"services.sell",{"uid":potion,"count":2})).ok and p.inventory.potion==1,"partial stack sale removes only selected amount")
	var sold: Dictionary=p.services.buyback.back()
	check(Items.count(p,sold.uid)==2 and sold.uid!=potion and Items.valid(p),"partial sale owns a distinct buyback stack without duplication")
	check(Services.command(p,"services.buyback",payload(p,"services.buyback",{"sale":sold.id})).ok and p.inventory.potion==3,"partial stack buyback restores amount")
	var sword: String=s.command("numbers.gear_give",{"id":"forest_sword"}).uid
	var stale:=payload(p,"services.sell",{"uid":sword});p.gear[sword].quality=80
	check(not Services.command(p,"services.sell",stale).ok and p.gear.has(sword),"stale confirmation refuses changed instance")
	var full=Session.new();var f: Dictionary=full.profile
	var uid: String=full.command("numbers.gear_give",{"id":"forest_sword"}).uid
	Services.command(f,"services.sell",payload(f,"services.sell",{"uid":uid}))
	Items.give(f,"forest_sword",48);before=JSON.stringify(f)
	check(not Services.command(f,"services.buyback",payload(f,"services.buyback",{"sale":"sale_1"})).ok and JSON.stringify(f)==before,"full bag buyback keeps coins and receipt")
	Items.give(f,"scrap_iron",99*48)
	var to_break: String=f.item_state.bags.weapon[0];before=JSON.stringify(f)
	check(not Services.command(f,"services.disassemble",payload(f,"services.disassemble",{"uid":to_break})).ok and JSON.stringify(f)==before,"full material bag rolls back original gear consumption")
	var cap=Session.new()
	for i in 21:
		var entry: String=cap.command("numbers.gear_give",{"id":"iron_sword"}).uid
		Services.command(cap.profile,"services.sell",payload(cap.profile,"services.sell",{"uid":entry}))
	check(cap.profile.services.buyback.size()==20 and not cap.profile.gear.has("gear_2") and Items.valid(cap.profile),"buyback limit expires oldest owner without orphaning inventory")
	var wear=Session.new();wear.command("flow.depart")
	var worn: String=wear.profile.equipment.weapon
	for i in 20:Services.wear(wear.profile,wear.run,{"type":"combat.damage","run_id":wear.run.id,"event_id":i,"victim":"monster","amount":1})
	check(wear.profile.gear[worn].durability==39,"landed hits wear the actual equipped weapon at configured threshold")
	Services.wear(wear.profile,wear.run,{"type":"combat.damage","run_id":wear.run.id,"event_id":19,"victim":"monster","amount":1})
	check(wear.profile.gear[worn].durability==39 and wear.profile.gear[worn].wear_progress==0,"duplicate combat facts cannot wear twice")
	Services.wear(wear.profile,wear.run,{"type":"combat.damage","run_id":"expired","event_id":21,"victim":"monster","amount":99})
	check(wear.profile.gear[worn].wear_progress==0,"stale run cannot wear current equipment")
	wear.combat_event({"type":"combat.player_defeated","run_id":wear.run.id,"stats":{}})
	check(wear.profile.gear[worn].durability==36,"real defeat applies configured penalty once")
	wear.combat_event({"type":"combat.player_defeated","run_id":wear.run.id,"stats":{}})
	check(wear.profile.gear[worn].durability==36,"duplicate defeat is harmless")
	var old=Session.new().serialize();old.schema="dnf_loop_save/3";old.profile.erase("services");old.profile.inventory.erase("scrap_iron")
	for instance: Dictionary in old.profile.gear.values():
		for key in ["durability","durability_max","wear_progress"]:instance.erase(key)
	check(loaded.restore(JSON.parse_string(JSON.stringify(old))) and loaded.profile.gear.gear_1.durability==40,"v3 migration adds full durability and newly registered zero-count material")
	var invalid=s.serialize();invalid.profile.gear[sword].durability=-1
	check(not loaded.restore(invalid),"invalid durability is rejected")
	invalid=cap.serialize();invalid.profile.services.buyback[0].uid="ghost"
	var missing:=cap.serialize();missing.profile.erase("item_state")
	var malformed:=cap.serialize();malformed.profile.item_state=[]
	check(not loaded.restore(invalid) and not loaded.restore(missing) and not loaded.restore(malformed),"unknown buyback entity or missing ownership table is rejected without crashing")
	check(not s.service_command("services.sell",payload(p,"services.sell",{"uid":sword}),{"npc":"seria","nearby":true}).ok,"NPC service permissions enforced below GUI")
	print("[SERVICE_TEST] COMPLETE checks=%d failures=%d" % [checks,failures]);quit(1 if failures else 0)
