# -*- coding: utf-8 -*-
"""AI 动作帧图 → 游戏动画：绿幕抠图 / 连通域切帧 / 脚底对齐 / 轻微像素化 / 合成 GIF。"""
import os
import sys

import numpy as np
from PIL import Image, ImageFilter
from scipy import ndimage

ROOT = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(ROOT)
BG = os.path.join(PROJ, "art", "concepts", "scenes", "dungeon", "legacy", "dungeon_hall.png")

# 本文件同时是「单张帧图预览」CLI 和「多动作 ingest」的算法库：
# tools/bake_ai_frames.py 直接 import 这里的 key_green / split_frames / anchor_of。
# 因此所有算法函数都不依赖模块级可变状态，**导入时无副作用**。
DEF_ROWS, DEF_COLS = 2, 3
PIXEL = 2            # 像素块边长（屏幕像素），2 = 很微弱的像素感
POSTERIZE = 40       # 每通道色阶数，越小像素画味越重
DURATIONS = [180, 150, 70, 80, 170, 220]   # 每帧时长 ms：预备慢、出刀快、命中定格
OUT = ""             # 由 main() 设定；算法函数不使用它


def key_green(rgb):
    r, g, b = rgb[..., 0].astype(np.int16), rgb[..., 1].astype(np.int16), rgb[..., 2].astype(np.int16)
    green = (g > 90) & (g - np.maximum(r, b) > 40)
    fg = ~green
    fg = ndimage.binary_opening(fg, iterations=1)
    # 去绿边：前景边缘像素的 G 通道压到 max(R,B)
    edge = fg & ndimage.binary_dilation(~fg, iterations=2)
    out = rgb.copy()
    spill = edge & (g > np.maximum(r, b))
    out[..., 1][spill] = np.maximum(r, b)[spill].astype(np.uint8)
    return out, fg


def split_frames(fg, rows=DEF_ROWS, cols=DEF_COLS):
    """逐步腐蚀直到分离出 rows*cols 个主体，再按最近主体回填全部前景像素（剑身/刀光/火焰归属最近的角色）。"""
    h, w = fg.shape
    need = rows * cols
    seeds = None
    for k in range(1, 25):
        er = ndimage.binary_erosion(fg, iterations=k)
        lab_e, n = ndimage.label(er)
        if n == 0:
            break
        sizes = ndimage.sum(er, lab_e, range(1, n + 1))
        big = [i + 1 for i, s in enumerate(sizes) if s > 1500]
        if len(big) >= need:
            big = sorted(big, key=lambda i: -sizes[i - 1])[:need]
            seeds = np.zeros_like(lab_e)
            for j, i in enumerate(big):
                seeds[lab_e == i] = j + 1
            print(f"[ANIM] separated {need} bodies at erosion={k}")
            break
    if seeds is None:
        raise RuntimeError("无法分离出全部帧")
    # 测地线生长：只沿前景连通扩张，剑身归属握剑的那一帧
    lab = seeds.copy()
    for _ in range(800):
        grown = ndimage.grey_dilation(lab, size=3)
        newly = (lab == 0) & fg & (grown > 0)
        if not newly.any():
            break
        lab[newly] = grown[newly]
    rest = fg & (lab == 0)
    if rest.any():
        _, (iy, ix) = ndimage.distance_transform_edt(lab == 0, return_indices=True)
        lab[rest] = lab[iy, ix][rest]
    cells = [[] for _ in range(need)]
    centers = ndimage.center_of_mass(seeds > 0, seeds, range(1, need + 1))
    for j, (cy, cx) in enumerate(centers):
        r = min(rows - 1, int(cy / (h / rows)))
        c = min(cols - 1, int(cx / (w / cols)))
        cells[r * cols + c].append((j + 1, int((seeds == j + 1).sum())))
    return lab, cells


def anchor_of(mask):
    ys, xs = np.nonzero(mask)
    foot = ys.max()
    top = ys.min()
    hgt = foot - top
    band = (ys > top + hgt * 0.40) & (ys < top + hgt * 0.62)
    hip_x = xs[band].mean() if band.any() else xs.mean()
    return hip_x, foot, hgt


def main():
    global OUT
    OUT = os.path.join(PROJ, "temp", "animation_tests", "processed")
    os.makedirs(OUT, exist_ok=True)
    sheet = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        PROJ, "temp", "animation_tests", "sheet_hero_slash.png")
    rgb = np.array(Image.open(sheet).convert("RGB"))
    rgb, fg = key_green(rgb)
    lab, cells = split_frames(fg)

    frames = []
    for idx, comps in enumerate(cells):
        if not comps:
            print(f"[ANIM] frame {idx + 1}: EMPTY")
            continue
        mask = np.isin(lab, [c[0] for c in comps])
        body = ndimage.binary_opening(mask, iterations=6)
        hip_x, foot, hgt = anchor_of(body)
        rgba = np.dstack([rgb, (mask * 255).astype(np.uint8)])
        frames.append(dict(rgba=rgba, mask=mask, hip_x=hip_x, foot=foot, hgt=hgt))
        print(f"[ANIM] frame {idx + 1}: comps={len(comps)} hip_x={hip_x:.0f} foot={foot} height={hgt}")

    hs = [f["hgt"] for f in frames]
    print(f"[ANIM] body height min={min(hs)} max={max(hs)} spread={(max(hs) - min(hs)) / max(hs) * 100:.1f}%")

    # 统一画布：以 hip_x / foot 为锚点
    left = max(f["hip_x"] - np.nonzero(f["mask"])[1].min() for f in frames)
    right = max(np.nonzero(f["mask"])[1].max() - f["hip_x"] for f in frames)
    up = max(f["foot"] - np.nonzero(f["mask"])[0].min() for f in frames)
    pad = 12
    cw = int(left + right) + pad * 2
    chh = int(up) + pad * 2
    ax, ay = int(left) + pad, int(up) + pad
    aligned = []
    for f in frames:
        canvas = Image.new("RGBA", (cw, chh), (0, 0, 0, 0))
        im = Image.fromarray(f["rgba"], "RGBA")
        canvas.alpha_composite(im, (int(round(ax - f["hip_x"])), int(round(ay - f["foot"]))))
        aligned.append(canvas)

    # 轻微像素化：缩到 1/PIXEL → 色阶轻度量化 → alpha 二值化 → 最近邻放大
    small = [a.resize((cw // PIXEL, chh // PIXEL), Image.LANCZOS) for a in aligned]
    step = 256 // POSTERIZE
    pixel_frames = []
    for s in small:
        arr = np.array(s)
        rgb_q = (arr[..., :3] // step * step + step // 2).clip(0, 255).astype(np.uint8)
        rgba = np.dstack([rgb_q, np.where(arr[..., 3] > 110, 255, 0).astype(np.uint8)])
        pixel_frames.append(Image.fromarray(rgba, "RGBA").resize((cw, chh), Image.NEAREST))

    # 场景背景（暗角处理）
    bg = Image.open(BG).convert("RGB")
    scale = (chh * 1.25) / bg.height
    bg = bg.resize((int(bg.width * scale), int(bg.height * scale)), Image.LANCZOS)
    bw, bh = cw + 260, int(chh * 1.12)
    bx = (bg.width - bw) // 2
    bg = bg.crop((bx, bg.height - bh - int(chh * 0.05), bx + bw, bg.height - int(chh * 0.05)))
    bgarr = np.array(bg).astype(np.float32) * 0.62
    bg = Image.fromarray(bgarr.clip(0, 255).astype(np.uint8))

    def compose(fr):
        out = bg.copy().convert("RGBA")
        ox, oy = 80, bh - chh + 6
        shadow = Image.new("RGBA", out.size, (0, 0, 0, 0))
        from PIL import ImageDraw
        sd = ImageDraw.Draw(shadow)
        sx, sy = ox + ax, oy + ay
        sd.ellipse([sx - 90, sy - 14, sx + 90, sy + 10], fill=(0, 0, 0, 110))
        out.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(4)))
        out.alpha_composite(fr, (ox, oy))
        return out.convert("RGB")

    composed = [compose(f) for f in pixel_frames]
    gif = os.path.join(OUT, "slash_pixel.gif")
    composed[0].save(gif, save_all=True, append_images=composed[1:], duration=DURATIONS[:len(composed)], loop=0, optimize=False)

    hd = [compose(a) for a in aligned]
    gif_hd = os.path.join(OUT, "slash_hd.gif")
    hd[0].save(gif_hd, save_all=True, append_images=hd[1:], duration=DURATIONS[:len(hd)], loop=0, optimize=False)

    # 帧条（透明底，供引擎使用）
    sheet = Image.new("RGBA", (cw * len(pixel_frames), chh), (0, 0, 0, 0))
    for i, f in enumerate(pixel_frames):
        sheet.alpha_composite(f, (i * cw, 0))
        f.save(os.path.join(OUT, f"slash_{i + 1:02d}.png"))
    sheet.save(os.path.join(OUT, "slash_strip.png"))

    # 像素感对比图：原图 vs 轻微像素化（局部放大）
    k = 2
    crop_box = (ax - 110, ay - up + 10, ax + 110, ay - up + 230)
    a0 = Image.alpha_composite(Image.new("RGBA", aligned[0].size, (40, 38, 48, 255)), aligned[0]).crop(crop_box)
    p0 = Image.alpha_composite(Image.new("RGBA", pixel_frames[0].size, (40, 38, 48, 255)), pixel_frames[0]).crop(crop_box)
    cmp = Image.new("RGB", (a0.width * k * 2 + 20, a0.height * k), (20, 18, 24))
    cmp.paste(a0.resize((a0.width * k, a0.height * k), Image.NEAREST).convert("RGB"), (0, 0))
    cmp.paste(p0.resize((p0.width * k, p0.height * k), Image.NEAREST).convert("RGB"), (a0.width * k + 20, 0))
    cmp.save(os.path.join(OUT, "pixel_compare.png"))

    print(f"[ANIM] frames={len(pixel_frames)} canvas={cw}x{chh} pixel={PIXEL} posterize={POSTERIZE}")
    print(f"[ANIM] gif={gif}")
    print(f"[ANIM] gif_hd={gif_hd}")


if __name__ == "__main__":
    main()
