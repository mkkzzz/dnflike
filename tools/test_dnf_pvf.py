"""Unit tests for tools/dnf_pvf.py and the compiler's field decoding (synthetic streams, no library)."""
from __future__ import annotations

import struct
import unittest

from audit_dnf_design import Strings
from dnf_pvf import canonical, parse_list, parse_script, resolve
from compile_dnf_content import decode_fields


def string_table(values):
    encoded = [s.encode('cp949') for s in values]
    offsets, cursor = [], 4 * (len(values) + 1)
    for value in encoded:
        offsets.append(cursor)
        cursor += len(value)
    offsets.append(cursor)
    return struct.pack('<I', len(values)) + struct.pack('<' + 'I' * len(offsets), *offsets) + b''.join(encoded)


def tok(kind, number):
    return bytes([kind]) + (struct.pack('<f', number) if kind == 4 else struct.pack('<i', number))


class Builder:
    def __init__(self):
        self.names: list[str] = []
        self.body = b''

    def idx(self, s):
        if s not in self.names:self.names.append(s)
        return self.names.index(s)

    def tag(self, s):
        self.body += tok(5, self.idx(s))
        return self

    def int(self, v):
        self.body += tok(2, v)
        return self

    def float(self, v):
        self.body += tok(4, v)
        return self

    def str(self, s):
        self.body += tok(7, self.idx(s))
        return self

    def build(self):
        return b'\xb0\xd0' + self.body, Strings(string_table(self.names))


class PvfStructure(unittest.TestCase):
    def test_enum_slots_attach_to_parent_and_aliases_normalize(self):
        content, strings = (Builder().tag('[attack type]').tag('[physic]').tag('[push aside]').int(30)
                            .tag('[attack direction]').tag('[hit horizono]')
                            .tag('[hit info]').tag('[blow]').tag('[no blood]').int(200).float(1.0)).build()
        fields = parse_script(content, strings, 'atk')['fields']
        self.assertEqual([f['tag'] for f in fields], ['[attack type]', '[push aside]', '[attack direction]', '[hit info]'])
        self.assertEqual(fields[0]['enum'][0]['canonical'], '[physic]')
        self.assertEqual(fields[2]['enum'][0]['raw' if False else 'tag'], '[hit horizono]')
        self.assertEqual(fields[2]['enum'][0]['canonical'], '[hit horizon]')
        self.assertEqual([e['tag'] for e in fields[3]['enum']], ['[blow]', '[no blood]'])
        self.assertEqual(fields[3]['enum'][1]['values'][0], 200)

    def test_sections_nest_and_unmatched_closes_are_reported(self):
        content, strings = (Builder().tag('[dungeon]').tag('[consume MP]').int(6).int(40).tag('[cool time]').int(2000)
                            .tag('[/dungeon]').tag('[pvp]').tag('[cool time]').int(3000).tag('[/pvp]').tag('[/ghost]')).build()
        parsed = parse_script(content, strings, 'skl')
        dungeon, pvp = parsed['fields']
        self.assertEqual([c['tag'] for c in dungeon['children']], ['[consume MP]', '[cool time]'])
        self.assertEqual(pvp['children'][0]['values'], [3000])
        self.assertEqual(parsed['diagnostics'][0]['code'], 'unmatched_close')

    def test_skill_context_decodes_per_mode_without_mixing(self):
        content, strings = (Builder().tag('[dungeon]').tag('[cool time]').int(2000).tag('[/dungeon]')
                            .tag('[pvp]').tag('[cool time]').int(3000).tag('[/pvp]').tag('[mystery]').int(1)).build()
        decoded, evidence, unsupported = decode_fields('skl', parse_script(content, strings, 'skl')['fields'], 'skill/x/a.skl')
        self.assertEqual(decoded['dungeon']['cool_time'], [2000])
        self.assertEqual(decoded['pvp'], {'present': True})
        self.assertEqual([u['tag'] for u in unsupported], ['[mystery]'])

    def test_atk_decoding_marks_alias_use_as_inferred(self):
        content, strings = (Builder().tag('[push aside]').int(40).tag('[lift up]').int(300)
                            .tag('[elemental property]').tag('[warter element]')).build()
        decoded, evidence, _ = decode_fields('atk', parse_script(content, strings, 'atk')['fields'], 'a.atk')
        self.assertEqual((decoded['push_aside'], decoded['lift_up']), (40, 300))
        self.assertEqual(decoded['element'][0]['value'], '[water element]')
        self.assertEqual(evidence['element'], 'E-INFER')
        self.assertEqual(evidence['push_aside'], 'E-PARSE')

    def test_character_stat_groups_and_paths(self):
        content, strings = (Builder().tag('[initial value]').tag('[HP MAX]').float(180.0).tag('[jump power]').float(430.0)
                            .tag('[attack info]').str('AttackInfo/Attack1.atk').str('AttackInfo/Attack2.atk').tag('[/attack info]')).build()
        decoded, _, unsupported = decode_fields('chr', parse_script(content, strings, 'chr')['fields'], 'character/swordman/swordman.chr')
        self.assertEqual(decoded['stat_groups']['initial_value']['hp_max'], 180.0)
        self.assertEqual(decoded['attack_infos'], ['character/swordman/attackinfo/attack1.atk', 'character/swordman/attackinfo/attack2.atk'])
        self.assertEqual(unsupported, [])

    def test_list_and_path_resolution(self):
        content, strings = Builder().int(46).str('Swordman/UpperSlash.skl').int(47).str('Swordman/Guard.skl').build()
        self.assertEqual(parse_list(content, strings), {46: 'Swordman/UpperSlash.skl', 47: 'Swordman/Guard.skl'})
        self.assertEqual(resolve('monster/goblin/action_goblin/attack1.act', '../Animation_Kinol/Attack1.ani'),
                         'monster/goblin/animation_kinol/attack1.ani')
        self.assertEqual(canonical('[noblood]'), '[no blood]')


if __name__ == '__main__':
    unittest.main()
