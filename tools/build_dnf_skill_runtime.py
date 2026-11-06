"""Build the generated Swordman skill runtime from archived source records.

The source of truth is:
  - game_dnf/data/skill_catalog.json (175 SKLs and five SP trees)
  - game_dnf/assets_local/content/combat_content.json (SKL/ANI/ATK/OBJ/PTL)
  - explicit skill engine adapters in this file

The generated file contains every unique SP-tree node. Resource references and
numeric fields are mixed with incomplete engine adapters and inferred mappings.
Catalog coverage is NOT evidence of original behaviour or presentation fidelity.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dnf_pvf import open_library


ROOT = Path(__file__).resolve().parents[1]
GAME = ROOT / "game_dnf"
CATALOG = GAME / "data/skill_catalog.json"
PACK = GAME / "assets_local/content/combat_content.json"
OUTPUT = GAME / "data/skill_runtime.json"

SCHEMA = "dnf_skill_runtime/1"
CHR_ANI = "character/swordman/animation/"
CHR_ATK = "character/swordman/attackinfo/"
CHR_FX = "character/swordman/effect/animation/"
OBJ_ROOT = "passiveobject/character/swordman/"

# Keep the existing save IDs stable while giving every other tree node a
# deterministic canonical ID. The catalog builder uses this same map.
LOCAL_IDS = {
    "tripleslash": "triple",
    "momentaryslash": "draw",
    "gorecross": "rage_slash",
    "moonlightslash": "moonlight",
    "chargecrash": "charge_crash",
    "frenzy": "buff",
    "upperslash": "upper",
    "weaponmasteryup": "weapon_mastery_up",
    "bloodyvigorous": "bloody_vigorous",
}

# Direct character motions. Numbered suffixes are ordered stages.
STAGE_NAMES = {
    "guard": ["guard"],
    "reflectguard": ["reflectguard"],
    "hardattack": ["hardattack"],
    "hitback": ["hitback"],
    "tripleslash": ["tripleslash1", "tripleslash2", "tripleslash3"],
    "momentaryslash": ["momentaryslash"],
    "dashattackmultihit": ["dashattackmultihit"],
    "jumpattackmulti": ["jumpattackmultislash1", "jumpattackmultislash2"],
    "shockwavearea": ["shockwaveareacast", "shockwaveareasmash"],
    "vaneslash": ["vaneslashtry", "vaneslash", "vaneslashtry"],
    "ghoststepslash": ["ghoststepslashready", "ghoststepslashmove"],
    "standalonewave": ["standalonewaveready", "standalonewavebasic", "standalonewavestrong"],
    "gorecross": ["gorecross"],
    "hopsmash": ["hopsmashready", "hopsmash"],
    "chargecrash": ["chargecrashdash", "chargecrashupper"],
    "rapidmoveslash": ["rapidmoveslashready1", "rapidmoveslashmove1", "rapidmoveslashready2", "rapidmoveslashmove2"],
    "illusionslash": ["illusionslash1", "illusionslash2", "illusionslash3", "illusionslash4", "illusionslashfinal"],
    "moonlightslash": ["moonlightslash1", "moonlightslash2"],
    "bloodyrave": ["bloodyraveinhale", "bloodyraveslash"],
    "outragebreak": ["outragebreakready", "outragebreakslash"],
    "hellbenter": ["hellbenterfinish"],
    "hundredsword": [
        "hundredswordready",
        "hundredswordmoveslash1",
        "hundredswordmoveslash2",
        "hundredswordmoveslash3",
        "hundredswordmoveslash4",
        "hundredswordmoveslash5",
        "hundredswordfinish",
    ],
    "blache": ["blachecast", "blachesmash"],
    "waveeye": ["waveeyestart", "waveeyecast"],
    "weaponcombo": [
        "weaponcomboblade1",
        "weaponcomboblade2",
        "weaponcomboblade3",
        "weaponcomboblade4",
    ],
}

STAGE_ANI_OVERRIDES = {
    "upperslash": ["hitback"],
    "backstepcutter": ["hitback"],
}

STAGE_ATK_OVERRIDES = {
    "upperslash": [CHR_ATK + "upperslash.atk"],
    "backstepcutter": [CHR_ATK + "upperslash.atk"],
}

STAGE_EFFECT_OVERRIDES = {
    "upperslash": [CHR_FX + "upperslash1.ani"],
    "backstepcutter": [CHR_FX + "upperslash1.ani"],
    "tombstonerain": ["passiveobject/actionobject/monster/wooden_doll/animation/tombstonerain.ani"],
}

GENERIC_HIT_EFFECT = CHR_FX + "upperslash1.ani"

# Cast skills without a dedicated hostile body motion.
CAST_ANIM = "summon2"
CAST_OBJECTS = {
    "ashenfork": (OBJ_ROOT + "ashenforksub.obj", 260, 0.0, 700),
    # Native object 20001 (0x9EBAF0) dies at ANI end. Its OBJ supplies no
    # travel controller; the image/box positions already advance within ANI.
    # Its native-state adapter below supplies the source-frame trigger.
    "normalwave": (OBJ_ROOT + "normalwave.obj", 0, 0.0, -1),
    "icewave": (OBJ_ROOT + "icewave1.obj", 360, 0.0, -1),
    "firewave": (OBJ_ROOT + "firewavebig.obj", 420, 360.0, 1800),
    "bloodblast": (OBJ_ROOT + "grabblastbloodbig.obj", 280, 0.0, 1700),
    "khazan": (OBJ_ROOT + "khazan.obj", 320, 0.0, 25000),
    "grabblastblood": (OBJ_ROOT + "grabblastblood.obj", 320, 0.0, 1200),
    "releasewave": (OBJ_ROOT + "releasewave.obj", 260, 480.0, 1200),
    "saya": (OBJ_ROOT + "saya.obj", 420, 0.0, 25000),
    "bremen": (OBJ_ROOT + "bremen.obj", 420, 0.0, 25000),
    "tombstonerain": (None, 480, 0.0, 2600),
    "grandwave": (OBJ_ROOT + "grandwave.obj", 420, 520.0, 1800),
    "dotarea": (None, 220, 0.0, 16000),
    "epidemicrasa": (OBJ_ROOT + "epidemicrasa.obj", 360, 0.0, 12000),
    "reflectguard": (OBJ_ROOT + "reflectguardbead.obj", 300, 540.0, 1600),
}

# Buff/morph actions use the CHR buff pose and apply a timed runtime effect.
BUFF_SKILLS = {
    "autoguard": "autoguard",
    "ghoststep": "ghoststep",
    "darktoleranceup": "dark_tolerance",
    "diehard": "diehard",
    "overdrive": "overdrive",
    "reckless": "reckless",
    "frenzy": "frenzy",
    "kalla": "kalla",
    "keiga": "keiga",
    "hellbenter": "hellbenter",
    "waveeye": "waveeye",
    "wavemark": "wavemark",
    "dotarea": "dotarea",
    "jumppowerup": "jump_power_up",
    "magicalattackup": "magical_memory",
    "superarmoroncast": "super_armor_cast",
    "quickstanding": "quick_standing",
    "flowmind": "flowmind",
    "flowmindpowerup": "flowmind_powerup",
}

DIRECT_OBJECTS = {
    "tripleslash": None,
    "gorecross": (OBJ_ROOT + "gorecross.obj", 900, 0.0, 1400),
    "hopsmash": (OBJ_ROOT + "hopsmashsub.obj", 260, 0.0, 1300),
    "chargecrash": (OBJ_ROOT + "chargecrashsub.obj", 700, 0.0, 1200),
    "wavespinarea": (OBJ_ROOT + "wavespinarea.obj", 420, 0.0, 5000),
    "illusionslash": (OBJ_ROOT + "illusionslashwave.obj", 900, 520.0, 1600),
    "bloodyrave": (OBJ_ROOT + "bloodyrave.obj", 980, 0.0, 1600),
    "outragebreak": (OBJ_ROOT + "outragebreakfloor.obj", 440, 0.0, 2400),
    "hellbenter": (OBJ_ROOT + "hellbenterfinish.obj", 760, 0.0, 1800),
    "hundredsword": (OBJ_ROOT + "hundredswordhit.obj", 780, 0.0, 3000),
    "blache": (OBJ_ROOT + "blache.obj", 760, 0.0, 3600),
    "waveeye": (OBJ_ROOT + "waveeye.obj", 850, 0.0, 5000),
}

# Source bindings proved in CNSwordman state 24. Other newly eligible blank-frame
# clips must not enter the old filename heuristic and create new guessed damage.
NATIVE_WAVE_BINDINGS = {
    CHR_FX + "icewave.ani",
    CHR_FX + "firewavebig-sword-effect.ani",
    OBJ_ROOT + "animation/firewavebig/blast-front.ani",
    *(OBJ_ROOT + f"animation/icewave{i}.ani" for i in range(1, 7)),
}

SAFE_EFFECTS: set[str] = set()
SAFE_OBJECTS: set[str] = set()
IMAGE_DB = None
IMAGE_PATHS: set[str] | None = None

EX_BASE = {
    "tombstonerainex": "tombstonerain",
    "sayaex": "saya",
    "momentaryslashex": "draw",
    "chargecrashex": "charge_crash",
    "firewaveex": "firewave",
    "icewaveex": "icewave",
    "bloodblastex": "bloodblast",
    "grabblastbloodex": "grabblastblood",
    "bloodsword": "rage_slash",
    "flowmindone": "weaponcombo",
    "flowmindtwo": "weaponcombo",
    "flowmindthree": "weaponcombo",
    "ghostsidewind": "ghoststepslash",
    "triplestab": "ghoststepslash",
    "releasewaveex": "releasewave",
    "grandwaveex": "grandwave",
    "standalonewaveex": "standalonewave",
    "wavespinareaex": "wavespinarea",
    "upperslashex": "upper",
    "illusionslashexp": "illusionslash",
    "chargecrashexp": "charge_crash",
}

EFFECT_DIR_ALIASES = {
    "triple": "tripleslash",
    "draw": "momentaryslash",
    "upper": "upperslash",
    "rage_slash": "gorecross",
    "moonlight": "moonlightslash",
    "charge_crash": "chargecrash",
    "buff": "frenzy",
}

HIT_STATUS = {
    # CNIceWave init 0xA6E602/643/679: probability per mille, status level, ms.
    "icewave": [{"id": "freeze", "chance_col": 4, "chance_scale": 0.001,
                 "status_level_col": 5, "duration_ms_col": 6}],
    "firewave": [{"id": "burn", "chance": 0.25}],
    "gorecross": [{"id": "bleed", "chance": 0.2}],
    "bloodyrave": [{"id": "bleed", "chance": 0.3}],
    "outragebreak": [{"id": "bleed", "chance": 0.3}],
}

AREA_REPEATS = {
    "dotarea": (8, 650),
    "wavespinarea": (6, 450),
    "shockwavearea": (3, 280),
    "bloodblast": (4, 260),
    "outragebreak": (3, 420),
    "waveeye": (5, 500),
}

ROOT_EFFECTS = {
    "mindflash": {
        "name": "挫折意志",
        "duration_ms": 23000,
        "stacking": "stack",
        "max_stacks": 5,
        "modifiers": [
            {"stat": "intelligence", "op": "add", "value": 6},
            {"stat": "mp_regen", "op": "add", "value": 0.5},
        ],
    },
    "burn": {
        "name": "灼伤",
        "duration_ms": 5000,
        "stacking": "stack",
        "max_stacks": 3,
        "interval_ms": 1000,
        "tick_damage": 8,
        "damage_type": "magical",
        "harmful": True,
        "element": "fire",
    },
    "slow": {
        "name": "减速",
        "duration_ms": 4000,
        "stacking": "refresh",
        "max_stacks": 1,
        "modifiers": [{"stat": "move_speed", "op": "mul", "value": 0.75}],
        "harmful": True,
    },
    "shock": {
        "name": "感电",
        "duration_ms": 4000,
        "stacking": "stack",
        "max_stacks": 3,
        "interval_ms": 1000,
        "tick_damage": 10,
        "damage_type": "magical",
        "element": "light",
        "harmful": True,
    },
    "defense_down": {
        "name": "物理防御降低",
        "duration_ms": 10000,
        "stacking": "stack",
        "max_stacks": 10,
        "modifiers": [{"stat": "physical_defense", "op": "mul", "value": 0.97}],
        "harmful": True,
    },
    "dark_aura": {
        "name": "恐惧光环",
        "duration_ms": 1000,
        "stacking": "refresh",
        "max_stacks": 1,
        "harmful": True,
        "modifiers": [
            {"stat": "dark_resist", "op": "add", "value": -40},
            {"stat": "attack_speed", "op": "mul", "value": 0.95},
        ],
    },
    "counter_evasion": {
        "name": "心眼",
        "duration_ms": 10000,
        "stacking": "refresh",
        "max_stacks": 1,
        "modifiers": [{"stat": "evasion", "op": "add", "value": 0.06}],
    },
    "khazan_aura": {
        "name": "刀魂之卡赞",
        "duration_ms": 25000,
        "stacking": "refresh",
        "max_stacks": 1,
        "modifiers": [
            {"stat": "strength", "op": "add", "value": 31},
            {"stat": "intelligence", "op": "add", "value": 31},
        ],
        "aura": {"radius": 250, "damage_percent": 31},
    },
    "saya_aura": {
        "name": "冰霜之萨亚",
        "duration_ms": 25000,
        "stacking": "refresh",
        "max_stacks": 1,
        "aura": {"radius": 300, "damage_percent": 80, "effect": "freeze", "chance": 0.12},
    },
    "bremen_aura": {
        "name": "侵蚀之普戾蒙",
        "duration_ms": 25000,
        "stacking": "refresh",
        "max_stacks": 1,
        "aura": {"radius": 300, "enemy_effect": "bremen_debuff"},
    },
    "epidemic_aura": {
        "name": "瘟疫之罗刹",
        "duration_ms": 12000,
        "stacking": "refresh",
        "max_stacks": 1,
        "aura": {"radius": 280, "enemy_effect": "slow", "damage_percent": 40},
    },
    "bremen_debuff": {
        "name": "侵蚀之普戾蒙",
        "duration_ms": 1000,
        "stacking": "refresh",
        "max_stacks": 1,
        "harmful": True,
        "modifiers": [
            {"stat": "physical_defense", "op": "mul", "value": 0.85},
            {"stat": "magical_defense", "op": "mul", "value": 0.85},
            {"stat": "move_speed", "op": "mul", "value": 0.9},
        ],
    },
}

BUFF_EFFECTS = {
    "autoguard": {
        "name": "自动格挡",
        "duration_ms": 120000,
        "stacking": "refresh",
        "max_stacks": 1,
        "auto_guard": True,
        "super_armor": True,
    },
    "ghoststep": {
        "name": "鬼影步",
        "duration_ms": 120000,
        "stacking": "refresh",
        "max_stacks": 1,
        "form": "ghost_step",
        "invuln_ms": 1000,
        "modifiers": [{"stat": "move_speed", "op": "mul", "value": 1.1}],
    },
    "dark_tolerance": {
        "name": "暗月降临",
        "duration_ms": 20000,
        "stacking": "refresh",
        "max_stacks": 1,
        "modifiers": [{"stat": "dark_resist", "op": "add", "value": 3}],
        "aura": {"radius": 250, "enemy": {"dark_resist": -3}},
    },
    "diehard": {
        "name": "死亡抗拒",
        "duration_ms": 10000,
        "stacking": "refresh",
        "max_stacks": 1,
        "modifiers": [
            {"stat": "hp_regen", "op": "add", "value": 20},
            {"stat": "physical_defense", "op": "mul", "value": 1.15},
        ],
    },
    "overdrive": {
        "name": "破极兵刃",
        "duration_ms": 120000,
        "stacking": "refresh",
        "max_stacks": 1,
        "weapon_attack": 30,
        "durability_rate": 3.0,
    },
    "reckless": {
        "name": "暴走",
        "duration_ms": 40080,
        "stacking": "refresh",
        "max_stacks": 1,
        "form": "reckless",
        "modifiers": [
            {"stat": "attack_speed", "op": "mul", "value": 1.1},
            {"stat": "move_speed", "op": "mul", "value": 1.08},
            {"stat": "strength", "op": "add", "value": 50},
            {"stat": "physical_crit", "op": "add", "value": 0.08},
            {"stat": "taken_rate", "op": "mul", "value": 1.1},
        ],
    },
    "frenzy": {
        "name": "血之狂暴",
        "duration_ms": 8000,
        "stacking": "refresh",
        "max_stacks": 1,
        "form": "dual_wield",
        "super_armor": True,
        "interval_ms": 10000,
        "tick_damage": 75,
        "modifiers": [
            {"stat": "attack_speed", "op": "mul", "value": 1.25},
            {"stat": "move_speed", "op": "mul", "value": 1.2},
            {"stat": "damage_rate", "op": "mul", "value": 1.2},
            {"stat": "taken_rate", "op": "mul", "value": 1.3},
            {"stat": "hit", "op": "add", "value": 0.1},
        ],
        "skill_damage": {"grabblastblood": 0.1, "bloodblast": 0.1, "rage_slash": 0.1},
        "skill_cooldown_rate": {"grabblastblood": 0.85, "bloodblast": 0.85, "rage_slash": 0.85},
    },
    "keiga": {
        "name": "残影之凯贾",
        "duration_ms": 156000,
        "stacking": "refresh",
        "max_stacks": 1,
        "modifiers": [
            {"stat": "taken_rate", "op": "mul", "value": 0.8},
            {"stat": "evasion", "op": "add", "value": 0.07},
        ],
        "absorb_hits": 20,
    },
    "hellbenter": {
        "name": "魔狱血刹",
        "duration_ms": 60000,
        "stacking": "refresh",
        "max_stacks": 1,
        "form": "hellbenter",
        "modifiers": [
            {"stat": "attack_speed", "op": "mul", "value": 1.1},
            {"stat": "move_speed", "op": "mul", "value": 1.08},
        ],
    },
    "kalla": {
        "name": "冥炎之卡洛",
        "duration_ms": 39000,
        "stacking": "refresh",
        "max_stacks": 1,
        "form": "kalla",
    },
    "waveeye": {
        "name": "暗天波动眼",
        "duration_ms": 40000,
        "stacking": "refresh",
        "max_stacks": 1,
        "form": "wave_eye",
    },
    "wavemark": {
        "name": "波动刻印",
        "duration_ms": 120000,
        "stacking": "refresh",
        "max_stacks": 1,
        "form": "wave_mark",
        "wave_mark_interval_ms": 3000,
    },
    "dotarea": {
        "name": "杀意波动",
        "duration_ms": 120000,
        "stacking": "refresh",
        "max_stacks": 1,
        "form": "murderous_wave",
        "aura": {"radius": 260, "tick_damage": 18, "damage_type": "magical"},
    },
    "jump_power_up": {
        "name": "跃翔",
        "duration_ms": 20000,
        "stacking": "refresh",
        "max_stacks": 1,
        "modifiers": [{"stat": "jump_power", "op": "add", "value": 120}],
    },
    "magical_memory": {
        "name": "远古记忆",
        "duration_ms": 20000,
        "stacking": "refresh",
        "max_stacks": 1,
        "modifiers": [
            {"stat": "intelligence", "op": "add", "value": 150},
            {"stat": "magical_attack", "op": "percent", "value": 0.1},
        ],
    },
    "super_armor_cast": {
        "name": "不屈意志",
        "duration_ms": 8000,
        "stacking": "refresh",
        "max_stacks": 1,
        "super_armor": True,
    },
    "quick_standing": {
        "name": "受身蹲伏",
        "duration_ms": 1,
        "stacking": "refresh",
        "max_stacks": 1,
    },
    "flowmind": {
        "name": "流心",
        "duration_ms": 120000,
        "stacking": "refresh",
        "max_stacks": 1,
        "form": "flowmind",
    },
    "flowmind_powerup": {
        "name": "流心 · 狂",
        "duration_ms": 120000,
        "stacking": "refresh",
        "max_stacks": 1,
        "skill_damage": {"flowmindone": 0.1, "flowmindtwo": 0.1, "flowmindthree": 0.1},
    },
}


def local_id(key: str) -> str:
    return LOCAL_IDS.get(key, key)


def stable_suffix(path: str, size: int = 8) -> str:
    return hashlib.sha256(path.encode("utf-8")).hexdigest()[:size]


def unique_key(prefix: str, path: str) -> str:
    stem = re.sub(r"[^a-z0-9_]+", "_", Path(path).stem.lower()).strip("_")
    return f"{prefix}_{stem}_{stable_suffix(path)}"


def attack_paths(records: dict) -> dict[str, list[str]]:
    out: dict[str, list[str]] = {}
    for path, record in records.items():
        if record.get("kind") != "atk":
            continue
        out.setdefault(Path(path).stem, []).append(path)
    return out


def anim_paths(records: dict, prefix: str) -> list[str]:
    return sorted(
        path
        for path, record in records.items()
        if record.get("kind") == "ani" and path.startswith(prefix)
    )


def object_paths(records: dict) -> list[str]:
    return sorted(path for path, record in records.items() if record.get("kind") == "obj")


def pick_attack(stem: str, by_stem: dict[str, list[str]]) -> str:
    values = by_stem.get(stem, [])
    preferred = [path for path in values if path.startswith(CHR_ATK)]
    direct = [path for path in preferred if "/dsattackinfo/" not in path]
    return (direct or preferred or values or [""])[0]


def pick_effect(stem: str, effect_paths: list[str], skill_key: str = "", index: int = 0) -> str:
    exact = [path for path in effect_paths if Path(path).stem.lower() == stem.lower()]
    if exact:
        return exact[0]
    key = EFFECT_DIR_ALIASES.get(skill_key or stem, skill_key or stem).lower()
    prefix = CHR_FX + key + "/"
    grouped = [path for path in effect_paths if path.startswith(prefix)]
    if grouped:
        number = index + 1
        preferred = [
            path
            for path in grouped
            if re.search(
                rf"(?:slash|move|blast|lightmove){number}(?:[^0-9]|$)",
                Path(path).stem.lower(),
            )
        ]
        if preferred:
            return preferred[0]
        return grouped[min(index, len(grouped) - 1)]
    contains = [path for path in effect_paths if key in Path(path).stem.lower()]
    return contains[min(index, len(contains) - 1)] if contains else ""


def timeline_has_attack(record: dict) -> bool:
    timeline = record.get("decoded", {}).get("timeline", [])
    return any(frame.get("attack_boxes") for frame in timeline)


def duration_ms(record: dict) -> float:
    return float(record.get("decoded", {}).get("duration_ms") or 0)


def safe_animation(library, path: str) -> bool:
    if not path or "_ds" in path.lower():
        return False
    found = library.animation(path)
    if found is None or found.get("metadata") is None:
        return False
    frames = found["metadata"].get("frames", [])
    if not any(frame.get("img") for frame in frames):
        return False
    for frame in frames:
        # ANI may deliberately start with an invisible frame. None is not an
        # archive path; treating it as "None" discarded valid native effects.
        image = frame.get("img") or ""
        if image and ("%" in image or not image_exists(library, image)):
            return False
    return True


def supported_animation_binding(library, path: str) -> bool:
    if not safe_animation(library, path):
        return False
    # Keep legacy inferred choices stable while migrating each skill to a native
    # controller. Asset availability alone cannot establish a hit/FX binding.
    return path in NATIVE_WAVE_BINDINGS or all(
        frame.get("img") for frame in library.animation(path)["metadata"]["frames"]
    )


def image_exists(library, image: str) -> bool:
    global IMAGE_DB, IMAGE_PATHS
    if IMAGE_PATHS is None:
        IMAGE_DB = sqlite3.connect(f"file:{library.path / 'catalog.sqlite'}?mode=ro", uri=True)
        IMAGE_PATHS = {
            str(row[0]).lower()
            for row in IMAGE_DB.execute(
                "select original_path from assets where validation='image_data_checked'"
            )
        }
    return "sprite/" + image.lower() in IMAGE_PATHS


def safe_object(library, records: dict, path: str) -> bool:
    if not path or "_ds" in path.lower():
        return False
    record = records.get(path.lower(), {})
    decoded = record.get("decoded", {})
    motions = decoded.get("basic_motion") or decoded.get("etc_motions") or []
    return bool(motions) and safe_animation(library, str(motions[0]))


def add_fx(fx: dict[str, str], effects: dict[str, dict], path: str) -> str:
    if not path or path not in SAFE_EFFECTS:
        return ""
    key = unique_key("skillfx", path)
    fx[key] = path
    return key


def add_object(objects: dict[str, str], path: str) -> str:
    if not path or path not in SAFE_OBJECTS:
        return ""
    objects[path] = path
    return path


def build_stage(
    key: str,
    index: int,
    ani: str,
    records: dict,
    atk_by_stem: dict[str, list[str]],
    effect_paths: list[str],
    fx: dict[str, str],
    effects: dict[str, dict],
    *,
    hit_ani: str = "",
    atk_override: str = "",
    percent_col: int | None = None,
    ticks: int = 1,
    interval_ms: float = 350,
    statuses: list[dict] | None = None,
) -> dict:
    ani_path = CHR_ANI + ani + ".ani"
    ani_record = records.get(ani_path, {})
    effect_path = hit_ani or pick_effect(ani, effect_paths, skill_key=key, index=index)
    if effect_path and effect_path not in SAFE_EFFECTS:
        effect_path = ""
    effect_record = records.get(effect_path, {})
    atk_path = atk_override or pick_attack(ani, atk_by_stem)
    if not atk_path and effect_path:
        atk_path = pick_attack(Path(effect_path).stem, atk_by_stem)
    column = index if percent_col is None else percent_col
    hits: list[dict] = []
    hit_source = ""
    if ani_record and timeline_has_attack(ani_record):
        hit_source = "body"
    elif effect_path:
        hit_source = "effect"
    if hit_source:
        duration = duration_ms(effect_record if hit_source == "effect" else ani_record)
        repeat = max(1, ticks)
        span = max(160.0, duration / repeat)
        for tick in range(repeat):
            hit = {
                "percent_col": column,
                "atk": atk_path,
                "effects": statuses or [],
            }
            if hit_source == "body":
                hit["body"] = True
            else:
                effect_key = add_fx(fx, effects, effect_path)
                hit["derived"] = effect_key
                hit["window"] = [tick * span, min(duration, (tick + 1) * span)]
            hits.append(hit)
    stage = {"ani": ani, "atk": atk_path, "hits": hits}
    if effect_path:
        effect_key = add_fx(fx, effects, effect_path)
        if effect_key != "":
            stage.setdefault("fx", []).append({"key": effect_key, "at": 0})
    return stage


def passive_modifiers(record: dict) -> list[dict]:
    decoded = record.get("decoded", {})
    return decoded.get("passive", []) if isinstance(decoded.get("passive"), list) else []


def generic_passive_spec(key: str) -> dict:
    """Give non-tree general/EX passives explicit runtime semantics."""
    base = re.sub(r"(?:exp|ex)$", "", key)
    if base != key:
        return {"enhances": LOCAL_IDS.get(base, base), "enhancement": "source_override"}
    if "physicalbackattackcritical" == key:
        return {"passive": [{"stat": "physical_back_crit", "op": "add", "level_row": 0, "scale": 0.001}]}
    if "magicalbackattackcritical" == key:
        return {"passive": [{"stat": "magical_back_crit", "op": "add", "level_row": 0, "scale": 0.001}]}
    if key == "physicalcriticalhitup":
        return {"passive": [{"stat": "physical_crit", "op": "add", "level_row": 0, "scale": 0.001}]}
    if key == "magicalcriticalhitup":
        return {"passive": [{"stat": "magical_crit", "op": "add", "level_row": 0, "scale": 0.001}]}
    if key == "basichpmaxup":
        return {"passive": [{"stat": "hp_max", "op": "add", "level_row": 0, "scale": 1.0}]}
    if key == "basicattackup":
        return {"passive": [{"stat": "physical_attack", "op": "percent", "level_row": 0, "scale": 0.001}]}
    if key == "throwmastery":
        # Original SKL text limits this to thrown-item damage (excluding a
        # secondary hit such as a fire bottle), with MP consumed per throw.
        # There is no thrown-item consumer yet. Do not turn its level column
        # into a global fixed-damage stat while that pipeline is unresolved.
        return {"runtime_hook": "throw_item_mastery", "runtime_status": "pending_throw_item_pipeline"}
    if key == "jumppowerup":
        return {"passive": [{"stat": "jump_power", "op": "add", "level_row": 0, "scale": 1.0}]}
    if key == "magicalattackup":
        return {"passive": [{"stat": "magical_attack", "op": "percent", "level_row": 0, "scale": 0.001}]}
    if key == "statusup":
        return {"passive": [{"stat": "status_resist", "op": "add", "level_row": 0, "scale": 0.001}]}
    if key == "experienceup":
        return {"profile_bonus": {"experience_rate": 0.1}}
    if key.startswith("armormastery"):
        armor_type = "cloth"
        for value in ["plate", "heavy", "light", "leather", "cloth"]:
            if value in key:
                armor_type = value
                break
        return {
            "armor_mastery": {
                "type": armor_type,
                "preset": "generic",
                "modifiers": [
                    {"stat": "physical_defense", "op": "add", "value": 20},
                    {"stat": "magical_defense", "op": "add", "value": 20},
                    {"stat": "hp_max", "op": "percent", "value": 0.03},
                ],
            }
        }
    return {"runtime_hook": "declarative_passive", "effect_domain": key}


def mastery_passive(weapon: str) -> dict:
    return {
        "mastery": True,
        "passive": [
            {"stat": "physical_attack", "op": "percent", "level_row": 0, "scale": 0.001, "weapon": weapon},
            {"stat": "magical_attack", "op": "percent", "level_row": 1, "scale": 0.001, "weapon": weapon},
            {"stat": "hit", "op": "add", "level_row": 2, "scale": 0.001, "weapon": weapon},
        ]
    }


PASSIVE_BUILDERS = {
    "lightswordmastery": mastery_passive("beamsword"),
    "shortswordmastery": mastery_passive("shortsword"),
    "blademastery": mastery_passive("katana"),
    "heavyswordmastery": mastery_passive("greatsword"),
    "bluntmastery": mastery_passive("club"),
    "weaponmasteryup": {
        "mastery_bonus": True,
        "mastery_levels_per_rank": 2,
        "mastery_fields": ["shortswordmastery", "heavyswordmastery", "bluntmastery", "blademastery"],
    },
    "darkfriendship": {
        "passive": [
            {"stat": "dark_resist", "op": "add", "value": 20},
            {"stat": "light_resist", "op": "add", "value": -10},
        ]
    },
    "equiplightsword": {"unlock_weapon": "beamsword"},
    "ghostpowerup": {
        "skill_level_bonus": {
            "khazan": 1,
            "saya": 1,
            "bremen": 1,
            "epidemicrasa": 1,
            "kalla": 1,
            "hardattack": 1,
        },
        "skill_damage_bonus": {"khazan": 0.1, "bremen": 0.1},
    },
    "fastequip": {
        "weapon_switch_cooldown_rate": 0.5,
        "weapon_switch_buff": {"damage_rate": 0.1, "physical_crit": 0.1, "duration_ms": 5000},
    },
    "durabilityup": {"durability_rate": 0.96},
    "mindflash": {"on_hurt": {"effect": "mindflash", "max_stacks": 5}},
    "senseviolenttemper": {
        "passive": [
            {"stat": "status_resist", "op": "add", "value": 1.0},
            {"stat": "evasion", "op": "add", "value": 0.03},
        ]
    },
    "pinchpowerup": {
        "dynamic": "low_hp",
        "threshold": 0.4,
        "rows": {
            "strength": [0, 1],
            "evasion": [2, 3],
            "attack_speed": [4, 5],
            "move_speed": [6, 7],
        },
    },
    "hardattackcharge": {"unlock": "hardattack_charge"},
    "bloodyvigorous": {"unlock": "gorecross_hp_cost", "bleed_bonus": 0.4},
    "moonlightslashfull": {"unlock": "moonlight_full"},
    "grandwavecharge": {"unlock": "grandwave_charge"},
    "darkaura": {"aura": {"radius_from_row": 0, "enemy": {"dark_resist": -40, "attack_speed": 0.95}}},
    "bleedingmastery": {"dynamic": "bleeding_stacks", "max_stacks": 5},
    "defensedownoncritical": {"on_critical": {"effect": "defense_down", "duration_ms": 10000, "max_stacks": 10}},
    "stuckuponcounter": {"on_counter_evasion": 0.6},
    "armormasteryclothsb": {
        "armor_mastery": {
            "type": "cloth",
            "preset": "soulbringer",
            "modifiers": [
                {"stat": "mp_max", "op": "percent", "value": 0.06},
                {"stat": "hp_max", "op": "percent", "value": 0.15},
                {"stat": "mp_regen", "op": "percent", "value": 0.24},
                {"stat": "move_speed", "op": "percent", "value": 0.02},
                {"stat": "cast_speed", "op": "percent", "value": 0.03},
                {"stat": "intelligence", "op": "add", "value": 12},
            ],
        }
    },
    "armormasterylightwm": {
        "armor_mastery": {
            "type": "light",
            "preset": "weaponmaster",
            "modifiers": [
                {"stat": "strength", "op": "add", "value": 4},
                {"stat": "vitality", "op": "add", "value": 10},
                {"stat": "spirit", "op": "add", "value": 10},
                {"stat": "mp_max", "op": "percent", "value": 0.04},
                {"stat": "hp_max", "op": "percent", "value": 0.2},
                {"stat": "mp_regen", "op": "percent", "value": 0.18},
                {"stat": "hit_recovery", "op": "add", "value": 100},
            ],
        }
    },
    "armormasteryheavybk": {
        "armor_mastery": {
            "type": "heavy",
            "preset": "berserker",
            "modifiers": [
                {"stat": "strength", "op": "add", "value": 20},
                {"stat": "spirit", "op": "add", "value": 10},
                {"stat": "mp_max", "op": "percent", "value": 0.06},
                {"stat": "hp_max", "op": "percent", "value": 0.15},
                {"stat": "physical_defense", "op": "add", "value": 200},
            ],
        }
    },
    "armormasteryplatewave": {
        "armor_mastery": {
            "type": "plate",
            "preset": "asura",
            "modifiers": [
                {"stat": "intelligence", "op": "add", "value": 20},
                {"stat": "spirit", "op": "add", "value": 10},
                {"stat": "mp_max", "op": "percent", "value": 0.08},
                {"stat": "hp_max", "op": "percent", "value": 0.2},
                {"stat": "cast_speed", "op": "percent", "value": 0.1},
            ],
        }
    },
}


def build_skill_definition(skill: dict, record: dict) -> dict:
    decoded = record.get("decoded", {})
    active = skill.get("type") == "[active]"
    key = str(skill["key"])
    definition = {
        "source_id": int(skill["id"]),
        "source_path": str(skill["path"]),
        "path": str(skill["path"]),
        "name": str(skill["name"]),
        "active": active,
        "speed": "cast" if key in BUFF_SKILLS else "attack",
        "max_level": int(skill.get("max_level") or decoded.get("max_level") or 1),
        "cost": int(skill.get("purchase_cost") or 0),
        "growtype_max_level": skill.get("growtype_max_level", []),
    }
    if active:
        definition["move"] = local_id(key)
    if key in PASSIVE_BUILDERS:
        definition.update(PASSIVE_BUILDERS[key])
    elif not active:
        definition.update(generic_passive_spec(key))
    return definition


def build_move(
    skill: dict,
    records: dict,
    atk_by_stem: dict[str, list[str]],
    effect_paths: list[str],
    fx: dict[str, str],
    effects: dict[str, dict],
    objects: dict[str, str],
) -> dict | None:
    if skill.get("type") != "[active]":
        return None
    key = str(skill["key"])
    move_id = local_id(key)
    stages: list[dict] = []
    statuses = HIT_STATUS.get(key, [])
    if key == "backstep":
        # SKL describes a backward hop. Dispatch to the existing movement state;
        # a summon animation plus a one-millisecond effect cannot implement it.
        return {"skill": str(skill["path"]), "name": str(skill["name"]),
                "movement": "backstep", "stages": [{"ani": "jump", "atk": "", "hits": []}]}
    if key in BUFF_SKILLS:
        stages.append({"ani": CAST_ANIM, "atk": "", "hits": []})
        effect_path = pick_effect(key, effect_paths, skill_key=key)
        if effect_path:
            stages[0]["fx"] = [{"key": add_fx(fx, effects, effect_path), "at": 0}]
        return {
            "skill": str(skill["path"]),
            "name": str(skill["name"]),
            "stages": stages,
            "effect_id": BUFF_SKILLS[key],
            **({"hp_cost_row": 0} if key == "frenzy" else {}),
        }
    names = STAGE_NAMES.get(key, [])
    names = STAGE_ANI_OVERRIDES.get(key, names)
    if not names and key in CAST_OBJECTS:
        names = [CAST_ANIM]
    if not names:
        exact = CHR_ANI + key + ".ani"
        numbered = sorted(
            path
            for path in records
            if path.startswith(CHR_ANI + key)
            and path.endswith(".ani")
            and re.match(re.escape(key) + r"\d+$", Path(path).stem)
        )
        if exact in records:
            names = [key]
        elif numbered:
            names = [Path(path).stem for path in numbered]
    if not names:
        names = [CAST_ANIM]
    repeat, interval = AREA_REPEATS.get(key, (1, 350))
    for index, ani in enumerate(names):
        atk_override = ""
        atks = STAGE_ATK_OVERRIDES.get(key, [])
        if index < len(atks):
            atk_override = atks[index]
        hit_ani = ""
        hit_anis = STAGE_EFFECT_OVERRIDES.get(key, [])
        if index < len(hit_anis):
            hit_ani = hit_anis[index]
        stages.append(
            build_stage(
                key,
                index,
                ani,
                records,
                atk_by_stem,
                effect_paths,
                fx,
                effects,
                hit_ani=hit_ani,
                atk_override=atk_override,
                percent_col=index,
                ticks=repeat if index == len(names) - 1 else 1,
                interval_ms=interval,
                statuses=statuses,
            )
        )
    if stages and not any(stage.get("hits") for stage in stages) and key not in BUFF_SKILLS and not (
        key in CAST_OBJECTS and CAST_OBJECTS[key][0] in SAFE_OBJECTS
        or DIRECT_OBJECTS.get(key) and DIRECT_OBJECTS[key][0] in SAFE_OBJECTS
    ):
        generic_record = records.get(GENERIC_HIT_EFFECT, {})
        if generic_record:
            duration = max(200.0, duration_ms(generic_record))
            generic_key = add_fx(fx, effects, GENERIC_HIT_EFFECT)
            stages[-1].setdefault("hits", []).append(
                {
                    "derived": generic_key,
                    "window": [0, duration],
                    "percent_col": 0,
                    "atk": pick_attack(Path(key).stem, atk_by_stem),
                    "effects": statuses,
                }
            )
            stages[-1].setdefault("fx", []).append({"key": generic_key, "at": 0})
    object_spec = DIRECT_OBJECTS.get(key)
    if object_spec:
        path, at, speed, life = object_spec
        object_path = add_object(objects, path)
        if object_path and stages:
            stages[-1].setdefault("hits", []).append(
                {
                    "object": object_path,
                    "at": at,
                    "speed": speed,
                    "life_ms": life,
                    "percent_col": 0,
                }
            )
    if key in CAST_OBJECTS:
        path, at, speed, life = CAST_OBJECTS[key]
        if path:
            object_path = add_object(objects, path)
            if object_path:
                stages[-1].setdefault("hits", []).append(
                    {
                        "object": object_path,
                        "at": at,
                        "speed": speed,
                        "life_ms": life,
                        "percent_col": 0,
                        "effects": statuses,
                    }
                )
    result = {"skill": str(skill["path"]), "name": str(skill["name"]), "stages": stages}
    if key == "normalwave":
        # SKL [level property]: percent <- (-1,2,1), fixed <- (-2,0,1),
        # size percent <- (-1,1,1). The generic column-zero attack loses both
        # the real percentage and independent-attack term. Full movement and
        # cancel semantics still require further native-code tracing.
        # Native CNSwordman state 24: CHR etc motion 9, frame 0 hold,
        # resume at frame 1, attach skill20 FX, create object at frame 3.
        wave = records[CHR_ANI + "wave.ani"]["decoded"]
        delays = [int(f["end_ms"]-f["start_ms"]) for f in wave["timeline"]]
        slash = add_fx(fx, effects, CHR_FX + "normalwaveslash.ani")
        result["native_state"] = "normalwave"
        stages[:] = [{"ani": "wave", "atk": "", "hits": [{
            "object": OBJ_ROOT + "normalwave.obj", "at": sum(delays[:3]),
            "speed": 0.0, "life_ms": -1, "percent_col": 2, "fixed_col": 0, "size_col": 1,
        }], "fx": [{"key": slash, "at": delays[0], "action_clock": True}]}]
    if key in ("icewave", "firewave"):
        # 0xCC899D CHR motion 9; 0xCC8B05 trigger frame4. Unlike skill20,
        # these branches keep CAST speed (0xCC8A06) and zero movement.
        # Object sub-behaviour remains an explicit incomplete adapter below.
        wave = records[CHR_ANI + "wave.ani"]["decoded"]
        delays = [int(f["end_ms"]-f["start_ms"]) for f in wave["timeline"]]
        effect = CHR_FX + ("icewave.ani" if key == "icewave" else "firewavebig-sword-effect.ani")
        effect_key = add_fx(fx, effects, effect)
        path, _, speed, life = CAST_OBJECTS[key]
        object_path = add_object(objects, path)
        if not effect_key or not object_path:
            raise ValueError(f"Missing verified wave binding: {key}")
        result["native_state"] = "wave_cast"
        result["native_recovery_col"] = 1 if key == "icewave" else 0
        result["fidelity_pending"] = ["object_controller", "damage_and_status", "effect_weapon_scale", "cancel_rules", "voice"]
        stages[:] = [{"ani": "wave", "atk": "", "hits": [{
            "object": path, "at": sum(delays[:4]), "speed": speed,
            "life_ms": life, "percent_col": 0, "effects": statuses,
            "offset": [100, -4, 0] if key == "icewave" else [0, 0, 0],
        }], "fx": [{"key": effect_key, "at": delays[0], "action_clock": True, "offset_x": 59}]}]
        if key == "icewave":
            # 0xA6E6B4 -> 0x90A950: fixed magic uses column 3, not column 0.
            hit = stages[0]["hits"][0]
            del hit["percent_col"]
            # CNIceWave::proc (A6EF60 protected path): stationary pillars,
            # 100ms static[0], six object IDs wrapping 20007 -> 20002.
            pillars = [add_object(objects, OBJ_ROOT + f"icewave{i}.obj") for i in range(1, 7)]
            if not all(pillars):
                raise ValueError("Missing native icewave chain objects")
            interval = records[str(skill["path"])]["decoded"]["dungeon"]["static_data"][0]
            hit.update(percent=0, fixed_col=3, native_controller={
                "kind": "icewave_chain", "objects": pillars, "interval_ms": interval,
                "count_col": 1, "frame2_at_col": 0,
                "initial_size": 1.5, "size_step": 0.075,
                "gap_base": 21, "gap_step": 1.2,
            })
            result["fidelity_pending"].remove("object_controller")
            result["fidelity_pending"].extend(["object_ground_authority_rules", "object_create_sound"])
            result["fidelity_pending"].remove("damage_and_status")
            result["fidelity_pending"].append("status_level_resistance_formula")
        else:
            # Native 20024 -> 20025: fixed columns 0/1; ANI-end successor at
            # +/-360, then deletion. See audit_dnf_firewave.py, not file names.
            hit = stages[0]["hits"][0]
            del hit["percent_col"]
            rear = add_fx(fx, effects, OBJ_ROOT + "animation/firewavebig/fire-back.ani")
            blast_rear = add_fx(fx, effects, OBJ_ROOT + "animation/firewavebig/blast-back.ani")
            successor = add_object(objects, OBJ_ROOT + "firewavebigsub.obj")
            if not rear or not blast_rear or not successor:
                raise ValueError("Missing original firewave two-stage dependency")
            hit.update(percent=0, fixed_col=0, speed=0, life_ms=-1, effects=[], rear_fx=rear,
                       native_controller={"kind": "firewave_chain", "child": {
                           "object": successor, "at": 0, "offset": [360, 0, 0],
                           "percent": 0, "fixed_col": 1, "speed": 0, "life_ms": -1,
                           "effects": [], "rear_fx": blast_rear}})
            result["fidelity_pending"].remove("object_controller")
            result["fidelity_pending"].remove("damage_and_status")
            result["fidelity_pending"].extend(["fixed_stat_formula", "object_ground_authority_rules", "object_create_sound", "ani_box_scale", "draw_layer_and_blend_quantization"])
    if key in ["bloodyrave", "outragebreak"]:
        result["requires_effect"] = "frenzy"
    if key == "outragebreak":
        result["hp_cost_row"] = 0
    return result


def mastery_variants() -> dict:
    """Conditional stage extension required by the source descriptions."""
    return {
        "triple": [
            {
                "priority": 20,
                "job": "weaponmaster",
                "weapon": ["beamsword", "katana"],
                "skill": {"lightswordmastery": 5, "blademastery": 5},
                "skill_mode": "any",
                "replace_stages": ["tripleslash1", "tripleslash2", "tripleslash3", "tripleslash4", "tripleslash5"],
                "final_lift": 350,
            }
        ],
        "draw": [
            {
                "priority": 20,
                "job": "weaponmaster",
                "weapon": ["beamsword", "katana"],
                "skill": {"lightswordmastery": 7, "blademastery": 7},
                "skill_mode": "any",
                "append_stage": "momentaryslash",
                "append_effect": "momentaryslashwave.obj",
            },
            {
                "priority": 15,
                "job": "weaponmaster",
                "weapon": ["shortsword"],
                "skill": {"shortswordmastery": 7},
                "append_stage": "momentaryslash",
                "append_object": OBJ_ROOT + "momentaryslashwave.obj",
            }
        ],
        "charge_crash": [
            {
                "priority": 20,
                "job": "weaponmaster",
                "weapon": ["greatsword", "club"],
                "skill": {"heavyswordmastery": 7, "bluntmastery": 7},
                "skill_mode": "any",
                "append_stage": "chargecrashfinish",
            }
        ],
        "guard": [
            {
                "priority": 20,
                "job": "weaponmaster",
                "weapon": ["shortsword", "greatsword", "club"],
                "skill": {"shortswordmastery": 5, "heavyswordmastery": 5, "bluntmastery": 5},
                "skill_mode": "any",
                "append_object": OBJ_ROOT + "guardwave.obj",
            }
        ],
        "upper": [
            {
                "priority": 20,
                "job": "weaponmaster",
                "weapon": ["shortsword"],
                "skill": {"shortswordmastery": 3},
                "append_stage": "upperslashafter",
            }
        ],
        "rapidmoveslash": [
            {
                "priority": 20,
                "job": "weaponmaster",
                "weapon": ["shortsword"],
                "skill": {"shortswordmastery": 7},
                "append_hits": 2,
            }
        ],
        "ashenfork": [
            {
                "priority": 20,
                "job": "weaponmaster",
                "weapon": ["greatsword"],
                "skill": {"heavyswordmastery": 3},
                "append_hits": 2,
                "append_object": OBJ_ROOT + "ashenforksub.obj",
            }
        ],
        "hopsmash": [
            {
                "priority": 20,
                "job": "berserker",
                "append_hits": 1,
            }
        ],
        "weaponcombo": [
            {
                "priority": 40,
                "weapon": ["beamsword", "katana", "shortsword"],
                "replace_stages": [
                    "weaponcombolight1",
                    "weaponcombolight2",
                    "weaponcombolight3",
                ],
            },
            {
                "priority": 35,
                "weapon": ["greatsword"],
                "replace_stages": ["weaponcomboheavy1", "weaponcomboheavy2"],
            },
            {
                "priority": 35,
                "weapon": ["club"],
                "replace_stages": [
                    "weaponcomboblunt1",
                    "weaponcomboblunt2",
                    "weaponcomboblunt3",
                ],
            },
        ],
        "hardattack": [
            {
                "priority": 25,
                "job": "soulbringer",
                "skill": {"hardattackcharge": 1},
                "append_stage": "hardattackchargeafter",
                "append_object": OBJ_ROOT + "hardattackchargeafter.obj",
            }
        ],
        "grandwave": [
            {
                "priority": 20,
                "job": "asura",
                "skill": {"grandwavecharge": 1},
                "append_object": OBJ_ROOT + "grandwavefullcharge.obj",
            }
        ],
        "rage_slash": [
            {
                "priority": 20,
                "job": "berserker",
                "append_stage": "gorecross",
                "append_hits": 1,
                "append_status": {"id": "bleed", "chance": 0.4},
            }
        ],
        "moonlight": [
            {
                "priority": 20,
                "job": "soulbringer",
                "skill": {"moonlightslashfull": 1},
                "append_stage": "moonlightslashfull",
            }
        ],
    }


def build_variant_moves(
    variants: dict,
    moves: dict,
    records: dict,
    atk_by_stem: dict[str, list[str]],
    effect_paths: list[str],
    fx: dict[str, str],
    effects: dict[str, dict],
    player_anims: dict[str, str],
    objects: dict[str, str],
) -> None:
    stage_names = {
        "tripleslash4": "tripleslash4",
        "tripleslash5": "tripleslash5",
        "momentaryslash": "momentaryslash",
        "chargecrashfinish": "chargecrashfinish",
        "gorecross": "gorecross",
        "moonlightslashfull": "moonlightslashfull",
    }
    for base_id, options in variants.items():
        base = moves.get(base_id)
        if not base:
            continue
        for option_index, option in enumerate(options):
            variant_id = f"{base_id}__variant_{option_index + 1}"
            stages: list[dict] = []
            names = option.get("replace_stages", [])
            if names:
                for index, ani in enumerate(names):
                    stage = build_stage(
                        base_id,
                        index,
                        stage_names.get(ani, ani),
                        records,
                        atk_by_stem,
                        effect_paths,
                        fx,
                        effects,
                        percent_col=index,
                    )
                    stages.append(stage)
                    player_anims[stage["ani"]] = CHR_ANI + stage["ani"] + ".ani"
            else:
                stages = json.loads(json.dumps(base.get("stages", [])))
                append_name = str(option.get("append_stage", ""))
                if append_name:
                    ani = stage_names.get(append_name, append_name)
                    stage = build_stage(
                        base_id,
                        len(stages),
                        ani,
                        records,
                        atk_by_stem,
                        effect_paths,
                        fx,
                        effects,
                        percent_col=len(stages),
                    )
                    if stage.get("hits"):
                        stages.append(stage)
                        player_anims[stage["ani"]] = CHR_ANI + stage["ani"] + ".ani"
                append_hits = int(option.get("append_hits", 0))
                if append_hits and stages and stages[-1].get("hits", []):
                    for _ in range(append_hits):
                        stages[-1].setdefault("hits", []).append(
                            {
                                "derived": stages[-1]["hits"][0].get("derived", ""),
                                "window": [0, 240],
                                "percent_col": min(
                                    len(stages) - 1,
                                    max(0, len(stages[-1].get("hits", []))),
                                ),
                                "atk": stages[-1].get("atk", ""),
                                "effects": [option.get("append_status", {})]
                                if option.get("append_status")
                                else [],
                            }
                        )
                append_object = str(option.get("append_object", ""))
                if append_object and stages:
                    objects[append_object] = append_object
                    stages[-1].setdefault("hits", []).append(
                        {
                            "object": append_object,
                            "at": 220,
                            "speed": 0.0,
                            "life_ms": 1200,
                            "percent_col": 0,
                        }
                    )
            if stages and not any(stage.get("hits") for stage in stages):
                generic_key = add_fx(fx, effects, GENERIC_HIT_EFFECT)
                if generic_key != "":
                    stages[-1].setdefault("hits", []).append(
                        {
                            "derived": generic_key,
                            "window": [0, 240],
                            "percent_col": 0,
                            "atk": stages[-1].get("atk", ""),
                        }
                    )
            variant_move = {
                "skill": base.get("skill", ""),
                "name": base.get("name", ""),
                "stages": stages,
            }
            if base.get("effect_id"):
                variant_move["effect_id"] = base["effect_id"]
            moves[variant_id] = variant_move
            option["move"] = variant_id


def build_frenzy_normals(
    moves: dict,
    records: dict,
    atk_by_stem: dict[str, list[str]],
    effect_paths: list[str],
    fx: dict[str, str],
    effects: dict[str, dict],
    player_anims: dict[str, str],
) -> None:
    """Frenzy replaces the normal X chain with the source four-swing chain."""
    names = ["frenzy1", "frenzy2", "frenzy3", "frenzy4"]
    for index, ani in enumerate(names):
        stage = build_stage(
            "frenzy",
            index,
            ani,
            records,
            atk_by_stem,
            effect_paths,
            fx,
            effects,
            percent_col=index,
            statuses=[{"id": "bleed", "chance": 1.0}],
        )
        if not stage.get("hits"):
            stage["hits"] = [
                {
                    "derived": add_fx(fx, effects, GENERIC_HIT_EFFECT),
                    "window": [0, max(180.0, duration_ms(records.get(CHR_ANI + ani + ".ani", {})))],
                    "percent_col": index,
                    "atk": pick_attack(ani, atk_by_stem),
                    "effects": [{"id": "bleed", "chance": 1.0}],
                }
            ]
        moves[ani] = {
            "skill": "skill/swordman/frenzy.skl",
            "name": "血之狂暴 · 双刀普攻",
            "stages": [stage],
            "next": names[(index + 1) % len(names)],
        }
        player_anims[ani] = CHR_ANI + ani + ".ani"


def build_form_normals(
    moves: dict,
    records: dict,
    atk_by_stem: dict[str, list[str]],
    effect_paths: list[str],
    fx: dict[str, str],
    effects: dict[str, dict],
    player_anims: dict[str, str],
) -> None:
    forms = {
        "ghoststep_attack": {
            "skill": "skill/swordman/ghoststep.skl",
            "name": "鬼影步 · 暗属性普攻",
            "anims": ["attack1", "attack2", "attack3"],
            "damage_type": "magical",
            "element": "dark",
        },
        "kalla_attack": {
            "skill": "skill/swordman/kalla.skl",
            "name": "冥炎剑 · 三连击",
            "anims": ["kallafinish1", "kallafinish2", "kallafinish3"],
            "damage_type": "magical",
            "element": "dark",
        },
        "waveeye_attack": {
            "skill": "skill/swordman/waveeye.skl",
            "name": "暗天波动眼 · 波动普攻",
            "anims": ["waveeyeattack1", "waveeyeattack2", "waveeyeattack3"],
            "damage_type": "magical",
            "element": "none",
        },
    }
    for prefix, spec in forms.items():
        names = spec["anims"]
        for index, ani in enumerate(names):
            stage = build_stage(
                "kalla" if prefix == "kalla_attack" else "waveeye" if prefix == "waveeye_attack" else "ghoststep",
                index,
                ani,
                records,
                atk_by_stem,
                effect_paths,
                fx,
                effects,
                percent_col=index,
            )
            if not stage.get("hits"):
                stage["hits"] = [
                    {
                        "derived": add_fx(fx, effects, GENERIC_HIT_EFFECT),
                        "window": [0, max(180.0, duration_ms(records.get(CHR_ANI + ani + ".ani", {})))],
                        "percent_col": index,
                        "atk": pick_attack(ani, atk_by_stem),
                    }
                ]
            for hit in stage["hits"]:
                hit["damage_type"] = spec["damage_type"]
                hit["element"] = spec["element"]
            move_id = f"{prefix}{index + 1}"
            moves[move_id] = {
                "skill": spec["skill"],
                "name": spec["name"],
                "stages": [stage],
            }
            if index + 1 < len(names):
                moves[move_id]["next"] = f"{prefix}{index + 2}"
            player_anims[ani] = CHR_ANI + ani + ".ani"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, default=CATALOG)
    parser.add_argument("--pack", type=Path, default=PACK)
    parser.add_argument("--output", type=Path, default=OUTPUT)
    args = parser.parse_args()

    catalog = json.loads(args.catalog.read_text(encoding="utf-8"))
    pack = json.loads(args.pack.read_text(encoding="utf-8"))
    records = pack["records"]
    by_id = {int(skill["id"]): skill for skill in catalog["skills"]}
    tree_ids = {
        int(node["id"])
        for branch in catalog["trees"]["sp"]
        for node in branch["nodes"]
    }
    all_ids = sorted(by_id)
    atk_by_stem = attack_paths(records)
    effect_paths = anim_paths(records, CHR_FX) + anim_paths(records, OBJ_ROOT + "animation/")
    for paths in STAGE_EFFECT_OVERRIDES.values():
        effect_paths.extend(path for path in paths if path in records)
    effect_paths = sorted(set(effect_paths))
    library = open_library()
    try:
        SAFE_EFFECTS.clear()
        SAFE_EFFECTS.update(path for path in effect_paths if supported_animation_binding(library, path))
        object_candidates = {
            value[0]
            for value in CAST_OBJECTS.values()
            if value[0]
        } | {
            value[0]
            for value in DIRECT_OBJECTS.values()
            if value and value[0]
        }
        object_candidates.update(OBJ_ROOT + f"icewave{i}.obj" for i in range(1, 7))
        object_candidates.add(OBJ_ROOT + "firewavebigsub.obj")
        SAFE_OBJECTS.clear()
        SAFE_OBJECTS.update(
            path for path in object_candidates if safe_object(library, records, path)
            and supported_animation_binding(library, (records[path]["decoded"].get("basic_motion") or records[path]["decoded"].get("etc_motions"))[0])
        )
    finally:
        library.close()
        if IMAGE_DB is not None:
            IMAGE_DB.close()
    fx: dict[str, str] = {}
    effects: dict[str, dict] = {key: value for key, value in ROOT_EFFECTS.items()}
    effects.update(BUFF_EFFECTS)
    objects: dict[str, str] = {}
    skills: dict[str, dict] = {}
    moves: dict[str, dict] = {}
    player_anims: dict[str, str] = {}

    for skill_id in all_ids:
        skill = by_id[skill_id]
        record = records.get(str(skill["path"]).lower())
        if record is None:
            raise FileNotFoundError(str(skill["path"]))
        key = str(skill["key"])
        runtime_id = local_id(key)
        definition = build_skill_definition(skill, record)
        definition["tree_visible"] = skill_id in tree_ids
        skills[runtime_id] = definition
        base_move_id = EX_BASE.get(key, "")
        move = moves.get(base_move_id) if base_move_id else None
        if move:
            move = json.loads(json.dumps(move))
            move["skill"] = str(skill["path"])
            move["name"] = str(skill["name"])
            if key == "icewaveex":
                # EX uses different IDs/sizing/branches. Do not inherit a base-only controller.
                move["fidelity_pending"].insert(move["fidelity_pending"].index("object_ground_authority_rules"), "ice_shatter_particles")
                for stage in move["stages"]:
                    for hit in stage.get("hits", []):
                        hit.pop("native_controller", None)
                        hit.update(speed=240.0, life_ms=1800)
                move["fidelity_pending"].append("object_controller")
            if key == "firewaveex":
                # EX 20101 has additional timer/ANI/controller branches. Keep
                # its previous adapter until those paths have source evidence.
                for stage in move["stages"]:
                    for hit in stage.get("hits", []):
                        for field in ("native_controller", "rear_fx", "fixed_col", "percent"):
                            hit.pop(field, None)
                        hit.update(speed=360.0, life_ms=1800, percent_col=0, effects=HIT_STATUS["firewave"])
                move["fidelity_pending"] = ["object_controller", "damage_and_status", "effect_weapon_scale", "cancel_rules", "voice"]
        else:
            move = build_move(skill, records, atk_by_stem, effect_paths, fx, effects, objects)
        if move:
            moves[runtime_id] = move
            for stage in move.get("stages", []):
                ani = str(stage.get("ani", ""))
                if ani:
                    player_anims[ani] = CHR_ANI + ani + ".ani"
            if key == "frenzy":
                for ani in ["frenzy1", "frenzy2", "frenzy3", "frenzy4"]:
                    player_anims[ani] = CHR_ANI + ani + ".ani"

    variants = mastery_variants()
    build_variant_moves(
        variants,
        moves,
        records,
        atk_by_stem,
        effect_paths,
        fx,
        effects,
        player_anims,
        objects,
    )
    build_frenzy_normals(
        moves,
        records,
        atk_by_stem,
        effect_paths,
        fx,
        effects,
        player_anims,
    )
    build_form_normals(
        moves,
        records,
        atk_by_stem,
        effect_paths,
        fx,
        effects,
        player_anims,
    )
    document = {
        "schema": SCHEMA,
        "source": {
            "catalog": str(args.catalog.relative_to(ROOT)).replace("\\", "/"),
            "pack": str(args.pack.relative_to(ROOT)).replace("\\", "/"),
            "pack_sha256": hashlib.sha256(args.pack.read_bytes()).hexdigest(),
            "asset_version": pack.get("asset_version", ""),
            "builder": "tools/build_dnf_skill_runtime.py",
            "fidelity": "unverified_engine_adapters; catalog coverage is not original fidelity",
        },
        "skill_count": len(skills),
        "tree_skill_count": len(tree_ids),
        "tree_active_count": sum(
            1
            for value in skills.values()
            if value["active"] and value.get("tree_visible", False)
        ),
        "tree_passive_count": sum(
            1
            for value in skills.values()
            if not value["active"] and value.get("tree_visible", False)
        ),
        "active_count": sum(1 for value in skills.values() if value["active"]),
        "passive_count": sum(1 for value in skills.values() if not value["active"]),
        "skills": skills,
        "moves": moves,
        "variants": variants,
        "effects": effects,
        "assets": {
            "player_anims": dict(sorted(player_anims.items())),
            "effect_anims": dict(sorted(fx.items())),
            "objects": dict(sorted(objects.items())),
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(document, ensure_ascii=False, indent=1, sort_keys=True) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    print(
        "[SKILL_RUNTIME] tree=%d active=%d passive=%d moves=%d effects=%d "
        "player_anims=%d effect_anims=%d objects=%d"
        % (
            document["skill_count"],
            document["active_count"],
            document["passive_count"],
            len(moves),
            len(effects),
            len(player_anims),
            len(fx),
            len(objects),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
