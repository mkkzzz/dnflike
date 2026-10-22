extends RefCounted
## Deterministic random source owned by one simulation; never use global randf().

var _rng := RandomNumberGenerator.new()
var seed_value := 0

func _init(value: int = 0) -> void:
	reseed(value)

func reseed(value: int) -> void:
	seed_value = value
	_rng.seed = value

func next_float() -> float:
	return _rng.randf()

func range_int(low: int, high: int) -> int:
	return _rng.randi_range(low, high)

func chance(probability: float) -> bool:
	return _rng.randf() < probability
