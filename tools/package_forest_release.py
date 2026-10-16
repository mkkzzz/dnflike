from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from pathlib import Path

from PIL import Image, ImageDraw


def package(root: Path) -> None:
    repository = Path(__file__).resolve().parents[1]
    pilot = repository / "art/concepts/scenes/forest/10001/pilot_lowres_v3"
    source_manifest = json.loads((pilot / "manifest.json").read_text(encoding="utf-8"))
    if not source_manifest["user_approved"]:
        raise ValueError("The v3 reference must be approved before packaging")
    root = root.resolve()
    rooms = root / "exports/rooms"
    entities = root / "exports/entities/stump"
    preview = root / "previews"
    for directory in (rooms, entities, preview):
        directory.mkdir(parents=True, exist_ok=True)
    source_path = pilot / source_manifest["exports"]["scene"]
    scene = Image.open(source_path).convert("RGBA")
    overlap = 64
    width, height = scene.size
    tile = scene.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
    long_scene = Image.new("RGBA", (width * 2 - overlap, height))
    long_scene.paste(scene, (0, 0))
    long_scene.paste(tile, (width - overlap, 0))
    transition = Image.new("L", (overlap, height))
    transition.putdata([round(x * 255 / (overlap - 1)) for _ in range(height) for x in range(overlap)])
    left = scene.crop((width - overlap, 0, width, height))
    right = tile.crop((0, 0, overlap, height))
    long_scene.paste(Image.composite(right, left, transition), (width - overlap, 0))
    room_path = rooms / "10001-R01.png"
    long_scene.save(room_path)
    for key, name in (("stump", "intact.png"), ("stump_shadow", "shadow.png")):
        shutil.copyfile(pilot / source_manifest["exports"][key], entities / name)
    w, h = long_scene.size
    walkable = [32, round(h * 0.5), w - 64, round(h * 0.38)]
    door_anchors = {
        "left": [walkable[0], walkable[1] + walkable[3] // 2],
        "right": [walkable[0] + walkable[2], walkable[1] + walkable[3] // 2],
        "up": [w // 2, walkable[1]],
        "down": [w // 2, walkable[1] + walkable[3]],
    }
    overview = long_scene.copy()
    stump = Image.open(entities / "intact.png").convert("RGBA")
    shadow = Image.open(entities / "shadow.png").convert("RGBA")
    foot = [300, 515]
    anchor = source_manifest["stump"]["root"]
    shadow_anchor = source_manifest["ground_contact"]["shadow_root"]
    overview.alpha_composite(shadow, (foot[0] - shadow_anchor[0], foot[1] - shadow_anchor[1]))
    overview.alpha_composite(stump, (foot[0] - anchor[0], foot[1] - anchor[1]))
    overview.save(preview / "r01_clean.png")
    overlay = overview.copy()
    draw = ImageDraw.Draw(overlay)
    x, y, rw, rh = walkable
    draw.rectangle((x, y, x + rw, y + rh), outline=(100, 230, 145, 255), width=3)
    for direction, (dx, dy) in door_anchors.items():
        draw.ellipse((dx - 7, dy - 7, dx + 7, dy + 7), fill=(255, 190, 70, 255))
        tx = min(max(dx + 12, 0), w - 140)
        draw.text((tx, dy - 18), direction.upper() + " ANCHOR", fill="white", stroke_width=2, stroke_fill="black")
    label = Image.new("RGBA", (w, h + 44), (29, 35, 39, 255))
    label.alpha_composite(overlay, (0, 44))
    ImageDraw.Draw(label).text((12, 14), "10001-R01 | low-resolution partial delivery | native-pixel mirrored extension | other assets BLOCKED", fill="white")
    label.save(preview / "r01_handoff.png")
    checks = {
        "room_has_no_upscale": long_scene.height == scene.height,
        "room_longer_than_two_reference_screens": long_scene.width >= 2560,
        "door_anchors_in_walkable_region": all(x <= p[0] <= x + rw and y <= p[1] <= y + rh for p in door_anchors.values()),
        "stump_transparent": stump.getchannel("A").getextrema() == (0, 255),
        "shadow_transparent_nonempty": shadow.getchannel("A").getextrema()[0] == 0 and shadow.getchannel("A").getextrema()[1] > 0,
        "stump_source_bytes_preserved": (entities / "intact.png").read_bytes() == (pilot / source_manifest["exports"]["stump"]).read_bytes(),
        "shadow_source_bytes_preserved": (entities / "shadow.png").read_bytes() == (pilot / source_manifest["exports"]["stump_shadow"]).read_bytes(),
    }
    if not all(checks.values()):
        raise ValueError(f"Release checks failed: {checks}")
    manifest = {
        "schema_version": 1,
        "package_id": "dungeon.10001.environment.lowres.v1",
        "status": "partial_blocked",
        "path_base": "manifest_directory",
        "reference_viewport": [1280, 720],
        "pixel_unit": "one exported pixel equals one world unit at scale 1",
        "coordinate_system": "x right, y down; anchors are pixel offsets from image top-left",
        "alpha": "straight RGBA, normal blend",
        "style_reference": "../pilot_lowres_v3/manifest.json",
        "native_2k": False,
        "upscale": False,
        "rooms": {
            "10001-R01": {
                "file": "exports/rooms/10001-R01.png",
                "size": [w, h],
                "anchor": [0, 0],
                "walkable_rect": walkable,
                "door_anchors": door_anchors,
                "build": "Approved native scene plus reflected tile, blended across 64-pixel overlap. Intentional repeated art; not an AI-generated unique panorama or 2K asset.",
                "source_sha256": hashlib.sha256(source_path.read_bytes()).hexdigest(),
                "visual_review_of_extension": "pending",
            }
        },
        "entities": {
            "stump": {
                "size": list(stump.size),
                "anchor": anchor,
                "states": {"intact": {"file": "exports/entities/stump/intact.png"}},
                "shadow": {"file": "exports/entities/stump/shadow.png", "size": list(shadow.size), "anchor": shadow_anchor},
                "footprint_rect_relative_to_anchor": [-45, -10, 90, 20],
                "collision_policy": "Suggested XY ground footprint only; not the full upright sprite rectangle; tune in future gameplay integration.",
                "default_preview_position": foot,
            }
        },
        "missing": {
            "rooms": ["10001-R02", "10001-R03", "10001-R04", "10001-R05"],
            "entities": ["torch", "fruit_tree.with_fruit", "fruit_tree.without_fruit", "fence.intact", "fence.damaged", "fence.debris", "bone_pile.intact", "bone_pile.damaged", "bone_pile.debris", "bush", "rock", "fruit_pickup"],
            "gates": ["up.closed", "up.open", "down.closed", "down.open", "left.closed", "left.open", "right.closed", "right.open"],
            "animations": ["torch_flame", "gate_lamp_flash", "destructible_hit"],
        },
        "godot4_usage": {
            "background": "Load room PNG into Sprite2D, centered=false, position=room_origin, scale=(1,1).",
            "entity": "Sprite2D centered=false, offset=-Vector2(anchor[0],anchor[1]); set position to foot world position.",
            "shadow": "Use a sibling Sprite2D with shadow offset=-shadow.anchor, same foot world position, drawn below entity.",
            "collision": "Attach RectangleShape2D using the footprint relative to the entity foot position; game behavior is not included.",
            "paths": "Copy this self-contained export package under the future game's resource directory and resolve files relative to manifest. Current game has no automatic reader for this schema.",
            "zoom": "Do not resize only texture without scaling anchors/collision/placement consistently. This batch is low-resolution, not a native 2K delivery.",
        },
        "blocker": "First remaining-room image_gen request timed out awaiting approval on 2026-10-16. No R02 output created; further generation awaits user-approved retry.",
        "technical_checks": checks,
        "game_integrated": False,
        "runtime_approved": False,
    }
    (root / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (root / "validation.json").write_text(json.dumps({"result": "PARTIAL_ASSETS_OK", "checks": checks, "complete_environment_package": False}, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"result": "PARTIAL_ASSETS_OK", "room_size": [w, h], "ready_room_count": 1, "ready_entity_count": 1, "environment_complete": False}, ensure_ascii=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    package(parser.parse_args().root)
