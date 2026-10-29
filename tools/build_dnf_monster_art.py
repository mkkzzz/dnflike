"""按 `.mob` 的动作表烘焙怪物动作图集（原生像素，不缩放）。

来源：`data/monster_catalog.json` 的 `motions`（waiting/move/attack/damage1/down/die…），
每个动作是 `.mob` 目录下的 ANI 相对路径；ANI 的 `frames` 给出 img / img_frame / pos / delay_ms。
输出：`assets_local/monster_art/<area>_<name>/<motion>.png` + `manifest.json`
（每帧 rect + 原始 pos + delay，供战斗侧按锚点绘制）。

用法：
  python tools/build_dnf_monster_art.py --ids goblin,goblinthrower,tauarmy
  python tools/build_dnf_monster_art.py            # catalog 里全部
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path, PurePosixPath

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_dnf_combat_assets as B
import dnf_pvf as P

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / 'game_dnf'
OUT = GAME / 'assets_local/monster_art'
CATALOG = GAME / 'data/monster_catalog.json'
MAP = GAME / 'data/monster_art.json'
MAX_FRAMES = 24


def bake_motion(src, folder: str, ani_rel: str) -> dict | None:
    path = (folder + '/' + ani_rel).lower().replace('//', '/')
    if not src.lib.exists(path):
        return None
    info = src.lib.animation(path)
    frames = ((info or {}).get('metadata') or {}).get('frames') or []
    if not frames:
        return None
    frames = frames[:MAX_FRAMES]
    images = []
    for frame in frames:
        try:
            image, _meta = src.frame(str(frame['img']), int(frame.get('img_frame', 0)))
        except Exception:
            return None
        images.append((image, frame))
    width = sum(image.width for image, _ in images)
    height = max(image.height for image, _ in images)
    sheet = B.Image.new('RGBA', (width, height), (0, 0, 0, 0))
    offset = 0
    meta_frames = []
    for image, frame in images:
        sheet.paste(image, (offset, height - image.height), image)
        meta_frames.append({
            'rect': [offset, height - image.height, image.width, image.height],
            'pos': list(frame.get('pos') or [0, 0]),
            'delay': int(frame.get('delay_ms') or 100),
        })
        offset += image.width
    return {'sheet': sheet, 'frames': meta_frames}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path, default=None)
    parser.add_argument('--ids', default='', help='只烘这些 mob 名（逗号分隔）；空=全部')
    args = parser.parse_args()
    wanted = {x.strip().lower() for x in args.ids.split(',') if x.strip()}
    catalog = json.loads(CATALOG.read_text(encoding='utf-8'))['monsters']
    OUT.mkdir(parents=True, exist_ok=True)
    src = B.Source(args.library)
    result: dict[str, dict] = {}
    baked = 0
    try:
        for key, mob in catalog.items():
            if wanted and mob.get('name', '').lower() not in wanted:
                continue
            motions = mob.get('motions') or {}
            if not motions:
                continue
            area_name = key.replace('/', '_')
            folder = OUT / area_name
            entry = {'mob': key, 'path': mob['path'], 'motions': {}}
            for motion, ani_list in motions.items():
                for index, ani_rel in enumerate(ani_list):
                    packed = bake_motion(src, mob['folder'], ani_rel)
                    if packed is None:
                        continue
                    folder.mkdir(parents=True, exist_ok=True)
                    name = motion if index == 0 else '%s_%d' % (motion, index)
                    target = folder / (name + '.png')
                    packed['sheet'].save(target)
                    entry['motions'][name] = {
                        'atlas': 'monster_art/%s/%s.png' % (area_name, name),
                        'size': [packed['sheet'].width, packed['sheet'].height],
                        'frames': packed['frames'],
                    }
                    baked += 1
                    break  # 每个动作取第一个 ANI（多数怪只有一个）
            if entry['motions']:
                result[key] = entry
    finally:
        if hasattr(src, 'lib'):
            src.lib.close()
    MAP.write_text(json.dumps({
        'schema': 'dnf_monster_art/1',
        'evidence': '动作帧取自 .mob 的 motion ANI，原生像素；pos 为 ANI 原始锚点偏移',
        'monsters': result,
    }, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    total_bytes = sum(f.stat().st_size for f in OUT.rglob('*.png'))
    print('[MONSTER_ART] 怪物 %d 种、动作图集 %d 张、%.2f MB'
          % (len(result), baked, total_bytes / 1048576))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
