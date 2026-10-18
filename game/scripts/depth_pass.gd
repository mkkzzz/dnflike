extends Node

var main: Node

func _physics_process(_delta: float) -> void:
	if main != null and main.dungeon_mode:
		main._update_depth_order()
