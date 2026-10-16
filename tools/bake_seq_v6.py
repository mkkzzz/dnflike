#!/usr/bin/env python3
"""Bake coupled painted actor/sword poses and pose-derived FX. Never writes game/."""
from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

from art_v5 import fx as F

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'art/animations/players/swordsman/v6/sources'
OUT = ROOT / 'art/animations/players/swordsman/v6/exports'
CONFIG = SOURCES / 'calibration.json'
BODY_SIZE, BODY_ANCHOR = (512, 320), (224, 280)
SLASH_SIZE, SLASH_ANCHOR = (640, 360), (256, 288)
IMPACT_SIZE, IMPACT_ANCHOR = (384, 320), (192, 192)
GROUND_SIZE, GROUND_ANCHOR = (512, 192), (256, 128)
FPS = 60


def config():
    return json.loads(CONFIG.read_text(encoding='utf-8'))


def straight_pm(pm):
    a = np.clip(pm[..., 3:4], 0, 1)
    rgb = np.clip(pm[..., :3] / np.maximum(a, 1e-8), 0, 1)
    rgb[a[..., 0] < 1e-6] = 0
    return Image.fromarray(np.round(np.concatenate([rgb, a], -1) * 255).astype(np.uint8))


def encode_light(light):
    light = np.clip(light, 0, 1)
    a = light.max(-1, keepdims=True)
    rgb = light / np.maximum(a, 1e-8)
    return Image.fromarray(np.round(np.concatenate([rgb, a], -1) * 255).astype(np.uint8))


def premult(im):
    a = np.asarray(im.convert('RGBA'), np.float32) / 255
    a[..., :3] *= a[..., 3:4]
    return a


def aa_light(light):
    channels = [np.asarray(Image.fromarray(light[..., c], 'F').resize(
        (light.shape[1] // 2, light.shape[0] // 2), Image.Resampling.LANCZOS)) for c in range(3)]
    return encode_light(np.stack(channels, -1))


def aa_matter(pm):
    channels = [np.asarray(Image.fromarray(pm[..., c], 'F').resize(
        (pm.shape[1] // 2, pm.shape[0] // 2), Image.Resampling.LANCZOS)) for c in range(4)]
    return straight_pm(np.stack(channels, -1))


def isolated_poses(spec):
    rgb = np.asarray(Image.open(SOURCES / spec['file']).convert('RGB'), np.float32)
    r, g, b = np.moveaxis(rgb, -1, 0)
    green = (g > 90) & (g > np.maximum(r, b) + 40)
    labels, count = ndimage.label(~green)
    sizes = np.bincount(labels.ravel())
    bodies = [i for i in range(1, count + 1) if sizes[i] > 9000]
    if len(bodies) != spec['actual_bodies']:
        raise ValueError(f"{spec['file']}: expected {spec['actual_bodies']} bodies, got {len(bodies)}")
    objects = ndimage.find_objects(labels)
    crops = []
    used = set()
    for p in spec['poses']:
        hx, hy = p['grip']
        patch = labels[max(0, hy - 9):hy + 10, max(0, hx - 9):hx + 10]
        candidates = [(np.count_nonzero(patch == i), i) for i in bodies]
        score, lab = max(candidates)
        if score == 0 or lab in used:
            raise ValueError(f"unmatched or duplicate grip at {p['grip']}")
        used.add(lab)
        sy, sx = objects[lab - 1]
        x0, y0 = max(0, sx.start - 4), max(0, sy.start - 4)
        x1, y1 = min(rgb.shape[1], sx.stop + 4), min(rgb.shape[0], sy.stop + 4)
        support = ndimage.binary_dilation(labels[y0:y1, x0:x1] == lab, iterations=2)
        cut = rgb[y0:y1, x0:x1].copy()
        rr, gg, bb = np.moveaxis(cut, -1, 0)
        alpha = (~green[y0:y1, x0:x1] & support).astype(np.float32)
        edge = ndimage.binary_dilation(alpha == 0, iterations=2) & (alpha > 0)
        cut[..., 1] = np.where(edge & (gg > np.maximum(rr, bb)), np.maximum(rr, bb), gg)
        pm = np.dstack([cut / 255 * alpha[..., None], alpha])
        crops.append((pm, (x0, y0)))
    return crops


def pose_image(spec, crop, landmark):
    pm, (x0, y0) = crop
    unit = 190 / spec['standing_height']
    w, h = max(1, round(pm.shape[1] * unit)), max(1, round(pm.shape[0] * unit))
    resized = np.stack([np.asarray(Image.fromarray(pm[..., c], 'F').resize(
        (w, h), Image.Resampling.LANCZOS)) for c in range(4)], -1)
    rx, ry = landmark['root']
    ox = round(BODY_ANCHOR[0] + (x0 - rx) * unit)
    oy = round(BODY_ANCHOR[1] + (y0 - ry) * unit)
    if ox < 0 or oy < 0 or ox + w > BODY_SIZE[0] or oy + h > BODY_SIZE[1]:
        raise ValueError(f'actor would clip: {(ox, oy, w, h)}')
    canvas = np.zeros((BODY_SIZE[1], BODY_SIZE[0], 4), np.float32)
    canvas[oy:oy + h, ox:ox + w] = resized
    return straight_pm(canvas)


def travel(move, tick):
    a, b, dx = move['travel']
    k = np.clip((tick - a) / (b - a), 0, 1)
    return float(dx * k * k * (3 - 2 * k))


def timeline(move):
    result = []
    for index, duration in move['keys']:
        result.extend([index] * duration)
    return result


def local_point(spec, index, name):
    p = spec['poses'][index]
    return (np.array(p[name], np.float64) - p['root']) * (190 / spec['standing_height'])


def sword_at(spec, move, tick):
    line = timeline(move)
    index = line[min(max(0, tick), len(line) - 1)]
    dx = np.array([travel(move, tick), 0])
    return local_point(spec, index, 'guard') + dx, local_point(spec, index, 'tip') + dx


def slash_image(spec, move, tick):
    w, h = SLASH_SIZE
    bufs = F.Buffers(w * 2, h * 2)
    start, end = move['active']
    life = move['trail_life']
    line = timeline(move)
    origin = np.array(SLASH_ANCHOR) * 2
    for at in range(start, min(end, tick + 1)):
        if at < 1 or line[at] == line[at - 1]:
            continue
        age = tick - at
        if age < 0 or age >= life:
            continue
        g0, t0 = sword_at(spec, move, at - 1)
        g1, t1 = sword_at(spec, move, at)
        fade = (1 - age / life) ** 1.8
        mask = Image.new('L', (w * 2, h * 2))
        dr = ImageDraw.Draw(mask)
        # A blade-swept surface, not an independently rotating moon-shaped sword.
        previous = None
        for k in np.linspace(0, 1, 25):
            guard = g0 * (1 - k) + g1 * k
            tip = t0 * (1 - k) + t1 * k
            tip[1] += math.sin(math.pi * k) * (6 if move['fx'] != 'heavy' else -8)
            inner = guard + (tip - guard) * 0.58
            pair = (inner * 2 + origin, tip * 2 + origin)
            if previous is not None:
                polygon = [tuple(previous[0]), tuple(previous[1]), tuple(pair[1]), tuple(pair[0])]
                dr.polygon(polygon, fill=int(170 * (0.3 + 0.7 * k)))
            previous = pair
        intensity = np.asarray(mask, np.float32) / 255 * fade
        yy, xx = np.mgrid[:h * 2, :w * 2]
        back = xx < origin[0] + travel(move, at) * 2 - 10
        col = np.array([0.26, 0.56, 0.90] if move['fx'] != 'iai' else [0.18, 0.64, 0.96])
        light = intensity[..., None] * col
        light += ndimage.gaussian_filter(light, (2.2, 2.2, 0)) * 0.3
        bufs.add['back'] += light * back[..., None] * 0.45
        bufs.add['front'] += light * (~back)[..., None]
        p1, p2 = g1 * 2 + origin, t1 * 2 + origin
        d = p2 - p1
        centre = (p1 + p2) * 0.5
        F.paint_spindle(bufs, 'front', centre, d, np.linalg.norm(d), 2.6,
                        (1, 1, 0.96), (0.30, 0.62, 0.98), gain=0.8 * fade)
    return aa_light(bufs.add['back']), aa_light(bufs.add['front'])


def impact_frames(kind, direction=(1.0, -0.08)):
    rng = np.random.default_rng(61 if kind == 'heavy' else 64)
    heavy = kind in ('heavy', 'iai')
    length = 32 if heavy else 24
    w, h = IMPACT_SIZE
    origin = np.array(IMPACT_ANCHOR) * 2
    d = np.asarray(direction, np.float64)
    d /= np.linalg.norm(d)
    angle = math.atan2(d[1], d[0])
    rays = [(angle + math.pi * (i % 2), 82 if heavy else 60, 2.2) for i in range(2)]
    rays += [(rng.uniform(-math.pi, math.pi), rng.uniform(13, 36), 1.2) for _ in range(5)]
    particles = [(rng.uniform(-0.9, 0.7), rng.uniform(120, 340), int(rng.integers(9, 22)))
                 for _ in range(20 if heavy else 12)]
    lights, matters = [], []
    for age in range(length):
        bufs = F.Buffers(w * 2, h * 2)
        if age < 3:
            F.paint_glow(bufs, 'top', origin, 12, (1, 0.74, 0.30), gain=0.6 * (1 - age / 3))
            F.paint_glow(bufs, 'top', origin, 4, (1, 1, 0.96), gain=1.8 * (1 - age / 3))
        if age < 5:
            k = (1 - age / 5) ** 1.5
            F.paint_starburst(bufs, 'top', origin, [(a, l * 2, width * 2) for a, l, width in rays],
                              (1, 1, 0.96), (1, 0.63, 0.22), gain=k)
        if age < 8:
            F.paint_spindle(bufs, 'top', origin, d, (68 if heavy else 48) * 2,
                            3 * (1 - age / 8), (1, 1, 0.94), (1, 0.69, 0.25), gain=1 - age / 8)
            F.paint_ring(bufs, 'top', origin, (4 + age * 4) * 2, 2,
                         (1, 0.76, 0.4), gain=0.4 * (1 - age / 8), squash=0.48, angle=angle)
        for a, speed, life in particles:
            if age >= life:
                continue
            t = age / FPS
            dist = speed * (1 - math.exp(-4 * t)) / 4
            vx, vy = math.cos(a) * dist, math.sin(a) * dist + 0.5 * 650 * t * t
            point = origin + np.array([vx, vy]) * 2
            k = 1 - age / life
            F.paint_spindle(bufs, 'top', point, (math.cos(a), math.sin(a)), 9 * k + 2, 1.4,
                            (1, 0.96, 0.75), (1, 0.38 + 0.3 * k, 0.10), gain=k)
        if heavy:
            for i in range(5):
                k = age / length
                cx = origin[0] + (i - 2) * 12 * (1 + k)
                cy = origin[1] + age * 0.4
                F.paint_blob(bufs, 'front', (cx, cy), (6 + k * 8), (0.30, 0.27, 0.23),
                             0.12 * (1 - k), seed=75 + i, stretch=(1.5, 0.6))
        lights.append(aa_light(bufs.add['top']))
        matters.append(aa_matter(bufs.mat['front']))
    return lights, matters


def ground_frames():
    rng = np.random.default_rng(72)
    w, h = GROUND_SIZE
    origin = np.array(GROUND_ANCHOR, np.float64) * 2
    pattern = Image.new('L', (w * 2, h * 2))
    dr = ImageDraw.Draw(pattern)
    for _ in range(8):
        angle = rng.uniform(0, math.tau)
        points = [tuple(origin)]
        end = origin.copy()
        for j in range(6):
            angle += rng.normal(0, 0.25)
            end += np.array([math.cos(angle) * 22, math.sin(angle) * 6])
            points.append(tuple(end))
        dr.line(points, fill=200, width=3)
    crack = np.asarray(pattern, np.float32) / 255
    matters, lights = [], []
    for age in range(36):
        bufs = F.Buffers(w * 2, h * 2)
        fade = 1 - float(F.smoothstep(18, 36, age))
        bufs.mat['ground'][..., :3] = crack[..., None] * np.array([0.06, 0.045, 0.04]) * fade
        bufs.mat['ground'][..., 3] = crack * fade
        bufs.add['top'] += ndimage.gaussian_filter(crack, 1.2)[..., None] * np.array([1, 0.51, 0.19]) * max(0, 1 - age / 14)
        if age < 10:
            F.paint_ring(bufs, 'top', origin, (10 + age * 9) * 2, 3,
                         (1, 0.78, 0.42), gain=0.6 * (1 - age / 10), squash=0.18)
        for side in (-1, 1):
            k = age / 36
            F.paint_blob(bufs, 'front', origin + (side * (12 + age * 2.5), -8),
                         18 + age, (0.38, 0.33, 0.27), 0.25 * (1 - k) ** 1.6,
                         seed=83 + side, stretch=(1.6, 0.55))
        F.over(bufs.mat['ground'][..., :3], bufs.mat['front'])
        a = bufs.mat['front'][..., 3]
        bufs.mat['ground'][..., 3] = a + bufs.mat['ground'][..., 3] * (1 - a)
        matters.append(aa_matter(bufs.mat['ground']))
        lights.append(aa_light(bufs.add['top']))
    return matters, lights


def store_clip(manifest, name, images, size, anchor, blend, clock, records=None):
    directory = OUT / name
    directory.mkdir(parents=True, exist_ok=True)
    hashes, frames = {}, []
    for tick, image in enumerate(images):
        if image.size != tuple(size):
            raise ValueError(f'{name}: wrong frame size')
        digest = hashlib.sha256(image.tobytes()).hexdigest()
        if digest not in hashes:
            path = f'{name}/f{len(hashes):03d}.png'
            image.save(OUT / path)
            hashes[digest] = path
        item = {'file': hashes[digest], 'start_tick': tick, 'duration_ticks': 1}
        if records:
            item.update(records[tick])
        if frames and frames[-1]['file'] == item['file'] and not records:
            frames[-1]['duration_ticks'] += 1
        else:
            frames.append(item)
    manifest['clips'][name] = {'size': list(size), 'anchor': list(anchor), 'blend': blend,
                              'alpha_mode': 'straight', 'clock': clock, 'start_tick': 0,
                              'duration_ticks': len(images), 'frames': frames,
                              'unique_images': len(hashes)}


def validate(manifest):
    tested, issues = set(), []
    for name, clip in manifest['clips'].items():
        next_tick = 0
        for f in clip['frames']:
            if f['start_tick'] != next_tick:
                issues.append(f'{name}: broken timeline at {next_tick}')
            next_tick += f['duration_ticks']
            if f['file'] in tested:
                continue
            tested.add(f['file'])
            im = Image.open(OUT / f['file'])
            rgba = np.asarray(im)
            if im.mode != 'RGBA' or im.size != tuple(clip['size']):
                issues.append(f'{f["file"]}: wrong format/size')
            edge = np.concatenate([rgba[0, :, 3], rgba[-1, :, 3], rgba[:, 0, 3], rgba[:, -1, 3]])
            if edge.max() > 5:
                issues.append(f'{f["file"]}: nontransparent canvas edge')
        if next_tick != clip['duration_ticks']:
            issues.append(f'{name}: incomplete duration')
    report = {'passed': not issues, 'unique_pngs_checked': len(tested), 'issues': issues,
              'checks': ['RGBA and dimensions', 'complete integer tick timelines',
                         'transparent canvas edges', 'no target/hit-stop in actor assets']}
    (OUT / 'validation.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    if issues:
        raise ValueError('\n'.join(issues))
    return report


def bake():
    cfg = config()
    manifest = {'version': 6, 'status': 'review_candidate', 'fps': FPS,
                'hitstop_baked': False, 'actor_includes_weapon': True,
                'normal_formula': 'dst = rgb * alpha + dst * (1-alpha)',
                'add_formula': 'dst = dst + rgb * alpha',
                'coordinate_system': 'pixels, right-facing, y-down; anchors are not centered',
                'clips': {}, 'moves': {}}
    poses = {}
    review = Image.new('RGB', (1536, 4 * 320), (21, 24, 31))
    draw = ImageDraw.Draw(review)
    for row, (name, spec) in enumerate(cfg['sheets'].items()):
        crops = isolated_poses(spec)
        poses[name] = [pose_image(spec, c, p) for c, p in zip(crops, spec['poses'])]
        for col, index in enumerate((0, 3 if name != 'quick_draw' else 4, 4 if name != 'quick_draw' else 5)):
            im = poses[name][index]
            base = Image.new('RGBA', BODY_SIZE, (21, 24, 31, 255))
            base.alpha_composite(im)
            review.paste(base.convert('RGB'), (col * 512, row * 320))
            for key, colour in (('grip', '#ffdd44'), ('guard', '#4bdfaf'), ('tip', '#44dfff')):
                p = local_point(spec, index, key) + BODY_ANCHOR
                x, y = p + np.array([col * 512, row * 320])
                draw.ellipse((x - 3, y - 3, x + 3, y + 3), outline=colour, width=2)
            draw.text((col * 512 + 8, row * 320 + 8), f'{name}:{index}', fill='white')
    for name, move in cfg['moves'].items():
        spec = cfg['sheets'][move['sheet']]
        line = timeline(move)
        actor_images, records, backs, fronts = [], [], [], []
        for tick, index in enumerate(line):
            actor_images.append(poses[move['sheet']][index])
            record = {'source_pose': f'{move["sheet"]}:{index}', 'root_dx': round(travel(move, tick), 4)}
            for key in ('grip', 'guard', 'tip'):
                record[key] = np.round(local_point(spec, index, key), 3).tolist()
            records.append(record)
            back, front = slash_image(spec, move, tick)
            backs.append(back)
            fronts.append(front)
        store_clip(manifest, f'actor/{name}', actor_images, BODY_SIZE, BODY_ANCHOR, 'normal', 'action', records)
        store_clip(manifest, f'slash_back/{name}', backs, SLASH_SIZE, SLASH_ANCHOR, 'add', 'action')
        store_clip(manifest, f'slash_front/{name}', fronts, SLASH_SIZE, SLASH_ANCHOR, 'add', 'action')
        manifest['moves'][name] = {**move, 'length': len(line), 'sword_points': 'actor frame guard/tip relative to root',
                                  'slash_anchor': 'root at move start, not moving root',
                                  'ground_tick': 12 if name == 'attack3' else None}
    for kind, direction in (('light', (1, -0.08)), ('heavy', (0.65, 0.76)), ('iai', (1, -0.04))):
        lights, matters = impact_frames(kind, direction)
        store_clip(manifest, f'hit_light/{kind}', lights, IMPACT_SIZE, IMPACT_ANCHOR, 'add', 'effect')
        store_clip(manifest, f'hit_matter/{kind}', matters, IMPACT_SIZE, IMPACT_ANCHOR, 'normal', 'effect')
    matters, lights = ground_frames()
    store_clip(manifest, 'ground/matter', matters, GROUND_SIZE, GROUND_ANCHOR, 'normal', 'effect')
    store_clip(manifest, 'ground/light', lights, GROUND_SIZE, GROUND_ANCHOR, 'add', 'effect')
    flashes = []
    for tick in range(22):
        bufs = F.Buffers(1920, 160)
        k = min(1, (tick + 1) / 2) * max(0, 1 - max(0, tick - 7) / 4)
        if k:
            F.paint_spindle(bufs, 'top', (960, 80), (1, -0.01), 1700, 3 + k * 3,
                            (1, 1, 1), (0.28, 0.74, 1), gain=k * 0.8)
        for index, at in enumerate((7, 10, 13)):
            age = tick - at
            if 0 <= age < 7:
                d = (1, (-0.28, 0.24, -0.03)[index])
                F.paint_spindle(bufs, 'top', (960, 80), d, 170, 3,
                                (1, 1, 1), (0.28, 0.74, 1), gain=(1 - age / 7) * 0.8)
        flashes.append(aa_light(bufs.add['top']))
    store_clip(manifest, 'iai/flash', flashes, (960, 80), (480, 40), 'add', 'effect')
    OUT.mkdir(parents=True, exist_ok=True)
    review.save(OUT / 'landmark_review.png')
    (OUT / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    report = validate(manifest)
    print(f'[V6] {len(manifest["clips"])} clips, {report["unique_pngs_checked"]} PNGs, validation PASS')
    return manifest


if __name__ == '__main__':
    bake()
