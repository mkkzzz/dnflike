extends RefCounted
const Recovery=preload("res://flow/recovery.gd")
const COIN_ICON="res://assets_local/revive_v1/coin_icon.png"
var game

func _init(root) -> void:game=root

func text(parent: Node, value: String, at: Vector2, size: Vector2, font_size:=13) -> Label:
	var label: Label=game.skin.label(parent,value,at,font_size,Color("f0d18a"))
	label.size=size
	label.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
	return label

func open() -> void:
	var node: Control=game.skin.panel(game.modal,Rect2(200,118,400,272))
	node.name="death_window"
	text(node,"角色已倒下",Vector2(24,18),Vector2(352,28),20)
	if not game.recovery_bridge.pending_effect.is_empty():
		text(node,"费用与物品变更已经保存，恢复尚未完成。\n点击重试恢复，不会再次扣除复活币。",Vector2(24,70),Vector2(352,110))
		game.skin.button(node,"重试恢复",Vector2(125,220),game.recovery_bridge.retry_effect)
		return
	if not game.recovery_bridge.pending_death.is_empty():
		text(node,"死亡记录尚未保存。请先重试保存，再继续处理本次冒险。\n本次额外耐久扣损尚未提交。",Vector2(24,70),Vector2(352,110))
		game.skin.button(node,"重试保存",Vector2(125,220),func():game.recovery_bridge.commit_death();game.show_overlay("death"))
		return
	var q:=Recovery.quote(game.session.profile,game.session.run)
	var available: bool=game.combat!=null and game.combat.has_method("can_revive") and game.combat.has_method("revive")
	var coin_texture=load(COIN_ICON) if ResourceLoader.exists(COIN_ICON) else null
	if coin_texture != null:game.skin.image(node,coin_texture,Vector2(24,60))
	game.skin.label(node,"复活币",Vector2(62,54),12,Color("f0d18a"))
	game.skin.label(node,"%d 枚" % int(q.get("coins",game.session.profile.get("resurrection_coins",0))),Vector2(62,74),15,Color("f0d18a"))
	var line: String=""
	if not available:
		line="当前无法原地复活。\n返回城镇不会获得通关奖励；已拾取物品与任务进度保留。"
	elif not q.get("ok",false):
		line=String(q.get("message","当前无法原地复活"))+"\n返回城镇不会获得通关奖励；已拾取物品与任务进度保留。"
	elif not bool(q.get("affordable",false)):
		line="复活币不足，无法原地复活。\n返回城镇不会获得通关奖励；已拾取物品与任务进度保留。"
	else:
		line="按 X 消耗 %d 枚复活币，原地复活。\n本次冒险已复活 %d/%d 次。\n恢复 HP %d%% / MP %d%%，保护 %.1f 秒。\n当前房间的怪物、掉落与进度保留。" % [int(q["coin_cost"]),int(q["used"]),int(q["limit"]),int(q["hp_percent"]),int(q["mp_percent"]),float(q["invulnerable_ms"])/1000]
	text(node,line,Vector2(24,116),Vector2(352,96),12)
	if available:
		var revive_button=game.skin.button(node,"原地复活 [X]",Vector2(24,224),revive_now)
		revive_button.disabled=not (q.get("ok",false) and bool(q.get("affordable",false)))
		game.skin.button(node,"返回城镇",Vector2(218,224),game.recovery_bridge.abandon)
	else:
		game.skin.button(node,"返回城镇",Vector2(125,224),game.recovery_bridge.abandon)

## X and the button both use the same deterministic transaction. A failed effect
## retry goes through pending_effect and never charges the coin twice.
func revive_now() -> bool:
	if game.session.state!="defeated" or game.combat==null:return false
	var q:=Recovery.quote(game.session.profile,game.session.run)
	if not q.get("ok",false):
		game.notice(q.get("message","当前无法原地复活"))
		return false
	if not bool(q.get("affordable",false)):
		game.notice("复活币不足，无法原地复活")
		return false
	var payload: Dictionary={"signature":q["signature"],"transaction":"revive:%s:%d" % [game.session.run["id"],int(q["death_id"])]}
	return game.recovery_bridge.revive(payload)
