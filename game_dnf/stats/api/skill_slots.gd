extends RefCounted
## Legacy indices stay on ASDFGH; new slots append QWERTY above them.
const KEYS := [KEY_A, KEY_S, KEY_D, KEY_F, KEY_G, KEY_H, KEY_Q, KEY_W, KEY_E, KEY_R, KEY_T, KEY_Y]
const COUNT := 12
const ROW_SIZE := 6
const LABELS := ["A", "S", "D", "F", "G", "H", "Q", "W", "E", "R", "T", "Y"]

static func position(index: int) -> Vector2:
	return Vector2(538 + (index % ROW_SIZE) * 30, 558 if index < ROW_SIZE else 526)
