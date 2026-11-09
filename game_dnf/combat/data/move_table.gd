extends RefCounted
## Runtime combat tables (doc 29, F3~F5). Joins three sources and keeps their roles apart:
##   content pack (ContentDB.record/original) — original ANI/ATK/SKL/CHR/MOB/OBJ/PTL values;
##   data/combat.json (adapt layer)          — which original file each trial move links to,
##                                             unit scales and missing base tables;
##   assets_local/combat/manifest.json        — baked banks for presentation and borrowed ANIs.
const Timeline = preload("res://combat/action/timeline.gd")
const Numbers = preload("res://stats/api/numbers.gd")
const WeaponAppearance = preload("res://content/api/weapon_appearance.gd")
const SKILL_RUNTIME := "res://data/skill_runtime.json"
const SWORDMAN_WEAPON_POSES := {"attack1":"attack1","attack2":"attack2","attack3":"attack3",
	"upper":"hitback","upper_followup":"upperslashafter",
	"hardattack":"hardattack",
	"frenzy1":"frenzy1","frenzy2":"frenzy2","frenzy3":"frenzy3","frenzy4":"frenzy4",
	"tripleslash1":"tripleslash1","tripleslash2":"tripleslash2","tripleslash3":"tripleslash3",
	"tripleslash4":"tripleslash4","tripleslash5":"tripleslash5",
	"weaponcomboshort1":"weaponcomboshort1","weaponcomboshort2":"weaponcomboshort2","weaponcomboshort3":"weaponcomboshort3",
	"weaponcomboblade1":"weaponcomboblade1","weaponcomboblade2":"weaponcomboblade2","weaponcomboblade3":"weaponcomboblade3","weaponcomboblade4":"weaponcomboblade4"}
const SHORT_MASTERY_SKL := "skill/swordman/shortswordmastery.skl"
const BLADE_MASTERY_SKL := "skill/swordman/blademastery.skl"
const HEAVY_MASTERY_SKL := "skill/swordman/heavyswordmastery.skl"
const NORMAL_ATTACK_CHAIN := ["attack1","attack2","attack3"]
# CA5474 and CA548A append the two native normal-attack cancel frames.
const NORMAL_CONTINUE_FRAMES := [5,4]
const SHORT_MASTERY_ANI := "character/swordman/effect/animation/shortswordmastery/shortweapon"
const SHORT_MASTERY_MOVES := {"attack1":"combo1","attack2":"combo2","attack3":"combo3",
	"upper":"upperslash","upper_followup":"upperslashafter",
	"weaponcomboshort1":"combo1","weaponcomboshort2":"combo2","weaponcomboshort3":"combo3"}
# swordman.sd [upper slash start frame], consumed at CBF0C8.
const UPPER_FOLLOWUP_FRAME := 3
# CB9EF6 compares the current body frame against the stage table at 16EB9D8.
const TRIPLE_CONTINUE_FRAME := 3
## D2FC90 factory cases: Goblin/Thrower use CNMonster's +788 and
## +58C. These Haze IDs all dispatch to the generic CNAIMonster constructor.
const NATIVE_TARGET_IDS := {
	"legacy":["1","2","265","266","602","603"],
	"ai":["56032","59016","59017","61243","61244","61245","61247","61263","61267","61269","63007"],
}
var skill_levels: Dictionary = {}
var job := "weaponmaster"
var weapon := "katana"

const CHR_ANI := "character/swordman/animation/"
const HARDATTACK_WAVE_OBJ := "passiveobject/character/swordman/hardattackchargeafter.obj"
const HARDATTACK_WAVE_PTL := "passiveobject/character/swordman/particle/hardattackchargemove.ptl"

var db
var rules: Dictionary
var assets: Dictionary
var moves: Dictionary = {}
var move_specs: Dictionary = {}
var skill_runtime: Dictionary = {}
var monsters: Dictionary = {}
var objects: Dictionary = {}
var player: Dictionary = {}
var problems: Array = []
var _timelines: Dictionary = {}
var _native_target_classes: Dictionary = {}
var _swordman_weapon_item := ""
var _swordman_weapon_family := ""
var _swordman_weapon_hits: Dictionary = {}
var _swordman_mastery_hits: Dictionary = {}
## 原版 HP 基准表（monster/monsterbaseparameter.tbl，每 5 级一档）。
var base_table: Array = []
## 原版选招规则（由 .ai 反编译提取）：按怪物名精确索引 + 按族目录索引。
## 原版 AI 是**族共享**的（monster/goblin/ai/ 覆盖全族），所以族索引是主用的一层。
var boss_rules: Dictionary = {}
var rules_by_family: Dictionary = {}
## 原版召唤表（.act 的 [SUMMON MONSTER]），按动作 ANI 路径索引；含 BOSS 死亡变身。
var summons_by_ani: Dictionary = {}

func build(content_db, adapt_rules: Dictionary, combat_assets: Dictionary) -> bool:
	db = content_db
	rules = adapt_rules
	assets = combat_assets
	if FileAccess.file_exists(SKILL_RUNTIME):
		skill_runtime = JSON.parse_string(FileAccess.get_file_as_string(SKILL_RUNTIME))
	else:
		skill_runtime = {}
	if not db.has_pack():
		problems.append("compiled content pack missing (python tools/compile_dnf_content.py)")
		return false
	_build_player()
	_load_base_table()
	move_specs = Dictionary(rules["moves"]).duplicate(true)
	for name: String in skill_runtime.get("moves", {}):
		if not move_specs.has(name):
			move_specs[name] = skill_runtime["moves"][name]
	for name: String in move_specs:
		if "__variant_" in name:
			continue
		moves[name] = _build_move(name, _selected_move_spec(name))
	_native_target_classes.clear()
	var source_ids: Dictionary = db.index("monsters_goblin")
	for target_class: String in NATIVE_TARGET_IDS:
		for id: String in NATIVE_TARGET_IDS[target_class]:
			if source_ids.has(id):_native_target_classes[source_ids[id]] = target_class
	for key: String in rules["monsters"]:monsters[key] = _build_monster(key,rules["monsters"][key])
	return problems.is_empty()

## 读 data/monster_tables.json 的 base 表（由 tools/build_dnf_monster_tables.py 生成）。
func _load_base_table() -> void:
	if not FileAccess.file_exists("res://data/monster_tables.json"):return
	var doc = JSON.parse_string(FileAccess.get_file_as_string("res://data/monster_tables.json"))
	if not doc is Dictionary:return
	var tables: Dictionary = doc.get("tables", {})
	var base: Dictionary = tables.get("base", {})
	if not bool(base.get("ok", false)):return
	base_table = base.get("table", [])
	# 同一份数据里也有 BOSS 选招规则（由 .ai 反编译提取）。
	if FileAccess.file_exists("res://data/boss_rules.json"):
		var rules_doc = JSON.parse_string(FileAccess.get_file_as_string("res://data/boss_rules.json"))
		if rules_doc is Dictionary:
			boss_rules = rules_doc.get("index", {})
			rules_by_family = rules_doc.get("by_family", {})
	if FileAccess.file_exists("res://data/summons.json"):
		var summon_doc = JSON.parse_string(FileAccess.get_file_as_string("res://data/summons.json"))
		if summon_doc is Dictionary:summons_by_ani = summon_doc.get("by_ani", {})

## HP 基准按怪物等级取原版表值；表缺失时退回 data/combat.json 的旧基准。
func monster_base_hp(mob: Dictionary) -> float:
	var fallback := float(rules["monster_base"]["hp"])
	if base_table.is_empty():return fallback
	var levels: Array = mob.get("level", []) if mob.get("level") is Array else []
	var level := int(levels[0]) if not levels.is_empty() else 1
	var picked := fallback
	for row: Dictionary in base_table:
		if int(row.get("from_level", 0)) <= level:
			picked = float(row.get("base_value", picked))
		else:
			break
	return picked

## Timeline of any original ANI by archive path (pack first, then borrowed raw ANIs).
func timeline(path: String) -> Array:
	path = path.to_lower()
	if _timelines.has(path):return _timelines[path]
	var tl: Array = []
	var rec: Dictionary = db.record(path)
	if not rec.is_empty():tl = rec["decoded"]["timeline"]
	elif assets.get("borrowed",{}).has(path):tl = Timeline.from_ani(assets["borrowed"][path])
	else:problems.append("ANI not found: "+path)
	_timelines[path] = tl
	return tl

func player_timeline(ani: String) -> Array:
	return timeline(CHR_ANI+ani+".ani")

func atk(path: String) -> Dictionary:
	if path == "":return {}
	var rec: Dictionary = db.record(path)
	if rec.is_empty():
		problems.append("ATK not found: "+path)
		return {}
	return rec["decoded"]

## First enum value of an ATK field, e.g. enum(atk,"damage_reaction") -> "[down]".
static func enum_value(decoded: Dictionary, key: String, fallback := "") -> String:
	var v = decoded.get(key)
	if v is Array and not v.is_empty() and v[0] is Dictionary:return String(v[0]["value"])
	return fallback

static func enum_args(decoded: Dictionary, key: String, index: int) -> Array:
	var v = decoded.get(key)
	if v is Array and v.size() > index and v[index] is Dictionary:return v[index]["args"]
	return []

func move_px(units: float) -> float:
	return units*float(rules["player"]["walk_speed"])/float(rules["units"]["move_speed_reference"])

func _build_player() -> void:
	var chr: Dictionary = db.record(String(rules["player"]["chr"])).get("decoded",{})
	var base: Dictionary = chr.get("stat_groups",{}).get("initial_value",{})
	player = {"hp_max":float(base.get("hp_max",0)),"mp_max":float(base.get("mp_max",0)),
		"jump_power":float(base.get("jump_power",0)),"hit_recovery":float(base.get("hit_recovery",500)),
		"weight":float(base.get("weight",68000)),
		"move_speed":float(base.get("move_speed",850)),"weapon_wav":chr.get("weapon_wav",[]),
		"weapon_hit_info":chr.get("weapon_hit_info",[]),"width":chr.get("width",[0,0]),
		"motions":{"damage1":"damage1","damage2":"damage2","down":"down","overturn":"overturn"}}
	if player["hp_max"] <= 0:problems.append("CHR initial HP missing")

## Weapon row of CHR [weapon hit info]: [kind, blood, size, scale, x, y] per weapon subtype.
func weapon_hit_info(weapon: String) -> Array:
	var index := int(rules["player"]["weapon_index"].get(weapon,0))
	var flat: Array = player["weapon_hit_info"]
	if flat.size() < (index+1)*6:return ["[cut]","[blood]",100,1.0]
	return flat.slice(index*6,index*6+6)

## Weapon row of CHR [weapon wav]: [swing A, swing B, hit A, hit B].
func weapon_wav(weapon: String) -> Array:
	var index := int(rules["player"]["weapon_index"].get(weapon,0))
	var rows: Array = player["weapon_wav"]
	return rows[index] if index < rows.size() else []

func _skill_row(path: String) -> Dictionary:
	var rec: Dictionary = db.record(path)
	if rec.is_empty():
		problems.append("SKL not found: "+path)
		return {}
	var d: Dictionary = rec["decoded"]
	if not skill_levels.is_empty():
		var cfg := Numbers.shared_config()
		for id: String in cfg["skills"]:
			if cfg["skills"][id].get("path","") == path:return Numbers.Skills.sample(d,int(skill_levels.get(id,1)))
	var dungeon: Dictionary = d.get("dungeon",{})
	var pick = func(key: String):return dungeon.get(key,d.get(key,[]))
	var info: Array = pick.call("level_info")
	var cols := int(info[0]) if not info.is_empty() else 0
	var mp: Array = pick.call("consume_mp")
	var cool: Array = pick.call("cool_time")
	var cast: Array = pick.call("casting_time")
	var static_data: Array = pick.call("static_data")
	# Level 1 = first column group and the first value of each [min, max] pair (E-INFER).
	return {"mp":float(mp[0]) if not mp.is_empty() else 0.0,"cool_ms":float(cool[0]) if not cool.is_empty() else 0.0,
		"cast_ms":float(cast[0]) if not cast.is_empty() else 0.0,"level_row":info.slice(1,1+cols) if cols > 0 else [],
		"static":static_data}

## 81A6B0 tests the current body ANI first, then the attached weapon ANIs.
func bind_swordman_weapon(item: String, body_clips: Dictionary) -> bool:
	if item == _swordman_weapon_item:return false
	_swordman_weapon_item = item
	_swordman_weapon_family = String(WeaponAppearance.skin(item).get("family",""))
	_swordman_weapon_hits.clear()
	_swordman_mastery_hits.clear()
	var layers := WeaponAppearance.layers(item,body_clips)
	if layers.is_empty():return true
	for move: String in SWORDMAN_WEAPON_POSES:
		if move == "upper_followup" and _swordman_weapon_family != "shortsword":continue
		var pose: String = SWORDMAN_WEAPON_POSES[move]
		var body := player_timeline(pose)
		var children: Array = []
		for layer: Dictionary in layers:
			children.append(Timeline.from_ani(layer["clips"].get(pose,{})))
		_swordman_weapon_hits[move] = Timeline.attached_attack_segments(body,children)
		if _swordman_weapon_family == "shortsword" and SHORT_MASTERY_MOVES.has(move):
			# 108CE20 appends the extra boxes to the body before checking equipment.
			children.push_front(timeline(SHORT_MASTERY_ANI+String(SHORT_MASTERY_MOVES[move])+".ani"))
			_swordman_mastery_hits[move] = Timeline.attached_attack_segments(body,children)
	return true

func _swordman_hits(name: String) -> Array:
	if weapon != _swordman_weapon_family or not _swordman_weapon_hits.has(name):return []
	if _uses_short_mastery_boxes(name):return _swordman_mastery_hits[name]
	return _swordman_weapon_hits[name]

func _uses_short_mastery_boxes(name: String) -> bool:
	var rank := int(skill_levels.get("shortswordmastery",0))
	if job != "weaponmaster" or rank <= 0 or not _swordman_mastery_hits.has(name):return false
	var mastery: Array = _skill_row(SHORT_MASTERY_SKL).get("static",[])
	return mastery.size() > 12 and rank >= int(mastery[12])

func configure_skills(levels: Dictionary, active_job := "", active_weapon := "") -> void:
	skill_levels = levels.duplicate(true)
	if active_job != "":job = active_job
	if active_weapon != "":weapon = active_weapon
	for name: String in move_specs:
		if "__variant_" in name:
			continue
		moves[name] = _build_move(name, _selected_move_spec(name))

## The companion samples its own AIC ranks against the same source moves. Share
## immutable content and caches without changing the player's active context.
func companion_moves(levels: Dictionary, active_weapon: String) -> Dictionary:
	var context = get_script().new()
	context.db = db
	context.rules = rules
	context.assets = assets
	context.skill_runtime = skill_runtime
	context.move_specs = move_specs
	context.objects = objects
	context._timelines = _timelines
	context.skill_levels = levels
	context.job = "asura"
	context.weapon = active_weapon
	var result := {}
	for name: String in levels:
		if move_specs.has(name):result[name] = context._build_move(name,context._selected_move_spec(name))
	return result

func _selected_move_spec(name: String) -> Dictionary:
	var base: Dictionary = Dictionary(move_specs.get(name, {})).duplicate(true)
	var generated: Dictionary = skill_runtime.get("moves", {}).get(name, {})
	for field: String in ["hp_cost_row", "material_cost", "requires_effect", "super_armor", "invuln_ms", "effect_id", "cast_fx", "aura_fx"]:
		if generated.has(field):
			base[field] = generated[field]
	if name == "triple":
		_apply_triple_blade_mastery(base)
		return base
	if name == "hardattack":return base
	var options: Array = skill_runtime.get("variants", {}).get(name, [])
	options = options.duplicate(true)
	options.sort_custom(func(a, b): return int(a.get("priority", 0)) > int(b.get("priority", 0)))
	for option: Dictionary in options:
		var wanted_job := String(option.get("job", ""))
		if wanted_job != "" and wanted_job != job:
			continue
		var wanted_weapons: Array = option.get("weapon", [])
		if not wanted_weapons.is_empty() and weapon not in wanted_weapons:
			continue
		var requirements: Dictionary = option.get("skill", {})
		var mode := String(option.get("skill_mode", "all"))
		var matched := mode == "any" and requirements.is_empty()
		var all_matched := true
		for skill_id: String in requirements:
			var has_rank := int(skill_levels.get(skill_id, 0)) >= int(requirements[skill_id])
			matched = matched or has_rank
			all_matched = all_matched and has_rank
		if mode == "any" and not requirements.is_empty() and not matched:
			continue
		if mode != "any" and not all_matched:
			continue
		var variant_id := String(option.get("move", ""))
		if variant_id != "" and move_specs.has(variant_id):
			var result: Dictionary = Dictionary(move_specs[variant_id]).duplicate(true)
			result["name"] = base.get("name", result.get("name", name))
			return result
	return base

func _apply_triple_blade_mastery(spec: Dictionary) -> void:
	# CC780F checks Oath, weapon subtype 1, then Blade Mastery against static column 0.
	var rank := int(skill_levels.get("blademastery",0))
	if weapon != "katana" or rank <= 0 or int(skill_levels.get("weapon_mastery_up",0)) <= 0:return
	if _swordman_hits("tripleslash4").is_empty() or _swordman_hits("tripleslash5").is_empty():return
	var mastery := _skill_row(BLADE_MASTERY_SKL)
	var thresholds: Array = mastery["static"]
	var row: Array = mastery["level_row"]
	if thresholds.is_empty() or rank < int(thresholds[0]) or row.size() <= 2:return
	var third: Dictionary = spec["stages"][2]
	third["atk"] = "character/swordman/attackinfo/tripleslash3.atk"
	# CC7AD1/CC7B78 pair the percentage column with the fixed column three later.
	third["hits"][0]["percent_col"] = 0
	third["hits"][0]["fixed_col"] = 3
	third["voice"] = "triple1"
	var extra: Array = spec["blade_mastery_stages"]
	# CC7BBB writes the mastery level row's column 2 to the last attack's lift.
	extra[-1]["hits"][0]["lift"] = float(row[2])
	spec["stages"].append_array(extra)

func _build_move(name: String, spec: Dictionary) -> Dictionary:
	var skill: Dictionary = _skill_row(String(spec["skill"])) if spec.has("skill") else {}
	var move := {"name":name,"label":String(spec.get("name","")),"mp":float(skill.get("mp",0)),
		"cool_ms":float(skill.get("cool_ms",0)),"cast_ms":float(skill.get("cast_ms",0)),"skill":String(spec.get("skill","")),
		"air":bool(spec.get("air",false)),"next":String(spec.get("next","")),"swing":int(spec.get("swing",-1)),
		"cast_fx":String(spec.get("cast_fx","")),"aura_fx":String(spec.get("aura_fx","")),
		"effect_id":String(spec.get("effect_id","")),"requires_effect":String(spec.get("requires_effect","")),
		"movement":String(spec.get("movement","")),
		"super_armor":bool(spec.get("super_armor",false)),"invuln_ms":float(spec.get("invuln_ms",0))}
	if spec.get("form_normal",false):
		# State 8 reads the active skill's level row without using the skill again.
		move.merge({"mp":0.0,"cool_ms":0.0,"cast_ms":0.0},true)
	if name == "buff":
		if spec.has("hp_cost_row"):move["hp_cost_row"] = spec["hp_cost_row"]
		var frenzy_static: Array = skill.get("static",[])
		move["frenzy_recovery_ms"] = int(frenzy_static[0])
		move["release_fx"] = String(spec["release_fx"])
		if frenzy_static.size()>1:move["frenzy_disable_after_ms"] = int(frenzy_static[1])
	if name == "guard":
		# CC615E stores the initial phase's release threshold from static column 0.
		var guard_static: Array = skill.get("static",[])
		move["guard_min_hold_ms"] = float(guard_static[0]) if not guard_static.is_empty() else 0.0
	if name == "hardattack" and job == "soulbringer" and int(skill_levels.get("hardattackcharge",0)) > 0:
		var charge := _skill_row("skill/swordman/hardattackcharge.skl")
		var values: Array = charge["static"]
		# CC6391 sets the charge threshold. CC6798 reads the rank's maximum bonus.
		var followup := _build_stage({"ani":"hardattackchargeafter",
			"fx":[{"key":"hardattack_dash_down","at":0.0,"action_clock":true},
				{"key":"hardattack_dash_up","at":0.0,"action_clock":true}]},skill)
		# CC688E / CC689E install this motion on the X axis. The pose has no attack boxes.
		followup["slide"] = {"speed":float(values[2]),"accel":float(values[3])}
		followup["swing"] = -1
		followup["waves"] = _hardattack_waves(charge["level_row"],int(values[5]))
		move["hardattack_charge"] = {"duration_ms":int(values[1]),"bonus_percent":int(charge["level_row"][0]),"followup":followup}
	if name == "weaponcombo" and job == "weaponmaster" and weapon == "greatsword":
		# CBEC7D reads column 5 as the rank gate. CD4A7A and CBEF33 read columns 6 and 8.
		var mastery := _skill_row(HEAVY_MASTERY_SKL)
		var values: Array = mastery.get("static",[])
		if values.size() > 8 and int(mastery.get("rank",0)) >= int(values[5]):
			move["weapon_combo_charge"] = {"peak_percent":int(values[6]),"duration_ms":int(values[8])}
	if spec.get("native_state","") == "normalwave":
		move["native_state"] = "normalwave"
		move["native_recovery_ms"] = float(skill["static"][0])
		move["native_move"] = {"speed":float(skill["static"][1]),"accel":float(skill["static"][2])}
		move["normal_cancel_job"] = "asura"
	if spec.get("native_state","") == "wave_cast":
		move["native_state"] = "wave_cast"
		move["native_recovery_ms"] = float(skill["static"][int(spec["native_recovery_col"])])
		move["native_move"] = {"speed":0.0,"accel":0.0}
	if spec.get("native_state","") == "ghost_cast":
		move["native_state"] = "ghost_cast"
		move["native_charge_ani"] = String(spec["native_charge_ani"])
		move["native_recovery_ms"] = float(skill["static"][0])
	if spec.get("native_state","") == "bloodblast":
		move["native_state"] = "bloodblast"
		move["cast_ms"] = float(skill["level_row"][1])
		move["native_recovery_ms"] = float(skill["static"][int(spec["native_recovery_col"])])
		move["fixed_attack_base"] = spec["fixed_attack_base"]["by_level"]
	if spec.get("native_state","") == "thirst":
		var values: Array = skill["static"]
		move.merge({"native_state":"thirst","hp_percent":int(values[0]),
			"native_recovery_ms":int(values[2]),"tier_hp_percent":int(values[5])})
	if spec.has("material_cost"):move["material_cost"] = spec["material_cost"]
	var weapon_hits := _swordman_hits(name)
	if spec.has("stages"):
		move["stages"] = []
		for stage: Dictionary in spec["stages"]:
			var stage_hits := weapon_hits if move["stages"].is_empty() else []
			if name in ["triple","weaponcombo"]:
				stage_hits = _swordman_hits(String(stage["ani"]))
			var built := _build_stage(stage,skill,stage_hits)
			var frames: Array = built["timeline"]
			if stage.has("continue_frame"):
				built["continue_at"] = float(frames[int(stage["continue_frame"])]["start_ms"])
			if name == "weaponcombo" and weapon == "shortsword" and _uses_short_mastery_boxes(String(stage["ani"])):
				# CD459B attaches the same ShortWeaponCombo clip whose boxes CD45CA copies.
				built["fx"].push_front({"key":"weapon_combo_short_mastery%d"%(move["stages"].size()+1),
					"at":0.0,"action_clock":true})
			if stage.has("combo_frame"):
				built["combo_at"] = float(frames[int(stage["combo_frame"])]["start_ms"])
			if name == "triple":
				if frames.size() > TRIPLE_CONTINUE_FRAME:
					built["continue_at"] = float(frames[TRIPLE_CONTINUE_FRAME]["start_ms"])
				var index: int = move["stages"].size()
				# CC7E5D / CC7E8F attach stage and parity clips at state entry.
				built["fx"] = [{"key":"triple_move%d" % (index%2+1),"at":0.0,"action_clock":true},
					{"key":"triple%d" % (index+1),"at":0.0,"action_clock":true}]
			move["stages"].append(built)
		# Static SKL columns are skill-specific. They are movement parameters only
		# when an explicit adapter declares their meaning.
		if spec.has("dash"):
			var dash: Dictionary = spec["dash"]
			var stat: Array = skill.get("static",[])
			var vi := int(dash.get("speed_static",0))
			var ai := int(dash.get("accel_static",1))
			move["dash"] = {"speed":float(stat[vi]) if stat.size() > vi else 0.0,"accel":float(stat[ai]) if stat.size() > ai else 0.0}
		move.merge(move["stages"][0],false)
	else:
		move.merge(_build_stage(spec,skill,weapon_hits),false)
	var normal_index := NORMAL_ATTACK_CHAIN.find(name)
	if normal_index >= 0 and normal_index < NORMAL_CONTINUE_FRAMES.size():
		move["combo_at"] = float(move["timeline"][NORMAL_CONTINUE_FRAMES[normal_index]]["start_ms"])
	if name == "upper":_append_upper_followup(move)
	for stage: Dictionary in move.get("stages",[move]):
		for hit: Dictionary in stage.get("hits",[]):
			hit["skill_id"] = name
			if spec.get("form_normal",false):hit["skill"] = false
	return move

func _append_upper_followup(move: Dictionary) -> void:
	# CBF008: effective ranks of weapon mastery up (27), upper (46) and short sword (12).
	if weapon != "shortsword" or int(skill_levels.get("weapon_mastery_up",0)) <= 0 \
		or int(skill_levels.get("upper",0)) <= 0:return
	var mastery := _skill_row(SHORT_MASTERY_SKL)
	var static_data: Array = mastery["static"]
	if static_data.size() <= 12 or int(mastery["rank"]) < int(static_data[2]):return
	var weapon_hits := _swordman_hits("upper_followup")
	if weapon_hits.is_empty():return
	var stage := _build_stage({"ani":"upperslashafter","atk":"character/swordman/attackinfo/upperslashafter.atk",
		"hits":[{"percent_col":2,"lift_col":3}],
		"sounds":[{"key":"UPPER_SLASH_02","at":0.0},{"key":"SM_UPPERSLASH_ADD","at":0.0}]},
		mastery,weapon_hits)
	var fx: Array = stage["fx"]
	# CD1824 attaches the mastery layer at entry. CBF23B starts the skill FX at frame 2.
	if job == "weaponmaster" and int(mastery["rank"]) >= int(static_data[12]):
		fx.append({"key":"upper_short_followup","at":0.0,"action_clock":true})
	fx.append({"key":"upper2","at":float(stage["timeline"][2]["start_ms"]),"action_clock":true,"scale":0.8})
	var first: Dictionary = move["stages"][0] if move.has("stages") else move.duplicate()
	move["stages"] = [first,stage]
	move["upper_followup_at"] = float(first["timeline"][UPPER_FOLLOWUP_FRAME]["start_ms"])

func _build_stage(spec: Dictionary, skill: Dictionary, weapon_hits: Array = []) -> Dictionary:
	var ani := String(spec.get("ani",""))
	var body := player_timeline(ani) if ani != "" else []
	var default_atk := String(spec.get("atk",""))
	var hits: Array = []
	var row: Array = skill.get("level_row",[])
	var prior_cancel := 0.0
	var hit_specs: Array = spec.get("hits",[])
	if weapon_hits.is_empty() and spec.has("fallback_hits"):
		hit_specs = spec["fallback_hits"]
	for h: Dictionary in hit_specs:
		var atk_path := String(h.get("atk",default_atk))
		if h.get("attached_weapon",false) and weapon_hits.is_empty():continue
		var obj: Dictionary = {}
		if h.has("object"):
			obj = object(String(h["object"]))
			if obj.is_empty():continue
			if atk_path == "":atk_path = String(obj["atk_path"])
		var decoded := atk(atk_path)
		var percent := 100.0+float(decoded.get("damage_bonus",0))
		if h.has("percent_col") and row.size() > int(h["percent_col"]):percent = float(row[int(h["percent_col"])])
		if h.has("percent_scale_col") and row.size() > int(h["percent_scale_col"]):
			# CD51C3 scales (100 + the ATK bonus) and truncates before storing the bonus again.
			percent = float(int(percent*float(row[int(h["percent_scale_col"])])/100.0))
		var lift := float(h.get("lift",-1.0))
		if h.has("lift_col") and row.size() > int(h["lift_col"]):lift = float(row[int(h["lift_col"])])
		if ani == "hitback" and not weapon_hits.is_empty() and row.size() > 2:
			# CD428A / CD42C0 write the ATK lift and horizontal push slots respectively.
			lift = float(row[1])
			decoded = decoded.duplicate()
			decoded["push_aside"] = float(row[2])
		var hit := {"atk":decoded,"atk_path":atk_path,"percent":percent,"lift":lift,"skill":skill.size() > 0,
			"ignore_defense":bool(h.get("ignore_defense",enum_value(decoded,"attack_type")=="[ignore defense]")),"true_damage":float(h.get("true_damage",0)),
			"effects":_level_effects(h.get("effects",[]),row),
			"fixed":float(row[int(h["fixed_col"])]) if h.has("fixed_col") and row.size()>int(h["fixed_col"]) else float(decoded.get("absolute_damage",0)),
			"damage_type":String(h.get("damage_type","magical" if enum_value(decoded,"attack_type")=="[magic]" else "physical")),
			"element":String(h.get("element",enum_value(decoded,"element", "[none element]").trim_prefix("[").trim_suffix(" element]")))}
		if not weapon_hits.is_empty():
			hit["kind"] = "boxes"
			hit["source"] = "attached_weapon"
			hit["segments"] = weapon_hits
			# Keep the existing cancel gate until its native input rules are mapped.
			if h.has("borrow"):
				prior_cancel = maxf(prior_cancel,Timeline.last_active_ms(Timeline.attack_segments(timeline(String(h["borrow"])))))
			elif h.has("window"):
				prior_cancel = maxf(prior_cancel,float(h["window"][1]))
		elif h.get("body",false):
			hit["kind"] = "boxes"
			hit["source"] = "body"
			hit["segments"] = Timeline.attack_segments(body)
		elif h.has("borrow"):
			hit["kind"] = "boxes"
			hit["source"] = "borrow:"+String(h["borrow"])
			hit["segments"] = Timeline.attack_segments(timeline(String(h["borrow"])))
		elif h.has("derived"):
			var box = assets.get("derived_boxes",{}).get(String(h["derived"]))
			if box == null:
				continue
			var w: Array = h["window"]
			hit["kind"] = "boxes"
			hit["source"] = "derived:"+String(h["derived"])
			hit["segments"] = [{"start":float(w[0]),"end":float(w[1]),"frames":[{"start":float(w[0]),"end":float(w[1]),"boxes":[box]}]}]
		elif h.has("object"):
			hit["kind"] = "object"
			hit["object"] = String(h["object"])
			hit["at"] = float(h.get("at",0))
			hit["active_ms"] = float(h.get("active_ms",-1))
			hit["speed"] = float(h.get("speed",0))
			hit["life_ms"] = float(h.get("life_ms",-1))
			if h.has("native_controller"):
				var controller: Dictionary = h["native_controller"].duplicate(true)
				if controller.get("kind","") == "icewave_chain":
					controller["count"] = int(row[int(controller["count_col"])])
					controller["frame2_at_ms"] = float(row[int(controller["frame2_at_col"])])
				elif controller.get("kind","") in ["khazan_field","bremen_field","saya_field","rasa_field","rasa_child"]:
					var column := int(controller["duration_col"])
					if row.size() <= column or float(row[column]) <= 0.0:continue
					hit["life_ms"] = float(row[column])
					if controller["kind"] == "rasa_field":
						var children: Array = _build_stage({"hits":[controller["child"]]},skill)["hits"]
						if children.is_empty():continue
						controller["child"] = children[0]
					elif controller.has("crystals"):
						var ice: Dictionary = controller["crystals"]
						if row.size() <= int(ice["range_col"]):continue
						var children: Array = _build_stage({"hits":[ice["child"]]},skill)["hits"]
						if children.is_empty():continue
						ice["child"] = children[0]
						ice["count"] = int(row[int(ice["count_col"])])
						ice["respawn_ms"] = int(row[int(ice["respawn_col"])])
						ice["range"] = int(row[int(ice["range_col"])])
					elif controller["kind"] == "rasa_child":
						if row.size() <= int(controller["attachment_duration_col"]):continue
						controller["attachment_ms"] = float(row[int(controller["attachment_duration_col"])])
						controller["attack_speed"] = float(row[int(controller["attack_speed_col"])])*0.001
						controller["defense"] = float(row[int(controller["defense_col"])])
						controller["recovery"] = float(row[int(controller["recovery_col"])])
						controller["status_interval_ms"] = float(row[int(controller["status_interval_col"])])
						var blind: Dictionary = {}
						for field: String in controller["blind_columns"]:
							blind[field] = int(row[int(controller["blind_columns"][field])])
						blind["chance"] = float(blind["chance"])*0.001
						controller["blind"] = blind
						controller["stay_timeline"] = timeline(String(controller["stay_ani"]))
				elif controller.get("kind","") == "firewave_chain":
					# Resolve the successor's own ATK and fixed column, not a copy
					# of the travelling-front reaction/damage definition.
					var child_stage := _build_stage({"hits":[controller["child"]]},skill)
					controller["child"] = child_stage["hits"][0]
				hit["native_controller"] = controller
				if controller.get("kind","") == "bloodblast":hit["starts_at_zero"] = true
			hit["rear_fx"] = String(h.get("rear_fx",""))
			# Explicit skill-specific size column; other objects retain native size.
			hit["size_rate"] = float(row[int(h["size_col"])])/100.0 if h.has("size_col") and row.size()>int(h["size_col"]) else 1.0
			if h.has("percent_col") and row.size() > int(h["percent_col"]):
				hit["percent"] = float(row[int(h["percent_col"])])
			elif h.has("percent"):
				hit["percent"] = float(h["percent"])
			var off: Array = h.get("offset",[0,0,0])
			hit["offset"] = Vector3(float(off[0]),float(off[1]),float(off[2]))
		if hit.get("kind","") == "boxes" and hit["segments"].is_empty():
			problems.append("no attack boxes for "+ani+" ("+String(hit["source"])+")")
		hits.append(hit)
	var last := prior_cancel
	for hit: Dictionary in hits:
		if hit["kind"] == "boxes":last = maxf(last,Timeline.last_active_ms(hit["segments"]))
		else:last = maxf(last,float(hit["at"])+maxf(0,float(hit["active_ms"])))
	# Moves without hits (buffs) cannot be cancelled before their motion ends.
	if hits.is_empty():last = Timeline.duration(body)
	var fx: Array = spec.get("fx",[])
	var sounds: Array = spec.get("sounds",[])
	var voice := String(spec.get("voice",""))
	if ani == "hitback" and not weapon_hits.is_empty():
		# CB0D80 attaches ordinary FX slot 0 once at body frame 3.
		var short_sword := weapon == "shortsword"
		fx = [{"key":"upper1","at":float(body[3]["start_ms"]),"action_clock":true,
			"scale":0.8 if short_sword else 0.9,"offset_x":5.0 if short_sword else 0.0,
			"offset_y":-18.0 if short_sword else 0.0}]
		sounds = [{"key":"UPPER_SLASH_01","at":0.0},{"key":"upper","at":0.0}]
		voice = ""
	return {"ani":ani,"timeline":body,"duration":Timeline.duration(body),"hits":hits,"cancel_at":last,
		"fx":fx,"voice":voice,"sounds":sounds}

## Explicit native field bindings only; never infer columns for other skills.
func _level_effects(specs: Array, row: Array) -> Array:
	var result: Array = specs.duplicate(true)
	for effect: Dictionary in result:
		for field: String in ["chance","duration_ms","status_level"]:
			var column := int(effect.get(field+"_col",-1))
			if column>=0 and column<row.size():
				effect[field] = float(row[column])*float(effect.get(field+"_scale",1.0))
	return result

## 20023 installs the lower ANI as the attacking motion and attaches the upper
## ANI in slot 1. Its X motion is a per-object PTL, independent of attack speed.
func _hardattack_waves(row: Array, speed: int) -> Dictionary:
	var source: Dictionary = db.record(HARDATTACK_WAVE_OBJ)["decoded"]
	var motion: Dictionary = db.record(HARDATTACK_WAVE_PTL)["decoded"].duplicate(true)
	motion["axes"]["x"]["move_variable_1"] = [speed,speed]
	var waves := {}
	var ghosts := ["khazan","saya","bremen"]
	for index in ghosts.size():
		var ghost: String = ghosts[index]
		var attack_path: String = source["etc_attack_infos"][index]
		var decoded := atk(attack_path)
		var wave_name := "hardattack_wave_"+ghost
		var definition := {"path":HARDATTACK_WAVE_OBJ,"bank":wave_name+"_up",
			"timeline":timeline(source["etc_motions"][2*index]),"add_fx":"","piercing":int(source["piercing_power"])}
		var hit := {"kind":"object","object":HARDATTACK_WAVE_OBJ,"skill_id":"hardattackcharge","skill":true,
			"atk_path":attack_path,"atk":decoded,"percent":float(row[1+index]),"damage_type":"magical",
			"element":enum_value(decoded,"element").trim_prefix("[").trim_suffix(" element]"),
			"rear_fx":wave_name+"_down","ptl_motion":motion}
		if ghost == "saya":
			# The packet's three words become ATK freeze percent, level and duration.
			hit["effects"] = [{"id":"freeze","chance":float(row[7])*0.01,
				"status_level":int(row[8]),"duration_ms":int(row[9])}]
		elif ghost == "bremen":
			hit["effects"] = [{"id":"sleep","chance":float(row[10])*0.01,
				"status_level":int(row[11]),"duration_ms":int(row[12])}]
		waves[ghost] = {"definition":definition,"hit":hit,"voice":"GHOST_DRIVE_"+ghost.to_upper()}
	waves["khazan"]["caster_buff"] = {"strength":int(row[4]),"intelligence":int(row[5]),"duration_ms":int(row[6])}
	# Selector 96 uses the same two wave clips and hit packet as selector 36.
	waves["sayaex"] = waves["saya"]
	return waves

## Passive object: motion timeline, attack info, particle motion and the render bank key.
func object(path: String) -> Dictionary:
	path = path.to_lower()
	if objects.has(path):return objects[path]
	var rec: Dictionary = db.record(path)
	if rec.is_empty():
		problems.append("OBJ not found: "+path)
		return {}
	var d: Dictionary = rec["decoded"]
	var motions: Array = d.get("basic_motion",[]) if d.get("basic_motion",[]) is Array else []
	if motions.is_empty():
		motions = d.get("etc_motions",[]) if d.get("etc_motions",[]) is Array else []
	var motion := String(motions[0]) if not motions.is_empty() else ""
	if motion == "":
		# Some OBJ records are spawners with no basic motion; they cannot be
		# rendered by the generic passive-object path. Skip that hit instead of
		# failing the whole combat table.
		return {}
	var atk_path := String(d.get("attack_infos",[""])[0])
	var bank := ""
	for key: String in assets.get("objects",{}):
		if String(assets["objects"][key]["source"]) == motion:bank = key
	var add_fx := ""
	var add: Array = d.get("add_object_effect",[])
	if not add.is_empty():
		var add_path := path.get_base_dir().path_join(String(add[0])).to_lower()
		for key: String in assets.get("effects",{}):
			if String(assets["effects"][key]["source"]) == add_path:add_fx = key
	var obj := {"path":path,"motion":motion,"timeline":timeline(motion),"atk":atk(atk_path),"atk_path":atk_path,
		"bank":bank,"add_fx":add_fx,"piercing":int(d.get("piercing_power",0)),"floating":float(d.get("floating_height",0))}
	obj["segments"] = Timeline.attack_segments(obj["timeline"])
	objects[path] = obj
	return obj

func _ability(mob: Dictionary, stat: String) -> float:
	var list: Array = mob.get("ability_category",[])
	for i in range(0,list.size()-2,3):
		if String(list[i]) == stat:return float(list[i+2])
	return 100.0

func _stem(paths) -> String:
	if not paths is Array or paths.is_empty() or String(paths[0]) == "":return ""
	return String(paths[0]).get_file().get_basename()

func _first_path(paths) -> String:
	if not paths is Array or paths.is_empty():return ""
	return String(paths[0]).to_lower()

## Newmonsters .mob action slots point to .act files; [BASE ANI] is the source motion.
func _action_ani(act_path: String) -> String:
	if act_path == "":return ""
	var rec: Dictionary = db.record(act_path)
	if rec.is_empty():
		problems.append("ACT not found: "+act_path)
		return ""
	return String(rec.get("decoded",{}).get("base_ani","")).to_lower()

func _build_monster(key: String, spec: Dictionary) -> Dictionary:
	var path := String(spec["mob"])
	var record: Dictionary = db.record(path)
	var mob: Dictionary = record.get("decoded",{})
	if mob.is_empty():
		problems.append("MOB not found: "+path)
		return {}
	var base: Dictionary = rules["monster_base"]
	# 部分怪（雕像、机关类）没有 waiting motion 或 attack info，空数组直接取 [0] 会崩。
	var waiting: Array = mob.get("waiting_motion", [])
	var motion_dir := String(waiting[0]).get_base_dir() if not waiting.is_empty() else ""
	var motions := {"stay":_stem(mob.get("waiting_motion")),"move":_stem(mob.get("move_motion")),
		"damage1":_stem(mob.get("damage_motion_1")),"damage2":_stem(mob.get("damage_motion_2")),
		"down":_stem(mob.get("down_motion")),"overturn":_stem(mob.get("overturn_motion")),
		"sit":_stem(mob.get("sit_motion")),"attack":_stem(mob.get("attack_motions"))}
	var ani_paths: Dictionary = {}
	var old_motions := {
		"stay":mob.get("waiting_motion",[]), "move":mob.get("move_motion",[]),
		"damage1":mob.get("damage_motion_1",[]), "damage2":mob.get("damage_motion_2",[]),
		"down":mob.get("down_motion",[]), "overturn":mob.get("overturn_motion",[]),
		"sit":mob.get("sit_motion",[])}
	for pose: String in old_motions:
		var stem := String(motions[pose])
		if stem != "" and motion_dir != "":
			var ani_path := String(motion_dir).path_join(stem+".ani").to_lower()
			ani_paths[pose] = ani_path
			ani_paths[stem] = ani_path
	# Newmonsters: [waiting action] ... [last action] resolve through .act.
	var action_slots := {
		"stay":"waiting_actions", "move":"move_actions", "sit":"sit_actions",
		"damage1":"damage_actions_1", "damage2":"damage_actions_2",
		"down":"down_actions", "overturn":"overturn_actions", "die":"last_actions",
		"jump":"jump_actions"}
	for pose: String in action_slots:
		var act_path := _first_path(mob.get(action_slots[pose],[]))
		var ani_path := _action_ani(act_path)
		if act_path == "" or ani_path == "":continue
		var clip := act_path.get_file().get_basename()
		motions[pose] = clip
		ani_paths[pose] = ani_path
		ani_paths[clip] = ani_path
	var m := {"key":key,"mob":path,"bank":String(spec.get("bank",key)),"dir":motion_dir,
		"name":String(spec.get("name",key)),"level":int(mob.get("level",[1])[0]),
		"hp":monster_base_hp(mob)*_ability(mob,"[HP MAX]")/100.0,
		"attack":float(base["attack"])*_ability(mob,"[EQUIPMENT_PHYSICAL_ATTACK]")/100.0,
		"speed":move_px(float(mob.get("move_speed",[300])[0])),"sight":float(mob.get("vision",mob.get("sight",300))),
		"blind_resistance":int(mob.get("blind_resistance",0)),
		"sleep_resistance":int(mob.get("sleep_resistance",0)),
		"poison_resistance":int(mob.get("poison_resistance",0)),
		"bleeding_resistance":int(mob.get("bleeding_resistance",0)),
		"attack_delay":float(mob.get("attack_delay",mob.get("think_term",1200))),
		"hit_recovery":float(mob.get("hit_recovery",[500])[0]),
		"keep_distance":float(spec.get("keep_distance",mob.get("keep_distance",0))),
		"motions":motions, "ani_paths":ani_paths}
	if _native_target_classes.has(path):
		var profile := {"uses_ai_vision":_native_target_classes[path]=="ai","sight":int(mob.get("sight",200)),
			"vision":int(mob.get("vision",1500)),"back_vision":1500,"keep_distance":-1}
		# [keep distance with target] is the separate movement preference.
		for field: Dictionary in record.get("raw",[]):
			if field["values"].is_empty():continue
			match field["tag"]:
				"[keep distance]":profile["keep_distance"] = int(field["values"][0])
				"[back vision]":profile["back_vision"] = int(field["values"][0])
		m["native_target_profile"] = profile
	if record.has("native_attack_selection"):m["native_attack_selection"] = record["native_attack_selection"]
	var summon: Dictionary = assets.get("native_spirit_summons",{}).get(path,{})
	if not summon.is_empty():
		summon = summon.duplicate()
		ani_paths["cast"] = summon["cast_ani"]
		summon["cast_duration_ms"] = Timeline.duration(timeline(summon["cast_ani"]))
		# Ordinary idle sets +3194 to 1000 at 82BB7F before state 13 uses it.
		summon["cast_rate"] = 1.0
		m["native_spirit_summon"] = summon
	var spirit := path in ["monster/spirit/darkspirit.mob","monster/spirit/lightspirit.mob"]
	if spirit or not summon.is_empty():m["native_attack_rate"] = float(mob["attack_speed"][0])/1000.0
	if spirit:
		m["native_spirit"] = true
		m["native_hover_height"] = float(mob.get("floating_height",[0])[0])
	if record.has("native_suicide"):
		var suicide: Dictionary = record["native_suicide"].duplicate(true)
		var source_ani := String(suicide["suicide_ani"])
		var source_timeline := timeline(source_ani)
		var sound_frame := int(suicide["sound_frame"])
		if sound_frame >= source_timeline.size():
			problems.append("suicide sound frame missing for "+path)
		else:
			var pose := source_ani.get_file().get_basename()
			ani_paths[pose] = source_ani
			suicide["pose"] = pose
			suicide["sound_at"] = float(source_timeline[sound_frame]["start_ms"])
			suicide["end_at"] = Timeline.duration(source_timeline)
			var original_ids: Dictionary = db.index("monsters_goblin")
			var children: Array[String] = []
			for child_id in suicide["spawn"]["monster_ids"]:
				children.append(String(original_ids[str(int(child_id))]))
			suicide["spawn"]["mobs"] = children
			m["native_suicide"] = suicide
	var attack_infos: Array = mob.get("attack_infos", [])
	var cooltimes: Array = mob.get("cooltimes", mob.get("cooltime", []))
	var moves: Array = []
	var emissions := {}
	for emission: Dictionary in record.get("native_attack_emissions", []):
		emissions[int(emission["slot"])] = emission
	# Newmonsters: [attack action] aligns by index with [attack info] and [cooltime].
	var attack_actions: Array = mob.get("attack_actions", [])
	for index in attack_actions.size():
		var act_path := String(attack_actions[index]).to_lower()
		var ani_path := _action_ani(act_path)
		if act_path == "" or ani_path == "":continue
		var stem := act_path.get_file().get_basename()
		var move_timeline := timeline(ani_path)
		var move := {"stem":stem, "act":act_path, "ani":ani_path, "timeline":move_timeline,
			"segments":Timeline.attack_segments(move_timeline), "reach":reach_of(move_timeline)}
		ani_paths[stem] = ani_path
		if index < attack_infos.size():
			var atk_path := String(attack_infos[index]).to_lower()
			if atk_path != "":
				move["atk"] = atk(atk_path)
				move["atk_path"] = atk_path
		if index < cooltimes.size():
			move["cool_ms"] = float(cooltimes[index])
		if emissions.has(index):_attach_attack_emission(move,emissions[index],path)
		moves.append(move)
	# Some newmonsters index locomotion as an attack action rather than a dedicated
	# [move action] (chainbiker2 slots 3-5 are move/move_up/move_down).
	if String(motions.get("move","")) == "" and ani_paths.has("move"):
		motions["move"] = "move"
	# 老架构多套招式：每招有独立 ANI 与 .atk。
	var motions_all: Array = mob.get("attack_motions", []) if mob.get("attack_motions") is Array else []
	if moves.is_empty() and motions_all.size() > 1:
		for index in motions_all.size():
			var stem := _stem([motions_all[index]])
			if stem == "":continue
			var move_timeline := timeline(String(motion_dir).path_join(stem + ".ani"))
			var move := {"stem":stem, "ani":String(motion_dir).path_join(stem + ".ani").to_lower(),
				"timeline":move_timeline,"segments":Timeline.attack_segments(move_timeline), "reach":reach_of(move_timeline)}
			ani_paths[stem] = move["ani"]
			if index < attack_infos.size():
				var atk_path := String(attack_infos[index]).to_lower()
				if atk_path != "":
					move["atk"] = atk(atk_path)
					move["atk_path"] = atk_path
			if index < cooltimes.size():move["cool_ms"] = float(cooltimes[index])
			if emissions.has(index):_attach_attack_emission(move,emissions[index],path)
			if record.has("native_starfish_jump"):move["source_slot"] = index
			moves.append(move)
	if not moves.is_empty():m["moves"] = moves
	if record.has("native_starfish_jump"):
		_bind_native_starfish_jump(m,record["native_starfish_jump"],moves)
	if record.has("native_starfish_bite"):
		_bind_native_starfish_bite(m,record["native_starfish_bite"],moves)
	for binding: Dictionary in record.get("native_attack_contacts",[]):
		var slot := int(binding["slot"])
		var object_path := String(binding["object_path"])
		var resolved: Array = _build_stage({"hits":[{"object":object_path}]},{})["hits"]
		var contact_object := object(object_path)
		if slot < 0 or slot >= attack_infos.size() or resolved.is_empty() or contact_object.get("bank","") != String(binding["object_bank"]):
			problems.append("attack contact slot, object, or render bank missing for "+path)
			continue
		var hit: Dictionary = resolved[0]
		hit["skill_id"] = ""
		hit["starts_at_zero"] = true
		if not m.has("attack_contacts"):m["attack_contacts"] = {}
		m["attack_contacts"][slot] = {
			"hit":hit,"target_class":int(binding["target_class"]),
			"chance_percent":int(binding["chance_percent"]),"atk_path":String(attack_infos[slot]).to_lower(),
		}
	var first_attack: Dictionary = moves[0] if not moves.is_empty() else {}
	if not first_attack.is_empty():
		motions["attack"] = String(first_attack["stem"])
		m["attack_timeline"] = first_attack["timeline"]
	else:
		var old_attack_path := String(motion_dir).path_join(String(motions["attack"])+".ani").to_lower() if motion_dir != "" and String(motions["attack"]) != "" else ""
		m["attack_timeline"] = timeline(old_attack_path) if old_attack_path != "" else []
		if old_attack_path != "":ani_paths[String(motions["attack"])] = old_attack_path
	m["attack_segments"] = Timeline.attack_segments(m["attack_timeline"])
	m["atk"] = first_attack.get("atk",atk(String(attack_infos[0])) if not attack_infos.is_empty() else {})
	# 原版选招规则：按 .mob 文件名（不含扩展名）在反编译出的规则表里查。
	# 规则形如 [{skill, area, cooldown_checked}]，area 为空的是无条件分支（多为大招）。
	var mob_stem := String(path).get_file().get_basename().to_lower()
	if boss_rules.has(mob_stem):
		m["rules"] = boss_rules[mob_stem]
	elif rules_by_family.has(String(path).get_base_dir()):
		# 族共享的 AI（原版绝大多数就是这一层）：同族的怪共用一套选招规则。
		m["rules"] = rules_by_family[String(path).get_base_dir()]
	# 召唤：动作 ANI 命中 .act 的 [SUMMON MONSTER] 时挂到该招上；
	# die 动作的召唤就是原版的“死亡变身”（如 chiefmongghost → chiefmongghost_2nd）。
	if not summons_by_ani.is_empty():
		for move: Dictionary in m.get("moves", []):
			var ani_path := String(move.get("ani", "")).to_lower()
			if summons_by_ani.has(ani_path):
				move["summons"] = summons_by_ani[ani_path]
		var die_path := String((m.get("ani_paths", {}) as Dictionary).get("die", ""))
		if die_path != "" and summons_by_ani.has(die_path):
			m["die_summons"] = summons_by_ani[die_path]
	var throw: Dictionary = mob.get("throw_attack",{}) if mob.get("throw_attack") is Dictionary else {}
	if not throw.is_empty():
		var objects_index: Dictionary = db.index("passive_objects")
		var obj := object(String(objects_index.get(str(int(throw.get("passive_object_index",-1))),"")))
		var filename:=String(throw.get("passive_object_filename","")).to_lower()
		var ptl_path:=filename if filename.begins_with("passiveobject/") else path.get_base_dir().path_join(filename)
		var ptl: Dictionary = db.record(ptl_path).get("decoded",{})
		var speed: Array = ptl.get("axes",{}).get("x",{}).get("move_variable_1",[0])
		m["throw"] = {"object":obj,"frame":int(throw.get("throw_frame",0)),"sound":String(throw.get("throw_sound","")),
			"start":Vector3(float(throw.get("passive_object_start_x_cood",0)),float(throw.get("passive_object_start_y_cood",0)),
				float(throw.get("passive_object_start_z_cood",0))),
			"speed":float(speed[0]),"life_ms":float(ptl.get("life_time",1000))}
		if obj.is_empty() or ptl.is_empty():problems.append("throw object/particle missing for "+path)
		m["atk"] = obj.get("atk",{})
	# Explicit content adaptation for the archived Gero MOB: no attack info or
	# throw record survives there. Reuse the declared thrower's projectile data,
	# keeping this MOB's original motion/bank. This does not restore its full AI.
	elif spec.has("attack_template"):
		var template: Dictionary=monsters.get(spec["attack_template"],{})
		if template.has("throw"):
			m["throw"]=template["throw"].duplicate(true)
			m["atk"]=template["atk"].duplicate(true)
		else:problems.append("monster attack template unavailable: "+key)
	return m

func _attach_attack_emission(move: Dictionary, emission: Dictionary, mob_path: String) -> void:
	var frame := int(emission["frame"])
	var motion: Dictionary = db.record(String(emission["ptl_path"])).get("decoded",{})
	var obj := object(String(emission["object_path"]))
	var timeline: Array = move["timeline"]
	if frame < 0 or frame >= timeline.size() or obj.is_empty() or motion.is_empty():
		problems.append("attack emission dependencies missing for %s slot %s" % [mob_path,emission["slot"]])
		return
	var offset: Array = emission["offset"]
	move["emission"] = {
		"at":float(timeline[frame]["start_ms"]),
		"sound":String(emission["sound"]),
		"hit":{"object":obj["path"],"atk":obj["atk"],"atk_path":obj["atk_path"],
			"percent":100.0+float(obj["atk"].get("damage_bonus",0)),"lift":-1.0,
			"offset":Vector3(offset[0],offset[1],offset[2]),"life_ms":float(motion["life_time"]),
			"ptl_motion":motion},
	}

## 一招能覆盖的水平区间（相对锚点，含朝向翻转前的正值侧）。
func _bind_native_starfish_jump(monster: Dictionary, source: Dictionary, moves: Array) -> void:
	var jump := source.duplicate(true)
	var indices := {}
	for index in moves.size():indices[int(moves[index]["source_slot"])] = index
	var move_index := int(indices.get(int(source["slot"]),-1))
	var clips: Dictionary = assets.get("monsters",{}).get(monster["bank"],{}).get("clips",{})
	for phase: String in ["start","rolling","end"]:
		var path := String(source[phase+"_ani"])
		var pose := path.get_file().get_basename()
		jump[phase+"_pose"] = pose
		jump[phase+"_timeline"] = timeline(path)
		if not clips.has(pose) or jump[phase+"_timeline"].is_empty():
			problems.append("missing original StarFish "+phase+" clip for "+String(monster["mob"]))
			return
		monster["ani_paths"][pose] = path
	var launch_frame := int(jump["launch_frame"])
	if move_index < 0 or launch_frame >= jump["start_timeline"].size():
		problems.append("missing original StarFish launch frame or slot for "+String(monster["mob"]))
		return
	jump["move_index"] = move_index
	jump["launch_at"] = float(jump["start_timeline"][launch_frame]["start_ms"])
	jump["rolling_segments"] = Timeline.attack_segments(jump["rolling_timeline"])
	var attack := atk(String(jump["rolling_atk"]))
	jump["rolling_hit"] = {"atk":attack,"atk_path":jump["rolling_atk"],"skill_id":"",
		"percent":100.0+float(attack.get("damage_bonus",0)),"lift":-1.0}
	monster["native_starfish_jump"] = jump
	monster["native_attack_selection"] = source["selection"]
	monster["native_move_indices"] = indices

func _bind_native_starfish_bite(monster: Dictionary, source: Dictionary, moves: Array) -> void:
	var bite := source.duplicate(true)
	var index := int(monster.get("native_move_indices",{}).get(int(bite["slot"]),-1))
	if index < 0 or String(moves[index]["ani"]) != String(bite["attempt_ani"]):
		problems.append("missing original StarFish TryBite slot")
		return
	var attempt: Dictionary = moves[index]
	bite["move_index"] = index
	bite["launch_at"] = float(attempt["timeline"][int(bite["launch_frame"])]["start_ms"])
	# TryBite has no damage-bearing input (8715C4 → 293C11E).
	bite["attempt_hit"] = {"atk":attempt["atk"],"atk_path":attempt["atk_path"],
		"skill_id":"","damage_type":"magical","percent":0.0,"fixed":0.0,"starfish_grab":true}
	var clips: Dictionary = assets.get("monsters",{}).get(monster["bank"],{}).get("clips",{})
	for phase: String in ["bite","release"]:
		var path := String(bite[phase+"_ani"])
		var pose := path.get_file().get_basename()
		var frames := timeline(path)
		if not clips.has(pose) or frames.size() < 2:
			problems.append("missing original StarFish "+phase+" clip")
			return
		bite[phase+"_pose"] = pose
		bite[phase+"_duration"] = Timeline.duration(frames)
		monster["ani_paths"][pose] = path
		if phase == "release":bite["release_landed_at"] = float(frames[1]["start_ms"])
	var attack := atk(String(bite["bite_atk"]))
	bite["hit"] = {"atk":attack,"atk_path":bite["bite_atk"],"skill_id":"",
		"ignore_defense":enum_value(attack,"attack_type") == "[ignore defense]",
		"percent":100.0+float(attack["damage_bonus"]),"lift":-1.0}
	monster["native_starfish_bite"] = bite

func reach_of(tl: Array) -> Array:
	var low := INF
	var high := -INF
	for f: Dictionary in tl:
		for box in f.get("attack_boxes", []):
			if not box is Array or box.size() < 4:continue
			var x := float(box[0])
			var w := float(box[3])
			low = minf(low, x)
			high = maxf(high, x + w)
	if low == INF:return []
	return [low, high]

func monster_timeline(m: Dictionary, motion: String) -> Array:
	var direct := String((m.get("ani_paths", {}) as Dictionary).get(motion, ""))
	if direct != "":return timeline(direct)
	var stem := String(m["motions"].get(motion,motion))
	return timeline(String(m["dir"]).path_join(stem+".ani"))

## Monster definition by MOB path (map spawn lists name the MOB file).
func monster_by_mob(mob: String) -> String:
	for key: String in monsters:
		if String(monsters[key].get("mob","")) == mob.to_lower():return key
	return ""
