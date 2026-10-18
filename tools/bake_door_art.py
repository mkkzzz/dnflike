"""把门双态设计样张加工成可运行的两态贴图。

只做三件事：按栏裁切、把纯白底转为 alpha、按两态联合包围盒对齐。
不缩放、不重绘、不镜像；镜像交给运行时 flip_h。

用法：
    python tools/bake_door_art.py
    python tools/bake_door_art.py --source art/.../side_c2.png --out game/assets/dungeon/10001/doors
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image

REPO = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = (
    REPO
    / "art/concepts/scenes/forest/10001/gate_v2/candidates/side_c2"
    / "2D_hand_painted_belt_scroller__2026-10-18T08-10-59.png"
)
DEFAULT_OUT = REPO / "game/assets/dungeon/10001/doors"

# 纯白底抠图：以最小通道判断“接近白”的程度，留一段软过渡给抗锯齿边。
WHITE_FLOOR = 246.0
WHITE_SPAN = 26.0
ALPHA_CUTOFF = 8


def key_white(image: Image.Image) -> Image.Image:
    rgba = image.convert("RGBA")
    pixels = rgba.load()
    width, height = rgba.size
    for y in range(height):
        for x in range(width):
            r, g, b, _a = pixels[x, y]
            light = min(r, g, b)
            alpha = (WHITE_FLOOR - float(light)) / WHITE_SPAN
            pixels[x, y] = (r, g, b, int(max(0.0, min(1.0, alpha)) * 255.0))
    return rgba


def content_box(image: Image.Image) -> tuple[int, int, int, int]:
    bbox = image.getchannel("A").point(lambda value: 255 if value > ALPHA_CUTOFF else 0).getbbox()
    if bbox is None:
        raise SystemExit("抠图后没有可见像素，检查白底或阈值")
    return bbox


def union_box(a: tuple[int, int, int, int], b: tuple[int, int, int, int]) -> tuple[int, int, int, int]:
    return (min(a[0], b[0]), min(a[1], b[1]), max(a[2], b[2]), max(a[3], b[3]))


def save(image: Image.Image, path: Path) -> dict:
    image.save(path, optimize=True)
    return {
        "file": path.name,
        "size": list(image.size),
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = parser.parse_args()

    if not args.source.exists():
        raise SystemExit(f"找不到门样张：{args.source}")

    sheet = Image.open(args.source).convert("RGB")
    width, height = sheet.size
    half = width // 2
    closed = key_white(sheet.crop((0, 0, half, height)))
    opened = key_white(sheet.crop((half, 0, width, height)))

    # 两态用同一个联合包围盒，切换时门框不位移。
    box = union_box(content_box(closed), content_box(opened))
    closed = closed.crop(box)
    opened = opened.crop(box)

    args.out.mkdir(parents=True, exist_ok=True)
    closed_meta = save(closed, args.out / "closed.png")
    open_meta = save(opened, args.out / "open.png")

    report = {
        "schema": "dnflike/baked-door-art/v1",
        "source": str(args.source.relative_to(REPO)).replace("\\", "/"),
        "source_sha256": hashlib.sha256(args.source.read_bytes()).hexdigest(),
        "source_size": [width, height],
        "crop": {"left": box[0], "top": box[1], "right": box[2], "bottom": box[3]},
        "key": {"mode": "min_channel_soft_white", "white_floor": WHITE_FLOOR,
                "white_span": WHITE_SPAN, "alpha_cutoff": ALPHA_CUTOFF},
        "anchor": [0.5, 1.0],
        "resize_applied": False,
        "upscale_applied": False,
        "states": {"closed": closed_meta, "open": open_meta},
    }
    (args.out / "bake_report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps({"crop": report["crop"], "closed": closed_meta["size"],
                      "open": open_meta["size"]}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
