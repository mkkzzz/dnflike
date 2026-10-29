"""全量解析原版 .qst，生成任务总账（供后续逐章实装使用）。

输出 game_dnf/data/quest_catalog.json：
  summary  —— 总数、目录分布、grade/type 分布、待中文化条目数
  quests   —— 每条：路径、grade、等级区间、类型、发布/交付 NPC 索引、职业限制、奖励、名称引用、是否已实装

字段来自原版脚本（E-PARSE）。本总账保留本地化 name_ref，已实装项从运行表取中文名。
完整中文可由 audit_dnf_reusable_data.TextResolver 读取STR引用；未实装不代表无中文。

用法：python tools/build_dnf_quest_catalog.py [--library DIR]
"""
from __future__ import annotations

import argparse
import collections
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dnf_pvf as P

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / 'game_dnf'
OUT = GAME / 'data/quest_catalog.json'


def first(spans: dict, tag: str, default=None):
    item = spans.get(tag)
    if not item:
        return default
    values = item[0]
    return values[0] if values else default


def values_of(spans: dict, tag: str) -> list:
    item = spans.get(tag)
    return list(item[0]) if item else []


def name_ref(spans: dict) -> str:
    for ref in values_of(spans, '[name]'):
        if isinstance(ref, dict) and ref.get('link_type') == 10:
            return 'string:%s' % ref['raw']
    return ''


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path, default=None)
    args = parser.parse_args()
    implemented = {}
    quests_doc = json.loads((GAME / 'data/quests.json').read_text(encoding='utf-8'))
    native = json.loads((GAME / 'data/native_runtime.json').read_text(encoding='utf-8'))
    for quest in quests_doc['quests'] + native['quests']:
        source = quest.get('source') or {}
        path = str(source.get('path', '')).lower()
        if path:
            implemented[path] = {'id': quest['id'], 'name': quest.get('name', ''), 'category': quest.get('category', '')}
    lib = P.open_library(args.library)
    rows: list[dict] = []
    failed: list[dict] = []
    groups = collections.Counter()
    grades = collections.Counter()
    kinds = collections.Counter()
    try:
        paths = [r[0] for r in lib.db.execute("select path from files where path like '%.qst' order by path")]
        for path in paths:
            try:
                doc = lib.script(path)
            except Exception as exc:  # 解析失败要如实记录，不静默跳过
                failed.append({'path': path, 'error': str(exc)[:120]})
                continue
            spans: dict = {}
            for item in doc.get('fields') or []:
                spans.setdefault(item['tag'], []).append(item['values'])
            level = values_of(spans, '[level]')
            parts = path.split('/')
            group = '/'.join(parts[:2]) if len(parts) > 2 else parts[0]
            local = implemented.get(path.lower(), {})
            entry = {
                'path': path,
                'group': group,
                'grade': (first(spans, '[grade]') or ''),
                'type': (first(spans, '[type]') or ''),
                'sub_type': first(spans, '[sub type]'),
                'level_min': int(level[0]) if len(level) > 0 else None,
                'level_max': int(level[1]) if len(level) > 1 else None,
                'npc': first(spans, '[npc index]'),
                'complete_npc': first(spans, '[complete npc index]'),
                'job': (first(spans, '[job]') or ''),
                'grow_type': first(spans, '[grow type]'),
                'reward_type': (first(spans, '[reward type]') or ''),
                'reward': values_of(spans, '[reward int data]'),
                'name_ref': name_ref(spans),
                'implemented': bool(local),
                'local_id': local.get('id', ''),
                'local_name': local.get('name', ''),
            }
            grades[str(entry['grade'])] += 1
            kinds[str(entry['type'])] += 1
            groups[group] += 1
            rows.append(entry)
    finally:
        lib.close()
    pending = len({r['name_ref'] for r in rows if r['name_ref'] and not r['implemented']})
    catalog = {
        'schema': 'dnf_quest_catalog/1',
        'evidence': '原版 .qst 结构化字段 E-PARSE；名称/描述为本地化引用（string 键），正文未解出',
        'summary': {
            'total': len(rows),
            'implemented': sum(1 for r in rows if r['implemented']),
            'failed': len(failed),
            'pending_name_refs': pending,
            'groups': dict(groups.most_common()),
            'grades': dict(grades.most_common()),
            'types': dict(kinds.most_common(20)),
        },
        'failed': failed[:50],
        'quests': rows,
    }
    OUT.write_text(json.dumps(catalog, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    print('[QUEST_CATALOG] total=%d implemented=%d failed=%d pending_names=%d groups=%d'
          % (len(rows), catalog['summary']['implemented'], len(failed), pending, len(groups)))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
