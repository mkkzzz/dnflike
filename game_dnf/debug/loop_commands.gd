extends RefCounted
## Bounded GM commands. No evaluation of GDScript or shell expressions.
const NumberCommands = preload("res://debug/number_commands.gd")
const RuntimeAPI = preload("res://debug/runtime_api.gd")
const HELP := "help 帮助 / status 状态 / save 保存 / town 回城\n角色：level 1~60 / job 职业 / awakening 0~2 / xp 数量 / sp 数量\n技能：skill list [current|learned] / skill 技能 max / skill maxjob active|passive|all / skill reset\n装备：gear kit|list|catalog|best 部位|give|equip|reinforce|enchant|repairall|breakall|reinforceall|unequipall\n副本：dungeon list|select ID|enter [ID]|restart / difficulty normal|adventure|expert|king\n房间：room 1~N|next|boss / spawn current|goblin|thrower|chief 1~20 / clear / win / lose\n任务：quest list available|active|ready|completed / quest current / quest info ID\n任务：quest accept ID / quest ready ID / quest claim ID [奖励] / quest readyall / quest track ID / quest abandon ID\n战斗：spawn current 数量 / god [on|off] / heal / cooldown / collision [on|off] / weapon katana|shortsword|greatsword\n数值：stat 属性 增量 / stats [属性] / buff|unbuff 效果 [目标] / monster 等级 / damage"
var game

func _init(target) -> void:game = target
func result(ok: bool, message: String) -> Dictionary:return {"ok": ok, "message": message}

func execute(text: String) -> Dictionary:
	var words := text.strip_edges().replace("\t", " ").split(" ", false)
	if words.is_empty():return result(false, "请输入命令；help 查看帮助")
	var numerical: Dictionary = NumberCommands.new(game).execute(words)
	if not numerical.is_empty():return numerical
	var cmd := words[0].to_lower()
	var args := words.slice(1)
	match cmd:
		"native":return preload("res://debug/native_commands.gd").execute(args)
		"help":return result(true, HELP)
		"status":return result(true, status())
		"save":return result(game.save_profile(), "进度已保存" if not game.save_failed else "保存失败，请检查存档目录")
		"dungeon":
			return dungeon_command(args)
		"difficulty":
			if args.size()!=1 or args[0] not in ["normal","adventure","expert","king"]:
				return result(false,"用法：difficulty normal|adventure|expert|king")
			var changed: bool=game.act("flow.difficulty",{"id":args[0]})
			return result(changed,"难度已设为 "+String(args[0]) if changed else "难度修改失败")
		"quest":
			return quest_command(args)
		"town":
			back_to_town()
			return result(true, "已回到城镇；未通关的战斗按撤退处理")
		"give":
			if args.size() != 2 or not game.Catalog.ITEMS.has(args[0]) or not positive_int(args[1], 999):return result(false, "用法：give potion|iron_sword|forest_sword 1~999")
			game.session.add_item(args[0], int(args[1]))
			return persist("获得 %s ×%d" % [game.Catalog.ITEMS[args[0]]["name"], int(args[1])])
		"gold":
			if args.size() != 1 or not positive_int(args[0], 999999):return result(false, "用法：gold 1~999999（增加金币）")
			game.session.profile["gold"] += int(args[0])
			return persist("金币增加 %d" % int(args[0]))
		"level":
			if args.size()!=1 or not args[0].is_valid_int():return result(false,"用法：level 等级")
			return NumberCommands.new(game).mutate("numbers.level",{"level":int(args[0])})

	if cmd not in ["heal", "cooldown", "god", "collision", "clear", "room", "spawn", "weapon", "win", "lose"]:return result(false, "未知命令：%s；help 查看帮助" % cmd)
	if game.session.state != "battle" or not is_instance_valid(game.battle) or not game.combat.is_running():
		return result(false, "此命令需要进行中的战斗；先用 dungeon enter")
	var api = RuntimeAPI.new(game.battle)
	match cmd:
		"heal":
			api.heal()
			return result(true, "生命值、魔法值已回满")
		"cooldown":
			api.reset_cooldowns()
			return result(true, "技能冷却已清除")
		"god", "collision":
			if args.size() > 1 or (args.size() == 1 and args[0] not in ["on", "off"]):return result(false, "用法：%s [on|off]" % cmd)
			var enabled: bool = not (api.god() if cmd == "god" else api.collision()) if args.is_empty() else args[0] == "on"
			if cmd == "god":api.set_god(enabled)
			else:api.set_collision(enabled)
			return result(true, ("无敌" if cmd == "god" else "碰撞显示") + ("已开启" if enabled else "已关闭"))
		"clear":
			api.kill_all_monsters()
			return result(true, "已清除本房敌人；关闭面板后触发开门或结算")
		"room":
			if args.size() != 1:return result(false, "用法：room 1~%d|next|boss" % api.room_count())
			var index: int = api.room_count() - 1 if args[0] == "boss" else api.room_index() + 1 if args[0] == "next" else int(args[0]) - 1 if positive_int(args[0], api.room_count()) else -1
			if index < 0 or index >= api.room_count():return result(false, "房间不存在")
			api.load_room(index, "start")
			game.sync_debug_pause()
			return result(true, "已跳到第 %d 房" % (index + 1))
		"spawn":
			if args.size()==2 and args[0]=="current" and positive_int(args[1],20):
				var kinds: int=api.spawn_current(int(args[1]))
				return result(true,"已按本房怪物表生成 %d 只（%d 种外观）" % [int(args[1]),kinds])
			if args.size() != 2 or args[0] not in ["goblin", "thrower", "chief"] or not positive_int(args[1], 20):return result(false, "用法：spawn current|goblin|thrower|chief 1~20")
			api.spawn(args[0], int(args[1]))
			return result(true, "已生成 %s ×%d" % [{"goblin":"哥布林", "thrower":"投掷手", "chief":"领主"}[args[0]], int(args[1])])
		"weapon":
			if args.size() != 1 or not api.has_weapon(args[0]):return result(false, "用法：weapon katana|shortsword|greatsword")
			api.set_weapon(args[0])
			return result(true, "本次战斗武器外观已切换；背包装备及伤害数值不变")
		"win":
			api.load_room(api.room_count() - 1, "start")
			api.kill_all_monsters()
			game.set_debug_open(false)
			return result(true, "已跳至领主房并清怪，按真实流程结算")
		"lose":
			api.lose()
			game.set_debug_open(false)
			return result(true, "已触发角色战败，按真实流程结算")
	return result(false, "未知命令：%s；help 查看帮助" % cmd)

func dungeon_command(args: PackedStringArray) -> Dictionary:
	if args.is_empty() or args[0] == "list":
		var keyword := args[1].to_lower() if args.size() >= 2 else ""
		var rows: Array[String] = []
		var ids: Array = game.session.dungeons.keys()
		ids.sort()
		for id: String in ids:
			var dungeon: Dictionary = game.session.dungeons[id]
			if dungeon.get("legacy",false):continue
			if keyword != "" and not (id.to_lower().contains(keyword) or String(dungeon.get("name","")).to_lower().contains(keyword)):continue
			rows.append("%s  Lv%d  %s  %s" % [id,int(dungeon.get("min_level",1)),
				String(dungeon.get("name",id)),"可进入" if game.session.dungeon_available(id) else "未满足"])
		if rows.is_empty():return result(false,"没有匹配副本")
		return result(true,"\n".join(rows) + "\n当前选择：" + String(game.selected_dungeon))
	if args[0] == "current":
		var current: Dictionary = game.session.dungeons.get(game.selected_dungeon,{})
		if current.is_empty():return result(false,"当前没有选择副本")
		return result(true,"%s  %s  Lv%d" % [game.selected_dungeon,String(current.get("name","")),
			int(current.get("min_level",1))])
	if args[0] == "select":
		if args.size()!=2 or not game.session.dungeons.has(args[1]) or game.session.dungeons[args[1]].get("legacy",false):
			return result(false,"用法：dungeon select 副本ID；dungeon list 查看")
		game.selected_dungeon = args[1]
		var available: bool=game.session.dungeon_available(args[1])
		return result(true,"已选择 %s%s" % [String(game.session.dungeons[args[1]].get("name",args[1])),
			"" if available else "（当前等级或前置未满足）"])
	if args[0] == "restart":
		if game.session.state != "town":back_to_town()
		if game.session.state != "town":return result(false,"无法返回城镇")
		game.depart()
		game.sync_debug_pause()
		return result(game.session.state=="battle","已重开 %s；关闭面板开始战斗" % String(game.session.dungeons.get(game.selected_dungeon,{}).get("name",game.selected_dungeon)))
	if args[0] != "enter" or args.size()>2:
		return result(false,"用法：dungeon list|select ID|enter [ID]|restart")
	if args.size()==2:
		if not game.session.dungeons.has(args[1]) or game.session.dungeons[args[1]].get("legacy",false):
			return result(false,"副本不存在；dungeon list 查看")
		game.selected_dungeon=args[1]
	if game.session.state!="town":return result(false,"请先回城，或使用 dungeon restart")
	if not game.session.dungeon_available(game.selected_dungeon):
		return result(false,"当前等级或任务前置未满足：" + String(game.selected_dungeon))
	game.depart()
	game.sync_debug_pause()
	if game.session.state!="battle":
		return result(false,"进入副本失败：" + String(game.notification))
	return result(true,"已进入 %s；关闭面板开始战斗" % String(game.session.dungeons.get(game.selected_dungeon,{}).get("name",game.selected_dungeon)))

func quest_command(args: PackedStringArray) -> Dictionary:
	var definitions: Dictionary = game.session.quests.catalog.definitions
	if args.is_empty() or args[0] in ["available","active","completed","list"]:
		var state: String = ""
		if not args.is_empty():
			state = args[1] if args[0]=="list" and args.size()>=2 else args[0] if args[0]!="list" else ""
		if state != "" and state not in ["available","active","ready","completed","locked"]:
			return result(false,"用法：quest list [available|active|ready|completed|locked]")
		var statuses: Array = [state] if state != "" else []
		return quest_list(statuses)
	if args[0] == "current":return quest_list(["active","ready"])
	if args[0] == "info":
		if args.size()!=2 or not definitions.has(args[1]):return result(false,"用法：quest info 任务ID")
		return quest_info(args[1])
	if args[0] == "readyall":return quest_ready_all()
	if args[0] not in ["accept","ready","claim","track","abandon"] or args.size()<2:
		return result(false,"用法：quest accept|ready|claim|track|abandon 任务ID")
	var id := String(args[1])
	if not definitions.has(id):return result(false,"任务不存在：" + id)
	if args[0]=="ready":return quest_ready(id)
	var choice := String(args[2]) if args.size()>=3 else ""
	return quest_transaction("quest."+String(args[0]),id,choice)

func quest_list(statuses: Array) -> Dictionary:
	var rows: Array[Dictionary] = game.session.quests.list(game.session.profile,statuses)
	rows.sort_custom(func(a,b):
		var level_a := int(a.get("min_level",1))
		var level_b := int(b.get("min_level",1))
		return level_a < level_b or level_a == level_b and String(a.get("name","")) < String(b.get("name","")))
	var lines: PackedStringArray = []
	for index in mini(rows.size(),28):
		var quest: Dictionary = rows[index]
		lines.append("%s  Lv%d  %s  %s" % [String(quest["id"]),int(quest.get("min_level",1)),
			String(quest.get("status","")),String(quest.get("name",""))])
	if lines.is_empty():return result(false,"没有匹配任务")
	if rows.size()>lines.size():lines.append("……共 %d 项，可用 quest info ID 查看" % rows.size())
	return result(true,"\n".join(lines))

func quest_info(id: String) -> Dictionary:
	var quest: Dictionary = game.session.quests.catalog.definitions[id]
	var status: String = game.session.quests.status(game.session.profile,id)
	var lines: PackedStringArray = ["%s  Lv%d  %s  %s" % [id,int(quest.get("min_level",1)),status,String(quest.get("name",""))],
		"发布："+String(quest.get("giver",""))+"  交付："+String(quest.get("receiver",""))]
	for objective: Dictionary in quest.get("objectives",[]):
		lines.append("目标：%s  %s  %s" % [String(objective.get("id","")),String(objective.get("type","")),
			String(objective.get("target",""))])
	lines.append("奖励：" + JSON.stringify(quest.get("reward",{})," "))
	return result(true,"\n".join(lines))

func quest_transaction(kind: String, id: String, choice := "") -> Dictionary:
	if game.session.state!="town":return result(false,"请先回城处理任务")
	var quest: Dictionary = game.session.quests.catalog.definitions[id]
	var candidate = session_candidate()
	var npc := String(quest.get("giver","")) if kind=="quest.accept" else String(quest.get("receiver",""))
	var payload := {"id":id}
	if choice!="":payload["choice"]=choice
	elif kind=="quest.claim":
		var rewards: Array = game.session.quests.reward_for(candidate.profile,quest).get("choices",[])
		if not rewards.is_empty():payload["choice"]=String(rewards[0]["id"])
	var response: Dictionary = candidate.quest_command(kind,payload,{"in_town":true,"nearby":true,"npc":npc,"gm":true})
	if not response.get("ok",false):return result(false,String(response.get("message","任务操作失败")))
	return commit_session(candidate,"任务操作完成：" + String(quest.get("name",id)),"numbers.xp" if kind=="quest.claim" else kind)

func quest_ready(id: String) -> Dictionary:
	if game.session.state!="town":return result(false,"请先回城准备任务")
	var candidate = session_candidate()
	var prepared: Dictionary = prepare_quest(candidate,id,true)
	if not prepared.get("ok",false):return prepared
	return commit_session(candidate,"任务已准备为可交付：" + id,"quest.ready")

func quest_ready_all() -> Dictionary:
	if game.session.state!="town":return result(false,"请先回城准备任务")
	var candidate = session_candidate()
	var changed := 0
	var active: Array = candidate.quests.list(candidate.profile,["active"])
	for quest: Dictionary in active:
		var prepared: Dictionary = prepare_quest(candidate,String(quest["id"]),false)
		if prepared.get("ok",false):changed+=1
	if changed==0:return result(false,"没有可准备的进行中任务")
	return commit_session(candidate,"已将 %d 个进行中任务准备为可交付" % changed,"quest.ready")

func prepare_quest(candidate,id: String, allow_accept: bool) -> Dictionary:
	var definitions: Dictionary = candidate.quests.catalog.definitions
	if not definitions.has(id):return result(false,"任务不存在：" + id)
	var quest: Dictionary = definitions[id]
	var state: String = candidate.quests.status(candidate.profile,id)
	if state=="available" and allow_accept:
		var accepted: Dictionary = candidate.quest_command("quest.accept",{"id":id},
			{"in_town":true,"nearby":true,"npc":String(quest.get("giver","")),"gm":true})
		if not accepted.get("ok",false):return result(false,String(accepted.get("message","接取失败")))
		state=candidate.quests.status(candidate.profile,id)
	if state!="active":return result(false,"任务当前不是进行中：" + state)
	var entry: Dictionary = candidate.profile["quest_state"]["entries"][id]
	for objective: Dictionary in quest.get("objectives",[]):
		var oid := String(objective.get("id",""))
		var amount := int(objective.get("amount",0))
		entry["progress"][oid]=amount
		if objective.get("type")=="collect_item":
			var target := String(objective.get("target",""))
			var missing: int = amount - candidate.quests.objective_count(candidate.profile,objective,entry)
			if missing>0:
				var given: Dictionary = candidate.Inventory.give(candidate.profile,target,missing)
				if not given.get("ok",false):return result(false,"补发任务物品失败：" + String(given.get("message","")))
	for item: String in quest.get("consume",{}):
		var missing: int = int(quest["consume"][item]) - candidate.Inventory.stock(candidate.profile,item)
		if missing>0:
			var given: Dictionary = candidate.Inventory.give(candidate.profile,item,missing)
			if not given.get("ok",false):return result(false,"补发任务材料失败：" + String(given.get("message","")))
	if candidate.quests.status(candidate.profile,id)!="ready":
		return result(false,"任务目标仍无法完成")
	if not candidate.quests.valid(candidate.profile):return result(false,"任务准备后校验失败")
	return result(true,"任务已准备")

func session_candidate():
	var candidate = game.Session.new()
	candidate.profile=game.session.profile.duplicate(true)
	candidate.run=game.session.run.duplicate(true)
	candidate.state=game.session.state
	candidate.result=game.session.result.duplicate(true)
	return candidate

func commit_session(candidate,message: String,sync_kind: String) -> Dictionary:
	if not game.store.write(candidate):
		game.save_failed=true
		return result(false,"存档写入失败，变更未提交")
	game.session=candidate
	game.save_failed=false
	game.sync_number_changes(sync_kind)
	if game.overlay in ["quest","numbers"]:game.show_overlay(game.overlay)
	return result(true,message)

func positive_int(value: String, maximum: int) -> bool:
	return value.is_valid_int() and int(value) >= 1 and int(value) <= maximum

func persist(message: String) -> Dictionary:
	var ok: bool = game.save_profile()
	if game.overlay != "":game.show_overlay(game.overlay)
	return result(ok, message + (" · 已保存" if ok else " · 保存失败"))

func back_to_town() -> void:
	if not game.recovery_bridge.pending_death.is_empty() and not game.recovery_bridge.commit_death():return
	if game.session.state=="defeated":
		if not game.act("flow.abandon"):return
	if game.session.state == "battle":game.act("flow.retreat")
	if game.session.state == "result":game.return_town()
	game.show_overlay("")

func status() -> String:
	var p: Dictionary = game.session.profile
	var state_names := {"town":"城镇", "battle":"战斗", "defeated":"等待复活选择", "result":"结算"}
	var active_count: int = game.session.quests.active_count(p)
	var ready_count: int = game.session.quests.list(p,["ready"]).size()
	var learned_count := 0
	for rank in p.get("skills",{}).values():
		if int(rank)>0:learned_count+=1
	var text := "%s · %s · Lv%d · SP %d · 金币 %d" % [state_names.get(game.session.state,game.session.state),
		String(game.number_windows.skill_panel.JOB_NAMES.get(p.get("growtype","swordman"),p.get("growtype","swordman"))),
		int(p["level"]),int(game.session.Numbers.Skills.available(p,game.session.Numbers.shared_config())),int(p["gold"])]
	text += "\n装备 %d 件 · 已学技能 %d · 任务 %d 进行/%d 可交 · 药剂 %d" % [
		p.get("gear",{}).size(),learned_count,active_count,ready_count,int(p["inventory"].get("potion",0))]
	var dungeon: Dictionary=game.session.dungeons.get(game.selected_dungeon,{})
	if not dungeon.is_empty():
		text += "\n副本："+String(dungeon.get("name",game.selected_dungeon))+" · 难度 "+String(p.get("difficulty","normal"))
	if game.session.state == "battle" and is_instance_valid(game.battle):
		var view: Dictionary = game.combat.read_view()
		text += "\n房间 %d/%d · 生命 %d/%d · 魔法 %d/%d · 敌人 %d" % [view["room"], view["room_count"], view["hp"], view["hp_max"], view["mp"], view["mp_max"], view["alive_monsters"]]
	return text
