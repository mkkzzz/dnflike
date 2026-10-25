#!/usr/bin/env python3
"""把原版"地面掉落物"特效从资源库 IMG 烘成本地 PNG。

原版掉落的表现 = 地面光圈 + 光柱 + 物品本体（本体是物品图标去掉外框）。
`sprite/common/commoneffect/itemdropeffect/` 下就是这套原版特效，本脚本取：
  - dropping_floor.img -> 地面光圈
  - beam.img           -> 光柱（稀有/金币用）

用法：
    python tools/bake_loot_sprites.py --library D:/dnflike-assets/dnf-native-assets-v1-20261022/library_v1
输出（assets_local 被 git 忽略，属本机生成物）：
    game_dnf/assets_local/loot/floor.png, beam.png, manifest.json
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
OUT = ROOT / "game_dnf/assets_local/loot"
WANTED = {
    "floor": "sprite/common/commoneffect/itemdropeffect/dropping_floor.img",
    "beam": "sprite/common/commoneffect/itemdropeffect/beam.img",
}

sys.path.insert(0, str(ROOT / "tools"))
import dnf_asset_reader as Reader  # noqa: E402


def lookup_local(library: Path, original_path: str) -> Path:
    db = library / "catalog.sqlite"
    con = sqlite3.connect(str(db))
    try:
        row = con.execute(
            "select local_path from assets where lower(original_path)=? limit 1", (original_path.lower(),)
        ).fetchone()
    finally:
        con.close()
    if not row:
        raise SystemExit("资源库里找不到：" + original_path)
    return library / row[0]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--library", type=Path, required=True, help="library_v1 目录（含 catalog.sqlite）")
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    manifest: dict[str, dict] = {}
    for key, original in WANTED.items():
        path = lookup_local(args.library, original)
        data = path.read_bytes()
        parsed = Reader.parse(data)
        image, frame = Reader.decode(data, parsed, 0)
        out = OUT / (key + ".png")
        image.save(out)
        manifest[key] = {
            "source": original,
            "source_sha256": hashlib.sha256(data).hexdigest()[:16],
            "file": out.name,
            "size": [image.width, image.height],
            "anchor": [int(frame.get("x", 0)), int(frame.get("y", 0))],
        }
        print("  %-6s %-58s -> %dx%d" % (key, original.split("/")[-1], image.width, image.height))
    (OUT / "manifest.json").write_text(
        json.dumps({"schema": "dnflike_loot_sprites/1", "sprites": manifest}, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(" 输出:", OUT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
