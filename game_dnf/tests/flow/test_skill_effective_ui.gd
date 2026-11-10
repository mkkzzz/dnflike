extends SceneTree
## Disposable real UI and combat fixtures; never writes a user save.
const Loop = preload("res://flow/loop_root.gd")
const Numbers = preload("res://stats/api/numbers.gd")
var game
var checks := 0
var failures := 0
func _initialize() -> void:call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		print("[SKILL_UI_RANKS] FAIL ",message)
func grant(id: String, rank: int) -> void:
	check(game.session.command("numbers.skill_grant",{"id":id,"level":rank})["ok"],"fixture grant "+id)
func texts(node: Node) -> String:
	var result := ""
	for label in node.find_children("*","Label",true,false):result += label.text+"\n"
	return result
func run() -> void:
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
	game.session.command("numbers.level",{"level":60})
	game.number_windows.tab = 1
	var panel = game.number_windows.skill_panel
	var battle = load("res://scenes/main.tscn").instantiate()
	battle.external_mode = true
	battle._muted = true
	root.add_child(battle)
	battle.set_process(false)
	battle.set_physics_process(false)
	battle.restart()
	var cfg := Numbers.shared_config()
	for job: String in ["soulbringer","weaponmaster"]:
		check(game.session.command("numbers.growtype",{"growtype":job,"force":true})["ok"],"registered UI job")
		var passive := "ghostpowerup" if job=="soulbringer" else "weapon_mastery_up"
		var targets := ["hardattack","khazan","saya","bremen","keiga","epidemicrasa","kalla"] if job=="soulbringer" else ["shortswordmastery","blademastery","heavyswordmastery","bluntmastery","lightswordmastery"]
		for mode: String in ["learned","zero","near_ceiling","ceiling","disabled"]:
			grant(passive,0 if mode=="disabled" else 1)
			for id: String in targets:
				var maximum := int(cfg["skills"][id]["max_level"])
				var base := int(cfg["skill_defaults"].get(id,0)) if mode=="zero" else maximum-1 if mode=="near_ceiling" else maximum if mode=="ceiling" else 1
				grant(id,base)
			game.show_overlay("numbers")
			await process_frame
			var before := JSON.stringify(game.session.profile)
			check(battle.update_numbers(game.session.stats()),"actual combat update")
			for id: String in targets:
				var base := int(game.session.profile["skills"][id])
				var maximum := int(cfg["skills"][id]["max_level"])
				var delta := 1 if job=="soulbringer" else 2 if id=="lightswordmastery" else 3
				var expected := base+delta if mode!="disabled" and base>0 and base<maximum else base
				var key := id
				panel.select_skill(key)
				var node: Dictionary = panel._node_views.get(key,{})
				check(not node.is_empty() and node["rank"].text==str(expected),mode+" "+id+" tree effective rank")
				var detail: Control = game.modal.find_child("skill_detail",true,false)
				var title: Label = detail.get_node("skill_detail_title")
				var title_rank: Label = detail.get_node("skill_detail_title_rank")
				var expected_color := Color("8cff71") if panel.by_key[key]["type"] == "[passive]" else Color("f7d65a")
				check(title.get_theme_color("font_color") == expected_color, mode+" "+id+" title uses the original type color")
				check(title_rank.text == " Lv%d" % expected and title_rank.get_theme_color("font_color") == (Color("41ff4e") if expected > base else expected_color),
					mode+" "+id+" title shows effective level in its original color")
				check(texts(detail).contains("等级  %d / %d" % [expected,maximum]),mode+" "+id+" detail effective rank")
				check(texts(detail).contains("已学等级  %d" % base),mode+" "+id+" learned rank remains separate")
				check(int(battle.skill_levels[id])==expected,mode+" "+id+" matches actual combat rank")
				var move: Dictionary = battle.table.moves.get(id,{})
				if not move.is_empty():
					var body: RichTextLabel = detail.get_node("skill_detail_body")
					var cooldown: int = battle.table.weapon_cooldown_ms(move,int(move.get("cool_ms",0)))
					var expected_meta := "MP：%d    冷却：%.1f秒" % [int(battle.skill_mp_cost(move)),cooldown/1000.0]
					check(body.text.contains(expected_meta),mode+" "+id+" detail resources match combat")
					var hits: Array = move.get("hits",[])
					if id in ["khazan", "bremen", "epidemicrasa"]:
						check(not body.text.contains("攻击力："),mode+" "+id+" non-attacking object has no direct damage line")
					elif not hits.is_empty():
						check(body.text.contains("攻击力：%d%%" % int(hits[0].get("percent",100))),mode+" "+id+" detail attack matches combat")
				if game.SkillDescriptions.SKILLS.has(id):
					game.windows.skill_tip(id,Rect2(20,20,28,28),true)
					check(texts(game.windows.tip).contains("技能等级 %d" % expected),mode+" "+id+" shortcut rank")
			check(JSON.stringify(game.session.profile)==before,"display leaves purchases and SP unchanged")
	# Refresh an existing tree after removing a passive; keep scroll and controls.
	check(game.session.command("numbers.growtype",{"growtype":"soulbringer","force":true})["ok"],"registered refund UI job")
	grant("ghostpowerup",1)
	grant("hardattack",1)
	panel.selected = "hardattack"
	game.show_overlay("numbers")
	var retained: Control = game.modal.find_child("skill_tree_content",true,false)
	var sp := Numbers.Skills.available(game.session.profile,cfg)
	check(game.session.command("numbers.skill",{"id":"ghostpowerup","delta":-1})["ok"],"refund actual passive")
	panel._refresh_progress()
	check(panel._node_views["hardattack"]["rank"].text=="1","passive refund refreshes target rank")
	check(retained==game.modal.find_child("skill_tree_content",true,false),"passive refund preserves tree")
	check(Numbers.Skills.available(game.session.profile,cfg)==sp,"free granted passive refunds zero SP")
	# A preview must carry all linked skills and reset job/weapon context on reuse.
	for job: String in ["asura","weaponmaster","swordman","soulbringer"]:
		check(game.session.command("numbers.growtype",{"growtype":job,"force":true})["ok"],"registered UI job")
		grant("normalwave",3)
		check(battle.update_numbers(game.session.stats()),"variant combat update")
		var values: Dictionary = game.skill_catalog.get_profile_skill("normalwave",game.session.profile)
		var expected: Dictionary = battle.table.moves["normalwave"]
		check(game.skill_catalog.table.skill_levels==battle.table.skill_levels,"preview includes entire effective skill context")
		check(game.skill_catalog.table.job==battle.table.job and game.skill_catalog.table.weapon==battle.table.weapon,"preview job and weapon agree with combat")
		var cooldown: int = battle.table.weapon_cooldown_ms(expected,int(expected.get("cool_ms",0)))
		check(values["mp"]==battle.skill_mp_cost(expected) and values["cooldown"]==cooldown/1000.0,"variant resource values agree with combat")
		var preview_move: Dictionary = game.skill_catalog.table.moves["normalwave"]
		game.skill_catalog.get_profile_skill("guard",game.session.profile)
		check(is_same(preview_move, game.skill_catalog.table.moves["normalwave"]), "selecting another skill in the same context reuses compiled preview moves")
	check(game.session.command("numbers.growtype",{"growtype":"asura","force":true})["ok"], "registered fixed-damage preview job")
	for id: String in ["icewave", "firewave"]:
		grant(id,1)
		panel.selected = id
		game.show_overlay("numbers")
		await process_frame
		var body: RichTextLabel = game.modal.find_child("skill_detail_body",true,false)
		var expected_fixed := [251] if id == "icewave" else [584,1170]
		for amount: int in expected_fixed:
			check(body.text.contains("魔法攻击力：固定 %d" % amount), id + " detail shows each original fixed component")
		check(not body.text.contains("攻击力：0%"), id + " detail suppresses the zero percentage")
		game.windows.skill_tip(id,Rect2(20,20,28,28),true)
		check(texts(game.windows.tip).contains("魔法攻击力：固定 %d" % expected_fixed[0]), id + " shortcut shows fixed rather than percentage damage")
	grant("guard",4)
	game.windows.skill_tip("guard",Rect2(20,20,28,28),true)
	var guard_tip := texts(game.windows.tip)
	check(guard_tip.contains("物理 30%") and guard_tip.contains("魔法 70%"), "guard tip shows the two source damage categories")
	check(not guard_tip.contains("攻击力："), "defensive guard does not advertise its unused attack adapter")
	game.windows.hide_tooltip()
	battle.queue_free()
	game.ui.free()
	game.ui_audio.free()
	game.town.free()
	game.free()
	await process_frame
	print("[SKILL_UI_RANKS] COMPLETE checks=%d failures=%d" % [checks,failures])
	quit(1 if failures else 0)
