# -*- coding: utf-8 -*-
"""动作原型预览渲染器：角色骨骼动画 / 怪物 / 特效 / 场景 / UI 全部由程序实时生成。"""
import math
import os
import random
from collections import deque

import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import imageio.v2 as imageio

W, H, S = 640, 360, 2
FPS = 30
FLOOR_TOP = 208
GROUND0 = 224
_PROJ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(_PROJ, "temp", "preview")
os.makedirs(OUT_DIR, exist_ok=True)
rng = random.Random(7)

_FONT_CACHE = {}


def _font(paths, size):
    key = (paths[0], size)
    if key not in _FONT_CACHE:
        f = None
        for p in paths:
            if os.path.exists(p):
                f = ImageFont.truetype(p, size)
                break
        _FONT_CACHE[key] = f or ImageFont.load_default()
    return _FONT_CACHE[key]


def F_NUM(s):
    return _font(["C:/Windows/Fonts/impact.ttf", "C:/Windows/Fonts/arialbd.ttf"], max(6, int(s)))


def F_CN(s):
    return _font(["C:/Windows/Fonts/msyhbd.ttc", "C:/Windows/Fonts/msyh.ttc", "C:/Windows/Fonts/simhei.ttf"], max(6, int(s)))


EASE = {
    "lin": lambda u: u,
    "out": lambda u: 1 - (1 - u) ** 3,
    "in": lambda u: u ** 3,
    "io": lambda u: u * u * (3 - 2 * u),
}


def lerp(a, b, t):
    return a + (b - a) * t


def lerp2(p, q, t):
    return (p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t)


def mixc(c1, c2, t):
    return tuple(int(c1[i] + (c2[i] - c1[i]) * t) for i in range(3))


def scalec(c, k):
    return tuple(max(0, min(255, int(v * k))) for v in c)


# ---------------------------------------------------------------- rig
PL_LEN = dict(torso=30, head=11, ua=17, la=17, th=21, sh=21, wpn=50, grip=8)
GB_LEN = dict(torso=20, head=14, ua=14, la=13, th=15, sh=15, wpn=30, grip=4)


def solve(pose, L, rot=0.0):
    pts = {}
    T = math.radians(pose["torso"])
    tv = (math.sin(T), -math.cos(T))
    pts["hip"] = (0.0, 0.0)
    pts["neck"] = (tv[0] * L["torso"], tv[1] * L["torso"])
    sh = (tv[0] * L["torso"] * 0.85, tv[1] * L["torso"] * 0.85)
    pts["sh"] = sh
    hd = math.radians(pose["torso"] + pose["head"])
    pts["head"] = (pts["neck"][0] + math.sin(hd) * L["head"] * 0.9, pts["neck"][1] - math.cos(hd) * L["head"] * 0.9)

    def chain(base, a1, rel, l1, l2):
        r1 = math.radians(a1)
        r2 = math.radians(a1 + rel)
        j = (base[0] + math.sin(r1) * l1, base[1] + math.cos(r1) * l1)
        e = (j[0] + math.sin(r2) * l2, j[1] + math.cos(r2) * l2)
        return j, e, a1 + rel

    pts["elf"], pts["hdf"], af = chain(sh, pose["uaf"], pose["laf"], L["ua"], L["la"])
    pts["elb"], pts["hdb"], _ = chain(sh, pose["uab"], pose["lab"], L["ua"], L["la"])
    pts["knf"], pts["ftf"], _ = chain((0.0, 0.0), pose["thf"], pose["shf"], L["th"], L["sh"])
    pts["knb"], pts["ftb"], _ = chain((0.0, 0.0), pose["thb"], pose["shb"], L["th"], L["sh"])
    sa = math.radians(af + pose["sword"])
    d = (math.sin(sa), math.cos(sa))
    hx, hy = pts["hdf"]
    pts["wtip"] = (hx + d[0] * L["wpn"], hy + d[1] * L["wpn"])
    pts["wbase"] = (hx - d[0] * L["grip"], hy - d[1] * L["grip"])
    if rot:
        r = math.radians(rot)
        c, s_ = math.cos(r), math.sin(r)
        for k, (x, y) in list(pts.items()):
            pts[k] = (x * c + y * s_, -x * s_ + y * c)
    return pts


def place(pts, L, X, feetY, h, facing, grounded=True, rot=0.0):
    if grounded:
        maxy = max(y for k, (x, y) in pts.items() if k not in ("wtip", "wbase", "head"))
        maxy = max(maxy, pts["head"][1] + L["head"] * 0.8)
        hipY = feetY - h - maxy
    else:
        stand = L["th"] + L["sh"]
        hipY = feetY - h - lerp(stand, L["head"] * 0.9, min(1.0, abs(rot) / 90.0))
    return {k: (X + x * facing, hipY + y) for k, (x, y) in pts.items()}


def circ(d, p, r, col):
    r = max(0.5, r)
    d.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=col)


def limb(d, p0, p1, w0, w1, col):
    x0, y0 = p0
    x1, y1 = p1
    dx, dy = x1 - x0, y1 - y0
    l = math.hypot(dx, dy) or 1e-6
    nx, ny = -dy / l, dx / l
    d.polygon([(x0 + nx * w0 / 2, y0 + ny * w0 / 2), (x1 + nx * w1 / 2, y1 + ny * w1 / 2),
               (x1 - nx * w1 / 2, y1 - ny * w1 / 2), (x0 - nx * w0 / 2, y0 - ny * w0 / 2)], fill=col)
    circ(d, p0, w0 / 2, col)
    circ(d, p1, w1 / 2, col)


def unit(p, q):
    dx, dy = q[0] - p[0], q[1] - p[1]
    l = math.hypot(dx, dy) or 1e-6
    return dx / l, dy / l


# ---------------------------------------------------------------- player look
OUTLINE = (16, 10, 20)
SKIN = (240, 206, 176)
HAIR = (226, 230, 242)
HAIR_D = (158, 168, 196)
COAT = (56, 66, 104)
COAT_D = (38, 44, 72)
TRIM = (190, 156, 72)
SHIRT = (226, 222, 206)
PANTS = (64, 60, 78)
PANTS_D = (44, 42, 56)
BOOT = (96, 62, 42)
BOOT_D = (70, 46, 32)
SCARF = (204, 40, 52)
CRIMSON = (214, 46, 60)
CRIMSON_L = (255, 110, 110)
BLADE = (200, 216, 232)
BLADE_HI = (255, 255, 255)
GOLD = (214, 172, 64)
GRIP = (70, 30, 34)
GLOVE = (62, 52, 72)
EYE = (30, 20, 30)


def draw_sword(d, q):
    hand, tip, base = q["hdf"], q["wtip"], q["wbase"]
    ux, uy = unit(hand, tip)
    nx, ny = -uy, ux
    bs = (hand[0] + ux * 10, hand[1] + uy * 10)
    near_tip = (tip[0] - ux * 12, tip[1] - uy * 12)
    mid1 = lerp2(bs, near_tip, 0.45)
    # 刃身三段金属渐变：根部暗钢 → 中部亮钢 → 尖端冷白
    d.polygon([(bs[0] + nx * 5.6, bs[1] + ny * 5.6), (mid1[0] + nx * 4.4, mid1[1] + ny * 4.4),
               (mid1[0] - nx * 4.4, mid1[1] - ny * 4.4), (bs[0] - nx * 5.6, bs[1] - ny * 5.6)], fill=(150, 170, 195))
    d.polygon([(mid1[0] + nx * 4.4, mid1[1] + ny * 4.4), (near_tip[0] + nx * 3.2, near_tip[1] + ny * 3.2),
               (near_tip[0] - nx * 3.2, near_tip[1] - ny * 3.2), (mid1[0] - nx * 4.4, mid1[1] - ny * 4.4)], fill=BLADE)
    d.polygon([(near_tip[0] + nx * 3.2, near_tip[1] + ny * 3.2), tip, (near_tip[0] - nx * 3.2, near_tip[1] - ny * 3.2)], fill=(238, 246, 255))
    # 剑脊高光 + 刃口暗线
    d.line([(bs[0] + nx * 1.6, bs[1] + ny * 1.6), (tip[0] - ux * 8 + nx * 1.0, tip[1] - uy * 8 + ny * 1.0)], fill=BLADE_HI, width=2)
    d.line([(bs[0] - nx * 2.4, bs[1] - ny * 2.4), (near_tip[0] - nx * 1.6, near_tip[1] - ny * 1.6)], fill=(110, 128, 152), width=2)
    # 剑柄缠绕纹 + 刀镡 + 剑首
    limb(d, base, hand, 7.2, 7.2, GRIP)
    for u in (0.35, 0.65):
        p = lerp2(base, hand, u)
        d.line([(p[0] + nx * 2.8, p[1] + ny * 2.8), (p[0] - nx * 2.8, p[1] - ny * 2.8)], fill=(104, 52, 58), width=2)
    g = (hand[0] + ux * 6.4, hand[1] + uy * 6.4)
    limb(d, (g[0] + nx * 11.2, g[1] + ny * 11.2), (g[0] - nx * 11.2, g[1] - ny * 11.2), 4.8, 4.8, GOLD)
    circ(d, (g[0] + nx * 11.2, g[1] + ny * 11.2), 3.2, (255, 216, 120))
    circ(d, (g[0] - nx * 11.2, g[1] - ny * 11.2), 3.2, (255, 216, 120))
    circ(d, base, 4.8, GOLD)
    circ(d, base, 2.2, (255, 216, 120))


def draw_leg(d, hip, kn, ft, f, pants, boot):
    limb(d, hip, kn, 17.6, 15.2, pants)
    limb(d, kn, ft, 15.2, 12.8, pants)
    kx, ky = kn
    d.line([(kx - 2.4, ky + 2.4), (kx + 2.4, ky - 2.4)], fill=scalec(pants, 0.65), width=2)
    limb(d, lerp2(kn, ft, 0.45), ft, 16.0, 14.4, boot)
    # 靴筒高光 + 鞋头
    limb(d, lerp2(lerp2(kn, ft, 0.45), ft, 0.3), lerp2(lerp2(kn, ft, 0.45), ft, 0.62), 13.2, 12.0, scalec(boot, 1.28))
    limb(d, ft, (ft[0] + f * 14.4, ft[1] + 1.6), 12.0, 9.6, boot)
    circ(d, (ft[0] + f * 8.0, ft[1] + 1.6), 2.8, scalec(boot, 1.35))


def draw_player(d, q, f, tnow, speed):
    q = {k: (x * 2, y * 2) for k, (x, y) in q.items()}
    neck, hip, head = q["neck"], q["hip"], q["head"]
    # 围巾：双层飘带（主层 + 内衬阴影层）
    pts = [neck]
    px, py = neck
    for i in range(1, 7):
        px += -f * (8.0 + speed * 2.2)
        py += 3.6 - speed * 0.56 + math.sin(tnow * 0.35 + i * 0.9) * 3.2
        pts.append((px, py))
    for i in range(len(pts) - 1):
        limb(d, pts[i], pts[i + 1], max(4.8, 14.0 - i * 1.6), max(4.0, 11.2 - i * 1.6), (150, 26, 38))
    for i in range(min(4, len(pts) - 1)):
        limb(d, lerp2(pts[i], pts[i + 1], 0.5), pts[i + 1], max(2.4, 6.8 - i * 1.2), max(2.4, 6.0 - i * 1.2), SCARF)
    d.line([lerp2(neck, pts[1], 0.3), lerp2(pts[1], pts[2], 0.5)], fill=(240, 96, 104), width=2)
    # 后臂（血红鬼手）
    limb(d, q["sh"], q["elb"], 13.6, 12.0, COAT_D)
    limb(d, q["elb"], q["hdb"], 12.0, 10.4, CRIMSON)
    limb(d, lerp2(q["elb"], q["hdb"], 0.4), lerp2(q["elb"], q["hdb"], 0.7), 10.4, 9.6, (150, 26, 38))
    circ(d, q["hdb"], 7.2, CRIMSON_L)
    circ(d, q["hdb"], 3.2, (255, 220, 220))
    # 衣摆：双层（内衬 + 主层），随速度飘动
    sway = math.sin(tnow * 0.3) * 4.8
    tail_len = 28 + speed * 8.8
    d.polygon([(hip[0] + f * 6, hip[1] - 4), (hip[0] + f * 8, hip[1] + 28), (hip[0] - f * 4, hip[1] + 48),
               (hip[0] - f * tail_len, hip[1] + 48 - speed * 6.4 + sway), (hip[0] - f * 14, hip[1] - 2)], fill=(22, 24, 42))
    d.polygon([(hip[0] + f * 8, hip[1] - 4), (hip[0] + f * 10, hip[1] + 24), (hip[0] - f * 2, hip[1] + 40),
               (hip[0] - f * (tail_len - 6), hip[1] + 40 - speed * 5.6 + sway), (hip[0] - f * 10, hip[1] - 4)], fill=COAT_D)
    d.line([(hip[0] - f * 4, hip[1] + 36), (hip[0] - f * (tail_len - 8), hip[1] + 38 - speed * 4.8 + sway)], fill=(18, 20, 36), width=2)
    # 后腿
    draw_leg(d, hip, q["knb"], q["ftb"], f, PANTS_D, BOOT_D)
    # 躯干：深蓝外套 + 白色衬衫前襟 + 领口 + 腰带
    ux, uy = unit(hip, neck)
    nx, ny = -uy, ux
    d.polygon([(hip[0] + nx * 15.2, hip[1] + ny * 15.2), (neck[0] + nx * 18.4, neck[1] + ny * 18.4),
               (neck[0] - nx * 18.4, neck[1] - ny * 18.4), (hip[0] - nx * 15.2, hip[1] - ny * 15.2)], fill=COAT)
    d.polygon([(hip[0] - nx * 15.2, hip[1] - ny * 15.2), (neck[0] - nx * 18.4, neck[1] - ny * 18.4),
               (neck[0] - nx * 13.2, neck[1] - ny * 13.2), (hip[0] - nx * 10.8, hip[1] - ny * 10.8)], fill=COAT_D)
    # 白衬衫前襟（开襟处露出的内衬）
    d.polygon([(neck[0] + nx * 8.0, neck[1] + ny * 8.0), (neck[0] + nx * 18.4, neck[1] + ny * 18.4),
               (neck[0] + nx * 15.2, neck[1] + ny * 15.2), (hip[0] + nx * 5.2, hip[1] + ny * 5.2)], fill=SHIRT)
    d.line([(neck[0] + nx * 10.4, neck[1] + ny * 10.4), (hip[0] + nx * 7.2, hip[1] + ny * 7.2)], fill=(160, 156, 140), width=2)
    # 衬衫领
    d.polygon([(neck[0], neck[1]), (neck[0] + nx * 9.2, neck[1] + ny * 9.2), (neck[0] - nx * 9.2, neck[1] - ny * 9.2)], fill=(240, 238, 228))
    d.line([(neck[0] + nx * 3.0, neck[1] + ny * 3.0), (neck[0] - nx * 3.0, neck[1] - ny * 3.0)], fill=(120, 116, 104), width=2)
    # 外套金边前襟线
    front = (nx * f, ny * f) if (nx * f) > 0 else (-nx * f, -ny * f)
    d.line([(neck[0] + front[0] * 6.4, neck[1] + front[1] * 6.4), (hip[0] + front[0] * 10.4, hip[1] + front[1] * 10.4)], fill=TRIM, width=4)
    limb(d, (hip[0] + nx * 15.2, hip[1] + ny * 15.2), (hip[0] - nx * 15.2, hip[1] - ny * 15.2), 7.2, 7.2, (96, 62, 40))
    bc = lerp2((hip[0] + nx * 15.2, hip[1] + ny * 15.2), (hip[0] - nx * 15.2, hip[1] - ny * 15.2), 0.5)
    d.rectangle([bc[0] - 3.2, bc[1] - 5.2, bc[0] + 3.2, bc[1] + 5.2], fill=GOLD)
    circ(d, bc, 2.0, (255, 224, 150))
    d.polygon([(hip[0] + f * 10, hip[1] - 4), (hip[0] + f * 16, hip[1] + 30), (hip[0] + f * 2, hip[1] + 36), (hip[0] - f * 4, hip[1])], fill=COAT)
    d.line([(hip[0] + f * 10, hip[1]), (hip[0] + f * 14, hip[1] + 28)], fill=(26, 30, 50), width=2)
    # 前腿
    draw_leg(d, hip, q["knf"], q["ftf"], f, PANTS, BOOT)
    # 头：脸 + 阴影 + 发 + 五官
    circ(d, head, 15.2, SKIN)
    hx, hy = head
    circ(d, (hx - f * 3.8, hy + 5.4), 6.4, mixc(SKIN, (208, 158, 130), 0.55))
    circ(d, (hx - f * 3.8, hy + 9.2), 4.0, mixc(SKIN, (208, 158, 130), 0.8))

    def hd(a, r):
        ar = math.radians(a)
        return (hx - f * math.sin(ar) * r, hy - math.cos(ar) * r)

    hair_back = [hd(-72, 16.0)] + [hd(a, 30 if i % 2 == 0 else 20) for i, a in enumerate(range(-45, 162, 23))] + [hd(168, 14), (hx - f * 3.0, hy)]
    d.polygon(hair_back, fill=HAIR_D)
    for i, a in enumerate(range(-50, 158, 17)):
        d.line([hd(a, 15.0), hd(a, 30 if i % 2 == 0 else 20)], fill=mixc(HAIR, (150, 160, 190), i % 3 * 0.25), width=3)
    d.polygon([(hx + f * 9.2, hy - 7.6), (hx + f * 4.6, hy - 15.2), (hx - f * 1.6, hy - 13.6)], fill=HAIR)
    # 眉 + 眼（白底黑瞳）+ 鼻影
    d.line([(hx + f * 4.2, hy - 4.6), (hx + f * 10.0, hy - 5.8)], fill=(86, 76, 84), width=2)
    _x0, _x1 = sorted((hx + f * 6.8 - 1.6, hx + f * 6.8 + 2.4))
    d.rectangle([_x0, hy - 1.0, _x1, hy + 1.8], fill=(248, 248, 252))
    _x0, _x1 = sorted((hx + f * 8.0, hx + f * 8.8))
    d.rectangle([_x0, hy - 1.0, _x1, hy + 1.8], fill=(36, 30, 42))
    d.point((hx + f * 7.0, hy - 0.6), fill=(255, 255, 255))
    d.line([(hx + f * 3.0, hy + 4.0), (hx + f * 1.6, hy + 6.4)], fill=mixc(SKIN, (180, 130, 100), 0.6), width=2)
    d.line([hd(-66, 16.0), hd(108, 16.0)], fill=SCARF, width=3)
    # 前臂 + 剑：上臂外套袖 → 剑 → 白衬衫袖 + 金袖口 + 手套
    limb(d, q["sh"], q["elf"], 14.4, 12.4, COAT)
    limb(d, lerp2(q["sh"], q["elf"], 0.5), lerp2(q["sh"], q["elf"], 0.8), 13.2, 12.0, (40, 48, 82))
    draw_sword(d, q)
    limb(d, q["elf"], q["hdf"], 12.4, 10.4, SHIRT)
    limb(d, lerp2(q["elf"], q["hdf"], 0.66), lerp2(q["elf"], q["hdf"], 0.94), 11.2, 10.8, TRIM)
    circ(d, q["hdf"], 7.6, GLOVE)
    d.line([(q["hdf"][0] - 3.2, q["hdf"][1] + 2.4), (q["hdf"][0] + 3.6, q["hdf"][1] + 3.2)], fill=(30, 24, 40), width=2)


# ---------------------------------------------------------------- goblin look
GOB1 = dict(skin=(112, 160, 68), skin_d=(78, 118, 48), cloth=(124, 80, 44), cloth_d=(92, 58, 34),
            club=(140, 100, 58), club_d=(98, 68, 40), eye=(255, 228, 70))
GOB2 = dict(skin=(176, 98, 70), skin_d=(126, 66, 50), cloth=(64, 62, 96), cloth_d=(46, 44, 70),
            club=(120, 120, 130), club_d=(80, 80, 92), eye=(255, 240, 120))


def draw_goblin(d, q, f, pal):
    q = {k: (x * 2, y * 2) for k, (x, y) in q.items()}
    hip, neck, head = q["hip"], q["neck"], q["head"]
    # 后臂
    limb(d, q["sh"], q["elb"], 12.0, 10.4, pal["skin_d"])
    limb(d, q["elb"], q["hdb"], 10.4, 9.6, pal["skin_d"])
    circ(d, q["hdb"], 6.4, pal["skin_d"])
    # 后腿
    limb(d, hip, q["knb"], 13.6, 12.0, pal["skin_d"])
    limb(d, q["knb"], q["ftb"], 12.0, 11.2, pal["skin_d"])
    limb(d, q["ftb"], (q["ftb"][0] + f * 12, q["ftb"][1] + 1.2), 10.4, 8.0, pal["skin_d"])
    # 躯干：弯腰驼背 + 肚皮
    ux, uy = unit(hip, neck)
    nx, ny = -uy, ux
    mid = lerp2(hip, neck, 0.45)
    d.polygon([(hip[0] + nx * 16, hip[1] + ny * 16), (mid[0] + nx * 22 + f * 6, mid[1] + ny * 22), (neck[0] + nx * 16, neck[1] + ny * 16),
               (neck[0] - nx * 16, neck[1] - ny * 16), (mid[0] - nx * 22 + f * 6, mid[1] - ny * 22), (hip[0] - nx * 16, hip[1] - ny * 16)], fill=pal["skin"])
    belly = lerp2(mid, hip, 0.35)
    d.ellipse([belly[0] - 14, belly[1] - 12, belly[0] + 14, belly[1] + 16], fill=mixc(pal["skin"], (255, 250, 235), 0.28))
    d.line([(belly[0] - 8, belly[1] + 12), (belly[0] + 8, belly[1] + 12)], fill=mixc(pal["skin"], (0, 0, 0), 0.25), width=2)
    for (dx, dy) in ((-18, -4), (-12, 12), (12, -16)):
        circ(d, (mid[0] + dx, mid[1] + dy), 2.4, mixc(pal["skin"], (20, 10, 10), 0.35))
    # 破布裙：主层 + 暗纹 + 破损锯齿边
    d.polygon([(hip[0] - 18, hip[1] - 8), (hip[0] + 18, hip[1] - 8), (hip[0] + f * 14, hip[1] + 24), (hip[0] + f * 6, hip[1] + 18),
               (hip[0] - f * 4, hip[1] + 30), (hip[0] - f * 12, hip[1] + 22), (hip[0] - f * 16, hip[1] + 16)], fill=pal["cloth"])
    d.line([(hip[0] - 16, hip[1]), (hip[0] + 16, hip[1])], fill=pal["cloth_d"], width=4)
    d.line([(hip[0] - 4, hip[1] + 4), (hip[0] - f * 10, hip[1] + 18)], fill=pal["cloth_d"], width=2)
    # 前腿 + 趾甲
    limb(d, hip, q["knf"], 13.6, 12.0, pal["skin"])
    limb(d, q["knf"], q["ftf"], 12.0, 11.2, pal["skin"])
    limb(d, q["ftf"], (q["ftf"][0] + f * 12, q["ftf"][1] + 1.2), 10.4, 8.0, pal["skin"])
    circ(d, (q["ftf"][0] + f * 10.8, q["ftf"][1] + 1.2), 2.0, (240, 230, 210))
    # 头：大圆头 + 耳 + 面部
    hx, hy = head
    d.polygon([(hx - f * 8, hy - 12), (hx - f * 52, hy - 26), (hx - f * 44, hy + 4), (hx - f * 12, hy + 10)], fill=pal["skin"])
    d.polygon([(hx - f * 16, hy - 14), (hx - f * 46, hy - 20), (hx - f * 40, hy - 2), (hx - f * 18, hy)], fill=mixc(pal["skin"], (255, 170, 160), 0.4))
    circ(d, head, 25.6, pal["skin"])
    d.polygon([(hx + f * 16, hy - 4), (hx + f * 34, hy + 6), (hx + f * 16, hy + 14)], fill=pal["skin"])
    d.polygon([(hx + f * 17, hy - 1), (hx + f * 29, hy + 4), (hx + f * 17, hy + 10)], fill=mixc(pal["skin"], (255, 170, 160), 0.4))
    # 眉弓 + 眼 + 瞳孔 + 高光 + 嘴牙
    d.line([(hx + f * 5.0, hy - 11.0), (hx + f * 17.0, hy - 8.0)], fill=mixc(pal["skin"], (0, 0, 0), 0.35), width=4)
    _x0, _x1 = sorted((hx + f * 5.2, hx + f * 14.8))
    d.rectangle([_x0, hy - 5.6, _x1, hy + 1.2], fill=pal["eye"])
    _x0, _x1 = sorted((hx + f * 9.2, hx + f * 12.8))
    d.rectangle([_x0, hy - 4.8, _x1, hy - 0.8], fill=(40, 20, 10))
    d.point((hx + f * 10.4, hy - 4.0), fill=(255, 255, 255))
    d.line([(hx + f * 4, hy + 9.2), (hx + f * 12, hy + 7.6)], fill=(40, 26, 20), width=4)
    _x0, _x1 = sorted((hx + f * 5.2, hx + f * 8.8))
    d.rectangle([_x0, hy + 10.8, _x1, hy + 15.2], fill=(242, 240, 228))
    _x0, _x1 = sorted((hx + f * 9.2, hx + f * 12.4))
    d.rectangle([_x0, hy + 12.4, _x1, hy + 16.4], fill=(242, 240, 228))
    _x0, _x1 = sorted((hx + f * 6.8, hx + f * 10.0))
    d.rectangle([_x0, hy + 16.4, _x1, hy + 19.2], fill=(222, 216, 200))
    # 前臂 + 木棒
    limb(d, q["sh"], q["elf"], 12.0, 10.4, pal["skin"])
    hand, tip = q["hdf"], q["wtip"]
    ux, uy = unit(hand, tip)
    nx, ny = -uy, ux
    d.polygon([(hand[0] + nx * 4.0, hand[1] + ny * 4.0), (tip[0] + nx * 10.4, tip[1] + ny * 10.4),
               (tip[0] - nx * 10.4, tip[1] - ny * 10.4), (hand[0] - nx * 4.0, hand[1] - ny * 4.0)], fill=pal["club"])
    circ(d, tip, 10.4, pal["club"])
    for u in (0.35, 0.6, 0.82):
        p = lerp2(hand, tip, u)
        w = lerp(4.0, 10.4, u)
        d.line([(p[0] + nx * w, p[1] + ny * w), (p[0] - nx * w, p[1] - ny * w)], fill=pal["club_d"], width=4)
    for (du, k) in ((0.3, -1), (0.72, 1)):
        p = lerp2(hand, tip, du)
        d.polygon([(p[0] + nx * 8.8, p[1] + ny * 8.8), (p[0] + nx * 12.4 + ux * k * 2.8, p[1] + ny * 12.4 + uy * k * 2.8),
                   (p[0] + nx * 14.0, p[1] + ny * 14.0)], fill=(90, 62, 44))
    limb(d, q["elf"], q["hdf"], 10.4, 9.6, pal["skin"])
    circ(d, q["hdf"], 6.8, pal["skin"])
    circ(d, (q["hdf"][0] + f * 2.4, q["hdf"][1] + 2.4), 2.0, (240, 230, 210))


# ---------------------------------------------------------------- layer finishing
def finish_layer(arr, flash=0.0, iters=1):
    a = arr[:, :, 3] > 0
    up = np.zeros_like(a)
    up[1:] = a[:-1]
    top = a & ~up
    rgb = arr[:, :, :3].astype(np.float32)
    rgb[top] += 32
    if flash > 0:
        rgb[a] = rgb[a] * (1 - flash) + 255 * flash
    rgb = np.clip(rgb, 0, 255).astype(np.uint8)
    dil = a.copy()
    for _ in range(iters):
        dil[1:] |= a[:-1]
        dil[:-1] |= a[1:]
        dil[:, 1:] |= a[:, :-1]
        dil[:, :-1] |= a[:, 1:]
        a = dil
    ol = dil & ~a
    out = np.zeros_like(arr)
    out[:, :, :3] = rgb
    out[:, :, 3] = np.where(a, 255, 0)
    out[ol] = (*OUTLINE, 255)
    return out


def comp_layer(world, layer, alpha_mul=1.0, tint=None, tint_k=0.0):
    a = layer[:, :, 3:4].astype(np.float32) / 255.0 * alpha_mul
    rgb = layer[:, :, :3].astype(np.float32)
    if tint is not None:
        rgb = rgb * (1 - tint_k) + np.array(tint, np.float32) * tint_k
    world[:] = world * (1 - a) + rgb * a


GLOW_CACHE = {}


def add_glow(arr, x, y, r, col, inten):
    r = max(1, int(r))
    k = GLOW_CACHE.get(r)
    if k is None:
        yy, xx = np.mgrid[-2 * r:2 * r + 1, -2 * r:2 * r + 1]
        k = np.exp(-(xx ** 2 + yy ** 2) / (2 * (r * 0.6) ** 2)).astype(np.float32)
        GLOW_CACHE[r] = k
    n = k.shape[0] // 2
    x, y = int(round(x)), int(round(y))
    x0, x1, y0, y1 = x - n, x + n + 1, y - n, y + n + 1
    kx0, ky0 = max(0, -x0), max(0, -y0)
    kx1 = k.shape[1] - max(0, x1 - W)
    ky1 = k.shape[0] - max(0, y1 - H)
    if kx0 >= kx1 or ky0 >= ky1:
        return
    arr[max(0, y0):min(H, y1), max(0, x0):min(W, x1)] += k[ky0:ky1, kx0:kx1, None] * np.array(col, np.float32) * inten


# ---------------------------------------------------------------- background
BG_PATH = os.path.join(_PROJ, "art", "environments", "dungeon_hall.png")
TORCHES = [(58, 134), (566, 136)]


def make_bg_legacy():
    img = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(img)
    for y in range(FLOOR_TOP):
        t = y / FLOOR_TOP
        d.line([(0, y), (W, y)], fill=(int(22 + 14 * t), int(19 + 12 * t), int(32 + 14 * t)))
    bh = 8
    for row, y in enumerate(range(2, FLOOR_TOP - 4, bh)):
        off = (row % 2) * 9
        for x in range(-18 + off, W, 18):
            v = rng.randint(-6, 6)
            base = (40 + v, 35 + v, 50 + v + rng.randint(0, 3))
            d.rectangle([x + 1, y + 1, x + 17, y + bh - 1], fill=base)
            d.line([(x + 1, y + 1), (x + 17, y + 1)], fill=scalec(base, 1.25))
            if rng.random() < 0.10:
                cx = x + rng.randint(4, 13)
                d.line([(cx, y + 2), (cx + rng.randint(-3, 3), y + bh - 2)], fill=scalec(base, 0.6))
            if rng.random() < 0.07:
                for _ in range(4):
                    d.point((x + rng.randint(2, 16), y + bh - rng.randint(1, 2)), fill=(50, 78, 46))
    # gate
    gx, gw, gt = 160, 58, 26
    d.rectangle([gx - gw // 2 - 7, gt + 10, gx + gw // 2 + 7, FLOOR_TOP], fill=(66, 60, 76))
    d.ellipse([gx - gw // 2 - 7, gt - 7, gx + gw // 2 + 7, gt + 28], fill=(66, 60, 76))
    for i in range(-3, 4):
        a = math.radians(90 + i * 22)
        p0 = (gx + math.cos(a) * (gw / 2), gt + 10 - math.sin(a) * 14)
        p1 = (gx + math.cos(a) * (gw / 2 + 7), gt + 10 - math.sin(a) * 20)
        d.line([p0, p1], fill=(44, 40, 52))
    d.rectangle([gx - gw // 2, gt + 10, gx + gw // 2, FLOOR_TOP], fill=(10, 6, 14))
    d.ellipse([gx - gw // 2, gt, gx + gw // 2, gt + 22], fill=(10, 6, 14))
    for bx in range(gx - gw // 2 + 4, gx + gw // 2, 7):
        d.line([(bx, gt + 2), (bx, gt + 22)], fill=(48, 44, 56))
    d.line([(gx - gw // 2 + 2, gt + 22), (gx + gw // 2 - 2, gt + 22)], fill=(56, 52, 64))
    d.polygon([(gx - 5, gt - 8), (gx + 5, gt - 8), (gx + 3, gt + 2), (gx - 3, gt + 2)], fill=(84, 76, 96))
    # pillars
    for px in (36, 262):
        pw = 22
        d.rectangle([px, 0, px + pw, FLOOR_TOP], fill=(60, 54, 70))
        d.rectangle([px, 0, px + 4, FLOOR_TOP], fill=(74, 68, 86))
        d.rectangle([px + pw - 5, 0, px + pw, FLOOR_TOP], fill=(44, 40, 52))
        for yy in (12, FLOOR_TOP - 10):
            d.rectangle([px - 3, yy, px + pw + 3, yy + 5], fill=(72, 66, 84))
            d.line([(px - 3, yy), (px + pw + 3, yy)], fill=(96, 88, 108))
        for yy in range(22, FLOOR_TOP - 12, 11):
            d.line([(px, yy), (px + pw, yy)], fill=(46, 42, 56))
        tx, ty = px + 11, 52
        d.rectangle([tx - 1, ty + 2, tx + 1, ty + 9], fill=(30, 24, 22))
        d.polygon([(tx - 4, ty), (tx + 4, ty), (tx + 2, ty + 4), (tx - 2, ty + 4)], fill=(80, 64, 40))
    # banners
    for bx in (92, 214):
        d.line([(bx - 11, 16), (bx + 11, 16)], fill=(110, 90, 50), width=2)
        d.polygon([(bx - 9, 17), (bx + 9, 17), (bx + 9, 60), (bx, 68), (bx - 9, 60)], fill=(96, 22, 32))
        d.polygon([(bx - 9, 17), (bx - 6, 17), (bx - 6, 62), (bx - 9, 60)], fill=(120, 34, 44))
        d.line([(bx - 9, 20), (bx + 9, 20)], fill=GOLD)
        d.polygon([(bx, 30), (bx + 6, 39), (bx, 48), (bx - 6, 39)], fill=(170, 130, 60))
        d.polygon([(bx, 34), (bx + 3, 39), (bx, 44), (bx - 3, 39)], fill=(96, 22, 32))
    # floor
    for y in range(FLOOR_TOP, H):
        t = (y - FLOOR_TOP) / (H - FLOOR_TOP)
        d.line([(0, y), (W, y)], fill=(int(48 + 16 * t), int(43 + 14 * t), int(54 + 14 * t)))
    ys = []
    y, step = FLOOR_TOP + 3.0, 4.0
    while y < H:
        ys.append(int(y))
        y += step
        step *= 1.3
    vx, vy = 160, FLOOR_TOP - 150
    for i in range(len(ys)):
        y0 = ys[i]
        y1 = ys[i + 1] if i + 1 < len(ys) else H
        off = 17 if i % 2 else 0
        for bx in range(-500 + off, W + 500, 34):
            xa = vx + (bx - vx) * ((y0 - vy) / (H - vy))
            xb = vx + (bx - vx) * ((y1 - vy) / (H - vy))
            d.line([(xa, y0), (xb, y1)], fill=(30, 27, 37))
        d.line([(0, y0), (W, y0)], fill=(30, 27, 37))
        d.line([(0, y0 + 1), (W, y0 + 1)], fill=(64, 58, 72))
    for _ in range(260):
        x, y = rng.randint(0, W - 1), rng.randint(FLOOR_TOP + 2, H - 1)
        d.point((x, y), fill=(36, 32, 42) if rng.random() < 0.6 else (74, 68, 82))
    for _ in range(14):
        x, y = rng.randint(10, W - 10), rng.randint(FLOOR_TOP + 6, H - 24)
        c = (84, 78, 90)
        d.ellipse([x, y, x + rng.randint(2, 4), y + 2], fill=c)
    for bx, by in ((72, 150), (240, 128), (120, 122)):
        d.line([(bx, by), (bx + 7, by + 1)], fill=(196, 186, 160), width=1)
        circ(d, (bx, by), 1, (196, 186, 160))
        circ(d, (bx + 7, by + 1), 1, (196, 186, 160))
    d.rectangle([0, FLOOR_TOP - 3, W, FLOOR_TOP], fill=(72, 65, 80))
    d.line([(0, FLOOR_TOP - 3), (W, FLOOR_TOP - 3)], fill=(96, 88, 104))
    d.line([(0, FLOOR_TOP + 1), (W, FLOOR_TOP + 1)], fill=(18, 15, 22))

    arr = np.array(img).astype(np.float32)
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    light = np.full((H, W), 0.60, np.float32)
    for tx, ty in TORCHES:
        light += 0.5 * np.exp(-((xx - tx) ** 2 + ((yy - ty) * 1.15) ** 2) / (2 * 40 ** 2))
    light += 0.25 * np.exp(-((xx - 160) ** 2 + (yy - 120) ** 2) / (2 * 70 ** 2))
    light *= 0.5 + 0.5 * np.clip(yy / 70, 0, 1)
    arr *= light[..., None] * np.array([1.10, 0.98, 0.90], np.float32)
    arr += (np.clip(1 - light, 0, 1)[..., None] * np.array([0, 3, 10], np.float32))
    door = np.exp(-((xx - 160) ** 2 / (2 * 18 ** 2) + (yy - 98) ** 2 / (2 * 22 ** 2)))
    mask = (np.abs(xx - 160) < 29) & (yy > 26) & (yy < FLOOR_TOP)
    arr += (door * mask)[..., None] * np.array([120, 30, 70], np.float32)
    return np.clip(arr, 0, 255)


def make_bg():
    """AI 生成的高清背景：裁剪 16:9 → 降采样到世界画布 → 色调统一。"""
    if os.path.exists(BG_PATH):
        img = Image.open(BG_PATH).convert("RGB")
        sw, sh = img.size
        ch = int(sw * 9 / 16)
        top = int(sh * 0.08)
        img = img.crop((0, top, sw, top + ch))
        img = img.resize((W, H), Image.LANCZOS)
        arr = np.array(img).astype(np.float32)
        arr = arr * 1.18
        arr[..., 0] += 6
        arr[..., 2] += 8
    else:
        arr = np.full((H, W, 3), 30, np.float32)
    return np.clip(arr, 0, 255)


VIGNETTE = None


def make_vignette():
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    v = 1 - 0.55 * (((xx - 320) / 400) ** 2 + ((yy - 190) / 250) ** 2)
    return np.clip(v, 0.35, 1.0)[..., None]


# ---------------------------------------------------------------- poses & clips
BASE = dict(torso=8, head=-4, uaf=25, laf=55, sword=-5, uab=-15, lab=35, thf=22, shf=-28, thb=-18, shb=-12, h=0.0)


def P(**kw):
    d = dict(BASE)
    d.update(kw)
    return d


def D(src, **kw):
    d = dict(src)
    d.update(kw)
    return d


A1_START = P(torso=-16, head=-8, uaf=178, laf=12, sword=20, uab=-42, lab=50, thf=10, shf=-16, thb=-22, shb=-10)
A1_HIT = P(torso=32, head=6, uaf=76, laf=10, sword=4, uab=-62, lab=28, thf=54, shf=-46, thb=-40, shb=-10)
A1_FOL = D(A1_HIT, uaf=56, sword=8)
A1_END = D(A1_FOL, torso=18, uaf=46, laf=26, sword=0)
A2_HIT = P(torso=-22, head=-14, uaf=170, laf=8, sword=16, uab=-16, lab=55, thf=22, shf=-14, thb=-40, shb=-6)
A2_END = D(A2_HIT, torso=2, uaf=154, laf=20, sword=14)
A3_WIND = P(torso=-30, head=-14, uaf=196, laf=18, sword=26, uab=-46, lab=44, thf=8, shf=-4, thb=-30, shb=-6)
A3_HIT = P(torso=52, head=20, uaf=74, laf=4, sword=8, uab=-78, lab=18, thf=70, shf=-84, thb=-56, shb=-8)
UP_CROUCH = P(torso=32, head=2, uaf=28, laf=4, sword=-6, uab=-34, lab=44, thf=70, shf=-100, thb=-30, shb=-64)
UP_HIT = P(torso=-22, head=-18, uaf=182, laf=0, sword=6, uab=-68, lab=28, thf=12, shf=-10, thb=-34, shb=-6, h=20)
GW_UP = P(torso=-16, head=-10, uaf=190, laf=8, sword=14, uab=-56, lab=64, thf=34, shf=-50, thb=-12, shb=-40, h=32)
GW_SLAM = P(torso=55, head=22, uaf=74, laf=0, sword=-36, uab=-88, lab=18, thf=76, shf=-100, thb=-60, shb=-12, h=0)
D_CROUCH = P(torso=42, head=12, uaf=-56, laf=28, sword=-46, uab=-46, lab=44, thf=64, shf=-84, thb=-46, shb=-24)
D_GO = P(torso=48, head=16, uaf=100, laf=0, sword=0, uab=-88, lab=18, thf=70, shf=-40, thb=-80, shb=-8)
D_END = P(torso=18, head=0, uaf=20, laf=10, sword=-30, uab=-20, lab=30, thf=30, shf=-40, thb=-30, shb=-15)

G_IDLE = dict(torso=18, head=-5, uaf=35, laf=45, sword=10, uab=-10, lab=40, thf=30, shf=-45, thb=-20, shb=-25, h=0.0)
G_HIT = dict(torso=-38, head=-32, uaf=-62, laf=34, sword=24, uab=-82, lab=34, thf=14, shf=-16, thb=-34, shb=-6, h=0.0)
G_AIR = dict(torso=-5, head=-15, uaf=160, laf=28, sword=12, uab=-165, lab=-24, thf=50, shf=-44, thb=-18, shb=-56, h=0.0)
G_DOWN = dict(torso=0, head=-10, uaf=160, laf=10, sword=0, uab=175, lab=0, thf=12, shf=-8, thb=-8, shb=-4, h=0.0)


# ---------------------------------------------------------------- 实机状态补充姿势
# preview 的剧本只演 idle / run / A1 A2 A3 / UPPER / GW / DASH，
# 但实机状态机（game/scripts/player.gd、monster.gd 的 St 枚举）还需要
# 起跳 / 后跳 / 格挡 / 受击 / 浮空 / 倒地 / 起身，以及哥布林的挥棒。
# 下面这些是同一套 rig 上的原创程序化姿势（基于 BASE / G_IDLE 调角度），
# 由 tools/bake_game_assets.py 烘焙成实机帧条 —— 改这里就等于改实机观感。
#
# 角度约定（详见 solve）：0 = 正下方，正 = 朝前（facing 方向），90 = 水平前，180 = 正上；
# shf / shb / laf / lab 是「相对上一节的夹角」，负值 = 关节向后折（膝盖/手肘的自然弯向）。
# h = 整体离地抬升（实机的物理位移由 CharacterBody2D 负责，这里只补视觉上的腾空/下沉）。

# 跳跃：蹲身蓄力 → 收腿上升 → 伸腿下落（落地那一下由状态机切回 idle，不单独做帧）
JUMP_TAKEOFF = P(torso=24, head=8, uaf=-34, laf=44, sword=-44, uab=-48, lab=32, thf=54, shf=-96, thb=-28, shb=-62)
JUMP_RISE = P(torso=-8, head=-14, uaf=148, laf=24, sword=14, uab=-124, lab=34, thf=58, shf=-104, thb=-34, shb=-58)
JUMP_FALL = P(torso=16, head=-2, uaf=48, laf=26, sword=-16, uab=-46, lab=42, thf=34, shf=-14, thb=-6, shb=-34)

# 后跳（↓+C）：向后仰身、双腿前蹬、剑在身前拖曳 → 落地刹住
BD_COIL = P(torso=26, head=6, uaf=-40, laf=52, sword=-40, uab=-44, lab=38, thf=48, shf=-88, thb=-24, shb=-58)
BD_LEAN = P(torso=-32, head=-12, uaf=126, laf=44, sword=26, uab=-74, lab=38, thf=50, shf=-26, thb=18, shb=-44, h=4)
BD_HOP = P(torso=-42, head=-16, uaf=144, laf=32, sword=16, uab=-88, lab=28, thf=64, shf=-38, thb=28, shb=-54, h=12)
BD_LAND = P(torso=8, head=2, uaf=34, laf=40, sword=-24, uab=-30, lab=44, thf=36, shf=-58, thb=-20, shb=-40)

# 格挡（V）：剑身竖在身前，重心下沉；GUARD_LOW 是循环里的呼吸帧
GUARD = P(torso=16, head=-2, uaf=98, laf=-58, sword=124, uab=-34, lab=46, thf=28, shf=-38, thb=-24, shb=-26)
GUARD_LOW = P(torso=20, head=0, uaf=104, laf=-54, sword=118, uab=-30, lab=48, thf=32, shf=-44, thb=-22, shb=-30, h=-3)
GUARD_HI = P(torso=13, head=-4, uaf=94, laf=-62, sword=128, uab=-37, lab=44, thf=25, shf=-34, thb=-25, shb=-23, h=1)

# 受击（HIT）：头后仰、手臂甩起 → 收势
HIT_RECOIL = P(torso=-26, head=-34, uaf=-44, laf=64, sword=-34, uab=-96, lab=44, thf=30, shf=-26, thb=-26, shb=-14)
HIT_SAG = P(torso=-8, head=-16, uaf=-16, laf=52, sword=-28, uab=-56, lab=40, thf=24, shf=-34, thb=-18, shb=-24)

# 浮空（AIR）：整体后仰（rot 由帧集给），四肢张开乱舞
AIR_FLAIL = P(torso=-34, head=-18, uaf=-118, laf=58, sword=-26, uab=138, lab=-28, thf=46, shf=-44, thb=-36, shb=-26)
AIR_FLAIL2 = P(torso=-22, head=-10, uaf=-88, laf=66, sword=-40, uab=108, lab=-16, thf=24, shf=-72, thb=-16, shb=-48)

# 倒地（DOWN）：躺平（rot=90），四肢摊开
DOWN_LIE = P(torso=12, head=-16, uaf=-18, laf=74, sword=-52, uab=-72, lab=54, thf=22, shf=-64, thb=-10, shb=-34)
DOWN_LIE2 = P(torso=6, head=-8, uaf=-8, laf=62, sword=-60, uab=-58, lab=46, thf=16, shf=-52, thb=-4, shb=-26)

# 起身（GETUP）：撑地 → 单膝 → 站起
GETUP_PUSH = P(torso=52, head=24, uaf=-70, laf=76, sword=-30, uab=-52, lab=62, thf=84, shf=-112, thb=-30, shb=-78, h=10)
GETUP_KNEE = P(torso=36, head=16, uaf=-46, laf=64, sword=-40, uab=-40, lab=50, thf=76, shf=-104, thb=-34, shb=-70, h=4)

# 哥布林挥棒（ATTACK）：棒子抡到脑后 → 砸向地面 → 收棒
G_ATK_WIND = D(G_IDLE, torso=-18, head=-16, uaf=152, laf=28, sword=32, uab=-42, lab=42, thf=18, shf=-30, thb=-32, shb=-18, h=4)
G_ATK_HIT = D(G_IDLE, torso=46, head=18, uaf=88, laf=-12, sword=-32, uab=-72, lab=42, thf=62, shf=-72, thb=-48, shb=-18)
G_ATK_FOL = D(G_ATK_HIT, torso=36, uaf=74, sword=-40)

# 剑魂「拔刀斩」：收刀入鞘（蓄） → 拔刀横斩 → 收势
QD_WIND = P(torso=30, head=8, uaf=-40, laf=60, sword=-70, uab=-30, lab=50, thf=40, shf=-70, thb=-20, shb=-40)
QD_DRAW = P(torso=40, head=14, uaf=95, laf=0, sword=0, uab=-72, lab=30, thf=58, shf=-56, thb=-44, shb=-14)
QD_END = P(torso=20, head=4, uaf=60, laf=24, sword=-14, uab=-40, lab=42, thf=32, shf=-44, thb=-24, shb=-26)

# 剑魂「连突刺」：剑端平的，连续前刺
TH_READY = P(torso=25, head=2, uaf=60, laf=-20, sword=50, uab=-38, lab=44, thf=35, shf=-55, thb=-25, shb=-30)
TH_STAB = P(torso=38, head=8, uaf=85, laf=-15, sword=25, uab=-86, lab=20, thf=56, shf=-36, thb=-46, shb=-10)
TH_STAB2 = P(torso=32, head=4, uaf=78, laf=-18, sword=32, uab=-80, lab=24, thf=50, shf=-42, thb=-40, shb=-14)


class Clip:
    def __init__(self, name, dur, keys=None, hits=(), move=(), trail=None, events=(), popup=None, proc=None, slot=None):
        self.name, self.dur, self.keys, self.hits, self.move = name, dur, keys, list(hits), list(move)
        self.trail, self.events, self.popup, self.proc, self.slot = trail, list(events), popup, proc, slot


def clip_pose(clip, t):
    if clip.proc:
        return clip.proc(t)
    keys = clip.keys
    if t <= keys[0][0]:
        return dict(keys[0][1])
    for i in range(1, len(keys)):
        f1, p1, e = keys[i]
        if t <= f1:
            f0, p0, _ = keys[i - 1]
            u = EASE[e]((t - f0) / max(1e-6, f1 - f0))
            return {k: p0[k] + (p1[k] - p0[k]) * u for k in p0}
    return dict(keys[-1][1])


def idle_proc(t):
    s = math.sin(G.sim * 0.12)
    return P(torso=8 + 1.5 * s, uaf=25 + 2 * s, uab=-15 - 2 * s)


def run_proc(t):
    p = PL.run_phase
    return P(torso=22, head=-10,
             thf=8 + 42 * math.sin(p), shf=-22 - 48 * max(0.0, math.cos(p)),
             thb=8 + 42 * math.sin(p + math.pi), shb=-22 - 48 * max(0.0, math.cos(p + math.pi)),
             uaf=-35 + 8 * math.sin(p), laf=22, sword=-45,
             uab=40 * math.sin(p), lab=55)


CLIPS = {
    "A1": Clip("A1", 12, [(0, A1_START, "lin"), (2, D(A1_START, uaf=186), "io"), (4, A1_HIT, "out"), (6, A1_FOL, "out"), (12, A1_END, "io")],
               hits=[dict(f=4, x0=-4, x1=76, hmax=112, dmg=(1180, 1560), kind="stun", stop=4, shake=1.8)],
               move=[(1, 4, 4.4)], trail=(1, 7)),
    "A2": Clip("A2", 12, [(0, A1_END, "lin"), (2, D(A1_END, torso=26, uaf=20, laf=6, sword=-20), "io"), (4, A2_HIT, "out"),
                          (6, D(A2_HIT, uaf=180, sword=24), "out"), (12, A2_END, "io")],
               hits=[dict(f=4, x0=-4, x1=72, hmax=112, dmg=(1260, 1680), kind="stun", stop=4, shake=1.8)],
               move=[(1, 4, 3.2)], trail=(1, 7)),
    "A3": Clip("A3", 18, [(0, A2_END, "lin"), (4, A3_WIND, "io"), (7, A3_HIT, "out"), (9, D(A3_HIT, uaf=58, sword=14), "out"), (18, BASE, "io")],
               hits=[dict(f=7, x0=-8, x1=92, hmax=112, dmg=(2600, 3400), kind="knock", stop=6, shake=5)],
               move=[(5, 8, 6.8)], trail=(4, 10), events=[(7, "crescent", None)]),
    "UPPER": Clip("UPPER", 18, [(0, BASE, "lin"), (4, UP_CROUCH, "io"), (7, UP_HIT, "out"), (9, D(UP_HIT, uaf=190, sword=12, h=24), "out"), (18, BASE, "io")],
                  hits=[dict(f=7, x0=-4, x1=68, hmax=60, dmg=(2000, 2600), kind="launch", power=13.6, stop=5, shake=3.5)],
                  move=[(3, 6, 3.6)], trail=(3, 9), popup="上挑", slot=0),
    "GW": Clip("GW", 28, [(0, BASE, "lin"), (5, GW_UP, "io"), (8, GW_SLAM, "out"), (22, GW_SLAM, "lin"), (28, BASE, "io")],
               trail=(5, 9), events=[(8, "gw", None)], popup="地裂波", slot=1),
    "DASH": Clip("DASH", 32, [(0, BASE, "lin"), (5, D_CROUCH, "io"), (7, D_GO, "out"), (16, D_GO, "lin"), (22, D_END, "io"), (32, BASE, "io")],
                 move=[(7, 16, 13.0)], trail=(6, 9), events=[(20, "turn", None), (25, "xslash", None)], popup="影突·斩", slot=2),
    # 剑魂技能（preview 剧本没演，实机 SKILL 状态要用）
    "QD": Clip("QD", 20, [(0, BASE, "lin"), (6, QD_WIND, "io"), (9, QD_DRAW, "out"), (12, D(QD_DRAW, uaf=110, sword=10), "out"),
                          (16, QD_END, "io"), (20, BASE, "io")],
               hits=[dict(f=9, x0=-10, x1=96, hmax=120, dmg=(3600, 4600), kind="knock", stop=8, shake=5)], trail=(8, 12), popup="拔刀斩", slot=3),
    "THRUST": Clip("THRUST", 16, [(0, BASE, "lin"), (2, TH_STAB, "out"), (4, TH_READY, "io"), (5, TH_STAB2, "out"), (7, TH_READY, "io"),
                                  (8, TH_STAB, "out"), (11, TH_READY, "io"), (16, BASE, "io")],
                   hits=[dict(f=2, x0=-4, x1=64, hmax=104, dmg=(900, 1300), kind="stun", stop=3, shake=2),
                         dict(f=5, x0=-4, x1=64, hmax=104, dmg=(900, 1300), kind="stun", stop=3, shake=2),
                         dict(f=8, x0=-4, x1=70, hmax=104, dmg=(1100, 1500), kind="knock", stop=4, shake=3)],
                   trail=(1, 9), popup="连突刺", slot=3),
}


# ---------------------------------------------------------------- 实机状态帧集
# game/scripts/player.gd、monster.gd 的状态机（St 枚举）→ 逐帧采样参数。
# tools/bake_game_assets.py 只调用 state_frames()，自己不复述任何美术细节。
#
# 帧序列里每一项：
#   pose / h / rot / grounded   solve + place 的输入（h 是离地抬升，实机的物理高度由 CharacterBody2D 负责）
#   tnow / speed                传给 draw_player，驱动围巾与衣摆的摆动
#   ticks                       该帧占几个实机物理帧（实机 60fps，preview 是 30fps，故默认 2）
FPS_GAME = 60
FPS_BAKE = 30
TICKS = FPS_GAME // FPS_BAKE


def _fr(pose, h=None, rot=0.0, grounded=True, tnow=0.0, speed=0.0, ticks=TICKS):
    return dict(pose=pose, h=(pose.get("h", 0.0) if h is None else float(h)), rot=float(rot),
                grounded=grounded, tnow=float(tnow), speed=float(speed), ticks=int(ticks))


def _clip_frames(clip):
    """按 preview 的 player_step 时间轴逐帧采样（t = 1..dur），并复现速度插值（围巾/衣摆幅度）。"""
    out, sp = [], 0.0
    for i in range(clip.dur):
        t = i + 1
        moving = False
        for f0, f1, vx in clip.move:
            if f0 < t <= f1:
                sp = lerp(sp, min(8.0, vx), 0.6)
                moving = True
        if not moving:
            sp *= 0.8
        out.append(_fr(clip_pose(clip, t), tnow=t, speed=sp))
    return out


def _key_frames(keys, speed=0.0, ticks=TICKS):
    """关键帧表 → 逐帧序列（t = 1..末帧，和 clip_pose 同一套插值）。"""
    c = Clip("tmp", keys[-1][0], keys)
    return [_fr(clip_pose(c, t), tnow=t, speed=speed, ticks=ticks) for t in range(1, keys[-1][0] + 1)]


def _pose_frames(poses, ticks=8, rot=0.0, grounded=True):
    """直接给定姿势序列（不插值），每帧占 ticks 个物理帧。"""
    return [_fr(p, tnow=i * ticks // TICKS, rot=rot, grounded=grounded, ticks=ticks)
            for i, p in enumerate(poses)]


def _blend(a, b, u):
    return {k: a[k] + (b[k] - a[k]) * u for k in a}


def _idle_frames(n=26, ticks=4):
    """待机循环：idle_proc 读的是全局 G.sim，这里让相位在 n 帧内正好走满一整圈 → 首尾无缝。

    相位整圈 = preview 的 52 帧（0.12 rad/帧 ≈ 1.75s）；这里采 26 个样、每样显示 4 个物理帧，
    呼吸周期与 preview 一致，帧条宽度又能塞进单张纹理。
    """
    out, old = [], G.sim
    try:
        for i in range(n):
            G.sim = i * (2 * math.pi / 0.12) / n
            out.append(_fr(idle_proc(0), tnow=i * ticks // TICKS, ticks=ticks))
    finally:
        G.sim = old
    return out


def _run_frames(n=15):
    """奔跑循环：run_proc 读全局 PL.run_phase；preview 是 0.42/帧（≈15 帧一圈），这里走满 2π。"""
    out, old = [], PL.run_phase
    try:
        for i in range(n):
            PL.run_phase = 2 * math.pi * i / n
            out.append(_fr(run_proc(0), tnow=i, speed=6.4))
    finally:
        PL.run_phase = old
    return out


def _air_frames(poses, n=6, ticks=3, rot0=-24.0, rotk=8.0):
    """浮空循环：整体后仰 + 四肢乱舞，首尾无缝。"""
    return [_fr(poses[i % len(poses)], rot=rot0 + rotk * math.sin(2 * math.pi * i / n), grounded=False,
                tnow=i * TICKS, ticks=ticks) for i in range(n)]


def _getup_frames(n=12):
    """倒地 → 起身：撑地 → 单膝 → 站起；整体旋转从 90° 回正。"""
    c = Clip("tmp", n, [(0, DOWN_LIE, "lin"), (3, GETUP_PUSH, "out"), (7, GETUP_KNEE, "io"), (n, BASE, "io")])
    return [_fr(clip_pose(c, t), rot=90.0 * (1.0 - EASE["io"](t / n)), tnow=t * TICKS, ticks=3)
            for t in range(1, n + 1)]


def _gob_idle_frames(n=42):
    """哥布林待机：preview 是 s = sin(e.t * 0.15)，n 帧走满一整圈 → 无缝。"""
    out = []
    for i in range(n):
        s = math.sin(2 * math.pi * i / n)
        out.append(_fr(D(G_IDLE, torso=G_IDLE["torso"] + 3 * s, uaf=G_IDLE["uaf"] + 6 * s), tnow=i))
    return out


def _gob_walk_frames(n=21, lean=7.0, swing=20.0):
    """哥布林走/跑：preview 的 walk 姿势，相位在 n 帧内走满一整圈。"""
    out = []
    for i in range(n):
        ph = 2 * math.pi * i / n
        out.append(_fr(D(G_IDLE, torso=G_IDLE["torso"] + lean + 3 * math.sin(ph * 2),
                         thf=G_IDLE["thf"] + swing * math.sin(ph), shf=G_IDLE["shf"] - 22 * max(0.0, math.cos(ph)),
                         thb=G_IDLE["thb"] + swing * math.sin(ph + math.pi),
                         shb=G_IDLE["shb"] - 22 * max(0.0, math.cos(ph + math.pi))), tnow=i))
    return out


def _gob_down_frames():
    """哥布林倒地：和 preview 一样 rot=90 躺平。"""
    return _pose_frames([D(G_DOWN, torso=-8, uaf=150), G_DOWN, D(G_DOWN, uaf=168), G_DOWN], ticks=8, rot=90.0)


def _gob_getup_frames(n=8):
    return [_fr(_blend(G_DOWN, G_IDLE, EASE["io"](i / (n - 1))),
                rot=90.0 * (1 - i / (n - 1)), tnow=i * TICKS, ticks=2) for i in range(n)]


def _player_state(name):
    """玩家状态 → (帧序列, 是否循环)。动作名与 player.gd 的 move_name / St 枚举对齐。"""
    if name == "idle":
        return _idle_frames(), True
    if name == "run":
        return _run_frames(15), True
    if name == "jump":
        return _key_frames([(0, BASE, "lin"), (3, JUMP_TAKEOFF, "io"), (7, JUMP_RISE, "out"),
                            (11, D(JUMP_RISE, torso=-2, thf=50, shf=-92), "io"), (14, JUMP_FALL, "io"),
                            (20, D(JUMP_FALL, torso=22, thf=42, shf=-32), "io")]), False
    if name == "back_dash":
        return _key_frames([(0, BASE, "lin"), (1, BD_COIL, "io"), (3, BD_LEAN, "out"), (5, BD_HOP, "lin"),
                            (7, BD_LEAN, "io"), (9, BD_LAND, "out"), (10, BASE, "io")]), False
    if name == "guard":
        return _pose_frames([GUARD, GUARD_HI, GUARD, GUARD_LOW], ticks=10), True
    if name == "hit":
        return _key_frames([(0, HIT_RECOIL, "lin"), (2, HIT_RECOIL, "lin"), (5, HIT_SAG, "io"), (8, BASE, "io")]), False
    if name == "air":
        return _air_frames([AIR_FLAIL, AIR_FLAIL2]), True
    if name == "down":
        return _pose_frames([D(DOWN_LIE, uaf=-40, thf=34, torso=22), DOWN_LIE, DOWN_LIE2, DOWN_LIE],
                            ticks=8, rot=90.0), False
    if name == "getup":
        return _getup_frames(), False
    if name == "attack1":
        return _clip_frames(CLIPS["A1"]), False
    if name == "attack2":
        return _clip_frames(CLIPS["A2"]), False
    if name == "attack3":
        return _clip_frames(CLIPS["A3"]), False
    if name == "upper":
        return _clip_frames(CLIPS["UPPER"]), False
    if name == "rage_slash":                      # 狂战士怒斩 ≈ preview 的地裂波（同为蓄力重击）
        return _clip_frames(CLIPS["GW"]), False
    if name == "quick_draw":                      # 剑魂拔刀斩
        return _clip_frames(CLIPS["QD"]), False
    if name == "thrust":                          # 剑魂连突刺
        return _clip_frames(CLIPS["THRUST"]), False
    return None


def _monster_state(name):
    """哥布林状态 → (帧序列, 是否循环)。名字与 monster.gd 的 St 枚举对齐。"""
    if name == "idle":
        return _gob_idle_frames(42), True
    if name == "patrol":
        return _gob_walk_frames(21, lean=7.0, swing=20.0), True
    if name == "chase":
        return _gob_walk_frames(14, lean=15.0, swing=27.0), True
    if name == "attack":
        return _key_frames([(0, G_IDLE, "lin"), (6, G_ATK_WIND, "io"), (7, D(G_ATK_WIND, uaf=158), "lin"),
                            (8, G_ATK_HIT, "out"), (11, G_ATK_FOL, "out"), (13, G_IDLE, "io")]), False
    if name == "hit":
        return _key_frames([(0, G_IDLE, "lin"), (3, G_HIT, "out"), (5, G_HIT, "lin"), (9, G_IDLE, "io")]), False
    if name == "air":
        return _air_frames([G_AIR, D(G_AIR, uaf=176, thf=30, thb=-30)], rot0=-14.0, rotk=12.0), True
    if name == "down":
        return _gob_down_frames(), False
    if name == "getup":
        return _gob_getup_frames(), False
    return None


PLAYER_STATE_NAMES = ["idle", "run", "jump", "back_dash", "guard", "hit", "air", "down", "getup",
                      "attack1", "attack2", "attack3", "upper", "rage_slash", "quick_draw", "thrust"]
MONSTER_STATE_NAMES = ["idle", "patrol", "chase", "attack", "hit", "air", "down", "getup"]


def state_frames(who, name):
    """实机帧条的唯一入口：返回 (帧序列, 是否循环)；未定义返回 None。"""
    st = _player_state(name) if who == "player" else _monster_state(name)
    return st


# ---------------------------------------------------------------- world state
class G:
    sim = 0
    fr = 0
    freeze = 0
    shake = 0.0
    flash = 0.0
    particles = []
    numbers = []
    popups = []
    fxs = []
    trail = []
    trail_id = 0
    afterimg = deque(maxlen=6)
    combo = 0
    combo_fr = -999
    target = None
    cooldown = {}
    snaps = {}
    hitlog = []
    done_at = None


class Enemy:
    def __init__(self, name, x, z, pal):
        self.name, self.x, self.z, self.pal = name, x, z, pal
        self.h = self.vx = self.vh = 0.0
        self.state, self.timer, self.rot, self.vspin = "idle", 0, 0.0, 0.0
        self.facing, self.flash, self.bounced, self.marked = -1, 0, False, False
        self.max_hp = self.hp = self.chip = 90000
        self.t = rng.random() * 100


class Player:
    def __init__(self):
        self.x, self.z, self.h, self.facing = 68.0, 64.0, 0.0, 1
        self.clip, self.t, self.action = None, 0, None
        self.blend_from, self.blend_len = None, 0
        self.run_phase, self.speed = 0.0, 0.0
        self.last_pose = dict(BASE)
        self.queue = deque()

    def pose(self, t=None):
        t = self.t if t is None else t
        p = clip_pose(self.clip, t)
        if self.blend_from is not None and t < self.blend_len:
            u = EASE["io"](max(0.0, t) / self.blend_len)
            p = {k: self.blend_from[k] + (p[k] - self.blend_from[k]) * u for k in p}
        return p


PL = Player()
E1 = Enemy("哥布林战士", 352, 56, GOB1)
E2 = Enemy("红皮哥布林", 412, 80, GOB2)
ENEMIES = [E1, E2]
IDLE_CLIP = lambda n: Clip("IDLE", n, proc=idle_proc)
RUN_CLIP = Clip("RUN", 10 ** 9, proc=run_proc)


def start_action(a):
    PL.action = a
    PL.blend_from = dict(PL.last_pose)
    PL.t = 0
    if a[0] == "idle":
        PL.clip, PL.blend_len = IDLE_CLIP(a[1]), 4
    elif a[0] == "runto":
        PL.clip, PL.blend_len = RUN_CLIP, 3
    else:
        PL.clip, PL.blend_len = CLIPS[a[1]], 3
        G.trail_id += 1
        if PL.clip.popup:
            G.popups.append(dict(text=PL.clip.popup, born=G.fr))
        if PL.clip.slot is not None:
            G.cooldown[PL.clip.slot] = G.fr


def next_action():
    if PL.queue:
        start_action(PL.queue.popleft())
    else:
        start_action(("idle", 10 ** 9))
        if G.done_at is None:
            G.done_at = G.fr + 50


# ---------------------------------------------------------------- combat
def enemy_center(e):
    return e.x, GROUND0 + e.z - e.h - 24


def enemy_react(e, kind, dirx, power=None):
    e.flash = 2
    if kind == "launch":
        e.state, e.vh, e.vx, e.bounced = "air", (power or 12.0), dirx * 0.5, False
        e.vspin = 13.0
    elif e.state == "air":
        e.vh = max(e.vh, 6.8 if kind == "knock" else 6.0)
        e.vx = dirx * (3.2 if kind == "knock" else 0.9)
        e.bounced = False
    elif e.state == "down":
        e.state, e.vh, e.vx, e.bounced = "air", 5.2, dirx * 1.0, True
    else:
        e.state = "hit"
        e.timer = 24 if kind == "knock" else 18
        e.vx = dirx * (4.8 if kind == "knock" else 1.8)
        e.facing = -dirx


def land_hit(e, dmg_rng, kind, stop, dirx, power=None, shake=0.0, crit_ch=0.22, spark=1.0, big=False):
    dmg = rng.randint(*dmg_rng)
    crit = rng.random() < crit_ch
    if crit:
        dmg = int(dmg * 1.5)
    enemy_react(e, kind, dirx, power)
    e.hp = max(1, e.hp - dmg)
    cx, cy = enemy_center(e)
    spawn_sparks(cx, cy, dirx, spark * (1.4 if crit else 1.0))
    G.fxs.append(dict(type="flash", x=cx, y=cy, born=G.fr, life=2, r=9 if big else 7))
    G.numbers.append(dict(x=cx + rng.uniform(-8, 8), y=cy - 20, val=dmg, crit=crit, born=G.fr))
    G.combo += 1
    G.combo_fr = G.fr
    G.freeze = max(G.freeze, stop)
    G.shake = max(G.shake, shake)
    G.target = e
    G.hitlog.append((G.fr, PL.clip.name if PL.clip else "?", e.name, kind, dmg, crit))


def spawn_sparks(x, y, dirx, k=1.0):
    base = 0.0 if dirx > 0 else math.pi
    for _ in range(int(10 * k)):
        a = base + rng.uniform(-1.4, 1.4) if rng.random() < 0.75 else rng.uniform(0, 2 * math.pi)
        sp = rng.uniform(4.0, 11.0)
        G.particles.append(dict(kind="spark", x=x, y=y, vx=math.cos(a) * sp, vy=math.sin(a) * sp, life=rng.randint(5, 9),
                                age=0, col=(255, 250, 220) if rng.random() < 0.5 else (255, 200, 90)))
    for _ in range(int(6 * k)):
        a = base + rng.uniform(-1.0, 1.0)
        sp = rng.uniform(2.0, 6.0)
        G.particles.append(dict(kind="shard", x=x, y=y, vx=math.cos(a) * sp, vy=math.sin(a) * sp - 3.0, life=rng.randint(12, 20),
                                age=0, col=(255, 170, 90)))


def spawn_dust(x, y, n=4, spread=1.0):
    for _ in range(n):
        G.particles.append(dict(kind="dust", x=x + rng.uniform(-6, 6), y=y - rng.uniform(0, 4), vx=rng.uniform(-1.2, 1.2) * spread,
                                vy=-rng.uniform(0.2, 1.0), life=rng.randint(14, 22), age=0, col=(150, 140, 150)))


def do_event(name):
    p = PL
    if name == "crescent":
        sh = place(solve(p.pose(), PL_LEN), PL_LEN, p.x, GROUND0 + p.z, p.h + p.pose()["h"], p.facing)["sh"]
        G.fxs.append(dict(type="cres", x=sh[0], y=sh[1], f=p.facing, born=G.sim, life=8))
        G.snaps[G.fr + 1] = "combo_heavy"
    elif name == "gw":
        G.shake = max(G.shake, 10)
        tip = place(solve(p.pose(), PL_LEN), PL_LEN, p.x, GROUND0 + p.z, p.h, p.facing)["wtip"]
        G.fxs.append(dict(type="ring", x=tip[0], y=GROUND0 + p.z, born=G.sim, life=12))
        spawn_dust(tip[0], GROUND0 + p.z, 10, 2.5)
        for i in range(6):
            G.fxs.append(dict(type="spike", x=p.x + p.facing * (40 + i * 24), z=p.z, born=G.sim + i * 2, life=18, hit=False, f=p.facing))
        G.snaps[G.fr] = "skill_groundwave"
    elif name == "turn":
        p.facing = -p.facing
    elif name == "xslash":
        hit_any = False
        for e in ENEMIES:
            if e.marked:
                e.marked = False
                cx, cy = enemy_center(e)
                G.fxs.append(dict(type="xs", x=cx, y=cy, born=G.sim, life=12))
                dirx = 1 if e.x > p.x else -1
                land_hit(e, (5200, 6800), "launch", 8, dirx, power=8.8, shake=6, crit_ch=0.6, spark=1.3, big=True)
                hit_any = True
        if hit_any:
            G.flash = 0.32
            G.snaps[G.fr + 22] = "skill_dash_xslash"


def player_step():
    p = PL
    a = p.action
    moving = False
    if a[0] == "runto":
        tx, tz = a[1]()
        dx, dz = tx - p.x, tz - p.z
        if abs(dx) < 5 and abs(dz) < 3:
            near = min(ENEMIES, key=lambda e: abs(e.x - p.x) + abs(e.z - p.z) * 2, default=None)
            if near is not None:
                p.facing = -1 if near.x < p.x else 1
            p.last_pose = p.pose()
            next_action()
            return
        p.facing = 1 if dx > 0 else -1
        mvx = max(-6.4, min(6.4, dx))
        mvz = max(-2.4, min(2.4, dz))
        p.x += mvx
        p.z = max(48.0, min(92.0, p.z + mvz))
        p.run_phase += 0.42
        p.speed = lerp(p.speed, abs(mvx), 0.5)
        moving = True
        if p.t % 7 == 0:
            spawn_dust(p.x - p.facing * 6, GROUND0 + p.z, 2)
        p.t += 1
    else:
        clip = p.clip
        prev_x = p.x
        p.t += 1
        t = p.t
        for f0, f1, vx in clip.move:
            if f0 < t <= f1:
                p.x += vx * p.facing
                p.speed = lerp(p.speed, min(8.0, vx), 0.6)
                moving = True
        p.x = max(28, min(580, p.x))
        if clip.name == "DASH" and 7 < t <= 17:
            lo, hi = min(prev_x, p.x) - 8, max(prev_x, p.x) + 8
            for e in ENEMIES:
                if not e.marked and lo <= e.x <= hi and abs(e.z - p.z) <= 40 and e.h <= 120:
                    e.marked = True
                    land_hit(e, (900, 1200), "stun", 2, p.facing, shake=2, spark=0.8)
            if t % 2 == 0:
                G.afterimg.append([None, G.sim])
                G.particles.append(dict(kind="streak", x=p.x - p.facing * 16, y=GROUND0 + p.z - 44 - (t % 4) * 14,
                                        vx=-p.facing * 18, vy=0, life=5, age=0, col=(190, 215, 255)))
        for hd in clip.hits:
            if hd["f"] == t:
                hit = False
                for e in ENEMIES:
                    dx = (e.x - p.x) * p.facing
                    if hd["x0"] <= dx <= hd["x1"] and abs(e.z - p.z) <= 32 and e.h <= hd["hmax"]:
                        land_hit(e, hd["dmg"], hd["kind"], hd["stop"], p.facing, hd.get("power"), hd.get("shake", 0))
                        hit = True
                if not hit:
                    G.hitlog.append((G.fr, clip.name, "MISS", "", 0, False))
        for f, name, _ in clip.events:
            if f == t:
                do_event(name)
        p.last_pose = p.pose()
        if t >= clip.dur:
            next_action()
    if not moving:
        p.speed *= 0.8


def enemy_step(e):
    e.t += 1
    if e.flash > 0:
        e.flash -= 1
    if e.state == "idle":
        dxx = PL.x - e.x
        e.facing = -1 if dxx < 0 else 1
        if abs(dxx) > 60 and e.h <= 0:
            e.state = "walk"
    elif e.state == "walk":
        dxx = PL.x - e.x
        e.facing = -1 if dxx < 0 else 1
        if abs(dxx) <= 52:
            e.state = "idle"
        else:
            e.x += e.facing * 2.8
            if e.t % 9 == 0:
                spawn_dust(e.x - e.facing * 6, GROUND0 + e.z, 1)
    elif e.state == "hit":
        e.x += e.vx
        e.vx *= 0.82
        e.timer -= 1
        if e.timer <= 0:
            e.state = "idle"
    elif e.state == "air":
        e.x += e.vx
        e.h += e.vh
        e.vh -= 0.80
        e.rot = min(92.0, e.rot + e.vspin)
        if e.h <= 0:
            e.h = 0.0
            if not e.bounced and e.vh < -5.0:
                e.vh, e.bounced = 4.8, True
                spawn_dust(e.x, GROUND0 + e.z, 6, 1.5)
                G.shake = max(G.shake, 1.5)
            else:
                e.state, e.timer, e.vh, e.vx, e.rot = "down", 36, 0.0, 0.0, 90.0
                spawn_dust(e.x, GROUND0 + e.z, 5)
    elif e.state == "down":
        e.timer -= 1
        if e.timer <= 0:
            e.state, e.timer = "getup", 12
    elif e.state == "getup":
        e.timer -= 1
        e.rot = 90.0 * max(0, e.timer) / 12.0
        if e.timer <= 0:
            e.state, e.rot = "idle", 0.0
    e.x = max(32, min(576, e.x))
    e.z = max(48.0, min(92.0, e.z))


def fx_sim_step():
    for fx in G.fxs:
        if fx["type"] == "spike" and not fx["hit"] and G.sim - fx["born"] >= 1:
            fx["hit"] = True
            spawn_dust(fx["x"], GROUND0 + fx["z"], 3, 1.5)
            for e in ENEMIES:
                if abs(e.x - fx["x"]) <= 20 and abs(e.z - fx["z"]) <= 36 and e.h <= 88:
                    land_hit(e, (900, 1300), "launch", 2, fx["f"], power=8.0, shake=2.5, crit_ch=0.15, spark=0.7)
    G.fxs = [fx for fx in G.fxs if not (fx.get("born", 0) + fx.get("life", 0) < (G.fr if fx["type"] == "flash" else G.sim) - 1)]


def sample_trail():
    p = PL
    c = p.clip
    if c is None or c.trail is None or not (c.trail[0] <= p.t <= c.trail[1]):
        return
    for k in range(1, 5):
        tt = p.t - 1 + k / 4.0
        pose = p.pose(tt)
        q = place(solve(pose, PL_LEN), PL_LEN, p.x, GROUND0 + p.z, p.h + pose["h"], p.facing)
        base = lerp2(q["hdf"], q["wtip"], 0.3)
        G.trail.append(dict(b=base, t=q["wtip"], birth=G.sim - 1 + k / 4.0, id=G.trail_id))


# ---------------------------------------------------------------- render world
def char_layer(drawfn, flash=0.0):
    img = Image.new("RGBA", (W * 2, H * 2), (0, 0, 0, 0))
    drawfn(ImageDraw.Draw(img))
    arr = finish_layer(np.array(img), flash, iters=2)
    arr = np.array(Image.fromarray(arr).resize((W, H), Image.BILINEAR))
    return arr


def enemy_pose_and_place(e):
    s = math.sin(e.t * 0.15)
    if e.state == "idle":
        pose, rot, grounded = D(G_IDLE, torso=G_IDLE["torso"] + 3 * s, uaf=G_IDLE["uaf"] + 6 * s), 0.0, True
    elif e.state == "walk":
        ph = e.t * 0.3
        pose = D(G_IDLE, torso=G_IDLE["torso"] + 7 + 3 * math.sin(ph * 2),
                 thf=G_IDLE["thf"] + 20 * math.sin(ph), shf=G_IDLE["shf"] - 22 * max(0.0, math.cos(ph)),
                 thb=G_IDLE["thb"] + 20 * math.sin(ph + math.pi), shb=G_IDLE["shb"] - 22 * max(0.0, math.cos(ph + math.pi)))
        rot, grounded = 0.0, True
    elif e.state == "hit":
        u = min(1.0, e.timer / 10.0)
        pose = {k: lerp(G_IDLE[k], G_HIT[k], u) for k in G_IDLE}
        rot, grounded = 0.0, True
    elif e.state == "air":
        pose, rot, grounded = D(G_AIR, uaf=G_AIR["uaf"] + 15 * math.sin(e.t * 0.6)), e.rot, False
    elif e.state == "down":
        pose, rot, grounded = G_DOWN, 90.0, True
    else:
        u = e.rot / 90.0
        pose = {k: lerp(G_IDLE[k], G_DOWN[k], u) for k in G_IDLE}
        rot, grounded = e.rot, True
    pts = solve(pose, GB_LEN, rot)
    jit = (1 if G.fr % 2 else -1) if (G.freeze > 0 and e.flash > 0) else 0
    return place(pts, GB_LEN, e.x + jit, GROUND0 + e.z, e.h, e.facing, grounded, rot)


def draw_trails(d):
    keep = []
    for s in G.trail:
        if G.sim - s["birth"] <= 4.5:
            keep.append(s)
    G.trail = keep
    for i in range(len(keep) - 1):
        a, b = keep[i], keep[i + 1]
        if a["id"] != b["id"]:
            continue
        age = G.sim - (a["birth"] + b["birth"]) / 2
        k = max(0.0, 1 - age / 4.5)
        # 三层半透明刀光：宽淡外层 → 中层 → 白芯
        d.polygon([a["b"], a["t"], b["t"], b["b"]], fill=(70, 120, 255, int(85 * k)))
        am = lerp2(a["b"], a["t"], 0.5)
        bm = lerp2(b["b"], b["t"], 0.5)
        d.polygon([lerp2(a["b"], am, 0.5), lerp2(a["t"], am, 0.5), lerp2(b["t"], bm, 0.5), lerp2(b["b"], bm, 0.5)],
                  fill=(170, 205, 255, int(165 * k)))
        d.line([a["t"], b["t"]], fill=(255, 255, 255, int(215 * k)), width=4)


def crescent_poly(cx, cy, f, a0, a1, r, th, n=16):
    outer, inner = [], []
    for i in range(n + 1):
        u = i / n
        a = math.radians(a0 + (a1 - a0) * u)
        w = th * math.sin(math.pi * u)
        outer.append((cx + math.sin(a) * r * f, cy + math.cos(a) * r))
        inner.append((cx + math.sin(a) * (r - w) * f, cy + math.cos(a) * (r - w)))
    return outer + inner[::-1]


def render_world():
    world = BG.copy()
    glow = np.zeros((H, W, 3), np.float32)
    fximg = Image.new("RGB", (W, H))
    fd = ImageDraw.Draw(fximg)

    # torches
    flame_img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    fmd = ImageDraw.Draw(flame_img)
    for tx, ty in TORCHES:
        fl = 0.8 + 0.2 * math.sin(G.fr * 0.9 + tx) + rng.uniform(-0.08, 0.08)
        add_glow(glow, tx, ty - 8, 22, (255, 150, 70), 0.08 * fl)
        hgt = 14 + rng.uniform(-2, 3)
        fmd.polygon([(tx - 6, ty), (tx + 6, ty), (tx + rng.uniform(-2, 2), ty - hgt)], fill=(235, 100, 30, 255))
        fmd.polygon([(tx - 3.2, ty), (tx + 3.2, ty), (tx + rng.uniform(-1.2, 1.2), ty - hgt * 0.6)], fill=(255, 215, 130, 255))
        if rng.random() < 0.3:
            G.particles.append(dict(kind="ember", x=tx + rng.uniform(-4, 4), y=ty - hgt, vx=rng.uniform(-0.4, 0.4), vy=-rng.uniform(0.6, 1.4),
                                    life=rng.randint(10, 20), age=0, col=(255, 150, 60)))
    comp_layer(world, np.array(flame_img))
    # floor overlay: shadows & dust
    ov = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    od = ImageDraw.Draw(ov)
    chars = [("P", PL)] + [("E", e) for e in ENEMIES]
    for kind, c in chars:
        h = c.h + (PL.pose()["h"] if kind == "P" else 0)
        w = 40 * (1 - min(h, 140) / 280)
        y = GROUND0 + c.z
        od.ellipse([c.x - w / 2, y - 5, c.x + w / 2, y + 5], fill=(0, 0, 0, 120))
    for pt in G.particles:
        if pt["kind"] == "dust":
            a = int(110 * (1 - pt["age"] / pt["life"]))
            r = 3 + pt["age"] * 0.36
            od.ellipse([pt["x"] - r, pt["y"] - r, pt["x"] + r, pt["y"] + r], fill=(*pt["col"], a))
    comp_layer(world, np.array(ov))

    # ground-wave spikes (props)
    props = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    pd = ImageDraw.Draw(props)
    has_prop = False
    for fx in G.fxs:
        if fx["type"] != "spike":
            continue
        age = G.sim - fx["born"]
        if age < 0:
            continue
        k = min(1.0, (age + 1) / 2.5) * (1.0 if age < 11 else max(0.0, 1 - (age - 11) / 6))
        if k <= 0:
            continue
        has_prop = True
        x, y = fx["x"], GROUND0 + fx["z"]
        hgt = 34 * k
        pd.polygon([(x - 12, y + 2), (x - 6, y - hgt * 0.55), (x - 2, y - hgt), (x + 3, y - hgt * 0.75), (x + 6, y - hgt * 0.9),
                    (x + 12, y + 2)], fill=(82, 70, 96, 255))
        pd.line([(x - 2, y - hgt), (x - 4, y)], fill=(120, 108, 136, 255), width=2)
    if has_prop:
        comp_layer(world, finish_layer(np.array(props)))

    # afterimages
    for item in list(G.afterimg):
        if item[0] is None:
            item[0] = player_layer()
        age = G.sim - item[1]
        a = max(0.0, 0.55 * (1 - age / 12))
        if a > 0:
            comp_layer(world, item[0], a, tint=(110, 120, 255), tint_k=0.7)

    # characters
    order = sorted(chars, key=lambda kc: kc[1].z)
    for kind, c in order:
        if kind == "P":
            comp_layer(world, player_layer())
            pose = PL.pose()
            q = place(solve(pose, PL_LEN), PL_LEN, PL.x, GROUND0 + PL.z, PL.h + pose["h"], PL.facing)
            add_glow(glow, q["hdb"][0], q["hdb"][1], 10, (255, 40, 60), 0.3 + 0.1 * math.sin(G.fr * 0.3))
            add_glow(glow, q["elb"][0], q["elb"][1], 8, (255, 40, 60), 0.15)
        else:
            q = enemy_pose_and_place(c)
            comp_layer(world, char_layer(lambda d, q=q, c=c: draw_goblin(d, q, c.facing, c.pal), flash=0.35 if c.flash > 0 else 0.0))

    # beam layer: 能量光柱 / 十字斩（角色前层，普通 alpha 混合）
    beam = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    bd = ImageDraw.Draw(beam)
    for fx in G.fxs:
        if fx["type"] == "spike":
            age = G.sim - fx["born"]
            if age < 0:
                continue
            gk = min(1.0, (age + 1) / 2.5)
            ek = max(0.0, 1 - age / 12)
            if ek <= 0:
                continue
            x, y = fx["x"], GROUND0 + fx["z"]
            hgt = 34 * gk
            bd.rectangle([x - 2, y - hgt * 1.8, x + 2, y], fill=(130, 55, 230, int(210 * ek)))
            bd.rectangle([x - 1, y - hgt * 2.0, x + 1, y], fill=(225, 200, 255, int(190 * ek)))
            add_glow(glow, x, y - hgt, 16, (160, 70, 255), 0.10 * ek)
        elif fx["type"] == "xs":
            age = G.sim - fx["born"]
            k = max(0.0, 1 - max(0, age - 3) / (fx["life"] - 3))
            ln = 48 * min(1.0, (age + 1) / 3)
            x, y = fx["x"], fx["y"]
            for sx in (1, -1):
                bd.line([(x - ln * sx, y - ln * 0.8), (x + ln * sx, y + ln * 0.8)], fill=(120, 180, 255, int(215 * k)), width=8)
                bd.line([(x - ln * sx, y - ln * 0.8), (x + ln * sx, y + ln * 0.8)], fill=(255, 255, 255, int(225 * k)), width=2)
            add_glow(glow, x, y, 20, (140, 190, 255), 0.18 * k)
    draw_trails(bd)
    comp_layer(world, np.array(beam.filter(ImageFilter.GaussianBlur(1))))

    # fx
    for fx in G.fxs:
        t = fx["type"]
        if t == "cres":
            age = G.sim - fx["born"]
            k = max(0.0, 1 - age / fx["life"])
            r = 50 + age * 4
            fd.polygon(crescent_poly(fx["x"], fx["y"], fx["f"], 218, 52, r + 14, 32 * k + 6), fill=scalec((40, 95, 205), k * 0.55))
            fd.polygon(crescent_poly(fx["x"], fx["y"], fx["f"], 215, 55, r, 16 * k + 4), fill=scalec((95, 165, 255), k))
            fd.polygon(crescent_poly(fx["x"], fx["y"], fx["f"], 208, 62, r - 4, 6 * k + 2), fill=scalec((245, 250, 255), k))
        elif t == "ring":
            age = G.sim - fx["born"]
            k = max(0.0, 1 - age / fx["life"])
            r = 10 + age * 8
            fd.ellipse([fx["x"] - r, fx["y"] - r * 0.28, fx["x"] + r, fx["y"] + r * 0.28], outline=scalec((210, 130, 255), k), width=4)
            add_glow(glow, fx["x"], fx["y"], 20, (180, 90, 255), 0.3 * k)
        elif t == "flash":
            age = G.fr - fx["born"]
            k = max(0.0, 1 - age / fx["life"])
            r = fx["r"] * (1 + age * 0.2)
            x, y = fx["x"], fx["y"]
            fd.line([(x - r * 1.7, y), (x + r * 1.7, y)], fill=scalec((255, 255, 245), k), width=4)
            fd.line([(x, y - r * 0.75), (x, y + r * 0.75)], fill=scalec((255, 255, 245), k), width=4)
            d45 = r * 0.6
            fd.line([(x - d45, y - d45), (x + d45, y + d45)], fill=scalec((255, 232, 170), k), width=2)
            fd.line([(x - d45, y + d45), (x + d45, y - d45)], fill=scalec((255, 232, 170), k), width=2)
            circ(fd, (x, y), max(1.6, r * 0.4), scalec((255, 255, 255), k))
            fd.ellipse([x - r * 2.0, y - r * 0.55, x + r * 2.0, y + r * 0.55], outline=scalec((255, 200, 120), k * 0.7), width=2)
            add_glow(glow, x, y, 10, (255, 220, 160), 0.2 * k)
    for pt in G.particles:
        k = max(0.0, 1 - pt["age"] / pt["life"])
        if pt["kind"] == "spark":
            fd.line([(pt["x"], pt["y"]), (pt["x"] - pt["vx"] * 1.6, pt["y"] - pt["vy"] * 1.6)], fill=scalec(pt["col"], k), width=2)
        elif pt["kind"] == "streak":
            fd.line([(pt["x"], pt["y"]), (pt["x"] - pt["vx"] * 1.6, pt["y"])], fill=scalec(pt["col"], k), width=2)
        elif pt["kind"] in ("shard", "ember"):
            fd.point((pt["x"], pt["y"]), fill=scalec(pt["col"], k))
    fxarr = np.array(fximg).astype(np.float32)
    bloom = np.array(fximg.filter(ImageFilter.GaussianBlur(6))).astype(np.float32)
    world += fxarr + bloom * 0.5 + glow * 255
    if G.flash > 0:
        world += G.flash * 100
    world *= VIGNETTE
    return np.clip(world, 0, 255).astype(np.uint8)


def player_layer():
    pose = PL.pose()
    q = place(solve(pose, PL_LEN), PL_LEN, PL.x, GROUND0 + PL.z, PL.h + pose["h"], PL.facing)
    return char_layer(lambda d: draw_player(d, q, PL.facing, G.sim, PL.speed))


def update_particles():
    alive = []
    for pt in G.particles:
        pt["age"] += 1
        if pt["age"] >= pt["life"]:
            continue
        pt["x"] += pt["vx"]
        pt["y"] += pt["vy"]
        if pt["kind"] == "spark":
            pt["vx"] *= 0.82
            pt["vy"] *= 0.82
        elif pt["kind"] == "shard":
            pt["vy"] += 0.5
        elif pt["kind"] == "dust":
            pt["vx"] *= 0.92
        alive.append(pt)
    G.particles = alive


# ---------------------------------------------------------------- HUD
PORTRAIT_PATH = os.path.join(_PROJ, "art", "characters", "portrait_hero.png")


def make_icon(kind, c1, c2, sz=46):
    yy, xx = np.mgrid[0:sz, 0:sz].astype(np.float32)
    t = ((xx + yy) / (2 * sz))[..., None]
    arr = np.array(c1, np.float32) * (1 - t) + np.array(c2, np.float32) * t
    img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8)).convert("RGBA")
    d = ImageDraw.Draw(img)
    wcol = (255, 255, 255, 255)
    if kind == "up":
        d.polygon(crescent_poly(sz * 0.35, sz * 0.62, 1, 20, 180, sz * 0.42, 9), fill=wcol)
    elif kind == "wave":
        for i in range(4):
            x = 6 + i * 10
            hgt = 12 + i * 5
            d.polygon([(x, sz - 6), (x + 4, sz - 6 - hgt), (x + 8, sz - 6)], fill=(235, 210, 255, 255))
        d.line([(4, sz - 6), (sz - 4, sz - 6)], fill=wcol, width=2)
    elif kind == "dash":
        d.polygon([(8, sz / 2 - 4), (sz - 14, sz / 2 - 4), (sz - 14, sz / 2 - 10), (sz - 4, sz / 2), (sz - 14, sz / 2 + 10),
                   (sz - 14, sz / 2 + 4), (8, sz / 2 + 4)], fill=wcol)
        for y in (10, sz - 10):
            d.line([(4, y), (20, y)], fill=(200, 220, 255, 255), width=2)
    elif kind == "cross":
        d.line([(10, 10), (sz - 10, sz - 10)], fill=wcol, width=5)
        d.line([(sz - 10, 10), (10, sz - 10)], fill=wcol, width=5)
    elif kind == "sword":
        d.line([(10, sz - 10), (sz - 8, 8)], fill=wcol, width=5)
        d.line([(8, sz - 22), (22, sz - 8)], fill=(240, 200, 90, 255), width=4)
    elif kind == "aura":
        d.ellipse([10, 10, sz - 10, sz - 10], outline=wcol, width=4)
        d.ellipse([18, 18, sz - 18, sz - 18], fill=(255, 120, 120, 255))
    elif kind in ("hp", "mp"):
        col = (230, 50, 60, 255) if kind == "hp" else (60, 110, 240, 255)
        d.rectangle([19, 8, 27, 16], fill=(200, 190, 170, 255))
        d.ellipse([10, 14, 36, 40], fill=col, outline=(240, 240, 240, 255), width=2)
        d.ellipse([15, 19, 21, 25], fill=(255, 255, 255, 180))
    d.rectangle([0, 0, sz - 1, sz - 1], outline=(30, 20, 10, 255), width=2)
    return img


def draw_orb(ov, cx, cy, r, frac, col, col_d):
    d = ImageDraw.Draw(ov)
    d.ellipse([cx - r - 7, cy - r - 7, cx + r + 7, cy + r + 7], fill=(26, 20, 16, 255), outline=(180, 142, 66, 255), width=3)
    d.ellipse([cx - r - 2, cy - r - 2, cx + r + 2, cy + r + 2], outline=(80, 62, 32, 255), width=2)
    sz = 2 * r
    liquid = Image.new("RGBA", (sz, sz), (8, 6, 10, 255))
    ld = ImageDraw.Draw(liquid)
    top = int(sz * (1 - frac))
    for y in range(top, sz):
        t = (y - top) / max(1, sz - top)
        ld.line([(0, y), (sz, y)], fill=(*mixc(col, col_d, t), 255))
    ld.line([(0, top), (sz, top)], fill=(*mixc(col, (255, 255, 255), 0.5), 255), width=2)
    ld.ellipse([sz * 0.2, sz * 0.12, sz * 0.55, sz * 0.38], fill=(255, 255, 255, 70))
    m = Image.new("L", (sz, sz), 0)
    ImageDraw.Draw(m).ellipse([0, 0, sz - 1, sz - 1], fill=255)
    liquid.putalpha(m)
    ov.alpha_composite(liquid, (cx - r, cy - r))


SLOT_POS = []


def build_hud():
    ov = Image.new("RGBA", (W * S, H * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)
    top = 650
    for y in range(top, H * S):
        d.line([(0, y), (W * S, y)], fill=(16, 14, 22, int(205 + 40 * (y - top) / (H * S - top))))
    d.line([(0, top), (W * S, top)], fill=(180, 142, 66, 255), width=2)
    d.line([(0, top + 3), (W * S, top + 3)], fill=(70, 56, 30, 255))
    ex0, ex1 = 140, 1140
    d.rectangle([ex0, top + 9, ex1, top + 14], fill=(30, 26, 20, 255), outline=(90, 74, 40, 255))
    d.rectangle([ex0 + 1, top + 10, ex0 + int((ex1 - ex0) * 0.63), top + 13], fill=(232, 202, 82, 255))
    draw_orb(ov, 70, 668, 50, 0.86, (236, 60, 60), (120, 10, 20))
    draw_orb(ov, 1210, 668, 50, 0.72, (80, 140, 255), (16, 30, 120))
    d.text((70, 672), "18620", font=F_NUM(18), fill=(255, 255, 255, 255), anchor="mm", stroke_width=2, stroke_fill=(0, 0, 0, 255))
    d.text((1210, 672), "6480", font=F_NUM(18), fill=(255, 255, 255, 255), anchor="mm", stroke_width=2, stroke_fill=(0, 0, 0, 255))
    icons = [("up", (120, 30, 40), (255, 120, 90)), ("wave", (60, 20, 100), (190, 110, 255)), ("dash", (20, 40, 100), (110, 180, 255)),
             ("cross", (90, 60, 20), (250, 200, 90)), ("sword", (40, 60, 70), (150, 210, 220)), ("aura", (90, 10, 20), (230, 70, 90)),
             ("hp", (40, 30, 30), (90, 60, 60)), ("mp", (30, 30, 40), (60, 60, 90))]
    keys = ["A", "S", "D", "F", "G", "H", "1", "2"]
    n = len(icons)
    gap = 60
    x0 = 640 - (n * gap) // 2 + 7
    for i, (k, c1, c2) in enumerate(icons):
        x = x0 + i * gap + (14 if i >= 6 else 0)
        y = 664
        d.rectangle([x - 3, y - 3, x + 49, y + 49], fill=(10, 8, 12, 255), outline=(150, 118, 58, 255), width=2)
        ov.alpha_composite(make_icon(k, c1, c2), (x, y))
        d.text((x + 3, y + 1), keys[i], font=F_NUM(14), fill=(255, 240, 200, 255), stroke_width=2, stroke_fill=(0, 0, 0, 255))
        SLOT_POS.append((x, y))
    d.text((24, 20), "幽暗回廊", font=F_CN(24), fill=(240, 220, 170, 255), stroke_width=2, stroke_fill=(20, 10, 0, 255))
    d.text((26, 52), "第 2 / 5 间 · 难度：冒险", font=F_CN(15), fill=(200, 190, 170, 255), stroke_width=2, stroke_fill=(20, 10, 0, 255))
    try:
        av = Image.open(PORTRAIT_PATH).convert("RGBA")
        av = av.crop((282, 202, 742, 662)).resize((64, 64), Image.LANCZOS).transpose(Image.FLIP_LEFT_RIGHT)
        m = Image.new("L", (64, 64), 0)
        ImageDraw.Draw(m).ellipse([1, 1, 62, 62], fill=255)
        av.putalpha(m)
        ov.alpha_composite(av, (20, 574))
        d.ellipse([20, 574, 84, 638], outline=(180, 142, 66, 255), width=3)
        d.ellipse([23, 577, 81, 635], outline=(70, 56, 30, 255))
    except Exception:
        pass
    d.text((92, 606), "幽影剑士  Lv.30", font=F_CN(17), fill=(255, 236, 190, 255), stroke_width=2, stroke_fill=(10, 6, 0, 255))
    mx, my, cs = 1100, 22, 26
    rooms = [(0, 1), (1, 1), (2, 1), (2, 0), (3, 0), (3, 1)]
    for i in range(len(rooms) - 1):
        a, b = rooms[i], rooms[i + 1]
        d.line([(mx + a[0] * cs + cs // 2, my + a[1] * cs + cs // 2), (mx + b[0] * cs + cs // 2, my + b[1] * cs + cs // 2)], fill=(120, 110, 90, 255), width=3)
    for i, (rx, ry) in enumerate(rooms):
        col = (70, 66, 60, 255) if i > 1 else (130, 120, 100, 255)
        if i == len(rooms) - 1:
            col = (150, 40, 40, 255)
        d.rectangle([mx + rx * cs + 3, my + ry * cs + 3, mx + rx * cs + cs - 3, my + ry * cs + cs - 3], fill=col, outline=(20, 16, 12, 255), width=2)
    return ov


LAYER_HP = 15000
LAYER_COLS = [(200, 40, 40), (220, 120, 30), (210, 190, 40), (80, 170, 60), (60, 120, 210), (150, 70, 200)]


def draw_dynamic_ui(ov, shake_off):
    d = ImageDraw.Draw(ov)
    sx, sy = shake_off[0] * S, shake_off[1] * S
    for slot, t0 in G.cooldown.items():
        el = G.fr - t0
        cd = 120
        if el < cd:
            x, y = SLOT_POS[slot]
            frac = 1 - el / cd
            d.pieslice([x - 8, y - 8, x + 54, y + 54], -90, -90 + 360 * frac, fill=(0, 0, 0, 160))
            d.text((x + 23, y + 23), f"{(cd - el) / FPS:.1f}", font=F_NUM(16), fill=(255, 255, 255, 255), anchor="mm", stroke_width=2, stroke_fill=(0, 0, 0, 255))
    e = G.target
    if e is not None:
        x0, x1, y = 400, 880, 36
        layers = math.ceil(e.hp / LAYER_HP)
        cur = e.hp - (layers - 1) * LAYER_HP
        chip_cur = min(LAYER_HP, max(cur, e.chip - (layers - 1) * LAYER_HP))
        ci = (layers - 1) % len(LAYER_COLS)
        d.rectangle([x0 - 46, y - 6, x0 - 8, y + 30], fill=(20, 16, 12, 230), outline=(160, 128, 60, 255), width=2)
        d.ellipse([x0 - 38, y + 0, x0 - 16, y + 22], fill=(*e.pal["skin"], 255))
        d.rectangle([x0 - 32, y + 7, x0 - 28, y + 10], fill=(*e.pal["eye"], 255))
        d.text((x0, y - 4), f"{e.name}  Lv.28", font=F_CN(16), fill=(255, 230, 200, 255), anchor="lb", stroke_width=2, stroke_fill=(0, 0, 0, 255))
        d.rectangle([x0 - 2, y - 2, x1 + 2, y + 18], fill=(10, 8, 8, 230), outline=(160, 128, 60, 255), width=2)
        if layers > 1:
            d.rectangle([x0, y, x1, y + 16], fill=(*LAYER_COLS[(ci - 1) % len(LAYER_COLS)], 255))
        d.rectangle([x0, y, x0 + (x1 - x0) * chip_cur / LAYER_HP, y + 16], fill=(250, 240, 220, 255))
        d.rectangle([x0, y, x0 + (x1 - x0) * cur / LAYER_HP, y + 16], fill=(*LAYER_COLS[ci], 255))
        d.line([(x0, y + 2), (x0 + (x1 - x0) * cur / LAYER_HP, y + 2)], fill=(*mixc(LAYER_COLS[ci], (255, 255, 255), 0.4), 255), width=2)
        d.text((x1 + 10, y + 8), f"x{layers}", font=F_NUM(22), fill=(255, 240, 200, 255), anchor="lm", stroke_width=2, stroke_fill=(0, 0, 0, 255))
    for n in G.numbers:
        age = G.fr - n["born"]
        if age > 34:
            continue
        pop = 1.8 - 0.8 * min(1.0, age / 4)
        base = 34 if n["crit"] else 26
        a = int(255 * (1 - max(0, age - 22) / 12))
        x = n["x"] * S + sx
        y = (n["y"] - min(age, 18) * 1.1) * S + sy
        col = (255, 150, 40, a) if n["crit"] else (255, 230, 96, a)
        d.text((x, y), str(n["val"]), font=F_NUM(base * pop), fill=col, anchor="mm", stroke_width=4, stroke_fill=(60, 18, 0, a))
        if n["crit"] and age < 26:
            d.text((x, y - base * pop * 0.75), "暴击", font=F_CN(14 * pop), fill=(255, 90, 60, a), anchor="mm", stroke_width=2, stroke_fill=(40, 0, 0, a))
    G.numbers = [n for n in G.numbers if G.fr - n["born"] <= 34]
    if G.combo > 0 and G.fr - G.combo_fr < 60:
        age = G.fr - G.combo_fr
        pop = 1 + 0.45 * max(0.0, 1 - age / 5)
        a = int(255 * (1 - max(0, age - 45) / 15))
        d.text((1150, 250), str(G.combo), font=F_NUM(70 * pop), fill=(255, 214, 90, a), anchor="rm", stroke_width=5, stroke_fill=(90, 30, 0, a))
        d.text((1162, 262), "COMBO", font=F_NUM(26), fill=(255, 245, 220, a), anchor="lm", stroke_width=3, stroke_fill=(60, 20, 0, a))
    elif G.fr - G.combo_fr >= 60:
        G.combo = 0
    pose = PL.pose()
    q = place(solve(pose, PL_LEN), PL_LEN, PL.x, GROUND0 + PL.z, PL.h + pose["h"], PL.facing)
    for p in G.popups:
        age = G.fr - p["born"]
        if age > 34:
            continue
        pop = 1.5 - 0.5 * min(1.0, age / 5)
        a = int(255 * (1 - max(0, age - 22) / 12))
        d.text((min(max(PL.x * S + sx, 90), 1190), (q["head"][1] - 32) * S + sy), p["text"], font=F_CN(30 * pop), fill=(255, 240, 190, a), anchor="mm",
               stroke_width=4, stroke_fill=(110, 30, 10, a))
    G.popups = [p for p in G.popups if G.fr - p["born"] <= 34]
    total = G.done_at or 10 ** 9
    if G.fr < 60:
        a = int(255 * min(1.0, (60 - G.fr) / 15))
        d.rectangle([0, 470, W * S, 560], fill=(0, 0, 0, int(a * 0.55)))
        d.text((640, 500), "怀旧横版动作 · 美术动作原型预览", font=F_CN(36), fill=(255, 236, 190, a), anchor="mm", stroke_width=3, stroke_fill=(30, 10, 0, a))
        d.text((640, 540), "角色 / 怪物 / 特效 / 场景 / UI 全部由程序实时生成，无任何外部素材", font=F_CN(18), fill=(220, 210, 200, a), anchor="mm",
               stroke_width=2, stroke_fill=(0, 0, 0, a))
    if G.fr > total - 40:
        a = int(255 * min(1.0, (G.fr - (total - 40)) / 12))
        d.rectangle([0, 470, W * S, 560], fill=(0, 0, 0, int(a * 0.55)))
        d.text((640, 515), f"本段连击 {len(G.hitlog) - sum(1 for h in G.hitlog if h[2] == 'MISS')} Hits · 命中停顿 / 浮空 / 弹地 / 倒地 / 受身", font=F_CN(26),
               fill=(255, 236, 190, a), anchor="mm", stroke_width=3, stroke_fill=(30, 10, 0, a))


# ---------------------------------------------------------------- script
def target_near(e, dist):
    return lambda: (e.x - dist if PL.x < e.x else e.x + dist, e.z + 6)


def build_script():
    q = PL.queue
    q.append(("idle", 26))
    q.append(("runto", target_near(E1, 44)))
    q.append(("clip", "A1"))
    q.append(("clip", "A2"))
    q.append(("clip", "A3"))
    q.append(("idle", 4))
    q.append(("runto", target_near(E1, 32)))
    q.append(("clip", "UPPER"))
    q.append(("clip", "A1"))
    q.append(("clip", "A2"))
    q.append(("clip", "A3"))
    q.append(("idle", 8))
    q.append(("runto", lambda: (156, 68)))
    q.append(("idle", 95))
    q.append(("clip", "GW"))
    q.append(("idle", 4))
    q.append(("runto", lambda: (168, 68)))
    q.append(("clip", "DASH"))


# ---------------------------------------------------------------- pose sheet
def pose_sheet():
    cw, ch = 128, 164
    entries = [("待机", "P", BASE, 0), ("奔跑", "P", None, 0), ("普攻 · 一段", "P", A1_HIT, 0), ("普攻 · 二段", "P", A2_HIT, 0),
               ("普攻 · 三段", "P", A3_HIT, 0), ("上挑", "P", UP_HIT, 0), ("地裂波 · 起跳", "P", GW_UP, 0), ("地裂波 · 砸地", "P", GW_SLAM, 0),
               ("影突 · 冲刺", "P", D_GO, 0), ("哥布林 · 待机", "E", G_IDLE, 0), ("哥布林 · 受击", "E", G_HIT, 0), ("哥布林 · 浮空", "E", G_AIR, 60)]
    cols = 6
    rows = math.ceil(len(entries) / cols)
    cell_w, cell_h = cw * S, ch * S
    sheet = Image.new("RGB", (cols * cell_w, rows * (cell_h + 44) + 70), (18, 16, 24))
    sd = ImageDraw.Draw(sheet)
    sd.text((sheet.width // 2, 36), "动作关键帧一览（程序骨骼动画 · 实时绘制）", font=F_CN(30), fill=(255, 236, 190), anchor="mm")
    old_phase = PL.run_phase
    for i, (label, who, pose, rot) in enumerate(entries):
        r, c = divmod(i, cols)
        img = Image.new("RGBA", (cw * 2, ch * 2), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        if who == "P":
            if pose is None:
                PL.run_phase = 1.2
                pose = run_proc(0)
            q = place(solve(pose, PL_LEN), PL_LEN, cw * 0.42, ch - 16, pose["h"], 1)
            draw_player(d, q, 1, 0, 2.0 if label == "奔跑" else 0.0)
        else:
            pts = solve(pose, GB_LEN, rot)
            q = place(pts, GB_LEN, cw * 0.5, ch - 16, 28 if rot else 0, -1, not rot, rot)
            draw_goblin(d, q, -1, GOB1)
        arr = finish_layer(np.array(img), iters=2)
        arr = np.array(Image.fromarray(arr).resize((cw, ch), Image.BILINEAR))
        bg = Image.new("RGB", (cw, ch), (36, 32, 46))
        ImageDraw.Draw(bg).rectangle([0, ch - 16, cw, ch], fill=(54, 48, 62))
        bg.paste(Image.fromarray(arr), (0, 0), Image.fromarray(arr))
        big = bg.resize((cell_w, cell_h), Image.NEAREST)
        x, y = c * cell_w, 70 + r * (cell_h + 44)
        sheet.paste(big, (x, y))
        sd.rectangle([x, y, x + cell_w - 1, y + cell_h - 1], outline=(90, 74, 40))
        sd.text((x + cell_w // 2, y + cell_h + 22), label, font=F_CN(20), fill=(230, 220, 200), anchor="mm")
    PL.run_phase = old_phase
    path = os.path.join(OUT_DIR, "pose_sheet.png")
    sheet.save(path)
    return path


# ---------------------------------------------------------------- main
def main():
    global BG, VIGNETTE
    BG = make_bg()
    VIGNETTE = make_vignette()
    hud = build_hud()
    build_script()
    next_action()

    mp4_path = os.path.join(OUT_DIR, "action_preview.mp4")
    writer = imageio.get_writer(mp4_path, fps=FPS, codec="libx264", quality=8, pixelformat="yuv420p", macro_block_size=1)
    gif_frames = []
    while True:
        if G.freeze > 0:
            G.freeze -= 1
        else:
            G.sim += 1
            player_step()
            for e in ENEMIES:
                enemy_step(e)
            fx_sim_step()
            sample_trail()
        update_particles()
        for e in ENEMIES:
            if e.chip > e.hp:
                e.chip = max(e.hp, e.chip - max(120, (e.chip - e.hp) * 0.06))

        world = render_world()
        off = (0, 0)
        if G.shake > 0.4:
            a = int(round(G.shake))
            off = (rng.randint(-a, a), rng.randint(-a, a) // 2 if a > 1 else 0)
            pad = np.pad(world, ((16, 16), (16, 16), (0, 0)), mode="edge")
            world = pad[16 - off[1]:16 - off[1] + H, 16 - off[0]:16 - off[0] + W]
            G.shake *= 0.78
        else:
            G.shake = 0.0
        G.flash *= 0.6 if G.flash > 0.02 else 0.0

        frame = Image.fromarray(world).resize((W * S, H * S), Image.NEAREST).convert("RGBA")
        frame.alpha_composite(hud)
        dyn = Image.new("RGBA", frame.size, (0, 0, 0, 0))
        draw_dynamic_ui(dyn, off)
        frame.alpha_composite(dyn)
        rgb = frame.convert("RGB")
        writer.append_data(np.array(rgb))
        if G.fr in G.snaps:
            rgb.save(os.path.join(OUT_DIR, f"shot_{G.snaps[G.fr]}.png"))
        if G.fr % 3 == 0:
            gif_frames.append(rgb.resize((480, 270), Image.LANCZOS))
        G.fr += 1
        if G.done_at is not None and G.fr >= G.done_at:
            break
        if G.fr > 1500:
            print("WARN: timeout")
            break
    writer.close()
    gif_path = os.path.join(OUT_DIR, "action_preview.gif")
    gif_frames[0].save(gif_path, save_all=True, append_images=gif_frames[1:], duration=1000 // 15, loop=0, optimize=True)
    sheet = pose_sheet()

    hits = [h for h in G.hitlog if h[2] != "MISS"]
    misses = [h for h in G.hitlog if h[2] == "MISS"]
    print(f"[PREVIEW] frames={G.fr} duration={G.fr / FPS:.1f}s hits={len(hits)} misses={len(misses)}")
    for h in G.hitlog:
        print(f"[PREVIEW] fr={h[0]:4d} clip={h[1]:6s} target={h[2]} kind={h[3]} dmg={h[4]} crit={h[5]}")
    print(f"[PREVIEW] mp4={mp4_path}")
    print(f"[PREVIEW] gif={gif_path}")
    print(f"[PREVIEW] sheet={sheet}")
    print(f"[PREVIEW] shots={[v for v in G.snaps.values()]}")


if __name__ == "__main__":
    main()
