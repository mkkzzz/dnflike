extends SceneTree
## Real update_numbers -> move-table ranks; source caller evidence is separate.
const Numbers = preload("res://stats/api/numbers.gd")
const Session = preload("res://flow/session.gd")
var checks := 0
var failures := 0

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		print("[GHOST_RANKS] FAIL ",label)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var game = load("res://scenes/main.tscn").instantiate()
	game.external_mode = true
	game._muted = true
	root.add_child(game)
	game.set_process(false)
	game.set_physics_process(false)
	game.restart()
	var session = Session.new()
	session.command("numbers.level",{"level":60})
	var config := Numbers.shared_config()
	var targets := ["hardattack","khazan","saya","bremen","keiga","epidemicrasa","kalla"]
	for scenario in ["absent","zero","learned","ceiling","near_ceiling","disabled","extra_passive_rank"]:
		var levels := {"ghostpowerup":0 if scenario=="disabled" else 5 if scenario=="extra_passive_rank" else 1,"uppercut":3}
		for id: String in targets:
			if scenario=="absent":continue
			levels[id] = 0 if scenario=="zero" else int(config["skills"][id]["max_level"]) if scenario=="ceiling" else int(config["skills"][id]["max_level"])-1 if scenario=="near_ceiling" else 1
		var spec: Dictionary = session.stats()
		spec["skills"] = levels.duplicate(true)
		check(game.update_numbers(spec),scenario+" applies through combat entry")
		for id: String in targets:
			var base := int(levels.get(id,0))
			var expected := base+1 if int(levels["ghostpowerup"])>0 and base>0 and base<int(config["skills"][id]["max_level"]) else base
			check(int(game.skill_levels.get(id,0))==expected,scenario+" "+id+" native eligibility and increment")
			check(int(game.table.skill_levels.get(id,0))==expected,scenario+" "+id+" move table uses effective rank")
		check(game.skill_levels["uppercut"]==3,scenario+" unrelated skill preserved")
		check(spec["skills"]==levels,scenario+" profile input retains purchased ranks")
		var once: Dictionary = game.skill_levels.duplicate(true)
		check(game.update_numbers(spec) and game.skill_levels==once,scenario+" repeated refresh does not accumulate")
	game.queue_free()
	await process_frame
	print("[GHOST_RANKS] COMPLETE checks=",checks," failures=",failures)
	quit(0 if failures==0 else 1)
