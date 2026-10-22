extends RefCounted
## Player-facing text is Chinese. Latin key bindings, units and rank letters are allowed.
static func contains_korean(value: String) -> bool:
	for i in value.length():
		var code := value.unicode_at(i)
		if (code >= 0x1100 and code <= 0x11ff) or (code >= 0x3130 and code <= 0x318f) or (code >= 0xa960 and code <= 0xa97f) or (code >= 0xac00 and code <= 0xd7ff) or (code >= 0xffa0 and code <= 0xffdc):return true
	return false

static func display(value: String) -> String:
	if contains_korean(value):
		push_warning("界面文字未通过中文检查")
		return "内容暂不可用"
	return value
