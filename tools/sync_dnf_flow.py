"""Install the independent native-loop art pack; preserve the base runtime stamp."""
from __future__ import annotations
import argparse
import json
from pathlib import Path, PurePosixPath
import shutil
import tempfile
import urllib.parse
from dnf_asset_store import ROOT, GitHub, cache_home, digest, download, install_archive, write_json
from sync_dnf_references import safe_name

LOCK = ROOT / 'game_dnf/flow_store.json'


def installed_matches(lock: dict, project: Path) -> bool:
    """Read-only launch check: an installed immutable pack needs no network."""
    root = (project/'assets_local').resolve()
    try:
        stamp = json.loads((root/'.flow_install.json').read_text(encoding='utf8'))
        hashes = stamp['files']
        if stamp['version'] != lock['version'] or len(hashes) != sum(p['files'] for p in lock['packs']):return False
        for name, expected in hashes.items():
            file = root/name
            if not file.resolve().is_relative_to(root) or not file.is_file() or digest(file) != expected:return False
        return True
    except (OSError, ValueError, KeyError, TypeError):return False


def sync_flow(lock: dict, home: Path, project: Path, local_archives: Path | None = None, evidence=False) -> Path:
    if lock.get('schema') != 'dnflike_loop_store/1' or not safe_name(lock.get('version', '')):
        raise ValueError('Unsupported loop lock/version')
    if home.resolve() == ROOT or ROOT in home.resolve().parents:
        raise ValueError('Cache must stay outside the source checkout')
    entries = list(lock['packs'])
    if not entries or any(p.get('kind') != 'flow_v1' or not safe_name(p.get('name', '')) for p in entries):
        raise ValueError('Invalid loop package kind/name')
    if len({p['name'] for p in entries}) != len(entries):
        raise ValueError('Duplicate loop packages')
    if evidence:
        extra = lock.get('evidence', [])
        if any(p.get('kind') != 'evidence' or not safe_name(p.get('name', '')) for p in extra):
            raise ValueError('Invalid evidence package')
        entries.extend(extra)
    github, remote = None, {}
    if local_archives is None:
        github = GitHub()
        release = github.json('/repos/' + lock['repository'] + '/releases/tags/' + urllib.parse.quote(lock['tag'], safe=''))
        if release['draft']:raise ValueError('Loop release is still a draft')
        remote = {p['name']: p for p in release['assets']}
    destination = home / lock['version']
    inventory = []
    for entry in entries:
        archive = (local_archives or home / 'downloads' / lock['version']) / entry['name']
        if local_archives is None:
            if entry['name'] not in remote:raise ValueError('Missing loop archive: ' + entry['name'])
            download(github, remote[entry['name']], entry, archive)
        members = install_archive(archive, entry, destination)
        if entry['kind'] == 'flow_v1':inventory.extend(members)
    unresolved = project / 'assets_local'
    if unresolved.is_symlink():raise ValueError('Asset consumer cannot be a symbolic link')
    target_root = unresolved.resolve()
    stamp = target_root / '.flow_install.json'
    previous = json.loads(stamp.read_text(encoding='utf-8')) if stamp.exists() else {}
    old_hashes = previous.get('files', {})
    planned, hashes = [], {}
    for info in inventory:
        relative = PurePosixPath(info['path'])
        if relative.parts[0] != 'flow_v1':raise ValueError('Unexpected loop root')
        target = target_root / relative.as_posix()
        if target_root not in target.resolve().parents:raise ValueError('Consumer path escapes assets_local')
        current = digest(target) if target.exists() else None
        if current and current not in [info['sha256'], old_hashes.get(relative.as_posix())]:
            raise ValueError('Local loop asset differs; preserved: ' + str(target))
        hashes[relative.as_posix()] = info['sha256']
        if current != info['sha256']:planned.append((destination / relative.as_posix(), target))
    for source, target in planned:
        target.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=target.parent, prefix='.dnf-flow-', delete=False) as out:
            temporary = Path(out.name)
            with source.open('rb') as inp:shutil.copyfileobj(inp, out, 1024 * 1024)
        temporary.replace(target)
    write_json(stamp, {'schema': 'dnflike_loop_install/1', 'version': lock['version'], 'files': hashes})
    print('LOOP', target_root / 'flow_v1', len(hashes), 'verified files')
    if evidence:print('EVIDENCE', destination / 'evidence')
    return target_root / 'flow_v1'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lock', type=Path, default=LOCK)
    parser.add_argument('--home', type=Path)
    parser.add_argument('--project', type=Path, default=ROOT / 'game_dnf')
    parser.add_argument('--local-archives', type=Path)
    parser.add_argument('--evidence', action='store_true')
    parser.add_argument('--check-installed', action='store_true', help='Verify the current project pack without network')
    args = parser.parse_args()
    lock = json.loads(args.lock.read_text(encoding='utf-8'))
    if args.check_installed:
        if not installed_matches(lock, args.project.resolve()):raise SystemExit(1)
        print('LOOP installed version and file hashes verified; offline launch ready')
        return
    sync_flow(lock, args.home or cache_home(),
              args.project.resolve(), args.local_archives, args.evidence)


if __name__ == '__main__':main()
