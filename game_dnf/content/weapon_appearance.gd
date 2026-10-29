extends RefCounted
## Item identity is separate from weapon family (simulation/sound/skill rules).
const PATH := "res://assets_local/weapon_appearance_v1/manifest.json"
static var _data: Dictionary = {}
static var _layers: Dictionary = {}

static func data() -> Dictionary:
	if _data.is_empty():
		var value=JSON.parse_string(FileAccess.get_file_as_string(PATH))
		if value is Dictionary and value.get("schema")=="dnf_weapon_appearance/1":_data=value
	return _data

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

static func apply(actor, item: String, clips: Dictionary) -> bool:
	if not can_display(item):return false
	var info:=data()
	var key: String=info["items"].get(identity(item),"")
	if not _layers.has(key):
		var layers: Array=[]
		for layer: Dictionary in info["appearances"].get(key,{}).get("layers",[]):
			var animations: Dictionary={}
			for pose: String in layer["clips"]:animations[pose]=info["animations"][layer["clips"][pose]]
			layers.append({"order":int(layer["order"]),"bank":info["banks"][layer["bank"]],"clips":animations})
		_layers[key]=layers
	actor.setup(info["body"]["base"],clips,{"move":info["body"]["locomotion"],"dash":info["body"]["locomotion"]})
	actor.set_equipment_layers(_layers[key])
	actor.set_meta("weapon_item",item)
	actor.set_meta("weapon_appearance",key)
	return true
