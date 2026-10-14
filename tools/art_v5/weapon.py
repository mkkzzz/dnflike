"""Katana drawn from a 3D blade direction, projected with the camera tilt.

Horizontal cuts foreshorten the blade and its guard; the blade width follows
its cutting edge direction, so an edge-on blade reads thin and a blade
pointing at the camera reads short.
"""
from __future__ import annotations

import math

import numpy as np
from PIL import Image, ImageDraw

from .fx import project, view_depth

PROFILE = {
    'length': 144.0, 'width': 6.5, 'curve': 5.0, 'guard': 10.0, 'grip': 24.0,
    'outline': (11, 13, 18), 'spine': (78, 98, 116), 'steel': (176, 198, 212),
    'edge': (236, 246, 250), 'handle': (22, 24, 34), 'wrap': (142, 39, 54), 'metal': (168, 155, 125),
}
SS = 4


def _orth(d: np.ndarray, hint: np.ndarray) -> np.ndarray:
    n = hint - d * float(np.dot(hint, d))
    norm = np.linalg.norm(n)
    if norm < 1e-4:
        n = np.cross(d, np.array([0.0, 0.0, 1.0]))
        norm = np.linalg.norm(n)
    return n / norm


def draw_katana(hand_px, d: np.ndarray, edge_hint: np.ndarray, scale: float,
                alpha: float = 1.0, tint=None, profile=PROFILE):
    """Return (RGBA image, top-left) of the weapon in render pixels."""
    d = d / np.linalg.norm(d)
    n = _orth(d, edge_hint)
    m = np.cross(d, n)
    L, W, C = profile['length'], profile['width'], profile['curve']
    G, grip = profile['guard'], profile['grip']

    def P(off3):
        p = project(off3) * scale
        return (hand_px[0] + p[0], hand_px[1] + p[1])

    steps = 14
    edge_pts, spine_pts, mid_pts = [], [], []
    for i in range(steps + 1):
        s = i / steps
        x = 13 + s * (L - 13)
        bend = -n * C * s * s
        half = W * 0.5 * (1 - 0.22 * s)
        if i == steps:
            half = 0.0
        c3 = d * x + bend
        edge_pts.append(P(c3 + n * half))
        spine_pts.append(P(c3 - n * half * 0.9))
        mid_pts.append(P(c3 + n * half * 0.15))
    blade = edge_pts + spine_pts[::-1]
    grip_a = [P(d * 13 + n * 3.4), P(d * -grip + n * 3.0), P(d * -grip - n * 3.0), P(d * 13 - n * 3.4)]
    guard_pts = [P(d * 12 + (n * math.cos(a) + m * math.sin(a)) * G * 0.58)
                 for a in np.linspace(0, 2 * math.pi, 20, endpoint=False)]
    pommel = [P(d * (-grip - 1.5) + (n * math.cos(a) + m * math.sin(a)) * 3.4)
              for a in np.linspace(0, 2 * math.pi, 10, endpoint=False)]
    pts = blade + grip_a + guard_pts + pommel
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    x0, y0 = math.floor(min(xs)) - 4, math.floor(min(ys)) - 4
    x1, y1 = math.ceil(max(xs)) + 4, math.ceil(max(ys)) + 4
    w, h = max(1, x1 - x0), max(1, y1 - y0)
    img = Image.new('RGBA', (w * SS, h * SS), (0, 0, 0, 0))
    dr = ImageDraw.Draw(img)

    def T(seq):
        return [((px - x0) * SS, (py - y0) * SS) for px, py in seq]

    # Flat-face light: brighter when the blade's broad side faces the camera.
    face = abs(view_depth(m))
    lit = 0.62 + 0.38 * face

    def shade(rgb, k=1.0):
        return tuple(int(min(255, c * k)) for c in rgb) + (255,)

    ol = profile['outline'] + (255,)
    dr.polygon(T(grip_a), fill=ol)
    dr.line(T([P(d * 12), P(d * -grip)]), fill=shade(profile['handle']), width=int(5 * scale * SS * 0.5))
    for k in range(5):
        a = -grip + 4 + k * ((grip + 2) / 5.0)
        dr.line(T([P(d * a - n * 2.0), P(d * (a + 3.5) + n * 2.0)]), fill=shade(profile['wrap']),
                width=max(1, int(1.6 * scale * SS * 0.5)))
    dr.polygon(T(pommel), fill=shade(profile['metal'], 0.8))
    # Outline is a slightly fattened copy of the blade.
    fat = [P(d * (13 + s * (L - 13)) - n * C * s * s + n * (W * 0.5 * (1 - 0.22 * s) + 0.9))
           for s in np.linspace(0, 1, steps + 1)]
    fat += [P(d * (L + 1.2) - n * C)]
    fat += [P(d * (13 + s * (L - 13)) - n * C * s * s - n * (W * 0.45 * (1 - 0.22 * s) + 0.9))
            for s in np.linspace(1, 0, steps + 1)]
    dr.polygon(T(fat), fill=ol)
    dr.polygon(T(spine_pts[:-1] + mid_pts[::-1]), fill=shade(profile['spine'], lit))
    dr.polygon(T(mid_pts + edge_pts[::-1]), fill=shade(profile['steel'], lit))
    dr.line(T(edge_pts), fill=shade(profile['edge'], 0.9 + 0.1 * face), width=max(1, int(1.1 * scale * SS * 0.5)))
    dr.line(T(mid_pts[1:-2]), fill=(220, 236, 244, int(120 * face + 40)), width=max(1, int(0.8 * scale * SS * 0.5)))
    if view_depth(d) > 0:
        dr.polygon(T(guard_pts), fill=shade((24, 22, 26)), outline=shade(profile['metal']))
    else:
        dr.polygon(T(guard_pts), fill=shade((24, 22, 26)), outline=shade(profile['metal'], 0.8))
    img = img.resize((w, h), Image.Resampling.BOX)
    arr = np.asarray(img).astype(np.float32) / 255.0
    if tint is not None:
        arr[..., :3] = arr[..., :3] * (1 - tint[3]) + np.array(tint[:3], np.float32) * tint[3]
    arr[..., 3] *= alpha
    arr[..., :3] *= arr[..., 3:4]
    tip = P(d * L - n * C)
    return arr, (x0, y0), tip
