"""Generate data-only pose guides for standard_v1 action source candidates.

This is a planning aid, not final character art or a runtime animation export.
Reuses the explore puppet's body proportions, IK solver, and orthographic view.
Run: python tools/explore/standard_actions_guides.py [walk run jump attack1]
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

import puppet as pp
from poses import ATTACK1

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "art/animations/players/swordsman/v7/sources/guides"
CELL = (512, 512)
SCALE = 1.52
ORIGIN = (235, 452)
BG = (247, 247, 243)
NEAR = (208, 58, 63)
FAR = (61, 109, 199)
CORE = (58, 68, 80)
WEAPON = (13, 139, 143)


def font(size: int):
    for path in ("C:/Windows/Fonts/arial.ttf", "C:/Windows/Fonts/msyh.ttc"):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            pass
    return ImageFont.load_default()


def base_pose(**fields):
    p = dict(pp.DEFAULT_POSE, pelvis_h=90.0, pelvis_lean=4.0,
             chest_lean=2.0, head_lean=-3.0)
    p.update(fields)
    return p


def walk_poses():
    # Contact / down / passing / up, then the opposite leg. y is height.
    feet = [(28, 0), (12, 0), (-6, 0), (-26, 0),
            (-28, 2), (-10, 19), (12, 13), (26, 4)]
    labels = ["R contact", "R down", "R passing", "R heel rise",
              "L contact", "L down", "L passing", "L heel rise"]
    out = []
    for i, label in enumerate(labels):
        phase = i * math.pi / 4
        r, l = feet[i], feet[(i + 4) % 8]
        p = base_pose()
        p.update(pelvis_h=[90, 87, 91, 93, 90, 87, 91, 93][i],
                 pelvis_yaw=5 * math.cos(phase), chest_yaw=-9 * math.cos(phase),
                 hand_r=(12 - 10 * math.cos(phase), 89 + 2 * math.sin(phase), 26),
                 hand_l=(5 + 22 * math.cos(phase), 91 + 3 * math.sin(phase), -25),
                 foot_r=(r[0], r[1], 11), foot_l=(l[0], l[1], -11),
                 blade_dir=(-0.92, -0.34, 0.12), blade_edge=(0, -1, 0))
        out.append((label, p, {"phase_fraction": i / 8, "start_tick": i * 5, "duration_ticks": 5}))
    return out


def run_poses():
    feet = [(43, 0), (16, 0), (-22, 4), (-38, 28),
            (-30, 46), (-3, 43), (27, 25), (43, 10)]
    labels = ["R contact", "R compression", "R push off", "R flight / L reach",
              "L contact", "L compression", "L push off", "L flight / R reach"]
    out = []
    for i, label in enumerate(labels):
        phase = i * math.pi / 4
        r, l = feet[i], feet[(i + 4) % 8]
        p = base_pose()
        p.update(pelvis_h=[82, 77, 87, 95, 82, 77, 87, 95][i],
                 pelvis_lean=15, chest_lean=7, head_lean=-14,
                 pelvis_yaw=8 * math.cos(phase), chest_yaw=-14 * math.cos(phase),
                 hand_r=(25 - 19 * math.cos(phase), 102 + 9 * math.cos(phase), 29),
                 hand_l=(28 + 36 * math.cos(phase), 103 - 10 * math.cos(phase), -23),
                 foot_r=(r[0], r[1], 11), foot_l=(l[0], l[1], -11),
                 blade_dir=(-0.98, -0.11, 0.12), blade_edge=(0, -1, 0))
        out.append((label, p, {"phase_fraction": i / 8, "start_tick": i * 3, "duration_ticks": 3}))
    return out


def jump_poses():
    # Root is the same virtual-ground origin throughout. Height is never
    # normalized from per-pose foot minima. Airborne feet retain their height.
    raw = [
        ("anticipation crouch", 70, 0, (-12, 0), (20, 0), (15, 94, 28), (-10, 96, -25)),
        ("push off", 96, 10, (-19, 6), (14, 10), (34, 119, 28), (44, 123, -22)),
        ("ascending", 122, 48, (-17, 40), (27, 57), (26, 143, 28), (24, 150, -24)),
        ("near apex", 145, 83, (-21, 79), (27, 91), (21, 155, 28), (10, 156, -26)),
        ("descending", 128, 52, (-21, 45), (25, 53), (23, 141, 28), (11, 139, -26)),
        ("landing contact", 88, 0, (-16, 3), (21, 0), (30, 100, 28), (28, 102, -26)),
        ("landing compression", 67, 0, (-15, 0), (23, 0), (29, 88, 28), (37, 90, -26)),
        ("recover to stand", 90, 0, (-10, 0), (15, 0), (13, 91, 28), (5, 91, -26)),
    ]
    out = []
    for i, (label, pelvis_h, root_h, fr, fl, hr, hl) in enumerate(raw):
        p = base_pose()
        p.update(pelvis_h=pelvis_h, pelvis_lean=([16, 8, 8, 5, 8, 10, 18, 4][i]),
                 chest_lean=5, head_lean=-8,
                 hand_r=hr, hand_l=hl, foot_r=(*fr, 11), foot_l=(*fl, -11),
                 blade_dir=(-0.87, -0.48, 0.10), blade_edge=(0, -1, 0))
        out.append((label, p, {"phase_index": i, "duration_ticks": [6, 3, 6, 5, 6, 2, 5, 5][i],
                               "visual_root_height_cm": root_h,
                               "physics_timing": "design suggestion; runtime jump uses state transitions"}))
    return out


def attack_poses():
    ticks = [0, 6, 8, 9, 10, 12, 20, 30]
    labels = ["ready", "hip / shoulder windup", "release", "horizontal contact",
              "rotation follow through", "settle weight", "recover blade", "return guard"]
    return [(label, pp.sample(ATTACK1, t), {"sample_tick": t,
             "timing_reference": "V6 30 ticks; [8,12) active; contact reference tick 9"})
            for t, label in zip(ticks, labels)]


def xy(p):
    return [round(float(v), 3) for v in p]


def draw_board(name: str, poses):
    OUT.mkdir(parents=True, exist_ok=True)
    board = Image.new("RGB", (CELL[0] * 4, CELL[1] * 2), BG)
    draw = ImageDraw.Draw(board)
    view = pp.View(*CELL, SCALE, ORIGIN, yaw=-25, pitch=6, ss=1)
    frames = []
    for i, (label, pose, detail) in enumerate(poses):
        col, row = i % 4, i // 4
        offset = np.array([col * CELL[0], row * CELL[1]])
        j = pp.solve(pose)
        points = {k: view.px(v) for k, v in j.items() if isinstance(v, np.ndarray) and v.shape == (3,)}
        grip, direction, edge, _ = j["blade"]
        points.update(root=view.px((pose["root_x"], 0, 0)),
                      grip=view.px(grip), guard=view.px(grip + direction * 5.5),
                      tip=view.px(grip + direction * 96.7 - edge * 2.4),
                      pommel=view.px(grip - direction * 20))
        def pt(key):
            return tuple(points[key] + offset)
        x0, y0 = map(int, offset)
        draw.rectangle((x0, y0, x0 + 511, y0 + 511), outline=(198, 201, 203), width=2)
        draw.text((x0 + 16, y0 + 12), f"{name.upper()}  {i + 1:02d} / 08", font=font(22), fill=CORE)
        draw.text((x0 + 16, y0 + 41), label, font=font(17), fill=CORE)
        ground = y0 + ORIGIN[1]
        draw.line((x0 + 18, ground, x0 + 493, ground), fill=(186, 190, 191), width=2)
        draw.text((x0 + 17, ground + 8), "virtual ground / fixed root", font=font(13), fill=(126, 130, 135))
        # Far side first; near right arm / leg stay distinguishable.
        for side, color in (("l", FAR), ("r", NEAR)):
            for chain in (("sh_", "el_", "grip_"), ("hip_", "knee_", "ankle_")):
                draw.line([pt(k + side) for k in chain], fill=color, width=6)
            draw.line([pt("heel_" + side), pt("toe_" + side)], fill=color, width=7)
            for prefix in ("sh_", "el_", "grip_", "hip_", "knee_", "ankle_"):
                x, y = pt(prefix + side)
                draw.ellipse((x - 5, y - 5, x + 5, y + 5), fill=BG, outline=color, width=3)
        for chain in (("hip_l", "pelvis", "hip_r"), ("pelvis", "waist", "chest", "neck_base", "head"),
                      ("sh_l", "chest", "sh_r")):
            draw.line([pt(k) for k in chain], fill=CORE, width=5)
        hx, hy = pt("head")
        draw.ellipse((hx - 13, hy - 17, hx + 13, hy + 17), outline=CORE, width=4)
        draw.line((hx + 12, hy - 2, hx + 21, hy + 3, hx + 12, hy + 7), fill=CORE, width=3)
        draw.line([pt("pommel"), pt("grip"), pt("guard"), pt("tip")], fill=WEAPON, width=5)
        for key, color in (("root", (111, 112, 114)), ("grip", (205, 142, 10)),
                           ("guard", (57, 151, 60)), ("tip", (13, 139, 143))):
            x, y = pt(key)
            r = 6 if key != "root" else 7
            draw.ellipse((x-r, y-r, x+r, y+r), outline=color, width=3)
        # No finger/hand contour is implied: the circle is a joint marker only.
        draw.text((x0 + 17, y0 + 490), "RED = near R / sword   BLUE = far L", font=font(13), fill=CORE)
        bounds = np.array(list(points.values()))
        if bounds.min(axis=0)[0] < 8 or bounds.max(axis=0)[0] > 504 or bounds.min(axis=0)[1] < 65 or bounds.max(axis=0)[1] > 485:
            raise ValueError(f"{name} frame {i}: guide landmark outside safe area: {bounds.min(axis=0)} {bounds.max(axis=0)}")
        frames.append({"index": i, "label": label, "cell_bbox_xyxy": [x0, y0, x0+512, y0+512],
                       "root": xy(points["root"] + offset), "grip": xy(points["grip"] + offset),
                       "guard": xy(points["guard"] + offset), "tip": xy(points["tip"] + offset),
                       "joints_cell_px": {k: xy(v) for k, v in points.items()},
                       "joints_sheet_px": {k: xy(v + offset) for k, v in points.items()},
                       "pose_cm": {k: xy(v) if hasattr(v, "__len__") else v for k, v in pose.items()},
                       **detail})
    metadata = {"schema": "standard_action_pose_guides.v1", "purpose": "pose planning only; not final art",
                "action": name, "sheet_size": list(board.size), "grid": [4, 2], "reading_order": "row major",
                "coordinates": "px, x right, y down; bbox max exclusive",
                "body_space": "cm; x facing right, y up, z character right / near camera",
                "camera": {"yaw": -25, "pitch": 6, "scale_px_per_cm": SCALE},
                "source_identity": "standard_v1; no character appearance generated by this script",
                "handedness": "right hand, near camera, single katana grip; left hand balances freely",
                "loop": name in ("walk", "run"), "fps_reference": 60,
                "total_duration_ticks": {"walk": 40, "run": 24, "attack1": 30}.get(name),
                "root_contract": "fixed virtual ground origin; airborne feet are not normalized to ground",
                "limitations": ["Guide proportions use explore puppet BODY; final identity uses approved standard art.",
                                "No fingers, cloth, silhouette, shading, collision, or final weapon layer design.",
                                "Eight poses are source planning; transition interpolation and runtime timing require review."],
                "frames": frames}
    png = OUT / f"{name}_guide.png"
    js = OUT / f"{name}_guide.json"
    board.save(png)
    js.write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
    print(png.relative_to(ROOT))
    print(js.relative_to(ROOT))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("actions", nargs="*", choices=("walk", "run", "jump", "attack1"))
    args = parser.parse_args()
    builders = {"walk": walk_poses, "run": run_poses, "jump": jump_poses, "attack1": attack_poses}
    for action in args.actions or builders:
        draw_board(action, builders[action]())


if __name__ == "__main__":
    main()
