extends RefCounted
var game
var host

func run() -> void:
	var unique := Crypto.new().generate_random_bytes(8).hex_encode()
	game.characters.directory = "res://../temp/loop_tests/roster_" + unique
	game.characters.legacy_path = game.characters.directory.path_join("legacy.json")
	game.character_screen.show_roster()
	host.check(not game.character_active and game.overlay == "characters" and not game.hud.visible and not game.world_clip.visible, "startup is original character selection before town")
	host.check(game.character_screen.enter_button.disabled and game.characters.entries.is_empty(), "fresh roster has no automatic character and cannot enter")
	await host.frame("46_character_empty")
	host.key(KEY_I, true)
	await host.ticks(2)
	host.key(KEY_I, false)
	host.check(game.overlay == "characters" and not game.town.enabled, "game shortcuts do not bypass character gate")
	host.check(host.click_text("创建角色"), "create action opens fixed Swordman creation")
	await host.ticks(2)
	host.check(game.character_screen.creating and game.character_screen.name_input.has_focus(), "creation focuses real editable name field")
	await host.frame("47_character_create")
	host.check(host.click_text("创建角色"), "empty name is submitted through real button")
	await host.ticks(2)
	host.check(not game.character_screen.message_label.text.is_empty() and game.characters.entries.is_empty(), "invalid name does not create a save")
	await host.frame("48_character_name_error")
	game.character_screen.name_input.text = "剑士P号"
	host.key(KEY_P, true)
	await host.ticks(2)
	host.key(KEY_P, false)
	host.check(not game.debug_is_open(), "typing P in character name does not open debug panel")
	game.character_screen.name_input.text = "冒险家"
	game.character_screen.name_input.grab_focus()
	host.key(KEY_ENTER, true)
	await host.ticks(3)
	host.key(KEY_ENTER, false)
	await host.ticks(2)
	host.check(not game.character_screen.creating and game.characters.entries.size() == 1 and not game.character_active, "Enter creates Swordman and returns to selected roster without auto entering")
	var first: String = game.character_screen.selected_path
	await host.frame("49_character_selected")
	host.click_text("创建角色")
	await host.ticks(2)
	game.character_screen.name_input.text = "冒险家"
	host.click_text("创建角色")
	await host.ticks(2)
	host.check(game.characters.entries.size() == 1 and game.character_screen.message_label.text.contains("使用"), "duplicate character name is rejected")
	game.character_screen.name_input.text = "红莲剑士"
	host.click_text("创建角色")
	await host.ticks(3)
	var second: String = game.character_screen.selected_path
	host.check(second != first and game.characters.entries.size() == 2, "second character has independent file identifier")
	await host.ticks(12)
	await host.frame("50_character_roster")
	host.double_click_control(game.character_screen.slot_buttons[1 if game.characters.entries[1]["path"] == second else 0])
	await host.ticks(4)
	host.check(game.character_active and game.session.profile["name"] == "红莲剑士" and game.overlay == "", "double clicking selected Swordman enters town")
	host.check(game.town.player_name == "红莲剑士", "town nameplate uses selected character name")
	game.session.profile["gold"] = 987
	host.check(game.save_profile(), "active character progress is saved")
	game.show_overlay("menu")
	await host.ticks(2)
	host.check(host.click_text("返回选人"), "town menu returns to character selection")
	await host.ticks(3)
	host.check(not game.character_active and not game.town.enabled, "returning to roster stops town movement")
	host.check(game.character_screen.selected_path == second, "return to roster keeps active character selected")
	game.character_screen.selected_path = first
	game.character_screen.show_roster()
	host.click_control(game.character_screen.enter_button)
	await host.ticks(3)
	host.check(game.session.profile["name"] == "冒险家" and game.session.profile["gold"] == 300, "other character keeps separate initial money and inventory")
	game.show_character_selection()
	await host.ticks(2)
	game.character_screen.selected_path = second
	host.key(KEY_ENTER, true)
	await host.ticks(3)
	host.key(KEY_ENTER, false)
	host.check(game.character_active and game.session.profile["gold"] == 987, "Enter reopens saved character without resetting progress")
	# Test legacy discovery and corrupt-primary recovery without touching user data.
	var legacy = game.Store.new()
	legacy.path = game.characters.legacy_path
	var state = game.Session.new()
	state.profile["name"] = "旧存档剑士"
	state.profile["gold"] = 654
	legacy.write(state)
	legacy.write(state)
	var file := FileAccess.open(legacy.path, FileAccess.WRITE)
	file.store_string("broken")
	file.close()
	game.characters.refresh()
	var migrated := false
	for entry in game.characters.entries:
		if entry["path"] == legacy.path:migrated = entry["name"] == "旧存档剑士" and entry["recovered"]
	host.check(migrated and FileAccess.get_file_as_string(legacy.path) == "broken", "legacy save is discovered in place and backup recovery preserves original bytes")
	game.show_character_selection()
	await host.ticks(2)
	host.check(game.enter_character(legacy.path) and game.session.profile["gold"] == 654 and game.store.recovered, "legacy backup character enters with preserved progress")
	game.show_character_selection()
	await host.ticks(2)
	host.check(not game.enter_character(game.characters.directory.path_join("missing.json")) and not game.character_active, "missing save cannot enter or replace state")
	for value in ["a", "a/b", "带 空格", String.chr(0xac00) + "名字", "abcdefghijklmn"]:
		host.check(not game.characters.create(value)["ok"], "invalid character name is rejected: " + str(value.length()))
	# Saving failure must leave the roster unchanged.
	var blocked: String = game.characters.directory.path_join("blocked")
	file = FileAccess.open(blocked, FileAccess.WRITE)
	file.store_string("file")
	file.close()
	var original: String = game.characters.directory
	game.characters.directory = blocked + "/characters"
	host.check(not game.characters.create("失败测试")["ok"], "creation handles unwritable directory without fake success")
	game.characters.directory = original
	game.characters.refresh()
	host.check(game.characters.entries.size() == 3, "failed creation leaves previous character files intact")
	for value in ["测试剑士一", "测试剑士二", "测试剑士三"]:host.check(game.characters.create(value)["ok"], "remaining native slot accepts character")
	host.check(not game.characters.create("超过上限")["ok"] and game.characters.entries.size() == game.characters.LIMIT, "full roster rejects creation without overwriting existing saves")
	# A pending settled result remains a result when selected again; no reward replay.
	var result_store = game.Store.new()
	result_store.path = second
	var pending = game.Session.new()
	result_store.read_into(pending)
	pending.command("flow.depart")
	pending.combat_event({"type":"combat.room_combat_finished", "run_id":pending.run["id"], "final_room":true})
	result_store.write(pending)
	host.check(game.enter_character(second) and game.overlay == "result" and game.session.profile["gold"] == 1137, "selecting pending result preserves settled reward without repayment")
	game.return_town()
	game.show_character_selection()
	await host.ticks(3)
	game.character_screen.selected_path = first
	game.character_screen.show_roster()
	host.key(KEY_ENTER, true)
	await host.ticks(3)
	host.key(KEY_ENTER, false)
	host.check(game.character_active and game.session.profile["name"] == "冒险家", "existing complete town dungeon loop starts from selected character")
