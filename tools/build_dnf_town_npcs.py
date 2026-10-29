"""核对城镇里实际站着的 NPC：城镇地图锚点 × `.npc` 定义。

匹配链（两者是同一批图的两种写法，必须按 basename 比）：
  `.npc` 的 `[field animation]`（如 `Animation/Npc_al.ani`）→ 真实文件 `npc/animation/npc_al.ani`
  → ANI 的 `metadata.images`（如 `Map/Npc/Npc_al.img`）
  城镇地图 animation 的帧 → `images[key].source_path`（如 `sprite/map/npc/linus.img`）
  → 取 basename 小写比对，命中即判定该 NPC 站在该城镇，锚点取地图 anchor。

输出 `game_dnf/data/town_npcs.json`：每个城镇的 NPC（id、锚点、是否已实装、field/popup 语音 key、立绘、动画）。
用法：python tools/build_dnf_town_npcs.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path, PurePosixPath

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dnf_pvf as P

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / 'game_dnf'
OUT = GAME / 'data/town_npcs.json'
TOWNS = GAME / 'data/towns.json'

# 原版 NPC 文件名的写法差异：右侧是 data/quests.json 里使用的本地 id。
ALIASES = {
    'questnpc_seria': 'seria',
    'poongjin': 'pungjin',
    'cc_gsd': 'gsd',
    'rothon': 'norton',
    'danjin': 'danjin',
}


def first(spans: dict, tag: str, default=None):
    """取该 tag 第一组 values 的第一个值（标量），不是整组列表。"""
    item = spans.get(tag)
    if not item:
        return default
    values = item[0]
    return values[0] if values else default


def group(spans: dict, tag: str) -> list:
    item = spans.get(tag)
    return list(item[0]) if item else []


def base(name: str) -> str:
    return PurePosixPath(str(name).replace('\\', '/')).name.lower()


def load_npcs(lib) -> dict[str, dict]:
    npcs: dict[str, dict] = {}
    for row in lib.db.execute("select path from files where path like '%.npc' order by path"):
        path = row[0]
        name = PurePosixPath(path).stem
        try:
            doc = lib.script(path)
        except Exception:
            continue
        spans: dict[str, list] = {}
        for item in doc.get('fields') or []:
            spans.setdefault(item['tag'], []).append(item['values'])
        ani = first(spans, '[field animation]')
        if not ani:
            continue
        real = 'npc/animation/' + PurePosixPath(str(ani)).name.lower()
        if not lib.exists(real):
            continue
        try:
            info = lib.animation(real)
        except Exception:
            continue
        images = (info or {}).get('metadata', {}).get('images') or []
        if not images:
            continue
        npcs[name] = {
            'id': name,
            'path': path,
            'field_animation': real,
            'images': sorted({base(i) for i in images}),
            'field_wav': [str(v) for v in group(spans, '[field wav]')],
            'popup_wav': [str(v) for v in group(spans, '[popup wav]')],
            # 立绘引用是 [img, frame] 两元组，必须整组保留，不能只取第一个。
            'faces': {k: group(spans, '[%s face]' % k) for k in ('small', 'big', 'popup')
                      if group(spans, '[%s face]' % k)},
        }
    return npcs


def main() -> int:
    towns = json.loads(TOWNS.read_text(encoding='utf-8'))['locations']
    lib = P.open_library()
    try:
        npcs = load_npcs(lib)
        by_image: dict[str, str] = {}
        for name, npc in npcs.items():
            for image in npc['images']:
                by_image.setdefault(image, name)
        result = {}
        for town_id, loc in towns.items():
            asset = GAME / str(loc['asset']).replace('res://', '')
            if not asset.is_file():
                continue
            data = json.loads(asset.read_text(encoding='utf-8'))
            placement = next((p for p in data['dungeon']['placements'] if p['id'] == loc['placement']), None)
            if placement is None:
                continue
            room = data['dungeon']['rooms'][placement['map']]
            declared = set((loc.get('npcs') or {}).keys())
            standing: list[dict] = []
            seen: set[str] = set()
            for item in room.get('animations') or []:
                frames = ((item.get('sprite') or {}).get('frames') or [])
                hit = None
                for frame in frames:
                    source = (data['images'].get(frame.get('image'), {}) or {}).get('source_path')
                    if source and base(source) in by_image:
                        hit = by_image[base(source)]
                        break
                if hit is None or hit in seen:
                    continue
                seen.add(hit)
                npc = npcs[hit]
                local = ALIASES.get(hit, hit)
                standing.append({
                    'id': hit, 'local_id': local, 'anchor': item.get('anchor'), 'layer': item.get('layer'),
                    'implemented': local in declared or hit in declared,
                    'field_wav': npc['field_wav'], 'popup_wav': npc['popup_wav'],
                    'faces': npc['faces'], 'field_animation': npc['field_animation'],
                })
            result[town_id] = {'placement': loc['placement'], 'declared': sorted(declared), 'npcs': standing}
    finally:
        lib.close()
    OUT.write_text(json.dumps({
        'schema': 'dnf_town_npcs/1',
        'evidence': '城镇地图 animation 的 source_path 与 .npc field animation 的 images 按 basename 相交（E-PARSE）',
        'towns': result,
    }, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    total = sum(len(v['npcs']) for v in result.values())
    missing = sum(1 for v in result.values() for n in v['npcs'] if not n['implemented'])
    print('[TOWN_NPCS] 城镇 %d 个、站位 NPC %d 个、其中未实装 %d 个' % (len(result), total, missing))
    for town_id, info in result.items():
        if info['npcs']:
            print('  %-20s 站位 %-2d 声明 %d：%s' % (town_id, len(info['npcs']), len(info['declared']),
                                                   ', '.join(n['id'] for n in info['npcs'][:10])))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
