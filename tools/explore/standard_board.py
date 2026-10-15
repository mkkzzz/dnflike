"""标准鬼剑士原画设定：候选评审板 + 色号表（纯离线，不开窗口）。

  python tools/explore/standard_board.py
读取 temp/standard/ 下的候选，输出 temp/standard/review_board.png 与 palette_<候选>.png/.json。
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "temp" / "standard"
V6_READY = ROOT / "art/sheets/v6/forehand/Production_2D_action_RPG_anima_2026-10-14T08-17-58.png"
FONT = Path("C:/Windows/Fonts/msyh.ttc")

# 标准身份规格里的关键部件，按候选图中实际取样区域给出（相对正面像的归一化框，由人工核对）
PARTS = {
    "头发（银白）": "hair", "挑染（深红）": "streak", "风衣（黑皮）": "coat", "内衬（深红）": "lining",
    "绷带（深红）": "bandage", "护膝护胫（深钢）": "greave", "皮肤": "skin",
}


def font(size):
    try:
        return ImageFont.truetype(str(FONT), size)
    except OSError:
        return ImageFont.load_default()


def label(im, text, size=18, fill=(235, 235, 240), bg=(18, 18, 24)):
    im = im.copy()
    d = ImageDraw.Draw(im)
    d.rectangle((0, 0, im.width, size + 10), fill=bg)
    d.text((8, 4), text, font=font(size), fill=fill)
    return im


def fit_h(im, h):
    return im.resize((round(im.width * h / im.height), h), Image.LANCZOS)


def v6_reference():
    a = np.asarray(Image.open(V6_READY).convert("RGB").crop((10, 40, 370, 450)), np.float32)
    g = (a[..., 1] > 150) & (a[..., 1] > a[..., 0] * 1.35) & (a[..., 1] > a[..., 2] * 1.35)
    a[g] = (205, 205, 210)
    return Image.fromarray(a.astype(np.uint8))


def classify(rgb):
    """按色相/明度把像素分到规格部件（粗分类，只用于色号表与偏差统计）。"""
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    mx, mn = rgb.max(-1), rgb.min(-1)
    sat = (mx - mn) / np.maximum(mx, 1)
    out = {}
    bg = (np.abs(r - g) < 10) & (np.abs(g - b) < 12) & (mx > 185) & (mx < 225)
    out["hair"] = (mx > 175) & (sat < 0.12) & ~bg
    red = (r > g * 1.6) & (r > b * 1.3) & (r > 70)
    out["crimson"] = red
    out["skin"] = (r > 170) & (g > 120) & (b > 95) & (r > b * 1.15) & (sat > 0.12) & (sat < 0.45)
    out["black"] = (mx < 60) & ~red
    out["steel"] = (mx >= 60) & (mx < 140) & (sat < 0.18) & ~red
    return out, bg


def palette(img, k=12):
    a = np.asarray(img.convert("RGB"), np.float32)
    parts, bg = classify(a)
    fg = a[~bg & (a.max(-1) > 25)].reshape(-1, 3)
    rng = np.random.default_rng(0)
    pts = fg[rng.choice(len(fg), min(len(fg), 40000), replace=False)]
    cent = pts[rng.choice(len(pts), k, replace=False)]
    for _ in range(25):
        lab = np.argmin(((pts[:, None] - cent[None]) ** 2).sum(-1), 1)
        cent = np.array([pts[lab == i].mean(0) if (lab == i).any() else cent[i] for i in range(k)])
    counts = np.bincount(lab, minlength=k)
    order = np.argsort(-counts)
    chips = [{"rgb": [int(round(x)) for x in cent[i]], "share": round(float(counts[i] / counts.sum()), 3)}
             for i in order]
    stats = {name: [int(round(x)) for x in a[m].mean(0)] if m.any() else None for name, m in parts.items()}
    return chips, stats


def chip_board(chips, stats, title):
    W, H = 900, 260
    im = Image.new("RGB", (W, H), (24, 24, 30))
    d = ImageDraw.Draw(im)
    d.text((10, 6), title, font=font(18), fill=(235, 235, 240))
    for i, c in enumerate(chips):
        x = 10 + i * 73
        d.rectangle((x, 40, x + 64, 104), fill=tuple(c["rgb"]))
        d.text((x, 108), "#%02x%02x%02x" % tuple(c["rgb"]), font=font(12), fill=(200, 200, 205))
        d.text((x, 124), f"{c['share']*100:.0f}%", font=font(12), fill=(150, 150, 160))
    names = {"hair": "银白发", "crimson": "深红(挑染/内衬/绷带)", "skin": "皮肤", "black": "黑皮/黑衣", "steel": "深钢护具"}
    for i, (k, v) in enumerate(stats.items()):
        x = 10 + i * 178
        if v:
            d.rectangle((x, 160, x + 40, 200), fill=tuple(v))
        d.text((x + 48, 168), names[k], font=font(13), fill=(220, 220, 225))
        d.text((x + 48, 186), "#%02x%02x%02x" % tuple(v) if v else "—", font=font(12), fill=(160, 160, 170))
    d.text((10, 226), "自动聚类主色（上）与按部件归类的平均色（下）；正式色号表以认可后的母版为准",
           font=font(12), fill=(150, 150, 160))
    return im


def main():
    cands = sorted((SRC / "sheet_main").glob("c*.png"))
    pose = sorted((SRC / "sheet_pose_head").glob("*.png"))
    rows = []
    ref = fit_h(v6_reference(), 520)
    rows.append(label(ref, "参照：V6 forehand 起手帧（标准身份来源）", 16))
    for c in cands:
        rows.append(label(fit_h(Image.open(c).convert("RGB"), 520), f"设定总图候选 {c.stem}", 16))
    for p in pose:
        rows.append(label(fit_h(Image.open(p).convert("RGB"), 520), f"机位持刀 + 表情 {p.stem}", 16))
    pal = {}
    for c in cands:
        chips, stats = palette(Image.open(c))
        pal[c.stem] = {"chips": chips, "parts": stats}
        board = chip_board(chips, stats, f"色号表（自动提取） {c.stem}")
        board.save(SRC / f"palette_{c.stem}.png")
    (SRC / "palette.json").write_text(json.dumps(pal, ensure_ascii=False, indent=1), "utf-8")
    top = [rows[0], rows[1]]
    rest = rows[2:]
    def hcat(ims, pad=10):
        w = sum(i.width for i in ims) + pad * (len(ims) - 1)
        out = Image.new("RGB", (w, max(i.height for i in ims)), (10, 10, 14))
        x = 0
        for i in ims:
            out.paste(i, (x, 0))
            x += i.width + pad
        return out
    lines = [hcat(top)] + [hcat([r]) for r in rest]
    W = max(l.width for l in lines)
    H = sum(l.height for l in lines) + 10 * (len(lines) - 1)
    board = Image.new("RGB", (W, H), (10, 10, 14))
    y = 0
    for l in lines:
        board.paste(l, (0, y))
        y += l.height + 10
    board.save(SRC / "review_board.png")
    print("[OK] review_board.png", board.size, "palettes:", list(pal))


if __name__ == "__main__":
    main()
