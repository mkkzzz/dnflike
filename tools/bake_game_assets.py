# -*- coding: utf-8 -*-
"""把 render_preview.py 的程序化美术烘焙成 Godot 实机贴图（输出到 game/art/）。

单一美术源原则
--------------
角色 / 怪物 / HUD / 背景 / 特效的**唯一定义**都在 `tools/render_preview.py`。
本脚本只负责「采样 → 烘焙 → 落盘」，不重复描述任何美术细节。
改完美术重跑本脚本，实机即同步，不会出现两份实现漂移。

将来 M4 换 AI 真帧图时，只要让本脚本输出同样的帧条格式，
Godot 侧一行都不用改。

用法
----
    python tools/bake_game_assets.py                  # 全部（背景 + 暗角 + 角色 + 怪物）
    python tools/bake_game_assets.py --only bg        # 只烘焙背景
    python tools/bake_game_assets.py --only char      # 只烘焙角色/怪物帧条
    python tools/bake_game_assets.py --only char:player   # 只烘焙玩家
"""
import argparse
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(ROOT)
sys.path.insert(0, ROOT)

import render_preview as RP  # noqa: E402  美术源

OUT = os.path.join(PROJ, "game", "art")
GAME_W, GAME_H = 1280, 720           # 实机分辨率
SCALE = GAME_W // RP.W               # = 2，preview 世界 640x360 → 实机 1280x720
GROUND_Y = RP.GROUND0 * SCALE        # 224 * 2 = 448，实机地面 y

BG_PATH = os.path.join(RP.BG_PATH)

# 帧条宽度上限：GL 的 GL_MAX_TEXTURE_SIZE 桌面端一般是 16384，
# 这里留一半余量，超了就说明该减少帧数或改用网格（目前只有 idle 接近）。
STRIP_MAX_W = 8192


def _ensure(*parts):
    p = os.path.join(OUT, *parts)
    os.makedirs(p, exist_ok=True)
    return p


def _save(img, *parts):
    p = os.path.join(OUT, *parts)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    img.save(p)
    return os.path.relpath(p, PROJ).replace("\\", "/")


# ------------------------------------------------------------------ 背景 / 暗角
def bake_background():
    """地牢背景：沿用 preview 的取景（顶部裁掉 8%）与调色，烘焙到实机分辨率。

    注意这里直接从原始 1264x848 缩放到 1280x720，
    比 preview 的「先降到 640x360 再放大 2 倍」更清晰（符合"高清位图质感"的定稿要求）。
    """
    if not os.path.exists(BG_PATH):
        raise FileNotFoundError(f"缺背景源图：{BG_PATH}")
    img = Image.open(BG_PATH).convert("RGB")
    sw, sh = img.size
    ch = int(sw * 9 / 16)                 # 16:9 裁切高度
    top = int(sh * 0.08)                  # 与 preview 同取景
    img = img.crop((0, top, sw, min(sh, top + ch)))
    img = img.resize((GAME_W, GAME_H), Image.LANCZOS)

    arr = np.array(img).astype(np.float32)
    arr = arr * 1.18                      # 与 preview 同调色
    arr[..., 0] += 6
    arr[..., 2] += 8
    return _save(Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8)),
                 "bg_dungeon.png")


def bake_vignette():
    """暗角：preview 里是 `world *= VIGNETTE`（边缘压暗），此处烘焙成黑色半透明叠加层。"""
    yy, xx = np.mgrid[0:GAME_H, 0:GAME_W].astype(np.float32)
    v = 1 - 0.55 * (((xx - RP.W * 0.5 * SCALE) / (400.0 * SCALE)) ** 2 +
                    ((yy - 190.0 * SCALE) / (250.0 * SCALE)) ** 2)
    v = np.clip(v, 0.35, 1.0)
    rgba = np.zeros((GAME_H, GAME_W, 4), np.uint8)
    rgba[..., 3] = np.clip((1.0 - v) * 255.0, 0, 255).astype(np.uint8)
    return _save(Image.fromarray(rgba, "RGBA"), "vignette.png")


BAKERS = {
    "bg": (bake_background, bake_vignette),
}


# ------------------------------------------------------------------ 角色 / 怪物帧条
# 帧条规范（docs/design/11_实机表现层管线.md 第四节）：
#   - 水平排列的 PNG，所有帧共用同一画布尺寸与锚点（否则播放时会抖）
#   - 一律烘焙成朝右（facing = +1），实机靠水平翻转处理朝左
#   - 锚点 = 脚底相对帧左上角的像素偏移，写进 game/art/anim.json
#
# 坐标：preview 世界 640x360 → 实机 1280x720（SCALE=2）。
# 角色在 preview 里本来就是画进 2 倍分辨率图层再降采样的（char_layer 超采样），
# 实机分辨率恰好等于那层 2 倍图层，所以这里**不降采样**：形状与描边比例
# 和 preview 放大到实机后完全一致，边缘还更干净。

CHAR_X = 160.0                                     # 画布上的 preview 世界 X
FEET_Y = float(RP.GROUND0)                         # 画布上的 preview 世界脚底 Y
ANCHOR = (int(round(CHAR_X * SCALE)), int(round(FEET_Y * SCALE)))   # (320, 448)
WIN = (24, 40, 1016, 600)                          # 裁剪窗口（角色不可能越界，留足余量）
PAD = 3                                            # 每帧四周留白（实机像素）


def _char_layer_2x(drawfn, iters=2):
    """角色画进 2 倍分辨率透明层 + 描边（同 preview 的 char_layer，但保留 2 倍分辨率）。"""
    img = Image.new("RGBA", (GAME_W, GAME_H), (0, 0, 0, 0))
    drawfn(ImageDraw.Draw(img))
    a = np.array(img)[WIN[1]:WIN[3], WIN[0]:WIN[2]]
    return RP.finish_layer(a, 0.0, iters=iters)


def _player_frame_draw(fr):
    """一帧玩家：solve → place → draw_player（参数全部来自 render_preview 的帧集）。"""
    pose = fr["pose"]
    q = RP.place(RP.solve(pose, RP.PL_LEN, fr["rot"]), RP.PL_LEN, CHAR_X, FEET_Y, fr["h"], 1,
                 fr["grounded"], fr["rot"])
    return _char_layer_2x(lambda d: RP.draw_player(d, q, 1, fr["tnow"], fr["speed"]))


def _goblin_frame_draw(fr):
    """一帧哥布林：solve → place → draw_goblin（GOB1 绿皮战士）。"""
    pose = fr["pose"]
    q = RP.place(RP.solve(pose, RP.GB_LEN, fr["rot"]), RP.GB_LEN, CHAR_X, FEET_Y, fr["h"], 1,
                 fr["grounded"], fr["rot"])
    return _char_layer_2x(lambda d: RP.draw_goblin(d, q, 1, RP.GOB1))


def bake_state_strip(who, name, frames, loop, out_dir):
    """把一个动作的全部帧画出来，裁到公共包围盒，横向拼成一张帧条 PNG。

    帧条超过纹理宽度上限时自动抽帧（被抽掉那帧的时长并到前一帧上，动作总时长不变）。
    """
    draw = _player_frame_draw if who == "player" else _goblin_frame_draw
    arrs = [draw(fr) for fr in frames]
    idx = list(range(len(arrs)))
    tks = [fr["ticks"] for fr in frames]

    while True:
        boxes = []
        for i in idx:
            ys, xs = np.nonzero(arrs[i][:, :, 3])
            if xs.size == 0:
                raise RuntimeError(f"{who}/{name} 第 {i + 1} 帧是空的")
            boxes.append((int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1))
        x0 = min(b[0] for b in boxes) - PAD
        y0 = min(b[1] for b in boxes) - PAD
        x1 = max(b[2] for b in boxes) + PAD
        y1 = max(b[3] for b in boxes) + PAD
        fw, fh = x1 - x0, y1 - y0
        if fw * len(idx) <= STRIP_MAX_W or len(idx) <= 1:
            break
        keep, kt = [], []
        for k, i in enumerate(idx):
            if k % 2 == 0:
                keep.append(i)
                kt.append(tks[k])
            else:
                kt[-1] += tks[k]                     # 抽掉这帧，时长并到前一帧
        print(f"[BAKE]   {who}/{name}: 帧条 {fw * len(idx)}px 超上限，抽帧 {len(idx)} → {len(keep)}")
        idx, tks = keep, kt

    if x0 <= 0 or y0 <= 0 or x1 >= WIN[2] - WIN[0] or y1 >= WIN[3] - WIN[1]:
        print(f"[BAKE] !! {who}/{name} 包围盒贴到裁剪窗口边（{x0},{y0},{x1},{y1}），可能被裁")

    strip = Image.new("RGBA", (fw * len(idx), fh), (0, 0, 0, 0))
    for n, i in enumerate(idx):
        strip.paste(Image.fromarray(arrs[i][y0:y1, x0:x1]), (n * fw, 0))

    rel = _save(strip, out_dir, f"{name}.png")
    # 锚点：脚底在画布上的位置（ANCHOR）减去裁剪与窗口偏移
    ax = ANCHOR[0] - WIN[0] - x0
    ay = ANCHOR[1] - WIN[1] - y0
    kb = os.path.getsize(os.path.join(PROJ, rel)) / 1024.0
    print(f"[BAKE]   {who}/{name:12s} {len(idx):3d}帧  {fw:4d}x{fh:<4d}  条 {fw * len(idx):5d}px  "
          f"锚点({ax},{ay})  {kb:6.1f}KB  loop={loop}  时长{sum(tks)}帧")
    return {
        "file": rel[len("game/"):].replace("\\", "/"),
        "path": "res://" + rel[len("game/"):].replace("\\", "/"),
        "frames": len(idx),
        "frame_w": fw,
        "frame_h": fh,
        "durations": tks,
        "fps": RP.FPS_BAKE,
        "loop": bool(loop),
        "ax": ax,
        "ay": ay,
    }


def bake_characters(only_group=""):
    """玩家 / 怪物全部实机动作 → 帧条 + anim.json。"""
    groups = {}
    for who, names, out_dir in (("player", RP.PLAYER_STATE_NAMES, "player"),
                                ("monster", RP.MONSTER_STATE_NAMES, "monster")):
        if only_group and only_group != who:
            continue
        entries = {}
        for name in names:
            spec = RP.state_frames(who, name)
            if spec is None:
                print(f"[BAKE]   {who}/{name}: render_preview 没有定义，跳过")
                continue
            frames, loop = spec
            entries[name] = bake_state_strip(who, name, frames, loop, out_dir)
        groups[who] = entries
    return groups


def _merge_manifest(groups):
    """anim.json：Godot 侧切帧与定位的唯一依据。"""
    path = os.path.join(OUT, "anim.json")
    data = {
        "version": 1,
        "generator": "tools/bake_game_assets.py",
        "source": "tools/render_preview.py",
        "note": "帧条一律朝右（facing=+1）；锚点 (ax,ay) = 脚底相对帧左上角的实机像素偏移",
        "game": {"width": GAME_W, "height": GAME_H},
        "preview": {"width": RP.W, "height": RP.H},
        "scale": SCALE,
        "fps": RP.FPS_GAME,
        "groups": {},
    }
    if os.path.exists(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                data["groups"] = json.load(f).get("groups", {})
        except Exception:
            data["groups"] = {}
    for g, entries in groups.items():
        if entries:
            data["groups"][g] = entries
    os.makedirs(OUT, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1, sort_keys=True)
        f.write("\n")
    return os.path.relpath(path, PROJ).replace("\\", "/")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="", help="逗号分隔：bg / char / char:player / char:monster")
    args = ap.parse_args()
    want = [s.strip() for s in args.only.split(",") if s.strip()] or ["bg", "char"]

    _ensure()
    print(f"[BAKE] 输出目录 {os.path.relpath(OUT, PROJ)}  ({GAME_W}x{GAME_H}, scale={SCALE})")
    groups = {}
    for key in want:
        if key == "bg":
            for fn in BAKERS["bg"]:
                print(f"[BAKE] {fn.__name__:22s} -> {fn()}")
        elif key == "char" or key.startswith("char:"):
            groups.update(bake_characters(key.split(":", 1)[1] if ":" in key else ""))
        else:
            print(f"[BAKE] 跳过未知目标：{key}")
    if groups:
        print(f"[BAKE] anim.json          -> {_merge_manifest(groups)}")


if __name__ == "__main__":
    main()
