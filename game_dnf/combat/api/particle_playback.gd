extends RefCounted
## Public playback boundary for an emitted motion instance. The view receives
## snapshots; it does not import or advance private combat implementation types.
const Motion = preload("res://combat/particles/native_motion.gd")
var _motion: RefCounted
var _initial_age_ms := 0
var animation_ms := 0.0
var mirrored := false
var errors: Array[String] = []

func _init(source: Variant) -> void:
	if not source is Motion:
		errors.append("native particle motion instance is required")
		return
	_motion = source
	_initial_age_ms = source.elapsed_ms
	mirrored = source.mirrored

func set_paused(value: bool) -> void:
	if _motion != null:_motion.paused = value

func advance(ms: float) -> Dictionary:
	if ms < 0.0:errors.append("particle display clock cannot move backwards")
	if not errors.is_empty():return {"ok":false,"problems":errors.duplicate()}
	# The ANI starts fresh at emission, even when motion was backdated by the
	# emitter. Simulation pause freezes both clocks as an integration contract.
	if not _motion.paused:animation_ms += ms
	var state: Dictionary = _motion.advance_to(_initial_age_ms + int(animation_ms))
	state["animation_ms"] = animation_ms
	return state
