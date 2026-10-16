from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter


def white_matte(image: Image.Image) -> Image.Image:
    rgb = image.convert("RGB")
    channels = rgb.split()
    darkest = ImageChops.darker(ImageChops.darker(channels[0], channels[1]), channels[2])
    alpha = darkest.point([max(0, min(255, round((249 - value) * 255 / 24))) for value in range(256)])
    inner = alpha.filter(ImageFilter.MinFilter(5))
    rgb_access, alpha_access, inner_access = rgb.load(), alpha.load(), inner.load()
    colors = getattr(rgb, "get_flattened_data", rgb.getdata)()
    opacities = getattr(alpha, "get_flattened_data", alpha.getdata)()
    pixels = []
    for index, (color, opacity) in enumerate(zip(colors, opacities)):
        if opacity == 0:
            pixels.append((0, 0, 0, 0))
            continue
        x, y = index % rgb.width, index // rgb.width
        weight = opacity / 255
        if inner_access[x, y] < 255:
            neighbors = [rgb_access[nx, ny] for ny in range(max(0, y - 2), min(rgb.height, y + 3)) for nx in range(max(0, x - 2), min(rgb.width, x + 3)) if alpha_access[nx, ny] == 255 and min(rgb_access[nx, ny]) < 200]
            if neighbors:
                foreground = min(neighbors, key=min)
                difference = [255 - component for component in foreground]
                estimate = sum((255 - component) * distance for component, distance in zip(color, difference)) / sum(distance * distance for distance in difference)
                weight = max(1 / 255, min(1.0, estimate))
        clean = tuple(max(0, min(255, round((component - 255 * (1 - weight)) / weight))) for component in color)
        pixels.append((*clean, round(weight * 255)))
    result = Image.new("RGBA", rgb.size)
    result.putdata(pixels)
    return result


def downsample(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    if size[0] > image.width or size[1] > image.height:
        raise ValueError("Upscaling is not permitted")
    return image.convert("RGBa").resize(size, Image.Resampling.LANCZOS).convert("RGBA")


def checker(size: tuple[int, int]) -> Image.Image:
    image = Image.new("RGBA", size, (210, 214, 215, 255))
    draw = ImageDraw.Draw(image)
    for y in range(0, size[1], 16):
        for x in range(0, size[0], 16):
            if (x // 16 + y // 16) % 2:
                draw.rectangle((x, y, x + 15, y + 15), fill=(242, 244, 244, 255))
    return image


def source_for(root: Path, subject: str) -> Path:
    files = list((root / "sources" / subject).glob("*.png"))
    if len(files) != 1:
        raise ValueError(f"Expected one {subject} source, found {len(files)}")
    return files[0]


def bake(root: Path) -> None:
    root = root.resolve()
    sources = {name: source_for(root, name) for name in ("background", "ground", "stump")}
    images = {name: Image.open(path).convert("RGBA") for name, path in sources.items()}
    background, ground_source, stump_source = (images[name] for name in ("background", "ground", "stump"))
    if background.size != ground_source.size:
        raise ValueError("Room source canvases differ; do not silently resize layers")
    ground = white_matte(ground_source)
    stump = white_matte(stump_source)
    stump_box = stump.getbbox()
    ground_box = ground.getbbox()
    if stump_box is None or ground_box is None:
        raise ValueError("Empty source after matting")
    if not 0.25 * ground.height <= ground_box[1] <= 0.55 * ground.height:
        raise ValueError("Ground boundary is outside the pilot layout range")
    stump_crop = stump.crop(stump_box)
    target_width = min(160, stump_crop.width)
    sprite = downsample(stump_crop, (target_width, round(stump_crop.height * target_width / stump_crop.width)))
    stump_root = [sprite.width // 2, sprite.height - 1]
    placement_root = [round(background.width * 0.19), round(background.height * 0.67)]
    position = (placement_root[0] - stump_root[0], placement_root[1] - stump_root[1])
    composite = Image.alpha_composite(background, ground)
    shadow = Image.new("RGBA", composite.size)
    draw = ImageDraw.Draw(shadow)
    x, y = placement_root
    draw.ellipse((x - sprite.width * 0.48, y - 12, x + sprite.width * 0.48, y + 8), fill=(35, 31, 24, 95))
    composite = Image.alpha_composite(composite, shadow.filter(ImageFilter.GaussianBlur(6)))
    composite.alpha_composite(sprite, position)
    exports = root / "exports"
    previews = root / "previews"
    exports.mkdir(parents=True, exist_ok=True)
    previews.mkdir(parents=True, exist_ok=True)
    files = {
        "background": exports / "r01_background.png",
        "ground": exports / "r01_ground.png",
        "stump": exports / "stump_intact.png",
    }
    for name, image in (("background", background), ("ground", ground), ("stump", sprite)):
        image.save(files[name])
    composite.save(previews / "r01_composite.png")
    downsample(composite, (round(composite.width * 0.75), round(composite.height * 0.75))).save(previews / "r01_composite_075.png")
    panel_height = 260
    board = Image.new("RGBA", (composite.width, composite.height + panel_height), (29, 35, 39, 255))
    board.alpha_composite(composite)
    panel_width = composite.width // 3
    captions = ("BACKGROUND | independent", "GROUND | transparent", "STUMP | transparent")
    for index, image in enumerate((background, ground, sprite)):
        scale = min(1.0, (panel_width - 24) / image.width, (panel_height - 48) / image.height)
        thumb = downsample(image, (round(image.width * scale), round(image.height * scale)))
        area = checker((panel_width - 16, panel_height - 40))
        area.alpha_composite(thumb, ((area.width - thumb.width) // 2, (area.height - thumb.height) // 2))
        board.alpha_composite(area, (index * panel_width + 8, composite.height + 32))
        ImageDraw.Draw(board).text((index * panel_width + 10, composite.height + 10), captions[index], fill="white")
    board.save(previews / "review_board.png")
    checks = {
        "matching_room_canvases": background.size == ground.size,
        "ground_has_transparency": ground.getchannel("A").getextrema() == (0, 255),
        "ground_bottom_is_opaque": ground.getchannel("A").crop((0, ground.height - 1, ground.width, ground.height)).getextrema() == (255, 255),
        "stump_has_transparency": sprite.getchannel("A").getextrema() == (0, 255),
        "stump_placement_in_bounds": position[0] >= 0 and position[1] >= 0 and position[0] + sprite.width <= background.width and position[1] + sprite.height <= background.height,
        "no_upscaling": sprite.width <= stump_crop.width and sprite.height <= stump_crop.height,
    }
    if not all(checks.values()):
        raise ValueError(f"Pilot checks failed: {checks}")
    manifest = {
        "task_id": "dungeon_10001_lowres_pilot",
        "revision": "pilot_lowres_v1",
        "status": "source_review",
        "resolution_exception": "User authorized a lower-resolution partial pilot on 2026-10-16; native 2K production targets unchanged.",
        "canvas": list(background.size),
        "scope": "One screen of R01, combined forest background layer, separate ground layer and one stump sprite. Not the complete long room or four-layer production package.",
        "reference_image_input": False,
        "upscale": False,
        "sources": {name: {"path": str(path.relative_to(root)).replace("\\", "/"), "size": list(images[name].size), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()} for name, path in sources.items()},
        "exports": {name: str(path.relative_to(root)).replace("\\", "/") for name, path in files.items()},
        "processing": {"tool": "tools/bake_forest_pilot.py", "pillow_version": importlib.metadata.version("Pillow"), "matte": "White backdrop: alpha clamps (249-min(R,G,B))*255/24; white edge decontamination; no semantic forest segmentation.", "ground_bounds": list(ground_box), "stump_source_crop": list(stump_box), "stump_sprite_size": list(sprite.size), "stump_scale": sprite.width / stump_crop.width, "alpha": "straight", "composition_shadow": "Independent procedural elliptical shadow; only in previews."},
        "stump": {"root": stump_root, "preview_root": placement_root, "collision": None},
        "preview": "previews/review_board.png",
        "checks": checks,
        "known_limits": ["Text-only generation may drift from the approved combination reference.", "Background far/mid forest currently share one layer; no true four-layer full-room production yet.", "Transparency is white-matte postprocessing, not native generator alpha; edges need visual review.", "Room seams, extended room sizes, other entities, gates and animations are not part of this pilot.", "No game integration or runtime acceptance."],
        "user_approved": False,
    }
    (root / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"result": "PILOT_OK", "checks": checks, "canvas": list(background.size), "stump_size": list(sprite.size), "preview": str(previews / "review_board.png")}, ensure_ascii=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    bake(parser.parse_args().root)
