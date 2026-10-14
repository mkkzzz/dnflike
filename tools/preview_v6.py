#!/usr/bin/env python3
"""Review the exported V6 PNGs/manifest, not a separate procedural actor renderer."""
from __future__ import annotations

import argparse
import json
from functools import lru_cache
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

from art_v5.monster import monster_pose, READY, RECOIL, DOWN
from bake_seq_v6 import OUT as ASSETS, premult
from preview_v5 import encode, label

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/previews/v6_art'
SIZE = (800, 420)
GROUND = 350


@lru_cache(maxsize=None)
def image(path):
    return Image.open(ASSETS / path).convert('RGBA')


def clip_frame(clip, tick):
    for frame in clip['frames']:
        if frame['start_tick'] <= tick < frame['start_tick'] + frame['duration_ticks']:
            return frame
    return None


def paste(rgb, im, pos, blend='normal', gain=1.0):
    src = premult(im)
    x, y = (round(v) for v in pos)
    h, w = src.shape[:2]
    H, W = rgb.shape[:2]
    x0, y0, x1, y1 = max(0, x), max(0, y), min(W, x + w), min(H, y + h)
    if x1 <= x0 or y1 <= y0:
        return
    cut = src[y0 - y:y1 - y, x0 - x:x1 - x]
    if blend == 'add':
        rgb[y0:y1, x0:x1] += cut[..., :3] * gain
    else:
        a = cut[..., 3:4] * gain
        rgb[y0:y1, x0:x1] = cut[..., :3] * gain + rgb[y0:y1, x0:x1] * (1 - a)


def paint_clip(rgb, manifest, name, tick, anchor, gain=1.0):
    clip = manifest['clips'][name]
    frame = clip_frame(clip, tick)
    if frame:
        origin = np.asarray(anchor) - clip['anchor']
        paste(rgb, image(frame['file']), origin, clip['blend'], gain)


def opponent(cell, root, colour_age=None):
    p = monster_pose(cell, 180 / 132, -1)
    im = p.image.copy()
    if colour_age is not None and colour_age < 10:
        a = np.asarray(im).copy()
        f = 0.17 if colour_age == 0 else 0
        a[..., :3] = np.clip(a[..., :3] * (1 - f) + 255 * f, 0, 255)
        im = Image.fromarray(a)
    return im, np.asarray(root) + p.offset


def contact_at(guard, tip, target_image, target_origin, target_root):
    alpha = np.asarray(target_image)[..., 3]
    for k in np.linspace(0, 1, 121):
        p = guard * (1 - k) + tip * k
        if not target_root[0] - 40 <= p[0] <= target_root[0] + 45:
            continue
        x, y = np.round(p - target_origin).astype(int)
        if 0 <= x < alpha.shape[1] and 0 <= y < alpha.shape[0] and alpha[y, x] > 160:
            return p
    return None


def render(names, manifest, naked=False, debug=False):
    schedule = []
    start = 12
    for name in names:
        schedule.append((start, name))
        start += manifest['moves'][name]['length']
    total = start + 30
    clock, freeze, frames, marks, contacts = 0, 0, [], [], []
    effects, hit_done, ground_done = [], set(), set()
    bg = Image.open(ROOT / 'art/environments/dungeon_hall.png').convert('RGB').crop((220, 226, 1020, 646))
    base = np.asarray(bg, np.float32) / 255
    initial_x = 220 if names == ['quick_draw'] else 270
    enemy_base = initial_x + (218 if names == ['quick_draw'] else 128)
    enemy_x, enemy_hit_age, enemy_cell = enemy_base, None, READY
    enemy_last_kind = None
    last_frame = manifest['clips'][f'actor/{names[0]}']['frames'][0]
    last_root = np.array([initial_x, GROUND], np.float64)
    last_move, last_t, last_start_x = names[0], 0, initial_x
    for real in range(total + 28):
        cur = None
        travelled = 0.0
        for index, (s, name) in enumerate(schedule):
            if s <= clock < s + manifest['moves'][name]['length']:
                cur = index, name, clock - s, initial_x + travelled
                break
            if clock >= s + manifest['moves'][name]['length']:
                travelled += manifest['moves'][name]['travel'][2]
        if cur:
            index, name, local, start_x = cur
            frame = clip_frame(manifest['clips'][f'actor/{name}'], local)
            root = np.array([start_x + frame['root_dx'], GROUND])
            last_frame, last_root = frame, root
            last_move, last_t, last_start_x = name, local, start_x
        else:
            index, name, local, start_x = -1, last_move, last_t, last_start_x
            frame, root = last_frame, last_root
        move = manifest['moves'][name]
        target_root = np.array([enemy_x, GROUND])
        target_im, target_origin = opponent(enemy_cell, target_root, enemy_hit_age)
        guard = root + frame['guard']
        tip = root + frame['tip']
        if cur and not naked and index not in hit_done and move['active'][0] <= local < move['active'][1]:
            point = contact_at(guard, tip, target_im, target_origin, target_root)
            if point is not None:
                hit_done.add(index)
                freeze = move['hitstop']
                enemy_hit_age, enemy_cell = 0, RECOIL
                enemy_last_kind = move['fx']
                effects.append({'kind': 'hit', 'variant': move['fx'], 'point': point.copy(), 'age': 0})
                if move['fx'] == 'iai':
                    effects.append({'kind': 'iai', 'point': point.copy(), 'age': 0})
                contacts.append({'move': name, 'action_tick': local, 'real_tick': real,
                                 'contact': np.round(point, 2).tolist(), 'guard': np.round(guard, 2).tolist(),
                                 'tip': np.round(tip, 2).tolist(), 'freeze_ticks': move['hitstop']})
                target_im, target_origin = opponent(enemy_cell, target_root, 0)
        if cur and not naked and name == 'attack3' and local == move['ground_tick'] and index not in ground_done:
            ground_done.add(index)
            effects.append({'kind': 'ground', 'point': np.array([tip[0], GROUND]), 'age': 0})
        rgb = base.copy()
        iai_ages = [e['age'] for e in effects if e['kind'] == 'iai']
        if not naked and iai_ages:
            age = min(iai_ages)
            dim = max(0, 1 - max(0, age - 7) / 8)
            rgb *= 1 - dim * 0.30
        if not naked:
            for e in effects:
                if e['kind'] == 'ground':
                    paint_clip(rgb, manifest, 'ground/matter', e['age'], e['point'])
                    paint_clip(rgb, manifest, 'ground/light', e['age'], e['point'])
            paste(rgb, target_im, target_origin)
            paint_clip(rgb, manifest, f'slash_back/{name}', local, (start_x, GROUND))
        actor = image(frame['file'])
        if not naked and name == 'quick_draw' and cur and 16 <= local < 20:
            ghost = actor.copy()
            paste(rgb, ghost, root - manifest['clips'][f'actor/{name}']['anchor'] - (25, 0), gain=0.13)
        paste(rgb, actor, root - manifest['clips'][f'actor/{name}']['anchor'])
        if not naked:
            paint_clip(rgb, manifest, f'slash_front/{name}', local, (start_x, GROUND))
            for e in effects:
                if e['kind'] == 'hit':
                    paint_clip(rgb, manifest, f'hit_matter/{e["variant"]}', e['age'], e['point'])
                    paint_clip(rgb, manifest, f'hit_light/{e["variant"]}', e['age'], e['point'])
                elif e['kind'] == 'iai':
                    paint_clip(rgb, manifest, 'iai/flash', e['age'], e['point'])
        rgb = np.clip(rgb, 0, 1)
        im = Image.fromarray(np.round(rgb * 255).astype(np.uint8))
        if debug:
            draw = ImageDraw.Draw(im)
            draw.line([tuple(guard), tuple(tip)], fill='#53e7e1', width=1)
            grip = root + frame['grip']
            draw.ellipse((grip[0] - 3, grip[1] - 3, grip[0] + 3, grip[1] + 3), outline='#ffdc35', width=2)
        subtitle = '无特效·角色与剑同帧' if naked else '序列帧回放·命中演示'
        frames.append(label(im, f'V6  {subtitle}   {move["label"]}', 15))
        marks.append({'name': name, 'tick': local, 'source': frame['source_pose'], 'real': real})
        for e in effects:
            e['age'] += 1
        effects = [e for e in effects if e['age'] < 40]
        if enemy_hit_age is not None:
            enemy_hit_age += 1
            if freeze == 0:
                if enemy_hit_age < 16:
                    enemy_x += 0.7
                elif enemy_hit_age >= 18:
                    enemy_cell = DOWN if enemy_last_kind == 'heavy' else READY
        if freeze:
            freeze -= 1
        else:
            clock += 1
        if clock >= total:
            break
    return frames, marks, contacts


def keyframes(frames, marks, manifest, path):
    selected = []
    for name in dict.fromkeys(m['name'] for m in marks):
        move = manifest['moves'][name]
        for tick in (move['active'][0] - 2, move['active'][0], move['contact_tick'], move['active'][1] + 1):
            index = next((i for i, m in enumerate(marks) if m['name'] == name and m['tick'] == tick), None)
            if index is not None:
                tile = frames[index].crop((140, 95, 660, 375)).resize((520, 280), Image.Resampling.LANCZOS)
                selected.append(label(tile, f'{move["label"]} / tick {tick}', 14))
    canvas = Image.new('RGB', (520 * 4, 280 * ((len(selected) + 3) // 4)), (15, 17, 22))
    for i, tile in enumerate(selected):
        canvas.paste(tile, ((i % 4) * 520, (i // 4) * 280))
    canvas.save(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--stills', action='store_true')
    args = ap.parse_args()
    manifest = json.loads((ASSETS / 'manifest.json').read_text(encoding='utf-8'))
    OUT.mkdir(parents=True, exist_ok=True)
    reports = {}
    for clip, names in (('combo', ['attack1', 'attack2', 'attack3']), ('quick_draw', ['quick_draw'])):
        for naked in (True, False):
            frames, marks, contacts = render(names, manifest, naked=naked)
            tag = f'{clip}_naked' if naked else clip
            keyframes(frames, marks, manifest, OUT / f'{tag}_keyframes.png')
            if not args.stills:
                encode(frames, 60, OUT / f'{tag}_realtime.gif', OUT / f'{tag}_60fps.mp4', gif_fps=30)
                # Slow motion preserves every native 60 Hz frame, played at 20 Hz.
                zoom = [label(im.crop((120, 90, 690, 385)).resize((1140, 590), Image.Resampling.NEAREST),
                              'V6  原始帧 2倍放大 / 1/3速度', 18) for im in frames]
                encode(zoom, 20, OUT / f'{tag}_slow.gif', OUT / f'{tag}_slow.mp4', gif_fps=20)
            if not naked:
                reports[clip] = contacts
                print(f'[V6] {clip}: {len(frames)} real ticks, contacts={contacts}')
    (OUT / 'contacts.json').write_text(json.dumps(reports, ensure_ascii=False, indent=2), encoding='utf-8')
    missing = [n for names in (['attack1', 'attack2', 'attack3'], ['quick_draw']) for n in names
               if not any(c['move'] == n for cs in reports.values() for c in cs)]
    if missing:
        raise RuntimeError(f'no visible blade/target contact in preview: {missing}')
    print('[V6] exported-asset playback contact checks PASS')


if __name__ == '__main__':
    main()
