#!/usr/bin/env python3
"""Bake the generated transparent demo atlases into Godot animation strips.

Requires Pillow and NumPy. No network or image-generation dependencies.
Run from any directory: python tools/bake_demo_art.py
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
SHEETS = ROOT / 'art/animations/shared/demo_v2/sources'
OUT = ROOT / "game" / "assets" / "demo"

# Reviewed source-space floor/root landmarks. These belong to the 16 logical
# grid cells, NOT to each pose's weapon-inclusive alpha bounding box.
# One scale per character avoids attacks changing size as the blade rotates.
GROUPS = {
    "player": {
        "target_body_h": 190,
        "standing_body_h": 307,
        "anchors": [(145, 320), (480, 320), (779, 320), (1122, 311),
                    (190, 600), (490, 609), (810, 598), (1127, 610),
                    (169, 925), (475, 916), (773, 932), (1110, 932),
                    (145, 1212), (454, 1223), (790, 1226), (1119, 1213)],
        "pose_names": ["ready", "ready_breathe", "guard", "crouch",
                       "run_contact_a", "run_pass_a", "run_contact_b", "run_pass_b",
                       "attack_windup", "horizontal_slash", "rising_cut", "heavy_cut",
                       "airborne", "hit_recoil", "knocked_down", "kneeling_getup"],
        "actions": {
            "idle": ([0, 1], [24, 24], True, "two distinct breathing keyframes"),
            "run": ([4, 5, 6, 7], [6, 5, 6, 5], True, "four distinct stride keyframes"),
            "attack1": ([8, 9, 1], [6, 4, 10], False, "horizontal cut and recovery"),
            "attack2": ([8, 10, 2, 1], [5, 4, 6, 6], False, "rising cut and guarded recovery"),
            "attack3": ([8, 11, 9, 1], [8, 5, 8, 10], False, "heavy cut and low follow-through"),
            "upper": ([3, 10, 12, 1], [5, 3, 6, 6], False, "crouch, rising cut, airborne, recovery"),
            "jump": ([3, 12], [5, 12], False, "takeoff crouch and airborne keyframe"),
            "air": ([12], [12], True, "held airborne pose; motion provided by game physics"),
            "back_dash": ([3, 12, 3, 1], [3, 8, 3, 4], False, "reuse crouch and airborne poses; game provides travel"),
            "guard": ([2], [12], True, "held guard pose"),
            "hit": ([13, 3, 1], [7, 4, 5], False, "recoil, regain balance, recovery"),
            "down": ([13, 14], [5, 24], False, "recoil and grounded knocked-down keyframe"),
            "getup": ([14, 15, 3, 1], [4, 7, 4, 5], False, "down, kneel, crouch, stand"),
            "blood_rage": ([2, 8, 2, 1], [6, 4, 4, 6], False, "core guard/windup reuse; buff aura supplied by game"),
            "quick_draw": ([8, 9, 11, 1], [18, 6, 7, 7], False, "windup and horizontal-cut reuse; wide FX supplied by game"),
            "rage_slash": ([8, 10, 8, 11, 1], [6, 3, 5, 3, 21], False, "two distinct cuts; reused windup/recovery"),
            "thrust": ([8, 9, 8, 9, 8, 9, 1], [4, 2, 4, 2, 4, 2, 16], False, "three pulses reuse horizontal extension; dedicated thrust poses deferred"),
        },
    },
    "monster": {
        "target_body_h": 132,
        "standing_body_h": 245,
        "anchors": [(190, 320), (510, 320), (795, 320), (1110, 320),
                    (213, 608), (509, 590), (806, 611), (1106, 609),
                    (201, 941), (499, 939), (761, 932), (1080, 937),
                    (211, 1220), (505, 1187), (801, 1220), (1111, 1218)],
        "pose_names": ["ready", "ready_breathe", "alert", "crouch",
                       "run_contact_a", "run_pass_a", "run_contact_b", "run_pass_b",
                       "attack_windup", "attack_overhead", "club_smash", "club_followthrough",
                       "hit_recoil", "airborne_knockback", "knocked_down", "kneeling_getup"],
        "actions": {
            "idle": ([0, 1], [25, 25], True, "two distinct ready keyframes"),
            "patrol": ([4, 5, 6, 7], [9, 7, 9, 7], True, "four stride poses; slower playback"),
            "chase": ([4, 5, 6, 7], [6, 5, 6, 5], True, "four distinct stride keyframes"),
            "attack": ([8, 9, 10, 11, 0], [6, 6, 4, 6, 4], False, "windup, overhead, smash, follow-through, recover"),
            "hit": ([12, 3, 0], [7, 3, 4], False, "recoil and recovery"),
            "air": ([13], [10], True, "held airborne knockback; motion supplied by physics"),
            "down": ([13, 14], [5, 30], False, "fall and grounded knocked-down keyframe"),
            "getup": ([14, 15, 3, 0], [3, 4, 3, 2], False, "down, kneel, crouch, stand"),
        },
    },
}


def components(mask: np.ndarray) -> tuple[np.ndarray, list[dict]]:
    """Deterministic 8-connected scanline labeling without SciPy.

    Whole connected weapons are retained even if generation puts their tips in
    a neighboring grid cell. The regular 4x4 grid determines pose ownership;
    grid boundaries never sever a sword or club.
    """
    parent = [0]
    runs: list[tuple[int, int, int, int]] = []
    previous: list[tuple[int, int, int]] = []

    def find(n: int) -> int:
        while parent[n] != n:
            parent[n] = parent[parent[n]]
            n = parent[n]
        return n

    for y, row in enumerate(mask):
        edge = np.diff(np.r_[False, row, False].astype(np.int8))
        starts = np.flatnonzero(edge == 1)
        stops = np.flatnonzero(edge == -1)
        current = []
        cursor = 0
        for x0, x1 in zip(starts, stops):
            while cursor < len(previous) and previous[cursor][1] < x0:
                cursor += 1
            labels = []
            j = cursor
            while j < len(previous) and previous[j][0] <= x1:
                labels.append(find(previous[j][2]))
                j += 1
            if labels:
                label = min(labels)
                for n in labels:
                    parent[n] = label
            else:
                label = len(parent)
                parent.append(label)
            current.append((int(x0), int(x1), label))
            runs.append((y, int(x0), int(x1), label))
        previous = current

    labels = np.zeros(mask.shape, dtype=np.int32)
    stats: dict[int, dict] = {}
    for y, x0, x1, label in runs:
        label = find(label)
        labels[y, x0:x1] = label
        st = stats.setdefault(label, dict(label=label, area=0, x0=x0, y0=y,
                                          x1=x1, y1=y + 1, sx=0, sy=0))
        n = x1 - x0
        st["area"] += n
        st["x0"] = min(st["x0"], x0)
        st["x1"] = max(st["x1"], x1)
        st["y1"] = max(st["y1"], y + 1)
        st["sx"] += (x0 + x1 - 1) * n / 2
        st["sy"] += y * n
    return labels, sorted(stats.values(), key=lambda st: -st["area"])


def inspect(path: Path) -> None:
    image = Image.open(path).convert("RGBA")
    _, stats = components(np.array(image)[..., 3] >= 24)
    print(path.name, image.size)
    for st in stats:
        if st["area"] < 150:
            continue
        print(st["area"], [st[k] for k in ("x0", "y0", "x1", "y1")],
              [round(st["sx"] / st["area"]), round(st["sy"] / st["area"])])


def extract_grid_poses(path: Path) -> tuple[list[Image.Image], list[dict]]:
    image = Image.open(path).convert("RGBA")
    rgba = np.array(image)
    if rgba[..., 3].min() != 0 or rgba[..., 3].max() != 255:
        raise ValueError(f"{path}: expected actual transparent RGBA atlas")
    labels, stats = components(rgba[..., 3] >= 24)
    bodies = [st for st in stats if st["area"] >= 4000]
    if len(bodies) != 16:
        raise ValueError(f"{path}: expected 16 isolated character bodies, got {len(bodies)}")
    ordered: list[dict | None] = [None] * 16
    for st in bodies:
        c = min(3, int(st["sx"] / st["area"] / image.width * 4))
        r = min(3, int(st["sy"] / st["area"] / image.height * 4))
        i = r * 4 + c
        if ordered[i] is not None:
            raise ValueError(f"{path}: two bodies assigned to grid cell {i}")
        ordered[i] = st
    if any(st is None for st in ordered):
        raise ValueError(f"{path}: an empty grid cell")
    poses, report = [], []
    for i, st in enumerate(ordered):
        assert st is not None
        # Retain source antialias alpha immediately around the component.
        # Remove unrelated subpixel speckles in the atlas's empty gutters.
        x0, y0 = max(0, st["x0"] - 4), max(0, st["y0"] - 4)
        x1, y1 = min(image.width, st["x1"] + 4), min(image.height, st["y1"] + 4)
        member = (labels[y0:y1, x0:x1] == st["label"]).astype(np.uint8) * 255
        support = np.array(Image.fromarray(member).filter(ImageFilter.MaxFilter(7))) > 0
        region = rgba[y0:y1, x0:x1].copy()
        region[..., 3] *= support
        pose = Image.fromarray(region)
        bbox = pose.getbbox()
        if bbox is None:
            raise ValueError(f"{path}: empty pose {i}")
        poses.append(pose.crop(bbox))
        report.append({"grid_cell": i, "row": i // 4, "col": i % 4,
                       "source_bbox": [x0 + bbox[0], y0 + bbox[1], x0 + bbox[2], y0 + bbox[3]],
                       "source_alpha_area": st["area"]})
    return poses, report


def align_poses(group: str) -> tuple[list[Image.Image], dict]:
    spec = GROUPS[group]
    path = SHEETS / f"{group}_demo_v2.png"
    poses, report = extract_grid_poses(path)
    scale = spec["target_body_h"] / spec["standing_body_h"]
    offsets = []
    for pose, info, (ax, ay) in zip(poses, report, spec["anchors"]):
        x0, y0, _, _ = info["source_bbox"]
        offsets.append((round((x0 - ax) * scale), round((y0 - ay) * scale)))
    # Every pose of the character shares this ONE canvas and ONE anchor.
    # Padding includes weapon geometry below the floor and above the head.
    sizes = [(max(1, round(p.width * scale)), max(1, round(p.height * scale))) for p in poses]
    pad = 14
    left = min(x for x, _ in offsets) - pad
    top = min(y for _, y in offsets) - pad
    right = max(x + w for (x, _), (w, _) in zip(offsets, sizes)) + pad
    bottom = max(y + h for (_, y), (_, h) in zip(offsets, sizes)) + pad
    fw, fh = right - left, bottom - top
    anchor = (-left, -top)
    aligned = []
    for i, (pose, offset, size) in enumerate(zip(poses, offsets, sizes)):
        frame = Image.new("RGBA", (fw, fh))
        frame.alpha_composite(pose.resize(size, Image.Resampling.LANCZOS),
                              (offset[0] - left, offset[1] - top))
        bbox = frame.getbbox()
        if bbox is None or bbox[0] <= 0 or bbox[1] <= 0 or bbox[2] >= fw or bbox[3] >= fh:
            raise ValueError(f"{group}: clipped or empty baked pose {i}")
        aligned.append(frame)
        report[i].update(pose=spec["pose_names"][i], source_floor_anchor=list(spec["anchors"][i]),
                         baked_bbox=list(bbox))
    return aligned, {"source_atlas": path.relative_to(ROOT).as_posix(),
                     "scale": scale, "target_body_h": spec["target_body_h"],
                     "standing_body_h_source": spec["standing_body_h"],
                     "frame_w": fw, "frame_h": fh, "ax": anchor[0], "ay": anchor[1],
                     "keyframes": report}


def review_board(group: str, poses: list[Image.Image], info: dict) -> None:
    fw, fh = poses[0].size
    label_h = 32
    board = Image.new("RGBA", ((fw + 12) * 4, (fh + label_h + 12) * 4), (31, 30, 41, 255))
    draw = ImageDraw.Draw(board)
    for i, pose in enumerate(poses):
        x, y = (i % 4) * (fw + 12) + 6, (i // 4) * (fh + label_h + 12) + 6
        draw.line((x, y + info["ay"], x + fw, y + info["ay"]), fill=(100, 61, 67))
        draw.line((x + info["ax"] - 4, y + info["ay"], x + info["ax"] + 4, y + info["ay"]),
                  fill=(255, 220, 125), width=2)
        board.alpha_composite(pose, (x, y))
        draw.text((x + 5, y + fh + 3), f"{i:02}: {GROUPS[group]['pose_names'][i]}", fill=(232, 223, 211))
    board.convert("RGB").save(SHEETS / f"{group}_demo_v2_review.png")


def bake(out: Path, previews: bool) -> None:
    manifest = {"version": 2, "fps": 60, "generator": "tools/bake_demo_art.py",
                "art_source": "built-in image_gen transparent keyframe atlases",
                "note": "Right-facing strips. Duration units: 60 Hz physics ticks. Same scale/canvas/foot anchor for every action within a character.",
                "groups": {}}
    report = {"generator": "tools/bake_demo_art.py", "groups": {}}
    for group, spec in GROUPS.items():
        frames, info = align_poses(group)
        report["groups"][group] = info
        manifest["groups"][group] = {}
        group_out = out / group
        group_out.mkdir(parents=True, exist_ok=True)
        fw, fh = frames[0].size
        for name, (indices, durations, loop, reuse_note) in spec["actions"].items():
            if len(indices) != len(durations) or min(durations) <= 0:
                raise ValueError(f"{group}/{name}: invalid duration count")
            strip = Image.new("RGBA", (fw * len(indices), fh))
            for i, cell in enumerate(indices):
                strip.alpha_composite(frames[cell], (fw * i, 0))
            strip.save(group_out / f"{name}.png")
            manifest["groups"][group][name] = {
                "file": f"assets/demo/{group}/{name}.png", "frames": len(indices),
                "frame_w": fw, "frame_h": fh, "ax": info["ax"], "ay": info["ay"],
                "durations": durations, "fps": 12, "loop": loop, "source": "ai_keyframes",
                "atlas": info["source_atlas"], "source_cells": indices, "pose_note": reuse_note,
            }
            if previews and name in ("run", "attack3", "rage_slash", "chase", "attack"):
                preview = []
                for cell in indices:
                    bg = Image.new("RGBA", (fw, fh), (31, 30, 41, 255))
                    bg.alpha_composite(frames[cell])
                    preview.append(bg.convert("RGB"))
                preview[0].save(SHEETS / f"{group}_{name}_demo_v2.gif", save_all=True,
                                append_images=preview[1:], duration=[round(d / 60 * 1000) for d in durations],
                                loop=0, disposal=2)
        if previews:
            review_board(group, frames, info)
        print(f"[DEMO ART] {group}: 16 genuine atlas poses, {len(spec['actions'])} actions, "
              f"{fw}x{fh}, anchor ({info['ax']}, {info['ay']}), scale {info['scale']:.6f}")
    out.mkdir(parents=True, exist_ok=True)
    (out / "anim.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (SHEETS / "demo_v2_bake_report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    validate(out)


def validate(out: Path) -> None:
    manifest = json.loads((out / "anim.json").read_text(encoding="utf-8"))
    checked = 0
    for group, actions in manifest["groups"].items():
        geometry = set()
        for name, clip in actions.items():
            image = Image.open(out / group / f"{name}.png").convert("RGBA")
            fw, fh, n = clip["frame_w"], clip["frame_h"], clip["frames"]
            if image.size != (fw * n, fh) or len(clip["durations"]) != n:
                raise ValueError(f"{group}/{name}: strip/manifest mismatch")
            geometry.add((fw, fh, clip["ax"], clip["ay"]))
            for i in range(n):
                bbox = image.crop((i * fw, 0, (i + 1) * fw, fh)).getbbox()
                if bbox is None or bbox[0] <= 0 or bbox[1] <= 0 or bbox[2] >= fw or bbox[3] >= fh:
                    raise ValueError(f"{group}/{name}/{i}: empty or clipped frame")
                checked += 1
        if len(geometry) != 1:
            raise ValueError(f"{group}: action canvases/anchors differ")
    print(f"[DEMO ART] PASS: {checked} frames, actual alpha, no empty/clipped frames, shared character geometry")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--inspect", action="store_true")
    ap.add_argument("--out-root", type=Path, default=OUT)
    ap.add_argument("--validate-only", action="store_true")
    ap.add_argument("--no-previews", action="store_true")
    args = ap.parse_args()
    if args.inspect:
        for group in ("player", "monster"):
            inspect(SHEETS / f"{group}_demo_v2.png")
    elif args.validate_only:
        validate(args.out_root)
    else:
        bake(args.out_root, not args.no_previews)


if __name__ == "__main__":
    main()
