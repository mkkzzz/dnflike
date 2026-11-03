"""Copy selected original UI sounds into the Godot project.

The archive's ``sounds/ui`` family is the authoritative source. This tool keeps
the selected Ogg files byte-for-byte and writes a semantic manifest used by the
runtime UI sound router.

Usage:
  python tools/bake_dnf_ui_audio.py [--library DIR]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_dnf_combat_assets as B

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / "game_dnf"
OUT = GAME / "assets_local/ui_audio"
MAP = GAME / "data/ui_sounds.json"

# Semantic key -> original sound path. These are used by the shared UI router,
# not hard-coded into individual windows.
SOUNDS = {
    "click": "sounds/ui/click1.ogg",
    "hover": "sounds/ui/mouseover.ogg",
    "window_open": "sounds/ui/winshow.ogg",
    "window_close": "sounds/ui/winclose.ogg",
    "tab": "sounds/ui/tabselect.ogg",
    "character_select": "sounds/ui/selectcharacter.ogg",
    "character_create": "sounds/ui/char_create.ogg",
    "text_input": "sounds/ui/write_char.ogg",
    "quest_accept": "sounds/ui/quest_accept.ogg",
    "quest_complete": "sounds/ui/qcomplete1.ogg",
    "item_get": "sounds/ui/get_item.ogg",
    "item_drop": "sounds/ui/icondrop.ogg",
    "purchase": "sounds/ui/buy_item.ogg",
    "coin": "sounds/ui/coin_in.ogg",
    "repair": "sounds/ui/repair.ogg",
    "strengthen_success": "sounds/ui/strengthen_success.ogg",
    "strengthen_fail": "sounds/ui/strengthen_fail.ogg",
    "level_up": "sounds/ui/levup.ogg",
    "result": "sounds/ui/result_flash.ogg",
    "error": "sounds/ui/alert_1.ogg",
    "map_select": "sounds/ui/map_select.ogg",
    "map_hover": "sounds/ui/map_mouse.ogg",
    "page": "sounds/ui/scrollarrow.ogg",
    "skill_click": "sounds/ui/skill_click.ogg",
    "skill_move": "sounds/ui/skill_move.ogg",
    "skill_learn": "sounds/ui/skill_learn.ogg",
    "equip": "sounds/ui/iconset.ogg",
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, default=None)
    args = parser.parse_args()
    src = B.Source(args.library)
    OUT.mkdir(parents=True, exist_ok=True)
    result: dict[str, dict] = {}
    missing: list[str] = []
    try:
        for key, source in SOUNDS.items():
            row = src.cat.execute(
                "select local_path, sha256, bytes from assets "
                "where kind='audio' and lower(original_path)=? "
                "order by container limit 1",
                (source.lower(),),
            ).fetchone()
            if row is None:
                missing.append(source)
                continue
            raw = (src.root / row["local_path"]).read_bytes()
            digest = hashlib.sha256(raw).hexdigest()
            if digest != row["sha256"]:
                raise ValueError("音频哈希不一致: " + source)
            target = OUT / (key + ".ogg")
            target.write_bytes(raw)
            result[key] = {
                "file": "ui_audio/" + target.name,
                "source": source,
                "sha256": digest,
                "bytes": row["bytes"],
            }
    finally:
        src.cat.close()
        if hasattr(src, "lib"):
            src.lib.close()

    if missing:
        print("[UI_AUDIO] 缺少原版音频: " + ", ".join(missing), file=sys.stderr)
        return 2

    MAP.write_text(
        json.dumps(
            {
                "schema": "dnf_ui_sounds/1",
                "evidence": "原版 sounds/ui/*.ogg 原字节；语义键到文件的映射由运行时统一使用（E-PARSE）",
                "sounds": result,
            },
            ensure_ascii=False,
            indent=1,
        )
        + "\n",
        encoding="utf-8",
    )
    print(
        "[UI_AUDIO] sounds=%d bytes=%d -> %s"
        % (len(result), sum(int(v["bytes"]) for v in result.values()), MAP.relative_to(ROOT))
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
