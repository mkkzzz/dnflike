"""Read-only native PE inventory and CRC-verified Swordman client/backup comparison.

Does not launch executables, rewrite archives, or call compiled code 'source'.
Finds embedded PE resource payloads so the outer wrapper is not mistaken for the
game engine. Only resource names/PE structure and hashes are recorded.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import struct

from dnf_pvf_archive import Archive, compare_indexed_payloads, indexed_payload_mask

ROOT = Path(__file__).resolve().parents[1]


def pe_inventory(raw):
    if len(raw) < 64 or raw[:2] != b'MZ':
        raise ValueError('Not a PE image')
    pe = struct.unpack_from('<I', raw, 60)[0]
    if raw[pe:pe+4] != b'PE\0\0':
        raise ValueError('Missing PE signature')
    machine, count = struct.unpack_from('<HH', raw, pe+4)
    optional_size = struct.unpack_from('<H', raw, pe+20)[0]
    sections = []
    for i in range(count):
        offset = pe+24+optional_size+i*40
        name = raw[offset:offset+8].rstrip(b'\0').decode('ascii', errors='replace')
        virtual_size, rva, size, file_offset = struct.unpack_from('<4I', raw, offset+8)
        if file_offset+size > len(raw):
            raise ValueError('Section outside file')
        sections.append(dict(name=name, rva=rva, virtual_size=virtual_size, bytes=size, offset=file_offset))
    return {'sha256': hashlib.sha256(raw).hexdigest(), 'bytes': len(raw), 'machine': machine, 'sections': sections}


def embedded_resources(raw):
    outer = pe_inventory(raw)
    pe = struct.unpack_from('<I', raw, 60)[0]
    magic = struct.unpack_from('<H', raw, pe+24)[0]
    directory = pe+24+(112 if magic == 0x20b else 96)

    def file_offset(rva):
        for section in outer['sections']:
            if section['rva'] <= rva < section['rva']+section['bytes']:
                return section['offset']+rva-section['rva']
        raise ValueError('Resource RVA outside file-backed section')

    resource_rva, _ = struct.unpack_from('<II', raw, directory+16)
    if not resource_rva:
        return outer
    base = file_offset(resource_rva)
    payloads, visited = [], set()

    def walk(relative=0, chain=()):
        if relative in visited or len(chain) > 4:
            raise ValueError('Cyclic or overdeep resource directory')
        visited.add(relative)
        offset = base+relative
        named, ids = struct.unpack_from('<HH', raw, offset+12)
        for i in range(named+ids):
            key, value = struct.unpack_from('<II', raw, offset+16+8*i)
            if key >> 31:
                pos = base+(key & 0x7fffffff)
                length = struct.unpack_from('<H', raw, pos)[0]
                label = raw[pos+2:pos+2+length*2].decode('utf-16le')
            else:
                label = str(key)
            if value >> 31:
                walk(value & 0x7fffffff, chain+(label,))
            else:
                rva, size, _, _ = struct.unpack_from('<4I', raw, base+value)
                start = file_offset(rva)
                if start+size > len(raw):
                    raise ValueError('Resource outside file')
                body = raw[start:start+size]
                if body[:2] == b'MZ':
                    payloads.append({'resource': '/'.join(chain+(label,)), 'offset': start, **pe_inventory(body)})
    walk()
    outer['embedded_pe_resources'] = payloads
    return outer


def compare_skills(client, backup, matched_payloads=None):
    selected, failures, differences = [], [], []
    prefixes = ('skill/swordman/', 'character/swordman/', 'passiveobject/character/swordman/')
    suffixes = {'.skl', '.ani', '.atk', '.chr', '.obj', '.nut', '.act', '.ptl'}
    for path in sorted(set(client.entries) | set(backup.entries)):
        if not path.startswith(prefixes) or Path(path).suffix not in suffixes:
            continue
        try:
            current, previous = client.raw(path), backup.raw(path)
        except ValueError as error:
            failures.append({'path': path, 'reason': str(error)})
            continue
        selected.append(path)
        if not current or not previous or current[1] != previous[1]:
            differences.append({'path': path, 'client_sha256': current[1] if current else None,
                                'backup_sha256': previous[1] if previous else None})
        elif matched_payloads is not None:
            matched_payloads[path] = previous[0]
    return {'selected': len(selected), 'by_kind': dict(sorted(Counter(Path(p).suffix for p in selected).items())),
            'payload_crc_failures': failures, 'differences': differences}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--client-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT/'temp/skill_logic_audit/client_code.json')
    parser.add_argument('--record', action='append', default=[], help='Also compare this internal PVF path in all four archives')
    args = parser.parse_args()
    client_root = args.client_root/'情怀60复古'
    native = {name: embedded_resources((client_root/name).read_bytes()) for name in ('DNF.exe', '地下城与勇士.exe')}
    client = Archive(client_root/'ImagePacks2/Script.pvf', allow_known_client_transform=True)
    backup = Archive(args.client_root/'111Script.pvf')
    try:
        matched = {}
        comparison = compare_skills(client, backup, matched)
        requested = {}
        for name in args.record:
            name = name.replace('\\', '/').lower()
            if name == 'stringtable.bin':
                parser.error('stringtable.bin supplies the indexed payload anchor and is not an independent comparison')
            current, previous = client.raw(name), backup.raw(name)
            requested[name] = {'client_sha256': current[1] if current else None,
                               'backup_sha256': previous[1] if previous else None}
            if current and previous and current[1] == previous[1]:
                matched[name] = previous[0]
        stringtable = backup.raw('stringtable.bin')[0]
        mask = indexed_payload_mask(client_root/'Script.pvf', stringtable, max(map(len, matched.values()), default=0))
        indexed = {name: compare_indexed_payloads(client_root/name, mask, matched)
                   for name in ('Script.pvf', 'Video/Script.pvf')}
        result = {'schema': 'dnf_client_code_audit/2', 'effective_loaded_pvf': 'unconfirmed',
                  'native': native, 'directory_transform': client.directory_transform,
                  'comparison': comparison, 'additional_records': requested,
                  'indexed_content_comparison': indexed}
    finally:
        client.close()
        backup.close()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(result['comparison'], ensure_ascii=False))
    for name, audit in indexed.items():
        print(f'{name}: {audit["index_entries"]} entries, {len(audit["exact_content_matches"])} full payload matches, '
              f'{len(audit["without_exact_match"])} without a full match')
    print('Read-only native/PVF evidence: '+str(args.output))
    return 1 if (comparison['payload_crc_failures'] or comparison['differences'] or any(
        audit['without_exact_match'] for audit in indexed.values()) or any(
        not row['client_sha256'] or row['client_sha256'] != row['backup_sha256'] for row in requested.values()
    )) else 0


if __name__ == '__main__':
    raise SystemExit(main())
