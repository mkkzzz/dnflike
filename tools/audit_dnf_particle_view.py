"""Reproduce bounded disassembly evidence for ANI flags and particle lifetime.

Exact verified engine only. No PE execution, host calls or symbolic branch
claims: these are selected source blocks with hashes and decoded instructions.
Protected control-flow links are explained separately in the source report.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys

from audit_dnf_particle_axis import AxisEvaluator
from audit_dnf_native_strings import ENGINE_SHA, recover_string

BLOCKS = [
    ('ANI default: loop=0, other flag=1', 0x1093FC4, 0x1093FCF),
    ('binary global tag dispatch and writes', 0x10943C8, 0x1094405),
    ('LOOP text registration', 0x1095706, 0x1095760),
    ('LOOP text numeric value', 0x1095EB3, 0x1095ED0),
    ('ANI last-frame stop versus restart', 0x108E5D8, 0x108E637),
    ('particle ANI object constructor arguments', 0xE4E662, 0xE4E6B8),
    ('particle motion and follow controller', 0xE4E7FE, 0xE4E855),
    ('animation object constructor forwarding', 0x406CB0, 0x406CF0),
    ('auto-delete argument stored at +179', 0x7F12A8, 0x7F12BA),
    ('motion alive call', 0x2242579, 0x2242588),
    ('motion alive getter', 0x61B540, 0x61B550),
    ('auto-delete flag branch', 0x2226217, 0x2226224),
    ('object alive setter', 0xA10630, 0xA10640),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('client', type=Path)
    parser.add_argument('--decoder-dir', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.client.resolve() == args.output.resolve():
        raise ValueError('Output cannot replace the source client')
    if args.decoder_dir:
        sys.path.insert(0, str(args.decoder_dir.resolve()))
    reader = AxisEvaluator(args.client.read_bytes())
    rows = []
    for label, start, end in BLOCKS:
        raw = reader.source_bytes(start, end-start)
        instructions = list(reader.decoder.disasm(raw, start))
        if sum(i.size for i in instructions) != len(raw):
            raise ValueError(f'Incomplete instruction span: {label}')
        rows.append({'label': label, 'start': hex(start), 'end_exclusive': hex(end),
                     'sha256': hashlib.sha256(raw).hexdigest(),
                     'instructions': [f'{i.address:08X} {i.mnemonic} {i.op_str}' for i in instructions]})
    # Exact switch table binds global numeric tags to the field write branches.
    targets = [hex(struct.unpack('<I', reader.source_bytes(
        0x1094FD0 + reader.source_bytes(0x1094FEC+i, 1)[0]*4, 4))[0]) for i in range(30)]
    text, _ = recover_string(reader.source_bytes(0x182439C, 64), 0, 2)
    assert text == '[LOOP]' and targets[:2] == ['0x10943e2', '0x10943ed']
    output = {'schema': 'dnf_native_particle_view_evidence/1', 'engine_sha256': ENGINE_SHA,
              'method': 'bounded static disassembly; not client execution or a complete control-flow proof',
              'loop_text': text, 'global_tag_targets': targets, 'blocks': rows}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, indent=1)+'\n', encoding='utf8', newline='\n')
    print(f'[PARTICLE_VIEW_EVIDENCE] Decoded {len(rows)} source blocks; loop tag 0 verified')


if __name__ == '__main__':
    main()
