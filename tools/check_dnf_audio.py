"""Validate local BGM, UI sound, and NPC voice manifests and referenced files."""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / "game_dnf"
ASSETS = GAME / "assets_local"
UI_REQUIRED = {
    "click",
    "hover",
    "window_open",
    "window_close",
    "tab",
    "character_select",
    "character_create",
    "quest_accept",
    "quest_complete",
    "level_up",
}


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def check_hashed(entry: dict, path: Path, label: str, failures: list[str]) -> None:
    if not path.is_file():
        failures.append("%s 文件缺失: %s" % (label, path.relative_to(ROOT)))
        return
    expected = str(entry.get("sha256", ""))
    if expected:
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if actual != expected:
            failures.append("%s 哈希不一致: %s" % (label, path.relative_to(ROOT)))


def main() -> int:
    failures: list[str] = []
    ui_path = GAME / "data/ui_sounds.json"
    ui = load(ui_path) if ui_path.is_file() else {}
    ui_sounds = ui.get("sounds", {})
    for key in sorted(UI_REQUIRED):
        if key not in ui_sounds:
            failures.append("UI 音效缺少语义键: " + key)
    for key, entry in ui_sounds.items():
        check_hashed(entry, ASSETS / str(entry.get("file", "")), "UI " + key, failures)

    bgm = load(GAME / "data/bgm.json")
    tracks = bgm.get("tracks", {})
    for key, entry in tracks.items():
        check_hashed(entry, ASSETS / str(entry.get("file", "")), "BGM " + key, failures)
    for target in bgm.get("scenes", {}).values():
        if target not in tracks:
            failures.append("场景 BGM 引用未烘焙: " + str(target))
    for slots in bgm.get("dungeons", {}).values():
        for target in slots.values():
            if target not in tracks:
                failures.append("副本 BGM 引用未烘焙: " + str(target))
    for target in bgm.get("screens", {}).values():
        if target not in tracks:
            failures.append("界面 BGM 引用未烘焙: " + str(target))
    for targets in bgm.get("ambience", {}).values():
        for target in targets:
            if target not in tracks:
                failures.append("环境音引用未烘焙: " + str(target))

    voices = load(GAME / "data/npc_voices.json").get("npcs", {})
    voice_files = 0
    for npc, entry in voices.items():
        for kind in ("amb", "talk", "farewell"):
            for relative in entry.get(kind, []):
                path = ASSETS / str(relative)
                voice_files += 1
                if not path.is_file():
                    failures.append("%s %s 语音缺失: %s" % (npc, kind, relative))
        for relative in entry.get("faces", {}).values():
            if not (ASSETS / str(relative)).is_file():
                failures.append("%s 立绘缺失: %s" % (npc, relative))

    if failures:
        print("[AUDIO] FAIL %d" % len(failures))
        for line in failures:
            print("  - " + line)
        return 1
    print(
        "[AUDIO] OK BGM %d、UI %d、NPC %d（语音文件 %d）全部有本地映射"
        % (len(tracks), len(ui_sounds), len(voices), voice_files)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
