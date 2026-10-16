"""A7 标准太刀标定（纯离线，不开窗口）。

输入 art/concepts/characters/players/swordsman/standard_v1/sheet_weapon_c1.png（四行：出鞘侧面 / 刀背俯视 / 入鞘 / 空鞘）：
  1. 去底，按行拆出 4 张透明图 → art/concepts/characters/players/swordsman/standard_v1/weapon/
     空鞘行原图多画了一个镡，切图时去掉（镡属于刀，不属于鞘）
  2. 标定柄头 / 握点 / 护手 / 刀尖（出鞘与俯视）、柄头 / 护手 / 鞘口 / 鞘尾（入鞘）、鞘口 / 鞘尾（空鞘）
  3. 换算实机尺寸：刀身（护手→刀尖）以 V6 实机最长测量值为准，握点距护手取 V6 中位值
     → art/concepts/characters/players/swordsman/standard_v1/weapon/katana.json + docs/previews/standard_v1/weapon_calibration.png

  python tools/explore/standard_weapon.py
"""
from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

from standard_master import font, label

ROOT = Path(__file__).resolve().parents[2]
STD = ROOT / 'art/concepts/characters/players/swordsman/standard_v1'
SRC = STD / "sheet_weapon_c1.png"
OUT = STD / "weapon"
PREV = ROOT / "docs" / "previews" / "standard_v1"
V6_MANIFEST = ROOT / "game" / "assets" / "seq_v6" / "manifest.json"
BODY_H_GAME = 190
ROWS = ["katana_drawn", "katana_spine", "katana_sheathed", "scabbard_empty"]


def cutout(img):
    a = np.asarray(img.convert("RGB"), np.float32)
    corners = np.concatenate([a[:8, :8].reshape(-1, 3), a[:8, -8:].reshape(-1, 3), a[-8:, :8].reshape(-1, 3)])
    bg = np.median(corners, 0)
    dist = np.linalg.norm(a - bg, axis=-1)
    near = dist < 18
    lab, _ = ndimage.label(near)
    border = np.unique(np.concatenate([lab[0], lab[-1], lab[:, 0], lab[:, -1]]))
    fg = ~np.isin(lab, border[border > 0])
    fg = ndimage.binary_fill_holes(ndimage.binary_opening(fg, iterations=1))
    lab2, n = ndimage.label(fg)
    sizes = ndimage.sum(fg, lab2, range(1, n + 1))
    fg = np.isin(lab2, [i + 1 for i, s in enumerate(sizes) if s >= 40])
    edge = fg & ~ndimage.binary_erosion(fg, iterations=2)
    alpha = fg.astype(np.float32)
    alpha[edge] = np.clip((dist[edge] - 10) / 40, 0.2, 1.0)
    rgb = (a - bg * (1 - alpha[..., None])) / np.maximum(alpha[..., None], 1e-3)
    rgba = np.concatenate([np.clip(rgb, 0, 255), alpha[..., None] * 255], -1).astype(np.uint8)
    return rgba, fg, a


def row_bands(fg, n=4):
    prof = fg.any(1)
    bands, y = [], 0
    H = len(prof)
    while y < H:
        if prof[y]:
            y0 = y
            while y < H and prof[y]:
                y += 1
            bands.append((y0, y))
        y += 1
    bands = [b for b in bands if b[1] - b[0] > 6]
    while len(bands) > n:
        gaps = [bands[i + 1][0] - bands[i][1] for i in range(len(bands) - 1)]
        i = int(np.argmin(gaps))
        bands[i:i + 2] = [(bands[i][0], bands[i + 1][1])]
    return bands


def col_profile(mask):
    h = mask.sum(0)
    yc = np.array([np.where(mask[:, x])[0].mean() if h[x] else np.nan for x in range(mask.shape[1])])
    return h, yc


def axis_y(yc, x, r=3):
    seg = yc[max(0, x - r):x + r + 1]
    seg = seg[~np.isnan(seg)]
    return float(seg.mean()) if len(seg) else float("nan")


def find_guard(mask, x0, x1):
    """镡 = 左半段里最高的那一簇列。"""
    h, _ = col_profile(mask)
    span = h[x0:x1]
    gx = x0 + int(np.argmax(span))
    thr = 0.72 * h[gx]
    l = gx
    while l > x0 and h[l - 1] >= thr:
        l -= 1
    r = gx
    while r < x1 - 1 and h[r + 1] >= thr:
        r += 1
    ys = np.where(mask[:, (l + r) // 2])[0]
    return l, r, ((l + r) / 2, (ys.min() + ys.max()) / 2)


def calib_sword(mask):
    xs = np.where(mask.any(0))[0]
    x0, x1 = int(xs.min()), int(xs.max())
    _, yc = col_profile(mask)
    gl, gr, guard = find_guard(mask, x0, x0 + int((x1 - x0) * 0.5))
    pommel = (float(x0), axis_y(yc, x0 + 3))
    tip_col = mask[:, x1 - 1:x1 + 1].any(1)
    tip = (float(x1), float(np.where(tip_col)[0].mean()))
    return {"pommel": pommel, "guard": guard, "guard_x_range": [gl, gr], "tip": tip}


def calib_scabbard(mask, with_guard):
    xs = np.where(mask.any(0))[0]
    x0, x1 = int(xs.min()), int(xs.max())
    _, yc = col_profile(mask)
    res = {"end": (float(x1), axis_y(yc, x1 - 3))}
    if with_guard:
        gl, gr, guard = find_guard(mask, x0, x0 + int((x1 - x0) * 0.5))
        res.update(pommel=(float(x0), axis_y(yc, x0 + 3)), guard=guard, guard_x_range=[gl, gr],
                   mouth=(float(gr + 1), axis_y(yc, gr + 4)))
    else:
        res["mouth"] = (float(x0), axis_y(yc, x0 + 3))
    return res


def v6_reference():
    m = json.loads(V6_MANIFEST.read_text("utf-8"))
    blade, grip = [], []
    for k, c in m["clips"].items():
        if not k.startswith("actor/"):
            continue
        for f in c["frames"]:
            if "tip" in f and "guard" in f:
                blade.append(math.dist(f["guard"], f["tip"]))
                grip.append(math.dist(f["grip"], f["guard"]))
    return {"blade_max": round(max(blade), 1), "blade_p95": round(float(np.percentile(blade, 95)), 1),
            "grip_to_guard_median": round(float(np.median(grip)), 1), "frames": len(blade)}


def overlay_v6(katana_im, guard, tip, picks=(("actor/attack1", 0), ("actor/attack2", None), ("actor/attack3", 0))):
    """把标准太刀按 护手→刀尖 对齐贴到 V6 实机帧上（半透明），检查柄长与握位是否吻合。"""
    m = json.loads(V6_MANIFEST.read_text("utf-8"))
    tiles = []
    for clip, idx in picks:
        c = m["clips"][clip]
        fr = [f for f in c["frames"] if "tip" in f]
        f = fr[idx] if idx is not None else max(fr, key=lambda f: math.dist(f["guard"], f["tip"]))
        ax, ay = c["anchor"]
        g = (ax + f["guard"][0], ay + f["guard"][1])
        t = (ax + f["tip"][0], ay + f["tip"][1])
        gp = (ax + f["grip"][0], ay + f["grip"][1])
        frame = Image.open(V6_MANIFEST.parent / f["file"]).convert("RGBA")
        vs = complex(tip[0] - guard[0], tip[1] - guard[1])
        vd = complex(t[0] - g[0], t[1] - g[1])
        k = vd / vs
        inv = 1 / k
        a, b = inv.real, inv.imag
        # 目标点 p -> 源点 q = guard + inv * (p - g)（复数乘法 = 旋转 + 缩放）
        coeffs = (a, -b, guard[0] - a * g[0] + b * g[1], b, a, guard[1] - b * g[0] - a * g[1])
        warped = katana_im.transform(frame.size, Image.AFFINE, coeffs, resample=Image.BICUBIC)
        w = np.asarray(warped).copy()
        w[..., 3] = (w[..., 3] * 0.55).astype(np.uint8)
        base = Image.new("RGBA", frame.size, (205, 205, 210, 255))
        base.alpha_composite(frame)
        base.alpha_composite(Image.fromarray(w))
        d = ImageDraw.Draw(base)
        for p, col in ((g, (255, 200, 40)), (t, (255, 60, 60)), (gp, (60, 220, 90))):
            d.ellipse((p[0] - 3, p[1] - 3, p[0] + 3, p[1] + 3), outline=col, width=2)
        crop = base.crop((60, 40, 452, 300)).convert("RGB")
        tiles.append(label(crop.resize((crop.width * 2, crop.height * 2), Image.LANCZOS),
                           f"{clip.split('/')[1]} f{c['frames'].index(f):03d}：标准太刀半透明叠在 V6 帧上", 14))
    W = sum(t.width for t in tiles) + 10 * (len(tiles) - 1)
    out = Image.new("RGB", (W, tiles[0].height), (10, 10, 14))
    x = 0
    for t in tiles:
        out.paste(t, (x, 0))
        x += t.width + 10
    return out


def r2(p):
    return [round(float(p[0]), 1), round(float(p[1]), 1)]


def main():
    img = Image.open(SRC).convert("RGB")
    rgba, fg, rgb = cutout(img)
    bands = row_bands(fg)
    assert len(bands) == 4, bands
    OUT.mkdir(parents=True, exist_ok=True)
    pad = 6
    parts, crops = {}, {}
    for name, (y0, y1) in zip(ROWS, bands):
        m = np.zeros_like(fg)
        m[y0:y1] = fg[y0:y1]
        removed = None
        if name == "scabbard_empty":
            # 镡在鞘口银圈左侧、并有一部分被银圈压住：切掉银圈左边的列，银圈所在列只保留银圈高度
            xs = np.where(m.any(0))[0]
            h = m.sum(0)
            body_h = float(np.median(h[xs.min() + (xs.max() - xs.min()) // 3: xs.max() - 20]))
            mx, mn = rgb.max(-1), rgb.min(-1)
            silver = m & (mx > 150) & ((mx - mn) / np.maximum(mx, 1) < 0.12)
            head = np.arange(xs.min(), xs.min() + (xs.max() - xs.min()) // 6)
            ring = head[silver[:, head].sum(0) > 0.5 * body_h]
            rl, rr = int(ring.min()), int(ring.max())
            tops, bots = [], []
            for x in range(rr + 4, rr + 40):
                ys_ = np.where(m[:, x])[0]
                if len(ys_):
                    tops.append(ys_.min())
                    bots.append(ys_.max())
            ry0, ry1 = int(np.median(tops)) - 4, int(np.median(bots)) + 4
            m[:, :rl] = False
            m[:ry0, rl:rr + 1] = False
            m[ry1 + 1:, rl:rr + 1] = False
            removed = [int(xs.min()), rl - 1]
        ys, xs = np.where(m)
        box = (int(xs.min()) - pad, int(ys.min()) - pad, int(xs.max()) + pad + 1, int(ys.max()) + pad + 1)
        cut = rgba.copy()
        cut[~m, 3] = 0
        im = Image.fromarray(cut).crop(box)
        im.save(OUT / f"{name}.png")
        crops[name] = (im, box)
        local = m[box[1]:box[3], box[0]:box[2]]
        if name in ("katana_drawn", "katana_spine"):
            c = calib_sword(local)
        else:
            c = calib_scabbard(local, with_guard=(name == "katana_sheathed"))
        if removed:
            c["note"] = f"原图此行在 x={removed[0]}~{removed[1]} 多画了一个镡，已切除"
        parts[name] = c

    v6 = v6_reference()
    d = parts["katana_drawn"]
    blade_src = math.dist(d["guard"], d["tip"])
    hilt_src = math.dist(d["pommel"], d["guard"])
    blade_game = round(v6["blade_max"])
    s = blade_game / blade_src
    grip_game = round(v6["grip_to_guard_median"])
    t = grip_game / s / hilt_src
    for name in ("katana_drawn", "katana_spine"):
        p = parts[name]
        g, pm = p["guard"], p["pommel"]
        p["grip"] = (g[0] + (pm[0] - g[0]) * t, g[1] + (pm[1] - g[1]) * t)
    sh = parts["katana_sheathed"]
    scab_src = math.dist(sh["mouth"], sh["end"])
    sh_scale = math.dist(sh["pommel"], sh["guard"]) / hilt_src

    spec = {
        "source": str(SRC.relative_to(ROOT)),
        "coordinate_system": "每张切图自己的像素坐标，x 向右（刀尖方向），y 向下",
        "images": {n: f"weapon/{n}.png" for n in ROWS},
        "landmarks": {n: {k: (r2(v) if isinstance(v, tuple) else v) for k, v in p.items()} for n, p in parts.items()},
        "ratios": {
            "hilt_over_blade": round(hilt_src / blade_src, 3),
            "grip_from_guard_over_hilt": round(t, 3),
            "scabbard_over_blade": round(scab_src / sh_scale / blade_src, 3),
        },
        "game": {
            "body_height_px": BODY_H_GAME,
            "blade_guard_to_tip_px": blade_game,
            "hilt_pommel_to_guard_px": round(hilt_src * s, 1),
            "grip_to_guard_px": grip_game,
            "total_length_px": round((blade_src + hilt_src) * s, 1),
            "blade_over_body": round(blade_game / BODY_H_GAME, 3),
            "src_to_game_scale_drawn": round(s, 4),
            "basis": "刀身长取 V6 实机全部动作帧护手→刀尖的最大值（刀身与画面平行时最长，透视只会缩短）；握点距护手取 V6 中位值",
            "v6_measure": v6,
        },
        "rules": [
            "握点固定在右手（靠镜头的手），单手持（D026）",
            "刀光取护手→刀尖的扫掠",
            "刀鞘挂左腰，入鞘时鞘口贴镡",
            "换武器时只换武器层：握点对齐握点、护手→刀尖方向对齐，长度按各武器参数缩放",
            "切图默认刃朝下（反手、上撩等刃朝上的帧把切图上下翻转），刃朝向逐帧由骨架数据给出",
            "刀身看向刃口或刀背（透视极窄）时改用 katana_spine",
        ],
        "v6_overlay_check": "docs/previews/standard_v1/weapon_v6_overlay.jpg：按护手→刀尖对齐贴到 V6 attack1/2/3 帧上，柄长与握位与 V6 原画基本吻合",
    }
    (OUT / "katana.json").write_text(json.dumps(spec, ensure_ascii=False, indent=1), "utf-8")

    tiles = []
    colors = {"pommel": (80, 160, 255), "grip": (60, 220, 90), "guard": (255, 200, 40), "tip": (255, 60, 60),
              "mouth": (200, 120, 255), "end": (255, 140, 40)}
    names_cn = {"pommel": "柄头", "grip": "握点", "guard": "护手", "tip": "刀尖", "mouth": "鞘口", "end": "鞘尾"}
    titles = {"katana_drawn": "出鞘侧面", "katana_spine": "刀背俯视", "katana_sheathed": "入鞘",
              "scabbard_empty": "空鞘（已切除多余的镡）"}
    M = 40
    for name in ROWS:
        im, _ = crops[name]
        base = Image.new("RGB", (im.width + 2 * M, im.height + 44), (205, 205, 210))
        base.paste(im, (M, 0), im)
        dr = ImageDraw.Draw(base)
        for k, v in spec["landmarks"][name].items():
            if k in colors:
                x, y = v[0] + M, v[1]
                ty = im.height + (22 if k in ("grip", "mouth") else 4)
                dr.ellipse((x - 6, y - 6, x + 6, y + 6), outline=colors[k], width=3)
                dr.line((x, y + 7, x, ty), fill=colors[k], width=1)
                dr.text((x - 12, ty), names_cn[k], font=font(13), fill=colors[k])
        tiles.append(label(base, titles[name], 15))
    g = spec["game"]
    info = Image.new("RGB", (max(t.width for t in tiles), 70), (24, 24, 30))
    di = ImageDraw.Draw(info)
    di.text((10, 8), f"实机尺寸（人物 {BODY_H_GAME}px）：刀身 护手→刀尖 {g['blade_guard_to_tip_px']}px（{g['blade_over_body']:.2f} 身高），"
                     f"柄 {g['hilt_pommel_to_guard_px']}px，全长 {g['total_length_px']}px，握点距护手 {g['grip_to_guard_px']}px",
            font=font(15), fill=(235, 235, 240))
    di.text((10, 38), f"依据：V6 实机 {v6['frames']} 帧标定，护手→刀尖最大 {v6['blade_max']}px、握点→护手中位 {v6['grip_to_guard_median']}px",
            font=font(13), fill=(160, 160, 170))
    W = max(t.width for t in tiles)
    H = sum(t.height for t in tiles) + info.height + 10 * len(tiles)
    board = Image.new("RGB", (W, H), (10, 10, 14))
    y = 0
    for t in tiles + [info]:
        board.paste(t, (0, y))
        y += t.height + 10
    PREV.mkdir(parents=True, exist_ok=True)
    board.save(PREV / "weapon_calibration.png")
    overlay_v6(crops["katana_drawn"][0], d["guard"], d["tip"]).save(PREV / "weapon_v6_overlay.jpg", quality=90)
    print(json.dumps({"ratios": spec["ratios"], "game": {k: v for k, v in g.items() if k != "v6_measure"}},
                     ensure_ascii=False))
    for n in ROWS:
        print(n, spec["landmarks"][n])


if __name__ == "__main__":
    main()
