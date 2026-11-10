"""Build the generated Swordman skill runtime from archived source records.

The source of truth is:
  - game_dnf/data/skill_catalog.json (175 SKLs and five SP trees)
  - game_dnf/assets_local/content/combat_content.json (SKL/ANI/ATK/OBJ/PTL)
  - pinned passive-object animation layer script for ordinary Blood Blast
  - pinned dungeon fixed-attack base table used by Blood Blast
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
from pathlib import Path, PurePosixPath

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dnf_pvf import decode_tokens, open_library


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
BLOODBLAST_LAYER_SCRIPT = OBJ_ROOT + "animation/blastblood1.ani.als"
ILLUSION_CLUB_LAYER_SCRIPT = OBJ_ROOT + "animation/illusionslashsub/1_shockwave_dodge.ani.als"
FIXED_ATTACK_BASE_SOURCE = "etc/etcparameter.etc"
DRAW_SHOCK_STATUS_SOURCE = "etc/activestatustable_ex.etc"

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
        "hundredswordmoveready1",
        "hundredswordmoveready2",
        "hundredswordmoveready3",
        "hundredswordmoveready4",
        "hundredswordmoveready5",
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

# C9F238, C9F35D and C9F4B5 index four columns per native weapon subtype.
WEAPON_COMBO_VARIANTS = {
    "shortsword": ("short", (1, 2, 3), (4, 5), "weapon_combo_short_finish"),
    "katana": ("blade", (1, 2, 3, 4), (3, 4, 4), "weapon_combo_blade_finish"),
    "club": ("blunt", (1, 2, 2, 3), (4, 5, 5), "weapon_combo_blunt_finish"),
    "greatsword": ("heavy", (1, 2), (5,), "weapon_combo_heavy_finish"),
    "beamsword": ("light", (1, 2, 3), (3, 3), "weapon_combo_light_finish"),
}
# CD4D98 gives the six original slots orders -3,-2,-1,1,2,3. The trailing
# slots omitted here have no IMG in the source phase's ANI.
WEAPON_COMBO_LIGHT_DEPTHS = ((-3, -2, -1, 1, 2), (-3, -2, -1, 1, 2), (-3, -2, -1, 1))

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
GHOST_FIELD_SKILLS = ("khazan", "bremen", "saya", "sayaex")
RASA_CREATOR = OBJ_ROOT + "epidemicrasacreater.obj"
RASA_CHILD = OBJ_ROOT + "epidemicrasa.obj"
RASA_ANIMATION = OBJ_ROOT + "animation/epidemicrasa/"
CAST_OBJECTS = {
    "ashenfork": (OBJ_ROOT + "ashenforksub.obj", 260, 0.0, 700),
    # Native object 20001 (0x9EBAF0) dies at ANI end. Its OBJ supplies no
    # travel controller; the image/box positions already advance within ANI.
    # Its native-state adapter below supplies the source-frame trigger.
    "normalwave": (OBJ_ROOT + "normalwave.obj", 0, 0.0, -1),
    "icewave": (OBJ_ROOT + "icewave1.obj", 360, 0.0, -1),
    "firewave": (OBJ_ROOT + "firewavebig.obj", 420, 360.0, 1800),
    "bloodblast": (OBJ_ROOT + "grabblastbloodbig.obj", 280, 0.0, 1700),
    "releasewave": (OBJ_ROOT + "releasewave.obj", 260, 480.0, 1200),
    # Legacy Saya EX adapter only. Ordinary Saya uses native object 20012.
    "saya": (OBJ_ROOT + "saya.obj", 420, 0.0, 25000),
    "tombstonerain": (None, 480, 0.0, 2600),
    "grandwave": (OBJ_ROOT + "grandwave.obj", 420, 520.0, 1800),
    "dotarea": (None, 220, 0.0, 16000),
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
    # The EX adapter still consumes this legacy binding.
    "illusionslash": (OBJ_ROOT + "illusionslashwave.obj", 900, 520.0, 1600),
    "wavespinarea": (OBJ_ROOT + "wavespinarea.obj", 420, 0.0, 5000),
    "hellbenter": (OBJ_ROOT + "hellbenterfinish.obj", 760, 0.0, 1800),
    "blache": (OBJ_ROOT + "blache.obj", 760, 0.0, 3600),
    "waveeye": (OBJ_ROOT + "waveeye.obj", 850, 0.0, 5000),
}

# Source bindings in CNSwordman state 24 and the ghost object's motion vector.
# Keep other blank-frame clips out of the legacy filename heuristic.
NATIVE_ANIMATION_BINDINGS = {
    CHR_FX + "hundredsword/ready.ani",
    *(OBJ_ROOT + f"animation/illusionslashmelee{index}.ani" for index in range(1, 5)),
    OBJ_ROOT + "animation/momentaryslash/start.ani",
    CHR_FX + "giveblood/givebloodstay.ani",
    CHR_FX + "giveblood/givebloodshoot.ani",
    OBJ_ROOT + "animation/givebloodsub_back.ani",
    OBJ_ROOT + "animation/givebloodsub_front.ani",
    OBJ_ROOT + "animation/blastbloodpresub_back.ani",
    OBJ_ROOT + "animation/blastbloodpresub_front.ani",
    OBJ_ROOT + "animation/blastbloodfloor2.ani",
    OBJ_ROOT + "animation/blastbloodhit1.ani",
    OBJ_ROOT + "animation/blastbloodhit2.ani",
    CHR_FX + "icewave.ani",
    CHR_FX + "firewavebig-sword-effect.ani",
    OBJ_ROOT + "animation/firewavebig/blast-front.ani",
    *(OBJ_ROOT + f"animation/icewave{i}.ani" for i in range(1, 7)),
    OBJ_ROOT + "animation/khazanareaappear1.ani",
    OBJ_ROOT + "animation/bremenareaappear1.ani",
    OBJ_ROOT + "animation/sayaareaappear1.ani",
    *(RASA_ANIMATION + name + ".ani" for name in (
        "epidemicrasaareaappear1", "epidemicrasaareaappear2", "epidemicrasaareastay", "epidemicrasaareadisappear",
        "rasa", "rasa_ldodge", "startup", "startup_ldodge", "stay", "stay_ldodge",
        "grab", "grab_ldodge", "grab_stay", "grab_stay_ldodge",
    )),
}

SAFE_EFFECTS: set[str] = set()
SAFE_OBJECTS: set[str] = set()
IMAGE_DB = None
IMAGE_PATHS: set[str] | None = None

WAVE_CAST_VOICES = {"normalwave": "HADOUKEN", "icewave": "SM_ICEWAVE", "firewave": "SM_FIREWAVE"}
GHOST_FIELD_SOUNDS = {
    "khazan": ("SM_GHOST_KAZHAN", "GHOST_KAJAN"),
    "bremen": ("SM_GHOST_BREMEN", "GHOST_BREMEN"),
    "saya": ("SM_GHOST_SAYA", "GHOST_SAYA"),
}

EX_BASE = {
    "tombstonerainex": "tombstonerain",
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
    "thirst": {
        "name": "嗜血",
        "source_skill": "sacrifice",
        "duration_level_row": 0,
        "stacking": "refresh",
        "max_stacks": 1,
        "modifiers": [
            {"stat": "strength", "op": "add", "level_row": 12},
            {"stat": "physical_attack", "op": "add", "level_row": 13},
        ],
    },
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
        "source_skill": "khazan",
        "duration_level_row": 1,
        "stacking": "refresh",
        "max_stacks": 1,
        "modifiers": [
            {"stat": "strength", "op": "add", "level_row": 0},
            {"stat": "intelligence", "op": "add", "level_row": 2},
        ],
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
        "source_skill": "bremen",
        "duration_level_row": 1,
        "stacking": "refresh",
        "max_stacks": 1,
        "modifiers": [
            {"stat": "abnormal_resistance", "op": "add", "level_row": 0, "scale": -1.0},
            {"stat": "magical_defense", "op": "add", "level_row": 2, "scale": -1.0},
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
        "source_skill": "overdrive",
        "duration_level_row": 0,
        "weapon_wear_level_row": 1,
        "stacking": "refresh",
        "max_stacks": 1,
        "modifiers": [
            # CD92B6 -> CD935C writes column 2 to equipment physical attack (enum 4).
            {"stat": "physical_attack", "op": "add", "level_row": 2},
            # CD936A selects column 3 in tenths of a percentage point (enum 15).
            {"stat": "physical_crit", "op": "add", "level_row": 3, "scale": 0.001},
        ],
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
        "source_skill": "buff",
        "hp_drain_level_row": 1,
        "stacking": "refresh",
        "max_stacks": 1,
        "form": "dual_wield",
        "modifiers": [
            {"stat": "hit", "op": "add", "level_row": 3, "scale": 0.001},
            {"stat": "hit_recovery", "op": "add", "level_row": 4},
        ],
        "skill_damage": {"grabblastblood": 0.1, "rage_slash": 0.1},
        "skill_cooldown_reduction_rows": {"grabblastblood": 10, "bloodblast": 12, "bloodblastex": 12, "rage_slash": 14},
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
        "source_skill": "magicalattackup",
        "duration_level_row": 0,
        "stacking": "refresh",
        "max_stacks": 1,
        "modifiers": [
            {"stat": "intelligence", "op": "add", "level_row": 1},
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
    return path in NATIVE_ANIMATION_BINDINGS or all(
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
        # Native 83FA10 adjusts one eligible attack record, after swordman
        # state gates, using category-specific columns and native rounding.
        # Its rank producer/attack-record integration is not yet closed.
        return {"runtime_hook": "basic_attack_mastery", "runtime_status": "pending_native_attack_record_pipeline"}
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
    "weaponmasteryup": {"runtime_hook": "weapon_mastery_rank_bonus"},
    "darkfriendship": {
        "passive": [
            {"stat": "dark_resist", "op": "add", "value": 20},
            {"stat": "light_resist", "op": "add", "value": -10},
        ]
    },
    "equiplightsword": {"unlock_weapon": "beamsword"},
    "ghostpowerup": {"runtime_hook": "ghost_skill_rank_bonus"},
    "fastequip": {
        "weapon_switch_cooldown_rate": 0.5,
        "weapon_switch_buff": {"damage_rate": 0.1, "physical_crit": 0.1, "duration_ms": 5000},
    },
    "durabilityup": {"runtime_hook": "weapon_wear"},
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
    for field in ("second_growtype_max_level", "fitness_second_growtype"):
        if field in skill:
            definition[field] = skill[field]
    if active:
        definition["move"] = local_id(key)
    if key in PASSIVE_BUILDERS:
        definition.update(PASSIVE_BUILDERS[key])
    elif not active:
        definition.update(generic_passive_spec(key))
    if key in ("ghostpowerup", "weaponmasteryup"):
        # CD9E60..CDA05C walks all static IDs: seven ghost targets (including
        # Keiga) and five mastery targets (including the beamsword column).
        targets = decoded.get("dungeon", {}).get("static_data", decoded.get("static_data", []))
        if not targets or any(type(n) is not int or not 0 <= n < 255 for n in targets):
            raise ValueError(f"{key} requires source static skill IDs")
        definition["skill_rank_bonus_ids"] = list(targets)
        if key == "weaponmasteryup":
            levels = decoded.get("dungeon", {}).get("level_info", decoded.get("level_info", []))
            if (not levels or levels[0] != len(targets) or (len(levels)-1) % len(targets)
                    or any(type(n) is not int for n in levels)):
                raise ValueError("weaponmasteryup requires aligned source level columns")
            definition["skill_rank_bonus_rows"] = [levels[j:j+len(targets)] for j in range(1,len(levels),len(targets))]
            if len(definition["skill_rank_bonus_rows"]) < definition["max_level"]:
                raise ValueError("weaponmasteryup source levels do not cover maximum rank")
    return definition


def build_rasa_move(skill: dict, records: dict, fx: dict, effects: dict, objects: dict) -> dict:
    if not add_object(objects, RASA_CREATOR) or not add_object(objects, RASA_CHILD):
        raise ValueError("Missing original Rasa creator or child object")
    creator = records[RASA_CREATOR]["decoded"]
    child = records[RASA_CHILD]["decoded"]
    entry, = creator["basic_motion"]
    entry_overlay, stay, exit_ani, ghost, ghost_overlay = creator["etc_motions"]
    startup, = child["basic_motion"]
    startup_overlay, child_stay, stay_overlay, grab, grab_overlay, grab_stay, grab_stay_overlay = child["etc_motions"]
    bindings = {path: add_fx(fx, effects, path) for path in (
        entry, entry_overlay, stay, exit_ani, ghost, ghost_overlay,
        startup_overlay, child_stay, stay_overlay, grab, grab_overlay, grab_stay, grab_stay_overlay,
    )}
    if not all(bindings.values()) or not timeline_has_attack(records[child_stay]):
        raise ValueError("Incomplete original Rasa visuals or stay collision")
    statics = records[skill["path"]]["decoded"]["dungeon"]["static_data"]
    if len(statics) != 9 or min(statics) <= 0:
        raise ValueError("Missing original Rasa static data")
    # Creator A63950 samples lifetime, timers and scale. A63790 uses a separate
    # literal 233 for target selection; the visual radius is SKL static[6].
    child_controller = {
        "kind": "rasa_child", "duration_col": 1, "attachment_duration_col": 19,
        "attack_speed_col": 2, "defense_col": 3, "recovery_col": 4, "attachment_limit": statics[8],
        # A633DF sets the independent child timer. A64BC0 sends enum 5 with
        # these level columns when the three-way native draw selects blind.
        "status_interval_col": 5,
        "blind_columns": {"chance": 10, "level": 11, "duration_ms": 12, "vision_percent": 13, "stuck_percent": 14},
        "startup_ms": duration_ms(records[startup]), "grab_ms": duration_ms(records[grab]),
        "stay_ani": child_stay,
        "startup_overlay": bindings[startup_overlay],
        "stay_fx": bindings[child_stay], "stay_overlay": bindings[stay_overlay],
        "grab_fx": bindings[grab], "grab_overlay": bindings[grab_overlay],
        "grab_stay_fx": bindings[grab_stay], "grab_stay_overlay": bindings[grab_stay_overlay],
    }
    controller = {
        "kind": "rasa_field", "duration_col": 0, "radius": 233, "depth_scale": 0.29,
        "pulse_ms": statics[1], "area_scale": statics[6] / 233.0, "child_count": statics[7],
        "ghost_base_fx": bindings[ghost], "ghost_fx": bindings[ghost_overlay],
        "appear_fx": [bindings[entry], bindings[entry_overlay]], "stay_fx": bindings[stay],
        "disappear_fx": bindings[exit_ani], "appear_ms": duration_ms(records[entry_overlay]),
        "disappear_ms": duration_ms(records[exit_ani]),
        "child": {"object": RASA_CHILD, "percent": 0, "native_controller": child_controller},
    }
    return {
        "skill": skill["path"], "name": skill["name"], "native_state": "ghost_cast", "native_charge_ani": "throw1",
        "fidelity_pending": ["attachment_poison_bleed", "blind_hit_rate_and_visual", "monster_rank_factors", "attack_speed_quantization",
                             "attachment_offsets", "area_draw_order", "object_random_stream"],
        "stages": [{"ani": "throw2", "atk": "", "fx": [], "sounds": [{"at": 0, "key": "SM_RASA"}],
                    "hits": [{"object": RASA_CREATOR, "offset": [122, 0, 0], "percent": 0,
                              "native_controller": controller}]}],
    }


def fixed_cube_cost(skill: dict, records: dict) -> dict:
    item_id, first_cost, last_cost = records[str(skill["path"]).lower()]["decoded"]["consume_item"]
    if item_id != 3037 or first_cost != last_cost or first_cost <= 0:
        raise ValueError(f"Unverified item cost for {skill['key']}")
    return {"source_id": item_id, "amount": first_cost}


def bloodblast_layer_script(library, records: dict) -> dict:
    script = library.script(BLOODBLAST_LAYER_SCRIPT)
    if not script or script["sha256"] != "2453ae7a06fb7c9846c9bcc530bf62123d6ae4aaf206f2444ec1d127fc07ab19":
        raise ValueError("Unverified Blood Blast layer script")
    timeline = records[BLOODBLAST_LAYER_SCRIPT.removesuffix(".als")]["decoded"]["timeline"]
    directory = PurePosixPath(BLOODBLAST_LAYER_SCRIPT).parent
    paths: dict[str, str] = {}
    layers = []
    for field in script["fields"]:
        if field["tag"] == "[use animation]":
            relative, alias = field["values"]
            paths[alias] = str(directory / relative).lower()
        elif field["tag"] == "[add]":
            frame, order, alias = field["values"]
            layers.append({"path": paths[alias], "at_ms": timeline[frame]["start_ms"], "order": order})
        else:
            raise ValueError("Unsupported Blood Blast layer instruction: " + field["tag"])
    if len(layers) != 10 or len({layer["order"] for layer in layers}) != len(layers):
        raise ValueError("Incomplete Blood Blast layer sequence")
    return {"source": BLOODBLAST_LAYER_SCRIPT, "sha256": script["sha256"],
            "layers": sorted(layers, key=lambda layer: layer["order"])}


def illusion_club_layer_script(library) -> dict:
    script = library.script(ILLUSION_CLUB_LAYER_SCRIPT)
    if not script or script["sha256"] != "d60736053f47094121b7342f0b0cc287f58e250be7cc6dfcf997faf2b2c3c65e":
        raise ValueError("Unverified Illusion Slash ground-wave layer script")
    directory = PurePosixPath(ILLUSION_CLUB_LAYER_SCRIPT).parent
    paths: dict[str, str] = {}
    attached = ""
    detached = []
    for field in script["fields"]:
        tag, values = field["tag"], field["values"]
        if tag == "[use animation]":
            relative, alias = values
            paths[alias] = str(directory / relative).lower()
        elif tag == "[add]" and values[:2] == [0, 0] and not attached:
            attached = paths[values[2]]
        elif tag == "[create draw only object]" and values[0] == 0 and values[2:] == [0, 0, 0]:
            detached.append(paths[values[1]])
        else:
            raise ValueError("Unexpected Illusion Slash ground-wave layer placement")
    if not attached or len(detached) != 4:
        raise ValueError("Incomplete Illusion Slash ground-wave layers")
    return {"attached": attached, "detached": detached}


def dungeon_fixed_attack_base(library, column: int) -> dict:
    script = library.script(FIXED_ATTACK_BASE_SOURCE)
    if not script or script["sha256"] != "61fe2583df5a6cbf0f33ab8a084d18aca760732441b332128dfcff98c1de0ba4":
        raise ValueError("Unverified dungeon fixed attack base table")
    rows = next(field["values"] for field in script["fields"]
                if field["tag"] == "[skill damage base parameter dungeon]")
    if len(rows) != 700 or rows[::7] != list(range(1, 101)):
        raise ValueError("Invalid level rows in dungeon fixed attack base table")
    return {"source": FIXED_ATTACK_BASE_SOURCE, "sha256": script["sha256"], "by_level": rows[column::7]}


def draw_stagger_parameters(library) -> dict:
    script = library.script(FIXED_ATTACK_BASE_SOURCE)
    if not script or script["sha256"] != "61fe2583df5a6cbf0f33ab8a084d18aca760732441b332128dfcff98c1de0ba4":
        raise ValueError("Unverified hit recovery table")
    fields = {field["tag"]: field["values"] for field in script["fields"]}
    return {"source": FIXED_ATTACK_BASE_SOURCE, "sha256": script["sha256"],
            "min_ms": fields["[hit delay time min]"][0], "max_ms": fields["[hit delay time max]"][0],
            "max_recovery": fields["[hit recovery max]"][0]}


def swordman_weapon_tracks(library, pose: str, folders: dict[str, str],
                           active_frames: list[int] | dict[str, list[int]]) -> dict:
    tracks = {}
    for family, folder in folders.items():
        path = f"equipment/character/swordman/weapon/{folder}/{pose}.ani"
        source = library.animation(path)
        frames = [{"frame": frame["frame"], "delay_ms": frame["delay_ms"],
                   "boxes": [box for box in frame.get("boxes", []) if box["kind"] == "attack"]}
                  for frame in source["metadata"]["frames"]]
        expected = active_frames[family] if isinstance(active_frames, dict) else active_frames
        if [frame["frame"] for frame in frames if frame["boxes"]] != expected:
            raise ValueError(f"unexpected native weapon attack frames: {path}")
        tracks[family] = {"source": path, "sha256": source["sha256"], "frames": frames}
    return tracks


def rapid_move_slash_tracks(library) -> dict:
    folders = {
        "shortsword": "ssword/sswdb", "katana": "katana/katanab", "greatsword": "hsword/lswdb",
        "club": "club/clubb", "beamsword": "beamsword/beamswdb",
    }
    return {
        "rapidmoveslashmove1": swordman_weapon_tracks(library, "rapidmoveslashmove1", folders, [0, 1, 2, 3]),
        "rapidmoveslashmove2": swordman_weapon_tracks(library, "rapidmoveslashmove2", folders, [0, 1, 2]),
    }


def illusion_finish_tracks(library) -> dict:
    pose = "illusionslashfinal"
    upper = swordman_weapon_tracks(library, pose, {
        "shortsword": "ssword/sswdb", "katana": "katana/katanab", "greatsword": "hsword/lswdb",
        "club": "club/clubb", "beamsword": "beamsword/beamswdb",
    }, [2])
    smash = swordman_weapon_tracks(library, pose, {
        "shortsword": "ssword/sswdc", "katana": "katana/katanac", "greatsword": "hsword/lswdc",
        "club": "club/clubc", "beamsword": "beamsword/beamswdc",
    }, {"shortsword": [6], "katana": [6], "greatsword": [6, 7], "club": [5], "beamsword": [6, 7]})
    return {family: [upper[family], smash[family]] for family in upper}


DRAW_WAVE_ALS = OBJ_ROOT + "animation/momentaryslash/start.ani.als"
DRAW_EFFECT_SCRIPT = "sqr/common.nut"


def swordman_skill_effect_slots(library, skill: bytes) -> dict:
    source = library.raw(DRAW_EFFECT_SCRIPT)
    if not source or source[1] != "28b733752116ca5fee2ca0a9dbb335686e8b0c5403069d795dc691144ba2fa79":
        raise ValueError("unverified Swordman skill effect registration")
    swordman = source[0].split(b"function sq_LoadSkillEffect_Swordman(", 1)[1]
    block = re.search(rb"else if \(skillIndex == " + skill + rb"\)\s*\{([^}]+)\}", swordman)
    if not block:
        raise ValueError(f"missing Swordman effect registration for {skill!r}")
    names = re.findall(rb'obj\.sq_LoadSkillEffectAni\(skillIndex, "([^"]+)"\);', block[1])
    return {"source": DRAW_EFFECT_SCRIPT, "sha256": source[1],
            "paths": ["character/swordman/" + name.decode("ascii").lower() for name in names]}


def draw_effect_slots(library) -> dict:
    registration = swordman_skill_effect_slots(library, b"SKILL_MOMENTARY_SLASH")
    paths = registration["paths"]
    if len(paths) != 10 or not all(path.startswith(CHR_FX + "momentaryslash/") for path in paths):
        raise ValueError("unexpected Swordman Draw Sword effect slots")
    return registration


def grab_hold_effect_slot(library) -> dict:
    registration = swordman_skill_effect_slots(library, b"SKILL_GRAB_BLAST_BLOOD")
    paths = registration.pop("paths")
    if paths != [CHR_FX + "grabblastblood.ani"]:
        raise ValueError("unexpected Swordman Bloodlust effect slot")
    return {**registration, "path": paths[0]}


def draw_wave_layer(library) -> dict:
    script = library.script(DRAW_WAVE_ALS)
    if not script or script["sha256"] != "498ee5045fd4f970659510b7804a4291b35ccdf20588367b6b7bbd1137e436e9":
        raise ValueError("unverified Draw Sword wave layer script")
    binding, placement = script["fields"]
    file, alias = binding["values"]
    if binding["tag"] != "[use animation]" or placement["tag"] != "[add]" or placement["values"] != [0, -10, alias]:
        raise ValueError("unexpected Draw Sword wave layer placement")
    return {"path": str(PurePosixPath(DRAW_WAVE_ALS).parent / file.lower()),
            "source": DRAW_WAVE_ALS, "sha256": script["sha256"]}


def bloody_rave_typhoon_params(library) -> dict:
    path = "data/skill/swordman.sd"
    source, digest = library.raw(path)
    keys = {"start offset": "start_x", "end offset": "end_x", "interval": "spacing",
            "move speed": "speed", "start size": "start_scale", "end size": "end_scale"}
    tokens = decode_tokens(source, library.strings)["tokens"]
    params = {}
    for current, following in zip(tokens, tokens[1:]):
        tag = str(current.get("value", ""))
        if tag.startswith("br typhoon ") and tag[11:] in keys:
            params[keys[tag[11:]]] = following["value"]
    if set(params) != set(keys.values()):
        raise ValueError("Missing original Bloody Rave typhoon parameters")
    if params["spacing"] <= 0 or params["end_x"] <= params["start_x"]:
        raise ValueError("Invalid Bloody Rave typhoon distance parameters")
    return {**params, "source": path, "sha256": digest}


def build_bloody_rave(skill: dict, records: dict, fx: dict, effects: dict, objects: dict,
                      slots: list[str], bleed_attack_base: dict, typhoon_params: dict) -> dict:
    # CAA22B, CAA300 and CAA360 attach two original layers per body frame gate.
    inhale = records[CHR_ANI + "bloodyraveinhale.ani"]["decoded"]["timeline"]
    release = records[CHR_ANI + "bloodyraveslash.ani"]["decoded"]["timeline"]
    inhale_fx = []
    for first, frame in ((0, 3), (2, 6), (4, 8)):
        for index in (first, first + 1):
            cue = {"key": add_fx(fx, effects, slots[index]), "at": inhale[frame]["start_ms"],
                   "action_clock": True, "loop": True, "offset_x": 55, "offset_y": -96,
                   "depth_offset": (1, 2, 3, 4, 6, 7)[index]}
            if index in (4, 5):
                # CAA2A3 restarts a finished line clip at its frame 5.
                cue["repeat_from_ms"] = records[slots[index]]["decoded"]["timeline"][5]["start_ms"]
            inhale_fx.append(cue)
    if any(frame.get("img") for frame in records[slots[9]]["decoded"]["timeline"]):
        raise ValueError("Bloody Rave's empty sword slot now contains images")
    sword_fx = [{"key": add_fx(fx, effects, slots[slot]), "at": 0, "action_clock": True,
                 "depth_offset": depth} for slot, depth in ((8, -2), (10, 1), (11, 2))]
    slash = add_object(objects, OBJ_ROOT + "bloodyrave.obj")
    rear = add_fx(fx, effects, OBJ_ROOT + "animation/bloodyravelayer.ani")
    end_fx = add_fx(fx, effects, slots[7])
    typhoon = add_fx(fx, effects, slots[6])
    contact_fx = add_fx(fx, effects, slots[14])
    typhoon_frames = records[slots[6]]["decoded"]["timeline"]
    if any(frame["end_ms"] - frame["start_ms"] != 40 for frame in typhoon_frames):
        raise ValueError("Unexpected Bloody Rave typhoon frame timing")
    if not slash or not rear or not end_fx or not typhoon or not contact_fx or not all(cue["key"] for cue in inhale_fx + sword_fx):
        raise ValueError("Missing original Bloody Rave presentation bank")
    if records[slash]["decoded"].get("add_object_effect") != ["Animation/BloodyRaveLayer.ani", -1]:
        raise ValueError("Unexpected Bloody Rave slash attachment")
    contact_atk = CHR_ATK + "bloodyrave.atk"
    contact = records[contact_atk]["decoded"]
    if any(contact.get(field, 0) for field in ("damage", "absolute_damage", "weapon_damage_apply")) \
            or contact["damage_reaction"][0]["value"] != "[none]":
        raise ValueError("Unexpected Bloody Rave inhale attack")
    return {"skill": str(skill["path"]), "name": str(skill["name"]), "native_state": "bloody_rave",
            "requires_effect": "frenzy", "material_cost": fixed_cube_cost(skill, records),
            "suction_bleed_base": bleed_attack_base, "suction_end_fx": end_fx,
            "suction_contact_fx": contact_fx, "suction_contact_sound": contact["hit_wav"],
            "suction_typhoon": {**typhoon_params, "key": typhoon, "frames": len(typhoon_frames), "frame_ms": 40,
                                "at": inhale[8]["start_ms"], "fade_in_ms": 300},
            "fidelity_pending": ["special_target_permissions_and_weights", "contact_effect_parent_transform",
                                 "cancel_permission"],
            "stages": [{"ani": "bloodyraveinhale", "fx": inhale_fx, "voice": "SM_BLOOD_RAVE_STORM"},
                       {"ani": "bloodyraveslash", "fx": sword_fx,
                        "hits": [{"object": slash, "at": release[3]["start_ms"], "percent_col": 0,
                                  "speed": 0, "life_ms": -1, "rear_fx": rear, "starts_at_zero": True}]}]}


OUTRAGE_OBJECT_ANIM = OBJ_ROOT + "animation/outragebreak/"
HUNDRED_SWORD_FINISH_PARTICLE = "character/swordman/effect/particle/hundredswordfinish.ptl"
HUNDRED_SWORD_FINISH_LAYERS = (("finishslash", 1), ("finishflash", 2), ("finishfloor", -1),
                             *((f"finishcircle{i}", i + 1) for i in range(1, 5)))
HUNDRED_SWORD_STYLES = [3, 0, 2, 3, 5, 2, 0, 1, 5, 3, 0, 2, 1, 5, 1, 0, 3, 5, 0, 1, 2, 5, 2, 1]
HUNDRED_SWORD_ORDER = [13, 6, 23, 9, 2, 17, 12, 0, 7, 19, 20, 14, 21, 16, 15, 10, 3, 22, 11, 8, 5, 1, 4, 18]
HUNDRED_SWORD_POSES = [1, 2, 3, 4, 1, 5]
HUNDRED_SWORD_WEAPON_DRAW_ORDER = ((2155, 655),)*4 + ((2607, 657, 2606, 656),)
HUNDRED_SWORD_FINISH_TRAILS = ((302, 12, 20), (267, 35, 25), (232, 30, 35), (214, 63, 45),
                             (152, 83, 50), (105, 72, 60), (82, 95, 80))
HUNDRED_SWORD_BLADES = ("swordspread", "swordair", "swordland")
HUNDRED_SWORD_FORMATION_LAYERS = ("light1", "light2", "light3", "swordairglow", "swordlandglow1",
                                 "swordlandglow2", "sworddisappear1", "sworddisappear2",
                                 *(f"lighttail{i}" for i in range(1, 5)),
                                 *(f"finishtail{i}" for i in range(1, 5)))


def hundred_sword_blade_banks():
    return {
        f"hundred_sword_{stem}{layer}_{style:02d}": {
            "ani": CHR_FX + f"hundredsword/{stem}{layer}.ani", "image_variant": style,
        }
        for stem in HUNDRED_SWORD_BLADES for layer in (1, 2) for style in sorted(set(HUNDRED_SWORD_STYLES))
    }


def hundred_sword_weapon_banks():
    return {
        f"hundred_sword_weaponready{pose}_{layer:02d}": {
            "ani": CHR_FX + f"hundredsword/weaponready{pose}{'dodge' if layer >= 2 else 'normal'}.ani",
            "image_variant": layer,
        }
        for pose, orders in enumerate(HUNDRED_SWORD_WEAPON_DRAW_ORDER, 1)
        for layer in range(len(orders))
    }


OUTRAGE_PARTICLES = {
    "stone": "character/swordman/effect/particle/outragebreak_stone_part.ptl",
    "light": OBJ_ROOT + "particle/outragebreak_light_part.ptl",
    "drops": OBJ_ROOT + "particle/outragebreak_drops.ptl",
}
OUTRAGE_FLOOR_FX = ("floor_over", "floor_blood", "floor_impact_ldodge")
OUTRAGE_MAGMA_FX = ("bloodexp1_none", "bloodexp1_ldodge", "bloodexp2_none",
                   "bloodexp2_ldodge", "bloodexp_glow")


def outrage_eruption_timing(library) -> dict:
    path = "data/skill/swordman.sd"
    source, digest = library.raw(path)
    tokens = decode_tokens(source, library.strings)["tokens"]
    intervals = [following["value"] for current, following in zip(tokens, tokens[1:])
                 if current.get("value") == "orb effect term"]
    if len(intervals) != 1 or int(intervals[0]) <= 0:
        raise ValueError("Missing original OutRageBreak visual interval")
    return {"visual_interval_ms": int(intervals[0]), "source": path, "sha256": digest}


def build_outrage_break(skill: dict, records: dict, fx: dict, effects: dict, objects: dict,
                        slots: list[str], fixed_attack_base: dict, timing: dict) -> dict:
    slash = records[CHR_ANI + "outragebreakslash.ani"]["decoded"]["timeline"]
    impact = slash[5]["start_ms"]
    layers = [add_fx(fx, effects, path) for path in slots[:7]]
    floor = add_object(objects, OBJ_ROOT + "outragebreakfloor.obj")
    # This object is collision-only. Its visible effects are separately spawned
    # by A723A0 and do not follow its damage ANI.
    magma = OBJ_ROOT + "outragebreakbloodexp.obj"
    floor_fx = [add_fx(fx, effects, OUTRAGE_OBJECT_ANIM + name + ".ani") for name in OUTRAGE_FLOOR_FX]
    magma_fx = [add_fx(fx, effects, OUTRAGE_OBJECT_ANIM + name + ".ani") for name in OUTRAGE_MAGMA_FX]
    if magma not in records or not all([*layers, floor, *floor_fx, *magma_fx]):
        raise ValueError("Missing original OutRageBreak animation binding")
    # A72A91 reads frame 4 of the second ETC motion. A7228F uses the
    # complete damage-only ANI duration for the independent hit interval.
    floor_motions = records[floor]["decoded"]["etc_motions"]
    eruption_at = records[floor_motions[1]]["decoded"]["timeline"][4]["start_ms"]
    controller = {"kind": "outrage_floor", "layers": floor_fx, "eruption_at_ms": eruption_at,
                  "light_particle": OUTRAGE_PARTICLES["light"], "drops_particle": OUTRAGE_PARTICLES["drops"],
                  "child": {"object": magma, "percent": 0, "fixed_col": 2,
                            "native_controller": {"kind": "outrage_magma", "layers": magma_fx, **timing}}}
    ready_fx = [{"key": layers[slot], "at": 0, "action_clock": True, "depth_offset": depth}
                for slot, depth in ((0, 2), (1, 1))]
    slash_fx = [{"key": layers[slot], "at": at, "action_clock": True, "depth_offset": depth}
                for slot, depth, at in ((2, 2, 0), (3, 1, 0), (4, 4, impact), (5, 3, impact))]
    # CB4654 installs the stone composite in the caster's draw slot 6.
    slash_fx.append({"key": layers[6], "at": impact, "action_clock": True, "depth_offset": 6,
                     "offset_x": 121, "offset_y": 10})
    return {"skill": str(skill["path"]), "name": str(skill["name"]), "native_state": "outrage_break",
            "requires_effect": "frenzy", "hp_cost_row": 3, "material_cost": fixed_cube_cost(skill, records),
            "fixed_attack_base": fixed_attack_base, "impact_frame": 5,
            "stone_particle": OUTRAGE_PARTICLES["stone"],
            "fidelity_pending": ["hp_write_timing", "special_target_dispatch"],
            "stages": [{"ani": "outragebreakready", "fx": ready_fx, "voice": "OUTRAGE_READY"},
                       {"ani": "outragebreakslash", "fx": slash_fx,
                        "sounds": [{"at": impact, "key": key} for key in ("OUTRAGE_SWING", "CCRASH_CRASH")],
                        "hits": [{"atk": CHR_ATK + "outragebreak.atk", "body": True, "percent_col": 0},
                                 {"object": floor, "at": impact, "offset": [150, 0, 0],
                                  "percent": 0, "fixed_col": 1, "starts_at_zero": True,
                                  "native_controller": controller}]}]}


def build_move(
    skill: dict,
    records: dict,
    atk_by_stem: dict[str, list[str]],
    effect_paths: list[str],
    fx: dict[str, str],
    effects: dict[str, dict],
    objects: dict[str, str],
    *,
    native_bloodblast: bool = True,
    bloodblast_script: dict | None = None,
    native_draw: bool = True,
) -> dict | None:
    if skill.get("type") != "[active]":
        return None
    source_key = str(skill["key"])
    if source_key == "epidemicrasa":
        return build_rasa_move(skill, records, fx, effects, objects)
    key = "saya" if source_key == "sayaex" else source_key
    move_id = local_id(key)
    stages: list[dict] = []
    statuses = HIT_STATUS.get(key, [])
    if key == "backstep":
        # SKL describes a backward hop. Dispatch to the existing movement state;
        # a summon animation plus a one-millisecond effect cannot implement it.
        return {"skill": str(skill["path"]), "name": str(skill["name"]),
                "movement": "backstep", "stages": [{"ani": "jump", "atk": "", "hits": []}]}
    if key == "momentaryslash" and native_draw:
        # CC7F44 selects body/ATK slot 8. The body has no attack boxes.
        atk = "character/swordman/attackinfo/momentaryslash.atk"
        return {"skill": str(skill["path"]), "name": str(skill["name"]), "native_state": "draw",
                "material_cost": fixed_cube_cost(skill, records),
                "fidelity_pending": ["followup_abnormal_status", "beamsword_equipped_appearance", "wave_wall_and_final_damage", "temporary_hit_atk_and_final_formula",
                                     "original_command", "weapon_durability"],
                "stages": [{"ani": "momentaryslash", "voice": "SM_BAL_READY",
                            "hits": [{"atk": atk, "percent_col": 0, "attached_weapon": True}]}]}
    if key == "grabblastblood":
        sprays = [add_object(objects, OBJ_ROOT + path) for path in ("grabblastblood.obj", "grabblastbloodbig.obj")]
        if not all(sprays):
            raise ValueError("Missing original Bloodlust spray object")
        return {"skill": str(skill["path"]), "name": str(skill["name"]), "native_state": "grab_blast",
                "strike_atk": "character/swordman/attackinfo/grabblastblood.atk",
                "stages": [{"ani": "grab", "atk": "character/swordman/attackinfo/grab.atk",
                            "hits": [{"body": True}]},
                           {"ani": "grab", "hits": [{"object": spray, "at": 750, "percent": 0,
                            "fixed_col": 1, "speed": 0.0, "life_ms": 480, "offset": [43, 1, 90]}
                            for spray in sprays]}]}
    if key == "frenzy":
        # CC10F0 uses throw slot 0. State 13 loads its charge and shoot motions.
        return {"skill": str(skill["path"]), "name": str(skill["name"]),
                "stages": [{"ani": "throw1"}, {"ani": "throw2"}], "effect_id": "frenzy",
                "cast_fx": "frenzy_cast", "release_fx": "frenzy_blast", "aura_fx": "frenzy_buff",
                "hp_cost_row": 0, "material_cost": fixed_cube_cost(skill, records)}
    if key == "sacrifice":
        cast_fx = add_fx(fx, effects, CHR_FX + "giveblood/givebloodstay.ani")
        release_fx = add_fx(fx, effects, CHR_FX + "giveblood/givebloodshoot.ani")
        burst = add_object(objects, OBJ_ROOT + "givebloodsub.obj")
        front_fx = add_fx(fx, effects, records[burst]["decoded"]["etc_motions"][0]) if burst else ""
        if not all((cast_fx, release_fx, burst, front_fx)):
            raise ValueError("missing Thirst cast, release or full-charge animation")
        # 61CA00 installs status 11 and scales the basic and attached animations.
        full_charge = {"object": burst, "offset": [0, 0, 1], "percent": 0,
                       "native_controller": {"kind": "thirst_burst", "layers": [front_fx]}}
        return {"skill": str(skill["path"]), "name": str(skill["name"]),
                "native_state": "thirst", "effect_id": "thirst", "cast_fx": cast_fx, "release_fx": release_fx,
                "full_charge_hit": full_charge, "active_idle_ani": "staysacrifice",
                "fidelity_pending": ["bleeding_modifiers_and_special_targets", "loop_stop_during_nonidle_expiry",
                                     "original_command", "other_skill_bonuses"],
                "stages": [{"ani": "summon1"}, {"ani": "summon2", "voice": "SM_SACRIFICE_CAST",
                    "fx": [{"key": release_fx, "at": 0, "action_clock": True}]}]}
    if source_key == "bloodblast" and native_bloodblast:
        skill_path = str(skill["path"])
        static = records[skill_path]["decoded"]["dungeon"]["static_data"]
        hits = []
        # CD8131..CD834A creates the centered spray, rear-offset pillar and ground burst.
        for name, depth, fixed_col, lift_col, reset_frames in (
            ("blastbloodsuborigin", 0, 0, 2, (1, 4)),
            ("blastbloodorigin", 50, 0, 1, (10, 13)),
            ("blastbloodpresuborigin", 0, 2, None, ()),
        ):
            path = OBJ_ROOT + name + ".obj"
            obj = records[path]["decoded"]
            timeline = records[obj["basic_motion"][0]]["decoded"]["timeline"]
            motions = obj.get("etc_motions", [])
            # Root ETC slot 0 is an image-free timing clip in this archive.
            visible = motions[1:] if name == "blastbloodorigin" else motions
            controller = {"kind": "bloodblast", "layers": [
                add_fx(fx, effects, motion) for motion in visible
            ]}
            if not all(controller["layers"]):
                raise ValueError(f"Missing original {name} effect bank")
            if not reset_frames and not add_object(objects, path):
                raise ValueError(f"Missing original {name} object bank")
            if reset_frames:
                first, last = (timeline[frame]["start_ms"] for frame in reset_frames)
                controller.update(reset_ms=(last-first)//static[0], reset_count=static[0]-1)
            if name == "blastbloodsuborigin":
                # A61879 and A61959 create separate ground and normal draw objects.
                controller["ground_hit_fx"] = [
                    add_fx(fx, effects, OBJ_ROOT + f"animation/blastbloodhit{i}.ani")
                    for i in (1, 2)
                ]
                if not all(controller["ground_hit_fx"]):
                    raise ValueError("Missing original Blood Blast contact animations")
            if name == "blastbloodorigin":
                plume = records[obj["etc_motions"][0]]["decoded"]["timeline"]
                controller["sound_at_ms"] = plume[8]["start_ms"]
                if bloodblast_script is None:
                    raise ValueError("Missing original Blood Blast layer script")
                controller["ani_layers"] = [
                    {"effect": add_fx(fx, effects, layer["path"]),
                     "at_ms": layer["at_ms"], "order": layer["order"]}
                    for layer in bloodblast_script["layers"]
                ]
                if not all(layer["effect"] for layer in controller["ani_layers"]):
                    raise ValueError("Missing original Blood Blast eruption layer bank")
                controller["ani_layer_source"] = {key: bloodblast_script[key] for key in ("source", "sha256")}
            hit = {"object": path, "offset": [0, depth, 0], "fixed_col": fixed_col,
                   "percent": 0, "native_controller": controller}
            if lift_col is not None:
                # A60751/A611C8 update the attack template's lift slot (+990+5C).
                hit["lift"] = static[lift_col]
            hits.append(hit)
        return {"skill": skill_path, "name": str(skill["name"]),
                "native_state": "bloodblast", "native_recovery_col": 3,
                "material_cost": fixed_cube_cost(skill, records),
                "fidelity_pending": ["target_reaction_rules", "fixed_attack_modifiers",
                                     "fixed_attack_normalization", "final_damage", "thirst_special_target_bonus",
                                     "etc_layer_order", "hit_fx_nested_lifetime", "non_weapon_attack_speed"],
                "stages": [{"ani": "summon1"}, {"ani": "summon2", "voice": "SM_BLOOD_CAST", "hits": hits}]}
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
        }
    names = STAGE_NAMES.get(key, [])
    names = STAGE_ANI_OVERRIDES.get(key, names)
    if not names and (key in CAST_OBJECTS or key in ("khazan", "bremen")):
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
    if key == "hundredsword":
        # CD237F selects ETC 76..80. Only the terminal stage installs a body ATK.
        stages[1:-1] = [{"ani": stage["ani"]} for stage in stages[1:-1]]
        ready = add_fx(fx, effects, CHR_FX + "hundredsword/ready.ani")
        if not ready:
            raise ValueError("Missing original Hundred Sword ready effect")
        # CD1F81..CD1FD6 attaches Ready.ani to the state 47 body.
        stages[0]["fx"] = [{"key": ready, "at": 0, "action_clock": True, "depth_offset": 1}]
        field = add_object(objects, OBJ_ROOT + "hundredswordhit.obj")
        if not field:
            raise ValueError("Missing original Hundred Sword field object")
        definition = records[field]["decoded"]
        main, = definition["basic_motion"]
        overlay, exit_main, exit_overlay = definition["etc_motions"]
        layers = [add_fx(fx, effects, path) for path in (overlay, exit_main, exit_overlay)]
        frames = records[main]["decoded"]["timeline"]
        if not all(layers) or len(frames) != 2 or not frames[1]["attack_boxes"]:
            raise ValueError("Incomplete original Hundred Sword field")
        field_at = records[CHR_ANI + "hundredswordready.ani"]["decoded"]["timeline"][18]["start_ms"]
        distance = records[skill["path"]]["decoded"]["dungeon"]["static_data"][0]
        # CB7EB9 creates object 20051 once. A6C960 holds the last frame and
        # disables the initial hit 50 ms after the first frame ends.
        stages[0]["hits"].append({
            "object": field, "at": field_at, "offset": [distance, 0, 0],
            "percent_col": 0, "starts_at_zero": True,
            "native_controller": {"kind": "hundred_sword_field", "overlay": layers[0],
                                  "exit_layers": layers[1:], "exit_ms": duration_ms(records[exit_main]),
                                  "open_ms": frames[1]["start_ms"], "close_ms": frames[1]["start_ms"] + 50},
        })
        finish = stages[-1]
        impact = records[CHR_ANI + "hundredswordfinish.ani"]["decoded"]["timeline"][2]["start_ms"]
        # CB812D..CB8208 attaches all seven motions together, after the windup.
        finish["fx"] = []
        for stem, depth in HUNDRED_SWORD_FINISH_LAYERS:
            effect = add_fx(fx, effects, CHR_FX + f"hundredsword/{stem}.ani")
            if not effect:
                raise ValueError(f"Missing original Hundred Sword effect: {stem}")
            finish["fx"].append({"key": effect, "at": impact, "depth_offset": depth, "action_clock": True})
        # CD27C3 selects ETC ATK 62, then CD27ED reads zero-based rank column 2.
        finish["hits"][0]["percent_col"] = 2
    if stages and not any(stage.get("hits") for stage in stages) and key not in BUFF_SKILLS and not (
        key in ("khazan", "bremen")
        or key in CAST_OBJECTS and CAST_OBJECTS[key][0] in SAFE_OBJECTS
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
    if key == "hundredsword":
        formation_fx = {stem: add_fx(fx, effects, CHR_FX + f"hundredsword/{stem}.ani")
                        for stem in HUNDRED_SWORD_FORMATION_LAYERS}
        if not all(formation_fx.values()):
            raise ValueError("Missing original Hundred Sword formation effects")
        # CD2550 chooses Normal for layers 0/1, Dodge for layers 2/3.
        # CD26E7 attaches the result by its native render order.
        travel_weapon = [
            [{"bank": f"hundred_sword_weaponready{pose}_{layer:02d}", "order": order,
              "behind": order < 1000, "loop": False}
             for layer, order in sorted(enumerate(orders), key=lambda entry: entry[1])]
            for pose, orders in enumerate(HUNDRED_SWORD_WEAPON_DRAW_ORDER, 1)
        ]
        result.update(native_state="hundred_sword", material_cost=fixed_cube_cost(skill, records),
                      finish_impact_ms=impact, finish_particle=HUNDRED_SWORD_FINISH_PARTICLE,
                      formation={"distance": distance, "styles": HUNDRED_SWORD_STYLES, "effects": formation_fx,
                                 "order": HUNDRED_SWORD_ORDER, "poses": HUNDRED_SWORD_POSES,
                                 "finish_trails": HUNDRED_SWORD_FINISH_TRAILS,
                                 "disappear_ms": duration_ms(records[CHR_FX + "hundredsword/sworddisappear1.ani"])},
                      travel_rate=records[skill["path"]]["decoded"]["dungeon"]["static_data"][1:4],
                      travel_weapon=travel_weapon,
                      fidelity_pending=["sword_formation_pulls_and_repeat_contacts", "travel_slash_effects",
                                        "finish_camera", "rank_bonuses", "original_command"])
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
    if source_key in GHOST_FIELD_SKILLS:
        path = add_object(objects, OBJ_ROOT + source_key + ".obj")
        if not path:
            raise ValueError(f"Missing original {key} field object")
        motions = records[path]["decoded"]["etc_motions"]
        if len(motions) != 6:
            raise ValueError(f"{key} field object needs all six original motions")
        # CNGhost::draw colors ETC slots 0/1. procAppend detaches 2/3,
        # attaches 4, then replaces 4 with 5 when the active interval ends.
        ghost_fx, appear_1, appear_2, stay, disappear = (
            add_fx(fx, effects, motion) for motion in motions[1:]
        )
        if not all((ghost_fx, appear_1, appear_2, stay, disappear)):
            raise ValueError(f"Incomplete original {key} animation banks")
        dungeon = records[str(skill["path"]).lower()]["decoded"]["dungeon"]
        statics = dungeon["static_data"]
        static_count = {"saya": 4, "sayaex": 6}.get(source_key, 2)
        if len(statics) != static_count or min(statics) <= 0:
            raise ValueError(f"Missing original {key} recovery or area radius")
        radius = statics[1]
        # CBBCE0..CBBE7E starts state 13 with SKL casting time, static[0]
        # recovery and motion index zero. 85C750 loads CHR throw motion 1-1/1-2.
        result["native_state"] = "ghost_cast"
        result["native_charge_ani"] = "throw1"
        # CD6026/CD6137/CD7C4E -> 86DE68/86DE70: mirror the original 122 px X offset.
        # A689F0 -> 5FF9D0: static[1] supplies the aura radius and area ANI scale.
        result["fidelity_pending"] = ["area_membership_filters", "area_draw_order"]
        if key in ("bremen", "saya"):
            result["fidelity_pending"].append("status_level_resistance_formula")
        cast_sound, field_sound = GHOST_FIELD_SOUNDS[key]
        hit = {
            "object": path, "at": 0, "offset": [122, 0, 0],
            "percent": 0, "speed": 0,
            "native_controller": {
                "kind": key + "_field", "duration_col": 1, "radius": radius,
                "pulse_ms": statics[3] if key == "saya" else (100 if key == "khazan" else 250),
                "area_scale": radius / 233.0,
                # 7F10B3 multiplies the depth ratio 29 by float32 0.01.
                "depth_scale": 0.29,
                "ghost_fx": ghost_fx, "appear_fx": [appear_1, appear_2],
                "stay_fx": stay, "disappear_fx": disappear,
                "appear_ms": duration_ms(records[motions[2]]),
                "disappear_ms": duration_ms(records[motions[5]]),
                # A67B64..A67D96 gates the object sound on its first update.
                "first_update_sound": field_sound,
            },
        }
        if key == "saya":
            # A67C5B reads level[0] as a percentage. A689F0 sets the three
            # freeze inputs and A680CE checks the height cap at each pulse.
            hit["percent_col"] = 0
            hit["effects"] = [{"id": "freeze", "chance_col": 2, "chance_scale": 0.001,
                               "status_level_col": 3, "duration_ms_col": 4}]
            hit["native_controller"]["height_limit"] = statics[2]
            result["material_cost"] = fixed_cube_cost(skill, records)
            result["fidelity_pending"].append("skill_item_cost_modifiers")
        if source_key == "sayaex":
            # CD7C73 distinguishes 20062 from ordinary 20012, and the last
            # summoned spirit remains skill 96 after the field disappears.
            hit["native_controller"]["ghost_variant"] = "sayaex"
            ice_path = add_object(objects, OBJ_ROOT + "sayaexice.obj")
            ice = records[ice_path]["decoded"]
            ready = records[ice["basic_motion"][0]]["decoded"]
            start, stay, end = ice["etc_motions"]
            layers = {phase: add_fx(fx, effects, motion) for phase, motion in
                      zip(("start", "stay", "end"), (start, stay, end))}
            if not all(layers.values()):
                raise ValueError("Incomplete original Saya EX ice animations")
            launch, = records[start]["decoded"]["sound_events"]
            hit["native_controller"]["crystals"] = {
                "count_col": 5, "respawn_col": 7, "range_col": 8,
                "height": statics[4], "speed": statics[5],
                "child": {"object": ice_path, "percent_col": 6, "native_controller": {
                    "kind": "sayaex_ice", "layers": layers,
                    "ready_first_ms": ready["timeline"][0]["end_ms"],
                    "start_ms": duration_ms(records[start]), "end_ms": duration_ms(records[end]),
                    "start_sound": launch["sound"],
                    "start_sound_at_ms": records[start]["decoded"]["timeline"][launch["frame"]]["start_ms"],
                }},
            }
            result["fidelity_pending"].extend(["crystal_target_predicates", "crystal_native_height",
                                               "crystal_world_rng_seed", "second_growth_learning"])
        # The actor sound is in the phase 1 branch, before object creation.
        stages[:] = [{"ani": "throw2", "atk": "", "hits": [hit], "fx": [],
                      "sounds": [{"at": 0, "key": cast_sound}]}]
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
        result["fidelity_pending"] = ["object_controller", "damage_and_status", "effect_weapon_scale", "cancel_rules"]
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
    # Native state entry 0xCC906A calls the sound virtual with the selected key.
    if key in WAVE_CAST_VOICES:
        stages[0]["voice"] = WAVE_CAST_VOICES[key]
    if key == "bloodyrave":
        result["requires_effect"] = "frenzy"
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
            {"priority": 40, "weapon": [family],
             "replace_stages": [f"weaponcombo{stem}{stage}" for stage in stages]}
            for family, (stem, stages, _, _) in WEAPON_COMBO_VARIANTS.items()
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
                    if base_id == "weaponcombo":
                        family = option["weapon"][0]
                        _, _, gates, finish_fx = WEAPON_COMBO_VARIANTS[family]
                        stage = {"ani": ani, "atk": CHR_ATK + ani + ".atk",
                                 "hits": [{"attached_weapon": True}]}
                        if family == "beamsword":
                            stage["fx"] = [{"key": f"weapon_combo_light_{index + 1}_{layer}",
                                            "at": 0.0, "action_clock": True, "depth_offset": depth}
                                           for layer, depth in enumerate(WEAPON_COMBO_LIGHT_DEPTHS[index], 1)]
                        if index < len(gates):
                            stage["continue_frame"] = gates[index]
                        elif finish_fx:
                            depth = {"greatsword": -1, "beamsword": 4}.get(family, 1)
                            stage.setdefault("fx", []).append({"key": finish_fx, "at": 0.0,
                                                              "action_clock": True, "depth_offset": depth})
                    else:
                        stage = build_stage(
                            base_id, index, stage_names.get(ani, ani), records,
                            atk_by_stem, effect_paths, fx, effects, percent_col=index,
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
                    if base_id == "charge_crash":
                        # The downstroke effect is visual only. 81A6B0 uses the mounted weapon boxes.
                        stage["hits"] = [{"attached_weapon": True}]
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
            # Weapon Combo keeps its previous substitute reach when no original layer is mounted.
            if stages and (base_id == "weaponcombo" or not any(stage.get("hits") for stage in stages)):
                generic_key = add_fx(fx, effects, GENERIC_HIT_EFFECT)
                if generic_key != "":
                    hit_key = "fallback_hits" if base_id == "weaponcombo" else "hits"
                    # The greatsword B/C layers first strike on frame 3 and
                    # cease before frame 6. The fallback retains substitute reach.
                    window = [180, 360] if stages[-1]["ani"] == "weaponcomboheavy2" else [0, 240]
                    stages[-1].setdefault(hit_key, []).append(
                        {
                            "derived": generic_key,
                            "window": window,
                            "percent_col": 0,
                            "atk": stages[-1].get("atk", ""),
                        }
                    )
            variant_move = {
                "skill": base.get("skill", ""),
                "name": base.get("name", ""),
                "stages": stages,
            }
            if base_id == "weaponcombo":
                variant_move["swing"] = 0
            if base.get("effect_id"):
                variant_move["effect_id"] = base["effect_id"]
            moves[variant_id] = variant_move
            option["move"] = variant_id


def build_frenzy_normals(
    moves: dict,
    player_anims: dict[str, str],
) -> None:
    """Frenzy replaces the normal X chain with the source four-swing chain."""
    names = ["frenzy1", "frenzy2", "frenzy3", "frenzy4"]
    for index, ani in enumerate(names):
        stage_number = index + 1
        attack = f"character/swordman/attackinfo/{ani}.atk"
        # CD510A mounts four ANI slots, including one empty clip per stage.
        visible_layers = (1, 3, 4) if stage_number <= 2 else (1, 2, 3)
        depth = {1: -2, 2: -1, 3: 1, 4: 2}
        stage = {
            "ani": ani,
            "atk": attack,
            "hits": [{"attached_weapon": True, "percent_scale_col": 2,
                      "effects": [{"id": "bleed", "native_frenzy": True,
                                   "chance_col": 5, "chance_scale": 0.001,
                                   "status_level_col": 6, "duration_ms_col": 7}]}],
            "fx": [{"key": f"frenzy_sword{stage_number}_{layer}", "at": 0,
                    "action_clock": True, "depth_offset": depth[layer]} for layer in visible_layers],
        }
        move = {
            "skill": "skill/swordman/frenzy.skl",
            "name": "血之狂暴 · 双刀普攻",
            "form_normal": True,
            "requires_effect": "frenzy",
            "swing": 0,  # CD55ED plays the current weapon's first swing cue.
            "stages": [stage],
        }
        # C9F449 caps the continuation index at 3. C9F4CC reads these body frames.
        if index < 3:
            move["next"] = names[index + 1]
            stage["combo_frame"] = (5, 3, 4)[index]
        moves[ani] = move
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
        bloodblast_script = bloodblast_layer_script(library, records)
        fixed_attack_base = dungeon_fixed_attack_base(library, 1)
        bleed_attack_base = dungeon_fixed_attack_base(library, 3)
        shock_attack_base = dungeon_fixed_attack_base(library, 5)
        draw_stagger = draw_stagger_parameters(library)
        shock_table = library.script(DRAW_SHOCK_STATUS_SOURCE)
        if not shock_table or shock_table["sha256"] != "8c94c682a3e2e39835816a1af27b8ffa66d50d161e15aee50d07d0604776a599":
            raise ValueError("Unverified original lightning status table")
        shock_hit_ms, = next(field["values"] for field in shock_table["fields"]
                             if field["tag"] == "[lightning time per number]")
        # Default source tracks for actors currently using family-level equipment.
        draw_tracks = swordman_weapon_tracks(library, "momentaryslash", {
            "shortsword": "ssword/sswdc", "katana": "katana/katanac", "greatsword": "hsword/lswdc",
            "club": "club/clubc", "beamsword": "beamsword/beamswdc",
        }, [2, 3, 4, 5])
        charge_finish_tracks = swordman_weapon_tracks(library, "chargecrashfinish", {
            "greatsword": "hsword/lswdc", "club": "club/clubb",
        }, [3, 4])
        rapid_tracks = rapid_move_slash_tracks(library)
        illusion_tracks = illusion_finish_tracks(library)
        illusion_club_layers = illusion_club_layer_script(library)
        rapid_effects = swordman_skill_effect_slots(library, b"SKILL_RAPID_MOVE_SLASH")["paths"]
        if len(rapid_effects) != 4 or not all(path.startswith(CHR_FX + "rapidmoveslash/") for path in rapid_effects):
            raise ValueError("unexpected Rapid Move Slash effect slots")
        draw_layer = draw_wave_layer(library)
        draw_slashes = draw_effect_slots(library)
        grab_hold = grab_hold_effect_slot(library)
        rave_slots = swordman_skill_effect_slots(library, b"SKILL_BLOODY_RAVE")["paths"]
        outrage_slots = swordman_skill_effect_slots(library, b"SKILL_OUT_RAGE_BREAK")["paths"]
        rave_typhoon = bloody_rave_typhoon_params(library)
        if len(rave_slots) != 15:
            raise ValueError("Unexpected Bloody Rave animation slots")
        SAFE_EFFECTS.clear()
        SAFE_EFFECTS.update(path for path in effect_paths if supported_animation_binding(library, path))
        SAFE_EFFECTS.update(layer["path"] for layer in bloodblast_script["layers"]
                            if safe_animation(library, layer["path"]))
        SAFE_EFFECTS.update(path for path in (illusion_club_layers["attached"], *illusion_club_layers["detached"])
                            if safe_animation(library, path))
        if safe_animation(library, draw_layer["path"]):
            SAFE_EFFECTS.add(draw_layer["path"])
        SAFE_EFFECTS.update(path for path in draw_slashes["paths"] if safe_animation(library, path))
        if safe_animation(library, grab_hold["path"]):
            SAFE_EFFECTS.add(grab_hold["path"])
        SAFE_EFFECTS.update(path for path in [*rave_slots, OBJ_ROOT + "animation/bloodyravelayer.ani"]
                            if safe_animation(library, path))
        SAFE_EFFECTS.update(path for path in outrage_slots if safe_animation(library, path))
        outrage_timing = outrage_eruption_timing(library)
        SAFE_EFFECTS.update(path for name in (*OUTRAGE_FLOOR_FX, *OUTRAGE_MAGMA_FX)
                            if safe_animation(library, path := OUTRAGE_OBJECT_ANIM + name + ".ani"))
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
        object_candidates.update(OBJ_ROOT + key + ".obj" for key in GHOST_FIELD_SKILLS)
        object_candidates.add(OBJ_ROOT + "sayaexice.obj")
        object_candidates.update((RASA_CREATOR, RASA_CHILD))
        object_candidates.add(OBJ_ROOT + "firewavebigsub.obj")
        object_candidates.add(OBJ_ROOT + "blastbloodpresuborigin.obj")
        object_candidates.add(OBJ_ROOT + "givebloodsub.obj")
        object_candidates.add(OBJ_ROOT + "grabblastblood.obj")
        object_candidates.add(OBJ_ROOT + "bloodyrave.obj")
        object_candidates.add(OBJ_ROOT + "outragebreakfloor.obj")
        hundred_sword_field = OBJ_ROOT + "hundredswordhit.obj"
        object_candidates.add(hundred_sword_field)
        SAFE_EFFECTS.update(path for path in records[hundred_sword_field]["decoded"]["etc_motions"]
                            if safe_animation(library, path))
        SAFE_EFFECTS.update(path for stem, _ in HUNDRED_SWORD_FINISH_LAYERS
                            if safe_animation(library, path := CHR_FX + f"hundredsword/{stem}.ani"))
        SAFE_EFFECTS.update(path for stem in HUNDRED_SWORD_FORMATION_LAYERS
                            if safe_animation(library, path := CHR_FX + f"hundredsword/{stem}.ani"))
        object_candidates.add(OBJ_ROOT + "momentaryslashwave.obj")
        object_candidates.update(OBJ_ROOT + f"illusionslashmelee{index}.obj" for index in range(1, 5))
        object_candidates.add(OBJ_ROOT + "illusionslashsub.obj")
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
        if key == "bloodblastex":
            # The EX adapter previously copied the generic base move.
            move = build_move(by_id[24], records, atk_by_stem, effect_paths, fx, effects, objects,
                              native_bloodblast=False)
        if key == "momentaryslashex":
            move = build_move(by_id[9], records, atk_by_stem, effect_paths, fx, effects, objects,
                              native_draw=False)
        if key == "illusionslashexp":
            move = build_move(by_id[73], records, atk_by_stem, effect_paths, fx, effects, objects)
        if move:
            move = json.loads(json.dumps(move))
            move["skill"] = str(skill["path"])
            move["name"] = str(skill["name"])
            if key == "icewaveex":
                # EX uses different IDs/sizing/branches. Do not inherit a base-only controller.
                move["fidelity_pending"].insert(move["fidelity_pending"].index("cancel_rules") + 1, "voice")
                move["fidelity_pending"].insert(move["fidelity_pending"].index("object_ground_authority_rules"), "ice_shatter_particles")
                for stage in move["stages"]:
                    stage.pop("voice", None)
                    for hit in stage.get("hits", []):
                        hit.pop("native_controller", None)
                        hit.update(speed=240.0, life_ms=1800)
                move["fidelity_pending"].append("object_controller")
            if key == "firewaveex":
                # EX 20101 has additional timer/ANI/controller branches. Keep
                # its previous adapter until those paths have source evidence.
                for stage in move["stages"]:
                    stage.pop("voice", None)
                    for hit in stage.get("hits", []):
                        for field in ("native_controller", "rear_fx", "fixed_col", "percent"):
                            hit.pop(field, None)
                        hit.update(speed=360.0, life_ms=1800, percent_col=0, effects=HIT_STATUS["firewave"])
                move["fidelity_pending"] = ["object_controller", "damage_and_status", "effect_weapon_scale", "cancel_rules", "voice"]
        elif key == "bloodyrave":
            move = build_bloody_rave(skill, records, fx, effects, objects, rave_slots, bleed_attack_base, rave_typhoon)
        elif key == "outragebreak":
            move = build_outrage_break(skill, records, fx, effects, objects, outrage_slots, fixed_attack_base,
                                       outrage_timing)
        elif key == "rapidmoveslash":
            layers = [add_fx(fx, effects, path) for path in rapid_effects]
            if not all(layers):
                raise ValueError("missing Rapid Move Slash effect layers")
            move = {"skill": skill["path"], "name": skill["name"], "material_cost": fixed_cube_cost(skill, records),
                    "weapon_tracks": rapid_tracks, "shock_base": shock_attack_base, "shock_hit_ms": shock_hit_ms,
                    "stages": []}
            for index in (1, 2):
                move["stages"].extend([
                    {"ani": f"rapidmoveslashready{index}"},
                    {"ani": f"rapidmoveslashmove{index}",
                     "atk": f"character/swordman/attackinfo/rapidmoveslash{index}.atk",
                     "fx": [{"key": layers[slot], "at": 0, "action_clock": True, "depth_offset": depth}
                            for slot, depth in ((0, 4), (1 + index, 5), (1, 6))],
                     "hits": [{"attached_weapon": True, "percent_col": index - 1}]},
                ])
        else:
            move = build_move(skill, records, atk_by_stem, effect_paths, fx, effects, objects,
                              bloodblast_script=bloodblast_script)
        if move:
            if key == "illusionslash":
                # CC367B's eight ETC slots; 251F810 creates the matching melee object.
                move["slash_order"] = [0, 2, 1, 3, 2, 0, 3, 1]
                move["finish_weapon_tracks"] = illusion_tracks
                move["material_cost"] = fixed_cube_cost(skill, records)
                for index, stage in enumerate(move["stages"][:-1], 1):
                    melee = add_object(objects, OBJ_ROOT + f"illusionslashmelee{index}.obj")
                    if not melee:
                        raise ValueError(f"missing original Illusion Slash melee object {index}")
                    stage["hits"] = [{"object": melee, "percent_col": 0, "offset": [0, 1, 1],
                                      "starts_at_zero": True, "native_controller": {"kind": "illusion_melee"}}]
                    stage["fx"] = []
                move["stages"][0]["voice"] = "SM_HOANYOUNG_START"
                final = move["stages"][-1]
                finish_frames = records[CHR_ANI + final["ani"] + ".ani"]["decoded"]["timeline"]
                upper_at = finish_frames[2]["start_ms"]
                smash_at = finish_frames[6]["start_ms"]
                # CB5145 gates both the smash record and the sword-wave dispatch on frame 6.
                wave = add_object(objects, OBJ_ROOT + "illusionslashwave.obj")
                if not wave:
                    raise ValueError("missing original Illusion Slash sword wave")
                final["hits"] = [{"object": wave, "at": smash_at, "offset": [65, 0, 0], "starts_at_zero": True}]
                ground_wave = add_object(objects, OBJ_ROOT + "illusionslashsub.obj")
                attached = add_fx(fx, effects, illusion_club_layers["attached"])
                detached = [add_fx(fx, effects, path) for path in illusion_club_layers["detached"]]
                if not ground_wave or not attached or not all(detached):
                    raise ValueError("missing original Illusion Slash ground-wave resources")
                shake = records[str(skill["path"])]["decoded"]["shake_screen"]
                if len(shake) != 2:
                    raise ValueError("unexpected original Illusion Slash shake parameters")
                move["club_wave"] = {"object": ground_wave, "at": smash_at, "offset": [180, 0, 0],
                                     "starts_at_zero": True, "native_controller": {"kind": "illusion_club_wave",
                                         "attached": attached, "detached": detached,
                                         "shake": shake,
                                         "particle": OBJ_ROOT + "particle/illusionslashsub.ptl"}}
                upper = add_fx(fx, effects, CHR_FX + "illusionslash/upper.ani")
                smash = add_fx(fx, effects, CHR_FX + "illusionslash/smash.ani")
                if not upper or not smash:
                    raise ValueError("missing original Illusion Slash finisher effect")
                final["fx"] = [{"key": upper, "at": upper_at, "action_clock": True, "depth_offset": 1},
                               {"key": smash, "at": smash_at, "action_clock": True, "depth_offset": 2}]
                final["sounds"] = [{"key": "SM_HOANYOUNG_FIN", "at": smash_at}]
            if key in ("bloodblast", "grabblastblood", "chargecrash"):
                move["fixed_attack_base"] = fixed_attack_base
            if key == "chargecrash":
                move["finish_weapon_tracks"] = charge_finish_tracks
            if key == "grabblastblood":
                move["grab_bleed_base"] = bleed_attack_base
                effect = add_fx(fx, effects, grab_hold["path"])
                if not effect:
                    raise ValueError("Missing original Bloodlust hold effect")
                move["grab_hold_fx"] = {**grab_hold, "effect": effect}
            if key == "momentaryslash":
                move["weapon_tracks"] = draw_tracks
                move["draw_bleed_base"] = bleed_attack_base
                move["draw_shock_base"] = shock_attack_base
                move["draw_shock_hit_ms"] = shock_hit_ms
                move["draw_stagger"] = draw_stagger
                slash_fx = [add_fx(fx, effects, path) for path in draw_slashes["paths"]]
                if not all(slash_fx):
                    raise ValueError("missing original Draw Sword slash layer")
                move["slash_layers"] = {"source": draw_slashes["source"], "sha256": draw_slashes["sha256"],
                                        "slots": slash_fx}
                wave = add_object(objects, OBJ_ROOT + "momentaryslashwave.obj")
                rear = add_fx(fx, effects, draw_layer["path"])
                if not wave or not rear:
                    raise ValueError("missing original Draw Sword wave or rear layer")
                if records[wave]["decoded"].get("int_data") != [0]:
                    raise ValueError("unexpected normal Draw Sword wave growth coefficient")
                move["short_wave"] = {"object": wave, "percent": 0, "offset": [0, 0, 50],
                                      "rear_fx": rear, "native_controller": {"kind": "draw_short_wave",
                                          "layer_source": {k: draw_layer[k] for k in ("source", "sha256")}}}
            moves[runtime_id] = move
            charge_ani = move.get("native_charge_ani")
            if charge_ani:
                player_anims[charge_ani] = CHR_ANI + charge_ani + ".ani"
            idle_ani = move.get("active_idle_ani")
            if idle_ani:
                player_anims[idle_ani] = CHR_ANI + idle_ani + ".ani"
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
