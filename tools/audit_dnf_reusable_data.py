"""Read-only audit/export of Chinese text and numeric IDs in the archived PVF.

The .kor.str suffix is not a language detector. Resolve type 9 (table ID) plus
type 10 (string-table key index), or decode direct string bytes as CP950. Never
join different archives by string index. Outputs are evidence, not enabled data.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import re
import struct

from dnf_pvf import open_library, resolve

ROOT = Path(__file__).resolve().parents[1]
KEY = re.compile(r'^([A-Za-z0-9_]+)>(.*)$')
FIELDS = {'[name]', '[explain]', '[basic explain]', '[detail explain]', '[flavor text]',
          '[depend message]', '[condition message]', '[solve message]', '[dialog]'}
BAD = re.compile(r'[\u1100-\u11ff\u3130-\u318f\uac00-\ud7ff\ue000-\uf8ff\ufffd]')


def string_bytes(strings, index):
    if not 0 <= index < strings.count:
        raise ValueError('String index out of bounds')
    start, end = struct.unpack_from('<2I', strings.content, 4 + index * 4)
    if not strings.table_end <= start + 4 <= end + 4 <= len(strings.content):
        raise ValueError('String span out of bounds')
    return strings.content[start + 4:end + 4]


def decode_text(raw, encoding='cp950'):
    text = raw.decode(encoding, errors='strict')
    if text.encode(encoding) != raw:
        raise ValueError(encoding + ' round trip mismatch')
    return text


def parse_table(raw, encoding='cp950'):
    text = decode_text(raw, encoding)
    table, duplicates, key = {}, [], None
    # CRCRLF occurs in these files; splitting on LF preserves actual line numbers.
    for line_number, line in enumerate(text.split('\n'), 1):
        line = line.rstrip('\r')
        match = KEY.match(line)
        if match:
            key = match[1]
            if key in table:
                duplicates.append(key)
                # Keep the first occurrence and make ambiguity visible.
                key = None
                continue
            table[key] = {'text': match[2], 'line': line_number}
        elif key is not None:
            table[key]['text'] += '\n' + line
    for entry in table.values():
        entry['text'] = entry['text'].strip()
    return table, duplicates


class TextResolver:
    def __init__(self, lib, encoding='cp950'):
        self.lib = lib
        self.encoding = encoding
        self.links = lib.listing('n_string.lst')
        self.tables = {}
        self.sources = {}

    def table(self, table_id):
        path = self.links[table_id].replace('\\', '/').lower()
        if path not in self.tables:
            raw, sha = self.lib.raw(path)
            entries, duplicates = parse_table(raw, self.encoding)
            self.tables[path] = entries
            self.sources[path] = {'sha256': sha, 'encoding': self.encoding,
                                  'round_trip': True, 'entries': len(entries),
                                  'duplicate_keys': duplicates}
        return path, self.tables[path]

    def fields(self, raw):
        if not raw.startswith(b'\xb0\xd0') or (len(raw) - 2) % 5:
            raise ValueError('Not an aligned B0D0 script')
        result, field, pending = {}, None, None
        for kind, value in struct.iter_unpack('<Bi', raw[2:]):
            if kind == 5:
                field = string_bytes(self.lib.strings, value).decode('ascii', 'replace')
                pending = None
                continue
            if field not in FIELDS:
                continue
            if kind == 9:
                pending = value
                continue
            if kind == 10 and pending is not None:
                path, table = self.table(pending)
                key = string_bytes(self.lib.strings, value).decode('ascii')
                entry = table.get(key)
                text = entry['text'] if entry else ''
                record = {'text': text, 'table': path, 'table_id': pending,
                          'key': key, 'line': entry['line'] if entry else None,
                          'missing': entry is None}
            elif kind in (6, 7, 8):
                try:
                    text = decode_text(string_bytes(self.lib.strings, value), self.encoding)
                    record = {'text': text, 'string_index': value, 'encoding': self.encoding}
                except (UnicodeError, ValueError) as exc:
                    record = {'text': '', 'string_index': value, 'error': str(exc)}
            else:
                pending = None
                continue
            record['needs_review'] = bool(BAD.search(record['text']))
            result.setdefault(field, []).append(record)
            pending = None
        return result


def audit(lib, encoding='cp950'):
    resolver = TextResolver(lib, encoding)
    ids = defaultdict(list)
    indices = {}
    for listing in ['n_quest/quest.lst', 'equipment/equipment.lst', 'stackable/stackable.lst']:
        rows = lib.listing(listing)
        missing = 0
        for number, path in rows.items():
            target = resolve(listing, path)
            ids[target].append({'list': listing, 'id': number})
            missing += not lib.exists(target)
        indices[listing] = {'ids': len(rows), 'missing_files': missing}
    summary, records, failures = defaultdict(Counter), [], []
    scripts = lib.scripts() if hasattr(lib, 'scripts') else lib.db.execute(
        "select path,content,sha256,crc_ok from files where extension in ('.qst','.equ','.stk') order by path")
    for path, raw, sha, crc_ok in scripts:
        kind = Path(path).suffix[1:]
        counts = summary[kind]
        counts['total'] += 1
        counts['indexed'] += bool(ids.get(path))
        counts['crc_failed'] += not bool(crc_ok)
        try:
            fields = resolver.fields(raw)
        except (ValueError, UnicodeError, KeyError, TypeError) as exc:
            failures.append({'path': path, 'error': str(exc)})
            continue
        names = fields.get('[name]', [])
        counts['name_resolved'] += bool(names and names[0]['text'])
        counts['name_needs_review'] += bool(names and names[0]['needs_review'])
        counts['condition_resolved'] += bool(fields.get('[condition message]', [{}])[0].get('text'))
        counts['solve_resolved'] += bool(fields.get('[solve message]', [{}])[0].get('text'))
        counts['explain_resolved'] += bool(fields.get('[explain]', [{}])[0].get('text'))
        for values in fields.values():
            counts['missing_text_links'] += sum(v.get('missing', False) for v in values)
            counts['text_decode_errors'] += sum('error' in v for v in values)
        records.append({'path': path, 'source_ids': ids.get(path, []), 'sha256': sha,
                        'crc_ok': bool(crc_ok), 'fields': fields})
    return {'schema': 'dnf_reusable_text_audit/1',
            'scope': 'source_file_evidence_not_verified_runtime_or_60_level_whitelist',
            'summary': dict(summary), 'indices': indices, 'text_sources': resolver.sources,
            'failures': failures, 'records': records}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path)
    parser.add_argument('--pvf', type=Path, help='Read a standard PVF directly; never modifies it')
    parser.add_argument('--encoding', choices=['cp950', 'gb18030'], default='cp950')
    parser.add_argument('--output', type=Path, default=ROOT / 'temp/reusable_data/text_audit.json')
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.is_relative_to((ROOT / 'temp').resolve()):
        parser.error('Generated evidence must stay in temp/')
    if args.pvf and args.library:
        parser.error('Choose either --pvf or --library')
    if args.pvf:
        from dnf_pvf_archive import Archive
        lib = Archive(args.pvf)
    else:
        lib = open_library(args.library)
    try:
        result = audit(lib, args.encoding)
        source_path = args.pvf if args.pvf else lib.db_path
        with source_path.open('rb') as source:
            result['source'] = {'name': source_path.name, 'sha256': hashlib.file_digest(source, 'sha256').hexdigest(),
                                'kind': 'pvf' if args.pvf else 'extraction_database', 'encoding': args.encoding}
    finally:
        lib.close()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    print(json.dumps({k: v for k, v in result.items() if k not in ['records', 'text_sources']},
                     ensure_ascii=False, indent=2))
    print('OUTPUT', output)


if __name__ == '__main__':
    main()
