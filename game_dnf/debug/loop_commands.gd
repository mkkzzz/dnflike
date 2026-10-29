extends RefCounted
## Bounded GM commands. No evaluation of GDScript or shell expressions.
const NumberCommands = preload("res://debug/number_commands.gd")
const RuntimeAPI = preload("res://debug/runtime_api.gd")
const HELP := "help 帮助 / status 状态 / dungeon enter|restart 进本或重开 / town 回城\nroom 1~5|next|boss 跳房 / spawn goblin|thrower|chief 1~20 刷怪 / clear 清怪\ngod [on|off] 无敌 / heal 回满 / cooldown 清冷却 / collision [on|off] 碰撞\nweapon katana|shortsword|greatsword 临时外观 / win 通关 / lose 失败\ngive potion|iron_sword|forest_sword 数量 / gold 数量 / level 1~60 / save 保存\nxp 数量 / sp 数量 / skill 技能 等级 / stat 属性 增量 / stats [属性]\ngear give|equip|reinforce|enchant / buff|unbuff 效果 [目标] / monster 等级 / damage 伤害明细\nelement none|fire|water|light|dark 属性攻击"
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
			if args.size() != 1 or args[0] not in ["enter", "restart"]:return result(false, "用法：dungeon enter 或 dungeon restart")
			if game.session.state != "town":
				if args[0] != "restart":return result(false, "请先回城，或使用 dungeon restart")
				back_to_town()
			game.depart()
			game.sync_debug_pause()
			return result(game.session.state == "battle", "已进入密林试炼；关闭面板开始战斗")
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
			if args.size() != 2 or args[0] not in ["goblin", "thrower", "chief"] or not positive_int(args[1], 20):return result(false, "用法：spawn goblin|thrower|chief 1~20")
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
	var text := "%s · 等级 %d · 金币 %d · 药剂 %d" % [{"town":"城镇", "battle":"战斗", "defeated":"等待复活选择", "result":"结算"}[game.session.state], p["level"], p["gold"], p["inventory"].get("potion", 0)]
	if game.session.state == "battle" and is_instance_valid(game.battle):
		var view: Dictionary = game.combat.read_view()
		text += "\n房间 %d/%d · 生命 %d/%d · 魔法 %d/%d · 敌人 %d" % [view["room"], view["room_count"], view["hp"], view["hp_max"], view["mp"], view["mp_max"], view["alive_monsters"]]
	return text
