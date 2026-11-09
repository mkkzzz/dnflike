extends SceneTree

const MonsterAI = preload("res://combat/ai/monster_ai.gd")
const AREA := [200, 0, 0, 0, 40, 0, 40, 0]
const POLICY := {"initial_ms":3000, "delay_ms":1200, "delay_spread_ms":240, "down_gate_percent":0, "slots":[
	{"slot":0, "standing_percent":20, "no_target_percent":0, "area":AREA},
	{"slot":1, "standing_percent":60, "no_target_percent":0, "area":AREA},
]}
var checks := 0
var failures := 0

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("[NATIVE_ATTACK_SELECTION] FAIL " + label)

func poll(elapsed: int, deadline: int, facing: int, targets: Array, draws: Array) -> Dictionary:
	var remaining := draws.duplicate()
	var result := MonsterAI.native_attack_poll(
		{"elapsed_ms":elapsed, "next_attack_ms":deadline, "position":Vector2i(300, 100), "facing":facing},
		POLICY, targets, func() -> int:
			if remaining.is_empty():
				check(false, "unexpected extra RNG draw")
				return 0
			return int(remaining.pop_front()))
	check(remaining.is_empty(), "all expected RNG draws consumed")
	return result

func target(point: Vector2i, down := false) -> Dictionary:
	return {"position":point, "size":Vector2i(22, 11), "down":down}

func _initialize() -> void:
	var right := [target(Vector2i(400, 100))]
	var left := [target(Vector2i(200, 100))]
	check(poll(2999, 0, 1, right, []) == {"slot":-1, "next_attack_ms":0}, "2999ms remains within initial delay")
	check(poll(3000, 0, 1, right, [0, 2000, 0, 6000, 0]) == {"slot":-1, "next_attack_ms":4080},
		"first attempt happens at 3000ms and advances deadline on both failures")
	check(poll(4079, 4080, 1, right, []) == {"slot":-1, "next_attack_ms":4080}, "wait through previous deadline")
	check(poll(4080, 4080, 1, right, [239, 1999, 6000, 0, 15]) == {"slot":0, "next_attack_ms":5399},
		"slot 0 passes its own 20-percent threshold at deadline and high jitter bound")
	check(poll(3000, 0, -1, left, [120, 2000, 0, 5999, 0]) == {"slot":1, "next_attack_ms":4200},
		"slot 1 passes its own 60-percent threshold facing left")
	for draw in [0, 1, 2, 3]:
		check(poll(3000, 0, 1, right, [0, 0, 0, draw]).slot == draw%2, "uniform draw among both passed slots")
	check(poll(3000, 0, 1, left, [0, 0, 0]).slot == -1, "rear target leaves only fallback draws")
	check(poll(3000, 0, -1, right, [0, 0, 0]).slot == -1, "rear target fails symmetrically")
	check(poll(3000, 0, 1, [target(Vector2i(505, 142))], [0, 0, 0, 0]).slot == 0,
		"inclusive edge intersects with target quarter-size")
	check(poll(3000, 0, -1, [target(Vector2i(95, 58))], [0, 0, 0, 0]).slot == 0,
		"inclusive edge mirrors the source front")
	check(poll(3000, 0, 1, [target(Vector2i(506, 142))], [0, 0, 0]).slot == -1, "one unit outside X fails")
	check(poll(3000, 0, 1, [target(Vector2i(505, 143))], [0, 0, 0]).slot == -1, "one unit outside Y fails")
	check(poll(3000, 0, 1, [target(Vector2i(400, 100), true)], [0, 0, 0, 0, 0]).slot == -1,
		"downed targets fail their gate and fall through to the zero fallback")
	check(poll(3000, 0, 1, right + right, [0, 2000, 1999, 5999, 1]).slot == 1,
		"an eligible target ends the current slot scan only")
	print("[NATIVE_ATTACK_SELECTION] COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)
