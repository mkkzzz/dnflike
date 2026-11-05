extends SceneTree
## Headless microbenchmark of the real panel; no user saves or visible windows.
const Loop = preload("res://flow/loop_root.gd")
var game
func _initialize():
	call_deferred("run")
func run():
	if DisplayServer.get_name() != "headless":
		push_error("Run the skill panel profiler with --headless")
		quit(1)
		return
	game = Loop.new()
	game.town = game.Town.new()
	game.town.loader.load_export("res://assets_local/flow_v1/manifest.json")
	game.skin = game.NativeSkin.new(game.town.loader)
	game.windows = game.Windows.new(game)
	game.number_windows = game.NumberWindows.new(game)
	game.skill_catalog = game.SkillCatalog.new()
	game.recovery_bridge = game.RecoveryBridge.new(game)
	game.ui_audio = game.UIAudio.new()
	game.character_active = true
	game.modal = Control.new()
	game.modal.size = Vector2(800,600)
	game.modal.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(game.modal)
	game.hud = Control.new()
	root.add_child(game.hud)
	game.number_windows.tab = 1
	game.session.profile["growtype"] = "weaponmaster"
	game.session.profile["level"] = 60
	game.session.profile["sp_bonus"] = 2000
	var panel = game.number_windows.skill_panel
	var start = Time.get_ticks_usec()
	for node in panel.tree_nodes():
		panel._state(panel.by_id[int(node["id"])])
	print("[PERF] all_states_ms=%.3f" % ((Time.get_ticks_usec()-start)/1000.0))
	for i in 3:
		start = Time.get_ticks_usec()
		game.show_overlay("numbers")
		print("[PERF] open_%d_ms=%.3f" % [i,(Time.get_ticks_usec()-start)/1000.0])
		await process_frame
		await process_frame
	for id in [1,3,46,1,3,46]:
		var node = game.modal.find_child("skill_node_%d" % id,true,false)
		start = Time.get_ticks_usec()
		node.pressed.emit()
		print("[PERF] select_%d_ms=%.3f" % [id,(Time.get_ticks_usec()-start)/1000.0])
		await process_frame
		await process_frame
	game.modal.free()
	game.hud.free()
	game.ui_audio.free()
	game.town.free()
	game.free()
	quit()
