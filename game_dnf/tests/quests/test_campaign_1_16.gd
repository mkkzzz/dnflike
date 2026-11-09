extends SceneTree
const Session=preload("res://flow/session.gd")
const Inventory=preload("res://items/inventory.gd")
const Drops=preload("res://quests/drops.gd")
const Native=preload("res://content/api/native_catalog.gd")
const CombatSession=preload("res://combat/api/combat_session.gd")
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
	for rule: Dictionary in q.get("clear_items", []):
		session.run={"id":"campaign_clear:"+q.id,"dungeon":rule.dungeon,"difficulty":rule.difficulty[0]}
		session.award_clear_items()

func draconian_eyes() -> void:
	var session := Session.new()
	var quest_id := "original.quest.4306"
	check(session.quests.catalog.definitions.has(quest_id), "G.S.D. source eye collection quest is available to the game")
	if not session.quests.catalog.definitions.has(quest_id):return
	session.profile.level = 16
	completed(session, "original.quest.8")
	completed(session, "original.quest.117")
	var gsd := {"npc":"gsd", "nearby":true}
	check(session.quest_command("quest.accept", {"id":"original.quest.4305"}, gsd).ok, "G.S.D. offers the source prerequisite")
	session.npc_met("gsd")
	check(session.quest_command("quest.claim", {"id":"original.quest.4305"}, gsd).ok
		and session.quest_command("quest.accept", {"id":quest_id}, gsd).ok, "G.S.D. offers the eye quest after its conversation")
	var room := "draconiantower:source_boss_fixture"
	var boss := {"type":"combat.monster_defeated", "entity_id":0, "event_id":"boss:0", "room_id":room,
		"position":Vector2(100, 200), "monster_id":"monster/draconian/lakius.mob", "boss":true}
	check(session.command("flow.depart", {"dungeon":"draconiantower"}).ok, "normal Draconian Tower departure uses the live route")
	boss.run_id = session.run.id
	check(Drops.entries(session.profile, session.run, boss, session.quests.catalog.definitions).is_empty(), "normal mode has no source eye drop")
	session.finish_run(true, {})
	session.command("flow.return")
	check(session.command("flow.difficulty", {"id":"expert"}).ok
		and session.command("flow.depart", {"dungeon":"draconiantower"}).ok, "Expert Draconian Tower departure succeeds")
	boss.run_id = session.run.id
	# Repeated source boss-event fixtures exercise the holding cap without playing 15 routes.
	for index in range(16):
		boss.entity_id = index
		boss.event_id = "boss:%d" % index
		session.combat_event(boss)
	var eyes: Array = session.Loot.pending(session.run, room).filter(func(drop):return drop.item == "original_3129")
	check(eyes.size() == 15 and Inventory.stock(session.profile, "original_3129") == 0,
		"guaranteed source boss drops reserve the fifteen-eye cap on the ground")
	check(session.quests.status(session.profile, quest_id) == "active", "unclaimed eyes do not satisfy the quest")
	var picked_up := true
	for drop: Dictionary in eyes:
		var position := Vector2(float(drop.position[0]), float(drop.position[1]))
		picked_up = session.Loot.claim(session.profile, session.run, drop.id, room, position).ok and picked_up
	check(picked_up and session.quests.status(session.profile, quest_id) == "ready", "picking up fifteen eyes prepares the hand-in")
	session.finish_run(true, {})
	session.command("flow.return")
	var gold := int(session.profile.gold)
	check(session.quest_command("quest.claim", {"id":quest_id}, gsd).ok and Inventory.stock(session.profile, "original_3129") == 0
		and session.quests.has_completed(session.profile, quest_id) and int(session.profile.gold) == gold + 5000,
		"G.S.D. consumes the source eyes and pays the original fixed gold")

func light_lord_chain() -> void:
	var session := Session.new()
	var meeting := "original.quest.18"
	var message := "original.quest.19"
	var delivery := "original.quest.20"
	var seria := {"npc":"seria", "nearby":true}
	var kagon := {"npc":"kagon", "nearby":true}
	var sharan := {"npc":"sharan", "nearby":true}
	session.profile.level = 25
	completed(session, "original.quest.17")
	check(session.quest_command("quest.accept", {"id":meeting}, seria).ok, "Seria offers the original Lord of Light chain")
	session.npc_met("kagon")
	check(session.quest_command("quest.claim", {"id":meeting}, kagon).ok
		and session.quest_command("quest.accept", {"id":message}, kagon).ok
		and Inventory.stock(session.profile, "original_3105") == 1, "Kagon supplies the source quest item after meeting")
	var room := "palaceofload:1_0:(1,0)b2408"
	var boss := {"type":"combat.monster_defeated", "entity_id":0, "event_id":"lord:0", "room_id":room,
		"position":Vector2(100, 200), "monster_id":"monster/lordoflight/lordoflight.mob", "boss":true}
	check(session.command("flow.depart", {"dungeon":"palaceofload"}).ok, "the source Palace of the Lord route is selectable")
	boss.run_id = session.run.id
	session.combat_event(boss)
	check(session.Loot.pending(session.run, room).all(func(drop):return drop.item != "original_3107"), "normal mode does not drop the memory crystal")
	session.finish_run(true, {})
	session.command("flow.return")
	check(session.command("flow.difficulty", {"id":"adventure"}).ok
		and session.command("flow.depart", {"dungeon":"palaceofload"}).ok, "Adventure Palace departure succeeds")
	boss.run_id = session.run.id
	session.combat_event(boss)
	var crystals: Array = session.Loot.pending(session.run, room).filter(func(drop):return drop.item == "original_3107")
	check(crystals.size() == 1 and session.quests.status(session.profile, message) == "active", "the original boss drops one unclaimed crystal")
	if crystals.size() != 1:return
	var crystal: Dictionary=crystals[0]
	var position := Vector2(float(crystal.position[0]), float(crystal.position[1]))
	check(session.Loot.claim(session.profile, session.run, crystal.id, room, position).ok, "the player can pick up the source memory crystal")
	session.finish_run(true, {})
	session.command("flow.return")
	check(session.quest_command("quest.claim", {"id":message}, kagon).ok
		and Inventory.stock(session.profile, "original_3105") == 0
		and Inventory.stock(session.profile, "original_3107") == 0, "Kagon consumes both original quest items")
	check(session.quest_command("quest.accept", {"id":delivery}, kagon).ok
		and Inventory.stock(session.profile, "original_3107") == 1, "Kagon gives the memory crystal for delivery to Sharan")
	check(session.quest_command("quest.claim", {"id":delivery}, sharan).ok
		and Inventory.stock(session.profile, "original_3107") == 0, "Sharan receives the memory crystal")

func escort_maze(dungeon: String, quest: String, companion: int, maps: Array, boss: String) -> void:
	var session := Session.new()
	session.profile.level = 18
	for required: String in session.dungeons[dungeon].get("requires", []):
		completed(session, required)
	check(session.quests.status(session.profile,quest)=="locked", "escort quest is not offered before its source prerequisites")
	var selection := {"dungeon":dungeon, "quest_maze":quest}
	session.command("flow.difficulty", {"id":"expert"})
	check(session.command("flow.depart", selection).ok and not session.run.has("quest_maze"), "departure cannot request a quest maze without an active quest")
	session.finish_run(false, {})
	session.command("flow.return")
	for required: String in session.quests.catalog.definitions[quest].requires:
		completed(session, required)
	check(session.quest_command("quest.accept", {"id":quest}, {"npc":"gsd","nearby":true}).ok, "G.S.D. offers the original escort quest after its prerequisites")
	session.command("flow.difficulty", {"id":"adventure"})
	check(session.command("flow.depart", selection).ok and not session.run.has("quest_maze"), "the active escort quest still uses the ordinary Adventure route")
	session.finish_run(false, {})
	session.command("flow.return")
	session.command("flow.difficulty", {"id":"expert"})
	check(session.command("flow.depart", {"dungeon":dungeon}).ok and session.run.get("quest_maze")==quest, "Hard departure binds the active original quest maze")
	var route := session.active_dungeon_route()
	var combat := CombatSession.new()
	var battle = combat.mount(root)
	battle.set_physics_process(false)
	var final_event: Dictionary={}
	combat.room_combat_finished.connect(func(event: Dictionary):
		if event.get("final_room",false):final_event.assign(event)
		session.combat_event(event))
	var started := combat.start_room({"run_id":session.run.id, "dungeon":dungeon, "route":route,
		"room_id":dungeon+":0", "room_index":0, "player":session.run.stats, "audio":{"muted":true}})
	check(started, "combat API validates the complete quest route and original MOB roster")
	if not started:
		combat.stop()
		return
	check(battle.room_map.companions.size()==1 and int(battle.room_map.companions[0].source_id)==companion,
		"the first room exposes the original friendly APC placement")
	for index in maps.size():
		check(battle.room_index==index and int(battle.room_map.map_id)==maps[index], "quest gate reaches source MAP%d" % maps[index])
		if index==maps.size()-1:
			check(battle.monsters.any(func(enemy):return enemy.chief and enemy.mob==boss), "the dedicated final MAP loads the original boss")
		else:
			battle.player.pos=battle.door_point(route.rooms[index].next)
			battle.door_lock_ms=0.0
		for enemy: Dictionary in battle.monsters:
			enemy.hp=0.0
			enemy.death_ms=1000.0
		battle._physics_process(1.0/60.0)
	check(battle.map_loader.errors.is_empty() and session.state=="result" and session.result.victory, "quest maps render and the final room settles the battle")
	check(session.QuestConditions.escort_survived(final_event,int(maps[-1]),companion),
		"the combat settlement reports the exact final MAP and a living source APC")
	check(session.quests.status(session.profile,quest)=="ready", "the final battle completes the accepted original escort objective")
	combat.stop()
	session.command("flow.return")
	var gold: int = session.profile.gold
	check(session.quest_command("quest.claim", {"id":quest}, {"npc":"gsd","nearby":true}).ok
		and int(session.profile.gold)==gold+5000,"the actual escort route pays the original reward at G.S.D.")
	if quest=="original.quest.4308":escort_followups(session)

func escort_followups(session: Session) -> void:
	var kiri := {"npc":"kiri","nearby":true}
	var talk := {"id":"original.quest.4309"}
	check(session.quest_command("quest.accept",talk,{"npc":"gsd","nearby":true}).ok,"G.S.D. sends the player to Kiri after the second escort")
	session.npc_met("kiri")
	check(session.quest_command("quest.claim",talk,kiri).ok,"meeting Kiri completes the original follow-up")
	for row: Array in [["original.quest.4310","golemtower",20],["original.quest.4311","darkentrance",22]]:
		var payload := {"id":row[0]}
		session.profile.level=row[2]
		check(session.quest_command("quest.accept",payload,kiri).ok,"the original Sky Tower follow-up becomes available: "+row[0])
		session.command("flow.difficulty",{"id":"adventure"})
		check(session.command("flow.depart",{"dungeon":row[1]}).ok,"the original follow-up dungeon route is selectable: "+row[1])
		session.finish_run(true,{})
		session.command("flow.return")
		check(session.quest_command("quest.claim",payload,kiri).ok,"the Adventure clear can be handed in at Kiri: "+row[0])

func escort_completion_guards() -> void:
	var session := Session.new()
	var quest := "original.quest.4307"
	var dungeon := "draconiantower"
	var gsd := {"npc":"gsd","nearby":true}
	var route: Dictionary = session.dungeons[dungeon].quest_routes[quest]
	var last_index: int = route.rooms.size()-1
	var payload := {"id":quest}
	session.profile.level=16
	check(not session.quest_command("quest.accept",payload,gsd).ok,"escort requires the preceding dragon-eye quest")
	completed(session,"original.quest.4306")
	completed(session,"original.quest.8")
	session.profile.level=15
	check(not session.quest_command("quest.accept",payload,gsd).ok,"escort requires the source level")
	session.profile.level=16
	check(session.quest_command("quest.accept",payload,gsd).ok and not session.quest_command("quest.abandon",payload,gsd).ok,
		"G.S.D. offers the source quest and it cannot be abandoned")
	session.ingest_quest_event({"type":"map.cleared","event_id":"ordinary-cell","dungeon":dungeon,"cell":[0,2],"difficulty":"expert"})
	check(session.quests.status(session.profile,quest)=="active","an ordinary room clear cannot satisfy an escort objective")
	var proof := {"source_map_id":1619,"companions_alive":[201]}
	var final_event := {"type":"combat.room_combat_finished","room_id":"%s:%d" % [dungeon,last_index],
		"room_index":last_index,"final_room":true,"boss":true}
	var invalid := [{}, {"source_map_id":1620,"companions_alive":[201]}, {"source_map_id":1619,"companions_alive":[]},
		{"source_map_id":1619,"companions_alive":[202]}, {"source_map_id":1619,"companions_alive":["201"]},
		proof.merged({"party_size":2}), proof.merged({"room_id":"wrong-room"}), proof.merged({"final_room":false}),
		proof.merged({"boss":false}), proof.merged({"run_id":"expired"})]
	session.command("flow.difficulty",{"id":"expert"})
	for evidence: Dictionary in invalid:
		session.command("flow.depart",{"dungeon":dungeon})
		var event := final_event.merged({"run_id":session.run.id}).merged(evidence,true)
		session.combat_event(event)
		check(session.quests.status(session.profile,quest)=="active","invalid escort proof leaves the quest active: "+str(evidence))
		if session.state=="battle":session.finish_run(false,{})
		session.command("flow.return")
	session.command("flow.depart",{"dungeon":dungeon})
	var valid_event := final_event.merged({"run_id":session.run.id}).merged(proof)
	check(session.combat_event(valid_event).ok and session.quests.status(session.profile,quest)=="ready",
		"exact Hard MAP and living APC evidence unlocks escort turn-in")
	check(not session.combat_event(valid_event).ok,"replaying the final combat event cannot add progress")
	session.command("flow.return")
	var gold: int = session.profile.gold
	check(session.quest_command("quest.claim",payload,gsd).ok and int(session.profile.gold)==gold+5000
		and not session.quest_command("quest.claim",payload,gsd).ok,"the source 5000-gold reward is paid only once at G.S.D.")

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
	check(s.command("flow.depart", {"dungeon":"lorien"}).ok and s.finish_run(true, {}).ok,
		"unrelated dungeon settles through the normal flow")
	check(Inventory.stock(s.profile, "original_3081") == 0 and s.quests.status(s.profile, "original.quest.203") == "active",
		"unrelated victory leaves the Sinda quest active without its hammer")
	s.command("flow.return")
	check(s.command("flow.depart", {"dungeon":"sunderland_dark"}).ok and s.finish_run(false, {}).ok,
		"defeat in the source dungeon settles through the normal flow")
	check(Inventory.stock(s.profile, "original_3081") == 0, "defeat does not award the hammer")
	s.command("flow.return")
	check(s.command("flow.difficulty", {"id":"expert"}).ok and s.command("flow.depart", {"dungeon":"sunderland_dark"}).ok
		and s.finish_run(true, {}).ok, "victory in the source dungeon settles on Expert")
	check(Inventory.stock(s.profile, "original_3081") == 1 and s.quests.status(s.profile, "original.quest.203") == "ready",
		"source dungeon victory awards the hammer and prepares the Sinda hand-in")
	s.command("flow.return")
	check(s.command("flow.depart", {"dungeon":"sunderland_dark"}).ok and s.finish_run(true, {}).ok
		and Inventory.stock(s.profile, "original_3081") == 1, "another source clear respects the holding cap")
	s.command("flow.return")
	check(s.quest_command("quest.claim", {"id":"original.quest.203"}, {"npc":"sinda", "nearby":true}).ok
		and Inventory.stock(s.profile, "original_3081") == 0 and s.quests.has_completed(s.profile, "original.quest.203"),
		"Sinda hand-in consumes the source hammer and completes the quest")

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
	draconian_eyes()
	light_lord_chain()
	escort_completion_guards()
	escort_maze("draconiantower", "original.quest.4307", 201,
		[1618,1602,1620,1603,1609,1610,1604,1619], "monster/draconian/lakius.mob")
	escort_maze("hallofdoll", "original.quest.4308", 202,
		[1819,1821,1805,1811,1812,1813,1808,1803,1802,1820], "monster/dollmaster/masterdogri.mob")

	print("[CAMPAIGN] COMPLETE checks=%d failures=%d" % [checks,failures])
	quit(1 if failures else 0)
