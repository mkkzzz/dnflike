extends SceneTree
const Native=preload("res://content/native_catalog.gd")
const Session=preload("res://flow/session.gd")
const Inventory=preload("res://items/inventory.gd")
const Restore=preload("res://combat/item_restoration.gd")
var checks:=0
var failures:=0

class Actor:
	extends RefCounted
	var player: Dictionary={"hp":100.0,"mp":20.0}
	var max_hp:=1000.0
	var max_mp:=400.0
	var paused:=false
	var finished:=false
	var item_restorations: Array=[]

func check(value: bool,label: String) -> void:
	checks+=1
	if not value:failures+=1;push_error("[NATIVE_BULK] FAIL "+label)

func _initialize() -> void:call_deferred("run")

func run() -> void:
	var runtime:=Native.runtime()
	check(Native.index().indexes.quests.size()==2824,"every indexed original quest is queryable offline")
	check(Native.index().indexes.equipment.size()==67184 and Native.index().indexes.stackable.size()==14499,"all original item indexes load without a PVF")
	var original:=Native.original("quests",101)
	check(original.text["[name]"]!="" and not original.raw_base64.is_empty(),"source text and exact bytes are available together")
	check(not Native.search("林纳斯","quests",10).is_empty(),"Chinese full-corpus search")
	check(Native.original("equipment",-1).is_empty(),"missing original ID never aliases to a different item")
	var s=Session.new()
	check(s.quests.catalog.errors.is_empty(),"all admitted bulk quests validate in the actual quest service")
	for id: String in runtime.items:
		var p: Dictionary=s.profile.duplicate(true)
		check(Inventory.give(p,id,1).ok,"all bulk definitions enter the authoritative ownership ledger: "+id)
		check(Inventory.valid(p),"all bulk definitions preserve ledger invariants: "+id)
		if checks%500==0:print("[NATIVE_BULK] checked ",checks)
	# Check actual service accept/event/claim/save for each admitted quest. Set up
	# prerequisite receipts only; no dungeon playthrough or unrelated AI assertions.
	for q: Dictionary in runtime.quests:
		var session=Session.new()
		session.profile.level=int(q.min_level)
		var jobs: Array=q.eligibility.jobs
		session.profile["job_index"]=0 if -1 in jobs else int(jobs[0])
		for required: String in q.requires:
			var entry: Dictionary=session.quests.new_entry(session.quests.catalog.definitions[required]);entry.state="completed"
			session.profile.quest_state.entries[required]=entry
			session.profile.quest_state.transactions[session.quests.transaction_id(required)]=true
		check(session.quest_command("quest.accept",{"id":q.id},{"npc":q.giver,"nearby":true}).ok,"bulk source quest accepts: "+q.id)
		for o: Dictionary in q.objectives:
			if o.type=="collect_item":Inventory.give(session.profile,o.target,int(o.amount))
			elif o.type=="meet_npc":session.quests.ingest(session.profile,{"type":"npc.met","event_id":"native:"+q.id+o.id,"npc":o.target})
			elif o.type=="clear_dungeon":session.quests.ingest(session.profile,{"type":"dungeon.cleared","event_id":"native:"+q.id+o.id,"dungeon":o.target,"victory":true,"difficulty":o.get("difficulty",["normal"])[0]})
		check(session.quests.status(session.profile,q.id)=="ready","bulk source objectives complete through service events or real inventory: "+q.id)
		check(session.quest_command("quest.claim",{"id":q.id},{"npc":q.receiver,"nearby":true}).ok,"bulk source reward and consume transaction: "+q.id)
		var restored=Session.new()
		check(restored.restore(JSON.parse_string(JSON.stringify(session.serialize()))) and restored.quests.status(restored.profile,q.id)=="completed","bulk source completion survives real save restoration: "+q.id)
	var food:=""
	for id: String in runtime.consumables:
		if float(runtime.consumables[id].effect.get("hp_percent",0))>0:food=id;break
	check(food!="","actual source percentage recovery definition is admitted")
	if food!="":
		var session=Session.new();session.profile.level=60
		Inventory.give(session.profile,food,2);session.command("flow.depart")
		var request: Dictionary=session.use_consumable(food,{"run_id":session.run.id,"hp":100.0,"hp_max":1000.0,"mp":20.0,"mp_max":400.0,"time_ms":0.0,"paused":false,"finished":false},"native-percent")
		var rule: Dictionary=runtime.consumables[food].effect
		check(request.ok and is_equal_approx(float(request.effect.hp),float(rule.hp)+1000.0*float(rule.hp_percent)/100.0),"percentage resolves against current maximum at use time")
		var actor=Actor.new();check(Restore.apply(actor,request.effect),"resolved source percentage uses existing public combat receiver")
		Restore.step(actor,float(request.effect.duration_ms))
		check(is_equal_approx(actor.player.hp,minf(1000,100+float(request.effect.hp))),"source percentage restores the requested total")
		check(Inventory.stock(session.profile,food)==1,"percentage item consumes exactly one real stack entry")
	print("[NATIVE_BULK] COMPLETE checks=%d failures=%d" % [checks,failures])
	quit(1 if failures else 0)
