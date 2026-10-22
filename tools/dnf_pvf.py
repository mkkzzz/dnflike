"""Structural decoder for archived PVF scripts (ATK/SKL/CHR/MOB/ACT/AI/LST...).

Builds an ordered field tree from the B0D0 token stream decoded by audit_dnf_design:
- ``[x] ... [/x]`` pairs become sections with children (closing tags seen in the file);
- enum slots (``[attack type]`` followed by ``[physic]``) are attached to their parent;
- known misspellings in shipped data map to a canonical tag through ALIASES (E-INFER);
- every value keeps its raw token type; nothing unknown is dropped.
This is structure only. Field meaning, units and runtime rules are not asserted here.
"""
from __future__ import annotations

from contextlib import closing
import hashlib
import json
from pathlib import Path, PurePosixPath
import sqlite3

from audit_dnf_design import Strings, connect_readonly, decode_tokens
from dnf_asset_store import LOCK, cache_home

# Parent tag -> number of following zero-value sibling tags that are its enum values.
# Derived from whole-library follower statistics (2026-10-22, 6089 ATK files); E-INFER.
ENUM_SLOTS = {
    'atk': {'[damage reaction]': 1, '[attack type]': 1, '[elemental property]': 1,
            '[hit info]': 2, '[attack direction]': 1, '[active status]': 1, '[hit direction]': 1},
    'skl': {'[type]': 1, '[weapon effect type]': 1},
}
# Spellings that occur in shipped files and are treated as the canonical tag. E-INFER.
ALIASES = {
    '[hit horizono]': '[hit horizon]', '[hit horizoon]': '[hit horizon]', '[hit horiozn]': '[hit horizon]',
    '[hit horizontal]': '[hit horizon]', '[horizontal]': '[hit horizon]',
    '[warter element]': '[water element]', '[Fire element]': '[fire element]', '[Dark element]': '[dark element]',
    '[no elemental]': '[no element]', '[none element]': '[no element]',
    '[noblood]': '[no blood]', '[damage bouns]': '[damage bonus]', '[Down]': '[down]',
    '[physical]': '[physic]', '[magical]': '[magic]',
}
VALUE_TYPES = {2: 'int', 4: 'float', 6: 'str', 7: 'str', 8: 'str', 9: 'link', 10: 'link'}


def canonical(tag: str) -> str:
    return ALIASES.get(tag, tag)


def key_of(tag: str) -> str:
    return canonical(tag).strip('[]').strip().lower().replace(' ', '_').replace('-', '_')


def _value(token: dict):
    kind = token['type']
    if kind in (2, 4, 6, 7, 8):
        return token.get('value')
    if kind == 5:
        return token.get('value')
    return {'link_type': kind, 'raw': token.get('raw_int')}


def parse_script(content: bytes, strings: Strings, kind: str = '') -> dict:
    """Return {'fields': [...], 'diagnostics': [...], 'token_types': {...}}."""
    decoded = decode_tokens(content, strings)
    spans = decoded['tag_spans']
    closers = {s['tag'][2:] for s in spans if isinstance(s['tag'], str) and s['tag'].startswith('[/')}
    root: list = []
    stack: list[tuple[str, list]] = [('', root)]
    diags: list = []
    for span in spans:
        tag = span['tag']
        if not isinstance(tag, str):
            diags.append({'code': 'non_string_tag', 'offset': span['offset']})
            continue
        values = [_value(t) for t in span['values']]
        types = [VALUE_TYPES.get(t['type'], 'tag' if t['type'] == 5 else 'unknown') for t in span['values']]
        if tag.startswith('[/'):
            name = tag[2:]
            depth = next((i for i in range(len(stack) - 1, 0, -1) if stack[i][0] == name), None)
            if depth is None:
                diags.append({'code': 'unmatched_close', 'tag': tag, 'offset': span['offset']})
                continue
            if depth != len(stack) - 1:
                diags.append({'code': 'implicit_close', 'tag': tag, 'offset': span['offset'],
                              'closed': [s[0] for s in stack[depth + 1:]]})
            del stack[depth:]
            continue
        node = {'tag': tag, 'values': values, 'types': types, 'offset': span['offset']}
        if canonical(tag) != tag:
            node['canonical'] = canonical(tag)
        stack[-1][1].append(node)
        if tag[1:] in closers:
            node['children'] = []
            stack.append((tag[1:], node['children']))
    if len(stack) > 1:
        diags.append({'code': 'unclosed_section', 'tags': [s[0] for s in stack[1:]]})
    _attach_enums(root, ENUM_SLOTS.get(kind, {}))
    return {'fields': root, 'diagnostics': diags,
            'unresolved_token_types': decoded['unresolved_types']}


def _attach_enums(nodes: list, slots: dict) -> None:
    i = 0
    while i < len(nodes):
        node = nodes[i]
        if 'children' in node:
            _attach_enums(node['children'], slots)
        count = slots.get(canonical(node['tag']), 0)
        if count and not node['values'] and 'children' not in node:
            taken = nodes[i + 1:i + 1 + count]
            node['enum'] = [{'tag': t['tag'], 'canonical': canonical(t['tag']), 'values': t['values']} for t in taken]
            del nodes[i + 1:i + 1 + len(taken)]
        i += 1


def find(fields: list, tag: str) -> list:
    """All top-level nodes with this canonical tag, in file order."""
    return [f for f in fields if canonical(f['tag']) == tag]


def first_values(fields: list, tag: str):
    hits = find(fields, tag)
    return hits[0]['values'] if hits else None


def parse_list(content: bytes, strings: Strings) -> dict:
    """LST files: alternating integer IDs and path strings."""
    decoded = decode_tokens(content, strings)
    out, pending = {}, None
    for token in decoded['tokens']:
        if token['type'] == 2:
            pending = token['value']
        elif token['type'] in (6, 7, 8) and pending is not None:
            out[pending] = token.get('value')
            pending = None
    return out


def resolve(base_file: str, relative: str) -> str:
    """Resolve a script-relative reference to a normalized lower-case archive path."""
    parts: list[str] = []
    for part in (PurePosixPath(base_file).parent / relative.replace('\\', '/')).parts:
        if part == '..':
            if parts:parts.pop()
        elif part not in ('.', ''):
            parts.append(part)
    return '/'.join(parts).lower()


class Library:
    """Read-only access to the shared extraction library (pvf_config.sqlite)."""

    def __init__(self, library: Path | None = None):
        lock = json.loads(LOCK.read_text(encoding='utf-8'))
        self.asset_version = lock['version']
        self.path = (library or cache_home() / lock['version'] / 'library_v1').resolve()
        self.db_path = self.path / 'pvf_config.sqlite'
        if not self.db_path.is_file():
            raise FileNotFoundError(f'Full extraction library missing: {self.db_path}; run python tools/dnf_asset_store.py sync --full')
        self.db = connect_readonly(self.db_path)
        self.strings = Strings(self.db.execute("select content from files where path='stringtable.bin'").fetchone()[0])

    def close(self) -> None:
        self.db.close()

    def raw(self, path: str) -> tuple[bytes, str] | None:
        row = self.db.execute('select content, sha256 from files where path=?', (path.lower(),)).fetchone()
        return (row[0], row[1]) if row else None

    def exists(self, path: str) -> bool:
        return self.db.execute('select 1 from files where path=?', (path.lower(),)).fetchone() is not None

    def script(self, path: str, kind: str = '') -> dict | None:
        found = self.raw(path)
        if found is None:
            return None
        content, sha = found
        result = parse_script(content, self.strings, kind or PurePosixPath(path).suffix.lstrip('.'))
        result['sha256'] = sha
        return result

    def listing(self, path: str) -> dict:
        found = self.raw(path)
        return parse_list(found[0], self.strings) if found else {}

    def animation(self, path: str) -> dict | None:
        row = self.db.execute('select a.status, a.metadata, a.error, f.sha256 from animations a join files f on f.path=a.path where a.path=?',
                              (path.lower(),)).fetchone()
        if row is None:
            return None
        status, metadata, error, sha = row
        return {'status': status, 'error': error, 'sha256': sha,
                'metadata': json.loads(metadata) if metadata else None}

    def files(self, extension: str):
        for path, content in self.db.execute('select path, content from files where extension=?', (extension,)):
            yield path, content


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def open_library(library: Path | None = None) -> Library:
    return Library(library)


__all__ = ['ALIASES', 'ENUM_SLOTS', 'Library', 'canonical', 'find', 'first_values', 'key_of',
           'open_library', 'parse_list', 'parse_script', 'resolve', 'sha256_file', 'closing', 'sqlite3']
