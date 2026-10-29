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
			if args.size()!=1:return fail("用法：growtype swordman|weaponmaster|berserker")
			return mutate("numbers.growtype",{"growtype":args[0]})
		"xp", "sp":
			if args.size()!=1 or not args[0].is_valid_int():return fail("用法：xp 数量 / sp 数量")
			return mutate("numbers."+cmd,{"amount":int(args[0]),"transaction":"gm:%d:%d" % [Time.get_ticks_usec(),game.session.profile["xp_transactions"].size()]})
		"skill":
			if args.size()==1 and args[0]=="reset":return mutate("numbers.skill_reset",{})
			if args.size()!=2:return fail("用法：skill upper|draw|triple|rage_slash|buff|guard|physical_mastery 等级；skill reset")
			if args[1] in ["+","-"]:return mutate("numbers.skill",{"id":args[0],"delta":1 if args[1]=="+" else -1})
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
			if args.size()==0:return fail("用法：gear give 定义 [品质] / equip 实例 / reinforce 实例 等级 / enchant 实例 属性 增量")
			if args[0]=="list":return {"ok":true,"message":JSON.stringify(game.session.profile["gear"]," ")}
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

func active() -> bool:
	return game.session.state=="battle" and is_instance_valid(game.battle)

func mutate(kind: String, payload: Dictionary) -> Dictionary:
	if kind=="numbers.skill":
		var saved: bool=game.item_action(kind,payload)
		if game.overlay=="numbers":game.show_overlay("numbers")
		return {"ok":saved,"message":"技能已保存" if saved else "技能操作未提交"}
	var response: Dictionary = game.session.command(kind,payload)
	if not response["ok"]:return response
	game.sync_number_changes(kind)
	var saved: bool = game.save_profile()
	if game.overlay=="numbers":game.show_overlay("numbers")
	return {"ok":saved,"message":("数值已更新" if saved else "数值已更新，但存档失败")+(" · "+String(response["uid"]) if response.has("uid") else "")}

func fail(message: String) -> Dictionary:return {"ok":false,"message":message}
