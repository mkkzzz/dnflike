extends SceneTree
const Catalog = preload("res://quests/catalog.gd")
const Service = preload("res://quests/service.gd")
var checks := 0
var failures := 0
var service = Service.new()

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if ok:print("[QUEST_TEST] PASS " + label)
	else:
		failures += 1
		push_error("[QUEST_TEST] FAIL " + label)

func profile() -> Dictionary:
	var p := {"level":1,"xp":0,"gold":300,"equipped":"iron_sword","inventory":{"iron_sword":1,"potion":3},"quest":"available"}
	service.initialize(p)
	return p

func near(npc: String) -> Dictionary:
	return {"in_town":true,"nearby":true,"npc":npc}

func grant(p: Dictionary, reward: Dictionary, _tx: String) -> Dictionary:
	p["gold"] += int(reward["gold"])
	p["xp"] += int(reward["xp"])
	for item: String in reward["items"]:p["inventory"][item] = int(p["inventory"].get(item, 0)) + int(reward["items"][item])
	return {"ok":true}

func command(p: Dictionary, kind: String, id: String, npc: String) -> Dictionary:
	return service.command(p, kind, {"id":id}, near(npc), grant)

func event(p: Dictionary, type: String, key: String, extra := {}) -> Dictionary:
	var data := {"type":type,"event_id":key}
	data.merge(extra)
	return service.ingest(p, data)

func run() -> void:
	check(service.catalog.errors.is_empty(), "source node definitions validate")
	var p := profile()
	check(service.valid(p), "new profile ledger validates")
	check(service.status(p, "elvengard.meet_linus") == "available" and service.status(p, "lorien.first_clear") == "locked", "source predecessor gates first two tasks")
	check(service.list(p).size() == 18 + preload("res://content/native_catalog.gd").runtime()["quests"].size() + preload("res://content/native_catalog.gd").quest_rules()["quests"].size() and not service.list(p).any(func(q):return q["id"]=="legacy.trial"), "new profile includes compiled original content and hides unstarted legacy adaptation")
	check(not command(p,"quest.accept","elvengard.meet_linus","linus")["ok"], "accepting requires correct giver")
	check(not service.command(p,"quest.accept",{"id":"elvengard.meet_linus"},{"in_town":true,"nearby":false,"npc":"seria"},grant)["ok"], "remote NPC cannot accept task")
	check(command(p,"quest.accept","elvengard.meet_linus","seria")["ok"], "accept source 101 from Seria")
	check(not command(p,"quest.accept","elvengard.meet_linus","seria")["ok"], "duplicate acceptance does not reset task")
	event(p,"npc.met","talk-seria",{"npc":"seria"})
	check(service.status(p,"elvengard.meet_linus") == "active", "wrong conversation does not satisfy visit")
	event(p,"npc.met","talk-linus",{"npc":"linus"})
	check(service.status(p,"elvengard.meet_linus") == "ready", "real target conversation makes task ready")
	check(not command(p,"quest.claim","elvengard.meet_linus","seria")["ok"], "claim requires receiver NPC")
	check(command(p,"quest.claim","elvengard.meet_linus","linus")["ok"] and p["gold"] == 400, "atomic source 101 reward unlocks successor")
	check(not command(p,"quest.claim","elvengard.meet_linus","linus")["ok"] and p["gold"] == 400, "duplicate claim never pays again")
	check(service.status(p,"lorien.first_clear") == "available", "predecessor completes source 102 unlock")
	command(p,"quest.accept","lorien.first_clear","linus")
	event(p,"dungeon.cleared","failed",{"dungeon":"lorien","victory":false})
	event(p,"dungeon.cleared","trial",{"dungeon":"forest_trial","victory":true})
	check(service.status(p,"lorien.first_clear") == "active", "failed or wrong dungeon cannot complete source task")
	event(p,"dungeon.cleared","lorien-win",{"dungeon":"lorien","victory":true})
	check(command(p,"quest.claim","lorien.first_clear","linus")["ok"], "source 102 clears only original Lorien identity")
	check(service.status(p,"lorien.goblin_noise") == "locked", "minimum level gate remains independent of story progress")
	p["level"] = 2
	check(command(p,"quest.accept","lorien.goblin_noise","linus")["ok"], "source 103 opens at level two")
	for i in 10:
		event(p,"combat.monster_defeated","outside-%d" % i,{"monster_id":"monster/goblin/goblin.mob","dungeon":"lorien"})
	check(service.status(p,"lorien.goblin_noise") == "active", "kills in wrong original dungeon do not advance 103")
	for i in 10:
		var data := {"monster_id":"monster/goblin/goblin.mob","dungeon":"lorien_inside"}
		event(p,"combat.monster_defeated","inside-%d" % i,data)
		event(p,"combat.monster_defeated","inside-%d" % i,data)
	var view: Dictionary = service.list(p,["ready"])[0]
	check(view["objectives"][0]["current"] == 10, "ten unique deaths count once despite duplicate delivery")
	var before := JSON.stringify(p)
	check(not service.command(p,"quest.claim",{"id":"lorien.goblin_noise"},near("linus"),func(candidate, _reward, _tx): candidate["gold"] = 0; return {"ok":false,"message":"满包"})["ok"] and JSON.stringify(p) == before, "failed reward adapter cannot leak partial resource changes")
	check(command(p,"quest.claim","lorien.goblin_noise","linus")["ok"], "successful 103 claim follows failed attempt")
	check(command(p,"quest.accept","elvengard.seria_fate","linus")["ok"], "source 4301 accepts from Linus")
	event(p,"npc.met","seria-return",{"npc":"seria"})
	check(command(p,"quest.claim","elvengard.seria_fate","seria")["ok"], "source chain returns to Seria for final handoff")
	check(service.active_count(p) == 0 and service.list(p,["completed"]).size() == 4, "completed chapter releases active and tracking capacity")
	var copy: Dictionary = JSON.parse_string(JSON.stringify(p))
	check(service.valid(copy) and not command(copy,"quest.claim","elvengard.seria_fate","seria")["ok"], "JSON restore preserves completion and reward idempotency")
	copy["quest_state"]["transactions"].clear()
	check(not service.valid(copy), "completed record without reward transaction is rejected")
	var legacy := {"level":2,"gold":900,"inventory":{},"quest":"done"}
	service.initialize(legacy, true)
	check(service.valid(legacy) and service.status(legacy,"legacy.trial") == "completed" and legacy["gold"] == 900, "legacy done migrates without replaying reward")
	check(service.status(legacy,"lorien.first_clear") == "locked", "legacy completion never impersonates original quest 101")
	legacy = {"level":2,"gold":300,"inventory":{},"quest":"ready"}
	service.initialize(legacy, true)
	check(service.status(legacy,"legacy.trial") == "ready", "legacy ready retains deliverable reward separately")
	check(command(legacy,"quest.abandon","legacy.trial","linus")["ok"] and service.status(legacy,"legacy.trial") == "available", "optional legacy task supports explicit abandonment")
	var cfg: Dictionary = service.catalog.config.duplicate(true)
	cfg["quests"][1]["requires"] = ["unknown.task"]
	check(not Catalog.new(cfg).errors.is_empty(), "missing predecessor blocks invalid content")
	cfg = service.catalog.config.duplicate(true)
	cfg["quests"][0]["requires"] = ["lorien.first_clear"]
	check(not Catalog.new(cfg).errors.is_empty(), "cyclic task dependencies are diagnosed")
	cfg = service.catalog.config.duplicate(true)
	cfg["quests"][0]["objectives"][0]["type"] = "unsupported"
	check(not Catalog.new(cfg).errors.is_empty(), "unsupported objective cannot silently become complete")
	check(not service.ingest(p,{"type":"combat.room_combat_finished","event_id":"room"})["ok"], "ordinary room clear is not a task dungeon clear event")
	var fresh := profile()
	command(fresh,"quest.accept","elvengard.meet_linus","seria")
	check(service.command(fresh,"quest.track",{"id":"elvengard.meet_linus"},{"in_town":false})["ok"], "tracking can change during battle without NPC access")
	check(not command(fresh,"quest.abandon","elvengard.meet_linus","seria")["ok"], "mandatory source story cannot be abandoned")
	for key in ["npcs","limits","dungeons"]:
		cfg = service.catalog.config.duplicate(true)
		cfg[key] = []
		check(not Catalog.new(cfg).errors.is_empty(), "malformed registry rejected: " + key)
	cfg = service.catalog.config.duplicate(true)
	cfg["quests"][0]["requires"] = 12
	check(not Catalog.new(cfg).errors.is_empty(), "non-array dependencies do not crash cycle validation")
	cfg = service.catalog.config.duplicate(true)
	var def: Dictionary = cfg["quests"][0]
	def["objectives"] = [{"id":"collect","type":"collect_item","target":"potion","amount":3}]
	def["consume"] = {"potion":3}
	def["reward"]["choices"] = [{"id":"blade","item":"forest_sword","amount":1},{"id":"medicine","item":"potion","amount":2}]
	var collect = Service.new(Catalog.new(cfg))
	fresh = profile()
	collect.command(fresh,"quest.accept",{"id":def["id"]},near("seria"),grant)
	check(collect.status(fresh,def["id"]) == "ready", "collect objective recognizes items held before accepting")
	fresh["inventory"]["potion"] = 2
	check(collect.status(fresh,def["id"]) == "active", "lost material removes derived ready state")
	fresh["inventory"]["potion"] = 3
	before = JSON.stringify(fresh)
	check(not collect.command(fresh,"quest.claim",{"id":def["id"]},near("linus"),grant)["ok"] and before == JSON.stringify(fresh), "missing reward choice cannot consume materials")
	check(collect.command(fresh,"quest.claim",{"id":def["id"],"choice":"blade"},near("linus"),grant)["ok"] and fresh["inventory"]["potion"] == 0 and fresh["inventory"]["forest_sword"] == 1, "chosen item and material consumption commit together")
	print("[QUEST_TEST] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)
