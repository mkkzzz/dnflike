extends RefCounted
const Recovery=preload("res://flow/recovery.gd")
const Consumables=preload("res://items/consumables.gd")
var game
var confirmation: Control
func _init(root) -> void:game=root
func text(parent: Node, value: String, at: Vector2, size: Vector2, font_size:=13) -> Label:
	var label: Label=game.skin.label(parent,value,at,font_size,Color("f0d18a"))
	label.size=size;label.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;return label
func open() -> void:
	var node: Control=game.skin.panel(game.modal,Rect2(145,110,510,295));node.name="death_window"
	text(node,"角色已倒下",Vector2(22,18),Vector2(465,30),20)
	if not game.recovery_bridge.pending_effect.is_empty():
		text(node,"费用与物品变更已经保存，恢复尚未完成。\n点击重试恢复，不会再次扣除物品或金币。",Vector2(22,72),Vector2(465,105))
		game.skin.button(node,"重试恢复",Vector2(190,230),game.recovery_bridge.retry_effect)
		return
	if not game.recovery_bridge.pending_death.is_empty():
		text(node,"死亡记录尚未保存。请先重试保存，再继续处理本次冒险。\n本次额外耐久扣损尚未提交。",Vector2(22,72),Vector2(465,105))
		game.skin.button(node,"重试保存",Vector2(190,230),func():game.recovery_bridge.commit_death();game.show_overlay("death"))
		return
	var q:=Recovery.quote(game.session.profile,game.session.run)
	var available: bool=game.combat!=null and game.combat.has_method("can_revive")
	var line:="本次死亡已记录，穿戴装备耐久扣损已保存。\n放弃不会获得通关奖励；已拾取物品和任务进度保留。"
	if not available:line+="\n\n当前可选择结束本次冒险并返回城镇。"
	elif q["ok"]:line+="\n\n复活费用：%d 金币 · 当前金币 %d\n已复活 %d/%d 次 · 恢复 HP %d%% / MP %d%%\n原地继续当前房间，获得 %.1f 秒保护。" % [q["price"],game.session.profile["gold"],q["used"],q["limit"],q["hp_percent"],q["mp_percent"],float(q["invulnerable_ms"])/1000]
	else:line+="\n\n"+String(q["message"])
	text(node,line,Vector2(22,65),Vector2(465,157),12)
	if available:game.skin.button(node,"原地复活",Vector2(105,246),prepare).disabled=not q["ok"]
	game.skin.button(node,"放弃回城",Vector2(300 if available else 206,246),game.recovery_bridge.abandon)
func prepare() -> void:
	if is_instance_valid(confirmation):return
	var q:=Recovery.quote(game.session.profile,game.session.run)
	if not q["ok"]:game.notice(q["message"]);return
	var data: Dictionary={"signature":q["signature"],"transaction":"revive:%s:%d:%d" % [game.session.run["id"],q["death_id"],Time.get_ticks_usec()]}
	var shield:=Control.new();shield.size=Vector2(800,508);shield.mouse_filter=Control.MOUSE_FILTER_STOP;shield.z_index=150;game.modal.add_child(shield);confirmation=shield;shield.name="revival_confirmation"
	var node: Control=game.skin.panel(shield,Rect2(202,135,396,235))
	text(node,"确认原地复活",Vector2(18,15),Vector2(360,30),17)
	text(node,"花费 %d 金币\n恢复 HP %d%% / MP %d%%，保护 %.1f 秒。\n本次冒险还可复活 %d 次（含本次）。\n当前房间的怪物、掉落和已完成进度保留。" % [q["price"],q["hp_percent"],q["mp_percent"],float(q["invulnerable_ms"])/1000,int(q["limit"])-int(q["used"])],Vector2(18,55),Vector2(360,126),12)
	game.skin.button(node,"确认复活",Vector2(48,191),func():
		if game.recovery_bridge.revive(data):confirmation=null)
	game.skin.button(node,"取消操作",Vector2(237,191),func():shield.queue_free();confirmation=null)
