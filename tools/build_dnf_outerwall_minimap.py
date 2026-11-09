"""Export the target client's OuterWall minimap pixels and fixed layout."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from PIL import Image

from build_dnf_combat_assets import Atlas, Source
from dnf_pvf import first_values

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "game_dnf/assets_local/outerwall_minimap_v1"
RESOURCE_DIR = "res://assets_local/outerwall_minimap_v1"
DUNGEON = "dungeon/act3/outerwall.dgn"
WINDOW = "ui/dungeonminimap/dungeonminimap.ui"
ROOM_BANK = "Map/MiniMap/Act3.img"
CHROME_BANK = "Interface2/Minimap/Dungeon/minimap.img"
PINNED = {
    DUNGEON: "4bc1517d37fdefdd4288ff0766a0bdc52d4c03248ca5e8d395e02354f05b08b8",
    WINDOW: "a21303208b63a031c4d333103433a8b17030fa554d923437e7259a8eeeeaf916",
    "sprite/" + ROOM_BANK.lower(): "61de0c58af2427e0646c5cac88c69e08d83b7b68fd6e77ffdea18e18d632226b",
    "sprite/" + CHROME_BANK.lower(): "660bac4038facf05c42d435a32e1bff01f0fcd731994d25d32b76a2eedff6e59",
}


def chrome(source: Source, width: int, rows: int, pitch: int, inset: int) -> Image.Image:
    board = Image.new("RGBA", (width * pitch + 2 * inset, rows * pitch + 2 * inset))
    frames = {number: source.frame(CHROME_BANK, number) for number in [*range(27, 36), 39]}
    # Native tile type 10: corner/edge/centre frames 27..35, drawn at
    # window origin minus the tile offset (0xEECE73..0xEED940).
    for y in range(rows + 2):
        band = 0 if y == 0 else 2 if y == rows + 1 else 1
        for x in range(width + 2):
            edge = 0 if x == 0 else 2 if x == width + 1 else 1
            index = 27 + band * 3 + edge
            if y == 1 and edge == 1:
                index = 39
            image, meta = frames[index]
            at = (
                (0 if x == 0 else inset + (x - 1) * pitch) + meta["x"],
                (0 if y == 0 else inset + (y - 1) * pitch) + meta["y"],
            )
            board.alpha_composite(image.convert("RGBA"), at)
    return board


def build(source: Source, output: Path) -> dict:
    dungeon = source.lib.script(DUNGEON)
    window = source.lib.script(WINDOW)
    if dungeon["sha256"] != PINNED[DUNGEON] or window["sha256"] != PINNED[WINDOW]:
        raise ValueError("Unexpected target DGN or DungeonMinimap UI")
    width, height = first_values(dungeon["fields"], "[size]")
    if first_values(dungeon["fields"], "[minimap image]") != [ROOM_BANK]:
        raise ValueError("Unexpected OuterWall room art bank")
    controls = {field["tag"]: field["values"] for field in window["fields"][0]["children"]}
    pitch, = controls["[tile width]"]
    inset, = controls["[tile offset]"]
    if (controls["[tile height]"] != [pitch] or controls["[tile type]"] != [10]
            or controls["[imagepack]"][0].replace("\\", "/") != CHROME_BANK
            or controls["[starting frame]"] != [27] or controls["[title bar]"] != [1, -1, 39, -1]
            or controls["[horizontal alignment]"] != ["right"] or controls["[vertical alignment]"] != ["top"]):
        raise ValueError("Unexpected native minimap layout")

    atlas = Atlas("atlas", RESOURCE_DIR, output)
    for number in range(122):
        image, meta = source.frame(ROOM_BANK, number)
        if image.size != (pitch, pitch) or (meta["x"], meta["y"]) != (0, 0):
            raise ValueError(f"Unexpected room frame geometry: {number}")
        atlas.add(f"room_{number}", image.convert("RGBA"), (0, 0))
    for key, frame, offset in (("player", 3, (6, 4)), ("boss", 37, (1, 2))):
        image, meta = source.frame(CHROME_BANK, frame)
        atlas.add(key, image.convert("RGBA"), (offset[0] + meta["x"], offset[1] + meta["y"]))
    atlas.add("board", chrome(source, width, height + 1, pitch, inset), (-inset, -inset))
    for path in ("sprite/" + ROOM_BANK.lower(), "sprite/" + CHROME_BANK.lower()):
        if source.sources[path] != PINNED[path]:
            raise ValueError(f"Unexpected original minimap art: {path}")

    manifest = {
        "schema": "dnf_outerwall_minimap/1",
        "sources": PINNED,
        "layout": {
            "grid": [width, height], "pitch": pitch, "grid_top": pitch,
            "window_right": controls["[horizontal distance]"][0],
            "window_top": controls["[vertical distance]"][0],
            "alpha": controls["[alpha]"][0],
        },
        "frame_sources": {"room_0..121": ROOM_BANK, "board": [*range(27, 36), 39], "player": 3, "boss": 37},
        **atlas.save(),
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path)
    parser.add_argument("--output", type=Path, default=OUT)
    args = parser.parse_args()
    manifest = build(Source(args.library), args.output)
    print(f"[OUTERWALL_MINIMAP] {len(manifest['items'])} original atlas parts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
