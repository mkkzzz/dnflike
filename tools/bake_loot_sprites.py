#!/usr/bin/env python3
"""烘焙原版"地面掉落物"贴图：field 系列本体 + 16 帧动画光柱。

原版掉落 = 光柱（itemdropeffect/beam.img，16 帧循环）+ 本体（sprite/item/field*.img）。
本脚本把需要的帧逐个导出为 PNG，并写出映射表，供 game_dnf 运行时直接加载。

物品到帧的映射是人工对照原版 field 图挑的（本工程物品只有几件），
与 DNF 的 .stk/.eqb 字段号无对应；换物品时改 SHEETS 即可。

用法：
    python tools/bake_loot_sprites.py --library D:/dnflike-assets/dnf-native-assets-v1-20261022/library_v1
输出（assets_local 被 git 忽略，属本机生成物）：
    game_dnf/assets_local/loot/beam_00.png ... <item>_00.png ... manifest.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sqlite3
import sys
from pathlib import Path

from PIL import Image  # noqa: F401  (Reader 内部用)

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "game_dnf/assets_local/loot"

sys.path.insert(0, str(ROOT / "tools"))
import dnf_asset_reader as Reader  # noqa: E402

SHEETS = {
    "beam": ("sprite/common/commoneffect/itemdropeffect/beam.img", list(range(16))),
    "gold": ("sprite/common/etc/usecoin.img", list(range(6))),
    "potion": ("sprite/item/field_consumption.img", [10]),
    "scrap_iron": ("sprite/item/field_material.img", [93]),
    "iron_sword": ("sprite/item/field_weapon.img", [2]),
    "forest_sword": ("sprite/item/field_weapon.img", [2]),
    "training_coat": ("sprite/item/fieldimage.img", [3]),
    "training_necklace": ("sprite/item/fieldimage.img", [7]),
}
FPS = {"beam": 12, "gold": 8}
# 拾取音效（原版）：金币用 coin_pick_01..03，其它物品用 item_pick
SOUNDS = {
    "coin_pick": ["sounds/effect/coin_pick_01.ogg", "sounds/effect/coin_pick_02.ogg", "sounds/effect/coin_pick_03.ogg"],
    "item_pick": ["sounds/effect/item_pick.ogg"],
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--library", type=Path, required=True, help="library_v1 目录（含 catalog.sqlite）")
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("*.png"):
        old.unlink()
    con = sqlite3.connect(str(args.library / "catalog.sqlite"))
    manifest: dict[str, object] = {"schema": "dnflike_loot_sprites/2", "sprites": {}}
    sprites: dict[str, dict] = manifest["sprites"]  # type: ignore[assignment]
    for key, (original, frames) in SHEETS.items():
        row = con.execute(
            "select local_path from assets where lower(original_path)=? limit 1", (original.lower(),)
        ).fetchone()
        if not row:
            print("  ❌ 资源库找不到：", original)
            continue
        data = (args.library / row[0]).read_bytes()
        parsed = Reader.parse(data)
        files: list[str] = []
        size = [0, 0]
        for order, frame_index in enumerate(frames):
            if frame_index >= len(parsed["frames"]):
                continue
            try:
                image, _frame = Reader.decode(data, parsed, frame_index)
            except Exception as exc:  # noqa: BLE001
                print("  ❌ %s 帧 %d: %s" % (key, frame_index, exc))
                continue
            if image.width <= 1 or image.height <= 1:
                continue
            name = "%s_%02d.png" % (key, order)
            image.save(OUT / name)
            files.append(name)
            size = [image.width, image.height]
        if not files:
            continue
        sprites[key] = {
            "frames": files,
            "fps": FPS.get(key, 10),
            "source": original,
            "source_sha256": hashlib.sha256(data).hexdigest()[:16],
            "source_frame": frames[0] if frames else 0,
            "size": size,
        }
        print("  %-16s %2d 帧  %-46s %dx%d" % (key, len(files), original.split("/")[-1], size[0], size[1]))
    (OUT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(" 输出:", OUT)
    # 拾取音效：原样复制（ogg 不需要再编码）
    audio_dir = OUT / "audio"
    audio_dir.mkdir(parents=True, exist_ok=True)
    sounds: dict[str, list[str]] = {}
    for key, originals in SOUNDS.items():
        files: list[str] = []
        for original in originals:
            row = con.execute(
                "select local_path from assets where lower(original_path)=? limit 1", (original.lower(),)
            ).fetchone()
            if not row:
                print("  ❌ 音效缺失：", original)
                continue
            source = args.library / row[0]
            # 库里本地文件名带 20 位哈希前缀，这里还原成原始文件名
            clean = source.name
            if len(clean) > 21 and clean[20] == "_":
                clean = clean[21:]
            target = audio_dir / clean
            target.write_bytes(source.read_bytes())
            files.append(clean)
        if files:
            sounds[key] = files
    manifest["sounds"] = sounds
    (OUT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    for key, files in sounds.items():
        print("  音效 %-10s %s" % (key, ", ".join(files)))
    con.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
