#!/usr/bin/env python3
"""Bake V5 horizontal-slash body keys from generated green-screen sheets.

Flow: key the green background into real RGBA, split the six silhouettes per
sheet, then apply the hand-reviewed CALIBRATION below (root / grip / blade
angle / layer in source pixels). Reuses bake_body_v3.extract so downstream
tools (art_v5.poses) can consume the sheets unchanged.
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

from bake_body_v3 import extract  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
SHEETS = ROOT / 'art' / 'sheets' / 'v5'
GEN = ROOT / 'temp' / 'v5_gen'

# Landmarks reviewed against the generated sheets (1024x1024, 2 rows x 3 cols):
# each point is (root_x, root_y, grip_x, grip_y, blade_angle_degrees, layer).
# Blade angle is a Godot-style suggestion for the runtime rig (y down, from +x);
# the offline preview reads grip/root only and drives angles from the moves table.
CALIBRATION = {
    # Forehand horizontal slash: wind-up (back turned) -> launch -> mid -> full
    # extension -> over-rotation -> guard recover.
    'slash1': {'standing_h': 478, 'points': [
        (170, 468, 85, 270, -150, 'back'),
        (520, 470, 640, 148, -120, 'front'),
        (840, 478, 990, 155, 0, 'front'),
        (170, 990, 360, 648, -30, 'front'),
        (525, 995, 700, 645, 15, 'front'),
        (880, 985, 925, 630, 35, 'front'),
    ]},
    # Backhand horizontal slash: cross-body wind-up at the LEFT shoulder,
    # sweep right through back-turned full extension, low-guard recover.
    'slash2': {'standing_h': 478, 'points': [
        (200, 500, 95, 128, -150, 'back'),
        (525, 505, 655, 115, -30, 'front'),
        (860, 510, 985, 155, -10, 'front'),
        (185, 995, 355, 650, 10, 'front'),
        (530, 1000, 700, 680, 25, 'front'),
        (880, 995, 790, 780, 35, 'front'),
    ]},
}


def extract_grid(path: Path, expected: int, rows: int = 2, cols: int = 3):
    """Like bake_body_v3.extract but orders cells row-major over an rows x cols grid."""
    from bake_demo_art import components
    im = Image.open(path).convert('RGBA')
    rgba = np.asarray(im)
    if rgba[..., 3].min() != 0 or rgba[..., 3].max() != 255:
        raise ValueError(f'{path.name}: expected real transparent RGBA source alpha')
    labels, stats = components(rgba[..., 3] >= 64)
    bodies = [s for s in stats if s['area'] > 4000]
    if len(bodies) != expected:
        raise ValueError(f'{path.name}: expected {expected} silhouettes, got {len(bodies)}')
    h, w = rgba.shape[:2]
    bodies.sort(key=lambda s: (min(rows - 1, int((s['sy'] / s['area']) / (h / rows))),
                               s['sx'] / s['area']))
    poses, report = [], []
    for s in bodies:
        x0, y0 = max(0, s['x0'] - 3), max(0, s['y0'] - 3)
        x1, y1 = min(im.width, s['x1'] + 3), min(im.height, s['y1'] + 3)
        member = Image.fromarray((labels[y0:y1, x0:x1] == s['label']).astype(np.uint8) * 255)
        support = np.asarray(member.filter(ImageFilter.MaxFilter(5))) > 0
        part = rgba[y0:y1, x0:x1].copy()
        part[..., 3] *= support
        poses.append(Image.fromarray(part))
        report.append({'cell': len(report), 'bbox': [x0, y0, x1, y1], 'area': s['area'],
                       'centroid': [round(s['sx'] / s['area']), round(s['sy'] / s['area'])]})
    return poses, report


def key_green(path: Path) -> Image.Image:
    im = Image.open(path).convert('RGB')
    a = np.asarray(im).astype(np.int16)
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    fg = ~((g > 90) & (g - np.maximum(r, b) > 40))
    from scipy import ndimage
    fg = ndimage.binary_closing(fg, iterations=2)
    fg = ndimage.binary_opening(fg, iterations=1)
    # kill leftover green halo by clamping G on edge pixels
    edge = fg & ndimage.binary_dilation(~fg, iterations=2)
    out = a.astype(np.float64)
    spill = edge & (g > np.maximum(r, b))
    out[..., 1][spill] = np.maximum(r, b)[spill]
    rgba = np.dstack([np.clip(out, 0, 255).astype(np.uint8),
                      (fg * 255).astype(np.uint8)])
    return Image.fromarray(rgba, 'RGBA')


def bake(name: str, src: Path) -> None:
    rgba = key_green(src)
    dst = SHEETS / f'body_{name}.png'
    dst.parent.mkdir(parents=True, exist_ok=True)
    rgba.save(dst)
    n = len(CALIBRATION[name]['points'])
    if n == 0:
        # calibration pass: dump a numbered grid preview for landmark review
        prev = rgba.copy()
        dr = ImageDraw.Draw(prev)
        for gx in range(0, prev.width, 64):
            dr.line([(gx, 0), (gx, prev.height)], fill=(255, 255, 255, 40))
            dr.text((gx + 2, 2), str(gx), fill=(255, 255, 0, 255))
        for gy in range(0, prev.height, 64):
            dr.line([(0, gy), (prev.width, gy)], fill=(255, 255, 255, 40))
            dr.text((2, gy + 2), str(gy), fill=(255, 255, 0, 255))
        prev.convert('RGB').save(SHEETS / f'grid_{name}.png')
        return
    poses, report = extract_grid(dst, n)
    cal = SHEETS / f'calibration_{name}.jpg'
    vis = rgba.convert('RGB').copy()
    dr = ImageDraw.Draw(vis)
    for cell, (rx, ry, hx, hy, ang, layer) in enumerate(CALIBRATION[name]['points']):
        dr.ellipse((hx - 9, hy - 9, hx + 9, hy + 9), outline=(255, 230, 0), width=3)
        dr.line([(rx - 8, ry), (rx + 8, ry)], fill=(0, 255, 0), width=3)
        dr.line([(rx, ry - 8), (rx, ry + 8)], fill=(0, 255, 0), width=3)
        rad = np.radians(ang)
        dr.line([(hx, hy), (hx + np.cos(rad) * 120, hy + np.sin(rad) * 120)],
                fill=(60, 130, 255), width=3)
        dr.text((rx - 30, ry + 6), f'#{cell}', fill=(255, 255, 255))
    vis.save(cal, quality=90)
    print(f'{name}: baked {n} poses -> {dst.name}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--calibrate-only', action='store_true')
    args = ap.parse_args()
    for name, src in (('slash1', GEN / 'slash1_sheet.png'), ('slash2', GEN / 'slash2_sheet.png')):
        if not src.exists():
            print(f'{name}: source missing ({src})')
            continue
        if args.calibrate_only:
            bake(name, src)
        elif CALIBRATION[name]['points']:
            bake(name, src)
        else:
            print(f'{name}: CALIBRATION empty; run --calibrate-only first')


if __name__ == '__main__':
    main()
