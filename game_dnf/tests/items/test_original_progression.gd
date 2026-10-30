extends SceneTree
const Session=preload("res://flow/session.gd")
const Items=preload("res://items/inventory.gd")
const Consumables=preload("res://items/consumables.gd")
const Restore=preload("res://combat/item_restoration.gd")
var checks:=0
var failures:=0

class EffectActor:
	extends RefCounted
	var player: Dictionary={"hp":100.0,"mp":0.0}
	var max_hp:=500.0
	var max_mp:=200.0
	var paused:=false
	var finished:=false
	var item_restorations: Array=[]

func check(value: bool, label: String) -> void:
	checks+=1
	if not value:failures+=1;push_error("[ORIGINAL_DATA] FAIL "+label)
	else:print("[ORIGINAL_DATA] PASS "+label)

func view(s, time_ms:=0.0) -> Dictionary:
	return {"run_id":s.run.id,"hp":100.0,"hp_max":500.0,"mp":0.0,"mp_max":200.0,"time_ms":time_ms,"paused":false,"finished":false}

func near(npc: String) -> Dictionary:
	return {"nearby":true,"npc":npc}

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var s=Session.new()
	check(s.CATALOG.ITEMS.size()==21+preload("res://content/api/native_catalog.gd").runtime()["items"].size() and s.CATALOG.ITEMS.original_1106.name=="诺顿的新手HP药剂","original Simplified Chinese definitions load beside compatible legacy IDs")
	check(Items.give(s.profile,"original_1106",1001).ok,"original source stack accepts more than the legacy limit")
	var bag: Array=s.profile.item_state.bags.consumable
	var stacks: Array=bag.filter(func(uid):return uid!="" and Items.definition(s.profile,uid)=="original_1106")
	check(stacks.size()==2 and Items.count(s.profile,stacks[0])==1000 and Items.count(s.profile,stacks[1])==1,"per-item source stack cap splits exactly 1000 plus one")
	check(Items.valid(s.profile),"source-sized stacks validate without raising the old potion cap")
	check(s.CATALOG.stack_limit("potion")==99,"legacy stack maximum remains 99")
	var copy=Session.new()
	check(copy.restore(JSON.parse_string(JSON.stringify(s.serialize()))) and Items.stock(copy.profile,"original_1106")==1001,"source items and stack limits survive save restoration")
	check(Items.command(copy.profile,"items.split",{"uid":stacks[0],"count":25}).ok and Items.command(copy.profile,"items.sort",{}).ok and Items.stock(copy.profile,"original_1106")==1001,"split and sort preserve original-item ownership")
	Items.give(s.profile,"original_1112",2)
	s.command("flow.depart")
	var hp:=s.use_consumable("original_1106",view(s),"source_hp")
	check(hp.ok and hp.effect.kind=="restore" and hp.effect.hp==70 and hp.effect.duration_ms==1000,"original HP tuple compiles into a timed public request")
	var mp:=s.use_consumable("original_1112",view(s),"source_mp")
	check(mp.ok and mp.effect.mp==65,"original MP medicine works independently of the HP group")
	var before:=JSON.stringify(s.serialize())
	check(not s.use_consumable("original_1106",view(s),"second_hp").ok and before==JSON.stringify(s.serialize()),"original HP cooldown refuses duplicate resource consumption")
	Items.give(s.profile,"original_1107",1)
	check(not s.use_consumable("original_1107",view(s),"other_hp").ok,"different HP medicine shares its source cooldown group")
	var actor=EffectActor.new()
	check(Restore.apply(actor,hp.effect) and Restore.apply(actor,mp.effect),"new HP and MP requests both apply to the combat receiver")
	Restore.step(actor,250)
	check(is_equal_approx(actor.player.hp,117.5) and is_equal_approx(actor.player.mp,16.25),"quarter-duration recovery grants exactly a quarter of both resources")
	actor.paused=true;Restore.step(actor,500)
	check(is_equal_approx(actor.player.hp,117.5),"paused simulation never advances timed recovery")
	actor.paused=false;Restore.step(actor,750)
	check(is_equal_approx(actor.player.hp,170) and is_equal_approx(actor.player.mp,65) and actor.item_restorations.is_empty(),"exact deadline delivers each requested total once and clears both schedules")
	actor.player.hp=499;actor.player.mp=199
	check(Restore.apply(actor,{"kind":"restore","hp":50,"mp":50,"duration_ms":0}) and actor.player.hp==500 and actor.player.mp==200,"instant mixed restoration clips both resources to their maxima")
	check(not Restore.can_apply(actor,hp.effect),"full matching resource refuses a paid request")
	actor.player.hp=100;Restore.apply(actor,hp.effect);actor.player.hp=0;Restore.step(actor,1000)
	check(actor.item_restorations.is_empty() and actor.player.hp==0,"death cancels recovery and cannot revive the actor")
	check(not Restore.valid({"kind":"restore","hp":NAN,"mp":0,"duration_ms":0}),"nonfinite recovery amounts are rejected")
	var gear=Session.new();gear.profile.level=6
	Items.give(gear.profile,"original_10580",1)
	var coat: String=gear.profile.item_state.bags.weapon[0]
	check(gear.profile.gear[coat].durability_max==28,"new equipment instances use original durability")
	check(Items.equip(gear.profile,coat).ok and gear.profile.equipment.coat==coat,"source armor equips in the actual coat slot")
	check(gear.Numbers.gear_detail(gear.profile,coat).physical_defense==48,"source equipment stat range is evaluated without legacy percentage distortion")
	Items.give(gear.profile,"original_24116",1)
	var ring: String=gear.profile.item_state.bags.weapon.filter(func(uid):return uid!="" and Items.definition(gear.profile,uid)=="original_24116")[0]
	Items.equip(gear.profile,ring)
	check(gear.Numbers.gear_detail(gear.profile,ring).light_resist==5,"source ring's lightning resistance affects actual attributes")
	gear.profile.gear[coat].durability-=1
	check(gear.Services.quote(gear.profile,"services.repair",{"uid":coat,"all":false}).ok,"source gear has complete service rules")
	var q=Session.new();q.profile.level=6
	var predecessor: Dictionary=q.quests.new_entry(q.quests.catalog.definitions["gran.meet_shylock"])
	predecessor.state="completed";q.profile.quest_state.entries["gran.meet_shylock"]=predecessor
	q.profile.quest_state.transactions[q.quests.transaction_id("gran.meet_shylock")]=true
	check(q.quest_command("quest.accept",{"id":"gran.kaino_legend"},near("shylock")).ok,"108 opens at Shylock after the original predecessor")
	q.quests.ingest(q.profile,{"type":"combat.monster_defeated","event_id":"wrong_scope","monster_id":"monster/goblin/kinol.mob","dungeon":"lorien"})
	check(q.quests.status(q.profile,"gran.kaino_legend")=="active","Kaino killed in another dungeon cannot satisfy 108")
	q.quests.ingest(q.profile,{"type":"combat.monster_defeated","event_id":"kaino","monster_id":"monster/goblin/kinol.mob","dungeon":"sunderland"})
	check(q.quest_command("quest.claim",{"id":"gran.kaino_legend"},near("shylock")).ok,"108 commits source fixed and class-conditioned rewards")
	check(Items.stock(q.profile,"original_24116")==1 and Items.stock(q.profile,"original_27800")==1 and Items.stock(q.profile,"original_1107")==5 and Items.stock(q.profile,"original_1113")==5,"actual swordman gets the ring, saber and both medicine stacks exactly once")
	check(q.quest_command("quest.accept",{"id":"gran.goblin_mutation"},near("shylock")).ok and q.quests.status(q.profile,"gran.goblin_mutation")=="active","4302 requires a new Kaino defeat and never inherits the previous kill")
	before=JSON.stringify(q.serialize())
	check(not q.quest_command("quest.claim",{"id":"gran.kaino_legend"},near("shylock")).ok and JSON.stringify(q.serialize())==before,"source conditional rewards cannot replay after hand-in")
	var loaded=Session.new()
	check(loaded.restore(JSON.parse_string(JSON.stringify(q.serialize()))) and loaded.quests.status(loaded.profile,"gran.goblin_mutation")=="active","new task and original equipment coexist in a restorable save")
	print("[ORIGINAL_DATA] COMPLETE checks=%d failures=%d" % [checks,failures])
	quit(1 if failures else 0)
