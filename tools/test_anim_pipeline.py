# -*- coding: utf-8 -*-
"""帧条管线冒烟测试：不需要任何真实美术，验证 AI 帧图 ingest 是否正确。

做的事：
  造一张合成 2x3 绿幕帧图（6 个不同姿势，每个角色挂一根**很细的剑**，
  用来检验腐蚀后靠测地线生长把剑身归属回本体）
    → 跑一遍 tools/bake_ai_frames.py 的烘焙
    → 断言：切满 6 帧、无空帧、**无帧贴到画布边缘（裁切）**、脚底锚点在画布内、时长已折算成物理帧

真帧图出问题时的第一道排查工具。历史上它抓到过一个隐蔽 bug：
画布高度只算了脚底以上，导致指向下方的刀尖被整段裁掉。

    python tools/test_anim_pipeline.py
"""
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(ROOT)
sys.path.insert(0, ROOT)

import bake_ai_frames as B  # noqa: E402

ROWS, COLS, CELL = 2, 3, 600
GREEN = (0, 255, 0)
SKIN, COAT, COAT2 = (236, 196, 164), (34, 34, 42), (52, 52, 66)
PANTS, BOOT, HAIR, BAND, BLADE, GRIP = (58, 56, 74), (72, 50, 36), (226, 230, 242), (198, 40, 52), (206, 220, 236), (60, 30, 34)


def _limb(d, p0, p1, w, col):
    d.line([p0, p1], fill=col, width=w, joint="curve")
    r = w / 2
    d.ellipse([p0[0] - r, p0[1] - r, p0[0] + r, p0[1] + r], fill=col)
    d.ellipse([p1[0] - r, p1[1] - r, p1[0] + r, p1[1] + r], fill=col)


def _figure(d, cx, cy, swing, arm_a, blade_a):
    foot_y = cy
    hip, neck, head = (cx, foot_y - 150), (cx, foot_y - 258), (cx, foot_y - 300)
    for sign, ang in ((1, swing), (-1, -swing)):
        th = math.radians(90 + ang)
        knee = (hip[0] + math.cos(th) * 78 * sign, hip[1] + math.sin(th) * 78)
        sh = math.radians(90 + ang * 0.35)
        ft = (knee[0] + math.cos(sh) * 74 * sign, min(knee[1] + math.sin(sh) * 74, foot_y))
        _limb(d, hip, knee, 30, PANTS)
        _limb(d, knee, ft, 26, PANTS)
        _limb(d, (ft[0] - 16, ft[1] - 6), (ft[0] + 22, ft[1] - 6), 20, BOOT)
    d.polygon([(hip[0] - 34, hip[1]), (hip[0] + 34, hip[1]), (neck[0] + 30, neck[1]), (neck[0] - 30, neck[1])], fill=COAT)
    d.polygon([(neck[0] - 12, neck[1]), (neck[0] + 12, neck[1]), (hip[0] + 16, hip[1] - 20), (hip[0] - 16, hip[1] - 20)], fill=COAT2)
    _limb(d, neck, head, 40, SKIN)
    d.ellipse([head[0] - 46, head[1] - 46, head[0] + 46, head[1] + 46], fill=HAIR)
    d.rectangle([head[0] - 48, head[1] - 48, head[0] + 48, head[1] - 30], fill=BAND)
    sh_p = (neck[0], neck[1] + 16)
    for sign, a in ((-1, -40), (1, arm_a)):
        th = math.radians(a)
        elb = (sh_p[0] + math.cos(th) * 56 * sign, sh_p[1] + math.sin(th) * 56)
        ha = math.radians(a + 30)
        hnd = (elb[0] + math.cos(ha) * 52 * sign, elb[1] + math.sin(ha) * 52)
        _limb(d, sh_p, elb, 22, COAT2)
        _limb(d, elb, hnd, 20, SKIN)
        if sign == 1:
            bt = math.radians(blade_a)
            _limb(d, hnd, (hnd[0] + math.cos(bt) * 190, hnd[1] + math.sin(bt) * 190), 10, BLADE)
            _limb(d, (hnd[0] - 12, hnd[1] - 6), (hnd[0] + 12, hnd[1] + 6), 12, GRIP)


def make_sheet(path):
    """6 个姿势明显不同 + 刀尖指向各异（含指向下方，专门压那个裁切 bug）。"""
    img = Image.new("RGB", (COLS * CELL, ROWS * CELL), GREEN)
    d = ImageDraw.Draw(img)
    poses = [(-22, -10, -70), (0, 10, -35), (22, 30, 0), (12, 50, 25), (-12, 70, 55), (-30, 90, 80)]
    for i, (sw, aa, ba) in enumerate(poses):
        r, c = divmod(i, COLS)
        _figure(d, c * CELL + CELL // 2, r * CELL + CELL - 90, sw, aa, ba)
    img.save(path)
    return poses


def main():
    tmp = os.path.join(PROJ, "temp")
    os.makedirs(tmp, exist_ok=True)
    sheet = os.path.join(tmp, "_smoke_sheet.png")
    make_sheet(sheet)

    strip, ax, ay, n = B.bake_action(sheet, ROWS, COLS, target_body_h=190, pixel=2, posterize=40)
    fw, fh = strip.width // n, strip.height

    fails = []
    if n != ROWS * COLS:
        fails.append(f"帧数 {n} != {ROWS * COLS}")
    arr = np.array(strip.convert("RGBA"))
    for i in range(n):
        f = arr[:, i * fw:(i + 1) * fw]
        ys, xs = np.nonzero(f[..., 3] > 20)
        if len(xs) == 0:
            fails.append(f"帧 {i} 是空的")
            continue
        if xs.min() <= 0 or xs.max() >= fw - 1 or ys.min() <= 0 or ys.max() >= fh - 1:
            fails.append(f"帧 {i} 贴到画布边缘（被裁）")
    if not (0 < ax < fw and 0 < ay < fh):
        fails.append(f"脚底锚点 ({ax},{ay}) 不在画布内")

    print(f"[SMOKE] 画布 {fw}x{fh} × {n} 帧，锚点 ({ax},{ay})")
    if fails:
        print("[SMOKE] FAIL")
        for f in fails:
            print("   -", f)
        sys.exit(1)
    print("[SMOKE] PASS  切帧数正确、无空帧、无裁切、锚点有效")


if __name__ == "__main__":
    main()
