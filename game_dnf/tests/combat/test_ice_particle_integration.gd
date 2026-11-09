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

func particles(suffix := "icewaveparticlesmoke.ptl") -> Array:
	return game.view.effects.filter(func(fx):return is_instance_valid(fx) and not fx.is_queued_for_deletion() and fx is Particle and String(fx.get_meta("source_ptl","")).ends_with(suffix))

func shatter_cues() -> Array:
	return game.bus.events_of("combat.cue").filter(func(e):return e.get("kind","")=="native_particle" and not String(e.path).ends_with("smoke.ptl"))

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
	# Isolate all eight ordinals, both directions and a level-dependent timeline.
	# Observe real bus -> original PTL -> view, not a duplicate cue implementation.
	for facing in [1,-1]:
		for ordinal in range(8):
			game.restart()
			var hit: Dictionary=game.move_def("icewave").hits[0].duplicate(true)
			hit.chain_ordinal=ordinal
			hit.object=hit.native_controller.objects[ordinal%6]
			if ordinal==7:hit.native_controller.frame2_at_ms=430.0
			game.spawn_object(hit,"player",Vector2(350,300),0,facing,1.0)
			var ice: Dictionary=game.objects[0]
			ice.child_spawned=true
			game.bus.clear_history()
			var trigger:=int(ice.timeline[3].start_ms)
			step(trigger-1)
			check(shatter_cues().is_empty(),"no shatter before ANI frame 3")
			step(1)
			var cues:=shatter_cues()
			check(cues.size()==2,"frame 3 emits shards and stars")
			if cues.size()!=2:continue
			check(String(cues[0].path).ends_with("icewaveparticle.ptl") and String(cues[1].path).ends_with("icewaveparticlestar.ptl"),"source shard then star order")
			check(cues[0].height==20+int(ordinal*1.5) and cues[1].height==cues[0].height,"ordinal-dependent original emission height")
			check(cues[0].point==ice.pos and cues[1].point==ice.pos,"both emitters use ice world XY")
			var shards:=particles("icewaveparticle.ptl")
			var stars:=particles("icewaveparticlestar.ptl")
			check(shards.size()==3 and stars.size()==3,"both original maximum_create_number=3 at quality 2")
			for fx in shards+stars:
				check(fx.clock_ms==0.0 and fx.facing==1,"fresh shatter ANI clock and shared emitter facing")
			check(shards.all(func(fx):return is_equal_approx(fx.base_scale,ice.size_rate)),"shards inherit ice image size")
			check(stars.all(func(fx):return fx.base_scale==1.0),"stars keep original image size")
			for tick in 10:game.view.present(game.view_snapshot(),16.0,0.0)
			check((shards+stars).all(func(fx):return fx.clock_ms==0.0),"pause freezes both shatter types")
			step(1)
			check(shatter_cues().size()==2,"DD6 suppresses duplicate emission")
			step(100)
			check(game.objects.is_empty() and not particles("icewaveparticlestar.ptl").is_empty(),"star particles outlive ice independently")
			check(shatter_cues().size()==2,"ANI end does not emit again")
			game.restart()
			check(particles("icewaveparticle.ptl").is_empty() and particles("icewaveparticlestar.ptl").is_empty(),"room teardown removes both shatter types")
	game.restart()
	game.spawn_object(game.move_def("icewave").hits[0],"player",Vector2(350,300),0,1,1.0)
	game.objects[0].child_spawned=true
	game.bus.clear_history()
	game.step_objects(500.0)
	check(game.objects.is_empty() and shatter_cues().size()==2,"large update crossing final frame emits once before disposal")
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
	# Native ANI LOOP controls the successor of the last frame. A view can
	# replay a non-looping bank without interpolating across that boundary.
	smoke.frames[0].items["7"]=[1.0,2.0]
	smoke.frames[1]["delay_ms"]=500
	smoke.frames[1].items["7"]=[3.0,1.0]
	smoke.frames[1].items["10"]=1
	smoke["duration_ms"]=2000
	fx.loop=true
	fx.seek(1750)
	check(fx.frame_scale().is_equal_approx(Vector2(3.0,1.0)),"non-looping source keeps its final scale on a replaying view")
	smoke["loop"]=true
	fx.seek(1750)
	check(fx.frame_scale().is_equal_approx(Vector2(2.0,1.5)),"looping source interpolates from its last frame to its first")
	fx.seek(2000)
	check(fx.frame_scale().is_equal_approx(Vector2(1.0,2.0)),"wrapped view reaches the first scale endpoint")
	fx.queue_free()
	game.queue_free()
	await process_frame
	print("[ICE_PARTICLES] COMPLETE checks=",checks," failures=",failures)
	quit(0 if failures==0 else 1)
