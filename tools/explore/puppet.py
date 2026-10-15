"""探索原型：参数化人偶 + IK 摆姿 + numpy 正交渲染（不开任何窗口）。

仅用于"角色锚定与动作管线"技术探索，不是生产管线。
单位 cm。片段世界系：x = 角色朝向（面朝右时即屏幕右），y = 上，
z = 角色右侧（面朝右时朝向镜头）。所有转职 / 外观共用 BODY 体型契约。
"""
from __future__ import annotations

import math

import numpy as np

BODY = {
    "ankle_h": 8.0,
    "shin": 44.0,
    "thigh": 43.0,
    "hip_half": 9.5,
    "pelvis_up": 3.0,
    "waist": 14.0,
    "chest": 16.0,
    "neck_base": 19.0,
    "shoulder_up": 14.0,
    "shoulder_half": 18.0,
    "upper_arm": 29.0,
    "forearm_grip": 31.0,
    "neck": 6.0,
    "foot": 17.0,
    "heel": 5.0,
}

# 部件 ID 按"可换装槽位"划分，为以后的时装混搭预留掩码边界
PARTS = {
    "face": 1, "hair": 2, "neck": 3, "torso": 4, "coat": 5, "pants": 6,
    "thigh_l": 7, "thigh_r": 8, "shin_l": 9, "shin_r": 10, "boot_l": 11, "boot_r": 12,
    "uarm_l": 13, "uarm_r": 14, "farm_l": 15, "farm_r": 16, "hand_l": 17, "hand_r": 18,
    "weapon": 20,
}
SLOT_OF_PART = {
    "face": "head", "neck": "head", "hair": "hair",
    "torso": "top", "coat": "top", "uarm_l": "top", "uarm_r": "top", "farm_l": "top",
    "farm_r": "arm_accessory", "hand_r": "arm_accessory", "hand_l": "gloves",
    "pants": "bottom", "thigh_l": "bottom", "thigh_r": "bottom", "shin_l": "bottom", "shin_r": "bottom",
    "boot_l": "shoes", "boot_r": "shoes", "weapon": "weapon",
}

# 标杆身份色（hero_cool：银白发、黑皮衣、持刀的右前臂缠红绷带、黑柄刀）
IDENTITY_COLORS = {
    "face": (236, 204, 186), "neck": (226, 194, 176), "hair": (226, 229, 236),
    "torso": (46, 42, 50), "coat": (38, 35, 42), "pants": (50, 50, 60),
    "thigh_l": (46, 46, 56), "thigh_r": (50, 50, 60), "shin_l": (46, 46, 56), "shin_r": (50, 50, 60),
    "boot_l": (30, 27, 30), "boot_r": (32, 29, 32),
    "uarm_l": (42, 38, 46), "uarm_r": (46, 42, 50), "farm_l": (42, 38, 46), "farm_r": (156, 38, 40),
    "hand_l": (36, 32, 36), "hand_r": (150, 34, 36), "weapon": (200, 206, 214),
}

SEG_COLORS = {
    "face": (255, 200, 160), "hair": (240, 240, 255), "neck": (230, 170, 140),
    "torso": (40, 90, 200), "coat": (20, 50, 140), "pants": (120, 60, 160),
    "thigh_l": (90, 40, 130), "thigh_r": (160, 90, 210), "shin_l": (60, 120, 60), "shin_r": (110, 200, 110),
    "boot_l": (110, 70, 30), "boot_r": (190, 130, 60),
    "uarm_l": (30, 120, 130), "uarm_r": (60, 200, 210), "farm_l": (180, 30, 30), "farm_r": (240, 120, 120),
    "hand_l": (150, 150, 20), "hand_r": (250, 240, 60), "weapon": (255, 255, 255),
}
PART_NAMES = {v: k for k, v in PARTS.items()}


def rot_x(deg):
    a = math.radians(deg)
    c, s = math.cos(a), math.sin(a)
    return np.array([[1, 0, 0], [0, c, -s], [0, s, c]], float)


def rot_y(deg):
    a = math.radians(deg)
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]], float)


def rot_z(deg):
    a = math.radians(deg)
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]], float)


def unit(v):
    v = np.asarray(v, float)
    n = np.linalg.norm(v)
    return v / n if n > 1e-9 else v


def ortho(primary, secondary):
    a = unit(primary)
    b = np.asarray(secondary, float)
    b = b - a * float(a @ b)
    if np.linalg.norm(b) < 1e-6:
        b = np.cross(a, [0.0, 0.0, 1.0])
    b = unit(b)
    return a, b, np.cross(a, b)


def slerp(a, b, s):
    a, b = unit(a), unit(b)
    d = float(np.clip(a @ b, -1.0, 1.0))
    w = math.acos(d)
    if w < 1e-4:
        return unit(a + (b - a) * s)
    return unit((math.sin((1 - s) * w) * a + math.sin(s * w) * b) / math.sin(w))


def two_bone_ik(root, target, l1, l2, pole):
    root = np.asarray(root, float)
    d = np.asarray(target, float) - root
    length = float(np.clip(np.linalg.norm(d), abs(l1 - l2) + 1e-3, l1 + l2 - 1e-3))
    dirv = unit(d)
    cos_a = (l1 * l1 + length * length - l2 * l2) / (2 * l1 * length)
    sin_a = math.sqrt(max(0.0, 1 - cos_a * cos_a))
    pole = np.asarray(pole, float)
    pp = pole - dirv * float(dirv @ pole)
    if np.linalg.norm(pp) < 1e-6:
        pp = np.cross(dirv, [0.0, 0.0, 1.0])
    pp = unit(pp)
    mid = root + l1 * (cos_a * dirv + sin_a * pp)
    return mid, root + dirv * length


# ---------------- 关键帧与插值 ----------------

SCALARS = ["root_x", "pelvis_h", "pelvis_dx", "pelvis_dz", "pelvis_yaw", "pelvis_lean", "pelvis_roll",
           "chest_yaw", "chest_lean", "chest_roll", "head_yaw", "head_lean"]
POINTS = ["hand_r", "hand_l", "foot_r", "foot_l", "coat"]
DIRS = ["blade_dir", "blade_edge", "pole_r", "pole_l", "foot_r_dir", "foot_l_dir"]

DEFAULT_POSE = {
    "root_x": 0.0, "pelvis_h": 98.0, "pelvis_dx": 0.0, "pelvis_dz": 0.0, "pelvis_yaw": 0.0,
    "pelvis_lean": 0.0, "pelvis_roll": 0.0, "chest_yaw": 0.0, "chest_lean": 0.0, "chest_roll": 0.0,
    "head_yaw": 0.0, "head_lean": 0.0,
    "hand_r": (4.0, 84.0, 24.0), "hand_l": (4.0, 84.0, -24.0),
    "foot_r": (0.0, 0.0, 10.0), "foot_l": (0.0, 0.0, -10.0), "coat": (0.0, 0.0, 0.0),
    "blade_dir": (1.0, 0.0, 0.0), "blade_edge": (0.0, -1.0, 0.0),
    "pole_r": (-0.3, -1.0, 0.7), "pole_l": (-0.3, -1.0, -0.7),
    "foot_r_dir": (1.0, 0.0, 0.1), "foot_l_dir": (1.0, 0.0, -0.1),
}

EASES = {
    "linear": lambda s: s,
    "inout": lambda s: s * s * (3 - 2 * s),
    "in": lambda s: s * s,
    "out": lambda s: 1 - (1 - s) * (1 - s),
    "snap": lambda s: 1 - (1 - s) ** 4,
    "step": lambda s: 0.0,
}


def build_keys(raw):
    """raw: [(tick, ease, {fields})]，未写的字段沿用上一帧。"""
    keys, cur = [], dict(DEFAULT_POSE)
    for tick, ease, fields in raw:
        cur = dict(cur)
        cur.update(fields)
        keys.append((float(tick), ease, cur))
    return keys


def _catmull(p0, p1, p2, p3, s):
    p0, p1, p2, p3 = (np.asarray(p, float) for p in (p0, p1, p2, p3))
    s2, s3 = s * s, s * s * s
    return 0.5 * ((2 * p1) + (-p0 + p2) * s + (2 * p0 - 5 * p1 + 4 * p2 - p3) * s2 + (-p0 + 3 * p1 - 3 * p2 + p3) * s3)


def sample(keys, t):
    if t <= keys[0][0]:
        return dict(keys[0][2])
    if t >= keys[-1][0]:
        return dict(keys[-1][2])
    i = max(j for j in range(len(keys) - 1) if keys[j][0] <= t)
    t0, _, a = keys[i]
    t1, ease, b = keys[i + 1]
    s = EASES[ease]((t - t0) / (t1 - t0))
    pa = keys[i - 1][2] if i > 0 else a
    pb = keys[i + 2][2] if i + 2 < len(keys) else b
    out = {}
    for k in SCALARS:
        out[k] = a[k] + (b[k] - a[k]) * s
    for k in POINTS:
        out[k] = _catmull(pa[k], a[k], b[k], pb[k], s)
    for k in DIRS:
        out[k] = slerp(a[k], b[k], s)
    return out


# ---------------- 骨架求解 ----------------

def solve(p):
    B = BODY
    P = rot_y(p["pelvis_yaw"]) @ rot_z(-p["pelvis_lean"]) @ rot_x(p["pelvis_roll"])
    pelvis = np.array([p["root_x"] + p["pelvis_dx"], p["pelvis_h"], p["pelvis_dz"]])
    C = P @ rot_y(p["chest_yaw"]) @ rot_z(-p["chest_lean"]) @ rot_x(p["chest_roll"])
    waist = pelvis + P @ [0, B["waist"], 0]
    chest = waist + C @ [0, B["chest"], 0]
    neck_base = chest + C @ [0, B["neck_base"], 0]
    H = C @ rot_y(p["head_yaw"]) @ rot_z(-p["head_lean"])
    neck_top = neck_base + H @ [0, B["neck"], 0]
    head = neck_top + H @ [1.5, 10.0, 0]
    j = {"P": P, "C": C, "H": H, "pelvis": pelvis, "waist": waist, "chest": chest,
         "neck_base": neck_base, "neck_top": neck_top, "head": head}
    for side, sz in (("r", 1.0), ("l", -1.0)):
        sh = chest + C @ [0, B["shoulder_up"], sz * B["shoulder_half"]]
        el, gr = two_bone_ik(sh, p["hand_" + side], B["upper_arm"], B["forearm_grip"], p["pole_" + side])
        hip = pelvis + P @ [0, -B["pelvis_up"], sz * B["hip_half"]]
        foot = np.asarray(p["foot_" + side], float)
        ankle_t = foot + [0, B["ankle_h"], 0]
        knee_pole = P @ [1.0, 0.0, 0.25 * sz]
        kn, an = two_bone_ik(hip, ankle_t, B["thigh"], B["shin"], knee_pole)
        fd = unit(np.asarray(p["foot_" + side + "_dir"], float) * [1, 0, 1])
        j.update({"sh_" + side: sh, "el_" + side: el, "grip_" + side: gr, "hip_" + side: hip,
                  "knee_" + side: kn, "ankle_" + side: an,
                  "heel_" + side: an + fd * -B["heel"] + [0, -4.5, 0],
                  "toe_" + side: an + fd * B["foot"] + [0, -5.0, 0]})
    j["coat"] = np.asarray(p["coat"], float)
    d, e, n = ortho(p["blade_dir"], p["blade_edge"])
    j["blade"] = (j["grip_r"], d, e, n)
    return j


# ---------------- 体素基元 ----------------

def build_prims(j, coat=True):
    """返回 [(kind, part, data)]；kind: ell(中心, 3x3 轴矩阵) / cap(p0, r0, p1, r1)。"""
    pr = []
    H, C, P = j["H"], j["C"], j["P"]

    def ell(part, center, frame, radii):
        pr.append(("ell", part, (np.asarray(center, float), frame @ np.diag(radii))))

    def cap(part, a, ra, b, rb):
        pr.append(("cap", part, (np.asarray(a, float), ra, np.asarray(b, float), rb)))

    ell("face", j["head"], H, (9.0, 11.0, 8.6))
    ell("hair", j["head"] + H @ [-2.2, 3.2, 0], H, (9.8, 10.2, 9.6))
    for d, ln in (((-0.9, 0.42, 0.2), 15.0), ((-0.7, 0.7, 0.4), 14.0), ((-0.75, 0.62, -0.4), 14.0),
                  ((-0.3, 0.95, 0.15), 13.0), ((-0.98, 0.1, 0.3), 13.0), ((-0.98, 0.15, -0.3), 13.0),
                  ((0.55, 0.8, 0.25), 9.0), ((0.6, 0.72, -0.2), 8.0), ((0.15, 0.98, -0.1), 11.0)):
        base = j["head"] + H @ [-1.0, 4.5, 0]
        cap("hair", base, 5.0, base + H @ (unit(d) * ln), 1.0)
    cap("neck", j["neck_base"], 4.6, j["neck_top"], 4.2)
    ell("torso", j["neck_base"] + C @ [0, -1.0, 0], C, (8.0, 6.5, 9.0))
    ell("torso", j["chest"] + C @ [0, 5.5, 0], C, (10.5, 13.5, 15.5))
    ell("torso", j["waist"] + P @ [0, 3.0, 0], P, (9.6, 10.0, 13.2))
    ell("pants", j["pelvis"] + P @ [0, -2.0, 0], P, (10.6, 9.0, 14.6))
    for side in ("r", "l"):
        sh, el, gr = j["sh_" + side], j["el_" + side], j["grip_" + side]
        fdir = unit(gr - el)
        wrist = gr - fdir * 4.0
        cap("uarm_" + side, sh, 6.0, el, 4.5)
        cap("farm_" + side, el, 4.5, wrist, 3.6)
        fa, fb, fc = ortho(fdir, j["blade"][1] if side == "r" else C @ [1, 0, 0])
        ell("hand_" + side, gr - fdir * 0.5, np.column_stack([fb, fa, fc]), (4.3, 5.0, 3.9))
        cap("thigh_" + side, j["hip_" + side], 9.4, j["knee_" + side], 6.4)
        cap("shin_" + side, j["knee_" + side], 6.3, j["ankle_" + side], 4.4)
        cap("boot_" + side, j["heel_" + side], 4.2, j["toe_" + side], 3.4)
        cap("boot_" + side, j["ankle_" + side] + [0, 6, 0], 4.8, j["heel_" + side], 4.2)
    if coat:
        hem = j["coat"]
        for phi in range(60, 301, 30):
            a = math.radians(phi)
            top = j["pelvis"] + P @ [10.0 * math.cos(a), 10.0, 14.0 * math.sin(a)]
            flare = P @ [7.0 * math.cos(a), 0.0, 6.0 * math.sin(a)]
            bottom = top + flare + [0, -50.0, 0] + hem
            cap("coat", top, 5.6, bottom, 4.6)
    return pr


# ---------------- 正交渲染 ----------------

class View:
    """yaw/pitch 为相机绕角色的角度；yaw=-25 即游戏机位（略见正面），-90 正面，0 右侧，90 背面。"""

    def __init__(self, w, h, scale, origin, yaw=-25.0, pitch=10.0, ss=2):
        self.ss = ss
        self.w, self.h = w * ss, h * ss
        self.out_w, self.out_h = w, h
        self.scale = scale * ss
        self.ox, self.oy = origin[0] * ss, origin[1] * ss
        self.R = rot_x(pitch) @ rot_y(yaw)

    def cam(self, p):
        return self.R @ np.asarray(p, float)

    def px(self, p):
        c = self.cam(p)
        return np.array([(self.ox + c[0] * self.scale) / self.ss, (self.oy - c[1] * self.scale) / self.ss])


class Buffers:
    def __init__(self, view):
        self.v = view
        self.z = np.full((view.h, view.w), -np.inf, np.float32)
        self.part = np.zeros((view.h, view.w), np.int16)
        self.nrm = np.zeros((view.h, view.w, 3), np.float32)

    def _grid(self, cx, cy, r):
        v = self.v
        x0 = int(max(0, math.floor(v.ox + (cx - r) * v.scale)))
        x1 = int(min(v.w, math.ceil(v.ox + (cx + r) * v.scale) + 1))
        y0 = int(max(0, math.floor(v.oy - (cy + r) * v.scale)))
        y1 = int(min(v.h, math.ceil(v.oy - (cy - r) * v.scale) + 1))
        if x1 <= x0 or y1 <= y0:
            return None
        xs = (np.arange(x0, x1) + 0.5 - v.ox) / v.scale
        ys = (v.oy - (np.arange(y0, y1) + 0.5)) / v.scale
        X, Y = np.meshgrid(xs, ys)
        return (slice(y0, y1), slice(x0, x1)), X, Y

    def _commit(self, sl, mask, z, n, part_id):
        zb = self.z[sl]
        upd = mask & (z > zb)
        if not upd.any():
            return
        zb[upd] = z[upd]
        self.part[sl][upd] = part_id
        self.nrm[sl][upd] = n[upd]

    def sphere(self, c, r, part_id):
        g = self._grid(c[0], c[1], r)
        if g is None:
            return
        sl, X, Y = g
        dx, dy = X - c[0], Y - c[1]
        d2 = dx * dx + dy * dy
        m = d2 < r * r
        if not m.any():
            return
        dz = np.sqrt(np.maximum(r * r - d2, 0.0))
        n = np.stack([dx, dy, dz], -1) / r
        self._commit(sl, m, c[2] + dz, n, part_id)

    def ellipsoid(self, c, A, part_id):
        r = float(np.max(np.linalg.norm(A, axis=0)))
        g = self._grid(c[0], c[1], r)
        if g is None:
            return
        sl, X, Y = g
        Ai = np.linalg.inv(A)
        q0 = (Ai[:, 0, None, None] * (X - c[0]) + Ai[:, 1, None, None] * (Y - c[1]) - Ai[:, 2, None, None] * c[2])
        dq = Ai[:, 2]
        a = float(dq @ dq)
        b = 2 * np.einsum("i,ijk->jk", dq, q0)
        cc = np.einsum("ijk,ijk->jk", q0, q0) - 1.0
        disc = b * b - 4 * a * cc
        m = disc > 0
        if not m.any():
            return
        t = (-b + np.sqrt(np.maximum(disc, 0.0))) / (2 * a)
        p = np.stack([X - c[0], Y - c[1], t - c[2]], -1)
        n = p @ (Ai.T @ Ai).T
        n /= np.linalg.norm(n, axis=-1, keepdims=True) + 1e-9
        self._commit(sl, m, t, n, part_id)

    def capsule(self, a, ra, b, rb, part_id):
        length = float(np.linalg.norm(b - a))
        steps = max(2, int(math.ceil(length / (min(ra, rb) * 0.3))) + 1)
        for s in np.linspace(0.0, 1.0, steps):
            self.sphere(a + (b - a) * s, ra + (rb - ra) * s, part_id)


def rasterize(view, prims):
    buf = Buffers(view)
    for kind, part, data in prims:
        pid = PARTS[part]
        if kind == "ell":
            c, A = data
            buf.ellipsoid(view.cam(c), view.R @ A, pid)
        else:
            a, ra, b, rb = data
            buf.capsule(view.cam(a), ra, view.cam(b), rb, pid)
    return buf


# ---------------- 着色与引导图 ----------------

LIGHT = unit([-0.45, 0.65, 0.6])
OUTLINE = np.array([22, 18, 26], np.float32)


def _down(img, ss):
    if ss == 1:
        return img
    h, w = img.shape[0] // ss, img.shape[1] // ss
    return img[: h * ss, : w * ss].reshape(h, ss, w, ss, -1).mean(axis=(1, 3))


def _edges(buf, depth_jump=2.5):
    part = buf.part
    z = np.where(np.isfinite(buf.z), buf.z, -1e4)
    e = np.zeros(part.shape, bool)
    for dy, dx in ((0, 1), (1, 0)):
        pa = part[: part.shape[0] - dy, : part.shape[1] - dx]
        pb = part[dy:, dx:]
        za = z[: z.shape[0] - dy, : z.shape[1] - dx]
        zb = z[dy:, dx:]
        diff = (pa != pb) | (np.abs(za - zb) > depth_jump)
        diff &= (pa > 0) | (pb > 0)
        e[: e.shape[0] - dy, : e.shape[1] - dx] |= diff
        e[dy:, dx:] |= diff
    return e


def downsample_pm(view, pm):
    """premultiplied 超采样 float → straight RGBA uint8 输出分辨率。"""
    ss = view.ss
    h, w = pm.shape[0] // ss, pm.shape[1] // ss
    d = pm[: h * ss, : w * ss].reshape(h, ss, w, ss, 4).mean(axis=(1, 3))
    a = d[..., 3:4]
    rgb = d[..., :3] / np.maximum(a, 1e-6)
    return (np.clip(np.concatenate([rgb, a], -1), 0, 1) * 255).astype(np.uint8)


def over(dst, src):
    """premultiplied 叠加：src 盖在 dst 上。"""
    return src + dst * (1.0 - src[..., 3:4])


def shade_pm(buf, colors=IDENTITY_COLORS, outline=True, skip=("weapon",)):
    """赛璐璐二阶明暗 + 轮廓线，返回超采样 premultiplied float（0..1）。"""
    part = buf.part
    base = np.zeros(part.shape + (3,), np.float32)
    for name, pid in PARTS.items():
        if name not in skip:
            base[part == pid] = colors.get(name, (128, 128, 128))
    ndl = buf.nrm @ LIGHT
    lit = np.clip((ndl + 0.05) / 0.25, 0, 1)
    tone = 0.58 + 0.42 * lit
    rgb = base * tone[..., None] / 255.0
    alpha = ((part > 0) & ~np.isin(part, [PARTS[s] for s in skip])).astype(np.float32)
    if outline:
        e = _edges(buf) & (alpha > 0)
        grow = e.copy()
        grow[:, 1:] |= e[:, :-1]
        grow[1:, :] |= e[:-1, :]
        rgb[grow & (alpha > 0)] = OUTLINE / 255.0
    return np.concatenate([rgb * alpha[..., None], alpha[..., None]], -1)


def shade(buf, colors=IDENTITY_COLORS, outline=True):
    """赛璐璐二阶明暗 + 轮廓线，返回 straight-alpha RGBA uint8（输出分辨率）。"""
    return downsample_pm(buf.v, shade_pm(buf, colors, outline, skip=()))


def seg_image(buf):
    out = np.zeros(buf.part.shape + (3,), np.uint8)
    for name, pid in PARTS.items():
        out[buf.part == pid] = SEG_COLORS[name]
    return out[:: buf.v.ss, :: buf.v.ss]


def depth_image(buf):
    z = buf.z
    m = np.isfinite(z)
    out = np.zeros(z.shape, np.float32)
    if m.any():
        lo, hi = float(z[m].min()), float(z[m].max())
        out[m] = 0.25 + 0.75 * (z[m] - lo) / max(hi - lo, 1e-6)
    return (np.clip(_down(out[..., None], buf.v.ss)[..., 0], 0, 1) * 255).astype(np.uint8)


def normal_image(buf):
    n = (buf.nrm * 0.5 + 0.5) * (buf.part > 0)[..., None]
    n[buf.part == 0] = (0.5, 0.5, 1.0)
    return (np.clip(_down(n, buf.v.ss), 0, 1) * 255).astype(np.uint8)


def line_image(buf):
    e = _edges(buf, depth_jump=1.5).astype(np.float32)
    v = 1.0 - _down(e[..., None], buf.v.ss)[..., 0]
    return (np.clip(v, 0, 1) * 255).astype(np.uint8)


OPENPOSE_PAIRS = [(1, 2), (1, 5), (2, 3), (3, 4), (5, 6), (6, 7), (1, 8), (8, 9), (9, 10), (1, 11), (11, 12),
                  (12, 13), (1, 0), (0, 14), (14, 16), (0, 15), (15, 17)]
OPENPOSE_COLORS = [(255, 0, 0), (255, 85, 0), (255, 170, 0), (255, 255, 0), (170, 255, 0), (85, 255, 0),
                   (0, 255, 0), (0, 255, 85), (0, 255, 170), (0, 255, 255), (0, 170, 255), (0, 85, 255),
                   (0, 0, 255), (85, 0, 255), (170, 0, 255), (255, 0, 255), (255, 0, 170), (255, 0, 85)]


def openpose_points(j):
    H = j["H"]
    head = j["head"]
    return [head + H @ [8.5, -1.0, 0], j["neck_base"], j["sh_r"], j["el_r"], j["grip_r"], j["sh_l"], j["el_l"],
            j["grip_l"], j["hip_r"], j["knee_r"], j["ankle_r"], j["hip_l"], j["knee_l"], j["ankle_l"],
            head + H @ [7.5, 2.0, 3.2], head + H @ [7.5, 2.0, -3.2], head + H @ [0, 1.0, 8.0],
            head + H @ [0, 1.0, -8.0]]
