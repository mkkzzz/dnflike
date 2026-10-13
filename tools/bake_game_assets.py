# -*- coding: utf-8 -*-
"""把 render_preview.py 的程序化美术烘焙成 Godot 实机贴图（输出到 game/art/）。

单一美术源原则
--------------
角色 / 怪物 / HUD / 背景 / 特效的**唯一定义**都在 `tools/render_preview.py`。
本脚本只负责「采样 → 烘焙 → 落盘」，不重复描述任何美术细节。
改完美术重跑本脚本，实机即同步，不会出现两份实现漂移。

将来 M4 换 AI 真帧图时，只要让本脚本输出同样的帧条格式，
Godot 侧一行都不用改。

用法
----
    python tools/bake_game_assets.py              # 全部
    python tools/bake_game_assets.py --only bg    # 只烘焙背景
"""
import argparse
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(ROOT)
sys.path.insert(0, ROOT)

import render_preview as RP  # noqa: E402  美术源

OUT = os.path.join(PROJ, "game", "art")
GAME_W, GAME_H = 1280, 720           # 实机分辨率
SCALE = GAME_W // RP.W               # = 2，preview 世界 640x360 → 实机 1280x720
GROUND_Y = RP.GROUND0 * SCALE        # 224 * 2 = 448，实机地面 y

BG_PATH = os.path.join(RP.BG_PATH)


def _ensure(*parts):
    p = os.path.join(OUT, *parts)
    os.makedirs(p, exist_ok=True)
    return p


def _save(img, *parts):
    p = os.path.join(OUT, *parts)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    img.save(p)
    return os.path.relpath(p, PROJ).replace("\\", "/")


# ------------------------------------------------------------------ 背景 / 暗角
def bake_background():
    """地牢背景：沿用 preview 的取景（顶部裁掉 8%）与调色，烘焙到实机分辨率。

    注意这里直接从原始 1264x848 缩放到 1280x720，
    比 preview 的「先降到 640x360 再放大 2 倍」更清晰（符合"高清位图质感"的定稿要求）。
    """
    if not os.path.exists(BG_PATH):
        raise FileNotFoundError(f"缺背景源图：{BG_PATH}")
    img = Image.open(BG_PATH).convert("RGB")
    sw, sh = img.size
    ch = int(sw * 9 / 16)                 # 16:9 裁切高度
    top = int(sh * 0.08)                  # 与 preview 同取景
    img = img.crop((0, top, sw, min(sh, top + ch)))
    img = img.resize((GAME_W, GAME_H), Image.LANCZOS)

    arr = np.array(img).astype(np.float32)
    arr = arr * 1.18                      # 与 preview 同调色
    arr[..., 0] += 6
    arr[..., 2] += 8
    return _save(Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8)),
                 "bg_dungeon.png")


def bake_vignette():
    """暗角：preview 里是 `world *= VIGNETTE`（边缘压暗），此处烘焙成黑色半透明叠加层。"""
    yy, xx = np.mgrid[0:GAME_H, 0:GAME_W].astype(np.float32)
    v = 1 - 0.55 * (((xx - RP.W * 0.5 * SCALE) / (400.0 * SCALE)) ** 2 +
                    ((yy - 190.0 * SCALE) / (250.0 * SCALE)) ** 2)
    v = np.clip(v, 0.35, 1.0)
    rgba = np.zeros((GAME_H, GAME_W, 4), np.uint8)
    rgba[..., 3] = np.clip((1.0 - v) * 255.0, 0, 255).astype(np.uint8)
    return _save(Image.fromarray(rgba, "RGBA"), "vignette.png")


BAKERS = {
    "bg": (bake_background, bake_vignette),
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="", help="逗号分隔：bg")
    args = ap.parse_args()
    want = [s.strip() for s in args.only.split(",") if s.strip()] or list(BAKERS)

    _ensure()
    print(f"[BAKE] 输出目录 {os.path.relpath(OUT, PROJ)}  ({GAME_W}x{GAME_H}, scale={SCALE})")
    for key in want:
        if key not in BAKERS:
            print(f"[BAKE] 跳过未知目标：{key}")
            continue
        for fn in BAKERS[key]:
            print(f"[BAKE] {fn.__name__:22s} -> {fn()}")


if __name__ == "__main__":
    main()
