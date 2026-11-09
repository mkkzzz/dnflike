extends RefCounted
## Small ws1-owned helpers for the inventory management board.

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
