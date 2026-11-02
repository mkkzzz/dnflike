#!/usr/bin/env python3
"""Build the offline level-60 PvE parity baseline.

The tool does not claim that the archived ``111Script.pvf`` backup is the
runtime-effective client. It freezes candidate scope, separates source/parse/
runtime/acceptance layers, and records every unresolved scope decision.

Outputs:
  game_dnf/data/target_60_manifest.json
  game_dnf/data/local_rules_spec.json
  game_dnf/data/target_60_parity.json
  docs/reports/ws1/2026-11/2026-11-02_60级单机一致基线.md
"""
from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import sys
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from compile_dnf_content import record as content_record
from dnf_pvf import first_values, open_library, resolve


ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / "game_dnf"
DATA = GAME / "data"
MANIFEST_PATH = DATA / "target_60_manifest.json"
RULES_PATH = DATA / "local_rules_spec.json"
PARITY_PATH = DATA / "target_60_parity.json"
REPORT_PATH = (
    ROOT
    / "docs/reports/ws1/2026-11/2026-11-02_60级单机一致基线.md"
)

LEVEL_CAP = 60
SKILL_TABLES = {
    "skill/swordmanskill.lst": "swordman",
    "skill/fighterskill.lst": "fighter",
    "skill/gunnerskill.lst": "gunner",
    "skill/mageskill.lst": "mage",
    "skill/priestskill.lst": "priest",
    "skill/thiefskill.lst": "thief",
    "skill/atgunnerskill.lst": "atgunner",
    "skill/atfighterskill.lst": "atfighter",
    "skill/atmageskill.lst": "atmage",
    "skill/demonicswordman.lst": "demonicswordman",
    "skill/creatormage.lst": "creatormage",
    "skill/autoskill.lst": "common",
}


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def dump_json(data: Any) -> str:
    return json.dumps(data, ensure_ascii=False, indent=1, sort_keys=True) + "\n"


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")


def level_values(value: Any) -> tuple[int | None, int | None]:
    if isinstance(value, (int, float)):
        return int(value), int(value)
    if isinstance(value, list) and value:
        low = int(value[0]) if isinstance(value[0], (int, float)) else None
        high = int(value[-1]) if isinstance(value[-1], (int, float)) else low
        return low, high
    return None, None


def classify_level(level: int | None) -> str:
    if level is None:
        return "unknown"
    return "target" if level <= LEVEL_CAP else "post_60"


def runtime_skill_paths(
    numbers: dict[str, Any],
    skill_catalog: dict[str, Any],
    combat: dict[str, Any],
) -> tuple[dict[str, str], dict[str, str]]:
    paths: dict[str, str] = {}
    for local_id, spec in (numbers.get("skills") or {}).items():
        path = str(spec.get("path", "")).lower()
        if path:
            paths[path] = str(local_id)
    for move_id, move in (combat.get("moves") or {}).items():
        path = str(move.get("skill", "")).lower()
        if path:
            paths.setdefault(path, str(move_id))
    mapped: dict[str, str] = {}
    for row in skill_catalog.get("skills") or []:
        path = str(row.get("path", "")).lower()
        runtime = row.get("local_id") or row.get("implemented")
        if path and runtime:
            mapped[path] = str(runtime)
    return paths, mapped


def character_entries(
    lib,
    numbers: dict[str, Any],
) -> tuple[list[dict[str, Any]], dict[str, int]]:
    entries: list[dict[str, Any]] = []
    runtime_base = "character/swordman/swordman.chr"
    for character_id, relative in sorted(lib.listing("character/character.lst").items()):
        path = resolve("character/character.lst", str(relative))
        runtime = path == runtime_base
        entries.append(
            {
                "id": int(character_id),
                "path": path,
                "exists": lib.exists(path),
                "state": "runtime" if runtime else "parsed",
                "scope": "scope_decision_required",
            }
        )
    summary = {
        "source": len(entries),
        "target": len(entries),
        "post_60": 0,
        "unknown_scope": len(entries),
        "runtime": sum(row["state"] == "runtime" for row in entries),
        "accepted": 0,
        "runtime_growtypes": len(numbers.get("growtypes") or {}),
    }
    return entries, summary


def skill_entries(
    lib,
    runtime_paths: dict[str, str],
    mapped_paths: dict[str, str],
) -> tuple[list[dict[str, Any]], dict[str, int], Counter]:
    target: list[dict[str, Any]] = []
    classes: Counter = Counter()
    indexed_paths: set[str] = set()
    post_60 = 0
    unknown = 0
    unresolved = 0
    for table, class_name in SKILL_TABLES.items():
        listing = lib.listing(table)
        for skill_id, relative in sorted(listing.items()):
            path = resolve(table, str(relative))
            indexed_paths.add(path)
            source = content_record(lib, path, "skl")
            if source is None:
                unresolved += 1
                continue
            decoded = source.get("decoded") or {}
            level = decoded.get("required_level")
            level = int(level) if isinstance(level, (int, float)) else None
            state = classify_level(level)
            if state == "post_60":
                post_60 += 1
                continue
            if state == "unknown":
                unknown += 1
                continue
            classes[class_name] += 1
            runtime_id = runtime_paths.get(path, "")
            mapped_id = mapped_paths.get(path, "")
            row_state = "runtime" if runtime_id else "mapped" if mapped_id else "parsed"
            target.append(
                {
                    "id": int(skill_id),
                    "path": path,
                    "class": class_name,
                    "required_level": level,
                    "max_level": decoded.get("max_level"),
                    "type": (decoded.get("type") or [""])[0],
                    "state": row_state,
                    "runtime_id": runtime_id or mapped_id,
                }
            )
    target.sort(key=lambda row: (row["class"], row["id"], row["path"]))
    summary = {
        "source": sum(len(lib.listing(table)) for table in SKILL_TABLES),
        "target": len(target),
        "post_60": post_60,
        "unknown_level": unknown,
        "runtime": sum(row["state"] == "runtime" for row in target),
        "mapped_not_runtime": sum(row["state"] == "mapped" for row in target),
        "source_linked_runtime": sum(
            path in indexed_paths for path in runtime_paths if path
        ),
        "runtime_without_source": sum(
            path not in indexed_paths for path in runtime_paths if path
        ),
        "orphan_runtime_paths": sorted(
            path for path in runtime_paths if path and path not in indexed_paths
        ),
        "accepted": 0,
        "unresolved": unresolved,
        "by_class": dict(sorted(classes.items())),
    }
    return target, summary, classes


def dungeon_entries(
    lib,
    current_dungeons: dict[str, Any],
) -> tuple[list[dict[str, Any]], dict[str, int]]:
    current_by_path: dict[str, str] = {}
    current_by_sha: dict[str, str] = {}
    for runtime_id, spec in (current_dungeons.get("dungeons") or {}).items():
        if spec.get("legacy"):
            continue
        source = spec.get("source") or {}
        path = str(source.get("path", "")).lower()
        sha = str(source.get("sha256", "")).lower()
        if path:
            current_by_path[path] = str(runtime_id)
        if sha:
            current_by_sha[sha] = str(runtime_id)
        export = str(spec.get("map_export", ""))
        if export.startswith("res://"):
            export_path = GAME / export.removeprefix("res://")
            if export_path.is_file():
                exported = load_json(export_path)
                dungeon = exported.get("dungeon") or {}
                export_path_value = str(dungeon.get("path", "")).lower()
                export_sha = str(dungeon.get("sha256", "")).lower()
                if export_path_value:
                    current_by_path[export_path_value] = str(runtime_id)
                if export_sha:
                    current_by_sha[export_sha] = str(runtime_id)

    target: list[dict[str, Any]] = []
    post_60 = 0
    unknown = 0
    unresolved = 0
    runtime_post_60 = 0
    for dungeon_id, relative in sorted(lib.listing("dungeon/dungeon.lst").items()):
        path = resolve("dungeon/dungeon.lst", str(relative))
        source = lib.script(path, "dgn")
        if source is None:
            unresolved += 1
            continue
        fields = source.get("fields") or []
        minimum = first_values(fields, "[minimum required level]")
        basis = first_values(fields, "[basis level]")
        size = first_values(fields, "[size]") or []
        level = int(minimum[0]) if minimum and isinstance(minimum[0], (int, float)) else None
        state = classify_level(level)
        if state == "post_60":
            post_60 += 1
            runtime_id = current_by_path.get(path, "") or current_by_sha.get(
                str(source.get("sha256", "")).lower(), ""
            )
            if runtime_id:
                runtime_post_60 += 1
            continue
        if state == "unknown":
            unknown += 1
            continue
        runtime_id = current_by_path.get(path, "") or current_by_sha.get(
            str(source.get("sha256", "")).lower(), ""
        )
        target.append(
            {
                "id": int(dungeon_id),
                "path": path,
                "min_level": level,
                "basis_level": basis[0] if basis else None,
                "grid": size,
                "sha256": source.get("sha256"),
                "state": "runtime" if runtime_id else "parsed",
                "runtime_id": runtime_id,
            }
        )
    target.sort(key=lambda row: (row["min_level"] is None, row["min_level"] or 0, row["id"]))
    summary = {
        "source": len(lib.listing("dungeon/dungeon.lst")),
        "target": len(target),
        "post_60": post_60,
        "unknown_level": unknown,
        "runtime": sum(row["state"] == "runtime" for row in target),
        "runtime_post_60": runtime_post_60,
        "accepted": 0,
        "unresolved": unresolved,
    }
    return target, summary


def quest_entries(
    quest_catalog: dict[str, Any],
    runtime_rows: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], dict[str, int]]:
    runtime_paths = {
        str(q.get("source", {}).get("path", "")).lower()
        for q in runtime_rows
        if q.get("source", {}).get("path")
    }
    target: list[dict[str, Any]] = []
    post_60 = 0
    unknown = 0
    grades: Counter = Counter()
    types: Counter = Counter()
    for row in quest_catalog.get("quests") or []:
        level = row.get("level_min")
        level = int(level) if isinstance(level, (int, float)) else None
        state = classify_level(level)
        if state == "post_60":
            post_60 += 1
            continue
        if state == "unknown":
            unknown += 1
            continue
        source_path = str(row.get("path", "")).lower()
        runtime = bool(row.get("implemented")) or source_path in runtime_paths
        grade = str(row.get("grade", ""))
        quest_type = str(row.get("type", ""))
        grades[grade] += 1
        types[quest_type] += 1
        target.append(
            {
                "id": row.get("local_id") or row.get("path"),
                "path": row.get("path"),
                "level_min": level,
                "level_max": row.get("level_max"),
                "grade": grade,
                "type": quest_type,
                "state": "runtime" if runtime else "parsed",
                "runtime_id": row.get("local_id") or "",
            }
        )
    target.sort(key=lambda row: (row["level_min"] is None, row["level_min"] or 0, str(row["id"])))
    summary = {
        "source": int((quest_catalog.get("summary") or {}).get("total", 0)),
        "target": len(target),
        "post_60": post_60,
        "unknown_level": unknown,
        "runtime": sum(row["state"] == "runtime" for row in target),
        "accepted": 0,
        "by_grade": dict(sorted(grades.items())),
        "by_type": dict(sorted(types.items())),
    }
    return target, summary


def item_summary(
    lib,
    item_catalog: dict[str, Any],
    runtime_items: dict[str, Any],
    native_runtime: dict[str, Any],
) -> dict[str, Any]:
    path_to_id: dict[str, int] = {}
    for table in ("equipment/equipment.lst", "stackable/stackable.lst"):
        for item_id, relative in lib.listing(table).items():
            path_to_id[resolve(table, str(relative)).lower()] = int(item_id)

    runtime_ids: set[int] = set()
    for row in (runtime_items.get("items") or {}).values():
        source_id = (row.get("source") or {}).get("id")
        if isinstance(source_id, int):
            runtime_ids.add(source_id)
    for row in (native_runtime.get("items") or {}).values():
        source_id = (row.get("source") or {}).get("id")
        if isinstance(source_id, int):
            runtime_ids.add(source_id)

    target = 0
    unknown = 0
    post_60 = 0
    runtime_target = 0
    runtime_post_60 = 0
    runtime_indexed_target = 0
    by_kind: Counter = Counter()
    by_kind_target: Counter = Counter()
    missing_id = 0
    for row in item_catalog.get("items") or []:
        path = str(row.get("path", "")).lower()
        item_id = path_to_id.get(path)
        if item_id is None:
            missing_id += 1
        level = row.get("level")
        level = int(level) if isinstance(level, (int, float)) else None
        state = classify_level(level)
        kind = str(row.get("kind", ""))
        by_kind[kind] += 1
        if state == "post_60":
            post_60 += 1
            continue
        if state == "unknown":
            unknown += 1
            continue
        target += 1
        by_kind_target[kind] += 1
        if item_id in runtime_ids:
            runtime_indexed_target += 1

    for row in (native_runtime.get("items") or {}).values():
        level = row.get("level")
        level = int(level) if isinstance(level, (int, float)) else None
        if level is None:
            continue
        if level <= LEVEL_CAP:
            runtime_target += 1
        else:
            runtime_post_60 += 1

    return {
        "source": int((item_catalog.get("summary") or {}).get("total", 0)),
        "target": target,
        "post_60": post_60,
        "unknown_level": unknown,
        "runtime": runtime_target,
        "runtime_post_60": runtime_post_60,
        "runtime_indexed_target": runtime_indexed_target,
        "runtime_unindexed_target": max(0, runtime_target - runtime_indexed_target),
        "accepted": 0,
        "missing_source_id": missing_id,
        "by_kind": dict(sorted(by_kind.items())),
        "target_by_kind": dict(sorted(by_kind_target.items())),
    }


def monster_entries(
    monster_catalog: dict[str, Any],
    combat: dict[str, Any],
) -> tuple[list[dict[str, Any]], dict[str, int]]:
    runtime_by_path = {
        str(spec.get("mob", "")).lower(): str(bank)
        for bank, spec in (combat.get("monsters") or {}).items()
        if spec.get("mob")
    }
    target: list[dict[str, Any]] = []
    post_60 = 0
    unknown = 0
    runtime_post_60 = 0
    for row in (monster_catalog.get("monsters") or {}).values():
        low, high = level_values(row.get("level"))
        state = classify_level(low)
        if state == "post_60":
            post_60 += 1
            runtime_bank = runtime_by_path.get(str(row.get("path", "")).lower(), "")
            if runtime_bank:
                runtime_post_60 += 1
            continue
        if state == "unknown":
            unknown += 1
        path = str(row.get("path", "")).lower()
        runtime_bank = runtime_by_path.get(path, "")
        target.append(
            {
                "id": row.get("id"),
                "path": path,
                "level_min": low,
                "level_max": high,
                "state": "runtime" if runtime_bank else "parsed",
                "runtime_bank": runtime_bank,
            }
        )
    target.sort(key=lambda row: (row["level_min"] is None, row["level_min"] or 0, row["path"]))
    summary = {
        "source": len(monster_catalog.get("monsters") or {}),
        "target": len(target),
        "post_60": post_60,
        "unknown_level": unknown,
        "runtime": sum(row["state"] == "runtime" for row in target),
        "runtime_post_60": runtime_post_60,
        "accepted": 0,
    }
    return target, summary


def town_npc_summary(lib, towns: dict[str, Any]) -> dict[str, Any]:
    locations = towns.get("locations") or {}
    placed = {
        str(npc)
        for location in locations.values()
        for npc in (location.get("npcs") or {})
    }
    npc_index = len(lib.listing("npc/npc.lst"))
    return {
        "towns_source": lib.db.execute(
            "select count(*) from files where extension='.twn'"
        ).fetchone()[0],
        "towns_runtime": len(locations),
        "npc_index_source": npc_index,
        "npc_files_source": lib.db.execute(
            "select count(*) from files where extension='.npc'"
        ).fetchone()[0],
        "npc_runtime_placed": len(placed),
        "scope": "level_60_whitelist_required",
    }


def source_inventory(lib) -> dict[str, int]:
    values = {}
    for extension in (
        ".chr",
        ".skl",
        ".dgn",
        ".qst",
        ".mob",
        ".equ",
        ".stk",
        ".etc",
        ".twn",
        ".npc",
        ".ui",
        ".act",
        ".atk",
        ".ani",
    ):
        values[extension] = int(
            lib.db.execute(
                "select count(*) from files where extension=?", (extension,)
            ).fetchone()[0]
        )
    return values


def rule_spec(numbers: dict[str, Any], services: dict[str, Any],
              upgrades: dict[str, Any], loot: dict[str, Any],
              recovery: dict[str, Any]) -> dict[str, Any]:
    rules = [
        {
            "id": "scope.offline_single_player",
            "domain": "scope",
            "requirement": "离线单机运行，不启动联网服务端",
            "source": "user_decision",
            "current": "现有闭环为本地单机权威",
            "status": "implemented",
            "blocks_target": False,
            "next": "保持，不引入网络协议和账号登录",
        },
        {
            "id": "scope.no_updater",
            "domain": "scope",
            "requirement": "不做版本更新器、热更新和多版本兼容",
            "source": "user_decision",
            "current": "按一个固定内容基线维护",
            "status": "fixed_scope",
            "blocks_target": False,
            "next": "只冻结一次目标来源，不建更新链",
        },
        {
            "id": "scope.above_60_future",
            "domain": "scope",
            "requirement": "60 级以上内容保留为后续拓展，不删除、不要求隐藏",
            "source": "user_decision",
            "current": "超 60 内容继续保留在源库与运行库，仅不计入当前 60 内容分母",
            "status": "fixed_scope",
            "blocks_target": False,
            "next": "后续扩展开关或内容批次再逐项验收",
        },
        {
            "id": "scope.local_server_logic",
            "domain": "scope",
            "requirement": "原服务端负责的结算逻辑改为本地权威规则",
            "source": "user_decision",
            "current": "部分已有，部分仍为项目适配",
            "status": "partial",
            "blocks_target": True,
            "next": "按本清单逐项恢复经验、掉落、任务、商店、强化、修理与限制",
        },
        {
            "id": "scope.party_pvp_social",
            "domain": "scope",
            "requirement": "不含组队、玩家交易、邮件、公会、拍卖与 PVP",
            "source": "user_decision",
            "current": "队伍人数固定为 1，只有 NPC 出售/回购",
            "status": "excluded",
            "blocks_target": False,
            "next": "涉及多人条件的原条目单独列为排除或单机等价，不静默算完成",
        },
        {
            "id": "progression.level_cap",
            "domain": "progression",
            "requirement": "角色等级上限 60",
            "source": "E-ADAPT",
            "current": {"level_cap": numbers.get("progression", {}).get("level_cap")},
            "status": "implemented",
            "blocks_target": False,
            "next": "保留",
        },
        {
            "id": "progression.xp_curve",
            "domain": "progression",
            "requirement": "1～60 原版逐级经验曲线和服务端升级规则",
            "source": "server_logic_missing",
            "current": {
                "xp_per_level": numbers.get("progression", {}).get("xp_per_level"),
                "fallback": numbers.get("progression", {}).get("xp_fallback_per_level"),
            },
            "status": "adapted",
            "blocks_target": True,
            "next": "从原客户端表现/表结构与可复核行为恢复；不在本地继续猜固定 100 增量",
        },
        {
            "id": "progression.clear_reward",
            "domain": "progression",
            "requirement": "原版副本通关金币、经验、评价和奖励规则",
            "source": "server_logic_missing",
            "current": {
                "clear_xp": numbers.get("progression", {}).get("clear_xp"),
                "kill_xp": numbers.get("progression", {}).get("kill_xp"),
            },
            "status": "adapted",
            "blocks_target": True,
            "next": "与副本难度、怪物、评价和翻牌一起恢复",
        },
        {
            "id": "progression.fatigue",
            "domain": "progression",
            "requirement": "原版疲劳值、扣除、恢复和入场限制",
            "source": "server_logic_missing",
            "current": "未实现",
            "status": "missing",
            "blocks_target": True,
            "next": "先确认目标版本存在形式，再由本地 Run/Profile 服务执行",
        },
        {
            "id": "stats.attributes",
            "domain": "stats",
            "requirement": "原版职业成长、基础属性、装备/被动汇总顺序",
            "source": "partial_source",
            "current": numbers.get("formula"),
            "status": "adapted",
            "blocks_target": True,
            "next": "逐项替换公式常数和取整顺序，保留来源记录",
        },
        {
            "id": "stats.difficulty",
            "domain": "stats",
            "requirement": "难度基础倍率",
            "source": "E-PARSE",
            "current": (numbers.get("monsters") or {}).get("difficulty"),
            "status": "implemented",
            "blocks_target": False,
            "next": "用同条件战斗继续核验作用范围和叠算顺序",
        },
        {
            "id": "economy.loot",
            "domain": "economy",
            "requirement": "原版怪物/副本/任务掉率、地面归属和拾取限制",
            "source": "server_logic_missing",
            "current": {
                "enabled_dungeons": loot.get("enabled_dungeons"),
                "normal_entries": len(loot.get("normal") or []),
                "boss_entries": len(loot.get("boss") or []),
            },
            "status": "adapted",
            "blocks_target": True,
            "next": "先接怪物表已有掉落字段，再补服务端权重和数量规则",
        },
        {
            "id": "economy.card_reward",
            "domain": "economy",
            "requirement": "原版通关翻牌卡池和随机结果",
            "source": "server_logic_missing",
            "current": "翻牌固定显示并发放 1 个恢复药剂",
            "status": "adapted",
            "blocks_target": True,
            "next": "建立按副本/难度选择卡池的本地奖励表",
        },
        {
            "id": "economy.shop",
            "domain": "economy",
            "requirement": "NPC 商店库存、价格、回购和购买条件",
            "source": "server_logic_missing",
            "current": {
                "buyback_limit": services.get("buyback_limit"),
                "configured_items": len(services.get("items") or {}),
            },
            "status": "adapted",
            "blocks_target": True,
            "next": "从 NPC/任务/地图依赖形成目标商店清单",
        },
        {
            "id": "economy.repair_durability",
            "domain": "economy",
            "requirement": "原版耐久损耗、修理价格和零耐久规则",
            "source": "server_logic_missing",
            "current": {
                "durability_max": services.get("durability_max"),
                "wear": services.get("wear"),
            },
            "status": "adapted",
            "blocks_target": True,
            "next": "确认原版是否按攻击次数/受击/死亡损耗",
        },
        {
            "id": "economy.reinforce",
            "domain": "economy",
            "requirement": "原版强化等级、概率、费用、失败结果与属性",
            "source": "server_logic_missing",
            "current": {
                "steps": len((upgrades.get("reinforcement") or {}).get("steps") or []),
            },
            "status": "adapted",
            "blocks_target": True,
            "next": "替换项目 10 级试玩曲线",
        },
        {
            "id": "economy.enchant",
            "domain": "economy",
            "requirement": "原版附魔来源、部位限制、替换与清除",
            "source": "server_logic_missing",
            "current": {
                "recipes": len(upgrades.get("enchants") or {}),
            },
            "status": "adapted",
            "blocks_target": True,
            "next": "接原附魔宝珠/卡片/配方和失败结果",
        },
        {
            "id": "items.avatar",
            "domain": "items",
            "requirement": "原版时装、染色、徽章和纸娃娃外观",
            "source": "source_fields_present",
            "current": "未接入",
            "status": "missing",
            "blocks_target": True,
            "next": "按目标 60 白名单筛出 item_type 与时装槽",
        },
        {
            "id": "items.set_bonus",
            "domain": "items",
            "requirement": "套装件数、触发条件和属性加成",
            "source": "source_fields_present",
            "current": "运行框架可读简单 set，但原库 set item master 未迁入",
            "status": "partial",
            "blocks_target": True,
            "next": "先接装备 set 字段和阈值，再接技能/触发效果",
        },
        {
            "id": "items.recipe_package",
            "domain": "items",
            "requirement": "配方、制作、礼包、魔盒和开出结果",
            "source": "source_fields_present",
            "current": "未接入",
            "status": "missing",
            "blocks_target": True,
            "next": "以 item_type 和 input/output 字段为入口批次",
        },
        {
            "id": "quests.lifecycle",
            "domain": "quests",
            "requirement": "原版前置、职业条件、目标、奖励、重复/每日和历史",
            "source": "partial_source",
            "current": "120 条运行，周期框架已接但大量目标/职业依赖未启用",
            "status": "partial",
            "blocks_target": True,
            "next": "按目标类型与前置图批量补齐，不用少量章节代替全量",
        },
        {
            "id": "quests.job_change",
            "domain": "quests",
            "requirement": "原版转职任务、职业资格和技能点重置",
            "source": "source_present",
            "current": "18 级技能页简化转职",
            "status": "missing",
            "blocks_target": True,
            "next": "选一条职业链先贯通，再扩其余职业",
        },
        {
            "id": "save.transactions",
            "domain": "save",
            "requirement": "奖励、消费、掉落和任务状态单事务提交",
            "source": "local_design",
            "current": "候选快照、原子写盘和备份恢复已接",
            "status": "implemented",
            "blocks_target": False,
            "next": "新规则一律走现有事务入口，不新增旁路写档",
        },
        {
            "id": "combat.player_actions",
            "domain": "combat",
            "requirement": "目标职业完整基础动作、输入优先级、取消和武器差异",
            "source": "partial_source",
            "current": "鬼剑士基础子集已接，部分判定由特效范围补",
            "status": "partial",
            "blocks_target": True,
            "next": "以 1～18 样板先行补齐，再按等级段扩",
        },
        {
            "id": "combat.skills",
            "domain": "combat",
            "requirement": "目标职业技能的 SKL/ACT/ATK/ANI/被动物完整执行",
            "source": "partial_source",
            "current": "剑士 17 个运行时节点，其中 16 条有源路径、1 条为无源遗留；其他职业 0",
            "status": "partial",
            "blocks_target": True,
            "next": "以剑魂 1～60 为第一条完整技能线",
        },
        {
            "id": "combat.monster_ai",
            "domain": "combat",
            "requirement": "目标怪物选招、移动、阶段、召唤和特殊机制",
            "source": "partial_source",
            "current": "通用距离/冷却 AI，部分 BOSS 阶段为项目适配",
            "status": "partial",
            "blocks_target": True,
            "next": "区分无脚本引擎内置行为和有脚本可恢复行为",
        },
        {
            "id": "world.dungeon_routes",
            "domain": "world",
            "requirement": "目标地下城的房间生成、门、刷怪、机关和返回",
            "source": "partial_source",
            "current": "17 条 60 级内运行路线，另有 1 条 68/71 级隐藏测试床；共 117 房，随机迷宫未恢复",
            "status": "partial",
            "blocks_target": True,
            "next": "先用 DGN/地图依赖生成本地目标副本表，再恢复路线规则",
        },
        {
            "id": "ui.audio_presentation",
            "domain": "presentation",
            "requirement": "目标版本的完整 UI、字体、音效、动作和结算表现",
            "source": "partial_source",
            "current": "多项原图已接，但全屏幕/全事件矩阵未完成",
            "status": "partial",
            "blocks_target": True,
            "next": "以 pilot 等级段的同条件原版/Godot 对照收口",
        },
        {
            "id": "recovery.revive",
            "domain": "recovery",
            "requirement": "原版死亡恢复、复活币和返回城镇",
            "source": "source_present",
            "current": {
                "revival_limit": (recovery.get("revival") or {}).get("limit"),
                "coin_cost": (recovery.get("revival") or {}).get("coin_cost"),
            },
            "status": "partial",
            "blocks_target": True,
            "next": "补原版复活币来源、消耗和次数规则",
        },
    ]
    summary = Counter(row["status"] for row in rules)
    return {
        "schema": "dnf_local_rules_spec/1",
        "scope": {
            "goal": "offline_single_player_level_60_pve_parity",
            "level_cap": LEVEL_CAP,
            "above_level_60": "retained_future_extension",
            "server_process": "excluded",
            "network": "excluded",
            "updater": "excluded",
            "party_pvp_social": "excluded",
            "local_authority_required": True,
        },
        "status_meanings": {
            "implemented": "现有本地实现可承担目标范围",
            "partial": "有真实实现，但目标范围未闭合",
            "adapted": "当前使用项目适配值或规则，必须替换",
            "missing": "尚无实现",
            "excluded": "用户明确排除的非目标范围",
            "fixed_scope": "范围约束，不需要运行时实现",
        },
        "rules": rules,
        "summary": {
            "total": len(rules),
            "by_status": dict(sorted(summary.items())),
            "blocking": sum(bool(row["blocks_target"]) for row in rules),
        },
    }


def build_baseline(library: Path | None = None) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    lib = open_library(library)
    try:
        numbers = load_json(DATA / "numbers.json")
        skill_catalog = load_json(DATA / "skill_catalog.json")
        combat = load_json(DATA / "combat.json")
        current_dungeons = load_json(DATA / "dungeons.json")
        quest_catalog = load_json(DATA / "quest_catalog.json")
        item_catalog = load_json(DATA / "item_catalog.json")
        monster_catalog = load_json(DATA / "monster_catalog.json")
        towns = load_json(DATA / "towns.json")
        runtime_items = load_json(DATA / "runtime_items.json")
        native_runtime = load_json(DATA / "native_runtime.json")
        services = load_json(DATA / "services.json")
        upgrades = load_json(DATA / "upgrades.json")
        loot = load_json(DATA / "loot.json")
        recovery = load_json(DATA / "recovery.json")
        source_materials = load_json(GAME / "source_materials.json")
        runtime_quests = _merged_runtime_quests()

        chars, char_summary = character_entries(lib, numbers)
        runtime_paths, mapped_paths = runtime_skill_paths(
            numbers, skill_catalog, combat
        )
        skills, skill_summary, _ = skill_entries(lib, runtime_paths, mapped_paths)
        skill_summary["legacy_runtime_without_path"] = sum(
            1 for spec in (numbers.get("skills") or {}).values() if not spec.get("path")
        )
        dungeons, dungeon_summary = dungeon_entries(lib, current_dungeons)
        quests, quest_summary = quest_entries(quest_catalog, runtime_quests)
        items = item_summary(lib, item_catalog, runtime_items, native_runtime)
        monsters, monster_summary = monster_entries(monster_catalog, combat)
        towns_npcs = town_npc_summary(lib, towns)
        source_pvf = next(
            (
                row
                for row in source_materials.get("existing_library_materials", [])
                if row.get("original_path") == "adjacent_backup/111Script.pvf"
            ),
            {},
        )
        decisions = [
            {
                "id": "source_baseline",
                "question": "是否把 111Script.pvf 备份固定为本项目目标来源？",
                "current_default": "暂以 111 备份建立候选基线",
                "impact": "决定 CHR/SKL/DGN/QST/物品目标和后续同条件对照的参照",
                "status": "pending_user",
            },
            {
                "id": "class_roster",
                "question": "目标 60 版本包含哪些基础职业和特殊 CHR（含 Thief、AT*、Creator、DemonicSwordman 吗）？",
                "current_default": "全部 {} 个 CHR 先列为候选，只有 swordman 计运行".format(
                    char_summary["source"]
                ),
                "impact": "直接决定技能、转职、装备限制和任务分母",
                "status": "pending_user",
            },
            {
                "id": "party_only_content",
                "question": "原版要求组队的任务/副本，是排除还是改写为单机等价？",
                "current_default": "记为排除或待适配，不静默计入完成",
                "impact": "影响全内容白名单和任务可达性",
                "status": "pending_user",
            },
            {
                "id": "unknown_item_levels",
                "question": "{} 件无等级物品需要按索引/任务/商店依赖继续分类".format(
                    items["unknown_level"]
                ),
                "current_default": "保持 unknown，不进入目标完成分子",
                "impact": "决定物品白名单最终分母",
                "status": "technical_task",
            },
        ]
        manifest = {
            "schema": "dnf_60_target_manifest/1",
            "scope": {
                "goal": "offline_single_player_level_60_pve_parity",
                "level_cap": LEVEL_CAP,
                "above_level_60": "retained_future_extension",
                "server_process": "excluded",
                "network": "excluded",
                "updater": "excluded",
                "party_pvp_social": "excluded",
            },
            "source": {
                "config_role": "111Script.pvf backup in the shared library; runtime-effective PVF unconfirmed",
                "pvf_sha256": source_pvf.get("sha256", ""),
                "asset_version": lib.asset_version,
                "provisional": True,
            },
            "candidate_rules": {
                "known_level": "level <= 60 进入当前内容候选；>60 保留为后续拓展",
                "unknown_level": "保留为 unknown，不进入已完成分子",
                "runtime": "有当前运行定义，不代表规则已完全一致",
                "accepted": "必须有用户实机同条件验收记录",
            },
            "summary": {
                "characters": char_summary,
                "skills": skill_summary,
                "dungeons": dungeon_summary,
                "quests": quest_summary,
                "items": items,
                "monsters": monster_summary,
                "towns_npcs": towns_npcs,
            },
            "source_inventory": source_inventory(lib),
            "entries": {
                "characters": chars,
                "skills": skills,
                "dungeons": dungeons,
                "quests": quests,
                "monsters": monsters,
            },
            "decisions": decisions,
        }
        rules = rule_spec(numbers, services, upgrades, loot, recovery)
        parity = build_parity(manifest, rules)
        return manifest, rules, parity
    finally:
        lib.close()


def _merged_runtime_quests() -> list[dict[str, Any]]:
    merged: dict[str, dict[str, Any]] = {}
    for relative in (
        "quests.json",
        "native_runtime.json",
        "native_quest_rules_v2.json",
    ):
        path = DATA / relative
        if not path.is_file():
            continue
        for row in load_json(path).get("quests") or []:
            quest_id = str(row.get("id", ""))
            if quest_id:
                merged[quest_id] = row
    return [merged[key] for key in sorted(merged)]


def build_parity(
    manifest: dict[str, Any], rules: dict[str, Any]
) -> dict[str, Any]:
    categories: dict[str, Any] = {}
    for key in ("characters", "skills", "dungeons", "quests", "items", "monsters"):
        summary = manifest["summary"][key]
        target = int(summary.get("target", 0))
        runtime = int(summary.get("runtime", 0))
        mapped = int(summary.get("mapped_not_runtime", 0))
        unresolved = int(summary.get("unresolved", 0))
        categories[key] = {
            "target_candidates": target,
            "runtime": runtime,
            "mapped_not_runtime": mapped,
            "parsed_not_runtime": max(0, target - runtime - mapped - unresolved),
            "unresolved": unresolved,
            "accepted": int(summary.get("accepted", 0)),
            "above_60_future": int(summary.get("post_60", 0)),
            "runtime_post_60_excluded": int(summary.get("runtime_post_60", 0)),
            "unknown_level": int(summary.get("unknown_level", 0)),
        }
    categories["towns_npcs"] = manifest["summary"]["towns_npcs"]
    return {
        "schema": "dnf_60_parity_matrix/1",
        "policy": {
            "aggregate_percentage": False,
            "reason": "目标候选、运行定义、规则一致和用户验收分母不同",
        },
        "source_baseline": manifest["source"],
        "categories": categories,
        "rules": rules["summary"],
        "decisions": manifest["decisions"],
    }


def render_report(
    manifest: dict[str, Any],
    rules: dict[str, Any],
    parity: dict[str, Any],
) -> str:
    lines = [
        "# 60 级单机一致基线",
        "",
        "> 本文件由 `python tools/build_dnf_60_baseline.py --write` 生成。",
        "> 目标是离线单机 60 级 PVE 内容与表现一致；不做更新器、联网服务端、组队/交易/邮件/公会/拍卖/PVP。",
        "> 当前来源仍为 111 备份候选，不声明已锁定实际客户端版本。",
        "",
        "## 一、目标范围",
        "",
        "| 约束 | 当前基线 |",
        "|---|---|",
        "| 等级上限 | 60 |",
        "| 60 级以上内容 | 保留为后续拓展，不计入当前 60 内容分母 |",
        "| 服务端进程 | 不实现；服务端规则本地化 |",
        "| 更新器/热更新 | 不实现 |",
        "| 社交/PVP | 不实现；多人条件内容单列 |",
        "| 完成定义 | 目标内容可运行，并完成原版同条件对照与用户验收 |",
        "",
        "## 二、内容候选快照",
        "",
        "| 类别 | 当前 60 内容候选 | 已解析未运行 | 当前运行 | 已验收 | 60 级以上后续 | 等级未知 |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    labels = {
        "characters": "职业/CHR",
        "skills": "技能 SKL",
        "dungeons": "地下城 DGN",
        "quests": "任务 QST",
        "items": "物品 EQU/STK/ETC",
        "monsters": "怪物 MOB",
    }
    for key, label in labels.items():
        row = parity["categories"][key]
        lines.append(
            "| {label} | {target_candidates} | {parsed_not_runtime} | {runtime} | "
            "{accepted} | {above_60_future} | {unknown_level} |".format(
                label=label, **row
            )
        )
    towns = manifest["summary"]["towns_npcs"]
    lines.append(
        "| 城镇 / NPC | 16 / 161 索引 | — | {} / {} | 0 | — | 目标白名单待定 |".format(
            towns["towns_runtime"], towns["npc_runtime_placed"]
        )
    )
    skill_summary = manifest["summary"]["skills"]
    item_summary_data = manifest["summary"]["items"]
    dungeon_summary = manifest["summary"]["dungeons"]
    lines.extend(
        [
            "",
            "“当前运行”只表示存在运行定义或映射，不表示技能、任务或物品规则已经与原版完全一致。",
            "",
            "- 技能：{} 条有源文件的运行技能；{} 条运行技能没有对应源路径，未计入目标分子。".format(
                skill_summary.get("source_linked_runtime", 0),
                skill_summary.get("runtime_without_source", 0),
            ),
            "- 另有 {} 条项目遗留技能没有源路径，同样不计入原版技能覆盖。".format(
                skill_summary.get("legacy_runtime_without_path", 0)
            ),
            "- 物品：运行库中有 {} 件 60 级以上装备，保留为后续拓展，不计入当前 60 内容分子；{} 件原物品等级未知，同样不计入已完成分子。".format(
                item_summary_data.get("runtime_post_60", 0),
                item_summary_data.get("unknown_level", 0),
            ),
            "- 地下城：{} 条当前运行路线属于 60 级以上拓展；其中隐藏阿登源数据最低 68、基准 71，现有 58 级标注不能作为原版事实，但内容本身保留。".format(
                dungeon_summary.get("runtime_post_60", 0)
            ),
            "",
            "## 三、本地规则缺口",
            "",
            "| 规则 | 当前状态 | 是否阻塞 | 下一步 |",
            "|---|---|---|---|",
        ]
    )
    for rule in rules["rules"]:
        if not rule["blocks_target"] and rule["status"] in ("fixed_scope", "excluded"):
            continue
        lines.append(
            "| `{}` | {} | {} | {} |".format(
                rule["id"],
                rule["status"],
                "是" if rule["blocks_target"] else "否",
                str(rule["next"]).replace("|", "/"),
            )
        )
    lines.extend(
        [
            "",
            "## 四、待决策",
            "",
            "| ID | 问题 | 当前默认 | 影响 |",
            "|---|---|---|---|",
        ]
    )
    for decision in manifest["decisions"]:
        lines.append(
            "| `{}` | {} | {} | {} |".format(
                decision["id"],
                decision["question"].replace("|", "/"),
                decision["current_default"].replace("|", "/"),
                decision["impact"].replace("|", "/"),
            )
        )
    lines.extend(
        [
            "",
            "## 五、执行与复跑",
            "",
            "```powershell",
            "python tools/build_dnf_60_baseline.py --write",
            "python tools/build_dnf_60_baseline.py --check",
            "python -m unittest tools.test_build_dnf_60_baseline -v",
            "```",
            "",
            "机器产物：`game_dnf/data/target_60_manifest.json`、`game_dnf/data/local_rules_spec.json`、`game_dnf/data/target_60_parity.json`。",
            "",
            "## 六、下一步",
            "",
            "1. 先确认目标来源和职业范围，冻结目标分母。",
            "2. 以鬼剑士→剑魂为第一条 1～60 完整样板。",
            "3. 每个等级段同时完成内容、规则、表现和同条件验收，再扩其它职业。",
            "",
        ]
    )
    return "\n".join(lines)


def outputs(library: Path | None = None) -> dict[Path, str]:
    manifest, rules, parity = build_baseline(library)
    report = render_report(manifest, rules, parity)
    return {
        MANIFEST_PATH: dump_json(manifest),
        RULES_PATH: dump_json(rules),
        PARITY_PATH: dump_json(parity),
        REPORT_PATH: report,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--library", type=Path)
    parser.add_argument("--write", action="store_true", help="write versioned baseline files")
    parser.add_argument("--check", action="store_true", help="fail if dated outputs are stale")
    args = parser.parse_args(argv)
    if args.write and args.check:
        parser.error("--write and --check are mutually exclusive")
    generated = outputs(args.library)
    if args.write:
        for path, text in generated.items():
            write_text(path, text)
            print(f"written {path.relative_to(ROOT)}")
        return 0
    if args.check:
        stale = []
        for path, text in generated.items():
            actual = path.read_text(encoding="utf-8") if path.is_file() else ""
            if actual != text:
                stale.append(str(path.relative_to(ROOT)))
        if stale:
            print("stale: " + ", ".join(stale))
            return 1
        print("baseline outputs are current")
        return 0
    manifest, rules, parity = build_baseline(args.library)
    print("target candidates:")
    for key in ("characters", "skills", "dungeons", "quests", "items", "monsters"):
        summary = manifest["summary"][key]
        print(
            f"  {key}: target={summary.get('target')} runtime={summary.get('runtime')} "
            f"above_60_future={summary.get('post_60')} unknown={summary.get('unknown_level')}"
        )
    print("rules: " + json.dumps(rules["summary"], ensure_ascii=False, sort_keys=True))
    print("parity categories: " + str(len(parity["categories"])))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
