extends Node
## Real keyboard/GUI regression. Profile edits use a separate temporary save.
const RuntimeAPI = preload("res://debug/runtime_api.gd")
var game
var host

func ticks(count := 4) -> void:
	for i in count:await get_tree().physics_frame

func key(code: int, unicode := 0, echo := false) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.unicode = unicode
	event.pressed = true
	event.echo = echo
	Input.parse_input_event(event)
	await ticks()
	event = event.duplicate()
	event.pressed = false
	event.echo = false
	Input.parse_input_event(event)
	await ticks()

func submit(text: String) -> void:
	game.debug_panel.command_input.grab_focus()
	game.debug_panel.command_input.text = text
	await key(KEY_ENTER)
	host.check(game.debug_panel.command_input.text.is_empty() and game.debug_panel.history[-1] == text, "one Enter submits the next console command: " + text)

func button(command: String) -> void:
	for node in game.debug_panel.find_children("*", "Button", true, false):
		if node.get_meta("gm_command", "") == command:
			host.click_control(node)
			await ticks()
			return
	host.check(false, "GM button exists: " + command)

func run() -> void:
	var original = game.session
	var path: String = game.store.path
	game.session = game.Session.new()
	game.store.path = "res://../temp/loop_tests/gm_profile.json"
	game.show_overlay("")
	if DisplayServer.get_name() != "headless":host.check(game.get_window().unresizable, "fixed 1080p disables window resizing")
	await key(KEY_P)
	host.check(game.debug_is_open() and game.debug_panel.is_visible_in_tree(), "P opens an actually visible GM panel")
	await key(KEY_P, 0, true)
	host.check(game.debug_is_open(), "held P does not repeatedly toggle GM")
	game.debug_panel.command_input.grab_focus()
	game.debug_panel.command_input.text = ""
	await key(KEY_P, 112)
	host.check(game.debug_is_open() and game.debug_panel.command_input.text == "p", "typing p is text and never closes the console")
	await key(KEY_ESCAPE)
	host.check(not game.debug_is_open() and not game.debug_panel.command_input.has_focus(), "Esc closes GM and releases input focus")
	await key(KEY_P)
	await submit("give potion 2")
	host.check(game.session.profile["inventory"]["potion"] == 5, "Enter executes typed item grant")
	await key(KEY_UP)
	host.check(game.debug_panel.command_input.text == "give potion 2", "Up retrieves previous command")
	await key(KEY_DOWN)
	host.check(game.debug_panel.command_input.text == "", "Down restores the draft after history")
	await button("gold 1000")
	host.check(game.session.profile["gold"] == 1300, "GUI button executes actual gold grant")
	var loaded = game.Session.new()
	host.check(game.store.read_into(loaded) and loaded.profile == game.session.profile, "GM item and gold edits round-trip through the save")
	var gold: int = game.session.profile["gold"]
	for text in ["gold -1", "give unknown 2", "give potion 1.5", "level 61", "room 0", "not_a_command"]:
		host.check(not game.debug_panel.execute(text)["ok"], "invalid GM command is rejected: " + text)
	host.check(game.session.profile["gold"] == gold and game.session.profile["inventory"]["potion"] == 5, "invalid commands preserve profile state")
	await submit("help")
	await host.frame("13_gm_town_help")
	await button("dungeon enter")
	host.check(game.session.state == "battle" and game.combat.read_view()["paused"], "GM can enter a dungeon while keeping it paused")
	var api = RuntimeAPI.new(game.battle)
	var elapsed: float = api.elapsed_ms()
	await ticks(20)
	host.check(api.elapsed_ms() == elapsed and not game.battle.is_processing_input(), "GM opening freezes combat and disconnects battle key input")
	await submit("spawn goblin 2")
	host.check(game.battle.held.is_empty() and game.battle.requests.is_empty(), "command typing never leaks into battle actions")
	var count: int = game.combat.read_view()["alive_monsters"]
	await submit("spawn thrower 2")
	host.check(game.combat.read_view()["alive_monsters"] == count + 2, "spawn command creates original thrower enemies")
	for text in ["spawn goblin 0", "spawn goblin 21", "spawn unknown 1", "room 99", "god perhaps"]:
		host.check(not game.debug_panel.execute(text)["ok"], "invalid battle GM request is rejected: " + text)
	api.set_p("hp", 1.0)
	api.set_p("mp", 0.0)
	await button("heal")
	var view: Dictionary = game.combat.read_view()
	host.check(view["hp"] == view["hp_max"] and view["mp"] == view["mp_max"], "heal button restores real HP and MP")
	api.game.player["cooldowns"]["draw"] = 9.0
	await button("cooldown")
	host.check(game.combat.read_view()["cooldowns"].is_empty(), "cooldown button clears actual skill cooldowns")
	await submit("god on")
	host.check(api.god(), "god on applies to battle")
	await button("collision")
	host.check(api.collision() and game.battle.view.stage.debug_collision, "collision command changes rendered geometry")
	await submit("weapon greatsword")
	host.check(api.weapon() == "greatsword" and game.session.profile["equipped"] == "iron_sword", "temporary weapon appearance preserves equipped profile item")
	await submit("room 3")
	host.check(game.combat.read_view()["room"] == 3, "numbered room command jumps to requested room")
	await button("room next")
	host.check(game.combat.read_view()["room"] == 4, "next room button follows numbered rooms")
	await button("room boss")
	host.check(game.combat.read_view()["room"] == 5, "boss button reaches final room")
	await submit("room 1")
	await submit("status")
	await host.frame("14_gm_battle")
	game.debug_panel.command_input.release_focus()
	await key(KEY_P)
	host.check(not game.debug_is_open() and not game.combat.read_view()["paused"] and not game.battle.is_processing_input(), "P closes panel and restores routed battle input")
	await key(KEY_P)
	await button("clear")
	game.set_debug_open(false)
	await ticks(40)
	host.check(game.combat.read_view()["room_cleared"] and game.session.state == "battle", "clear command opens the normal room without awarding victory")
	game.set_debug_open(true)
	await button("spawn goblin 1")
	host.check(not game.combat.read_view()["room_cleared"] and game.combat.read_view()["alive_monsters"] == 1, "spawning in a cleared room relocks its exits")
	await button("win")
	await ticks(45)
	host.check(game.session.state == "result" and game.session.result["victory"] and game.session.profile["clears"] == 1, "win command reaches real victory and grants a single clear")
	gold = game.session.profile["gold"]
	host.check(not game.debug_panel.execute("win")["ok"] and game.session.profile["gold"] == gold, "repeated win does not pay a second reward")
	game.set_debug_open(true)
	await button("dungeon restart")
	host.check(game.session.state == "battle" and game.combat.read_view()["room"] == 1 and game.combat.read_view()["paused"], "restart button creates a fresh paused adventure")
	await button("lose")
	await ticks(8)
	host.check(game.session.state == "defeated" and game.session.result.is_empty() and not game.session.run["recovery"]["pending"].is_empty(), "lose command reaches pending death choice without rewards")
	game.set_debug_open(true)
	await button("town")
	host.check(game.session.state == "town" and not is_instance_valid(game.battle), "town button cleans up combat and restores town")
	await button("level 60")
	host.check(game.session.profile["level"] == 60 and is_equal_approx(float(game.session.stats()["hp"]),2441.1), "level command updates the next-run stat source")
	game.set_debug_open(false)
	await key(KEY_F3)
	host.check(game.get_window().content_scale_size == Vector2i(game.display_settings.OUTPUT), "F3 cannot change the fixed output resolution")
	if host.capture:
		await key(KEY_F11)
		await RenderingServer.frame_post_draw
		host.check(get_viewport().get_texture().get_image().get_size() == Vector2i(game.display_settings.OUTPUT), "fullscreen keeps the fixed render target")
		await key(KEY_F11)
	game.session = original
	game.store.path = path
	game.show_overlay("")
