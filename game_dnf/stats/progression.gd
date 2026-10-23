extends RefCounted
## Reward sources call this once with a stable transaction ID; no dungeon dependency.
static func need(level: int, config: Dictionary) -> int:
	if level >= int(config["level_cap"]):return 0
	var rows: Array = config["xp_per_level"]
	return maxi(1, int(rows[level - 1]) if level > 0 and level <= rows.size() else level * int(config["xp_fallback_per_level"]))

static func grant(profile: Dictionary, amount: int, transaction: String, config: Dictionary) -> Dictionary:
	if amount < 0 or transaction.is_empty():return {"ok":false,"message":"经验数量或奖励标识无效"}
	if profile["xp_transactions"].has(transaction):return {"ok":false,"message":"该经验奖励已领取"}
	profile["xp_transactions"][transaction] = true
	var before := int(profile["level"])
	profile["xp"] += amount
	while int(profile["level"]) < int(config["level_cap"]) and int(profile["xp"]) >= need(int(profile["level"]),config):
		profile["xp"] -= need(int(profile["level"]),config)
		profile["level"] += 1
	if int(profile["level"]) >= int(config["level_cap"]):profile["xp"] = 0
	return {"ok":true,"from":before,"level":profile["level"],"levels":int(profile["level"])-before,"amount":amount}

static func sp_total(profile: Dictionary, config: Dictionary) -> int:
	return int(config["sp_initial"]) + (int(profile["level"])-1)*int(config["sp_per_level"]) + int(profile.get("sp_bonus",0))
