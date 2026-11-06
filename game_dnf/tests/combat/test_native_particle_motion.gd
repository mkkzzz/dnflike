extends SceneTree
const Motion = preload("res://combat/particles/native_motion.gd")
var checks := 0
var failures := 0

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("[PARTICLE_MOTION] FAIL " + label)

func _initialize() -> void:
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/native_particle_axis.json"))
	check(fixture.engine_sha256 == "187ad34ab6bfff040d9b12bb145bdda0bba29f82aaa41183280b0ae42e914b84", "native source identity")
	check(fixture.cases.size() == 241, "all native branch samples are present")
	for row: Dictionary in fixture.cases:
		var input: Dictionary = row.input
		var axis := {"move_type": Motion.MOVES[int(input.move)], "move_variable_1": input.v1, "move_variable_2": input.v2}
		var actual: float = Motion.axis_displacement(axis, int(input.time), int(input.term), Motion.CHANGES[int(input.change)])
		var bytes := PackedByteArray()
		bytes.resize(4)
		bytes.encode_float(0, actual)
		var exact := "%08x" % bytes.decode_u32(0)
		check(exact == row.bits, "native axis " + str(input) + " expected=" + row.bits + " actual=" + exact)

	var moving := {"axes": {}, "gravity": 100, "life_time": 2000, "transparent_value": [100, 0]}
	for axis in ["x", "y", "z"]:
		moving.axes[axis] = {"move_type": "[straight line]", "move_variable_1": [10, 10]}
	var motion = Motion.new(moving, Vector3i(100, 200, 100))
	var sample: Dictionary = motion.advance_to(1000)
	check(sample.position == Vector3i(110, 202, 60), "integer XYZ, native 29 percent depth, then gravity")
	check(sample.alpha == 50.0 and sample.alive, "life-relative transparency")
	var mirror = Motion.new(moving, Vector3i(100, 200, 100), true)
	check(mirror.advance_to(1000).position == Vector3i(90, 202, 60), "mirror affects X only")
	var sliced = Motion.new(moving, Vector3i(100, 200, 100))
	for time in [1, 17, 250, 600, 1000]:
		sliced.advance_to(time)
	check(sliced.snapshot() == sample, "absolute-time motion is independent of tick subdivision")
	check(not motion.advance_to(999).ok, "clock reversal rejected")
	motion.paused = true
	check(motion.advance_to(1500) == sample, "paused instance retains clock and all fields")
	motion.paused = false
	check(motion.advance_to(1999).alive and not motion.advance_to(2000).alive, "strict lifetime boundary")

	for landing in Motion.LANDINGS:
		var config := {"axes": {"x": {"move_type": "[straight line]", "move_variable_1": [10, 10]}},
			"gravity": 100, "landing_type": landing, "life_time": 2000, "transparent_value": [100, 0]}
		var particle = Motion.new(config, Vector3i(0, 0, 10))
		var first: Dictionary = particle.advance_to(1000)
		check(first.position.z == (0 if landing in ["[slide]", "[stop]"] else -40), "landing height " + landing)
		check(first.alive == (landing != "[vanish]"), "landing survival " + landing)
		var second: Dictionary = particle.advance_to(1500)
		check(second.position.x == (10 if landing == "[stop]" else 15), "stop freezes all coordinates; slide continues " + landing)
		check(second.alpha == (50.0 if landing == "[stop]" else 25.0), "native stopped alpha early return " + landing)
		check(not particle.advance_to(2000).alive, "stopped particles still expire " + landing)

	var rotating := {"axes": {"x": {"move_type": "[straight line]", "move_variable_1": [10, 10]}}, "rotation_angle": [0, 30, 0]}
	check(Motion.new(rotating, Vector3i(0, 0, 100)).advance_to(1000).position == Vector3i(8, 0, 105), "native XZ rotation before coordinate truncation")
	var no_life = Motion.new({})
	check(no_life.advance_to(1000000).alive and no_life.alpha == 100, "zero lifetime is unbounded")
	var cosine := {"axes": {"x": {"move_type": "[cos]", "move_variable_1": [10, 10], "move_variable_2": [1000, 1000]}}}
	check(Motion.new(cosine).position == Vector3i(10, 0, 0), "reset evaluates cosine at time zero")
	check(not Motion.new({"changing_type": "[unknown]"}).advance_to(0).ok, "unknown rule is explicit")
	var invalid_period := {"axes": {"x": {"move_type": "[sin]", "move_variable_1": [10, 10], "move_variable_2": [0, 0]}}}
	check(not Motion.new(invalid_period).advance_to(100).ok, "zero sinusoidal period cannot silently become straight movement")
	print("[PARTICLE_MOTION] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)
