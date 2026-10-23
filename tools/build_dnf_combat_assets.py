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
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import sqlite3
import sys

from PIL import Image

from dnf_asset_reader import decode, parse
from dnf_asset_store import ROOT
from dnf_pvf import open_library
from dnf_locomotion import build as build_locomotion

OUT = ROOT / 'game_dnf/assets_local/combat'
SCHEMA = 'dnf_combat_assets/1'
BUILD_VERSION = 5

MONSTERS = {
    # key: (mob path, clip dir, extra clips)
    'goblin': ('monster/goblin/goblin.mob', 'monster/goblin/animation_goblin2', []),
    'goblin_thrower': ('monster/goblin/goblinthrower.mob', 'monster/goblin/animation_thrower', []),
    'tau_army': ('monster/tau/tauarmy.mob', 'monster/tau/armyanimation', []),
}
MONSTER_CLIPS = ['stay', 'move', 'attack1', 'throw', 'damage1', 'damage2', 'down', 'sit', 'overturn']
OBJECTS = {
    'gorecross': 'passiveobject/character/swordman/animation/gorecross1.ani',
    'throwstone': 'passiveobject/monster/goblin/animation/throwstone.ani',
}
# Player motions used by the trial skills that the runtime manifest does not carry yet.
# Frames index the same 210-pose body/weapon atlases (all <= 209).
PLAYER_CLIPS = {
    'tripleslash1': 'character/swordman/animation/tripleslash1.ani',
    'tripleslash2': 'character/swordman/animation/tripleslash2.ani',
    'tripleslash3': 'character/swordman/animation/tripleslash3.ani',
    'summon2': 'character/swordman/animation/summon2.ani',
}
# Effects whose opaque pixel extent stands in for an attack box where the original motion has
# none (DNF-D011). Depth is fixed to the common original box depth (y=-15, d=30). E-ADAPT.
DERIVED_BOXES = ['upper1', 'triple1', 'triple2', 'triple3', 'gore_slash1', 'gore_slash2']
DERIVED_DEPTH = (-15, 30)
# Original swordman ANIs whose attack boxes stand in for motions that carry none (DNF-D011):
# the short-sword-mastery variants of the same normal attacks / upper slash. E-ADAPT.
BORROWED = ['character/swordman/effect/animation/shortswordmastery/shortattack1dodge.ani',
            'character/swordman/effect/animation/shortswordmastery/shortattack2dodge.ani',
            'character/swordman/effect/animation/shortswordmastery/shortweaponupperslashafter.ani']
EFFECTS = {
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
CUE_SOUNDS = {
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


class Source:
    def __init__(self, library: Path | None):
        self.lib = open_library(library)
        self.root = self.lib.path
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

    def audio(self, path: str) -> Path | None:
        row = self.cat.execute("select * from assets where kind='audio' and lower(original_path)=? order by container limit 1",
                               (path.lower(),)).fetchone()
        return (self.root / row['local_path'], row['sha256']) if row else None


class Atlas:
    def __init__(self, name: str):
        self.name, self.items, self.images = name, {}, []
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
        canvas.save(OUT / (self.name + '.png'))
        return {'texture': 'res://assets_local/combat/' + self.name + '.png', 'items': self.items}


def cropped(image: Image.Image, meta: dict):
    box = image.getbbox()
    if not box:
        return Image.new('RGBA', (1, 1)), [meta['x'], meta['y']]
    # Trim transparent padding only; native pixels are never resized or recolored.
    return image.crop(box), [meta['x'] + box[0], meta['y'] + box[1]]


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
    bank = {'atlas': atlas.save(), 'frames': frames, 'duration_ms': ani['duration_ms'], 'source': ani_path}
    if bounds is not None:
        # Box6 [x, y, z, w, d, h]: screen y grows downward, height z grows upward from the anchor.
        bank['pixel_box'] = [bounds[0], DERIVED_DEPTH[0], -bounds[3], bounds[2] - bounds[0], DERIVED_DEPTH[1], bounds[3] - bounds[1]]
    return bank


def monster_bank(src: Source, key: str, mob: str, clip_dir: str, unresolved: list) -> dict:
    clips, used, images = {}, set(), set()
    for name in MONSTER_CLIPS:
        path = f'{clip_dir}/{name}.ani'
        try:
            ani = src.animation(path)
        except KeyError:
            continue
        clips[name] = ani
        images.update(ani['images'])
        used.update(f['img_frame'] for f in ani['frames'] if f.get('img_frame') is not None)
    if len(images) != 1:
        unresolved.append({'kind': 'monster_layers', 'monster': mob, 'images': sorted(images)})
    body = sorted(images)[0]
    atlas = Atlas('mob_' + key)
    for n in sorted(used):
        image, meta = src.frame(body, n)
        image, offset = cropped(image, meta)
        atlas.add(n, image, offset)
    script = src.lib.script(mob, 'mob')
    equipment = [f['values'] for f in script['fields'] if f['tag'] == '[equipment]']
    for parts in equipment:
        for part in parts[1:]:
            equ = ('monster/goblin/' + PurePosixPath(part).name).lower() if isinstance(part, str) else None
            if equ and not src.lib.exists(equ):
                unresolved.append({'kind': 'monster_equipment', 'monster': mob, 'path': part,
                                   'note': 'Referenced .equ absent from archive; appearance drawn from body IMG only'})
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
        target = OUT / 'audio' / PurePosixPath(path).name
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


def build(library: Path | None) -> dict:
    # Validate the full source library before replacing a consumable runtime.
    src = Source(library)
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)
    unresolved: list = []
    manifest = {'schema': SCHEMA, 'build_version': BUILD_VERSION, 'asset_version': src.lib.asset_version,
                'monsters': {}, 'objects': {}, 'effects': {}, 'digits': {}, 'audio': {}, 'weapon_sounds': {},
                'unresolved': unresolved}
    for key, (mob, clip_dir, _) in MONSTERS.items():
        manifest['monsters'][key] = monster_bank(src, key, mob, clip_dir, unresolved)
    for key, path in OBJECTS.items():
        manifest['objects'][key] = effect_bank(src, 'obj_' + key, path, unresolved)
        manifest['objects'][key]['clip'] = src.animation(path)
    for key, path in EFFECTS.items():
        try:
            manifest['effects'][key] = effect_bank(src, key, path, unresolved)
        except KeyError as error:
            unresolved.append({'kind': 'animation', 'path': path, 'error': str(error)})
    manifest['derived_boxes'] = {k: manifest['effects'][k]['pixel_box'] for k in DERIVED_BOXES
                                 if 'pixel_box' in manifest['effects'].get(k, {})}
    manifest['player_clips'] = {k: src.animation(p) for k, p in PLAYER_CLIPS.items()}
    manifest['borrowed'] = {p: src.animation(p) for p in BORROWED}
    # ANI frame sound events: event key -> original file, from the archive's own cross-reference.
    used = [p for p in PLAYER_CLIPS.values()] + list(OBJECTS.values()) + \
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
    (OUT / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, separators=(',', ':')), encoding='utf-8')
    summary = {'monsters': list(manifest['monsters']), 'objects': list(manifest['objects']),
               'effects': len(manifest['effects']), 'digits': len(manifest['digits']['items']),
               'audio_keys': len(manifest['audio']), 'unresolved': len(unresolved)}
    (OUT / 'build_summary.json').write_text(json.dumps({**summary, 'unresolved_items': unresolved}, ensure_ascii=False, indent=1), encoding='utf-8')
    # Marks a machine that builds combat banks from the full library itself. Kept outside the
    # combat/ folder so the shared combat_runtime pack (tools/pack_dnf_flow.py) never carries it;
    # the loop launcher then keeps this local build instead of installing the shared pack.
    (OUT.parent / '.combat_local_build.json').write_text(json.dumps(
        {'asset_version': src.lib.asset_version, 'build_version': BUILD_VERSION}), encoding='utf-8')
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--library', type=Path)
    args = parser.parse_args()
    print(json.dumps(build(args.library), ensure_ascii=True))
    return 0


if __name__ == '__main__':
    sys.exit(main())
