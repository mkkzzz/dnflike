"""探索原型：武器 = 一张"刀身平面"标准贴图 + 握点三点标定，按手部变换仿射贴到每一帧。

正交相机下平面物体的投影恰好是仿射变换，所以一张贴图即可覆盖任意挥砍角度；
深度与身体 z-buffer 比较，拆成身前 / 身后两层。武器只改贴图与长度参数，不改动作。
"""
from __future__ import annotations

import math

import numpy as np

PX_PER_CM = 8.0

WEAPONS = {
    "katana": {"label": "太刀", "pommel": -20.0, "guard": 5.5, "blade": 90.0, "width": 3.3, "tip_w": 2.4,
               "sori": 2.4, "guard_kind": "tsuba", "guard_w": 8.0, "fuller": False, "hamon": True},
    "greatsword": {"label": "巨剑", "pommel": -24.0, "guard": 5.5, "blade": 112.0, "width": 11.5, "tip_w": 9.0,
                   "sori": 0.0, "guard_kind": "cross", "guard_w": 30.0, "fuller": True, "hamon": False},
    "shortsword": {"label": "短剑", "pommel": -9.0, "guard": 5.0, "blade": 46.0, "width": 5.2, "tip_w": 4.4,
                   "sori": 0.0, "guard_kind": "cross", "guard_w": 13.0, "fuller": True, "hamon": False},
}


def blade_extent(spec):
    return spec["guard"] + 1.2, spec["guard"] + 1.2 + spec["blade"]


def make_sprite(spec):
    """生成刀身平面贴图（straight RGBA float，0..1）。u=沿刀身（cm，握点为 0），v=刃向（+v 为刃口）。"""
    a0, a1 = spec["pommel"] - 2.0, spec["guard"] + spec["blade"] + 4.0
    hw = max(spec["guard_w"], spec["width"] * 1.6) / 2 + 2.0
    W = int(math.ceil((a1 - a0) * PX_PER_CM))
    H = int(math.ceil(2 * hw * PX_PER_CM))
    u = a0 + (np.arange(W) + 0.5) / PX_PER_CM
    v = hw - (np.arange(H) + 0.5) / PX_PER_CM
    U, V = np.meshgrid(u, v)
    rgb = np.zeros((H, W, 3), np.float32)
    alpha = np.zeros((H, W), np.float32)

    bs, be = blade_extent(spec)
    L = be - bs
    s = np.clip((U - bs) / L, 0, 1)
    center = -spec["sori"] * s * s
    tip_len = min(spec["width"] * 1.6, L * 0.2)
    taper = np.clip((be - U) / tip_len, 0, 1)
    half_w = (spec["width"] + (spec["tip_w"] - spec["width"]) * s) / 2
    if spec["sori"] > 0:
        edge_side = center + half_w * np.sqrt(taper)
        spine_side = center - half_w * (0.15 + 0.85 * np.clip(taper * 1.6, 0, 1))
    else:
        edge_side = center + half_w * np.sqrt(taper)
        spine_side = center - half_w * np.sqrt(taper)
    blade = (U >= bs) & (U <= be) & (V <= edge_side) & (V >= spine_side)
    across = np.clip((V - spine_side) / np.maximum(edge_side - spine_side, 1e-3), 0, 1)
    steel = np.array([0.66, 0.69, 0.74], np.float32)
    shade = 0.62 + 0.38 * across
    col = steel[None, None, :] * shade[..., None]
    bevel = across > (0.55 if spec["sori"] > 0 else 0.62)
    col[bevel] = col[bevel] * 0.55 + np.array([0.98, 0.99, 1.0]) * 0.45
    if spec["sori"] == 0:
        mid = np.abs(across - 0.5) < 0.04
        col[mid & ~bevel] *= 0.85
        bevel2 = across < 0.38
        col[bevel2] = col[bevel2] * 0.85 + np.array([0.86, 0.9, 0.96]) * 0.15
    if spec["fuller"]:
        fuller = (np.abs(across - 0.5) < 0.09) & (U < bs + L * 0.72)
        col[fuller] *= 0.62
    if spec["hamon"]:
        wave = 0.62 + 0.06 * np.sin(U * 1.7) + 0.03 * np.sin(U * 4.3)
        ham = (np.abs(across - wave) < 0.035)
        col[ham] = col[ham] * 0.4 + np.array([1.0, 1.0, 1.0]) * 0.6
    rgb[blade] = col[blade]
    alpha[blade] = 1.0

    habaki = (U >= spec["guard"]) & (U < bs + 2.0) & (np.abs(V - center) <= half_w + 0.35)
    if spec["guard_kind"] == "tsuba":
        rgb[habaki] = (0.78, 0.62, 0.30)
        alpha[habaki] = 1.0
        g = (U >= spec["guard"] - 0.9) & (U <= spec["guard"]) & (np.abs(V) <= spec["guard_w"] / 2)
        rgb[g] = (0.17, 0.16, 0.19)
        rgb[g & (np.abs(V) > spec["guard_w"] / 2 - 0.6)] = (0.55, 0.42, 0.22)
    else:
        g = (U >= spec["guard"] - 1.6) & (U <= spec["guard"] + 1.2) & (np.abs(V) <= spec["guard_w"] / 2)
        tip_round = np.abs(V) > spec["guard_w"] / 2 - 1.5
        rgb[g] = (0.20, 0.19, 0.23)
        rgb[g & ((U < spec["guard"] - 1.1) | tip_round)] = (0.62, 0.48, 0.24)
    alpha[g] = 1.0

    grip_w = 1.5 if spec["guard_kind"] == "tsuba" else 1.7
    hilt = (U >= spec["pommel"]) & (U < spec["guard"] - 0.9) & (np.abs(V) <= grip_w)
    diamond = (np.abs(((U * 1.25) % 2.0) - 1.0) + np.abs(V) / grip_w * 0.9) < 0.75
    rgb[hilt] = (0.10, 0.09, 0.11)
    rgb[hilt & diamond] = (0.42, 0.10, 0.12)
    alpha[hilt] = 1.0
    pom = (U >= spec["pommel"] - 1.6) & (U < spec["pommel"]) & (np.abs(V) <= grip_w + 0.5)
    rgb[pom] = (0.55, 0.43, 0.22)
    alpha[pom] = 1.0

    a = alpha > 0
    grow = a.copy()
    for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0), (1, 1), (-1, -1), (1, -1), (-1, 1)):
        grow |= np.roll(np.roll(a, dy, 0), dx, 1)
    outline = grow & ~a
    rgb[outline] = (0.06, 0.05, 0.07)
    alpha[outline] = 1.0
    return {"rgb": rgb, "alpha": alpha, "a0": a0, "hw": hw, "W": W, "H": H, "spec": spec}


def _bilinear(img, x, y):
    h, w = img.shape[:2]
    x = np.clip(x, 0, w - 1.001)
    y = np.clip(y, 0, h - 1.001)
    x0 = np.floor(x).astype(int)
    y0 = np.floor(y).astype(int)
    fx = (x - x0)[..., None] if img.ndim == 3 else x - x0
    fy = (y - y0)[..., None] if img.ndim == 3 else y - y0
    p00, p01 = img[y0, x0], img[y0, x0 + 1]
    p10, p11 = img[y0 + 1, x0], img[y0 + 1, x0 + 1]
    return (p00 * (1 - fx) + p01 * fx) * (1 - fy) + (p10 * (1 - fx) + p11 * fx) * fy


def _frame_vectors(view, blade, width_cm, min_width_px=1.4):
    grip, d, e, n = blade
    G = view.cam(grip)
    Dc, Ec = view.R @ d, view.R @ e
    dxy = Dc[:2]
    dl = np.linalg.norm(dxy)
    if dl > 1e-6:
        perp = np.array([-dxy[1], dxy[0]]) / dl
        comp = float(Ec[:2] @ perp)
        need = min_width_px / (view.scale / view.ss) / width_cm
        if abs(comp) < need:
            sign = 1.0 if comp >= 0 else -1.0
            Ec = Ec.copy()
            Ec[:2] += perp * (sign * need - comp)
    return G, Dc, Ec


def render_weapon(view, buf, sprite, blade, stamp=False):
    """返回 (front_rgba, back_rgba, landmarks)，均为超采样分辨率的 premultiplied float。

    stamp=True 时把武器的可见像素写回 buf（供深度 / 分件 / 线稿引导图使用）。
    """
    spec = sprite["spec"]
    G, Dc, Ec = _frame_vectors(view, blade, spec["width"])
    a0, a1 = sprite["a0"], sprite["a0"] + sprite["W"] / PX_PER_CM
    hw = sprite["hw"]
    corners = [G + Dc * a + Ec * e for a in (a0, a1) for e in (-hw, hw)]
    xs = [c[0] for c in corners]
    ys = [c[1] for c in corners]
    x0 = int(max(0, math.floor(view.ox + min(xs) * view.scale)))
    x1 = int(min(view.w, math.ceil(view.ox + max(xs) * view.scale) + 1))
    y0 = int(max(0, math.floor(view.oy - max(ys) * view.scale)))
    y1 = int(min(view.h, math.ceil(view.oy - min(ys) * view.scale) + 1))
    front = np.zeros((view.h, view.w, 4), np.float32)
    back = np.zeros_like(front)
    lm = {}
    if x1 > x0 and y1 > y0:
        X, Y = np.meshgrid((np.arange(x0, x1) + 0.5 - view.ox) / view.scale,
                           (view.oy - (np.arange(y0, y1) + 0.5)) / view.scale)
        M = np.array([[Dc[0], Ec[0]], [Dc[1], Ec[1]]])
        Mi = np.linalg.inv(M)
        rx, ry = X - G[0], Y - G[1]
        A = Mi[0, 0] * rx + Mi[0, 1] * ry
        E = Mi[1, 0] * rx + Mi[1, 1] * ry
        sx = (A - a0) * PX_PER_CM - 0.5
        sy = (hw - E) * PX_PER_CM - 0.5
        inside = (sx >= 0) & (sx < sprite["W"] - 1) & (sy >= 0) & (sy < sprite["H"] - 1)
        al = _bilinear(sprite["alpha"], sx, sy) * inside
        rgb = _bilinear(sprite["rgb"] * sprite["alpha"][..., None], sx, sy) * inside[..., None]
        z = G[2] + A * Dc[2] + E * Ec[2]
        body_z = buf.z[y0:y1, x0:x1]
        n_cam = view.R @ blade[3]
        light = 0.82 + 0.3 * abs(float(n_cam[2]))
        rgb = np.clip(rgb * light, 0, 1)
        is_front = z >= body_z
        tile = np.concatenate([rgb, al[..., None]], -1)
        front[y0:y1, x0:x1] = tile * is_front[..., None]
        back[y0:y1, x0:x1] = tile * (~is_front)[..., None]
        if stamp:
            upd = (al > 0.5) & is_front
            buf.z[y0:y1, x0:x1][upd] = z[upd]
            buf.part[y0:y1, x0:x1][upd] = 20
            buf.nrm[y0:y1, x0:x1][upd] = n_cam if n_cam[2] >= 0 else -n_cam
    bs, be = blade_extent(spec)
    for name, a in (("grip", 0.0), ("guard", spec["guard"]), ("tip", be)):
        off = -spec["sori"] if name == "tip" else 0.0
        p3 = blade[0] + blade[1] * a + blade[2] * off
        lm[name] = p3
    return front, back, lm
