"""检查任务总账与已实装任务是否一致，并打印实装进度。

判定：
  ① `data/quest_catalog.json` 必须存在且无解析失败；
  ② `data/quests.json` 里每个带原版 source 的任务，都必须在总账里标成 implemented；
  ③ 打印 epic（剧情主线）与各目录的实装进度，供逐章推进。

用法：python tools/check_dnf_quests.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / 'game_dnf'


def main() -> int:
    catalog = json.loads((GAME / 'data/quest_catalog.json').read_text(encoding='utf-8'))
    quests = json.loads((GAME / 'data/quests.json').read_text(encoding='utf-8'))['quests']
    quests += json.loads((GAME / 'data/native_runtime.json').read_text(encoding='utf-8'))['quests']
    by_path = {r['path'].lower(): r for r in catalog['quests']}
    fails: list[str] = []
    if catalog['summary']['failed']:
        fails.append('总账里有 %d 条解析失败' % catalog['summary']['failed'])
    for quest in quests:
        path = str((quest.get('source') or {}).get('path', '')).lower()
        if not path:
            continue
        row = by_path.get(path)
        if row is None:
            fails.append('%s 的源文件不在总账里：%s' % (quest['id'], path))
        elif not row['implemented']:
            fails.append('%s 的源文件未标记已实装：%s' % (quest['id'], path))
    epic = [r for r in catalog['quests'] if r['grade'] == '[epic]']
    done = sum(1 for r in epic if r['implemented'])
    print('[QUESTS] 总账 %d 条（失败 %d），已实装 %d 条'
          % (catalog['summary']['total'], catalog['summary']['failed'], catalog['summary']['implemented']))
    print('[QUESTS] 剧情主线 epic：%d / %d' % (done, len(epic)))
    for group, total in list(catalog['summary']['groups'].items())[:8]:
        rows = [r for r in catalog['quests'] if r['group'] == group]
        print('  %-26s %4d 条，已实装 %d' % (group, total, sum(1 for r in rows if r['implemented'])))
    if fails:
        print('\n[QUESTS] FAIL %d' % len(fails))
        for line in fails:
            print('  - ' + line)
        return 1
    print('\n[QUESTS] OK 总账与已实装任务一致')
    return 0


if __name__ == '__main__':
    sys.exit(main())
