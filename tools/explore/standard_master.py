"""标准原画母版处理（纯离线，不开窗口）。

以 art/characters/standard_v1/sheet_main_c1.png 为母版：
  1. 去掉浅灰底与地平线，按人物拆出 5 个视角的透明图 → art/characters/standard_v1/views/
  2. 比例与一致性自检（各视角身高、脚底线、近似头身比）
  3. 按部位取正式色号表（中值 + 亮部 + 暗部）→ art/characters/standard_v1/palette.json
  4. 游戏尺寸可读性检查 + 评审板 → docs/previews/standard_v1/

  python tools/explore/standard_master.py
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage

ROOT = Path(__file__).resolve().parents[2]
STD = ROOT / "art" / "characters" / "standard_v1"
PREV = ROOT / "docs" / "previews" / "standard_v1"
TMP = ROOT / "temp" / "standard"
MASTER = STD / "sheet_main_c1.png"
V6_READY = ROOT / "art/sheets/v6/forehand/Production_2D_action_RPG_anima_2026-10-14T08-17-58.png"
FONT = Path("C:/Windows/Fonts/msyh.ttc")
VIEWS = ["A1_front", "A1_three_quarter", "A1_side_right", "A1_back", "A4_base_body"]
VIEW_CN = {"A1_front": "正面", "A1_three_quarter": "3/4", "A1_side_right": "侧面（朝右）", "A1_back": "背面",
           "A4_base_body": "素体"}
GAME_H = 200


def font(size):
    try:
        return ImageFont.truetype(str(FONT), size)
    except OSError:
        return ImageFont.load_default()


def label(im, text, size=16, fill=(235, 235, 240), bg=(18, 18, 24)):
    im = im.convert("RGB").copy()
    d = ImageDraw.Draw(im)
    d.rectangle((0, 0, im.width, size + 10), fill=bg)
    d.text((8, 4), text, font=font(size), fill=fill)
    return im


def hexc(c):
    return "#%02x%02x%02x" % tuple(int(round(v)) for v in c)


# ---------------- 去底拆图 ----------------

def remove_background(img):
    a = np.asarray(img.convert("RGB"), np.float32)
    H, W = a.shape[:2]
    corners = np.concatenate([a[:8, :8].reshape(-1, 3), a[:8, -8:].reshape(-1, 3)])
    bg = np.median(corners, 0)
    dist = np.linalg.norm(a - bg, axis=-1)
    near = dist < 16
    lab, n = ndimage.label(near)
    border = set(np.unique(np.concatenate([lab[0], lab[-1], lab[:, 0], lab[:, -1]]))) - {0}
    sizes = ndimage.sum(near, lab, range(1, n + 1))
    keep_bg = np.isin(lab, list(border)) | np.isin(lab, [i + 1 for i, s in enumerate(sizes) if s > 600])
    fg = ~keep_bg
    lum = a.mean(-1)
    neutral = (np.abs(a[..., 0] - a[..., 2]) < 10) & (np.abs(a[..., 0] - a[..., 1]) < 10)
    line_px = fg & neutral & (lum > 80) & (lum < bg.mean() - 12)
    line_rows = np.where(line_px.mean(1) > 0.45)[0]
    line_rows = line_rows[line_rows > H * 0.6]
    line_mask = np.zeros_like(fg)
    for y in line_rows:
        line_mask[y] = line_px[y]
    line_y = int(np.median(line_rows)) if len(line_rows) else None
    fg &= ~line_mask
    fg = ndimage.binary_opening(fg, iterations=1)
    edge = fg & ~ndimage.binary_erosion(fg, iterations=2)
    alpha = fg.astype(np.float32)
    alpha[edge] = np.clip((dist[edge] - 10) / 40, 0.15, 1.0)
    rgb = (a - bg * (1 - alpha[..., None])) / np.maximum(alpha[..., None], 1e-3)
    rgba = np.concatenate([np.clip(rgb, 0, 255), alpha[..., None] * 255], -1).astype(np.uint8)
    return rgba, fg, bg, line_y


def split_figures(fg, n_fig=5):
    lab, n = ndimage.label(fg)
    sizes = ndimage.sum(fg, lab, range(1, n + 1))
    order = np.argsort(-sizes)
    bodies = [int(i) + 1 for i in order[:n_fig]]
    slices = ndimage.find_objects(lab)
    cx = {i + 1: (s[1].start + s[1].stop) / 2 for i, s in enumerate(slices)}
    bodies.sort(key=lambda i: cx[i])
    owner = {}
    for i in range(1, n + 1):
        if sizes[i - 1] < 30:
            continue
        if i in bodies:
            owner[i] = i
            continue
        s = slices[i - 1]
        best, bd = None, 1e9
        for b in bodies:
            bs = slices[b - 1]
            overlap = min(s[1].stop, bs[1].stop) - max(s[1].start, bs[1].start)
            d = -overlap if overlap > 0 else abs(cx[i] - cx[b])
            if d < bd:
                best, bd = b, d
        owner[i] = best
    masks = []
    for b in bodies:
        ids = [i for i, o in owner.items() if o == b]
        masks.append(np.isin(lab, ids))
    return masks


def measure(mask):
    ys, xs = np.where(mask)
    top, bot = int(ys.min()), int(ys.max())
    h = bot - top + 1
    widths = mask.sum(1)
    lo, hi = top + int(h * 0.08), top + int(h * 0.22)
    neck = lo + int(np.argmin(widths[lo:hi]))
    return {"top": top, "bottom": bot, "height": h, "left": int(xs.min()), "right": int(xs.max()),
            "neck_y": neck, "head_px": neck - top, "heads_tall": round(h / max(neck - top, 1), 2)}


# ---------------- 色号表 ----------------

PARTS = [
    # 名称, 规格描述, y 范围（相对身高）, x 条件（相对中心 / 半宽）, 像素条件
    ("hair", "头发（银白）", (0.0, 0.13), None, "bright"),
    ("streak", "挑染（深红）", (0.0, 0.12), None, "red"),
    ("skin", "皮肤", (0.05, 0.17), (0.0, 0.5), "skin"),
    ("lining", "内衬（深红）", (0.14, 0.62), (0.0, 0.45), "red"),
    ("bandage", "绷带（深红）", (0.3, 0.58), (0.55, 1.2), "red"),
    ("coat", "风衣 / 内衣（黑）", (0.16, 0.62), None, "dark"),
    ("steel", "护膝护胫（深钢）", (0.6, 0.93), None, "steel"),
    ("boots", "靴（黑）", (0.93, 1.0), None, "dark"),
]


def part_mask(a, mask, m, spec):
    _, _, yr, xr, kind = spec
    H, W = mask.shape
    yy, xx = np.mgrid[0:H, 0:W]
    rel_y = (yy - m["top"]) / m["height"]
    cx = (m["left"] + m["right"]) / 2
    half = (m["right"] - m["left"]) / 2
    rel_x = np.abs(xx - cx) / max(half, 1)
    sel = mask & (rel_y >= yr[0]) & (rel_y < yr[1])
    if xr:
        sel &= (rel_x >= xr[0]) & (rel_x < xr[1])
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    mx, mn = a.max(-1), a.min(-1)
    sat = (mx - mn) / np.maximum(mx, 1)
    cond = {
        "bright": (mx > 150) & (sat < 0.12),
        "red": (r > g * 1.6) & (r > b * 1.25) & (r > 60),
        "skin": (r > 165) & (g > 115) & (b > 90) & (r > b * 1.12) & (sat > 0.1) & (sat < 0.45),
        "dark": (mx < 70) & ~((r > g * 1.6) & (r > 50)),
        "steel": (mx >= 55) & (mx < 150) & (sat < 0.16),
    }[kind]
    return sel & cond


def palette(img_rgb, mask, m):
    a = np.asarray(img_rgb, np.float32)
    out = []
    for spec in PARTS:
        sel = part_mask(a, mask, m, spec)
        px = a[sel]
        if len(px) < 20:
            out.append({"id": spec[0], "name": spec[1], "pixels": int(len(px))})
            continue
        lum = px @ np.array([0.299, 0.587, 0.114])
        lo, hi = np.percentile(lum, 20), np.percentile(lum, 80)
        out.append({
            "id": spec[0], "name": spec[1], "pixels": int(len(px)),
            "base": hexc(np.median(px, 0)),
            "light": hexc(np.median(px[lum >= hi], 0)),
            "shadow": hexc(np.median(px[lum <= lo], 0)),
        })
    return out


def palette_board(pal):
    W, H = 1040, 150
    im = Image.new("RGB", (W, H), (24, 24, 30))
    d = ImageDraw.Draw(im)
    d.text((10, 6), "A6 色号表（取自母版 c1 正面像，每格：亮部 / 中值 / 暗部）", font=font(16), fill=(235, 235, 240))
    for i, p in enumerate(pal):
        x = 10 + i * 128
        if "base" not in p:
            d.text((x, 50), p["name"] + "\n样本不足", font=font(12), fill=(200, 120, 120))
            continue
        for k, key in enumerate(("light", "base", "shadow")):
            c = tuple(int(p[key][j:j + 2], 16) for j in (1, 3, 5))
            d.rectangle((x + k * 38, 36, x + k * 38 + 34, 80), fill=c)
        d.text((x, 86), p["name"], font=font(12), fill=(225, 225, 230))
        d.text((x, 104), p["base"], font=font(12), fill=(160, 160, 170))
        d.text((x, 120), f"{p['pixels']} px", font=font(11), fill=(120, 120, 130))
    return im


# ---------------- 评审板 ----------------

def fit_h(im, h):
    return im.resize((max(1, round(im.width * h / im.height)), h), Image.LANCZOS)


def on_gray(rgba, bg=(205, 205, 210)):
    base = Image.new("RGB", rgba.size, bg)
    base.paste(rgba, (0, 0), rgba)
    return base


def v6_ready():
    a = np.asarray(Image.open(V6_READY).convert("RGB").crop((10, 40, 370, 450)), np.float32)
    g = (a[..., 1] > 150) & (a[..., 1] > a[..., 0] * 1.35) & (a[..., 1] > a[..., 2] * 1.35)
    a[g] = (205, 205, 210)
    return Image.fromarray(a.astype(np.uint8))


def vstack(ims, pad=10, bg=(10, 10, 14)):
    W = max(i.width for i in ims)
    H = sum(i.height for i in ims) + pad * (len(ims) - 1)
    out = Image.new("RGB", (W, H), bg)
    y = 0
    for i in ims:
        out.paste(i, (0, y))
        y += i.height + pad
    return out


def hstack(ims, pad=10, bg=(10, 10, 14)):
    W = sum(i.width for i in ims) + pad * (len(ims) - 1)
    H = max(i.height for i in ims)
    out = Image.new("RGB", (W, H), bg)
    x = 0
    for i in ims:
        out.paste(i, (x, 0))
        x += i.width + pad
    return out


def main():
    img = Image.open(MASTER).convert("RGB")
    rgba, fg, bg, line_y = remove_background(img)
    masks = split_figures(fg)
    out_dir = STD / "views"
    out_dir.mkdir(parents=True, exist_ok=True)
    meas, crops = {}, {}
    for name, mk in zip(VIEWS, masks):
        m = measure(mk)
        meas[name] = m
        pad = 6
        box = (max(0, m["left"] - pad), max(0, m["top"] - pad), min(img.width, m["right"] + pad + 1),
               min(img.height, m["bottom"] + pad + 1))
        cut = rgba.copy()
        cut[~ndimage.binary_dilation(mk, iterations=2), 3] = 0
        im = Image.fromarray(cut).crop(box)
        im.save(out_dir / f"{name}.png")
        crops[name] = im
    hs = [meas[v]["height"] for v in VIEWS[:4]]
    feet = [meas[v]["bottom"] for v in VIEWS]
    report = {
        "master": str(MASTER.relative_to(ROOT)), "background_rgb": [int(x) for x in bg], "ground_line_y": line_y,
        "views": meas,
        "check": {
            "height_spread_px_A1": int(max(hs) - min(hs)),
            "height_spread_pct_A1": round((max(hs) - min(hs)) / np.mean(hs) * 100, 1),
            "feet_spread_px": int(max(feet) - min(feet)),
            "heads_tall_front": meas["A1_front"]["heads_tall"],
            "note": "头身比按'头顶到颈部最窄行'估算，含刺发高度，仅供参考",
        },
    }
    pal = palette(img, masks[0], meas["A1_front"])
    (STD / "palette.json").write_text(json.dumps({"source": report["master"], "view": "A1_front", "parts": pal},
                                                 ensure_ascii=False, indent=1), "utf-8")
    (STD / "measure.json").write_text(json.dumps(report, ensure_ascii=False, indent=1), "utf-8")

    PREV.mkdir(parents=True, exist_ok=True)
    pb = palette_board(pal)
    pb.save(PREV / "palette.png")

    # 游戏尺寸检查：母版各视角缩到 V6 实机身高，与 V6 起手帧原生尺寸并排
    v6 = v6_ready()
    v6_actor = Image.open(V6_READY).convert("RGB")
    scale_tiles = []
    for name in VIEWS[:4]:
        im = crops[name]
        g = fit_h(im, GAME_H)
        scale_tiles.append(label(on_gray(g).resize((g.width * 2, g.height * 2), Image.NEAREST),
                                 f"{VIEW_CN[name]} {GAME_H}px ×2", 13))
    v6_small = fit_h(v6, GAME_H + 20)
    scale_tiles.append(label(v6_small.resize((v6_small.width * 2, v6_small.height * 2), Image.NEAREST),
                             "V6 起手帧 原生 ×2", 13))
    scale_row = hstack(scale_tiles)
    del v6_actor

    errata = ("母版 c1 已知瑕疵（以文字规格为准）：侧面缺护膝护胫；背面看不到刀鞘；素体不应带护膝（护具属'鞋'槽位）")
    master_tile = label(on_gray(Image.fromarray(rgba)), "母版 c1：A1 四向 + A4 素体（已去底）", 16)
    d = ImageDraw.Draw(master_tile)
    d.rectangle((0, master_tile.height - 26, master_tile.width, master_tile.height), fill=(60, 24, 24))
    d.text((8, master_tile.height - 23), errata, font=font(14), fill=(255, 200, 190))
    views_row = hstack([label(on_gray(fit_h(crops[v], 420)), VIEW_CN[v], 14) for v in VIEWS])
    sheets = [
        ("pose_head_c2", TMP / "sheet_pose_head" / "pose_head_c2.png", "A2 机位持刀（朝右）+ A3 表情 c2"),
        ("parts_c1", TMP / "sheet_parts" / "parts_c1.png", "A5 部件拆解 c1"),
        ("weapon_c1", TMP / "sheet_weapon" / "weapon_c1.png", "A7 标准太刀三视图 c1"),
    ]
    sheet_tiles = [label(fit_h(Image.open(p).convert("RGB"), 520), t, 16) for _, p, t in sheets]
    board = vstack([
        hstack([label(fit_h(v6, 560), "参照：V6 起手帧", 16), fit_h(master_tile, 560)]),
        views_row,
        hstack(sheet_tiles[:2]),
        sheet_tiles[2],
        pb,
        label(scale_row, "游戏尺寸可读性（缩到实机身高后 2 倍放大）", 14),
    ])
    board.save(PREV / "master_board.jpg", quality=92)
    print(json.dumps(report["check"], ensure_ascii=False))
    print("heights", {v: meas[v]["height"] for v in VIEWS}, "line_y", line_y)
    print("[OK]", (PREV / "master_board.jpg").relative_to(ROOT), board.size)


if __name__ == "__main__":
    main()
