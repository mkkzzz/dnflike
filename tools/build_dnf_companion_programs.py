"""Compile the original G.S.D. AIC, AI branches and key streams for APC 201/202."""
from __future__ import annotations

import argparse
import json
from pathlib import Path, PurePosixPath

from dnf_pvf import open_library, parse_script, resolve
from dnf_pvf_archive import Archive


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'game_dnf/data/companion_programs.json'
INDEX = 'aicharacter/aicharacter.lst'
IDS = (201, 202)
ENTRY_POINTS = ('event', 'destination', 'action', 'movement')
PREDICATES = {
    '[attack success]': ('int',),
    '[my attack]': ('int',),
    '[check use skill]': ('int',),
    '[check skill on]': ('int',),
    '[target state]': ('float',),
    '[target distance]': ('str', 'float'),
    '[void]': ('str', 'float', 'float', 'float', 'float'),
}


def source(library, path):
    raw = library.raw(path)
    if raw is None:
        raise ValueError('Missing companion source: ' + path)
    return {'path': path, 'sha256': raw[1]}


def script(library, path):
    doc = library.script(path)
    if doc is None or doc['diagnostics']:
        raise ValueError('Unreadable companion script: ' + path)
    return doc['fields']


def decision(node):
    tag = node['tag']
    values = node['values']
    if tag in ('[return]', '[import ai]') and len(values) == 1 and not node.get('children'):
        kind = node['types'][0]
        if tag == '[return]' and kind in ('int', 'str'):
            return {'return': values[0]}
        if tag == '[import ai]' and kind == 'str' and PurePosixPath(values[0]).name == values[0]:
            return {'import': values[0].lower()}
    if tag == '[think]' and not values:
        parts = node.get('children', [])
        if (len(parts) == 5 and [parts[i]['tag'] for i in (1, 3)] == ['[true]', '[false]']
                and not any(parts[i]['values'] or parts[i].get('children') for i in (1, 3))):
            predicate = parts[0]
            op = predicate['tag']
            args = predicate['values']
            if tuple(predicate['types']) != PREDICATES.get(op):
                raise ValueError('Unsupported APC predicate: ' + op)
            if op == '[void]' and args[0] != 'is target in attack area()':
                raise ValueError('Unsupported APC function: ' + args[0])
            if op == '[target distance]' and args[0] != '>=':
                raise ValueError('Unsupported APC distance comparison: ' + args[0])
            return {'if': [op, *args], 'then': decision(parts[2]), 'else': decision(parts[4])}
    raise ValueError('Unsupported APC branch: ' + tag)


def compile_ai(library, path, programs, streams, active):
    if path in active:
        raise ValueError('Recursive APC import: ' + path)
    if path in programs:
        return
    fields = script(library, path)
    if len(fields) != 1 or fields[0]['tag'] != '[ai pattern]' or len(fields[0].get('children', [])) != 1:
        raise ValueError('Unsupported APC AI root: ' + path)
    tree = decision(fields[0]['children'][0])

    def validate(node):
        if 'if' in node:
            validate(node['then'])
            validate(node['else'])
        if 'import' in node:
            compile_ai(library, resolve(path, node['import']), programs, streams, active | {path})
        if isinstance(node.get('return'), str) and node['return'] not in streams:
            raise ValueError('Missing APC key stream: ' + node['return'])

    validate(tree)
    programs[path] = {'source': source(library, path), 'decision': tree}


def compile_stream(library, path):
    entries = script(library, path)
    if not entries:
        raise ValueError('Empty APC key stream: ' + path)
    for entry in entries:
        tag, values = entry['tag'], entry['values']
        if tag == '[input]' and not values:
            continue  # Original stream block delimiter, retained in the artifact.
        if (tag not in ('[input]', '[state check]') or entry['types'] != ['str', 'int', 'str', 'int']
                or values[2] != 'time' or values[1] < 0 or values[3] < 0):
            raise ValueError('Unsupported APC key stream entry: ' + path)
    return {'source': source(library, path), 'commands': [[e['tag'], *e['values']] for e in entries]}


def compile_companion(library, path):
    fields = {f['tag']: f['values'] for f in script(library, path)}
    stream_fields = fields['[key stream]']
    if not stream_fields or len(stream_fields) % 2:
        raise ValueError('Invalid APC stream table: ' + path)
    streams = {}
    for key, name in zip(stream_fields[::2], stream_fields[1::2]):
        if key in streams or PurePosixPath(name).name != name:
            raise ValueError('Invalid APC stream binding: ' + str(name))
        streams[key] = compile_stream(library, resolve(path, 'key/' + name))
    patterns = fields['[ai pattern]']
    if len(patterns) != len(ENTRY_POINTS):
        raise ValueError('Invalid APC AI table: ' + path)
    ai = {role: resolve(path, 'ai/' + name) for role, name in zip(ENTRY_POINTS, patterns)}
    programs = {}
    for program in ai.values():
        compile_ai(library, program, programs, streams, set())
    result = {'source': source(library, path), 'ai': ai, 'programs': programs, 'streams': streams}
    for tag in ('minimum info', 'party member', 'character status rate', 'additional character status',
                'attack damage rate', 'quick skill', 'skill', 'equipment', 'think term',
                'destination change term', 'keep distance with target', 'vision', 'skill correction',
                'far attack reaction rate', 'targeting bonus', 'warlike', 'appearance point'):
        result[tag.replace(' ', '_')] = fields['[' + tag + ']']
    return result


def build(library):
    listing = library.listing(INDEX)
    return {'schema': 'dnf_companion_programs/1', 'index': source(library, INDEX), 'companions': {
        str(apc_id): compile_companion(library, resolve(INDEX, listing[apc_id])) for apc_id in IDS
    }}


def verify_archives(library, result, reference_root):
    paths = {INDEX}
    for companion in result['companions'].values():
        paths.add(companion['source']['path'])
        paths.update(companion['programs'])
        paths.update(s['source']['path'] for s in companion['streams'].values())
    for path in [reference_root / '111Script.pvf', reference_root / '情怀60复古/ImagePacks2/Script.pvf']:
        archive = Archive(path, allow_known_client_transform=True)
        try:
            if any(archive.listing(INDEX).get(i) != library.listing(INDEX)[i] for i in IDS):
                raise ValueError('Different original APC index: ' + str(path))
            for item in sorted(paths):
                raw = archive.raw(item)
                if raw is None or raw != library.raw(item):
                    raise ValueError('Different original APC bytes: ' + str(path / item))
                if item != INDEX and parse_script(raw[0], archive.strings, PurePosixPath(item).suffix[1:])['fields'] != script(library, item):
                    raise ValueError('Different original APC strings: ' + str(path / item))
        finally:
            archive.close()
    print('Original APC archive entries verified:', len(paths))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path)
    parser.add_argument('--reference-root', type=Path)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    library = open_library(args.library)
    try:
        result = build(library)
        if args.reference_root is not None:
            verify_archives(library, result, args.reference_root)
    finally:
        library.close()
    if args.check:
        if json.loads(OUTPUT.read_text(encoding='utf-8')) != result:
            raise SystemExit('Companion program artifact is stale')
    else:
        OUTPUT.write_text(json.dumps(result, ensure_ascii=False, indent=1) + '\n', encoding='utf-8', newline='\n')
    print('Companion programs ready:', ', '.join(result['companions']))


if __name__ == '__main__':
    main()
