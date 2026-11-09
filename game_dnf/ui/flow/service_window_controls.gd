extends RefCounted
## Shared ws1 state helpers for service and upgrade windows.

static var _transaction_serial := 0

static func transaction_id(prefix: String, persisted_count: int) -> String:
	_transaction_serial += 1
	return "%s:%d:%d:%d" % [prefix, Time.get_ticks_usec(), persisted_count, _transaction_serial]

static func set_feedback(label: Label, message: String) -> void:
	if not is_instance_valid(label):
		return
	label.text = game_text(message)
	label.visible = label.text != ""

static func clear_feedback(label: Label) -> void:
	if not is_instance_valid(label):
		return
	label.text = ""
	label.visible = false

static func replace_named_child(parent: Node, child_name: String) -> void:
	var old := parent.get_node_or_null(NodePath(child_name))
	if is_instance_valid(old):
		parent.remove_child(old)
		old.queue_free()

static func game_text(value: String) -> String:
	return preload("res://ui/flow/language_guard.gd").display(value)
