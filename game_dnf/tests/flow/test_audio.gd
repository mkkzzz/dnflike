extends RefCounted
## Runtime audio contracts: one-shot NPC voice, interface routing, and menu lifecycle.
var game
var host

func run() -> void:
	host.check(game.ui_audio.stream_count() >= 20, "original UI audio manifest loads semantic cues")
	for key in ["click", "hover", "window_open", "window_close", "character_create", "quest_accept", "quest_complete"]:
		host.check(game.ui_audio.streams.has(key), "UI audio cue is available: " + key)

	# Character selection/creation must fully outlive the hidden town scene without voices.
	game.show_character_selection()
	await host.ticks(3)
	var hidden_state: Dictionary = game.town.voice_debug()
	host.check(not hidden_state["ambient_playing"] and not hidden_state["speech_playing"], "character selection stops town ambient and speech voices")
	host.check(game.enter_character(game.active_character_path), "selected character re-enters after audio lifecycle check")
	await host.ticks(2)

	var linus: Vector2 = game.session.TownWorld.vec(game.town.world.scene("elvengard")["npcs"]["linus"])
	game.town.set_location("elvengard", linus)
	game.town.enabled = true
	game.town.set_voice_enabled(true)
	game.town.stop_npc_voices(true)
	await host.ticks(2)
	var near_state: Dictionary = game.town.voice_debug()
	host.check(near_state["ambient_npc"] == "linus", "approaching Linus selects his ambient voice")
	host.check(not near_state["ambient_loop"], "NPC ambient voice is a one-shot cue rather than a loop")
	var first_count := int(game.town.ambient_play_count.get("linus", 0))
	game.town._update_npc_voices()
	host.check(int(game.town.ambient_play_count.get("linus", 0)) == first_count, "staying near an NPC does not replay the ambient cue")
	game.town.ground = linus + Vector2(260, 0)
	game.town._update_npc_voices()
	host.check(game.town.ambient_npc == "", "leaving the NPC range clears the ambient voice latch")
	game.town.ground = linus
	game.town._update_npc_voices()
	host.check(int(game.town.ambient_play_count.get("linus", 0)) == first_count + 1, "re-entering the NPC range may play one new cue")

	var opens: int = game.ui_audio.play_count("window_open")
	game.show_overlay("menu")
	await host.ticks(2)
	host.check(game.ui_audio.play_count("window_open") == opens + 1, "opening a native window plays its original cue")
	var continue_button: Control
	for node in game.ui.find_children("*", "BaseButton", true, false):
		if String(node.get_meta("action_label", "")) == "继续游戏":
			continue_button = node
			break
	var hovers: int = game.ui_audio.play_count("hover")
	if continue_button != null:
		await host.hover_control(continue_button)
	host.check(continue_button != null and game.ui_audio.play_count("hover") > hovers, "hovering a native button plays one lightweight UI cue")
	var clicks: int = game.ui_audio.play_count("click")
	var closes: int = game.ui_audio.play_count("window_close")
	host.check(host.click_text("继续游戏"), "real native menu button remains clickable with audio routing")
	await host.ticks(2)
	host.check(game.ui_audio.play_count("click") > clicks, "native button press routes through shared UI audio")
	host.check(game.ui_audio.play_count("window_close") > closes, "closing the window plays the close cue")

	game.town.set_location("elvengard", linus)
	game.town.enabled = true
	game.town.set_voice_enabled(true)
	game.town.stop_npc_voices(true)
	game.show_overlay("npc")
	await host.ticks(2)
	var talk_state: Dictionary = game.town.voice_debug()
	host.check(talk_state["speech_npc"] == "linus" and talk_state["speech_kind"] == "talk", "opening dialogue plays one talk line for the nearest NPC")
	var talk_count := int(talk_state["talk_count"])
	game.show_overlay("quest")
	await host.ticks(2)
	host.check(game.town.voice_debug()["speech_kind"] == "talk", "switching dialogue tabs does not restart the greeting")
	game.show_overlay("npc")
	await host.ticks(2)
	host.check(int(game.town.voice_debug()["talk_count"]) == talk_count, "returning from a dialogue tab does not replay the greeting")
	game.show_overlay("")
	await host.ticks(2)
	var close_state: Dictionary = game.town.voice_debug()
	host.check(close_state["speech_kind"] == "farewell" and game.conversation_npc == "", "ending the conversation plays one farewell and clears dialogue state")
