"""Build the original PTL catalog with separate axes and lossless source fields.

Native reader 0x1310C60 distinguishes three axes and global parameters. This
catalog preserves decoded values, ordered raw fields, hashes and unsupported
fields; it does not certify units, object parameters or rendered behaviour.
"""
from __future__ import annotations

import argparse
import json
import hashlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dnf_pvf as P
from dnf_particle_fields import decode_particle_fields

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / 'game_dnf'
OUT = GAME / 'assets_local/content/particles.json'
def parse(path: str, doc: dict) -> dict | None:
    fields = doc.get("fields") or []
    if not fields:
        return None
    decoded, evidence, unsupported = decode_particle_fields(fields, path)
    entry = {"ptl": path, "sha256": doc.get("sha256"), "decoded": decoded,
             "raw": fields, "evidence": evidence, "unsupported": unsupported,
             "diagnostics": doc.get("diagnostics", [])}
    # Keep the established asset-baking dependency list, including duplicates.
    entry["animations"] = [item["path"] for item in decoded.get("object_entries", [])
                           if item["path"].endswith(".ani")]
    return entry


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--library', type=Path, default=None)
    parser.add_argument('--limit', type=int, default=0)
    args = parser.parse_args()
    lib = P.open_library(args.library)
    result: dict[str, dict] = {}
    failures = []
    animations: set[str] = set()
    try:
        rows = [r[0] for r in lib.db.execute(
            "select path from files where path like '%.ptl' order by path")]
        if args.limit:
            rows = rows[:args.limit]
        for path in rows:
            try:
                doc = lib.script(path)
            except Exception as exc:
                failures.append({"path": path, "reason": str(exc)})
                continue
            entry = parse(path, doc) if doc else None
            if entry is None:
                failures.append({"path": path, "reason": "empty field tree"})
                continue
            result[path] = entry
            animations.update(entry.get('animations') or [])
    finally:
        lib.close()
    meta = {
        'schema': 'dnf_particles/2',
        'source_asset_version': lib.asset_version,
        'extractor_sha256': hashlib.sha256(b''.join((ROOT/'tools'/name).read_bytes().replace(b'\r\n', b'\n') for name in ['build_dnf_particles.py','dnf_particle_fields.py','dnf_pvf.py'])).hexdigest(),
        'evidence': 'Native 0x1310C60: independent XYZ movement fields; ordered object path/int list; raw values retained',
        'count': len(result), 'failed': len(failures), 'failures': failures,
        'animations': len(animations),
    }
    # One stable line per original definition; readable diffs without repeating
    # indentation for every raw token in the full archive.
    header = json.dumps(meta, ensure_ascii=False, indent=1)[:-2]
    lines = [header+',', ' "particles": {']
    entries = list(result.items())
    for index, (path, entry) in enumerate(entries):
        lines.append('  '+json.dumps(path, ensure_ascii=False)+': '+json.dumps(entry, ensure_ascii=False, separators=(',', ':'))+(',' if index+1<len(entries) else ''))
    lines.extend([' }', '}'])
    OUT.write_text('\n'.join(lines)+'\n', encoding='utf8', newline='\n')
    with_move = sum(1 for v in result.values() if v['decoded'].get('axes'))
    print('[PTL] 提取 %d 个定义（失败 %d），含分轴运动字段 %d，引用 ANI %d 个'
          % (len(result), len(failures), with_move, len(animations)))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
