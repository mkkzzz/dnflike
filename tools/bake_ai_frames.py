# -*- coding: utf-8 -*-
"""AI 动作帧图 → 实机帧条（正式美术生产线）

算法全部复用 `tools/make_anim.py`（已在其 CLI 里验证过），本脚本只补三件事：
  1. **多动作**：按 spec 一次处理一批帧图，而不是写死单张 2x3
  2. **归一化到实机尺寸**：AI 帧图很大，必须缩到游戏的角色尺度（见 spec 的 target_body_h）
  3. **写 anim.json**：产出与 `game/scripts/anim_lib.gd` 契约一致的清单项，Godot 侧零改动

流程：
    AI 整张动作帧图（绿幕 / 纯色底，rows x cols 网格）
      → 抠背景            make_anim.key_green / key_flat（本脚本补纯色底）
      → 连通域切帧        make_anim.split_frames（剑身/刀光归属最近角色）
      → 脚底锚点 + 统一画布 make_anim.anchor_of
      → 归一化到实机尺寸
      → 微弱像素化（2px 块 + 40 阶色阶）
      → 水平透明帧条 → game/art/{player,monster}/<action>.png
      → 合并写入 game/art/anim.json

用法：
    python tools/bake_ai_frames.py                # 烘焙 spec 里所有已存在的帧图
    python tools/bake_ai_frames.py --list         # 只看 spec 要求哪些帧图、哪些还没出
    python tools/bake_ai_frames.py --only idle,run
    python tools/bake_ai_frames.py --force        # 覆盖已有条目（默认也覆盖，保留此开关语义）
"""
import argparse
import json
import os
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(ROOT)
sys.path.insert(0, ROOT)

import make_anim as MA  # noqa: E402  复用已验证的算法

SPEC_PATH = os.path.join(ROOT, "ai_anim_spec.json")
OUT_ROOT = os.path.join(PROJ, "game", "art")
MANIFEST = os.path.join(OUT_ROOT, "anim.json")
FPS = 60                     # 实机物理帧率，durations 以物理帧为单位
PAD_TARGET = 12              # 帧条四周留白（**实机像素**；会按归一化倍率折算回源图空间）


# ------------------------------------------------------------------ 抠背景
def key_flat(rgb, tol: int = 26):
    """纯色底抠图：只把**与画面边缘连通**的近似底色算背景，避免吃掉角色内部的相近颜色。

    绿幕请走 make_anim.key_green；本函数给 art/ 下那种灰底立绘用。
    """
    h, w = rgb.shape[:2]
    corner = rgb[0:8, 0:8].reshape(-1, 3).mean(axis=0)
    dist = np.abs(rgb.astype(np.int16) - corner).max(axis=2)
    near = dist <= tol
    seed = np.zeros((h, w), bool)
    seed[0, :] = near[0, :]
    seed[-1, :] = near[-1, :]
    seed[:, 0] = near[:, 0]
    seed[:, -1] = near[:, -1]
    bg = ndimage.binary_propagation(seed, mask=near)
    fg = ndimage.binary_opening(~bg, iterations=1)
    fg = ndimage.binary_fill_holes(fg)      # 补角色内部的空洞
    return rgb, fg


def key_image(path, mode: str):
    rgb = np.array(Image.open(path).convert("RGB"))
    if mode == "flat":
        return key_flat(rgb)
    return MA.key_green(rgb)

# ------------------------------------------------------------------ 单动作烘焙
def bake_action(sheet_path, rows, cols, target_body_h, pixel, posterize, key_mode="green"):
    """一张动作帧图 → 水平帧条 + 锚点。返回 (strip_image, ax, ay, frames)。"""
    rgb, fg = key_image(sheet_path, key_mode)

    lab, cells = MA.split_frames(fg, rows, cols)
    frames = []
    for idx, comps in enumerate(cells):
        if not comps:
            print(f"    frame {idx + 1}: EMPTY（网格该格没检出角色）")
            continue
        mask = np.isin(lab, [c[0] for c in comps])
        body = ndimage.binary_opening(mask, iterations=6)
        hip_x, foot, hgt = MA.anchor_of(body)
        rgba = np.dstack([rgb, (mask * 255).astype(np.uint8)])
        frames.append(dict(rgba=rgba, mask=mask, hip_x=hip_x, foot=foot, hgt=hgt))
    if not frames:
        raise RuntimeError("没有切出任何帧")

    body_h = float(np.median([f["hgt"] for f in frames]))
    print(f"    切出 {len(frames)} 帧，body 高度中位数={body_h:.0f}px")

    # 归一化到实机角色尺寸（AI 帧图通常远大于游戏尺度）
    scale = target_body_h / body_h if body_h > 0 else 1.0

    # 统一画布：以 hip_x / foot 为锚点。
    # 两个坑：
    #   1) 必须同时算脚底**以下**的 `down` —— 刀尖/飘带可能越过脚底，
    #      只按 `up` 定高会把它们裁掉（foot 来自腐蚀后的身体掩码，细刀身不算在里面）
    #   2) pad 必须折算到源图空间，否则源图越大、折算到实机的留白越小（4K 帧图会几乎没留白）
    pad = max(2, int(round(PAD_TARGET / scale))) if scale > 0 else 12
    left = max(f["hip_x"] - np.nonzero(f["mask"])[1].min() for f in frames)
    right = max(np.nonzero(f["mask"])[1].max() - f["hip_x"] for f in frames)
    up = max(f["foot"] - np.nonzero(f["mask"])[0].min() for f in frames)
    down = max(max(0.0, np.nonzero(f["mask"])[0].max() - f["foot"]) for f in frames)
    cw = int(left + right) + pad * 2
    chh = int(up + down) + pad * 2
    ax, ay = int(left) + pad, int(up) + pad

    aligned = []
    for f in frames:
        canvas = Image.new("RGBA", (cw, chh), (0, 0, 0, 0))
        canvas.alpha_composite(Image.fromarray(f["rgba"], "RGBA"),
                               (int(round(ax - f["hip_x"])), int(round(ay - f["foot"]))))
        aligned.append(canvas)

    if abs(scale - 1.0) > 0.01:
        cw = max(2, int(round(cw * scale)))
        chh = max(2, int(round(chh * scale)))
        ax = int(round(ax * scale))
        ay = int(round(ay * scale))
        aligned = [a.resize((cw, chh), Image.LANCZOS) for a in aligned]
        print(f"    归一化 x{scale:.3f} → 画布 {cw}x{chh}，身高≈{target_body_h}px，留白≈{PAD_TARGET}px")

    # 微弱像素化：缩到 1/pixel → 轻度色阶量化 → alpha 二值化 → 最近邻放大
    step = 256 // posterize
    small = [a.resize((max(1, cw // pixel), max(1, chh // pixel)), Image.LANCZOS) for a in aligned]
    pixel_frames = []
    for s in small:
        arr = np.array(s)
        rgb_q = (arr[..., :3] // step * step + step // 2).clip(0, 255).astype(np.uint8)
        rgba = np.dstack([rgb_q, np.where(arr[..., 3] > 110, 255, 0).astype(np.uint8)])
        pixel_frames.append(Image.fromarray(rgba, "RGBA").resize((cw, chh), Image.NEAREST))

    # 自检：任何一帧贴到画布边缘 = 画布算小了（刀尖/飘带/发梢被裁）。
    # 这个坑很隐蔽（脚底以下的刀尖曾整段消失），所以每次都报出来，别等实机才发现。
    clipped = []
    for i, f in enumerate(pixel_frames):
        arr = np.array(f)
        ys, xs = np.nonzero(arr[..., 3] > 20)
        if len(xs) == 0:
            clipped.append(f"{i}:空帧")
            continue
        touch = []
        if xs.min() <= 0:
            touch.append("左")
        if xs.max() >= cw - 1:
            touch.append("右")
        if ys.min() <= 0:
            touch.append("上")
        if ys.max() >= chh - 1:
            touch.append("下")
        if touch:
            clipped.append(f"{i}:{'+'.join(touch)}")
    if clipped:
        print(f"    ⚠ 有 {len(clipped)} 帧贴到画布边缘，可能被裁：{', '.join(clipped)}")
        print("      → 检查帧图是否角色越出网格，或调大 PAD_TARGET / 调小 target_body_h")

    strip = Image.new("RGBA", (cw * len(pixel_frames), chh), (0, 0, 0, 0))
    for i, f in enumerate(pixel_frames):
        strip.alpha_composite(f, (i * cw, 0))
    return strip, ax, ay, len(pixel_frames)


# ------------------------------------------------------------------ 主流程
def load_manifest(path):
    if os.path.exists(path):
        try:
            with open(path, encoding="utf-8") as f:
                return json.load(f)
        except Exception as e:
            print(f"[AI] 现有 anim.json 解析失败（将重建）：{e}")
    return {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--spec", default=SPEC_PATH)
    ap.add_argument("--only", default="")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--out-root", default=OUT_ROOT,
                    help="贴图输出根目录（默认 game/art，仅供试烘焙时改到 temp/）")
    ap.add_argument("--manifest", default=MANIFEST,
                    help="anim.json 路径（默认 game/art/anim.json，仅供试烘焙时改到 temp/）")
    args = ap.parse_args()
    out_root, manifest_path = args.out_root, args.manifest

    with open(args.spec, encoding="utf-8") as f:
        spec = json.load(f)

    only = [s.strip() for s in args.only.split(",") if s.strip()]
    manifest = load_manifest(manifest_path)
    groups = manifest.setdefault("groups", {})
    manifest.setdefault("generator", "tools/bake_ai_frames.py")
    manifest.setdefault("note", "帧条契约见 docs/design/11_实机表现层管线.md")

    if args.list:
        print(f"[AI] 规格：{args.spec}")
        for grp, g in spec["groups"].items():
            print(f"  {grp}  target_body_h={g['target_body_h']}")
            for name, a in g["actions"].items():
                p = os.path.join(PROJ, a["sheet"])
                ok = "有" if os.path.exists(p) else "缺"
                print(f"    {name:12s} {a['rows']}x{a['cols']}={a['rows']*a['cols']}帧  [{ok}] {a['sheet']}")
        return

    baked = 0
    for grp, g in spec["groups"].items():
        target = float(g["target_body_h"])
        for name, a in g["actions"].items():
            if only and name not in only:
                continue
            sheet = os.path.join(PROJ, a["sheet"])
            if not os.path.exists(sheet):
                print(f"[AI] 跳过 {grp}/{name}：帧图不存在 {a['sheet']}")
                continue
            print(f"[AI] {grp}/{name}  <- {a['sheet']}  ({a['rows']}x{a['cols']})")
            try:
                strip, ax, ay, n = bake_action(sheet, a["rows"], a["cols"], target,
                                               int(g.get("pixel", MA.PIXEL)),
                                               int(g.get("posterize", MA.POSTERIZE)),
                                               str(a.get("key", g.get("key", "green"))))
            except Exception as e:
                print(f"    失败：{e}")
                continue

            out_dir = os.path.join(out_root, grp)
            os.makedirs(out_dir, exist_ok=True)
            out_png = os.path.join(out_dir, name + ".png")
            strip.save(out_png)

            ms = a.get("durations_ms") or [140] * n
            durs = [max(1, int(round(float(m) / 1000.0 * FPS))) for m in ms[:n]]
            if len(durs) != n:                      # 时长数量对不上就退回 fps 折算
                durs = [max(1, int(round(FPS / float(a.get("fps", 12))))) for _ in range(n)]

            rel = f"art/{grp}/{name}.png"
            groups.setdefault(grp, {})[name] = {
                "file": rel, "frames": n, "frame_w": strip.width // n, "frame_h": strip.height,
                "ax": ax, "ay": ay, "durations": durs, "loop": bool(a.get("loop", False)),
                "fps": int(a.get("fps", 12)), "source": "ai",
            }
            print(f"    -> {rel}  {n}帧 {strip.width // n}x{strip.height}  锚点({ax},{ay})  "
                  f"时长{[d/60 for d in durs]}s")
            baked += 1

    if baked:
        with open(manifest_path, "w", encoding="utf-8") as f:
            json.dump(manifest, f, ensure_ascii=False, indent=2)
        print(f"[AI] 已更新 {os.path.relpath(manifest_path, PROJ)}（本次写入 {baked} 个动作）")
    else:
        print("[AI] 没有可烘焙的帧图。先按 --list 的清单补充 AI 帧图。")


if __name__ == "__main__":
    main()
