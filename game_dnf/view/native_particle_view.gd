extends "res://view/fx_view.gd"
## Animation-object branch of 0xE4E170. Free particles only: parent position
## following and passive-object factories require separate, proven adapters.
const Playback = preload("res://combat/api/particle_playback.gd")
const Frame = preload("res://view/world_frame.gd")
var playback: RefCounted
var errors: Array[String] = []

## bank must preserve source, loop, original frame delays and atlas anchors.
## No asset lookup by basename: the selected PTL entry identifies the exact bank.
func setup_particle(emission: Dictionary, bank: Dictionary) -> bool:
	var entry: Dictionary = emission.get("entry", {})
	if emission.get("object_type", "") != "[animation]":
		errors.append("passive particle objects need their native object factory")
	if int(entry.get("parameter", -2)) != -1 or String(entry.get("path", "")).is_empty():
		errors.append("this adapter requires an ANI file entry")
	if String(bank.get("source", "")).to_lower() != String(entry.get("path", "")).to_lower():
		errors.append("particle animation source does not match selected entry")
	if not bank.has("loop"):
		errors.append("particle bank must preserve the source ANI loop flag")
	playback = Playback.new(emission.get("motion"))
	errors.append_array(playback.errors)
	if not errors.is_empty():return false
	loop = bool(bank.loop)
	# 0x406CB0 -> 0x7F1210 gets auto-delete argument 0 from 0xE4E6AA.
	# 0x2226217 skips ANI-end deletion; 0x224257E checks motion alive instead.
	hold_last_frame = true
	setup(bank, -1 if playback.mirrored else 1)
	clock_ms = 0.0
	advance(0.0)
	return errors.is_empty()

func advance(ms: float) -> void:
	if playback == null or not errors.is_empty() or is_queued_for_deletion():return
	# The ANI is freshly constructed at emission. Backdated motion age does
	# not skip the initial animation frames (0xE4E662..0xE4E6B3).
	var state: Dictionary = playback.advance(ms)
	if not state.ok:
		errors.assign(state.problems)
		return
	if not state.alive:
		hide()
		queue_free()
		return
	var point: Vector3i = state.position
	position = Vector2(point.x, point.y + Frame.MAP_DY - point.z)
	z_index = point.y + 4
	fade = float(state.alpha) / 100.0
	super.seek(state.animation_ms)
