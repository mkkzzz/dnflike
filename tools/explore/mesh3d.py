"""E4 探索：图生 3D 模型的加载、归一化、正交软光栅（延迟贴图）与简易蒙皮摆姿。

纯 numpy，不开窗口。坐标与 puppet.py 一致：x = 角色朝向，y = 上，z = 角色右侧，单位 cm。
"""
from __future__ import annotations

import math
from pathlib import Path

import numpy as np
from PIL import Image

import puppet as pp

Image.MAX_IMAGE_PIXELS = None


def load_obj(path):
    V, VT, FV, FT = [], [], [], []
    for line in Path(path).read_text("utf-8", errors="ignore").splitlines():
        if line.startswith("v "):
            V.append([float(x) for x in line.split()[1:4]])
        elif line.startswith("vt "):
            VT.append([float(x) for x in line.split()[1:3]])
        elif line.startswith("f "):
            idx = [p.split("/") for p in line.split()[1:]]
            for k in range(1, len(idx) - 1):
                tri = (idx[0], idx[k], idx[k + 1])
                FV.append([int(t[0]) - 1 for t in tri])
                FT.append([int(t[1]) - 1 if len(t) > 1 and t[1] else 0 for t in tri])
    return np.array(V, float), np.array(VT, float), np.array(FV, int), np.array(FT, int)


def facing_correction(V):
    """立绘多为 3/4 视角，模型身体并不正对 +x：用肩/腰/脚截面的左右轴 PCA 求修正角（度）。"""
    angs = []
    for lo, hi in ((120, 148), (95, 105), (10, 30)):
        P = V[(V[:, 1] > lo) & (V[:, 1] < hi)][:, [0, 2]]
        if len(P) < 50:
            continue
        _, _, vt = np.linalg.svd(P - P.mean(0), full_matrices=False)
        ax = vt[0] if vt[0][1] >= 0 else -vt[0]
        angs.append(math.degrees(math.atan2(ax[0], ax[1])))
    return -float(np.median(angs)) if angs else 0.0


def normalize(V, height=186.0, face_axis="+z", auto_facing=True):
    """把模型转成角色系：脚底 y=0、身高 height、朝向 +x、横向居中。"""
    V = V.copy()
    if face_axis == "+z":
        V = V @ pp.rot_y(90.0).T
    elif face_axis == "-z":
        V = V @ pp.rot_y(-90.0).T
    if auto_facing:
        lo0 = V[:, 1].min()
        Vn = (V - [0, lo0, 0]) * (height / (V[:, 1].max() - lo0))
        V = V @ pp.rot_y(facing_correction(Vn)).T
    lo, hi = V.min(0), V.max(0)
    s = height / (hi[1] - lo[1])
    V = (V - [0, lo[1], 0]) * s
    foot = V[V[:, 1] < 12.0]
    c = foot.mean(0) if len(foot) else V.mean(0)
    V[:, 0] -= c[0]
    V[:, 2] -= c[2]
    return V


class Tex:
    def __init__(self, path, max_size=2048):
        im = Image.open(path).convert("RGB")
        if max(im.size) > max_size:
            im = im.resize((max_size, max_size), Image.LANCZOS)
        self.img = np.asarray(im, np.float32) / 255.0
        self.h, self.w = self.img.shape[:2]

    def sample(self, uv):
        x = np.clip(uv[..., 0], 0, 1) * (self.w - 1)
        y = (1 - np.clip(uv[..., 1], 0, 1)) * (self.h - 1)
        x0 = np.floor(x).astype(int)
        y0 = np.floor(y).astype(int)
        x1 = np.minimum(x0 + 1, self.w - 1)
        y1 = np.minimum(y0 + 1, self.h - 1)
        fx, fy = (x - x0)[..., None], (y - y0)[..., None]
        im = self.img
        return ((im[y0, x0] * (1 - fx) + im[y0, x1] * fx) * (1 - fy) + (im[y1, x0] * (1 - fx) + im[y1, x1] * fx) * fy)


def vertex_normals(V, F):
    fn = np.cross(V[F[:, 1]] - V[F[:, 0]], V[F[:, 2]] - V[F[:, 0]])
    vn = np.zeros_like(V)
    for k in range(3):
        np.add.at(vn, F[:, k], fn)
    return vn / (np.linalg.norm(vn, axis=1, keepdims=True) + 1e-9)


def raster(view, V, F, batch_k=10):
    """返回每像素 (z, tri, w1, w2)，透视无关的正交重心坐标；超采样分辨率。"""
    C = V @ view.R.T
    sx = view.ox + C[:, 0] * view.scale
    sy = view.oy - C[:, 1] * view.scale
    sz = C[:, 2]
    H, W = view.h, view.w
    zb = np.full(H * W, -np.inf, np.float32)
    tb = np.full(H * W, -1, np.int32)
    w1b = np.zeros(H * W, np.float32)
    w2b = np.zeros(H * W, np.float32)
    x0, y0 = sx[F], sy[F]
    bx0 = np.floor(x0.min(1)).astype(int)
    by0 = np.floor(y0.min(1)).astype(int)
    bw = np.ceil(x0.max(1)).astype(int) - bx0 + 1
    bh = np.ceil(y0.max(1)).astype(int) - by0 + 1
    ax, ay = x0[:, 0], y0[:, 0]
    e1x, e1y = x0[:, 1] - ax, y0[:, 1] - ay
    e2x, e2y = x0[:, 2] - ax, y0[:, 2] - ay
    den = e1x * e2y - e2x * e1y
    ok = np.abs(den) > 1e-9
    groups = [(np.where(ok & (np.maximum(bw, bh) <= batch_k))[0], batch_k)]
    big = np.where(ok & (np.maximum(bw, bh) > batch_k))[0]
    sizes = np.maximum(bw[big], bh[big])
    for k in (24, 64, 160, 512, 4096):
        sel = big[(sizes <= k) & (sizes > (groups[-1][1] if groups else 0))]
        if len(sel):
            groups.append((sel, k))
    for idx, k in groups:
        for start in range(0, len(idx), max(1, 400000 // (k * k))):
            ii = idx[start:start + max(1, 400000 // (k * k))]
            gx, gy = np.meshgrid(np.arange(k), np.arange(k))
            px = bx0[ii, None, None] + gx[None]
            py = by0[ii, None, None] + gy[None]
            cx = px + 0.5 - ax[ii, None, None]
            cy = py + 0.5 - ay[ii, None, None]
            d = den[ii, None, None]
            w1 = (cx * e2y[ii, None, None] - e2x[ii, None, None] * cy) / d
            w2 = (e1x[ii, None, None] * cy - cx * e1y[ii, None, None]) / d
            w0 = 1 - w1 - w2
            inside = (w0 >= -1e-4) & (w1 >= -1e-4) & (w2 >= -1e-4) & (px >= 0) & (px < W) & (py >= 0) & (py < H)
            if not inside.any():
                continue
            tz = sz[F[ii]]
            z = w0 * tz[:, 0, None, None] + w1 * tz[:, 1, None, None] + w2 * tz[:, 2, None, None]
            tri = np.broadcast_to(ii[:, None, None], inside.shape)
            pix = (py * W + px)[inside]
            zz, tt, a1, a2 = z[inside], tri[inside], w1[inside], w2[inside]
            order = np.argsort(zz)
            pix, zz, tt, a1, a2 = pix[order], zz[order], tt[order], a1[order], a2[order]
            cur = zb[pix]
            m = zz > cur
            pix, zz, tt, a1, a2 = pix[m], zz[m], tt[m], a1[m], a2[m]
            zb[pix] = zz
            tb[pix] = tt
            w1b[pix] = a1
            w2b[pix] = a2
    return zb.reshape(H, W), tb.reshape(H, W), w1b.reshape(H, W), w2b.reshape(H, W)


def shade_mesh(view, V, F, VT, FT, tex, toon=True, outline=True, vn=None, line_px=0):
    """贴图 + 赛璐璐二阶明暗 + 深度轮廓线，返回超采样 premultiplied float 与 z。

    line_px：轮廓线在超采样空间额外加粗的像素数。
    """
    zb, tb, w1, w2 = raster(view, V, F)
    m = tb >= 0
    out = np.zeros(zb.shape + (4,), np.float32)
    if not m.any():
        return out, zb
    t = tb[m]
    a1, a2 = w1[m][:, None], w2[m][:, None]
    a0 = 1 - a1 - a2
    uv = VT[FT[t, 0]] * a0 + VT[FT[t, 1]] * a1 + VT[FT[t, 2]] * a2
    col = tex.sample(uv)
    if vn is None:
        vn = vertex_normals(V, F)
    n = vn[F[t, 0]] * a0 + vn[F[t, 1]] * a1 + vn[F[t, 2]] * a2
    n = n @ view.R.T
    n /= np.linalg.norm(n, axis=1, keepdims=True) + 1e-9
    ndl = n @ pp.LIGHT
    if toon:
        lit = np.clip((ndl + 0.1) / 0.18, 0, 1)
        tone = 0.72 + 0.34 * lit
    else:
        tone = 0.55 + 0.55 * np.clip(ndl, 0, 1)
    rgb = np.clip(col * tone[:, None], 0, 1)
    out[m, :3] = rgb
    out[m, 3] = 1.0
    if outline:
        z = np.where(m, zb, -1e4)
        e = np.zeros(m.shape, bool)
        lim = 2.0
        for dy, dx in ((0, 1), (1, 0)):
            za, zc = z[: z.shape[0] - dy, : z.shape[1] - dx], z[dy:, dx:]
            d = np.abs(za - zc) > lim
            e[: e.shape[0] - dy, : e.shape[1] - dx] |= d
            e[dy:, dx:] |= d
        for _ in range(line_px):
            g = e.copy()
            g[1:] |= e[:-1]
            g[:-1] |= e[1:]
            g[:, 1:] |= e[:, :-1]
            g[:, :-1] |= e[:, 1:]
            e = g
        e &= m
        out[e, :3] = pp.OUTLINE / 255.0
    return out, zb


# ---------------- 蒙皮 ----------------

BONES = [
    ("pelvis", "waist"), ("waist", "chest"), ("chest", "neck_base"), ("neck_base", "head"),
    ("sh_r", "el_r"), ("el_r", "grip_r"), ("sh_l", "el_l"), ("el_l", "grip_l"),
    ("hip_r", "knee_r"), ("knee_r", "ankle_r"), ("ankle_r", "toe_r"),
    ("hip_l", "knee_l"), ("knee_l", "ankle_l"), ("ankle_l", "toe_l"),
    ("chest", "sh_r"), ("chest", "sh_l"), ("pelvis", "hip_r"), ("pelvis", "hip_l"),
]


def _seg_dist(P, a, b):
    ab = b - a
    t = np.clip(((P - a) @ ab) / max(float(ab @ ab), 1e-9), 0, 1)
    return np.linalg.norm(P - (a + t[:, None] * ab), axis=1), t


def bone_frame(a, b, ref):
    y = pp.unit(b - a)
    x = ref - y * float(y @ ref)
    if np.linalg.norm(x) < 1e-6:
        x = np.cross(y, [0.0, 0.0, 1.0])
    x = pp.unit(x)
    return np.column_stack([x, y, np.cross(x, y)])


def bone_frames(j):
    fr = []
    fwd_body = j["P"] @ [1.0, 0, 0]
    fwd_chest = j["C"] @ [1.0, 0, 0]
    for a, b in BONES:
        if a in ("sh_r", "el_r"):
            ref = j["blade"][1] if a == "el_r" else fwd_chest
        elif a in ("hip_r", "knee_r", "hip_l", "knee_l", "ankle_r", "ankle_l", "pelvis"):
            ref = fwd_body
        else:
            ref = fwd_chest
        fr.append((np.asarray(j[a], float), bone_frame(np.asarray(j[a], float), np.asarray(j[b], float), ref)))
    return fr


def skin_weights(V, j_rest, falloff=3.0, k=3):
    D = np.stack([_seg_dist(V, np.asarray(j_rest[a], float), np.asarray(j_rest[b], float))[0] for a, b in BONES], 1)
    D[:, 14:] *= 1.35
    idx = np.argsort(D, axis=1)[:, :k]
    d = np.take_along_axis(D, idx, 1)
    w = 1.0 / np.power(d + 1.5, falloff)
    w /= w.sum(1, keepdims=True)
    return idx, w


def find_sword(V, front_x=45.0, max_y=95.0, radius=4.5):
    """模型里与手融合的刀：取身体前方远端的顶点做 PCA 拟合刀线，再沿线收集半径内的顶点。"""
    seed = V[(V[:, 0] > front_x) & (V[:, 1] < max_y)]
    c = seed.mean(0)
    _, _, vt = np.linalg.svd(seed - c, full_matrices=False)
    d = pp.unit(vt[0])
    if d[0] < 0:
        d = -d
    t = (V - c) @ d
    dist = np.linalg.norm((V - c) - t[:, None] * d, axis=1)
    sel = dist < radius
    return sel, c, d, t


def vertex_colors(V, F, VT, FT, tex):
    col = np.zeros((len(V), 3))
    cnt = np.zeros(len(V))
    for k in range(3):
        c = tex.sample(VT[FT[:, k]])
        np.add.at(col, F[:, k], c)
        np.add.at(cnt, F[:, k], 1)
    return col / np.maximum(cnt, 1)[:, None]


def strip_weapon(V, F, VT, FT, tex, grip, hand_r=6.0):
    """剥离模型里融合的刀身：沿拟合刀线、且颜色为金属灰的顶点；保留握拳手指。刀柄与刀穗不处理。"""
    _, c, d, t = find_sword(V)
    t_hand = float((np.asarray(grip) - c) @ d)
    line_d = np.linalg.norm((V - c) - t[:, None] * d, axis=1)
    col = vertex_colors(V, F, VT, FT, tex)
    mx, mn = col.max(1), col.min(1)
    metal = (mx > 0.28) & ((mx - mn) < 0.16)
    near_hand = np.linalg.norm(V - np.asarray(grip), axis=1) < hand_r
    blade = (t > t_hand + 2.0) & (((line_d < 7.0) & metal) | (line_d < 3.6))
    remove = blade & ~near_hand
    keep = ~remove[F].any(1)
    return keep, remove


def rigid_override(idx, w, sel, bone_index):
    idx = idx.copy()
    w = w.copy()
    idx[sel] = bone_index
    w[sel] = 0.0
    w[sel, 0] = 1.0
    return idx, w


def pose_mesh(V, idx, w, rest_frames, pose_frames):
    out = np.zeros_like(V)
    mats = []
    for (ra, rf), (pa, pf) in zip(rest_frames, pose_frames):
        M = pf @ rf.T
        mats.append((M, pa - M @ ra))
    Ms = np.stack([m for m, _ in mats])
    Ts = np.stack([t for _, t in mats])
    for k in range(idx.shape[1]):
        bi = idx[:, k]
        out += w[:, k:k + 1] * (np.einsum("nij,nj->ni", Ms[bi], V) + Ts[bi])
    return out
