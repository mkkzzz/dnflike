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
SWORDMAN_ANIMATION = "character/swordman/animation/"
SWORDMAN_OBJECT = "passiveobject/character/swordman/"
CAST_EVIDENCE_IMAGE_SHA256 = "187ad34ab6bfff040d9b12bb145bdda0bba29f82aaa41183280b0ae42e914b84"
# Native dispatch and passiveobject.lst, independently of the runtime builder.
# A matching row covers these cast bindings only. Each object has its own rules.
WAVE_CASTS = {
    20: ("normalwave", 3, 20001, "normalwave"),
    21: ("wave_cast", 4, 20002, "icewave1"),
    22: ("wave_cast", 4, 20024, "firewavebig"),
    99: ("wave_cast", 4, 20100, "firewavebigex"),
    100: ("wave_cast", 4, 20105, "icewave1ex"),
}
GHOST_CASTS = {
    25: (20011, "khazan"),
    36: (20012, "saya"),
    41: (20013, "bremen"),
    75: (20040, "epidemicrasacreater"),
    96: (20062, "sayaex"),
}


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
        path = SWORDMAN_ANIMATION + ani + ".ani" if ani else ""
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
    return {"movement": move.get("movement", ""), "effect_id": effect_id,
            "fidelity_pending": move.get("fidelity_pending", []), "risks": sorted(risks), "stages": stages}


def native_cast_families(runtime, combat, records):
    """Compare shared cast inputs and first emission, leaving object behavior open."""
    keys_by_source = {int(skill["source_id"]): key for key, skill in runtime["skills"].items()}
    wave_ani = records[SWORDMAN_ANIMATION + "wave.ani"]["decoded"]["timeline"]
    families = {
        "swordman_wave": {
            "original_state": 24,
            "dispatch": "0xCC899D / 0xCB25FB",
            "members": {
                skill_id: (state, "", "wave", wave_ani[frame]["start_ms"], object_id, object_name)
                for skill_id, (state, frame, object_id, object_name) in WAVE_CASTS.items()
            },
        },
        "swordman_ghost": {
            "original_state": 13,
            "dispatch": "0xCBBCD5 / 0x19EBF14",
            "members": {
                skill_id: ("ghost_cast", "throw1", "throw2", 0, object_id, object_name)
                for skill_id, (object_id, object_name) in GHOST_CASTS.items()
            },
        },
    }
    for family in families.values():
        members = []
        for skill_id, (state, charge, ani, at, object_id, object_name) in family["members"].items():
            key = keys_by_source.get(skill_id, "")
            skill = runtime["skills"].get(key, {})
            move = effective_base(key, runtime, combat) if key else {}
            stage = next(iter(move.get("stages", [move])), {})
            emissions = [{"path": hit["object"], "at": hit.get("at", 0)}
                         for hit in stage.get("hits", []) if "object" in hit]
            expected_emission = {"path": SWORDMAN_OBJECT + object_name + ".obj", "at": at}
            actual = {"state": move.get("native_state", ""), "charge_ani": move.get("native_charge_ani", ""),
                      "ani": stage.get("ani", ""), "emissions": emissions}
            expected = {"state": state, "charge_ani": charge, "ani": ani, "emissions": [expected_emission]}
            members.append({
                "source_id": skill_id, "key": key, "tree_visible": skill.get("tree_visible", False),
                "object_id": object_id, "expected": expected, "actual": actual,
                "expected_object_sha256": records.get(expected_emission["path"], {}).get("source", {}).get("sha256", ""),
                "binding_differences": [name for name in expected if expected[name] != actual[name]],
                "fidelity_pending": move.get("fidelity_pending", []),
            })
        family["client_image_sha256"] = CAST_EVIDENCE_IMAGE_SHA256
        family["members"] = members
    return families


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
            if str(skill.get("runtime_status", "")).startswith("pending_"):
                item["risks"].append("pending_runtime_consumer")
            if skill_id == "throwmastery" and skill.get("passive"):
                item["risks"].append("throw_item_bonus_applied_to_general_character_stats")
            if skill_id == "basicattackup" and skill.get("passive"):
                item["risks"].append("basic_attack_bonus_applied_to_general_character_stats")
            if "backattackcritical" in skill_id and any(m.get("stat") in ("physical_crit", "magical_crit") for m in skill.get("passive", [])):
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
    combat = read(GAME / "data/combat.json")
    records = read(GAME / "assets_local/content/combat_content.json")["records"]
    document = audit(runtime, combat, records, read(GAME / "data/skill_catalog.json"), clips)
    document["native_cast_families"] = native_cast_families(runtime, combat, records)
    document["inputs_sha256"] = {str(p.relative_to(ROOT)).replace("\\", "/"): hashlib.sha256(p.read_bytes()).hexdigest() for p in (GAME / "data/skill_runtime.json", GAME / "data/combat.json", GAME / "assets_local/content/combat_content.json")}
    if args.client_root:
        document["client_archives"] = client_inventory(args.client_root)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(document["counts"], ensure_ascii=False))
    for name, family in document["native_cast_families"].items():
        differences = [row["source_id"] for row in family["members"] if row["binding_differences"]]
        print(f"{name} cast binding differences: {differences}")
    print("Evidence gaps written to " + str(args.output))


if __name__ == "__main__":
    main()
