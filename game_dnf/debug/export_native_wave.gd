extends SceneTree
## Real framebuffer capture on the user's required private desktop.
## This is our implementation, never a claim to have recorded the original client.
func _initialize() -> void:
	call_deferred("capture")

func capture() -> void:
	if OS.get_environment("DNF_PRIVATE_DESKTOP") != "1" or DisplayServer.get_name()=="headless":
		push_error("Native-wave capture requires the private desktop renderer")
		quit(1)
		return
	var args:=OS.get_cmdline_user_args()
	if args.is_empty():quit(2);return
	var output:=args[0]
	var skill:=args[1] if args.size()>1 else "normalwave"
	if skill not in ["normalwave","icewave","firewave"]:quit(7);return
	var samples: Array = [0.0,49.0,50.0,100.0,150.0,250.0,300.0,449.0,450.0]
	if skill=="icewave":samples=[150.0,300.0,350.0,500.0,600.0,800.0,1000.0,1200.0,1380.0]
	if skill=="firewave":samples=[0.0,249.0,250.0,300.0,399.0,400.0,450.0,749.0,750.0]
	DirAccess.make_dir_recursive_absolute(output)
	root.size=Vector2i(800,600)
	root.content_scale_size=Vector2i(800,600)
	var game=load("res://scenes/main.tscn").instantiate()
	game.external_mode=true
	game._muted=true
	root.add_child(game)
	if game.missing_assets:quit(5);return
	game.set_process(false)
	game.set_physics_process(false)
	for facing in [1,-1]:
		game.restart()
		game.player["pos"]=Vector2(350,300) if skill=="icewave" else Vector2(350,250)
		game.player["mp"]=500.0
		game.player["facing"]=facing
		game.view.set_equipped_weapon("original_27601")
		if not game.start_action(skill):quit(3);return
		var previous:=0.0
		for at in samples:
			var remaining: float = at-previous
			while remaining>0.0:
				# Never skip child-generation ticks between distant image samples.
				var delta := minf(1.0,remaining)
				game.step_objects(delta)
				if String(game.player["action"])!="":game.step_action(delta,Vector2.ZERO)
				game.view.present(game.view_snapshot(),delta,delta)
				remaining -= delta
			var snapshot: Dictionary = game.view_snapshot()
			print("[WAVE_STATE] ",facing," ",at," ",JSON.stringify(snapshot["objects"]))
			if skill=="icewave":
				var expected := 0
				for ordinal in 8:
					var birth := 300.0+ordinal*100.0
					if at>=birth and at<birth+380.0:expected += 1
				if (snapshot["objects"] as Array).size()!=expected:
					push_error("Ice capture object lifecycle mismatch at "+str(at))
					quit(8)
					return
			game.view.present(snapshot,0.0,0.0)
			for i in 2:await process_frame
			await RenderingServer.frame_post_draw
			var file:=output+"/wave_%s_%03d.png" % ["right" if facing==1 else "left",int(at)]
			if root.get_texture().get_image().save_png(file)!=OK:quit(4);return
			previous=at
	var marker:=FileAccess.open(output+"/capture_complete.json",FileAccess.WRITE)
	if marker==null:quit(6);return
	marker.store_string(JSON.stringify({"frames":18}))
	marker.close()
	print("[WAVE_CAPTURE] COMPLETE frames=18")
	quit()
