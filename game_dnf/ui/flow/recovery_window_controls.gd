extends RefCounted
## Small ws1-owned helpers for the death and revival window.

static func set_feedback(label: Label, message: String, skin) -> void:
	if not is_instance_valid(label):
		return
	label.text = skin.chinese(message)
	label.tooltip_text = label.text
	label.visible = label.text != ""

static func clear_feedback(label: Label) -> void:
	if not is_instance_valid(label):
		return
	label.text = ""
	label.tooltip_text = ""
	label.visible = false

static func focus_buttons(buttons: Array, preferred: Button = null) -> void:
	var chain: Array[Button] = []
	for value in buttons:
		var button := value as Button
		if button != null and is_instance_valid(button) and not button.disabled:
			button.focus_mode = Control.FOCUS_ALL
			chain.append(button)
	for index in chain.size():
		var button := chain[index]
		var previous := chain[posmod(index - 1, chain.size())]
		var following := chain[posmod(index + 1, chain.size())]
		button.focus_neighbor_left = button.get_path_to(previous)
		button.focus_neighbor_right = button.get_path_to(following)
		button.focus_neighbor_top = button.get_path_to(previous)
		button.focus_neighbor_bottom = button.get_path_to(following)
	var target := preferred if preferred != null and not preferred.disabled else (chain[0] if not chain.is_empty() else null)
	if target != null:
		target.call_deferred("grab_focus")
