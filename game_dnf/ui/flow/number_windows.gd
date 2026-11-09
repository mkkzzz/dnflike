extends RefCounted
## Native attributes, equipment instances and the existing skill panel.

const Numbers = preload("res://stats/api/numbers.gd")
const SkillPanel = preload("res://ui/flow/skill_panel.gd")
const WindowControls = preload("res://ui/flow/number_window_controls.gd")

const NAMES := {
	"hp_max":"生命上限","mp_max":"魔法上限","strength":"力量","intelligence":"智力",
	"vitality":"体力","spirit":"精神","physical_attack":"基础物攻","magical_attack":"基础魔攻",
	"independent_attack":"独立攻击","physical_panel":"物理攻击面板","magical_panel":"魔法攻击面板",
	"physical_defense":"物理防御","magical_defense":"魔法防御","hit":"命中修正","evasion":"回避率",
	"physical_crit":"物理暴击","magical_crit":"魔法暴击","attack_speed":"攻击速度",
	"move_speed":"移动速度","cast_speed":"施放速度","cooldown_rate":"冷却系数",
	"mp_cost_rate":"蓝耗系数","fire_attack":"火属性强化","water_attack":"冰属性强化",
	"light_attack":"光属性强化","dark_attack":"暗属性强化","fire_resist":"火属性抗性",
	"water_resist":"冰属性抗性","light_resist":"光属性抗性","dark_resist":"暗属性抗性",
	"damage_rate":"伤害系数","taken_rate":"承伤系数","skill_rate":"技能伤害系数",
	"hp_regen":"每秒回血","mp_regen":"每秒回蓝","status_resist":"异常抗性",
	"hit_recovery":"硬直恢复","jump_power":"跳跃力","physical_independent_attack":"物理独立",
	"magical_independent_attack":"魔法独立","carry_capacity":"负重上限",
}

const SLOT_NAMES := {
	"weapon":"武器","coat":"上衣","pants":"下装","shoulder":"头肩","belt":"腰带",
	"shoes":"鞋","bracelet":"手镯","necklace":"项链","ring":"戒指",
}

const ATTRIBUTE_GROUPS := [
	{"id":"core","name":"基础属性","stats":["hp_max","mp_max","strength","intelligence","vitality","spirit"]},
	{"id":"attack","name":"攻击属性","stats":["physical_attack","magical_attack","independent_attack","physical_panel","magical_panel","physical_independent_attack","magical_independent_attack"]},
	{"id":"defense","name":"防御与倍率","stats":["physical_defense","magical_defense","damage_rate","taken_rate","skill_rate"]},
	{"id":"accuracy","name":"命中与暴击","stats":["hit","evasion","physical_crit","magical_crit"]},
	{"id":"speed","name":"速度与消耗","stats":["attack_speed","move_speed","cast_speed","cooldown_rate","mp_cost_rate"]},
	{"id":"element","name":"属性与抗性","stats":["fire_attack","water_attack","light_attack","dark_attack","fire_resist","water_resist","light_resist","dark_resist"]},
	{"id":"recovery","name":"恢复与容量","stats":["hp_regen","mp_regen","status_resist","hit_recovery","jump_power","carry_capacity"]},
]

const PERCENT_STATS := ["hit","evasion","physical_crit","magical_crit","attack_speed","move_speed","cast_speed","status_resist","damage_rate","taken_rate","skill_rate"]
const RATIO_STATS := ["cooldown_rate","mp_cost_rate"]
const COMPARE_STATS := ["physical_panel","magical_panel","physical_defense","magical_defense","hp_max","mp_max","attack_speed","move_speed","cast_speed","carry_capacity"]

var game
var skill_panel
var tab := 0
var page := 0
var selected_stat := "physical_attack"
var selected_group := "core"
var selected_gear_uid := ""
var window: Control
var content: Control
var feedback: Label
var source_body: VBoxContainer
var equipment_body: VBoxContainer
var gear_rows: Dictionary = {}
var group_buttons: Array[Button] = []
var window_builds := 0
var content_refreshes := 0

func _init(target) -> void:
	game = target
	skill_panel = SkillPanel.new(target)

func show_window() -> void:
	if tab == 1:
		skill_panel.show_window(game.modal)
		return
	if is_instance_valid(window) and not window.is_queued_for_deletion() \
		and window.get_parent() == game.modal:
		_render_content()
		return
	_build_window()

func _build_window() -> void:
	window_builds += 1
	window = game.windows.board(game.modal,"角色成长",Rect2(28,38,744,458))
	window.name = "number_window"
	content = Control.new()
	content.name = "number_window_content"
	content.size = Vector2(744,458)
	content.mouse_filter = Control.MOUSE_FILTER_PASS
	window.add_child(content)
	feedback = game.skin.label(window,"",Vector2(150,405),10,Color("e58d7c"))
	feedback.name = "number_window_feedback"
	feedback.size = Vector2(300,14)
	feedback.clip_text = true
	feedback.visible = false
	_render_content()

func _render_content() -> void:
	if not is_instance_valid(content):
		return
	content_refreshes += 1
	gear_rows.clear()
	group_buttons.clear()
	for child in content.get_children():
		content.remove_child(child)
		child.queue_free()
	WindowControls.clear_feedback(feedback)
	for index in 3:
		var value := index
		var button := _button(["角色属性","技能加点","装备管理"][index],Vector2(18+index*115,40),
			func(): _select_tab(value),true,"tab")
		button.size = Vector2(97,23)
		button.name = "number_tab_%d" % index
		if index == tab:
			button.modulate = Color("ffdb85")
	var profile: Dictionary = game.session.profile
	game.skin.label(content,"%s  Lv.%d" % [profile["name"],profile["level"]],
		Vector2(20,78),14,Color("f0d18a"))
	if tab == 0:
		attributes(content)
	else:
		equipment(content)
	game.skin.label(content,"O 角色成长   K 技能加点   Esc 关闭",Vector2(20,429),11,Color("a59c88"))

func _select_tab(index: int) -> void:
	if index == tab:
		return
	tab = index
	page = 0
	if tab == 1:
		game.show_overlay("numbers")
	else:
		_render_content()

func _button(label: String, at: Vector2, action: Callable, wide := true, sound := "") -> Button:
	var button: Button = game.skin.button(content,label,at,action,wide,sound)
	button.focus_mode = Control.FOCUS_ALL
	return button

func live_stats() -> Dictionary:
	if game.session.state=="battle" and is_instance_valid(game.battle):
		var view: Dictionary = game.combat.read_view()
		return {"values":view["numbers"],"sources":view["sources"]}
	return Numbers.profile_stats(game.session.profile)

func _group_definition(id: String) -> Dictionary:
	for group: Dictionary in ATTRIBUTE_GROUPS:
		if group["id"] == id:
			return group
	return ATTRIBUTE_GROUPS[0]

func attributes(node: Control) -> void:
	var group := _group_definition(selected_group)
	for index in ATTRIBUTE_GROUPS.size():
		var entry: Dictionary = ATTRIBUTE_GROUPS[index]
		var id := String(entry["id"])
		var button := _button(String(entry["name"]),Vector2(18,108+index*38),
			func(): select_attribute_group(id),false,"tab")
		button.size.x = 130
		button.name = "number_group_"+id
		if id == selected_group:
			button.modulate = Color("ffdb85")
		group_buttons.append(button)
	WindowControls.focus_buttons(group_buttons)
	if selected_stat not in group["stats"]:
		selected_stat = String(group["stats"][0])
	var data := live_stats()
	var values: Dictionary = data["values"]
	var scroll := ScrollContainer.new()
	scroll.name = "number_attribute_list_scroll"
	scroll.position = Vector2(162,104)
	scroll.size = Vector2(264,284)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content.add_child(scroll)
	var list := VBoxContainer.new()
	list.name = "number_attribute_list"
	list.add_theme_constant_override("separation",4)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	for stat: String in group["stats"]:
		var row := Button.new()
		row.name = "number_stat_"+stat
		row.flat = true
		row.focus_mode = Control.FOCUS_ALL
		row.custom_minimum_size = Vector2(248,31)
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.add_theme_font_override("font",game.skin.font)
		row.add_theme_font_size_override("font_size",12)
		row.text = "%s    %s" % [NAMES.get(stat,stat),format_value(stat,float(values.get(stat,0)))]
		row.set_meta("stat",stat)
		row.pressed.connect(select_stat.bind(stat))
		row.focus_entered.connect(select_stat.bind(stat))
		list.add_child(row)
	_update_stat_rows()
	var board: Control = game.skin.item_board(content,Rect2(438,80,292,318))
	board.name = "number_source_board"
	game.skin.label(board,"属性来源 · "+String(NAMES.get(selected_stat,selected_stat)),
		Vector2(12,10),13,Color("f0d18a")).name = "number_source_title"
	var source_scroll := ScrollContainer.new()
	source_scroll.name = "number_source_scroll"
	source_scroll.position = Vector2(8,38)
	source_scroll.size = Vector2(276,270)
	source_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	board.add_child(source_scroll)
	source_body = VBoxContainer.new()
	source_body.name = "number_source_body"
	source_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	source_body.add_theme_constant_override("separation",6)
	source_scroll.add_child(source_body)
	_render_sources(data)

func select_attribute_group(id: String) -> void:
	if id == selected_group:
		return
	selected_group = id
	var group := _group_definition(id)
	selected_stat = String(group["stats"][0])
	_render_content()

func select_stat(id: String) -> void:
	if id == selected_stat or not NAMES.has(id):
		return
	selected_stat = id
	_update_stat_rows()
	if is_instance_valid(window):
		var title := window.find_child("number_source_title",true,false) as Label
		if title != null:
			title.text = game.skin.chinese("属性来源 · "+String(NAMES.get(id,id)))
	_render_sources(live_stats())

func _update_stat_rows() -> void:
	if not is_instance_valid(content):
		return
	for row in content.find_children("number_stat_*","Button",true,false):
		row.modulate = Color("ffdd85") if row.get_meta("stat","") == selected_stat else Color.WHITE

func _render_sources(data: Dictionary) -> void:
	if not is_instance_valid(source_body):
		return
	WindowControls.clear_children(source_body)
	var values: Dictionary = data["values"]
	_source_line("当前值  "+format_value(selected_stat,float(values.get(selected_stat,0))),
		Color("a7dd74"),12)
	var sources: Array = data["sources"].get(selected_stat,[])
	for source: Dictionary in sources:
		var op := String(source.get("op","add"))
		var amount := float(source.get("value",0))
		var operation: String = String({"base":"基础","add":"增加","percent":"比例","mul":"乘算"}.get(op,op))
		var value_text := format_source_value(selected_stat,op,amount)
		_source_line("%s\n  %s  %s" % [String(source.get("source","基础")),operation,value_text],
			Color("d4c9b1"),11)
	if sources.is_empty():
		_source_line("由基础属性、装备、技能与当前效果计算",Color("b9b1a0"),11)
	if game.session.state=="battle" and is_instance_valid(game.battle):
		var effects: Array = game.combat.read_view().get("effects",[])
		if not effects.is_empty():
			_source_line("当前效果",Color("f0d18a"),12)
			for effect: Dictionary in effects:
				_source_line("%s  %.1fs" % [effect["definition"].get("name",effect["id"]),
					float(effect["remaining_ms"])/1000],Color("a7dd74"),10)

func _source_line(value: String, color: Color, size: int) -> void:
	var label := Label.new()
	label.text = game.skin.chinese(value)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_override("font",game.skin.font)
	label.add_theme_font_size_override("font_size",size)
	label.add_theme_color_override("font_color",color)
	source_body.add_child(label)

func format_value(id: String, value: float) -> String:
	if id in PERCENT_STATS:
		return "%.1f%%" % (value*100)
	if id in RATIO_STATS:
		return "%.3f×" % value
	if id in ["hp_regen","mp_regen"]:
		return "%.2f/s" % value
	if id == "carry_capacity":
		return "%.1f kg" % value
	if id in ["hp_max","mp_max"]:
		return "%.0f" % value
	return "%.2f" % value

func format_source_value(stat: String, op: String, value: float) -> String:
	if op == "percent":
		return "%+.1f%%" % (value*100)
	if op == "mul":
		return "×%.3f" % value
	return format_value(stat,value)

func equipment(node: Control) -> void:
	var profile: Dictionary = game.session.profile
	var cfg := Numbers.shared_config()
	var instances: Array = profile["gear"].keys()
	instances.sort_custom(func(a,b):
		var da: Dictionary=cfg["equipment"][profile["gear"][a]["definition"]]
		var db: Dictionary=cfg["equipment"][profile["gear"][b]["definition"]]
		return (String(da["slot"])+"|"+String(da["name"])+"|"+String(a)).naturalnocasecmp_to(
			String(db["slot"])+"|"+String(db["name"])+"|"+String(b))<0)
	page = clampi(page,0,maxi(0,(instances.size()-1)/5))
	if selected_gear_uid=="" or not profile["gear"].has(selected_gear_uid):
		selected_gear_uid = String(instances[page*5]) if not instances.is_empty() else ""
	var scroll := ScrollContainer.new()
	scroll.name = "number_equipment_list_scroll"
	scroll.position = Vector2(18,104)
	scroll.size = Vector2(350,244)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content.add_child(scroll)
	var list := VBoxContainer.new()
	list.name = "number_equipment_list"
	list.add_theme_constant_override("separation",3)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	for index in mini(5,instances.size()-page*5):
		var uid: String = instances[page*5+index]
		var instance: Dictionary = profile["gear"][uid]
		var definition: Dictionary = cfg["equipment"][instance["definition"]]
		var equipped: bool = profile["equipment"].get(definition["slot"],"")==uid
		var row := Button.new()
		row.name = "number_gear_"+uid
		row.flat = true
		row.focus_mode = Control.FOCUS_ALL
		row.custom_minimum_size = Vector2(330,45)
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.add_theme_font_override("font",game.skin.font)
		row.add_theme_font_size_override("font_size",11)
		row.text = "%s +%d　编号%s　品质%d%s\n%s" % [
			definition["name"],instance["reinforce"],uid.trim_prefix("gear_"),instance["quality"],
			"　已装备" if equipped else "",SLOT_NAMES.get(definition["slot"],definition["slot"])]
		row.set_meta("uid",uid)
		row.pressed.connect(select_gear.bind(uid))
		row.focus_entered.connect(select_gear.bind(uid))
		list.add_child(row)
		gear_rows[uid] = row
	if instances.is_empty():
		var empty: Label = game.skin.label(content,"暂无装备实例",Vector2(20,120),11,Color("b9b1a0"))
		empty.name = "number_equipment_empty"
	_update_gear_rows()
	_button("上一页",Vector2(18,356),func(): change_equipment_page(-1),false,"page").name = "number_equipment_prev"
	_button("下一页",Vector2(126,356),func(): change_equipment_page(1),false,"page").name = "number_equipment_next"
	game.skin.label(node,"%d / %d 页 · 共 %d 件" % [page+1,maxi(1,(instances.size()+4)/5),instances.size()],
		Vector2(18,392),10)
	var detail_scroll := ScrollContainer.new()
	detail_scroll.name = "number_equipment_detail_scroll"
	detail_scroll.position = Vector2(380,104)
	detail_scroll.size = Vector2(344,224)
	detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content.add_child(detail_scroll)
	equipment_body = VBoxContainer.new()
	equipment_body.name = "number_equipment_detail"
	equipment_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	equipment_body.add_theme_constant_override("separation",6)
	detail_scroll.add_child(equipment_body)
	var action := _button("装备",Vector2(380,338),toggle_equipment,true)
	action.name = "number_equipment_action"
	_render_equipment_detail()

func select_gear(uid: String) -> void:
	if uid == selected_gear_uid or uid=="":
		return
	selected_gear_uid = uid
	_update_gear_rows()
	_render_equipment_detail()

func _update_gear_rows() -> void:
	for uid: String in gear_rows:
		var row: Button = gear_rows[uid]
		if is_instance_valid(row):
			row.modulate = Color("ffdd85") if uid == selected_gear_uid else Color.WHITE

func change_equipment_page(step: int) -> void:
	var total := maxi(1,ceili(float(game.session.profile["gear"].size())/5.0))
	page = clampi(page+step,0,total-1)
	_render_content()

func _render_equipment_detail() -> void:
	if not is_instance_valid(equipment_body):
		return
	WindowControls.clear_children(equipment_body)
	var profile: Dictionary = game.session.profile
	if selected_gear_uid=="" or not profile["gear"].has(selected_gear_uid):
		_equipment_line("请选择具体装备实例",Color("b9b1a0"),11)
		return
	var cfg := Numbers.shared_config()
	var instance: Dictionary = profile["gear"][selected_gear_uid]
	var definition: Dictionary = cfg["equipment"][instance["definition"]]
	var slot := String(definition["slot"])
	var equipped_uid := String(profile["equipment"].get(slot,""))
	var equipped := equipped_uid == selected_gear_uid
	_equipment_line(String(definition["name"])+"  +%d" % int(instance["reinforce"]),Color("f0d18a"),16)
	_equipment_line("编号 %s · 品质 %d · %s" % [selected_gear_uid.trim_prefix("gear_"),
		int(instance["quality"]),SLOT_NAMES.get(slot,slot)],Color("c9bda3"),11)
	_equipment_line("耐久 %d / %d%s" % [int(instance["durability"]),int(instance["durability_max"]),
		" · 属性失效" if int(instance["durability"])==0 else ""],
		Color("ff7777") if int(instance["durability"])==0 else Color("a7dd74"),11)
	var properties := Numbers.gear_detail(profile,selected_gear_uid)
	_equipment_line("本件属性",Color("f0d18a"),12)
	if properties.is_empty():
		_equipment_line("无直接属性",Color("b9b1a0"),10)
	for stat: String in properties:
		_equipment_line("%s  %+.2f" % [NAMES.get(stat,stat),float(properties[stat])],Color("a7dd74"),10)
	var current: Dictionary = Numbers.profile_stats(profile)["values"]
	var preview_profile := profile.duplicate(true)
	preview_profile["equipment"][slot] = selected_gear_uid
	var preview: Dictionary = Numbers.profile_stats(preview_profile)["values"]
	_equipment_line("换装比较",Color("f0d18a"),12)
	var changed := false
	for stat: String in COMPARE_STATS:
		var before := float(current.get(stat,0))
		var after := float(preview.get(stat,0))
		if is_equal_approx(before,after):
			continue
		changed = true
		_equipment_line("%s  %s → %s" % [NAMES.get(stat,stat),
			format_value(stat,before),format_value(stat,after)],Color("d8c690"),10)
	if not changed:
		_equipment_line("当前面板无变化",Color("b9b1a0"),10)
	_equipment_line("当前%s：%s" % [SLOT_NAMES.get(slot,slot),
		cfg["equipment"][profile["gear"][equipped_uid]["definition"]]["name"] if equipped_uid!="" else "空"],
		Color("c9bda3"),10)
	var action := content.find_child("number_equipment_action",true,false) as Button
	if is_instance_valid(action):
		action.set_meta("action_label",game.skin.chinese("卸下" if equipped else "装备"))
		var caption = action.get("caption")
		if caption is Label:
			caption.text = game.skin.chinese("卸下" if equipped else "装备")

func _equipment_line(value: String, color: Color, size: int) -> void:
	var label := Label.new()
	label.text = game.skin.chinese(value)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_override("font",game.skin.font)
	label.add_theme_font_size_override("font_size",size)
	label.add_theme_color_override("font_color",color)
	equipment_body.add_child(label)

func toggle_equipment() -> void:
	if selected_gear_uid=="" or not game.session.profile["gear"].has(selected_gear_uid):
		WindowControls.set_feedback(feedback,"请先选择装备")
		return
	var profile: Dictionary = game.session.profile
	var definition: Dictionary = Numbers.shared_config()["equipment"][profile["gear"][selected_gear_uid]["definition"]]
	var slot := String(definition["slot"])
	var equipped := String(profile["equipment"].get(slot,"")) == selected_gear_uid
	var kind := "numbers.gear_unequip" if equipped else "numbers.gear_equip"
	var ok: bool = game.act(kind,{"uid":selected_gear_uid,"slot":slot})
	if not ok:
		WindowControls.set_feedback(feedback,String(game.notification))
		return
	_render_content()
	WindowControls.set_feedback(feedback,"已卸下装备" if equipped else "已装备 "+String(definition["name"]))
	var action := content.find_child("number_equipment_action",true,false) as Button
	if is_instance_valid(action):
		action.call_deferred("grab_focus")
