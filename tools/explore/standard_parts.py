"""A5 槽位拆解后处理（纯离线，不开窗口）。

输入 art/concepts/characters/players/swordsman/standard_v1/sheet_parts_c1.png：
  1. 去掉生图多画的圈号（用底色覆盖），另存 sheet_parts_c1_clean.png
  2. 按部件切出透明图 → art/concepts/characters/players/swordsman/standard_v1/parts/<槽位>__<部件>.png
  3. 按 18 号文档第七节槽位框架标注 → docs/previews/standard_v1/parts_slots.jpg，并写 parts/parts.json

  python tools/explore/standard_parts.py
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

from standard_master import font, label

ROOT = Path(__file__).resolve().parents[2]
STD = ROOT / 'art/concepts/characters/players/swordsman/standard_v1'
SRC = STD / "sheet_parts_c1.png"
OUT = STD / "parts"
PREV = ROOT / "docs" / "previews" / "standard_v1"

SLOT_CN = {"top": "上衣（时装）", "bottom": "下装（时装）", "belt": "腰带（时装）", "shoes": "鞋（时装，含护膝护胫）",
           "base": "素体（职业固定）", "fixed": "绷带（职业固定）", "equip": "装备（武器系统）"}
SLOT_COLOR = {"top": (90, 170, 255), "bottom": (120, 220, 120), "belt": (240, 200, 60), "shoes": (250, 140, 60),
              "base": (190, 190, 190), "fixed": (230, 80, 90), "equip": (190, 120, 255)}
# (slot, part_id, 中文名, 源图包围盒 x0, y0, x1, y1, 备注)
PARTS = [
    ("top", "coat_front", "风衣（正，敞开）", (30, 34, 348, 708), ""),
    ("top", "coat_back", "风衣（背）", (366, 34, 675, 704), ""),
    ("base", "inner_turtleneck", "贴身高领内衣", (700, 44, 939, 322), "属于 A4 素体"),
    ("top", "chest_straps", "胸前束带", (964, 70, 1150, 216), "图中画成背带式；规格为两道横向银扣皮带"),
    ("belt", "waist_belt", "腰带", (968, 224, 1146, 280), ""),
    ("bottom", "trousers", "长裤（含右腿绑带）", (741, 316, 900, 724), ""),
    ("shoes", "boot_pair", "靴 + 护膝 + 护胫", (952, 432, 1182, 732), ""),
    ("fixed", "bandage_pair", "双前臂绷带", (1178, 70, 1336, 336), "跨转职保留（D027）"),
    ("equip", "scabbard", "刀鞘（含挂带）", (1226, 340, 1330, 724), "图中鞘内带刀；空鞘以 A7 为准"),
]


def background(a):
    return np.median(np.concatenate([a[:8, :8].reshape(-1, 3), a[:8, -8:].reshape(-1, 3)]), 0)


def find_badges(a, bg):
    """圈号：小、近似正方、中空的连通块。"""
    fg = np.linalg.norm(a - bg, axis=-1) > 18
    lab, n = ndimage.label(fg)
    out = []
    for i, sl in enumerate(ndimage.find_objects(lab), 1):
        h, w = sl[0].stop - sl[0].start, sl[1].stop - sl[1].start
        if not (22 <= w <= 44 and 22 <= h <= 44 and 0.8 <= w / h <= 1.25):
            continue
        comp = lab[sl] == i
        filled = ndimage.binary_fill_holes(comp)
        if comp.sum() < 120 or filled.sum() < comp.sum() * 1.5:
            continue
        # 圈号内部的数字是另一块，一起抹掉
        out.append((sl[1].start, sl[0].start, sl[1].stop, sl[0].stop))
    return out


def main():
    img = Image.open(SRC).convert("RGB")
    a = np.asarray(img, np.float32).copy()
    bg = background(a)
    badges = find_badges(a, bg)
    for x0, y0, x1, y1 in badges:
        a[max(0, y0 - 3):y1 + 3, max(0, x0 - 3):x1 + 3] = bg
    clean = Image.fromarray(a.astype(np.uint8))
    clean.save(STD / "sheet_parts_c1_clean.png")

    dist = np.linalg.norm(a - bg, axis=-1)
    fg = dist > 18
    lab, _ = ndimage.label(fg)
    border = np.unique(np.concatenate([lab[0], lab[-1], lab[:, 0], lab[:, -1]]))
    fg &= ~np.isin(lab, border[border > 0])
    OUT.mkdir(parents=True, exist_ok=True)
    meta = []
    board = clean.copy().convert("RGB")
    d = ImageDraw.Draw(board)
    for slot, pid, cn, (x0, y0, x1, y1), note in PARTS:
        m = np.zeros_like(fg)
        m[y0:y1, x0:x1] = fg[y0:y1, x0:x1]
        m = ndimage.binary_fill_holes(ndimage.binary_closing(m, iterations=1)) & (dist > 10)
        lab2, n2 = ndimage.label(m)
        if n2:
            sizes = ndimage.sum(m, lab2, range(1, n2 + 1))
            m = np.isin(lab2, [i + 1 for i, s in enumerate(sizes) if s >= 60])
        alpha = m.astype(np.float32)
        edge = m & ~ndimage.binary_erosion(m, iterations=2)
        alpha[edge] = np.clip((dist[edge] - 10) / 40, 0.2, 1.0)
        rgb = (a - bg * (1 - alpha[..., None])) / np.maximum(alpha[..., None], 1e-3)
        rgba = np.concatenate([np.clip(rgb, 0, 255), alpha[..., None] * 255], -1).astype(np.uint8)
        ys, xs = np.where(m)
        box = (int(xs.min()) - 4, int(ys.min()) - 4, int(xs.max()) + 5, int(ys.max()) + 5)
        name = f"{slot}__{pid}.png"
        Image.fromarray(rgba).crop(box).save(OUT / name)
        meta.append({"slot": slot, "slot_cn": SLOT_CN[slot], "part": pid, "name": cn, "file": f"parts/{name}",
                     "source_box": list(box), "note": note})
        d.rectangle(box, outline=SLOT_COLOR[slot], width=3)
    for p in meta:
        box, col = p["source_box"], SLOT_COLOR[p["slot"]]
        tag = p["name"] + ("  ※" if p["note"] else "")
        tw = d.textlength(tag, font=font(14))
        d.rectangle((box[0], box[3] + 2, box[0] + tw + 10, box[3] + 22), fill=(20, 20, 26))
        d.text((box[0] + 5, box[3] + 3), tag, font=font(14), fill=col)

    W = board.width
    legend_h = 34 + 22 * ((len(SLOT_CN) + 3) // 4) + 22 * len([p for p in PARTS if p[4]]) + 30
    legend = Image.new("RGB", (W, legend_h), (24, 24, 30))
    dl = ImageDraw.Draw(legend)
    dl.text((10, 6), "槽位图例（框颜色 = 槽位；发型槽位见 A3 头像；头饰槽位默认装扮为空）", font=font(15),
            fill=(235, 235, 240))
    for i, (k, v) in enumerate(SLOT_CN.items()):
        x, y = 10 + (i % 4) * 330, 34 + (i // 4) * 22
        dl.rectangle((x, y + 3, x + 14, y + 17), fill=SLOT_COLOR[k])
        dl.text((x + 22, y), v, font=font(14), fill=(220, 220, 225))
    y = 34 + 22 * ((len(SLOT_CN) + 3) // 4) + 6
    for _, _, cn, _, note in PARTS:
        if note:
            dl.text((10, y), f"※ {cn}：{note}", font=font(13), fill=(255, 200, 170))
            y += 22
    dl.text((10, y), f"已用底色抹掉生图多画的圈号 {len(badges)} 个", font=font(13), fill=(150, 150, 160))
    full = Image.new("RGB", (W, board.height + 34 + legend.height), (10, 10, 14))
    full.paste(label(board, "A5 槽位拆解（c1，已去圈号）", 16), (0, 0))
    full.paste(legend, (0, board.height + 34))
    PREV.mkdir(parents=True, exist_ok=True)
    full.save(PREV / "parts_slots.jpg", quality=90)
    (OUT / "parts.json").write_text(json.dumps({
        "source": str(SRC.relative_to(ROOT)), "clean_source": "sheet_parts_c1_clean.png",
        "slots": SLOT_CN, "parts": meta, "badges_removed": [list(map(int, b)) for b in badges],
        "missing": {"hair": "发型单件未单独画；以 A1 / A3 为准", "headwear": "默认装扮无头饰"},
    }, ensure_ascii=False, indent=1), "utf-8")
    print("badges", badges)
    for p in meta:
        print(p["file"], p["source_box"])


if __name__ == "__main__":
    main()
