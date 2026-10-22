"""Read-only design evidence audit; never execute clients or edit shared assets.

This inventories the archived backup, NOT the effective configuration of a running
client. Token decoding is structural: names/units/formulas remain unverified.
Raw token types 9/10 (localized string indirection) are deliberately preserved.
"""
from __future__ import annotations

import argparse
from collections import Counter
from contextlib import closing
import hashlib
import json
import math
from pathlib import Path
import sqlite3
import struct

from dnf_asset_store import ROOT, LOCK, cache_home

SAMPLES = [
    'character/swordman/swordman.chr',
    'character/swordman/attackinfo/attack1.atk',
    'character/swordman/attackinfo/attack3.atk',
    'skill/swordman/upperslash.skl',
    'skill/swordman/momentaryslash.skl',
    'monster/goblin/goblin.mob',
    'monster/goblin/action_goblin/attack1.act',
    'monster/goblin/attackinfo/attack1.atk',
    'monster/goblin/ai/action.ai',
    'dungeon/act1/lorien.dgn',
    'map/lorien/4.map',
]


def digest(path: Path) -> str:
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def connect_readonly(path: Path) -> sqlite3.Connection:
    return sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True)


class Strings:
    def __init__(self, content: bytes):
        if len(content) < 12:
            raise ValueError('Truncated string table')
        self.content = content
        self.count = struct.unpack_from('<I', content)[0]
        self.table_end = 4 + 4 * (self.count + 1)
        if self.table_end > len(content):
            raise ValueError('Truncated string offsets')

    def get(self, index: int) -> str:
        if not 0 <= index < self.count:
            raise ValueError('String index outside table')
        start, end = struct.unpack_from('<2I', self.content, 4 + index * 4)
        # Offsets are relative to byte 4, as verified against known ASCII tags.
        start += 4
        end += 4
        if not self.table_end <= start <= end <= len(self.content):
            raise ValueError('String span outside payload')
        return self.content[start:end].decode('cp949', errors='replace')


def decode_tokens(content: bytes, strings: Strings) -> dict:
    if not content.startswith(b'\xb0\xd0') or (len(content) - 2) % 5:
        raise ValueError('Not an aligned B0D0 token stream')
    tokens, fields, unknown = [], [], Counter()
    for offset in range(2, len(content), 5):
        kind = content[offset]
        raw = content[offset + 1:offset + 5]
        integer = struct.unpack('<i', raw)[0]
        token = {'offset': offset, 'type': kind, 'raw_hex': raw.hex()}
        if kind == 2:
            token['value'] = integer
        elif kind == 4:
            number = struct.unpack('<f', raw)[0]
            # JSON must remain interoperable for NaN/Infinity bit patterns.
            token['value'] = number if math.isfinite(number) else None
        elif kind in (5, 6, 7, 8):
            token['string_index'] = integer
            try:
                token['value'] = strings.get(integer)
            except ValueError as error:
                token['error'] = str(error)
        else:
            token['raw_int'] = integer
            token['interpretation'] = 'unresolved'
            unknown[str(kind)] += 1
        tokens.append(token)
        if kind == 5 and 'value' in token:
            fields.append({'tag': token['value'], 'offset': offset, 'values': []})
        elif fields:
            fields[-1]['values'].append(token)
    return {'interpretation': 'structural_only_not_runtime_semantics',
            'tokens': tokens, 'tag_spans': fields, 'unresolved_types': dict(unknown)}


def animation_summary(path: str, row: tuple) -> dict:
    status, metadata, error, sha256, crc_ok = row
    result = {'path': path, 'status': status, 'sha256': sha256,
              'crc_ok': bool(crc_ok), 'error': error}
    if not metadata:
        return result
    ani = json.loads(metadata)
    clock, attacks, tags = 0, [], Counter()
    for frame in ani['frames']:
        delay = frame.get('delay_ms')
        for tag in frame.get('items', {}):
            tags[tag] += 1
        boxes = [box['box'] for box in frame.get('boxes', []) if box['kind'] == 'attack']
        if boxes:
            attacks.append({'frame': frame['frame'], 'img_frame': frame['img_frame'],
                            'start_ms': clock, 'end_ms': clock + (delay or 0),
                            'boxes_raw': boxes})
        clock += delay or 0
    result.update(frame_count=ani['frame_count'], duration_ms=ani['duration_ms'],
                  missing_delay_frames=ani.get('missing_delay_frames'),
                  images=ani['images'], attack_frames=attacks,
                  frame_tags=dict(tags), global_items=ani.get('global_items', {}),
                  note='Empty attack_frames does not prove absence of an attack; inspect ACT/ATK/weapon dependencies.')
    return result


def audit(library: Path, client: Path | None = None) -> dict:
    lock = json.loads(LOCK.read_text(encoding='utf-8'))
    report = {'schema': 'dnf_design_evidence_audit/1', 'asset_version': lock['version'],
              'scope': 'archived_backup_not_verified_effective_runtime',
              'library': str(library), 'databases': {}, 'script_samples': [],
              'animation_samples': [], 'client_files': []}
    config_path, asset_path = library / 'pvf_config.sqlite', library / 'catalog.sqlite'
    for name, path in [('config', config_path), ('assets', asset_path)]:
        report['databases'][name] = {'sha256': digest(path), 'bytes': path.stat().st_size}
    with closing(connect_readonly(asset_path)) as assets:
        report['assets_by_kind'] = dict(assets.execute('select kind,count(*) from assets group by kind'))
        report['asset_validation'] = dict(assets.execute('select validation,count(*) from assets group by validation'))
        report['archive_problems'] = assets.execute('select count(*) from problems').fetchone()[0]
    with closing(connect_readonly(config_path)) as config:
        report['files_by_extension'] = dict(config.execute('select extension,count(*) from files group by extension'))
        report['animation_status'] = dict(config.execute('select status,count(*) from animations group by status'))
        report['crc_status'] = {str(k): v for k, v in config.execute('select crc_ok,count(*) from files group by crc_ok')}
        report['reference_observations'] = {
            'images_zero_candidates': config.execute('select count(*) from image_references where candidates=0').fetchone()[0],
            'images_multiple_candidates': config.execute('select count(*) from image_references where candidates>1').fetchone()[0],
            'images_no_in_range_candidate': config.execute('select count(*) from image_references where frame_range_ok=0').fetchone()[0],
            'sounds_zero_candidates': config.execute('select count(*) from sound_references where candidates=0').fetchone()[0],
            'meaning': 'Archive cross-reference observations; not counts of broken playable content.'}
        content = config.execute("select content from files where path='stringtable.bin'").fetchone()[0]
        strings = Strings(content)
        report['strings'] = {'count': strings.count, 'encoding_policy': 'cp949_replace_as_existing_archive; localization_indirection_unresolved'}
        for path in SAMPLES:
            row = config.execute('select content,sha256,crc_ok from files where path=?', (path,)).fetchone()
            if row is None:
                report['script_samples'].append({'path': path, 'error': 'absent'})
                continue
            sample = {'path': path, 'sha256': row[1], 'crc_ok': bool(row[2]),
                      'payload_sha256_matches': hashlib.sha256(row[0]).hexdigest() == row[1]}
            try:
                sample.update(decode_tokens(row[0], strings))
            except ValueError as error:
                sample['error'] = str(error)
            report['script_samples'].append(sample)
        for path in ['character/swordman/animation/' + name + '.ani' for name in
                     ['attack1', 'attack2', 'attack3', 'momentaryslash', 'triplestab']] + [
                         'monster/goblin/animation_goblin/attack1.ani']:
            row = config.execute('select a.status,a.metadata,a.error,f.sha256,f.crc_ok from animations a join files f on f.path=a.path where a.path=?', (path,)).fetchone()
            if row:
                report['animation_samples'].append(animation_summary(path, row))
    report['config_provenance'] = json.loads((library / 'config_summary.json').read_text(encoding='utf-8'))
    report['current_adaptation'] = json.loads((ROOT / 'game_dnf/data/combat.json').read_text(encoding='utf-8'))
    report['implementation_sha256'] = {p.relative_to(ROOT).as_posix(): digest(p) for p in
        [ROOT / 'tools/build_dnf_assets.py', ROOT / 'game_dnf/data/combat.json'] + sorted((ROOT / 'game_dnf/scripts').glob('*.gd'))}
    if client:
        for role, path in [('client_root_pvf', client / 'Script.pvf'),
                           ('imagepacks_pvf', client / 'ImagePacks2/Script.pvf'),
                           ('adjacent_backup_pvf', client.parent / '111Script.pvf')]:
            entry = {'role': role, 'exists': path.is_file()}
            if path.is_file():
                with path.open('rb') as source:
                    header = source.read(32)
                entry.update(bytes=path.stat().st_size, sha256=digest(path), header_hex=header.hex())
            report['client_files'].append(entry)
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path)
    parser.add_argument('--client', type=Path, help='Optional client directory for PVF fingerprints only')
    parser.add_argument('--output', type=Path, default=ROOT / 'temp/dnf_design_audit/audit.json')
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.is_relative_to((ROOT / 'temp').resolve()):
        parser.error('Generated audit must be under this checkout temp directory')
    lock = json.loads(LOCK.read_text(encoding='utf-8'))
    library = args.library or cache_home() / lock['version'] / 'library_v1'
    result = audit(library.resolve(), args.client.resolve() if args.client else None)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False) + '\n', encoding='utf-8')
    print(json.dumps({'output': str(output), 'files': sum(result['files_by_extension'].values()),
                      'script_samples': len(result['script_samples']),
                      'script_errors': sum('error' in s or any('error' in t for t in s.get('tokens', [])) for s in result['script_samples'])}, ensure_ascii=True))


if __name__ == '__main__':
    main()
