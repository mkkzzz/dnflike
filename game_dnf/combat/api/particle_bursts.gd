extends RefCounted
## Public boundary for single native PTL emissions. One shared cosmetic random
## stream per view; gameplay RNG is untouched. Full client seed/clock sharing
## remains an integration difference, explicitly injectable for replay.
const Emitter = preload("res://combat/particles/native_emitter.gd")
const Random = preload("res://combat/particles/native_random.gd")
var random = Random.new(0)
var clock: Callable = func():return Time.get_ticks_msec()
var quality := 2

func emit_once(definition: Dictionary, origin: Vector3i, mirrored := false) -> Dictionary:
	if float(definition.get("creation_frequency",0)) > 0:
		return {"ok":false,"problems":["burst API cannot schedule a continuous emitter"],"particles":[]}
	var at := int(clock.call())
	var emitter = Emitter.new(definition,func():return random.next_u31(at,true),origin,mirrored)
	emitter.quality = quality
	return emitter.emit_at(0)
