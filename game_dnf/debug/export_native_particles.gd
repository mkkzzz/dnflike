extends SceneTree
## Original PTL + ANI + atlas, isolated display probe. This is not a gameplay
## trigger or a recording of the original client. No source timing is shortened.
const Particle = preload("res://view/native_particle_view.gd")
const Emitter = preload("res://combat/particles/native_emitter.gd")
const Random = preload("res://combat/particles/native_random.gd")

func _initialize() -> void:
	call_deferred("capture")

func capture() -> void:
	if OS.get_environment("DNF_PRIVATE_DESKTOP") != "1" or DisplayServer.get_name()=="headless":
		push_error("Particle capture requires the private desktop renderer")
		quit(1);return
	var args:=OS.get_cmdline_user_args()
	if args.is_empty():quit(2);return
	var output:=args[0]
	DirAccess.make_dir_recursive_absolute(output)
	root.size=Vector2i(800,600)
	root.content_scale_size=Vector2i(800,600)
	root.canvas_item_default_texture_filter=Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	RenderingServer.set_default_clear_color(Color("25323a"))
	var manifest: Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://assets_local/combat/manifest.json"))
	var catalog: Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://assets_local/content/particles.json"))
	var path:="passiveobject/mapobject/breakableobject/particle/actiontreeloriendamage.ptl"
	var by_source: Dictionary={}
	for bank: Dictionary in manifest.effects.values():by_source[bank.source]=bank
	var views: Array=[]
	for mirror in [false,true]:
		var random=Random.new(42)
		var emitter=Emitter.new(catalog.particles[path].decoded,func():return random.next_u31(1000,true),
			Vector3i(220 if not mirror else 580,160,240),mirror)
		var result: Dictionary=emitter.emit_at(0)
		if not result.ok or result.particles.size()!=30:quit(3);return
		for emission: Dictionary in result.particles:
			var view=Particle.new();root.add_child(view)
			if not view.setup_particle(emission,by_source.get(emission.entry.path,{})):
				push_error(str(view.errors));quit(4);return
			views.append(view)
	var samples: Array[int]=[0,70,350,700,750,1000,2000]
	var previous:=0
	var records: Array=[]
	for at in samples:
		var rows: Array=[]
		for view in views:
			if not is_instance_valid(view):continue
			view.advance(at-previous)
			if not view.errors.is_empty():push_error(str(view.errors));quit(5);return
			if view.is_queued_for_deletion():continue
			rows.append({"source":view.data.source,"facing":view.facing,"frame":view.frame.frame,
				"position":[view.position.x,view.position.y],"alpha":view.fade})
		# ANI duration is 700 ms; native loop continues until PTL landing/lifetime.
		if at==750 and (rows.size()!=60 or rows[0].frame!=0):quit(6);return
		if at==2000 and not rows.is_empty():quit(7);return
		for i in 2:await process_frame
		await RenderingServer.frame_post_draw
		if root.get_texture().get_image().save_png(output+"/particles_%04d.png"%at)!=OK:quit(8);return
		records.append({"time_ms":at,"alive":rows.size(),"particles":rows})
		previous=at
	var marker:=FileAccess.open(output+"/capture_complete.json",FileAccess.WRITE)
	if marker==null:quit(9);return
	marker.store_string(JSON.stringify({"frames":samples.size(),"source":path,"samples":records}))
	marker.close()
	print("[PARTICLE_CAPTURE] COMPLETE frames=",samples.size())
	quit()
