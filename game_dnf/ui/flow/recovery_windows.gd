extends RefCounted
const Recovery=preload("res://flow/recovery.gd")
const COIN_ICON="res://assets_local/revive_v1/coin_icon.png"
const WindowControls=preload("res://ui/flow/recovery_window_controls.gd")
var game
var window: Control
var feedback: Label
var action_buttons: Array[Button] = []

func _init(root) -> void:game=root

func text(parent: Node, value: String, at: Vector2, size: Vector2, font_size:=13) -> Label:
	var label: Label=game.skin.label(parent,value,at,font_size,Color("f0d18a"))
	label.size=size
	label.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
	return label

func open() -> void:
	action_buttons.clear()
	window=game.skin.panel(game.modal,Rect2(200,118,400,272))
	window.name="death_window"
	text(window,"角色已倒下",Vector2(24,18),Vector2(352,28),20)
	feedback=game.skin.label(window,"",Vector2(24,196),11,Color("ef9b83"))
	feedback.name="recovery_window_feedback"
	feedback.size=Vector2(352,20)
	feedback.clip_text=true
	feedback.visible=false
	if not game.recovery_bridge.pending_effect.is_empty():
		text(window,"费用与物品变更已经保存，恢复尚未完成。\n点击重试恢复，不会再次扣除复活币。",Vector2(24,70),Vector2(352,110))
		_add_button("重试恢复",Vector2(125,220),retry_effect,"recovery_window_retry_effect")
		_finish_layout()
		return
	if not game.recovery_bridge.pending_death.is_empty():
		text(window,"死亡记录尚未保存。请先重试保存，再继续处理本次冒险。\n本次额外耐久扣损尚未提交。",Vector2(24,70),Vector2(352,110))
		_add_button("重试保存",Vector2(125,220),retry_death,"recovery_window_retry_save")
		_finish_layout()
		return
	var q:=Recovery.quote(game.session.profile,game.session.run)
	window.set_meta("revive_quote",q)
	var available: bool=game.combat!=null and game.combat.has_method("can_revive") and game.combat.has_method("revive")
	var coin_texture=load(COIN_ICON) if ResourceLoader.exists(COIN_ICON) else null
	if coin_texture != null:game.skin.image(window,coin_texture,Vector2(24,60))
	game.skin.label(window,"复活币",Vector2(62,54),12,Color("f0d18a"))
	game.skin.label(window,"%d 枚" % int(q.get("coins",game.session.profile.get("resurrection_coins",0))),Vector2(62,74),15,Color("f0d18a"))
	var line: String=""
	if not available:
		line="当前无法原地复活。\n返回城镇不会获得通关奖励；已拾取物品与任务进度保留。"
	elif not q.get("ok",false):
		line=String(q.get("message","当前无法原地复活"))+"\n返回城镇不会获得通关奖励；已拾取物品与任务进度保留。"
	elif not bool(q.get("affordable",false)):
		line="复活币不足，无法原地复活。\n返回城镇不会获得通关奖励；已拾取物品与任务进度保留。"
	else:
		line="按 X 消耗 %d 枚复活币，原地复活。\n本次冒险已复活 %d/%d 次。\n恢复 HP %d%% / MP %d%%，保护 %.1f 秒。\n当前房间的怪物、掉落与进度保留。" % [int(q["coin_cost"]),int(q["used"]),int(q["limit"]),int(q["hp_percent"]),int(q["mp_percent"]),float(q["invulnerable_ms"])/1000]
	text(window,line,Vector2(24,112),Vector2(352,82),12)
	if available:
		var revive_button=_add_button("原地复活 [X]",Vector2(24,224),revive_now,"recovery_window_revive")
		revive_button.disabled=not (q.get("ok",false) and bool(q.get("affordable",false)))
		_add_button("返回城镇",Vector2(218,224),abandon,"recovery_window_return")
		_finish_layout(revive_button)
	else:
		_add_button("返回城镇",Vector2(125,224),abandon,"recovery_window_return")
		_finish_layout()

func _add_button(label: String, at: Vector2, action: Callable, node_name: String) -> Button:
	var button: Button=game.skin.button(window,label,at,action)
	button.name=node_name
	button.focus_mode=Control.FOCUS_ALL
	action_buttons.append(button)
	return button

func _finish_layout(preferred: Button = null) -> void:
	WindowControls.focus_buttons(action_buttons,preferred)

func _show_feedback(message: String) -> void:
	WindowControls.set_feedback(feedback,message,game.skin)

func retry_effect() -> bool:
	var applied: bool=game.recovery_bridge.retry_effect()
	if not applied:
		_show_feedback(String(game.notification) if String(game.notification)!="" else "恢复尚未完成，请重试")
	return applied

func retry_death() -> bool:
	var committed: bool=game.recovery_bridge.commit_death()
	if not committed:
		_show_feedback(String(game.notification) if String(game.notification)!="" else "死亡记录保存失败，请重试")
		return false
	game.show_overlay("death")
	return true

func abandon() -> void:
	game.recovery_bridge.abandon()
	if game.session.state=="defeated":
		_show_feedback(String(game.notification) if String(game.notification)!="" else "返回城镇未提交，请重试")

## X and the button both use the same deterministic transaction. A failed effect
## retry goes through pending_effect and never charges the coin twice.
func revive_now() -> bool:
	if not game.recovery_bridge.pending_effect.is_empty():return retry_effect()
	if not game.recovery_bridge.pending_death.is_empty():
		_show_feedback("死亡记录尚未保存，请先重试保存")
		return false
	if game.session.state!="defeated" or game.combat==null:
		_show_feedback("当前无法原地复活")
		return false
	var q:=Recovery.quote(game.session.profile,game.session.run)
	if not q.get("ok",false):
		var reason:=String(q.get("message","当前无法原地复活"))
		game.notice(reason)
		_show_feedback(reason)
		return false
	if not bool(q.get("affordable",false)):
		game.notice("复活币不足，无法原地复活")
		_show_feedback("复活币不足，无法原地复活")
		return false
	var payload: Dictionary={"signature":q["signature"],"transaction":"revive:%s:%d" % [game.session.run["id"],int(q["death_id"])]}
	var revived: bool=game.recovery_bridge.revive(payload)
	if not revived:
		_show_feedback(String(game.notification) if String(game.notification)!="" else "原地复活未提交，请重试")
	return revived
