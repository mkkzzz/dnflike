extends SceneTree
const Session=preload("res://flow/session.gd")
const Inventory=preload("res://items/inventory.gd")
const Drops=preload("res://quests/drops.gd")
const Native=preload("res://content/api/native_catalog.gd")
var checks:=0
var failures:=0

func check(ok: bool,label: String) -> void:
	checks+=1
	if not ok:failures+=1;push_error("[CAMPAIGN] FAIL "+label)

func _initialize() -> void:call_deferred("run")

func completed(session: Session,id: String) -> void:
	var definition: Dictionary=session.quests.catalog.definitions[id]
	var entry: Dictionary=session.quests.new_entry(definition)
	entry.state="completed"
	session.profile.quest_state.entries[id]=entry
	session.profile.quest_state.transactions[session.Quests.transaction_id(id)]=true
	session.profile.quest_state.tracked.erase(id)

func npc_placed(session: Session,npc: String) -> bool:
	for location: Dictionary in session.town_world.data.locations.values():
		if location.get("npcs",{}).has(npc):return true
	return false

func satisfy(session: Session,q: Dictionary) -> void:
	for o: Dictionary in q.objectives:
		if o.type=="collect_item":
			var missing:=int(o.amount)-Inventory.stock(session.profile,o.target)
			if missing>0:Inventory.give(session.profile,o.target,missing)
		elif o.type=="meet_npc":
			for index in int(o.amount):
				session.quests.ingest(session.profile,{"type":"npc.met","event_id":"campaign:"+q.id+":"+o.id+":"+str(index),"npc":o.target})
		elif o.type=="kill_monster":
			for index in int(o.amount):
				session.quests.ingest(session.profile,{"type":"combat.monster_defeated","event_id":"campaign:"+q.id+":"+o.id+":"+str(index),"monster_id":o.target,"dungeon":o.get("dungeon",""),"difficulty":o.get("difficulty",["normal"])[0]})
		elif o.type=="clear_dungeon":
			session.quests.ingest(session.profile,{"type":"dungeon.cleared","event_id":"campaign:"+q.id+":"+o.id,"dungeon":o.target,"victory":true,"difficulty":o.get("difficulty",["normal"])[0],"facts":{"elapsed_ms":0,"hits_taken":0,"revives":0,"party_size":1}})
		elif o.type=="clear_map":
			session.quests.ingest(session.profile,{"type":"map.cleared","event_id":"campaign:"+q.id+":"+o.id,"dungeon":o.dungeon,"cell":o.cell})
		elif o.type=="learn_skill":
			session.quests.ingest(session.profile,{"type":"skill.learned","event_id":"campaign:"+q.id+":"+o.id,"skill":"upper","levels":1})
		elif o.type=="disassemble_item":
			var given: Dictionary=session.command("numbers.gear_give",{"id":"iron_sword"})
			var quote: Dictionary=session.Services.quote(session.profile,"services.disassemble",{"uid":given.uid})
			session.service_command("services.disassemble",{"uid":given.uid,"signature":quote.signature,"transaction":"campaign:"+q.id},{"npc":"norton","nearby":true})
	if not q.get("clear_items",[]).is_empty():
		session.run={"id":"campaign_clear:"+q.id,"dungeon":"sunderland_dark","difficulty":"normal"}
		session.award_clear_items()

func run() -> void:
	var rules: Dictionary=Native.quest_rules()
	var campaign: Dictionary=rules.campaign
	check(campaign.id=="campaign_1_16" and campaign.required==41 and campaign.executable==41 and campaign.missing==0,"curated 1-16 source chain is complete")
	var s=Session.new()
	check(s.quests.catalog.errors.is_empty() and s.town_world.errors.is_empty(),"campaign quests and expanded towns validate")
	for row: Dictionary in campaign.rows:
		check(row.state!="blocked" and s.quests.catalog.definitions.has(row.id),"campaign source task is executable: "+str(row.source_id))
	check(s.dungeon_choices("granfloris").has("grakkarak"),"Grakkarak is selectable from the forest entrance")
	check(s.town_world.data.locations.has("westcoast_magic") and s.town_world.data.locations.westcoast_magic.npcs.has("sharan"),"Sharan has an original-map town placement")
	check(s.town_world.data.locations.hendon_pub.npcs.has("shusia") and s.town_world.data.locations.westcoast.npcs.has("lorian"),"Shusia and Lorian have original-map placements")

	s.profile.level=16
	completed(s,"lorien.first_clear")
	s.advance_auto_quests()
	check(s.quests.status(s.profile,"original.quest.4465")=="active","time-piece chain auto-starts from the first clear")
	Inventory.give(s.profile,"original_4799",1)
	s.advance_auto_quests()
	check(s.quests.status(s.profile,"original.quest.4465")=="completed","automatic time-piece reward closes after the source item exists")

	completed(s,"original.quest.116")
	var before:=Inventory.stock(s.profile,"original_3077")
	var accepted: Dictionary=s.quest_command("quest.accept",{"id":"original.quest.112"},{"npc":"gsd","nearby":true})
	check(accepted.ok and Inventory.stock(s.profile,"original_3077")==before+1,"depend-give item is committed when the quest is accepted")

	completed(s,"original.quest.112")
	var shusia_accept: Dictionary=s.quest_command("quest.accept",{"id":"original.quest.113"},{"npc":"shusia","nearby":true})
	check(shusia_accept.ok,"Grakkarak investigation quest accepts from Shusia: "+String(shusia_accept.get("message","")))
	var drop_quest: Dictionary=s.quests.catalog.definitions["original.quest.113"]
	var rule: Dictionary=drop_quest.drops[0]
	var event: Dictionary={"run_id":"campaign_drop","monster_id":rule.monster,"dungeon":rule.dungeon,"difficulty":rule.difficulty[0]}
	var drops: Array=Drops.entries(s.profile,{"id":"campaign_drop","dungeon":rule.dungeon,"difficulty":rule.difficulty[0]},event,s.quests.catalog.definitions)
	check(not drops.is_empty() and drops[0].quest=="original.quest.113","source monster-reward item becomes an eligible quest drop")

	completed(s,"original.quest.202")
	var sinda_accept: Dictionary=s.quest_command("quest.accept",{"id":"original.quest.203"},{"npc":"sinda","nearby":true})
	check(sinda_accept.ok,"dark forest investigation accepts before its clear reward: "+String(sinda_accept.get("message","")))
	s.run={"id":"campaign_clear","dungeon":"sunderland_dark","difficulty":"normal"}
	check(s.award_clear_items() and Inventory.stock(s.profile,"original_3081")==1,"clear reward creates the exact source item once")
	check(not s.award_clear_items() and Inventory.stock(s.profile,"original_3081")==1,"clear reward respects the source holding cap")

	completed(s,"original.quest.117")
	var sharan_accept: Dictionary=s.quest_command("quest.accept",{"id":"original.quest.4601"},{"npc":"sharan","nearby":true})
	check(sharan_accept.ok,"Sky Tower rescue quest accepts from Sharan: "+String(sharan_accept.get("message","")))
	var sky_objective: Dictionary=s.quests.catalog.definitions["original.quest.4601"].objectives[0]
	var map_result: Dictionary=s.quests.ingest(s.profile,{"type":"map.cleared","event_id":"campaign-map","dungeon":"draconiantower","cell":[2,1]})
	check(s.quests.status(s.profile,"original.quest.4601")=="ready","clear-map objective completes on the mapped source cell: "+JSON.stringify(sky_objective)+" "+JSON.stringify(map_result)+" status="+s.quests.status(s.profile,"original.quest.4601"))
	check(s.command("flow.difficulty",{"id":"expert"}).ok,"expert difficulty is selectable for source difficulty 2")

	var flow=Session.new()
	var remaining: Dictionary={}
	for row: Dictionary in campaign.rows:remaining[row.id]=true
	for _pass in range(campaign.rows.size()+2):
		var acted:=false
		for id: String in remaining.keys():
			var q: Dictionary=flow.quests.catalog.definitions[id]
			if not q.requires.all(func(required):return flow.quests.has_completed(flow.profile,required)):continue
			flow.profile.level=maxi(int(flow.profile.level),int(q.min_level))
			if q.get("auto_accept",false):
				flow.advance_auto_quests()
				if not flow.profile.quest_state.entries.has(id):continue
			else:
				check(npc_placed(flow,q.giver),"campaign giver is placed in town: "+q.giver)
				if not flow.quest_command("quest.accept",{"id":id},{"npc":q.giver,"nearby":true}).ok:continue
			satisfy(flow,q)
			flow.advance_auto_quests()
			if q.get("auto_complete",false):
				if flow.quests.status(flow.profile,id)=="completed":remaining.erase(id);acted=true
			elif flow.quests.status(flow.profile,id)=="ready":
				check(npc_placed(flow,q.receiver),"campaign receiver is placed in town: "+q.receiver)
				var claim: Dictionary={"id":id}
				if not q.reward.choices.is_empty():claim["choice"]=q.reward.choices[0].id
				if flow.quest_command("quest.claim",claim,{"npc":q.receiver,"nearby":true}).ok and flow.quests.has_completed(flow.profile,id):
					remaining.erase(id);acted=true
		if remaining.is_empty() or not acted:break
	check(remaining.is_empty(),"all campaign nodes form one playable dependency graph")

	print("[CAMPAIGN] COMPLETE checks=%d failures=%d" % [checks,failures])
	quit(1 if failures else 0)
