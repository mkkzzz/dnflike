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
from dnf_pvf import first_values, open_library, resolve
from dnf_locomotion import build as build_locomotion
from build_dnf_particles import parse as parse_particle
from build_dnf_skill_runtime import OUTRAGE_PARTICLES, WEAPON_COMBO_LIGHT_DEPTHS
from compile_dnf_content import (NATIVE_JAR_GAS_SHA, NATIVE_JAR_TRAP_OBJECTS, NATIVE_JAR_TRAP_SHA, NATIVE_JAR_TRAP_WARNING,
                                 NATIVE_OUTERWALL_BANKS, NATIVE_OUTERWALL_BREAKABLES,
                                 NATIVE_POISON_PARTICLE, NATIVE_POISON_VISUAL_SHA,
                                 NATIVE_SPIRIT_CAST_LAYERS, NATIVE_SPIRIT_LIGHT_ATTACK2,
                                 NATIVE_SPIRIT_PROXY, NATIVE_SPIRIT_PROXY_SHA,
                                 NATIVE_ZEALOT_MONSTERS, OUTERWALL_BREAKABLE_ROOT)

OUT = ROOT / 'game_dnf/assets_local/combat'
ACTIVE_OUT = OUT
SCHEMA = 'dnf_combat_assets/1'
BUILD_VERSION = 7
SKILL_RUNTIME = ROOT / 'game_dnf/data/skill_runtime.json'
NATIVE_PARTICLES = [
    'passiveobject/character/swordman/particle/'+stem+'.ptl'
    for stem in ('icewaveparticlesmoke', 'icewaveparticle', 'icewaveparticlestar', 'illusionslash')
]
OUTRAGE_PARTICLE_SOURCES = {
    OUTRAGE_PARTICLES['stone']: {
        OUTRAGE_PARTICLES['stone']: '917e7ec061ee2a42b90fdf938c5f71823612bfcce306d52d79d8f4b147bf44b3',
        **{f'character/swordman/effect/animation/outragebreak/particle/outragebreak_stone_part_{index}.ani': digest
           for index, digest in enumerate((
               '66e16f3b56f6b46a21f46b004af55f17862f0392b24b9a830182808251c51058',
               '8db95ac72405833b2af710f2d2507ef9d7f28dfd0d8cc6e72350ade6f22fa462',
               '21590ecdbdbbd9f8015f5a6e12634b68ed4d9be262cd566e66fc1a714a403d82',
               'a8be9edb399e99dea71174f9e3275d8fc2791715bfdd5b2af40d040239b69094',
           ), 1)},
    },
    OUTRAGE_PARTICLES['light']: {
        OUTRAGE_PARTICLES['light']: 'dcbadf6472fd660aafc5bce25cc878448f4ee717954364b6e1208cbeaef0ca79',
        'passiveobject/character/swordman/animation/outragebreak/particle/outragebreak_light_part_1.ani':
            'c6b749ecafd6c02e13b13ff7e0fcd14b34f90c761289bdcc8c2241dabf4a56c9',
        'passiveobject/character/swordman/animation/outragebreak/particle/outragebreak_light_part_2.ani':
            '1e579bb8b0eb7c5530bad75c52351ad1e7bef5850a0e81f5b46ea35e16a17fcc',
    },
    OUTRAGE_PARTICLES['drops']: {
        OUTRAGE_PARTICLES['drops']: '5f5c75338a5d066e277c213f7d3720ead083056a9d4a026b160775a12c6e69a6',
        'passiveobject/character/swordman/animation/outragebreak/particle/outragebreak_drops_1.ani':
            '85e7c406d64363338bcafacca66b0ac60a99179bc8248c2b53e6264008befe36',
        'passiveobject/character/swordman/animation/outragebreak/particle/outragebreak_drops_2.ani':
            '482fd68f3c68ee7047feec81345ccdb20abe25c4aaffa8d3223ff02a0a2cfdeb',
    },
}
ARMOR_DAMAGE_PARTICLE = 'common/commoneffect/particle/superarmor_damage_particle.ptl'
ARMOR_DAMAGE_SOURCES = {
    ARMOR_DAMAGE_PARTICLE: 'e33073aedab87783f38e3551f08a22a218be1efbcc82f1b8c849e260ce0aa309',
    'common/commoneffect/animation/superarmor_damage_particle01.ani': '814274ae6431e83ef19e2f4bc5ace7949406d97a7792af0ad3ae38f36dbf6268',
    'common/commoneffect/animation/superarmor_damage_particle02.ani': '6b8add08c180862e3c7de28a7e6eb6477547808dfcafce1b83e646a495fdb122',
    'common/commoneffect/animation/superarmor_damage_particle03.ani': 'bf47d08c2b70aa2f1c001cfb114e3a9bdf6f9f5b0a921f89c941311fbf12aa30',
}
PATTACK_PARTICLE = 'common/commoneffect/particle/status_effect/pattack.ptl'
PATTACK_SOURCES = {
    PATTACK_PARTICLE: 'dd92ee249cb7b856b1cdbcf411485aa7ab51d643f46b1fa5e26ff1731817f9d7',
    'common/commoneffect/animation/status_effect/pattack.ani': '6e4247ee0318a29636209d00953962babef8ddd6e32384b5f695d77ee38eac0b',
}


def swordman_half_height(src) -> int:
    chr_path = 'character/swordman/swordman.chr'
    fields = src.lib.script(chr_path)['fields']
    src.sources[chr_path] = src.lib.raw(chr_path)[1]
    fixed_height = first_values(fields, '[fixed height]')
    if fixed_height and fixed_height[0] != -1:
        return int(fixed_height[0] / 2)
    # 829F3A uses getStayAni frame 0. 1086316 uses the raw IMG offset,
    # before atlas cropping. The current base actor uses skin index zero.
    stay = resolve(chr_path, first_values(fields, '[waiting motion]')[0])
    frame = src.animation(stay)['frames'][0]
    skin = frame['img'] % 0
    _, metadata = src.frame(skin, frame['img_frame'])
    return int(-(frame['pos'][1] + metadata['y']) / 2)


def monster_number_height(src, mob: str) -> int | None:
    """829EF8..829F6B measures the first source waiting frame, before IMG cropping."""
    decoded = src.pack_records.get(mob, {}).get('decoded', {})
    if not decoded:
        return None
    actions = decoded.get('waiting_actions') or []
    if actions:
        act = src.pack_records.get(actions[0], {}).get('decoded', {})
        waiting = [act['base_ani']] if act.get('base_ani') else []
    else:
        waiting = decoded.get('waiting_motion') or []
    if not waiting:
        return None
    try:
        frame = src.animation(waiting[0])['frames'][0]
        _, meta = src.frame(frame['img'], frame['img_frame'])
    except (KeyError, IndexError, TypeError):
        return None
    return -(frame['pos'][1] + meta['y'])


def native_particle_definitions(src, extra_pins=None):
    """Small runtime subset, decoded from the source; retain duplicate choices."""
    particles, effects = {}, {}
    pinned = {}
    for obj_name, ani_name, ptl_name, obj_sha, ani_sha, ptl_sha in NATIVE_OUTERWALL_BREAKABLES.values():
        obj_path = OUTERWALL_BREAKABLE_ROOT + obj_name + '.obj'
        motion = OUTERWALL_BREAKABLE_ROOT + 'animation/' + ani_name + '.ani'
        path = OUTERWALL_BREAKABLE_ROOT + 'particle/' + ptl_name + '.ptl'
        binding = src.pack_records.get(obj_path, {}).get('native_breakable', {})
        hashes = binding.get('source_hashes', {})
        if binding.get('destroy_particle') != path or binding.get('motion_ani') != motion or hashes.get(path) != ptl_sha:
            raise ValueError('Compile the pinned native breakable before baking: ' + obj_path)
        for source, digest in ((obj_path, obj_sha), (motion, ani_sha)):
            raw = src.lib.raw(source)
            if not raw or raw[1] != digest or hashes.get(source) != digest:
                raise ValueError('Native breakable source differs from compiled pack: ' + source)
            src.sources[source] = digest
        pinned[path] = hashes
    pinned.update(extra_pins or {})
    pinned.update(OUTRAGE_PARTICLE_SOURCES)
    pinned[ARMOR_DAMAGE_PARTICLE] = ARMOR_DAMAGE_SOURCES
    pinned[PATTACK_PARTICLE] = PATTACK_SOURCES
    for path in [*NATIVE_PARTICLES, *pinned]:
        doc = src.lib.script(path)
        if not doc:
            raise ValueError('Missing original particle: '+path)
        entry = parse_particle(path, doc)
        if not entry or entry['unsupported'] or entry['diagnostics']:
            raise ValueError('Unresolved native particle: '+path)
        if path in pinned and (entry['sha256'] != pinned[path][path] or any(
                not (raw := src.lib.raw(animation)) or raw[1] != pinned[path].get(animation)
                for animation in entry['animations'])):
            raise ValueError('Native particle source differs from compiled pack: '+path)
        particles[path] = {'sha256': entry['sha256'], 'decoded': entry['decoded']}
        src.sources[path] = entry['sha256']
        for animation in entry['animations']:
            effects['native_'+PurePosixPath(animation).stem] = animation
    half_height = swordman_half_height(src)
    particles[ARMOR_DAMAGE_PARTICLE]['z_offset'] = half_height
    particles[PATTACK_PARTICLE]['z_offset'] = half_height
    return particles, effects


def native_status_visuals(src):
    poison = src.pack_records.get(NATIVE_POISON_PARTICLE, {}).get('native_status_visual', {})
    if (poison.get('particle') != NATIVE_POISON_PARTICLE
            or poison.get('source', {}).get('source_hashes') != NATIVE_POISON_VISUAL_SHA):
        raise ValueError('Compile the original poison status visual before baking')
    return {'overdrive': {'particle': PATTACK_PARTICLE},
            'poison': dict(poison, apply_sound='CONDITION_POSION', loop_sound='G_POISON_LOOP',
                           loop_items=[
                               {'sound': 'CONDITION_POSION_DROP', 'start_delay_ms': 0, 'loop_delay_ms': 3000},
                               {'sound': 'CONDITION_POISON_POP', 'start_delay_ms': 0, 'loop_delay_ms': 1000},
                           ])}


OUTERWALL_TRAP_SOUNDS = {
    'FIRE_EXPLOSION_CREATE': ('sounds/effect/magic/fire_explosion.ogg',
                              'b36e216267d64695ddc0256e953a52c1b469c4ce7109612872b79bb163e6613b'),
    'CLOUD_KILL_LOOP': ('sounds/effect/magic/cloudkill.ogg',
                        '3db734272e26a4b368a030e3bd3377da0d8e8502763ef3ed8991238c75a8cebf'),
    'CONDITION_POSION': ('sounds/effect/c_poison.ogg',
                         '28d7278038a35b4176deac86c513e5f8e41494fd2d9855008f7a943a46b0183d'),
    'CONDITION_POSION_DROP': ('sounds/effect/c_poison_drop.ogg',
                              '48a1f75121003eadfa32ebf700283efdaaf6a6835c09721a4c431fd860b4ecf5'),
    'CONDITION_POISON_POP': ('sounds/effect/c_poison_pop.ogg',
                             '710c1b559ef16e3939d09869f4f6e2b3bd9cdcfae0b984be3b65e39cd68e46c7'),
    'TINGKERBELL_FLOAT_LOOP': ('sounds/effect/tingk_float.ogg',
                              'e2b4d6721e73baf137ab930a43eb94d3216225d2b494c100d472512b602be23f'),
    'TINGKERBELL_ALL_ABSORB': ('sounds/effect/tingk_aab.ogg',
                               'ec83d74dde031fade3e99682977bbbdc96e56e9b6d11a00730d8da8828b38593'),
    'TINGKERBELL_HP_ABSORB': ('sounds/effect/tingk_hab.ogg',
                              '5f9e6b0ca0f3bcb5285f77986aaaf5a9153cd5c6062a086d166395fe6ba81b6c'),
}


def native_jar_trap_assets(src):
    effects, pinned, objects, hashes = {}, {}, {}, {}

    def bank_for(path):
        key = 'native_jar_' + PurePosixPath(path).stem
        effects[key] = path
        return key

    warning = src.pack_records.get(NATIVE_JAR_TRAP_WARNING, {}).get('native_trap_warning')
    if not warning:
        raise ValueError('Compile the original jar trap warning before baking')
    hashes[warning['rate_source']] = warning['rate_sha256']
    hashes[NATIVE_JAR_TRAP_WARNING] = src.pack_records[NATIVE_JAR_TRAP_WARNING]['source']['sha256']
    warning = dict(warning, ani=NATIVE_JAR_TRAP_WARNING, bank=bank_for(NATIVE_JAR_TRAP_WARNING))
    for path, (source_ids, kind) in NATIVE_JAR_TRAP_OBJECTS.items():
        spec = src.pack_records.get(path, {}).get('native_trap', {})
        if spec.get('source_ids') != list(source_ids) or spec.get('kind') != kind:
            raise ValueError('Compile the original jar trap object before baking: ' + path)
        hashes.update(spec['source_hashes'])
        for particle in spec['particles']:
            pinned[particle] = spec['source_hashes']
        row = {key: spec[key] for key in ('kind', 'motion_ani', 'attack', 'attack_window_ms',
                                         'floating_height', 'particles', 'spawn_sound', 'hit_sound',
                                         'consume_sound')}
        row['source_path'] = path
        row['motion_bank'] = bank_for(spec['motion_ani']) if spec['extra_animations'] else ''
        row['attack_timeline'] = src.pack_records[spec['motion_ani']]['decoded']['timeline']
        if kind == 'poison':
            row['poison'] = spec['poison']
        row['extras'] = [bank_for(animation) for animation in spec['extra_animations']]
        row['destroy'] = [bank_for(animation) for animation in spec['destroy_animations']]
        for source_id in source_ids:
            objects[str(source_id)] = row
    if hashes != NATIVE_JAR_TRAP_SHA | NATIVE_JAR_GAS_SHA:
        raise ValueError('Compiled jar trap dependencies do not match the pinned original set')
    for path, digest in hashes.items():
        raw = src.lib.raw(path)
        if not raw or raw[1] != digest:
            raise ValueError('Original jar trap asset differs: ' + path)
    src.sources.update(hashes)
    return {'warning': warning, 'objects': objects}, effects, pinned


def copy_native_jar_trap_audio(src, audio, unresolved):
    for key, (path, digest) in OUTERWALL_TRAP_SOUNDS.items():
        found = src.audio(path)
        if not found or found[1] != digest or sha(found[0].read_bytes()) != digest:
            raise ValueError('Original jar trap audio differs: ' + path)
        clips = {}
        copy_audio(src, [path], clips, key, unresolved)
        if (key in audio and audio[key] != clips[key]
                or sha((ACTIVE_OUT/'audio'/PurePosixPath(path).name).read_bytes()) != digest):
            raise ValueError('Existing jar trap audio differs: ' + key)
        audio.update(clips)


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
# These ETC ANI slots use the same body IMG as the basic motions. Cast and
# firing overlays remain separate source dependencies, with their own timing.
OUTERWALL_BODY_ETC_SLOTS = {
    'native_bossfather': (2,), 'native_bosspope': (2, 7), 'native_catapult': (),
    'native_lightspirit': (0, 1, 2),
}
HARDATTACK_WAVE_ROOT = 'passiveobject/character/swordman/animation/hardattackcharge/'
HARDATTACK_WAVE_VARIANTS = ('khazan', 'saya', 'bremen')
HARDATTACK_WAVE_FRONTS = {f'hardattack_wave_{kind}_up': HARDATTACK_WAVE_ROOT + kind + '-up.ani'
                          for kind in HARDATTACK_WAVE_VARIANTS}
HARDATTACK_WAVE_REARS = {f'hardattack_wave_{kind}_down': HARDATTACK_WAVE_ROOT + kind + '-down.ani'
                         for kind in HARDATTACK_WAVE_VARIANTS}
OBJECTS = {
    **HARDATTACK_WAVE_FRONTS,
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
    'hardattackchargeafter': 'character/swordman/animation/hardattackchargeafter.ani',
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
    'hardattack_charge1': 'character/swordman/effect/animation/hardattackoncharge1.ani',
    'hardattack_charge2': 'character/swordman/effect/animation/hardattackoncharge2.ani',
    'hardattack_full1': 'character/swordman/effect/animation/hardattackfullcharge1.ani',
    'hardattack_full2': 'character/swordman/effect/animation/hardattackfullcharge2.ani',
    'hardattack_dash_dust': 'character/swordman/effect/animation/hardattackchargeafterdust.ani',
    'hardattack_dash_down': 'character/swordman/effect/animation/wave-down.ani',
    'hardattack_dash_up': 'character/swordman/effect/animation/wave-up.ani',
    **HARDATTACK_WAVE_REARS,
    'native_sleep': 'common/activestatus/animation/sleep.ani',
    'moonlight1': 'character/swordman/effect/animation/moonlightslash1.ani',
    'moonlight2': 'character/swordman/effect/animation/moonlightslash2.ani',
    'charge_dash': 'character/swordman/effect/animation/chargecrash/dash.ani',
    'charge_dash_dust': 'character/swordman/effect/animation/chargecrash/dustdash.ani',
    'charge_upper': 'character/swordman/effect/animation/chargecrash/up-slash.ani',
    'charge_crash_wave': 'passiveobject/character/swordman/animation/chargecrash/damage-front.ani',
    'upper1': 'character/swordman/effect/animation/upperslash1.ani',
    'upper2': 'character/swordman/effect/animation/upperslash2.ani',
    'upper_short_followup': 'character/swordman/effect/animation/shortswordmastery/shortweaponupperslashafter.ani',
    'upper_armor_light': 'common/commoneffect/animation/superarmordamage.ani',
    'guard_spark': 'character/swordman/effect/animation/guard/spark.ani',
    'guard_dust': 'character/swordman/effect/animation/guard/dust.ani',
    'triple1': 'character/swordman/effect/animation/tripleslash/slash1.ani',
    'triple2': 'character/swordman/effect/animation/tripleslash/slash2.ani',
    'triple3': 'character/swordman/effect/animation/tripleslash/slash3.ani',
    'triple4': 'character/swordman/effect/animation/tripleslash/slash4.ani',
    'triple5': 'character/swordman/effect/animation/tripleslash/slash5.ani',
    'triple_move1': 'character/swordman/effect/animation/tripleslash/move1.ani',
    'triple_move2': 'character/swordman/effect/animation/tripleslash/move2.ani',
    'gore_slash1': 'character/swordman/effect/animation/gorecross/slash1.ani',
    'gore_slash2': 'character/swordman/effect/animation/gorecross/slash2.ani',
    'gore_cross_add': 'passiveobject/character/swordman/animation/gorecross2.ani',
    'frenzy_cast': 'character/swordman/effect/animation/frenzy/cast.ani',
    'frenzy_blast': 'character/swordman/effect/animation/frenzy/blast.ani',
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
                 'SLESSSWDA': 'SLESSSWD', 'STICK_HIT': 'STICKA_HIT'}
# State 24 entry keys at 0xCC8C2F, 0xCC901A, and 0xCC8EE4, resolved by original audio.xml.
WAVE_CAST_AUDIO = {
    'HADOUKEN': 'sounds/char/swordman/effect/hadouken.ogg',
    'SM_ICEWAVE': 'sounds/char/swordman/sm_icewave.ogg',
    'SM_FIREWAVE': 'sounds/char/swordman/sm_firewave.ogg',
}
# CD7594 and CD75B5 resolve the cast keys through audio.xml; 9C587C and 9C575B
# resolve the recovery orb keys. FLENSE_CHARGE has no entry in the supplied table.
FRENZY_AUDIO = {
    'SM_FLENSE': 'sounds/char/swordman/sm_flense.ogg',
    'FLENSE_GET': 'sounds/char/swordman/effect/flense_get.ogg',
    'FLENSE_SUCK': 'sounds/char/swordman/effect/flense_suck.ogg',
    'FLENSE_FLASH': 'sounds/char/swordman/effect/flense_flash.ogg',
}
BLOODBLAST_AUDIO = {
    'SM_BLOOD_CAST': 'sounds/char/swordman/sm_blood.ogg',
    'FIRE_PILLAR_UP': 'sounds/effect/magic/fire_pillar.ogg',
    'FIRE_PILLAR_HIT': 'sounds/effect/magic/fire_pillarhit.ogg',
}
THIRST_AUDIO = {
    'SM_SACRIFICE_CAST': 'sounds/char/swordman/sm_sacri.ogg',
    'SACRI': 'sounds/char/swordman/effect/sacri.ogg',
    'SACRI_LOOP': 'sounds/char/swordman/effect/sacri_loop.ogg',
}
GRAB_BLAST_AUDIO = {
    'BLOODR_GET': 'sounds/char/swordman/effect/bloodr_get.ogg',
    'BLOOD_SUCK': 'sounds/effect/blood_suck.ogg',
    'BLOODR_FIRE': 'sounds/char/swordman/effect/bloodr_fire.ogg',
}
BLOODY_RAVE_AUDIO = {
    'SM_BLOOD_RAVE_STORM': 'sounds/char/swordman/sm_blood_rave_storm.ogg',
    'BLOODYR_BLACKHOLE_LOOP': 'sounds/char/swordman/effect/bloodyr_blackhole.ogg',
    'DRAWING_SWORD': 'sounds/char/swordman/effect/drawing_sword.ogg',
    'SM_BLOOD_RAVE_ATK': 'sounds/char/swordman/sm_blood_rave_atk.ogg',
}
BLOODY_RAVE_CONTACT_AUDIO = {
    'MINERALSWDC_HIT_01': 'sounds/char/swordman/weapon/minswdc_hit.ogg',
}
DRAW_AUDIO = {
    'SM_BAL_READY': 'sounds/char/swordman/sm_bal1.ogg',
    'SM_BAL_SHOT': 'sounds/char/swordman/sm_bal2.ogg',
    'SWD_BAL_END': 'sounds/char/swordman/weapon/swd_bal_03.ogg',
}
FRENZY_RECOVERY_EFFECTS = {
    'frenzy_create_ball': 'character/swordman/effect/animation/frenzy/createball.ani',
    'frenzy_ball': 'character/swordman/effect/animation/frenzy/ball.ani',
    'frenzy_ball_layer': 'character/swordman/effect/animation/frenzy/balllayer.ani',
}
FRENZY_SWING_EFFECTS = {
    f'frenzy_sword{stage}_{layer}': f'character/swordman/effect/animation/frenzy/sword{stage}-{layer}.ani'
    for stage in range(1, 5) for layer in (1, 3, 4 if stage <= 2 else 2)
}
EFFECTS.update(FRENZY_SWING_EFFECTS)
EFFECTS.update(FRENZY_RECOVERY_EFFECTS)

# State 17 installs these two common animations and plays MOON_CURTAIN_LIGHT.
SELF_BUFF_EFFECTS = {
    'self_buff_start': 'common/commoneffect/animation/selfbuff_start.ani',
    'self_buff_loop': 'common/commoneffect/animation/selfbuff_loop.ani',
}
OVERDRIVE_AUDIO = {
    'MOON_CURTAIN_LIGHT': 'sounds/effect/magic/mcurtain_light.ogg',
    'SM_OVERDRIVE': 'sounds/char/swordman/sm_overdrive.ogg',
    'BUFF_OVERDRIVE': 'sounds/effect/magic/buff_odrive.ogg',
}
EFFECTS.update(SELF_BUFF_EFFECTS)

WEAPON_COMBO_FINISH_EFFECTS = {
    'weapon_combo_short_finish': 'character/swordman/effect/animation/weaponcombo/short.ani',
    'weapon_combo_blade_finish': 'character/swordman/effect/animation/weaponcombo/blade.ani',
    'weapon_combo_blunt_finish': 'character/swordman/effect/animation/weaponcombo/blunt.ani',
    'weapon_combo_heavy_finish': 'character/swordman/effect/animation/weaponcombo/heavy.ani',
    'weapon_combo_light_finish': 'character/swordman/effect/animation/weaponcombo/light.ani',
    **{f'weapon_combo_light_{phase}_{layer}':
       f'character/swordman/effect/animation/weaponcombo/light{phase}-{layer}.ani'
       for phase, depths in enumerate(WEAPON_COMBO_LIGHT_DEPTHS, 1)
       for layer in range(1, len(depths) + 1)},
}
WEAPON_COMBO_MASTERY_EFFECTS = {
    f'weapon_combo_short_mastery{i}':
    f'character/swordman/effect/animation/shortswordmastery/shortweaponcombo{i}.ani'
    for i in range(1, 4)
}
WEAPON_COMBO_MASTERY_EFFECTS['weapon_combo_heavy_charge'] = (
    'character/swordman/effect/animation/shortswordmastery/heavyweaponcombochargedodge.ani')
EFFECTS.update(WEAPON_COMBO_FINISH_EFFECTS | WEAPON_COMBO_MASTERY_EFFECTS)

# State 30 entry at CD152F and CD1578, resolved by original audio.xml.
UPPER_FOLLOWUP_AUDIO = {
    'UPPER_SLASH_02': 'sounds/char/swordman/effect/upper_slash_02.ogg',
    'SM_UPPERSLASH_ADD': 'sounds/char/swordman/sm_upperslash_add.ogg',
}

# Preserve audio.xml spelling: Khazan's caster key is KAZHAN and the object key is KAJAN.
GHOST_FIELD_AUDIO = {
    'SM_GHOST_KAZHAN': 'sounds/char/swordman/sm_kghost.ogg',
    'GHOST_KAJAN': 'sounds/effect/magic/ghost_kajan.ogg',
    'SM_GHOST_BREMEN': 'sounds/char/swordman/sm_bghost.ogg',
    'GHOST_BREMEN': 'sounds/effect/magic/ghost_bremen.ogg',
    'SM_GHOST_SAYA': 'sounds/char/swordman/sm_sghost.ogg',
    'GHOST_SAYA': 'sounds/effect/magic/ghost_saya.ogg',
    'P_SAYA_ICE': 'sounds/char/swordman/effect/p_saya_ice.ogg',
    'P_SAYA_ICE_HIT': 'sounds/char/swordman/effect/p_saya_ice_hit.ogg',
    'SM_RASA': 'sounds/char/swordman/sm_rasa.ogg',
}

ZEALOT_SOUNDS = {
    'HOLD': ['sounds/effect/hold_01.ogg'],
    'KNIFE_STICK': ['sounds/effect/knife_stick.ogg'],
    'ZGM_SPRING': ['sounds/mon/act3/zgm_spring.ogg'],
    'ZGM_ATK': ['sounds/mon/act3/zgm_atk.ogg'],
    'ZGM_ATTACH': ['sounds/mon/act3/zgm_attach.ogg'],
}
# Father and Pope ATK [hit wav], resolved by the original audio.xml.
NATIVE_SPIRIT_SOUNDS = {
    'R_CLAWC_HIT': {
        'sounds/char/fighter/weapon/clawc_hit_01.ogg': '365b55acacdfde3201b783151cd8d6d27fe02ba3301e8c68ca2e328e41988038',
        'sounds/char/fighter/weapon/clawc_hit_02.ogg': '2d31ac7e9a65c57a36e3d2e88ae9fd785765985eb5204642b2ad21078a35ca87',
    },
    'FG_HIT_01': {
        'sounds/char/priest/effect/fg_hit_01.ogg': '14ea2a60918006401bffa6bcd619bc9e73169b64d206f9cb4a0f5594baedbe0b',
    },
    'BELIEVER_PRAY': {
        'sounds/mon/act3/believer_pray_01.ogg': 'd93a997920f77dd9a839ac69a4ba1950e79686db03050d88eac8e5429d8a1d2e',
        'sounds/mon/act3/believer_pray_02.ogg': 'a3011fea27748e1e34e11fb6522cf5316ec1fe4cc414f23926e7037eab602f9f',
    },
}
OUTERWALL_SOUNDS = {'SPEAR_HIT': ['sounds/effect/spear_hit.ogg'],
                   **{key: list(paths) for key, paths in NATIVE_SPIRIT_SOUNDS.items()}}
# Breakable OBJ string slot 4, resolved by the original audio.xml.
OUTERWALL_BREAKABLE_SOUNDS = {'WOOD_HIT': ['sounds/effect/wood_hit.ogg']}
GUARD_AUDIO = {
    'SWD_GUARD': 'sounds/char/swordman/weapon/swd_eff_05.ogg',
    'SWD_GUARDED': 'sounds/char/swordman/weapon/swd_eff_01.ogg',
    'SWD_GUARD_END': 'sounds/char/swordman/weapon/swd_eff_06.ogg',
    'SM_GUARD': 'sounds/char/swordman/sm_guard.ogg',
}
TRIPLE_SWING = 'R_TSLASH'
TRIPLE_SWING_FILES = [f'sounds/char/swordman/effect/tslash_{index:02}.ogg' for index in (1, 2, 3)]
HARDATTACK_VOICE = 'R_SM_GUE'
HARDATTACK_VOICE_FILES = [f'sounds/char/swordman/sm_gue_{index:02}.ogg' for index in (1, 2)]
HARDATTACK_CHARGE_AUDIO = {
    'SM_GUE_CHARGE': 'sounds/char/swordman/sm_gue_charge.ogg',
    'GHOSTSLASH_CHARGE_END': 'sounds/effect/gslash_charged.ogg',
    'GHOSTSLASH_CRY': 'sounds/effect/ghostslashcry.ogg',
}
# Original audio.xml RANDOM groups, in the same order as their source items.
HARDATTACK_WAVE_AUDIO = {f'GHOST_DRIVE_{kind.upper()}': f'sounds/char/swordman/effect/ghost_drive_{kind}.ogg'
                         for kind in (*HARDATTACK_WAVE_VARIANTS, 'hit')}
RAPID_SLASH_DUST = 'character/swordman/effect/animation/rapidmoveslash/dust.ani'
EFFECTS['rapid_move_slash_dust'] = RAPID_SLASH_DUST
RAPID_SLASH_AUDIO = {
    'SM_MENGRYONG_START': 'sounds/char/swordman/sm_mengryong_start.ogg',
    'SM_MENGRYONG_FIN': 'sounds/char/swordman/sm_mengryong_fin.ogg',
    'R_SM_MENGRYONG': [f'sounds/char/swordman/sm_mengryong_{index:02}.ogg' for index in (1, 2, 3)],
    'MENGRYOUNG_ATK': 'sounds/char/swordman/effect/mengryong_atk.ogg',
    'JAKYEOL_HIT': 'sounds/char/swordman/effect/jakyeol_hit.ogg',
}
SOURCE_AUDIO_WEIGHTS = {TRIPLE_SWING: (34, 33, 33), HARDATTACK_VOICE: (50, 50), 'R_SM_MENGRYONG': (34, 33, 33)}
ILLUSION_SLASH_AUDIO = {
    'SM_HOANYOUNG_START': 'sounds/char/swordman/sm_hoanyoung_start.ogg',
    'SM_HOANYOUNG_FIN': 'sounds/char/swordman/sm_hoanyoung_fin.ogg',
    'HOANYOUNG_HIT': 'sounds/char/swordman/effect/hoanyoung_hit.ogg',
}
ILLUSION_SLASH_REPEAT_VOICES = [f'sounds/char/swordman/sm_hoanyoung_{index:02}.ogg' for index in range(1, 5)]
ILLUSION_WAVE_LAYERS = {
    f'illusion_wave_bottom{index}': f'passiveobject/character/swordman/animation/illusionslashwavebottom{index}.ani'
    for index in (1, 2)
}
ILLUSION_WAVE_LAYERS['illusion_wave_hit'] = 'passiveobject/character/swordman/animation/illusionslashwavehit.ani'
EFFECTS.update(ILLUSION_WAVE_LAYERS)
SOURCE_AUDIO_WEIGHTS['R_SM_HOANYOUNG'] = (25, 25, 25, 25)
OUTRAGE_AUDIO = {key: [f'sounds/char/swordman/effect/{key.lower()}.ogg']
                 for key in ('OUTRAGE_READY', 'OUTRAGE_SWING', 'CCRASH_CRASH', 'OUTRAGE_CRASH')}
OUTRAGE_AUDIO['FLAMES_HIT'] = ['sounds/char/wizard/effect/fs_hit.ogg']
CUE_SOUNDS = {
    **OUTRAGE_AUDIO,
    **{key: [path] for key, path in ILLUSION_SLASH_AUDIO.items()},
    'R_SM_HOANYOUNG': ILLUSION_SLASH_REPEAT_VOICES,
    **{key: paths if isinstance(paths, list) else [paths] for key, paths in RAPID_SLASH_AUDIO.items()},
    'SM_CHARGE_CRASH': ['sounds/char/swordman/sm_chargecrash.ogg'],
    'CCRASH_MOVING': ['sounds/char/swordman/effect/ccrash_moving.ogg'],
    'SM_CHARGE_CRASH_UP': ['sounds/char/swordman/sm_chargecrash_up.ogg'],
    'SM_CHARGE_CRASH_DOWN': ['sounds/char/swordman/sm_chargecrash_down.ogg'],
    'CCRASH_GET': ['sounds/char/swordman/effect/ccrash_get.ogg'],
    'JAKYEOL_SWING': ['sounds/char/swordman/effect/jakyeol_swing.ogg'],
    **{key: [path] for key, path in WAVE_CAST_AUDIO.items()},
    **{key: [path] for key, path in FRENZY_AUDIO.items()},
    **{key: [path] for key, path in BLOODBLAST_AUDIO.items()},
    **{key: [path] for key, path in THIRST_AUDIO.items()},
    **{key: [path] for key, path in GRAB_BLAST_AUDIO.items()},
    **{key: [path] for key, path in BLOODY_RAVE_AUDIO.items()},
    **{key: [path] for key, path in BLOODY_RAVE_CONTACT_AUDIO.items()},
    **{key: [path] for key, path in DRAW_AUDIO.items()},
    **{key: [path] for key, path in OVERDRIVE_AUDIO.items()},
    **{key: [path] for key, path in UPPER_FOLLOWUP_AUDIO.items()},
    **{key: [path] for key, path in GUARD_AUDIO.items()},
    TRIPLE_SWING: TRIPLE_SWING_FILES,
    HARDATTACK_VOICE: HARDATTACK_VOICE_FILES,
    **{key: [path] for key, path in HARDATTACK_CHARGE_AUDIO.items()},
    **{key: [path] for key, path in HARDATTACK_WAVE_AUDIO.items()},
    'CONDITION_SLEEP': ['sounds/effect/c_sleep.ogg'],
    **{key: [path] for key, path in GHOST_FIELD_AUDIO.items()},
    **ZEALOT_SOUNDS,
    **OUTERWALL_SOUNDS,
    **OUTERWALL_BREAKABLE_SOUNDS,
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
              'R_GORECROSS_HIT', 'THROW_STONE', 'GORECROSS_ATK3', 'UPPER_SLASH_01']
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
    bank = {'atlas': atlas.save(), 'clips': clips, 'mob': mob, 'body_image': body}
    height = monster_number_height(src, mob)
    if height is not None:
        bank['number_height'] = height
    return bank


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
    weights = SOURCE_AUDIO_WEIGHTS.get(key, ())
    if weights and len(weights) != len(files):
        raise ValueError('Audio variant weights differ from source file count: '+key)
    for index, path in enumerate(files):
        found = src.audio(path)
        if not found:
            unresolved.append({'kind': 'audio', 'key': key, 'path': path})
            continue
        local, digest = found
        target = ACTIVE_OUT / 'audio' / PurePosixPath(path).name
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists():
            shutil.copyfile(local, target)
        entry = {'file': 'res://assets_local/combat/audio/' + target.name, 'source': path, 'sha256': digest}
        if weights:
            entry['weight'] = weights[index]
        out.append(entry)
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
    builtin = {str(mob).lower() for mob, _dir, _extra in MONSTERS.values()}
    builtin.update(NATIVE_ZEALOT_MONSTERS.values())
    builtin.update(NATIVE_OUTERWALL_BANKS.values())
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


def native_monster_bank(src: Source, key: str, mob: str, unresolved: list) -> dict:
    """Use the pinned content pack to include the exact native state animation clips."""
    record = src.pack_records.get(mob, {})
    decoded = record.get('decoded', {})
    suicide = record.get('native_suicide', {})
    jump = record.get('native_starfish_jump', {})
    if not decoded or not (suicide or jump or NATIVE_OUTERWALL_BANKS.get(key) == mob):
        raise ValueError('Compile the native monster content first: ' + mob)
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
    specials = decoded.get('etc_motions') or []
    if key in OUTERWALL_BODY_ETC_SLOTS:
        specials = [specials[slot] for slot in OUTERWALL_BODY_ETC_SLOTS[key]]
    elif suicide:
        specials = (suicide['suicide_ani'],)
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


def native_spirit_summon_assets(src: Source) -> tuple[dict, dict]:
    proxy = src.pack_records.get(NATIVE_SPIRIT_PROXY, {})
    summons = proxy.get('native_spirit_summons', {})
    if set(summons) != {NATIVE_OUTERWALL_BANKS['native_bossfather'], NATIVE_OUTERWALL_BANKS['native_bosspope']}:
        raise ValueError('Compile original spirit summon contracts before baking')
    if proxy['source']['sha256'] != NATIVE_SPIRIT_PROXY_SHA:
        raise ValueError('Original spirit summon proxy identity differs')
    effects = {'native_spirit_light_attack2': NATIVE_SPIRIT_LIGHT_ATTACK2}
    effects.update({bank: f'monster/zealot/commonani/{stem}.ani'
                    for _slot, stem, bank, _order, _sha in NATIVE_SPIRIT_CAST_LAYERS})
    effects.update({row['proxy_bank']: row['proxy_ani'] for row in summons.values()})
    for path in (NATIVE_SPIRIT_PROXY, *effects.values()):
        raw = src.lib.raw(path)
        if not raw or raw[1] != src.pack_records.get(path, {}).get('source', {}).get('sha256'):
            raise ValueError('Original spirit summon asset differs: ' + path)
        src.sources[path] = raw[1]
    for paths in NATIVE_SPIRIT_SOUNDS.values():
        for path, digest in paths.items():
            audio = src.audio(path)
            if not audio or audio[1] != digest or sha(audio[0].read_bytes()) != digest:
                raise ValueError('Original spirit summon audio differs: ' + path)
            src.sources[path] = digest
    return summons, effects


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
    manifest['native_jar_traps'], trap_effects, trap_pins = native_jar_trap_assets(src)
    manifest['native_spirit_summons'], summon_effects = native_spirit_summon_assets(src)
    manifest['native_status_visuals'] = native_status_visuals(src)
    particle_pins = {**trap_pins, NATIVE_POISON_PARTICLE: NATIVE_POISON_VISUAL_SHA}
    manifest['particles'], particle_effects = native_particle_definitions(src, particle_pins)
    effects.update(particle_effects)
    effects.update(trap_effects)
    effects.update(summon_effects)
    for key, spec in monster_specifications().items():
        manifest['monsters'][key] = monster_bank(src, key, spec['mob'], spec.get('clip_dir', ''), unresolved,
                                                  spec.get('extra', ()), spec.get('motions'))
    for key, path in (NATIVE_ZEALOT_MONSTERS | NATIVE_OUTERWALL_BANKS).items():
        manifest['monsters'][key] = native_monster_bank(src, key, path, unresolved)
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
    copy_native_jar_trap_audio(src, manifest['audio'], unresolved)
    for key in SOUND_KEYS:
        copy_audio(src, sound_files(src, key), manifest['audio'], key, unresolved)
    # MomentarySlashWave.atk requests ASTROM; audio.xml only registers ASTORM.
    unresolved.append({'kind': 'audio', 'key': 'ASTROM_HIT_LIGHT', 'note': 'no original audio.xml entry'})
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


def extend_native_particles(library: Path | None, output: Path = OUT, *, pack_path: Path | None = None) -> dict:
    """Stage the existing tree plus new banks; reject changes to existing PNGs."""
    global ACTIVE_OUT
    src = Source(library, pack_path=pack_path)
    previous_output = ACTIVE_OUT
    (ROOT/'temp').mkdir(parents=True,exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='dnf-particle-extend-', dir=ROOT/'temp'))
    try:
        shutil.copytree(output, stage, dirs_exist_ok=True)
        ACTIVE_OUT = stage
        manifest = json.loads((output/'manifest.json').read_text(encoding='utf8'))
        traps, trap_effects, trap_pins = native_jar_trap_assets(src)
        if 'native_jar_traps' in manifest:
            previous_traps = manifest['native_jar_traps']
            gas = traps['objects']['48003']['poison']
            previous_traps['objects']['48003'].setdefault('poison', gas)
            if previous_traps != traps:
                raise ValueError('Existing original jar trap contract differs')
        manifest['native_jar_traps'] = traps
        status_visuals = native_status_visuals(src)
        if any(status_visuals.get(key) != value
               for key, value in manifest.get('native_status_visuals', {}).items()):
            raise ValueError('Existing original status visual contract differs')
        manifest['native_status_visuals'] = status_visuals
        particle_pins = {**trap_pins, NATIVE_POISON_PARTICLE: NATIVE_POISON_VISUAL_SHA}
        definitions, effects = native_particle_definitions(src, particle_pins)
        effects.update(trap_effects)
        unresolved = []
        for key, path in effects.items():
            bank = effect_bank(src, key, path, unresolved)
            if key in manifest['effects'] and manifest['effects'][key] != bank:
                raise ValueError('Existing particle bank differs; create a new version: '+key)
            texture = 'fx_'+key+'.png'
            if (output/texture).exists() and (output/texture).read_bytes() != (stage/texture).read_bytes():
                raise ValueError('Existing particle texture differs: '+texture)
            manifest['effects'][key] = bank
        audio = {}
        for key, paths in OUTERWALL_BREAKABLE_SOUNDS.items():
            copy_audio(src, paths, audio, key, unresolved)
            for clip in audio.get(key, []):
                if sha((stage/'audio'/PurePosixPath(clip['source']).name).read_bytes()) != clip['sha256']:
                    raise ValueError('Original particle audio identity differs: ' + clip['source'])
            if key in manifest['audio'] and manifest['audio'][key] != audio.get(key):
                raise ValueError('Existing particle audio binding differs: ' + key)
        manifest['audio'].update(audio)
        copy_native_jar_trap_audio(src, manifest['audio'], unresolved)
        if unresolved:
            raise ValueError('Incomplete particle assets: '+str(unresolved))
        for path, digest in src.sources.items():
            if path in manifest['sources'] and manifest['sources'][path] != digest:
                raise ValueError('Existing source identity differs: '+path)
        manifest.setdefault('particles', {}).update(definitions)
        manifest['sources'].update(src.sources)
        manifest['skill_runtime_sha256'] = sha(SKILL_RUNTIME.read_bytes())
        (stage/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,separators=(',',':')),encoding='utf8')
        summary_path = stage/'build_summary.json'
        if summary_path.is_file():
            summary = json.loads(summary_path.read_text(encoding='utf8'))
            summary.update(effects=len(manifest['effects']), particle_templates=len(manifest['particles']),
                           audio_keys=len(manifest['audio']))
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
    if skill == 'sayaex':
        path = stage['hits'][0]['object']
        specs.append(('objects', path, path))
        ice = controller['crystals']['child']
        path = ice['object']
        specs.append(('objects', path, path))
        specs.extend(('effects', key, runtime['assets']['effect_anims'][key])
                     for key in ice['native_controller']['layers'].values())
        specs.extend(('audio', key, GHOST_FIELD_AUDIO[key])
                     for key in (ice['native_controller']['start_sound'], 'P_SAYA_ICE_HIT'))
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


def extend_skill_banks(library: Path | None, output: Path, specs: list, *, pack_path: Path | None = None,
                       include_spirit_summons: bool = False) -> dict:
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
        if include_spirit_summons:
            summons, effects = native_spirit_summon_assets(src)
            if 'native_spirit_summons' in manifest and manifest['native_spirit_summons'] != summons:
                raise ValueError('Existing original spirit summon contract differs')
            manifest['native_spirit_summons'] = summons
            specs = [*specs, *(('effects', key, path) for key, path in effects.items())]
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
                bank = native_monster_bank(src, key, path, unresolved)
            else:
                ani = src.object_animation(path) if section == 'objects' else path
                bank = effect_bank(src, safe_atlas_key('obj', key) if section == 'objects' else key, ani, unresolved)
                if section == 'objects':
                    bank.update(clip=src.animation(ani), object=path if path.endswith('.obj') else '')
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
    parser.add_argument('--extend-frenzy', action='store_true',
                        help='Add the original Frenzy release animation and cast sounds')
    parser.add_argument('--extend-bloodblast', action='store_true',
                        help='Add the ordinary Blood Blast layers and sounds')
    parser.add_argument('--extend-bloody-rave-audio', action='store_true',
                        help='Add the original Bloody Rave cast, loop and release sounds')
    parser.add_argument('--extend-bloody-rave-end', action='store_true',
                        help='Add the original Bloody Rave End.ani bank')
    parser.add_argument('--extend-bloody-rave-typhoon', action='store_true',
                        help='Add the original Bloody Rave Typhoon.ani bank')
    parser.add_argument('--extend-bloody-rave-contact', action='store_true',
                        help='Add the original Bloody Rave contact animation and ATK sound')
    parser.add_argument('--extend-outrage-break', action='store_true',
                        help='Add the original OutRageBreak ready, slash and impact layers and audio')
    parser.add_argument('--extend-thirst', action='store_true',
                        help='Add the original Thirst cast and release effects and sounds')
    parser.add_argument('--extend-draw', action='store_true',
                        help='Add the original Draw Sword slash and charge layers, short-sword wave and sounds')
    parser.add_argument('--extend-overdrive', action='store_true',
                        help='Add the original state 17 cast animations and Overdrive sounds')
    parser.add_argument('--extend-weapon-combo', action='store_true',
                        help='Add the original short-sword combo clips and short-sword/katana finish effects')
    parser.add_argument('--extend-illusion-slash-audio', action='store_true',
                        help='Append the original Illusion Slash objects, voices and sword-wave hit cue')
    parser.add_argument('--extend-rapid-move-slash', action='store_true',
                        help='Append the original Rapid Move Slash dust and voice/swing cues')
    parser.add_argument('--extend-upper-armor-light', action='store_true',
                        help='Add the original super-armor impact light animation')
    parser.add_argument('--extend-guard', action='store_true',
                        help='Add original guard spark, dust, and audio cues')
    parser.add_argument('--extend-triple-cues', action='store_true',
                        help='Add the final two Triple Slash animations and original weapon sound group')
    parser.add_argument('--extend-hardattack-voice', action='store_true',
                        help='Add the original Ghost Slash voice group')
    parser.add_argument('--extend-hardattack-charge', action='store_true',
                        help='Add Ghost Slash charge and full-charge cues')
    parser.add_argument('--extend-hardattack-dash', action='store_true',
                        help='Add the original full-charge Ghost Slash follow-up animation and effects')
    parser.add_argument('--extend-hardattack-wave', action='store_true',
                        help='Add original Ghost Drive wave banks and voices')
    parser.add_argument('--extend-sleep-status', action='store_true',
                        help='Add the original sleep status ANI and sound')
    parser.add_argument('--extend-upper-followup', action='store_true',
                        help='Add the original short-sword Upper Slash follow-up effect and sounds')
    parser.add_argument('--extend-khazan', action='store_true',
                        help='Add the Khazan ghost and area banks, preserving existing assets')
    parser.add_argument('--extend-bremen', action='store_true',
                        help='Add the Bremen ghost and area banks, preserving existing assets')
    parser.add_argument('--extend-saya', action='store_true',
                        help='Add the Saya ghost and area banks, preserving existing assets')
    parser.add_argument('--extend-sayaex', action='store_true',
                        help='Add the original EX Saya field and its animation banks')
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
    parser.add_argument('--extend-outerwall', action='store_true',
                        help='Add the original Father, Pope and Catapult body banks')
    parser.add_argument('--output', type=Path, help='Existing asset tree for incremental monster builds')
    parser.add_argument('--pack', type=Path, help='Compiled source pack for incremental monster builds')
    args = parser.parse_args()
    if (args.output or args.pack) and not (args.extend_raxy_starfish or args.extend_outerwall or args.extend_native_particles):
        parser.error('--output and --pack require --extend-raxy-starfish, --extend-outerwall or --extend-native-particles')
    if args.extend_outerwall:
        specs = [('monsters', key, path) for key, path in NATIVE_OUTERWALL_BANKS.items()]
        specs.extend(('audio', key, paths) for key, paths in OUTERWALL_SOUNDS.items())
        print(json.dumps(extend_skill_banks(args.library, args.output or OUT, specs, pack_path=args.pack,
                                          include_spirit_summons=True)))
        return 0
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
    if args.extend_sayaex:
        print(json.dumps(extend_ghost_field(args.library, 'sayaex')))
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
    if args.extend_frenzy:
        specs = [('effects', 'frenzy_blast', EFFECTS['frenzy_blast'])]
        specs.extend(('effects', key, path) for key, path in FRENZY_SWING_EFFECTS.items())
        specs.extend(('effects', key, path) for key, path in FRENZY_RECOVERY_EFFECTS.items())
        specs.extend(('audio', key, path) for key, path in FRENZY_AUDIO.items())
        print(json.dumps(extend_skill_banks(args.library, OUT, specs)))
        return 0
    if args.extend_bloodblast:
        runtime = json.loads(SKILL_RUNTIME.read_bytes())
        assets = runtime['assets']
        hits = runtime['moves']['bloodblast']['stages'][1]['hits']
        specs = [('player_clips', 'summon1', assets['player_anims']['summon1'])]
        specs.extend(('effects', key, assets['effect_anims'][key])
                     for hit in hits for key in hit['native_controller']['layers'])
        specs.extend(('effects', layer['effect'], assets['effect_anims'][layer['effect']])
                     for hit in hits for layer in hit['native_controller'].get('ani_layers', []))
        specs.extend(('effects', key, assets['effect_anims'][key])
                     for hit in hits for key in hit['native_controller'].get('ground_hit_fx', []))
        specs.extend(('objects', hit['object'], hit['object'])
                     for hit in hits if hit['object'] in assets['objects'])
        specs.extend(('audio', key, path) for key, path in BLOODBLAST_AUDIO.items())
        print(json.dumps(extend_skill_banks(args.library, OUT, specs)))
        return 0
    if args.extend_bloody_rave_audio:
        specs = [('audio', key, path) for key, path in BLOODY_RAVE_AUDIO.items()]
        print(json.dumps(extend_skill_banks(args.library, OUT, specs)))
        return 0
    if args.extend_bloody_rave_end:
        runtime = json.loads(SKILL_RUNTIME.read_bytes())
        key = runtime['moves']['bloodyrave']['suction_end_fx']
        print(json.dumps(extend_skill_banks(args.library, OUT, [('effects', key, runtime['assets']['effect_anims'][key])])))
        return 0
    if args.extend_bloody_rave_typhoon:
        runtime = json.loads(SKILL_RUNTIME.read_bytes())
        key = runtime['moves']['bloodyrave']['suction_typhoon']['key']
        print(json.dumps(extend_skill_banks(args.library, OUT, [('effects', key, runtime['assets']['effect_anims'][key])])))
        return 0
    if args.extend_bloody_rave_contact:
        runtime = json.loads(SKILL_RUNTIME.read_bytes())
        key = runtime['moves']['bloodyrave']['suction_contact_fx']
        specs = [('effects', key, runtime['assets']['effect_anims'][key])]
        specs.extend(('audio', cue, path) for cue, path in BLOODY_RAVE_CONTACT_AUDIO.items())
        print(json.dumps(extend_skill_banks(args.library, OUT, specs)))
        return 0
    if args.extend_outrage_break:
        runtime = json.loads(SKILL_RUNTIME.read_bytes())
        effects = runtime['assets']['effect_anims']
        stages = runtime['moves']['outragebreak']['stages']
        specs = [('effects', cue['key'], effects[cue['key']]) for stage in stages for cue in stage['fx']]
        floor = stages[1]['hits'][1]['native_controller']
        specs.extend(('effects', key, effects[key])
                     for key in (*floor['layers'], *floor['child']['native_controller']['layers']))
        specs.extend(('audio', cue, paths) for cue, paths in OUTRAGE_AUDIO.items())
        print(json.dumps(extend_skill_banks(args.library, OUT, specs)))
        return 0
    if args.extend_overdrive:
        specs = [('effects', key, path) for key, path in SELF_BUFF_EFFECTS.items()]
        specs.extend(('audio', key, path) for key, path in OVERDRIVE_AUDIO.items())
        print(json.dumps(extend_skill_banks(args.library, OUT, specs)))
        return 0
    if args.extend_thirst:
        runtime = json.loads(SKILL_RUNTIME.read_bytes())
        assets = runtime['assets']
        move = runtime['moves']['sacrifice']
        burst = move['full_charge_hit']
        specs = [('player_clips', name, assets['player_anims'][name])
                 for name in ('summon1', 'summon2', move['active_idle_ani'])]
        specs.extend(('effects', key, assets['effect_anims'][key])
                     for key in (move['cast_fx'], move['release_fx'], *burst['native_controller']['layers']))
        specs.append(('objects', burst['object'], burst['object']))
        specs.extend(('audio', key, path) for key, path in THIRST_AUDIO.items())
        print(json.dumps(extend_skill_banks(args.library, OUT, specs)))
        return 0
    if args.extend_draw:
        runtime = json.loads(SKILL_RUNTIME.read_bytes())
        draw = runtime['moves']['draw']
        wave = draw['short_wave']
        effect_paths = runtime['assets']['effect_anims']
        specs = [('audio', key, path) for key, path in DRAW_AUDIO.items()]
        specs.extend(('effects', key, effect_paths[key]) for key in [wave['rear_fx'], *draw['slash_layers']['slots']])
        specs.append(('objects', wave['object'], wave['object']))
        print(json.dumps(extend_skill_banks(args.library, OUT, specs)))
        return 0
    if args.extend_weapon_combo:
        specs = [('player_clips', f'weaponcomboshort{i}',
                  f'character/swordman/animation/weaponcomboshort{i}.ani') for i in range(1, 4)]
        specs.extend(('effects', key, path) for key, path in
                     (WEAPON_COMBO_FINISH_EFFECTS | WEAPON_COMBO_MASTERY_EFFECTS).items())
        print(json.dumps(extend_skill_banks(args.library, OUT, specs)))
        return 0
    if args.extend_illusion_slash_audio:
        specs = [('audio', key, path) for key, path in ILLUSION_SLASH_AUDIO.items()]
        specs.append(('audio', 'R_SM_HOANYOUNG', ILLUSION_SLASH_REPEAT_VOICES))
        specs.extend(('effects', key, path) for key, path in ILLUSION_WAVE_LAYERS.items())
        specs.extend(('objects', path, path) for path in
                     (f'passiveobject/character/swordman/illusionslashmelee{index}.obj' for index in range(1, 5)))
        print(json.dumps(extend_skill_banks(args.library, OUT, specs)))
        return 0
    if args.extend_rapid_move_slash:
        specs = [('effects', 'rapid_move_slash_dust', RAPID_SLASH_DUST)]
        specs.extend(('audio', key, path) for key, path in RAPID_SLASH_AUDIO.items())
        runtime = json.loads(SKILL_RUNTIME.read_text(encoding='utf-8'))
        effect_paths = runtime['assets']['effect_anims']
        layers = dict.fromkeys(layer['key'] for stage in runtime['moves']['rapidmoveslash']['stages']
                              for layer in stage.get('fx', []))
        specs.extend(('effects', key, effect_paths[key]) for key in layers)
        print(json.dumps(extend_skill_banks(args.library, OUT, specs)))
        return 0
    if args.extend_upper_armor_light:
        key = 'upper_armor_light'
        print(json.dumps(extend_skill_banks(args.library, OUT, [('effects', key, EFFECTS[key])])))
        return 0
    if args.extend_guard:
        specs = [('effects', key, EFFECTS[key]) for key in ('guard_spark', 'guard_dust')]
        specs.extend(('audio', key, path) for key, path in GUARD_AUDIO.items())
        print(json.dumps(extend_skill_banks(args.library, OUT, specs)))
        return 0
    if args.extend_hardattack_voice:
        print(json.dumps(extend_skill_banks(args.library, OUT, [('audio', HARDATTACK_VOICE, HARDATTACK_VOICE_FILES)])))
        return 0
    if args.extend_hardattack_charge:
        keys = ('hardattack_charge1', 'hardattack_charge2', 'hardattack_full1', 'hardattack_full2')
        specs = [('effects', key, EFFECTS[key]) for key in keys]
        specs.extend(('audio', key, path) for key, path in HARDATTACK_CHARGE_AUDIO.items())
        print(json.dumps(extend_skill_banks(args.library, OUT, specs)))
        return 0
    if args.extend_hardattack_dash:
        specs = [('player_clips', 'hardattackchargeafter', PLAYER_CLIPS['hardattackchargeafter'])]
        specs.extend(('effects', key, EFFECTS[key]) for key in ('hardattack_dash_dust', 'hardattack_dash_down', 'hardattack_dash_up'))
        print(json.dumps(extend_skill_banks(args.library, OUT, specs)))
        return 0
    if args.extend_triple_cues:
        specs = [('effects', key, EFFECTS[key]) for key in ('triple4', 'triple5')]
        specs.append(('audio', TRIPLE_SWING, TRIPLE_SWING_FILES))
        print(json.dumps(extend_skill_banks(args.library, OUT, specs)))
        return 0
    if args.extend_hardattack_wave:
        specs = [('objects', key, path) for key, path in HARDATTACK_WAVE_FRONTS.items()]
        specs.extend(('effects', key, path) for key, path in HARDATTACK_WAVE_REARS.items())
        specs.extend(('audio', key, path) for key, path in HARDATTACK_WAVE_AUDIO.items())
        print(json.dumps(extend_skill_banks(args.library, OUT, specs)))
        return 0
    if args.extend_sleep_status:
        specs = [('effects', 'native_sleep', EFFECTS['native_sleep']),
                 ('audio', 'CONDITION_SLEEP', CUE_SOUNDS['CONDITION_SLEEP'])]
        print(json.dumps(extend_skill_banks(args.library, OUT, specs)))
        return 0
    if args.extend_upper_followup:
        key = 'upper_short_followup'
        specs = [('effects', key, EFFECTS[key])]
        specs.extend(('audio', key, path) for key, path in UPPER_FOLLOWUP_AUDIO.items())
        print(json.dumps(extend_skill_banks(args.library, OUT, specs)))
        return 0
    if args.extend_native_particles:
        print(json.dumps(extend_native_particles(args.library, args.output or OUT, pack_path=args.pack)))
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
