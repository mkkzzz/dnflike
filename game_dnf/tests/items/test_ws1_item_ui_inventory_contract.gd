extends SceneTree
## ws1-owned inventory management board contract.
const Loop = preload("res://flow/loop_root.gd")

var game
var checks := 0
var failures := 0
var capture_dir := ""
var potion_uid := ""
var split_uid := ""

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var capture := "--capture" in args
	if capture:
		capture_dir = String(args[args.find("--output") + 1]) \
			if args.find("--output") >= 0 and args.find("--output") + 1 < args.size() else ""
		if OS.get_environment("DNF_PRIVATE_DESKTOP") != "1" \
			or DisplayServer.get_name() == "headless" or capture_dir == "":
			push_error("[WS1_INVENTORY_UI] capture requires the private desktop and --output")
			quit(1)
			return
	elif DisplayServer.get_name() != "headless":
		push_error("[WS1_INVENTORY_UI] headless display required")
		quit(1)
		return
	call_deferred("run")

func check(value: bool, message: String) -> void:
	checks += 1
	if value:
		print("[WS1_INVENTORY_UI] PASS " + message)
	else:
		failures += 1
		push_error("[WS1_INVENTORY_UI] FAIL " + message)

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

func consumable_stack(minimum := 1) -> String:
	for uid: String in game.session.profile["item_state"]["bags"]["consumable"]:
		if uid != "" and game.session.Inventory.definition(game.session.profile,uid) == "potion" \
			and game.session.Inventory.count(game.session.profile,uid) >= minimum:
			return uid
	return ""

func setup_game() -> void:
	game = Loop.new()
	root.add_child(game)
	await frames(4)
	var unique := Crypto.new().generate_random_bytes(8).hex_encode()
	game.store.path = "res://../temp/ws1_inventory_ui_tests/profile_" + unique + ".json"
	game.session = game.Session.new()
	game.session.profile["name"] = "仓库契约旅人"
	game.session.Inventory.give(game.session.profile,"potion",120)
	game.session.command("numbers.gear_give",{"id":"forest_sword","quality":100})
	game.session.command("numbers.gear_give",{"id":"forest_sword","quality":0})
	game.session.command("numbers.gear_give",{"id":"training_coat"})
	check(game.store.write(game.session),"disposable inventory character is written")
	check(game.enter_character(game.store.path),"disposable inventory character enters the real town flow")
	await frames(4)
	game.ui_audio.muted = true
	game.town.set_voice_enabled(false)
	game.town.stop_npc_voices(true)

func open_inventory() -> void:
	game.windows.inventory_tab = 1
	game.show_overlay("inventory")
	await frames(4)

func fill_storage() -> Array[String]:
	var fillers: Array[String] = []
	var storage: Array = game.session.profile["item_state"]["storage"]
	for index in storage.size():
		if storage[index] != "":
			continue
		var uid: String = game.session.Inventory.new_stack(game.session.profile,"scrap_iron",1)
		storage[index] = uid
		fillers.append(uid)
		if index == 47:
			break
	return fillers

func clear_fillers(fillers: Array[String], storage := true) -> void:
	var profile: Dictionary = game.session.profile
	for uid in fillers:
		if storage:
			var index: int = profile["item_state"]["storage"].find(uid)
			if index >= 0:
				profile["item_state"]["storage"][index] = ""
		else:
			for kind: String in game.session.Inventory.KINDS:
				var bag: Array = profile["item_state"]["bags"][kind]
				var index := bag.find(uid)
				if index >= 0:
					bag[index] = ""
					break
		profile["item_state"]["stacks"].erase(uid)
	game.session.Inventory.sync(profile)

func fill_consumable_bag() -> Array[String]:
	var fillers: Array[String] = []
	var bag: Array = game.session.profile["item_state"]["bags"]["consumable"]
	for index in bag.size():
		if bag[index] != "":
			continue
		var uid: String = game.session.Inventory.new_stack(game.session.profile,"potion",1)
		bag[index] = uid
		fillers.append(uid)
	game.session.Inventory.sync(game.session.profile)
	return fillers

func inventory_contract() -> void:
	await open_inventory()
	var root_window: Control = game.inventory_tools.window
	check(root_window != null and root_window.position == Vector2(8,16)
		and root_window.size == Vector2(460,488),"inventory management keeps the native 460x488 board")
	check(game.inventory_tools.window_builds == 1,"inventory management has one stable root build")
	var builds: int = game.inventory_tools.window_builds
	check(game.modal.find_child("storage_grid",true,false) != null,
		"storage exposes the native eight by six grid")
	potion_uid = consumable_stack(20)
	check(potion_uid != "","fixture finds a real multi-count potion stack")
	var slot := find_slot("bag",potion_uid)
	check(slot != null,"consumable tab exposes the selected stack")
	if slot != null:
		slot.pressed.emit()
		await frames(2)
	check(game.inventory_tools.selected == potion_uid
		and game.inventory_tools.detail.text.contains("恢复药剂"),
		"inventory selection follows the exact stack UID")
	check(game.inventory_tools.amount.max_value == game.session.Inventory.count(game.session.profile,potion_uid)-1,
		"split amount is capped below the full stack count")

	var source_count_before: int = game.session.Inventory.count(game.session.profile,potion_uid)
	game.inventory_tools.amount.get_line_edit().text = "10"
	game.inventory_tools.amount.apply()
	check(press_action("拆分堆叠"),"split action is available through the management board")
	await frames(4)
	check(game.session.Inventory.count(game.session.profile,potion_uid) == source_count_before-10
		and game.session.profile["inventory"]["potion"] == 123,
		"split preserves the total count and leaves the selected source stack")
	for uid: String in game.session.profile["item_state"]["bags"]["consumable"]:
		if uid != "" and uid != potion_uid and game.session.Inventory.definition(game.session.profile,uid) == "potion":
			split_uid = uid
			break
	check(split_uid != "","split creates a distinct owned stack UID")

	slot = find_slot("bag",potion_uid)
	if slot != null:
		slot.pressed.emit()
		await frames(2)
	check(press_action("锁定 / 解锁"),"lock action operates on the selected stack")
	await frames(4)
	check(game.session.Inventory.locked(game.session.profile,potion_uid),
		"lock persists on the exact stack")
	check(root.gui_get_focus_owner() == find_action("锁定 / 解锁"),
		"local refresh returns focus to the lock action")
	check(press_action("存入仓库"),"locked stack can attempt deposit")
	await frames(3)
	var feedback := game.modal.find_child("inventory_management_feedback",true,false) as Label
	check(potion_uid in game.session.profile["item_state"]["bags"]["consumable"]
		and feedback != null and feedback.visible and feedback.text.contains("解锁"),
		"locked deposit is rejected with an in-window receipt")
	check(press_action("锁定 / 解锁"),"selected stack can be unlocked")
	await frames(4)
	check(not game.session.Inventory.locked(game.session.profile,potion_uid),
		"unlock persists on the exact stack")
	check(press_action("存入仓库"),"unlocked stack deposits into storage")
	await frames(4)
	check(potion_uid in game.session.profile["item_state"]["storage"]
		and game.inventory_tools.selected_place == "storage",
		"deposit moves the exact stack and selection follows it")
	slot = find_slot("storage",potion_uid)
	if slot != null:
		slot.pressed.emit()
		await frames(2)
	check(press_action("取回背包"),"stored stack withdraws through the same root")
	await frames(4)
	check(potion_uid in game.session.profile["item_state"]["bags"]["consumable"]
		and game.inventory_tools.selected_place == "bag",
		"withdraw restores the exact stack and selection place")
	check(game.inventory_tools.window == root_window
		and game.inventory_tools.window_builds == builds,
		"split, lock, deposit and withdraw use local refresh")

	check(press_action("存入仓库"),"stack returns to storage for full-storage fixture")
	await frames(4)
	var fillers := fill_storage()
	game.inventory_tools._render_content()
	await frames(2)
	slot = find_slot("bag",split_uid)
	if slot != null:
		slot.pressed.emit()
		await frames(2)
	var before := JSON.stringify(game.session.serialize())
	check(press_action("存入仓库"),"deposit can be attempted when storage is full")
	await frames(3)
	feedback = game.modal.find_child("inventory_management_feedback",true,false) as Label
	check(split_uid in game.session.profile["item_state"]["bags"]["consumable"]
		and feedback != null and feedback.visible and feedback.text.contains("仓库已满")
		and JSON.stringify(game.session.serialize()) == before,
		"full storage rejects the move without changing ownership")
	clear_fillers(fillers)
	game.inventory_tools._render_content()
	await frames(2)

	var bag_fillers := fill_consumable_bag()
	slot = find_slot("storage",potion_uid)
	if slot != null:
		slot.pressed.emit()
		await frames(2)
	before = JSON.stringify(game.session.serialize())
	check(press_action("取回背包"),"withdraw can be attempted when the category is full")
	await frames(3)
	feedback = game.modal.find_child("inventory_management_feedback",true,false) as Label
	check(potion_uid in game.session.profile["item_state"]["storage"]
		and feedback != null and feedback.visible and feedback.text.contains("背包已满")
		and JSON.stringify(game.session.serialize()) == before,
		"full bag rejects withdrawal without losing the stored stack")
	clear_fillers(bag_fillers,false)
	game.inventory_tools._render_content()
	await frames(2)

	check(press_action("整理背包"),"sort action runs with no selected item")
	await frames(4)
	check(game.session.Inventory.valid(game.session.profile),"sort preserves a valid ownership ledger")
	check(game.inventory_tools.window == root_window
		and game.inventory_tools.window_builds == builds,
		"sort keeps the dedicated management root")

	slot = find_slot("bag",split_uid)
	if slot != null:
		slot.pressed.emit()
		await frames(2)
	var path: String = game.store.path
	game.store.path = "res://data/loot.json/cannot_write.json"
	before = JSON.stringify(game.session.serialize())
	check(press_action("锁定 / 解锁"),"lock can attempt a failing disk commit")
	await frames(4)
	feedback = game.modal.find_child("inventory_management_feedback",true,false) as Label
	check(game.save_failed and not game.session.Inventory.locked(game.session.profile,split_uid)
		and feedback != null and feedback.visible and feedback.text.contains("存档写入失败")
		and JSON.stringify(game.session.serialize()) == before,
		"failed item save preserves lock state and reports inline")
	game.store.path = path
	check(press_action("锁定 / 解锁"),"same lock action retries after save failure")
	await frames(4)
	check(game.session.Inventory.locked(game.session.profile,split_uid),
		"retry commits the lock once")

	slot = find_slot("storage",potion_uid)
	if slot != null:
		slot.pressed.emit()
		await frames(2)
	await capture_frame("inventory_management_1x",1)
	await capture_frame("inventory_management_2x",2)
	check(press_action("取回背包"),"captured storage selection can be withdrawn")
	await frames(4)
	var loaded = game.Session.new()
	check(game.store.read_into(loaded) and loaded.profile == game.session.profile,
		"inventory management operations survive actual disk reload")

func capture_frame(name: String, scale_factor: int) -> void:
	if capture_dir == "":
		return
	root.min_size = Vector2i(1,1)
	root.max_size = Vector2i(8192,8192)
	root.content_scale_size = Vector2i(800,600)*scale_factor
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
	check(colored > 100,"capture %s contains a nonblank rendered board" % name)
	if error == OK:
		print("[WS1_INVENTORY_UI] CAPTURE " + path)

func run() -> void:
	await setup_game()
	await inventory_contract()
	finish()

func finish() -> void:
	var code := 1 if failures else 0
	print("[WS1_INVENTORY_UI] COMPLETE checks=%d failures=%d" % [checks,failures])
	if is_instance_valid(game):
		game.queue_free()
		await process_frame
	quit(code)
