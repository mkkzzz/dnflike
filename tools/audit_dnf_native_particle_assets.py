"""Compare shipped native particle banks to original ANI fields and IMG pixels."""
import argparse
import hashlib
import json
from pathlib import Path
from PIL import Image

from build_dnf_combat_assets import Source, OUT, ROOT, native_particle_definitions, cropped, animation_flags


def audit(library=None, firewave=False):
    source = Source(library)
    manifest = json.loads((OUT/'manifest.json').read_text(encoding='utf8'))
    rows = []
    try:
        templates, effects = ({}, {}) if firewave else native_particle_definitions(source)
        banks = manifest['effects']
        if firewave:
            banks = {**manifest['effects'], **manifest['objects']}
            effects = {key: bank['source'] for key, bank in banks.items()
                       if '/animation/firewavebig/' in bank.get('source','')}
            if len(effects) != 4:
                raise ValueError('Need original front/back banks for both ordinary firewave stages')
        for path, definition in templates.items():
            if manifest['particles'][path] != definition:
                raise ValueError('Runtime PTL differs from original: '+path)
        for key, path in effects.items():
            bank = banks[key]
            ani = source.animation(path)
            if bank['source'] != path or bank['duration_ms'] != ani['duration_ms']:
                raise ValueError('ANI source/timing differs: '+path)
            if any(bank[k] != v for k,v in animation_flags(ani).items()):
                raise ValueError('ANI global flags differ: '+path)
            if len(bank['frames']) != len(ani['frames']):
                raise ValueError('ANI frame count differs: '+path)
            texture = ROOT/'game_dnf'/bank['atlas']['texture'].removeprefix('res://')
            with Image.open(texture) as atlas:
                for original, exported in zip(ani['frames'], bank['frames']):
                    if {k:v for k,v in exported.items() if k!='sprite'} != original:
                        raise ValueError('ANI frame metadata differs: '+path)
                    if not original.get('img'):continue
                    image, meta = source.frame(original['img'],original['img_frame'])
                    image, offset = cropped(image,meta)
                    item = bank['atlas']['items'][exported['sprite']]
                    if item['offset'] != [offset[0]+original['pos'][0],offset[1]+original['pos'][1]]:
                        raise ValueError('Sprite anchor differs: '+path)
                    x,y,w,h = item['rect']
                    if (w,h) != image.size or atlas.crop((x,y,x+w,y+h)).tobytes() != image.tobytes():
                        raise ValueError('Native pixels differ: '+path)
                rows.append({'source':path,'source_sha256':source.sources[path],
                             'texture':bank['atlas']['texture'],'texture_sha256':hashlib.sha256(texture.read_bytes()).hexdigest(),
                             'size':list(atlas.size),'frames':len(ani['frames']),'duration_ms':ani['duration_ms'],'loop':bank['loop']})
        for path,digest in source.sources.items():
            if manifest['sources'].get(path) != digest:
                raise ValueError('Source dependency hash differs: '+path)
        return {'schema':'dnf_native_firewave_assets/1' if firewave else 'dnf_native_particle_assets/1','asset_version':source.lib.asset_version,
                'method':'Every original ANI field, ordered PTL entry, sprite pixel and anchor compared; not gameplay fidelity approval',
                'templates':templates,'banks':rows,'sources':source.sources}
    finally:
        source.cat.close()
        source.lib.db.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library',type=Path)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--firewave',action='store_true',help='Audit four ordinary firewave ANI banks instead of particles')
    args=parser.parse_args()
    result=audit(args.library,args.firewave)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(result,ensure_ascii=False,indent=1)+'\n',encoding='utf8',newline='\n')
    print('[NATIVE_ASSETS] %d templates / %d banks / %d frames verified' % (len(result['templates']),len(result['banks']),sum(b['frames'] for b in result['banks'])))
