extends SceneTree
## ws1-owned GM panel command and category contract.
const Loop = preload("res://flow/loop_root.gd")
const Numbers = preload("res://stats/api/numbers.gd")

var game
var checks := 0
var failures := 0
var capture_dir := ""

func _initialize() -> void:
	var args:=OS.get_cmdline_user_args()
	var capture:="--capture" in args
	if capture:
		capture_dir=String(args[args.find("--output")+1]) if args.find("--output")>=0 and args.find("--output")+1<args.size() else ""
		if OS.get_environment("DNF_PRIVATE_DESKTOP")!="1" or DisplayServer.get_name()=="headless" or capture_dir=="":
			push_error("[WS1_GM] capture requires the private desktop and --output")
			quit(1)
			return
	elif DisplayServer.get_name() != "headless":
		push_error("[WS1_GM] headless display required")
		quit(1)
		return
	call_deferred("run")

func check(value: bool, message: String) -> void:
	checks += 1
	if value:
		print("[WS1_GM] PASS " + message)
	else:
		failures += 1
		push_error("[WS1_GM] FAIL " + message)

func frames(count := 3) -> void:
	for _index in count:
		await process_frame

func setup_game() -> void:
	game = Loop.new()
	root.add_child(game)
	await frames(4)
	var unique := Crypto.new().generate_random_bytes(8).hex_encode()
	game.test_mode = true
	game.store.path = "res://../temp/ws1_gm_tests/profile_" + unique + ".json"
	game.characters.directory = "res://../temp/ws1_gm_tests/characters_" + unique
	game.characters.legacy_path = "res://../temp/ws1_gm_tests/legacy_" + unique + ".json"
	game.session = game.Session.new()
	game.session.profile["name"] = "GM契约剑士"
	game.session.profile["town_location"] = "elvengard"
	game.session.profile["town_position"] = [445.0,222.0]
	check(game.store.write(game.session),"disposable GM character is written")
	check(game.enter_character(game.store.path),"disposable GM character enters the formal flow")
	await frames(5)
	game.ui_audio.muted = true
	game.town.set_voice_enabled(false)
	game.town.stop_npc_voices(true)

func execute(command: String) -> Dictionary:
	var response: Dictionary=game.debug_panel.commands.execute(command)
	check(response.get("ok",false),command+" executes: "+String(response.get("message","")))
	return response

func session_valid(label: String) -> bool:
	var verifier=game.Session.new()
	var valid: bool=verifier.restore(game.session.serialize())
	check(valid,label+" leaves a restorable session")
	return valid

func panel_contract() -> void:
	game.set_debug_open(true)
	await frames(3)
	check(game.debug_panel.category_bar.get_child_count()==6,"GM panel exposes six test categories")
	check(game.debug_panel.status_label.position.y+game.debug_panel.status_label.size.y \
		<=game.debug_panel.log_view.position.y,"GM status block stays clear of the command log")
	var ids: Array[String] = []
	for node in game.debug_panel.category_bar.get_children():
		if not node.is_queued_for_deletion():ids.append(String(node.get_meta("gm_category","")))
	check(ids == ["role","skill","gear","dungeon","quest","combat"],"GM categories keep the planned order")
	check(game.debug_panel.reveal_command("gear kit 100"),"command discovery reveals the gear category")
	await frames(2)
	check(game.debug_panel.active_category=="gear","command discovery activates the owning category")
	var found := false
	for node in game.debug_panel.action_bar.get_children():
		if not node.is_queued_for_deletion() and String(node.get_meta("gm_command",""))=="gear kit 100":found=true
	check(found,"gear kit is exposed as a real quick action")
	game.debug_panel.active_category="role"
	game.debug_panel._refresh_categories()
	game.debug_panel._refresh_actions()

func progression_contract() -> void:
	execute("level 18")
	check(int(game.session.profile["level"])==18,"level preset changes the real profile")
	execute("job soulbringer")
	check(String(game.session.profile["growtype"])=="soulbringer","job command force-switches the current class")
	execute("awakening 1")
	check(int(game.session.profile["awakening_stage"])==1,"awakening command commits the source stage field")
	execute("level 60")
	execute("sp 1000")
	check(int(game.session.profile["sp_bonus"])==1000,"SP GM transaction is saved")
	session_valid("progression category")

func skill_contract() -> void:
	var listed: Dictionary=execute("skill list current")
	check(String(listed["message"]).contains("/") and String(listed["message"]).contains("鬼斩"),
		"current class skill list exposes ids and ranks")
	execute("skill maxjob active")
	check(int(game.session.profile["skills"].get("upper",0))==int(Numbers.shared_config()["skills"]["upper"]["max_level"]),
		"current-class active skills reach their source maximum")
	check(Numbers.valid(game.session.profile),"batch skill grant keeps the numeric profile valid")
	execute("skill reset")
	check(int(game.session.profile["skills"]["upper"])==int(Numbers.shared_config()["skill_defaults"]["upper"]),
		"skill reset restores configured defaults")
	session_valid("skill category")

func equipment_contract() -> void:
	execute("gear kit 100")
	session_valid("gear kit")
	check(game.session.profile["equipment"].size()>=5,"gear kit equips the available current-level slots")
	var listed: Dictionary=execute("gear list")
	check(String(listed["message"]).contains("品质"),"gear list is human-readable instead of raw JSON")
	var uids: Array=game.session.profile["gear"].keys()
	check(not uids.is_empty(),"gear kit creates real equipment instances")
	execute("gear breakall")
	session_valid("gear breakall")
	var all_broken: bool = game.session.profile["gear"].values().all(func(instance):return int(instance["durability"])==0)
	check(all_broken,"breakall sets every instance durability to zero")
	execute("gear repairall")
	session_valid("gear repairall")
	var all_repaired: bool = game.session.profile["gear"].values().all(func(instance):return int(instance["durability"])==int(instance["durability_max"]))
	check(all_repaired,"repairall restores every instance")
	execute("gear reinforceall 10")
	session_valid("gear reinforceall")
	check(game.session.profile["gear"].values().all(func(instance):return int(instance["reinforce"])==10),
		"reinforceall applies the requested test level")
	execute("gear unequipall")
	session_valid("gear unequipall")
	check(game.session.profile["equipment"].is_empty() and String(game.session.profile["equipped"]).is_empty(),
		"unequipall clears all equipped slots")
	var catalog: Dictionary=execute("gear catalog weapon")
	check(String(catalog["message"]).contains("weapon"),"gear catalog filters the current-level weapon definitions")
	execute("gear best weapon")
	check(String(game.session.profile["equipment"].get("weapon",""))!="",
		"gear best equips the strongest available weapon in one command")
	session_valid("equipment category")

func dungeon_contract() -> void:
	execute("difficulty expert")
	check(String(game.session.profile["difficulty"])=="expert","difficulty command updates the next run")
	var listed: Dictionary=execute("dungeon list")
	check(String(listed["message"]).contains("lorien"),"dungeon list exposes stable dungeon ids")
	execute("dungeon enter lorien")
	check(game.session.state=="battle" and String(game.session.run["dungeon"])=="lorien",
		"dungeon enter can select and start a known dungeon")
	var before_spawn: int=int(game.combat.read_view()["alive_monsters"])
	execute("spawn current 2")
	check(int(game.combat.read_view()["alive_monsters"])==before_spawn+2,
		"spawn current uses the current room monster table")
	execute("god on")
	execute("heal")
	check(game.combat.read_view()["hp"]==game.combat.read_view()["hp_max"],"combat GM still heals the live actor")
	execute("town")
	check(game.session.state=="town","town command returns from the test dungeon")
	session_valid("dungeon category")

func quest_contract() -> void:
	var definitions: Dictionary=game.session.quests.catalog.definitions
	var available: Array=game.session.quests.list(game.session.profile,["available"])
	var quest: Dictionary={}
	for candidate: Dictionary in available:
		if not definitions[candidate["id"]].get("auto_accept",false) and not definitions[candidate["id"]].get("auto_complete",false):
			quest=candidate
			break
	check(not quest.is_empty(),"fixture finds a manually controllable available quest")
	if quest.is_empty():return
	var id := String(quest["id"])
	var info: Dictionary=execute("quest info "+id)
	check(String(info["message"]).contains("目标"),"quest info exposes objectives")
	execute("quest accept "+id)
	check(game.session.quests.status(game.session.profile,id) in ["active","ready"],
		"GM proximity can accept an available quest through the real task transaction")
	execute("quest ready "+id)
	check(game.session.quests.status(game.session.profile,id)=="ready",
		"quest ready completes testable objectives and supplied materials")
	execute("quest claim "+id)
	check(game.session.quests.status(game.session.profile,id)=="completed",
		"quest claim pays the real reward transaction")
	var next: Dictionary={}
	for candidate: Dictionary in game.session.quests.list(game.session.profile,["available"]):
		if not definitions[candidate["id"]].get("auto_accept",false) and not definitions[candidate["id"]].get("auto_complete",false):
			next=candidate
			break
	if not next.is_empty():
		var next_id := String(next["id"])
		execute("quest accept "+next_id)
		execute("quest readyall")
		check(game.session.quests.status(game.session.profile,next_id)=="ready",
			"quest readyall prepares every active testable quest")
		execute("quest claim "+next_id)
		check(game.session.quests.status(game.session.profile,next_id)=="completed",
			"readyall result can be delivered normally")
	var current: Dictionary=game.debug_panel.commands.execute("quest current")
	check(not String(current["message"]).is_empty(),"quest current returns either active work or an explicit empty state")
	session_valid("quest category")

func persistence_contract() -> void:
	check(Numbers.valid(game.session.profile) and game.session.quests.valid(game.session.profile),
		"GM edits keep numeric and quest ledgers valid")
	var verifier=game.Session.new()
	var live_restore: bool=verifier.restore(game.session.serialize())
	check(live_restore,"complete live session passes the published restore validator")
	var loaded=game.Session.new()
	var restored: bool=game.store.read_into(loaded)
	if restored and loaded.profile!=game.session.profile:
		for key in game.session.profile:
			if loaded.profile.get(key)!=game.session.profile[key]:
				print("[WS1_GM] DIFF %s live=%s loaded=%s" % [key,
					JSON.stringify(game.session.profile[key]," "),JSON.stringify(loaded.profile.get(key)," ")])
	check(restored and loaded.profile==game.session.profile,
		"GM category operations round-trip through disk")

func capture_frame(name: String, scale_factor: int) -> void:
	if capture_dir=="":return
	root.min_size=Vector2i(1,1)
	root.max_size=Vector2i(8192,8192)
	root.content_scale_size=Vector2i(800,600)*scale_factor
	root.content_scale_mode=Window.CONTENT_SCALE_MODE_VIEWPORT
	root.size=root.content_scale_size
	game.transform=Transform2D(0.0,Vector2.ONE*scale_factor,0.0,Vector2.ZERO)
	(game.ui.get_parent() as CanvasLayer).transform=Transform2D(0.0,Vector2.ONE*scale_factor,0.0,Vector2.ZERO)
	await frames(3)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(capture_dir))
	var path:=capture_dir.path_join(name+".png")
	var image:=root.get_texture().get_image()
	var error:=image.save_png(path)
	check(error==OK and image.get_size()==Vector2i(800,600)*scale_factor,
		"capture %s writes actual %dx%d pixels" % [name,image.get_width(),image.get_height()])
	var colored:=0
	for y in range(0,image.get_height(),20):
		for x in range(0,image.get_width(),20):
			if not image.get_pixel(x,y).is_equal_approx(Color.BLACK):colored+=1
	check(colored>100,"capture %s contains a nonblank GM panel" % name)
	if error==OK:print("[WS1_GM] CAPTURE "+path)

func capture_contract() -> void:
	if capture_dir=="":return
	game.debug_panel.active_category="role"
	game.debug_panel._refresh_categories()
	game.debug_panel._refresh_actions()
	await capture_frame("gm_role_1x",1)
	await capture_frame("gm_role_2x",2)
	root.min_size=Vector2i(1,1)
	root.max_size=Vector2i(8192,8192)
	root.content_scale_size=Vector2i(800,600)
	root.size=Vector2i(800,600)
	game.transform=Transform2D.IDENTITY
	(game.ui.get_parent() as CanvasLayer).transform=Transform2D.IDENTITY
	await frames(2)

func run() -> void:
	await setup_game()
	await panel_contract()
	await capture_contract()
	await progression_contract()
	await skill_contract()
	await equipment_contract()
	await dungeon_contract()
	await quest_contract()
	await persistence_contract()
	finish()

func finish() -> void:
	var code:=1 if failures else 0
	print("[WS1_GM] COMPLETE checks=%d failures=%d" % [checks,failures])
	if is_instance_valid(game):
		game.queue_free()
		await process_frame
	quit(code)
