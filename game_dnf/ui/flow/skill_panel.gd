extends RefCounted
## 原版 SkillShop 技能树：节点坐标和前后置边来自 Swordman_Sp.co + SKL。
## 175 条源技能中只有已接入运行时招式的节点可交易；其余保留原图与说明但标灰。
const Numbers = preload("res://stats/api/numbers.gd")
const CATALOG := "res://data/skill_catalog.json"
const MANIFEST := "res://assets_local/skill_panel/manifest.json"
const WINDOW_ORIGIN := Vector2(14, 12)
const WINDOW_SIZE := Vector2(772, 490)
const TREE_ORIGIN := Vector2(10, 88)
const TREE_SIZE := Vector2(540, 342)
const TREE_INSET := Vector2(24, 8)
const NODE_SLOT := 38
const NODE_CENTER := 19
const JOB_NAMES := {
	"swordman": "鬼剑士",
	"weaponmaster": "剑魂",
	"soulbringer": "鬼泣",
	"berserker": "狂战士",
	"asura": "阿修罗",
}
var game
var selected := ""
var free_mode := false
var class_only := true
var skills: Array = []
var by_id: Dictionary = {}
var by_key: Dictionary = {}
var trees: Dictionary = {}
var parts: Dictionary = {}
var selected_branch := "none"
var tree_scroll := 0.0
var _textures: Dictionary = {}

func _init(target) -> void:
	game = target
	_load()

func _load() -> void:
	for path in [CATALOG, MANIFEST]:
		if not FileAccess.file_exists(path):
			push_warning("技能面板资源缺失：" + path)
			return
	var catalog: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(CATALOG))
	skills = catalog.get("skills", [])
	trees = catalog.get("trees", {})
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	parts = manifest.get("parts", {})
	for skill: Dictionary in skills:
		by_id[int(skill["id"])] = skill
		by_key[String(skill["key"])] = skill
	for skill: Dictionary in skills:
		if String(skill["local_id"]) == "upper":
			selected = String(skill["key"])
			break
	if selected == "" and not skills.is_empty():
		selected = String(skills[0]["key"])
	selected_branch = current_branch()

func _tex(rel: String) -> Texture2D:
	if rel == "":
		return null
	if _textures.has(rel):
		return _textures[rel]
	var image := Image.load_from_file(ProjectSettings.globalize_path("res://assets_local/skill_panel/" + rel))
	var texture: Texture2D = ImageTexture.create_from_image(image) if image != null else null
	_textures[rel] = texture
	return texture

func _part(key: String) -> Texture2D:
	var entry: Dictionary = parts.get(key, {})
	if entry.is_empty():
		return null
	return _tex(String(entry.get("file", "")))

func _sp_branches() -> Array:
	var value = trees.get("sp", [])
	return value if value is Array else []

func current_branch() -> String:
	var job := String(game.session.profile.get("growtype", "swordman"))
	var source_branch := "none" if job == "swordman" else job
	for branch: Dictionary in _sp_branches():
		if String(branch.get("source_branch", "")) == source_branch:
			return source_branch
	return "none"

func branch_data(source_branch := "") -> Dictionary:
	var wanted := source_branch if source_branch != "" else current_branch()
	for branch: Dictionary in _sp_branches():
		if String(branch.get("source_branch", "")) == wanted:
			return branch
	return {}

func tree_nodes(source_branch := "") -> Array:
	return _array(branch_data(source_branch).get("nodes", []))

func tree_edges(source_branch := "") -> Array:
	return _array(branch_data(source_branch).get("edges", []))

func active_skill(id: String) -> bool:
	return bool(Numbers.shared_config().get("skills", {}).get(id, {}).get("active", false))

func runtime_max_level(skill: Dictionary) -> int:
	var local := String(skill.get("local_id", ""))
	var definition: Dictionary = Numbers.shared_config().get("skills", {}).get(local, {})
	return int(definition.get("max_level", skill.get("max_level", 0)))

func class_allowed(skill: Dictionary) -> bool:
	if not class_only:
		return true
	var caps: Array = _array(skill.get("growtype_max_level"))
	if caps.is_empty():
		return true
	var profile: Dictionary = game.session.profile
	var slot := int(Numbers.shared_config().get("growtype_index", {}).get(String(profile["growtype"]), 0))
	if slot >= caps.size():
		return false
	return int(caps[0]) > 0 or int(caps[slot]) > 0

func show_window(parent: Control) -> void:
	var skin = game.skin
	selected_branch = current_branch()
	var branch := branch_data(selected_branch)
	var visible_ids: Dictionary = {}
	for node: Dictionary in _array(branch.get("nodes", [])):
		visible_ids[int(node["id"])] = true
	if not visible_ids.has(int(by_key.get(selected, {}).get("id", -1))):
		selected = String(by_id[46]["key"]) if visible_ids.has(46) else ""
		if selected == "" and not visible_ids.is_empty():
			selected = String(by_id[visible_ids.keys()[0]]["key"])

	var root := Control.new()
	root.name = "number_window"
	root.position = WINDOW_ORIGIN
	root.size = WINDOW_SIZE
	root.clip_contents = true
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	parent.add_child(root)
	skin.panel(root, Rect2(Vector2.ZERO, WINDOW_SIZE))
	skin.image_region(root, _part("dim"), Rect2(8, 8, WINDOW_SIZE.x - 16, WINDOW_SIZE.y - 16), Vector2(8, 8))
	_navigation(root)
	_header(root)
	_tree(root, branch)
	_detail(root)
	_job_advancement(root)
	skin.close_button(root, Vector2(748, 8), func(): game.show_overlay(""))

func _navigation(root: Control) -> void:
	var skin = game.skin
	var entries := [["属性", 0], ["技能", 1], ["装备", 2]]
	for entry in entries:
		var tab := int(entry[1])
		var button: Button = skin.button(root, String(entry[0]), Vector2(16 + tab * 62, 10),
			func(): game.number_windows.tab = tab; game.show_overlay("numbers"), false)
		button.size = Vector2(56, 23)
		button.disabled = tab == 1
	skin.label(root, "技能学习", Vector2(218, 11), 14, Color("f0d18a"))

func _header(root: Control) -> void:
	var skin = game.skin
	var profile: Dictionary = game.session.profile
	var job := String(profile["growtype"])
	var sp := Numbers.Skills.available(profile, Numbers.config())
	var sp_bar := _part("sp_icon")
	if sp_bar != null:
		var bar: TextureRect = skin.image(root, sp_bar, Vector2(342, 41))
		bar.name = "skill_sp_bar"
	var sp_label: Label = skin.label(root, str(sp), Vector2(364, 43), 12, Color("f0d18a"))
	sp_label.size = Vector2(44, 16)
	sp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	skin.label(root, "%s  Lv.%d" % [JOB_NAMES.get(job, job), int(profile["level"])],
		Vector2(20, 49), 12, Color("a7dd74"))
	skin.label(root, "SP 技能", Vector2(20, 77), 11, Color("e8ddb9"))
	skin.label(root, "剩余 SP", Vector2(342, 25), 10, Color("c9c0a8"))

func _tree(root: Control, branch: Dictionary) -> void:
	var skin = game.skin
	var nodes: Array = _array(branch.get("nodes", []))
	var content_height := TREE_SIZE.y
	for node: Dictionary in nodes:
		content_height = maxf(content_height, float(node.get("y", 0)) + TREE_INSET.y + NODE_SLOT + 18.0)
	var viewport := Control.new()
	viewport.name = "skill_tree_viewport"
	viewport.position = TREE_ORIGIN
	viewport.size = TREE_SIZE
	viewport.clip_contents = true
	viewport.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(viewport)
	var content := Control.new()
	content.name = "skill_tree_content"
	content.size = Vector2(TREE_SIZE.x, content_height)
	content.mouse_filter = Control.MOUSE_FILTER_PASS
	viewport.add_child(content)

	for edge: Dictionary in tree_edges(selected_branch):
		var source: Dictionary = by_id.get(int(edge["from"]), {})
		var target: Dictionary = by_id.get(int(edge["to"]), {})
		var source_node := _find_node(nodes, int(edge["from"]))
		var target_node := _find_node(nodes, int(edge["to"]))
		if source.is_empty() or target.is_empty() or source_node.is_empty() or target_node.is_empty():
			continue
		var line := Line2D.new()
		line.name = "skill_edge_%d_%d" % [int(edge["from"]), int(edge["to"])]
		line.points = PackedVector2Array(_edge_points(source_node, target_node))
		line.width = 1.0
		var selected_id := _selected_id()
		line.default_color = Color("c39a54") if selected_id in [int(edge["from"]), int(edge["to"])] else Color("315f91")
		line.z_index = -1
		content.add_child(line)
		var points := _edge_points(source_node, target_node)
		var direction: Vector2 = (points[1] - points[0]).normalized()
		var normal := Vector2(-direction.y, direction.x)
		var arrow := Line2D.new()
		arrow.points = PackedVector2Array([points[1] - direction * 5 + normal * 3, points[1], points[1] - direction * 5 - normal * 3])
		arrow.width = 1.0
		arrow.default_color = line.default_color
		content.add_child(arrow)

	var ordered := nodes.duplicate()
	ordered.sort_custom(func(a, b):
		var ay := int(a.get("y", 0))
		var by := int(b.get("y", 0))
		return ay < by or ay == by and int(a.get("x", 0)) < int(b.get("x", 0)))
	for node: Dictionary in ordered:
		var skill: Dictionary = by_id.get(int(node["id"]), {})
		if not skill.is_empty():
			_tree_node(content, node, skill)

	var scroll := VScrollBar.new()
	scroll.name = "skill_tree_scroll"
	scroll.position = TREE_ORIGIN + Vector2(TREE_SIZE.x + 2, 0)
	scroll.size = Vector2(14, TREE_SIZE.y)
	scroll.min_value = 0
	scroll.max_value = content_height
	scroll.page = TREE_SIZE.y
	scroll.step = 16
	tree_scroll = clampf(tree_scroll, 0.0, scroll.max_value - scroll.page)
	scroll.value = tree_scroll
	_style_scroll(scroll)
	scroll.value_changed.connect(func(value: float):
		tree_scroll = value
		content.position.y = -value)
	root.add_child(scroll)
	content.position.y = -tree_scroll
	viewport.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed:
			if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				scroll.value += 67
				viewport.accept_event()
			elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
				scroll.value -= 67
				viewport.accept_event())

func _style_scroll(scroll: VScrollBar) -> void:
	# The SP page names stick-vscroll but does not specify its IMG skin.
	var skin = game.skin
	var track := StyleBoxTexture.new()
	track.texture = skin.texture("shop", 13)
	scroll.add_theme_stylebox_override("scroll", track)
	for state in ["grabber", "grabber_highlight", "grabber_pressed"]:
		var grabber := StyleBoxTexture.new()
		grabber.texture = skin.texture("shop", 8)
		grabber.texture_margin_top = 3
		grabber.texture_margin_bottom = 3
		scroll.add_theme_stylebox_override(state, grabber)
	for pair in [["increment", 12], ["increment_highlight", 12], ["increment_pressed", 12], ["decrement", 9], ["decrement_highlight", 9], ["decrement_pressed", 9]]:
		scroll.add_theme_icon_override(pair[0], skin.texture("shop", pair[1]))

func _tree_node(parent: Control, node: Dictionary, skill: Dictionary) -> void:
	var skin = game.skin
	var key := String(skill["key"])
	var local := String(skill["local_id"])
	var chosen := key == selected
	var at := TREE_INSET + Vector2(int(node.get("x", 0)), int(node.get("y", 0)))
	var hit := Button.new()
	hit.name = "skill_node_%d" % int(skill["id"])
	hit.position = at
	hit.size = Vector2(NODE_SLOT, NODE_SLOT)
	hit.focus_mode = Control.FOCUS_NONE
	hit.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	hit.tooltip_text = String(skill["name"])
	hit.set_meta("skill_id", int(skill["id"]))
	hit.set_meta("skill_key", key)
	hit.set_meta("tree_x", int(node.get("x", 0)))
	hit.set_meta("tree_y", int(node.get("y", 0)))
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		hit.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	var base: TextureRect = skin.image(hit, _part("node_selected") if chosen else _part("node_slot"), Vector2.ZERO)
	var icon := _tex(String(skill.get("icon_selected", "")) if chosen else String(skill.get("icon", "")))
	if icon == null:
		icon = _tex(String(skill.get("icon", "")))
	var icon_view: TextureRect = skin.image(hit, icon, Vector2(5, 5)) if icon != null else null
	var state := _state(skill)
	if local == "" or not class_allowed(skill):
		if base != null:
			base.modulate = Color(0.58, 0.58, 0.58, 0.8)
		if icon_view != null:
			icon_view.modulate = Color(0.48, 0.48, 0.48, 0.72)
	elif not bool(state["ok"]):
		if icon_view != null:
			icon_view.modulate = Color(0.7, 0.7, 0.7, 0.9)
	var rank := int(game.session.profile["skills"].get(local, 0)) if local != "" else 0
	var rank_label: Label = skin.label(hit, "%d" % rank, Vector2(0, 37), 10,
		Color("f3df9b") if rank > 0 else Color("938e82"))
	rank_label.size = Vector2(NODE_SLOT, 15)
	rank_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hit.pressed.connect(func():
		selected = key
		game.show_overlay("numbers"))
	var base_color: Color = base.modulate
	hit.mouse_entered.connect(func():
		if not chosen and is_instance_valid(base):
			base.modulate = Color(1.25, 1.25, 1.25, 1.0))
	hit.mouse_exited.connect(func():
		if not chosen and is_instance_valid(base):
			base.modulate = base_color)
	var drag_icon := icon
	hit.set_drag_forwarding(func(_at: Vector2):
		if not active_skill(local) or int(game.session.profile["skills"].get(local, 0)) <= 0:
			return null
		if drag_icon != null:
			var preview := TextureRect.new()
			preview.texture = drag_icon
			preview.size = Vector2(50, 50)
			preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			hit.set_drag_preview(preview)
		return {"place": "skill_catalog", "id": local}, Callable(), Callable())
	parent.add_child(hit)

func _find_node(nodes: Array, id: int) -> Dictionary:
	for node: Dictionary in nodes:
		if int(node.get("id", -1)) == id:
			return node
	return {}

func _edge_points(source: Dictionary, target: Dictionary) -> Array[Vector2]:
	var start := TREE_INSET + Vector2(int(source.get("x", 0)) + NODE_CENTER, int(source.get("y", 0)) + NODE_CENTER)
	var finish := TREE_INSET + Vector2(int(target.get("x", 0)) + NODE_CENTER, int(target.get("y", 0)) + NODE_CENTER)
	var direction := (finish - start).normalized()
	return [start + direction * NODE_CENTER, finish - direction * NODE_CENTER]

func _selected_id() -> int:
	return int(by_key.get(selected, {}).get("id", -1))

func _detail(root: Control) -> void:
	var skin = game.skin
	var skill: Dictionary = by_key.get(selected, {})
	if skill.is_empty():
		return
	var panel := Control.new()
	panel.name = "skill_detail"
	panel.position = Vector2(562, 35)
	panel.size = Vector2(199, 402)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.clip_contents = true
	root.add_child(panel)
	var board := NinePatchRect.new()
	board.texture = _part("detail_board")
	board.size = panel.size
	board.patch_margin_left = 12
	board.patch_margin_right = 12
	board.patch_margin_top = 13
	board.patch_margin_bottom = 12
	board.axis_stretch_horizontal = NinePatchRect.AXIS_STRETCH_MODE_TILE
	board.axis_stretch_vertical = NinePatchRect.AXIS_STRETCH_MODE_TILE
	board.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(board)
	skin.image(panel, _part("title"), Vector2(-20, 3))
	var title_label: Label = skin.label(panel, String(skill["name"]), Vector2(15, 8), 13, Color("f0d18a"))
	title_label.size = Vector2(173, 18)
	title_label.clip_text = true
	title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var art := _part("detail_art")
	if art != null:
		skin.image(panel, art, Vector2(19, 33))
	var icon := _tex(String(skill.get("icon_selected", "")))
	if icon == null:
		icon = _tex(String(skill.get("icon", "")))
	if icon != null:
		var icon_view: TextureRect = skin.image(panel, icon, Vector2(88, 57))
		icon_view.name = "skill_detail_icon"
	var separator := _part("detail_separator")
	if separator != null:
		skin.image(panel, separator, Vector2(8, 134))
	var local := String(skill["local_id"])
	var rank := int(game.session.profile["skills"].get(local, 0)) if local != "" else 0
	var limit := runtime_max_level(skill)
	var level_text := "等级  %d / %d" % [rank, limit] if local != "" else "状态  未实装"
	var level_label: Label = skin.label(panel, level_text, Vector2(30, 104), 11, Color("e8ddb9"))
	level_label.size = Vector2(140, 17)
	level_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	var description := String(skill.get("explain", ""))
	if description == "":
		description = String(skill.get("basic_explain", ""))
	var cost := _number(skill.get("purchase_cost"))
	skin.label(panel, "消耗 SP：%d" % cost, Vector2(16, 137), 11, Color("68d5ed"))
	skin.label(panel, "技能等级  %d" % rank, Vector2(16, 154), 10, Color("ddd0b2"))
	var learn := _rank_button(panel, "加点", Vector2(146, 153), "+", func(): change(selected, 1))
	learn.disabled = not bool(_state(skill)["ok"])
	learn.get_child(0).modulate.a = 0.35 if learn.disabled else 1.0
	var refund := _rank_button(panel, "退点", Vector2(166, 153), "-", func(): change(selected, -1))
	refund.disabled = rank <= 0
	refund.get_child(0).modulate.a = 0.35 if refund.disabled else 1.0
	var meta: Array[String] = ["技能类型：" + _type_name(String(skill["type"]))]
	var need := int(skill.get("required_level", 0)) + rank * _number(skill.get("required_level_range"))
	meta.append("学习等级：%d" % need)
	var requires := _requires(skill)
	if requires != "":
		meta.append("前置技能：" + requires)
	if local != "":
		var values: Dictionary = game.skill_catalog.get_skill(local, maxi(1, rank))
		meta.append("MP：%d    冷却：%.1f秒" % [int(values.get("mp", 0)), float(values.get("cooldown", 0))])
		var percentages: Array = values.get("damage_percent", [])
		if not percentages.is_empty():
			meta.append("攻击力：%d%%" % int(percentages[0]))
	var body := RichTextLabel.new()
	body.name = "skill_detail_body"
	body.position = Vector2(9, 176)
	body.size = Vector2(179, 214)
	body.add_theme_font_override("normal_font", skin.font)
	body.add_theme_font_size_override("normal_font_size", 11)
	body.add_theme_color_override("default_color", Color("ddc58d"))
	body.add_theme_constant_override("line_separation", 3)
	body.text = description + "\n\n" + "\n".join(meta)
	body.scroll_active = true
	body.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.add_child(body)
	_style_scroll(body.get_v_scroll_bar())
	var state := _state(skill)
	var tip := "可以学习" if bool(state["ok"]) else String(state["reason"])
	var tip_label: Label = skin.label(root, tip, Vector2(20, 440), 11,
		Color("a7dd74") if bool(state["ok"]) else Color("c86a5a"))
	tip_label.size = Vector2(535, 18)
	tip_label.clip_text = true
	tip_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var reset: Button = skin.button(root, "重置", Vector2(232, 461),
		func(): game.act("numbers.skill_reset"); game.show_overlay("numbers"))
	reset.size = Vector2(68, 23)
	var close: Button = skin.button(root, "关闭", Vector2(306, 461), func(): game.show_overlay(""))
	close.size = Vector2(68, 23)

func _rank_button(parent: Control, title: String, at: Vector2, symbol: String, action: Callable) -> Button:
	var hit := Button.new()
	hit.position = at
	hit.size = Vector2(18, 16)
	hit.focus_mode = Control.FOCUS_NONE
	hit.tooltip_text = title
	hit.set_meta("action_label", title)
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		hit.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	var label: Label = game.skin.label(hit, symbol, Vector2.ZERO, 12, Color("e8ddb9"))
	label.size = hit.size
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hit.pressed.connect(action)
	parent.add_child(hit)
	return hit

func _job_advancement(root: Control) -> void:
	var profile: Dictionary = game.session.profile
	if String(profile.get("growtype", "swordman")) != "swordman":
		return
	var ready := int(profile.get("level", 1)) >= int(Numbers.config()["progression"].get("job_change_level", 18))
	var first: Button = game.skin.button(root, "转职剑魂", Vector2(16, 461),
		func(): job_change("weaponmaster"), false)
	first.size = Vector2(80, 23)
	first.disabled = not ready
	var second: Button = game.skin.button(root, "转职狂战士", Vector2(102, 461),
		func(): job_change("berserker"), false)
	second.size = Vector2(92, 23)
	second.disabled = not ready

func _type_name(raw: String) -> String:
	if raw.contains("passive"):
		return "被动"
	if raw.contains("active"):
		return "主动"
	return "未知"

func _jobs(skill: Dictionary) -> String:
	var index: Dictionary = Numbers.config().get("growtype_index", {})
	var caps: Array = _array(skill.get("growtype_max_level"))
	var out: Array[String] = []
	for job: String in index:
		var slot := int(index[job])
		if slot < caps.size() and int(caps[slot]) > 0:
			out.append(JOB_NAMES.get(job, job))
	if out.size() == index.size():
		return ""
	return "、".join(out)

func _requires(skill: Dictionary) -> String:
	var out: Array[String] = []
	for entry: Dictionary in _array(skill.get("pre_required_skill")):
		var parent: Dictionary = by_id.get(int(entry["id"]), {})
		out.append("%s Lv%d" % [String(parent.get("name", "编号 %d" % int(entry["id"]))), int(entry["level"])])
	return "、".join(out)

## 返回 {ok, reason}：原版等级/职业/前置 + 本地实装与 SP 状态。
func _state(skill: Dictionary) -> Dictionary:
	var local := String(skill.get("local_id", ""))
	if local == "":
		return {"ok": false, "reason": "未实装战斗动作"}
	if free_mode:
		return {"ok": true, "reason": ""}
	var profile: Dictionary = game.session.profile
	var cfg := Numbers.config()
	var rank := int(profile["skills"].get(local, 0))
	if rank >= runtime_max_level(skill):
		return {"ok": false, "reason": "已满级"}
	var caps: Array = _array(skill.get("growtype_max_level"))
	var slot := int(cfg.get("growtype_index", {}).get(String(profile["growtype"]), 0))
	if not caps.is_empty() and (slot >= caps.size() or rank >= int(caps[slot])):
		return {"ok": false, "reason": "职业不符"}
	var need := int(skill.get("required_level", 1)) + rank * _number(skill.get("required_level_range"))
	if int(profile["level"]) < need:
		return {"ok": false, "reason": "需 Lv%d" % need}
	for entry: Dictionary in _array(skill.get("pre_required_skill")):
		var parent: Dictionary = by_id.get(int(entry["id"]), {})
		var parent_local := String(parent.get("local_id", ""))
		if parent_local == "":
			return {"ok": false, "reason": "前置未实装"}
		if int(profile["skills"].get(parent_local, 0)) < int(entry["level"]):
			return {"ok": false, "reason": "前置 %s Lv%d" % [String(parent.get("name", "")), int(entry["level"])]}
	if Numbers.Skills.available(profile, cfg) < _number(skill.get("purchase_cost")):
		return {"ok": false, "reason": "SP 不足"}
	return {"ok": true, "reason": ""}

func change(key: String, delta: int) -> void:
	var skill: Dictionary = by_key.get(key, {})
	var local := String(skill.get("local_id", ""))
	if local == "":
		game.notice("该技能尚未实装")
		return
	if game.act("numbers.skill", {"id": local, "delta": delta, "force": free_mode}):
		selected = key
		game.show_overlay("numbers")

func job_change(job: String) -> void:
	if game.act("numbers.growtype", {"growtype": job}):
		game.notice("已转职：" + JOB_NAMES.get(job, job))
		selected_branch = current_branch()
		game.show_overlay("numbers")

func _array(value) -> Array:
	return value if value is Array else []

func _number(value) -> int:
	return int(value) if value is int or value is float else 0
