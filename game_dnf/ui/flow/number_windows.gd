extends RefCounted
## Existing native skin only. Every displayed value comes from the live numeric APIs.
const Numbers = preload("res://stats/api/numbers.gd")
const SkillPanel = preload("res://ui/flow/skill_panel.gd")
var game
var skill_panel
var tab := 0
var page := 0
var selected_stat := "physical_attack"
const NAMES := {"hp_max":"生命上限","mp_max":"魔法上限","strength":"力量","intelligence":"智力","vitality":"体力","spirit":"精神","physical_attack":"基础物攻","magical_attack":"基础魔攻","independent_attack":"独立攻击","physical_panel":"物理攻击面板","magical_panel":"魔法攻击面板","physical_defense":"物理防御","magical_defense":"魔法防御","hit":"命中修正","evasion":"回避率","physical_crit":"物理暴击","magical_crit":"魔法暴击","attack_speed":"攻击速度","move_speed":"移动速度","cast_speed":"施放速度","cooldown_rate":"冷却系数","mp_cost_rate":"蓝耗系数","fire_attack":"火属性强化","water_attack":"冰属性强化","light_attack":"光属性强化","dark_attack":"暗属性强化","fire_resist":"火属性抗性","water_resist":"冰属性抗性","light_resist":"光属性抗性","dark_resist":"暗属性抗性","damage_rate":"伤害系数","taken_rate":"承伤系数","skill_rate":"技能伤害系数","hp_regen":"每秒回血","mp_regen":"每秒回蓝","status_resist":"异常抗性","hit_recovery":"硬直恢复","jump_power":"跳跃力","physical_independent_attack":"物理独立","magical_independent_attack":"魔法独立","carry_capacity":"负重上限"}
const SLOT_NAMES := {"weapon":"武器","coat":"上衣","pants":"下装","shoulder":"头肩","belt":"腰带","shoes":"鞋","bracelet":"手镯","necklace":"项链","ring":"戒指"}

func _init(target) -> void:
	game = target
	skill_panel = SkillPanel.new(target)

func show_window() -> void:
	var skin = game.skin
	var node = game.windows.board(game.modal,"角色成长",Rect2(28,38,744,458))
	node.name = "number_window"
	for index in 3:
		var value := index
		skin.button(node,["角色属性","技能加点","装备管理"][index],Vector2(18+index*115,40),func(): tab=value; page=0; game.show_overlay("numbers"))
	if tab == 0:attributes(node)
	elif tab == 1:skill_panel.show_window(node)
	else:equipment(node)
	skin.label(node,"O 角色成长   K 技能加点   Esc 关闭",Vector2(20,428),11,Color("a59c88"))

func live_stats() -> Dictionary:
	if game.session.state=="battle" and is_instance_valid(game.battle):
		var view: Dictionary = game.combat.read_view()
		return {"values":view["numbers"],"sources":view["sources"]}
	return Numbers.profile_stats(game.session.profile)

func attributes(node: Control) -> void:
	var skin = game.skin
	var data := live_stats()
	var values: Dictionary = data["values"]
	var keys: Array = NAMES.keys()
	var start := page*18
	skin.label(node,"%s  Lv.%d" % [game.session.profile["name"],game.session.profile["level"]],Vector2(20,78),14,Color("f0d18a"))
	for index in mini(18,keys.size()-start):
		var id: String = keys[start+index]
		var x := 20+(index/9)*225
		var y := 111+(index%9)*30
		var name: Button = skin.button(node,NAMES[id],Vector2(x,y),func(): selected_stat=id; game.show_overlay("numbers"),false)
		name.size.x = 130
		var value := float(values.get(id,0))
		var formatted := "%.1f%%" % (value*100) if id in ["hit","evasion","physical_crit","magical_crit","attack_speed","move_speed","cast_speed","status_resist"] else "%.2f" % value
		skin.label(node,formatted,Vector2(x+140,y+3),12,Color("a7dd74"))
	skin.button(node,"上一页",Vector2(20,389),func(): page=maxi(0,page-1); game.show_overlay("numbers"),false)
	skin.button(node,"下一页",Vector2(130,389),func(): page=mini((keys.size()-1)/18,page+1); game.show_overlay("numbers"),false)
	skin.label(node,"属性来源 · "+String(NAMES.get(selected_stat,selected_stat)),Vector2(479,86),13,Color("f0d18a"))
	var lines := ""
	for source: Dictionary in data["sources"].get(selected_stat,[]):
		lines += "%s\n  %s %.3f\n" % [NAMES.get(source.get("source","基础"),source.get("source","基础")),{"base":"基础","add":"增加","percent":"比例增加","mul":"乘以"}.get(source.get("op","add"),"增加"),source.get("value",0)]
	var label: Label = skin.label(node,lines if lines!="" else "由基础攻击与主属性计算",Vector2(480,117),11)
	label.size = Vector2(238,254)
	label.clip_text = true
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if game.session.state=="battle":
		var effects: Array = game.combat.read_view()["effects"]
		var text := "当前效果："
		for effect: Dictionary in effects:text += "%s %.1fs  " % [effect["definition"].get("name",effect["id"]),float(effect["remaining_ms"])/1000]
		skin.label(node,text,Vector2(480,385),10)

func equipment(node: Control) -> void:
	var cfg := Numbers.config()
	var skin = game.skin
	var profile: Dictionary = game.session.profile
	var instances: Array = profile["gear"].keys()
	skin.label(node,"每件装备分别保存品质、强化与附魔",Vector2(20,80),13,Color("f0d18a"))
	page = clampi(page,0,maxi(0,(instances.size()-1)/5))
	for index in mini(5,instances.size()-page*5):
		var uid: String = instances[page*5+index]
		var instance: Dictionary = profile["gear"][uid]
		var definition: Dictionary = cfg["equipment"][instance["definition"]]
		var equipped: bool = profile["equipment"].get(definition["slot"],"")==uid
		var y := 116+index*52
		skin.label(node,"%s +%d%s" % [definition["name"],instance["reinforce"],"（已装备）" if equipped else ""],Vector2(20,y),12,Color("a7dd74") if equipped else Color.WHITE)
		var description := "编号 %s · 品质 %d · 等级 %d" % [uid.trim_prefix("gear_"),instance["quality"],definition["required_level"]]
		var properties: Dictionary = Numbers.gear_detail(profile,uid)
		for stat: String in properties:description += "  %s +%.1f" % [NAMES.get(stat,stat),properties[stat]]
		var detail: Label = skin.label(node,description,Vector2(20,y+21),10,Color("b9b1a0"))
		detail.size = Vector2(431,28)
		detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		detail.clip_text = true
		var gear_uid := uid
		var slot: String = definition["slot"]
		skin.button(node,"卸下" if equipped else "装备",Vector2(465,y),func():
			if game.act("numbers.gear_unequip" if equipped else "numbers.gear_equip",{"uid":gear_uid,"slot":slot}):game.show_overlay("numbers"),false)
	skin.button(node,"上一页",Vector2(20,389),func(): page=maxi(0,page-1); game.show_overlay("numbers"),false)
	skin.button(node,"下一页",Vector2(130,389),func(): page+=1; game.show_overlay("numbers"),false)
	var text := "已装备部位\n\n"
	for slot: String in cfg["equipment_slots"]:
		var uid: String = profile["equipment"].get(slot,"")
		text += "%s：%s\n\n" % [SLOT_NAMES[slot],cfg["equipment"][profile["gear"][uid]["definition"]]["name"] if uid!="" else "空"]
	skin.label(node,text,Vector2(570,91),11)
