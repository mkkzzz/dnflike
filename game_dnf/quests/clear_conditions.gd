extends RefCounted
## E-PARSE: QST condition-under-clear subtypes 0=time(s),1=received hits,
## 4=no revival,5=min party; subtype6 is unconditional. Never default missing facts.
const LIMITS={"max_elapsed_ms":["elapsed_ms",false],"max_hits_taken":["hits_taken",false],"max_revives":["revives",false],"min_party_size":["party_size",true]}

static func valid(rules) -> bool:
	if not rules is Dictionary:return false
	for key in rules:
		if key not in LIMITS or not finite(rules[key]) or float(rules[key])!=floorf(float(rules[key])):return false
		if key=="min_party_size" and rules[key]<1:return false
	return true

static func finite(value) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and value>=0 and value<=1000000000000

static func matches(rules: Dictionary, facts: Dictionary) -> bool:
	if not valid(rules):return false
	for key: String in rules:
		var field: String=LIMITS[key][0]
		if not finite(facts.get(field)):return false
		if LIMITS[key][1]:
			if facts[field]<rules[key]:return false
		elif facts[field]>rules[key]:return false
	return true

static func initialize(run: Dictionary) -> void:
	if not run.has("quest_facts"):run["quest_facts"]={"hits_taken":0,"seen":{}}

static func damage(run: Dictionary, event: Dictionary) -> void:
	if event.get("run_id")!=run.get("id") or event.get("type")!="combat.damage" or not event.has("event_id"):return
	if event.get("victim")!="player" or not finite(event.get("amount")) or float(event["amount"])<=0 or event.get("missed",false):return
	if not run.has("quest_facts"):return # An old run has no complete observation history.
	if not finite(event["event_id"]) or float(event["event_id"])!=floorf(float(event["event_id"])):return
	var key:=str(int(event["event_id"]))
	if key.is_empty() or run["quest_facts"]["seen"].has(key):return
	run["quest_facts"]["seen"][key]=true
	run["quest_facts"]["hits_taken"]=int(run["quest_facts"]["hits_taken"])+1

static func valid_run(run: Dictionary) -> bool:
	if not run.has("quest_facts"):return true
	var state=run["quest_facts"]
	if not state is Dictionary or not finite(state.get("hits_taken")) or not state.get("seen") is Dictionary:return false
	if float(state["hits_taken"])!=floorf(float(state["hits_taken"])) or int(state["hits_taken"])!=state["seen"].size():return false
	for key in state["seen"]:
		if not key is String or not key.is_valid_int() or str(int(key))!=key or int(key)<0 or state["seen"][key]!=true:return false
	return true

static func facts(run: Dictionary, details: Dictionary) -> Dictionary:
	var result: Dictionary={"party_size":1} # Current host is explicitly single-player.
	if finite(details.get("elapsed_ms")):result["elapsed_ms"]=details["elapsed_ms"]
	if run.has("quest_facts"):result["hits_taken"]=run["quest_facts"]["hits_taken"]
	if run.has("recovery"):result["revives"]=run["recovery"]["revives"]
	return result
