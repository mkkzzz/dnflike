"""S2 第二版探索：3D 模型 + 定格节奏关键姿势 + 改良卡通渲染 + 与 V6 同场打击对比（纯离线，不开窗口）。

  python tools/explore/s2b.py stills     # 关键姿势速览（调姿用）
  python tools/explore/s2b.py all        # 全部评审产出 → temp/explore/s2b/
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path
from types import SimpleNamespace

import numpy as np
from PIL import Image, ImageDraw, ImageFilter
from scipy import ndimage
from scipy.sparse import coo_matrix, diags

HERE = Path(__file__).resolve().parent
TOOLS = HERE.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(TOOLS))
import mesh3d as m3  # noqa: E402
import puppet as pp  # noqa: E402
import render_anchor as ra  # noqa: E402
import weapons as wp  # noqa: E402
from poses import MESH_REST, flat, lead_edge, look  # noqa: E402

ROOT = TOOLS.parent
OUT = ROOT / "temp" / "explore" / "s2b"
GROUND = 350
START_X = 270
CANVAS = (640, 360, (256, 300))
TILT = -50.0


def F(phi, down=0.0):
    return flat(phi, down, tilt=TILT)


def E(phi):
    return lead_edge(phi, tilt=TILT)


def smoothstep(e0, e1, x):
    t = np.clip((np.asarray(x, float) - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


# ---------------- 动作：V6 式定格节奏（起手停顿 → 1 tick 释放 → 2 tick 接触 → 过冲余势 → 收招） ----------------

READY = {
    "root_x": 0.0, "pelvis_h": 90.0, "pelvis_dx": 0.0, "pelvis_dz": 0.0,
    "pelvis_yaw": -12.0, "pelvis_lean": 6.0, "pelvis_roll": 0.0,
    "chest_yaw": -10.0, "chest_lean": 6.0, "chest_roll": 0.0,
    "head_yaw": look(-12, -10, 0.85), "head_lean": -4.0,
    "hand_r": (28.0, 98.0, 24.0), "blade_dir": (0.82, -0.5, 0.2), "blade_edge": (0.0, -1.0, 0.0),
    "pole_r": (-0.4, -1.0, 0.6), "hand_l": (6.0, 96.0, -24.0), "pole_l": (-0.5, -1.0, -0.4),
    "foot_r": (24.0, 0.0, 11.0), "foot_l": (-26.0, 0.0, -11.0),
    "foot_r_dir": (1.0, 0.0, 0.15), "foot_l_dir": (0.75, 0.0, -0.65), "coat": (0.0, 0.0, 0.0),
}

READY.update({"pelvis_h": 88.0, "foot_r": (26.0, 0.0, 11.0), "foot_l": (-30.0, 0.0, -11.0)})

ATTACK1 = pp.build_keys([
    (0, "linear", READY),
    (2, "linear", {}),
    (4, "snap", {
        "root_x": -2.0, "pelvis_h": 82.0, "pelvis_dx": -7.0, "pelvis_yaw": -26.0, "pelvis_lean": 2.0,
        "chest_yaw": -44.0, "chest_lean": -4.0, "chest_roll": 8.0, "head_yaw": look(-26, -44, 0.9),
        "head_lean": -8.0, "hand_r": (-28.0, 128.0, 26.0), "blade_dir": F(150, -0.35), "blade_edge": E(150),
        "pole_r": (-0.5, -0.2, 0.8), "hand_l": (24.0, 110.0, -12.0), "pole_l": (0.0, -1.0, -0.5),
        "foot_r": (26.0, 0.0, 11.0), "foot_l": (-32.0, 0.0, -11.0),
    }),
    (7, "out", {
        "pelvis_h": 80.0, "pelvis_yaw": -30.0, "chest_yaw": -52.0, "head_yaw": look(-30, -52, 0.9),
        "hand_r": (-34.0, 132.0, 24.0), "blade_dir": F(160, -0.4), "blade_edge": E(160),
        "foot_r": (22.0, 4.0, 11.0),
    }),
    (8, "step", {
        "root_x": 3.0, "pelvis_h": 82.0, "pelvis_dx": 3.0, "pelvis_yaw": -16.0, "pelvis_lean": 8.0,
        "chest_yaw": -22.0, "chest_lean": 8.0, "chest_roll": 0.0, "head_yaw": look(-16, -22, 0.9),
        "head_lean": -2.0, "hand_r": (18.0, 118.0, 42.0), "blade_dir": F(96, -0.02), "blade_edge": E(96),
        "pole_r": (-0.3, -1.0, 0.4), "hand_l": (10.0, 106.0, -24.0), "foot_r": (36.0, 5.0, 11.0),
        "foot_l": (-28.0, 0.0, -11.0),
    }),
    (9, "step", {
        "root_x": 9.0, "pelvis_h": 75.0, "pelvis_dx": 7.0, "pelvis_yaw": -8.0, "pelvis_lean": 12.0,
        "chest_yaw": -6.0, "chest_lean": 14.0, "head_yaw": look(-8, -6, 0.9), "head_lean": 6.0,
        "hand_r": (78.0, 116.0, 8.0), "blade_dir": F(-4, 0.0), "blade_edge": E(-4),
        "pole_r": (-0.2, -1.0, 0.3), "hand_l": (-26.0, 104.0, -30.0), "pole_l": (0.3, -1.0, -0.4),
        "foot_r": (54.0, 0.0, 12.0), "foot_l": (-34.0, 0.0, -12.0), "foot_l_dir": (0.6, 0.0, -0.8),
    }),
    (10, "out", {
        "pelvis_yaw": -6.0, "chest_yaw": -2.0, "head_yaw": look(-6, -2, 0.9),
        "hand_r": (80.0, 115.0, 2.0), "blade_dir": F(-14, 0.02), "blade_edge": E(-14),
    }),
    (11, "step", {
        "root_x": 12.0, "pelvis_h": 78.0, "pelvis_dx": 7.0, "pelvis_yaw": 2.0, "chest_yaw": 14.0,
        "chest_lean": 12.0, "head_yaw": look(2, 14, 0.85), "hand_r": (56.0, 106.0, -34.0),
        "blade_dir": F(-92, 0.12), "blade_edge": E(-92), "pole_r": (-0.5, -1.0, 0.0),
        "hand_l": (-22.0, 100.0, -32.0),
    }),
    (15, "out", {
        "pelvis_h": 79.0, "pelvis_yaw": 4.0, "chest_yaw": 20.0, "head_yaw": look(4, 20, 0.85),
        "hand_r": (50.0, 102.0, -38.0), "blade_dir": F(-108, 0.2), "blade_edge": E(-108),
    }),
    (19, "inout", {
        "pelvis_h": 84.0, "pelvis_dx": 4.0, "pelvis_yaw": -8.0, "pelvis_lean": 8.0, "chest_yaw": -6.0,
        "chest_lean": 8.0, "head_yaw": look(-8, -6, 0.85), "head_lean": -2.0,
        "hand_r": (46.0, 100.0, 12.0), "blade_dir": (0.85, -0.45, 0.1), "blade_edge": (0.0, -1.0, 0.0),
        "pole_r": (-0.4, -1.0, 0.6), "hand_l": (8.0, 98.0, -26.0), "pole_l": (-0.5, -1.0, -0.4),
        "foot_l": (-22.0, 7.0, -11.0), "foot_l_dir": (0.75, 0.0, -0.65),
    }),
    (21, "inout", {"foot_l": (-14.0, 0.0, -11.0), "foot_r": (44.0, 5.0, 11.0)}),
    (24, "inout", dict(READY, root_x=12.0, hand_r=(40.0, 98.0, 24.0), hand_l=(18.0, 96.0, -24.0),
                       foot_r=(36.0, 0.0, 11.0), foot_l=(-14.0, 0.0, -11.0))),
    (29, "linear", {}),
])
LENGTH = 30
ACTIVE = (7.0, 12.5)
HITSTOP = 3


def smooth_path(keys):
    """刀光用的连续虚拟轨迹：把定格硬切还原成插值，身体可以硬切，刀光仍画出完整弧线。"""
    return [(t, "linear" if ease in ("step", "snap") else ease, p) for t, ease, p in keys]


ATTACK1_PATH = smooth_path(ATTACK1)


# ---------------- 绑定 ----------------

LEG_BONES = [8, 9, 11, 12]
ARM_BONES = [4, 5, 6, 7]


def adjacency(Fc, n):
    e = np.concatenate([Fc[:, [0, 1]], Fc[:, [1, 2]], Fc[:, [2, 0]]])
    e = np.concatenate([e, e[:, ::-1]])
    A = coo_matrix((np.ones(len(e)), (e[:, 0], e[:, 1])), shape=(n, n)).tocsr()
    A.data[:] = 1.0
    deg = np.asarray(A.sum(1)).ravel()
    return diags(1.0 / np.maximum(deg, 1)) @ A


def smooth(A, X, iters, keep=0.5):
    for _ in range(iters):
        X = keep * X + (1 - keep) * (A @ X)
    return X


def nrm(v):
    return v / (np.linalg.norm(v, axis=-1, keepdims=True) + 1e-9)


def rotate_between(vecs, a, b):
    """逐顶点 Rodrigues：把方向 a 转到 b 的旋转作用在 vecs 上（a、b 为 Nx3 单位向量）。"""
    axis = np.cross(a, b)
    s = np.linalg.norm(axis, axis=1, keepdims=True)
    c = np.sum(a * b, axis=1, keepdims=True)
    k = axis / np.maximum(s, 1e-9)
    return vecs * c + np.cross(k, vecs) * s + k * np.sum(k * vecs, axis=1, keepdims=True) * (1 - c)


def rot_y_about(P, pivot, deg):
    a = np.radians(deg)[:, None]
    o = P - pivot
    x = o[:, 0:1] * np.cos(a) + o[:, 2:3] * np.sin(a)
    z = -o[:, 0:1] * np.sin(a) + o[:, 2:3] * np.cos(a)
    return pivot + np.concatenate([x, o[:, 1:2], z], 1)


def toon_texture(tex, cache):
    if cache.exists():
        return np.asarray(Image.open(cache).convert("RGB"), np.float32) / 255.0
    im = Image.fromarray((tex.img * 255).astype(np.uint8)).filter(ImageFilter.MedianFilter(5))
    q = im.quantize(colors=48, method=Image.Quantize.MEDIANCUT, kmeans=3)
    pal = np.asarray(q.getpalette()[: 48 * 3], np.float32).reshape(-1, 3) / 255.0
    pal = leather_correct(pal)
    q.putpalette((np.clip(pal, 0, 1) * 255).astype(np.uint8).ravel().tolist())
    q = q.convert("RGB")
    cache.parent.mkdir(parents=True, exist_ok=True)
    q.save(cache)
    return np.asarray(q, np.float32) / 255.0


def leather_correct(pal):
    """色板校正：低饱和中间灰（模型贴图烘进去的皮革反光）压暗到标杆的黑皮衣；银白发（高明度）保留。"""
    mx, mn = pal.max(1), pal.min(1)
    sat = (mx - mn) / np.maximum(mx, 1e-6)
    gray = (sat < 0.18) & (mx < 0.80)
    v = mx[gray]
    target = 0.10 + 0.55 * (v / 0.80) ** 1.7
    pal[gray] *= (target / np.maximum(v, 1e-6))[:, None]
    return pal


def strip_all(V, Fc, VT, FT, tex, j_rest):
    """去掉模型自带的刀身、刀柄与刀穗，只保留握拳。"""
    keep_blade, removed = m3.strip_weapon(V, Fc, VT, FT, tex, j_rest["grip_r"])
    _, c, d, t = m3.find_sword(V)
    t_hand = float((np.asarray(j_rest["grip_r"]) - c) @ d)
    line_d = np.linalg.norm((V - c) - t[:, None] * d, axis=1)
    near_hand = np.linalg.norm(V - np.asarray(j_rest["grip_r"]), axis=1) < 6.0
    hilt = (t < t_hand - 5.0) & (t > t_hand - 34.0) & (line_d < 2.8) & ~near_hand
    remove = removed | hilt
    return ~remove[Fc].any(1), remove


class Rig:
    def __init__(self):
        _, V, VT, Fc, FT, tex = ra.load_hero3d()
        self.V, self.VT = V, VT
        self.j_rest = pp.solve(pp.sample(MESH_REST, 0))
        keep, removed = strip_all(V, Fc, VT, FT, tex, self.j_rest)
        self.F, self.FT = Fc[keep], FT[keep]
        self.removed = removed
        self.A = adjacency(Fc, len(V))
        self.tex = toon_texture(tex, OUT / "toon_texture_v2.png")
        self.rest_frames = m3.bone_frames(self.j_rest)
        D = np.stack([m3._seg_dist(V, np.asarray(self.j_rest[a], float), np.asarray(self.j_rest[b], float))[0]
                      for a, b in m3.BONES], 1)
        D[:, 14:] *= 1.35
        idx = np.argsort(D, axis=1)[:, :4]
        W = np.zeros_like(D)
        rows = np.arange(len(V))[:, None]
        W[rows, idx] = 1.0 / np.power(np.take_along_axis(D, idx, 1) + 1.0, 4)
        W /= W.sum(1, keepdims=True)
        W = smooth(self.A, W, 6)
        sword = m3.find_sword(V)[0]
        W[sword] = 0.0
        W[sword, 5] = 1.0
        self.W = W / W.sum(1, keepdims=True)
        y = V[:, 1]
        dleg = D[:, LEG_BONES].min(1)
        darm = D[:, ARM_BONES].min(1)
        k = (smoothstep(104, 96, y) * smoothstep(30, 38, y) * smoothstep(11.0, 15.0, dleg)
             * smoothstep(4.0, 7.0, darm))
        scabbard = (V[:, 0] < -19.0) & (y > 62.0) & (y < 104.0)
        k[scabbard] = 0.0
        self.k = np.clip(smooth(self.A, k[:, None], 4)[:, 0], 0, 1)
        self.k[scabbard] = 0.0
        W = self.W.copy()
        W[scabbard] = 0.0
        W[scabbard, 0] = 1.0
        self.W = W
        self.scabbard = scabbard
        local = V - np.asarray(self.j_rest["pelvis"])
        self.side = 1.0 / (1.0 + np.exp(-local[:, 2] / 4.0))
        self.h = smoothstep(100, 68, y)

    def lbs(self, j):
        out = np.zeros_like(self.V)
        for b, ((ra_, rf), (pa, pf)) in enumerate(zip(self.rest_frames, m3.bone_frames(j))):
            M = pf @ rf.T
            w = self.W[:, b:b + 1]
            if w.max() <= 0:
                continue
            out += w * (self.V @ M.T + (pa - M @ ra_))
        return out

    def skirt(self, j, vel, yaw_vel):
        jr = self.j_rest
        pivot_r = np.asarray(jr["pelvis"], float)
        P = j["P"]
        rigid = j["pelvis"] + (self.V - pivot_r) @ P.T
        s = self.side[:, None]

        def legs(jj):
            return (pp.unit(jj["knee_r"] - jj["hip_r"]), pp.unit(jj["knee_l"] - jj["hip_l"]))

        dR, dL = legs(j)
        dR0, dL0 = legs(jr)
        down = P @ np.array([0.0, -1.0, 0.0])
        leg = nrm(s * dR + (1 - s) * dL)
        leg0 = nrm(s * (P @ dR0) + (1 - s) * (P @ dL0))
        hang = nrm(0.82 * leg + 0.18 * down - np.asarray(vel) * 0.035)
        hang0 = nrm(0.82 * leg0 + 0.18 * down)
        pivot = np.asarray(j["pelvis"], float)
        sk = pivot + rotate_between(rigid - pivot, hang0, hang)
        h = self.h
        sk = rot_y_about(sk, pivot, -yaw_vel * 0.9 * h)
        flare = 1.0 + np.clip(abs(yaw_vel) * 0.008, 0, 0.12) * h - 0.12 * h
        off = sk - pivot
        off[:, 0] *= flare
        off[:, 2] *= flare
        sk = pivot + off
        return rigid + (sk - rigid) * h[:, None]

    def pose(self, keys, t):
        p = pp.sample(keys, t)
        j = pp.solve(p)
        vel = np.zeros(3)
        yaw_vel = 0.0
        wsum = 0.0
        prev = j
        prev_yaw = p["pelvis_yaw"]
        for k in range(1, 7):
            pk = pp.sample(keys, t - k)
            jk = pp.solve(pk)
            w = 0.55 ** (k - 1)
            vel += w * (np.asarray(prev["pelvis"]) - np.asarray(jk["pelvis"]))
            yaw_vel += w * (prev_yaw - pk["pelvis_yaw"])
            wsum += w
            prev, prev_yaw = jk, pk["pelvis_yaw"]
        vel /= wsum
        yaw_vel /= wsum
        Vl = self.lbs(j)
        Vs = self.skirt(j, vel, yaw_vel)
        k = self.k[:, None]
        Vp = Vl * (1 - k) + Vs * k
        vn = m3.vertex_normals(Vp, self.F)
        vn = nrm(smooth(self.A, vn, 3))
        return Vp, vn, j


# ---------------- 渲染 ----------------

SHADOW = np.array([0.64, 0.65, 0.80], np.float32)
LIT = 1.14
ALBEDO_GAMMA = 1.0
SCALE = 1.08
RIM_SIDE = pp.unit([-0.75, 0.55, 0.0])


def sample_nearest(img, uv):
    h, w = img.shape[:2]
    x = np.clip(np.rint(np.clip(uv[:, 0], 0, 1) * (w - 1)).astype(int), 0, w - 1)
    y = np.clip(np.rint((1 - np.clip(uv[:, 1], 0, 1)) * (h - 1)).astype(int), 0, h - 1)
    return img[y, x]


def shade_toon(view, rig, Vp, vn):
    zb, tb, w1, w2 = m3.raster(view, Vp, rig.F)
    m = tb >= 0
    H, W = m.shape
    rgb = np.zeros((H, W, 3), np.float32)
    alb = np.zeros((H, W, 3), np.float32)
    nimg = np.zeros((H, W, 3), np.float32)
    if m.any():
        t = tb[m]
        a1, a2 = w1[m][:, None], w2[m][:, None]
        a0 = 1 - a1 - a2
        F_, FT_ = rig.F, rig.FT
        uv = rig.VT[FT_[t, 0]] * a0 + rig.VT[FT_[t, 1]] * a1 + rig.VT[FT_[t, 2]] * a2
        col = sample_nearest(rig.tex, uv) ** ALBEDO_GAMMA
        n = (vn[F_[t, 0]] * a0 + vn[F_[t, 1]] * a1 + vn[F_[t, 2]] * a2) @ view.R.T
        n = nrm(n)
        lit = smoothstep(-0.06, 0.06, n @ pp.LIGHT)[:, None]
        c = col * (SHADOW + (LIT - SHADOW) * lit)
        rim = np.clip((1 - np.clip(n[:, 2], 0, 1)) ** 2 * np.clip(n @ RIM_SIDE, 0, 1) * 2.2 - 0.25, 0, 1)
        c += rim[:, None] * 0.42 * (0.4 + 0.6 * lit)
        rgb[m] = np.clip(c, 0, 1)
        alb[m] = col
        nimg[m] = n
    z = np.where(m, zb, -1e4)
    e = np.zeros_like(m)
    for dy, dx in ((0, 1), (1, 0)):
        za, zc = z[: H - dy, : W - dx], z[dy:, dx:]
        na, nc = nimg[: H - dy, : W - dx], nimg[dy:, dx:]
        d = (np.abs(za - zc) > 3.0) | (np.sum(na * nc, -1) < 0.45)
        e[: H - dy, : W - dx] |= d
        e[dy:, dx:] |= d
    e &= m
    e = ndimage.binary_dilation(e, iterations=1) & m
    rgb[e] = alb[e] * 0.3
    sil = ndimage.binary_dilation(m, iterations=view.ss + 1) & ~m
    rgb[sil] = pp.OUTLINE / 255.0
    alpha = (m | sil).astype(np.float32)
    return np.concatenate([rgb * alpha[..., None], alpha[..., None]], -1), zb


def outline_layer(pm, ss):
    a = pm[..., 3] > 0.35
    ring = ndimage.binary_dilation(a, iterations=ss) & ~a
    out = pm.copy()
    out[ring] = np.concatenate([pp.OUTLINE / 255.0, [1.0]])
    return out


def down_pm(view, pm):
    ss = view.ss
    h, w = pm.shape[0] // ss, pm.shape[1] // ss
    return pm[: h * ss, : w * ss].reshape(h, ss, w, ss, 4).mean(axis=(1, 3))


def trail_layers(view, keys, t, weapon, life=4.5, step=0.125):
    """刀光：护手外侧→刀尖逐 0.2 tick 扫掠成面，新亮旧暗，按刀尖深度拆成身后 / 身前两层。"""
    W2, H2 = view.out_w * 2, view.out_h * 2
    imgs = {k: Image.new("L", (W2, H2), 0) for k in ("back", "front", "core_back", "core_front")}
    t0, t1 = max(ACTIVE[0], t - life), min(t, ACTIVE[1])
    if t1 > t0:
        spec = wp.WEAPONS[weapon]
        bs, be = wp.blade_extent(spec)
        us = list(np.arange(t0, t1, step)) + [t1]
        pts = []
        for u in us:
            j = pp.solve(pp.sample(keys, u))
            g, d, e, _ = j["blade"]
            inner = g + d * (bs + (be - bs) * 0.5)
            tip = g + d * be - e * spec["sori"]
            front = view.cam(tip)[2] > view.cam(j["chest"])[2]
            pts.append((view.px(inner) * 2, view.px(tip) * 2, front, u))
        draws = {k: ImageDraw.Draw(v) for k, v in imgs.items()}
        for k in range(1, len(pts)):
            (ia, ta, fa, ua), (ib, tb, fb, ub) = pts[k - 1], pts[k]
            age = np.clip((ub - (t - life)) / life, 0, 1) ** 1.4
            layer = "front" if (fa or fb) else "back"
            for b in range(4):
                f0, f1 = b / 4, (b + 1) / 4
                quad = [tuple(ia + (ta - ia) * f0), tuple(ia + (ta - ia) * f1), tuple(ib + (tb - ib) * f1),
                        tuple(ib + (tb - ib) * f0)]
                draws[layer].polygon(quad, fill=int(215 * age * (0.1 + 0.9 * f1 * f1)))
            if ub > t - 1.8:
                draws["core_" + layer].line([tuple(ta), tuple(tb)], fill=int(255 * age), width=4)
    out = {}
    for k, im in imgs.items():
        im = im.filter(ImageFilter.GaussianBlur(1.2)).resize((view.out_w, view.out_h), Image.BILINEAR)
        out[k] = np.asarray(im, np.float32) / 255.0
    return out


def trail_rgb(i, core):
    col = i[..., None] * np.array([0.40, 0.62, 1.0], np.float32) + (i ** 3)[..., None] * np.array([0.6, 0.38, 0.0])
    return col + core[..., None] * np.array([0.9, 0.95, 1.0], np.float32)


class Actor:
    def __init__(self, rig, keys, ss=3, path=None):
        self.rig, self.keys, self.ss = rig, keys, ss
        self.path = path or smooth_path(keys)
        self.body_cache, self.cache = {}, {}

    def view(self):
        w, h, o = CANVAS
        return pp.View(w, h, SCALE, o, yaw=-25.0, pitch=10.0, ss=self.ss)

    def body(self, t):
        if t not in self.body_cache:
            view = self.view()
            Vp, vn, j = self.rig.pose(self.keys, t)
            pm, zb = shade_toon(view, self.rig, Vp, vn)
            self.body_cache[t] = (pm, zb, j)
        return self.body_cache[t]

    def layers(self, t, weapon):
        key = (t, weapon)
        if key not in self.cache:
            view = self.view()
            pm, zb, j = self.body(t)
            front, back, lm = wp.render_weapon(view, SimpleNamespace(z=zb), ra.sprite(weapon), j["blade"],
                                               min_width_px=2.4)
            front, back = outline_layer(front, self.ss), outline_layer(back, self.ss)
            spec = wp.WEAPONS[weapon]
            bs, be = wp.blade_extent(spec)
            g, d, e, _ = j["blade"]
            self.cache[key] = {
                "back": down_pm(view, back), "body": down_pm(view, pm), "front": down_pm(view, front),
                "trail": trail_layers(view, self.path, float(t), weapon),
                "guard": view.px(g + d * spec["guard"]), "tip": view.px(g + d * be - e * spec["sori"]),
            }
        return self.cache[key]


# ---------------- 同场合成（与 V6 预览同背景、同目标、同受击特效） ----------------

def paste_pm(rgb, pm, origin):
    x, y = int(round(origin[0])), int(round(origin[1]))
    h, w = pm.shape[:2]
    H, W = rgb.shape[:2]
    x0, y0, x1, y1 = max(0, x), max(0, y), min(W, x + w), min(H, y + h)
    if x1 <= x0 or y1 <= y0:
        return
    cut = pm[y0 - y:y1 - y, x0 - x:x1 - x]
    rgb[y0:y1, x0:x1] = cut[..., :3] + rgb[y0:y1, x0:x1] * (1 - cut[..., 3:4])


def add_img(rgb, img, origin, gain=1.0):
    x, y = int(round(origin[0])), int(round(origin[1]))
    h, w = img.shape[:2]
    H, W = rgb.shape[:2]
    x0, y0, x1, y1 = max(0, x), max(0, y), min(W, x + w), min(H, y + h)
    if x1 > x0 and y1 > y0:
        rgb[y0:y1, x0:x1] += img[y0 - y:y1 - y, x0 - x:x1 - x] * gain


def run_scene(actor, weapon="katana", naked=False, enemy_gap=150, lead=12, tail=30, title="S2 第二版"):
    import preview_v6 as v6
    from art_v5.monster import READY as M_READY, RECOIL
    manifest = json.loads((v6.ASSETS / "manifest.json").read_text("utf-8"))
    bg = Image.open(ROOT / "art/environments/dungeon_hall.png").convert("RGB").crop((220, 226, 1020, 646))
    base = np.asarray(bg, np.float32) / 255
    enemy_x, enemy_age, enemy_cell = START_X + enemy_gap, None, M_READY
    origin = np.array([START_X - CANVAS[2][0], GROUND - CANVAS[2][1]], float)
    clock, freeze, frames, effects, contact = 0, 0, [], [], None
    locals_ = []
    total = lead + LENGTH + tail
    while clock < total:
        local = int(np.clip(clock - lead, 0, LENGTH - 1))
        moving = lead <= clock < lead + LENGTH
        L = actor.layers(local, weapon)
        target_root = np.array([enemy_x, GROUND])
        target_im, target_origin = v6.opponent(enemy_cell, target_root, enemy_age)
        guard, tip = origin + L["guard"], origin + L["tip"]
        if not naked and moving and contact is None and ACTIVE[0] <= local < ACTIVE[1]:
            point = v6.contact_at(guard, tip, target_im, target_origin, target_root)
            if point is not None:
                contact = {"tick": local, "point": np.round(point, 1).tolist()}
                freeze = HITSTOP
                enemy_age, enemy_cell = 0, RECOIL
                effects.append({"point": point.copy(), "age": 0})
                target_im, target_origin = v6.opponent(enemy_cell, target_root, 0)
        rgb = base.copy()
        tr = L["trail"]
        if not naked:
            v6.paste(rgb, target_im, target_origin)
            add_img(rgb, trail_rgb(tr["back"], tr["core_back"]), origin, 0.95)
        paste_pm(rgb, L["back"], origin)
        paste_pm(rgb, L["body"], origin)
        paste_pm(rgb, L["front"], origin)
        if not naked:
            add_img(rgb, trail_rgb(tr["front"], tr["core_front"]), origin, 0.95)
            for e in effects:
                v6.paint_clip(rgb, manifest, "hit_matter/light", e["age"], e["point"])
                v6.paint_clip(rgb, manifest, "hit_light/light", e["age"], e["point"])
        im = Image.fromarray(np.round(np.clip(rgb, 0, 1) * 255).astype(np.uint8))
        sub = "无特效·3D 驱动 + 武器图层" if naked else "命中演示（受击特效与目标沿用 V6）"
        frames.append(ra_label(im, f"{title}  {sub}   tick {local}"))
        locals_.append(local if moving else -1)
        for e in effects:
            e["age"] += 1
        effects = [e for e in effects if e["age"] < 40]
        if enemy_age is not None:
            enemy_age += 1
            if freeze == 0:
                if enemy_age < 16:
                    enemy_x += 0.7
                elif enemy_age >= 18:
                    enemy_cell = M_READY
        if freeze:
            freeze -= 1
        else:
            clock += 1
    return frames, contact, locals_


def ra_label(im, text, size=15):
    from preview_v5 import label
    return label(im, text, size)


def v6_frames(naked):
    import preview_v6 as v6
    manifest = json.loads((v6.ASSETS / "manifest.json").read_text("utf-8"))
    frames, marks, contacts = v6.render(["attack1"], manifest, naked=naked)
    return frames, marks, contacts


def side_by_side(a, b, vertical=True):
    n = max(len(a), len(b))
    a = a + [a[-1]] * (n - len(a))
    b = b + [b[-1]] * (n - len(b))
    out = []
    for x, y in zip(a, b):
        if vertical:
            c = Image.new("RGB", (max(x.width, y.width), x.height + y.height + 4), (8, 8, 12))
            c.paste(x, (0, 0))
            c.paste(y, (0, x.height + 4))
        else:
            c = Image.new("RGB", (x.width + y.width + 4, max(x.height, y.height)), (8, 8, 12))
            c.paste(x, (0, 0))
            c.paste(y, (x.width + 4, 0))
        out.append(c)
    return out


def encode_set(frames, stem, slow_crop=(120, 90, 690, 385)):
    from preview_v5 import encode
    OUT.mkdir(parents=True, exist_ok=True)
    encode(frames, 60, OUT / f"{stem}_realtime.gif", OUT / f"{stem}_60fps.mp4", gif_fps=30)
    print(f"[OK] {stem} realtime/60fps ({len(frames)} frames)")


def slow_set(frames, stem, crop, scale=2):
    from preview_v5 import encode
    zoom = [im.crop(crop).resize(((crop[2] - crop[0]) * scale, (crop[3] - crop[1]) * scale), Image.NEAREST)
            for im in frames]
    encode(zoom, 20, OUT / f"{stem}_slow.gif", OUT / f"{stem}_slow.mp4", gif_fps=20)
    print(f"[OK] {stem} slow")


def key_sheet(ours, theirs, path, ticks=(4, 7, 8, 9, 11, 15), crop=(150, 110, 530, 365), cols=None):
    """上 V6、下 S2 第二版，按动作 tick 取帧（停帧重复帧取第一张），同裁切、2 倍放大。

    ours / theirs：(frames, 每帧动作 tick 列表)。
    """
    def pick(pair, t):
        frames, ticks_ = pair
        idx = next((i for i, x in enumerate(ticks_) if x == t), len(frames) - 1)
        return frames[idx]
    tiles = []
    for pair, name in ((theirs, "V6"), (ours, "S2 第二版")):
        for t in ticks:
            im = pick(pair, t).crop(crop)
            im = im.resize((im.width * 2, im.height * 2), Image.LANCZOS)
            tiles.append(ra_label(im, f"{name}  tick {t}", 18))
    cols = cols or len(ticks)
    W, H = tiles[0].size
    rows = math.ceil(len(tiles) / cols)
    sheet = Image.new("RGB", (W * cols, H * rows), (8, 8, 12))
    for i, im in enumerate(tiles):
        sheet.paste(im, ((i % cols) * W, (i // cols) * H))
    sheet.save(path)
    print(f"[OK] {path.relative_to(ROOT)}")


def cmd_stills():
    rig = Rig()
    actor = Actor(rig, ATTACK1, ss=2)
    ticks = [int(a) for a in sys.argv[2:]] or [0, 4, 7, 8, 9, 10, 11, 15, 19, 24]
    tiles = []
    for t in ticks:
        L = actor.layers(t, "katana")
        rgb = np.full((CANVAS[1], CANVAS[0], 3), 0.80, np.float32)
        paste_pm(rgb, L["back"], (0, 0))
        paste_pm(rgb, L["body"], (0, 0))
        paste_pm(rgb, L["front"], (0, 0))
        rgb[CANVAS[2][1], :, :] = 0.5
        im = Image.fromarray(np.round(np.clip(rgb, 0, 1) * 255).astype(np.uint8)).crop((110, 60, 520, 320))
        im = im.resize((im.width * 2, im.height * 2), Image.LANCZOS)
        tiles.append(np.asarray(ra_label(im, f"tick {t}", 18)))
    OUT.mkdir(parents=True, exist_ok=True)
    Image.fromarray(ra.grid(tiles, 2)).save(OUT / "stills.png")
    print("[OK] stills.png")


def cmd_all():
    rig = Rig()
    actor = Actor(rig, ATTACK1, ss=3)
    report = {}
    naked, _, naked_t = run_scene(actor, naked=True)
    full, contact, full_t = run_scene(actor, naked=False)
    report["contact_katana"] = contact
    v6_naked, v6n_marks, _ = v6_frames(True)
    v6_full, v6f_marks, v6_contacts = v6_frames(False)
    report["contact_v6"] = v6_contacts
    v6n = (v6_naked, [m["tick"] for m in v6n_marks])
    v6f = (v6_full, [m["tick"] for m in v6f_marks])
    encode_set(side_by_side(v6_naked, naked), "cmp_naked")
    encode_set(side_by_side(v6_full, full), "cmp_full")
    slow_set(side_by_side(v6_naked, naked, vertical=False), "cmp_naked", (0, 0, 1604, 420), scale=1)
    key_sheet((naked, naked_t), v6n, OUT / "cmp_keyposes_naked.png", ticks=(0, 7, 8, 9, 11, 15), cols=3)
    key_sheet((full, full_t), v6f, OUT / "cmp_keyposes_full.png", ticks=(8, 9, 11), crop=(170, 90, 560, 370))
    rows = []
    for wname in ("katana", "greatsword", "shortsword"):
        frames, c, tks = run_scene(actor, weapon=wname, title="S2 第二版")
        report[f"contact_{wname}"] = c
        name = wp.WEAPONS[wname]["label"]
        rows.append([ra_label(f.crop((95, 0, 595, 420)), f"S2 第二版 + {name}   tick {max(tk, 0)}", 15)
                     for f, tk in zip(frames, tks)])
    n = min(len(r) for r in rows)
    still = []
    for t in (7, 9, 11):
        idx = next(i for i, x in enumerate(full_t) if x == t)
        c = Image.new("RGB", (1500 + 8, 420), (8, 8, 12))
        for i, r in enumerate(rows):
            c.paste(r[idx], (i * 504, 0))
        still.append(c)
    sheet = Image.new("RGB", (1508, 420 * 3 + 8), (8, 8, 12))
    for i, c in enumerate(still):
        sheet.paste(c, (0, i * 424))
    sheet.save(OUT / "weapons_keyposes.png")
    trip = []
    for k in range(n):
        c = Image.new("RGB", (1500 + 8, 420), (8, 8, 12))
        for i, r in enumerate(rows):
            c.paste(r[k], (i * 504, 0))
        trip.append(c)
    encode_set(trip, "weapons_full")
    (OUT / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=1), "utf-8")
    print(json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "stills"
    {"stills": cmd_stills, "all": cmd_all}[cmd]()
