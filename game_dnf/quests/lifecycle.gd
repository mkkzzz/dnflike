extends RefCounted
## Repeat/daily rounds own unique reward receipts. Old once-only receipts stay intact.
## Calendar policy E-ADAPT: configurable UTC offset and reset hour, default UTC+8 00:00.
static func whole(value, low: int, high: int) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and value==floorf(float(value)) and value>=low and value<=high

static func day(ledger: Dictionary, seconds: float, calendar: Dictionary) -> int:
	var current:=int(floor((seconds+int(calendar.get("utc_offset_minutes",480))*60-int(calendar.get("reset_hour",0))*3600)/86400.0))
	return maxi(int(ledger.get("calendar_day",0)),current)

static func repeating(q: Dictionary) -> bool:return q.get("lifecycle","once") in ["repeat","daily"]

static func completed(ledger: Dictionary, id: String) -> bool:
	return int(ledger.get("cycles",{}).get(id,{}).get("completions",0))>0 or ledger["entries"].get(id,{}).get("state")=="completed"

static func can_claim(ledger: Dictionary, q: Dictionary, today: int) -> bool:
	return q.get("lifecycle")!="daily" or int(ledger.get("cycles",{}).get(q["id"],{}).get("last_day",-1))<today

static func tx(id: String, entry: Dictionary) -> String:
	return "quest:"+id+":cycle:"+str(int(entry["cycle"])) if entry.has("cycle") else "quest:"+id+":once"

static func begin(ledger: Dictionary, q: Dictionary, entry: Dictionary, today: int) -> void:
	if not repeating(q):return
	if not ledger.has("cycles"):ledger["cycles"]={}
	if not ledger["cycles"].has(q["id"]):ledger["cycles"][q["id"]]={"next":1,"completions":0,"last_day":-1}
	var row: Dictionary=ledger["cycles"][q["id"]]
	entry["cycle"]=int(row["next"]);row["next"]=int(row["next"])+1
	ledger["calendar_day"]=today

static func finish(ledger: Dictionary, q: Dictionary, today: int) -> void:
	if not repeating(q):return
	var row: Dictionary=ledger["cycles"][q["id"]]
	row["completions"]=int(row["completions"])+1;row["last_day"]=today
	ledger["calendar_day"]=today

static func valid(ledger: Dictionary) -> bool:
	if ledger.has("calendar_day") and not whole(ledger["calendar_day"],0,10000000):return false
	var cycles=ledger.get("cycles",{})
	if not cycles is Dictionary:return false
	for id in cycles:
		if not id is String or not cycles[id] is Dictionary:return false
		var row: Dictionary=cycles[id]
		if not whole(row.get("next"),1,1000000000) or not whole(row.get("completions"),0,int(row.get("next",0))-1) or not whole(row.get("last_day"),-1,int(ledger.get("calendar_day",0))):return false
		if (row["completions"]==0)!=(row["last_day"]==-1):return false
		var receipts:=0;var prefix: String="quest:"+id+":cycle:"
		for key in ledger["transactions"]:
			if not key is String:return false
			if not key.begins_with(prefix):continue
			var serial: String=key.trim_prefix(prefix)
			if not serial.is_valid_int() or str(int(serial))!=serial or int(serial)<1 or int(serial)>=int(row["next"]):return false
			receipts+=1
		if receipts!=int(row["completions"]):return false
	for id in ledger["entries"]:
		var entry=ledger["entries"][id]
		if not entry is Dictionary:return false
		if entry.has("cycle"):
			if not cycles.has(id) or not whole(entry["cycle"],1,int(cycles[id]["next"])-1):return false
	return true
