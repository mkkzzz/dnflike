"""Build/install the independent original item icon pack without changing town packs."""
from __future__ import annotations
import argparse
import json
from pathlib import Path, PurePosixPath
import shutil
import urllib.parse
import zipfile
from dnf_asset_store import ROOT, LOCK, GitHub, cache_home, digest, download, install_archive, write_json
from export_dnf_map import Library, span_values

ITEM_LOCK = ROOT/'game_dnf/items_store.json'


def build(library: Path, release: Path) -> None:
    if release.exists() and any(release.iterdir()):raise ValueError('Use a new empty release directory')
    release.mkdir(parents=True, exist_ok=True)
    output = ROOT/'game_dnf/assets_local/items_v2'
    lib = Library(library, output)
    try:
        icons = {}
        sources = {}
        for item, path in {
            'training_coat':'equipment/character/common/jacket/cloth/100050017.equ',
            'training_necklace':'equipment/character/common/amulet/100300001.equ',
            'scrap_iron':'stackable/material/piece_iron.stk',
        }.items():
            reference = span_values(lib.script(path)['spans'], '[icon]')
            icons[item] = lib.image(reference[0], int(reference[1]), item)
            if not icons[item]:raise ValueError('Missing original item icon: '+item)
            sources[item] = path
        write_json(output/'manifest.json', {'schema':'dnf_item_icons/1', 'items':icons,
            'images':lib.images, 'sources':sources,
            'selection':'E-ADAPT sample equipment uses original icons, not the source item identity or balance',
            'pixel_policy':'Original native RGBA, no resize, no drawing, no atlas replacement'})
    finally:lib.close()
    archive = release/'items_v2-01.zip'
    inventory = []
    with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as target:
        for source in sorted(output.rglob('*')):
            if not source.is_file() or source.name.endswith('.import'):continue
            name='items_v2/'+source.relative_to(output).as_posix()
            inventory.append({'path':name,'bytes':source.stat().st_size,'sha256':digest(source)})
            target.write(source,name)
        target.writestr('_manifests/'+archive.name+'.json',json.dumps(inventory).encode())
    lock={'schema':'dnflike_items_store/1','version':'dnf-items-v2-services-20261023','tag':'dnf-items-v2-services-20261023',
          'repository':'mkkzzz/dnflike-assets','packs':[{'kind':'items_v2','name':archive.name,
          'bytes':archive.stat().st_size,'sha256':digest(archive),'files':len(inventory),
          'unpacked_bytes':sum(f['bytes'] for f in inventory)}]}
    write_json(release/'asset_store.json',lock)
    write_json(ITEM_LOCK,lock)
    print('ITEM ICONS BUILT',len(icons),len(inventory))


def installed(lock: dict, project: Path) -> bool:
    root=(project/'assets_local').resolve()
    try:
        stamp=json.loads((root/'.items_install.json').read_text(encoding='utf8'))
        return stamp['version']==lock['version'] and len(stamp['files'])==sum(p['files'] for p in lock['packs']) and all(
            (root/name).resolve().is_relative_to(root) and (root/name).is_file() and digest(root/name)==sha
            for name,sha in stamp['files'].items())
    except (OSError,KeyError,ValueError,TypeError):return False


def sync(lock: dict, project: Path, local: Path | None) -> None:
    if lock.get('schema')!='dnflike_items_store/1':raise ValueError('Unsupported item pack')
    version=lock['version']
    if PurePosixPath(version).name!=version or ':' in version or '\\' in version or version in ['.','..']:raise ValueError('Invalid version')
    root=(project/'assets_local').resolve()
    if (project/'assets_local').is_symlink():raise ValueError('Asset root cannot be a symlink')
    github=None;remote={}
    if local is None:
        github=GitHub();release=github.json('/repos/'+lock['repository']+'/releases/tags/'+urllib.parse.quote(lock['tag'],safe=''))
        if release['draft']:raise ValueError('Item pack is still draft')
        remote={a['name']:a for a in release['assets']}
    hashes={};planned=[]
    for entry in lock['packs']:
        if entry['kind'] not in ['items_v1','items_v2'] or entry['name']!=entry['kind']+'-01.zip':raise ValueError('Unexpected item archive')
        archive=(local or cache_home()/'downloads'/version)/entry['name']
        if local is None:download(github,remote[entry['name']],entry,archive)
        base=cache_home()/version
        for info in install_archive(archive,entry,base):
            parts=PurePosixPath(info['path']).parts
            if parts[0]!=entry['kind']:raise ValueError('Unexpected item asset root')
            target=root/info['path']
            if not target.resolve().is_relative_to(root):raise ValueError('Item asset escapes root')
            if target.exists() and digest(target)!=info['sha256']:raise ValueError('Local item asset differs; preserved: '+str(target))
            hashes[info['path']]=info['sha256'];planned.append((base/info['path'],target))
    for source,target in planned:
        target.parent.mkdir(parents=True,exist_ok=True)
        if not target.exists():shutil.copyfile(source,target)
    write_json(root/'.items_install.json',{'version':version,'files':hashes})
    print('ITEM ICONS',len(hashes),'verified files')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode',choices=['build','sync'])
    parser.add_argument('--library',type=Path)
    parser.add_argument('--release',type=Path)
    parser.add_argument('--project',type=Path,default=ROOT/'game_dnf')
    parser.add_argument('--local-archives',type=Path)
    parser.add_argument('--check-installed',action='store_true')
    args=parser.parse_args()
    if args.mode=='build':
        if not args.release or not args.release.resolve().is_relative_to((ROOT/'temp').resolve()):parser.error('Release must stay in temp/')
        base=json.loads(LOCK.read_text(encoding='utf8'))['version']
        build(args.library or cache_home()/base/'library_v1',args.release)
    else:
        lock=json.loads(ITEM_LOCK.read_text(encoding='utf8'))
        if args.check_installed:raise SystemExit(0 if installed(lock,args.project) else 1)
        sync(lock,args.project,args.local_archives)
