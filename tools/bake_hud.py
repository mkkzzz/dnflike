# -*- coding: utf-8 -*-
"""把 render_preview.py 的成品级 HUD 静态层烘焙成 Godot 实机贴图 + 坐标清单。

单一美术源原则
--------------
HUD 的**静态**部分（底板 / 技能格外框 / 技能图标 / 头像 / HP·MP 球 / 铭牌框 / 小地图）
只在 `tools/render_preview.py` 里定义一次。本脚本 import 它，调用它已有的
`make_icon()` 等函数取像素，**不重新描述任何美术细节**，因此不会出现两份实现漂移。
改完 preview 的 HUD 重跑本脚本，实机即同步。

动态部分（血条填充 / 数值文字 / COMBO / 冷却遮罩）由 `game/scripts/hud.gd`
按本脚本产出的 manifest 坐标叠加，见该文件的 TODO 与公开接口。

坐标约定
--------
preview 的 HUD 是**直接画在 1280x720（W*S, H*S）画布上**的
（render_preview.py:1298 `Image.new("RGBA", (W*S, H*S), ...)`），
所以 build_hud() 里的坐标**本身就是实机像素坐标，不需要再乘 SCALE**。
实机 viewport 也是 1280x720（project.godot: viewport_width/height），一一对应。

产出
----
    game/art/hud/hud_manifest.json   坐标清单（Godot 侧唯一布局来源）
    game/art/hud/panel/*.png         HUD 底板
    game/art/hud/slots/*.png         技能格框 + 图标（8 格 × 图标变体）
    game/art/hud/orbs/*.png          HP / MP 球底
    game/art/hud/plate/*.png         铭牌框 / 小地图 / 房间名 / 经验条

用法
----
    python tools/bake_hud.py            # 烘焙 + 自检
    python tools/bake_hud.py --check    # 只校验已有 manifest 与贴图
"""
import argparse
import json
import os
import sys

from PIL import Image, ImageDraw
import numpy as np

ROOT = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(ROOT)
sys.path.insert(0, ROOT)

import render_preview as RP  # noqa: E402  美术源（只读，不修改）

OUT = os.path.join(PROJ, "game", "art", "hud")
CANVAS_W, CANVAS_H = RP.W * RP.S, RP.H * RP.S        # 1280 x 720
MANIFEST = os.path.join(OUT, "hud_manifest.json")

# ---------------------------------------------------------------- 版式（照抄 preview build_hud）
PANEL_TOP = 650
PANEL_GOLD = (180, 142, 66, 255)
PANEL_GOLD_D = (70, 56, 30, 255)
PANEL_LINE = (90, 74, 40, 255)

EXP_X0, EXP_X1 = 140, 1140
EXP_FRAC = 0.63

ORB = {
    "hp": dict(cx=70, cy=668, r=50, col=(236, 60, 60), col_d=(120, 10, 20)),
    "mp": dict(cx=1210, cy=668, r=50, col=(80, 140, 255), col_d=(16, 30, 120)),
}

PORTRAIT_BOX = (282, 202, 742, 662)
PORTRAIT_POS = (20, 574)
PORTRAIT_SZ = 64

# build_hud(): icons / keys / gap / x0 的逐字对应
ICONS = [
    ("up", (120, 30, 40), (255, 120, 90)),
    ("wave", (60, 20, 100), (190, 110, 255)),
    ("dash", (20, 40, 100), (110, 180, 255)),
    ("cross", (90, 60, 20), (250, 200, 90)),
    ("sword", (40, 60, 70), (150, 210, 220)),
    ("aura", (90, 10, 20), (230, 70, 90)),
    ("hp", (40, 30, 30), (90, 60, 60)),
    ("mp", (30, 30, 40), (60, 60, 90)),
]
KEYS = ["A", "S", "D", "F", "G", "H", "1", "2"]
SLOT_GAP = 60
SLOT_W = 53               # [x-3, y-3, x+49, y+49]
SLOT_H = 53
SLOT_ICON = 46            # make_icon(sz=46)
SLOT_ICON_OFF = 3


def slot_x(i):
    """build_hud() 里 x = x0 + i*gap + (14 if i >= 6 else 0)"""
    n = len(ICONS)
    x0 = CANVAS_W // 2 - (n * SLOT_GAP) // 2 + 7
    return x0 + i * SLOT_GAP + (14 if i >= 6 else 0)


def slot_pos(i):
    return (slot_x(i), 664)


# 职业 → A/S 两格的技能图标（preview 里没有职业图标，这里用它的 make_icon 变体映射，
# 保证仍然是"唯一美术源生成"，不是 GDScript 现画）
JOB_SLOT_ICONS = {
    0: {0: "up", 1: "wave"},
    1: {0: "aura", 1: "wave"},      # 狂战士：A 血怒 / S 怒斩
    2: {0: "cross", 1: "dash"},     # 剑魂：A 拔刀斩 / S 连突刺
}
JOB_NAMES = {0: "基础鬼剑士", 1: "狂战士", 2: "剑魂"}

# 静态文字（坐标 / 字号 / 颜色直接抄 preview，保证 1:1 对齐）
STATIC_TEXTS = [
    dict(id="room_name", text="幽暗回廊", pos=[24, 20], size=24, anchor="tl",
         color=[240, 220, 170, 255], stroke=2, stroke_color=[20, 10, 0, 255],
         group="room"),
    dict(id="hero_name", text="幽影剑士  Lv.30", pos=[92, 606], size=17, anchor="tl",
         color=[255, 236, 190, 255], stroke=2, stroke_color=[10, 6, 0, 255],
         group="hero"),
]

ICON_COLOR = {
    "hp": (230, 50, 60, 255),
    "mp": (60, 110, 240, 255),
    "aura": (255, 120, 120, 255),
    "dash_hi": (200, 220, 255, 255),
    "wave_hi": (235, 210, 255, 255),
}


# ---------------------------------------------------------------- 工具
def canvas():
    img = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, 0))
    return img, ImageDraw.Draw(img)


def save_crop(canvas_img, box, group, name):
    """把全画布的一块裁出来落盘，返回相对 manifest 用的路径与几何。

    裁切保证贴图原点 = 元素在屏上的真实原点，hud.gd 直接 draw_texture 到 pos 即可。
    若元素伸出画布（如底部球体超出 720），裁切后尺寸会变小，pos 仍是**未裁时的原点**，
    裁剪量由 Godot 侧的绘制顺序自然吸收（见 hud.gd 的注释）。
    """
    x0, y0, x1, y1 = (int(round(v)) for v in box)
    x0 = max(0, x0)
    y0 = max(0, y0)
    x1 = min(CANVAS_W, x1)
    y1 = min(CANVAS_H, y1)
    sub = canvas_img.crop((x0, y0, x1, y1))
    d = os.path.join(OUT, group)
    os.makedirs(d, exist_ok=True)
    rel = f"{group}/{name}.png"
    sub.save(os.path.join(OUT, rel))
    return dict(path=rel, pos=[x0, y0], size=[x1 - x0, y1 - y0])


def _unused_rect_points(x0, y0, x1, y1, width):
    """PIL 经典语义（ImageDraw.rectangle + width）：描边画在矩形**内侧**。
    render_preview 的 HUD 全是这个调用，所以直接照抄即可 1:1。"""
    return [x0, y0, x1, y1], width


# ---------------------------------------------------------------- 各静态块
def draw_panel():
    img, d = canvas()
    top = PANEL_TOP
    for y in range(top, CANVAS_H):
        d.line([(0, y), (CANVAS_W, y)],
               fill=(16, 14, 22, int(205 + 40 * (y - top) / (CANVAS_H - top))))
    d.line([(0, top), (CANVAS_W, top)], fill=PANEL_GOLD, width=2)
    d.line([(0, top + 3), (CANVAS_W, top + 3)], fill=PANEL_GOLD_D)
    return img


def draw_exp_bar():
    img, d = canvas()
    top = PANEL_TOP
    d.rectangle([EXP_X0, top + 9, EXP_X1, top + 14], fill=(30, 26, 20, 255), outline=PANEL_LINE)
    d.rectangle([EXP_X0 + 1, top + 10, EXP_X0 + int((EXP_X1 - EXP_X0) * EXP_FRAC), top + 13],
                fill=(232, 202, 82, 255))
    return img


def draw_slot_frames():
    """8 个技能格底色框（不含图标、不含按键字母）。"""
    img, d = canvas()
    for i in range(len(ICONS)):
        x, y = slot_pos(i)
        d.rectangle([x - 3, y - 3, x + 49, y + 49], fill=(10, 8, 12, 255),
                    outline=(150, 118, 58, 255), width=2)
    return img


def draw_orb(kind):
    """照抄 render_preview.draw_orb() 的**底盘**：深色内胆 + 双层描边。

    注意：preview 里液面是在这层之后 alpha_composite 上去的（画在球底**之上**），
    所以这里必须把液面的位置空出来 —— 实机由 hud.gd 先画液面再叠本层（描边不遮液面）。
    玻璃高光另出图，见 draw_orb_glass()。
    """
    o = ORB[kind]
    cx, cy, r = o["cx"], o["cy"], o["r"]
    img, d = canvas()
    d.ellipse([cx - r - 7, cy - r - 7, cx + r + 7, cy + r + 7],
              fill=(26, 20, 16, 255), outline=PANEL_GOLD, width=3)
    d.ellipse([cx - r - 2, cy - r - 2, cx + r + 2, cy + r + 2], outline=(80, 62, 32, 255), width=2)
    return img


def draw_orb_glass(kind):
    """球体玻璃高光（preview: ld.ellipse([sz*0.2, sz*0.12, sz*0.55, sz*0.38], (255,255,255,70))）。

    透明底，**裁到内圆**（preview 用 putalpha(m) 裁过），叠在液面之上。
    高光位于内圆**左上**（约 x 27..62 / y 19..45，坐标相对贴图），
    圆心处本来就是透明的 —— 校验时别只看正中心那一个像素。
    """
    o = ORB[kind]
    cx, cy, r = o["cx"], o["cy"], o["r"]
    sz = 2 * r
    img, d = canvas()
    d.ellipse([cx - r + sz * 0.2, cy - r + sz * 0.12,
               cx - r + sz * 0.55, cy - r + sz * 0.38], fill=(255, 255, 255, 70))
    # 圆形裁剪：只保留内圆里的像素（直接操作 ndarray，避免重建通道时丢 alpha）
    arr = np.array(img)
    yy, xx = np.mgrid[0:CANVAS_H, 0:CANVAS_W]
    inside = ((xx - cx) ** 2 + (yy - cy) ** 2) <= r * r
    arr[..., 3] = np.where(inside, arr[..., 3], 0)
    return Image.fromarray(arr, "RGBA")


def draw_portrait():
    img, d = canvas()
    ok = False
    if os.path.exists(RP.PORTRAIT_PATH):
        try:
            av = Image.open(RP.PORTRAIT_PATH).convert("RGBA")
            av = av.crop(PORTRAIT_BOX).resize((PORTRAIT_SZ, PORTRAIT_SZ), Image.LANCZOS)
            av = av.transpose(Image.FLIP_LEFT_RIGHT)
            m = Image.new("L", (PORTRAIT_SZ, PORTRAIT_SZ), 0)
            ImageDraw.Draw(m).ellipse([1, 1, PORTRAIT_SZ - 2, PORTRAIT_SZ - 2], fill=255)
            av.putalpha(m)
            img.alpha_composite(av, PORTRAIT_POS)
            ok = True
        except Exception as e:                      # pragma: no cover
            print(f"[BAKE][WARN] 头像读取失败：{e}")
    px, py = PORTRAIT_POS
    d.ellipse([px, py, px + 64, py + 64], outline=PANEL_GOLD, width=3)
    d.ellipse([px + 3, py + 3, px + 61, py + 61], outline=PANEL_GOLD_D)
    return img, ok


def draw_nameplate():
    """顶部当前目标怪物的铭牌框（不含名字 / 等级 / 分段填充）。"""
    img, d = canvas()
    x0, x1, y = 400, 880, 36
    d.rectangle([x0 - 46, y - 6, x0 - 8, y + 30], fill=(20, 16, 12, 230),
                outline=(160, 128, 60, 255), width=2)
    d.rectangle([x0 - 2, y - 2, x1 + 2, y + 18], fill=(10, 8, 8, 230),
                outline=(160, 128, 60, 255), width=2)
    return img


def draw_room_map():
    """右上角小地图（静态装饰）。"""
    img, d = canvas()
    mx, my, cs = 1100, 22, 26
    rooms = [(0, 1), (1, 1), (2, 1), (2, 0), (3, 0), (3, 1)]
    for i in range(len(rooms) - 1):
        a, b = rooms[i], rooms[i + 1]
        d.line([(mx + a[0] * cs + cs // 2, my + a[1] * cs + cs // 2),
                (mx + b[0] * cs + cs // 2, my + b[1] * cs + cs // 2)],
               fill=(120, 110, 90, 255), width=3)
    for i, (rx, ry) in enumerate(rooms):
        col = (70, 66, 60, 255) if i > 1 else (130, 120, 100, 255)
        if i == len(rooms) - 1:
            col = (150, 40, 40, 255)
        d.rectangle([mx + rx * cs + 3, my + ry * cs + 3,
                     mx + rx * cs + cs - 3, my + ry * cs + cs - 3],
                    fill=col, outline=(20, 16, 12, 255), width=2)
    return img


# ---------------------------------------------------------------- 主流程
def bake():
    os.makedirs(OUT, exist_ok=True)
    files = {}

    # 1) 底板
    panel_img = draw_panel()
    files["panel"] = save_crop(panel_img, (0, PANEL_TOP, CANVAS_W, CANVAS_H), "panel", "panel_bottom")

    exp_img = draw_exp_bar()
    files["exp_bar"] = save_crop(exp_img, (EXP_X0, PANEL_TOP + 9, EXP_X1 + 1, PANEL_TOP + 15),
                                 "panel", "exp_bar")

    # 2) 技能格框（仅底板）
    frames_img = draw_slot_frames()
    boxes = []
    for i in range(len(ICONS)):
        x, y = slot_pos(i)
        boxes.append((x - 3, y - 3, x + 49 + 1, y + 49 + 1))
    all_box = (min(b[0] for b in boxes), min(b[1] for b in boxes),
               max(b[2] for b in boxes), max(b[3] for b in boxes))
    files["slot_frames"] = save_crop(frames_img, all_box, "slots", "slot_frames")
    # 3) 技能图标：**一格一图**（格框 + 图标烘焙在一起，53x53），
    #    贴图原点 == 屏幕上的 [x-3, y-3]，hud.gd 直接 draw_texture 到 slot.frame_origin。
    #    A/S 两格按职业各出一张变体（图标种类仍全部来自 RP.make_icon）。
    base_color = {k: (a, b) for k, a, b in ICONS}
    slot_icon_files = {}
    for i, (kind, c1, c2) in enumerate(ICONS):
        x, y = slot_pos(i)
        for job in JOB_SLOT_ICONS:
            k = JOB_SLOT_ICONS[job].get(i, kind)
            kc1, kc2 = base_color[k]
            img, d = canvas()
            # 画布原点 = 贴图原点 = 屏幕 (x-3, y-3)，故格框左上角在画布 (0,0)
            d.rectangle([0, 0, 52, 52], fill=(10, 8, 12, 255),
                        outline=(150, 118, 58, 255), width=2)
            img.alpha_composite(RP.make_icon(k, kc1, kc2), (SLOT_ICON_OFF, SLOT_ICON_OFF))
            name = f"slot{i}_{KEYS[i]}_job{job}_{k}"
            save_crop(img, (0, 0, SLOT_W, SLOT_H), "slots", name)
            slot_icon_files[(i, job)] = f"slots/{name}.png"
            files[f"slot{i}_job{job}"] = dict(path=f"slots/{name}.png",
                                              pos=[x - 3, y - 3], size=[SLOT_W, SLOT_H])

    # 4) 球底（描边底盘）+ 玻璃高光（透明底，叠在液面之上）
    for kind in ("hp", "mp"):
        o = ORB[kind]
        r = o["r"]
        orb_box = (o["cx"] - r - 7, o["cy"] - r - 7,
                   o["cx"] + r + 7 + 1, o["cy"] + r + 7 + 1)
        files[f"orb_{kind}"] = save_crop(draw_orb(kind), orb_box, "orbs", f"orb_{kind}_base")
        files[f"orb_{kind}_glass"] = save_crop(draw_orb_glass(kind), orb_box, "orbs",
                                               f"orb_{kind}_glass")

    # 5) 头像
    portrait_img, portrait_ok = draw_portrait()
    files["portrait"] = save_crop(portrait_img, (20, 574, 84 + 1, 638 + 1), "plate", "portrait_hero")

    # 6) 铭牌框
    plate_img = draw_nameplate()
    files["nameplate"] = save_crop(plate_img, (398, 28, 884 + 1, 56 + 1), "plate", "nameplate_frame")

    # 7) 小地图
    map_img = draw_room_map()
    files["room_map"] = save_crop(map_img, (1103, 25, 1211 + 1, 67 + 1), "plate", "room_map")

    # ---------------------------------------------------------- manifest
    slots = []
    for i, (kind, c1, c2) in enumerate(ICONS):
        x, y = slot_pos(i)
        variants = {str(job): slot_icon_files[(i, job)] for job in JOB_SLOT_ICONS}
        slots.append(dict(
            index=i, key=KEYS[i], kind=kind,
            rect=[x - 3, y - 3, x + 49, y + 49],
            frame_origin=[x - 3, y - 3],
            icon_pos=[x, y], icon_size=[SLOT_ICON, SLOT_ICON],
            key_pos=[x + 3, y + 1], key_size=14,
            # 冷却遮罩圆心 / 半径（照抄 draw_dynamic_ui 的 pieslice 外接框）
            cd_center=[x + 23, y + 23], cd_radius=31,
            cd_text_pos=[x + 23, y + 23], cd_text_size=16,
            icon_by_job=variants,
            consumable=(i >= 6),
        ))

    orbs = {}
    for kind in ("hp", "mp"):
        o = ORB[kind]
        orbs[kind] = dict(
            center=[o["cx"], o["cy"]], radius=o["r"],
            liquid_color=list(o["col"]), liquid_color_dark=list(o["col_d"]),
            # 绘制顺序（与 preview draw_orb 内部一致）：液面 → 描边底盘 → 玻璃高光
            base=files[f"orb_{kind}"]["path"],
            base_pos=files[f"orb_{kind}"]["pos"],
            base_size=files[f"orb_{kind}"]["size"],
            glass=files[f"orb_{kind}_glass"]["path"],
            glass_pos=files[f"orb_{kind}_glass"]["pos"],
            glass_size=files[f"orb_{kind}_glass"]["size"],
            value_pos=[o["cx"], o["cy"] + 4], value_size=18, value_anchor="center",
            value_color=[255, 255, 255, 255], value_stroke=2,
            value_stroke_color=[0, 0, 0, 255],
        )

    manifest = dict(
        version=1,
        generator="tools/bake_hud.py",
        art_source="tools/render_preview.py",
        canvas=[CANVAS_W, CANVAS_H],
        note=("preview 的 HUD 直接画在 1280x720（W*S, H*S）画布上，"
              "坐标即实机像素坐标，无需再乘 SCALE"),
        panel=dict(path=files["panel"]["path"], pos=files["panel"]["pos"],
                   size=files["panel"]["size"], top=PANEL_TOP),
        exp_bar=dict(path=files["exp_bar"]["path"], pos=files["exp_bar"]["pos"],
                     size=files["exp_bar"]["size"], rect=[EXP_X0, PANEL_TOP + 9, EXP_X1, PANEL_TOP + 14],
                     inner=[EXP_X0 + 1, PANEL_TOP + 10, EXP_X1 - 1, PANEL_TOP + 13], fraction=EXP_FRAC),
        slot_frames=dict(path=files["slot_frames"]["path"],
                         pos=files["slot_frames"]["pos"], size=files["slot_frames"]["size"]),
        slots=slots,
        orbs=orbs,
        portrait=dict(path=files["portrait"]["path"], pos=files["portrait"]["pos"],
                      size=files["portrait"]["size"], ok=portrait_ok),
        nameplate=dict(
            path=files["nameplate"]["path"], pos=files["nameplate"]["pos"],
            size=files["nameplate"]["size"],
            plate=[350, 30, 884, 60], icon_box=[354, 30, 392, 60], icon_center=[373, 46],
            bar=[398, 34, 882, 52], bar_inner=[400, 36, 880, 52],
            name_pos=[400, 32], name_size=16, name_anchor="bl",
            name_color=[255, 230, 200, 255], name_stroke=2, name_stroke_color=[0, 0, 0, 255],
            layer_pos=[890, 44], layer_size=22, layer_anchor="lm",
            layer_color=[255, 240, 200, 255], layer_stroke=2,
            layer_stroke_color=[0, 0, 0, 255],
        ),
        room_map=dict(path=files["room_map"]["path"], pos=files["room_map"]["pos"],
                      size=files["room_map"]["size"],
                      # 小地图格子的坐标系（hud.gd 据此点亮"当前房间"）
                      origin=[1100, 22], cell=26, cell_pad=3,
                      rooms=[[0, 1], [1, 1], [2, 1], [2, 0], [3, 0], [3, 1]],
                      current=5),
        # 分段血条参数（照抄 render_preview 的 LAYER_HP / LAYER_COLS）
        hp_layers=dict(layer_hp=RP.LAYER_HP, colors=[list(c) for c in RP.LAYER_COLS],
                       chip_color=[250, 240, 220, 255]),
        texts=STATIC_TEXTS,
        fonts=dict(num=["C:/Windows/Fonts/impact.ttf", "C:/Windows/Fonts/arialbd.ttf"],
                   cn=["C:/Windows/Fonts/msyhbd.ttc", "C:/Windows/Fonts/msyh.ttc",
                       "C:/Windows/Fonts/simhei.ttf"]),
        job_names=JOB_NAMES,
        files={k: v["path"] for k, v in files.items()},
    )

    with open(MANIFEST, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
    return manifest


def check(manifest):
    """校验 manifest 引用的贴图是否都在、尺寸是否与清单一致。"""
    bad = []
    refs = [("panel", manifest["panel"]), ("exp_bar", manifest["exp_bar"]),
            ("slot_frames", manifest["slot_frames"]), ("portrait", manifest["portrait"]),
            ("nameplate", manifest["nameplate"]), ("room_map", manifest["room_map"])]
    for kind, o in manifest["orbs"].items():
        refs.append((f"orb_{kind}", dict(path=o["base"], size=o["base_size"])))
        refs.append((f"orb_{kind}_glass", dict(path=o["glass"], size=o["glass_size"])))
    for s in manifest["slots"]:
        for job, p in s["icon_by_job"].items():
            refs.append((f"slot{s['index']}/job{job}", dict(path=p, size=None)))
    for name, o in refs:
        p = os.path.join(OUT, o["path"])
        if not os.path.exists(p):
            bad.append(f"{name}: 缺文件 {o['path']}")
            continue
        if o.get("size"):
            with Image.open(p) as im:
                if list(im.size) != list(o["size"]):
                    bad.append(f"{name}: 尺寸 {im.size} != manifest {o['size']}")
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只校验已有产物")
    args = ap.parse_args()

    if args.check:
        with open(MANIFEST, encoding="utf-8") as f:
            m = json.load(f)
    else:
        m = bake()

    bad = check(m)
    total = 0
    for group in ("panel", "slots", "orbs", "plate"):
        d = os.path.join(OUT, group)
        if os.path.isdir(d):
            for fn in sorted(os.listdir(d)):
                if fn.endswith(".png"):
                    total += 1
                    sz = os.path.getsize(os.path.join(d, fn))
                    print(f"[BAKE] {group}/{fn:26s} {sz:>8d} B")
    print(f"[BAKE] manifest -> {os.path.relpath(MANIFEST, PROJ)}  ({total} PNG, "
          f"canvas={m['canvas']}, slots={len(m['slots'])})")
    if bad:
        print("[BAKE][FAIL] " + "; ".join(bad))
        sys.exit(1)
    print("[BAKE] OK 全部贴图与 manifest 一致")


if __name__ == "__main__":
    main()
