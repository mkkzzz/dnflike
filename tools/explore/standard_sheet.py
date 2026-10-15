"""standard_v1 设定集收尾（纯离线，不开窗口）。

  1. 从 A2 机位图切出持刀站姿透明图 → views/A2_ready_right.png
  2. A0 身份标注总览（正面 + 侧面，辨识点引线 + 头身比例尺）→ docs/previews/standard_v1/identity_callouts.png
  3. 游戏尺寸剪影与 1:1 缩略图 → docs/previews/standard_v1/game_scale.png
  4. 设定集总图 → docs/previews/standard_v1/standard_sheet.jpg
  5. 设定集索引 → art/characters/standard_v1/manifest.json

先跑 standard_master.py、standard_weapon.py、standard_parts.py，再跑本脚本：
  python tools/explore/standard_sheet.py
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

from standard_master import fit_h, font, hstack, label, on_gray, vstack

ROOT = Path(__file__).resolve().parents[2]
STD = ROOT / "art" / "characters" / "standard_v1"
PREV = ROOT / "docs" / "previews" / "standard_v1"
GAME_H = 190
GRAY = (205, 205, 210)

# 正面图坐标（views/A1_front.png，258×693）：(文字, 锚点, 放在哪一侧)
FRONT_CALLOUTS = [
    ("深红挑染：角色右前额（正面在观者左）", (124, 40), "L"),
    ("深灰眼", (142, 80), "R"),
    ("立领 + 翻驳领，深红内衬", (88, 120), "L"),
    ("黑色贴身高领内衣", (128, 128), "R"),
    ("胸前银扣横带", (146, 168), "R"),
    ("银扣腰带", (124, 293), "R"),
    ("右前臂绷带：到肘、露指、无护具", (30, 322), "L"),
    ("左前臂同款绷带", (226, 322), "R"),
    ("右大腿细绑带", (96, 400), "L"),
    ("深钢护膝", (80, 485), "L"),
    ("黑皮长风衣到小腿中部", (232, 540), "R"),
    ("分段深钢护胫", (78, 585), "L"),
    ("黑靴", (190, 668), "R"),
]
SIDE_CALLOUTS = [
    ("游戏机位朝右：挑染朝向镜头", (174, 52), "R"),
    ("太刀挂左腰：柄朝前上", (232, 250), "R"),
    ("鞘尾朝后下", (16, 515), "L"),
    ("此视角缺护膝护胫（母版瑕疵）", (110, 560), "R"),
]


def cutout_figure(img, region):
    a = np.asarray(img.convert("RGB"), np.float32)
    x0, y0, x1, y1 = region
    sub = a[y0:y1, x0:x1]
    bg = np.median(np.concatenate([a[:8, :8].reshape(-1, 3), a[-8:, :8].reshape(-1, 3)]), 0)
    dist = np.linalg.norm(sub - bg, axis=-1)
    near = dist < 16
    lab, _ = ndimage.label(near)
    border = np.unique(np.concatenate([lab[0], lab[-1], lab[:, 0], lab[:, -1]]))
    fg = ~np.isin(lab, border[border > 0])
    fg = ndimage.binary_opening(fg, iterations=1)
    lab2, n = ndimage.label(fg)
    sizes = ndimage.sum(fg, lab2, range(1, n + 1))
    big = int(np.argmax(sizes)) + 1
    sl = ndimage.find_objects(lab2)[big - 1]
    keep = [i + 1 for i, s in enumerate(sizes) if s > 150]
    fg = np.isin(lab2, keep)
    alpha = fg.astype(np.float32)
    edge = fg & ~ndimage.binary_erosion(fg, iterations=2)
    alpha[edge] = np.clip((dist[edge] - 10) / 40, 0.15, 1.0)
    rgb = (sub - bg * (1 - alpha[..., None])) / np.maximum(alpha[..., None], 1e-3)
    rgba = np.concatenate([np.clip(rgb, 0, 255), alpha[..., None] * 255], -1).astype(np.uint8)
    ys, xs = np.where(fg)
    return Image.fromarray(rgba).crop((int(xs.min()) - 6, int(ys.min()) - 6, int(xs.max()) + 7, int(ys.max()) + 7))


def callout_panel(view, callouts, title, margin=300, ruler=None):
    W, H = view.width + 2 * margin, view.height + 40
    im = Image.new("RGB", (W, H), GRAY)
    im.paste(view, (margin, 20), view)
    d = ImageDraw.Draw(im)
    f = font(14)
    left = sorted([c for c in callouts if c[2] == "L"], key=lambda c: c[1][1])
    right = sorted([c for c in callouts if c[2] == "R"], key=lambda c: c[1][1])
    for side, items in (("L", left), ("R", right)):
        last = -99
        for text, (ax, ay), _ in items:
            px, py = margin + ax, 20 + ay
            ty = max(py, last + 24)
            last = ty
            tw = d.textlength(text, font=f)
            if side == "L":
                tx = margin - 30 - tw
                d.line((px, py, margin - 22, ty + 9), fill=(150, 30, 40), width=2)
            else:
                tx = margin + view.width + 30
                d.line((px, py, tx - 8, ty + 9), fill=(150, 30, 40), width=2)
            d.ellipse((px - 4, py - 4, px + 4, py + 4), fill=(200, 30, 45), outline=(255, 255, 255))
            d.rectangle((tx - 4, ty - 1, tx + tw + 4, ty + 19), fill=(28, 28, 34))
            d.text((tx, ty), text, font=f, fill=(240, 235, 235))
    if ruler:
        top, head = ruler
        n = int(round(view.height / head))
        x = margin - 14
        for i in range(n + 1):
            y = 20 + top + i * head
            if y > H - 20:
                break
            d.line((x - 6, y, x + 6, y), fill=(40, 90, 200), width=2)
            d.text((x - 24, y - 8), str(i), font=font(12), fill=(40, 90, 200))
        d.line((x, 20 + top, x, 20 + min(view.height, n * head)), fill=(40, 90, 200), width=2)
    return label(im, title, 15)


def silhouette(rgba, h):
    g = fit_h(rgba, h)
    a = np.asarray(g)[..., 3] > 100
    out = np.full(a.shape + (3,), 235, np.uint8)
    out[a] = (20, 20, 26)
    return Image.fromarray(out)


def main():
    views = {p.stem: Image.open(p).convert("RGBA") for p in sorted((STD / "views").glob("A1_*.png"))}
    views["A4_base_body"] = Image.open(STD / "views" / "A4_base_body.png").convert("RGBA")
    pose_sheet = Image.open(STD / "sheet_pose_head_c2.png").convert("RGB")
    a2 = cutout_figure(pose_sheet, (0, 0, int(pose_sheet.width * 0.46), pose_sheet.height))
    a2.save(STD / "views" / "A2_ready_right.png")
    heads = pose_sheet.crop((int(pose_sheet.width * 0.46), 0, pose_sheet.width, pose_sheet.height))

    meas = json.loads((STD / "measure.json").read_text("utf-8"))
    fm = meas["views"]["A1_front"]
    head_px = fm["head_px"]
    front = callout_panel(views["A1_front"], FRONT_CALLOUTS, "A0 身份辨识点（正面）：文字规格优先于图", ruler=(6, head_px))
    side = callout_panel(views["A1_side_right"], SIDE_CALLOUTS, "A0 身份辨识点（侧面，游戏朝向）", margin=230)
    ident = hstack([front, side])
    ident.save(PREV / "identity_callouts.png")

    # 游戏尺寸：剪影 + 1:1 + 2 倍
    tiles = []
    for name, im in (("正面", views["A1_front"]), ("侧面", views["A1_side_right"]), ("A2 持刀", a2)):
        h = GAME_H if name != "A2 持刀" else int(GAME_H * a2.height / views["A1_front"].height * 0.98)
        sil = silhouette(im, h)
        one = on_gray(fit_h(im, h))
        two = one.resize((one.width * 2, one.height * 2), Image.NEAREST)
        tiles.append(label(hstack([sil, one, two], pad=8, bg=GRAY), f"{name}：剪影 / 1:1 / 2 倍", 13))
    scale = label(hstack(tiles, pad=12), f"游戏尺寸检查（人物 {GAME_H}px；剪影看可读性）", 14)
    scale.save(PREV / "game_scale.png")

    row_views = hstack([label(on_gray(fit_h(views[k], 420)), t, 14) for k, t in
                        (("A1_front", "A1 正面"), ("A1_three_quarter", "A1 3/4"), ("A1_side_right", "A1 侧面（朝右）"),
                         ("A1_back", "A1 背面"), ("A4_base_body", "A4 素体"))])
    a2_tile = label(on_gray(fit_h(a2, 600)), "A2 游戏机位持刀（朝右）", 15)
    heads_tile = label(fit_h(heads, 420), "A3 头部与表情", 15)
    palette = label(Image.open(PREV / "palette.png").convert("RGB"), "A6", 13)
    parts = Image.open(PREV / "parts_slots.jpg").convert("RGB")
    weapon = Image.open(PREV / "weapon_calibration.png").convert("RGB")
    overlay = label(Image.open(PREV / "weapon_v6_overlay.jpg").convert("RGB"), "A7 与 V6 对位校验", 14)
    W = 2000
    rows = [
        hstack([fit_h(ident, 760), fit_h(a2_tile, 760)]),
        hstack([row_views, vstack([heads_tile, palette])]),
        fit_h(parts, 900),
        vstack([fit_h(weapon, 560), fit_h(overlay, 300)]),
        scale,
    ]
    rows = [r if r.width <= W else r.resize((W, round(r.height * W / r.width)), Image.LANCZOS) for r in rows]
    sheet = vstack(rows, pad=16)
    head = Image.new("RGB", (sheet.width, 50), (40, 18, 22))
    ImageDraw.Draw(head).text((12, 10), "鬼剑士标准原画设定集 standard_v1（母版 c1，D027 / D030）", font=font(24),
                              fill=(255, 235, 230))
    sheet = vstack([head, sheet], pad=0)
    sheet.save(PREV / "standard_sheet.jpg", quality=90)

    manifest = {
        "asset_id": "char.swordsman.standard", "revision": "standard_v1", "date": "2026-10-15",
        "spec": "docs/tasks/art_tasks/char_swordsman_standard_v1.md（第一节文字规格优先于图）",
        "decisions": ["D025", "D026", "D027", "D029", "D030"],
        "master": "sheet_main_c1.png",
        "items": {
            "A0": {"name": "身份辨识点", "preview": "docs/previews/standard_v1/identity_callouts.png"},
            "A1": {"name": "四向转面", "source": "sheet_main_c1.png",
                   "files": [f"views/{k}.png" for k in ("A1_front", "A1_three_quarter", "A1_side_right", "A1_back")]},
            "A2": {"name": "游戏机位持刀（朝右）", "source": "sheet_pose_head_c2.png", "files": ["views/A2_ready_right.png"]},
            "A3": {"name": "头部与表情", "source": "sheet_pose_head_c2.png（右半）"},
            "A4": {"name": "素体", "source": "sheet_main_c1.png", "files": ["views/A4_base_body.png"]},
            "A5": {"name": "槽位拆解", "source": "sheet_parts_c1.png", "clean": "sheet_parts_c1_clean.png",
                   "index": "parts/parts.json"},
            "A6": {"name": "色号表", "file": "palette.json"},
            "A7": {"name": "标准太刀与标定", "source": "sheet_weapon_c1.png", "index": "weapon/katana.json"},
        },
        "errata": [
            "A1 侧面缺护膝护胫；A1 背面看不到刀鞘；A4 素体不应带护膝（护具属鞋槽位）——保留母版，以文字规格为准（方式乙）",
            "A3 的 3/4 头像挑染略偏中",
            "A5 胸前束带画成背带式（规格为两道横向银扣皮带）；刀鞘内带刀（空鞘以 A7 为准）；无单独发型件（以 A1/A3 为准）",
            "A7 空鞘行原图多画的镡已在切图中去掉",
        ],
        "not_used": {"sheet_main_c2.png": "手臂多出金属护臂", "sheet_pose_head_c1.png": "全身像朝左"},
        "followups": ["A8 手部与握法（正手 / 反手 / 拔刀 / 空握拳 / 张手）：生图确认超时未生成",
                      "A5 按槽位重出（含单独发型件、两道横带、空鞘）：生图确认超时未生成"],
        "tools": ["tools/explore/standard_master.py", "tools/explore/standard_weapon.py",
                  "tools/explore/standard_parts.py", "tools/explore/standard_sheet.py"],
    }
    (STD / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=1), "utf-8")
    print("[OK] a2", a2.size, "ident", ident.size, "sheet", sheet.size)


if __name__ == "__main__":
    main()
