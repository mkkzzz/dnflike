extends RefCounted
## Trial adaptation; source icons do not imply these are original item stats.
const ITEMS := {
	"training_coat": {"name":"练习布甲", "kind":"weapon", "rarity":0, "level":1, "weight":1.0, "description":"防御与生命加成"},
	"training_necklace": {"name":"练习项链", "kind":"weapon", "rarity":0, "level":1, "weight":0.3, "description":"魔防与法力加成"},
	"iron_sword": {"name": "练习太刀", "kind": "weapon", "rarity": 0, "level": 1, "weight": 1.2, "multiplier": 1.0, "description": "物理伤害 ×1.00"},
	"forest_sword": {"name": "林间太刀", "kind": "weapon", "rarity": 2, "level": 1, "weight": 1.2, "multiplier": 1.2, "description": "物理伤害 ×1.20", "price": 240},
	"potion": {"name": "恢复药剂", "kind": "consumable", "rarity": 1, "level": 1, "weight": 0.01, "heal": 150, "price": 40, "description": "恢复 150 HP；战斗中按 1"},
}
## Rarity is separate from an equipment roll's lower/upper quality grade.
## Trial swords retain adapted rarity; potion rarity=1 is in its source STK.
const RARITIES := {
	0: {"name": "普通", "color": "eeeeee"},
	1: {"name": "高级", "color": "6ba8ff"},
	2: {"name": "稀有", "color": "bb8dff"},
	3: {"name": "神器", "color": "ff85c8"},
	4: {"name": "史诗", "color": "ffb544"},
}
