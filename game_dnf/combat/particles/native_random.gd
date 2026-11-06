extends RefCounted
## Original 0xE47F50: three 32-bit LCG steps combine to a nonnegative 31-bit draw.
## The null-pointer/global form adds timeGetTime before each draw. Callers supply
## that clock value explicitly; replaying a seed alone does not replay wall time.
var state: int
var draws := 0

func _init(seed: int = 0) -> void:
	state = seed & 0xffffffff

func next_u31(clock_ms: int = 0, mix_clock := false) -> int:
	if mix_clock:
		state = (state + clock_ms) & 0xffffffff
	state = (state * 0x41c64e6d + 0x3039) & 0xffffffff
	var high := (state >> 16) & 0x7ff
	state = (state * 0x41c64e6d + 0x3039) & 0xffffffff
	var middle := (state >> 16) & 0x3ff
	state = (state * 0x41c64e6d + 0x3039) & 0xffffffff
	draws += 1
	return (((high << 10) ^ middle) << 10) ^ ((state >> 16) & 0x3ff)
