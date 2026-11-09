"""Bake original combat presentation assets into game_dnf/assets_local/combat/ (doc 29, F3~F5).

Reads the full extraction library (dnf_asset_store.py sync --full); never edits it. Output is
git-ignored and lives beside the asset-store runtime copy without touching its managed files.
Everything baked here is an original IMG/ANI/OGG; nothing is drawn or synthesized. Lookups that
cannot be resolved are listed under "unresolved" and never replaced by stand-ins.

Contents
- monsters: Lorien goblin (monster.lst #1, goblin.mob) and its boss, the goblin thrower (#2),
  with their ANI clips (frames, delays, attack/damage boxes) and native-pixel atlases;
- objects: passive-object animations (gore-cross wave, thrown stone) with attack boxes;
- effects: skill and hit effects in the same bank format as the runtime manifest;
- digits: combo/damage bitmap glyphs from sprite/common/etc/combo.img;
- audio: sound keys (ATK [hit wav], CHR [weapon wav], skill cues) mapped to original OGG files.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sqlite3
import sys
import tempfile
import time

from PIL import Image

from dnf_asset_reader import decode, parse
from dnf_asset_store import ROOT
from dnf_pvf import open_library, resolve
from dnf_locomotion import build as build_locomotion
from build_dnf_particles import parse as parse_particle
from compile_dnf_content import NATIVE_ZEALOT_MONSTERS

OUT = ROOT / 'game_dnf/assets_local/combat'
ACTIVE_OUT = OUT
SCHEMA = 'dnf_combat_assets/1'
BUILD_VERSION = 7
SKILL_RUNTIME = ROOT / 'game_dnf/data/skill_runtime.json'
NATIVE_PARTICLES = [
    'passiveobject/character/swordman/particle/'+stem+'.ptl'
    for stem in ('icewaveparticlesmoke', 'icewaveparticle', 'icewaveparticlestar')
]


def native_particle_definitions(src):
    """Small runtime subset, decoded from the source; retain duplicate choices."""
    particles, effects = {}, {}
    for path in NATIVE_PARTICLES:
        doc = src.lib.script(path)
        if not doc:
            raise ValueError('Missing original particle: '+path)
        entry = parse_particle(path, doc)
        if not entry or entry['unsupported'] or entry['diagnostics']:
            raise ValueError('Unresolved native particle: '+path)
        particles[path] = {'sha256': entry['sha256'], 'decoded': entry['decoded']}
        src.sources[path] = entry['sha256']
        for animation in entry['animations']:
            effects['native_'+PurePosixPath(animation).stem] = animation
    return particles, effects

MONSTERS = {
    # key: (mob path, clip dir, extra clips)
    'goblin': ('monster/goblin/goblin.mob', 'monster/goblin/animation_goblin2', []),
    'goblin_thrower': ('monster/goblin/goblinthrower.mob', 'monster/goblin/animation_thrower', []),
    'tau_army': ('monster/tau/tauarmy.mob', 'monster/tau/armyanimation', []),
    'tau_beast': ('monster/tau/taubeast.mob', 'monster/tau/beastanimation', []),
    'lugaru': ('monster/lugaru/lugaru.mob', 'monster/lugaru/animation_lugaru', ['stay_2','attack']),
    'kurogaru': ('monster/lugaru/kurogaru.mob', 'monster/lugaru/animation_blacklugaru', ['stay_2','attack']),
    'goblin_ice': ('monster/goblin/seagab.mob','monster/goblin/animation_islandgoblin',[]),
    'goblin_fire': ('monster/goblin/hillgab.mob','monster/goblin/animation_mountaingoblin',[]),
    'goblin_taskmaster': ('monster/goblin/goblintaskmaster.mob','monster/goblin/animation_kinol2',[]),
    'goblin_thrower_taskmaster': ('monster/goblin/goblinthrowertaskmaster.mob','monster/goblin/animation_gero',[]),
}
MONSTER_CLIPS = ['stay', 'move', 'attack1', 'throw', 'damage1', 'damage2', 'down', 'sit', 'overturn']
OBJECTS = {
    'gorecross': 'passiveobject/character/swordman/animation/gorecross1.ani',
    'throwstone': 'passiveobject/monster/goblin/animation/throwstone.ani',
    'goblin_ice': 'passiveobject/common/animation/icemissile1.ani',
    'goblin_fire': 'passiveobject/common/animation/firemissile.ani',
    'native_cannonball': 'passiveobject/monster/vehicle/cannonball.obj',
    'native_pope_thunderbolt': 'passiveobject/monster/zealot/popethunderbolt.obj',
}
# Player motions used by the trial skills that the runtime manifest does not carry yet.
# Frames index the same 210-pose body/weapon atlases (all <= 209).
PLAYER_CLIPS = {
    'getitem': 'character/swordman/animation/getitem.ani',
    'hardattack': 'character/swordman/animation/hardattack.ani',
    'moonlightslash1': 'character/swordman/animation/moonlightslash1.ani',
    'moonlightslash2': 'character/swordman/animation/moonlightslash2.ani',
    'chargecrashdash': 'character/swordman/animation/chargecrashdash.ani',
    'chargecrashupper': 'character/swordman/animation/chargecrashupper.ani',
    'tripleslash1': 'character/swordman/animation/tripleslash1.ani',
    'tripleslash2': 'character/swordman/animation/tripleslash2.ani',
    'tripleslash3': 'character/swordman/animation/tripleslash3.ani',
    'summon2': 'character/swordman/animation/summon2.ani',
}
# Effects whose opaque pixel extent stands in for an attack box where the original motion has
# none (DNF-D011). Depth is fixed to the common original box depth (y=-15, d=30). E-ADAPT.
DERIVED_BOXES = ['hardattack1', 'upper1', 'triple1', 'triple2', 'triple3', 'gore_slash1', 'gore_slash2']
DERIVED_DEPTH = (-15, 30)
# Original swordman ANIs whose attack boxes stand in for motions that carry none (DNF-D011):
# the short-sword-mastery variants of the same normal attacks / upper slash. E-ADAPT.
BORROWED = ['character/swordman/effect/animation/shortswordmastery/shortattack1dodge.ani',
            'character/swordman/effect/animation/shortswordmastery/shortattack2dodge.ani',
            'character/swordman/effect/animation/shortswordmastery/shortweaponupperslashafter.ani']
EFFECTS = {
    'item_heal': 'common/commoneffect/animation/heal.ani',
    'item_fastheal': 'common/commoneffect/animation/fastheal.ani',
    'hardattack1': 'character/swordman/effect/animation/hardattack1.ani',
    'hardattack2': 'character/swordman/effect/animation/hardattack2.ani',
    'moonlight1': 'character/swordman/effect/animation/moonlightslash1.ani',
    'moonlight2': 'character/swordman/effect/animation/moonlightslash2.ani',
    'charge_dash': 'character/swordman/effect/animation/chargecrash/dash.ani',
    'charge_upper': 'character/swordman/effect/animation/chargecrash/up-slash.ani',
    'upper1': 'character/swordman/effect/animation/upperslash1.ani',
    'upper2': 'character/swordman/effect/animation/upperslash2.ani',
    'triple1': 'character/swordman/effect/animation/tripleslash/slash1.ani',
    'triple2': 'character/swordman/effect/animation/tripleslash/slash2.ani',
    'triple3': 'character/swordman/effect/animation/tripleslash/slash3.ani',
    'triple_move1': 'character/swordman/effect/animation/tripleslash/move1.ani',
    'triple_move2': 'character/swordman/effect/animation/tripleslash/move2.ani',
    'gore_slash1': 'character/swordman/effect/animation/gorecross/slash1.ani',
    'gore_slash2': 'character/swordman/effect/animation/gorecross/slash2.ani',
    'gore_cross_add': 'passiveobject/character/swordman/animation/gorecross2.ani',
    'frenzy_cast': 'character/swordman/effect/animation/frenzy/cast.ani',
    'frenzy_buff': 'character/swordman/effect/animation/frenzy/buff.ani',
    'hit_cut_s1': 'common/hiteffect/animation/age12/slashsmall1.ani',
    'hit_cut_s2': 'common/hiteffect/animation/age12/slashsmall2.ani',
    'hit_cut_s3': 'common/hiteffect/animation/age12/slashsmall3.ani',
    'hit_cut_l1': 'common/hiteffect/animation/age12/slashlarge1.ani',
    'hit_cut_l2': 'common/hiteffect/animation/age12/slashlarge2.ani',
    'hit_cut_l3': 'common/hiteffect/animation/age12/slashlarge3.ani',
    'hit_blow_s': 'common/hiteffect/animation/age12/knocksmall.ani',
    'hit_blow_l': 'common/hiteffect/animation/age12/knocklarge.ani',
    'hit_blood_s1': 'common/hiteffect/animation/splashbloodsmall1.ani',
    'hit_blood_s2': 'common/hiteffect/animation/splashbloodsmall2.ani',
    'hit_blood_s3': 'common/hiteffect/animation/splashbloodsmall3.ani',
    'hit_blood_l': 'common/hiteffect/animation/splashbloodlarge.ani',
}
# combo.img frame ranges, read from the image itself (temp contact sheet, 2026-10-22).
DIGITS = {'combo': (0, 10), 'combo_label': (10, 11), 'damage': (44, 54), 'damage_crit': (54, 64),
          'heal': (64, 74), 'mp': (74, 84), 'damage_taken': (88, 98)}
# Sound keys -> filename stems. R_ prefix = random variants (_01.._0n) of the stem.
# Aliases are inferred from file naming in the archive (E-INFER); unknown keys stay unresolved.
SOUND_ALIASES = {'MINERAL_SWD': 'MINSWD', 'MINERALSWD': 'MINSWD', 'SQUARESWD': 'SQRSWD', 'KATANA': 'KAT',
                 'SLESSSWDA': 'SLESSSWD', 'STICK_HIT': 'STICKA_HIT', 'ASTROM': 'ASTORM'}
# State 24 entry keys at 0xCC8C2F, 0xCC901A, and 0xCC8EE4, resolved by original audio.xml.
WAVE_CAST_AUDIO = {
    'HADOUKEN': 'sounds/char/swordman/effect/hadouken.ogg',
    'SM_ICEWAVE': 'sounds/char/swordman/sm_icewave.ogg',
    'SM_FIREWAVE': 'sounds/char/swordman/sm_firewave.ogg',
}

# Preserve audio.xml spelling: Khazan's caster key is KAZHAN and the object key is KAJAN.
GHOST_FIELD_AUDIO = {
    'SM_GHOST_KAZHAN': 'sounds/char/swordman/sm_kghost.ogg',
    'GHOST_KAJAN': 'sounds/effect/magic/ghost_kajan.ogg',
    'SM_GHOST_BREMEN': 'sounds/char/swordman/sm_bghost.ogg',
    'GHOST_BREMEN': 'sounds/effect/magic/ghost_bremen.ogg',
    'SM_GHOST_SAYA': 'sounds/char/swordman/sm_sghost.ogg',
    'GHOST_SAYA': 'sounds/effect/magic/ghost_saya.ogg',
    'SM_RASA': 'sounds/char/swordman/sm_rasa.ogg',
}

ZEALOT_SOUNDS = {
    'KNIFE_STICK': ['sounds/effect/knife_stick.ogg'],
    'ZGM_SPRING': ['sounds/mon/act3/zgm_spring.ogg'],
    'ZGM_ATK': ['sounds/mon/act3/zgm_atk.ogg'],
}
CUE_SOUNDS = {
    **{key: [path] for key, path in WAVE_CAST_AUDIO.items()},
    **{key: [path] for key, path in GHOST_FIELD_AUDIO.items()},
    **ZEALOT_SOUNDS,
    'DRGCANNON_SHOOT': ['sounds/mon/act3/drgcan_shoot.ogg'],
    'R_BOMB_HIT': ['sounds/effect/bomb_hit_01.ogg', 'sounds/effect/bomb_hit_02.ogg'],
    'swing1': ['sounds/char/swordman/sm_atk_01.ogg'], 'swing2': ['sounds/char/swordman/sm_atk_02.ogg'],
    'swing3': ['sounds/char/swordman/sm_atk_03.ogg'], 'jump': ['sounds/char/swordman/sm_jump.ogg'],
    'jump_attack': ['sounds/char/swordman/sm_jumpatk_01.ogg', 'sounds/char/swordman/sm_jumpatk_02.ogg'],
    'upper': ['sounds/char/swordman/sm_upslash.ogg'], 'draw_ready': ['sounds/char/swordman/sm_bal1.ogg'],
    'draw': ['sounds/char/swordman/sm_bal2.ogg'], 'triple1': ['sounds/char/swordman/sm_triple1.ogg'],
    'triple2': ['sounds/char/swordman/sm_triple2.ogg'], 'triple3': ['sounds/char/swordman/sm_triple3.ogg'],
    'gorecross': ['sounds/char/swordman/sm_gorecross.ogg'], 'gorecross_cross': ['sounds/char/swordman/effect/gorecross_cross.ogg'],
    'backstep': ['sounds/char/swordman/sm_back.ogg'],
    'hurt': ['sounds/char/swordman/sm_dmg_01.ogg', 'sounds/char/swordman/sm_dmg_02.ogg', 'sounds/char/swordman/sm_dmg_03.ogg'],
    'die': ['sounds/char/swordman/sm_die.ogg'],
    'goblin_hurt': ['sounds/mon/act1/gbn_dmg_01.ogg', 'sounds/mon/act1/gbn_dmg_02.ogg', 'sounds/mon/act1/gbn_dmg_03.ogg', 'sounds/mon/act1/gbn_dmg_04.ogg'],
    'goblin_die': ['sounds/mon/act1/gbn_die_01.ogg', 'sounds/mon/act1/gbn_die_02.ogg'],
}
SOUND_KEYS = ['STAFF_HIT', 'R_STICK_HIT', 'R_DRAWING_SWORD_HIT', 'R_SLESSSWDA_HIT', 'R_SQUARESWDC_HIT',
              'R_GORECROSS_HIT', 'THROW_STONE', 'GORECROSS_ATK3', 'ASTROM_HIT_LIGHT', 'UPPER_SLASH_01']
MONSTER_HP_IMG = 'sprite/interface/newstyle/windows/monster_hp/monster_hp.img'


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def safe_atlas_key(prefix: str, value: str) -> str:
    stem = re.sub(r'[^a-z0-9_]+', '_', Path(value).stem.lower()).strip('_')
    return '%s_%s_%s' % (prefix, stem, hashlib.sha256(value.encode('utf-8')).hexdigest()[:8])


class Source:
    def __init__(self, library: Path | None, *, pack_path: Path | None = None):
        self.lib = open_library(library)
        self.root = self.lib.path
        pack_path = pack_path or ROOT / 'game_dnf/assets_local/content/combat_content.json'
        self.pack_records = json.loads(pack_path.read_text(encoding='utf-8'))['records'] if pack_path.is_file() else {}
        self.cat = sqlite3.connect(f'file:{self.root / "catalog.sqlite"}?mode=ro', uri=True)
        self.cat.row_factory = sqlite3.Row
        self._img = {}
        self.audio_paths = sorted({r[0] for r in self.cat.execute(
            "select distinct lower(original_path) from assets where kind='audio'")})
        self.sources: dict[str, str] = {}

    def image(self, path: str):
        path = ('sprite/' + path if not path.lower().startswith('sprite/') else path).lower()
        if path not in self._img:
            rows = self.cat.execute("select * from assets where lower(original_path)=? and validation='image_data_checked'",
                                    (path,)).fetchall()
            if not rows:
                self._img[path] = None
            else:
                rows = sorted(rows, key=lambda r: (not Path(r['container']).name.lower().startswith('sprite_'), r['container']))
                data = (self.root / rows[0]['local_path']).read_bytes()
                if sha(data) != rows[0]['sha256']:
                    raise ValueError('Library image hash mismatch: ' + path)
                self.sources[path] = rows[0]['sha256']
                self._img[path] = (data, parse(data))
        return self._img[path]

    def frame(self, path: str, index: int):
        found = self.image(path)
        if found is None:
            raise KeyError(path)
        return decode(found[0], found[1], index)

    def animation(self, path: str) -> dict:
        found = self.lib.animation(path)
        if found is None or found['metadata'] is None:
            raise KeyError('Missing parsed ANI: ' + path)
        self.sources[path] = found['sha256']
        return found['metadata']

    def object_animation(self, path: str) -> str:
        """Resolve OBJ [basic motion] to the ANI consumed by effect_bank."""
        path = path.lower()
        if not path.endswith('.obj'):
            return path
        compiled = self.pack_records.get(path, {}).get('decoded', {})
        motions = compiled.get('basic_motion') or compiled.get('etc_motions') or []
        if motions:
            return str(motions[0])
        script = self.lib.script(path, 'obj')
        if script is None:
            raise KeyError('Missing parsed OBJ: ' + path)
        stack = list(script['fields'])
        while stack:
            node = stack.pop()
            if node['tag'] == '[basic motion]' and node.get('values'):
                return resolve(path, str(node['values'][0]))
            stack.extend(node.get('children', []))
        raise KeyError('OBJ has no [basic motion]: ' + path)

    def audio(self, path: str) -> Path | None:
        row = self.cat.execute("select * from assets where kind='audio' and lower(original_path)=? order by container limit 1",
                               (path.lower(),)).fetchone()
        return (self.root / row['local_path'], row['sha256']) if row else None


class Atlas:
    def __init__(self, name: str, texture_root: str = 'res://assets_local/combat/', output_dir: Path | None = None):
        self.name, self.items, self.images = name, {}, []
        self.texture_root = texture_root.rstrip('/') + '/'
        self.output_dir = output_dir or ACTIVE_OUT
        self.x = self.y = 2
        self.row_h = 0

    def add(self, key, image: Image.Image, offset) -> None:
        w, h = image.size
        if self.x + w + 2 > 2048:
            self.x, self.y, self.row_h = 2, self.y + self.row_h + 4, 0
        self.items[str(key)] = {'rect': [self.x, self.y, w, h], 'offset': list(offset)}
        self.images.append((image, self.x, self.y))
        self.x += w + 4
        self.row_h = max(self.row_h, h)

    def save(self) -> dict:
        canvas = Image.new('RGBA', (2048, self.y + self.row_h + 2))
        for image, x, y in self.images:
            canvas.paste(image, (x, y))
        self.output_dir.mkdir(parents=True, exist_ok=True)
        canvas.save(self.output_dir / (self.name + '.png'))
        return {'texture': self.texture_root + self.name + '.png', 'items': self.items}


def cropped(image: Image.Image, meta: dict):
    box = image.getbbox()
    if not box:
        return Image.new('RGBA', (1, 1)), [meta['x'], meta['y']]
    # Trim transparent padding only; native pixels are never resized or recolored.
    return image.crop(box), [meta['x'] + box[0], meta['y'] + box[1]]


def animation_flags(ani: dict) -> dict:
    """Preserve native globals; binary tag 0 is [LOOP], default false.

    Verified client: 10943E2 writes data+1, 1093FC7 initializes it to 0;
    1095EB3 is the [LOOP] text branch, 108E5F8 chooses stop/restart.
    Tag 1 writes data+2 and is NOT the loop flag.
    """
    globals_ = copy.deepcopy(ani.get('global_items', {}))
    return {'global_items': globals_, 'loop': bool(globals_.get('0', 0))}


def refresh_animation_metadata(src: Source, manifest: dict) -> dict:
    """Update only ANI metadata, validating the bank's pinned source first.

    Prepare a copy so any missing/mismatched source leaves the caller intact.
    Original PNGs, frame timing, cropping and anchors are never regenerated.
    """
    result = copy.deepcopy(manifest)
    for section in ('objects', 'effects'):
        for bank in result.get(section, {}).values():
            path = bank['source']
            ani = src.animation(path)
            if manifest.get('sources', {}).get(path) != src.sources[path]:
                raise ValueError('ANI source hash differs from existing bank: ' + path)
            bank.update(animation_flags(ani))
    return result


def effect_bank(src: Source, key: str, ani_path: str, unresolved: list) -> dict:
    ani = src.animation(ani_path)
    atlas, frames = Atlas('fx_' + key), []
    bounds = None
    for n, f in enumerate(ani['frames']):
        rec = dict(f)
        if f.get('img'):
            try:
                image, meta = src.frame(f['img'], f['img_frame'])
            except KeyError:
                unresolved.append({'kind': 'image', 'path': f['img'], 'for': ani_path})
                frames.append(rec)
                continue
            image, offset = cropped(image, meta)
            x, y = offset[0] + f['pos'][0], offset[1] + f['pos'][1]
            atlas.add(n, image, [x, y])
            rec['sprite'] = str(n)
            if image.width > 1:
                b = (x, y, x + image.width, y + image.height)
                bounds = b if bounds is None else (min(bounds[0], b[0]), min(bounds[1], b[1]), max(bounds[2], b[2]), max(bounds[3], b[3]))
        frames.append(rec)
    bank = {'atlas': atlas.save(), 'frames': frames, 'duration_ms': ani['duration_ms'], 'source': ani_path,
            **animation_flags(ani)}
    if bounds is not None:
        # Box6 [x, y, z, w, d, h]: screen y grows downward, height z grows upward from the anchor.
        bank['pixel_box'] = [bounds[0], DERIVED_DEPTH[0], -bounds[3], bounds[2] - bounds[0], DERIVED_DEPTH[1], bounds[3] - bounds[1]]
    return bank


def monster_bank(src: Source, key: str, mob: str, clip_dir: str, unresolved: list, extra=(), motion_map=None,
                 *, atlas_root: str = 'res://assets_local/combat/', output_dir: Path | None = None) -> dict:
    """烘焙一只怪的动作图集。

    有 motion_map（pose → 完整 ANI 路径）时直接按 .mob 的动作表逐帧取图：
    帧可以来自不同 IMG，atlas 内统一重编号，clips 的 img_frame 同步改写。
    没有 motion_map 时沿用旧的 clip_dir + MONSTER_CLIPS 约定。
    """
    atlas = Atlas('mob_' + key, atlas_root, output_dir)
    clips, images, index = {}, set(), 0
    missing_images = set()
    specs = list(motion_map.items()) if motion_map else [(n, f'{clip_dir}/{n}.ani') for n in MONSTER_CLIPS + list(extra)]
    for name, path in specs:
        try:
            ani = src.animation(path)
        except KeyError:
            continue
        images.update(ani['images'])
        frames = []
        for frame in ani['frames']:
            if frame.get('img_frame') is None:
                continue
            try:
                image, meta = src.frame(str(frame['img']), int(frame['img_frame']))
            except KeyError:
                missing_images.add(str(frame['img']))
                continue
            except Exception as error:
                unresolved.append({'kind': 'monster_frame_error', 'monster': mob,
                                   'path': str(frame['img']), 'error': str(error)})
                continue
            image, offset = cropped(image, meta)
            atlas.add(index, image, offset)
            turned = dict(frame)
            turned['img_frame'] = index
            frames.append(turned)
            index += 1
        if frames:
            clips[name] = {'frames': frames, 'duration_ms': ani.get('duration_ms', 0), 'images': ani['images']}
    if len(images) > 1:
        unresolved.append({'kind': 'monster_layers', 'monster': mob, 'images': sorted(images)})
    for image_path in sorted(missing_images):
        unresolved.append({'kind': 'monster_image', 'monster': mob, 'path': image_path})
    # 运行时播的 pose 是 "attack"；旧 clip 目录约定叫 "attack1"，缺了就别名过去，
    # 否则攻击时视图回落成 stay（站着挨打）。
    if 'attack' not in clips and 'attack1' in clips:
        clips['attack'] = clips['attack1']
    if not clips:
        unresolved.append({'kind': 'monster_no_clips', 'monster': mob})
        return {}
    body = sorted(images)[0] if images else ''
    script = src.lib.script(mob, 'mob')
    equipment = [f['values'] for f in script['fields'] if f['tag'] == '[equipment]']
    # `.mob` 的 [equipment] 写作 `Monster/Goblin/tcc2.equ`，实际文件在
    # `equipment/monster/goblin/tcc2.equ`；按 mob 所在的怪种目录（goblin/tau/…）拼接。
    area = PurePosixPath(mob).parent.name.lower()
    for parts in equipment:
        for part in parts[1:]:
            if not isinstance(part, str):
                continue
            name = PurePosixPath(part.replace('\\', '/')).name.lower()
            equ = 'equipment/monster/%s/%s' % (area, name)
            if not src.lib.exists(equ):
                unresolved.append({'kind': 'monster_equipment', 'monster': mob, 'path': equ,
                                   'note': 'equipment file absent; appearance drawn from body IMG only'})
    return {'atlas': atlas.save(), 'clips': clips, 'mob': mob, 'body_image': body}


def sound_files(src: Source, key: str) -> list[str]:
    stem = key[2:] if key.startswith('R_') else key
    for old, new in SOUND_ALIASES.items():
        stem = stem.replace(old, new)
    stem = stem.lower()
    exact = [p for p in src.audio_paths if PurePosixPath(p).stem == stem]
    variants = [p for p in src.audio_paths if PurePosixPath(p).stem.startswith(stem + '_')
                and PurePosixPath(p).stem[len(stem) + 1:].isdigit()]
    found = variants if key.startswith('R_') and variants else exact or variants
    # Prefer the shared effect folder when the same stem exists for several characters.
    effect = [p for p in found if p.startswith('sounds/effect/')]
    return effect or found


def copy_audio(src: Source, files: list[str], audio: dict, key: str, unresolved: list) -> None:
    out = []
    for path in files:
        found = src.audio(path)
        if not found:
            unresolved.append({'kind': 'audio', 'key': key, 'path': path})
            continue
        local, digest = found
        target = ACTIVE_OUT / 'audio' / PurePosixPath(path).name
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists():
            shutil.copyfile(local, target)
        out.append({'file': 'res://assets_local/combat/audio/' + target.name, 'source': path, 'sha256': digest})
    if out:
        audio[key] = out
    elif key not in [u.get('key') for u in unresolved]:
        unresolved.append({'kind': 'audio', 'key': key, 'note': 'no original file matches'})


def weapon_sounds(src: Source) -> dict:
    chr_rec = src.lib.script('character/swordman/swordman.chr', 'chr')
    rows = [f['values'] for f in chr_rec['fields'] if f['tag'] == '[weapon wav]']
    # CHR weapon subtype order (E-INFER from key names): short sword, katana, club, greatsword, -, beam sword.
    names = ['shortsword', 'katana', 'club', 'greatsword', 'unknown', 'beamsword']
    return {names[i]: row for i, row in enumerate(rows) if i < len(names)}


# .mob 的动作槽 ↔ 运行时 pose 名（view 按 pose 取 clip）。
POSE_MAP = {'waiting': 'stay', 'move': 'move', 'attack': 'attack', 'damage1': 'damage1',
            'damage2': 'damage2', 'down': 'down', 'overturn': 'overturn', 'sit': 'sit',
            'die': 'die', 'jump': 'jump'}


def catalog_monster_specs() -> dict:
    """副本里出现、但不在手写 MONSTERS 里的怪：按 data/monster_catalog.json 的动作表补。

    返回 {key: {'mob': path, 'motions': {pose: 完整 ANI 路径}}}。
    """
    catalog_path = ROOT / 'game_dnf/data/monster_catalog.json'
    dungeons_path = ROOT / 'game_dnf/data/dungeons.json'
    if not catalog_path.is_file():
        return {}
    catalog = json.loads(catalog_path.read_text(encoding='utf-8'))['monsters']
    needed: set[str] = set()
    if dungeons_path.is_file():
        dungeons = json.loads(dungeons_path.read_text(encoding='utf-8'))['dungeons']
        for spec in dungeons.values():
            export = spec.get('map_export', '')
            if not export:
                continue
            path = ROOT / 'game_dnf' / export.replace('res://', '')
            if not path.is_file():
                continue
            data = json.loads(path.read_text(encoding='utf-8'))
            for room in (data.get('dungeon', {}).get('rooms') or {}).values():
                for monster in room.get('monsters') or []:
                    if monster.get('mob'):
                        needed.add(str(monster['mob']).lower())
    builtin = {str(mob).lower() for mob, _dir, _extra in MONSTERS.values()} | set(NATIVE_ZEALOT_MONSTERS.values())
    out = {}
    for _key, mob in catalog.items():
        path = str(mob['path']).lower()
        if path in builtin or path not in needed:
            continue
        motions = {}
        for slot, values in (mob.get('motions') or {}).items():
            pose = POSE_MAP.get(slot)
            if pose is None or not values:
                continue
            # 攻击槽多值 = 多套招式（BOSS）。每招用 ANI 文件名（小写）当 clip 名，
            # 与运行时 enemy_ani 选的 stem 一致；第一招再额外挂 "attack" 兜底。
            for index, value in enumerate(values):
                full = (mob['folder'] + '/' + str(value)).lower()
                if pose != 'attack':
                    if index == 0:
                        motions[pose] = full
                    continue
                stem = PurePosixPath(str(value)).stem.lower()
                motions[stem] = full
                if index == 0:
                    motions['attack'] = full
        if not motions:
            continue
        out[path.replace('monster/', '', 1).replace('.mob', '').replace('/', '_')] = {'mob': path, 'motions': motions}
    return out


def resolve_relative(folder: str, relative: str) -> str:
    """`../trap/particle/x.ptl` 这类相对路径 → 库内绝对路径。"""
    stack: list[str] = []
    for part in (folder + '/' + relative.replace('\\', '/')).split('/'):
        if part in ('', '.'):
            continue
        if part == '..':
            if stack:
                stack.pop()
            continue
        stack.append(part)
    return '/'.join(stack).lower()


def breakable_objects() -> list[str]:
    """副本地图里出现的可破坏物 .obj 路径（去重）。"""
    dungeons_path = ROOT / 'game_dnf/data/dungeons.json'
    if not dungeons_path.is_file():
        return []
    found: set[str] = set()
    for spec in json.loads(dungeons_path.read_text(encoding='utf-8'))['dungeons'].values():
        export = spec.get('map_export', '')
        if not export:
            continue
        path = ROOT / 'game_dnf' / export.replace('res://', '')
        if not path.is_file():
            continue
        try:
            data = json.loads(path.read_text(encoding='utf-8'))
        except Exception:
            continue
        for room in (data.get('dungeon', {}).get('rooms') or {}).values():
            for obj in room.get('objects') or []:
                target = str(obj.get('obj', '')).lower()
                if 'breakableobject/' in target and target.endswith('.obj'):
                    found.add(target)
    return sorted(found)


def breakable_particle_animations(src: Source) -> tuple[dict, dict]:
    """可破坏物打碎时的粒子：`.obj` 的 `[destroy particle]` → `.ptl` → 它引用的 ANI。

    返回 (effect_key → ANI 路径, obj 路径 → effect_key 列表)：
    前者用于烘 effect bank，后者写进 data/breakable_particles.json 供运行时查。
    """
    particles_path = ROOT / 'game_dnf/assets_local/content/particles.json'
    if not particles_path.is_file():
        return {}, {}
    particles = json.loads(particles_path.read_text(encoding='utf-8'))['particles']
    effects: dict[str, str] = {}
    mapping: dict[str, list] = {}
    for path in breakable_objects():
        if not src.lib.exists(path):
            continue
        doc = src.lib.script(path)
        spans: dict[str, list] = {}
        for item in doc.get('fields') or []:
            spans.setdefault(item['tag'], []).append(item['values'])
        folder = str(PurePosixPath(path).parent)
        keys: list = []
        # 粒子有两种写法：独立的 [destroy particle] 字段，或塞在 [string data] 里
        # （桶的 BarrelDestroy.ptl 就在 string data 第 3 项）。两条都扫。
        candidates: list = list((spans.get('[destroy particle]') or [[]])[0])
        candidates += list((spans.get('[string data]') or [[]])[0])
        for value in candidates:
            if not isinstance(value, str) or not value.lower().endswith('.ptl'):
                continue
            entry = particles.get(resolve_relative(folder, value), {})
            for ani in entry.get('animations') or []:
                key = 'ptl_' + PurePosixPath(ani).stem.lower()
                effects.setdefault(key, ani)
                if key not in keys:
                    keys.append(key)
        if keys:
            mapping[path] = keys
    return effects, mapping


def native_zealot_monster_bank(src: Source, key: str, mob: str, unresolved: list) -> dict:
    """Use the pinned content pack to include the exact native state animation clips."""
    record = src.pack_records.get(mob, {})
    decoded = record.get('decoded', {})
    suicide = record.get('native_suicide', {})
    jump = record.get('native_starfish_jump', {})
    if not decoded or not (suicide or jump):
        raise ValueError('Compile the native Zealot and StarFish content first: ' + mob)
    motions = {}
    for pose, field in (('stay', 'waiting_motion'), ('move', 'move_motion'), ('sit', 'sit_motion'),
                        ('damage1', 'damage_motion_1'), ('damage2', 'damage_motion_2'),
                        ('down', 'down_motion'), ('overturn', 'overturn_motion')):
        paths = decoded.get(field) or []
        if paths and paths[0]:
            motions[pose] = paths[0]
            motions[PurePosixPath(paths[0]).stem] = paths[0]
    for slot, path in enumerate(decoded.get('attack_motions') or []):
        if path:
            motions[PurePosixPath(path).stem] = path
            if slot == 0:
                motions['attack'] = path
    specials = (suicide['suicide_ani'],) if suicide else (decoded.get('etc_motions') or [])
    for path in specials:
        if path:
            motions[PurePosixPath(path).stem] = path
    for path in {mob, *motions.values()}:
        found = src.lib.raw(path)
        if not found or found[1] != src.pack_records.get(path, {}).get('source', {}).get('sha256'):
            raise ValueError('Native monster source differs from compiled pack: ' + path)
        src.sources[path] = found[1]
    bank = monster_bank(src, key, mob, '', unresolved, motion_map=motions)
    missing_clips = set(motions) - bank.get('clips', {}).keys()
    if missing_clips:
        raise ValueError(f'Native monster {mob} lacks source clips: {sorted(missing_clips)}')
    return bank


def monster_specifications() -> dict:
    """手写条目（旧 clip 目录约定）+ 总账自动补全条目。"""
    specs = {key: {'mob': mob, 'clip_dir': clip_dir, 'extra': extra} for key, (mob, clip_dir, extra) in MONSTERS.items()}
    specs.update(catalog_monster_specs())
    return specs


def remove_tree(path: Path) -> None:
    """Remove a completed staging/backup tree without a bulk recursive delete."""
    if not path.exists():
        return
    for child in sorted(path.rglob('*'), key=lambda item: len(item.parts), reverse=True):
        if child.is_symlink() or child.is_file():
            child.unlink()
        elif child.is_dir():
            child.rmdir()
    path.rmdir()


def publish_tree(stage: Path, target: Path, *, backup_parent: Path | None = None) -> Path | None:
    """Swap a completed build into place; keep the old tree until the swap succeeds."""
    backup_parent = backup_parent or (ROOT / 'temp')
    backup_parent.mkdir(parents=True, exist_ok=True)
    backup = backup_parent / ('%s.previous.%d' % (target.name, time.time_ns()))
    had_previous = target.exists()
    if had_previous:
        # Import metadata owns stable resource UIDs. Carry it into the staged tree
        # only for assets that are still generated by this build.
        for old_import in target.rglob('*.import'):
            relative = old_import.relative_to(target)
            asset_relative = Path(str(relative)[:-7])
            if (stage / asset_relative).is_file():
                destination = stage / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(old_import, destination)
        os.replace(target, backup)
    try:
        os.replace(stage, target)
    except Exception:
        if had_previous and backup.exists() and not target.exists():
            os.replace(backup, target)
        raise
    if not had_previous:
        return None
    try:
        remove_tree(backup)
    except OSError as error:
        print('WARNING: previous combat tree retained at %s (%s)' % (backup, error), file=sys.stderr)
        return backup
    return None


def build(library: Path | None, output: Path = OUT) -> dict:
    global ACTIVE_OUT
    # Validate the full source library before replacing a consumable runtime.
    src = Source(library)
    staging_root = ROOT / 'temp'
    staging_root.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='dnf-combat-build-', dir=staging_root))
    ACTIVE_OUT = stage
    unresolved: list = []
    manifest = {'schema': SCHEMA, 'build_version': BUILD_VERSION, 'asset_version': src.lib.asset_version,
                'monsters': {}, 'objects': {}, 'effects': {}, 'digits': {}, 'audio': {}, 'weapon_sounds': {},
                'unresolved': unresolved}
    runtime = json.loads(SKILL_RUNTIME.read_text(encoding='utf-8')) if SKILL_RUNTIME.is_file() else {}
    if runtime:
        manifest['skill_runtime_sha256'] = hashlib.sha256(SKILL_RUNTIME.read_bytes()).hexdigest()
    runtime_assets = runtime.get('assets', {})
    player_clips = dict(PLAYER_CLIPS)
    player_clips.update(runtime_assets.get('player_anims', {}))
    objects = dict(OBJECTS)
    objects.update(runtime_assets.get('objects', {}))
    effects = dict(EFFECTS)
    effects.update(runtime_assets.get('effect_anims', {}))
    manifest['particles'], particle_effects = native_particle_definitions(src)
    effects.update(particle_effects)
    for key, spec in monster_specifications().items():
        manifest['monsters'][key] = monster_bank(src, key, spec['mob'], spec.get('clip_dir', ''), unresolved,
                                                  spec.get('extra', ()), spec.get('motions'))
    for key, path in NATIVE_ZEALOT_MONSTERS.items():
        manifest['monsters'][key] = native_zealot_monster_bank(src, key, path, unresolved)
    for key, path in objects.items():
        try:
            animation_path = src.object_animation(path)
            manifest['objects'][key] = effect_bank(
                src, safe_atlas_key('obj', key), animation_path, unresolved
            )
            manifest['objects'][key]['clip'] = src.animation(animation_path)
            manifest['objects'][key]['object'] = path if path.endswith('.obj') else ''
        except KeyError as error:
            unresolved.append({'kind': 'object_animation', 'path': path, 'error': str(error)})
    for key, path in effects.items():
        try:
            manifest['effects'][key] = effect_bank(src, key, path, unresolved)
        except KeyError as error:
            unresolved.append({'kind': 'animation', 'path': path, 'error': str(error)})
    # 可破坏物打碎的粒子（.obj 的 [destroy particle] → .ptl → ANI）。
    breakable_effects, breakable_mapping = breakable_particle_animations(src)
    for key, path in breakable_effects.items():
        try:
            manifest['effects'][key] = effect_bank(src, key, path, unresolved)
        except KeyError as error:
            unresolved.append({'kind': 'particle_animation', 'path': path, 'error': str(error)})
    (ROOT / 'game_dnf/data/breakable_particles.json').write_text(json.dumps({
        'schema': 'dnf_breakable_particles/1',
        'evidence': '.obj 的 [destroy particle] → .ptl 的 [object] ANI 列表',
        'objects': breakable_mapping,
    }, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    manifest['derived_boxes'] = {
        k: value['pixel_box']
        for k, value in manifest['effects'].items()
        if 'pixel_box' in value
    }
    manifest['player_clips'] = {k: src.animation(p) for k, p in player_clips.items()}
    manifest['borrowed'] = {p: src.animation(p) for p in BORROWED}
    # ANI frame sound events: event key -> original file, from the archive's own cross-reference.
    used = [p for p in player_clips.values()] + list(objects.values()) + \
           [f'{d}/{n}.ani' for _, d, _ in MONSTERS.values() for n in MONSTER_CLIPS] + \
           ['character/swordman/animation/' + n + '.ani' for n in
            ['attack1', 'attack2', 'attack3', 'dashattack', 'jumpattack', 'upperslashafter', 'momentaryslash', 'gorecross', 'hitback']]
    events = {}
    for path in used:
        for frame, key, audio in src.lib.db.execute(
                'select frame, event_key, audio_path from sound_references where animation=? and candidates>0', (path,)):
            events.setdefault(key, set()).add(audio)
    for key, files in sorted(events.items()):
        if key not in manifest['audio']:
            copy_audio(src, sorted(files), manifest['audio'], key, unresolved)
    # 怪物分类音效：bake_dnf_monster_sounds.py 已把原版 ogg 复制到 monster_sound/，
    # 这里只登记到 audio 表（key = mon_<kind>_<event>），运行时按怪种播放。
    sounds_path = ROOT / 'game_dnf/data/monster_sounds.json'
    if sounds_path.is_file():
        for key, entry in json.loads(sounds_path.read_text(encoding='utf-8')).get('monsters', {}).items():
            for event, files in (entry.get('events') or {}).items():
                manifest['audio']['mon_%s_%s' % (key, event)] = [
                    {'file': 'res://assets_local/' + f} for f in files]
    atlas = Atlas('digits')
    for key, (start, stop) in DIGITS.items():
        for n in range(start, stop):
            image, meta = src.frame('sprite/common/etc/combo.img', n)
            image, offset = cropped(image, meta)
            atlas.add(f'{key}_{n - start}', image, offset)
    manifest['digits'] = atlas.save()
    manifest['digits']['source'] = 'sprite/common/etc/combo.img'
    # Top-of-screen monster HP bar (frames + right caps + colour lines) and MOB [face image] frames.
    atlas = Atlas('ui_monster_hp')
    for n in range(19):
        image, meta = src.frame(MONSTER_HP_IMG, n)
        atlas.add(f'f{n}', image, [meta['x'], meta['y']])
    for mob, _, _ in MONSTERS.values():
        face = src.lib.script(mob, 'mob')
        ref = next((f['values'] for f in face['fields'] if f['tag'] == '[face image]'), None)
        if ref and isinstance(ref[0], str):
            image, meta = src.frame(ref[0], int(ref[1]))
            image, offset = cropped(image, meta)
            atlas.add('face:' + mob, image, offset)
        else:
            unresolved.append({'kind': 'face_image', 'monster': mob})
    manifest['monster_hp'] = atlas.save()
    manifest['monster_hp']['source'] = MONSTER_HP_IMG
    for key, files in CUE_SOUNDS.items():
        copy_audio(src, files, manifest['audio'], key, unresolved)
    for key in SOUND_KEYS:
        copy_audio(src, sound_files(src, key), manifest['audio'], key, unresolved)
    for weapon, row in weapon_sounds(src).items():
        keys = []
        for key in row:
            if not isinstance(key, str) or not key:
                continue
            copy_audio(src, sound_files(src, key), manifest['audio'], key, unresolved)
            keys.append(key if key in manifest['audio'] else '')
        manifest['weapon_sounds'][weapon] = keys
    manifest['player_locomotion'] = build_locomotion(src, Atlas)
    manifest['sources'] = dict(sorted(src.sources.items()))
    (ACTIVE_OUT / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, separators=(',', ':')), encoding='utf-8')
    summary = {'monsters': list(manifest['monsters']), 'objects': list(manifest['objects']),
               'effects': len(manifest['effects']), 'digits': len(manifest['digits']['items']),
               'audio_keys': len(manifest['audio']), 'unresolved': len(unresolved),
               'particle_templates': len(manifest['particles'])}
    (ACTIVE_OUT / 'build_summary.json').write_text(json.dumps({**summary, 'unresolved_items': unresolved}, ensure_ascii=False, indent=1), encoding='utf-8')
    # Marks a machine that builds combat banks from the full library itself. Kept outside the
    # combat/ folder so the shared combat_runtime pack (tools/pack_dnf_flow.py) never carries it;
    # the loop launcher then keeps this local build instead of installing the shared pack.
    (output.parent / '.combat_local_build.json').write_text(json.dumps(
        {'asset_version': src.lib.asset_version, 'build_version': BUILD_VERSION}), encoding='utf-8')
    publish_tree(stage, output)
    ACTIVE_OUT = output
    return summary


def extend_native_particles(library: Path | None, output: Path = OUT) -> dict:
    """Stage the existing tree plus new banks; reject changes to existing PNGs."""
    global ACTIVE_OUT
    src = Source(library)
    previous_output = ACTIVE_OUT
    (ROOT/'temp').mkdir(parents=True,exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='dnf-particle-extend-', dir=ROOT/'temp'))
    try:
        shutil.copytree(output, stage, dirs_exist_ok=True)
        ACTIVE_OUT = stage
        manifest = json.loads((output/'manifest.json').read_text(encoding='utf8'))
        definitions, effects = native_particle_definitions(src)
        unresolved = []
        for key, path in effects.items():
            bank = effect_bank(src, key, path, unresolved)
            if key in manifest['effects'] and manifest['effects'][key] != bank:
                raise ValueError('Existing particle bank differs; create a new version: '+key)
            texture = 'fx_'+key+'.png'
            if (output/texture).exists() and (output/texture).read_bytes() != (stage/texture).read_bytes():
                raise ValueError('Existing particle texture differs: '+texture)
            manifest['effects'][key] = bank
        if unresolved:
            raise ValueError('Incomplete particle assets: '+str(unresolved))
        for path, digest in src.sources.items():
            if path in manifest['sources'] and manifest['sources'][path] != digest:
                raise ValueError('Existing source identity differs: '+path)
        manifest.setdefault('particles', {}).update(definitions)
        manifest['sources'].update(src.sources)
        (stage/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,separators=(',',':')),encoding='utf8')
        summary_path = stage/'build_summary.json'
        if summary_path.is_file():
            summary = json.loads(summary_path.read_text(encoding='utf8'))
            summary.update(effects=len(manifest['effects']),particle_templates=len(manifest['particles']))
            summary_path.write_text(json.dumps(summary,ensure_ascii=False,indent=1),encoding='utf8')
        publish_tree(stage, output)
        return {'particle_templates': len(definitions), 'animation_banks': len(effects)}
    finally:
        ACTIVE_OUT = previous_output
        src.cat.close()
        src.lib.db.close()


def extend_firewave(library: Path | None, output: Path = OUT) -> dict:
    """Add the verified ordinary firewave banks without touching existing PNGs."""
    runtime = json.loads(SKILL_RUNTIME.read_text(encoding='utf8'))
    prefix = 'passiveobject/character/swordman/'
    specs = [('objects', key, path) for key, path in runtime['assets']['objects'].items()
             if path == prefix+'firewavebigsub.obj']
    specs += [('effects', key, path) for key, path in runtime['assets']['effect_anims'].items()
              if path in [prefix+'animation/firewavebig/'+n+'.ani' for n in ('fire-back', 'blast-back')]]
    if len(specs) != 3:
        raise ValueError('Build skill runtime first; need explosion and two rear banks')
    return extend_skill_banks(library, output, specs)


def extend_ghost_field(library: Path | None, skill: str, output: Path = OUT) -> dict:
    runtime = json.loads(SKILL_RUNTIME.read_text(encoding='utf8'))
    stage = runtime['moves'][skill]['stages'][0]
    controller = stage['hits'][0]['native_controller']
    keys = [controller['ghost_fx'], *controller['appear_fx'], controller['stay_fx'], controller['disappear_fx']]
    specs = [('effects', key, runtime['assets']['effect_anims'][key]) for key in keys]
    for key in (stage['sounds'][0]['key'], controller['first_update_sound']):
        specs.append(('audio', key, GHOST_FIELD_AUDIO[key]))
    return extend_skill_banks(library, output, specs)


def extend_rasa(library: Path | None, output: Path = OUT) -> dict:
    runtime = json.loads(SKILL_RUNTIME.read_text(encoding='utf8'))
    stage = runtime['moves']['epidemicrasa']['stages'][0]
    field = stage['hits'][0]
    controller = field['native_controller']
    child = controller['child']['native_controller']
    keys = [controller['ghost_base_fx'], controller['ghost_fx'], *controller['appear_fx'],
            controller['stay_fx'], controller['disappear_fx']]
    keys += [child[name] for name in ('startup_overlay', 'stay_fx', 'stay_overlay', 'grab_fx',
                                      'grab_overlay', 'grab_stay_fx', 'grab_stay_overlay')]
    voice = stage['sounds'][0]['key']
    specs = [('effects', key, runtime['assets']['effect_anims'][key]) for key in keys]
    specs += [('objects', field['object'], field['object']), ('audio', voice, GHOST_FIELD_AUDIO[voice])]
    return extend_skill_banks(library, output, specs)


def extend_skill_banks(library: Path | None, output: Path, specs: list, *, pack_path: Path | None = None) -> dict:
    """Add explicitly bound banks while retaining every existing asset byte."""
    global ACTIVE_OUT
    src = Source(library, pack_path=pack_path)
    previous = ACTIVE_OUT
    (ROOT/'temp').mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='dnf-skill-extend-', dir=ROOT/'temp'))
    try:
        shutil.copytree(output, stage, dirs_exist_ok=True)
        ACTIVE_OUT = stage
        manifest = json.loads((output/'manifest.json').read_text(encoding='utf8'))
        additions, unresolved = [], []
        for section, key, path in specs:
            if section == 'player_clips':
                clip = src.animation(path)
                if not clip.get('frames'):
                    raise ValueError('Missing player clip: '+path)
                if key in manifest[section] and manifest[section][key] != clip:
                    raise ValueError('Existing player clip differs: '+key)
                manifest[section][key] = clip
                additions.append(path)
                continue
            if section == 'audio':
                audio = {}
                copy_audio(src, path if isinstance(path, list) else [path], audio, key, unresolved)
                if key not in audio:
                    continue
                bank = audio[key]
                for clip in bank:
                    target = stage / 'audio' / PurePosixPath(clip['source']).name
                    if sha(target.read_bytes()) != clip['sha256']:
                        raise ValueError('Audio source identity differs: '+clip['source'])
                if key in manifest[section] and manifest[section][key] != bank:
                    raise ValueError('Existing bank differs; needs a new version: '+key)
                manifest[section][key] = bank
                additions.extend(clip['file'] for clip in bank)
                continue
            if section == 'monsters':
                bank = native_zealot_monster_bank(src, key, path, unresolved)
            else:
                ani = src.object_animation(path) if section == 'objects' else path
                bank = effect_bank(src, safe_atlas_key('obj', key) if section == 'objects' else key, ani, unresolved)
                if section == 'objects':
                    bank.update(clip=src.animation(ani), object=path)
            if key in manifest[section] and manifest[section][key] != bank:
                raise ValueError('Existing bank differs; needs a new version: '+key)
            manifest[section][key] = bank
            additions.append(bank['atlas']['texture'])
        if unresolved:
            raise ValueError('Incomplete skill assets: '+str(unresolved))
        for image in output.glob('*.png'):
            if image.read_bytes() != (stage/image.name).read_bytes():
                raise ValueError('Cannot overwrite existing original image: '+image.name)
        for path, digest in src.sources.items():
            if path in manifest['sources'] and manifest['sources'][path] != digest:
                raise ValueError('Source identity differs: '+path)
        manifest['sources'].update(src.sources)
        manifest['skill_runtime_sha256'] = hashlib.sha256(SKILL_RUNTIME.read_bytes()).hexdigest()
        (stage/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,separators=(',',':')),encoding='utf8')
        summary_path = stage/'build_summary.json'
        if summary_path.is_file():
            summary = json.loads(summary_path.read_text(encoding='utf8'))
            summary.update(effects=len(manifest['effects']), objects=list(manifest['objects']),
                           audio_keys=len(manifest['audio']))
            if any(section == 'monsters' for section, _, _ in specs):
                summary['monsters'] = list(manifest['monsters'])
            summary_path.write_text(json.dumps(summary,ensure_ascii=False,indent=1),encoding='utf8')
        publish_tree(stage, output)
        return {'banks': additions}
    finally:
        ACTIVE_OUT = previous
        src.cat.close(); src.lib.db.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--library', type=Path)
    parser.add_argument('--refresh-ani-metadata', action='store_true',
                        help='Update pinned ANI globals in existing manifest without rebuilding images')
    parser.add_argument('--extend-native-particles', action='store_true',
                        help='Add native particle banks atomically, preserving every existing asset')
    parser.add_argument('--extend-firewave', action='store_true',
                        help='Add ordinary firewave explosion/rear banks, preserving existing assets')
    parser.add_argument('--extend-wave-sounds', action='store_true',
                        help='Add original wave cast sounds, preserving existing assets')
    parser.add_argument('--extend-khazan', action='store_true',
                        help='Add the Khazan ghost and area banks, preserving existing assets')
    parser.add_argument('--extend-bremen', action='store_true',
                        help='Add the Bremen ghost and area banks, preserving existing assets')
    parser.add_argument('--extend-saya', action='store_true',
                        help='Add the Saya ghost and area banks, preserving existing assets')
    parser.add_argument('--extend-rasa', action='store_true',
                        help='Add the original Rasa creator, child animations and cast voice')
    parser.add_argument('--extend-cannon', action='store_true',
                        help='Add original cannonball art and source firing/hit sounds')
    parser.add_argument('--extend-ghost-cast-clips', action='store_true',
                        help='Add original ghost cast clip metadata to the existing player atlases')
    parser.add_argument('--extend-pope-thunderbolt', action='store_true',
                        help='Add the Pope contact attack object without changing existing banks')
    parser.add_argument('--extend-raxy-starfish', action='store_true',
                        help='Add the original Raxy and StarFish banks and state sounds')
    parser.add_argument('--output', type=Path, help='Existing asset tree for --extend-raxy-starfish')
    parser.add_argument('--pack', type=Path, help='Compiled source pack for --extend-raxy-starfish')
    args = parser.parse_args()
    if (args.output or args.pack) and not args.extend_raxy_starfish:
        parser.error('--output and --pack require --extend-raxy-starfish')
    if args.extend_raxy_starfish:
        specs = [('monsters', key, path) for key, path in NATIVE_ZEALOT_MONSTERS.items()]
        specs.extend(('audio', key, paths) for key, paths in ZEALOT_SOUNDS.items())
        print(json.dumps(extend_skill_banks(args.library, args.output or OUT, specs, pack_path=args.pack)))
        return 0
    if args.extend_pope_thunderbolt:
        specs = [('objects', 'native_pope_thunderbolt', OBJECTS['native_pope_thunderbolt'])]
        print(json.dumps(extend_skill_banks(args.library, OUT, specs)))
        return 0
    if args.extend_cannon:
        specs = [('objects', 'native_cannonball', OBJECTS['native_cannonball'])]
        specs.extend(('audio', key, CUE_SOUNDS[key]) for key in ('DRGCANNON_SHOOT', 'R_BOMB_HIT'))
        print(json.dumps(extend_skill_banks(args.library, OUT, specs)))
        return 0
    if args.extend_rasa:
        print(json.dumps(extend_rasa(args.library)))
        return 0
    if args.extend_ghost_cast_clips:
        motions = json.loads(SKILL_RUNTIME.read_text(encoding='utf8'))['assets']['player_anims']
        specs = [('player_clips', key, motions[key]) for key in ('throw1', 'throw2')]
        print(json.dumps(extend_skill_banks(args.library, OUT, specs)))
        return 0
    if args.extend_khazan or args.extend_bremen or args.extend_saya:
        skill = 'saya' if args.extend_saya else 'bremen' if args.extend_bremen else 'khazan'
        print(json.dumps(extend_ghost_field(args.library, skill)))
        return 0
    if args.extend_firewave:
        print(json.dumps(extend_firewave(args.library)))
        return 0
    if args.extend_wave_sounds:
        specs = [('audio', key, path) for key, path in WAVE_CAST_AUDIO.items()]
        print(json.dumps(extend_skill_banks(args.library, OUT, specs)))
        return 0
    if args.extend_native_particles:
        print(json.dumps(extend_native_particles(args.library)))
        return 0
    if args.refresh_ani_metadata:
        path = OUT / 'manifest.json'
        source = Source(args.library)
        try:
            manifest = refresh_animation_metadata(source, json.loads(path.read_text(encoding='utf8')))
            body = json.dumps(manifest, ensure_ascii=False, separators=(',', ':'))
            temporary = path.with_suffix('.json.tmp')
            temporary.write_text(body, encoding='utf8')
            os.replace(temporary, path)
            print(json.dumps({'updated_banks': sum(len(manifest.get(k, {})) for k in ('objects', 'effects'))}))
        finally:
            source.cat.close()
            source.lib.db.close()
        return 0
    print(json.dumps(build(args.library), ensure_ascii=True))
    return 0


if __name__ == '__main__':
    sys.exit(main())
