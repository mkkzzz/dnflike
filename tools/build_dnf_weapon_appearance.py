"""Bake item-specific original weapon layers, independent of combat simulation.

EQU variation fills the two slots of the actual weapon ANI IMG template. No
item-ID-to-colour guess, family-default substitution, repainted pixels or clock
retiming. Shared native bindings are deduplicated, not made artificially unique.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import sqlite3

from PIL import Image
from build_dnf_assets import LAYERS
from build_dnf_combat_assets import Source
from dnf_locomotion import AVATAR, compose

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = re.compile(r'%02d%02d')
LAY_PATH = 'equipment/character/swordman.lay'


def sha(data):return hashlib.sha256(data).hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=1) + '\n', encoding='utf8', newline='\n')


def bind_image(template, variation):
    if len(variation) != 2 or not all(type(v) is int and 0 <= v <= 99 for v in variation):
        raise ValueError('Unsupported original weapon variation')
    if TEMPLATE.findall(template) != ['%02d%02d'] or template.count('%') != 2:
        raise ValueError('Unverified weapon image template: ' + template)
    return ('sprite/' + (template % tuple(variation))).lower().replace('\\', '/')


def recipe(fields):
    variation = [f['values'] for f in fields if f['tag'] == '[variation]']
    if len(variation) != 1:raise ValueError('Ambiguous weapon variation')
    layers = []
    current = None
    for f in fields:
        if f['tag'] == '[layer variation]':
            v = f['values']
            if len(v) != 2 or v[0] not in [650,2790] or not isinstance(v[1], str):
                raise ValueError('Unsupported original weapon layer')
            current = {'order':v[0], 'animation_folder':v[1].lower()}
            layers.append(current)
        elif f['tag'] == '[equipment ani script]':
            if current is None or f['values'] != [LAY_PATH]:raise ValueError('Unsupported equipment LAY binding')
            current['lay'] = LAY_PATH
    if sorted(l['order'] for l in layers) != [650,2790] or any('lay' not in l for l in layers):
        raise ValueError('Incomplete original front/back layers')
    return variation[0], sorted(layers, key=lambda l:l['order'])


class Atlas:
    def __init__(self, output, name):
        self.output, self.name = output, name
        self.items, self.frames = {}, []
        self.x = self.y = 2
        self.row_height = 0

    def add(self, number, image, offset):
        w,h = image.size
        if w + 4 > 2048:raise ValueError('Native frame too wide')
        if self.x + w + 2 > 2048:self.x=2;self.y+=self.row_height+4;self.row_height=0
        self.items[str(number)] = {'rect':[self.x,self.y,w,h], 'offset':offset, 'rgba_sha256':sha(image.tobytes())}
        self.frames.append((image,self.x,self.y))
        self.x+=w+4;self.row_height=max(self.row_height,h)

    def save(self):
        height=self.y+self.row_height+2
        if height>16384:raise ValueError('Native atlas exceeds supported texture extent')
        image=Image.new('RGBA',(2048,height))
        for frame,x,y in self.frames:image.paste(frame,(x,y))
        name=self.name+'.png';image.save(self.output/name)
        return {'texture':'res://assets_local/'+self.output.name+'/'+name,
                'items':self.items,'size':[2048,height]}


def check(output):
    data=json.loads((output/'manifest.json').read_text(encoding='utf8'))
    for file, digest in data['files'].items():
        if sha((output/file).read_bytes())!=digest:raise ValueError('Weapon asset hash: '+file)
    for bank in list(data['banks'].values())+list(data['body'].values()):
        with Image.open(output/Path(bank['texture']).name) as image:
            image=image.convert('RGBA')
            for number, frame in bank['items'].items():
                x,y,w,h=frame['rect']
                if sha(image.crop((x,y,x+w,y+h)).tobytes())!=frame['rgba_sha256']:raise ValueError('Weapon native pixels: '+number)
    for item, skin in data['items'].items():
        if skin not in data['appearances']:raise ValueError('Missing item skin: '+item)
    print('WEAPON APPEARANCE VERIFIED',data['summary'])
    return data


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library',type=Path)
    parser.add_argument('--version',default='weapon_appearance_v1')
    parser.add_argument('--check',action='store_true')
    args=parser.parse_args()
    if not re.fullmatch(r'weapon_appearance_v\d+',args.version):raise ValueError('Expected immutable weapon_appearance_vN')
    output=ROOT/'game_dnf/assets_local'/args.version
    if args.check:check(output);return
    if output.exists() and any(output.iterdir()):raise ValueError('Immutable appearance version already exists')
    output.mkdir(parents=True,exist_ok=True)
    src=Source(args.library)
    ram=sqlite3.connect(':memory:');src.cat.backup(ram);src.cat.close();ram.row_factory=sqlite3.Row
    ram.execute('create index if not exists appearance_image_lookup on assets(lower(original_path),validation)');src.cat=ram
    equipment=json.loads((ROOT/'game_dnf/data/numbers.json').read_text(encoding='utf8'))['equipment']
    equipment.update(json.loads((ROOT/'game_dnf/data/native_runtime.json').read_text(encoding='utf8'))['equipment'])
    equipment={k:v for k,v in equipment.items() if k.startswith('original_') and v['slot']=='weapon'}
    runtime=json.loads((ROOT/'game_dnf/assets_local/manifest.json').read_text(encoding='utf8'))
    combat=json.loads((ROOT/'game_dnf/assets_local/combat/manifest.json').read_text(encoding='utf8'))
    clips={k.removeprefix('player/'):v for k,v in runtime['clips'].items() if k.startswith('player/')}
    clips.update({k:v for k,v in combat['player_clips'].items() if k not in clips})
    data={'schema':'dnf_weapon_appearance/1','items':{},'appearances':{},'banks':{},'body':{},'animations':{},'source_images':{},'source_animations':{},'files':{},
          'legacy_aliases':{'iron_sword':'original_27601','forest_sword':'original_27800'},
          'policy':'Native original pixels; source two-number variation and ordered layer ANI; shared body, same absolute action clock; no simulation changes'}
    try:
        # Two unarmed body banks preserve the established attacks and the existing
        # corrected locomotion leg order. No category weapon is baked into them.
        for name,layers in [('base',LAYERS),('locomotion',AVATAR)]:
            paths=['sprite/character/swordman/equipment/avatar/'+p for p in layers]
            atlas=Atlas(output,'body_'+name)
            for n in range(210):
                image,offset=compose(src,paths,n);atlas.add(n,image,offset)
            data['body'][name]=atlas.save()
        image_banks={}
        for i,(item,definition) in enumerate(sorted(equipment.items())):
            if i%25==0:print('WEAPON ITEMS',i,'/',len(equipment),flush=True)
            path=definition['source']['path'];source=src.lib.script(path)
            variation,layers=recipe(source['fields'])
            descriptor=[]
            for layer in layers:
                compiled={'order':layer['order'],'clips':{}}
                folder=str(PurePosixPath(path).parent/layer['animation_folder'])
                for pose in clips:
                    animation=folder+'/'+pose+'.ani'
                    ani=src.animation(animation)
                    data['source_animations'][animation]=src.sources[animation]
                    templates=set(f['img'] for f in ani['frames'] if f.get('img'))
                    if len(templates)!=1:raise ValueError('Unsupported multi-image weapon ANI: '+animation)
                    template=next(iter(templates));image_path=bind_image(template,variation)
                    if image_path not in image_banks:
                        img=src.image(image_path)
                        if img is None:raise ValueError('Missing original weapon IMG: '+image_path)
                        bank_name='weapon_'+src.sources[image_path][:20]
                        if bank_name not in data['banks']:
                            atlas=Atlas(output,bank_name)
                            for n in range(len(img[1]['frames'])):
                                image,meta=src.frame(image_path,n);box=image.getbbox()
                                if box:image=image.crop(box);offset=[meta['x']+box[0],meta['y']+box[1]]
                                else:image=Image.new('RGBA',(1,1));offset=[meta.get('x',0),meta.get('y',0)]
                                atlas.add(n,image,offset)
                            data['banks'][bank_name]=atlas.save()
                        image_banks[image_path]=bank_name
                    bank=image_banks[image_path]
                    if 'bank' in compiled and compiled['bank']!=bank:raise ValueError('Weapon ANI changes source bank: '+animation)
                    compiled['bank']=bank
                    for frame in ani['frames']:
                        if str(frame.get('img_frame',0)) not in data['banks'][bank]['items']:raise ValueError('Weapon frame outside IMG: '+animation)
                        if set(frame.get('items',{}))-{'8','12','23'}:raise ValueError('Unknown weapon visual control: '+animation)
                    data['animations'].setdefault(animation,{'frames':ani['frames'],'duration_ms':ani['duration_ms'],'source_ani':animation,'sha256':src.sources[animation]})
                    compiled['clips'][pose]=animation
                descriptor.append(compiled)
            identity=sha(json.dumps(descriptor,sort_keys=True,separators=(',',':')).encode())[:20]
            data['appearances'].setdefault(identity,{'family':definition['weapon'],'variation':variation,'layers':descriptor})
            data['items'][item]=identity
            # Item identity never disappears even when the original shares a skin.
            data.setdefault('item_sources',{})[item]={'path':path,'sha256':source['sha256'],'variation':variation,'layers':layers}
        for image_path,digest in src.sources.items():
            if image_path.endswith('.img'):
                rows=src.cat.execute("select container from assets where lower(original_path)=? and sha256=? order by container",(image_path,digest)).fetchall()
                data['source_images'][image_path]={'sha256':digest,'source_npk_candidates':[r[0] for r in rows]}
        data['source_lay']={'path':LAY_PATH,'sha256':src.lib.raw(LAY_PATH)[1]}
        data['files']={p.name:sha(p.read_bytes()) for p in sorted(output.glob('*.png'))}
        data['summary']={'original_items':len(data['items']),'unique_appearances':len(data['appearances']),
                         'weapon_layer_banks':len(data['banks']),'body_banks':len(data['body']),
                         'poses':len(clips),'families':dict(Counter(v['weapon'] for v in equipment.values()))}
        write(output/'manifest.json',data)
        print('WEAPON APPEARANCE BUILT',data['summary'])
    finally:src.lib.close();src.cat.close()


if __name__=='__main__':main()
