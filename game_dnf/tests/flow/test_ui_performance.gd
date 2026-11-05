extends SceneTree
## Real UI/data paths in a disposable fixture; no user saves or visible windows.
const Loop = preload("res://flow/loop_root.gd")
const Numbers = preload("res://stats/api/numbers.gd")
const Upgrades = preload("res://items/upgrades.gd")
const Services = preload("res://items/services.gd")
var game
var failures := 0
var checks := 0
var measure_only := false
func _initialize() -> void:
	call_deferred("run")
func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("[UI_PERF] FAIL " + message)
func measure(label: String, action: Callable, budget_ms: float) -> void:
	var elapsed: Array[float] = []
	action.call()
	await process_frame
	for i in 3:
		var started := Time.get_ticks_usec()
		action.call()
		elapsed.append((Time.get_ticks_usec() - started) / 1000.0)
		await process_frame
	elapsed.sort()
	print("[UI_PERF] %s median_ms=%.3f peak_ms=%.3f budget_ms=%.1f" % [label,elapsed[1],elapsed[2],budget_ms])
	if not measure_only:check(elapsed[1] < budget_ms, label + " exceeds warm main-thread latency budget")
func run() -> void:
	if DisplayServer.get_name() != "headless":
		quit(1)
		return
	measure_only = "--measure-only" in OS.get_cmdline_user_args()
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
	game.ui = Control.new()
	game.ui.size = Vector2(800,600)
	root.add_child(game.ui)
	game.modal = Control.new()
	game.modal.mouse_filter = Control.MOUSE_FILTER_IGNORE
	game.ui.add_child(game.modal)
	game.hud = Control.new()
	game.ui.add_child(game.hud)
	for i in 5:game.session.command("numbers.gear_give", {"id":"training_coat"})
	var config_before := JSON.stringify(Numbers.shared_config())
	var services_before := JSON.stringify(Services.config())
	var upgrades_before := JSON.stringify(Upgrades.config())
	check(is_same(Services.config(), Services.config()), "service definitions are cached instead of rebuilt for each quote")
	check(is_same(Upgrades.config(), Upgrades.config()), "upgrade definitions are cached instead of reread for each quote")
	var profile_before := JSON.stringify(game.session.profile)
	var uid: String = game.session.profile["equipment"]["weapon"]
	await measure("equipment_window", func():
		game.number_windows.tab = 2
		game.show_overlay("numbers"), 80.0)
	await measure("weapon_tooltip", func(): game.windows.item_tip("iron_sword",Rect2(20,20,28,28),false,false,uid), 30.0)
	await measure("skill_tooltip", func(): game.windows.skill_tip("guard",Rect2(20,20,28,28),true), 60.0)
	await measure("drag_equipment_check", func():
		game.can_drop_slot({"place":"equipment","slot":"weapon","uid":uid,"id":"iron_sword"},{"place":"bag","category":"weapon","index":0}), 20.0)
	await measure("reinforcement_preview", func(): Upgrades.quote(game.session.profile,"services.reinforce",{"uid":uid}), 30.0)
	await measure("profile_validation", func(): check(Numbers.valid(game.session.profile), "numeric profile stays valid"), 20.0)
	await measure("weapon_appearance_query", func(): game.equipped_weapon_shape(), 5.0)
	await measure("skill_window", func():
		game.number_windows.tab = 1
		game.show_overlay("numbers"), 80.0)
	check(JSON.stringify(Numbers.shared_config()) == config_before, "readers leave shared numeric definitions unchanged")
	check(JSON.stringify(Services.config()) == services_before and JSON.stringify(Upgrades.config()) == upgrades_before, "preview leaves cached service/upgrade definitions unchanged")
	check(JSON.stringify(game.session.profile) == profile_before, "hover/drag/preview do not mutate profile")
	game.ui.free()
	game.ui_audio.free()
	game.town.free()
	game.free()
	print("[UI_PERF] COMPLETE checks=%d failures=%d" % [checks,failures])
	quit(1 if failures else 0)
