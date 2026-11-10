#!/usr/bin/env python3
"""Audit every runtime dungeon against its exported source DGN and combat data."""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GAME = ROOT / "game_dnf"


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def source_int(raw: list[dict], tag: str) -> int | None:
    for field in raw:
        if field.get("tag") != tag or not field.get("values"):
            continue
        value = field["values"][0]
        if isinstance(value, list) and len(value) >= 3:
            return int(value[2])
    return None


def audit() -> dict:
    dungeons = load_json(GAME / "data/dungeons.json")["dungeons"]
    combat = load_json(GAME / "data/combat.json")
    combat_mobs = {
        str(entry["mob"]).lower()
        for entry in combat.get("monsters", {}).values()
        if entry.get("mob")
    }
    errors: list[str] = []
    warnings: list[str] = []
    rows: list[dict] = []

    for dungeon_id, dungeon in dungeons.items():
        if dungeon.get("legacy"):
            continue
        map_export = str(dungeon.get("map_export", ""))
        if not map_export.startswith("res://"):
            errors.append(f"{dungeon_id}: missing map_export")
            continue
        export_path = GAME / map_export.removeprefix("res://")
        if not export_path.is_file():
            errors.append(f"{dungeon_id}: missing {map_export}")
            continue
        export = load_json(export_path)
        source = export.get("dungeon", {})
        raw = source.get("raw", [])
        source_path = str(source.get("path", ""))
        source_sha = str(source.get("sha256", ""))
        minimum = source_int(raw, "[minimum required level]")
        basis = source_int(raw, "[basis level]")
        recorded_source = dungeon.get("source", {})

        if not source.get("crc_ok", False):
            errors.append(f"{dungeon_id}: source DGN CRC check failed")
        if not source_path or not source_sha:
            errors.append(f"{dungeon_id}: map export lacks source path or SHA256")
        if minimum is None or basis is None:
            errors.append(f"{dungeon_id}: source minimum/basis level missing")
            continue
        future_scope = recorded_source.get("target_scope") == "future_above_60"
        if future_scope:
            if recorded_source.get("source_min_level") != minimum:
                errors.append(
                    f"{dungeon_id}: source_min_level="
                    f"{recorded_source.get('source_min_level')} source={minimum}"
                )
            if recorded_source.get("source_basis_level") != basis:
                errors.append(
                    f"{dungeon_id}: source_basis_level="
                    f"{recorded_source.get('source_basis_level')} source={basis}"
                )
        elif dungeon.get("min_level") != minimum:
            errors.append(
                f"{dungeon_id}: min_level={dungeon.get('min_level')} source={minimum}"
            )
        if not future_scope and dungeon.get("monster_level") != basis:
            errors.append(
                f"{dungeon_id}: monster_level={dungeon.get('monster_level')} source basis={basis}"
            )
        if recorded_source.get("path") != source_path:
            errors.append(f"{dungeon_id}: source.path does not match {source_path}")
        if recorded_source.get("sha256") != source_sha:
            errors.append(f"{dungeon_id}: source.sha256 does not match {source_sha}")

        placements = {
            str(entry.get("id", "")): entry
            for entry in source.get("placements", [])
        }
        rooms = dungeon.get("rooms", [])
        if not rooms:
            errors.append(f"{dungeon_id}: no runtime rooms")
            continue
        if not rooms[-1].get("boss"):
            errors.append(f"{dungeon_id}: final runtime room is not marked boss")

        species: Counter[str] = Counter()
        monster_count = 0
        map_ids: list[int] = []
        for index, room in enumerate(rooms):
            placement_id = str(room.get("placement", ""))
            placement = placements.get(placement_id)
            if placement is None:
                errors.append(f"{dungeon_id}: room {index} missing placement {placement_id}")
                continue
            room_map = source.get("rooms", {}).get(str(placement.get("map", "")))
            if room_map is None:
                errors.append(
                    f"{dungeon_id}: room {index} missing MAP {placement.get('map')}"
                )
                continue
            if room_map.get("map_id") is not None:
                map_ids.append(int(room_map["map_id"]))
            for monster in room_map.get("monsters", []):
                source_mob = monster.get("mob")
                mob = str(source_mob).lower() if source_mob else ""
                if not mob:
                    warnings.append(
                        f"{dungeon_id}: room {index} has an unparsed source monster row "
                        f"at {monster.get('anchor')}"
                    )
                    continue
                species[mob] += 1
                monster_count += 1
                if mob not in combat_mobs:
                    errors.append(f"{dungeon_id}: room {index} unresolved combat mob {mob}")

        rows.append(
            {
                "id": dungeon_id,
                "name": dungeon.get("name", dungeon_id),
                "source": source_path,
                "sha256": source_sha,
                "min_level": minimum,
                "basis_level": basis,
                "runtime_min_level": dungeon.get("min_level"),
                "runtime_monster_level": dungeon.get("monster_level"),
                "rooms": len(rooms),
                "monsters": monster_count,
                "species": dict(sorted(species.items())),
                "map_ids": map_ids,
            }
        )

    return {
        "schema": "dnf_world_content_audit/1",
        "dungeons": rows,
        "errors": errors,
        "warnings": warnings,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    report = audit()
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        for row in report["dungeons"]:
            print(
                f"{row['id']}: Lv{row['min_level']}/{row['basis_level']} "
                f"{row['rooms']} rooms, {row['monsters']} monsters, "
                f"{len(row['species'])} species"
            )
        for warning in report["warnings"]:
            print("WARN", warning)
        for error in report["errors"]:
            print("ERROR", error)
        print(
            "world content audit: dungeons=%d errors=%d warnings=%d"
            % (len(report["dungeons"]), len(report["errors"]), len(report["warnings"]))
        )
    return 1 if report["errors"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
