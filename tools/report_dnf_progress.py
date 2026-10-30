#!/usr/bin/env python3
"""Generate a reproducible engineering-progress snapshot for game_dnf.

The report deliberately avoids a single aggregate completion percentage.
Source migration, runtime availability, functional support, and acceptance
cover different denominators and must remain separate.

Examples:
  python tools/report_dnf_progress.py
  python tools/report_dnf_progress.py --write docs/reports/ws1/2026-10/2026-10-30_工程完成度数据.md
  python tools/report_dnf_progress.py --json docs/reports/ws1/2026-10/2026-10-30_工程完成度数据.json
"""
from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / "game_dnf"
QUEST_COVERAGE = (
    ROOT
    / "docs/reports/ws2/2026-10/2026-10-29_通用原任务规则覆盖.json"
)

LEVEL_BANDS = (
    ("1-16", 1, 16),
    ("17-30", 17, 30),
    ("31-45", 31, 45),
    ("46-57", 46, 57),
    ("58-60", 58, 60),
)


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def percentage(done: int, total: int) -> float:
    return round(done * 100.0 / total, 2) if total else 0.0


def count_value(value: Any) -> int:
    if isinstance(value, (list, dict)):
        return len(value)
    if isinstance(value, (int, float)):
        return int(value)
    return 0


def level_band(level: int) -> str:
    for label, low, high in LEVEL_BANDS:
        if low <= level <= high:
            return label
    return "范围外"


def runtime_quests(game: Path) -> list[dict[str, Any]]:
    entries: dict[str, dict[str, Any]] = {}
    for relative in (
        "data/quests.json",
        "data/native_runtime.json",
        "data/native_quest_rules_v2.json",
    ):
        for quest in load_json(game / relative).get("quests", []):
            quest_id = str(quest.get("id", ""))
            if quest_id and not quest_id.startswith("legacy."):
                entries[quest_id] = quest
    return [entries[key] for key in sorted(entries)]


def collect_snapshot(root: Path = ROOT) -> dict[str, Any]:
    game = root / "game_dnf"
    dungeon_doc = load_json(game / "data/dungeons.json")["dungeons"]
    towns_doc = load_json(game / "data/towns.json")
    combat = load_json(game / "data/combat.json")
    monster_catalog = load_json(game / "data/monster_catalog.json")
    boss_rules = load_json(game / "data/boss_rules.json")
    quest_catalog = load_json(game / "data/quest_catalog.json")
    quest_rules = load_json(game / "data/native_quest_rules_v2.json")
    native_runtime = load_json(game / "data/native_runtime.json")
    native_manifest = load_json(
        game / "assets_local/native_data_v1/manifest.json"
    )
    skill_catalog = load_json(game / "data/skill_catalog.json")
    numbers = load_json(game / "data/numbers.json")

    playable = {
        name: spec
        for name, spec in dungeon_doc.items()
        if not spec.get("legacy")
    }
    hidden = {
        name: spec for name, spec in playable.items() if spec.get("hidden")
    }
    selectable = {
        name: spec for name, spec in playable.items() if not spec.get("hidden")
    }
    legacy = {
        name: spec
        for name, spec in dungeon_doc.items()
        if spec.get("legacy")
    }
    regions = Counter(
        str(spec.get("region") or "lorien") for spec in playable.values()
    )
    bands: Counter[str] = Counter()
    unknown_levels: list[str] = []
    for name, spec in playable.items():
        value = spec.get("monster_level")
        if value is None:
            unknown_levels.append(name)
            continue
        bands[level_band(int(value))] += 1

    towns = towns_doc["locations"]
    npc_count = sum(len(town.get("npcs") or {}) for town in towns.values())
    dungeon_entries = sum(
        1 for town in towns.values() if town.get("dungeon_entry")
    )

    catalog_rows = quest_catalog["quests"]
    grades: Counter[str] = Counter(str(row.get("grade", "")) for row in catalog_rows)
    implemented_grades: Counter[str] = Counter(
        str(row.get("grade", "")) for row in catalog_rows if row.get("implemented")
    )
    epic_rows = [row for row in catalog_rows if row.get("grade") == "[epic]"]
    runtime_quest_rows = runtime_quests(game)

    blockers: list[dict[str, Any]] = []
    blocked_indexed = 0
    if (root / QUEST_COVERAGE.relative_to(ROOT)).is_file():
        coverage = load_json(root / QUEST_COVERAGE.relative_to(ROOT))
        blocked_indexed = int((coverage.get("summary") or {}).get("blocked", 0))
        blockers = [
            {"reason": reason, "count": int(count)}
            for reason, count in sorted(
                (coverage.get("blocked_reasons") or {}).items(),
                key=lambda item: (-int(item[1]), str(item[0])),
            )[:15]
        ]

    item_kinds = Counter(
        str(item.get("kind", ""))
        for item in native_runtime.get("items", {}).values()
    )
    source_by_extension = {
        key: int(value)
        for key, value in sorted(
            native_manifest["summary"]["by_extension"].items()
        )
    }
    source_item_files = (
        source_by_extension.get(".equ", 0)
        + source_by_extension.get(".stk", 0)
    )
    item_gaps = [
        {"reason": reason, "count": int(count)}
        for reason, count in sorted(
            (native_manifest.get("unsupported_reasons") or {}).items(),
            key=lambda item: (-int(item[1]), str(item[0])),
        )[:15]
    ]

    skill_rows = skill_catalog.get("skills", [])
    executable_skills = numbers.get("skills", {})
    monster_rows = monster_catalog.get("monsters", {})

    return {
        "schema": "dnf_progress_snapshot/1",
        "policy": {
            "aggregate_percentage": False,
            "reason": (
                "源记录、运行时定义、功能支持与实机验收的分母不同；"
                "本快照只给出各维度独立覆盖，不合成总完成率。"
            ),
        },
        "world": {
            "towns": len(towns),
            "town_npcs": npc_count,
            "town_dungeon_entries": dungeon_entries,
            "dungeon_entries": len(dungeon_doc),
            "playable_routes": len(playable),
            "selectable_routes": len(selectable),
            "hidden_routes": len(hidden),
            "legacy_routes": len(legacy),
            "rooms": sum(len(spec.get("rooms") or []) for spec in playable.values()),
            "regions": dict(sorted(regions.items())),
            "level_bands": {
                label: bands.get(label, 0) for label, _, _ in LEVEL_BANDS
            },
            "level_unknown": sorted(unknown_levels),
            "hidden_names": sorted(hidden),
            "legacy_names": sorted(legacy),
        },
        "quests": {
            "source_total": int(quest_catalog["summary"]["total"]),
            "source_failed": int(quest_catalog["summary"]["failed"]),
            "catalog_implemented": int(
                quest_catalog["summary"]["implemented"]
            ),
            "runtime_total": len(runtime_quest_rows),
            "runtime_percent_of_source": percentage(
                len(runtime_quest_rows), int(quest_catalog["summary"]["total"])
            ),
            "epic_total": len(epic_rows),
            "epic_runtime": sum(1 for row in epic_rows if row.get("implemented")),
            "indexed_blocked": blocked_indexed,
            "grades": [
                {
                    "grade": grade,
                    "total": count,
                    "runtime": implemented_grades.get(grade, 0),
                }
                for grade, count in sorted(
                    grades.items(), key=lambda item: (-item[1], item[0])
                )
            ],
            "top_blockers": blockers,
        },
        "campaign": {
            "id": str((quest_rules.get("campaign") or {}).get("id", "")),
            "target_level": int(
                (quest_rules.get("campaign") or {}).get("target_level", 0)
            ),
            "required": int(
                (quest_rules.get("campaign") or {}).get("required", 0)
            ),
            "executable": int(
                (quest_rules.get("campaign") or {}).get("executable", 0)
            ),
            "missing": int((quest_rules.get("campaign") or {}).get("missing", 0)),
        },
        "items": {
            "source_library_files": int(native_manifest["summary"]["files"]),
            "source_item_files": source_item_files,
            "source_by_extension": source_by_extension,
            "source_retained_raw": int(native_manifest["summary"]["retained_raw"]),
            "runtime_total": len(native_runtime.get("items", {})),
            "runtime_by_kind": dict(sorted(item_kinds.items())),
            "top_support_gaps": item_gaps,
        },
        "skills": {
            "panel_total": len(skill_rows),
            "runtime_total": len(executable_skills),
            "runtime_percent": percentage(len(executable_skills), len(skill_rows)),
            "runtime_names": [
                str(spec.get("name", key))
                for key, spec in executable_skills.items()
            ],
        },
        "monsters": {
            "catalog_total": len(monster_rows),
            "catalog_failed": count_value(monster_catalog.get("failed", [])),
            "catalog_missing_atk": count_value(
                monster_catalog.get("missing_atk", [])
            ),
            "runtime_mappings": len(combat.get("monsters", {})),
            "boss_rule_scripts": int(boss_rules.get("count", 0)),
            "boss_rule_index": len(boss_rules.get("index", {})),
            "boss_rule_families": len(boss_rules.get("by_family", {})),
            "boss_rooms": sum(
                1
                for spec in playable.values()
                for room in (spec.get("rooms") or [])
                if room.get("boss")
            ),
        },
    }


def _table(headers: list[str], rows: list[list[Any]]) -> list[str]:
    lines = [
        "| " + " | ".join(headers) + " |",
        "|" + "|".join("---" for _ in headers) + "|",
    ]
    for row in rows:
        lines.append("| " + " | ".join(str(value) for value in row) + " |")
    return lines


def render_markdown(snapshot: dict[str, Any]) -> str:
    world = snapshot["world"]
    quests = snapshot["quests"]
    items = snapshot["items"]
    skills = snapshot["skills"]
    monsters = snapshot["monsters"]
    campaign = snapshot["campaign"]

    level_rows = [
        [label, world["level_bands"][label]]
        for label, _, _ in LEVEL_BANDS
    ]
    level_rows.append(["未标等级", len(world["level_unknown"])])

    grade_rows = [
        [row["grade"], row["total"], row["runtime"]]
        for row in quests["grades"]
    ]
    blocker_rows = [
        [f"`{row['reason']}`", row["count"]]
        for row in quests["top_blockers"]
    ]
    item_source_rows = [
        [f"`{extension}`", count]
        for extension, count in items["source_by_extension"].items()
    ]
    item_kind_labels = {
        "weapon": "装备（运行时统一 `weapon`）",
        "material": "材料",
        "consumable": "消耗品",
        "quest": "任务物品",
        "profession": "职业材料",
    }
    item_runtime_rows = [
        [item_kind_labels.get(kind, kind), count]
        for kind, count in items["runtime_by_kind"].items()
    ]
    item_gap_rows = [
        [f"`{row['reason']}`", row["count"]]
        for row in items["top_support_gaps"]
    ]

    lines = [
        "# DNF 工程完成度数据",
        "",
        "> 本文件由 `python tools/report_dnf_progress.py --write` 生成，"
        "统计当前仓库中的数据事实。",
        "> 源迁移、运行时可用、功能处理器和实机验收分开计算；"
        "不生成容易误导的总完成率。",
        "",
        "## 一、总览",
        "",
    ]
    lines.extend(
        _table(
            ["维度", "当前规模", "运行时可执行", "关键说明"],
            [
                [
                    "世界",
                    f"{world['towns']} 城镇 / {world['dungeon_entries']} 副本条目",
                    f"{world['selectable_routes']} 可选路线 + {world['hidden_routes']} 隐藏路线",
                    f"{world['rooms']} 房间；另有 {world['legacy_routes']} 个旧样板不计路线",
                ],
                [
                    "任务",
                    f"{quests['source_total']} 条源总账",
                    f"{quests['runtime_total']} 条 ({quests['runtime_percent_of_source']:.2f}%)",
                    f"史诗 {quests['epic_runtime']} / {quests['epic_total']}；"
                    f"1-16 主线 {campaign['executable']} / {campaign['required']}；"
                    f"索引任务阻塞 {quests['indexed_blocked']} 条",
                ],
                [
                    "物品",
                    f"{items['source_item_files']} 份装备/堆叠源文件",
                    f"{items['runtime_total']} 种运行定义",
                    "完整原库另含任务、ETC与未入索引文件，不能直接当物品分母",
                ],
                [
                    "技能",
                    f"{skills['panel_total']} 条面板定义",
                    f"{skills['runtime_total']} 个可执行技能",
                    f"可执行覆盖 {skills['runtime_percent']:.2f}%",
                ],
                [
                    "怪物 / 战斗",
                    f"{monsters['catalog_total']} 条怪物定义",
                    f"{monsters['runtime_mappings']} 条当前映射",
                    f"{monsters['boss_rooms']} 个 BOSS 房；"
                    f"{monsters['boss_rule_scripts']} 份 AI 规则",
                ],
            ],
        )
    )
    lines.extend(
        [
            "",
            "## 二、世界与等级覆盖",
            "",
        ]
    )
    lines.extend(
        _table(
            ["指标", "数值"],
            [
                ["城镇", world["towns"]],
                ["城镇 NPC 站位记录", world["town_npcs"]],
                ["带副本入口的城镇", world["town_dungeon_entries"]],
                ["副本条目", world["dungeon_entries"]],
                ["非样板可玩路线", world["playable_routes"]],
                ["当前可选路线", world["selectable_routes"]],
                ["隐藏路线", world["hidden_routes"]],
                ["旧样板路线", world["legacy_routes"]],
                ["可玩路线房间", world["rooms"]],
            ],
        )
    )
    lines.extend(
        [
            "",
            "区域分布：" + "，".join(
                f"`{region}` {count}"
                for region, count in world["regions"].items()
            )
            + "。",
            "",
            "按副本 `monster_level` 统计：",
            "",
        ]
    )
    lines.extend(_table(["等级段", "副本数"], level_rows))
    if world["level_unknown"]:
        lines.extend(
            [
                "",
                "未标 `monster_level`："
                + "、".join(f"`{name}`" for name in world["level_unknown"])
                + "。",
            ]
        )
    if world["hidden_names"]:
        lines.append(
            "隐藏路线："
            + "、".join(f"`{name}`" for name in world["hidden_names"])
            + "。"
        )
    if world["legacy_names"]:
        lines.append(
            "旧样板："
            + "、".join(f"`{name}`" for name in world["legacy_names"])
            + "。"
        )

    lines.extend(
        [
            "",
            "## 三、任务执行覆盖",
            "",
        ]
    )
    lines.extend(
        _table(
            ["任务类型/品质", "源记录", "运行时已启用"],
            grade_rows,
        )
    )
    lines.extend(
        [
            "",
            "当前 `%s`：**%d / %d** 可执行，目标等级 **%d**，缺失 **%d**。"
            % (
                campaign["id"],
                campaign["executable"],
                campaign["required"],
                campaign["target_level"],
                campaign["missing"],
            ),
        ]
    )
    if blocker_rows:
        lines.extend(
            [
                "",
                "主要阻塞原因如下。计数按出现次数统计，同一任务可能命中多项，不能相加当任务数：",
                "",
            ]
        )
        lines.extend(_table(["阻塞原因", "出现次数"], blocker_rows))

    lines.extend(
        [
            "",
            "## 四、物品数据与功能缺口",
            "",
            f"完整原库 {items['source_library_files']} 份源文件；"
            "其中装备与堆叠物文件如下，其他类型只作迁移规模参考：",
            "",
        ]
    )
    lines.extend(_table(["扩展名", "数量"], item_source_rows))
    lines.extend(
        [
            "",
            f"保留原字节的解析异常：**{items['source_retained_raw']}** 份。",
            "",
            "当前运行物品类型：",
            "",
        ]
    )
    lines.extend(_table(["类型", "数量"], item_runtime_rows))
    if item_gap_rows:
        lines.extend(
            [
                "",
                "主要未支持字段/类别。计数为字段出现次数，不是未实现物品数：",
                "",
            ]
        )
        lines.extend(_table(["未支持项", "出现次数"], item_gap_rows))

    lines.extend(
        [
            "",
            "## 五、技能与怪物",
            "",
        ]
    )
    lines.extend(
        _table(
            ["指标", "数值"],
            [
                ["技能面板定义", skills["panel_total"]],
                ["当前可执行技能", skills["runtime_total"]],
                [
                    "可执行技能列表",
                    "、".join(skills["runtime_names"]),
                ],
                ["怪物总账", monsters["catalog_total"]],
                ["怪物总账解析失败", monsters["catalog_failed"]],
                ["总账缺失攻击定义", monsters["catalog_missing_atk"]],
                ["当前怪物运行时映射", monsters["runtime_mappings"]],
                ["BOSS 房", monsters["boss_rooms"]],
                ["AI 规则脚本", monsters["boss_rule_scripts"]],
                ["AI 规则按名字索引", monsters["boss_rule_index"]],
                ["AI 规则按族索引", monsters["boss_rule_families"]],
            ],
        )
    )
    lines.extend(
        [
            "",
            "## 六、复跑",
            "",
            "```powershell",
            "python tools/report_dnf_progress.py",
            "python tools/report_dnf_progress.py --write docs/reports/ws1/2026-10/2026-10-30_工程完成度数据.md",
            "python tools/report_dnf_progress.py --json docs/reports/ws1/2026-10/2026-10-30_工程完成度数据.json",
            "python tools/report_dnf_progress.py --check docs/reports/ws1/2026-10/2026-10-30_工程完成度数据.md",
            "```",
            "",
            "本工具只汇总仓库数据，不替代 Godot 战斗、循环或实机验收。",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", type=Path, help="write Markdown to this path")
    parser.add_argument("--json", type=Path, help="write JSON to this path")
    parser.add_argument(
        "--check",
        type=Path,
        help="verify that an existing Markdown snapshot is current",
    )
    args = parser.parse_args()
    snapshot = collect_snapshot()
    markdown = render_markdown(snapshot)
    if args.check:
        path = args.check if args.check.is_absolute() else ROOT / args.check
        current = path.read_text(encoding="utf-8")
        if current != markdown:
            print(f"[PROGRESS] stale: {path.relative_to(ROOT)}")
            return 1
        print(f"[PROGRESS] current: {path.relative_to(ROOT)}")
        if not args.write and not args.json:
            return 0
    if args.write:
        path = args.write if args.write.is_absolute() else ROOT / args.write
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(markdown, encoding="utf-8")
        print(f"[PROGRESS] wrote {path.relative_to(ROOT)}")
    else:
        print(markdown)
    if args.json:
        path = args.json if args.json.is_absolute() else ROOT / args.json
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(snapshot, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        print(f"[PROGRESS] wrote {path.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
