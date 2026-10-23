extends RefCounted
## Outer transactions. The emitting kernel is never mutated from an event callback.
const Recovery=preload("res://flow/recovery.gd")
const Consumables=preload("res://items/consumables.gd")
var game
var pending_death: Dictionary={}
var pending_effect: Dictionary={}
func _init(root) -> void:game=root
func reset() -> void:pending_death={};pending_effect={}
func candidate():
	var next=game.Session.new()
	next.profile=game.session.profile.duplicate(true);next.run=game.session.run.duplicate(true)
	next.state=game.session.state;next.result=game.session.result.duplicate(true)
	return next
func receive(event: Dictionary) -> void:
	if game.session.state!="battle" or event.get("run_id")!=game.session.run.get("id"):return
	pending_death=event.duplicate(true)
	if not commit_death() and pending_death.is_empty():return
	game.show_overlay("death")
func commit_death() -> bool:
	if pending_death.is_empty():return game.session.state=="defeated"
	var next=candidate();var response: Dictionary=next.combat_event(pending_death)
	if not response["ok"]:pending_death={};return false
	if not game.store.write(next):game.save_failed=true;game.notice("死亡记录保存失败，请重试；当前尚未提交耐久扣损");return false
	game.session=next;game.save_failed=false;pending_death={};game.build_hotbars();game.notice("死亡记录已保存，请选择后续操作");return true
func use_item(id: String) -> bool:
	if not pending_effect.is_empty():return retry_effect()
	if game.combat==null or game.session.state!="battle" or game.overlay!="" or game.debug_is_open() or not pending_death.is_empty():game.notice("请关闭菜单后在战斗中使用物品");return false
	var view: Dictionary=game.combat.read_view()
	var next=candidate()
	var response: Dictionary=next.use_consumable(id,view,"consume:%s:%d" % [game.session.run.get("id",""),Time.get_ticks_usec()])
	if not response["ok"]:game.notice(response["message"]);return false
	if not game.combat.can_apply_effect(response["effect"]):game.notice("当前无法使用该恢复物品");return false
	if not game.store.write(next):game.save_failed=true;game.notice("物品未使用：存档写入失败");return false
	# No await or simulation step between preflight, synchronous write and effect.
	game.session=next;game.save_failed=false
	if not game.combat.apply_effect(response["effect"]):
		pending_effect={"kind":"item","spec":response["effect"]};game.show_overlay("death");return false
	game.notice("使用%s · HP +%d" % [game.Catalog.ITEMS[id]["name"],response["amount"]]);return true
func revive(payload: Dictionary) -> bool:
	if not pending_effect.is_empty():return retry_effect()
	if not pending_death.is_empty() or game.combat==null:return false
	var next=candidate();var response: Dictionary=next.revive_command(payload)
	if not response["ok"]:game.notice(response["message"]);return false
	if not game.combat.has_method("can_revive") or not game.combat.can_revive(response["quote"]):game.notice("当前无法原地复活");return false
	if not game.store.write(next):game.save_failed=true;game.notice("复活未提交：存档写入失败，请重试");return false
	game.session=next;game.save_failed=false;game.build_hotbars()
	if not game.combat.revive(response["quote"]):
		pending_effect={"kind":"revive","spec":response["quote"]};game.show_overlay("death");return false
	game.show_overlay("")
	game.notice("已原地复活 · 本次冒险已用 %d 次" % int(game.session.run["recovery"]["revives"]));return true
func retry_effect() -> bool:
	if pending_effect.is_empty():return true
	if game.combat==null:return false
	game.combat.set_paused(false)
	var applied: bool=game.combat.apply_effect(pending_effect["spec"]) if pending_effect["kind"]=="item" else game.combat.revive(pending_effect["spec"])
	if not applied:game.combat.set_paused(true);game.notice("恢复尚未完成，重试不会重复扣费");return false
	pending_effect={};game.show_overlay("");game.notice("恢复已完成，费用没有重复扣除");return true
func abandon() -> void:
	if not commit_death():game.show_overlay("death");return
	if game.act("flow.abandon"):
		game.show_overlay("result");game.return_town()
