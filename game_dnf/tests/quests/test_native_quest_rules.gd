extends SceneTree
const Session=preload("res://flow/session.gd")
const Catalog=preload("res://quests/catalog.gd")
const Service=preload("res://quests/service.gd")
const Conditions=preload("res://quests/clear_conditions.gd")
const Inventory=preload("res://items/inventory.gd")
var checks:=0
var failures:=0
var clock_state={"now":172800.0}

func check(ok: bool,label: String) -> void:
	checks+=1
	if not ok:failures+=1;push_error("[QUEST_RULES] FAIL "+label)

func _initialize() -> void:call_deferred("run")
func npc(id: String="gsd") -> Dictionary:return {"npc":id,"nearby":true}
func meet(s,id: String) -> void:s.quests.ingest(s.profile,{"type":"npc.met","event_id":id,"npc":"gsd"})
func completed(s,id: String) -> void:
	var entry: Dictionary=s.quests.new_entry(s.quests.catalog.definitions[id]);entry.state="completed"
	s.profile.quest_state.entries[id]=entry;s.profile.quest_state.transactions[s.Quests.transaction_id(id)]=true

func fixture() -> Session:
	var s=Session.new();var cfg: Dictionary=s.quests.catalog.config.duplicate(true)
	for id: String in ["fixture.repeat","fixture.daily","fixture.follow"]:
		var q: Dictionary=s.quests.catalog.definitions["original.quest.1106"].duplicate(true)
		q.id=id;q.erase("source");q.min_level=1;q.requires=[];q.objectives=[{"id":"visit","type":"meet_npc","target":"gsd","amount":1}]
		q.reward={"gold":3,"xp":1,"items":{"potion":1},"choices":[]};q.consume={}
		if id!="fixture.follow":q.lifecycle="repeat" if id=="fixture.repeat" else "daily"
		else:q.requires=["fixture.repeat"]
		cfg.quests.append(q)
	s.quests=Service.new(Catalog.new(cfg));s.quests.clock=func():return clock_state.now
	return s

func check_growth_eligibility() -> void:
	var base=Session.new()
	var cfg: Dictionary=base.quests.catalog.config.duplicate(true)
	var q: Dictionary=base.quests.catalog.definitions["original.quest.1106"].duplicate(true)
	q.id="fixture.growth_gate";q.erase("source");q.requires=[];q.min_level=48
	q.eligibility={"jobs":[0],"grow_types":[2]}
	q.objectives=[{"id":"visit","type":"meet_npc","target":"gsd","amount":1}]
	q.giver="gsd";q.receiver="gsd";q.consume={}
	q.reward={"gold":0,"xp":0,"items":{},"choices":[],"conditional_items":[
		{"item":"potion","amount":1,"jobs":[0],"grow_types":[0]},
		{"item":"potion","amount":2,"jobs":[0],"grow_types":[2]},
		{"item":"potion","amount":4,"jobs":[0],"grow_types":[4]},
		{"item":"potion","amount":8,"jobs":[0],"grow_types":[-1]},
		{"item":"potion","amount":16,"jobs":[1],"grow_types":[-1]},
	]}
	cfg.quests.append(q)
	for row in [["swordman",9],["soulbringer",10],["asura",12]]:
		var s=Session.new()
		s.quests=Service.new(Catalog.new(cfg))
		check(s.quests.catalog.errors.is_empty(),"growth restriction and reward rows validate")
		s.profile.level=47
		if row[0]!="swordman":
			check(s.command("numbers.growtype",{"growtype":row[0]}).ok,"normal growth command sets "+row[0])
		check(not s.quest_command("quest.accept",{"id":q.id},npc()).ok,"quest cannot start below level 48: "+row[0])
		s.profile.level=48
		check(s.quests.reward_for(s.profile,q).items.potion==row[1],"fixed and wildcard reward rows select "+row[0])
		var accepted: Dictionary=s.quest_command("quest.accept",{"id":q.id},npc())
		check(accepted.ok==(row[0]=="soulbringer"),"only swordman growth index 2 passes the original restriction: "+row[0])
		if accepted.ok:
			var before: int=Service.stock(s.profile,"potion")
			meet(s,"growth-gate")
			check(s.quest_command("quest.claim",{"id":q.id},npc()).ok and Service.stock(s.profile,"potion")==before+10,"quest claim grants index 2 and wildcard rows exactly once")
	var unknown: Dictionary=base.profile.duplicate(true)
	unknown.growtype="unrecognized"
	check(Service.new().reward_for(unknown,q).items.potion==8,"unknown growth receives only the wildcard row")

func check_soulbringer_awakening_collection() -> void:
	var s=Session.new()
	var id:="original.quest.981"
	var request:={"id":id}
	s.profile.level=48
	check(not s.quest_command("quest.accept",request,npc()).ok,"base Swordman cannot accept the Soulbringer awakening collection")
	check(s.command("numbers.growtype",{"growtype":"soulbringer"}).ok,"ordinary job command creates the eligible Soulbringer")
	s.profile.level=47
	check(not s.quest_command("quest.accept",request,npc()).ok,"Soulbringer must reach the original minimum level")
	s.profile.level=48
	s.profile.awakening_stage=1
	check(not s.quest_command("quest.accept",request,npc()).ok,"the offline first-awakening collection is limited to stage zero")
	s.profile.awakening_stage=0
	check(not s.quest_command("quest.accept",request,npc("albert")).ok,"only G.S.D. offers the collection")
	check(s.quest_command("quest.accept",request,npc()).ok,"level 48 Soulbringer accepts the original collection")
	for item: String in ["original_3038","original_3039","original_3040","original_3041","original_3042"]:
		check(Inventory.give(s.profile,item,1).ok,"fixture supplies "+item)
	check(Inventory.give(s.profile,"original_3155",29).ok,"fixture supplies fewer than thirty high-grade materials")
	check(s.quests.status(s.profile,id)=="active" and not s.quest_command("quest.claim",request,npc()).ok,"twenty-nine materials do not satisfy the original requirement")
	check(Inventory.give(s.profile,"original_3155",2).ok,"fixture supplies one spare material above the requirement")
	check(not s.quest_command("quest.claim",request,npc("albert")).ok,"only G.S.D. can complete the collection")
	var gold: int=s.profile.gold
	check(s.quest_command("quest.claim",request,npc()).ok,"original collection is handed in through the quest service")
	check(Inventory.stock(s.profile,"original_3155")==1 and Inventory.stock(s.profile,"original_3038")==0,"hand-in consumes the original amounts and leaves the surplus")
	check(Inventory.stock(s.profile,"original_1089")==20 and Inventory.stock(s.profile,"original_1090")==20 and s.profile.gold==gold+100,"original collection grants both twenty-item stacks and one hundred gold")
	check(s.profile.awakening_stage==0 and not s.quest_command("quest.claim",request,npc()).ok,"collection preserves stage zero and cannot pay twice")
	var loaded=Session.new()
	check(loaded.restore(JSON.parse_string(JSON.stringify(s.serialize()))) and loaded.quests.status(loaded.profile,id)=="completed","ordinary save restore preserves the completed collection")

func run() -> void:
	var plain=Session.new()
	check(plain.quests.catalog.errors.is_empty(),"all old and additive native definitions validate")
	check_growth_eligibility()
	check_soulbringer_awakening_collection()
	var commands=preload("res://debug/native_commands.gd")
	var quest217: String=commands.execute(PackedStringArray(["quests","217"])).message
	check(quest217.contains("admitted") or quest217.contains("existing"),"GM original-ID lookup reports the current compiler instead of stale migration status")
	check(commands.execute(PackedStringArray()).message.contains("当前原任务可执行 "+str(plain.quests.catalog.definitions.size()-1)),"GM summary distinguishes current executable quests from source-only counts")
	var level_cap:=int(Session.Numbers.shared_config().progression.level_cap)
	for q: Dictionary in preload("res://content/api/native_catalog.gd").quest_rules().quests:
		var min_level:=int(q.min_level)
		var s=Session.new();s.profile.level=mini(min_level,level_cap)
		s.profile.job_index=0 if -1 in q.eligibility.jobs else int(q.eligibility.jobs[0])
		if not q.eligibility.grow_types.is_empty() and -1 not in q.eligibility.grow_types:
			var growth: Dictionary=Session.Numbers.shared_config().growtype_index
			for branch: String in growth:
				if int(growth[branch])==int(q.eligibility.grow_types[0]):
					s.profile.growtype=branch
					break
		for required: String in q.requires:completed(s,required)
		if min_level>level_cap:
			if q.get("auto_accept",false):s.advance_auto_quests()
			else:check(not s.quest_command("quest.accept",{"id":q.id},npc(q.giver)).ok,"manual source quest above the cap rejects acceptance: "+q.id)
			check(s.quests.status(s.profile,q.id)=="locked" and not s.profile.quest_state.entries.has(q.id),"source quest above the cap stays locked at the highest legal level: "+q.id)
			var at_cap=Session.new()
			check(at_cap.restore(JSON.parse_string(JSON.stringify(s.serialize()))) and at_cap.quests.status(at_cap.profile,q.id)=="locked","above-cap source quest stays locked after restoring a legal save: "+q.id)
			continue
		if q.get("auto_accept",false):
			var accepted: Dictionary=s.advance_auto_quests()
			check(accepted.get("ok",false) and s.profile.quest_state.entries.has(q.id),"every automatic original node starts with its prerequisites: "+q.id)
		else:
			check(s.quest_command("quest.accept",{"id":q.id},npc(q.giver)).ok,"every admitted original node accepts with original class/prerequisites: "+q.id)
		for o: Dictionary in q.objectives:
			if o.type=="clear_dungeon":
				s.quests.ingest(s.profile,{"type":"dungeon.cleared","event_id":"native:"+q.id,"dungeon":o.target,"victory":true,"difficulty":o.get("difficulty",["normal"])[0],"facts":{"elapsed_ms":0,"hits_taken":0,"revives":0,"party_size":1}})
			elif o.type=="kill_monster":
				for index in int(o.amount):
					s.quests.ingest(s.profile,{"type":"combat.monster_defeated","event_id":"kill:"+q.id+":"+str(index),"monster_id":o.target,"dungeon":o.get("dungeon",""),"difficulty":o.get("difficulty",["normal"])[0]})
			elif o.type=="meet_npc":
				for index in int(o.amount):
					s.quests.ingest(s.profile,{"type":"npc.met","event_id":"meet:"+q.id+":"+str(index),"npc":o.target})
			elif o.type=="collect_item":
				var missing:=int(o.amount)-preload("res://items/inventory.gd").stock(s.profile,o.target)
				if missing>0:check(preload("res://items/inventory.gd").give(s.profile,o.target,missing)["ok"],"source collection fixture is obtainable: "+q.id)
			elif o.type=="clear_map":
				if o.has("quest_maze"):
					s.quests.ingest(s.profile,{"type":"map.cleared","event_id":"ordinary-map:"+q.id,"dungeon":o.dungeon,"victory":true})
					check(s.quests.status(s.profile,q.id)=="active","ordinary map clear cannot satisfy escort objective: "+q.id)
					s.quests.ingest(s.profile,{"type":"escort.map_cleared","event_id":"escort:"+q.id,"dungeon":o.dungeon,
						"quest_maze":o.quest_maze,"source_map_id":int(o.source_map_id),"companions_alive":[int(o.companion_id)],
						"party_size":1,"difficulty":o.difficulty[0],"victory":true})
				else:s.quests.ingest(s.profile,{"type":"map.cleared","event_id":"map:"+q.id,"dungeon":o.dungeon,"cell":o.cell})
			elif o.type=="learn_skill":
				s.quests.ingest(s.profile,{"type":"skill.learned","event_id":"skill:"+q.id,"skill":"upper","levels":1})
			elif o.type=="disassemble_item":
				var given: Dictionary=s.command("numbers.gear_give",{"id":"iron_sword"})
				var quote: Dictionary=s.Services.quote(s.profile,"services.disassemble",{"uid":given.uid})
				check(s.service_command("services.disassemble",{"uid":given.uid,"signature":quote.signature,"transaction":"native-disassemble"},npc("norton")).ok,"actual supported equipment disassembles through NPC service")
		s.advance_auto_quests()
		if q.get("auto_complete",false):
			check(s.quests.status(s.profile,q.id)=="completed","every automatic source reward hands in after its real event: "+q.id)
		else:
			check(s.quests.status(s.profile,q.id)=="ready","every new source objective reaches ready through its real service event: "+q.id)
			var claim: Dictionary={"id":q.id}
			if not q.reward.choices.is_empty():claim["choice"]=q.reward.choices[0].id
			check(s.quest_command("quest.claim",claim,npc(q.receiver)).ok,"every new source reward hands in: "+q.id)
		var loaded=Session.new()
		var restore_ok:=loaded.restore(JSON.parse_string(JSON.stringify(s.serialize())))
		var restored_status: String=loaded.quests.status(loaded.profile,q.id)
		check(restore_ok and (restored_status=="completed" or q.get("lifecycle","once")=="repeat" and restored_status=="available"),"all admitted completions survive JSON restore: "+q.id)
	for field: String in Conditions.LIMITS:
		var rules={field:2};var fact: String=Conditions.LIMITS[field][0]
		check(not Conditions.matches(rules,{}),"missing authoritative metric never defaults to success: "+field)
		check(Conditions.matches(rules,{fact:2}),"inclusive condition boundary: "+field)
		check(not Conditions.matches(rules,{fact:1 if field=="min_party_size" else 3}),"wrong side of condition boundary fails: "+field)
	for value in [NAN,INF,-1,"0",true]:check(not Conditions.matches({"max_hits_taken":2},{"hits_taken":value}),"invalid metric cannot satisfy a clear condition")
	check(not Conditions.valid({"fake_score":0}),"unimplemented clear conditions are rejected by the registry")
	var c=Session.new();c.profile.level=25
	check(c.quest_command("quest.accept",{"id":"original.quest.1106"},npc()).ok,"actual original received-hit task accepts")
	c.command("flow.depart",{"dungeon":"palaceofload"})
	for n in 23:
		var e={"type":"combat.damage","run_id":c.run.id,"event_id":n,"victim":"player","amount":1}
		c.observe_damage(e);c.observe_damage(e)
	c.observe_damage({"type":"combat.damage","run_id":"old","event_id":30,"victim":"player","amount":99})
	c.observe_damage({"type":"combat.damage","run_id":c.run.id,"event_id":31,"victim":"monster","amount":99})
	check(c.run.quest_facts.hits_taken==23,"run observations count received hits once and exclude stale/monster facts")
	var bad_run: Dictionary=c.run.duplicate(true);bad_run.quest_facts.hits_taken=0
	check(not Conditions.valid_run(bad_run),"saved hit totals must agree with unique observed receipts")
	c.finish_run(true,{"elapsed_ms":1000,"hit_count":0,"hits_taken":0})
	check(c.quests.status(c.profile,"original.quest.1106")=="active","untrusted summary hit_count cannot bypass actual 23 received hits")
	c.command("flow.return");c.command("flow.depart",{"dungeon":"palaceofload"});c.finish_run(true,{"elapsed_ms":1000})
	check(c.quests.status(c.profile,"original.quest.1106")=="ready","new adventure resets metrics and can satisfy the same objective")
	var s=fixture();var initial_gold: int=s.profile.gold
	check(s.quests.catalog.errors.is_empty() and s.quests.valid(s.profile),"repeat/daily test definitions use the normal validated registry")
	check(s.quest_command("quest.accept",{"id":"fixture.repeat"},npc()).ok,"repeat round one accepts")
	meet(s,"r1");check(s.quest_command("quest.claim",{"id":"fixture.repeat"},npc()).ok,"repeat round one claims")
	check(s.quests.status(s.profile,"fixture.repeat")=="available" and s.quests.status(s.profile,"fixture.follow")=="available","next round availability preserves historical predecessor completion")
	var before:=JSON.stringify(s.serialize())
	check(not s.quest_command("quest.claim",{"id":"fixture.repeat"},npc()).ok and before==JSON.stringify(s.serialize()),"duplicate repeat claim neither rewards nor alters round receipts")
	check(s.quest_command("quest.accept",{"id":"fixture.repeat"},npc()).ok and s.profile.quest_state.entries["fixture.repeat"].progress.visit==0,"new round has fresh progress and dedup state")
	check(s.quests.status(s.profile,"fixture.follow")=="available","active repeat round cannot relock a historical prerequisite")
	meet(s,"r1");check(s.quest_command("quest.claim",{"id":"fixture.repeat"},npc()).ok,"same fact ID in a newly accepted round is scoped to that round")
	check(s.profile.gold==initial_gold+6 and s.profile.quest_state.cycles["fixture.repeat"].completions==2,"each completed round awards exactly once under a unique growth/reward receipt")
	s.quest_command("quest.accept",{"id":"fixture.repeat"},npc());s.quest_command("quest.abandon",{"id":"fixture.repeat"},npc())
	check(s.quests.has_completed(s.profile,"fixture.repeat") and s.quests.valid(s.profile),"abandoning a later round preserves completed history and ledger validity")
	s.quest_command("quest.accept",{"id":"fixture.repeat"},npc())
	check(s.profile.quest_state.entries["fixture.repeat"].cycle==4,"abandoning cannot reuse a previous round serial")
	var loaded=fixture()
	check(loaded.restore(JSON.parse_string(JSON.stringify(s.serialize()))) and loaded.profile.quest_state.cycles["fixture.repeat"].completions==2,"round counters and pending progress survive ordinary save restoration")
	var invalid: Dictionary=s.profile.duplicate(true);invalid.quest_state.cycles["fixture.repeat"].completions=3
	check(not s.quests.valid(invalid),"forged completion totals without matching receipts are rejected")
	check(s.quests.list(s.profile,["completed"]).any(func(q):return q.id=="fixture.repeat" and q.completions==2),"completed page retains repeat history while a later round is active")
	check(s.quest_command("quest.accept",{"id":"fixture.daily"},npc()).ok,"daily round accepts")
	meet(s,"daily1");check(s.quest_command("quest.claim",{"id":"fixture.daily"},npc()).ok,"daily round claims")
	check(s.quests.status(s.profile,"fixture.daily")=="completed" and not s.quest_command("quest.accept",{"id":"fixture.daily"},npc()).ok,"same calendar day cannot accept or reward another daily round")
	clock_state.now-=86400
	check(s.quests.status(s.profile,"fixture.daily")=="completed","rolling the local clock backwards cannot reopen an already claimed day")
	clock_state.now=3*86400.0-8*3600-1
	check(s.quests.status(s.profile,"fixture.daily")=="completed","daily stays completed one second before configured UTC+8 midnight")
	clock_state.now+=1
	check(s.quests.status(s.profile,"fixture.daily")=="available","configured day boundary makes the next daily round available")
	s.quest_command("quest.accept",{"id":"fixture.daily"},npc());meet(s,"daily2")
	check(s.quest_command("quest.claim",{"id":"fixture.daily"},npc()).ok and s.profile.quest_state.cycles["fixture.daily"].completions==2,"next-day reward uses a second distinct transaction")
	before=JSON.stringify(s.serialize());var receiver:=func(_candidate,_reward,_tx):return {"ok":false,"message":"故障注入"}
	s.quest_command("quest.accept",{"id":"fixture.repeat"},npc());meet(s,"r4")
	before=JSON.stringify(s.serialize())
	check(not s.quests.command(s.profile,"quest.claim",{"id":"fixture.repeat"},{"npc":"gsd","nearby":true,"in_town":true},receiver).ok and before==JSON.stringify(s.serialize()),"failed reward adapter preserves round progress, history and reward receipt together")
	check(Session.new().restore(JSON.parse_string(JSON.stringify(plain.serialize()))),"old saves without cycle/calendar keys remain readable")
	var scope: Dictionary={"id":"scoped","type":"clear_dungeon","target":"any","allowed_dungeons":["lorien"],"amount":1}
	var cfg: Dictionary=plain.quests.catalog.config.duplicate(true)
	var scoped: Dictionary=cfg.quests[0].duplicate(true);scoped.id="fixture.scope";scoped.requires=[];scoped.objectives=[scope];scoped.min_level=1;cfg.quests.append(scoped)
	var scoped_service=Service.new(Catalog.new(cfg));var profile: Dictionary=plain.profile.duplicate(true)
	check(scoped_service.catalog.errors.is_empty(),"explicit original dungeon wildcard scope validates")
	scoped_service.command(profile,"quest.accept",{"id":scoped.id},{"in_town":true,"nearby":true,"npc":scoped.giver})
	scoped_service.ingest(profile,{"type":"dungeon.cleared","event_id":"fake-map","dungeon":"forest_trial","victory":true})
	check(scoped_service.status(profile,scoped.id)=="active","original any-dungeon objective excludes legacy sample map")
	scoped_service.ingest(profile,{"type":"dungeon.cleared","event_id":"source-map","dungeon":"lorien","victory":true})
	check(scoped_service.status(profile,scoped.id)=="ready","original any-dungeon objective accepts a registered source map")
	print("[QUEST_RULES] COMPLETE checks=%d failures=%d" % [checks,failures]);quit(1 if failures else 0)
