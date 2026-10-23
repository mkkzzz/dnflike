"""Create an immutable, source-traceable loop art + rendered evidence release."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import zipfile
from dnf_asset_store import ROOT, digest, write_json


def pack(output: Path, version: str, evidence: Path | None = None) -> dict:
    if output.exists() and any(output.iterdir()):raise ValueError('Use a new empty release folder')
    output.mkdir(parents=True, exist_ok=True)
    entries = []
    for kind, base in [('flow_v1', ROOT/'game_dnf/assets_local/flow_v1'), ('evidence', evidence or ROOT/'temp/loop_review')]:
        archive_path = output / (kind + '-01.zip')
        inventory = []
        files = sorted(p for p in base.rglob('*') if p.is_file() and not p.name.endswith('.import'))
        if not files:raise ValueError('No release files: ' + str(base))
        with zipfile.ZipFile(archive_path, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for file in files:
                name = kind + '/' + file.relative_to(base).as_posix()
                inventory.append({'path': name, 'bytes': file.stat().st_size, 'sha256': digest(file)})
                archive.write(file, name)
            archive.writestr('_manifests/' + archive_path.name + '.json', json.dumps(inventory).encode())
        entries.append({'name': archive_path.name, 'kind': kind, 'bytes': archive_path.stat().st_size,
                        'sha256': digest(archive_path), 'files': len(inventory),
                        'unpacked_bytes': sum(f['bytes'] for f in inventory)})
    # The ws1 kernel now requires compiled content and original combat banks.
    # Ship these inputs too, so consumers still need no full extraction library.
    combat_base = ROOT/'game_dnf/assets_local'
    combat_files = sorted(p for p in (combat_base/'combat').rglob('*') if p.is_file() and not p.name.endswith('.import'))
    content = combat_base/'content/combat_content.json'
    if not combat_files or not content.is_file():raise ValueError('Build ws1 combat runtime inputs before publishing the loop')
    combat_files.append(content)
    archive_path = output/'combat_runtime-01.zip'
    inventory = []
    with zipfile.ZipFile(archive_path, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for file in combat_files:
            name = 'combat_runtime/' + file.relative_to(combat_base).as_posix()
            inventory.append({'path': name, 'bytes': file.stat().st_size, 'sha256': digest(file)})
            archive.write(file, name)
        archive.writestr('_manifests/'+archive_path.name+'.json', json.dumps(inventory).encode())
    entries.append({'name': archive_path.name, 'kind': 'combat_runtime', 'bytes': archive_path.stat().st_size,
                    'sha256': digest(archive_path), 'files': len(inventory),
                    'unpacked_bytes': sum(f['bytes'] for f in inventory)})
    lock = {'schema': 'dnflike_loop_store/1', 'version': version, 'tag': version,
            'repository': 'mkkzzz/dnflike-assets', 'base_asset_version': 'dnf-native-assets-v1-20261022',
            'packs': [p for p in entries if p['kind'] in ['flow_v1', 'combat_runtime']],
            'evidence': [p for p in entries if p['kind'] == 'evidence']}
    write_json(output / 'flow_store.json', lock)
    write_json(output / 'asset_store.json', dict(lock, packs=entries))
    return lock


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--evidence-source', type=Path)
    args = parser.parse_args()
    if not args.output.resolve().is_relative_to((ROOT/'temp').resolve()):parser.error('Pack output must stay in temp/')
    if args.evidence_source and not args.evidence_source.resolve().is_relative_to((ROOT/'temp').resolve()):parser.error('Evidence must stay in temp/')
    print(json.dumps(pack(args.output.resolve(), args.version, args.evidence_source)))
