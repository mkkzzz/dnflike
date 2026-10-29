extends RefCounted
## Trial adaptation; source icons do not imply these are original item stats.
const LEGACY_ITEMS := {
	"scrap_iron": {"name":"铁质碎片", "kind":"material", "rarity":0, "level":1, "weight":0.01, "description":"分解装备获得的基础材料"},
	"training_coat": {"name":"练习布甲", "kind":"weapon", "rarity":0, "level":1, "weight":1.0, "description":"防御与生命加成"},
	"training_necklace": {"name":"练习项链", "kind":"weapon", "rarity":0, "level":1, "weight":0.3, "description":"魔防与法力加成"},
	"iron_sword": {"name": "练习太刀", "kind": "weapon", "rarity": 0, "level": 1, "weight": 1.2, "multiplier": 1.0, "description": "物理伤害 ×1.00"},
	"forest_sword": {"name": "林间太刀", "kind": "weapon", "rarity": 2, "level": 1, "weight": 1.2, "multiplier": 1.2, "description": "物理伤害 ×1.20", "price": 240},
	"potion": {"name": "恢复药剂", "kind": "consumable", "rarity": 1, "level": 1, "weight": 0.01, "heal": 150, "price": 40, "description": "恢复 150 HP；战斗中按 1"},
}
static var ITEMS: Dictionary = load_items()

static func load_items() -> Dictionary:
	var result: Dictionary = LEGACY_ITEMS.duplicate(true)
	var data = JSON.parse_string(FileAccess.get_file_as_string("res://data/runtime_items.json"))
	if data is Dictionary and data.get("schema") == "dnf_runtime_items/1":result.merge(data.get("items",{}),false)
	result.merge(preload("res://content/native_catalog.gd").runtime().get("items",{}),false)
	var appearances=preload("res://content/weapon_appearance.gd")
	var ids: Array=appearances.data().get("items",{}).keys()
	ids.append_array(appearances.data().get("legacy_aliases",{}).keys())
	for id: String in ids:
		if not result.has(id):continue
		var item: Dictionary=result[id].duplicate(true)
		item["weapon_appearance"]=appearances.data()["items"][appearances.identity(id)]
		item["weapon_appearance_manifest"]=appearances.PATH
		# The immutable first migration snapshot keeps its old adaptation note;
		# the current runtime view must describe the now-installed item renderer.
		var adaptations: Array=item.get("adaptations",[]).filter(func(line):return not String(line).begins_with("Weapon appearance uses the existing three"))
		adaptations.append("Original item variation and source front/back ANI layers; legacy aliases are explicitly adapted")
		item["adaptations"]=adaptations
		result[id]=item
	return result

static func stack_limit(id: String) -> int:
	return maxi(1,int(ITEMS.get(id,{}).get("stack_limit",99)))
## Rarity is separate from an equipment roll's lower/upper quality grade.
## Trial swords retain adapted rarity; potion rarity=1 is in its source STK.
const RARITIES := {
	0: {"name": "普通", "color": "eeeeee"},
	1: {"name": "高级", "color": "6ba8ff"},
	2: {"name": "稀有", "color": "bb8dff"},
	3: {"name": "神器", "color": "ff85c8"},
	4: {"name": "史诗", "color": "ffb544"},
	5: {"name": "勇者", "color": "ff6666"},
}
