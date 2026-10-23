extends RefCounted
## Pure flow state. v1 rewards/items are E-ADAPT, never claimed as original balance.
const CATALOG := preload("res://items/catalog.gd")
const Layout = preload("res://items/slot_layout.gd")
var profile: Dictionary = {}
var state := "town"
var run: Dictionary = {}
var result: Dictionary = {}

func _init() -> void:
	profile = {"schema": 1, "name": "冒险家", "level": 1, "xp": 0, "gold": 300,
		"inventory": {"iron_sword": 1, "potion": 3}, "equipped": "iron_sword",
		"quest": "available", "clears": 0, "next_run": 1, "settled": {}}
	Layout.normalize(profile, CATALOG.ITEMS)

func snapshot() -> Dictionary:
	return {"profile": profile.duplicate(true), "state": state, "run": run.duplicate(true),
		"result": result.duplicate(true), "stats": stats()}

func stats() -> Dictionary:
	var item: Dictionary = CATALOG.ITEMS.get(profile["equipped"], {"multiplier": 0.8})
	return {"hp": 500 + (int(profile["level"]) - 1) * 25, "mp": 180,
		"damage_multiplier": float(item["multiplier"]), "weapon": "katana"}

func command(kind: String, payload: Dictionary = {}) -> Dictionary:
	match kind:
		"flow.accept_quest":
			if state != "town" or profile["quest"] != "available":return reject("现在无法接受这个任务")
			profile["quest"] = "active"
		"flow.claim_quest":
			if state != "town" or profile["quest"] != "ready":return reject("先击败密林领主，再来找林纳斯")
			profile["quest"] = "done"
			profile["gold"] += 200
			add_item("forest_sword", 1)
		"items.buy":
			if state != "town":return reject("请回城后购买")
			var id := String(payload.get("id", ""))
			if not CATALOG.ITEMS.has(id) or not CATALOG.ITEMS[id].has("price"):return reject("商品不存在")
			var count = payload.get("count", 1)
			if not count is int or count < 1 or count > 999:return reject("购买数量无效")
			var price: int = int(CATALOG.ITEMS[id]["price"]) * int(count)
			if int(profile["gold"]) < price:return reject("金币不足")
			profile["gold"] -= price
			add_item(id, count)
		"items.equip":
			if state != "town":return reject("请回城后更换装备")
			var id := String(payload.get("id", ""))
			if not CATALOG.ITEMS.has(id) or CATALOG.ITEMS[id].get("kind") != "weapon" or int(profile["inventory"].get(id, 0)) < 1:return reject("没有这件装备")
			profile["equipped"] = id
			Layout.normalize(profile, CATALOG.ITEMS)
		"items.unequip":
			if state != "town":return reject("请回城后更换装备")
			profile["equipped"] = ""
			Layout.normalize(profile, CATALOG.ITEMS)
		"slots.move":
			if payload.get("source", {}).get("place") == "equipment" or payload.get("target", {}).get("place") == "equipment":
				if state != "town":return reject("请回城后更换装备")
			if not Layout.move(profile, CATALOG.ITEMS, payload.get("source", {}), payload.get("target", {})):return reject("这里不能放置该物品或技能")
		"flow.difficulty":
			if state != "town" or payload.get("id") not in ["normal", "adventure", "king"]:return reject("难度无效")
			profile["difficulty"] = payload["id"]
		"flow.depart":
			if state != "town":return reject("已有进行中的冒险")
			if payload.get("dungeon", "forest_trial") != "forest_trial":return reject("地下城未开放")
			run = {"id": "run_%d" % int(profile["next_run"]), "dungeon": "forest_trial", "difficulty":profile.get("difficulty", "normal"), "stats": stats()}
			profile["next_run"] += 1
			result = {}
			state = "battle"
		"flow.return":
			if state != "result":return reject("请先完成冒险")
			state = "town"
			run = {}
		"flow.retreat":
			if state != "battle":return reject("当前没有战斗")
			finish_run(false, {"reason": "retreat"})
		_:
			return reject("未知操作：" + kind)
	return {"ok": true}

func consume_potion() -> Dictionary:
	if state != "battle" or int(profile["inventory"].get("potion", 0)) < 1:return reject("没有可用的恢复药剂")
	profile["inventory"]["potion"] -= 1
	return {"ok": true, "heal": int(CATALOG.ITEMS["potion"]["heal"])}

func add_item(id: String, count: int) -> void:
	# Fixed v1 catalog stacks by semantic ID; no finite-slot discard path.
	profile["inventory"][id] = int(profile["inventory"].get(id, 0)) + count
	Layout.normalize(profile, CATALOG.ITEMS)

func combat_event(event: Dictionary) -> Dictionary:
	if state != "battle" or event.get("run_id") != run.get("id"):return reject("忽略过期战斗事件")
	match event.get("type", ""):
		"combat.player_defeated":return finish_run(false, event.get("stats", {}))
		"combat.room_combat_finished":
			if bool(event.get("final_room", false)):return finish_run(true, event.get("stats", {}))
	return {"ok": true}

func finish_run(won: bool, details: Dictionary) -> Dictionary:
	var id := String(run.get("id", ""))
	if id.is_empty() or profile["settled"].has(id) or state != "battle":return reject("该冒险已结算")
	profile["settled"][id] = true
	result = {"run_id": id, "victory": won, "gold": 0, "xp": 0, "potion": 0, "stats": details.duplicate(true)}
	if won:
		result.merge({"gold": 150, "xp": 120, "potion": 1}, true)
		var damage := int(details.get("damage_taken", 0))
		result["rank"] = "S" if damage <= 50 else "A" if damage <= 250 else "B"
		profile["gold"] += 150
		profile["xp"] += 120
		profile["clears"] += 1
		add_item("potion", 1)
		if profile["quest"] == "active":profile["quest"] = "ready"
		while int(profile["xp"]) >= int(profile["level"]) * 100:
			profile["xp"] -= int(profile["level"]) * 100
			profile["level"] += 1
	state = "result"
	return {"ok": true}

func serialize() -> Dictionary:
	return {"schema": "dnf_loop_save/1", "profile": profile.duplicate(true), "state": state,
		"run": run.duplicate(true), "result": result.duplicate(true)}

func restore(data: Dictionary) -> bool:
	if data.get("schema") != "dnf_loop_save/1" or not data.get("profile") is Dictionary:return false
	var p: Dictionary = data["profile"]
	for k: String in profile:
		if k in ["bag_layout", "quick_items", "skill_slots", "difficulty"]:continue
		if not p.has(k) or typeof(p[k]) != typeof(profile[k]) and not (p[k] is float and profile[k] is int):return false
	if not p["inventory"] is Dictionary or not p["settled"] is Dictionary:return false
	if p["quest"] not in ["available", "active", "ready", "done"] or (p["equipped"] != "" and not CATALOG.ITEMS.has(p["equipped"])):return false
	if not Layout.valid(p, CATALOG.ITEMS):return false
	for id in p["inventory"]:
		if not CATALOG.ITEMS.has(id) or not (p["inventory"][id] is float or p["inventory"][id] is int) or float(p["inventory"][id]) < 0 or float(p["inventory"][id]) != floorf(float(p["inventory"][id])):return false
	for key in ["level", "gold", "xp", "clears", "next_run"]:
		if float(p[key]) < (1 if key in ["level", "next_run"] else 0) or float(p[key]) != floorf(float(p[key])):return false
	if p["equipped"] != "" and int(p["inventory"].get(p["equipped"], 0)) < 1:return false
	if not data.get("run", {}) is Dictionary or not data.get("result", {}) is Dictionary:return false
	for id in p["settled"]:
		if not id is String or not p["settled"][id] is bool or not p["settled"][id]:return false
	if data.get("state") == "result":
		var r: Dictionary = data["result"]
		if not r.get("stats") is Dictionary or not r.get("victory") is bool or not r.get("run_id") is String:return false
		if not p["settled"].has(r["run_id"]) or data["run"].get("id") != r["run_id"]:return false
		for key in ["gold", "xp", "potion"]:
			if not (r.get(key) is int or r.get(key) is float) or float(r[key]) < 0:return false
	profile = p.duplicate(true)
	Layout.normalize(profile, CATALOG.ITEMS)
	for key in ["schema", "level", "gold", "xp", "clears", "next_run"]:profile[key] = int(profile[key])
	for id in profile["inventory"]:profile["inventory"][id] = int(profile["inventory"][id])
	state = "result" if data.get("state") == "result" else "town"
	run = data.get("run", {}).duplicate(true) if state == "result" else {}
	result = data.get("result", {}).duplicate(true) if state == "result" else {}
	# Interrupted battles return safely to town without reward; run serial is kept.
	return true

static func reject(message: String) -> Dictionary:
	return {"ok": false, "message": message}
