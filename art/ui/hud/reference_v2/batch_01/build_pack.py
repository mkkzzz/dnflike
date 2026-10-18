"""Package generated HUD textures and assemble previews from the exact exports.

Only crop/trim, equal reduction, alpha masking, mirrored tiling and compositing.
No painted frame/icon is replaced by procedural geometry. Small runtime keycaps,
numbers, map markers and progress masks are deliberately separate from artwork.
"""
from pathlib import Path
import argparse
import hashlib
import json
import zipfile
from PIL import Image, ImageChops, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]
SOURCES, EXPORTS = HERE / "sources", HERE / "exports"
PREVIEWS = ROOT / "docs/previews/hud_reference_v2/batch_01"
CANVAS = (2560, 1440)
ITEMS = ["item_fruit", "item_herb", "item_potion_red", "item_potion_blue", "item_bread", "item_scroll"]
SKILLS = ["skill_quick_draw", "skill_thrust"]
TARGETS = {"hp_shell": (248, 384), "mp_shell": (248, 384), "wheel": (480, 410),
           "slot_frame": (116, 116), "fascia_tile": (512, 270), "exp_frame": (790, 70),
           "target_frame": (820, 116), "minimap_frame": (260, 285), "target_portrait": (80, 80), "title_plate": (620, 64),
           **{name: (96, 96) for name in ITEMS + SKILLS}}
TEXTURES, RECORDS = {}, {}
IDS = {"hp_shell": "ui.hud.orb_hp.frame", "mp_shell": "ui.hud.orb_mp.frame",
       "hp_liquid": "ui.hud.orb_hp.fill", "mp_liquid": "ui.hud.orb_mp.fill",
       "wheel": "ui.hud.wheel", "slot_frame": "ui.hud.slot_frame",
       "fascia_tile": "ui.hud.panel_bottom.tile", "exp_frame": "ui.hud.exp_track",
       "target_frame": "ui.hud.target_frame", "target_portrait": "ui.hud.target_portrait",
       "minimap_frame": "ui.hud.minimap_frame", "title_plate": "ui.hud.dungeon_title",
       "skill_quick_draw": "ui.skill.quick_draw.icon", "skill_thrust": "ui.skill.thrust.icon",
       **{name: "ui.item." + name.removeprefix("item_") + ".icon" for name in ITEMS}}


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def reduce_rgba(image, size):
    if size[0] > image.width or size[1] > image.height:
        raise ValueError(f"Upscale forbidden: {image.size} -> {size}")
    return image.convert("RGBa").resize(size, Image.Resampling.LANCZOS).convert("RGBA")


def load_trimmed(name):
    path = SOURCES / f"{name}.png"
    original = Image.open(path)
    original.load()
    image = original.convert("RGBA")
    # Locate solid artwork; remove only transparent safety margin and faint halo.
    solid = image.getchannel("A").point(lambda value: 255 if value > 200 else 0).getbbox()
    if solid is None:
        raise ValueError(f"No solid artwork: {name}")
    x0, y0, x1, y1 = solid
    bbox = (max(0, x0 - 2), max(0, y0 - 2), min(image.width, x1 + 2), min(image.height, y1 + 2))
    RECORDS[name] = {"asset_id": IDS[name], "source": path.relative_to(ROOT).as_posix(), "source_sha256": sha(path),
                     "source_size": list(image.size), "source_mode": original.mode,
                     "crop_bbox": list(bbox), "source_alpha": image.getchannel("A").getextrema(),
                     "prompt": (HERE / "prompts" / f"{name}.txt").relative_to(ROOT).as_posix(),
                     "generator": "built_in image_gen.imagegen", "model": "not_returned", "seed": "not_returned",
                     "actual_reference_inputs":
                        (["art/ui/hud/reference_v2/batch_01/sources/hp_shell.png"] if name == "mp_shell" else []) +
                        ["art/ui/hud/reference_v2/candidates/c1/source.png"],
                     "transparent_background_requested": name != "fascia_tile"}
    return image.crop(bbox)


def save_texture(name, image):
    path = EXPORTS / f"{name}.png"
    image.save(path)
    TEXTURES[name] = Image.open(path).convert("RGBA")  # Preview consumes saved export.
    RECORDS[name].update({"file": "exports/" + name + ".png", "export": path.relative_to(ROOT).as_posix(), "export_size": list(image.size),
                           "export_sha256": sha(path), "blend": "normal_straight_alpha", "upscaled": False})


def package_texture(name, target):
    image = load_trimmed(name)
    scale = min(target[0] / image.width, target[1] / image.height)
    if scale > 1:
        raise ValueError(f"Source below native target: {name}")
    size = (max(1, round(image.width * scale)), max(1, round(image.height * scale)))
    small = reduce_rgba(image, size)
    offset = ((target[0] - size[0]) // 2, target[1] - size[1])
    result = Image.new("RGBA", target)
    result.alpha_composite(small, offset)
    RECORDS[name].update({"uniform_scale": scale, "trimmed_size": list(image.size), "offset": list(offset)})
    save_texture(name, result)


def liquid_layer(name, well):
    image = load_trimmed(name)
    x, y, width, height = well
    scale = max(width / image.width, height / image.height)
    if scale > 1:
        raise ValueError(f"Liquid below target: {name}")
    size = (max(width, round(image.width * scale)), max(height, round(image.height * scale)))
    image = reduce_rgba(image, size)
    # Keep the painted upper glass glint; center cropping can cut it off.
    dx, dy = (image.width - width) // 2, 0
    image = image.crop((dx, dy, dx + width, dy + height))
    # Runtime reservoir geometry, 4x antialias, follows the inner black well.
    mask = Image.new("L", (width * 4, height * 4))
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, width * 4 - 1, height * 4 - 1), radius=width * 2, fill=255)
    mask = mask.resize((width, height), Image.Resampling.LANCZOS)
    image.putalpha(ImageChops.multiply(image.getchannel("A"), mask))
    result = Image.new("RGBA", (248, 384))
    result.alpha_composite(image, (x, y))
    RECORDS[name].update({"uniform_scale": scale, "cover_crop": [dx, dy, dx + width, dy + height],
                           "well_xywh": list(well), "mask": "vertical_capsule", "mask_radius": width / 2})
    save_texture(name, result)


def glass_highlight(liquid_name):
    """Extract existing near-white painted glints; do not invent extra artwork.

    This static layer stays visible when the coloured reservoir is clipped.
    Taking the minimum RGB channel excludes the saturated red/blue liquid.
    """
    image = TEXTURES[liquid_name].copy()
    red, green, blue, alpha = image.split()
    white = ImageChops.darker(ImageChops.darker(red, green), blue)
    matte = white.point(lambda value: min(210, max(0, (value - 140) * 3)))
    image.putalpha(ImageChops.multiply(alpha, matte))
    name = liquid_name.replace("liquid", "glass")
    RECORDS[name] = {**RECORDS[liquid_name], "asset_id": "ui.hud.orb_" + liquid_name[:2] + ".glass",
                     "derived_from": liquid_name, "derivation": "painted_near_white_glints_min_rgb_above_140",
                     "new_original_artwork": False}
    save_texture(name, image)


def texture(name):
    return TEXTURES.get(name)


def place(canvas, name, xy):
    image = texture(name)
    if image is not None:
        canvas.alpha_composite(image, tuple(xy))


def font(size, bold=False, italic=False):
    candidates = (["C:/Windows/Fonts/arialbi.ttf"] if italic else []) + [
        "C:/Windows/Fonts/msyhbd.ttc" if bold else "C:/Windows/Fonts/msyh.ttc",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]
    for path in candidates:
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default(size=size)


def text(canvas, xy, value, size, color="#eee6d3", anchor="lt", bold=False, italic=False):
    ImageDraw.Draw(canvas).text(xy, str(value), font=font(size, bold, italic), fill=color, anchor=anchor,
                               stroke_width=max(1, size // 15), stroke_fill="#080909")


def clip_liquid(name, ratio):
    result = texture(name).copy()
    _, y, _, height = RECORDS[name]["well_xywh"]
    cutoff = y + round(height * (1 - ratio))
    alpha = result.getchannel("A")
    if cutoff > 0:
        ImageDraw.Draw(alpha).rectangle((0, 0, result.width, cutoff - 1), fill=0)
    result.putalpha(alpha)
    return result


def runtime_bar(canvas, box, fraction, palette):
    """Small dynamic fill, explicitly allowed runtime geometry, never a frame."""
    x, y, w, h = box
    length = round(w * min(1, max(0, fraction)))
    draw = ImageDraw.Draw(canvas)
    top, mid, bottom = palette
    for row in range(h):
        t = row / max(1, h - 1)
        a, b, u = (top, mid, t * 2) if t < .5 else (mid, bottom, (t - .5) * 2)
        color = tuple(round(a[i] * (1 - u) + b[i] * u) for i in range(3))
        if length:
            draw.line((x, y + row, x + length - 1, y + row), fill=color)


def draw_slot(canvas, xy, key, icon=None, quantity=None, cooldown=0):
    x, y = xy
    place(canvas, "slot_frame", (x, y))
    if icon:
        place(canvas, icon, (x + 10, y + 10))
    if cooldown:
        veil = Image.new("RGBA", (100, 100))
        draw = ImageDraw.Draw(veil)
        draw.pieslice((-20, -20, 120, 120), -90, -90 + 360 * cooldown, fill=(0, 0, 0, 175))
        canvas.alpha_composite(veil, (x + 8, y + 8))
        text(canvas, (x + 58, y + 58), "3.6", 32, anchor="mm", bold=True)
    # Tiny runtime key plates; structural art is the generated frame above.
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle((x + 39, y + 96, x + 77, y + 124), radius=3, fill="#b7a37b", outline="#3d3529", width=2)
    text(canvas, (x + 58, y + 110), key, 23, "#f8eed7", anchor="mm", bold=True)
    if quantity is not None:
        text(canvas, (x + 100, y + 99), quantity, 22, anchor="rs", bold=True)


def assemble(hp=1.0, mp=1.0, cooldown=0, exp=0.0):
    canvas = Image.new("RGBA", CANVAS)
    tile = texture("fascia_tile")
    if tile:
        for i, x in enumerate(range(0, 2560, tile.width)):
            panel = tile if i % 2 == 0 else tile.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
            canvas.alpha_composite(panel, (x, 1170))
    place(canvas, "exp_frame", (260, 1202))
    text(canvas, (325, 1238), "Lv.30", 27, anchor="mm", bold=True)
    runtime_bar(canvas, (404, 1228, 626, 19), exp, ((166, 230, 92), (94, 189, 27), (28, 94, 6)))
    for index, name in enumerate(ITEMS):
        draw_slot(canvas, (274 + index * 128, 1302), str(index + 1), name, [5, 5, 3, 5, 5, 1][index])
    # Existing two Sword Soul skills. Other ten slots remain empty.
    for row, keys in enumerate(["QWERTY", "ASDFGH"]):
        for col, key in enumerate(keys):
            icon = SKILLS[col] if row == 1 and col < 2 else None
            draw_slot(canvas, (1540 + col * 126, 1178 + row * 130), key, icon,
                      cooldown=cooldown if icon == "skill_quick_draw" else 0)
    place(canvas, "wheel", (1060, 1098))
    for name, xy in [("hp_shell", (0, 1056)), ("mp_shell", (2312, 1056))]:
        place(canvas, name, xy)
        fill_name = name.replace("shell", "liquid")
        if texture(fill_name):
            canvas.alpha_composite(clip_liquid(fill_name, hp if name.startswith("hp") else mp), xy)
        place(canvas, name.replace("shell", "glass"), xy)
    # Lower-left buff samples reuse the generated skill art as demonstration.
    # No fictitious named game buffs or claimed game data.
    for i, name in enumerate(SKILLS):
        icon = texture(name)
        frame = texture("slot_frame")
        if icon and frame:
            canvas.alpha_composite(reduce_rgba(frame, (64, 64)), (266 + 72 * i, 1124))
            canvas.alpha_composite(reduce_rgba(icon, (52, 52)), (272 + 72 * i, 1130))
    place(canvas, "target_frame", (16, 100))
    place(canvas, "target_portrait", (30, 118))
    text(canvas, (155, 114), "人型  Lv.4 哥布林", 27, bold=True)
    runtime_bar(canvas, (150, 164, 672, 32), .72, ((246, 90, 70), (210, 22, 24), (102, 5, 13)))
    place(canvas, "minimap_frame", (2288, 66))
    text(canvas, (2438, 103), "地图", 27, anchor="mm", bold=True)
    # Connected map cells and tiny markers are runtime geometry.
    draw = ImageDraw.Draw(canvas)
    for col, row in [(0, 0), (0, 1), (1, 1), (2, 1), (2, 2)]:
        x, y = 2360 + col * 39, 150 + row * 43
        draw.rounded_rectangle((x, y, x + 34, y + 35), radius=3, fill="#313315", outline="#0c1009", width=2)
    draw.polygon([(2377, 151), (2368, 165), (2377, 179), (2386, 165)], fill="#56c6f2", outline="#101d2d", width=2)
    draw.polygon([(2455, 243), (2444, 252), (2455, 265), (2466, 252)], fill="#e34f23", outline="#461209", width=2)
    place(canvas, "title_plate", (1940, 0))
    text(canvas, (2538, 32), "幽暗密林 · 冒险级", 31, anchor="rm", bold=True)
    text(canvas, (2532, 490), "7 Hit Combo!", 61, "#21c4ec", anchor="rt", bold=True, italic=True)
    for i, (number, label) in enumerate([("42%", "操作"), ("5%", "技巧"), ("4", "被击数"), ("A", "评分")]):
        y = 730 + i * 57
        text(canvas, (2350, y), number, 38, "#eeb13f" if i > 1 else "#f4f3ec", anchor="rt", bold=True, italic=True)
        text(canvas, (2530, y), label, 31, anchor="rt", bold=True)
    return canvas


def checker(size, step=32):
    image = Image.new("RGBA", size, "#21252a")
    draw = ImageDraw.Draw(image)
    for y in range(0, size[1], step):
        for x in range(0, size[0], step):
            if (x // step + y // step) % 2:
                draw.rectangle((x, y, x + step - 1, y + step - 1), fill="#292f35")
    return image


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--partial", action="store_true", help="Development preview while generation is still running")
    args = parser.parse_args()
    EXPORTS.mkdir(parents=True, exist_ok=True)
    PREVIEWS.mkdir(parents=True, exist_ok=True)
    expected = list(TARGETS) + ["hp_liquid", "mp_liquid", "scene_clean"]
    missing = [name for name in expected if not (SOURCES / f"{name}.png").exists()]
    if missing and not args.partial:
        raise FileNotFoundError("Missing generated sources: " + ", ".join(missing))
    for name, target in TARGETS.items():
        if (SOURCES / f"{name}.png").exists():
            package_texture(name, target)
    for name, well in [("hp_liquid", (18, 56, 130, 306)), ("mp_liquid", (100, 63, 130, 294))]:
        if (SOURCES / f"{name}.png").exists():
            liquid_layer(name, well)
            glass_highlight(name)
    default = assemble()
    showcase = assemble(exp=.62)
    demonstration = assemble(hp=.64, mp=.82, cooldown=.6, exp=.62)
    default.save(PREVIEWS / "assembled_overlay_2560.png")
    reduce_rgba(default, (1920, 1080)).save(PREVIEWS / "assembled_overlay_1920.png")
    demo_bg = Image.open(SOURCES / "scene_clean.png").convert("RGBA")
    if demo_bg.width > 2560 or demo_bg.height > 1440:
        raise ValueError("Review scene unexpected size; recheck preview reduction.")
    overlay = reduce_rgba(showcase, demo_bg.size)
    Image.alpha_composite(demo_bg, overlay).convert("RGB").save(PREVIEWS / "assembled_scene.png")
    Image.alpha_composite(demo_bg, reduce_rgba(demonstration, demo_bg.size)).convert("RGB").save(PREVIEWS / "assembled_states.png")
    bottom = default.crop((0, 1040, 2560, 1440))
    board = checker(bottom.size)
    board.alpha_composite(bottom)
    board.convert("RGB").save(PREVIEWS / "bottom_native_2560.png")
    bottom_small = reduce_rgba(bottom, (1920, 300))
    small_board = checker(bottom_small.size, 24)
    small_board.alpha_composite(bottom_small)
    small_board.convert("RGB").save(PREVIEWS / "bottom_1080_scale.png")
    sheet = checker((1536, 1050))
    names = list(TEXTURES)
    for i, name in enumerate(names):
        x, y = (i % 6) * 256, (i // 6) * 250
        image = TEXTURES[name]
        scale = min(1, 220 / image.width, 190 / image.height)
        image = reduce_rgba(image, (round(image.width * scale), round(image.height * scale)))
        sheet.alpha_composite(image, (x + (256 - image.width) // 2, y + 15))
        text(sheet, (x + 128, y + 223), name, 18, anchor="mm")
    sheet.convert("RGB").save(PREVIEWS / "asset_contact_sheet.png")
    manifest = {"asset_id": "ui.hud.theme", "revision": "reference_v2.batch_01", "path_base": "repository_root",
                "lifecycle": "baked_validated" if not missing else "source_review", "canvas": list(CANVAS),
                "scale_1080": .75, "upscale_allowed": False, "runtime_integrated": False,
                "textures": RECORDS, "export_path_base": "package_root", "missing": missing, "preview_numbers_are_demonstration": True,
                "supporting_scene": {"source": (SOURCES / "scene_clean.png").relative_to(ROOT).as_posix(),
                    "source_sha256": sha(SOURCES / "scene_clean.png"), "native_size": list(demo_bg.size),
                    "prompt": (HERE / "prompts/scene_clean.txt").relative_to(ROOT).as_posix(),
                    "actual_reference_inputs": ["art/ui/hud/reference_v2/candidates/c1/source.png"],
                    "transparent_background_requested": False, "production_asset": False},
                "font": "System fonts used for review only; no font file redistributed",
                "derived_art": "Trim/equal downsample/alpha clipping only; frame and icon pixels come from generated sources",
                "panel_tiling": "mirrored_repeat", "map_cells_and_keycaps": "small runtime geometry"}
    write_json(HERE / "manifest.json", manifest)
    layout = {"canvas": list(CANVAS), "bottom_fascia": [0, 1170, 2560, 270],
              "hp": [0, 1056, 248, 384], "mp": [2312, 1056, 248, 384], "wheel": [1060, 1098, 480, 410],
              "exp": [260, 1202, 790, 70], "items": {"start": [274, 1302], "pitch": 128, "count": 6},
              "skills": {"start": [1540, 1178], "pitch": [126, 130], "rows": 2, "cols": 6, "keys": ["QWERTY", "ASDFGH"]},
              "target": [16, 100, 820, 116], "target_hp_fill": [150, 164, 672, 32],
              "minimap": [2288, 66, 260, 285], "dungeon_title": [1940, 0, 620, 64],
              "preview_scene_native_size": list(demo_bg.size), "preview_scene_upscaled": False,
              "preview_data": {"default": {"hp": 1, "mp": 1, "exp": 0}, "showcase": {"hp": 1, "mp": 1, "exp": .62}, "states": {"hp": .64, "mp": .82, "exp": .62, "cooldown": .6}}}
    write_json(HERE / "layout.json", layout)
    checks = {"all_sources_exist": not missing,
              "all_exports_rgba": all(im.mode == "RGBA" for im in TEXTURES.values()),
              "all_downsample_scales_le_one": all(record["uniform_scale"] <= 1 for record in RECORDS.values()),
              "all_source_and_export_hashes_match": all(sha(ROOT / record["source"]) == record["source_sha256"] and sha(ROOT / record["export"]) == record["export_sha256"] for record in RECORDS.values()),
              "cutout_frames_have_real_alpha": all(RECORDS[name]["source_mode"] == "RGBA" and RECORDS[name]["source_alpha"][0] == 0 for name in ["hp_shell", "mp_shell", "wheel", "slot_frame", "exp_frame", "target_frame", "minimap_frame"] if name in RECORDS),
              "liquid_layers_align_with_shell_canvas": all(TEXTURES[name].size == (248, 384) for name in ["hp_liquid", "mp_liquid"] if name in TEXTURES),
              "skill_grid_fits_before_mp": 1540 + 5 * 126 + 116 < 2312,
              "item_row_fits_before_wheel": 274 + 5 * 128 + 116 < 1060,
              "twelve_skill_slots": len("QWERTYASDFGH") == 12,
              "six_item_slots": len(ITEMS) == 6,
              "source_image_is_not_used_as_hud": True,
              "scene_uses_native_pixels_without_enlargement": demo_bg.size == (1672, 941),
              "native_and_1080_overlay_sizes": Image.open(PREVIEWS / "assembled_overlay_2560.png").size == (2560, 1440) and Image.open(PREVIEWS / "assembled_overlay_1920.png").size == (1920, 1080)}
    write_json(HERE / "validation.json", {"checks": checks, "texture_count": len(TEXTURES), "missing": missing,
                                         "runtime_tested": False, "user_batch_approval": "pending",
                                         "scene_clean_size": list(demo_bg.size), "tool": "Pillow"})
    if not missing:
        with zipfile.ZipFile(HERE / "hud_reference_v2_batch_01.zip", "w", zipfile.ZIP_DEFLATED) as bundle:
            for path in sorted(EXPORTS.glob("*.png")) + [HERE / "manifest.json", HERE / "layout.json", HERE / "validation.json", HERE / "README.md"]:
                bundle.write(path, path.relative_to(HERE))
    print(json.dumps({"textures": len(TEXTURES), "missing": missing, "checks": checks}, ensure_ascii=False, indent=2))
    if not args.partial and not all(checks.values()):
        raise ValueError("HUD export validation failed")


if __name__ == "__main__":
    main()
