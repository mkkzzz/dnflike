#!/usr/bin/env python3
"""Bake V5 sequence-frame assets into art/seq_v5/ for engine-side ingest.

DNF-style separation, all 60 fps (one frame per simulation tick):
  body/<move>/      weaponless body + blade, NORMAL blend, root-anchored
  slash/<move>/     blade light only, ADDITIVE, anchored to the move's start root
  hit/<kind>/       impact flash / starburst / cut mark / particles, ADDITIVE,
                    anchored to the contact point (kind = light | heavy | iai)
  ground/heavy/     floor-crack decal, NORMAL blend, anchored to the crack centre
  ground/heavy_glow crack heat + dust ring, ADDITIVE, same anchor

Rendered at 2x and LANCZOS-downsampled to 1x game pixels. Hit-stop repeats are
merged into longer frame durations in manifest.json. Particles (sparks, blood,
dust) are baked into the hit/ground clips; the runtime may still spawn extra
particles using the parameters table in the ingest guide.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))

from art_v5 import fx as F  # noqa: E402
from art_v5.moves import MOVES  # noqa: E402
from art_v5.scene import GROUND_Y, Scene, pose, premult_of  # noqa: E402
from art_v5.weapon import draw_katana  # noqa: E402
from preview_v5 import CLIPS  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'art' / 'seq_v5'
S = 2.0
MS = 1000.0 / 60.0

BODY_SIZE, BODY_ANCHOR = (480, 260), (240, 230)
SLASH_SIZE, SLASH_ANCHOR = (560, 360), (280, 280)
HIT_SIZE, HIT_ANCHOR = (420, 300), (210, 210)
GROUND_SIZE, GROUND_ANCHOR = (300, 120), (150, 60)

HIT_FRAMES, GROUND_FRAMES = 52, 64


class W2:
    """World -> canvas pixels: anchor world point maps to anchor canvas pixel."""

    def __init__(self, ax: float, ay: float, px: float, py: float, scale: float):
        self.ax, self.ay, self.px, self.py, self.S = ax, ay, px, py, scale

    def __call__(self, x: float, y: float):
        return ((x - self.ax) * self.S + self.px, (y - self.ay) * self.S + self.py)


def paste_rgba(dst: np.ndarray, pm: np.ndarray, x: float, y: float, mul=None, add=None) -> None:
    """Alpha-over of a premultiplied patch onto a premultiplied RGBA canvas."""
    x, y = int(round(x)), int(round(y))
    h, w = pm.shape[:2]
    H, W = dst.shape[:2]
    x0, y0, x1, y1 = max(0, x), max(0, y), min(W, x + w), min(H, y + h)
    if x1 <= x0 or y1 <= y0:
        return
    src = pm[y0 - y:y1 - y, x0 - x:x1 - x]
    col, a = src[..., :3], src[..., 3:4]
    if mul is not None:
        col = col * np.asarray(mul, np.float32)
    if add is not None:
        col = col + a * np.asarray(add, np.float32)
    dst[y0:y1, x0:x1, :3] = col + dst[y0:y1, x0:x1, :3] * (1 - a)
    dst[y0:y1, x0:x1, 3:] = a + dst[y0:y1, x0:x1, 3:] * (1 - a)


def new_canvas(size):
    w, h = size
    return np.zeros((h * int(S), w * int(S), 4), np.float32)


def downsample(rgba: np.ndarray) -> Image.Image:
    im = Image.fromarray((np.clip(rgba, 0, 1) * 255 + 0.5).astype(np.uint8), 'RGBA')
    return im.resize((im.width // int(S), im.height // int(S)), Image.Resampling.LANCZOS)


def to_additive(light: np.ndarray) -> np.ndarray:
    rgb = np.clip(light, 0, 1)
    a = rgb.max(axis=2, keepdims=True)
    return np.concatenate([rgb, a], axis=2)


def mat_to_png(mat: np.ndarray) -> np.ndarray:
    """Premultiplied decal buffer -> straight-alpha RGBA."""
    a = np.clip(mat[..., 3:], 0, 1)
    rgb = np.where(a > 1e-4, np.clip(mat[..., :3] / np.maximum(a, 1e-4), 0, 1), 0)
    return np.concatenate([rgb, a], axis=2)


def draw_body(sc, t: float) -> np.ndarray:
    """Body + blade on a root-anchored transparent canvas (no trail, no ghosts)."""
    p = sc.player
    sheet, cell = p.pose_key(t)
    sp = pose(sheet, cell, S)
    d, th, tan, name = p.blade(t)
    m = MOVES.get(name) if name else None
    if m and m.get('ground_clamp') and th is not None:
        d, th = p.clamp_ground(t, d, th, m)
    if tan is not None:
        p.edge = tan
    edge = p.edge if tan is None else tan
    depth = F.view_depth(d)
    layer = sp.layer
    if depth < -0.30:
        layer = 'back'
    elif depth > 0.25:
        layer = 'front'
    w2 = W2(p.root_x(t), GROUND_Y, BODY_ANCHOR[0] * S, BODY_ANCHOR[1] * S, S)
    hand_r = w2(p.root_x(t) + sp.hand[0], GROUND_Y + sp.hand[1])
    weapon = [draw_katana(hand_r, d, edge, S)]
    body = premult_of(('p', (sheet, cell)), sp.image)
    rgba = new_canvas(BODY_SIZE)
    rx, ry = w2(p.root_x(t), GROUND_Y)
    if layer == 'back':
        for arr, (x0, y0), _ in weapon:
            paste_rgba(rgba, arr, x0, y0)
    paste_rgba(rgba, body, rx + sp.offset[0], ry + sp.offset[1])
    if layer != 'back':
        for arr, (x0, y0), _ in weapon:
            paste_rgba(rgba, arr, x0, y0)
        # Painted fist patch over the grip, same as the live renderer.
        r = 8.5 * S
        bx = int(round(hand_r[0] - rx - sp.offset[0] - r))
        by = int(round(hand_r[1] - ry - sp.offset[1] - r))
        size = int(2 * r)
        patch = np.zeros((size, size, 4), np.float32)
        ys0, xs0 = max(0, by), max(0, bx)
        ys1, xs1 = min(body.shape[0], by + size), min(body.shape[1], bx + size)
        if ys1 > ys0 and xs1 > xs0:
            patch[ys0 - by:ys1 - by, xs0 - bx:xs1 - bx] = body[ys0:ys1, xs0:xs1]
            yy, xx = np.mgrid[0:size, 0:size]
            mask = np.clip(1.4 - np.hypot(xx - r, yy - r) / r * 1.4 + 0.35, 0, 1)[..., None]
            paste_rgba(rgba, patch * mask, hand_r[0] - r, hand_r[1] - r)
    return rgba


def save_seq(directory: Path, frames: list[Image.Image]):
    directory.mkdir(parents=True, exist_ok=True)
    out, dur = [], []
    for im in frames:
        b = im.tobytes()
        if out and b == out[-1][1]:
            dur[-1] += MS
            continue
        name = f'f{len(out):03d}.png'
        im.save(directory / name, compress_level=6)
        out.append((name, b))
        dur.append(MS)
    return [{'f': n, 'ms': round(d, 2)} for n, d in zip([o[0] for o in out], dur)]


def bake():
    manifest = {'meta': {'fps': 60, 'render_scale': '1x game pixels (baked at 2x, LANCZOS down)'},
                'clips': {}}
    for clip, spec in CLIPS.items():
        sc = Scene(spec['view'], spec['schedule'], spec['player_x'], spec['target_x'],
                   scale=S, tail=spec['tail'])
        body_frames: dict[str, list[Image.Image]] = {}
        slash_frames: dict[str, list[Image.Image]] = {}
        hits: list[dict] = []
        grounds: list[dict] = []
        for tick in range(sc.length):
            # identity snapshots: Particles.step rebuilds its list every tick,
            # so index-based diffs are unsafe.
            objs_before = {id(o) for o in sc.objs}
            parts_before = {id(p) for p in sc.parts.items}
            sc.step()
            cur = sc.player.current()
            if cur is not None:
                _, start, mv = cur
                body_frames.setdefault(mv, []).append(draw_body(sc, sc.player.view_t()))
            for tr in sc.trails:
                lt = sc.player.view_t() - tr.start
                if tr.tr['t0'] <= lt <= tr.tr['t1'] + tr.tr['life']:
                    root0 = sc.player.root_x(tr.start)
                    w2 = W2(root0, GROUND_Y, SLASH_ANCHOR[0] * S, SLASH_ANCHOR[1] * S, S)
                    bufs = F.Buffers(SLASH_SIZE[0] * int(S), SLASH_SIZE[1] * int(S))
                    tr.draw(bufs, w2)
                    slash_frames.setdefault(tr.name, []).append(
                        downsample(to_additive(bufs.add['back'] + bufs.add['front'] + bufs.add['top'])))
            # new effects belong to the contact that just triggered them
            new_objs = [o for o in sc.objs if id(o) not in objs_before]
            new_parts = [p for p in sc.parts.items if id(p) not in parts_before]
            for o in new_objs:
                cname = o.__class__.__name__
                if cname == 'GroundImpact':
                    grounds.append({'obj': o, 'parts': list(new_parts), 't0': tick})
                elif cname in ('HitSpark', 'IaiFlash'):
                    move = cur[2] if cur else ''
                    hit = MOVES[move]['hit']
                    kind = 'iai' if hit.get('iai') else (
                        'heavy' if hit['heavy'] else 'light')
                    anchor = getattr(o, 'c', None)
                    # iai spawns a flash and a spark on the same contact: one clip
                    prev = hits[-1] if hits else None
                    if prev and prev['kind'] == kind and prev['anchor'] == anchor:
                        prev['objs'].append(o)
                        prev['parts'].extend(new_parts)
                    else:
                        hits.append({'objs': [o], 'parts': list(new_parts), 'kind': kind,
                                     'anchor': anchor, 't0': tick})
            # charge motes etc. spawned outside a contact stay in the live scene only
            # render one frame for every running effect, in-lockstep with their age
            for h in hits:
                if tick - h['t0'] >= HIT_FRAMES:
                    continue
                ax, ay = h['anchor']
                bufs = F.Buffers(HIT_SIZE[0] * int(S), HIT_SIZE[1] * int(S))
                w2 = W2(ax, ay, HIT_ANCHOR[0] * S, HIT_ANCHOR[1] * S, S)
                for o in h['objs']:
                    o.draw(bufs, w2)
                for prt in h['parts']:
                    sc.parts.draw_particle(prt, bufs, w2)
                h.setdefault('frames', []).append(
                    downsample(to_additive(bufs.add['back'] + bufs.add['front'] + bufs.add['top'])))
            for g in grounds:
                if tick - g['t0'] >= GROUND_FRAMES:
                    continue
                bufs = F.Buffers(GROUND_SIZE[0] * int(S), GROUND_SIZE[1] * int(S))
                w2 = W2(g['obj'].x, GROUND_Y, GROUND_ANCHOR[0] * S, GROUND_ANCHOR[1] * S, S)
                g['obj'].draw(bufs, w2)
                for prt in g['parts']:
                    sc.parts.draw_particle(prt, bufs, w2)
                g.setdefault('decal', []).append(downsample(mat_to_png(bufs.mat['ground'])))
                g.setdefault('glow', []).append(
                    downsample(to_additive(bufs.add['back'] + bufs.add['top'])))
        for h in hits:
            seq = save_seq(OUT / 'hit' / h['kind'], h['frames'])
            manifest['clips'][f'hit/{h["kind"]}'] = {
                'blend': 'add', 'size': list(HIT_SIZE), 'anchor': list(HIT_ANCHOR),
                'world_hint': 'anchor = blade/target contact point', 'frames': seq}
        for g in grounds:
            manifest['clips']['ground/heavy'] = {
                'blend': 'normal', 'size': list(GROUND_SIZE), 'anchor': list(GROUND_ANCHOR),
                'world_hint': 'anchor = crack centre on the ground line',
                'frames': save_seq(OUT / 'ground' / 'heavy', g['decal'])}
            manifest['clips']['ground/heavy_glow'] = {
                'blend': 'add', 'size': list(GROUND_SIZE), 'anchor': list(GROUND_ANCHOR),
                'world_hint': 'same anchor as ground/heavy',
                'frames': save_seq(OUT / 'ground' / 'heavy_glow', g['glow'])}
        for mv, frames in body_frames.items():
            seq = save_seq(OUT / 'body' / mv, [downsample(f) for f in frames])
            a, b, dist = MOVES[mv]['motion']
            manifest['clips'][f'body/{mv}'] = {
                'blend': 'normal', 'size': list(BODY_SIZE), 'anchor': list(BODY_ANCHOR),
                'world_hint': 'anchor = player root on the ground line; travel is gameplay-side',
                'motion_hint': {'travel_start': a, 'travel_end': b, 'dx': dist,
                                'hit_window': list(MOVES[mv]['hit']['window']),
                                'hitstop': MOVES[mv]['hit']['hitstop'],
                                'length': MOVES[mv]['length']},
                'frames': seq}
        for mv, frames in slash_frames.items():
            seq = save_seq(OUT / 'slash' / mv, frames)
            manifest['clips'][f'slash/{mv}'] = {
                'blend': 'add', 'size': list(SLASH_SIZE), 'anchor': list(SLASH_ANCHOR),
                'world_hint': 'anchor = player root at the tick the move starts',
                'frames': seq}
        print(f'{clip}: body={ {k: len(v) for k, v in body_frames.items()} } '
              f'slash={ {k: len(v) for k, v in slash_frames.items()} } hits={len(hits)} grounds={len(grounds)}')
    (OUT / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=1))
    print('manifest ->', OUT / 'manifest.json')


if __name__ == '__main__':
    bake()
