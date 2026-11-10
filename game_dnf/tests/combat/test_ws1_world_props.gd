extends SceneTree

const CombatSession = preload("res://combat/api/combat_session.gd")
const DUNGEONS := "res://data/dungeons.json"

var session := CombatSession.new()
var game
var checks := 0
var failures := 0
var audited_rooms := 0
var breakable_count := 0
var hazard_count := 0
var static_count := 0
var breakable_paths := {}
var hazard_paths := {}
var tested_breakables := {}
var tested_hazards := {}
var jar_candidate_props := 0
var tested_immediate_jar := false
var tested_delayed_jar := false

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("[WS1_WORLD_PROPS] FAIL " + label)

func run() -> void:
	var dungeons: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string(DUNGEONS)
	)["dungeons"]
	game = session.mount(root)
	game.set_process(false)
	game.set_physics_process(false)
	check(not game.missing_assets, "production combat content and assets load")
	if not game.missing_assets:
		var ids: Array = dungeons.keys()
		ids.sort()
		for dungeon_id: String in ids:
			var route: Dictionary = dungeons[dungeon_id]
			if bool(route.get("legacy", false)) or bool(route.get("hidden", false)) \
					or String(route.get("mode", "")) == "native_maze":
				continue
			audit_dungeon(dungeon_id, route)
		test_room_snapshot_persistence(dungeons)
	check(audited_rooms == 107, "all 107 rooms in the 17 visible dungeons were audited")
	check(breakable_count == 896, "all source breakableobject instances are counted")
	check(hazard_count == 152, "all source traps with attack info are counted")
	check(breakable_paths.size() == 22, "all 22 visible breakable source objects are covered")
	check(hazard_paths.size() == 7, "all 7 visible attack-trap source objects are covered")
	check(jar_candidate_props == 14, "all 14 mixed-payload props with verified trap branches are counted")
	check(tested_immediate_jar and tested_delayed_jar,
		"both immediate and delayed verified jar payloads execute")
	check(tested_breakables.size() == 22, "every visible breakable source object survives a source-HP hit chain")
	check(tested_hazards.size() == 7, "every visible attack-trap source object damages a contacting player")
	session.stop()
	await process_frame
	print("[WS1_WORLD_PROPS] COMPLETE checks=%d failures=%d rooms=%d breakable=%d hazard=%d static=%d" % [
		checks, failures, audited_rooms, breakable_count, hazard_count, static_count
	])
	quit(0 if failures == 0 else 1)

func test_room_snapshot_persistence(dungeons: Dictionary) -> void:
	var dungeon_id := "lorien_inside"
	var route: Dictionary = dungeons[dungeon_id]
	var spec := {
		"run_id": "ws1-world-props-snapshot",
		"dungeon": dungeon_id,
		"route": route,
		"room_id": dungeon_id + ":0",
		"room_index": 0,
		"player": {"hp": 500, "mp": 200, "weapon": "shortsword", "skill_slots": []},
		"audio": {"muted": true},
	}
	check(session.start_room(spec), "snapshot fixture starts its formal route")
	game.load_room(1, "start")
	var target: Dictionary = {}
	for prop: Dictionary in game.props:
		if bool(prop.get("breakable", false)):
			target = prop
			break
	check(not target.is_empty(), "snapshot fixture finds a source breakable")
	if target.is_empty():
		return
	var node := int(target["node"])
	var amount := int(target["hp"]) * int(target["stages"])
	check(game.apply_legacy_prop_damage(target, amount), "snapshot fixture destroys the source prop")
	check(game.room_snapshots.get(game.room_index, {}).has("props"),
		"destroying a prop writes the current room snapshot")
	game.load_room(game.room_index, "start")
	var restored: Dictionary = {}
	for prop: Dictionary in game.props:
		if int(prop["node"]) == node:
			restored = prop
			break
	check(not restored.is_empty() and bool(restored.get("broken", false)),
		"reloading the room restores the destroyed prop state")
	var stage_info: Dictionary = game.view_snapshot().get("stage", {})
	check(node in (stage_info.get("broken_props", []) as Array),
		"the restored room view receives the broken prop index")
	game.view.stage.invalidate_room()
	game.view.present(game.view_snapshot(), 0.0, 0.0)
	var hidden := false
	if game.view.stage.root != null:
		for child in game.view.stage.root.get_children():
			if int(child.get_meta("prop_node", -1)) == node:
				hidden = not child.visible
				break
	check(hidden, "a rebuilt map hides the restored broken prop")

func audit_dungeon(dungeon_id: String, route: Dictionary) -> void:
	var spec := {
		"run_id": "ws1-world-props-" + dungeon_id,
		"dungeon": dungeon_id,
		"route": route,
		"room_id": dungeon_id + ":0",
		"room_index": 0,
		"player": {"hp": 500, "mp": 200, "weapon": "shortsword", "skill_slots": []},
		"audio": {"muted": true},
	}
	check(session.start_room(spec), "formal route accepts " + dungeon_id)
	if game.room_index != 0 or game.missing_assets:
		return
	for index in (route.get("rooms", []) as Array).size():
		if index > 0:
			game.load_room(index, "start")
		check_room(dungeon_id, index)

func check_room(dungeon_id: String, index: int) -> void:
	audited_rooms += 1
	var expected := {}
	var source_objects: Array = game.room_map.get("objects", [])
	for object_index in source_objects.size():
		var item: Dictionary = source_objects[object_index]
		var path := String(item.get("obj", "")).to_lower()
		var source: Dictionary = game.content.record(path)
		var decoded: Dictionary = source.get("decoded", {})
		var kind := ""
		if path.contains("breakableobject/"):
			kind = "breakable"
		elif path.contains("/trap/") and not (decoded.get("attack_infos", []) as Array).is_empty():
			kind = "hazard"
		if kind.is_empty():
			static_count += 1
			continue
		expected[object_index] = kind
		if kind == "breakable":
			breakable_count += 1
			breakable_paths[path] = true
		else:
			hazard_count += 1
			hazard_paths[path] = true
	var actual := {}
	for prop: Dictionary in game.props:
		actual[int(prop["node"])] = prop
	var label := "%s room %d" % [dungeon_id, index + 1]
	check(actual.size() == expected.size(), label + " builds exactly its interactive source props")
	for node: int in expected:
		check(actual.has(node), label + " builds prop node " + str(node))
		if not actual.has(node):
			continue
		var prop: Dictionary = actual[node]
		var item: Dictionary = source_objects[node]
		var path := String(item.get("obj", "")).to_lower()
		var source: Dictionary = game.content.record(path).get("decoded", {})
		var anchor: Array = item.get("anchor", [])
		check(Vector2(prop["pos"]) == Vector2(float(anchor[0]), float(anchor[1])),
			label + " keeps source anchor for " + path)
		check(String(prop.get("source_path", "")) == path, label + " records its source path for " + path)
		if expected[node] == "breakable":
			check(bool(prop.get("breakable", false)), label + " marks " + path + " breakable")
			check(not bool(prop.get("hazard", false)), label + " does not treat " + path + " as a damage trap")
			check(int(prop.get("stages", 0)) == breakable_stages(source),
				label + " preserves source stages for " + path)
			check(int(prop.get("hp", 0)) == breakable_hp(source),
				label + " preserves source HP for " + path)
			check(String(prop.get("hit_sound", "")) == breakable_hit_sound(source),
				label + " preserves source hit sound for " + path)
			check(String(prop.get("break_sound", "")) == breakable_destroy_sound(source),
				label + " preserves source destroy sound for " + path)
			if int(prop.get("jar_trap_candidates", 0)) > 0:
				jar_candidate_props += 1
				check(prop.has("jar_trap") or prop.get("jar_trap_miss", false),
					label + " resolves or records its mixed trap selection for " + path)
			if not tested_breakables.has(path):
				test_breakable(prop, path)
			elif int(prop.get("jar_trap_candidates", 0)) > 0:
				test_generic_jar_payload(prop, path)
		else:
			check(bool(prop.get("hazard", false)), label + " marks " + path + " as a damage trap")
			check(not (prop.get("damage_atk", {}) as Dictionary).is_empty(),
				label + " resolves damage ATK for " + path)
			if not tested_hazards.has(path):
				test_hazard(prop, path)

func test_breakable(prop: Dictionary, path: String) -> void:
	tested_breakables[path] = true
	game.bus.clear_history()
	for sound: String in [String(prop["hit_sound"]), String(prop["break_sound"])]:
		if sound.is_empty():
			continue
		var clips: Array = game.combat_assets.get("audio", {}).get(sound, [])
		var playable := clips.any(func(clip): return ResourceLoader.exists(String(clip["file"]), "AudioStream"))
		var unresolved := (game.combat_assets.get("unresolved", []) as Array).any(
			func(entry): return entry.get("kind", "") == "audio" and entry.get("key", "") == sound)
		check(playable or unresolved, path + " either resolves " + sound + " or records the source gap")
	var source: Dictionary = prop["def"]
	var has_particle_source := not (source.get("destroy_particle", []) as Array).is_empty()
	for value in source.get("string_data", []):
		if String(value).to_lower().ends_with(".ptl"):
			has_particle_source = true
	var particle_keys: Array = game.breakable_particle_keys(path)
	if has_particle_source:
		check(not particle_keys.is_empty(), path + " resolves its original destroy particles")
	for key in particle_keys:
		var bank: Dictionary = game.combat_assets.get("effects", {}).get(String(key), {})
		var texture := String(bank.get("atlas", {}).get("texture", ""))
		check(ResourceLoader.exists(texture, "Texture2D"), path + " bakes destroy particle " + String(key))
	var stages := int(prop["stages"])
	var source_hp := int(prop["hp"])
	var destroy_on_final := bool(prop["destroy_on_final_stage"])
	for index in stages:
		var destroyed: bool = game.apply_legacy_prop_damage(prop, source_hp)
		var final := index+1 == stages
		check(destroyed == (final and destroy_on_final),
			path + " reports destruction only when its source stages end")
		check(bool(prop["broken"]) == (final and destroy_on_final),
			path + " keeps its source final-stage destruction policy")
		if not final:
			check(int(prop["stage"]) == index+1 and int(prop["hp"]) == source_hp,
				path + " restores source HP between stages")
	var events: Array = game.bus.events_of("combat.prop_broken")
	check(events.size() == (1 if destroy_on_final else 0),
		path + " emits one map hide event exactly when destroyed")

func test_hazard(prop: Dictionary, path: String) -> void:
	tested_hazards[path] = true
	game.player["pos"] = Vector2(prop["pos"])
	game.player["z"] = 0.0
	game.player["invuln_ms"] = 0.0
	game.player["hp"] = 500.0
	game.god_mode = false
	prop["hazard_ms"] = 0.0
	var before := float(game.player["hp"])
	game.step_hazards(1.0)
	check(float(game.player["hp"]) < before, path + " damages a contacting player")
	check(float(prop["hazard_ms"]) > 0.0, path + " arms its post-hit interval")
	var after := float(game.player["hp"])
	game.step_hazards(1.0)
	check(float(game.player["hp"]) == after, path + " does not damage twice inside its interval")

func test_generic_jar_payload(prop: Dictionary, path: String) -> void:
	var selection: Dictionary = prop.get("jar_trap", {})
	if selection.is_empty():
		return
	var source_id := int(selection["id"])
	if source_id in [40002, 48003]:
		if tested_delayed_jar:
			return
		tested_delayed_jar = true
		var before: int = game.native_jar_traps.actors.size()
		var amount := int(prop["hp"]) * int(prop["stages"])
		check(not game.apply_legacy_prop_damage(prop, amount),
			path + " delayed trap waits instead of destroying immediately")
		check(prop.has("jar_warning") and not bool(prop["broken"]),
			path + " keeps the source pot visible during its trap warning")
		game.native_jar_traps.advance_clock(game, 10000.0)
		game.native_jar_traps.step(game)
		check(bool(prop["broken"]) and game.native_jar_traps.actors.size() > before,
			path + " delayed trap destroys the pot and spawns after the warning")
	elif source_id in [2200, 2210, 2410]:
		if tested_immediate_jar:
			return
		tested_immediate_jar = true
		var before: int = game.native_jar_traps.actors.size()
		var amount := int(prop["hp"]) * int(prop["stages"])
		check(game.apply_legacy_prop_damage(prop, amount),
			path + " immediate jar payload destroys the source prop")
		check(game.native_jar_traps.actors.size() > before,
			path + " immediate jar payload creates its source actor")

func breakable_stages(source: Dictionary) -> int:
	var data: Array = source.get("int_data", [])
	if data.size() >= 7:
		return maxi(1, int(data[1]))
	if data.size() == 2:
		return maxi(1, int(data[1]))
	return 1

func breakable_hp(source: Dictionary) -> int:
	var data: Array = source.get("int_data", [])
	if data.size() >= 7:
		return maxi(1, int(data[6]))
	if data.size() == 2:
		return maxi(1, int(data[0]))
	return 1

func breakable_hit_sound(source: Dictionary) -> String:
	var strings: Array = source.get("string_data", [])
	if strings.size() >= 7:
		return String(strings[4])
	if strings.size() >= 5:
		return String(strings[4])
	if strings.size() >= 2:
		return String(strings[1])
	return ""

func breakable_destroy_sound(source: Dictionary) -> String:
	var strings: Array = source.get("string_data", [])
	if strings.size() >= 6 and String(strings[5]) != "":
		return String(strings[5])
	if strings.size() == 3:
		return String(strings[2])
	return ""
