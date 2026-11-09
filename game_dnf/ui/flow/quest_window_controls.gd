extends RefCounted
## Small ws1-owned helpers shared by the quest window and NPC dialogue.

static func clear_children(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()

static func focus_chain(buttons: Array, grab_first := true) -> void:
	var chain: Array[Control] = []
	for value in buttons:
		if not value is Control or not is_instance_valid(value):
			continue
		var control := value as Control
		control.focus_mode = Control.FOCUS_ALL
		chain.append(control)
	if chain.is_empty():
		return
	for index in chain.size():
		var control := chain[index]
		var previous := chain[posmod(index - 1, chain.size())]
		var following := chain[posmod(index + 1, chain.size())]
		control.focus_neighbor_left = control.get_path_to(previous)
		control.focus_neighbor_right = control.get_path_to(following)
		control.focus_neighbor_top = control.get_path_to(previous)
		control.focus_neighbor_bottom = control.get_path_to(following)
	if grab_first:
		chain[0].call_deferred("grab_focus")

static func add_focus_tint(control: Control, rest := Color.WHITE, focused := Color("ffe1a0")) -> void:
	control.focus_entered.connect(func(): control.modulate = focused)
	control.focus_exited.connect(func(): control.modulate = rest)
