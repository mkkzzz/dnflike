"""Goblin target poses straight from the reviewed demo atlas."""
from __future__ import annotations

import sys
from functools import lru_cache
from pathlib import Path

from PIL import Image

TOOLS = Path(__file__).resolve().parents[1]
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

from bake_demo_art import GROUPS, SHEETS, extract_grid_poses  # noqa: E402

READY, BREATHE, ALERT, CROUCH = 0, 1, 2, 3
RECOIL, AIRBORNE, DOWN, KNEEL = 12, 13, 14, 15


@lru_cache(maxsize=None)
def _cells():
    return extract_grid_poses(SHEETS / 'monster_demo_v2.png')


class MonsterPose:
    def __init__(self, cell: int, scale: float, facing: int):
        poses, report = _cells()
        spec = GROUPS['monster']
        ax, ay = spec['anchors'][cell]
        unit = spec['target_body_h'] / spec['standing_body_h']
        px = unit * scale
        src = poses[cell]
        x0, y0, _, _ = report[cell]['source_bbox']
        img = src.resize((max(1, round(src.width * px)), max(1, round(src.height * px))), Image.Resampling.LANCZOS)
        ox, oy = (x0 - ax) * px, (y0 - ay) * px
        if facing < 0:
            img = img.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
            ox = -(ox + img.width)
        self.image = img
        self.offset = (ox, oy)


@lru_cache(maxsize=None)
def monster_pose(cell: int, scale: float = 2.0, facing: int = -1) -> MonsterPose:
    return MonsterPose(cell, scale, facing)
