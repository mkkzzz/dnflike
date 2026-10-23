extends SceneTree
const Session=preload("res://flow/session.gd")
const Services=preload("res://items/services.gd")
const Upgrades=preload("res://items/upgrades.gd")
const Items=preload("res://items/inventory.gd")
var checks:=0
var failures:=0
var serial:=0
func check(ok: bool, label: String) -> void:
	checks+=1
	if not ok:failures+=1
	print("[UPGRADE_TEST] %s %s" % ["PASS" if ok else "FAIL",label])
func payload(p: Dictionary, kind: String, args: Dictionary) -> Dictionary:
	var data:=args.duplicate(true);serial+=1
	data["signature"]=Services.quote(p,kind,data).get("signature","")
	data["transaction"]="upgrade_test:%d" % serial
	return data
func execute(p: Dictionary, kind: String, args: Dictionary) -> Dictionary:
	return Services.command(p,kind,payload(p,kind,args))
func seed_for(success: bool, chance: int) -> int:
	for seed in range(1,1000):
		if ((seed*48271)%Upgrades.MODULUS%100<chance)==success:return seed
	return 1
func _initialize() -> void:
	var s=Session.new();var p: Dictionary=s.profile;p.gold=20000
	Items.give(p,"scrap_iron",200)
	var uid: String=p.equipment.weapon
	var before:=JSON.stringify(p)
	var q:=Services.quote(p,"services.reinforce",{"uid":uid})
	check(q.ok and q.from==0 and q.to==1 and q.chance==100 and q.price==20 and q.materials.scrap_iron==1,"quote contains configured bill and success/failure levels")
	check(JSON.stringify(p)==before,"opening quote never consumes or rolls RNG")
	var request:=payload(p,"services.reinforce",{"uid":uid})
	var attack: float=s.stats().numbers.physical_attack
	var response:=Services.command(p,"services.reinforce",request)
	check(response.ok and p.gear[uid].reinforce==1 and p.gold==19980 and p.inventory.scrap_iron==199,"reinforcement commits exact UID, gold and material bill")
	check(p.services.upgrades.attempts==1 and response.message.begins_with("强化成功"),"success returns truthful result and advances persisted attempt once")
	check(s.stats().numbers.physical_attack==attack+2,"reinforcement affects actual combat stats")
	before=JSON.stringify(p)
	check(not Services.command(p,"services.reinforce",request).ok and JSON.stringify(p)==before,"duplicate transaction cannot charge or roll twice")
	request=payload(p,"services.reinforce",{"uid":uid});p.gear[uid].quality=87
	before=JSON.stringify(p)
	check(not Services.command(p,"services.reinforce",request).ok and JSON.stringify(p)==before,"changed target invalidates old confirmation")
	request=payload(p,"services.reinforce",{"uid":uid});p.services.upgrades.seed=19
	before=JSON.stringify(p)
	check(not Services.command(p,"services.reinforce",request).ok and JSON.stringify(p)==before,"changed RNG state invalidates pending roll")
	p.gear[uid].reinforce=3;p.services.upgrades.seed=seed_for(false,85)
	var amount: int=p.inventory.scrap_iron;var gold: int=p.gold
	response=execute(p,"services.reinforce",{"uid":uid})
	check(response.ok and p.gear[uid].reinforce==3 and response.message.begins_with("强化失败"),"failed roll is committed outcome and retains configured level")
	check(p.gold==gold-100 and p.inventory.scrap_iron==amount-4 and p.services.upgrades.attempts==2,"failed roll consumes quoted bill and advances once")
	var loaded=Session.new()
	check(loaded.restore(JSON.parse_string(JSON.stringify(s.serialize()))),"upgrade save accepts JSON roundtrip")
	var left:=p.duplicate(true);var right: Dictionary=loaded.profile
	var a:=execute(left,"services.reinforce",{"uid":uid});var b:=execute(right,"services.reinforce",{"uid":uid})
	check(a.ok and b.ok and left.gear==right.gear and left.services.upgrades==right.services.upgrades,"reload preserves next roll without rerolling")
	p.services.upgrades.seed=seed_for(true,85)
	check(execute(p,"services.reinforce",{"uid":uid}).ok and p.gear[uid].reinforce==4,"successful probabilistic step advances exactly one level")
	p.gear[uid].reinforce=10
	check(not Services.quote(p,"services.reinforce",{"uid":uid}).ok,"configured enhancement cap enforced")
	p.gear[uid].reinforce=0;p.gear[uid].locked=true
	check(not Services.quote(p,"services.reinforce",{"uid":uid}).ok and not Services.quote(p,"services.enchant",{"uid":uid,"recipe":"strength"}).ok,"locked target cannot upgrade")
	p.gear[uid].locked=false;p.gear[uid].durability=0
	check(not Services.quote(p,"services.reinforce",{"uid":uid}).ok,"broken equipment must be repaired before upgrade")
	p.gear[uid].durability=40
	var coat: String=s.command("numbers.gear_give",{"id":"training_coat"}).uid
	var necklace: String=s.command("numbers.gear_give",{"id":"training_necklace"}).uid
	s.command("numbers.gear_equip",{"uid":coat});s.command("numbers.gear_equip",{"uid":necklace})
	var defense: float=s.stats().numbers.physical_defense
	check(execute(p,"services.reinforce",{"uid":coat}).ok and s.stats().numbers.physical_defense==defense+3,"equipped armor enhancement contributes defense")
	var magical: float=s.stats().numbers.magical_defense
	check(execute(p,"services.reinforce",{"uid":necklace}).ok and s.stats().numbers.magical_defense==magical+3,"accessory enhancement contributes magic defense")
	p.gear[coat].durability=0
	check(not Services.Numbers.Equipment.modifiers(p,Services.Numbers.config()).any(func(mod):return mod.get("source")=="装备强化" and mod.get("stat")=="physical_defense"),"broken armor disables enhancement too")
	p.gear[coat].durability=40
	check(not Services.quote(p,"services.enchant",{"uid":necklace,"recipe":"strength"}).ok,"enchant slot restriction enforced")
	var strength: float=s.stats().numbers.strength
	amount=p.inventory.scrap_iron;gold=p.gold
	check(execute(p,"services.enchant",{"uid":uid,"recipe":"strength"}).ok and s.stats().numbers.strength==strength+3,"enchantment applies one configured stat modifier")
	check(p.inventory.scrap_iron==amount-3 and p.gold==gold-80,"enchantment consumes exact configured cost")
	check(not Services.quote(p,"services.enchant",{"uid":uid,"recipe":"strength"}).ok,"identical enchant cannot charge again")
	q=Services.quote(p,"services.enchant",{"uid":uid,"recipe":"intelligence"})
	check(q.ok and q.after.get("strength",0)==0 and q.after.intelligence==3,"replacement quote previews removal of previous bonus")
	check(execute(p,"services.enchant",{"uid":uid,"recipe":"intelligence"}).ok and p.gear[uid].enchants.size()==1 and s.stats().numbers.strength==strength,"replacement never accumulates obsolete enchant bonus")
	amount=p.inventory.scrap_iron;gold=p.gold
	check(execute(p,"services.enchant_clear",{"uid":uid}).ok and p.gear[uid].enchants.is_empty() and p.gold==gold and p.inventory.scrap_iron==amount,"clear enchant removes modifier without hidden cost")
	check(not Services.quote(p,"services.enchant_clear",{"uid":uid}).ok,"empty enchant cannot be cleared twice")
	var poor=Session.new();var f: Dictionary=poor.profile;f.gold=0;Items.give(f,"scrap_iron",2)
	var weapon: String=f.equipment.weapon;request=payload(f,"services.reinforce",{"uid":weapon});before=JSON.stringify(f)
	check(not Services.command(f,"services.reinforce",request).ok and JSON.stringify(f)==before,"insufficient coins leaves exact state and RNG unchanged")
	f.gold=1000;f.gear[weapon].reinforce=2;before=JSON.stringify(f)
	check(not execute(f,"services.reinforce",{"uid":weapon}).ok and JSON.stringify(f)==before,"insufficient total materials consumes nothing")
	f.gear[weapon].reinforce=0
	var material: String=f.item_state.bags.material[0];f.item_state.stacks[material].locked=true
	before=JSON.stringify(f)
	check(not execute(f,"services.reinforce",{"uid":weapon}).ok and JSON.stringify(f)==before,"locked materials are excluded")
	f.item_state.stacks[material].locked=false
	f.item_state.bags.material[0]="";f.item_state.storage[0]=material;Items.sync(f);before=JSON.stringify(f)
	check(not execute(f,"services.reinforce",{"uid":weapon}).ok and JSON.stringify(f)==before,"warehouse materials are excluded")
	f.item_state.storage[0]="";f.item_state.overflow.append(material);Items.sync(f);before=JSON.stringify(f)
	check(not execute(f,"services.reinforce",{"uid":weapon}).ok and JSON.stringify(f)==before,"pending recovery materials are excluded")
	var split=Session.new();split.profile.gold=1000;Items.give(split.profile,"scrap_iron",4)
	var first: String=split.profile.item_state.bags.material[0]
	split.command("items.split",{"uid":first,"count":2})
	split.profile.gear[split.profile.equipment.weapon].reinforce=2
	check(execute(split.profile,"services.reinforce",{"uid":split.profile.equipment.weapon}).ok and split.profile.inventory.scrap_iron==1 and Items.valid(split.profile),"one bill spans multiple material stacks and removes exhausted entities")
	var packed: String=poor.command("numbers.gear_give",{"id":"forest_sword"}).uid
	var cell:=Items.locate(f,packed);cell[0][cell[1]]="";f.item_state.storage[1]=packed;Items.sync(f)
	check(not Services.quote(f,"services.reinforce",{"uid":packed}).ok,"stored target cannot be upgraded")
	cell=Items.locate(p,coat)
	# A live instance sold to buyback is neither carried nor equipped.
	s.command("numbers.gear_unequip",{"slot":"coat"})
	execute(p,"services.sell",{"uid":coat})
	check(not Services.quote(p,"services.reinforce",{"uid":coat}).ok,"buyback target cannot be upgraded")
	var old:=s.serialize();old.profile.services.erase("upgrades")
	var migrated=Session.new()
	check(migrated.restore(old) and migrated.profile.services.has("upgrades"),"existing service save migrates RNG state")
	var bad:=s.serialize();bad.profile.services.upgrades.seed=0
	check(not Session.new().restore(bad),"invalid RNG seed rejected")
	bad=s.serialize();bad.profile.services.upgrades.attempts=-1
	check(not Session.new().restore(bad),"invalid attempt counter rejected")
	bad=s.serialize();bad.profile.services.upgrades=[]
	check(not Session.new().restore(bad),"malformed upgrade state rejected safely")
	check(not Services.quote(p,"services.enchant",{"uid":uid,"recipe":12}).ok,"malformed recipe rejected without script exception")
	request=payload(p,"services.reinforce",{"uid":uid})
	check(not s.service_command("services.reinforce",request,{"npc":"linus","nearby":true}).ok,"NPC without role cannot upgrade")
	check(not s.service_command("services.reinforce",request,{"npc":"kiri","nearby":false}).ok,"remote NPC cannot upgrade")
	s.state="battle"
	check(not s.service_command("services.reinforce",request,{"npc":"kiri","nearby":true}).ok,"battle cannot use town upgrades")
	s.state="town"
	check(s.service_command("services.reinforce",request,{"npc":"kiri","nearby":true}).ok,"Kiri role accepts legitimate enhancement")
	check(s.service_command("services.enchant",payload(p,"services.enchant",{"uid":uid,"recipe":"strength"}),{"npc":"sinda","nearby":true}).ok,"Sinda role accepts legitimate enchantment")
	check(Items.valid(p) and Services.valid(p) and Services.Numbers.valid(p),"final ownership, numeric and service contracts remain valid")
	print("[UPGRADE_TEST] COMPLETE checks=%d failures=%d" % [checks,failures]);quit(1 if failures else 0)
