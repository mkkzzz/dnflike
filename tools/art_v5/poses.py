"""Weaponless body pose library backed by the reviewed V3/V4 source atlases.

Every pose is a real authored source cell. Poses are resampled straight from
the source sheet at the requested render scale, so 2x previews keep detail.
"""
from __future__ import annotations

import sys
from functools import lru_cache
from pathlib import Path

from PIL import Image

TOOLS = Path(__file__).resolve().parents[1]
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

from bake_body_v3 import CALIBRATION as V3_CAL, SHEETS as V3_SHEETS, extract  # noqa: E402
from bake_body_v4 import CALIBRATION as V4_CAL, SHEETS as V4_SHEETS  # noqa: E402
from bake_body_v5 import CALIBRATION as V5_CAL, SHEETS as V5_SHEETS  # noqa: E402

BODY_H = 190.0


def _sheet(name: str):
    if name in V5_CAL:
        return V5_SHEETS / f'body_{name}.png', V5_CAL[name]
    if name in V3_CAL:
        return V3_SHEETS / f'body_{name}.png', V3_CAL[name]
    return V4_SHEETS / f'body_{name}.png', V4_CAL[name]


@lru_cache(maxsize=None)
def _cells(name: str):
    path, cal = _sheet(name)
    if name in V5_CAL:
        from bake_body_v5 import extract_grid
        poses, report = extract_grid(path, len(cal['points']))
    else:
        poses, report = extract(path, len(cal['points']))
    return poses, report, cal


class Pose:
    """A body pose in game units: root at (0,0), y down, facing right."""

    def __init__(self, sheet: str, cell: int, scale: float):
        poses, report, cal = _cells(sheet)
        rx, ry, hx, hy, angle, layer = cal['points'][cell]
        unit = BODY_H / cal['standing_h']
        self.key = f'{sheet}:{cell}'
        self.angle = float(angle)
        self.layer = layer
        self.hand = ((hx - rx) * unit, (hy - ry) * unit)
        src = poses[cell]
        x0, y0, _, _ = report[cell]['bbox']
        px = unit * scale
        self.image = src.resize((max(1, round(src.width * px)), max(1, round(src.height * px))),
                                Image.Resampling.LANCZOS)
        # Offset of the image's top-left corner from the root, in render pixels.
        self.offset = ((x0 - rx) * px, (y0 - ry) * px)


@lru_cache(maxsize=None)
def pose(sheet: str, cell: int, scale: float = 2.0) -> Pose:
    return Pose(sheet, cell, scale)
