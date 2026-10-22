"""Install immutable supplemental source/reference materials outside the checkout.

This uses a separate lock and never changes the game's runtime installation stamp.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path, PurePosixPath
import urllib.parse

from dnf_asset_store import ROOT, GitHub, cache_home, download, install_archive

LOCK = ROOT / 'game_dnf/reference_store.json'


def safe_name(value: str) -> bool:
    return isinstance(value, str) and bool(value) and value not in ['.', '..'] and PurePosixPath(value).name == value and not any(c in value for c in ':\\/')


def sync_references(lock: dict, home: Path, local_archives: Path | None = None) -> Path:
    if lock.get('schema') != 'dnflike_reference_store/1' or not safe_name(lock.get('version', '')):
        raise ValueError('Unsupported reference lock/version')
    if home.resolve() == ROOT or ROOT in home.resolve().parents:
        raise ValueError('Reference cache must be outside this source checkout')
    entries = lock['packs']
    if not entries or any(p.get('kind') != 'references' or not safe_name(p.get('name', '')) for p in entries):
        raise ValueError('Invalid reference package kind/name')
    if len({p['name'] for p in entries}) != len(entries):
        raise ValueError('Duplicate reference package name')
    destination = home / lock['version']
    github, remote = None, {}
    if local_archives is None:
        github = GitHub()
        release = github.json('/repos/' + lock['repository'] + '/releases/tags/' + urllib.parse.quote(lock['tag'], safe=''))
        if release['draft']:
            raise ValueError('Reference release is still a draft')
        remote = {p['name']: p for p in release['assets']}
    for entry in entries:
        archive = (local_archives or home / 'downloads' / lock['version']) / entry['name']
        if local_archives is None:
            if entry['name'] not in remote:
                raise ValueError('Missing remote reference package: ' + entry['name'])
            download(github, remote[entry['name']], entry, archive)
        install_archive(archive, entry, destination)
    result = destination / 'references'
    print('REFERENCES', result)
    print('BASE_ASSET_VERSION', lock['base_asset_version'])
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lock', type=Path, default=LOCK)
    parser.add_argument('--home', type=Path)
    parser.add_argument('--local-archives', type=Path)
    args = parser.parse_args()
    lock = json.loads(args.lock.read_text(encoding='utf-8'))
    sync_references(lock, args.home.resolve() if args.home else cache_home(),
                    args.local_archives.resolve() if args.local_archives else None)


if __name__ == '__main__':
    main()
