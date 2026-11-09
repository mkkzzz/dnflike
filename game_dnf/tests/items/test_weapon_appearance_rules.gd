extends SceneTree
const Appearance=preload("res://content/api/weapon_appearance.gd")
const Actor=preload("res://view/actor_view.gd")
const Session=preload("res://flow/session.gd")
var checks:=0
var failures:=0

func check(value: bool,label: String) -> void:
	checks+=1
	if not value:failures+=1;push_error("[WEAPON_RULES] FAIL "+label)

func _initialize() -> void:call_deferred("run")

func run() -> void:
	var runtime: Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://assets_local/manifest.json"))
	var combat: Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://assets_local/combat/manifest.json"))
	var clips: Dictionary={}
	for key: String in runtime.clips:
		if key.begins_with("player/"):clips[key.trim_prefix("player/")]=runtime.clips[key]
	clips.merge(combat.player_clips,false)
	var actor=Actor.new();root.add_child(actor)
	var s=Session.new();var original_weapons:=0
	var definitions: Dictionary=s.Numbers.config_snapshot().equipment
	for id: String in definitions:
		var definition: Dictionary=definitions[id]
		if not id.begins_with("original_") or definition.slot!="weapon":continue
		original_weapons+=1
		check(Appearance.can_display(id),"all currently registered original weapon items have a native binding: "+id)
		check(Appearance.apply(actor,id,clips) and actor.get_meta("weapon_item")==id,"item identity reaches actor without family-only substitution: "+id)
		check(actor.equipment_layers.size()==2 and actor.equipment_layers[0].show_behind_parent and not actor.equipment_layers[1].show_behind_parent,"original back/body/front order: "+id)
		check(actor.bank.texture.ends_with("body_base.png") and actor.pose_banks.move.texture.ends_with("body_locomotion.png"),"shared body never contains a baked category weapon: "+id)
		var layers := Appearance.layers(id, clips)
		for index: int in layers.size():
			var source_path: String = Appearance.skin(id).layers[index].clips.hitback
			var original: Dictionary = Appearance.data().animations[source_path]
			var attached: Dictionary = layers[index].clips.hitback
			check(int(original.duration_ms)==550 and int(attached.duration_ms)==850,
				"attachment copies HitBack timing without changing the original weapon ANI: "+id)
			check(attached.frames[2].boxes==original.frames[2].boxes and attached.frames[2].pos==original.frames[2].pos,
				"shared collision layer retains the original weapon boxes and anchor: "+id)
			for pose: String in Appearance.PARENT_TIMED_POSES:
				if pose in ["tripleslash4","tripleslash5"] and definition.weapon != "katana":
					check(not layers[index].clips.has(pose),"enhanced katana pose is isolated to its family: "+id+"/"+pose)
					continue
				if pose.begins_with("weaponcomboshort") or pose.begins_with("weaponcomboblade"):
					var family := "shortsword" if pose.begins_with("weaponcomboshort") else "katana"
					if definition.weapon != family:
						check(not layers[index].clips.has(pose),"Weapon Combo attachment stays in its source family: "+id+"/"+pose)
						continue
					if not layers[index].clips.has(pose):
						check(false,"Weapon Combo attachment exists for its source family: "+id+"/"+pose)
						continue
				var body_delays: Array = clips[pose].frames.map(func(frame):return frame.delay_ms)
				var weapon_delays: Array = layers[index].clips[pose].frames.map(func(frame):return frame.delay_ms)
				check(body_delays==weapon_delays,"shared layer uses source body frame delays: "+id+"/"+pose)
		for sample: Array in [[50.0,51],[100.0,52],[400.0,58],[450.0,59]]:
			actor.present("hitback",sample[0],-1,0,0)
			var body_image := int(actor.sample().get("img_frame",-1))
			check(body_image==sample[1] and actor.equipment_layers.all(func(layer):return int(layer.frame.get("img_frame",-1))==body_image),
				"body and both rendered weapon layers share original HitBack boundary: "+id+"/"+str(sample[0]))
		for pose: String in clips:
			actor.present(pose,50,1,30,0.5,Color(0.5,0.8,1,0.6))
			for layer in actor.equipment_layers:
				check(not layer.frame.is_empty() and layer.height==30 and layer.facing==1 and is_equal_approx(layer.tint.a,0.6),"source weapon timeline and actor height/tint follow all existing poses: "+id+"/"+pose)
		for sample: Array in [["throw1",50.0,160],["throw2",0.0,165],["throw2",450.0,173]]:
			actor.present(sample[0],sample[1],1,0,0)
			check(actor.equipment_layers.all(func(layer):return layer.clips.has(sample[0]) and int(layer.frame.get("img_frame",-1))==sample[2]),"ghost cast uses both native weapon layers and their ANI clock: "+id+"/"+String(sample[0]))
		actor.present("attack1",100,-1,0,0)
		check(actor.equipment_layers.all(func(layer):return layer.facing==-1 and layer.height==0),"both weapon layers mirror with the body: "+id)
	check(original_weapons==Appearance.data().items.size(),"coverage is exact for all registered original weapons")
	check(Appearance.skin("original_27601")!=Appearance.skin("original_27800"),"two same-family source swords retain different original model/palette")
	check(Appearance.apply(actor,"",clips) and actor.equipment_layers.is_empty(),"unequipped state uses an unarmed body")
	check(not Appearance.can_display("original_missing") and not Appearance.apply(actor,"original_missing",clips),"missing source identity never silently becomes another weapon")
	check(Appearance.can_display("iron_sword") and Appearance.can_display("forest_sword"),"legacy sample aliases remain explicit and compatible")
	check(s.CATALOG.ITEMS.original_27601.weapon_appearance!=s.CATALOG.ITEMS.original_27800.weapon_appearance,"item catalog exposes separate exact appearance bindings")
	check(not Appearance.valid_spec({"weapon":"shortsword","weapon_item":"original_27601"}) and not Appearance.valid_spec({"weapon":"katana","weapon_item":123}),"public snapshots reject mismatched family and malformed identity")
	var normal=s.Numbers.combat_spec(s.profile)
	check(normal.weapon_item=="iron_sword" and normal.weapon=="katana","public snapshot separates equipment ID from weapon family")
	s.profile.level=10;s.Inventory.give(s.profile,"original_27601",1)
	check(s.command("items.equip",{"id":"original_27601"}).ok and s.Numbers.combat_spec(s.profile).weapon_item=="original_27601","normal equip changes public item identity")
	var copy=Session.new()
	check(copy.restore(JSON.parse_string(JSON.stringify(s.serialize()))) and copy.Numbers.combat_spec(copy.profile).weapon_item=="original_27601","old save format already preserves exact equipped definition")
	actor.queue_free();await process_frame
	print("[WEAPON_RULES] COMPLETE checks=%d failures=%d" % [checks,failures]);quit(1 if failures else 0)
