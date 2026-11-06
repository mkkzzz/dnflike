extends SceneTree
## Original CHR records through the public content API; no growth formula claim.
const ContentDB = preload("res://content/api/content_db.gd")
var checks := 0
var failures := 0
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		print("[CHR_GROUPS] FAIL ",label)
func _initialize() -> void:
	var db = ContentDB.new()
	var groups: Dictionary = db.original("character/swordman/swordman.chr","stat_groups")
	check(groups["initial_value"]["hp_max"]==180 and groups["initial_value"]["mp_max"]==140,"initial source group remains intact")
	check(not groups.has("awakening_1") and not groups.has("awakening_2"),"no ambiguous global awakening group")
	for row: Array in [[2,50,20,[91,1]],[3,40,30,[89,1]],[4,55,15,[90,1]],[5,45,25,[92,1]],[6,55,15,[]]]:
		var group: Dictionary = groups["growtype_%d" % int(row[0])]
		check(group.get("awakening_name_refs",[]).size()==4,"two scoped name references per source job")
		for stage: int in [1,2]:
			var data: Dictionary = group.get("awakenings",{}).get("awakening_%d" % stage,{})
			check(data.get("hp_max")==row[1] and data.get("mp_max")==row[2],"job %d awakening %d retains its source values" % [row[0],stage])
			var ids: Array = data.get("awakening_skill",[])
			ids = ids.map(func(value): return int(value))
			var expected: Array = row[3] if stage==1 else []
			check(ids==expected,"job %d awakening %d retains source skill list" % [row[0],stage])
	print("[CHR_GROUPS] COMPLETE checks=%d failures=%d" % [checks,failures])
	quit(1 if failures else 0)
