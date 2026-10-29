extends SceneTree
const Session=preload("res://flow/session.gd")
const Catalog=preload("res://quests/catalog.gd")
var checks:=0
var failures:=0

func check(value: bool, label: String) -> void:
	checks+=1
	if value:print("[TEACHING_RULES] PASS "+label)
	else:failures+=1;push_error("[TEACHING_RULES] FAIL "+label)

func npc() -> Dictionary:return {"nearby":true,"npc":"seria"}

func complete(s,id: String) -> void:
	var entry: Dictionary=s.quests.new_entry(s.quests.catalog.definitions[id]);entry.state="completed"
	s.profile.quest_state.entries[id]=entry;s.profile.quest_state.transactions[s.Quests.transaction_id(id)]=true

func _initialize() -> void:call_deferred("run")

func run() -> void:
	var s=Session.new();s.profile.level=30
	check(s.quests.catalog.errors.is_empty(),"all source eligibility and teaching objectives validate")
	check(s.quest_command("quest.accept",{"id":"tutorial.skill_intro"},npc()).ok,"level-five source teaching accepts from Seria")
	s.quests.ingest(s.profile,{"type":"npc.met","event_id":"intro:seria","npc":"seria"})
	check(s.quest_command("quest.claim",{"id":"tutorial.skill_intro"},npc()).ok,"source NPC conversation hands in normally")
	check(s.Inventory.stock(s.profile,"original_1062")==1 and s.Inventory.stock(s.profile,"original_1065")==1,"intro delivers original bilberry and magic flower")
	check(s.quests.status(s.profile,"tutorial.learn_skill")=="available","1012 hand-in unlocks original 211")
	check(s.command("numbers.skill",{"id":"upper","delta":1}).ok,"normal skill purchase before acceptance still works")
	check(s.quest_command("quest.accept",{"id":"tutorial.learn_skill"},npc()).ok and s.quests.status(s.profile,"tutorial.learn_skill")=="active","old learning is not retroactively counted by the new task")
	var serial:=int(s.profile.quest_state.next_skill_event)
	s.command("numbers.skill_grant",{"id":"upper","level":3})
	check(s.quests.status(s.profile,"tutorial.learn_skill")=="active" and int(s.profile.quest_state.next_skill_event)==serial,"GM grant cannot satisfy a learning task or spend its receipt")
	s.command("numbers.skill",{"id":"upper","delta":1,"force":true})
	check(s.quests.status(s.profile,"tutorial.learn_skill")=="active" and int(s.profile.quest_state.next_skill_event)==serial,"force bypass learning is excluded")
	s.command("numbers.skill",{"id":"upper","delta":-1})
	check(s.quests.status(s.profile,"tutorial.learn_skill")=="active" and int(s.profile.quest_state.next_skill_event)==serial,"refunding a rank cannot complete learning")
	var before:=JSON.stringify(s.serialize())
	check(not s.command("numbers.skill",{"id":"missing","delta":1}).ok and before==JSON.stringify(s.serialize()),"failed purchase leaves skills, SP and quest receipt unchanged")
	check(s.command("numbers.skill",{"id":"upper","delta":1}).ok and s.quests.status(s.profile,"tutorial.learn_skill")=="ready","successful normal purchase emits the required task event")
	before=JSON.stringify(s.serialize())
	s.quests.ingest(s.profile,{"type":"skill.learned","event_id":"skill:"+str(serial),"skill":"upper","levels":1})
	check(before==JSON.stringify(s.serialize()),"a repeated learning event cannot advance the task twice")
	var loaded=Session.new()
	check(loaded.restore(JSON.parse_string(JSON.stringify(s.serialize()))) and loaded.quests.status(loaded.profile,"tutorial.learn_skill")=="ready","learning receipt and task progress survive JSON save restoration")
	check(s.quest_command("quest.claim",{"id":"tutorial.learn_skill"},npc()).ok,"original second teaching reward hands in at Seria")
	var old=Session.new();old.profile.quest_state.erase("next_skill_event")
	check(loaded.restore(JSON.parse_string(JSON.stringify(old.serialize()))),"older quest saves without the additive event counter still load")
	var invalid: Dictionary=old.profile.duplicate(true);invalid.quest_state.next_skill_event=-1
	check(not old.quests.valid(invalid),"malformed learning counter is rejected")
	var c=Session.new();c.profile.level=10;complete(c,"gran.poison_scent")
	c.profile.job_index=1
	check(c.quests.status(c.profile,"gran.stronger_enemy")=="locked","swordman-only source challenge remains locked for another job")
	c.profile.job_index=0
	check(c.quest_command("quest.accept",{"id":"gran.stronger_enemy"},{"nearby":true,"npc":"gsd"}).ok,"current swordman can accept after poison hand-in")
	for mode: String in ["normal","king"]:
		c.quests.ingest(c.profile,{"type":"dungeon.cleared","event_id":"clear:"+mode,"dungeon":"sunderland_poison","difficulty":mode,"victory":true})
		check(c.quests.status(c.profile,"gran.stronger_enemy")=="active","challenge requires the exact requested mode: "+mode+" excluded")
	c.quests.ingest(c.profile,{"type":"dungeon.cleared","event_id":"clear:wrong","dungeon":"sunderland","difficulty":"adventure","victory":true})
	check(c.quests.status(c.profile,"gran.stronger_enemy")=="active","same difficulty in another dungeon cannot complete 503")
	c.quests.ingest(c.profile,{"type":"dungeon.cleared","event_id":"clear:right","dungeon":"sunderland_poison","difficulty":"adventure","victory":true})
	check(c.quests.status(c.profile,"gran.stronger_enemy")=="ready","adventure clear satisfies the exact original target")
	c.profile.job_index=1
	check(not c.quest_command("quest.claim",{"id":"gran.stronger_enemy"},{"nearby":true,"npc":"gsd"}).ok,"changing to an ineligible job cannot claim an active class task")
	c.profile.job_index=0
	check(c.quest_command("quest.claim",{"id":"gran.stronger_enemy"},{"nearby":true,"npc":"gsd"}).ok,"eligible source challenge reward is delivered once")
	check(s.command("flow.depart").ok,"food effect check uses an ordinary adventure session")
	var view: Dictionary={"run_id":s.run.id,"hp":100.0,"hp_max":500.0,"mp":0.0,"mp_max":500.0,"time_ms":0.0,"paused":false,"finished":false}
	var hp: Dictionary=s.use_consumable("original_1062",view,"bilberry")
	var mp: Dictionary=s.use_consumable("original_1065",view,"flower")
	check(hp.ok and hp.effect.hp==140 and hp.effect.duration_ms==1000,"bilberry uses its original timed HP tuple")
	check(mp.ok and mp.effect.mp==115 and mp.effect.duration_ms==1000,"magic flower uses its original timed MP tuple")
	check(s.CATALOG.stack_limit("original_1062")==1000 and s.CATALOG.stack_limit("original_1065")==1000,"both original food stacks retain source caps")
	var cfg: Dictionary=c.quests.catalog.config.duplicate(true)
	for q: Dictionary in cfg.quests:
		if q.id=="gran.stronger_enemy":q.eligibility.jobs=["bad"]
	check(not Catalog.new(cfg).errors.is_empty(),"malformed job eligibility fails definition validation")
	print("[TEACHING_RULES] COMPLETE checks=%d failures=%d" % [checks,failures]);quit(1 if failures else 0)
