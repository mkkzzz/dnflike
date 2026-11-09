extends RefCounted
## Ordinary Father/Pope state 13 and its separate OBJ48024 stage.
const CAST_STATE := "native_zealot_cast"
const CASTERS := ["monster/zealot/bossfather.mob","monster/zealot/bosspope.mob"]
const SPECIAL_POLL_MS := 333
const MAX_USES := 3
const OWNED_LIMIT := 2
const CAST_RECOVERY_ADD := 100.0
const CAST_DEFENSE_FACTOR := 10.0
var proxies: Array[Dictionary] = []

static func poll_due(enemy: Dictionary, ms: float) -> bool:
	var age := float(enemy.get("native_special_age_ms",0.0))+ms
	enemy["native_special_age_ms"] = age
	if int(age)-int(enemy.get("native_special_last_ms",0)) <= SPECIAL_POLL_MS:return false
	enemy["native_special_last_ms"] = int(age)
	return true

static func choose(game, enemy: Dictionary, has_target: bool) -> bool:
	if enemy["state"] != "idle" or not has_target or int(enemy.get("native_summon_uses",0)) >= MAX_USES:return false
	# DBD300 rolls before checking the room's current owned monsters.
	if game.rng.range_int(0,0x7fffffff)%300 >= 20:return false
	var owned := 0
	for child: Dictionary in game.monsters:
		if child.get("summon_owner",-1) == enemy["id"] and game.enemy_registered(child):
			owned += 1
			if owned >= OWNED_LIMIT:return false
	return true

static func start(game, enemy: Dictionary) -> void:
	var summon: Dictionary = enemy["def"]["native_spirit_summon"]
	var numeric = enemy.get("numeric")
	enemy["native_cast_rate"] = float(numeric.values["cast_speed"]) if numeric != null else float(summon["cast_rate"])
	enemy["state"] = CAST_STATE
	enemy["clock"] = 0.0
	game.play_sound(summon["cast_sound"])
	game.bus.emit("combat.zealot_cast_started",{"caster":enemy["id"],"mob":summon["mob"]})

func finish_cast(game, enemy: Dictionary) -> void:
	var summon: Dictionary = enemy["def"]["native_spirit_summon"]
	if float(enemy["clock"]) < float(summon["cast_duration_ms"]):return
	enemy["state"] = "idle"
	enemy["clock"] = 0.0
	enemy["native_summon_uses"] = int(enemy.get("native_summon_uses",0))+1
	var level: int = int(enemy["numeric"].values["level"]) if enemy.has("numeric") else int(enemy["def"]["level"])
	var proxy := {"id":game._next_entity_id,"owner":enemy,"level":level,"source":summon,
		"pos":Vector2(Vector2i(enemy["pos"])),"facing":enemy["facing"],"clock":0.0}
	game._next_entity_id += 1
	proxies.append(proxy)
	game.bus.emit("combat.zealot_summon_proxy",{"entity_id":proxy["id"],"caster":enemy["id"],
		"object_index":48024,"extra":summon["extra"],"level":level,"position":proxy["pos"]})

func step(game, ms: float, first_new_id: int) -> void:
	if proxies.is_empty():return
	var remaining: Array[Dictionary] = []
	for proxy: Dictionary in proxies:
		var summon: Dictionary = proxy["source"]
		var owner: Dictionary = proxy["owner"]
		if owner not in game.monsters or not game.enemy_registered(owner):continue
		if int(proxy["id"]) < first_new_id:proxy["clock"] = float(proxy["clock"])+ms
		if float(proxy["clock"]) < float(summon["proxy_duration_ms"]):
			remaining.append(proxy)
			continue
		var kind: String = game.table.monster_by_mob(summon["mob"])
		var child: Dictionary = game.spawn_enemy(proxy["pos"],false,kind,{"summon_owner":owner["id"],
			"level":proxy["level"],"z":summon["birth_z"],"facing":proxy["facing"]})
		game.bus.emit("combat.zealot_spirit_spawned",{"entity_id":child["id"],"caster":owner["id"],
			"mob":summon["mob"],"position":child["pos"],"height":child["z"]})
	proxies = remaining

func view_objects() -> Array:
	var visible: Array = []
	for proxy: Dictionary in proxies:
		visible.append({"id":proxy["id"],"effect":proxy["source"]["proxy_bank"],"pos":proxy["pos"],"z":0.0,
			"facing":proxy["facing"],"clock":proxy["clock"],"loop":false})
	return visible
