"""Export one original DNF dungeon and its maps as a traceable Godot sample (read-only).

Source is the archived 111Script.pvf backup inside the shared library; the effective
runtime configuration is unconfirmed. Every interpretation carries an evidence class
(E-PARSE / E-INFER / E-UNKNOWN, see docs/design/26_DNF原版拆解_证据与版本.md). Values that
cannot be interpreted stay raw and produce diagnostics; nothing unknown becomes 0.
Generated data goes to the git-ignored game_dnf/assets_local or temp/, never to Git.
"""
from __future__ import annotations

import argparse
from contextlib import closing
import hashlib
import json
from pathlib import Path, PurePosixPath
import sqlite3

from audit_dnf_design import Strings, connect_readonly, decode_tokens, digest
from dnf_asset_store import LOCK, ROOT, cache_home

SCHEMA = 'dnf_native_map/1'
REVISION = 1
TILE_W, TILE_H = 224, 480
GRID_COLS, GRID_ROWS = 14, 30
CELL_W, CELL_H = 16, 12
SCREEN_Y_OFFSET = TILE_H - GRID_ROWS * CELL_H
DOOR_BITS = {'right': 1, 'up': 2, 'left': 4, 'down': 8}
OPPOSITE = {'left': 'right', 'right': 'left', 'up': 'down', 'down': 'up'}
STEP = {'left': (-1, 0), 'right': (1, 0), 'up': (0, -1), 'down': (0, 1)}
GATE_ORDER = ['left', 'right', 'up', 'down']
GATE_SLOTS = [('left', 'normal'), ('left', 'boss'), ('left', 'wall'), ('right', 'normal'),
              ('right', 'boss'), ('right', 'wall'), ('up', 'normal'), ('up', 'boss'),
              ('down', 'normal'), ('down', 'boss')]
LAYERS = ['distantback', 'middleback', 'bottom', 'closeback', 'normal', 'close']
DEFAULT_OUTPUT = ROOT / 'game_dnf/assets_local/native_maps'

COORDINATES = {
    'map_x': {'unit': 'pixel', 'claim': 'Map x equals screen pixels; each [tile] column is 224 wide.',
              'evidence': 'E-PARSE: tile IMG canvas 224 wide; right pathgate x is width-15±3 in all lorien maps.'},
    'map_y': {'unit': 'ground depth unit', 'claim': f'screen_y = map_y + {SCREEN_Y_OFFSET} - z',
              'evidence': 'E-INFER: pass grid 30 rows x 12 = 360 aligns with the bottom of the 480 tile canvas; '
                          'up/down pathgate y lands exactly on walkable grid edges in 298/471 of 2488 maps.'},
    'pass_grid': {'claim': f'{GRID_COLS}x{GRID_ROWS} per tile column, cell {CELL_W}x{CELL_H} map units, 0=walkable, 2=blocked',
                  'evidence': 'E-INFER: 92% of 19582 monster spawn points fall on 0 cells; other values unknown.'},
    'background_y': {'claim': 'Background and tile images use screen space (anchor y=0); dgn [background pos] kept raw.',
                     'evidence': 'E-UNKNOWN: effect of [background pos] needs original screenshots.'},
    'layers': {'claim': ' < '.join(LAYERS) + '; normal is sorted by ground y',
               'evidence': 'E-INFER from tag names; draw order needs original footage.'},
    'scroll': {'claim': 'distantback/middleback/close scroll at far/middle/near sight scroll percent and repeat horizontally',
               'evidence': 'E-INFER from tag names; repeat behaviour unknown.'},
    'greed': {'claim': 'Dungeon cell letter minus "A" is a door mask: right=1 up=2 left=4 down=8',
              'evidence': 'E-INFER: all lorien neighbours are reciprocal; best of 24 bit orders across 328 dgn files.'},
    'gate_images': {'claim': '%d%d in gate IMG templates is filled with the two digits of the second [int data] value; '
                             'first value is state 0=always 1=closed 2=open',
                    'evidence': 'E-INFER: produces existing files (normal 01, boss 05/02); state matches Close/Open names.'},
}


def normalize(parts: list[str]) -> str:
    out: list[str] = []
    for part in parts:
        if part == '..':
            if not out:
                raise ValueError('Path escapes archive root')
            out.pop()
        elif part and part != '.':
            out.append(part)
    return '/'.join(out)


def resolve(base_file: str, relative: str) -> str:
    """Resolve a script-relative reference the way ANI/OBJ paths are written (case-insensitive)."""
    parent = PurePosixPath(base_file.lower()).parent.parts
    return normalize(list(parent) + relative.lower().replace('\\', '/').split('/'))


def sprite_path(img_ref: str) -> str:
    return 'sprite/' + img_ref.lower().replace('\\', '/').lstrip('/')


def fill_template(img_ref: str, variant: int | None) -> str:
    if '%d%d' not in img_ref:
        return img_ref
    if variant is None or not 0 <= variant <= 99:
        raise ValueError('Template variant unavailable')
    return img_ref.replace('%d%d', f'{variant // 10}{variant % 10}', 1)


def plain(tokens: list[dict]) -> list:
    """Token values for interpretation; unresolved tokens become None and are reported by callers."""
    return [t.get('value') for t in tokens]


def groups(values: list, size: int, label: str, path: str, diags: list) -> list[list]:
    if len(values) % size:
        diags.append(diag('error', 'group_size', path, f'{label}: {len(values)} values not divisible by {size}; tail ignored'))
    return [values[i:i + size] for i in range(0, len(values) - len(values) % size, size)]


def special_records(values: list, path: str, diags: list) -> list[list]:
    """E-INFER layout: id,x,y,z,count then count x ('[kind]', 5 values)."""
    records, i = [], 0
    while i < len(values):
        head = values[i:i + 5]
        count = head[4] if len(head) == 5 else None
        end = i + 5 + 6 * count if isinstance(count, int) and count >= 0 else None
        if end is None or end > len(values) or any(not isinstance(values[j], str) for j in range(i + 5, end, 6)):
            diags.append(diag('error', 'special_object_layout', path, f'cannot split at value {i}; rest kept raw only'))
            break
        records.append(values[i:end])
        i = end
    return records


def diag(level: str, code: str, path: str, detail: str) -> dict:
    return {'level': level, 'code': code, 'path': path, 'detail': detail}


def parse_greed(text: str, width: int, height: int, path: str, diags: list) -> dict:
    rows = [r.strip() for r in text.replace('\r', '').split('\n') if r.strip()]
    cells = {}
    if len(rows) != height:
        diags.append(diag('error', 'greed_rows', path, f'{len(rows)} rows for size height {height}'))
    for y, row in enumerate(rows):
        row = row.replace(' ', '')
        if width <= 0 or len(row) % width:
            diags.append(diag('error', 'greed_width', path, f'row {y} "{row}" does not split into {width} cells'))
            continue
        chars = len(row) // width
        for x in range(width):
            code = row[x * chars:(x + 1) * chars]
            if len(set(code)) != 1:
                diags.append(diag('warning', 'greed_mixed', path, f'cell {x},{y} "{code}" has differing characters'))
            mask = ord(code[0]) - 65 if 'A' <= code[0] <= 'P' else None
            if mask is None:
                diags.append(diag('warning', 'greed_code', path, f'cell {x},{y} "{code}" outside A-P; doors unknown'))
            cells[(x, y)] = {'x': x, 'y': y, 'code': code, 'mask': mask,
                             'doors': [d for d in GATE_ORDER if mask is not None and mask & DOOR_BITS[d]]}
    for (x, y), cell in cells.items():
        for door in cell['doors']:
            other = cells.get((x + STEP[door][0], y + STEP[door][1]))
            if not other or OPPOSITE[door] not in other['doors']:
                diags.append(diag('warning', 'greed_unpaired', path, f'cell {x},{y} door {door} has no reciprocal door'))
    return cells


class Library:
    def __init__(self, library: Path, output: Path):
        self.root = library
        self.output = output
        self.config = connect_readonly(library / 'pvf_config.sqlite')
        self.catalog = connect_readonly(library / 'catalog.sqlite')
        self.catalog.row_factory = sqlite3.Row
        self.strings = Strings(self.config.execute("select content from files where path='stringtable.bin'").fetchone()[0])
        self.scripts: dict[str, dict | None] = {}
        self.images: dict[str, dict] = {}
        self.decoded: dict[str, tuple] = {}
        self.diags: list[dict] = []

    def close(self) -> None:
        self.config.close()
        self.catalog.close()

    def script(self, path: str) -> dict | None:
        path = path.lower()
        if path not in self.scripts:
            row = self.config.execute('select content,sha256,crc_ok from files where path=?', (path,)).fetchone()
            if row is None:
                self.scripts[path] = None
            else:
                try:
                    spans = decode_tokens(row[0], self.strings)['tag_spans']
                except ValueError as error:
                    self.diags.append(diag('error', 'script_decode', path, str(error)))
                    spans = []
                self.scripts[path] = {'path': path, 'sha256': row[1], 'crc_ok': bool(row[2]), 'spans': spans}
        return self.scripts[path]

    def listing(self, path: str) -> dict[int, str]:
        row = self.config.execute('select content from files where path=?', (path,)).fetchone()
        tokens = decode_tokens(row[0], self.strings)['tokens']
        values = [t.get('value') for t in tokens]
        return {k: v for k, v in zip(values[0::2], values[1::2]) if isinstance(k, int) and isinstance(v, str)}

    def animation(self, path: str) -> dict | None:
        row = self.config.execute(
            'select a.status,a.metadata,a.error,f.sha256 from animations a join files f on f.path=a.path where a.path=?',
            (path.lower(),)).fetchone()
        if row is None or row[0] != 'parsed' or not row[1]:
            return None
        return {'sha256': row[3], 'meta': json.loads(row[1])}

    def image(self, img_ref: str, frame: int, context: str) -> str | None:
        from dnf_asset_reader import decode, parse
        path = sprite_path(img_ref)
        rows = self.catalog.execute("select * from assets where lower(original_path)=? and validation='image_data_checked'",
                                    (path,)).fetchall()
        if not rows:
            self.diags.append(diag('error', 'image_missing', context, f'{path} has no validated IMG in catalog'))
            return None
        rows = sorted(rows, key=lambda r: (not Path(r['container']).name.lower().startswith('sprite_'), r['container']))
        row = rows[0]
        key = f"{row['sha256'][:12]}_{frame}"
        if key in self.images:
            return key
        if row['sha256'] not in self.decoded:
            data = (self.root / row['local_path']).read_bytes()
            if hashlib.sha256(data).hexdigest() != row['sha256']:
                raise ValueError('Library IMG hash mismatch: ' + row['local_path'])
            self.decoded[row['sha256']] = (data, parse(data))
        data, parsed = self.decoded[row['sha256']]
        if not 0 <= frame < len(parsed['frames']):
            self.diags.append(diag('error', 'image_frame', context, f'{path} frame {frame} outside {len(parsed["frames"])}'))
            return None
        image, meta = decode(data, parsed, frame)
        target = self.output / 'img' / (key + '.png')
        target.parent.mkdir(parents=True, exist_ok=True)
        image.save(target)
        self.images[key] = {'file': 'img/' + target.name, 'source_path': row['original_path'], 'source_npk': row['container'],
                            'img_sha256': row['sha256'], 'frame': frame, 'size': [image.width, image.height],
                            'canvas_offset': [meta.get('x', 0), meta.get('y', 0)], 'variants': len(rows)}
        if len(rows) > 1:
            self.diags.append(diag('info', 'image_variants', context,
                                   f'{path}: {len(rows)} candidates; chose {row["container"]} (sprite_ package first, not proven client priority)'))
        return key

    def sprite(self, ani_path: str, context: str, variant: int | None = None) -> dict | None:
        ani = self.animation(ani_path)
        if ani is None:
            self.diags.append(diag('error', 'ani_missing', context, f'{ani_path} absent or not parsed'))
            return None
        frames = []
        for f in ani['meta']['frames']:
            entry = {'frame': f['frame'], 'delay_ms': f.get('delay_ms'), 'items': f.get('items', {}), 'image': None}
            if f.get('img'):
                try:
                    ref = fill_template(f['img'], variant)
                except ValueError:
                    self.diags.append(diag('error', 'img_template', context, f'{f["img"]} needs a variant'))
                    ref = None
                key = self.image(ref, f['img_frame'], context) if ref else None
                if key:
                    canvas = self.images[key]['canvas_offset']
                    entry.update(image=key, offset=[f['pos'][0] + canvas[0], f['pos'][1] + canvas[1]])
            items = entry['items']
            scale = items.get('7')
            entry['flip_x'] = bool(isinstance(scale, list) and scale and scale[0] < 0)
            entry['color'] = items.get('9')
            entry['additive'] = isinstance(items.get('11'), dict) and items['11'].get('type') == 2
            frames.append(entry)
        return {'ani': ani_path, 'ani_sha256': ani['sha256'], 'loop_flag': ani['meta'].get('global_items', {}).get('1'),
                'duration_ms': ani['meta'].get('duration_ms'), 'frames': frames}


def flatten(values: list) -> list:
    """把可能嵌套一层的值列表展平（原版 [dungeon]/[greed] 两种存法都存在）。"""
    out: list = []
    for entry in values:
        if isinstance(entry, list):
            out.extend(entry)
        else:
            out.append(entry)
    return out


def span_values(spans: list[dict], tag: str) -> list | None:
    for span in spans:
        if span['tag'] == tag:
            return plain(span['values'])
    return None


def raw_spans(script: dict) -> list[dict]:
    return [{'tag': s['tag'], 'offset': s['offset'],
             'values': [[t['type'], t['raw_hex'], t.get('value')] for t in s['values']]} for s in script['spans']]


def layer_name(token, path: str, diags: list) -> str:
    name = token.strip('[]') if isinstance(token, str) else None
    if name not in LAYERS:
        diags.append(diag('warning', 'layer_unknown', path, f'layer {token!r} unknown; placed in normal'))
        return 'normal'
    return name


def export_map(lib: Library, path: str, ids: dict) -> dict:
    script = lib.script(path)
    diags = lib.diags
    spans = script['spans']
    room = {'path': path, 'sha256': script['sha256'], 'crc_ok': script['crc_ok'], 'raw': raw_spans(script),
            'tiles': [], 'background': [], 'animations': [], 'objects': [], 'monsters': [], 'walk_grid': []}
    handled = set()

    tiles = span_values(spans, '[tile]') or []
    handled.update({'[tile]', '[/tile]'})
    for col, tile in enumerate(tiles):
        til_path = resolve(path, tile)
        til = lib.script(til_path)
        entry = {'column': col, 'til': til_path, 'sha256': til and til['sha256'], 'image': None, 'offset': None, 'pass': None}
        if til is None:
            diags.append(diag('error', 'tile_missing', path, til_path))
        else:
            image = span_values(til['spans'], '[IMAGE]')
            passes = span_values(til['spans'], '[pass type]')
            if image and len(image) >= 2:
                entry['image'] = lib.image(image[0], image[1], til_path)
                if entry['image']:
                    entry['offset'] = lib.images[entry['image']]['canvas_offset']
            if passes and len(passes) == GRID_COLS * GRID_ROWS:
                entry['pass'] = passes
            else:
                diags.append(diag('error', 'tile_pass', til_path, f'pass type has {len(passes or [])} values'))
        room['tiles'].append(entry)
    for row in range(GRID_ROWS):
        line = []
        for entry in room['tiles']:
            line += entry['pass'][row * GRID_COLS:(row + 1) * GRID_COLS] if entry['pass'] else [None] * GRID_COLS
        room['walk_grid'].append(line)
    room['width'] = len(tiles) * TILE_W

    scroll = {}
    for key, tag in [('distantback', '[far sight scroll]'), ('middleback', '[middle sight scroll]'), ('close', '[near sight scroll]')]:
        value = span_values(spans, tag)
        handled.add(tag)
        scroll[key] = value[0] if value else None
        if not value:
            diags.append(diag('info', 'scroll_absent', path, f'{tag} absent; loader keeps 100%'))
    room['scroll_percent'] = scroll

    current, inside = None, False
    for span in spans:
        tag, values = span['tag'], plain(span['values'])
        if tag == '[background animation]':
            inside = True
        elif tag == '[/background animation]':
            inside = False
        elif inside and tag == '[ani info]':
            current = {}
        elif inside and current is not None and tag in ('[filename]', '[layer]', '[order]'):
            current[tag.strip('[]')] = values[0] if values else None
        elif inside and tag == '[/ani info]' and current is not None:
            ani_path = resolve(path, current.get('filename') or '')
            sprite = lib.sprite(ani_path, path)
            room['background'].append({'layer': layer_name(current.get('layer'), path, diags),
                                       'order': (current.get('order') or '').strip('[]') or None,
                                       'anchor': [0, 0, 0], 'space': 'screen', 'sprite': sprite})
            current = None
    handled.update({'[background animation]', '[/background animation]', '[ani info]', '[/ani info]',
                    '[filename]', '[layer]', '[order]'})

    for group in groups(span_values(spans, '[animation]') or [], 5, '[animation]', path, diags):
        ani, layer, x, y, z = group
        room['animations'].append({'layer': layer_name(layer, path, diags), 'anchor': [x, y, z], 'space': 'map',
                                   'sprite': lib.sprite(resolve(path, ani), path)})
    handled.update({'[animation]', '[/animation]'})

    objects = ids['objects']
    for group in groups(span_values(spans, '[passive object]') or [], 4, '[passive object]', path, diags):
        room['objects'].append(export_object(lib, group, '[passive object]', objects, path))
    for group in special_records(span_values(spans, '[special passive object]') or [], path, diags):
        room['objects'].append(export_object(lib, group, '[special passive object]', objects, path))
    handled.update({'[passive object]', '[/passive object]', '[special passive object]', '[/special passive object]'})

    for group in groups(span_values(spans, '[monster]') or [], 10, '[monster]', path, diags):
        mob_id, x, y, z = group[0], group[3], group[4], group[5]
        mob_rel = ids['monsters'].get(mob_id)
        entry = {'id': mob_id, 'anchor': [x, y, z], 'raw': group, 'mob': None, 'sprite': None,
                 'field_meaning': {'0': 'monster id (E-PARSE via monster.lst)', '3-5': 'x,y,z (E-INFER)',
                                   'others': 'unknown (level/count/type/AI candidates)'}}
        if mob_rel is None:
            diags.append(diag('error', 'monster_id', path, f'monster id {mob_id} absent from monster.lst'))
        else:
            mob_path = ('monster/' + mob_rel).lower()
            entry['mob'] = mob_path
            mob = lib.script(mob_path)
            motion = mob and span_values(mob['spans'], '[waiting motion]')
            if motion:
                entry['sprite'] = lib.sprite(resolve(mob_path, motion[0]), mob_path)
            else:
                diags.append(diag('error', 'monster_motion', mob_path, 'no [waiting motion]'))
        room['monsters'].append(entry)
    handled.update({'[monster]', '[/monster]'})

    gates = span_values(spans, '[pathgate pos]')
    handled.add('[pathgate pos]')
    room['pathgate_pos'] = {d: gates[i * 2:i * 2 + 2] for i, d in enumerate(GATE_ORDER)} if gates and len(gates) == 8 else None
    if room['pathgate_pos'] is None:
        diags.append(diag('error', 'pathgate_pos', path, f'expected 8 values, got {gates}'))
    greed = span_values(spans, '[greed]')
    handled.add('[greed]')
    room['greed_codes'] = [code[0] for code in (greed[0].split() if greed and isinstance(greed[0], str) else [])]
    sound = span_values(spans, '[sound]')
    room['sound'] = sound
    handled.update({'[sound]', '[/sound]', '[dungeon]', '[/dungeon]'})
    # [dungeon start area] = x, y, width, depth of the player's entry rectangle (E-PARSE values).
    start = span_values(spans, '[dungeon start area]')
    room['start_area'] = start if start and len(start) == 4 else None
    handled.add('[dungeon start area]')
    unhandled = sorted({s['tag'] for s in spans} - handled)
    room['unhandled_tags'] = unhandled
    if unhandled:
        diags.append(diag('info', 'unhandled_tags', path, ', '.join(unhandled) + ' kept raw only'))
    return room


def export_object(lib: Library, group: list, tag: str, objects: dict, path: str) -> dict:
    obj_id, x, y, z = group[:4]
    entry = {'id': obj_id, 'source_tag': tag, 'anchor': [x, y, z], 'raw': group, 'obj': None, 'layer': 'normal',
             'width': None, 'pass_type': None, 'sprite': None,
             'field_meaning': {'0': 'object id (E-PARSE via passiveobject.lst)', '1-3': 'x,y,z (E-INFER)', 'others': 'unknown'}}
    rel = objects.get(obj_id)
    if rel is None:
        lib.diags.append(diag('error', 'object_id', path, f'object id {obj_id} absent from passiveobject.lst'))
        return entry
    obj_path = ('passiveobject/' + rel).lower()
    entry['obj'] = obj_path
    obj = lib.script(obj_path)
    if obj is None:
        lib.diags.append(diag('error', 'object_missing', path, obj_path))
        return entry
    layer = span_values(obj['spans'], '[layer]')
    entry['layer'] = layer_name(layer[0], obj_path, lib.diags) if layer else 'normal'
    entry['width'] = span_values(obj['spans'], '[width]')
    pass_type = span_values(obj['spans'], '[pass type]')
    entry['pass_type'] = pass_type[0] if pass_type else None
    motion = span_values(obj['spans'], '[basic motion]')
    if motion:
        entry['sprite'] = lib.sprite(resolve(obj_path, motion[0]), obj_path)
    else:
        lib.diags.append(diag('info' if 'particlefactory' in obj_path else 'warning', 'object_unrendered', obj_path,
                              'no [basic motion]; particle/behaviour not rendered, kept as data only'))
    return entry


def export_gate_object(lib: Library, obj_id: int, objects: dict) -> dict:
    obj_path = ('passiveobject/' + objects[obj_id]).lower()
    obj = lib.script(obj_path)
    strings = span_values(obj['spans'], '[string data]') or []
    ints = span_values(obj['spans'], '[int data]') or []
    layer = span_values(obj['spans'], '[layer]')
    result = {'id': obj_id, 'obj': obj_path, 'sha256': obj['sha256'], 'raw': raw_spans(obj),
              'layer': layer_name(layer[0], obj_path, lib.diags) if layer else 'normal', 'parts': [], 'door_tile': None}
    if len(ints) != 2 * len(strings):
        lib.diags.append(diag('warning', 'gate_int_pairs', obj_path, f'{len(strings)} strings vs {len(ints)} ints'))
    for index, name in enumerate(strings):
        state, variant = (ints[index * 2:index * 2 + 2] + [None, None])[:2]
        if str(name).lower().endswith('.til'):
            result['door_tile'] = {'til': resolve(obj_path, name), 'raw_pair': [state, variant],
                                   'note': 'E-UNKNOWN: pass overlay semantics not applied'}
            continue
        stem = PurePosixPath(str(name)).stem.lower()
        role = ('under' if stem.endswith('u1') else 'over' if stem.endswith('o1') else 'light' if 'light' in stem
                else 'door_open' if 'opendoor' in stem else 'door_closed' if 'closedoor' in stem else 'frame')
        layer_for = {'under': 'closeback', 'over': 'close'}.get(role, result['layer'])
        result['parts'].append({'role': role, 'state': {0: 'always', 1: 'closed', 2: 'open'}.get(state, 'unknown'),
                                'raw_pair': [state, variant], 'layer': layer_for,
                                'sprite': lib.sprite(resolve(obj_path, name), obj_path, variant)})
    return result


def export_dungeon(lib: Library, dungeon_path: str, extra_maps: list[str]) -> dict:
    ids = {'maps': lib.listing('map/map.lst'), 'objects': lib.listing('passiveobject/passiveobject.lst'),
           'monsters': lib.listing('monster/monster.lst'), 'dungeons': lib.listing('dungeon/dungeon.lst')}
    script = lib.script(dungeon_path)
    if script is None:
        raise ValueError('Dungeon script absent: ' + dungeon_path)
    spans = script['spans']
    dungeon_index = next((k for k, v in ids['dungeons'].items() if ('dungeon/' + v).lower() == dungeon_path), None)
    size = span_values(spans, '[size]') or [0, 0]
    greed = span_values(spans, '[greed]') or ['']
    cells = parse_greed(greed[0], size[0], size[1], dungeon_path, lib.diags)
    start_raw, boss_raw = span_values(spans, '[start map]'), span_values(spans, '[boss map]')
    as_cells = lambda raw: [raw[i:i + 2] for i in range(0, len(raw) - 1, 2)] if raw else []
    boss_cells = {tuple(c) for c in as_cells(boss_raw)}
    gate_ids = span_values(spans, '[pathgate object]') or []
    slots = {f'{d}_{k}': gate_ids[i] for i, (d, k) in enumerate(GATE_SLOTS) if i < len(gate_ids)}
    if len(gate_ids) != len(GATE_SLOTS):
        lib.diags.append(diag('error', 'pathgate_object', dungeon_path, f'expected 10 gate ids, got {gate_ids}'))

    candidates: dict[str, dict] = {}
    for map_id, rel in ids['maps'].items():
        map_path = ('map/' + rel).lower()
        map_script = lib.script(map_path)
        if not map_script:
            continue
        # [dungeon]/[greed] 在同一批地图里可能是平铺值，也可能多包一层列表，
        # 统一展平再比对；否则 11 in [[11]] 恒为 False，整批地图会被判成不属于该副本。
        owners = flatten(span_values(map_script['spans'], '[dungeon]') or [])
        if dungeon_index in owners or map_path in extra_maps:
            codes = flatten(span_values(map_script['spans'], '[greed]') or [])
            candidates[map_path] = {'map_id': map_id, 'codes': [c[0] for c in codes[0].split()] if codes and codes[0] else []}
    rooms = {path: export_map(lib, path, ids) for path in sorted(candidates)}
    for path, room in rooms.items():
        room['map_id'] = candidates[path]['map_id']
        stem = PurePosixPath(path).stem
        room['role_hint'] = ('start' if stem.startswith('s') else 'boss_near_or_unknown' if stem.startswith('bn')
                             else 'boss' if stem.startswith('b') else 'normal')

    gate_objects = {str(i): export_gate_object(lib, i, ids['objects']) for i in sorted(set(slots.values()))}
    placements = []
    for (x, y), cell in sorted(cells.items(), key=lambda kv: (kv[0][1], kv[0][0])):
        cell['map_candidates'] = sorted(p for p, c in candidates.items() if cell['code'][0] in c['codes'])
        cell['start_candidate'] = [x, y] in as_cells(start_raw)
        cell['boss_candidate'] = (x, y) in boss_cells
        if not cell['map_candidates']:
            lib.diags.append(diag('warning', 'cell_without_map', dungeon_path, f'cell {x},{y} code {cell["code"]}'))
        for map_path in cell['map_candidates']:
            gates = []
            room = rooms[map_path]
            for door in GATE_ORDER:
                neighbour = (x + STEP[door][0], y + STEP[door][1])
                if door in cell['doors']:
                    kind = 'boss' if neighbour in boss_cells else 'normal'
                elif door in ('left', 'right'):
                    kind = 'wall'
                else:
                    continue
                anchor = room['pathgate_pos'][door] if room['pathgate_pos'] else None
                gates.append({'direction': door, 'kind': kind, 'object': str(slots.get(f'{door}_{kind}')),
                              'anchor': anchor + [0] if anchor else None, 'target_cell': list(neighbour) if kind != 'wall' else None})
            placements.append({'id': f'{x}_{y}:{PurePosixPath(map_path).stem}', 'cell': [x, y], 'map': map_path, 'gates': gates})

    return {'path': dungeon_path, 'sha256': script['sha256'], 'crc_ok': script['crc_ok'], 'index': dungeon_index,
            'raw': raw_spans(script), 'size': size,
            'cells': [cells[k] for k in sorted(cells, key=lambda c: (c[1], c[0]))],
            'start_map_raw': start_raw, 'boss_map_raw': boss_raw,
            'start_boss_interpretation': 'E-INFER: value pairs are candidate cells (x,y); random choice unverified',
            'background_pos_raw': span_values(spans, '[background pos]'), 'pathgate_slots': slots,
            'gate_objects': gate_objects, 'rooms': rooms, 'placements': placements,
            'cell_map_rule': 'E-INFER: a map is a candidate when its [dungeon] lists this dungeon and its [greed] contains the cell letter'}


def run(library: Path, dungeon: str, output: Path, extra_maps: list[str]) -> dict:
    lock = json.loads(LOCK.read_text(encoding='utf-8'))
    output.mkdir(parents=True, exist_ok=True)
    lib = Library(library, output)
    try:
        exported = export_dungeon(lib, dungeon.lower(), [m.lower() for m in extra_maps])
    finally:
        lib.close()
    result = {'schema': SCHEMA, 'revision': REVISION,
              'source': {'asset_version': lock['version'], 'config_role': '111Script.pvf backup in shared library; effective runtime PVF unconfirmed',
                         'config_db_sha256': digest(library / 'pvf_config.sqlite'), 'catalog_db_sha256': digest(library / 'catalog.sqlite'),
                         'exporter': 'tools/export_dnf_map.py'},
              'coordinates': COORDINATES,
              'constants': {'tile_width': TILE_W, 'tile_height': TILE_H, 'grid_cols': GRID_COLS, 'grid_rows': GRID_ROWS,
                            'cell_width': CELL_W, 'cell_height': CELL_H, 'screen_y_offset': SCREEN_Y_OFFSET,
                            'viewport': [640, 480], 'layers': LAYERS},
              'dungeon': exported, 'images': lib.images, 'diagnostics': lib.diags}
    (output / 'map_export.json').write_text(json.dumps(result, ensure_ascii=False, indent=1, allow_nan=False) + '\n', encoding='utf-8')
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path)
    parser.add_argument('--dungeon', default='dungeon/act1/lorien.dgn')
    parser.add_argument('--map', action='append', default=[], dest='maps', help='Extra exact map path to include')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    lock = json.loads(LOCK.read_text(encoding='utf-8'))
    library = (args.library or cache_home() / lock['version'] / 'library_v1').resolve()
    output = (args.output or DEFAULT_OUTPUT / PurePosixPath(args.dungeon.lower()).stem).resolve()
    allowed = [(ROOT / 'temp').resolve(), (ROOT / 'game_dnf/assets_local').resolve()]
    if not any(output == base or base in output.parents for base in allowed):
        parser.error('Export output must stay in git-ignored temp/ or game_dnf/assets_local/')
    result = run(library, args.dungeon, output, args.maps)
    levels = {}
    for d in result['diagnostics']:
        levels[d['level']] = levels.get(d['level'], 0) + 1
    print(json.dumps({'output': str(output / 'map_export.json'), 'rooms': len(result['dungeon']['rooms']),
                      'placements': len(result['dungeon']['placements']), 'images': len(result['images']),
                      'diagnostics': levels}, ensure_ascii=True))


if __name__ == '__main__':
    main()
