"""Authored motion design for the V5 art-polish preview.

Ticks are 60 Hz and keep the V4 frame budget (moves.json / skills.json).
Blade direction is authored in a 3D swing plane, so horizontal cuts sweep
around the body (near side in front of the coat, far side behind it).
"""
from __future__ import annotations

import numpy as np

from .fx import plane, plane_dir

SCREEN = plane(90, 0)
READY = plane_dir(SCREEN, 35)
# Ticks the blade takes to glide back to the hip after a move ends.
RETRACT = 6


def vec(basis, theta):
    return plane_dir(basis, theta)


# Forehand flat cut: back -> near side (in front of the body) -> target -> far side.
A1_PLANE = plane(-8, 5)
# Backhand return cut on an opposite tilt, so the pair reads as left/right.
A2_PLANE = plane(-6, -10)
# Heavy overhead chop in (almost) the screen plane.
A3_PLANE = plane(82, 0)
# Iaido draw: nearly level, long and flat.
QD_PLANE = plane(-3, 2)

MOVES = {
    'attack1': {
        'label': '一段·右横斩', 'length': 30, 'plane': A1_PLANE, 'sweep': -1,
        'poses': [(0, 'slash1', 0), (3, 'slash1', 1), (8, 'slash1', 2), (10, 'slash1', 3),
                  (14, 'slash1', 4), (18, 'slash1', 5), (21, 'slash1', 5)],
        'blade': [(0, 2, 'vec', READY, vec(A1_PLANE, 160), 'smooth'),
                  (2, 8, 'arc', 160, 186, 'out'),
                  (8, 14, 'arc', 186, -78, 'out3'),
                  (14, 21, 'arc', -78, -128, 'out'),
                  (21, 30, 'vec', vec(A1_PLANE, -128), READY, 'smooth')],
        'trail': {'t0': 8, 't1': 15, 'span': 165, 'thick': 0.46, 'life': 11, 'gain': 1.15,
                  'palette': 'steel', 'from': 118, 'to': -22, 'anchor': 11.9},
        'motion': (5, 14, 12.0),
        'hit': {'window': (8, 14), 'hitstop': 3, 'knock': 20, 'heavy': False, 'shake': 2.0},
    },
    'attack2': {
        'label': '二段·反手横斩', 'length': 32, 'plane': A2_PLANE, 'sweep': 1,
        'poses': [(0, 'slash2', 0), (4, 'slash2', 0), (9, 'slash2', 1), (11, 'slash2', 2),
                  (14, 'slash2', 3), (18, 'slash2', 4), (24, 'slash2', 5), (30, 'slash2', 5)],
        'blade': [(0, 9, 'arc', -128, -150, 'out'),
                  (9, 15, 'arc', -150, 118, 'out3'),
                  (15, 22, 'arc', 118, 150, 'out'),
                  (22, 32, 'vec', vec(A2_PLANE, 150), READY, 'smooth')],
        'trail': {'t0': 9, 't1': 16, 'span': 170, 'thick': 0.46, 'life': 11, 'gain': 1.15,
                  'palette': 'steel', 'from': -78, 'to': 72, 'anchor': 12.9},
        'motion': (6, 15, 10.0),
        'hit': {'window': (9, 15), 'hitstop': 3, 'knock': 24, 'heavy': False, 'shake': 2.2},
    },
    'attack3': {
        'label': '三段·竖劈', 'length': 41, 'plane': A3_PLANE, 'sweep': 1,
        'poses': [(0, 'combo3upper', 0), (3, 'combo3upper', 1), (8, 'combo3upper', 2), (14, 'combo3upper', 3),
                  (16, 'combo3upper', 4), (18, 'combo3upper', 5), (30, 'combo3upper', 6), (35, 'combo3upper', 7)],
        'blade': [(0, 3, 'vec', READY, vec(A3_PLANE, -150), 'smooth'),
                  (3, 12, 'arc', -150, -112, 'out'),
                  (12, 19, 'arc', -112, 82, 'in_out_fast'),
                  (19, 30, 'arc', 82, 82, 'lin'),
                  (30, 41, 'vec', vec(A3_PLANE, 82), READY, 'smooth')],
        'ground_clamp': True,
        'trail': {'t0': 12, 't1': 20, 'span': 150, 'thick': 0.56, 'life': 14, 'gain': 1.2,
                  'palette': 'steel', 'reach': 1.14},
        'motion': (9, 19, 18.0),
        'hit': {'window': (12, 19), 'hitstop': 6, 'knock': 70, 'heavy': True, 'shake': 5.0, 'knockdown': True},
    },
    'quick_draw': {
        'label': '拔刀斩', 'length': 36, 'plane': QD_PLANE, 'sweep': -1,
        'poses': [(0, 'combo3upper', 8), (5, 'combo12', 10), (16, 'airdash', 11), (27, 'combo12', 14),
                  (32, 'combo3upper', 7)],
        'blade': [(0, 5, 'vec', READY, vec(QD_PLANE, 205), 'smooth'),
                  (5, 16, 'arc', 205, 208, 'lin'),
                  (16, 20, 'arc', 208, -32, 'out3'),
                  (20, 27, 'arc', -32, -40, 'out'),
                  (27, 36, 'vec', vec(QD_PLANE, -40), READY, 'smooth')],
        'trail': {'t0': 16, 't1': 21, 'span': 200, 'thick': 0.24, 'life': 16, 'gain': 1.3,
                  'palette': 'azure', 'from': 125},
        'motion': (16, 19, 104.0),
        'charge': (2, 16),
        'afterimage': (16, 22),
        'hit': {'window': (16, 21), 'hitstop': 9, 'knock': 46, 'heavy': True, 'shake': 4.0, 'iai': True},
    },
}

PALETTES = {
    # Base sword light: white-hot rim, cold steel body, a faint crimson ember at the inner fade
    # that ties the cut to the hero's red arm without turning every swing into a skill colour.
    'steel': {'core': (1.0, 0.99, 0.97), 'main': (0.42, 0.68, 1.0), 'deep': (0.10, 0.20, 0.62)},
    'crimson': {'core': (1.0, 0.94, 0.88), 'main': (1.0, 0.26, 0.18), 'deep': (0.62, 0.02, 0.10)},
    'azure': {'core': (0.96, 1.0, 1.0), 'main': (0.24, 0.80, 1.0), 'deep': (0.16, 0.24, 0.90)},
}

HIT_PALETTE = {
    'core': (1.0, 0.99, 0.96), 'glow': (1.0, 0.70, 0.36), 'spark_hot': (1.0, 0.93, 0.70),
    'spark_mid': (1.0, 0.55, 0.18), 'spark_cool': (0.80, 0.16, 0.06),
    'blood': (0.42, 0.03, 0.05), 'blood_hi': (0.75, 0.10, 0.10), 'mist': (0.30, 0.03, 0.05),
}

GROUND_Y = 576.0
