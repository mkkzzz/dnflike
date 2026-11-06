"""Inventory actual skill bindings and evidence gaps; never certify fidelity by counts.

Reads checked-in catalog, source records and both runtime rule layers. Optional
--client-root inspects the user-selected client/backup PVFs read-only. Outputs
stay in temp by default. Variants are listed as alternatives, not simultaneous
live moves; combat.json wins base selection as in MoveTable.
"""
from __future__ import annotations

import argparse
from collections import Counter
from copy import deepcopy
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GAME = ROOT / "game_dnf"
OVERLAYS = ("hp_cost_row", "requires_effect", "super_armor", "invuln_ms", "effect_id", "cast_fx", "aura_fx")
DIMENSIONS = ("body_animation", "weapon_pose", "effect_composition", "timing", "hit_and_damage", "status_and_state", "original_client_comparison")


def read(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def effective_base(skill_id, runtime, combat):
    generated = runtime["moves"].get(skill_id, {})
    base = deepcopy(combat.get("moves", {}).get(skill_id, generated))
    for field in OVERLAYS:
        if field in generated:
            base[field] = deepcopy(generated[field])
    return base


def inspect_move(move, runtime, records, clips):
    risks, stages = set(), []
    assets = runtime["assets"]

    def source(path):
        record = records.get(path, {})
        if path and not record:
            risks.add("missing_source_record")
        return {"path": path, "sha256": record.get("source", {}).get("sha256", "")}

    for stage in move.get("stages", [move]):
        ani = stage.get("ani", "")
        path = "character/swordman/animation/" + ani + ".ani" if ani else ""
        record = records.get(path, {}).get("decoded", {})
        if ani == "summon2":
            risks.add("generic_buff_motion_binding_needs_verification")
        if ani and ani not in clips:
            risks.add("missing_render_clip")
        if any(f.get("end_ms", 0) - f.get("start_ms", 0) >= 1000 for f in record.get("timeline", [])):
            risks.add("long_frame_requires_state_or_hold_review")
        fx = [{**source(assets.get("effect_anims", {}).get(f["key"], "")), "key": f["key"], "at": f.get("at", 0)} for f in stage.get("fx", [])]
        hits = []
        for hit in stage.get("hits", []):
            entry = deepcopy(hit)
            if "derived" in hit:
                risks.add("collision_derived_from_visual_bounds")
                entry["derived_source"] = source(assets.get("effect_anims", {}).get(hit["derived"], ""))
                if "upperslash1.ani" in entry["derived_source"]["path"]:
                    risks.add("upper_slash_collision_reused_check_binding")
            if "object" in hit:
                entry["object_source"] = source(hit["object"])
                obj = records.get(hit["object"], {}).get("decoded", {})
                entry["object_motions"] = [source(p) for p in obj.get("basic_motion", [])]
                entry["object_attacks"] = [source(p) for p in obj.get("attack_infos", [])]
                risks.add("object_spawn_speed_lifetime_adapter_needs_verification")
            if "atk" in hit and hit["atk"]:
                entry["attack_source"] = source(hit["atk"])
            hits.append(entry)
        if fx:
            risks.add("effect_binding_and_composition_need_verification")
        stages.append({"body": source(path), "source_duration_ms": record.get("duration_ms"), "attack": source(stage.get("atk", "")), "effects": fx, "hits": hits})
    effect_id = move.get("effect_id", "")
    if effect_id and runtime.get("effects", {}).get(effect_id, {}).get("duration_ms") == 1:
        risks.add("one_millisecond_placeholder_effect")
    if len(stages) > 1:
        risks.add("stage_transition_and_damage_columns_need_verification")
    return {"movement": move.get("movement", ""), "effect_id": effect_id, "risks": sorted(risks), "stages": stages}


def audit(runtime, combat, records, catalog, clips):
    result = []
    catalog_by_id = {int(skill["id"]): skill for skill in catalog["skills"]}
    for skill_id, skill in sorted(runtime["skills"].items()):
        path = skill.get("source_path", skill.get("path", ""))
        original = catalog_by_id[int(skill["source_id"])]
        item = {"id": skill_id, "name": skill["name"], "source_id": skill["source_id"],
                "source": {"path": path, "sha256": records.get(path, {}).get("source", {}).get("sha256", "")},
                "active": skill["active"], "tree_visible": skill.get("tree_visible", False),
                "original_explain": original.get("explain", ""),
                "dimensions": {d: "unverified" for d in DIMENSIONS}, "risks": []}
        if skill["active"]:
            item["base_owner"] = "combat.json" if skill_id in combat["moves"] else "skill_runtime.json"
            item["base"] = inspect_move(effective_base(skill_id, runtime, combat), runtime, records, clips)
            item["risks"] = item["base"]["risks"]
            item["variants"] = []
            for option in runtime.get("variants", {}).get(skill_id, []):
                move_id = option.get("move", "")
                spec = combat["moves"].get(move_id, runtime["moves"].get(move_id, {}))
                item["variants"].append({"selection": option, "bindings": inspect_move(spec, runtime, records, clips)})
        else:
            item["passive_definition"] = {k: v for k, v in skill.items() if k not in ("name", "path", "source_path")}
            if skill.get("runtime_hook") == "declarative_passive":
                item["risks"].append("declarative_hook_without_verified_consumer")
            if "backattackcritical" in skill_id and "passive" in skill:
                item["risks"].append("back_attack_bonus_applied_without_direction_condition")
        result.append(item)
    counts = Counter(risk for item in result for risk in item["risks"])
    return {"schema": "dnf_skill_fidelity_audit/1", "effective_client_pvf": "unconfirmed",
            "scope": "All catalog skills and selectable variants. Resource existence is not binding correctness. No original-client behaviour/presentation sign-off recorded.",
            "counts": {"skills": len(result), "active": sum(s["active"] for s in result), "risks": dict(sorted(counts.items()))}, "skills": result}


def client_inventory(root):
    from dnf_pvf_archive import Archive
    # Do not silently mix in the adjacent DNF1031 client.
    paths = [root / "111Script.pvf", root / "情怀60复古/Script.pvf",
             root / "情怀60复古/ImagePacks2/Script.pvf", root / "情怀60复古/Video/Script.pvf"]
    result = []
    for path in paths:
        if not path.is_file():
            continue
        with path.open("rb") as stream:
            sha = hashlib.file_digest(stream, "sha256").hexdigest()
        item = {"path": path.relative_to(root).as_posix(), "bytes": path.stat().st_size, "sha256": sha}
        try:
            archive = Archive(path, allow_known_client_transform=True)
            item.update(directory_valid=True, entries=len(archive.entries),
                        directory_transform=archive.directory_transform,
                        swordman_nut=[p for p in archive.entries if p.endswith(".nut") and "swordman" in p],
                        player_act_count=sum(p.startswith("character/swordman/") and p.endswith(".act") for p in archive.entries))
            archive.close()
        except ValueError as error:
            item.update(directory_valid=False, reason=str(error))
        result.append(item)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "temp/skill_logic_audit/fidelity.json")
    parser.add_argument("--client-root", type=Path)
    args = parser.parse_args()
    runtime = read(GAME / "data/skill_runtime.json")
    base = read(GAME / "assets_local/manifest.json")
    baked = read(GAME / "assets_local/combat/manifest.json")
    clips = set(baked["player_clips"]) | {p.removeprefix("player/") for p in base["clips"] if p.startswith("player/")}
    document = audit(runtime, read(GAME / "data/combat.json"), read(GAME / "assets_local/content/combat_content.json")["records"], read(GAME / "data/skill_catalog.json"), clips)
    document["inputs_sha256"] = {str(p.relative_to(ROOT)).replace("\\", "/"): hashlib.sha256(p.read_bytes()).hexdigest() for p in (GAME / "data/skill_runtime.json", GAME / "data/combat.json", GAME / "assets_local/content/combat_content.json")}
    if args.client_root:
        document["client_archives"] = client_inventory(args.client_root)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(document["counts"], ensure_ascii=False))
    print("Evidence gaps written to " + str(args.output))


if __name__ == "__main__":
    main()
