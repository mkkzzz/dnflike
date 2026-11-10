extends RefCounted
const Numbers = preload("res://stats/api/numbers.gd")
const Names = preload("res://ui/flow/number_windows.gd")
var game
func _init(target) -> void:game = target

func execute(words: PackedStringArray) -> Dictionary:
	var cmd := words[0].to_lower()
	var args := words.slice(1)
	match cmd:
		"element":
			if args.size()!=1:return fail("用法：element none|fire|water|light|dark")
			return mutate("numbers.element",{"element":args[0]})
		"growtype":
			if args.size()!=1:return fail("用法：growtype swordman|weaponmaster|soulbringer|berserker|asura")
			return mutate("numbers.growtype",{"growtype":args[0]})
		"job":
			if args.size()!=1:return fail("用法：job swordman|weaponmaster|soulbringer|berserker|asura")
			return mutate("numbers.growtype",{"growtype":args[0],"force":true})
		"awakening":
			if args.size()!=1 or not args[0].is_valid_int():return fail("用法：awakening 0|1|2")
			return set_awakening(int(args[0]))
		"xp", "sp":
			if args.size()!=1 or not args[0].is_valid_int():return fail("用法：xp 数量 / sp 数量")
			return mutate("numbers."+cmd,{"amount":int(args[0]),"transaction":"gm:%d:%d" % [Time.get_ticks_usec(),game.session.profile["xp_transactions"].size()]})
		"skill":
			if args.size()==1 and args[0]=="reset":return mutate("numbers.skill_reset",{})
			if args.size()==1 and args[0] in ["list","learned"]:return skill_list("current" if args[0]=="list" else "learned")
			if args.size()==2 and args[0]=="list":return skill_list(args[1])
			if args.size()==2 and args[0]=="maxjob":return set_job_skills(args[1])
			if args.size()!=2:return fail("用法：skill upper|draw|triple|rage_slash|buff|guard|physical_mastery 等级；skill reset")
			if args[1] in ["+","-"]:return mutate("numbers.skill",{"id":args[0],"delta":1 if args[1]=="+" else -1})
			if args[1]=="max":
				var entry := skill_entry(args[0])
				if entry.is_empty():return fail("技能不存在")
				return mutate("numbers.skill_grant",{"id":args[0],"level":runtime_max_level(entry)})
			if not args[1].is_valid_int():return fail("技能等级必须为整数")
			return mutate("numbers.skill_grant",{"id":args[0],"level":int(args[1])})
		"stat":
			if args.size()==1 and args[0]=="clear":return mutate("numbers.modifier_clear",{})
			if args.size()!=2 or not args[1].is_valid_float():return fail("用法：stat 属性 增量；stat clear")
			return mutate("numbers.modifier",{"modifier":{"stat":args[0],"op":"add","value":float(args[1]),"source":"GM 调试"}})
		"stats":
			var result: Dictionary = game.number_windows.live_stats()
			if args.size()==1:
				return {"ok":true,"message":"%s = %s\n%s" % [Names.NAMES.get(args[0],args[0]),result["values"].get(args[0],"无此属性"),JSON.stringify(result["sources"].get(args[0],[])," ")]}
			var text := ""
			for id: String in result["values"]:text += "%s %s  " % [Names.NAMES.get(id,id),result["values"][id]]
			return {"ok":true,"message":text}
		"gear":
			if args.size()==0:return fail("用法：gear list|catalog|kit|best|give|equip|unequip|reinforce|enchant|repairall|breakall|reinforceall")
			if args[0]=="list":return gear_list()
			if args[0]=="catalog":
				if args.size()>3:return fail("用法：gear catalog [部位] [关键词]")
				return gear_catalog(args[1] if args.size()>=2 else "",args[2] if args.size()>=3 else "")
			if args[0]=="kit":
				if args.size()>2 or args.size()==2 and not args[1].is_valid_int():return fail("用法：gear kit [品质]")
				return gear_kit(int(args[1]) if args.size()==2 else 100)
			if args[0]=="best":
				if args.size() not in [2,3] or args.size()==3 and not args[2].is_valid_int():return fail("用法：gear best 部位 [品质]")
				return gear_best(args[1],int(args[2]) if args.size()==3 else 100)
			if args[0]=="repairall":return edit_all_gear("repair")
			if args[0]=="breakall":return edit_all_gear("break")
			if args[0]=="reinforceall":
				if args.size()!=2 or not args[1].is_valid_int():return fail("用法：gear reinforceall 0~30")
				return edit_all_gear("reinforce",int(args[1]))
			if args[0]=="unequipall":return edit_all_gear("unequip")
			if args[0]=="give" and args.size() in [2,3]:
				if args.size()==3 and not args[2].is_valid_int():return fail("品质必须为整数")
				return mutate("numbers.gear_give",{"id":args[1],"quality":int(args[2]) if args.size()==3 else 50})
			if args[0]=="equip" and args.size()==2:return mutate("numbers.gear_equip",{"uid":args[1]})
			if args[0]=="unequip" and args.size()==2:return mutate("numbers.gear_unequip",{"slot":args[1]})
			if args[0]=="reinforce" and args.size()==3 and args[2].is_valid_int():return mutate("numbers.reinforce",{"uid":args[1],"level":int(args[2])})
			if args[0]=="enchant" and args.size()==4 and args[3].is_valid_float():return mutate("numbers.enchant",{"uid":args[1],"modifier":{"stat":args[2],"op":"add","value":float(args[3])}})
			return fail("装备命令参数无效")
		"buff", "unbuff":
			if not active():return fail("请先进入战斗")
			if args.size() not in [1,2] or args.size()==2 and not args[1].is_valid_int():return fail("用法：buff|unbuff 效果ID [目标实体ID]；默认自己")
			var ok: bool = game.combat.apply_effect({"kind":"effect" if cmd=="buff" else "remove_effect","id":args[0],"target":int(args[1]) if args.size()==2 else 0})
			return {"ok":ok,"message":"效果已更新" if ok else "效果或目标无效"}
		"monster":
			if not active():return fail("请先进入战斗")
			if args.size()!=1 or not args[0].is_valid_int():return fail("用法：monster 等级")
			var ok: bool = game.combat.configure_monsters(int(args[0]),String(game.session.run.get("difficulty","normal")))
			return {"ok":ok,"message":"当前与后续怪物等级已更新" if ok else "怪物等级超出范围"}
		"damage":
			if not active():return fail("请先进入战斗")
			return {"ok":true,"message":JSON.stringify(game.combat.read_view()["last_damage"]," ")}
	return {}

func skill_panel():
	return game.number_windows.skill_panel

func skill_entry(token: String) -> Dictionary:
	var panel = skill_panel()
	for skill: Dictionary in panel.skills:
		if token in [String(skill.get("local_id","")),String(skill.get("key","")),str(int(skill.get("id",-1)))]:
			return skill
	return {}

func runtime_max_level(skill: Dictionary) -> int:
	var local := String(skill.get("local_id",""))
	var definition: Dictionary = Numbers.shared_config().get("skills",{}).get(local,{})
	return int(definition.get("max_level",skill.get("max_level",0)))

func current_tree_ids() -> Dictionary:
	var result := {}
	var panel = skill_panel()
	for node: Dictionary in panel.tree_nodes(panel.current_branch()):
		result[int(node.get("id",-1))] = true
	return result

func skill_list(scope := "current") -> Dictionary:
	var panel = skill_panel()
	var current := current_tree_ids()
	var rows: Array[Dictionary] = []
	for skill: Dictionary in panel.skills:
		var local := String(skill.get("local_id",""))
		var learned := int(game.session.profile.get("skills",{}).get(local,0)) if local != "" else 0
		if scope == "learned" and learned <= 0:continue
		if scope in ["current","learned"] and not current.has(int(skill.get("id",-1))):continue
		rows.append(skill)
	rows.sort_custom(func(a,b): return String(a.get("name","")) < String(b.get("name","")))
	var lines: PackedStringArray = []
	for index in mini(rows.size(),32):
		var skill: Dictionary = rows[index]
		var local := String(skill.get("local_id",""))
		var rank := int(game.session.profile.get("skills",{}).get(local,0)) if local != "" else 0
		lines.append("%s  %d/%d  %s" % [local if local != "" else "-",rank,runtime_max_level(skill),String(skill.get("name",""))])
	if lines.is_empty():return fail("没有匹配的技能")
	if rows.size() > lines.size():lines.append("……共 %d 项，使用 skill 技能名 max 调整" % rows.size())
	return {"ok":true,"message":"\n".join(lines)}

func set_job_skills(mode: String) -> Dictionary:
	if mode not in ["active","passive","all"]:return fail("用法：skill maxjob active|passive|all")
	if game.session.state != "town":return fail("请先回城再批量修改技能")
	var panel = skill_panel()
	var current := current_tree_ids()
	var candidate = session_candidate()
	var changed := 0
	for skill: Dictionary in panel.skills:
		if not current.has(int(skill.get("id",-1))):continue
		var local := String(skill.get("local_id",""))
		if local == "" or not Numbers.shared_config().get("skills",{}).has(local):continue
		var passive := "[passive]" in String(skill.get("type",""))
		if mode == "active" and passive or mode == "passive" and not passive:continue
		var response: Dictionary = candidate.command("numbers.skill_grant",{"id":local,"level":runtime_max_level(skill)})
		if not response.get("ok",false):return fail("技能 %s 修改失败：%s" % [local,String(response.get("message",""))])
		changed += 1
	if changed == 0:return fail("当前职业没有可批量修改的技能")
	return commit_candidate(candidate,"已将当前职业 %d 个技能设为满级" % changed,"numbers.skill")

func set_awakening(stage: int) -> Dictionary:
	if stage < 0 or stage > 2:return fail("觉醒阶段必须为 0、1 或 2")
	var profile: Dictionary = game.session.profile
	if String(profile.get("growtype","swordman")) == "swordman" and stage != 0:
		return fail("基础鬼剑士不能设置觉醒阶段")
	var candidate = session_candidate()
	candidate.profile["awakening_stage"] = stage
	Numbers.normalize(candidate.profile)
	if not Numbers.valid(candidate.profile):return fail("觉醒阶段写入后校验失败")
	return commit_candidate(candidate,"觉醒阶段已设为 %d" % stage,"numbers.update")

func gear_list() -> Dictionary:
	var profile: Dictionary = game.session.profile
	var cfg := Numbers.shared_config()
	var lines: PackedStringArray = []
	var uids: Array = profile.get("gear",{}).keys()
	uids.sort()
	for uid: String in uids:
		var instance: Dictionary = profile["gear"][uid]
		var definition: Dictionary = cfg["equipment"].get(instance.get("definition",""),{})
		var slot := String(definition.get("slot",""))
		var equipped := String(profile.get("equipment",{}).get(slot,"")) == uid
		lines.append("%s %s +%d  品质%d  %s/%d%s" % [uid.trim_prefix("gear_"),String(definition.get("name",uid)),
			int(instance.get("reinforce",0)),int(instance.get("quality",0)),int(instance.get("durability",0)),
			int(instance.get("durability_max",0)),"  [已装备]" if equipped else ""])
	if lines.is_empty():return fail("当前角色没有装备实例")
	return {"ok":true,"message":"\n".join(lines)}

func gear_catalog(slot: String, keyword: String) -> Dictionary:
	var cfg := Numbers.shared_config()
	var profile: Dictionary = game.session.profile
	var needle := keyword.to_lower()
	var rows: Array[Dictionary] = []
	for id: String in cfg.get("equipment",{}):
		var definition: Dictionary = cfg["equipment"][id]
		if slot != "" and String(definition.get("slot","")) != slot:continue
		if needle != "" and not (id.to_lower().contains(needle) or String(definition.get("name","")).to_lower().contains(needle)):continue
		if int(definition.get("required_level",1)) > int(profile.get("level",1)):continue
		if not Numbers.Equipment.usable(profile,definition):continue
		rows.append({"id":id,"definition":definition})
	rows.sort_custom(func(a,b):
		var da: Dictionary=a["definition"]
		var db: Dictionary=b["definition"]
		return int(da.get("required_level",1)) > int(db.get("required_level",1)) or \
			int(da.get("required_level",1)) == int(db.get("required_level",1)) and String(da.get("name","")) < String(db.get("name","")))
	var lines: PackedStringArray = []
	for index in mini(rows.size(),24):
		var row: Dictionary = rows[index]
		var definition: Dictionary = row["definition"]
		lines.append("%s  Lv%d  %s  %s" % [String(definition.get("slot","")),int(definition.get("required_level",1)),
			String(definition.get("name","")),String(row["id"])])
	if lines.is_empty():return fail("当前等级没有匹配装备")
	if rows.size() > lines.size():lines.append("……共 %d 项" % rows.size())
	return {"ok":true,"message":"\n".join(lines)}

func gear_kit(quality: int) -> Dictionary:
	if quality < 0 or quality > 100:return fail("品质范围为 0 至 100")
	if game.session.state != "town":return fail("请先回城再生成整套装备")
	var candidate = session_candidate()
	var cfg := Numbers.shared_config()
	var changed := 0
	for slot: String in cfg.get("equipment_slots",[]):
		var definition_id := best_equipment(candidate.profile,slot)
		if definition_id == "":continue
		var given: Dictionary = candidate.command("numbers.gear_give",{"id":definition_id,"quality":quality})
		if not given.get("ok",false):return fail("生成 %s 失败：%s" % [slot,String(given.get("message",""))])
		var equipped: Dictionary = candidate.command("numbers.gear_equip",{"uid":given["uid"]})
		if not equipped.get("ok",false):return fail("装备 %s 失败：%s" % [slot,String(equipped.get("message",""))])
		changed += 1
	if changed == 0:return fail("当前等级没有可自动装备的整套装备")
	return commit_candidate(candidate,"已生成并装备 %d 件当前等级最优装备" % changed,"numbers.gear_equip")

func gear_best(slot: String, quality: int) -> Dictionary:
	if quality < 0 or quality > 100:return fail("品质范围为 0 至 100")
	if game.session.state != "town":return fail("请先回城再更换装备")
	var candidate = session_candidate()
	var definition_id := best_equipment(candidate.profile,slot)
	if definition_id == "":return fail("当前等级没有可用部位：" + slot)
	var given: Dictionary = candidate.command("numbers.gear_give",{"id":definition_id,"quality":quality})
	if not given.get("ok",false):return given
	var equipped: Dictionary = candidate.command("numbers.gear_equip",{"uid":given["uid"]})
	if not equipped.get("ok",false):return equipped
	return commit_candidate(candidate,"已装备 %s：%s" % [slot,String(Numbers.shared_config()["equipment"][definition_id]["name"])],"numbers.gear_equip")

func best_equipment(profile: Dictionary, slot: String) -> String:
	var cfg := Numbers.shared_config()
	var best_id := ""
	var best_required := -1
	var best_score := -INF
	for id: String in cfg.get("equipment",{}):
		var definition: Dictionary = cfg["equipment"][id]
		if String(definition.get("slot","")) != slot:continue
		var required := int(definition.get("required_level",1))
		if required > int(profile.get("level",1)) or not Numbers.Equipment.usable(profile,definition):continue
		var score := 0.0
		for value in definition.get("stats",{}).values():score += absf(float(value))
		if required > best_required or required == best_required and score > best_score:
			best_id = id
			best_required = required
			best_score = score
	return best_id

func edit_all_gear(action: String, level := 0) -> Dictionary:
	if game.session.state != "town":return fail("请先回城再修改装备")
	if action == "reinforce" and (level < 0 or level > 30):return fail("强化等级必须为 0~30")
	var candidate = session_candidate()
	if action == "unequip":
		for slot: String in candidate.profile.get("equipment",{}).keys():
			var unequipped: Dictionary=candidate.command("numbers.gear_unequip",{"slot":slot})
			if not unequipped.get("ok",false):return fail("卸下 %s 失败：%s" % [slot,String(unequipped.get("message",""))])
	elif candidate.profile.get("gear",{}).is_empty():
		return fail("当前角色没有装备实例")
	else:
		for instance: Dictionary in candidate.profile["gear"].values():
			if action == "repair":instance["durability"] = int(instance.get("durability_max",1))
			elif action == "break":instance["durability"] = 0
			else:instance["reinforce"] = level
	Numbers.normalize(candidate.profile)
	if not Numbers.valid(candidate.profile):return fail("装备修改后校验失败")
	var message: String = String({"repair":"全部装备已修复","break":"全部装备耐久已设为 0",
		"reinforce":"全部装备强化已设为 +%d" % level,"unequip":"已卸下全部装备"}.get(action,"装备已更新"))
	return commit_candidate(candidate,message,"numbers.gear_equip" if action=="unequip" else "numbers.reinforce")

func session_candidate():
	var candidate = game.Session.new()
	candidate.profile = game.session.profile.duplicate(true)
	candidate.run = game.session.run.duplicate(true)
	candidate.state = game.session.state
	candidate.result = game.session.result.duplicate(true)
	return candidate

func commit_candidate(candidate, message: String, sync_kind: String) -> Dictionary:
	if not Numbers.valid(candidate.profile):return fail("候选角色数值校验失败")
	if not game.store.write(candidate):
		game.save_failed = true
		return fail("存档写入失败，变更未提交")
	game.session = candidate
	game.save_failed = false
	game.sync_number_changes(sync_kind)
	if game.overlay == "numbers":game.show_overlay("numbers")
	return {"ok":true,"message":message}

func active() -> bool:
	return game.session.state=="battle" and is_instance_valid(game.battle)

func mutate(kind: String, payload: Dictionary) -> Dictionary:
	if kind=="numbers.skill" or kind.begins_with("numbers.gear_"):
		var saved: bool=game.item_action(kind,payload)
		if game.overlay=="numbers":game.show_overlay("numbers")
		return {"ok":saved,"message":"变更已保存" if saved else "变更未提交"}
	var response: Dictionary = game.session.command(kind,payload)
	if not response["ok"]:return response
	game.sync_number_changes(kind)
	var saved: bool = game.save_profile()
	if game.overlay=="numbers":game.show_overlay("numbers")
	return {"ok":saved,"message":("数值已更新" if saved else "数值已更新，但存档失败")+(" · "+String(response["uid"]) if response.has("uid") else "")}

func fail(message: String) -> Dictionary:return {"ok":false,"message":message}
