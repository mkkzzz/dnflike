extends SceneTree
const Emitter = preload("res://combat/particles/native_emitter.gd")
const Random = preload("res://combat/particles/native_random.gd")
const Motion = preload("res://combat/particles/native_motion.gd")
var checks := 0
var failures := 0
var draws := 0
var scripted: Array = []

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("[PARTICLE_EMITTER] FAIL " + label)

func draw() -> int:
	var value := int(scripted[draws % scripted.size()]) if not scripted.is_empty() else 0
	draws += 1
	return value

func definition(frequency := -1.0, number := 3) -> Dictionary:
	return {"creation_frequency": frequency, "maximum_create_number": number,
		"object_entries": [{"path": "a.ani", "parameter": -1}, {"path": "b.ani", "parameter": -1}]}

func _initialize() -> void:
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/native_particle_random.json"))
	for row: Dictionary in fixture.cases:
		var rng = Random.new(int(row.seed))
		check(rng.next_u31(int(row.clock), row.global_form) == int(row.value), "native random return " + str(row.seed))
		check(rng.state == int(row.state), "native random state " + str(row.seed))

	var emitter = Emitter.new(definition(), draw)
	check(emitter.emit_at(0).particles.size() == 3 and emitter.finished, "burst creates maximum count once")
	check(emitter.emit_at(1).particles.is_empty(), "burst cannot repeat without reset")
	emitter.reset(Vector3i.ZERO)
	check(emitter.emit_at(0).particles.size() == 3, "reset restores burst")
	var quality_def := definition()
	quality_def["display_effect_rate"] = [30, 60, 100]
	emitter = Emitter.new(quality_def, draw)
	emitter.global_effect_scale = 0.5
	check(emitter.emit_at(0).particles.size() == 1, "burst quality is capped at medium when global scale is not one")
	emitter = Emitter.new(quality_def, draw)
	emitter.quality = 0
	check(emitter.emit_at(0).particles.is_empty() and emitter.finished, "fractional burst count truncates")
	quality_def.display_effect_rate = [0, 60, 100]
	emitter = Emitter.new(quality_def, draw)
	emitter.quality = 0
	check(emitter.emit_at(0).particles.is_empty() and not emitter.finished, "zero display rate does not consume burst")
	emitter.quality = 2
	check(emitter.emit_at(0).particles.size() == 3, "reenabled display still permits burst")
	check(Emitter.new(definition(0.0), draw).emit_at(0).finished, "zero frequency finishes without generation")
	var positioned := definition(-1.0, 1)
	positioned.creation_pos = [4, 5, 6]
	check(Emitter.new(positioned, draw).emit_at(0).particles[0].motion.origin == Vector3i(4, 5, 6), "template creation position is retained without an explicit setter")
	check(Emitter.new(positioned, draw, Vector3i.ZERO).emit_at(0).particles[0].motion.origin == Vector3i.ZERO, "explicit position replaces template creation position")

	emitter = Emitter.new(definition(10.0, 4), draw)
	for time in [0, 100, 200, 300]:
		check(emitter.emit_at(time).particles.size() == 1, "continuous initial particle and count deadline " + str(time))
	check(emitter.finished and emitter.emit_at(400).particles.is_empty(), "maximum count deadline ends continuous emission")
	emitter = Emitter.new(definition(10.0, 1), draw)
	check(emitter.emit_at(0).particles.size() == 1 and emitter.emit_at(100).particles.size() == 1 and not emitter.finished, "native max count one gives zero deadline sentinel")
	emitter = Emitter.new(definition(2.0, 0), draw)
	emitter.emit_at(0)
	for time in [100, 200, 300, 400]:
		check(emitter.emit_at(time).particles.is_empty(), "fractional accumulator waits " + str(time))
	check(emitter.emit_at(500).particles.size() == 1, "fractional accumulator is retained across calls")
	emitter = Emitter.new(definition(1000.0, 0), draw)
	emitter.emit_at(0)
	var burst: Dictionary = emitter.emit_at(1000)
	check(burst.particles.size() == 50, "per-call ceiling is fifty")
	check(burst.particles[0].initial_age_ms == 0 and burst.particles[-1].initial_age_ms == 980, "batch ages span capped count")
	check(emitter.emit_at(1001).particles.size() == 1, "clipped excess is discarded rather than deferred")
	var timed := definition(10.0, 0)
	timed.maximum_create_time = 501
	emitter = Emitter.new(timed, draw)
	emitter.emit_at(0)
	check(emitter.emit_at(1000).particles.size() == 5 and emitter.finished, "maximum time uses native minus-one deadline")
	timed = definition(1000.0, 0)
	timed.life_time = 100
	emitter = Emitter.new(timed, draw)
	emitter.emit_at(0)
	check(emitter.emit_at(1000).particles.size() == 5, "expired batch ages are filtered before instance preparation")
	check(not emitter.emit_at(999).ok, "emitter clock reversal is explicit")

	var ordered := definition()
	ordered.how_to_create_object = "[in order]"
	emitter = Emitter.new(ordered, draw)
	var particles: Array = emitter.emit_at(0).particles
	check(particles.map(func(p): return p.entry.path) == ["a.ani", "b.ani", "b.ani"], "in-order selection repeats the last entry")
	var placed := definition(-1.0, 2)
	placed.create_area_size = [2, 0, 0]
	scripted = [0, 0, 1, 1]
	draws = 0
	particles = Emitter.new(placed, draw).emit_at(0).particles
	check(particles[0].motion.origin.x == -1 and particles[1].motion.origin.x == -1, "prepare all positions before object selection")
	check(particles[0].entry.path == "b.ani" and particles[1].entry.path == "b.ani" and draws == 4, "selection consumes the subsequent random draws")
	scripted = []
	placed.create_area_size = [20, 20, 20]
	check(Emitter.new(placed, draw, Vector3i(100, 100, 100), true).emit_at(0).particles[0].motion.origin == Vector3i(110, 98, 90), "area uses integer projection and mirrored X")
	placed = definition(10.0, 0)
	placed.create_area_size = [20, 20, 20]
	placed.create_pos_correct = 1
	emitter = Emitter.new(placed, draw)
	emitter.emit_at(0)
	emitter.origin = Vector3i(100, 0, 0)
	particles = emitter.emit_at(1000).particles
	check(particles.size() == 10 and particles[0].motion.origin == Vector3i(10, -2, -10) and particles[-1].motion.origin == Vector3i(100, -2, -10), "moving-emitter correction replaces only changed axes")

	var varied := definition(-1.0, 1)
	varied.axes = {"x": {"move_type": "[straight line]", "move_variable_1": [40, 20]},
		"y": {"move_type": "[sin]", "move_variable_1": [50, 30], "move_variable_2": [1000, 500]},
		"z": {"move_type": "[cos]", "move_variable_1": [10, 20], "move_variable_2": [200, 400]}}
	varied.random_range = 100
	varied.changing_term = 1000
	varied.life_time = 1000
	draws = 0
	particles = Emitter.new(varied, draw, Vector3i(0, 0, 100)).emit_at(0).particles
	var prepared: Dictionary = particles[0].motion.config
	check(prepared.axes.x.move_variable_1 == [20, 10], "straight endpoints share their axis random factor")
	check(prepared.axes.y.move_variable_1 == [25, 15] and prepared.axes.z.move_variable_1 == [5, 10], "sin/cos axes share amplitude random factor")
	check(prepared.axes.y.move_variable_2 == [500, 250] and prepared.axes.z.move_variable_2 == [100, 200], "sin/cos periods share their separate random factor")
	check(prepared.changing_term == 500 and prepared.life_time == 500 and draws == 6, "term/lifetime draw order and independent scaling")
	check(varied.axes.x.move_variable_1 == [40, 20], "preparation does not mutate the shared definition")
	varied = definition(-1.0, 1)
	varied.random_range = 200
	varied.life_time = 1
	check(Emitter.new(varied, draw).emit_at(0).particles[0].motion.config.life_time == 1, "randomized nonzero lifetime is at least one")
	varied.rotation_angle_range_type = "[circle]"
	varied.rotation_angle_variable = [0, 0]
	varied.rotation_angle = [0, 96, 12]
	check(Emitter.new(varied, draw).emit_at(0).particles[0].motion.config.rotation_angle == [0, 96, 90], "circle overwrites third angle even with zero cone width")
	check(Emitter.cone_angle(90, 0) == 0 and Emitter.cone_angle(90, Emitter.cone_cumulative[90]) == 90, "cone lookup lower-bound endpoints")
	check(Emitter.cone_cumulative[1] == 17 and Emitter.cone_cumulative[2] == 51, "native cumulative sine table truncates each addition")

	var preaged := {"axes": {"z": {"move_type": "[cos]", "move_variable_1": [-10, -10], "move_variable_2": [1000, 1000]}}, "landing_type": "[vanish]"}
	var particle = Motion.new(preaged, Vector3i(0, 0, 5), false, 500)
	check(particle.alive and particle.position.z == 15, "pre-aged reset must not evaluate an earlier vanishing position")
	particle = Motion.new({"life_time": 100}, Vector3i.ZERO, false, 500)
	check(not particle.alive and particle.elapsed_ms == 100, "reset clamps initial age to randomized lifetime")

	var catalog: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets_local/content/particles.json"))
	for name in ["icewaveparticlestar", "icewaveparticle", "icewaveparticlesmoke"]:
		var original: Dictionary = catalog.particles["passiveobject/character/swordman/particle/" + name + ".ptl"].decoded
		var rng = Random.new(42)
		emitter = Emitter.new(original, func(): return rng.next_u31(1000, true), Vector3i(200, 300, 20))
		var emitted: Dictionary = emitter.emit_at(0)
		check(emitted.ok and emitted.particles.size() == int(original.maximum_create_number), "original ice PTL emission " + name)
		for child: Dictionary in emitted.particles:
			check(child.motion.advance_to(100).ok and original.object_entries.has(child.entry), "original particle moves and retains an original object entry " + name)
	print("[PARTICLE_EMITTER] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)
