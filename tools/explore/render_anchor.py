"""探索原型渲染入口（纯离线，不开窗口）。

  python tools/explore/render_anchor.py quick      # 关键帧速览（调姿用）
  python tools/explore/render_anchor.py guides     # E2：接触帧引导图组 + 转面
  python tools/explore/render_anchor.py weapons    # E3：三种武器同一动作 + 分层拆解 + 动图
输出到 temp/explore/。
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent))
import puppet as pp  # noqa: E402
import weapons as wp  # noqa: E402
from poses import CLIPS  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "temp" / "explore"
FONT_PATH = Path("C:/Windows/Fonts/msyh.ttc")


def font(size):
    try:
        return ImageFont.truetype(str(FONT_PATH), size)
    except OSError:
        return ImageFont.load_default()


_SPRITES = {}


def sprite(weapon):
    if weapon not in _SPRITES:
        _SPRITES[weapon] = wp.make_sprite(wp.WEAPONS[weapon])
    return _SPRITES[weapon]


def render_frame(keys, t, weapon="katana", view=None, coat=True, stamp=False):
    p = pp.sample(keys, t)
    j = pp.solve(p)
    view = view or pp.View(512, 320, 1.0, (224, 288))
    buf = pp.rasterize(view, pp.build_prims(j, coat=coat))
    body = pp.shade_pm(buf)
    front = back = None
    lm = {}
    if weapon:
        front, back, lm = wp.render_weapon(view, buf, sprite(weapon), j["blade"], stamp=stamp)
    return {"pose": p, "joints": j, "view": view, "buf": buf, "body": body, "front": front, "back": back,
            "lm": lm}


def composite(fr, bg=None):
    view = fr["view"]
    acc = np.zeros((view.h, view.w, 4), np.float32) if bg is None else bg.copy()
    if fr["back"] is not None:
        acc = pp.over(acc, fr["back"])
    acc = pp.over(acc, fr["body"])
    if fr["front"] is not None:
        acc = pp.over(acc, fr["front"])
    return acc


def flatten(rgba, bg=(70, 72, 82)):
    a = rgba[..., 3:4].astype(np.float32) / 255.0
    rgb = rgba[..., :3].astype(np.float32) * a + np.array(bg, np.float32) * (1 - a)
    return rgb.astype(np.uint8)


def ground_line(img, view, color=(110, 112, 124)):
    y = int(round(view.oy / view.ss))
    img[min(y, img.shape[0] - 1), :, :] = color
    return img


def label(img, text, size=16, pos=(6, 4), color=(235, 235, 240)):
    im = Image.fromarray(img)
    d = ImageDraw.Draw(im)
    d.text(pos, text, font=font(size), fill=color)
    return np.asarray(im)


def grid(tiles, cols, pad=4, bg=(30, 30, 36)):
    h = max(t.shape[0] for t in tiles)
    w = max(t.shape[1] for t in tiles)
    rows = math.ceil(len(tiles) / cols)
    out = np.full((rows * (h + pad) + pad, cols * (w + pad) + pad, 3), bg, np.uint8)
    for i, t in enumerate(tiles):
        r, c = divmod(i, cols)
        y, x = pad + r * (h + pad), pad + c * (w + pad)
        out[y:y + t.shape[0], x:x + t.shape[1]] = t[..., :3]
    return out


def save(img, name):
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / name
    Image.fromarray(img).save(path)
    print(f"[OK] {path.relative_to(ROOT)}")
    return path


def cmd_quick():
    keys, _ = CLIPS["attack1"]
    ticks = [0, 6, 8, 9, 10, 12, 20, 30]
    tiles = []
    for t in ticks:
        view = pp.View(400, 300, 1.25, (170, 280))
        fr = render_frame(keys, t, view=view)
        img = flatten(pp.downsample_pm(view, composite(fr)))
        img = ground_line(img.copy(), view)
        tiles.append(label(img, f"tick {t}"))
    save(grid(tiles, 4), "quick_attack1.png")


def openpose_image(view, j):
    out_w, out_h = view.out_w, view.out_h
    im = Image.new("RGB", (out_w, out_h), (0, 0, 0))
    d = ImageDraw.Draw(im)
    pts = [view.px(p) for p in pp.openpose_points(j)]
    lw = max(2, int(round(view.scale / view.ss * 2.2)))
    for k, (a, b) in enumerate(pp.OPENPOSE_PAIRS):
        d.line([tuple(pts[a]), tuple(pts[b])], fill=pp.OPENPOSE_COLORS[k % 18], width=lw)
    for k, p in enumerate(pts):
        r = lw
        d.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=pp.OPENPOSE_COLORS[k % 18])
    return np.asarray(im)


def guide_set(keys, t, weapon="katana", size=384, scale=1.6, origin=(150, 350)):
    view = pp.View(size, size, scale, origin)
    fr = render_frame(keys, t, weapon=weapon, view=view, stamp=True)
    buf = fr["buf"]
    color = flatten(pp.downsample_pm(view, composite(fr)), bg=(200, 200, 204))
    seg = pp.seg_image(buf)
    depth = np.repeat(pp.depth_image(buf)[..., None], 3, -1)
    nrm = pp.normal_image(buf)
    lines = np.repeat(pp.line_image(buf)[..., None], 3, -1)
    pose = openpose_image(view, fr["joints"])
    return fr, {"color": color, "seg": seg, "depth": depth, "normal": nrm, "lines": lines, "openpose": pose}


GUIDE_LABELS = {"color": "色块人偶（身份色）", "seg": "分件掩码（换装槽位）", "depth": "深度", "normal": "法线",
                "lines": "线稿", "openpose": "OpenPose 骨架"}


def cmd_guides():
    keys, _ = CLIPS["attack1"]
    tiles = []
    meta = {}
    for t in (6, 9, 12):
        fr, g = guide_set(keys, t)
        for k, img in g.items():
            tiles.append(label(img.copy(), f"t{t} {GUIDE_LABELS[k]}", 14, color=(250, 80, 80)))
            if t == 9:
                save(img, f"guide_t{t}_{k}.png")
        view = fr["view"]
        meta[f"t{t}"] = {k: [round(float(c), 2) for c in view.px(v)] for k, v in fr["lm"].items()}
    save(grid(tiles, 6), "e2_guides.png")
    (OUT / "e2_guides_landmarks.json").write_text(json.dumps(meta, ensure_ascii=False, indent=1), "utf-8")

    stand, _ = CLIPS["stand"]
    tiles = []
    names = [(-90, "正面"), (-45, "3/4 正"), (-25, "游戏机位"), (0, "侧面"), (45, "3/4 背"), (90, "背面")]
    for yaw, nm in names:
        view = pp.View(300, 420, 1.85, (150, 395), yaw=yaw, pitch=0.0 if yaw != -25 else 10.0)
        fr = render_frame(stand, 0, view=view)
        img = flatten(pp.downsample_pm(view, composite(fr)), bg=(214, 214, 218))
        img = img.copy()
        for h_cm, col in ((190, (200, 60, 60)), (162, (90, 90, 200)), (112, (90, 160, 90)), (52, (160, 120, 60)),
                          (0, (60, 60, 60))):
            y = int(round(view.oy / view.ss - h_cm * view.scale / view.ss))
            if 0 <= y < img.shape[0]:
                img[y, ::3] = col
        tiles.append(label(img, nm, 15, color=(30, 30, 40)))
    save(grid(tiles, 6), "e2_turnaround.png")


def trail_layer(view, keys, t, weapon, start=8.0, end=13.0, length=3.0):
    """刀光示意：按护手→刀尖连线扫掠成面（长度随武器参数自动变化）。"""
    im = Image.new("L", (view.out_w * 2, view.out_h * 2), 0)
    if t < start:
        return np.zeros((view.out_h, view.out_w), np.float32)
    d = ImageDraw.Draw(im)
    spec = wp.WEAPONS[weapon]
    bs, be = wp.blade_extent(spec)
    t_end = min(t, end)
    t0 = max(start, t_end - length)
    if t > end:
        fade = max(0.0, 1.0 - (t - end) / 3.0)
        t0 = max(start, end - length * fade)
    steps = np.arange(t0, t_end + 1e-6, 0.2)
    prev = None
    for k, s in enumerate(steps):
        j = pp.solve(pp.sample(keys, s))
        g, dvec, e, _ = j["blade"]
        a = view.px(g + dvec * (bs + (be - bs) * 0.35)) * 2
        b = view.px(g + dvec * be + e * -spec["sori"]) * 2
        if prev is not None:
            age = (k / max(len(steps) - 1, 1))
            d.polygon([tuple(prev[0]), tuple(prev[1]), tuple(b), tuple(a)], fill=int(40 + 180 * age))
        prev = (a, b)
    arr = np.asarray(im.resize((view.out_w, view.out_h), Image.BILINEAR), np.float32) / 255.0
    return arr


def weapon_tile(keys, t, weapon, view, with_trail=True, bg=(64, 66, 78)):
    fr = render_frame(keys, t, weapon=weapon, view=view)
    img = flatten(pp.downsample_pm(view, composite(fr)), bg=bg).astype(np.float32)
    if with_trail:
        tr = trail_layer(view, keys, t, weapon)
        img = img + tr[..., None] * np.array([150, 190, 255], np.float32) * 0.85
    img = ground_line(np.clip(img, 0, 255).astype(np.uint8), view)
    return img, fr


def cmd_weapons():
    keys, total = CLIPS["attack1"]
    ticks = [0, 6, 8, 9, 10, 12, 20]
    tiles = []
    for w in wp.WEAPONS:
        for t in ticks:
            view = pp.View(330, 270, 1.05, (120, 255))
            img, _ = weapon_tile(keys, t, w, view)
            tiles.append(label(img, f"{wp.WEAPONS[w]['label']}  tick {t}", 14))
    save(grid(tiles, len(ticks)), "e3_weapons_strip.png")

    tiles = []
    for w, t in (("katana", 12), ("greatsword", 20), ("shortsword", 6)):
        view = pp.View(330, 300, 1.1, (130, 285))
        fr = render_frame(keys, t, weapon=w, view=view)
        bgc = (205, 205, 210)
        layers = [("身后层", fr["back"]), ("身体层", fr["body"]), ("身前层", fr["front"])]
        for nm, pm in layers:
            tiles.append(label(flatten(pp.downsample_pm(view, pm), bg=bgc), f"{wp.WEAPONS[w]['label']} t{t} {nm}", 14,
                               color=(30, 30, 40)))
        tiles.append(label(flatten(pp.downsample_pm(view, composite(fr)), bg=bgc),
                           f"{wp.WEAPONS[w]['label']} t{t} 合成", 14, color=(30, 30, 40)))
    save(grid(tiles, 4), "e3_layers.png")

    sheet = []
    for w in wp.WEAPONS:
        sp = sprite(w)
        rgb = sp["rgb"] * sp["alpha"][..., None] + np.array([0.82, 0.82, 0.85]) * (1 - sp["alpha"][..., None])
        sheet.append((rgb * 255).astype(np.uint8))
    wmax = max(s.shape[1] for s in sheet)
    rows = [np.pad(s, ((4, 4), (0, wmax - s.shape[1]), (0, 0)), constant_values=40) for s in sheet]
    save(np.concatenate(rows, 0), "e3_weapon_sprites.png")

    frames = []
    for t in range(total + 6):
        row = []
        for w in wp.WEAPONS:
            view = pp.View(360, 280, 1.05, (130, 262))
            img, _ = weapon_tile(keys, min(t, total), w, view)
            row.append(label(img, f"{wp.WEAPONS[w]['label']}  tick {min(t, total)}", 14))
        frames.append(np.concatenate(row, 1))
    write_anim(frames, "e3_attack1_weapons")


def write_anim(frames, stem):
    import imageio.v2 as imageio
    OUT.mkdir(parents=True, exist_ok=True)
    mp4 = OUT / f"{stem}_60fps.mp4"
    with imageio.get_writer(mp4, fps=60, codec="libx264", quality=8, macro_block_size=1) as wr:
        for f in frames:
            wr.append_data(f)
    imageio.mimsave(OUT / f"{stem}_realtime.gif", frames[::2], duration=1000 / 30, loop=0)
    imageio.mimsave(OUT / f"{stem}_slow.gif", frames, duration=50, loop=0)
    print(f"[OK] {mp4.relative_to(ROOT)} (+ realtime/slow gif)")


def cmd_probe_inputs():
    """E1 云端探针的输入图：人偶色块（1024x768）与"标杆立绘 + 人偶"拼图。"""
    keys, _ = CLIPS["attack1"]
    bg = (226, 226, 230)
    for t, root_x in ((9, 300), (6, 520)):
        view = pp.View(1024, 768, 3.5, (root_x, 735))
        fr = render_frame(keys, t, view=view)
        save(flatten(pp.downsample_pm(view, composite(fr)), bg=bg), f"probe_pose_t{t}.png")
    hero = Image.open(ROOT / 'art/concepts/characters/players/swordsman/legacy/hero_cool.png').convert("RGB").crop((232, 0, 792, 1024))
    canvas = Image.new("RGB", (1024, 768), bg)
    hs = 760 / hero.height
    hero_s = hero.resize((int(hero.width * hs), 760), Image.LANCZOS)
    canvas.paste(hero_s, (4, 4))
    view = pp.View(600, 768, 3.3, (120, 740))
    fr = render_frame(keys, 9, view=view)
    pose = flatten(pp.downsample_pm(view, composite(fr)), bg=bg)
    canvas.paste(Image.fromarray(pose), (424, 0))
    save(np.asarray(canvas), "probe_combo_t9.png")


HERO3D = OUT / "cloud" / "hero3d" / "obj"


def load_hero3d(face_axis="+z"):
    import mesh3d as m3
    objs = list(HERO3D.glob("*.obj"))
    V, VT, F, FT = m3.load_obj(objs[0])
    V = m3.normalize(V, face_axis=face_axis)
    tex = m3.Tex(next(HERO3D.glob("*.png")))
    return m3, V, VT, F, FT, tex


def cmd_mesh_turnaround():
    face_axis = sys.argv[2] if len(sys.argv) > 2 else "+z"
    m3, V, VT, F, FT, tex = load_hero3d(face_axis)
    print("bounds", V.min(0).round(1), V.max(0).round(1))
    tiles = []
    names = [(-90, "正面"), (-45, "3/4 正"), (-25, "游戏机位"), (0, "侧面"), (45, "3/4 背"), (90, "背面")]
    for yaw, nm in names:
        view = pp.View(300, 420, 1.85, (150, 395), yaw=yaw, pitch=0.0 if yaw != -25 else 10.0)
        pm, _ = m3.shade_mesh(view, V, F, VT, FT, tex)
        img = flatten(pp.downsample_pm(view, pm), bg=(214, 214, 218))
        tiles.append(label(img.copy(), nm, 15, color=(30, 30, 40)))
    save(grid(tiles, 6), "e4_mesh_turnaround.png")


def skeleton_overlay(img, view, j, color=(0, 220, 255)):
    import mesh3d as m3
    im = Image.fromarray(img)
    d = ImageDraw.Draw(im)
    for a, b in m3.BONES:
        pa, pb = view.px(j[a]), view.px(j[b])
        d.line([tuple(pa), tuple(pb)], fill=color, width=2)
    for k in ("grip_r", "grip_l", "el_r", "el_l", "knee_r", "knee_l", "sh_r", "sh_l", "head"):
        p = view.px(j[k])
        d.ellipse([p[0] - 3, p[1] - 3, p[0] + 3, p[1] + 3], fill=(255, 60, 60))
    return np.asarray(im)


def cm_grid(img, view, axis_label):
    im = Image.fromarray(img)
    d = ImageDraw.Draw(im)
    s = view.scale / view.ss
    ox, oy = view.ox / view.ss, view.oy / view.ss
    for c in range(-100, 201, 10):
        x = ox + c * s
        y = oy - c * s
        if 0 <= x < img.shape[1]:
            d.line([(x, 0), (x, img.shape[0])], fill=(150, 150, 160) if c % 50 else (90, 90, 200), width=1)
            if c % 50 == 0:
                d.text((x + 2, 2), f"{axis_label}{c}", font=font(11), fill=(40, 40, 160))
        if 0 <= y < img.shape[0] and c >= 0:
            d.line([(0, y), (img.shape[1], y)], fill=(150, 150, 160) if c % 50 else (90, 90, 200), width=1)
            if c % 50 == 0:
                d.text((2, y - 13), f"y{c}", font=font(11), fill=(40, 40, 160))
    return np.asarray(im)


def cmd_mesh_fit():
    from poses import MESH_REST
    m3, V, VT, F, FT, tex = load_hero3d()
    j = pp.solve(pp.sample(MESH_REST, 0))
    sel, c, d, t = m3.find_sword(V)
    print("sword verts", int(sel.sum()), "center", c.round(1), "dir", d.round(3),
          "t range", float(t[sel].min()), float(t[sel].max()))
    tiles = []
    for yaw, lab in ((-90, "-z"), (0, "x")):
        view = pp.View(520, 640, 3.2, (260, 615), yaw=yaw, pitch=0.0)
        pm, _ = m3.shade_mesh(view, V, F, VT, FT, tex)
        img = flatten(pp.downsample_pm(view, pm), bg=(224, 224, 228))
        img = cm_grid(img, view, lab)
        img = skeleton_overlay(img, view, j)
        im = Image.fromarray(img)
        dr = ImageDraw.Draw(im)
        for p in V[sel][::7]:
            q = view.px(p)
            dr.point((q[0], q[1]), fill=(255, 0, 255))
        tiles.append(np.asarray(im))
    save(grid(tiles, 2), "e4_mesh_fit.png")


def mesh_rig():
    from poses import MESH_REST
    m3, V, VT, F, FT, tex = load_hero3d()
    j_rest = pp.solve(pp.sample(MESH_REST, 0))
    sel, c, d, t = m3.find_sword(V)
    idx, w = m3.skin_weights(V, j_rest)
    idx, w = m3.rigid_override(idx, w, sel, 5)
    return m3, V, VT, F, FT, tex, j_rest, idx, w


def mesh_weapon_tile(rig, keys, t, weapon, view, bg=(64, 66, 78), trail=True):
    from types import SimpleNamespace
    m3, V, VT, F, FT, tex, j_rest, idx, w, rest_fr, F_body = rig
    j = pp.solve(pp.sample(keys, t))
    Vp = m3.pose_mesh(V, idx, w, rest_fr, m3.bone_frames(j))
    body, zb = m3.shade_mesh(view, Vp, F_body, VT, FT, tex)
    acc = np.zeros_like(body)
    if weapon:
        front, back, _ = wp.render_weapon(view, SimpleNamespace(z=zb), sprite(weapon), j["blade"])
        acc = pp.over(pp.over(pp.over(acc, back), body), front)
    else:
        acc = body
    img = flatten(pp.downsample_pm(view, acc), bg=bg).astype(np.float32)
    if weapon and trail:
        img = img + trail_layer(view, keys, t, weapon)[..., None] * np.array([150, 190, 255], np.float32) * 0.85
    return np.clip(img, 0, 255).astype(np.uint8)


def mesh_rig_full():
    m3, V, VT, F, FT, tex, j_rest, idx, w = mesh_rig()
    keep, removed = m3.strip_weapon(V, F, VT, FT, tex, j_rest["grip_r"])
    print("stripped verts", int(removed.sum()), "faces kept", int(keep.sum()), "/", len(F))
    return m3, V, VT, F[keep], FT[keep], tex, j_rest, idx, w, m3.bone_frames(j_rest), F[keep]


def cmd_mesh_weapons():
    rig = mesh_rig_full()
    m3, V, VT, F, FT, tex = rig[0], rig[1], rig[2], rig[3], rig[4], rig[5]
    chk = []
    for yaw in (-90, 0):
        view = pp.View(420, 520, 2.6, (210, 500), yaw=yaw, pitch=0.0)
        pm, _ = m3.shade_mesh(view, V, rig[-1], VT, FT, tex)
        chk.append(flatten(pp.downsample_pm(view, pm), bg=(224, 224, 228)))
    save(grid(chk, 2), "e4_strip_check.png")
    if len(sys.argv) > 2 and sys.argv[2] == "check":
        return
    keys, total = CLIPS["attack1"]
    ticks = [0, 6, 8, 9, 12, 20]
    tiles = []
    for wname in wp.WEAPONS:
        for t in ticks:
            view = pp.View(330, 270, 1.05, (120, 255))
            img = ground_line(mesh_weapon_tile(rig, keys, t, wname, view).copy(), view)
            tiles.append(label(img, f"3D+{wp.WEAPONS[wname]['label']}  tick {t}", 14))
    save(grid(tiles, len(ticks)), "e4_mesh_weapons_strip.png")
    big = []
    for wname, t in (("katana", 6), ("katana", 9), ("greatsword", 12)):
        view = pp.View(600, 460, 2.2, (230, 440))
        big.append(label(mesh_weapon_tile(rig, keys, t, wname, view, bg=(200, 200, 205), trail=False),
                         f"{wp.WEAPONS[wname]['label']} tick {t}（2.2 倍）", 15, color=(30, 30, 40)))
    save(grid(big, 3), "e4_mesh_weapons_big.png")
    frames = []
    for t in range(total + 6):
        row = []
        for wname in wp.WEAPONS:
            view = pp.View(360, 280, 1.05, (130, 262))
            img = ground_line(mesh_weapon_tile(rig, keys, min(t, total), wname, view).copy(), view)
            row.append(label(img, f"3D+{wp.WEAPONS[wname]['label']}  tick {min(t, total)}", 14))
        frames.append(np.concatenate(row, 1))
    write_anim(frames, "e4_attack1_mesh_weapons")


def cmd_mesh_pose():
    m3, V, VT, F, FT, tex, j_rest, idx, w = mesh_rig()
    rest_fr = m3.bone_frames(j_rest)
    keys, total = CLIPS["attack1"]
    ticks = [0, 6, 8, 9, 12, 20]
    rows = []
    for t in ticks:
        j = pp.solve(pp.sample(keys, t))
        Vp = m3.pose_mesh(V, idx, w, rest_fr, m3.bone_frames(j))
        view = pp.View(330, 270, 1.05, (120, 255))
        pm, _ = m3.shade_mesh(view, Vp, F, VT, FT, tex)
        img = ground_line(flatten(pp.downsample_pm(view, pm), bg=(64, 66, 78)).copy(), view)
        pup = render_frame(keys, t, view=pp.View(330, 270, 1.05, (120, 255)))
        pimg = ground_line(flatten(pp.downsample_pm(pup["view"], composite(pup)), bg=(64, 66, 78)).copy(),
                           pup["view"])
        rows.append((label(pimg, f"人偶 tick {t}", 14), label(img, f"3D 模型蒙皮 tick {t}", 14)))
    tiles = [r[0] for r in rows] + [r[1] for r in rows]
    save(grid(tiles, len(ticks)), "e4_mesh_pose.png")
    big = []
    for t in (6, 9, 12):
        j = pp.solve(pp.sample(keys, t))
        Vp = m3.pose_mesh(V, idx, w, rest_fr, m3.bone_frames(j))
        view = pp.View(560, 460, 2.2, (200, 440))
        pm, _ = m3.shade_mesh(view, Vp, F, VT, FT, tex)
        big.append(label(flatten(pp.downsample_pm(view, pm), bg=(200, 200, 205)), f"tick {t}（2.2 倍）", 15,
                         color=(30, 30, 40)))
    save(grid(big, 3), "e4_mesh_pose_big.png")


REVIEW = ROOT / "docs" / "previews" / "explore_anchor"
REVIEW_FILES = [
    "e1_cloud_probe.png", "e2_guides.png", "e2_turnaround.png", "e3_weapons_strip.png", "e3_layers.png",
    "e3_weapon_sprites.png", "e3_attack1_weapons_realtime.gif", "e3_attack1_weapons_60fps.mp4",
    "e4_mesh_turnaround.png", "e4_strip_check.png", "e4_mesh_pose.png", "e4_mesh_weapons_strip.png",
    "e4_mesh_weapons_big.png", "e4_attack1_mesh_weapons_realtime.gif", "e4_attack1_mesh_weapons_60fps.mp4",
]


def fit_h(img, h):
    im = Image.fromarray(img) if isinstance(img, np.ndarray) else img
    im = im.convert("RGB")
    return np.asarray(im.resize((int(im.width * h / im.height), h), Image.LANCZOS))


def cmd_review():
    import shutil
    cloud = OUT / "cloud"
    rows = []
    for src, res, cap in ((ROOT / 'art/concepts/characters/players/swordsman/legacy/hero_cool.png', "p1_identity",
                           "P1 参考图=标杆立绘：要求保持身份改画侧身站姿"),
                          (OUT / "probe_pose_t9.png", "p2_pose_t9", "P2 参考图=人偶色块：要求按姿势重绘")):
        log = json.loads((cloud / f"{res}.json").read_text("utf-8"))
        a = fit_h(np.asarray(Image.open(src).convert("RGB")), 360)
        b = fit_h(np.asarray(Image.open(cloud / log["files"][0]).convert("RGB")), 360)
        pad = np.full((360, 12, 3), 30, np.uint8)
        row = np.concatenate([a, pad, b], 1)
        bar = np.full((64, row.shape[1], 3), 30, np.uint8)
        rp = (log.get("revised_prompt") or [""])[0]
        bar = label(bar, cap + "（左输入 / 右输出）", 15, (6, 4))
        bar = label(bar, "服务端强制改写后的提示词：" + rp[:58] + "…", 13, (6, 34), color=(255, 170, 120))
        rows.append(np.concatenate([bar, row], 0))
    w = max(r.shape[1] for r in rows)
    rows = [np.pad(r, ((0, 8), (0, w - r.shape[1]), (0, 0)), constant_values=30) for r in rows]
    save(np.concatenate(rows, 0), "e1_cloud_probe.png")
    REVIEW.mkdir(parents=True, exist_ok=True)
    for name in REVIEW_FILES:
        shutil.copy2(OUT / name, REVIEW / name)
    print(f"[OK] {len(REVIEW_FILES)} files -> {REVIEW.relative_to(ROOT)}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "quick"
    if cmd == "review":
        cmd_review()
        sys.exit(0)
    if cmd in ("mesh_fit", "mesh_pose", "mesh_weapons"):
        {"mesh_fit": cmd_mesh_fit, "mesh_pose": cmd_mesh_pose, "mesh_weapons": cmd_mesh_weapons}[cmd]()
        sys.exit(0)
    {"quick": cmd_quick, "guides": cmd_guides, "weapons": cmd_weapons, "probe_inputs": cmd_probe_inputs,
     "mesh_turnaround": cmd_mesh_turnaround}[cmd]()
