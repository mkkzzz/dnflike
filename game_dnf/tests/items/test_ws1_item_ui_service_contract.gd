extends SceneTree
## ws1-owned service and upgrade window contract.
const Loop = preload("res://flow/loop_root.gd")

var game
var checks := 0
var failures := 0
var capture_dir := ""
var sword_uid := ""
var coat_uid := ""

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var capture := "--capture" in args
	if capture:
		capture_dir = String(args[args.find("--output") + 1]) \
			if args.find("--output") >= 0 and args.find("--output") + 1 < args.size() else ""
		if OS.get_environment("DNF_PRIVATE_DESKTOP") != "1" \
			or DisplayServer.get_name() == "headless" or capture_dir == "":
			push_error("[WS1_ITEM_UI] capture requires the private desktop and --output")
			quit(1)
			return
	elif DisplayServer.get_name() != "headless":
		push_error("[WS1_ITEM_UI] headless display required")
		quit(1)
		return
	call_deferred("run")

func check(value: bool, message: String) -> void:
	checks += 1
	if value:
		print("[WS1_ITEM_UI] PASS " + message)
	else:
		failures += 1
		push_error("[WS1_ITEM_UI] FAIL " + message)

func frames(count := 3) -> void:
	for _index in count:
		await process_frame

func find_action(label: String) -> Button:
	for node in game.modal.find_children("*", "Button", true, false):
		if node.is_queued_for_deletion():
			continue
		if node.text == label or String(node.get_meta("action_label", "")) == label:
			return node
	return null

func press_action(label: String) -> bool:
	var button := find_action(label)
	if button == null or button.disabled:
		return false
	button.pressed.emit()
	return true

func find_slot(place: String, uid: String) -> Control:
	for node in game.modal.find_children("*", "Button", true, false):
		if node.is_queued_for_deletion() or node.get_script() != game.ContentSlot:
			continue
		if node.cell.get("place", "") == place and node.cell.get("uid", "") == uid:
			return node
	return null

func find_potion_uid() -> String:
	for uid: String in game.session.profile["item_state"]["bags"]["consumable"]:
		if uid != "" and game.session.Inventory.definition(game.session.profile,uid) == "potion":
			return uid
	return ""

func remove_stock(id: String) -> void:
	var kind := String(game.Catalog.ITEMS[id]["kind"])
	var bag: Array = game.session.profile["item_state"]["bags"][kind]
	for index in bag.size():
		var uid := String(bag[index])
		if uid != "" and game.session.Inventory.definition(game.session.profile,uid) == id:
			bag[index] = ""
			game.session.profile["item_state"]["stacks"].erase(uid)
	game.session.Inventory.sync(game.session.profile)

func item_state_signature() -> String:
	var profile: Dictionary = game.session.profile
	return JSON.stringify({
		"gold":profile["gold"],
		"equipment":profile["equipment"],
		"gear":profile["gear"],
		"inventory":profile["inventory"],
		"item_state":profile["item_state"],
		"services":profile["services"],
	})

func move_to_npc(npc: String) -> bool:
	game.show_overlay("")
	for location: String in game.town.world.data["locations"]:
		var scene: Dictionary = game.town.world.scene(location)
		if not scene.get("npcs", {}).has(npc):
			continue
		var at: Array = scene["npcs"][npc]
		game.town.set_location(location,game.session.TownWorld.vec(at))
		game.session.profile["town_location"] = location
		game.session.profile["town_position"] = at.duplicate()
		return true
	return false

func open_action(action: String) -> bool:
	game.show_overlay("npc")
	await frames(3)
	if not press_action(action):
		return false
	await frames(3)
	return game.overlay in ["services","upgrades"]

func setup_game() -> void:
	game = Loop.new()
	root.add_child(game)
	await frames(4)
	var unique := Crypto.new().generate_random_bytes(8).hex_encode()
	game.store.path = "res://../temp/ws1_item_ui_tests/profile_" + unique + ".json"
	game.session = game.Session.new()
	game.session.profile["name"] = "服务契约旅人"
	game.session.profile["gold"] = 1000
	var sword: Dictionary = game.session.command("numbers.gear_give",{"id":"forest_sword","quality":87})
	sword_uid = String(sword.get("uid",""))
	game.session.profile["gear"][sword_uid]["reinforce"] = 4
	game.session.profile["gear"][sword_uid]["durability"] = 7
	var coat: Dictionary = game.session.command("numbers.gear_give",{"id":"training_coat"})
	coat_uid = String(coat.get("uid",""))
	game.session.command("numbers.gear_equip",{"uid":coat_uid})
	game.session.profile["gear"][coat_uid]["durability"] = 0
	game.session.Inventory.give(game.session.profile,"scrap_iron",20)
	check(game.store.write(game.session),"disposable service character is written")
	check(game.enter_character(game.store.path),"disposable service character enters the real town flow")
	await frames(4)
	game.ui_audio.muted = true
	game.town.set_voice_enabled(false)
	game.town.stop_npc_voices(true)

func service_contract() -> void:
	check(move_to_npc("linus"),"service fixture reaches Linus")
	await frames(2)
	check(await open_action("物品服务"),"Linus dialogue opens the real item service")
	var root_window: Control = game.service_windows.window
	check(root_window != null and root_window.position == Vector2(8,16)
		and root_window.size == Vector2(460,488),"service window keeps the native 460x488 board")
	check(game.service_windows.window_builds == 1,"service window has one stable root build")
	var builds: int = game.service_windows.window_builds
	var slot := find_slot("bag",sword_uid)
	check(slot != null,"service inventory exposes the selected equipment instance")
	if slot != null:
		slot.pressed.emit()
		await frames(2)
	check(game.service_windows.selected == sword_uid,"service selection follows the exact equipment UID")
	check(game.service_windows.detail.text.contains("强化 +4")
		and game.service_windows.detail.text.contains("耐久 7 / 40"),
		"service detail shows instance reinforcement and durability")

	check(press_action("出售所选"),"sale opens a confirmation")
	await frames(2)
	check(is_instance_valid(game.service_windows.confirmation),"sale confirmation exists")
	var quality_before := int(game.session.profile["gear"][sword_uid]["quality"])
	game.session.profile["gear"][sword_uid]["quality"] = quality_before + 1
	var before := JSON.stringify(game.session.serialize())
	check(press_action("确认操作"),"stale quote can be confirmed")
	await frames(4)
	var feedback := game.modal.find_child("service_window_feedback",true,false) as Label
	check(game.session.profile["gear"][sword_uid]["quality"] == quality_before + 1
		and game.session.profile["services"]["buyback"].is_empty()
		and JSON.stringify(game.session.serialize()) == before,
		"stale quote commits nothing")
	check(game.service_windows.confirmation == null and feedback != null
		and feedback.visible and feedback.text.contains("变化"),
		"stale quote closes the old confirmation and shows an in-window receipt")
	check(game.service_windows.window == root_window
		and game.service_windows.window_builds == builds,
		"stale quote recovery keeps the service root")

	check(press_action("出售所选"),"sale reopens with a fresh quote")
	await frames(2)
	var path: String = game.store.path
	game.store.path = "res://data/services.json/cannot_write.json"
	before = JSON.stringify(game.session.serialize())
	check(press_action("确认操作"),"sale confirmation accepts the save-failure retry path")
	await frames(4)
	var inline := game.modal.find_child("service_confirm_feedback",true,false) as Label
	check(game.save_failed and is_instance_valid(game.service_windows.confirmation)
		and inline != null and inline.visible and inline.text.contains("存档写入失败"),
		"save failure keeps the same confirmation and shows retry feedback")
	check(JSON.stringify(game.session.serialize()) == before,"save failure commits no sale")
	game.store.path = path
	check(press_action("确认操作"),"same confirmation is retryable after save failure")
	await frames(4)
	check(not game.save_failed and game.session.profile["services"]["buyback"].size() == 1,
		"retry commits the original sale exactly once")
	check(game.service_windows.window == root_window
		and game.service_windows.window_builds == builds,
		"successful sale uses local content and inventory refresh")

	var gold_after_sale := int(game.session.profile["gold"])
	check(press_action("回购"),"buyback opens from the new receipt")
	await frames(2)
	check(press_action("确认操作"),"buyback confirmation is actionable")
	await frames(4)
	check(game.session.profile["services"]["buyback"].is_empty()
		and int(game.session.profile["gold"]) == gold_after_sale - 60
		and sword_uid in game.session.profile["item_state"]["bags"]["weapon"],
		"buyback restores the exact equipment instance and charged sale price")
	check(game.service_windows.window == root_window,"buyback does not rebuild the service root")

	var potion_uid := find_potion_uid()
	check(potion_uid != "","service fixture owns a partial potion stack")
	game.windows.inventory_tab = 1
	game.service_windows._rebuild_inventory()
	await frames(3)
	slot = find_slot("bag",potion_uid)
	check(slot != null,"consumable tab exposes the partial potion stack")
	if slot != null:
		slot.pressed.emit()
		await frames(2)
	check(game.service_windows.selected == potion_uid,"partial stack selection follows the potion UID")
	game.service_windows.quantity.value = 2
	game.service_windows.quantity.get_line_edit().text = "2"
	game.service_windows.quantity.apply()
	await frames(2)
	check(int(game.service_windows.quantity.value) == 2,"service quantity accepts a typed partial amount")
	check(press_action("出售所选"),"partial stack opens a sale quote")
	await frames(2)
	check(is_instance_valid(game.service_windows.confirmation),
		"partial stack quote creates a confirmation: " + String(game.notification))
	check(press_action("确认操作"),"partial stack sale confirms")
	await frames(4)
	check(int(game.session.profile["inventory"]["potion"]) == 1
		and game.session.profile["services"]["buyback"].size() == 1,
		"partial stack sale transfers only the selected amount")
	check(press_action("回购"),"partial stack receipt is buyable")
	await frames(2)
	check(press_action("确认操作"),"partial stack buyback confirms")
	await frames(4)
	check(int(game.session.profile["inventory"]["potion"]) == 3,
		"partial stack buyback restores the selected amount")

	game.windows.inventory_tab = 0
	game.service_windows._rebuild_inventory()
	await frames(3)
	slot = find_slot("service_equipment",coat_uid)
	if slot != null:
		slot.pressed.emit()
		await frames(2)
	var saved_gold := int(game.session.profile["gold"])
	game.session.profile["gold"] = 0
	check(press_action("修理所选"),"broken coat opens a repair quote")
	await frames(2)
	check(press_action("确认操作"),"repair confirmation reaches the insufficient-gold branch")
	await frames(4)
	feedback = game.modal.find_child("service_window_feedback",true,false) as Label
	check(int(game.session.profile["gear"][coat_uid]["durability"]) == 0
		and feedback != null and feedback.visible and feedback.text.contains("金币不足"),
		"insufficient repair gold changes no durability and reports inline")
	game.session.profile["gold"] = saved_gold
	game.service_windows._render_content()
	await frames(2)
	await capture_frame("service_window_1x",1)
	await capture_frame("service_window_2x",2)
	check(press_action("修理所选"),"repair reopens for confirmation capture")
	await frames(2)
	await capture_frame("service_confirm_1x",1)
	await capture_frame("service_confirm_2x",2)
	check(press_action("取消操作"),"confirmation capture can be cancelled")
	await frames(3)
	check(game.service_windows.window == root_window
		and game.service_windows.window_builds == builds,
		"service window root survives selection, rejection, transactions and capture")

func seed_for(success: bool, chance: int) -> int:
	for seed in range(1,1000):
		if ((seed*48271)%2147483647%100<chance) == success:
			return seed
	return 1

func upgrade_contract() -> void:
	check(move_to_npc("kiri"),"upgrade fixture reaches Kiri")
	await frames(2)
	check(await open_action("强化"),"Kiri dialogue opens the real upgrade window")
	var root_window: Control = game.upgrade_windows.window
	check(root_window != null and root_window.position == Vector2(8,16)
		and root_window.size == Vector2(460,488),"upgrade window keeps the native 460x488 board")
	var builds: int = game.upgrade_windows.window_builds
	var slot := find_slot("bag",sword_uid)
	check(slot != null,"upgrade inventory exposes the selected instance")
	if slot != null:
		slot.pressed.emit()
		await frames(2)
	check(game.upgrade_windows.selected == sword_uid
		and game.upgrade_windows.preview.text.contains("成功率"),
		"upgrade preview follows the exact equipment UID")

	check(press_action("强化一级"),"reinforcement opens a quote")
	await frames(2)
	game.session.profile["services"]["upgrades"]["seed"] = int(game.session.profile["services"]["upgrades"]["seed"]) + 1
	var before := JSON.stringify(game.session.serialize())
	check(press_action("确认操作"),"stale reinforcement quote can be confirmed")
	await frames(4)
	var feedback := game.modal.find_child("upgrade_window_feedback",true,false) as Label
	check(JSON.stringify(game.session.serialize()) == before
		and game.upgrade_windows.confirmation == null
		and feedback != null and feedback.visible and feedback.text.contains("变化"),
		"changed RNG state rejects the stale upgrade quote without mutation")

	game.session.profile["services"]["upgrades"]["seed"] = seed_for(true,75)
	check(press_action("强化一级"),"reinforcement reopens after quote expiry")
	await frames(2)
	var path: String = game.store.path
	game.store.path = "res://data/upgrades.json/cannot_write.json"
	before = item_state_signature()
	check(press_action("确认操作"),"upgrade save failure reaches the retry branch")
	await frames(4)
	var inline := game.modal.find_child("upgrade_confirm_feedback",true,false) as Label
	check(game.save_failed and is_instance_valid(game.upgrade_windows.confirmation)
		and inline != null and inline.visible and inline.text.contains("存档写入失败"),
		"upgrade save failure keeps the confirmation and retry feedback")
	check(item_state_signature() == before,"upgrade save failure consumes nothing")
	game.store.path = path
	check(press_action("确认操作"),"same upgrade confirmation is retryable")
	await frames(4)
	check(not game.save_failed and int(game.session.profile["gear"][sword_uid]["reinforce"]) == 5,
		"upgrade retry commits exactly one configured level")
	check(game.upgrade_windows.window == root_window
		and game.upgrade_windows.window_builds == builds,
		"upgrade success keeps the dedicated root")

	var attempts := int(game.session.profile["services"]["upgrades"]["attempts"])
	game.session.profile["services"]["upgrades"]["seed"] = seed_for(true,65)
	check(press_action("强化一级"),"next reinforcement opens")
	await frames(2)
	var confirm := find_action("确认操作")
	check(confirm != null,"next reinforcement confirmation exists")
	if confirm != null:
		confirm.pressed.emit()
		confirm.pressed.emit()
	await frames(4)
	check(int(game.session.profile["services"]["upgrades"]["attempts"]) == attempts + 1,
		"double confirmation cannot roll or charge twice")

	remove_stock("scrap_iron")
	check(game.session.Inventory.stock(game.session.profile,"scrap_iron") == 0,
		"missing-material fixture clears every spendable stack")
	check(press_action("强化一级"),"missing material request reaches the window")
	await frames(3)
	check(is_instance_valid(game.upgrade_windows.confirmation),
		"missing material still opens the configured quote")
	check(press_action("确认操作"),"missing material confirmation reaches the transaction")
	await frames(3)
	feedback = game.modal.find_child("upgrade_window_feedback",true,false) as Label
	check(game.upgrade_windows.confirmation == null and feedback != null
		and feedback.visible and feedback.text.contains("不足"),
		"missing materials reject after confirmation and report inline")
	game.session.Inventory.give(game.session.profile,"scrap_iron",10)
	game.upgrade_windows._render_content()
	await frames(2)
	await capture_frame("upgrade_window_1x",1)
	await capture_frame("upgrade_window_2x",2)
	check(press_action("强化一级"),"upgrade reopens for confirmation capture")
	await frames(2)
	await capture_frame("upgrade_confirm_1x",1)
	await capture_frame("upgrade_confirm_2x",2)
	check(press_action("取消操作"),"upgrade confirmation capture can be cancelled")
	await frames(3)
	check(game.upgrade_windows.window == root_window
		and game.upgrade_windows.window_builds == builds,
		"upgrade root survives quote rejection, retry, double submit and capture")

	check(move_to_npc("sinda"),"enchant fixture reaches Sinda")
	await frames(2)
	check(await open_action("附魔"),"Sinda dialogue opens enchanting")
	root_window = game.upgrade_windows.window
	builds = game.upgrade_windows.window_builds
	slot = find_slot("bag",sword_uid)
	if slot != null:
		slot.pressed.emit()
		await frames(2)
	check(press_action("智力附魔"),"second enchant recipe is selectable")
	await frames(2)
	check(game.upgrade_windows.recipe == "intelligence"
		and game.upgrade_windows.preview.text.contains("智力"),
		"recipe switch updates the preview locally")
	check(press_action("应用附魔"),"enchant opens a confirmation")
	await frames(2)
	check(press_action("确认操作"),"enchant confirmation commits")
	await frames(4)
	check(game.session.profile["gear"][sword_uid]["enchants"].size() == 1
		and game.session.profile["gear"][sword_uid]["enchants"][0]["stat"] == "intelligence",
		"successful enchant applies the selected recipe")
	check(game.upgrade_windows.window == root_window
		and game.upgrade_windows.window_builds == builds,
		"enchant recipe, commit and refresh retain the dedicated root")
	check(press_action("清除附魔"),"enchant clear opens a confirmation")
	await frames(2)
	check(press_action("确认操作"),"enchant clear confirms")
	await frames(4)
	check(game.session.profile["gear"][sword_uid]["enchants"].is_empty(),
		"enchant clear removes the modifier without a hidden cost")

	var loaded = game.Session.new()
	check(game.store.read_into(loaded)
		and int(loaded.profile["gear"][sword_uid]["reinforce"]) == 6
		and loaded.profile["gear"][sword_uid]["enchants"].is_empty(),
		"reinforcement, double-submit guard and enchant clear survive reload")

func capture_frame(name: String, scale_factor: int) -> void:
	if capture_dir == "":
		return
	root.min_size = Vector2i(1,1)
	root.max_size = Vector2i(8192,8192)
	root.content_scale_size = Vector2i(800,600) * scale_factor
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	root.size = root.content_scale_size
	game.transform = Transform2D(0.0,Vector2.ONE*scale_factor,0.0,Vector2.ZERO)
	(game.ui.get_parent() as CanvasLayer).transform = Transform2D(0.0,Vector2.ONE*scale_factor,0.0,Vector2.ZERO)
	await frames(3)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(capture_dir))
	var path := capture_dir.path_join(name+".png")
	var image := root.get_texture().get_image()
	var error := image.save_png(path)
	check(error == OK and image.get_size() == Vector2i(800,600)*scale_factor,
		"capture %s writes actual %dx%d pixels" % [name,image.get_width(),image.get_height()])
	var colored := 0
	for y in range(0,image.get_height(),20):
		for x in range(0,image.get_width(),20):
			if not image.get_pixel(x,y).is_equal_approx(Color.BLACK):
				colored += 1
	check(colored > 100,"capture %s contains a nonblank rendered window" % name)
	if error == OK:
		print("[WS1_ITEM_UI] CAPTURE " + path)

func run() -> void:
	await setup_game()
	await service_contract()
	await upgrade_contract()
	finish()

func finish() -> void:
	var code := 1 if failures else 0
	print("[WS1_ITEM_UI] COMPLETE checks=%d failures=%d" % [checks,failures])
	if is_instance_valid(game):
		game.queue_free()
		await process_frame
	quit(code)
