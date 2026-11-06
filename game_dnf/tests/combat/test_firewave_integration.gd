extends SceneTree
const Numbers = preload("res://stats/api/numbers.gd")
const ROOT_PATH := "passiveobject/character/swordman/"
var checks := 0
var failures := 0
var game

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		print("[FIREWAVE] FAIL ",label)

func step(ms: int) -> void:
	for tick in ms:
		game.step_objects(1.0)
		game.view.present(game.view_snapshot(),1.0,1.0)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	game=load("res://scenes/main.tscn").instantiate()
	game.external_mode=true
	game._muted=true
	root.add_child(game)
	game.set_process(false)
	game.set_physics_process(false)
	check(not game.missing_assets,"formal scene loads original firewave dependencies")
	for rank in [1,10]:
		for facing in [1,-1]:
			game.restart()
			game.table.configure_skills({"firewave":rank},"asura","katana")
			var hit: Dictionary=game.move_def("firewave").hits[0]
			var child: Dictionary=hit.native_controller.child
			check(hit.percent==0.0 and hit.fixed==(584.0 if rank==1 else 1129.0),"front fixed original level column")
			check(child.percent==0.0 and child.fixed==(1170.0 if rank==1 else 2257.0),"explosion has independent fixed column")
			check(child.atk_path.ends_with("firewavebigsub.atk") and hit.atk_path.ends_with("firewavebig.atk"),"each phase resolves its own original reaction")
			for phase: Dictionary in [hit,child]:
				check(phase.damage_type=="magical" and phase.element=="fire" and phase.effects.is_empty(),"original magic fire without fabricated burn")
				var formula: Dictionary=Numbers.shared_config().formula
				var a: Dictionary=Numbers.Damage.resolve({"magical_attack":100,"independent_attack":100},{},phase,[0.0,1.0],formula)
				var b: Dictionary=Numbers.Damage.resolve({"magical_attack":9999,"independent_attack":100},{},phase,[0.0,1.0],formula)
				check(a.amount==b.amount and a.trace.percent_part==0,"fixed damage does not consume weapon percentage")
			game.spawn_object(hit,"player",Vector2(350,300),17,facing,1.0)
			var front_id: int=game.objects[0].id
			game.view.present(game.view_snapshot(),0.0,0.0)
			var front=game.view.object_views[front_id]
			var rear=front.get_node("RearAnimation")
			check(rear.z_index==-1 and rear.facing==facing and rear.clock_ms==0,"rear starts with object, mirrored and behind")
			step(419)
			check(game.objects.size()==1 and game.objects[0].pos==Vector2(350,300) and game.objects[0].z==17,"source frame motion does not add world translation")
			check(not rear.is_queued_for_deletion(),"fire rear survives until its original end")
			for tick in 5:game.view.present(game.view_snapshot(),16,0)
			check(rear.clock_ms==419 and front.clock_ms==419,"pause freezes both animation layers")
			step(1)
			check(rear.is_queued_for_deletion() and not front.is_queued_for_deletion(),"rear ends at 420ms independently of front")
			step(69)
			check(game.objects[0].id==front_id,"no explosion before 490ms")
			step(1)
			check(game.objects.size()==1 and game.objects[0].def.path==ROOT_PATH+"firewavebigsub.obj","ANI end replaces front with explosion exactly once")
			var blast: Dictionary=game.objects[0]
			check(blast.pos==Vector2(350+360*facing,300) and blast.z==17 and blast.facing==facing,"successor preserves original XYZ/direction with mirrored 360 offset")
			check(blast.clock==0 and blast.hit.fixed==child.fixed and blast.hit.skill_id=="firewave","successor gets fresh clock and skill provenance")
			check(front.is_queued_for_deletion(),"front view is removed with object")
			var blast_view=game.view.object_views[blast.id]
			var blast_rear=blast_view.get_node("RearAnimation")
			step(349)
			check(not blast_rear.is_queued_for_deletion(),"explosion rear survives to 349ms")
			step(1)
			check(blast_rear.is_queued_for_deletion() and not blast_view.is_queued_for_deletion(),"explosion rear ends at original 350ms")
			step(210)
			check(not blast_view.frame.has("sprite") and game.objects.size()==1,"blank final frame is retained, not replaced by last visible flame")
			step(70)
			check(game.objects.is_empty() and game.view.object_views.is_empty(),"explosion ends at original 630ms without repeating successor")
	game.restart()
	game.spawn_object(game.move_def("firewave").hits[0],"player",Vector2(350,300),0,1,1.0)
	game.step_objects(1000.0)
	check(game.objects.size()==1 and game.objects[0].clock==0,"large update emits one fresh successor")
	game.view.present(game.view_snapshot(),0,0)
	var saved=game.view.object_views.values()[0]
	game.restart()
	check(game.objects.is_empty() and game.view.object_views.is_empty() and saved.is_queued_for_deletion(),"room teardown removes parent and owned rear")
	# Real collision path: one target in front coverage and another at blast origin.
	game.table.configure_skills({"firewave":1},"asura","katana")
	game.numeric_player=preload("res://stats/api/actor_numbers.gd").new()
	game.numeric_player.configure({"numbers":Numbers.shared_config().base})
	game.numeric_player.values.hit=1.0
	var api=preload("res://debug/test_api.gd").new(game)
	var first: Dictionary=api.spawn_dummy(Vector2(450,300))
	var second: Dictionary=game.spawn_enemy(Vector2(710,300))
	second.hp=5000.0
	second.max_hp=5000.0
	second.ai=false
	game.spawn_object(game.move_def("firewave").hits[0],"player",Vector2(350,300),0,1,1.0)
	step(1)
	check(game.hit_count==1 and first.hp<first.max_hp and second.hp==second.max_hp,"front original frame hits near target only")
	step(489)
	check(game.objects.size()==1 and game.objects[0].hits.is_empty(),"blast does not inherit front contact history")
	var before: float=second.hp
	step(70)
	check(second.hp<before,"blast original active frame hits target at successor origin")
	check(not first.numeric.effects.active.has("burn") and not second.numeric.effects.active.has("burn"),"neither phase invents burn status")
	print("[FIREWAVE] COMPLETE checks=",checks," failures=",failures)
	game.queue_free()
	await process_frame
	quit(0 if failures==0 else 1)
