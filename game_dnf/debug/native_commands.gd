extends RefCounted
## Read-only access to the complete migrated original database from the GM panel.
const Native = preload("res://content/api/native_catalog.gd")

static func execute(args: PackedStringArray) -> Dictionary:
	if args.is_empty():
		var runtime := Native.runtime()
		var counts: Dictionary = Native.index().get("indexes",{})
		var quests: Dictionary=Native.quest_rules().get("coverage",{})
		return {"ok":true,"message":"原库：任务 %d，装备 %d，堆叠物品 %d\n首批运行快照：%s\n当前原任务可执行 %d，参数可解析 %d（不等于已启用）\nnative find equipment|stackable|quests 关键词\nnative equipment|stackable|quests 原ID" % [counts.get("quests",{}).size(),counts.get("equipment",{}).size(),counts.get("stackable",{}).size(),JSON.stringify(runtime.get("coverage",{})),int(quests.get("total_executable",0)),int(quests.get("objective_parsed",0))]}
	if args[0] == "find" and args.size() >= 3:
		var rows := Native.search(" ".join(args.slice(2)),args[1],10)
		var lines: PackedStringArray = []
		for row: Dictionary in rows:lines.append("%s · %s" % [row["name"],row["path"]])
		return {"ok":true,"message":"\n".join(lines) if not lines.is_empty() else "没有匹配记录"}
	if args.size() == 2 and args[0] in ["equipment","stackable","quests"] and args[1].is_valid_int():
		var row := Native.original(args[0],int(args[1]))
		if row.is_empty():return {"ok":false,"message":"原ID不存在"}
		var text: Dictionary = row.get("text",{})
		var current: Dictionary=Native.quest_execution(int(args[1])) if args[0]=="quests" else row.get("execution",{})
		return {"ok":true,"message":"%s\n%s\n%s\n迁移状态：%s；当前编译状态：%s" % [text.get("[name]","源名称待修复"),row["path"],String(text.get("[condition message]",text.get("[explain]",""))).left(600),row.get("parse_status",""),JSON.stringify(current)]}
	return {"ok":false,"message":"用法：native；native find equipment|stackable|quests 关键词；native equipment|stackable|quests 原ID"}
