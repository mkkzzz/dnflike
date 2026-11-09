extends RefCounted
## Public boundary for native PTL emission. One shared cosmetic random
## stream per view; gameplay RNG is untouched. Full client seed/clock sharing
## remains an integration difference, explicitly injectable for replay.
const Emitter = preload("res://combat/particles/native_emitter.gd")
const Random = preload("res://combat/particles/native_random.gd")
var random = Random.new(0)
var clock: Callable = func():return Time.get_ticks_msec()
var quality := 2
var _draw_time_ms := 0

func emit_once(definition: Dictionary, origin: Vector3i, mirrored := false) -> Dictionary:
	if float(definition.get("creation_frequency",0)) > 0:
		return {"ok":false,"problems":["burst API cannot schedule a continuous emitter"],"particles":[]}
	return emit_at(create_emitter(definition,origin,mirrored),0)

func create_emitter(definition: Dictionary, origin: Vector3i, mirrored := false) -> RefCounted:
	var emitter = Emitter.new(definition,_draw,origin,mirrored)
	emitter.quality = quality
	return emitter

func emit_at(emitter: RefCounted, elapsed_ms: int) -> Dictionary:
	_draw_time_ms = int(clock.call())
	return emitter.emit_at(elapsed_ms)

func _draw() -> int:
	return random.next_u31(_draw_time_ms,true)
