extends SceneTree
const Session=preload("res://flow/session.gd")
const Drops=preload("res://quests/drops.gd")
const Catalog=preload("res://quests/catalog.gd")
var checks:=0
var failures:=0

func check(value: bool, label: String) -> void:
	checks+=1
	if value:print("[POISON_RULES] PASS "+label)
	else:failures+=1;push_error("[POISON_RULES] FAIL "+label)

func fixture():
	var s=Session.new();s.profile.level=10
	for id: String in s.quests.catalog.definitions:
		if id in ["gran.poison_scent","legacy.trial"]:continue
		var entry: Dictionary=s.quests.new_entry(s.quests.catalog.definitions[id]);entry.state="completed"
		s.profile.quest_state.entries[id]=entry
		if s.quests.catalog.definitions[id].get("lifecycle","once") in ["repeat","daily"]:
			if not s.profile.quest_state.has("cycles"):s.profile.quest_state["cycles"]={}
			entry["cycle"]=1
			s.profile.quest_state["cycles"][id]={"next":2,"completions":1,"last_day":0}
			s.profile.quest_state["calendar_day"]=0
			s.profile.quest_state.transactions["quest:"+id+":cycle:1"]=true
		else:
			s.profile.quest_state.transactions[s.Quests.transaction_id(id)]=true
	return s

func death(s, entity:=1, mob:="monster/lugaru/penril.mob") -> Dictionary:
	return {"type":"combat.monster_defeated","run_id":s.run.id,"event_id":"poison:"+str(entity),"entity_id":entity,"room_id":"poison:boss","position":Vector2(100,200),"monster_id":mob,"boss":true}

func begin(s) -> void:
	s.quest_command("quest.accept",{"id":"gran.poison_scent"},{"npc":"gsd","nearby":true})
	s.command("flow.depart",{"dungeon":"sunderland_poison"})

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var s=fixture()
	check(s.quests.catalog.errors.is_empty(),"all definitions including drop rules validate")
	check(s.quests.catalog.definitions["gran.poison_scent"].description.contains("毒药袋"),"baseline seeking objective has matching Simplified Chinese body")
	check(s.CATALOG.ITEMS.original_4169.kind=="quest" and not s.CATALOG.ITEMS.original_4169.purchasable,"source quest material uses quest bag and cannot be bought")
	var before:=JSON.stringify(s.serialize())
	check(not s.command("items.buy",{"id":"original_4169"}).ok and before==JSON.stringify(s.serialize()),"free-price hidden purchase cannot mint quest items")
	s.command("flow.depart",{"dungeon":"sunderland_poison"})
	s.combat_event(death(s))
	check(s.Loot.pending(s.run,"poison:boss").is_empty(),"killing source boss without accepting task cannot generate its quest item")
	s=fixture();begin(s)
	var event:=death(s)
	var eligible_rules: Array=Drops.entries(s.profile,s.run,event,s.quests.catalog.definitions)
	check(eligible_rules.size()==1,"accepted exact source boss and dungeon produce one eligible rule "+JSON.stringify(eligible_rules))
	var wrong:=event.duplicate();wrong.run_id="stale"
	check(Drops.entries(s.profile,s.run,wrong,s.quests.catalog.definitions).is_empty(),"stale run cannot generate quest loot")
	wrong=event.duplicate();wrong.monster_id="monster/goblin/kinol.mob"
	check(Drops.entries(s.profile,s.run,wrong,s.quests.catalog.definitions).is_empty(),"Kaino cannot pay the poison boss item")
	var route: Dictionary=s.run.duplicate(true);route.dungeon="sunderland"
	check(Drops.entries(s.profile,route,event,s.quests.catalog.definitions).is_empty(),"correct boss ID in a wrong dungeon does not qualify")
	route=s.run.duplicate(true);route.difficulty="unsupported"
	check(Drops.entries(s.profile,route,event,s.quests.catalog.definitions).is_empty(),"unsupported difficulty cannot receive a quest item")
	var replay=fixture();begin(replay)
	s.combat_event(event);replay.combat_event(death(replay))
	check(s.run.loot==replay.run.loot,"identical run and death produce identical persisted quest drops")
	var pending: Array=s.Loot.pending(s.run,"poison:boss")
	check(pending.size()==1 and pending[0].item=="original_4169" and s.Inventory.stock(s.profile,"original_4169")==0,"death creates a ground record without auto-granting or completing collection")
	before=JSON.stringify(s.serialize());s.combat_event(event)
	check(before==JSON.stringify(s.serialize()),"repeated death cannot reroll loot or duplicate XP")
	s.combat_event(death(s,2))
	check(s.Loot.pending(s.run,"poison:boss").size()==1,"pending ground item reserves the source quest cap")
	var drop: Dictionary=pending[0]
	before=JSON.stringify(s.serialize())
	check(not s.Loot.claim(s.profile,s.run,drop.id,"poison:boss",Vector2.ZERO).ok and before==JSON.stringify(s.serialize()),"out-of-range pickup is harmless")
	check(s.Loot.claim(s.profile,s.run,drop.id,"poison:boss",Vector2(100,200)).ok,"actual pickup moves ground ownership into the quest bag")
	check(s.quests.status(s.profile,"gran.poison_scent")=="ready","collection becomes ready only after pickup")
	check(Drops.entries(s.profile,s.run,death(s,3),s.quests.catalog.definitions).is_empty(),"owned quest item also reserves its cap")
	var uid: String=s.profile.item_state.bags.quest[0]
	s.Inventory.command(s.profile,"items.lock",{"uid":uid})
	check(s.quests.status(s.profile,"gran.poison_scent")=="active" and Drops.entries(s.profile,s.run,death(s,3),s.quests.catalog.definitions).is_empty(),"locked quest item cannot be handed in and does not allow duplicate drops")
	s.Inventory.command(s.profile,"items.lock",{"uid":uid})
	check(not s.Services.quote(s.profile,"services.sell",{"uid":uid,"count":1}).ok,"quest item cannot be sold away through services")
	s.finish_run(true,{})
	var loaded=Session.new()
	check(loaded.restore(JSON.parse_string(JSON.stringify(s.serialize()))) and loaded.Inventory.stock(loaded.profile,"original_4169")==1,"result reload preserves quest material and claimed receipt together")
	s.command("flow.return")
	s.Inventory.command(s.profile,"items.deposit",{"uid":uid})
	check(s.quests.status(s.profile,"gran.poison_scent")=="active","stored item is excluded from hand-in availability")
	s.Inventory.command(s.profile,"items.withdraw",{"uid":uid})
	check(s.quest_command("quest.claim",{"id":"gran.poison_scent"},{"npc":"gsd","nearby":true}).ok,"correct NPC hand-in awards source necklace")
	check(s.Inventory.stock(s.profile,"original_4169")==0 and s.Inventory.stock(s.profile,"original_20006")==1 and s.Inventory.valid(s.profile),"hand-in consumes actual quest stack and grants one equipment instance")
	before=JSON.stringify(s.serialize())
	check(not s.quest_command("quest.claim",{"id":"gran.poison_scent"},{"npc":"gsd","nearby":true}).ok and before==JSON.stringify(s.serialize()),"completed quest cannot consume or pay twice")
	var cfg: Dictionary=s.quests.catalog.config.duplicate(true)
	for q: Dictionary in cfg.quests:
		if q.id=="gran.poison_scent":q.drops[0].chance=101
	check(not Catalog.new(cfg).errors.is_empty(),"malformed drop probability fails definition validation")
	print("[POISON_RULES] COMPLETE checks=%d failures=%d" % [checks,failures]);quit(1 if failures else 0)
