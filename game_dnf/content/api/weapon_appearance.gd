extends RefCounted
## Item identity is separate from weapon family (simulation/sound/skill rules).
const PATH := "res://assets_local/weapon_appearance_v2/manifest.json"
const POSE_OVERLAYS := ["res://assets_local/weapon_appearance_v3/manifest.json",
	"res://assets_local/weapon_appearance_v4/manifest.json",
	"res://assets_local/weapon_appearance_v5/manifest.json",
	"res://assets_local/weapon_appearance_v6/manifest.json",
	"res://assets_local/weapon_appearance_v7/manifest.json"]
const PARENT_TIMED_POSES := ["attack1", "attack2", "attack3", "hitback", "upperslashafter",
	"frenzy1", "frenzy2", "frenzy3", "frenzy4",
	"tripleslash1", "tripleslash2", "tripleslash3", "tripleslash4", "tripleslash5", "hardattack", "hardattackchargeafter"]
static var _data: Dictionary = {}
static var _layers: Dictionary = {}

static func data() -> Dictionary:
	if _data.is_empty():
		var manifest_text := FileAccess.get_file_as_string(PATH)
		var value = JSON.parse_string(manifest_text)
		if value is Dictionary and value.get("schema")=="dnf_weapon_appearance/1":
			_data=value
			# Existing Windows clones may still have CRLF from before Git pinned this file.
			var base_sha256 := manifest_text.replace("\r\n", "\n").sha256_text()
			for path: String in POSE_OVERLAYS:_apply_pose_overlay(path,base_sha256)
	return _data

static func _apply_pose_overlay(path: String, base_sha256: String) -> void:
	var overlay = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not overlay is Dictionary or overlay.get("schema")!="dnf_weapon_pose_overlay/1":return
	if overlay.get("base_manifest_sha256")!=base_sha256:return
	if not overlay.get("bindings") is Dictionary or not overlay.get("animations") is Dictionary:return
	var bindings: Dictionary = overlay["bindings"]
	_data["animations"].merge(overlay["animations"],false)
	for appearance: Dictionary in _data["appearances"].values():
		for layer: Dictionary in appearance["layers"]:
			layer["clips"].merge(bindings.get(layer["clips"]["stay"],{}),false)

static func identity(item: String) -> String:
	return String(data().get("legacy_aliases",{}).get(item,item))

static func can_display(item: String) -> bool:
	return not data().is_empty() and (item=="" or data().get("items",{}).has(identity(item)))

static func skin(item: String) -> Dictionary:
	return data().get("appearances",{}).get(data().get("items",{}).get(identity(item),""),{})

static func valid_spec(spec: Dictionary) -> bool:
	if not spec.has("weapon_item"):return true
	if not spec["weapon_item"] is String or not can_display(spec["weapon_item"]):return false
	return spec["weapon_item"]=="" or skin(spec["weapon_item"]).get("family")==spec.get("weapon")

## Original equipment attachment 0x8441C0 copies each overlapping body frame's delay.
## Keep the archive clips intact. Both drawing and collision use the attached clips.
static func layers(item: String, body_clips: Dictionary) -> Array:
	var info := data()
	var key: String = info.get("items", {}).get(identity(item), "")
	if key.is_empty():return []
	if not _layers.has(key):
		var source_layers: Array = []
		for layer: Dictionary in info["appearances"].get(key,{}).get("layers",[]):
			var animations: Dictionary={}
			for pose: String in layer["clips"]:animations[pose]=info["animations"][layer["clips"][pose]]
			source_layers.append({"order":int(layer["order"]),"bank":info["banks"][layer["bank"]],"clips":animations})
		_layers[key] = source_layers
	var result: Array = []
	for source_layer: Dictionary in _layers[key]:
		var layer := source_layer.duplicate()
		var clips: Dictionary = source_layer["clips"].duplicate()
		for pose: String in PARENT_TIMED_POSES:
			if body_clips.has(pose) and clips.has(pose):
				clips[pose] = _with_parent_delays(clips[pose], body_clips[pose])
		layer["clips"] = clips
		result.append(layer)
	return result

static func _with_parent_delays(source: Dictionary, parent: Dictionary) -> Dictionary:
	var frames: Array = source["frames"]
	var parent_frames: Array = parent["frames"]
	var retimed: Array = []
	var duration := int(source["duration_ms"])
	for index: int in mini(frames.size(), parent_frames.size()):
		var delay = parent_frames[index].get("delay_ms")
		var previous = frames[index].get("delay_ms")
		if delay == null or previous == null or delay == previous:continue
		if retimed.is_empty():retimed = frames.duplicate()
		var frame: Dictionary = frames[index].duplicate()
		frame["delay_ms"] = delay
		retimed[index] = frame
		duration += int(delay) - int(previous)
	if retimed.is_empty():return source
	var clip := source.duplicate()
	clip["frames"] = retimed
	clip["duration_ms"] = duration
	return clip

static func apply(actor, item: String, clips: Dictionary) -> bool:
	if not can_display(item):return false
	var info := data()
	actor.setup(info["body"]["base"],clips,{"move":info["body"]["locomotion"],"dash":info["body"]["locomotion"]})
	actor.set_equipment_layers(layers(item, clips))
	actor.set_meta("weapon_item",item)
	actor.set_meta("weapon_appearance",info["items"].get(identity(item),""))
	return true
