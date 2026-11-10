extends RefCounted
var game
var host
const RuntimeAPI = preload("res://debug/runtime_api.gd")
const Numbers = preload("res://stats/api/numbers.gd")

func run() -> void:
	game.show_overlay("numbers")
	await host.ticks(3)
	host.check(is_instance_valid(game.modal.find_child("number_window",true,false)),"numeric attributes window opens using native skin")
	await host.frame("60_number_attributes")
	game.number_windows.tab=1
	game.show_overlay("numbers")
	await host.ticks(3)
	await host.frame("61_number_skills")
	var skill_panel=game.number_windows.skill_panel
	await preload("res://tests/flow/test_skill_panel.gd").new().run(game, host)
	await preload("res://tests/flow/test_skill_shortcuts.gd").new().run(game, host, self)
	var viewport:Control=game.modal.find_child("skill_tree_viewport",true,false)
	var content:Control=game.modal.find_child("skill_tree_content",true,false)
	var base_upper:Control=game.modal.find_child("skill_node_46",true,false)
	var detail:Control=game.modal.find_child("skill_detail",true,false)
	var popup:Control=viewport.get_parent()
	host.check(viewport != null and viewport.size==Vector2(540,342),"large skill popup keeps a scrollable source-coordinate tree")
	host.check(popup.get_global_rect().end.y < game.hud.find_child("hud_skill_slot_6",true,false).get_global_rect().position.y,"large skill popup leaves both live HUD shortcut rows uncovered")
	host.check(detail != null and detail.position==Vector2(562,35) and detail.size==Vector2(199,402),"popup keeps native-width explanation board with enough space above the HUD")
	host.check(base_upper != null and base_upper.get_meta("tree_x",-1)==235 and base_upper.get_meta("tree_y",-1)==0,"skill node uses the measured Swordman_Sp.co coordinate")
	host.check(skill_panel.tree_nodes("none").size()==17 and skill_panel.tree_edges("weaponmaster").size()==4,"all source job branches and prerequisite edges are loaded")
	var original_job:String=game.session.profile["growtype"]
	game.session.profile["growtype"]="weaponmaster"
	game.show_overlay("numbers")
	await host.ticks(3)
	var edge:Line2D=game.modal.find_child("skill_edge_1_3",true,false)
	viewport=game.modal.find_child("skill_tree_viewport",true,false)
	content=game.modal.find_child("skill_tree_content",true,false)
	host.check(edge != null and edge.points.size()==2,"weaponmaster draws the original guard-to-autoguard prerequisite edge")
	var left_node:Control=game.modal.find_child("skill_node_94",true,false)
	host.check(left_node != null and left_node.position.x >= 0 and left_node.position.y >= 0,"leftmost and first-row skill borders stay inside the clipped viewport")
	var detail_icon:TextureRect=game.modal.find_child("skill_detail_icon",true,false)
	host.check(detail_icon != null and detail_icon.size==Vector2(28,28) and detail_icon.scale==Vector2.ONE,"detail icon retains its native pixels without enlargement")
	var read_only:Control=game.modal.find_child("skill_node_17",true,false)
	var read_only_frame:TextureRect=read_only.get_child(0)
	var original_tint:=read_only_frame.modulate
	read_only.mouse_entered.emit()
	read_only.mouse_exited.emit()
	host.check(read_only_frame.modulate==original_tint,"hover restores the read-only node tint instead of making it look available")
	skill_panel.selected="illusionslash"
	game.show_overlay("numbers")
	await host.ticks(3)
	var body:RichTextLabel=game.modal.find_child("skill_detail_body",true,false)
	host.check(body != null and body.position==Vector2(9,176) and body.size.y==210 and body.scroll_active,"popup explanation fits 15 full source rows within the adapted height")
	var source_pitch := body.get_line_count() > 1
	for line in range(1, body.get_line_count()):
		source_pitch = source_pitch and is_equal_approx(body.get_line_offset(line) - body.get_line_offset(line - 1), 14.0)
	host.check(source_pitch, "wrapped and explicit explanation lines use the source 14px pitch")
	var wheel:=InputEventMouseButton.new()
	wheel.position=body.get_global_transform_with_canvas()*Vector2(80,120)
	wheel.button_index=MOUSE_BUTTON_WHEEL_DOWN
	wheel.pressed=true
	var initial_tree_scroll: float = skill_panel.tree_scroll
	game.get_viewport().push_input(wheel,true)
	var wheel_release := wheel.duplicate() as InputEventMouseButton
	wheel_release.pressed = false
	game.get_viewport().push_input(wheel_release, true)
	await host.ticks(3)
	var detail_scroll := body.get_parent().get_node("skill_detail_scroll") as VScrollBar
	host.check(detail_scroll.value > 0 and fmod(detail_scroll.value, 14.0) == 0.0 and skill_panel.tree_scroll == initial_tree_scroll,
		"mouse wheel scrolls the explanation by whole rows without moving the skill tree")
	host.check(detail_scroll.size.x == 15 and detail_scroll.position.x == body.position.x + 174,
		"the Explain scrollbar leaves the 174px text width intact")
	var motion := InputEventMouseMotion.new()
	for direction in [1, -1]:
		var previous := detail_scroll.value
		var arrow := InputEventMouseButton.new()
		arrow.position = detail_scroll.get_global_transform_with_canvas() * Vector2(8, detail_scroll.size.y - 8 if direction > 0 else 8)
		motion.position = arrow.position
		game.get_viewport().push_input(motion, true)
		await host.ticks(1)
		arrow.button_index = MOUSE_BUTTON_LEFT
		arrow.pressed = true
		game.get_viewport().push_input(arrow, true)
		arrow = arrow.duplicate()
		arrow.pressed = false
		game.get_viewport().push_input(arrow, true)
		await host.ticks(2)
		host.check(is_equal_approx(detail_scroll.value, previous + direction * 14.0),
			"the Explain scrollbar arrow moves exactly one row")
	var detail_track = detail_scroll.get_node("skill_detail_scroll_track")
	var description := body.text
	var fits_source_width := "汉".repeat(15) + "A"
	body.text = (fits_source_width + "\n").repeat(28) + fits_source_width
	await host.ticks(3)
	detail_scroll.value = 0
	host.check(detail_track.thumb_rect() == Rect2(0, 0, 15, 14),
		"long Explain text uses the two original 7px thumb caps")
	_explain_pointer(detail_track, 8, true)
	_explain_motion(detail_track, 100)
	await host.ticks(1)
	host.check(detail_scroll.value == 8 * 14 and detail_track.thumb_rect().position.y == 94,
		"the short Explain thumb maps the pointer one-third down its height to an integer row")
	_explain_motion(detail_track, 220)
	_explain_pointer(detail_track, 220, false)
	await host.ticks(1)
	host.check(detail_scroll.value == 14 * 14 and detail_track.thumb_rect().end.y == 178 and skill_panel.tree_scroll == initial_tree_scroll,
		"the short thumb clamps at the last full row and drags independently of the skill tree")
	body.text = fits_source_width
	await host.ticks(3)
	host.check(not detail_scroll.visible and body.get_line_count() == 1,
		"a 173px description line fits the source width with no scrollbar")
	body.text = (fits_source_width + "\n").repeat(19) + fits_source_width
	await host.ticks(3)
	host.check(detail_scroll.visible and body.get_line_count() == 20,
		"showing the scrollbar preserves the source description wrap width")
	detail_scroll.value = 0
	host.check(detail_track.thumb_rect() == Rect2(0, 0, 15, 78),
		"a five-row overflow leaves exactly 100px for the original long thumb travel")
	_explain_pointer(detail_track, 160, true)
	_explain_pointer(detail_track, 160, false)
	host.check(detail_scroll.value == 14 and detail_track.thumb_rect().position.y == 20,
		"clicking beyond the long Explain thumb moves one row instead of one page")
	_explain_pointer(detail_track, 30, true)
	_explain_motion(detail_track, 49)
	host.check(detail_scroll.value == 14, "long Explain drag waits for the 20px row boundary")
	_explain_motion(detail_track, 50)
	_explain_pointer(detail_track, 50, false)
	host.check(detail_scroll.value == 28 and detail_track.thumb_rect().position.y == 40,
		"long Explain drag keeps the grabbed offset and moves one row at the source boundary")
	body.text = "汉".repeat(16)
	await host.ticks(3)
	host.check(not detail_scroll.visible and body.get_line_count() == 2,
		"a 176px description line wraps at the source 174px boundary")
	body.text = description
	host.check(game.modal.find_child("skill_panel_slot_5",true,false)==null and game.hud.find_child("hud_skill_slot_11",true,false)!=null,"popup has no duplicate shortcut controls and live HUD exposes twelve drop targets")
	viewport=game.modal.find_child("skill_tree_viewport",true,false)
	content=game.modal.find_child("skill_tree_content",true,false)
	wheel.position=viewport.get_global_transform_with_canvas()*Vector2(280,200)
	game.get_viewport().push_input(wheel,true)
	await host.ticks(3)
	var scroll:VScrollBar=game.modal.find_child("skill_tree_scroll",true,false)
	host.check(scroll != null and scroll.value>0 and content.position.y==-scroll.value,"mouse wheel scrolls the original-height skill tree and its content together")
	skill_panel.tree_scroll=0
	game.show_overlay("numbers")
	await host.ticks(3)
	await drag_skill(game.modal.find_child("skill_node_5",true,false),game.hud.find_child("hud_skill_slot_6",true,false))
	host.check(game.session.profile["skill_slots"][6]=="hardattack" and game.session.profile["skill_slots"].count("hardattack")==1,"tree drag reaches the uncovered Q slot and persists one learned binding")
	await drag_skill(game.hud.find_child("hud_skill_slot_6",true,false),game.hud.find_child("hud_skill_slot_11",true,false))
	host.check(game.session.profile["skill_slots"][11]=="hardattack" and game.session.profile["skill_slots"][6]=="","live upper shortcut row moves from Q to Y without duplication")
	await drag_skill(game.hud.find_child("hud_skill_slot_11",true,false),game.hud.find_child("hud_skill_slot_5",true,false))
	host.check(game.session.profile["skill_slots"][5]=="hardattack" and game.session.profile["skill_slots"][11]=="","shortcut can move between the QWERTY and ASDFGH rows while the popup is open")
	game.session.profile["growtype"]=original_job
	skill_panel.selected="upperslash"
	game.show_overlay("numbers")
	await host.ticks(3)
	host.check(game.debug_panel.commands.execute("sp 100")["ok"],"GM grants SP through numeric transaction")
	host.check(game.debug_panel.commands.execute("level 4")["ok"],"GM raises the character to the next original skill-rank threshold")
	await host.ticks(3)
	var initial_sp := Numbers.Skills.available(game.session.profile,Numbers.config_snapshot())
	var retained_tree: Control = game.modal.find_child("skill_tree_content",true,false)
	var sp_digits: Control = game.modal.find_child("skill_sp_digits",true,false)
	if is_instance_valid(sp_digits):
		skill_panel._set_sp(1380)
		var positions: Array[Vector2] = []
		for glyph: TextureRect in sp_digits.get_children():
			if glyph.visible:
				positions.append(sp_digits.position + glyph.position)
		host.check(positions == [Vector2(356,45), Vector2(364,45), Vector2(373,45), Vector2(382,45)],
			"mixed-width SP glyphs use the source center, crop origins, and canvas advance")
		skill_panel._set_sp(99999)
		host.check(sp_digits.visible and sp_digits.get_child_count() == 5 and sp_digits.get_child(4).visible,
			"the SP number set renders five digits with its original atlas")
		skill_panel._set_sp(100000)
		host.check(not sp_digits.visible and skill_panel._sp_label.visible and skill_panel._sp_label.text == "100000",
			"custom SP above the source limit remains readable")
		skill_panel._set_sp(initial_sp)
	host.check(host.click_text("加点"),"actual skill learn button accepts mouse click")
	await host.ticks(3)
	host.check(game.session.profile["skills"]["upper"]==2 and Numbers.Skills.available(game.session.profile,Numbers.config_snapshot())==initial_sp-20,"UI purchase changes skill rank and spends SP")
	host.check(is_instance_valid(retained_tree) and retained_tree==game.modal.find_child("skill_tree_content",true,false),"learning refreshes SP and ranks without destroying the tree")
	host.check(is_instance_valid(sp_digits) and sp_digits == game.modal.find_child("skill_sp_digits",true,false)
		and sp_digits.visible and skill_panel._sp_label.text == str(initial_sp - 20),"buying a rank refreshes the original SP digits in place")
	host.check(host.click_text("退点"),"purchased rank offers a working refund")
	await host.ticks(3)
	host.check(game.session.profile["skills"]["upper"]==1 and Numbers.Skills.available(game.session.profile,Numbers.shared_config())==initial_sp,"refund restores the exact spent SP")
	host.check(host.click_text("加点"),"learning again after refund accepts the next viewport click")
	await host.ticks(3)
	host.check(game.session.profile["skills"]["upper"]==2,"successive learn and refund refresh the current profile")
	host.check(game.debug_panel.commands.execute("skill draw 2")["ok"],"GM can configure skill rank independently of progression")
	game.number_windows.tab=2
	game.show_overlay("numbers")
	host.check(game.debug_panel.commands.execute("gear give training_coat")["ok"],"GM creates individual armor instance")
	await host.ticks(3)
	await host.frame("62_number_equipment")
	var armor_uid := ""
	for uid: String in game.session.profile["gear"]:
		if game.session.profile["gear"][uid]["definition"]=="training_coat":armor_uid=uid
	var defense_before := float(game.session.stats()["numbers"]["physical_defense"])
	host.check(game.debug_panel.commands.execute("gear equip "+armor_uid)["ok"] and is_equal_approx(float(game.session.stats()["numbers"]["physical_defense"]),defense_before+25),"equipped armor changes actual character defense")
	game.show_overlay("")
	game.depart()
	await host.ticks(4)
	host.check(game.combat.is_running(),"numeric profile starts real combat")
	if not game.combat.is_running():return
	var api = RuntimeAPI.new(game.battle)
	api.set_god(true)
	game.number_windows.tab = 1
	skill_panel.tree_scroll = 0
	for index in game.SkillSlots.COUNT:
		var skill := "upper" if index == 2 else "hardattack"
		var label: String = game.SkillSlots.LABELS[index]
		game.show_overlay("numbers")
		await host.ticks(3)
		var source: Control = game.modal.find_child("skill_node_46" if index == 2 else "skill_node_5", true, false)
		var target: Control = game.hud.find_child("hud_skill_slot_%d" % index, true, false)
		var dropped := await drag_skill(source, target, Vector2(26, 26) if index == 2 else Vector2(-1, -1))
		host.check(dropped and game.session.profile["skill_slots"][index] == skill,
			"live %s accepts a viewport skill drop in battle" % label)
		game.show_overlay("")
		api.heal()
		api.set_p("state","idle")
		api.set_p("action","")
		api.set_p("cooldowns",{})
		api.set_p("stuck_ms",0.0)
		host.key(game.SKILL_KEYS[index],true)
		await host.ticks(2)
		host.key(game.SKILL_KEYS[index],false)
		host.check(api.p("action") == skill and game.overlay == "",
			"live %s casts its dropped skill without opening another window" % label)
	game.set_debug_open(true)
	var old: Dictionary = game.combat.read_view()
	host.check(not old["numbers"].is_empty() and float(old["numbers"]["physical_defense"])==float(game.session.stats()["numbers"]["physical_defense"]),"combat consumes full profile including equipment defense")
	host.check(api.move("draw")["hits"][0]["percent"]==1192,"actual combat move uses chosen second skill rank")
	host.check(game.debug_panel.commands.execute("level 5")["ok"],"GM level updates running combat while paused")
	var after: Dictionary = game.combat.read_view()
	host.check(after["hp"]==old["hp"] and after["mp"]==old["mp"] and after["hp_max"]>old["hp_max"],"level change preserves current blood and mana while changing limits")
	host.check(game.debug_panel.commands.execute("buff strength_potion")["ok"],"GM applies effect during paused battle")
	var boosted := float(game.combat.read_view()["numbers"]["strength"])
	await host.ticks(20)
	host.check(float(game.combat.read_view()["numbers"]["strength"])==boosted,"paused simulation does not expire effects")
	host.check(game.debug_panel.commands.execute("unbuff strength_potion")["ok"] and game.combat.read_view()["numbers"]["strength"]==after["numbers"]["strength"],"removing effect restores baseline exactly")
	host.check(game.debug_panel.commands.execute("monster 8")["ok"],"GM changes current and future monster level")
	var enemy: Dictionary = api.monster_handle(0)
	host.check(api.actor_numbers(enemy)["level"]==8 and api.actor_numbers(enemy)["physical_defense"]>0,"monster's actual combat properties update")
	host.check(game.debug_panel.commands.execute("buff stun "+str(enemy["id"]))["ok"],"effect targets selected monster")
	host.check(api.actor_controlled(enemy),"targeted control locks monster AI")
	game.show_overlay("")
	game.set_debug_open(false)
	# Exercise the real collision/attack pipeline with guaranteed contact and no enemy AI.
	enemy = api.spawn_dummy(Vector2(175,250))
	api.set_p("pos",Vector2(125,250))
	api.set_p("facing",1)
	api.set_p("state","idle")
	api.set_p("action","")
	game.combat.submit_key(KEY_X,true)
	game.combat.submit_key(KEY_X,false)
	await host.ticks(25)
	var damage: Dictionary = game.combat.read_view()["last_damage"]
	host.check(not damage.is_empty() and damage.has("trace"),"real attack produces damage trace")
	game.set_debug_open(true)
	host.check(game.debug_panel.commands.execute("stat physical_crit 1")["ok"],"critical stat applies to running battle")
	host.check(game.debug_panel.commands.execute("stats physical_crit")["message"].contains("1"),"GM exposes live computed value")
	host.check(game.debug_panel.commands.execute("damage")["ok"],"GM exposes last damage calculation")
	game.set_debug_open(false)
	api.set_p("state","idle")
	api.set_p("action","")
	api.set_p("stuck_ms",0.0)
	api.set_e(enemy,"state","idle")
	api.set_e(enemy,"pos",Vector2(175,250))
	host.check(api.start_action("attack1"),"numeric critical test starts real attack")
	await host.ticks(25)
	var critical: Dictionary = game.combat.read_view()["last_damage"]
	host.check(critical.get("critical",false) and int(critical["amount"])>int(damage["amount"]),"guaranteed critical changes damage through actual hit pipeline")
	game.set_debug_open(true)
	host.check(game.debug_panel.commands.execute("stat fire_attack 220")["ok"] and game.debug_panel.commands.execute("element fire")["ok"],"elemental strength and attack property can be adjusted independently")
	game.set_debug_open(false)
	api.set_p("state","idle")
	api.set_p("action","")
	api.set_p("stuck_ms",0.0)
	api.set_e(enemy,"state","idle")
	api.set_e(enemy,"pos",Vector2(175,250))
	api.start_action("attack1")
	await host.ticks(25)
	host.check(game.combat.read_view()["last_damage"].get("trace",{}).get("element_factor",0)==2,"real weapon hit receives matching elemental strength")
	game.set_debug_open(true)
	host.check(game.debug_panel.commands.execute("stat attack_speed 1")["ok"],"attack-speed modifier updates current actor")
	game.set_debug_open(false)
	api.set_p("state","idle")
	api.set_p("action","")
	api.set_p("stuck_ms",0.0)
	api.start_action("attack1")
	await host.ticks(3)
	host.check(float(api.p("clock"))>=90,"attack speed advances actual action timeline")
	game.set_debug_open(true)
	host.check(game.debug_panel.commands.execute("buff bleed "+str(enemy["id"]))["ok"],"periodic damage can target real monster")
	api.set_e(enemy,"hp",1.0)
	game.set_debug_open(false)
	api.set_p("state","idle")
	api.set_p("action","")
	await host.ticks(65)
	host.check(float(api.e(enemy,"hp"))==0 and api.e(enemy,"state")=="dead","periodic effect can kill through normal death bookkeeping")
	game.show_overlay("numbers")
	game.number_windows.tab=0
	game.show_overlay("numbers")
	game.set_debug_open(false)
	await host.frame("63_number_battle_attributes")
	await _check_reckless_status()
	game.debug_panel.commands.execute("town")
	host.check(game.session.state=="town","numeric battle can safely return to existing flow")
	var snapshot: Dictionary = game.session.serialize()
	var restored = game.Session.new()
	host.check(restored.restore(JSON.parse_string(JSON.stringify(snapshot))) and restored.profile["skills"]["draw"]==2,"new progression and equipment survive real flow save")

func _check_reckless_status() -> void:
	game.show_overlay("")
	var battle = game.battle
	var was_processing: bool = battle.is_physics_processing()
	battle.set_physics_process(false)
	var actor = battle.numeric_player
	var icon = game.reckless_status
	host.check(not icon.visible, "the status row is empty without the Reckless appendage")
	actor.add_effect("reckless", 1)
	await host.ticks(2)
	host.check(icon.is_visible_in_tree() and icon.position == Vector2(92,528)
		and icon.size == Vector2(23,23) and icon._shade_height == 0,
		"the live HUD draws Reckless at the first original buff slot")
	if host.capture:await host.frame("63b_reckless_hud_start")
	actor.step(20040.0)
	await host.ticks(2)
	host.check(icon._shade_height == 10 and icon._alpha == 255,
		"the original Reckless icon has a 10px top mask at half duration")
	if host.capture:await host.frame("63c_reckless_hud_half")
	actor.step(10540.0)
	await host.ticks(2)
	host.check(icon._shade_height == 15 and icon._alpha == 128,
		"Reckless blinks in the original 500 ms phase")
	actor.step(4900.0)
	await host.ticks(2)
	host.check(icon._shade_height == 17 and icon._alpha == 128,
		"Reckless blinks in the original 200 ms phase")
	actor.step(4100.0)
	await host.ticks(2)
	host.check(icon._shade_height == 19 and icon._alpha == 127,
		"Reckless fades during the last second")
	actor.step(500.0)
	await host.ticks(2)
	host.check(not icon.visible, "the HUD removes the Reckless icon when the timed appendage expires")
	if host.capture:await host.frame("63d_reckless_hud_expired")
	battle.set_physics_process(was_processing)

func _explain_motion(track: Control, y: float, pressed := true) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = track.get_global_transform_with_canvas() * Vector2(8, y)
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	game.get_viewport().push_input(motion, true)

func _explain_pointer(track: Control, y: float, pressed: bool) -> void:
	if pressed:
		_explain_motion(track, y, false)
	var button := InputEventMouseButton.new()
	button.position = track.get_global_transform_with_canvas() * Vector2(8, y)
	button.button_index = MOUSE_BUTTON_LEFT
	button.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	button.pressed = pressed
	game.get_viewport().push_input(button, true)

func drag_skill(source: Control, target: Control, target_at := Vector2(-1, -1)) -> bool:
	var viewport:Viewport=game.get_viewport()
	var start:=source.get_global_transform_with_canvas()*(source.size/2)
	var finish:=target.get_global_transform_with_canvas()*(target_at if target_at.x >= 0 else target.size/2)
	var motion:=InputEventMouseMotion.new()
	motion.position=start
	viewport.push_input(motion,true)
	await host.ticks(2)
	var button:=InputEventMouseButton.new()
	button.position=start
	button.button_index=MOUSE_BUTTON_LEFT
	button.button_mask=MOUSE_BUTTON_MASK_LEFT
	button.pressed=true
	viewport.push_input(button,true)
	await host.ticks(2)
	motion=motion.duplicate()
	motion.position=start+Vector2(22,0)
	motion.relative=Vector2(22,0)
	motion.button_mask=MOUSE_BUTTON_MASK_LEFT
	viewport.push_input(motion,true)
	await host.ticks(2)
	host.check(viewport.gui_is_dragging(),"viewport mouse motion starts the skill drag")
	motion=motion.duplicate()
	motion.position=finish
	motion.relative=finish-start-Vector2(22,0)
	viewport.push_input(motion,true)
	await host.ticks(2)
	button=button.duplicate()
	button.position=finish
	button.button_mask=0
	button.pressed=false
	viewport.push_input(button,true)
	await host.ticks(4)
	host.check(not viewport.gui_is_dragging(),"viewport mouse release completes the skill drag")
	return viewport.gui_is_drag_successful()
