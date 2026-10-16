from __future__ import annotations

import hashlib
import math
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

from bake_forest_pilot import checker, downsample, white_matte


def unique_source(root: Path, subject: str) -> Path | None:
    paths = list((root / "sources" / subject).glob("*.png"))
    if len(paths) > 1:
        raise ValueError(f"Ambiguous source: {subject}")
    return paths[0] if paths else None


def place(image: Image.Image, sprite: Image.Image, anchor: list[int], foot: tuple[int, int]) -> None:
    image.alpha_composite(sprite, (foot[0] - anchor[0], foot[1] - anchor[1]))


def shadow_for(sprite: Image.Image, anchor: list[int]) -> tuple[Image.Image, list[int]]:
    pad = 32
    result = Image.new("RGBA", (sprite.width + pad * 2, sprite.height + pad * 2))
    alpha = sprite.getchannel("A")
    mask = Image.new("L", result.size)
    projection = alpha.transpose(Image.Transpose.FLIP_TOP_BOTTOM).resize((sprite.width, max(8, round(sprite.height * 0.2))), Image.Resampling.LANCZOS)
    for row in range(projection.height):
        mask.paste(projection.crop((0, row, projection.width, row + 1)), (pad + round(row * 0.6), pad + anchor[1] - 6 + row))
    mask = mask.point(lambda value: round(value * 0.28)).filter(ImageFilter.GaussianBlur(3))
    contact = Image.new("L", result.size)
    draw = ImageDraw.Draw(contact)
    pixels = alpha.load()
    for x in range(sprite.width):
        occupied = [y for y in range(sprite.height) if pixels[x, y] > 96]
        if occupied:
            y = max(occupied)
            draw.ellipse((x + pad - 1, y + pad - 2, x + pad + 1, y + pad + 2), fill=125)
    result.paste((40, 30, 20, 255), (0, 0, result.width, result.height))
    result.putalpha(ImageChops.lighter(mask, contact.filter(ImageFilter.GaussianBlur(1))))
    return result, [anchor[0] + pad, anchor[1] + pad]


def state_variant(sprite: Image.Image, variant: str) -> Image.Image:
    if variant == "intact":
        return sprite.copy()
    result = Image.new("RGBA", sprite.size)
    if variant == "damaged":
        mask = Image.new("L", sprite.size, 255)
        draw = ImageDraw.Draw(mask)
        w, h = sprite.size
        draw.polygon([(w * 0.31, 0), (w * 0.68, 0), (w * 0.6, h * 0.38), (w * 0.49, h * 0.31), (w * 0.43, h * 0.48), (w * 0.27, h * 0.34)], fill=0)
        result = sprite.copy()
        result.putalpha(ImageChops.multiply(sprite.getchannel("A"), mask))
        return result
    for index in range(4):
        x0, x1 = round(index * sprite.width / 4), round((index + 1) * sprite.width / 4)
        piece = sprite.crop((x0, 0, x1, sprite.height))
        bounds = piece.getbbox()
        if bounds is None:
            continue
        piece = piece.crop(bounds)
        scale = min(1.0, sprite.height * 0.25 / piece.height)
        piece = downsample(piece, (max(1, round(piece.width * scale)), max(1, round(piece.height * scale))))
        piece = piece.rotate((-22, 18, -12, 28)[index], Image.Resampling.BICUBIC, expand=True)
        px = min(max(0, round(index * sprite.width / 4)), max(0, result.width - piece.width))
        py = max(0, result.height - piece.height - (index % 2) * 2)
        result.alpha_composite(piece, (px, py))
    return result


def append_assets(root: Path, manifest: dict, extend_room) -> None:
    checks = manifest["technical_checks"]
    for number in (3, 4, 5):
        name = f"r{number:02}"
        source = unique_source(root, name)
        if source is None:
            continue
        native = Image.open(source).convert("RGBA")
        if number == 4:
            extra = 256
            scene = Image.new("RGBA", (native.width, native.height + extra))
            scene.paste(native.crop((0, 0, native.width, extra)).transpose(Image.Transpose.FLIP_TOP_BOTTOM), (0, 0))
            scene.paste(native, (0, extra))
            viewport = [960, 540]
            walk = [24, extra + round(native.height * 0.77), native.width - 48, round(native.height * 0.17)]
            build = "Native square scene with a 256px vertically reflected canopy extension; original ground preserved; repeated canopy, no upscale."
        else:
            scene = extend_room(native)
            if number == 3:
                scene = scene.crop((0, 0, min(1920, scene.width), scene.height))
            viewport = [1280, 720]
            walk = [32, round(scene.height * (0.68 if number == 5 else 0.64)), scene.width - 64, round(scene.height * (0.16 if number == 5 else 0.25))]
            build = "Native scene and horizontal mirrored extension with 64px blend; intentional repeated art, no upscale."
        room_id = f"10001-R{number:02}"
        path = root / "exports/rooms" / f"{room_id}.png"
        scene.save(path)
        x, y, w, h = walk
        anchors = {"left": [x, y + h // 2], "right": [x + w, y + h // 2], "up": [scene.width // 2, y], "down": [scene.width // 2, y + h]}
        manifest["rooms"][room_id] = {
            "file": str(path.relative_to(root)).replace("\\", "/"), "size": list(scene.size), "anchor": [0, 0],
            "reference_viewport": viewport, "walkable_rect": walk, "door_anchors": anchors,
            "source": str(source.relative_to(root)).replace("\\", "/"), "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
            "build": build, "visual_review_of_extension": "pending",
        }
        manifest["missing"]["rooms"].remove(room_id)
        scene.save(root / "previews" / f"{name}_clean.png")
        overlay = scene.copy()
        draw = ImageDraw.Draw(overlay)
        draw.rectangle((x, y, x + w, y + h), outline=(100, 230, 145, 255), width=3)
        for dx, dy in anchors.values():
            draw.ellipse((dx - 6, dy - 6, dx + 6, dy + 6), fill=(255, 190, 70, 255))
        overlay.save(root / "previews" / f"{name}_handoff.png")
        checks[f"{name}_anchors_in_bounds"] = all(0 <= p[0] < scene.width and 0 <= p[1] < scene.height for p in anchors.values())
        checks[f"{name}_walkable_rect_in_bounds"] = 0 <= x and 0 <= y and x + w < scene.width and y + h < scene.height
    props = unique_source(root, "props")
    if props is not None:
        sheet = Image.open(props).convert("RGBA")
        specs = [
            ("torch", 48, 240, [-12, -5, 24, 10]),
            ("fence", 260, 160, [-105, -12, 210, 24]),
            ("bone_pile", 140, 95, [-55, -8, 110, 16]),
            ("bush", 180, 135, [-70, -12, 140, 24]),
            ("rock", 150, 120, [-55, -12, 110, 24]),
            ("fruit_pickup", 40, 48, [-12, -5, 24, 10]),
        ]
        for index, (name, max_w, max_h, footprint) in enumerate(specs):
            column, row = index % 3, index // 3
            box = (round(column * sheet.width / 3) + 10, round(row * sheet.height / 2) + 10, round((column + 1) * sheet.width / 3) - 10, round((row + 1) * sheet.height / 2) - 10)
            sprite = white_matte(sheet.crop(box))
            bounds = sprite.getbbox()
            if bounds is None:
                raise ValueError(f"Empty prop cell: {name}")
            sprite = sprite.crop(bounds)
            ratio = min(1.0, max_w / sprite.width, max_h / sprite.height)
            sprite = downsample(sprite, (max(1, round(sprite.width * ratio)), max(1, round(sprite.height * ratio))))
            alpha_box = sprite.getbbox()
            anchor = [sprite.width // 2, alpha_box[3] - 1]
            directory = root / "exports/entities" / name
            directory.mkdir(parents=True, exist_ok=True)
            states = ("intact", "damaged", "debris") if name in ("fence", "bone_pile") else ("idle",) if name == "fruit_pickup" else ("intact",)
            files = {}
            for state in states:
                image = state_variant(sprite, state if len(states) == 3 else "intact")
                image.save(directory / f"{state}.png")
                shadow, shadow_anchor = shadow_for(image, anchor)
                shadow.save(directory / f"{state}_shadow.png")
                files[state] = {"file": f"exports/entities/{name}/{state}.png", "shadow": {"file": f"exports/entities/{name}/{state}_shadow.png", "size": list(shadow.size), "anchor": shadow_anchor}}
                checks[f"{name}_{state}_nonempty_transparent"] = image.getbbox() is not None and image.getchannel("A").getextrema() == (0, 255)
            manifest["entities"][name] = {
                "size": list(sprite.size), "anchor": anchor, "states": files, "footprint_rect_relative_to_anchor": footprint,
                "source": str(props.relative_to(root)).replace("\\", "/"), "source_cell": list(box),
                "source_sha256": hashlib.sha256(props.read_bytes()).hexdigest(), "upscale": False,
                "build": "Generated intact prop, white-matte alpha and native/downsampled cell crop. Damaged state uses a cutout mask; debris uses rotated/downsampled native fragments, not independently generated art.",
                "art_review": "pending",
            }
            if name in ("fence", "bone_pile"):
                for state in states:
                    manifest["missing"]["entities"].remove(f"{name}.{state}")
            else:
                manifest["missing"]["entities"].remove(name)
    manifest["blocker"] = "All five room images and six intact prop types exported. Fruit-tree request timed out awaiting approval; fruit-tree states, gates and animations remain missing."
    create_overview(root, manifest)


def create_overview(root: Path, manifest: dict) -> None:
    width, cell_w, cell_h = 1440, 480, 310
    room_count = len(manifest["rooms"])
    rows = math.ceil(room_count / 3)
    prop_cells = [(name, state) for name, entity in manifest["entities"].items() for state in entity["states"]]
    prop_rows = math.ceil(len(prop_cells) / 6)
    board = Image.new("RGBA", (width, 56 + rows * cell_h + prop_rows * 185 + 52), (29, 35, 39, 255))
    ImageDraw.Draw(board).text((14, 16), "10001 LOW-RES ENVIRONMENT | 5 room images + props | fruit tree / gates / animation STILL MISSING", fill="white")
    for index, (room_id, room) in enumerate(manifest["rooms"].items()):
        scene = Image.open(root / room["file"]).convert("RGBA")
        scale = min(1.0, (cell_w - 20) / scene.width, (cell_h - 38) / scene.height)
        thumb = downsample(scene, (round(scene.width * scale), round(scene.height * scale)))
        x, y = (index % 3) * cell_w, 56 + (index // 3) * cell_h
        board.alpha_composite(thumb, (x + (cell_w - thumb.width) // 2, y + 32))
        ImageDraw.Draw(board).text((x + 12, y + 8), f"{room_id} | {scene.width}x{scene.height}", fill="white")
    for index, (name, state) in enumerate(prop_cells):
        entity = manifest["entities"][name]
        entry = entity["states"][state]
        sprite = Image.open(root / entry["file"]).convert("RGBA")
        scale = min(1.0, 220 / sprite.width, 135 / sprite.height)
        thumb = downsample(sprite, (max(1, round(sprite.width * scale)), max(1, round(sprite.height * scale))))
        area = checker((224, 146))
        area.alpha_composite(thumb, ((area.width - thumb.width) // 2, (area.height - thumb.height) // 2))
        x, y = (index % 6) * 240 + 8, 56 + rows * cell_h + (index // 6) * 185
        board.alpha_composite(area, (x, y + 25))
        ImageDraw.Draw(board).text((x, y + 5), f"{name}.{state}", fill="white")
    board.save(root / "previews/environment_overview.png")
    scene = Image.open(root / manifest["rooms"]["10001-R01"]["file"]).convert("RGBA")
    if "torch" in manifest["entities"]:
        positions = {"stump": (300, 515), "torch": (570, 545), "fence": (1000, 560), "bone_pile": (1320, 550), "bush": (1640, 560), "rock": (2050, 555), "fruit_pickup": (2300, 550)}
        for name, foot in positions.items():
            entity = manifest["entities"][name]
            state = next(iter(entity["states"].values()))
            shadow_entry = state.get("shadow", entity.get("shadow"))
            if shadow_entry:
                place(scene, Image.open(root / shadow_entry["file"]).convert("RGBA"), shadow_entry["anchor"], foot)
            place(scene, Image.open(root / state["file"]).convert("RGBA"), entity["anchor"], foot)
        scene.save(root / "previews/props_on_r01.png")
