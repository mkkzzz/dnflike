#!/usr/bin/env python3
"""Bake the original "gate open" light wall (up) and ground light (down) frames.

Source (E-FILE, shared library built from the 111Script.pvf backup):
  sprite/common/commoneffect/gate/gateup.img
  sprite/common/commoneffect/gate/gatedown.img
Both are referenced by the generic path-gate animation
``passiveobject/mapobject/pathgate/common/animation/gateall_00.ani`` (up) and
``gateall_02.ani`` (down): 29 frames, 60 ms each, additive blend.

Frames are baked into a uniform canvas so the client can draw every frame at the
same bottom-centre anchor without per-frame offset math; the canvas keeps the
original IMG canvas offsets (frame x/y) so the animation does not jitter.

Usage:
    python tools/bake_town_gate_light.py [--library <library_v1>]
Output (assets_local is git-ignored, machine-generated):
    game_dnf/assets_local/town_gate/up_00.png ... down_28.png + manifest.json
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sqlite3
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "game_dnf/assets_local/town_gate"
sys.path.insert(0, str(ROOT / "tools"))
import dnf_asset_reader as Reader  # noqa: E402

IMAGES = {
    "up": "sprite/common/commoneffect/gate/gateup.img",
    "down": "sprite/common/commoneffect/gate/gatedown.img",
}
# Reference animation: passiveobject/mapobject/pathgate/common/animation/gateall_0{0,2}.ani
FRAME_DELAY_MS = 60
SCHEMA = "dnflike_town_gate_light/1"


def library_path(explicit: Path | None) -> Path:
    if explicit:
        return explicit
    import dnf_asset_store
    lock = json.loads(dnf_asset_store.LOCK.read_text(encoding="utf-8"))
    return dnf_asset_store.cache_home() / lock["version"] / "library_v1"


def bake_family(catalog: sqlite3.Connection, root: Path, key: str) -> dict:
    source_path = IMAGES[key]
    rows = catalog.execute(
        "select local_path, sha256, container from assets where lower(original_path)=?", (source_path,)).fetchall()
    if not rows:
        raise SystemExit(f"IMG not in catalog: {source_path}")
    row = sorted(rows, key=lambda r: (not Path(r["container"]).name.lower().startswith("sprite_"), r["container"]))[0]
    data = (root / row["local_path"]).read_bytes()
    if hashlib.sha256(data).hexdigest() != row["sha256"]:
        raise SystemExit(f"IMG hash mismatch: {row['local_path']}")
    parsed = Reader.parse(data)
    frames = [f for f in parsed["frames"] if "link" not in f]
    if not frames:
        raise SystemExit(f"IMG has no drawable frames: {source_path}")
    min_x = min(f["x"] for f in frames)
    min_y = min(f["y"] for f in frames)
    max_x = max(f["x"] + f["w"] for f in frames)
    max_y = max(f["y"] + f["h"] for f in frames)
    canvas_w, canvas_h = max_x - min_x, max_y - min_y
    out_frames = []
    for index in range(len(parsed["frames"])):
        image, meta = Reader.decode(data, parsed, index)
        canvas = Image.new("RGBA", (canvas_w, canvas_h), (0, 0, 0, 0))
        if image.size != (1, 1):
            canvas.alpha_composite(image, (meta["x"] - min_x, meta["y"] - min_y))
        name = f"{key}_{index:02d}.png"
        canvas.save(OUT / name)
        out_frames.append({"file": name, "delay_ms": FRAME_DELAY_MS})
    return {"source_path": source_path, "source_sha256": row["sha256"], "source_file": row["local_path"],
            "frames": out_frames, "size": [canvas_w, canvas_h], "blend": "add"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--library", type=Path, help="library_v1 directory (contains catalog.sqlite)")
    args = parser.parse_args()
    library = library_path(args.library)
    if not (library / "catalog.sqlite").is_file():
        raise SystemExit(f"full library missing: {library}; run python tools/dnf_asset_store.py sync --full")
    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("*.png"):
        old.unlink()
    catalog = sqlite3.connect(str(library / "catalog.sqlite"))
    catalog.row_factory = sqlite3.Row
    manifest = {"schema": SCHEMA, "evidence": "E-FILE; generic path-gate light (gateall_00/02)",
                "clips": {}}
    for key in IMAGES:
        manifest["clips"][key] = bake_family(catalog, library, key)
    (OUT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=1), encoding="utf-8")
    for key, clip in manifest["clips"].items():
        print(f"{key}: {len(clip['frames'])} frames {clip['size'][0]}x{clip['size'][1]} "
              f"from {clip['source_path']} sha256={clip['source_sha256'][:16]}...")
    print(f"written {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
