extends SceneTree
const Particle = preload("res://view/native_particle_view.gd")
const Frame = preload("res://view/world_frame.gd")
var checks := 0
var failures := 0
var game

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		print("[ICE_PARTICLES] FAIL ",label)

func particles() -> Array:
	return game.view.effects.filter(func(fx):return is_instance_valid(fx) and not fx.is_queued_for_deletion() and fx is Particle)

func step(ms: int) -> void:
	for tick in ms:
		game.step_objects(1.0)
		if String(game.player.action) != "":game.step_action(1.0,Vector2.ZERO)
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
	check(not game.missing_assets,"formal battle scene loads particle assets")
	game.view.particle_bursts.clock=func():return 1000
	for facing in [1,-1]:
		game.restart()
		game.player.pos=Vector2(350,300)
		game.player.facing=facing
		game.player.mp=500.0
		check(game.start_action("icewave"),"icewave starts in actual action controller")
		step(299)
		check(particles().is_empty(),"no smoke before source release frame")
		step(1)
		check(particles().size()==1,"one smoke generated with first ice")
		var first=particles()[0]
		check(first.clock_ms==0.0,"fresh particle ANI begins at zero on birth tick")
		check(first.data.source.contains("icewaveparticlesmoke"),"820 selects smoke, never star")
		check(is_equal_approx(first.base_scale,1.5),"source DD8 scales ANI")
		check(first.position==Vector2(game.objects[0].pos.x,game.objects[0].pos.y+Frame.MAP_DY),"ice XYZ used without extra FX offset")
		check(first.facing==1,"shared smoke emitter does not inherit caster flip")
		for i in 10:game.view.present(game.view_snapshot(),16.0,0.0)
		check(first.clock_ms==0.0,"simulation pause freezes particle ANI and motion")
		if facing==-1:
			game.end_action_fx()
			game.player.action=""
			game.player.state="idle"
			check(not first.is_queued_for_deletion(),"ending caster action keeps independent smoke")
		step(99)
		check(particles().size()==1,"no second smoke before next ice")
		step(1)
		check(particles().size()==2,"child ice emits its own smoke once")
		check(is_equal_approx(particles()[1].base_scale,1.575),"child smoke uses child's original size")
		step(600)
		check(particles().size()==8,"all eight ice births emit once")
		var last=particles()[-1]
		var last_life:=int(last.playback._motion.config.life_time)
		check(last_life>=940 and last_life<=1060,"native random range 12 varies smoke life by up to six percent")
		check(is_equal_approx(first.frame_color().a,1.0-700.0/1500.0),"source smoke ANI fades within frame")
		step(50)
		check(is_equal_approx(first.frame_color().a,0.5),"original 1500ms opacity endpoints interpolate at midpoint")
		step(330)
		check(game.objects.is_empty() and particles().size()>=6,"smoke outlives parent ice, but expires on its own PTL clock")
		step(last_life-381)
		check(not last.is_queued_for_deletion(),"last smoke survives to one ms before its randomized lifetime")
		step(1)
		check(last.is_queued_for_deletion(),"last smoke expires at its randomized PTL deadline")
		step(1060-last_life)
		check(particles().is_empty(),"all smoke expires within original randomization bounds")
		game.spawn_object(game.move_def("icewave").hits[0],"player",Vector2(350,300),0,1,1.0)
		check(not particles().is_empty(),"fresh object can emit again")
		game.restart()
		check(particles().is_empty(),"room restart clears particles")
	var fx=preload("res://view/fx_view.gd").new()
	root.add_child(fx)
	var smoke: Dictionary=game.combat_assets.effects.native_icewaveparticlesmoke1.duplicate(true)
	fx.hold_last_frame=true
	fx.setup(smoke,1)
	fx.seek(750)
	check(is_equal_approx(fx.frame_color().a,0.5),"shared renderer consumes original opacity endpoints")
	fx.fade=0.4
	check(is_equal_approx(fx.frame_color().a,0.2),"ANI opacity multiplies particle fade only once")
	smoke.frames[0].items["10"]=0
	check(is_equal_approx(fx.frame_color().a,0.4),"disabled interpolation preserves frame color")
	fx.seek(1500)
	check(is_zero_approx(fx.frame_color().a),"zero-duration terminal frame retains transparent endpoint")
	fx.queue_free()
	game.queue_free()
	await process_frame
	print("[ICE_PARTICLES] COMPLETE checks=",checks," failures=",failures)
	quit(0 if failures==0 else 1)
