"""Build a read-only content ledger from the shared extraction library.

Scope: the library is built from the ``111Script.pvf`` backup (E-FILE). This tool
indexes the archive's LST tables and checks whether every path entry resolves to a
file inside the same archive (E-PARSE). It is a ledger of what the backup contains,
not proof of the runtime-effective PVF, and not a statement that any entry is enabled
in the target client version; see docs/design/26_DNF原版拆解_证据与版本.md.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

import dnf_pvf as pvf

LEDGER_SCHEMA = 'dnf_content_ledger/1'
DATA_SUFFIXES = ('.chr', '.mob', '.map', '.dgn', '.equ', '.stk', '.skl', '.atk', '.ani',
                 '.ui', '.npc', '.qst', '.act', '.obj', '.til', '.ai', '.als', '.etc',
                 '.key', '.apd', '.img', '.rep', '.ptl', '.cre', '.nut', '.msn')


def extension_stats(lib: pvf.Library) -> list[dict]:
    rows = lib.db.execute(
        'select extension, count(*), sum(length(content)) from files group by extension '
        'order by count(*) desc').fetchall()
    return [{'extension': str(ext or ''), 'files': int(n), 'bytes': int(size or 0)}
            for ext, n, size in rows]


def _looks_like_paths(values: list[str]) -> bool:
    probe = [str(v).lower() for v in values[:10]]
    return bool(probe) and sum(v.endswith(DATA_SUFFIXES) for v in probe) >= max(1, len(probe) // 2)


def lst_entry_stats(lib: pvf.Library) -> list[dict]:
    """Classify every LST table and resolve the path-indexed ones."""
    out: list[dict] = []
    rows = lib.db.execute("select path, content from files where path like '%.lst' order by path").fetchall()
    for path, content in rows:
        try:
            entries = pvf.parse_list(content, lib.strings)
        except Exception as exc:  # noqa: BLE001 - report, never drop silently
            out.append({'lst': path, 'kind': 'error', 'entries': 0, 'resolved': 0, 'missing': 0,
                        'refs_per_file': 0, 'error': f'{type(exc).__name__}: {exc}',
                        'missing_samples': []})
            continue
        values = [str(v) for v in entries.values()]
        if not entries and content:
            # parse_list understands ``id -> string``; some tables use other layouts.
            out.append({'lst': path, 'kind': 'other_layout', 'entries': 0, 'bytes': len(content),
                        'resolved': 0, 'missing': 0, 'refs_per_file': 0, 'missing_samples': []})
            continue
        if not _looks_like_paths(values):
            # Display-name / id tables (itemname.lst, ...): their values are text, not paths.
            out.append({'lst': path, 'kind': 'name_table', 'entries': len(entries),
                        'resolved': 0, 'missing': 0, 'refs_per_file': 0, 'missing_samples': []})
            continue
        resolved = 0
        missing: list[str] = []
        targets: dict[str, int] = {}
        for rel in values:
            target = pvf.resolve(path, rel)
            targets[target] = targets.get(target, 0) + 1
            if lib.exists(target):
                resolved += 1
            elif len(missing) < 12:
                missing.append(rel)
        out.append({'lst': path,
                    'kind': 'path_index',
                    'entries': len(entries),
                    'resolved': resolved,
                    'missing': len(entries) - resolved,
                    'refs_per_file': round(len(entries) / max(1, len(targets)), 2),
                    'missing_samples': missing})
    return out


def index_coverage(lib: pvf.Library, lst: list[dict]) -> list[dict]:
    """Files per extension that no path-index table reaches.

    Only extensions with an owning LST table are reported. Unreferenced is not invalid:
    ``.map``/``.obj``/``.skl`` may be reached from scripts, alternate versions or unused
    content, so this is a candidate list for T1 classification, not a defect list.
    """
    refs: dict[str, set[str]] = {}
    for row in lst:
        if row['kind'] != 'path_index':
            continue
        for rel in lib.listing(row['lst']).values():
            target = pvf.resolve(row['lst'], str(rel))
            refs.setdefault(Path(target).suffix, set()).add(target)
    out: list[dict] = []
    for ext in ('.map', '.obj', '.equ', '.stk', '.chr', '.mob', '.skl', '.qst', '.npc', '.dgn'):
        files = {path for (path,) in lib.db.execute('select path from files where extension=?', (ext,))}
        reachable = files & refs.get(ext, set())
        out.append({'extension': ext, 'files': len(files), 'indexed': len(reachable),
                    'unindexed': len(files) - len(reachable)})
    return out


def dungeon_entries(lib: pvf.Library) -> list[dict]:
    """DGN records reachable from ``dungeon/dungeon.lst`` with their size grid."""
    out: list[dict] = []
    for index, rel in sorted(lib.listing('dungeon/dungeon.lst').items(), key=lambda kv: kv[0]):
        path = pvf.resolve('dungeon/dungeon.lst', str(rel))
        if not lib.exists(path):
            out.append({'id': index, 'path': path, 'exists': False})
            continue
        script = lib.script(path, 'dgn') or {}
        fields = script.get('fields', [])
        size = pvf.first_values(fields, '[size]') or []
        greed = pvf.first_values(fields, '[greed]') or []
        rows = [line for line in ''.join(greed).replace('\r', '').split('\n') if line.strip()]
        out.append({'id': index, 'path': path, 'exists': True,
                    'sha256': script.get('sha256', ''), 'grid': size, 'room_rows': len(rows)})
    return out


def multi_version(lib: pvf.Library) -> dict:
    """Duplicate-path records reported by the extraction library itself."""
    path = lib.path / '同路径多版本.json'
    if not path.is_file():
        return {'available': False}
    raw = json.loads(path.read_text(encoding='utf-8'))
    return {'available': True, 'entries': len(raw) if isinstance(raw, (list, dict)) else 0}


def build(lib: pvf.Library) -> dict:
    lst = lst_entry_stats(lib)
    dungeons = dungeon_entries(lib)
    path_tables = [row for row in lst if row['kind'] == 'path_index']
    return {
        'schema': LEDGER_SCHEMA,
        'asset_version': lib.asset_version,
        'library': str(lib.path),
        'config_role': '111Script.pvf backup in the shared library; runtime-effective PVF unconfirmed',
        'evidence_class': 'E-FILE / E-PARSE',
        'files': lib.db.execute('select count(*) from files').fetchone()[0],
        'extensions': extension_stats(lib),
        'index_coverage': index_coverage(lib, lst),
        'lst': lst,
        'totals': {
            'lst_tables': len(lst),
            'path_tables': len(path_tables),
            'name_tables': sum(1 for row in lst if row['kind'] == 'name_table'),
            'other_layout': sum(1 for row in lst if row['kind'] == 'other_layout'),
            'path_entries': sum(row['entries'] for row in path_tables),
            'resolved': sum(row['resolved'] for row in path_tables),
            'missing': sum(row['missing'] for row in path_tables),
        },
        'dungeons': {'total': len(dungeons),
                     'missing': sum(1 for d in dungeons if not d['exists']),
                     'entries': dungeons},
        'multi_version': multi_version(lib),
    }


def summarize(ledger: dict) -> str:
    totals = ledger['totals']
    lines = [f"asset_version={ledger['asset_version']} files={ledger['files']}",
             f"library={ledger['library']}",
             f"lst_tables={totals['lst_tables']} path_tables={totals['path_tables']} "
             f"name_tables={totals['name_tables']} other_layout={totals['other_layout']}",
             f"path_entries={totals['path_entries']} resolved={totals['resolved']} "
             f"missing={totals['missing']}"]
    for row in sorted((r for r in ledger['lst'] if r['kind'] == 'path_index'),
                      key=lambda r: r['entries'], reverse=True)[:14]:
        lines.append(f"  {row['lst']:44} entries={row['entries']:6} resolved={row['resolved']:6} "
                     f"missing={row['missing']:5} refs/file={row['refs_per_file']}")
    dungeons = ledger['dungeons']
    lines.append(f"dungeons={dungeons['total']} missing_dgn={dungeons['missing']}")
    coverage = ', '.join(f"{row['extension']} {row['indexed']}/{row['files']}"
                         for row in ledger['index_coverage'])
    lines.append('index coverage: ' + coverage)
    return '\n'.join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--library', type=Path, help='shared extraction library directory')
    parser.add_argument('--out', type=Path, default=Path('temp/dnf_content_ledger/ledger.json'))
    args = parser.parse_args(argv)
    lib = pvf.open_library(args.library)
    ledger = build(lib)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(ledger, ensure_ascii=False, indent=1), encoding='utf-8')
    print(summarize(ledger))
    print(f"written {args.out}")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
