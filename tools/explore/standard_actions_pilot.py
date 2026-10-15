#!/usr/bin/env python3
"""Crop/calibrate painted candidate poses and preview the actual exported PNGs.

This experiment does not infer a source grid, synthesize poses, remove a painted
background, or write game/. All coordinates in crop_bbox/root/foot are absolute
source pixels. crop_bbox is [left, top, right, bottom], right/bottom exclusive.
The image operations are crop, optional explicit alpha-component isolation,
transparent trim, uniform resize and paste. No painted pose is deformed.

Run: python tools/explore/standard_actions_pilot.py path/to/config.json
Paths are relative to that JSON (absolute local source paths also work).
Minimal configuration, with every real source pose explicitly enumerated:
{
  "revision": "standard_actions_pilot_v1",
  "output_dir": "export",
  "canvas": [512, 400], "anchor": [224, 360],
  "target_standing_height": 190,
  "sources": {"walk_sheet": {"file": "walk.png", "standing_height": 300}},
  "declarations": {
    "actor_includes_weapon": true, "weapon_layering": "not_attempted",
    "G1": "pending_review", "G2": "pending_review",
    "G3": "not_passed", "G4": "pending_review"
  },
  "clips": {
    "walk": {"asset_id": "actor.player.base.walk", "loop": true,
      "root_mode": "ground", "poses": [
        {"id": "walk_01", "source": "walk_sheet",
         "crop_bbox": [10, 10, 240, 350],
         "root": [125, 330], "foot": [125, 330], "duration_ticks": 6}
      ]}
  }
}

root_mode:
  ground: root is the explicitly calibrated ground root; height_px is zero.
  virtual_ground: root is the virtual ground below an airborne pose. Its visible
    height is already encoded in the exported PNG; preview never applies it twice.
    height_px is optional metadata, defaulting to (root_y - foot_y) * scale.
  separate_height: root is the pose's local body/foot proxy; height_px is required
    in OUTPUT pixels and is stored separately. Playback translates the whole PNG
    upward by that value. Neither mode changes or deforms the painted pose.

Optional per-clip comparison: "compare": {"manifest": "../../seq_v6/manifest.json",
  "clip": "actor/attack1", "label": "V6 attack1"}. Its PNGs are loaded directly.
Per-clip "include_in_overview": false excludes it only from actions_naked;
its own exported frames, manifest, contact sheet and playback remain available.
Non-loop clips hold their last frame when a combined preview runs longer; this
preview-only hold is declared in preview_report.json. No hitstop is generated.
GIF timing uses cumulative centisecond quantization; 60 Hz JSON stays authoritative.

Optional per-pose isolation: "component_seed": [source_x, source_y],
"alpha_core_threshold": 24, "component_padding": 3. The seed must lie inside
that pose's alpha core. A four-connected core flood fill selects it, then a
square padding retains its antialiased edge. Pixels outside the binary mask are
discarded; retained source RGBA values are unchanged. Selected core touching the
crop edge or padding reaching another core is rejected: enlarge the crop or
reduce padding. Exported source-resolution masks and measured removal counts
are recorded, not interpreted as approval of the source gait or pose.
Optional "landmarks": {"grip": [x,y], "guard": [x,y], "tip": [x,y]} (or the
same named fields directly on a pose) checks that local source-alpha maxima
around those points survive. "landmark_radius" defaults to 2 source pixels.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

REPO = Path(__file__).resolve().parents[2]
FPS = 60
SCHEMA = "standard_actions_pilot/1"


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def write_json(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")


def resolve(base, value):
    path = Path(value)
    return (base / path).resolve() if not path.is_absolute() else path.resolve()


def pair(value, field):
    if not isinstance(value, list) or len(value) != 2:
        raise ValueError(f"{field}: expected [x, y]")
    values = tuple(float(v) for v in value)
    if not all(math.isfinite(v) for v in values):
        raise ValueError(f"{field}: coordinates must be finite")
    return values


def safe_name(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", value):
        raise ValueError(f"Unsafe clip/pose name: {value!r}")
    return value


def positive_int(value, field):
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise ValueError(f"{field}: expected a positive integer")
    return value


def assert_output_safe(path):
    if path == REPO / "game" or (REPO / "game") in path.parents:
        raise ValueError("This candidate tool never writes game/.")
    if path == REPO or path in REPO.parents:
        raise ValueError("Choose a dedicated candidate output directory.")


def load_sources(config, base):
    sources = {}
    for name, source in config["sources"].items():
        file = resolve(base, source["file"])
        with Image.open(file) as opened:
            image = opened.convert("RGBA")
        if image.getchannel("A").getextrema()[0] == 255:
            raise ValueError(f"{name}: opaque source; supply actual transparent RGBA, not a checkerboard image")
        height = float(source["standing_height"])
        if not math.isfinite(height) or height <= 0:
            raise ValueError(f"{name}: standing_height must be positive")
        sources[name] = (image, height, {
            "file": str(source["file"]), "sha256": hashlib.sha256(file.read_bytes()).hexdigest(),
            "size": list(image.size), "standing_height": height,
        })
    return sources


def isolate_component(cut, pose, box):
    """Select one explicitly seeded alpha component, without altering kept pixels."""
    seed = pair(pose["component_seed"], "component_seed")
    if any(v != round(v) for v in seed):
        raise ValueError(f"{pose['id']}: component_seed requires integer source pixels")
    local_seed = (int(seed[0]) - box[0], int(seed[1]) - box[1])
    if not (0 <= local_seed[0] < cut.width and 0 <= local_seed[1] < cut.height):
        raise ValueError(f"{pose['id']}: component_seed lies outside crop_bbox")
    threshold = pose.get("alpha_core_threshold", 24)
    padding = pose.get("component_padding", 3)
    radius = pose.get("landmark_radius", 2)
    if isinstance(threshold, bool) or not isinstance(threshold, int) or not 1 <= threshold <= 254:
        raise ValueError(f"{pose['id']}: alpha_core_threshold must be an integer from 1 to 254")
    for name, value in (("component_padding", padding), ("landmark_radius", radius)):
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise ValueError(f"{pose['id']}: {name} must be a nonnegative integer")
    original_alpha = cut.getchannel("A")
    core = original_alpha.point(lambda a: 255 if a > threshold else 0)
    if not core.getpixel(local_seed):
        raise ValueError(f"{pose['id']}: component_seed is not on alpha>{threshold} core")
    flooded = core.copy()
    ImageDraw.floodfill(flooded, local_seed, 128)
    selected = flooded.point(lambda a: 255 if a == 128 else 0)
    core_bounds = selected.getbbox()
    if core_bounds[0] == 0 or core_bounds[1] == 0 or core_bounds[2] == cut.width or core_bounds[3] == cut.height:
        raise ValueError(f"{pose['id']}: selected component core touches crop edge; enlarge explicit crop_bbox")
    mask = selected.filter(ImageFilter.MaxFilter(2 * padding + 1)) if padding else selected.copy()
    other_core = ImageChops.subtract(core, selected)
    if ImageChops.multiply(mask, other_core).getbbox():
        raise ValueError(f"{pose['id']}: component_padding reaches a different alpha core; reduce padding")
    isolated = Image.composite(cut, Image.new("RGBA", cut.size), mask)
    kept_alpha = isolated.getchannel("A")
    checks = {}
    landmarks = dict(pose.get("landmarks", {}))
    landmarks.update({name: pose[name] for name in ("grip", "guard", "tip") if name in pose})
    for name, point in landmarks.items():
        px, py = pair(point, f"landmark {name}")
        px, py = round(px) - box[0], round(py) - box[1]
        if not (0 <= px < cut.width and 0 <= py < cut.height):
            raise ValueError(f"{pose['id']}: landmark {name} lies outside crop_bbox")
        patch = (max(0, px - radius), max(0, py - radius),
                 min(cut.width, px + radius + 1), min(cut.height, py + radius + 1))
        before = original_alpha.crop(patch).getextrema()[1]
        after = kept_alpha.crop(patch).getextrema()[1]
        if not before or after != before:
            raise ValueError(f"{pose['id']}: isolation loses landmark {name} near {point}; source/retained max alpha {before}/{after}")
        checks[name] = {"source_point": point, "radius": radius,
                        "source_alpha_max": before, "retained_alpha_max": after, "retained": True}
    original_hist, kept_hist = original_alpha.histogram(), kept_alpha.histogram()
    digest = hashlib.sha256(mask.tobytes()).hexdigest()
    def source_box(bounds):
        return [bounds[0] + box[0], bounds[1] + box[1], bounds[2] + box[0], bounds[3] + box[1]]
    record = {
        "component_seed": list(map(int, seed)), "alpha_core_threshold": threshold,
        "component_padding": padding, "core_connectivity": 4,
        "mask_file": f"masks/{pose['id']}_{digest[:16]}.png",
        "mask_sha256_raw_l8": digest, "mask_size": list(mask.size),
        "mask_source_origin": box[:2], "mask_bbox_source": source_box(mask.getbbox()),
        "core_bbox_source": source_box(core_bounds),
        "retained_alpha_bbox_source": source_box(kept_alpha.getbbox()),
        "selected_core_pixels": selected.histogram()[255],
        "discarded_other_core_pixels": other_core.histogram()[255],
        "discarded_alpha_pixels": sum(original_hist[1:]) - sum(kept_hist[1:]),
        "discarded_alpha_sum": sum(i * (a - b) for i, (a, b) in enumerate(zip(original_hist, kept_hist))),
        "retained_alpha_pixels": sum(kept_hist[1:]), "landmark_checks": checks,
        "pixel_policy": "original RGBA unchanged inside binary mask; outside pixels set to transparent black",
    }
    return isolated, record, mask


def export_pose(pose, source, size, anchor, target_height, mode, mask_files=None):
    image, standing_height, _ = source
    box = pose["crop_bbox"]
    if not isinstance(box, list) or len(box) != 4 or any(isinstance(v, bool) or not isinstance(v, int) for v in box):
        raise ValueError(f"{pose['id']}: crop_bbox needs four explicit integer coordinates")
    x0, y0, x1, y1 = box
    if not (0 <= x0 < x1 <= image.width and 0 <= y0 < y1 <= image.height):
        raise ValueError(f"{pose['id']}: crop_bbox is outside source image: {box}")
    root = pair(pose["root"], "root")
    foot = pair(pose["foot"], "foot")
    cut = image.crop(box)
    isolation = None
    if "component_seed" in pose:
        cut, isolation, mask = isolate_component(cut, pose, box)
        if mask_files is not None:
            mask_files.append((isolation["mask_file"], mask))
    bounds = cut.getchannel("A").getbbox()
    if bounds is None:
        raise ValueError(f"{pose['id']}: empty transparent crop")
    edge = (bounds[0] == 0 or bounds[1] == 0 or bounds[2] == cut.width or bounds[3] == cut.height)
    if edge and not pose.get("allow_edge_alpha", False):
        raise ValueError(f"{pose['id']}: nontransparent pixels touch crop edge; pad bbox or explicitly allow_edge_alpha")
    cut = cut.crop(bounds)
    trim_origin = (x0 + bounds[0], y0 + bounds[1])
    scale = target_height / standing_height
    new_size = (max(1, round(cut.width * scale)), max(1, round(cut.height * scale)))
    # Pillow's premultiplied mode prevents dark fringes during uniform resampling.
    cut = cut.convert("RGBa").resize(new_size, Image.Resampling.LANCZOS).convert("RGBA")
    offset = (round(anchor[0] + (trim_origin[0] - root[0]) * scale),
              round(anchor[1] + (trim_origin[1] - root[1]) * scale))
    if offset[0] < 0 or offset[1] < 0 or offset[0] + cut.width > size[0] or offset[1] + cut.height > size[1]:
        raise ValueError(f"{pose['id']}: would clip exported canvas; offset={offset}, cut={new_size}, canvas={size}")
    if mode == "separate_height" and "height_px" not in pose:
        raise ValueError(f"{pose['id']}: separate_height requires explicit height_px in output pixels")
    height = float(pose.get("height_px", (root[1] - foot[1]) * scale if mode == "virtual_ground" else 0))
    if not math.isfinite(height) or height < 0 or (mode == "ground" and height != 0):
        raise ValueError(f"{pose['id']}: invalid height_px for {mode}")
    canvas = Image.new("RGBA", size)
    canvas.alpha_composite(cut, offset)
    foot_local = [(foot[0] - root[0]) * scale, (foot[1] - root[1]) * scale]
    record = {
        "source_pose": pose["id"], "source": pose["source"], "crop_bbox": box,
        "source_root": list(root), "source_foot": list(foot), "scale": scale,
        "trim_offset_source": list(trim_origin), "paste_offset": list(offset),
        "foot_from_anchor": foot_local, "height_px": height,
        "visible_alpha_bbox": list(canvas.getchannel("A").getbbox()),
        "crop_touches_alpha": edge,
    }
    if isolation is not None:
        record["component_isolation"] = isolation
    return canvas, record


def frame_at(clip, tick):
    total = clip["duration_ticks"]
    tick = tick % total if clip.get("loop", False) else min(tick, total - 1)
    for frame in clip["frames"]:
        if frame["start_tick"] <= tick < frame["start_tick"] + frame["duration_ticks"]:
            return frame
    raise ValueError(f"Missing frame at tick {tick}")


def bundle(manifest_path, clip_name, label):
    manifest = read_json(manifest_path)
    if manifest.get("fps") != FPS:
        raise ValueError(f"Comparison must use {FPS} Hz: {manifest_path}")
    clip = manifest["clips"][clip_name]
    if clip.get("blend", "normal") != "normal":
        raise ValueError("Naked comparisons support normal actor layers only")
    images = {}
    for frame in clip["frames"]:
        if frame["file"] not in images:
            with Image.open(manifest_path.parent / frame["file"]) as opened:
                images[frame["file"]] = opened.convert("RGBA")
    return {"label": label, "clip": clip, "images": images}


def panel_geometry(bundles):
    # Inspect exported alpha bounds so a separate jump-height curve stays visible.
    left = right = up = down = 0
    for item in bundles:
        clip = item["clip"]
        ax, ay = clip["anchor"]
        for frame in clip["frames"]:
            box = item["images"][frame["file"]].getchannel("A").getbbox()
            height = frame.get("height_px", 0) if clip.get("root_mode") == "separate_height" else 0
            dx = frame.get("root_dx", 0)
            left, right = max(left, ax - box[0] - dx), max(right, box[2] - ax + dx)
            up, down = max(up, ay - box[1] + height), max(down, box[3] - ay - height)
    left, right, up, down = [math.ceil(v) for v in (left, right, up, down)]
    return (max(250, left + right + 48), max(260, up + down + 90)), (left + 24, up + 50)


def paint_panel(item, tick, geometry, debug=False):
    size, anchor = geometry
    panel = Image.new("RGB", size, (28, 31, 38))
    draw = ImageDraw.Draw(panel)
    draw.line((0, anchor[1], size[0], anchor[1]), fill=(92, 96, 105))
    clip = item["clip"]
    frame = frame_at(clip, tick)
    height = frame.get("height_px", 0) if clip.get("root_mode") == "separate_height" else 0
    origin = (round(anchor[0] - clip["anchor"][0] + frame.get("root_dx", 0)),
              round(anchor[1] - clip["anchor"][1] - height))
    actor = item["images"][frame["file"]]
    panel.paste(actor, origin, actor)
    draw.text((12, 9), item["label"], fill=(236, 239, 245))
    draw.text((12, 26), f"pose {frame.get('source_pose', '?')}  {frame['duration_ticks']} ticks", fill=(187, 192, 204))
    if debug:
        draw.line((anchor[0] - 5, anchor[1], anchor[0] + 5, anchor[1]), fill=(255, 207, 66))
        draw.line((anchor[0], anchor[1] - 5, anchor[0], anchor[1] + 5), fill=(255, 207, 66))
        foot = frame.get("foot_from_anchor")
        if foot:
            fx, fy = anchor[0] + foot[0], anchor[1] + foot[1] - height
            draw.ellipse((fx - 3, fy - 3, fx + 3, fy + 3), outline=(85, 220, 245), width=1)
    return panel


def save_gif(path, frames, boundaries, looping):
    # Cumulative rounding bounds total error instead of rounding each hold apart.
    quantized = [round(t * 100 / FPS) * 10 for t in boundaries]
    durations = [b - a for a, b in zip(quantized, quantized[1:])]
    if any(ms <= 0 for ms in durations):
        raise ValueError("GIF cannot represent the selected timing")
    options = {"save_all": True, "append_images": frames[1:], "duration": durations,
               "disposal": 2, "optimize": False}
    if looping:
        options["loop"] = 0
    frames[0].save(path, **options)
    with Image.open(path) as gif:
        actual_ms = 0
        for index in range(gif.n_frames):
            gif.seek(index)
            actual_ms += gif.info.get("duration", 0)
    intended_ms = boundaries[-1] * 1000 / FPS
    return {"file": path.name, "intended_duration_ticks": boundaries[-1],
            "intended_duration_ms": intended_ms, "gif_duration_ms": actual_ms,
            "total_error_ms": actual_ms - intended_ms,
            "timing": "cumulative 10 ms quantization; manifest integer ticks are authoritative",
            "loop": looping}


def make_preview(items, output, stem, looping):
    geometry = panel_geometry(items)
    total = max(item["clip"]["duration_ticks"] for item in items)
    # A boundary occurs only when an exported frame or preview hold changes.
    boundaries = [0]
    previous = None
    for tick in range(total):
        state = tuple((frame_at(item["clip"], tick)["file"],
                       frame_at(item["clip"], tick).get("height_px", 0),
                       frame_at(item["clip"], tick).get("root_dx", 0)) for item in items)
        if previous is not None and state != previous:
            boundaries.append(tick)
        previous = state
    boundaries.append(total)
    images = []
    for tick in boundaries[:-1]:
        panels = [paint_panel(item, tick, geometry) for item in items]
        combined = Image.new("RGB", (geometry[0][0] * len(items), geometry[0][1]), (28, 31, 38))
        for index, panel in enumerate(panels):
            combined.paste(panel, (geometry[0][0] * index, 0))
        images.append(combined)
    images[0].save(output / f"{stem}.png")
    return save_gif(output / f"{stem}.gif", images, boundaries, looping)


def contact_sheet(item, output, columns):
    geometry = panel_geometry([item])
    clip = item["clip"]
    rows = math.ceil(len(clip["frames"]) / columns)
    sheet = Image.new("RGB", (geometry[0][0] * columns, geometry[0][1] * rows), (18, 20, 25))
    for index, frame in enumerate(clip["frames"]):
        panel = paint_panel(item, frame["start_tick"], geometry, debug=True)
        sheet.paste(panel, ((index % columns) * geometry[0][0], (index // columns) * geometry[0][1]))
    sheet.save(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("config", type=Path)
    parser.add_argument("--overwrite", action="store_true", help="replace this candidate's generated files")
    args = parser.parse_args()
    config_path = args.config.resolve()
    config, base = read_json(config_path), config_path.parent
    output = resolve(base, config["output_dir"])
    assert_output_safe(output)
    if output.exists() and any(output.iterdir()) and not args.overwrite:
        raise ValueError(f"Output is nonempty; choose a new revision or use --overwrite: {output}")
    size = tuple(positive_int(v, "canvas") for v in config["canvas"])
    if len(size) != 2:
        raise ValueError("canvas needs [width, height]")
    anchor = pair(config["anchor"], "anchor")
    if not (0 <= anchor[0] <= size[0] and 0 <= anchor[1] <= size[1]):
        raise ValueError("anchor must be inside the exported canvas")
    target_height = float(config["target_standing_height"])
    if not math.isfinite(target_height) or target_height <= 0:
        raise ValueError("target_standing_height must be positive")
    sources = load_sources(config, base)
    declarations = config.get("declarations", {})
    if declarations.get("G3") in ("passed", "approved"):
        raise ValueError("A crop/preview tool cannot claim G3 weapon-layering approval")
    manifest = {
        "schema": SCHEMA, "revision": config["revision"], "status": "review_candidate",
        "fps": FPS, "hitstop_baked": False, "actor_includes_weapon": declarations.get("actor_includes_weapon", True),
        "declarations": {"weapon_layering": "not_attempted", "G3": "not_passed", **declarations},
        "coordinate_system": "right-facing pixels, y-down; anchor is ground root except separate_height body proxy",
        "target_standing_height": target_height,
        "sources": {key: value[2] for key, value in sources.items()},
        "config_sha256": hashlib.sha256(config_path.read_bytes()).hexdigest(), "clips": {},
    }
    if not config["clips"]:
        raise ValueError("At least one explicitly configured clip is required")
    # Validate every pose before writing any candidate frame.
    prepared, mask_files = [], []
    for name, spec in config["clips"].items():
        safe_name(name)
        if not isinstance(spec["loop"], bool):
            raise ValueError(f"{name}: loop must be true/false")
        if not isinstance(spec.get("include_in_overview", True), bool):
            raise ValueError(f"{name}: include_in_overview must be true/false")
        mode = spec.get("root_mode", "ground")
        if mode not in ("ground", "virtual_ground", "separate_height"):
            raise ValueError(f"{name}: unsupported root_mode {mode}")
        if not spec["poses"]:
            raise ValueError(f"{name}: enumerate real source poses")
        clip = {"asset_id": spec["asset_id"], "size": list(size), "anchor": list(anchor),
                "blend": "normal", "alpha_mode": "straight", "clock": "action", "root_mode": mode,
                "loop": spec["loop"], "include_in_overview": spec.get("include_in_overview", True),
                "duration_ticks": 0, "frames": []}
        seen = set()
        for index, pose in enumerate(spec["poses"]):
            safe_name(pose["id"])
            if pose["id"] in seen:
                raise ValueError(f"{name}: duplicate source-pose id {pose['id']}")
            seen.add(pose["id"])
            duration = positive_int(pose["duration_ticks"], "duration_ticks")
            image, record = export_pose(pose, sources[pose["source"]], size, anchor, target_height, mode,
                                        mask_files=mask_files)
            record.update({"file": f"actor/{name}/f{index:03d}.png", "start_tick": clip["duration_ticks"],
                           "duration_ticks": duration})
            prepared.append((record["file"], image))
            clip["frames"].append(record)
            clip["duration_ticks"] += duration
        manifest["clips"][name] = clip
    output.mkdir(parents=True, exist_ok=True)
    for file, image in prepared + mask_files:
        destination = output / file
        destination.parent.mkdir(parents=True, exist_ok=True)
        image.save(destination)
    write_json(output / "manifest.json", manifest)
    write_json(output / "calibration_used.json", config)
    preview_dir = output / "previews"
    preview_dir.mkdir(exist_ok=True)
    report = {"schema": SCHEMA, "source_of_preview": "exported manifest.json and RGBA PNGs only",
              "nonloop_combination": "hold last frame after end, preview only",
              "weapon_layering": manifest["declarations"], "previews": []}
    candidates, overview_candidates = [], []
    columns = positive_int(config.get("contact_columns", 4), "contact_columns")
    for name, spec in config["clips"].items():
        item = bundle(output / "manifest.json", name, name)
        candidates.append(item)
        if spec.get("include_in_overview", True):
            overview_candidates.append(item)
        contact_sheet(item, preview_dir / f"{name}_contact.png", columns)
        report["previews"].append(make_preview([item], preview_dir, f"{name}_naked", spec["loop"]))
        if spec.get("compare"):
            ref = spec["compare"]
            reference = bundle(resolve(base, ref["manifest"]), ref["clip"], ref.get("label", ref["clip"]))
            report["previews"].append(make_preview([item, reference], preview_dir, f"{name}_compare", spec["loop"]))
    if overview_candidates:
        report["previews"].append(make_preview(overview_candidates, preview_dir, "actions_naked", True))
    report["overview_included"] = [item["label"] for item in overview_candidates]
    report["overview_excluded"] = [name for name, spec in config["clips"].items()
                                   if not spec.get("include_in_overview", True)]
    report["component_isolation"] = {"pose_count": len(mask_files),
                                     "mask_directory": "masks/", "visual_review": "pending"}
    report["exported_pose_count"] = len(prepared)
    report["automated_check"] = "passed: explicit crops, alpha bounds, canvas bounds, positive integer ticks; visual review pending"
    write_json(output / "preview_report.json", report)
    print(f"Exported {len(prepared)} poses across {len(candidates)} clips: {output / 'manifest.json'}")
    print(f"Previews: {preview_dir}; actual 60 Hz timing lives in manifest.json (GIF is quantized).")


if __name__ == "__main__":
    main()
