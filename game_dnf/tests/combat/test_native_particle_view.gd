extends SceneTree
const Particle = preload("res://view/native_particle_view.gd")
const Fx = preload("res://view/fx_view.gd")
const Motion = preload("res://combat/particles/native_motion.gd")
const Emitter = preload("res://combat/particles/native_emitter.gd")
const Random = preload("res://combat/particles/native_random.gd")
var checks := 0
var failures := 0

func check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		print("[PARTICLE_VIEW] FAIL ", label)

func _initialize() -> void:
	call_deferred("run")

func make_particle(config: Dictionary, bank: Dictionary, age := 0, mirror := false):
	var node = Particle.new()
	root.add_child(node)
	var emission := {"motion":Motion.new(config,Vector3i(200,100,40),mirror,age),
		"entry":{"path":bank.source,"parameter":-1},"object_type":"[animation]"}
	check(node.setup_particle(emission,bank), "native ANI object created")
	return node

func run() -> void:
	# The existing original atlas is used unmodified. Short delays below are an
	# explicit adversarial timing fixture, not a replacement for the source ANI.
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets_local/combat/manifest.json"))
	var source_bank: Dictionary = manifest.effects.ptl_act6boxparticle01
	var bank: Dictionary = source_bank.duplicate(true)
	bank.loop = false
	bank.duration_ms = 100
	bank.frames[0].delay_ms = 40
	bank.frames[1].delay_ms = 60
	var conf := {"life_time":1000,"axes":{"x":{"move_type":"[straight line]","move_variable_1":[100,100]}},"transparent_value":[100,0]}
	var node = make_particle(conf,bank)
	check(node.position==Vector2(200,260) and node.facing==1,"source XYZ uses common world projection")
	node.advance(100)
	check(not node.is_queued_for_deletion() and node.frame.frame==1,"ANI ending does not delete a living particle")
	check(node.position==Vector2(210,260) and is_equal_approx(node.fade,0.9),"motion and fade reach the view")
	node.advance(899)
	check(not node.is_queued_for_deletion(),"alive until native lifetime boundary")
	node.advance(1)
	check(node.is_queued_for_deletion() and not node.visible,"native expiration hides and deletes object")
	var ordinary = Fx.new()
	root.add_child(ordinary);ordinary.setup(bank,1);ordinary.advance(100)
	check(ordinary.is_queued_for_deletion(),"ordinary one-shot FX still ends with ANI")
	var aged = make_particle(conf,bank,500,true)
	check(aged.clock_ms==0 and aged.frame.frame==0,"pre-aged motion starts a fresh ANI")
	check(aged.position.x==150 and aged.facing==-1,"pre-aged mirrored position and sprite")
	aged.advance(40)
	check(aged.frame.frame==1 and aged.playback.advance(0).elapsed_ms==540,"animation and motion retain independent clock origins")
	aged.playback.set_paused(true)
	var point: Vector2=aged.position
	aged.advance(900)
	check(aged.clock_ms==40 and aged.position==point and not aged.is_queued_for_deletion(),"pause freezes both clocks and lifetime")
	aged.playback.set_paused(false);aged.advance(460)
	check(aged.is_queued_for_deletion(),"resume expires at remaining motion lifetime")
	var loop_bank := bank.duplicate(true);loop_bank.loop=true
	var looping=make_particle(conf,loop_bank)
	looping.advance(110)
	check(looping.frame.frame==0 and not looping.is_queued_for_deletion(),"explicit looping ANI wraps while particle remains alive")
	looping.free()
	var landing=make_particle({"life_time":1000,"gravity":1000,"landing_type":"[vanish]"},bank)
	landing.advance(500)
	check(landing.is_queued_for_deletion(),"vanish landing deletes before ANI-independent lifetime")
	var stopped=make_particle({"life_time":1000,"gravity":1000,"landing_type":"[stop]","transparent_value":[100,0]},bank)
	stopped.advance(500);var opacity: float=stopped.fade
	stopped.advance(100)
	check(stopped.position.y==300 and stopped.fade==opacity and not stopped.is_queued_for_deletion(),"stop landing freezes position and motion opacity, keeps object")
	stopped.advance(400)
	check(stopped.is_queued_for_deletion(),"stop landing still expires")
	var invalid=Particle.new();root.add_child(invalid)
	check(not invalid.setup_particle({"object_type":"[passive object]"},bank),"passive objects cannot silently become cosmetic ANI")
	invalid.free()
	invalid=Particle.new();root.add_child(invalid)
	check(not invalid.setup_particle({"object_type":"[animation]","entry":{"path":"wrong.ani","parameter":-1},"motion":Motion.new()},bank),"wrong source bank is rejected")
	invalid.free()
	invalid=Particle.new();root.add_child(invalid)
	var missing_loop:=bank.duplicate(true);missing_loop.erase("loop")
	check(not invalid.setup_particle({"object_type":"[animation]","entry":{"path":bank.source,"parameter":-1},"motion":Motion.new()},missing_loop),"unproven loop setting cannot silently default")
	invalid.free()
	invalid=Particle.new();root.add_child(invalid)
	check(not invalid.setup_particle({"object_type":"[animation]","entry":{"path":bank.source,"parameter":0},"motion":Motion.new()},bank),"indexed image branch needs its own factory")
	invalid.free()
	# Real PTL selection -> exact existing ANI bank -> actual Node2D positions.
	# Original ANI global tag 0 is loop=true for both leaf banks.
	var catalog: Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://assets_local/content/particles.json"))
	var definition: Dictionary=catalog.particles["passiveobject/mapobject/breakableobject/particle/actiontreeloriendamage.ptl"].decoded
	var random=Random.new(42)
	var emitter=Emitter.new(definition,func():return random.next_u31(1000,true),Vector3i(300,100,100))
	var emitted: Dictionary=emitter.emit_at(0)
	check(emitted.ok and emitted.particles.size()==30,"original tree PTL produces selected entries")
	var count := 0
	for emission: Dictionary in emitted.particles:
		var matching: Dictionary={}
		for existing: Dictionary in manifest.effects.values():
			if existing.source==emission.entry.path:matching=existing.duplicate(true);break
		check(matching.get("loop",false),"source tree ANI retains native loop flag")
		var view=Particle.new();root.add_child(view)
		if view.setup_particle(emission,matching):count+=1
		view.advance(70)
		check(view.errors.is_empty() and view.clock_ms==70 and view.frame.frame==1,"source emitter-to-display sample advances")
		view.free()
	check(count==30,"all emitted entries resolve by full original ANI path")
	check(source_bank.loop and source_bank.duration_ms==1000,"shared original bank is not mutated by probes")
	await process_frame
	print("[PARTICLE_VIEW] COMPLETE checks=%d failures=%d"%[checks,failures])
	quit(1 if failures else 0)
