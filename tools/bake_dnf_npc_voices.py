"""烘焙 NPC 语音与立绘：`.npc` 的 sound key → 原版 ogg，face 引用 → 原版 PNG。

对照关系（E-PARSE，实测）：
  `R_NPC_<NAME>_AMB_LOOP`  → sounds/npc/<name>_amb_NN.ogg   站桩环境循环
  `R_NPC_<NAME>_TALK`      → sounds/npc/<name>_tk_NN.ogg    对话
  `R_NPC_<NAME>_FAREWELL`  → sounds/npc/<name>_fw_NN.ogg    告别
  `[small face]` / `[big face]` / `[popup face]` = [img, frame] → 立绘帧

输出：
  game_dnf/assets_local/npc_voice/<npc>/amb_NN.ogg、talk_NN.ogg、farewell_NN.ogg、face_*.png
  game_dnf/data/npc_voices.json（npc → 语音文件、立绘文件、key 原文）

用法：python tools/bake_dnf_npc_voices.py [--library DIR]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_dnf_combat_assets as B

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / 'game_dnf'
SOURCE = GAME / 'data/town_npcs.json'
OUT = GAME / 'assets_local/npc_voice'
MAP = GAME / 'data/npc_voices.json'

KIND = {'AMB_LOOP': ('amb', 'amb'), 'TALK': ('talk', 'tk'), 'FAREWELL': ('farewell', 'fw')}
KEY_RE = re.compile(r'^R_NPC_(.+?)_(AMB_LOOP|TALK|FAREWELL)$')


def parse_key(key: str) -> tuple[str, str, str] | None:
    """返回 (key 里的名字, 输出类别, 文件名后缀)。音频文件按 key 里的名字命名。"""
    match = KEY_RE.match(key.strip().upper())
    if not match:
        return None
    name, tag = match.group(1).lower(), match.group(2)
    return name, KIND[tag][0], KIND[tag][1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path, default=None)
    args = parser.parse_args()
    data = json.loads(SOURCE.read_text(encoding='utf-8'))
    src = B.Source(args.library)
    cat = src.cat
    root = src.root
    OUT.mkdir(parents=True, exist_ok=True)
    result: dict[str, dict] = {}
    copied = 0
    missing: list[str] = []
    try:
        for town_id, town in data['towns'].items():
            for npc in town['npcs']:
                name = npc['local_id'] or npc['id']
                if name in result:
                    continue
                entry = {'id': npc['id'], 'local_id': name, 'town': town_id,
                         'amb': [], 'talk': [], 'farewell': [], 'faces': {}, 'keys': {
                             'field': npc.get('field_wav') or [], 'popup': npc.get('popup_wav') or []}}
                folder = OUT / name
                for key in (npc.get('field_wav') or []) + (npc.get('popup_wav') or []):
                    parsed = parse_key(str(key))
                    if parsed is None:
                        continue
                    key_name, kind, suffix = parsed
                    candidates = [key_name, name, npc['id'].lower().replace('npc_', '').replace('cc_', '')]
                    rows = []
                    for candidate in candidates:
                        rows = cat.execute(
                            "select local_path, sha256, original_path from assets where kind='audio' "
                            "and lower(original_path) like ? order by original_path",
                            ('sounds/npc/%s_%s_%%' % (candidate, suffix),)).fetchall()
                        if rows:
                            break
                    if not rows:
                        missing.append('%s:%s' % (name, key))
                        continue
                    folder.mkdir(parents=True, exist_ok=True)
                    for index, row in enumerate(rows):
                        raw = (root / row['local_path']).read_bytes()
                        if hashlib.sha256(raw).hexdigest() != row['sha256']:
                            raise ValueError('音频哈希不一致: ' + row['original_path'])
                        target = folder / ('%s_%02d.ogg' % (kind, index + 1))
                        target.write_bytes(raw)
                        entry[kind].append('npc_voice/%s/%s' % (name, target.name))
                        copied += 1
                for slot, ref in (npc.get('faces') or {}).items():
                    if not (isinstance(ref, list) and len(ref) >= 2):
                        continue
                    try:
                        image, _meta = src.frame(str(ref[0]), int(ref[1]))
                    except Exception:
                        continue
                    folder.mkdir(parents=True, exist_ok=True)
                    target = folder / ('face_%s.png' % slot)
                    image.save(target)
                    entry['faces'][slot] = 'npc_voice/%s/%s' % (name, target.name)
                result[name] = entry
    finally:
        cat.close()
        if hasattr(src, 'lib'):
            src.lib.close()
    MAP.write_text(json.dumps({
        'schema': 'dnf_npc_voices/1',
        'evidence': 'sound key 与 face 引用取自 .npc，音频/立绘为原版字节（E-PARSE）',
        'npcs': result,
    }, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    voiced = sum(1 for e in result.values() if e['talk'] or e['amb'])
    faced = sum(1 for e in result.values() if e['faces'])
    print('[NPC_VOICE] NPC %d 个：有语音 %d、有立绘 %d、音频文件 %d、缺 %d'
          % (len(result), voiced, faced, copied, len(missing)))
    for line in missing[:10]:
        print('  missing %s' % line)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
