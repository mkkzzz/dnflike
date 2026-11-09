extends SceneTree
const Particle = preload("res://view/native_particle_view.gd")
const ROOT := "passiveobject/common/particle/"
const FIRE := ["fireexplosionparticle1","fireexplosionparticle2","fireexplosionparticle3","fireexplosionparticle4"]
const GAS := "poisongas"

var game
var checks := 0
var failures := 0

func check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		print("[CONTINUOUS_PARTICLES] FAIL ",label)

func path(stem: String) -> String:
	return ROOT+stem+".ptl"

func particles(stem: String) -> Array:
	return game.view.effects.filter(func(fx):return is_instance_valid(fx) and not fx.is_queued_for_deletion() and fx is Particle and fx.get_meta("source_ptl","")==path(stem))

func cue(stem: String, index: int) -> void:
	game.bus.emit("combat.cue",{"kind":"native_particle","path":path(stem),"point":Vector2(350+index*5,300),
		"height":60,"mirrored":index%2==1,"scale":1.0+0.1*index})

func step(ms: float, simulation_ms: float) -> void:
	game.view.present(game.view_snapshot(),ms,simulation_ms)

func _initialize() -> void:
	call_deferred("run")

func use_templates() -> bool:
	var templates: Dictionary = game.combat_assets.particles
	var stems: Array = FIRE+[GAS]
	if stems.all(func(stem):return templates.has(path(stem))):return true
	# Original target PVF frequency, count, maximum time, and life. Before the
	# trap banks ship, reuse a compiled ANI only as a display test fixture.
	var timing := [[5,2,0,500],[20,4,0,700],[100,16,0,700],[10,2,0,1000],[100,30,2000,4000]]
	var bank: Dictionary = game.combat_assets.effects.ptl_act6boxparticle01
	templates = templates.duplicate()
	for index in stems.size():
		var values: Array = timing[index]
		templates[path(stems[index])] = {"decoded":{"creation_frequency":values[0],"maximum_create_number":values[1],
			"maximum_create_time":values[2],"life_time":values[3],"object_type":"[animation]",
			"object_entries":[{"path":String(bank.source).to_upper(),"parameter":-1}]}}
	game.view._combat = game.combat_assets.duplicate()
	game.view._combat.particles = templates
	return false

func run() -> void:
	game=load("res://scenes/main.tscn").instantiate()
	game.external_mode=true
	game._muted=true
	root.add_child(game)
	game.set_process(false)
	game.set_physics_process(false)
	game.restart()
	check(not game.missing_assets,"combat scene loads")
	var source_templates := use_templates()
	game.view.particle_bursts.clock=func():return 1000
	seed(42)
	var gameplay_draw := randi()
	seed(42)
	for index in FIRE.size():cue(FIRE[index],index)
	cue(GAS,4)
	check(randi()==gameplay_draw,"view particles use the independent native cosmetic RNG")
	check(game.view._particle_emitters.size()==5,"four independent fire schedulers and one gas scheduler")
	for index in FIRE.size():
		var born := particles(FIRE[index])
		check(born.size()==1,"fire group starts at cue")
		if born.size()==1:
			check(born[0].clock_ms==0 and born[0].facing==(1 if index%2==0 else -1),"fresh animation and cue facing")
			check(is_equal_approx(born[0].base_scale,1.0+index*0.1),"per-emitter scale")
	var initial_gas := particles(GAS)
	check(initial_gas.size()==1,"gas starts at cue")
	if initial_gas.is_empty():
		game.queue_free()
		await process_frame
		quit(1)
		return
	var first_gas: Node = initial_gas[0]
	var draw_count: int = game.view.particle_bursts.random.draws
	step(16,16)
	check(first_gas.clock_ms==0 and game.view._particle_emitters[4].elapsed_ms==0,"birth frame does not advance emitter or particle")
	step(2000,0)
	check(first_gas.clock_ms==0 and game.view.particle_bursts.random.draws==draw_count,"zero simulation time freezes emission, display and RNG")
	step(200,200)
	var fire_counts := [2,4,16,2]
	for index in FIRE.size():
		check(particles(FIRE[index]).size()==fire_counts[index],"original fire count at the longest fire deadline")
	check(game.view._particle_emitters.size()==1 and game.view._particle_emitters[0].path==path(GAS),"last fire batch emits then all four schedulers retire")
	var gas_at_200 := particles(GAS)
	check(gas_at_200.size()==21,"gas survives beyond fire emission")
	if gas_at_200.size()>1:
		var last_gas: Node = gas_at_200[-1]
		check(last_gas.clock_ms==0 and last_gas.playback.advance(0).elapsed_ms>0,"backdated motion begins with fresh ANI frame zero")
	check(first_gas.clock_ms==200,"existing particles advance with simulation")
	for t in range(200,280,10):step(10,10)
	check(particles(GAS).size()==29 and game.view._particle_emitters.size()==1,"gas emits after the fire schedulers finish")
	step(10,10)
	check(particles(GAS).size()==30 and game.view._particle_emitters.is_empty(),"gas count deadline is earlier than its maximum create time")
	step(3709,3709)
	check(not first_gas.is_queued_for_deletion(),"first gas particle survives until its own deadline")
	step(1,1)
	check(first_gas.is_queued_for_deletion() and not particles(GAS).is_empty(),"particle lifetime independent of scheduler end")
	step(290,290)
	check(particles(GAS).is_empty(),"remaining gas particles expire")
	cue(GAS,4)
	var active_gas := particles(GAS)
	check(game.view._particle_emitters.size()==1 and active_gas.size()==1,"new gas cue opens a fresh scheduler")
	game.restart()
	check(game.view._particle_emitters.is_empty() and particles(GAS).is_empty(),"real room reload clears emitters and particles")
	step(500,500)
	check(particles(GAS).is_empty(),"discarded room cannot emit again")
	game.queue_free()
	await process_frame
	print("[CONTINUOUS_PARTICLES] COMPLETE checks=",checks," failures=",failures," original_trap_templates=",source_templates)
	quit(0 if failures==0 else 1)
