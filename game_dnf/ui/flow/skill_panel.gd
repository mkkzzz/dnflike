extends RefCounted
## 技能面板：原版 SkillShop 零件（tools/build_dnf_skill_panel.py 烘焙）＋ SKL 图标。
## 列出全部 175 条原版剑士技能；已实装的 7 个可加点，其余标灰只读。
## 加点走 numbers.skill 事务；调试开关带 force 跳过等级/职业/前置（仍受上限与 SP 约束）。
const Numbers = preload("res://stats/api/numbers.gd")
const CATALOG := "res://data/skill_catalog.json"
const MANIFEST := "res://assets_local/skill_panel/manifest.json"
const ROWS := 9
const TABS := ["技能", "被动", "通用", "强化"]
const JOB_NAMES := {"swordman": "鬼剑士", "weaponmaster": "剑魂", "berserker": "狂战士"}
const GREAT_KEYS := ["enchant", "alchemy", "dollmaking", "opendisjointshop", "disjointitem", "disjointitemdark",
	"conversion", "statusup", "quickstanding", "throwmastery", "fastequip", "durabilityup", "superarmoroncast",
	"experienceup", "basichpmaxup", "basicattackup", "jumppowerup", "magicalattackup"]
## 可以拖进 HUD 技能槽的主动技能（slot_layout 的 DEFAULT_SKILLS 同源）。
const SLOT_CODES := ["draw", "triple", "rage_slash", "buff", "guard"]

var game
var tab := 0
var page := 0
var selected := ""
var free_mode := false
var skills: Array = []
var by_id: Dictionary = {}
var by_key: Dictionary = {}
var parts: Dictionary = {}
var _textures: Dictionary = {}

func _init(target) -> void:
	game = target
	_load()

func _load() -> void:
	for path in [CATALOG, MANIFEST]:
		if not FileAccess.file_exists(path):
			push_warning("技能面板资源缺失：" + path)
			return
	var catalog: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(CATALOG))
	skills = catalog.get("skills", [])
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	parts = manifest.get("parts", {})
	for skill: Dictionary in skills:
		by_id[int(skill["id"])] = skill
		by_key[String(skill["key"])] = skill
	for skill: Dictionary in skills:
		if String(skill["local_id"]) == "upper":
			selected = String(skill["key"])
			break
	if selected == "":
		for skill: Dictionary in skills:
			if String(skill["local_id"]) != "":
				selected = String(skill["key"])
				break
	if selected == "" and not skills.is_empty():
		selected = String(skills[0]["key"])

func _tex(rel: String) -> Texture2D:
	if rel == "":
		return null
	if _textures.has(rel):
		return _textures[rel]
	var image := Image.load_from_file(ProjectSettings.globalize_path("res://assets_local/skill_panel/" + rel))
	var tex: Texture2D = ImageTexture.create_from_image(image) if image != null else null
	_textures[rel] = tex
	return tex

func _part(key: String) -> Texture2D:
	var entry: Dictionary = parts.get(key, {})
	if entry.is_empty():
		return null
	return _tex(String(entry.get("file", "")))

func category(skill: Dictionary) -> int:
	var key := String(skill["key"])
	if key.ends_with("ex") or key.ends_with("exp"):
		return 3
	if key.contains("mastery") or key.ends_with("up") or key.begins_with("compound") or key in GREAT_KEYS:
		return 2
	if String(skill["type"]).contains("passive"):
		return 1
	return 0

## 每个分类内已实装的排前面，其余按原版编号。
func filtered() -> Array:
	var live: Array = []
	var rest: Array = []
	for skill: Dictionary in skills:
		if category(skill) != tab:
			continue
		if String(skill["local_id"]) != "":
			live.append(skill)
		else:
			rest.append(skill)
	live.sort_custom(func(a, b): return int(a["id"]) < int(b["id"]))
	rest.sort_custom(func(a, b): return int(a["id"]) < int(b["id"]))
	return live + rest

func show_window(parent: Control) -> void:
	var skin = game.skin
	var dim := _part("dim")
	if dim != null:
		skin.image(parent, dim, Vector2.ZERO)
	skin.panel(parent, Rect2(40, 20, 720, 560))
	var title := _part("title")
	if title != null:
		skin.image(parent, title, Vector2(56, 30))
	skin.label(parent, "技能", Vector2(70, 36), 14, Color("e8ddb9"))
	skin.close_button(parent, Vector2(724, 30), func(): game.show_overlay(""))
	for index in TABS.size():
		var value := index
		skin.button(parent, TABS[index], Vector2(56 + index * 92, 68), func(): tab = value; page = 0; game.show_overlay("numbers"), false)
	_head(parent)
	_list(parent)
	_detail(parent)
	_footer(parent)

func _head(parent: Control) -> void:
	var skin = game.skin
	var profile: Dictionary = game.session.profile
	skin.label(parent, "角色 Lv.%d  ·  %s" % [int(profile["level"]), JOB_NAMES.get(String(profile["growtype"]), String(profile["growtype"]))],
		Vector2(440, 38), 12, Color("a7dd74"))
	var sp := _part("sp_icon")
	if sp != null:
		skin.image(parent, sp, Vector2(440, 60))
	skin.label(parent, "可用 SP  %d" % Numbers.Skills.available(profile, Numbers.config()), Vector2(462, 62), 13, Color("f0d18a"))

func _list(parent: Control) -> void:
	var skin = game.skin
	var rows: Array = filtered()
	var pages := maxi(1, int(ceil(float(rows.size()) / ROWS)))
	page = clampi(page, 0, pages - 1)
	var start := page * ROWS
	for index in mini(ROWS, maxi(0, rows.size() - start)):
		var skill: Dictionary = rows[start + index]
		var y := 94 + index * 34
		var key := String(skill["key"])
		var chosen := key == selected
		var frame := _part("frame_selected") if chosen else _part("cell")
		if frame != null:
			skin.image(parent, frame, Vector2(56, y))
		var icon := _tex(String(skill["icon"]))
		if icon != null:
			skin.image(parent, icon, Vector2(58, y + 1))
		var state := _state(skill)
		var color := Color("e8ddb9") if bool(state["ok"]) else Color("8a8578")
		skin.label(parent, String(skill["name"]), Vector2(92, y + 4), 12, color)
		var rank := 0
		var level_text := "未实装"
		if String(skill["local_id"]) != "":
			rank = int(game.session.profile["skills"].get(String(skill["local_id"]), 0))
			level_text = "%d / %d" % [rank, int(skill.get("max_level", 0))]
		skin.label(parent, level_text, Vector2(246, y + 4), 11, Color("a59c88"))
		var reason := String(state["reason"])
		if reason != "":
			skin.label(parent, reason, Vector2(318, y + 4), 10, Color("c86a5a"))
		skin.label(parent, "SP " + str(int(skill.get("purchase_cost") or 0)), Vector2(388, y + 4), 10, Color("a59c88"))
		var hit := Button.new()
		hit.flat = true
		hit.position = Vector2(56, y)
		hit.size = Vector2(420, 30)
		hit.pressed.connect(func(): selected = key; game.show_overlay("numbers"))
		var local_id := String(skill["local_id"])
		var drag_icon := icon
		hit.set_drag_forwarding(func():
			if not (local_id in SLOT_CODES):
				return null
			if drag_icon != null:
				var preview := TextureRect.new()
				preview.texture = drag_icon
				preview.size = Vector2(50, 50)
				preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
				hit.set_drag_preview(preview)
			return {"place": "skill_catalog", "id": local_id}, Callable(), Callable())
		parent.add_child(hit)
		var plus := _part("plus")
		if plus != null and String(skill["local_id"]) != "":
			skin.icon_button(parent, plus, Vector2(478, y + 4), func(): change(key, 1))
	skin.button(parent, "上一页", Vector2(56, 402), func(): page = maxi(0, page - 1); game.show_overlay("numbers"), false)
	skin.button(parent, "下一页", Vector2(160, 402), func(): page = mini(pages - 1, page + 1); game.show_overlay("numbers"), false)
	skin.label(parent, "%d / %d · 共 %d 条" % [page + 1, pages, rows.size()], Vector2(270, 406), 11, Color("a59c88"))

func _detail(parent: Control) -> void:
	var skin = game.skin
	var skill: Dictionary = by_key.get(selected, {})
	if skill.is_empty():
		return
	skin.panel(parent, Rect2(520, 94, 224, 300))
	var big := _part("icon_big")
	if big != null:
		skin.image(parent, big, Vector2(528, 100))
	var icon := _tex(String(skill["icon_selected"]))
	if icon == null:
		icon = _tex(String(skill["icon"]))
	if icon != null:
		skin.image(parent, icon, Vector2(536, 108))
	skin.label(parent, String(skill["name"]), Vector2(528, 154), 14, Color("f0d18a"))
	skin.label(parent, "%s · 编号 %d" % [_type_name(String(skill["type"])), int(skill["id"])], Vector2(528, 176), 10, Color("a59c88"))
	var lines: Array[String] = []
	var local := String(skill["local_id"])
	if local == "":
		lines.append("状态  未实装（原版数据完整，缺战斗动作）")
	else:
		var rank := int(game.session.profile["skills"].get(local, 0))
		lines.append("等级  %d / %d" % [rank, int(skill.get("max_level", 0))])
		lines.append("每级 SP  %s" % str(int(skill.get("purchase_cost") or 0)))
		var values: Dictionary = game.skill_catalog.get_skill(local, maxi(1, rank))
		lines.append("MP %d · CD %.1fs" % [int(values.get("mp", 0)), float(values.get("cooldown", 0))])
		var percentages: Array = values.get("damage_percent", [])
		if not percentages.is_empty():
			lines.append("伤害  %d%%" % int(percentages[0]))
	lines.append("角色等级  %d（每级 +%d）" % [int(skill.get("required_level", 0)), int(skill.get("required_level_range") or 0)])
	var jobs := _jobs(skill)
	if jobs != "":
		lines.append("职业  " + jobs)
	var pre := _requires(skill)
	if pre != "":
		lines.append("前置  " + pre)
	for index in lines.size():
		skin.label(parent, lines[index], Vector2(528, 200 + index * 17), 10, Color("c9c0a8"))
	var state := _state(skill)
	var tip := "可学习 / 可加点" if bool(state["ok"]) else String(state["reason"])
	skin.label(parent, tip, Vector2(528, 366), 11, Color("a7dd74") if bool(state["ok"]) else Color("c86a5a"))

func _footer(parent: Control) -> void:
	var skin = game.skin
	var skill: Dictionary = by_key.get(selected, {})
	var key := String(skill.get("key", ""))
	skin.button(parent, "加点", Vector2(56, 430), func(): change(key, 1))
	skin.button(parent, "退点", Vector2(160, 430), func(): change(key, -1))
	skin.button(parent, "重置加点", Vector2(264, 430), func(): game.act("numbers.skill_reset"); game.show_overlay("numbers"))
	skin.button(parent, "调试·无视限制 " + ("开" if free_mode else "关"), Vector2(380, 430),
		func(): free_mode = not free_mode; game.show_overlay("numbers"))
	var profile: Dictionary = game.session.profile
	var job := String(profile["growtype"])
	if job == "swordman":
		var ready := int(profile["level"]) >= 18
		skin.button(parent, "转职·剑魂" + ("" if ready else " 18级"), Vector2(56, 466), func(): job_change("weaponmaster"))
		skin.button(parent, "转职·狂战士" + ("" if ready else " 18级"), Vector2(160, 466), func(): job_change("berserker"))
		if not ready:
			skin.label(parent, "18 级后可按原版转职", Vector2(56, 492), 10, Color("a59c88"))
	else:
		skin.label(parent, "已转职：" + JOB_NAMES.get(job, job), Vector2(56, 470), 12, Color("a7dd74"))
	skin.label(parent, "等级上限与前置取自原版 SKL；加点立即作用于战斗参数。", Vector2(270, 470), 10, Color("a59c88"))

func _type_name(raw: String) -> String:
	if raw.contains("passive"):
		return "被动"
	if raw.contains("active"):
		return "主动"
	return "未知"

func _jobs(skill: Dictionary) -> String:
	var index: Dictionary = Numbers.config().get("growtype_index", {})
	var caps: Array = skill.get("growtype_max_level") or []
	var out: Array[String] = []
	for job: String in index:
		var slot := int(index[job])
		if slot < caps.size() and int(caps[slot]) > 0:
			out.append(JOB_NAMES.get(job, job))
	if out.size() == index.size():
		return ""
	return "、".join(out)

func _requires(skill: Dictionary) -> String:
	var out: Array[String] = []
	for entry: Dictionary in skill.get("pre_required_skill") or []:
		var parent: Dictionary = by_id.get(int(entry["id"]), {})
		out.append("%s Lv%d" % [String(parent.get("name", "编号 %d" % int(entry["id"]))), int(entry["level"])])
	return "、".join(out)

## 返回 {ok, reason}：原版等级/职业/前置 + 本地实装与 SP 状态。
func _state(skill: Dictionary) -> Dictionary:
	var local := String(skill["local_id"])
	if local == "":
		return {"ok": false, "reason": "未实装"}
	if free_mode:
		return {"ok": true, "reason": ""}
	var profile: Dictionary = game.session.profile
	var cfg := Numbers.config()
	var rank := int(profile["skills"].get(local, 0))
	if rank >= int(skill.get("max_level", 0)):
		return {"ok": false, "reason": "已满级"}
	var caps: Array = skill.get("growtype_max_level") or []
	var slot := int(cfg.get("growtype_index", {}).get(String(profile["growtype"]), 0))
	if not caps.is_empty() and (slot >= caps.size() or rank >= int(caps[slot])):
		return {"ok": false, "reason": "职业不符"}
	var need := int(skill.get("required_level", 1)) + rank * int(skill.get("required_level_range") or 0)
	if int(profile["level"]) < need:
		return {"ok": false, "reason": "需 Lv%d" % need}
	for entry: Dictionary in skill.get("pre_required_skill") or []:
		var parent: Dictionary = by_id.get(int(entry["id"]), {})
		var parent_local := String(parent.get("local_id", ""))
		if parent_local == "":
			return {"ok": false, "reason": "前置未实装"}
		if int(profile["skills"].get(parent_local, 0)) < int(entry["level"]):
			return {"ok": false, "reason": "前置 %s Lv%d" % [String(parent.get("name", "")), int(entry["level"])]}
	if Numbers.Skills.available(profile, cfg) < int(skill.get("purchase_cost") or 0):
		return {"ok": false, "reason": "SP 不足"}
	return {"ok": true, "reason": ""}

func change(key: String, delta: int) -> void:
	var skill: Dictionary = by_key.get(key, {})
	var local := String(skill.get("local_id", ""))
	if local == "":
		game.notice("该技能尚未实装")
		return
	if game.act("numbers.skill", {"id": local, "delta": delta, "force": free_mode}):
		selected = key
		game.show_overlay("numbers")

func job_change(job: String) -> void:
	if game.act("numbers.growtype", {"growtype": job}):
		game.notice("已转职：" + JOB_NAMES.get(job, job))
		game.show_overlay("numbers")
