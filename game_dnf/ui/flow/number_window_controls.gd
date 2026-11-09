extends RefCounted
## Small ws1-owned helpers for the attributes and equipment boards.

static func clear_children(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()

static func set_feedback(label: Label, message: String) -> void:
	if not is_instance_valid(label):
		return
	label.text = preload("res://ui/flow/language_guard.gd").display(message)
	label.visible = label.text != ""

static func clear_feedback(label: Label) -> void:
	if not is_instance_valid(label):
		return
	label.text = ""
	label.visible = false

static func focus_buttons(buttons: Array) -> void:
	var chain: Array[Control] = []
	for value in buttons:
		if value is Control and is_instance_valid(value):
			var control := value as Control
			control.focus_mode = Control.FOCUS_ALL
			chain.append(control)
	for index in chain.size():
		var control := chain[index]
		var previous := chain[posmod(index-1,chain.size())]
		var following := chain[posmod(index+1,chain.size())]
		control.focus_neighbor_left = control.get_path_to(previous)
		control.focus_neighbor_right = control.get_path_to(following)
		control.focus_neighbor_top = control.get_path_to(previous)
		control.focus_neighbor_bottom = control.get_path_to(following)
